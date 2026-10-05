"""Real-VM egress failure probes shared by the filtered composition gate.

Only the runner's private instance is modified. No provider request is made.
Capabilities and verification-key bytes are kept out of command arguments/logs.
"""
from contextlib import contextmanager
import base64
import ctypes
import json
import os
from pathlib import Path
import signal
import secrets
import subprocess
import time
from urllib.parse import urlsplit


def executable_path(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return os.path.realpath(os.fsdecode(buffer.value))


def owned_pid(path, executable):
    pid = int(path.read_text())
    assert pid > 1, "invalid fixture process identity"
    assert executable_path(pid) == os.path.realpath(executable), "fixture process identity changed"
    return pid


@contextmanager
def paused(path, executable):
    pid = owned_pid(path, executable)
    os.kill(pid, signal.SIGSTOP)
    try:
        yield pid
    finally:
        # Resume only the same executable, even if the test failed.
        if executable_path(pid) == os.path.realpath(executable):
            os.kill(pid, signal.SIGCONT)


def exercise(state, binary, config, run):
    # A successful CONNECT control is necessary: an empty allowlist would mask
    # an authentication bypass behind an unrelated hostname-policy refusal.
    # Running boots retain their policy; a stopped boot adopts the new list
    # without discarding the instance or its disk.
    machine = (state / "apple-machine.json").read_bytes()
    settings = json.loads(config.read_text())
    settings["egress_filter"] = {"allowed_hosts": ["api.github.com"]}
    config.write_text(json.dumps(settings))
    run(["exec", "brokers", "--", "true"], expected=1, contains="POLICY_CHANGE_REQUIRES_RESTART")
    run(["stop", "brokers"])
    run(["start", "brokers", "--no-github"])
    assert json.loads((state / "apple-machine.json").read_bytes())["machine_id"] == json.loads(machine)["machine_id"]
    print("PASS changed allowlist refuses running handoffs and applies after stop/start on the same VM", flush=True)
    key = state / "egress-readiness-public-key"
    capability = state / "egress-capability"
    original_key = key.read_bytes()
    original_capability = capability.read_bytes()
    assert len(original_key) == len(original_capability) == 64
    assert key.stat().st_mode & 0o777 == 0o600
    assert capability.stat().st_mode & 0o777 == 0o600

    def healthy():
        run(["exec", "brokers", "--", "true"])

    def exited(pid):
        deadline = time.monotonic() + 10
        while subprocess.run(["/bin/ps", "-p", str(pid)], stdout=subprocess.DEVNULL).returncode == 0:
            assert time.monotonic() < deadline, "revoked companion remained alive"
            time.sleep(.05)

    def refused():
        _, elapsed = run(["exec", "brokers", "--", "true"], expected=1,
                         contains="FILTERED_EGRESS_NOT_READY", timeout=20)
        assert elapsed < 15, "egress failure exceeded handoff deadline"
        text, _ = run(["status", "brokers"], contains="(unhealthy)", timeout=20)
        assert "FILTERED_EGRESS_NOT_READY" in text, "unhealthy status must name the failed proof"

    def endpoint(instance):
        text, _ = run(["exec", instance, "--", "printenv", "HTTPS_PROXY"], private=True)
        # CLI diagnostics can follow stdout; only parse the managed URL line.
        values = [line for line in text.splitlines() if line.startswith("http://iso:")]
        assert len(values) == 1, "missing unambiguous managed proxy endpoint"
        value = urlsplit(values[0])
        assert value.hostname == "127.0.0.1" and value.port is not None
        assert value.password and len(value.password) == 64
        return value

    def connect(instance, port, token, host, status):
        basic = base64.b64encode(("iso:" + token).encode()).decode()
        request = (f"{port}\nCONNECT {host}:443 HTTP/1.1\r\n"
                   f"Host: {host}:443\r\nProxy-Authorization: Basic {basic}\r\n\r\n")
        exchange(instance, request, status)

    def exchange(instance, request, status):
        probe = ('set -e; IFS= read -r port; [[ "$port" =~ ^[0-9]{1,5}$ ]]; '
                 'exec 3<>/dev/tcp/127.0.0.1/"$port"; cat >&3; head -n 1 <&3')
        output, _ = run(["shell", instance, "--", "timeout", "20", "bash", "-c", probe],
                        input=request, private=True)
        assert output.startswith(f"HTTP/1.1 {status} "), "unexpected guest probe status"

    def authenticated_probe(instance, port, token, status):
        basic = base64.b64encode(("iso:" + token).encode()).decode()
        request = (f"{port}\nGET /__iso/egress-ready HTTP/1.1\r\n"
                   f"Proxy-Authorization: Basic {basic}\r\n"
                   f"X-Iso-Nonce: {secrets.token_hex(16)}\r\n\r\n")
        exchange(instance, request, status)

    healthy()
    own_endpoint = endpoint("brokers")
    connect("brokers", own_endpoint.port, own_endpoint.password, "example.com", 403)
    connect("brokers", own_endpoint.port, own_endpoint.password, "api.github.com", 200)
    authenticated_probe("brokers", own_endpoint.port, own_endpoint.password, 200)
    pressure = Path(__file__).parent / "fixtures/credential-proxy/egress-pressure.py"
    run(["shell", "brokers", "--", "python3", "-", str(own_endpoint.port)],
        input=pressure.read_text(), contains="PASS pressure round 3", timeout=40)
    healthy()
    authenticated_probe("brokers", own_endpoint.port, own_endpoint.password, 200)
    print("PASS guest socket pressure releases all slots and authenticated readiness recovers", flush=True)
    peer_project = binary.parent / "peer-project"
    peer_project.mkdir()
    run(["up", str(peer_project), "--name", "egress-peer", "--no-github", "--no-devcontainer"])
    peer_endpoint = endpoint("egress-peer")
    assert peer_endpoint.password != own_endpoint.password, "VMs share an egress capability"
    connect("egress-peer", peer_endpoint.port, peer_endpoint.password, "api.github.com", 200)
    connect("egress-peer", peer_endpoint.port, own_endpoint.password, "api.github.com", 403)
    connect("brokers", own_endpoint.port, peer_endpoint.password, "api.github.com", 403)
    authenticated_probe("egress-peer", peer_endpoint.port, peer_endpoint.password, 200)
    authenticated_probe("egress-peer", peer_endpoint.port, own_endpoint.password, 403)
    authenticated_probe("brokers", own_endpoint.port, peer_endpoint.password, 403)
    peer_state = state.parent / "egress-peer"
    peer_pid = owned_pid(peer_state / "proxy-egress.pid", str(binary / "iso-egress"))
    peer_tunnel = owned_pid(peer_state / "proxy-egress-fwd.pid", "/usr/bin/ssh")
    run(["destroy", "egress-peer"])
    exited(peer_pid)
    exited(peer_tunnel)
    assert not peer_state.exists(), "destroy retained peer authority state"
    print("PASS foreign-VM capabilities fail CONNECT/readiness authentication; own tokens establish approved tunnels", flush=True)
    with paused(state / "proxy-egress-fwd.pid", "/usr/bin/ssh"):
        refused()
    healthy()
    print("PASS paused egress tunnel refuses handoffs/status; resume restores proof", flush=True)

    try:
        key.write_bytes((state / "proxy-openai-readiness-public-key").read_bytes())
        refused()
        key.unlink()
        refused()
    finally:
        key.write_bytes(original_key)
        key.chmod(0o600)
    healthy()
    print("PASS wrong/missing egress verification keys fail closed; restoration recovers", flush=True)

    # Ten seconds exceeds the production two-second lease. Renewals queue while
    # the companion is stopped, but must never revive its expired grant.
    with paused(state / "proxy-egress.pid", str(binary / "iso-egress")) as pid:
        refused()
        time.sleep(10)
    exited(pid)
    refused()
    print("PASS paused egress companion expires permanently despite queued renewals", flush=True)

    run(["stop", "brokers"])
    assert not key.exists() and not capability.exists(), "stop retained egress authority"
    run(["start", "brokers", "--no-github"])
    assert key.read_bytes() != original_key, "restart reused egress signing identity"
    assert capability.read_bytes() != original_capability, "restart reused egress capability"
    healthy()
    restarted = endpoint("brokers")
    authenticated_probe("brokers", restarted.port, original_capability.decode("ascii"), 403)
    authenticated_probe("brokers", restarted.port, restarted.password, 200)
    connect("brokers", restarted.port, original_capability.decode("ascii"), "api.github.com", 403)
    connect("brokers", restarted.port, restarted.password, "api.github.com", 200)

    # Restoring the previous boot's capability in the host's private fixture
    # state must not authenticate to the new companion (including guest probe).
    current_capability = capability.read_bytes()
    try:
        capability.write_bytes(original_capability)
        refused()
    finally:
        capability.write_bytes(current_capability)
        capability.chmod(0o600)
    healthy()
    print("PASS stop removes authority; restart rotates it and rejects previous-boot capability", flush=True)

    companion_pid = owned_pid(state / "proxy-egress.pid", str(binary / "iso-egress"))
    supervisor_pid = owned_pid(state / "egress-lease.pid", str(binary / "iso"))
    os.kill(supervisor_pid, signal.SIGKILL)
    exited(companion_pid)
    refused()
    run(["stop", "brokers"])
    run(["start", "brokers", "--no-github"])
    healthy()
    print("PASS supervisor death closes the companion grant; explicit restart recovers", flush=True)

    # The lease supervises the companion and egress tunnel it has seen. Losing
    # the tunnel ends the lease, so the grant expires. (Closing port forwards
    # on exit is unit-tested: this fixture's data path is too long for an
    # ssh control socket.)
    lease_pid = owned_pid(state / "egress-lease.pid", str(binary / "iso"))
    companion_pid = owned_pid(state / "proxy-egress.pid", str(binary / "iso-egress"))
    os.kill(owned_pid(state / "proxy-egress-fwd.pid", "/usr/bin/ssh"), signal.SIGTERM)
    exited(lease_pid)
    exited(companion_pid)
    refused()
    run(["stop", "brokers"])
    run(["start", "brokers", "--no-github"])
    healthy()
    print("PASS a lost egress tunnel ends the lease and expires the companion grant", flush=True)
