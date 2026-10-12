#!/usr/bin/env python3
"""Throwaway host-control experiment. ALL runtime operations are SIMULATED."""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager

PROTOCOL = "iso.host.prototype/v0"
MAX_FRAME = 65536  # Includes the terminating newline, in each direction.
DEFAULT_TTL, SESSION_LEASE, MAX_TTL = 60, 15, 86400
MARKER = "SIMULATED ISO HOST PROTOTYPE ONLY\n"
OWNER = "prototype-owner"
MUTATIONS = {"vm.create", "vm.start", "vm.stop", "vm.destroy",
             "session.open", "session.renew", "session.close"}
METHODS = MUTATIONS | {"hello", "vm.inspect", "operation.get"}
REMOTE_COMMAND = ("python3 .local/lib/iso-host-prototype/prototype.py worker "
                  "--root .local/state/iso-host-prototype/PROTOTYPE-worker")
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")


class Failure(Exception):
    def __init__(self, code: str, message: str):
        self.code, self.message = code, message
        super().__init__(f"{code}: {message}")


def require(condition, code="INVALID_REQUEST", message="Invalid request"):
    if not condition:
        raise Failure(code, message)


def identifier(value):
    require(isinstance(value, str) and bool(IDENTIFIER.fullmatch(value)))
    return value


def number(value, maximum):
    require(type(value) in (int, float) and 0 < value <= maximum
            and math.isfinite(value))
    return value


def fields(value, required, optional=()):
    require(isinstance(value, dict) and set(required) <= value.keys()
            and value.keys() <= set(required) | set(optional))


def canonical(value):
    return json.dumps(value, allow_nan=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def encode(value):
    data = canonical(value) + b"\n"
    require(len(data) <= MAX_FRAME, "FRAME_TOO_LARGE", "Frame exceeds 64 KiB")
    return data


def decode(data):
    require(len(data) <= MAX_FRAME, "FRAME_TOO_LARGE", "Frame exceeds 64 KiB")
    require(data.endswith(b"\n") and b"\n" not in data[:-1],
            "MALFORMED_FRAME", "Expected one newline-terminated JSON frame")

    def unique(pairs):
        obj = {}
        for key, value in pairs:
            require(key not in obj, "MALFORMED_FRAME", "Duplicate JSON key")
            obj[key] = value
        return obj

    def constant(_):
        raise Failure("MALFORMED_FRAME", "Non-finite JSON number")

    def finite_float(raw):
        value = float(raw)
        require(math.isfinite(value), "MALFORMED_FRAME", "Non-finite JSON number")
        return value

    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique,
                           parse_constant=constant, parse_float=finite_float)
        require(isinstance(value, dict), "MALFORMED_FRAME", "Expected an object")
        return value
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise Failure("MALFORMED_FRAME", "Invalid UTF-8 or JSON") from exc


def atomic_json(root, value):
    fd, name = tempfile.mkstemp(prefix=".state-", dir=root)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, root / "state.json")
        directory = os.open(root, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def private_file(path, create=False):
    flags = os.O_RDWR | os.O_NOFOLLOW | (os.O_CREAT if create else 0)
    fd = os.open(path, flags, 0o600)
    info = os.fstat(fd)
    if not (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and info.st_mode & 0o077 == 0):
        os.close(fd)
        raise Failure("STATE_UNSAFE", "Prototype files must be owner-only regular files")
    return fd


class Store:
    def __init__(self, root):
        self.root = Path(root).absolute()

    def check(self):
        info = self.root.lstat()  # No implicit creation on inspection/reconnect.
        require(self.root.name.startswith("PROTOTYPE-"), "STATE_UNSAFE",
                "Worker directory must start with PROTOTYPE-")
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                and info.st_mode & 0o077 == 0, "STATE_UNSAFE",
                "Prototype root must be an owner-only directory, not a symlink")
        with os.fdopen(private_file(self.root / "PROTOTYPE_ONLY"), "r") as stream:
            require(stream.read(256) == MARKER, "STATE_UNSAFE", "Missing prototype marker")

    def initialize(self):
        require(self.root.name.startswith("PROTOTYPE-"), "STATE_UNSAFE",
                "Worker directory must start with PROTOTYPE-")
        self.root.mkdir(mode=0o700)  # Existing directories are deliberately refused.
        fd = os.open(self.root / "PROTOTYPE_ONLY", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(MARKER)
        state = {"format": PROTOCOL, "runtime": "simulated", "owner_id": OWNER,
                 "host_id": str(uuid.uuid4()), "now": 0, "vms": {},
                 "operations": {}, "sessions": {}}
        atomic_json(self.root, state)
        return state["host_id"]

    @contextmanager
    def transaction(self):
        self.check()
        with os.fdopen(private_file(self.root / "worker.lock", create=True), "r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with os.fdopen(private_file(self.root / "state.json"), "r") as stream:
                state = json.load(stream)
            require(state.get("format") == PROTOCOL and state.get("runtime") == "simulated",
                    "STATE_UNSAFE", "Unsupported prototype state")
            before = canonical(state)
            yield state
            if canonical(state) != before:
                atomic_json(self.root, state)

    def advance(self, seconds):
        number(seconds, MAX_TTL * 2)
        with self.transaction() as state:
            state["now"] += seconds
            return state["now"]  # Expiry reconciles on the NEXT protocol request.


def invalidate(state, instance_id, reason):
    for session in state["sessions"].values():
        if session["ref"]["instance_id"] == instance_id and session["active"]:
            session.update(active=False, invalid_reason=reason)


def reconcile(state):
    for vm in state["vms"].values():
        if vm["state"] == "running" and state["now"] >= vm["deadline"]:
            vm.update(state="stopped", stop_reason="modeled_ttl_expired",
                      generation=vm["generation"] + 1)
            invalidate(state, vm["ref"]["instance_id"], "ttl_expired")
    for session in state["sessions"].values():
        if session["active"] and state["now"] >= session["expires_at"]:
            session.update(active=False, invalid_reason="lease_expired")


def vm_for(state, ref):
    fields(ref, {"host_id", "instance_id"})
    identifier(ref["host_id"])
    identifier(ref["instance_id"])
    require(ref["host_id"] == state["host_id"], "HOST_IDENTITY_CHANGED", "Wrong reference host")
    vm = state["vms"].get(ref["instance_id"])
    require(vm is not None, "INSTANCE_NOT_FOUND", "Unknown instance identity")
    return vm


def observation(state, vm):
    return {**copy.deepcopy(vm), "observed_at": state["now"], "runtime": "simulated"}


def execute(state, method, params):
    if method == "hello":
        fields(params, set())
        return {"protocol": PROTOCOL, "runtime": "simulated", "owner_id": OWNER,
                "methods": sorted(METHODS), "model_time": state["now"]}
    if method == "operation.get":
        fields(params, {"operation_id"})
        operation = state["operations"].get(identifier(params["operation_id"]))
        require(operation is not None, "OPERATION_NOT_FOUND", "Unknown operation")
        return {"operation_id": params["operation_id"], **copy.deepcopy(operation)}
    if method == "vm.create":
        fields(params, {"name"}, {"policy_hash"})
        name = identifier(params["name"])
        policy = identifier(params.get("policy_hash", "simulated-policy-v1"))
        require(len(state["vms"]) < 128, "LIMIT_REACHED", "Prototype instance limit")
        require(not any(v["name"] == name and v["state"] != "destroyed"
                        for v in state["vms"].values()), "NAME_CONFLICT", "Name already exists on this host")
        instance_id = str(uuid.uuid4())
        vm = {"ref": {"host_id": state["host_id"], "instance_id": instance_id},
              "name": name, "state": "stopped", "generation": 0, "boot_id": None,
              "policy_hash": policy, "deadline": None, "stop_reason": None,
              "guest_address": "192.0.2.10"}
        state["vms"][instance_id] = vm
        return observation(state, vm)

    required = {"ref"}
    optional = {"ttl_seconds"} if method == "vm.start" else set()
    if method.startswith("session."):
        required |= {"client_key_fingerprint"}
        if method != "session.open":
            required |= {"session_id"}
    fields(params, required, optional)
    vm = vm_for(state, params["ref"])
    if method == "vm.inspect":
        return observation(state, vm)
    if method.startswith("session."):
        fingerprint = identifier(params["client_key_fingerprint"])
        if method == "session.open":
            require(vm["state"] == "running", "VM_NOT_RUNNING", "A running modeled VM is required")
            require(len(state["sessions"]) < 256, "LIMIT_REACHED", "Prototype session limit")
            session = {"session_id": str(uuid.uuid4()), "ref": copy.deepcopy(vm["ref"]),
                       "client_key_fingerprint": fingerprint, "active": True,
                       "invalid_reason": None, "boot_id": vm["boot_id"],
                       "policy_hash": vm["policy_hash"], "generation": vm["generation"],
                       "expires_at": min(state["now"] + SESSION_LEASE, vm["deadline"])}
            state["sessions"][session["session_id"]] = session
        else:
            session = state["sessions"].get(identifier(params["session_id"]))
            require(session is not None, "SESSION_NOT_FOUND", "Unknown session")
            require(session["ref"] == params["ref"], "SESSION_TARGET_MISMATCH", "Wrong session target")
            if session["client_key_fingerprint"] != fingerprint:
                session.update(active=False, invalid_reason="client_key_mismatch")
                raise Failure("SESSION_KEY_MISMATCH", "Session key does not match")
            current = vm["state"] == "running" and all(
                session[key] == vm[key] for key in ("boot_id", "policy_hash", "generation"))
            if not current:
                session.update(active=False, invalid_reason=session["invalid_reason"] or "binding_changed")
            require(session["active"], "SESSION_INVALID", "Session is expired, revoked, or bound to an old boot/policy")
            if method == "session.close":
                session.update(active=False, invalid_reason="closed")
            else:
                session["expires_at"] = min(state["now"] + SESSION_LEASE, vm["deadline"])
        return copy.deepcopy(session)

    require(vm["state"] != "destroyed", "INSTANCE_DESTROYED", "Instance identity is a tombstone")
    if method == "vm.start":
        ttl = number(params.get("ttl_seconds", DEFAULT_TTL), MAX_TTL)
        require(vm["state"] == "stopped", "VM_NOT_STOPPED", "VM is already running")
        invalidate(state, vm["ref"]["instance_id"], "boot_changed")
        vm.update(state="running", generation=vm["generation"] + 1,
                  boot_id=str(uuid.uuid4()), deadline=state["now"] + ttl, stop_reason=None)
    elif method in {"vm.stop", "vm.destroy"}:
        vm.update(state="destroyed" if method == "vm.destroy" else "stopped",
                  generation=vm["generation"] + 1, stop_reason=method)
        invalidate(state, vm["ref"]["instance_id"], method)
    return observation(state, vm)


def handle(store, request):
    fields(request, {"protocol", "request_id", "method", "params"}, {"host_id", "operation_id"})
    identifier(request["request_id"])
    require(request["protocol"] == PROTOCOL, "HOST_PROTOCOL_INCOMPATIBLE", "Unsupported protocol")
    method = request["method"]
    require(isinstance(method, str) and method in METHODS, "METHOD_NOT_FOUND", "Unknown method")
    require(isinstance(request["params"], dict))
    if method == "hello":
        require("host_id" not in request and "operation_id" not in request)
    else:
        identifier(request.get("host_id"))
    if method in MUTATIONS:
        identifier(request.get("operation_id"))
    else:
        require("operation_id" not in request)
    with store.transaction() as state:
        if method != "hello":
            require(request["host_id"] == state["host_id"], "HOST_IDENTITY_CHANGED", "Wrong execution host")
        reconcile(state)
        opid = request.get("operation_id")
        identity = hashlib.sha256(canonical({k: request[k] for k in
                                            ("host_id", "method", "params") if k in request})).hexdigest()
        old = state["operations"].get(opid)
        if old:
            require(old["payload_hash"] == identity, "OPERATION_CONFLICT", "Operation ID reused with different payload")
            outcome = copy.deepcopy(old["outcome"])
        else:
            if opid:
                require(len(state["operations"]) < 1024, "LIMIT_REACHED", "Prototype operation limit")
            try:
                outcome = {"ok": True, "result": execute(state, method, request["params"])}
            except Failure as exc:
                outcome = {"ok": False, "error": {"code": exc.code, "message": exc.message}}
            if opid:
                # Both modeled side effect and outcome commit in ONE atomic state file.
                # This does not model an out-of-process VM effect or a crash inside it.
                state["operations"][opid] = {"payload_hash": identity, "method": method,
                                            "state": "completed" if outcome["ok"] else "failed",
                                            "committed_at": state["now"], "outcome": copy.deepcopy(outcome)}
        response = {"protocol": PROTOCOL, "request_id": request["request_id"],
                    "host_id": state["host_id"], **outcome}
        encode(response)  # Do not commit an outcome that cannot fit a response.
    return response


def worker(root, drop_after_commit=None):
    store = Store(root)
    with store.transaction() as state:
        host_id = state["host_id"]
    while True:
        raw = sys.stdin.buffer.readline(MAX_FRAME + 1)
        if not raw:
            return
        request_id = "invalid"
        try:
            request = decode(raw)
            if isinstance(request.get("request_id"), str) and IDENTIFIER.fullmatch(request["request_id"]):
                request_id = request["request_id"]
            response = handle(store, request)
            if drop_after_commit == request["method"] and response["ok"]:
                os._exit(70)  # State fsync/rename finished; deliberately lose the reply.
        except Failure as exc:
            response = {"protocol": PROTOCOL, "request_id": request_id, "host_id": host_id,
                        "ok": False, "error": {"code": exc.code, "message": exc.message}}
        sys.stdout.buffer.write(encode(response))
        sys.stdout.buffer.flush()
        if len(raw) > MAX_FRAME:
            return  # Never interpret an oversized frame's remainder as a request.


def bounded_exchange(command, frame, timeout=8):
    """POSIX pipes with bounded output and a deadline, without shell invocation."""
    require(len(frame) <= MAX_FRAME, "FRAME_TOO_LARGE", "Frame exceeds 64 KiB")
    process = None
    selector = selectors.DefaultSelector()
    output, diagnostic, sent = bytearray(), bytearray(), 0
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        for stream, role, event in ((process.stdin, "input", selectors.EVENT_WRITE),
                                    (process.stdout, "output", selectors.EVENT_READ),
                                    (process.stderr, "error", selectors.EVENT_READ)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, event, role)
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("HOST_UNREACHABLE", "Control transport timed out")
            for key, _ in selector.select(remaining):
                stream = key.fileobj
                if key.data == "input":
                    try:
                        sent += os.write(stream.fileno(), frame[sent:sent + 4096])
                    except BrokenPipeError:
                        sent = len(frame)
                    if sent == len(frame):
                        selector.unregister(stream)
                        stream.close()
                    continue
                chunk = os.read(stream.fileno(), 4096)
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                elif key.data == "output":
                    output.extend(chunk)
                    require(len(output) <= MAX_FRAME, "FRAME_TOO_LARGE", "Worker response exceeds 64 KiB")
                elif len(diagnostic) < 2048:
                    diagnostic.extend(chunk[:2048 - len(diagnostic)])
        process.wait(timeout=max(0.01, deadline - time.monotonic()))
        if not output or process.returncode != 0:
            failure = Failure("HOST_UNREACHABLE", "No successful control response; operation outcome may be uncertain")
            failure.frontend_exit_code = process.returncode
            raise failure
        return bytes(output)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Failure("HOST_UNREACHABLE", "Cannot reach control frontend") from exc
    finally:
        selector.close()
        if process:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()


class LocalTransport:
    def __init__(self, root):
        self.root, self.drop_next_method = str(root), None

    def exchange(self, frame):
        command = [sys.executable, str(Path(__file__).resolve()), "worker", "--root", self.root]
        if self.drop_next_method:
            command += ["--drop-after-commit", self.drop_next_method]
            self.drop_next_method = None
        return bounded_exchange(command, frame)


class SSHTransport:
    """Opt-in only. Requires a preinstalled simulated worker and existing host pins."""
    def __init__(self, alias, known_hosts):
        require(bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", alias)),
                "INVALID_SSH_TARGET", "Use a simple trusted SSH config alias")
        path = str(Path(known_hosts).absolute())
        require(Path(path).is_file() and not any(c in path for c in '\n\r"\\%$'),
                "INVALID_SSH_PINS", "Provide an existing dedicated known_hosts file")
        options = ["BatchMode=yes", "StrictHostKeyChecking=yes", "ForwardAgent=no",
                   "ClearAllForwardings=yes", "RequestTTY=no", "EscapeChar=none",
                   "UpdateHostKeys=no", "GlobalKnownHostsFile=/dev/null",
                   "ConnectTimeout=5", "ConnectionAttempts=1", "ControlMaster=no",
                   "ControlPath=none", f'UserKnownHostsFile="{path}"']
        self.command = ["ssh", "-T"] + [item for opt in options for item in ("-o", opt)]
        self.command += [alias, REMOTE_COMMAND]

    def exchange(self, frame):
        return bounded_exchange(self.command, frame, timeout=12)


class Client:
    def __init__(self, transport, host_id=None, trace=None):
        self.transport, self.host_id, self.trace = transport, host_id, trace
        self.observed = {}

    def connect(self):
        result = self.call("hello", {})
        require(result.get("protocol") == PROTOCOL and result.get("runtime") == "simulated",
                "HOST_PROTOCOL_INCOMPATIBLE", "Expected this simulated worker protocol")
        return result

    def call(self, method, params, operation_id=None):
        request = {"protocol": PROTOCOL, "request_id": str(uuid.uuid4()), "method": method, "params": params}
        if method != "hello":
            require(self.host_id is not None, "HOST_NOT_ENROLLED", "Hello or a pinned host ID is required")
            request["host_id"] = self.host_id
        if method in MUTATIONS:
            request["operation_id"] = operation_id or str(uuid.uuid4())
        if self.trace:
            self.trace({"event": "request", "request": request})
        try:
            response = decode(self.transport.exchange(encode(request)))
        except Failure as exc:
            if self.trace:
                self.trace({"event": "transport_error", "code": exc.code, "operation_id": request.get("operation_id")})
            if method in MUTATIONS and exc.code == "HOST_UNREACHABLE":
                raise Failure("OPERATION_UNCERTAIN", "Query or retry the SAME operation_id: " + request["operation_id"]) from exc
            raise
        fields(response, {"protocol", "request_id", "host_id", "ok"}, {"result", "error"})
        require(response["protocol"] == PROTOCOL, "HOST_PROTOCOL_INCOMPATIBLE", "Unexpected response protocol")
        require(response["request_id"] == request["request_id"], "INVALID_RESPONSE", "Response request ID mismatch")
        identifier(response["host_id"])
        require(self.host_id is None or response["host_id"] == self.host_id,
                "HOST_IDENTITY_CHANGED", "Response came from a different host installation")
        require(type(response["ok"]) is bool and ((response["ok"] and "result" in response and "error" not in response)
                or (not response["ok"] and "error" in response and "result" not in response)), "INVALID_RESPONSE", "Invalid outcome")
        if self.trace:
            self.trace({"event": "response", "response": response})
        if not response["ok"]:
            fields(response["error"], {"code", "message"})
            require(all(isinstance(v, str) for v in response["error"].values()), "INVALID_RESPONSE", "Invalid error")
            raise Failure(response["error"]["code"], response["error"]["message"])
        if method == "hello":
            require(isinstance(response["result"], dict), "INVALID_RESPONSE", "Invalid hello")
            require(response["result"].get("protocol") == PROTOCOL
                    and response["result"].get("runtime") == "simulated",
                    "HOST_PROTOCOL_INCOMPATIBLE", "Unexpected worker advertisement")
            self.host_id = response["host_id"]
        return response["result"]

    def listing(self, ref):
        try:
            result = self.call("vm.inspect", {"ref": ref})
            self.observed[ref["instance_id"]] = result["observed_at"]
            return {**result, "reachability": "reachable"}
        except Failure as exc:
            if exc.code != "HOST_UNREACHABLE":
                raise
            return {"ref": ref, "state": "unknown", "reachability": "unreachable",
                    "last_observed_at": self.observed.get(ref["instance_id"]), "error": exc.code}


def demo(keep=False):
    directory = Path(tempfile.mkdtemp(prefix="PROTOTYPE-demo-", dir=Path.cwd()))
    print("SIMULATED runtime only. Two local stdio worker processes; no SSH or VM is launched.")
    try:
        clients = []
        for name in ("local", "remote-model"):
            root = directory / ("PROTOTYPE-" + name)
            Store(root).initialize()
            client = Client(LocalTransport(root))
            client.connect()
            vm = client.call("vm.create", {"name": "my-project"})
            running = client.call("vm.start", {"ref": vm["ref"]})
            print(json.dumps({"placement": name, "host_id": client.host_id,
                              "instance": running}, indent=2))
            clients.append((client, root, vm["ref"]))
        client, root, ref = clients[1]
        client.transport.drop_next_method = "vm.create"
        opid = "demo-create-with-lost-reply"
        try:
            client.call("vm.create", {"name": "retry-demo"}, opid)
        except Failure as exc:
            print(str(exc))
        recovered = client.call("vm.create", {"name": "retry-demo"}, opid)
        print("Recovered committed instance:", recovered["ref"]["instance_id"])
        Store(root).advance(DEFAULT_TTL)
        print("After explicit MODEL time advance:", json.dumps(client.listing(ref)))
    finally:
        if keep:
            print("Retained explicitly simulated state:", directory)
        else:
            shutil.rmtree(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "worker", "advance"):
        sub = commands.add_parser(name)
        sub.add_argument("--root", required=True)
        if name == "worker":
            sub.add_argument("--drop-after-commit", choices=sorted(MUTATIONS))
        if name == "advance":
            sub.add_argument("--seconds", type=float, required=True)
    sub = commands.add_parser("demo")
    sub.add_argument("--keep", action="store_true")
    sub = commands.add_parser("call", help="Call the simulated local or explicitly selected SSH worker")
    location = sub.add_mutually_exclusive_group(required=True)
    location.add_argument("--root")
    location.add_argument("--ssh-alias")
    sub.add_argument("--known-hosts")
    sub.add_argument("--expected-host-id")
    sub.add_argument("--operation-id")
    sub.add_argument("--params", default="{}", help="A JSON object; use no actual credentials")
    sub.add_argument("method", choices=sorted(METHODS))
    args = parser.parse_args()
    try:
        if args.command == "init":
            print(json.dumps({"host_id": Store(args.root).initialize(), "runtime": "simulated"}))
        elif args.command == "worker":
            worker(args.root, args.drop_after_commit)
        elif args.command == "advance":
            print(json.dumps({"model_time": Store(args.root).advance(args.seconds), "runtime": "simulated"}))
        elif args.command == "demo":
            demo(args.keep)
        else:
            if args.ssh_alias:
                require(args.known_hosts is not None, "INVALID_SSH_PINS", "--known-hosts is required")
                require(args.method == "hello" or args.expected_host_id is not None,
                        "HOST_NOT_ENROLLED", "Remote actions require --expected-host-id")
                transport = SSHTransport(args.ssh_alias, args.known_hosts)
            else:
                transport = LocalTransport(args.root)
            require(args.method not in MUTATIONS or args.operation_id is not None,
                    "INVALID_REQUEST", "Supply a reusable --operation-id for a mutation")
            client = Client(transport, args.expected_host_id)
            hello = client.connect()
            result = hello if args.method == "hello" else client.call(
                args.method, decode(args.params.encode("utf-8") + b"\n"), args.operation_id)
            print(json.dumps({"host_id": client.host_id, "runtime": "simulated", "result": result}, indent=2))
    except (Failure, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
