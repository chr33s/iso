"""Boot-owner, TTL and control-record revocation of an owned filtered fixture."""
from datetime import datetime, timezone
import json
import os
import signal
import time
import tempfile

from filtered_egress_readiness import executable_path, owned_pid


def exercise(state, binary, config, run):
    runtime = binary.parent / "runtime/bin/iso-sandbox"
    machine = json.loads((state / "apple-machine.json").read_text())["machine_id"]
    directory = state.parents[1] / "runtime/sandboxes" / machine
    live_path = directory / "live.json"

    def replace_live(contents):
        # Never expose a malformed intermediate record: that would revoke through
        # parsing failure rather than the boot-identity predicate under test.
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".probe-live-", delete=False) as stream:
            temporary = stream.name
            try:
                stream.write(contents)
                stream.flush()
                os.fsync(stream.fileno())
                os.replace(temporary, live_path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)

    def companion():
        return owned_pid(state / "proxy-egress.pid", str(binary / "iso-egress"))

    def wait_closed(pid, timeout=10):
        deadline = time.monotonic() + timeout
        while executable_path(pid) == str((binary / "iso-egress").resolve()):
            assert time.monotonic() < deadline, "revoked egress grant stayed alive"
            time.sleep(.05)

    def restart():
        run(["stop", "brokers"])
        run(["start", "brokers", "--no-github"])
        run(["exec", "brokers", "--", "true"])

    # Exercise stop while the grant is healthy, not only after another fault has
    # already killed it. Otherwise supervisor expiry could mask broken teardown.
    pid = companion()
    run(["stop", "brokers"])
    wait_closed(pid)
    assert not (state / "egress-capability").exists()
    assert not (state / "egress-readiness-public-key").exists()
    run(["start", "brokers", "--no-github"])
    run(["exec", "brokers", "--", "true"])
    print("PASS explicit stop revokes a healthy egress grant and removes its authority", flush=True)

    # A stale supervisor must not renew against a replaced runtime boot record.
    original = live_path.read_bytes()
    changed = json.loads(original)
    changed["bootId"] = "0" * 32 if changed["bootId"] != "0" * 32 else "1" * 32
    pid = companion()
    try:
        replace_live(json.dumps(changed).encode())
        wait_closed(pid)
    finally:
        replace_live(original)
    run(["exec", "brokers", "--", "true"], expected=1, contains="FILTERED_EGRESS_NOT_READY")
    restart()
    print("PASS changed live boot identity permanently revokes the old egress grant", flush=True)

    old = json.loads(live_path.read_text())
    assert executable_path(old["pid"]) == str(runtime.resolve()), "unexpected VM-owner executable"
    pid = companion()
    os.kill(old["pid"], signal.SIGKILL)
    wait_closed(pid)
    deadline = time.monotonic() + 30
    while True:
        try:
            current = json.loads(live_path.read_text())
            if current["pid"] != old["pid"] and current["bootId"] != old["bootId"]:
                assert executable_path(current["pid"]) == str(runtime.resolve())
                break
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        assert time.monotonic() < deadline, "owner did not automatically respawn with a new boot"
        time.sleep(.1)
    run(["exec", "brokers", "--", "true"], expected=1)
    restart()
    print("PASS killed owner revokes old grant; automatic new boot cannot reuse it", flush=True)

    original_config = config.read_text()
    settings = json.loads(original_config)
    settings["limits"] = {"session_ttl": 60}
    run(["stop", "brokers"])
    config.write_text(json.dumps(settings))
    try:
        run(["start", "brokers", "--no-github"])
        run(["exec", "brokers", "--", "true"])
        record = json.loads((directory / "record.json").read_text())
        expires = datetime.fromisoformat(record["expiresAt"].replace("Z", "+00:00"))
        remaining = (expires - datetime.now(timezone.utc)).total_seconds()
        assert 0 < remaining <= 60, "runtime TTL missing or not armed"
        pid = companion()
        wait_closed(pid, timeout=remaining + 10)
        run(["exec", "brokers", "--", "true"], expected=1)
        print("PASS session TTL closes egress grant and refuses further guest handoffs", flush=True)
    finally:
        config.write_text(original_config)
        run(["stop", "brokers"])
    restart()
