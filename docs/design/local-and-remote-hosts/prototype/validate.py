#!/usr/bin/env python3
"""Run measured control/state experiments; no actual VM or remote SSH is used."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import time

from prototype import (Client, DEFAULT_TTL, Failure, LocalTransport, MAX_FRAME,
                       PROTOCOL, REMOTE_COMMAND, SESSION_LEASE, SSHTransport,
                       Store, canonical, decode, encode)


class Harness:
    def __init__(self, root):
        self.root, self.events, self.results = root, [], []
        self.sequence, self.checks, self.scenario = 0, 0, ""

    def trace(self, event):
        self.events.append({"scenario": self.scenario, **copy.deepcopy(event)})

    def check(self, condition, label):
        self.checks += 1
        if not condition:
            raise AssertionError(label)
        self.trace({"event": "assertion_pass", "label": label})

    def expect(self, code, fn):
        try:
            fn()
        except Failure as exc:
            self.check(exc.code == code, f"Expected {code}; observed {exc.code}")
            return exc
        raise AssertionError(f"Expected failure {code}")

    def host(self):
        self.sequence += 1
        root = self.root / f"PROTOTYPE-host-{self.sequence}"
        Store(root).initialize()
        client = Client(LocalTransport(root), trace=self.trace)
        client.connect()
        return client, root

    def vm(self, running=True):
        client, root = self.host()
        vm = client.call("vm.create", {"name": "project"})
        if running:
            vm = client.call("vm.start", {"ref": vm["ref"]})
        return client, root, vm

    def snapshot(self, root):
        with Store(root).transaction() as state:
            return copy.deepcopy(state)

    def session(self, client, ref):
        session = client.call("session.open", {"ref": ref, "client_key_fingerprint": "SHA256:fake-key-a"})
        params = {"ref": ref, "session_id": session["session_id"],
                  "client_key_fingerprint": "SHA256:fake-key-a"}
        return session, params

    def run(self, name, fn):
        self.scenario, self.checks = name, 0
        self.trace({"event": "scenario_start"})
        started = time.perf_counter()
        result = {"name": name}
        try:
            result.update(status="passed", details=fn())
        except Exception as exc:
            result.update(status="failed", error=f"{type(exc).__name__}: {exc}")
        result.update(checks=self.checks, duration_seconds=round(time.perf_counter() - started, 6))
        self.results.append(result)
        self.trace({"event": "scenario_finish", "result": result})
        print(f"{result['status'].upper():6} {name} ({self.checks} checks)")


def lifecycle(h):
    c, root, vm = h.vm(running=False)
    ref = vm["ref"]
    h.check(vm["state"] == "stopped", "Create produces stopped modeled VM")
    running = c.call("vm.start", {"ref": ref})
    h.check(running["state"] == "running" and running["deadline"] == DEFAULT_TTL,
            "Start computes deadline from worker model time")
    session, params = h.session(c, ref)
    Store(root).advance(5)
    renewed = c.call("session.renew", params)
    h.check(renewed["expires_at"] == 5 + SESSION_LEASE, "Renew extends current modeled lease")
    closed = c.call("session.close", params)
    h.check(not closed["active"], "Close invalidates modeled access")
    stopped = c.call("vm.stop", {"ref": ref})
    h.check(stopped["state"] == "stopped", "Stop is observed")
    destroyed = c.call("vm.destroy", {"ref": ref})
    h.check(destroyed["state"] == "destroyed", "Destroy leaves identity tombstone")
    h.check(c.call("vm.inspect", {"ref": ref})["state"] == "destroyed", "Fresh inspect reads tombstone")
    return {"runtime": "simulated", "deadline": running["deadline"], "final_state": "destroyed"}


def two_hosts(h):
    a, ar, av = h.vm()
    b, br, bv = h.vm()
    h.check(av["name"] == bv["name"] and av["guest_address"] == bv["guest_address"],
            "Same display name and modeled guest address coexist")
    h.check(a.host_id != b.host_id and av["ref"] != bv["ref"], "Qualified references are distinct")
    a.call("vm.destroy", {"ref": av["ref"]})
    h.check(b.call("vm.inspect", {"ref": bv["ref"]})["state"] == "running", "Destroy on one host does not affect the other")
    h.expect("NAME_CONFLICT", lambda: b.call("vm.create", {"name": "project"}))
    return {"host_ids": [a.host_id, b.host_id], "same_guest_address": av["guest_address"]}


def wrong_host(h):
    a, root, vm = h.vm()
    b, _ = h.host()
    before = h.snapshot(root)["vms"]
    bad_client = Client(LocalTransport(root), b.host_id, h.trace)
    h.expect("HOST_IDENTITY_CHANGED", lambda: bad_client.call("vm.stop", {"ref": vm["ref"]}))
    bad_ref = {**vm["ref"], "host_id": b.host_id}
    h.expect("HOST_IDENTITY_CHANGED", lambda: a.call("vm.stop", {"ref": bad_ref}))
    h.check(before == h.snapshot(root)["vms"], "Wrong envelope and reference host cannot mutate VM records")
    return {"vm_state_after_refusals": "running"}


def lost_reply(h):
    c, root = h.host()
    opid = "lost-create-reply"
    c.transport.drop_next_method = "vm.create"
    failure = h.expect("OPERATION_UNCERTAIN", lambda: c.call("vm.create", {"name": "project"}, opid))
    exit_code = getattr(failure.__cause__, "frontend_exit_code", None)
    h.check(exit_code == 70, "Observed the deliberate post-commit frontend exit code")
    committed = h.snapshot(root)
    h.check(len(committed["vms"]) == 1 and committed["operations"][opid]["state"] == "completed",
            "Instance and receipt committed before frontend exited without reply")
    retry = Client(LocalTransport(root), c.host_id, h.trace)
    retry.connect()
    receipt = retry.call("operation.get", {"operation_id": opid})
    vm = retry.call("vm.create", {"name": "project"}, opid)
    h.check(vm == receipt["outcome"]["result"], "Retry returns exact historical receipt")
    h.check(len(h.snapshot(root)["vms"]) == 1, "No duplicate modeled instance after retry")
    return {"operation_id": opid, "instances_after_retry": 1, "frontend_fault_exit_code": exit_code}


def payload_conflict(h):
    c, root = h.host()
    vm = c.call("vm.create", {"name": "original"}, "same-id")
    h.expect("OPERATION_CONFLICT", lambda: c.call("vm.create", {"name": "different"}, "same-id"))
    h.expect("OPERATION_CONFLICT", lambda: c.call("vm.start", {"ref": vm["ref"]}, "same-id"))
    h.check(len(h.snapshot(root)["vms"]) == 1, "Conflicting payload does not create a second instance")
    return {"conflicts_checked": ["params", "method_and_target"]}


def frontend_restart(h):
    c, root = h.host()
    vm = c.call("vm.create", {"name": "project"}, "restart-create")
    other = Client(LocalTransport(root), c.host_id, h.trace)
    other.connect()
    h.check(c.host_id == other.host_id, "New frontend preserves installation identity")
    h.check(other.call("operation.get", {"operation_id": "restart-create"})["state"] == "completed",
            "New frontend reads previous operation")
    h.check(other.call("vm.create", {"name": "project"}, "restart-create") == vm,
            "New frontend replays original result")
    for path in [root, root / "PROTOTYPE_ONLY", root / "state.json", root / "worker.lock"]:
        h.check(stat.S_IMODE(path.stat().st_mode) & 0o077 == 0, f"{path.name} is owner-only")
    return {"frontend_model": "A new child process serves every local request", "host_id": c.host_id}


def unreachable(h):
    c, root, vm = h.vm()
    c.listing(vm["ref"])
    before = canonical(h.snapshot(root))
    missing = h.root / "PROTOTYPE-does-not-exist"
    c.transport = LocalTransport(missing)
    event_start = len(h.events)
    result = c.listing(vm["ref"])
    methods = [e["request"]["method"] for e in h.events[event_start:] if e["event"] == "request"]
    h.check(result["state"] == "unknown" and result["reachability"] == "unreachable", "Transport failure maps to unknown")
    h.check(result["last_observed_at"] == 0, "Last successful observation remains explicitly cached")
    h.check(methods == ["vm.inspect"], "Listing never issues create or start on failure")
    h.check(canonical(h.snapshot(root)) == before and not missing.exists(), "Failure leaves existing state intact and creates no root")
    return {"listing": result, "methods_attempted": methods}


def changed_boot(h):
    c, root, vm = h.vm()
    _, params = h.session(c, vm["ref"])
    c.call("vm.stop", {"ref": vm["ref"]})
    replacement = c.call("vm.start", {"ref": vm["ref"]})
    h.check(replacement["boot_id"] != vm["boot_id"] and replacement["generation"] > vm["generation"],
            "Replacement boot has fresh identity and generation")
    h.expect("SESSION_INVALID", lambda: c.call("session.renew", params))
    h.check(not h.snapshot(root)["sessions"][params["session_id"]]["active"], "Old session remains invalid")
    return {"old_boot_id": vm["boot_id"], "new_boot_id": replacement["boot_id"]}


def wrong_key(h):
    c, root, vm = h.vm()
    _, params = h.session(c, vm["ref"])
    h.expect("SESSION_KEY_MISMATCH", lambda: c.call("session.renew", {**params, "client_key_fingerprint": "SHA256:fake-key-b"}))
    h.expect("SESSION_INVALID", lambda: c.call("session.renew", params))
    h.check(h.snapshot(root)["sessions"][params["session_id"]]["invalid_reason"] == "client_key_mismatch",
            "Wrong-key attempt durably invalidates modeled session")
    return {"keys_used": "Fake fingerprint strings only; no cryptographic verification"}


def lease_expiry(h):
    c, root, vm = h.vm()
    _, params = h.session(c, vm["ref"])
    Store(root).advance(SESSION_LEASE)
    h.check(h.snapshot(root)["sessions"][params["session_id"]]["active"], "Clock advance alone does not run a supervisor")
    h.expect("SESSION_INVALID", lambda: c.call("session.renew", params))
    state = h.snapshot(root)
    h.check(state["sessions"][params["session_id"]]["invalid_reason"] == "lease_expired", "Next request reconciles modeled lease expiry")
    h.check(c.call("vm.inspect", {"ref": vm["ref"]})["state"] == "running", "Access lease and VM lifetime are distinct")
    return {"model_seconds_advanced": SESSION_LEASE, "live_relay_revocation_tested": False}


def ttl_expiry(h):
    c, root, vm = h.vm(running=False)
    params = {"ref": vm["ref"], "ttl_seconds": 10}
    start = c.call("vm.start", params, "ttl-start")
    _, session_params = h.session(c, vm["ref"])
    Store(root).advance(10)
    h.check(h.snapshot(root)["vms"][vm["ref"]["instance_id"]]["state"] == "running", "No independent real timer is modeled")
    observed = c.call("vm.inspect", {"ref": vm["ref"]})
    h.check(observed["state"] == "stopped" and observed["stop_reason"] == "modeled_ttl_expired", "Next request reconciles modeled TTL")
    h.check(c.call("vm.start", params, "ttl-start") == start, "Duplicate start returns original historical receipt")
    fresh = c.call("vm.inspect", {"ref": vm["ref"]})
    h.check(fresh["state"] == "stopped" and fresh["deadline"] == 10, "Retry neither restarts VM nor extends accepted deadline")
    h.expect("SESSION_INVALID", lambda: c.call("session.renew", session_params))
    return {"model_seconds_advanced": 10, "deadline_after_retry": fresh["deadline"], "physical_ttl_tested": False}


def delayed_retry(h):
    c, root = h.host()
    created = c.call("vm.create", {"name": "project"}, "original-create")
    c.call("vm.destroy", {"ref": created["ref"]})
    replacement = c.call("vm.create", {"name": "project"}, "replacement-create")
    retry = c.call("vm.create", {"name": "project"}, "original-create")
    h.check(retry == created, "Delayed create retry returns historical receipt")
    h.check(retry["ref"] != replacement["ref"], "Name reuse never reuses instance identity")
    h.check(c.call("vm.inspect", {"ref": retry["ref"]})["state"] == "destroyed", "Fresh inspect of old receipt confirms tombstone")
    h.check(len(h.snapshot(root)["vms"]) == 2, "Delayed retry does not recreate a destroyed instance")
    return {"historical_receipt_state": retry["state"], "fresh_state": "destroyed", "total_records": 2}


def malformed_inputs(h):
    _, root = h.host()
    valid = {"protocol": PROTOCOL, "request_id": "wire", "method": "hello", "params": {}}
    fixtures = [("duplicate_key", b'{"protocol":"x","protocol":"y"}\n', "MALFORMED_FRAME"),
                ("malformed_json", b'{bad}\n', "MALFORMED_FRAME"),
                ("malformed_utf8", b'{"x":"\xff"}\n', "MALFORMED_FRAME"),
                ("missing_newline", canonical(valid), "MALFORMED_FRAME"),
                ("oversized", b"x" * MAX_FRAME + b"\n", "FRAME_TOO_LARGE"),
                ("unknown_envelope_key", encode({**valid, "surprise": True}), "INVALID_REQUEST"),
                ("protocol_mismatch", encode({**valid, "protocol": "other/v1"}), "HOST_PROTOCOL_INCOMPATIBLE")]
    for value in ("NaN", "Infinity", "-Infinity", "1e9999"):
        fixtures.append(("nonfinite_" + value, ('{"x":' + value + '}\n').encode(), "MALFORMED_FRAME"))
    for name, raw, expected in fixtures:
        completed = subprocess.run([sys.executable, str(Path(__file__).with_name("prototype.py")),
                                    "worker", "--root", str(root)], input=raw, capture_output=True, timeout=5)
        response = decode(completed.stdout)
        h.check(completed.returncode == 0 and not response["ok"] and response["error"]["code"] == expected,
                f"Worker rejects {name} with {expected}")
    h.check(not h.snapshot(root)["vms"], "Rejected frames create no modeled instances")
    return {"fixtures": [f[0] for f in fixtures], "max_frame_bytes_including_newline": MAX_FRAME}


class FixtureTransport:
    def __init__(self, mutate):
        self.mutate = mutate

    def exchange(self, frame):
        request = decode(frame)
        response = {"protocol": PROTOCOL, "request_id": request["request_id"], "host_id": "fixture-host",
                    "ok": True, "result": {"protocol": PROTOCOL, "runtime": "simulated"}}
        return self.mutate(response)


def client_validation(h):
    fixtures = [("envelope_protocol", "HOST_PROTOCOL_INCOMPATIBLE", lambda r: encode({**r, "protocol": "other/v1"})),
                ("advertised_protocol", "HOST_PROTOCOL_INCOMPATIBLE", lambda r: encode({**r, "result": {"protocol": "other/v1", "runtime": "simulated"}})),
                ("unexpected_request_id", "INVALID_RESPONSE", lambda r: encode({**r, "request_id": "different"})),
                ("unknown_response_key", "INVALID_REQUEST", lambda r: encode({**r, "extra": 1})),
                ("oversized_response", "FRAME_TOO_LARGE", lambda r: b"x" * (MAX_FRAME + 1)),
                ("duplicate_response_key", "MALFORMED_FRAME", lambda r: b'{"ok":true,"ok":false}\n')]
    for name, code, fixture in fixtures:
        c = Client(FixtureTransport(fixture), trace=h.trace)
        h.expect(code, c.connect)
        h.check(c.host_id is None, f"{name} is not enrolled")
    c = Client(FixtureTransport(encode), "previously-pinned-host", h.trace)
    h.expect("HOST_IDENTITY_CHANGED", c.connect)
    return {"rejected_response_fixtures": [f[0] for f in fixtures], "changed_application_host_identity_rejected": True}


def concurrent_retries(h):
    c, root = h.host()
    def attempt(_):
        return Client(LocalTransport(root), c.host_id, h.trace).call("vm.create", {"name": "project"}, "concurrent-create")
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(attempt, range(2)))
    h.check(results[0] == results[1], "Concurrent same-operation requests share one receipt")
    h.check(len(h.snapshot(root)["vms"]) == 1, "Host file lock prevents duplicate state commits")
    return {"concurrent_frontends": 2, "instances": 1, "expected_generation_cas_tested": False}


def changed_policy(h):
    c, root, vm = h.vm()
    _, params = h.session(c, vm["ref"])
    with Store(root).transaction() as state:
        state["vms"][vm["ref"]["instance_id"]]["policy_hash"] = "simulated-policy-v2"
    h.expect("SESSION_INVALID", lambda: c.call("session.renew", params))
    h.check(h.snapshot(root)["sessions"][params["session_id"]]["invalid_reason"] == "binding_changed",
            "Policy mismatch refuses modeled session renewal")
    return {"fault": "Test-only local state fixture; no policy mutation wire method"}


def ssh_construction(h):
    pins = h.root / "simulated-known-hosts"
    pins.write_text("# fixture only; no actual SSH key is used\n")
    transport = SSHTransport("prepared-mac", pins)
    h.check(transport.command[-2:] == ["prepared-mac", REMOTE_COMMAND], "SSH remote command is a fixed constant")
    for option in ("StrictHostKeyChecking=yes", "ForwardAgent=no", "ClearAllForwardings=yes", "BatchMode=yes", "ControlPath=none"):
        h.check(option in transport.command, f"SSH argv sets {option}")
    h.expect("INVALID_SSH_TARGET", lambda: SSHTransport("host;touch-danger", pins))
    h.expect("INVALID_SSH_PINS", lambda: SSHTransport("prepared-mac", h.root / "missing-pins"))
    return {"ssh_process_executed": False, "host_key_verification_tested": False, "checks": "Argument construction only"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("evidence.json"))
    parser.add_argument("--trace", type=Path, default=Path(__file__).with_name("validation-trace.jsonl"))
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="PROTOTYPE-validation-", dir=Path.cwd()))
    h = Harness(root)
    started = time.perf_counter()
    scenarios = [("happy_lifecycle", lifecycle), ("same_name_two_hosts", two_hosts),
                 ("wrong_host_rejected", wrong_host), ("lost_committed_create_reply", lost_reply),
                 ("operation_payload_conflict", payload_conflict), ("frontend_restart_persists_identity", frontend_restart),
                 ("unreachable_maps_to_unknown", unreachable), ("changed_boot_invalidates_session", changed_boot),
                 ("wrong_session_key_rejected", wrong_key), ("modeled_lease_expiration", lease_expiry),
                 ("modeled_ttl_expiration", ttl_expiry), ("delayed_create_retry_after_destroy", delayed_retry),
                 ("strict_worker_protocol_inputs", malformed_inputs), ("strict_client_protocol_responses", client_validation),
                 ("concurrent_operation_retry", concurrent_retries), ("changed_policy_invalidates_session", changed_policy),
                 ("ssh_argument_construction_only", ssh_construction)]
    try:
        for name, fn in scenarios:
            h.run(name, lambda fn=fn: fn(h))
        evidence = {"format": "iso.host.prototype.evidence/v0", "protocol": PROTOCOL,
                    "generated_at": datetime.now(timezone.utc).isoformat(), "runtime": "simulated",
                    "environment": {"python": platform.python_version(), "os": platform.system(), "machine": platform.machine()},
                    "passed": all(r["status"] == "passed" for r in h.results),
                    "scenarios_passed": sum(r["status"] == "passed" for r in h.results),
                    "scenarios_total": len(h.results), "assertions_passed": sum(r["checks"] for r in h.results if r["status"] == "passed"),
                    "duration_seconds": round(time.perf_counter() - started, 6), "scenarios": h.results,
                    "limits": ["No real VM, Apple runtime, image, native isolation, broker, guest, editor, or file transfer",
                               "No actual SSH connection or cryptographic host/guest key verification",
                               "Explicit model time only; no live TTL timer, persistent supervisor, or relay revocation",
                               "No daemon epoch invalidation or expected-generation compare-and-swap",
                               "Fingerprint-only modeled sessions persist receipts; production secret session grants must not use this ledger",
                               "Atomic JSON side effects only; no crash recovery across an external VM side effect",
                               "Fixed prototype owner namespace; no production authorization validation"]}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.trace.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, indent=2) + "\n")
        args.trace.write_text("".join(json.dumps(e, sort_keys=True) + "\n" for e in h.events))
        print(f"{evidence['scenarios_passed']}/{len(h.results)} scenarios passed; {evidence['assertions_passed']} assertions passed.")
        print("Evidence:", args.output.resolve())
        print("Trace:", args.trace.resolve())
        return 0 if evidence["passed"] else 1
    finally:
        if args.keep:
            print("Retained explicitly simulated state:", root)
        else:
            shutil.rmtree(root)


if __name__ == "__main__":
    raise SystemExit(main())
