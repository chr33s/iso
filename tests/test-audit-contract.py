#!/usr/bin/env python3
"""`iso audit` run history against a hand-written `iso.audit/v1` store.

Run with --swift .build/debug/iso. Drives the real binary over real pipes:
JSONL lines parse independently and reach a pipe promptly, a follower emits
only for advanced snapshots, a stalled viewer holds no store lock, a closed
pipe ends the viewer instead of hanging it, hostile stored records are
reported or neutralized, and other commands refuse `--output jsonl`.
"""

import argparse
import fcntl
import json
import os
import secrets
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCHEMA = "iso.audit.stream/v1"


def hexid(prefix=""):
    return prefix + secrets.token_hex(16)


class Store:
    """A store laid out as AuditStore writes it, appended to like a writer."""

    def __init__(self, data):
        self.root = data / "backends" / "apple-container-v1" / "audit" / "v1"
        self.root.mkdir(parents=True)
        for path in [self.root, self.root.parent]:
            os.chmod(path, 0o700)
        self.journal = hexid("journal_")
        (self.root / "journal.json").write_text(
            json.dumps({"schema": "iso.audit/v1", "journal_id": self.journal, "created_at": "2026-10-18T09:00:00Z"}))
        self.segment = self.root / ("seg-%020d.jsonl" % 1)
        self.sequence = 0

    def raw(self, text):
        # One write per record, as the writer does.
        fd = os.open(self.segment, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, text.encode())
        finally:
            os.close(fd)

    def event(self, kind, evidence, subject, data, recorded_at=None):
        self.sequence += 1
        event = {
            "event_id": hexid("evt_"), "journal_id": self.journal, "sequence": self.sequence,
            "recorded_at": recorded_at or "2026-10-18T09:%02d:%02dZ" % divmod(self.sequence % 3600, 60),
            "kind": kind, "producer": "iso", "evidence": evidence, "subject": subject, "data": data,
        }
        self.raw(json.dumps(event, separators=(",", ":")) + "\n")
        return event


def run(binary, home, config, *args, timeout=60):
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "NO_COLOR": "1"}
    return subprocess.run([binary, "--config", str(config), *args], capture_output=True, env=env,
                          timeout=timeout, stdin=subprocess.DEVNULL)


def lines(raw):
    if raw and not raw.endswith(b"\n"):
        raise AssertionError(f"unterminated stream: {raw[-80:]!r}")
    records = []
    for line in raw.split(b"\n")[:-1]:
        if not line or len(line) + 1 > 64 << 10:
            raise AssertionError(f"bad line length {len(line)}")
        record = json.loads(line)
        if record.get("schema") != SCHEMA or "type" not in record:
            raise AssertionError(f"not a stream record: {record}")
        records.append(record)
    return records


class Viewer:
    """A live `--follow --output jsonl` process read through a real pipe."""

    def __init__(self, binary, home, config, run_id, *extra):
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "NO_COLOR": "1"}
        self.process = subprocess.Popen(
            [binary, "--config", str(config), "audit", "--run", run_id, "--follow", "--output", "jsonl", *extra],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, env=env)
        self.buffer = b""

    def until_progress(self, count=1, timeout=15):
        """Records up to the `count`th exhausted progress record."""
        records, seen = [], 0
        deadline = time.monotonic() + timeout
        while seen < count:
            while b"\n" in self.buffer and seen < count:
                line, self.buffer = self.buffer.split(b"\n", 1)
                record = lines(line + b"\n")[0]
                records.append(record)
                if record["type"] == "progress" and record["snapshot_exhausted"]:
                    seen += 1
            if seen >= count:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0 or self.process.poll() is not None:
                raise AssertionError(f"no progress record within {timeout}s: {records}")
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            if ready:
                self.buffer += os.read(self.process.stdout.fileno(), 1 << 16)
        return records

    def quiet(self, seconds=1.5):
        ready, _, _ = select.select([self.process.stdout], [], [], seconds)
        return not ready

    def stop(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=10)


def store_unlocked(store):
    """A writer could take the store lock right now."""
    fd = os.open(store.root / ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return True
    except BlockingIOError:
        return False
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--swift", required=True)
    binary = os.path.abspath(parser.parse_args().swift)
    failures = []

    def check(label, condition, detail=""):
        print(("PASS " if condition else "FAIL ") + label + ("" if condition else f": {detail}"))
        if not condition:
            failures.append(label)

    with tempfile.TemporaryDirectory(prefix="iso-audit-contract-") as scratch:
        home = Path(scratch)
        data = home / "data"
        config = home / "config.jsonc"
        config.write_text(json.dumps({"data_dir": str(data)}))
        store = Store(data)
        run_id, other = hexid("run_"), hexid("run_")
        vm, boot = secrets.token_hex(16), secrets.token_hex(16)
        request = {"command": "run", "role": "managed", "lifecycle": "persistent", "requested_agent": "claude",
                   "requested_instance": None, "permission_mode": "bypass", "iso_version": "iso test"}
        environment = {
            "action": "attached", "instance_name": "my-project", "vm_id": vm, "boot_id": boot,
            "image": "default", "guest_os": "linux", "workspace": "copy", "egress": None, "policy": None,
            "proxied_providers": [], "requested": {"egress": "open", "proxy_mode": "auto", "session_ttl_seconds": None},
            "agent": None, "disposable_session_id": None,
        }
        vm_subject = {"type": "vm", "vm_id": vm, "boot_id": boot}
        store.event("invocation.requested", "host_request", {"type": "invocation", "audit_run_id": run_id}, request)
        store.event("invocation.environment", "host_observation",
                    {"type": "invocation", "audit_run_id": run_id}, environment)
        store.event("invocation.requested", "host_request", {"type": "invocation", "audit_run_id": other}, request)
        # Hostile records: control characters, an unknown kind, garbage and a
        # non-object payload. None may reach a terminal raw or be trusted.
        store.event("boundary.stop", "host_observation", vm_subject,
                    {"instance_name": "evil\u001b[2J\nINJECTED", "k\u001b[31m": "v"},
                    recorded_at="2026-10-18T09:00:04Z\u001b[31m")
        store.sequence += 1
        store.raw(json.dumps({"event_id": hexid("evt_"), "journal_id": store.journal, "sequence": store.sequence,
                              "recorded_at": "x", "kind": "guest.claims_success", "producer": "guest",
                              "evidence": "host_observation", "subject": vm_subject, "data": {}}) + "\n")
        store.raw("{not json\n")
        store.event("boundary.stop", "host_observation", vm_subject, [])

        result = run(binary, home, config, "audit", "--run", run_id, "--output", "jsonl")
        records = lines(result.stdout)
        check("finite JSONL exits 0", result.returncode == 0, result.stderr)
        check("finite JSONL is state, events, progress",
              [r["type"] for r in records] == ["state", "event", "event", "event", "progress"],
              [r["type"] for r in records])
        check("another run's invocation events never join",
              all(r["event"]["subject"].get("audit_run_id") in (None, run_id) for r in records if r["type"] == "event"))
        check("hostile control characters stay escaped in JSONL", b"\x1b" not in result.stdout)
        gaps = records[0]["coverage"]["gaps"]
        check("unparseable stored records are reported as gaps",
              sum(g["reason"] == "unparseable_record" for g in gaps) == 3, gaps)
        check("the page is exhausted with a null cursor",
              records[-1]["snapshot_exhausted"] is True and records[-1]["cursor"] is None)

        text = run(binary, home, config, "audit", "--run", run_id)
        check("text output never carries raw control characters", b"\x1b" not in text.stdout)
        check("a stored newline cannot forge a text line",
              not any(line.startswith(b"INJECTED") for line in text.stdout.split(b"\n")))
        check("text shows no invented outcome", b"no terminal outcome recorded" in text.stdout)
        hostile = hexid("run_")
        store.event("invocation.requested", "host_request", {"type": "invocation", "audit_run_id": hostile}, request,
                    recorded_at="2026-10-18T10:00:00Z\u001b[31m")
        store.event("launch.transport_ended", "host_observation", {"type": "invocation", "audit_run_id": hostile},
                    {"transport": "ssh\u001b[31m", "termination": {"kind": "weird\u001b[31m", "status": None, "signal": None}})
        for args in (["--run", hostile], ["--runs"]):
            shown = run(binary, home, config, "audit", *args)
            check(f"stored times, kinds and keys never reach a terminal raw ({args[0]})",
                  shown.returncode == 0 and b"\x1b" not in shown.stdout, shown.stdout)

        document = json.loads(run(binary, home, config, "audit", "--run", run_id, "--output", "json").stdout)
        check("JSON and JSONL select the same events",
              [e["event"]["event_id"] for e in document["result"]["events"]]
              == [r["event"]["event_id"] for r in records if r["type"] == "event"])

        refused = run(binary, home, config, "list", "--output", "jsonl")
        check("other commands refuse --output jsonl", refused.returncode == 2 and refused.stdout == b"", refused)

        # Live following through a pipe.
        viewer = Viewer(binary, home, config, run_id)
        try:
            first = viewer.until_progress()
            check("follow flushes its first batch to a pipe while running",
                  viewer.process.poll() is None and first[0]["type"] == "state" and first[0]["mode"] == "follow")
            check("an idle follower emits nothing", viewer.quiet())
            check("a following viewer holds no store lock", store_unlocked(store))
            store.event("boundary.pull_direct", "host_observation", vm_subject, {"instance_name": "my-project"})
            batch = viewer.until_progress()
            check("a related record arrives as state, event, progress",
                  [r["type"] for r in batch] == ["state", "event", "progress"], batch)
            store.event("boundary.stop", "host_observation",
                        {"type": "vm", "vm_id": secrets.token_hex(16), "boot_id": None}, {"instance_name": "x"})
            batch = viewer.until_progress()
            check("an unrelated record still advances the snapshot",
                  [r["type"] for r in batch] == ["state", "progress"]
                  and batch[-1]["as_of"]["sequence"] == store.sequence, batch)
            store.event("launch.transport_ended", "host_observation", {"type": "invocation", "audit_run_id": run_id},
                        {"transport": "ssh", "termination": {"kind": "exited", "status": 0, "signal": None}})
            batch = viewer.until_progress()
            check("follow continues past the transport's end",
                  viewer.process.poll() is None and batch[0]["run"]["outcome"]["kind"] == "transport_ended")
            cursor = batch[-1]["cursor"]

            # A stalled consumer: fill the pipe and stop reading.
            for _ in range(400):
                store.event("boundary.stop", "host_observation", vm_subject, {"instance_name": "my-project"})
            time.sleep(2)
            check("a viewer blocked on a full pipe holds no store lock", store_unlocked(store))
            delivered = viewer.until_progress(timeout=30)
            while not (delivered[-1]["type"] == "progress" and delivered[-1]["as_of"]["sequence"] == store.sequence):
                delivered += viewer.until_progress(timeout=30)
            ids = [r["event"]["event_id"] for r in delivered if r["type"] == "event"]
            check("a slow consumer still receives every record once", len(ids) == 400 and len(set(ids)) == 400,
                  len(ids))

            # A closed pipe ends the viewer rather than hanging it.
            viewer.process.stdout.close()
            store.event("boundary.stop", "host_observation", vm_subject, {"instance_name": "my-project"})
            try:
                code = viewer.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                code = None
            check("a broken pipe stops the viewer with a failure status", code not in (None, 0), code)
        finally:
            viewer.stop()

        # Resuming from the last committed cursor replays only later records.
        resume = Viewer(binary, home, config, run_id, "--after", cursor)
        try:
            replay = resume.until_progress()
            replayed = [r for r in replay if r["type"] == "event"]
            check("a rolling cursor resumes after its snapshot",
                  replay[0]["type"] == "state" and len(replayed) == 401, len(replayed))
        finally:
            resume.stop()

        # A finite reader whose pipe is closed early exits instead of hanging.
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "NO_COLOR": "1"}
        process = subprocess.Popen([binary, "--config", str(config), "audit", "--run", run_id, "--output", "jsonl",
                                    "--limit", "1000"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, env=env)
        process.stdout.read(10)
        process.stdout.close()
        try:
            code = process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            code = None
        check("a closed pipe ends a finite reader with a failure status", code not in (None, 0), code)

        # The instance view is unchanged: the legacy log, verbatim but
        # neutralized, its stderr note, and the advisory fragment.
        instance = data / "backends" / "apple-container-v1" / "instances" / "legacy"
        instance.mkdir(parents=True)
        (instance / "instance.json").write_text(json.dumps({"name": "legacy", "index": 3, "image": "default"}))
        legacy = [
            '{"time":"2026-10-18T09:00:00Z","event":"boot","egress":"none","proxy_mode":"required","proxied":["anthropic"],"provider_secrets":[],"guest_references":0,"session_ttl_seconds":null}',
            '{"time":"2026-10-18T09:05:00Z","event":"pull_stage","changes":2,"staged_bytes":9,"applicable":true}',
        ]
        (instance / "audit.jsonl").write_text("\n".join(legacy) + "\n")
        shown = run(binary, home, config, "audit", "legacy")
        check("the instance view prints the legacy log verbatim",
              shown.returncode == 0 and shown.stdout.decode().splitlines() == legacy, shown)
        suggested = run(binary, home, config, "audit", "legacy", "--suggest-config")
        check("--suggest-config is unchanged", b'"proxy": { "mode": "required" }' in suggested.stdout
              and b'"egress": "none"' in suggested.stdout, suggested.stdout)
        (instance / "audit.jsonl").unlink()
        empty = run(binary, home, config, "audit", "legacy")
        check("an empty instance view notes it on stderr only",
              empty.returncode == 0 and empty.stdout == b"" and b"No boundary events" in empty.stderr)
        check("the instance view stays text",
              run(binary, home, config, "audit", "legacy", "--output", "json").returncode != 0)

        export = home / "run.json"
        export.write_text("keep")
        refused = run(binary, home, config, "audit", "--run", run_id, "--export", str(export))
        check("export refuses an existing file", refused.returncode != 0 and export.read_text() == "keep")

    print(f"{len(failures)} failures")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
