#!/usr/bin/env python3
"""Process-level checks of the confined iso-inference gateway.

    python3 scripts/test-inference-gateway-process.py [--binary PATH] [--profile PATH]

Starts the real binary under `sandbox-exec` with the gateway Seatbelt profile
(Sources/IsoHost/Guest/Resources/seatbelt-inference.sb) and a private state directory, then
drives it over its control socket. Stand-in carrier processes (each a small
HTTP client this script drives over a pipe) play the sandbox owner and the
brokered forward, since the gateway admits connections only from the bound
process, by its peer token; a loopback fake backend answers. No network, VM
or credential is used. Build first:

    swift build --package-path iso-proxy --product iso-inference
"""

import argparse
import ctypes
import ctypes.util
import json
import os
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "Sources/IsoHost/Inference/Resources/seatbelt-inference.sb"
WORKER_PROFILE = ROOT / "Sources/IsoHost/Inference/Resources/seatbelt-inference-worker.sb"
failures = []


def check(label, condition):
    print(("  PASS  " if condition else "  FAIL  ") + label, flush=True)
    if not condition:
        failures.append(label)


received = []


class Backend(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["content-length"]))
        received.append((self.path, {k.lower() for k in self.headers.keys()}, json.loads(body)))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()
        for event in [
            {"id": "c", "model": "real", "choices": [{"index": 0, "delta": {"content": "ok"},
                                                     "finish_reason": "stop"}]},
            {"id": "c", "model": "real", "choices": [],
             "usage": {"prompt_tokens": 3, "completion_tokens": 1}},
        ]:
            self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.close_connection = True


class ProcBSDInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid",
        "svgid", "rfu")] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32), ("nfiles", ctypes.c_uint32),
        ("pgid", ctypes.c_uint32), ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
        ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
        ("start_usec", ctypes.c_uint64)]


def process_start(pid):
    libproc = ctypes.CDLL(ctypes.util.find_library("proc"))
    info = ProcBSDInfo()
    libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    return f"{info.start_sec}.{info.start_usec}"


def pid_version(pid):
    """The audit token's PID version of `pid`, read as the host controller does."""
    libc = ctypes.CDLL(None)
    task_self = ctypes.c_uint.in_dll(libc, "mach_task_self_")
    name = ctypes.c_uint(0)
    if libc.task_name_for_pid(task_self, pid, ctypes.byref(name)) != 0:
        raise SystemExit(f"cannot read process {pid}")
    token, count = (ctypes.c_uint * 8)(), ctypes.c_uint(8)
    if libc.task_info(name, 15, token, ctypes.byref(count)) != 0:  # TASK_AUDIT_TOKEN
        raise SystemExit(f"cannot read the audit token of {pid}")
    return token[7]


# A carrier: sends one request per line of JSON on stdin to the session
# socket it names, and prints the response status (0 when the gateway closes
# the connection without answering).
CARRIER = r"""
import json, socket, sys
for line in sys.stdin:
    request = json.loads(line)
    status = 0
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(request["socket"])
        head = "POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\n"
        if request["token"]:
            head += "authorization: Bearer " + request["token"] + "\r\n"
        body = request["body"].encode()
        head += "content-length: %d\r\n\r\n" % len(body)
        s.sendall(head.encode() + body)
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        if data:
            status = int(data.split(b" ")[1])
    except OSError:
        status = 0
    print(status, flush=True)
"""


class Carrier:
    def __init__(self):
        self.process = subprocess.Popen([sys.executable, "-I", "-c", CARRIER],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.pid = self.process.pid

    def request(self, path, token, body):
        self.process.stdin.write(json.dumps(
            {"socket": str(path), "token": token, "body": body.decode()}) + "\n")
        self.process.stdin.flush()
        return int(self.process.stdout.readline())

    def binding(self):
        return {"pid": self.pid, "version": pid_version(self.pid)}

    def kill(self):
        self.process.kill()
        self.process.wait()


def control(state, message):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(str(state / "control.sock"))
    body = json.dumps(message).encode()
    s.sendall(struct.pack(">I", len(body)) + body)
    (length,) = struct.unpack(">I", s.recv(4, socket.MSG_WAITALL))
    data = b""
    while len(data) < length:
        data += s.recv(length - len(data))
    s.close()
    return json.loads(data)


def http(path, token, body):
    """A request on a session socket, as the sandbox owner's relay sends it."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(str(path))
    head = f"POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\n"
    if token:
        head += f"authorization: Bearer {token}\r\n"
    head += f"content-length: {len(body)}\r\n\r\n"
    s.sendall(head.encode() + body)
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    s.close()
    # A connection the gateway closes unanswered is status 0.
    return (int(data.split(b" ")[1]) if data else 0), data


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", default=str(ROOT / "iso-proxy/.build/debug/iso-inference"))
    parser.add_argument("--profile", default=str(PROFILE))
    args = parser.parse_args()
    binary = os.path.realpath(args.binary)
    if not os.path.isfile(binary):
        raise SystemExit(f"{binary} not found; build iso-inference first")
    if not os.path.isfile(args.profile):
        raise SystemExit(f"{args.profile} not found")
    state = Path(os.path.realpath(tempfile.mkdtemp(prefix="iso-inference-")))
    os.chmod(state, 0o700)
    # Short, so session socket paths fit sun_path (the runtime uses the
    # per-user temp directory).
    relay = Path(os.path.realpath(tempfile.mkdtemp(prefix="ir-", dir="/tmp")))
    os.chmod(relay, 0o700)
    backend = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    backend_port = backend.server_address[1]
    # The broker's profile is used as is: it names no backend port (§20.5).
    profile_path = Path(args.profile)
    confined = ["/usr/bin/sandbox-exec", "-D", f"INFERENCE_BIN={binary}", "-D", f"STATE_DIR={state}",
                "-f", str(profile_path), binary, "--state-dir", str(state),
                "--relay-dir", str(relay),
                "--backend-port", str(backend_port)]

    unconfined = subprocess.run([binary, "--state-dir", str(state), "--relay-dir", str(relay),
                                 "--backend-port", str(backend_port)],
                                capture_output=True, timeout=30)
    check("an unconfined gateway refuses to start", unconfined.returncode == 1)
    selftest = subprocess.run(confined + ["--jail-selftest"], capture_output=True, timeout=30)
    check("the jail self-test passes under the profile", selftest.returncode == 0)
    os.chmod(state, 0o755)
    wide = subprocess.run(confined, capture_output=True, timeout=30)
    check("a group- or world-readable state directory is refused", wide.returncode == 1)
    os.chmod(state, 0o700)

    gateway = subprocess.Popen(confined, stderr=subprocess.PIPE)
    for _ in range(100):
        if (state / "control.sock").exists():
            break
        time.sleep(0.05)
    mode = stat.S_IMODE(os.stat(state / "control.sock").st_mode)
    check("the control socket is owner-only (0600)", mode == 0o600)
    second = subprocess.run(confined, capture_output=True, timeout=30)
    check("a second gateway exits on the startup lock (status 3)", second.returncode == 3)
    check("the broker serves an owner-only worker socket",
          stat.S_IMODE(os.stat(state / "workers.sock").st_mode) == 0o600)

    # One session's worker, as iso starts it: its own rendered profile,
    # the one-time key on stdin (§5.1).
    def worker_command(socket_path, session_id, ports=(backend_port,), program=None, extra=()):
        rules = "\n".join(f'(allow network-outbound (remote ip "localhost:{port}"))' for port in ports)
        text = WORKER_PROFILE.read_text().replace(";; @BACKEND_PORTS@", rules)
        path = state.parent / (state.name + f"-{session_id[:8]}.sb")
        path.write_text(text)
        target = program or [binary, "--worker", "--broker", str(state / "workers.sock"),
                             "--socket", str(socket_path), "--session", session_id, *extra]
        return ["/usr/bin/sandbox-exec", "-D", f"INFERENCE_BIN={program[0] if program else binary}",
                "-D", f"SESSION_SOCKET={socket_path}", "-D", f"BROKER_SOCKET={state / 'workers.sock'}",
                "-f", str(path), *target]

    def start_worker(session, key=None):
        socket_path = relay / session["socket"]
        process = subprocess.Popen(worker_command(socket_path, session["session_id"]),
                                   stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
        process.stdin.write(((key or session["worker_key"]) + "\n").encode())
        process.stdin.close()
        for _ in range(100):
            if socket_path.exists() or process.poll() is not None:
                break
            time.sleep(0.05)
        return process

    # The sandbox owner and another process of this user that is not it.
    owner = Carrier()
    impostor = Carrier()
    time.sleep(0.5)

    profile = {"name": "p", "protocol": "openai-chat", "completion_evidence": "drain",
               "stream_close_drain_ms": 100, "context_overflow": "reject",
               "overhead_per_request_bytes": 64, "overhead_per_message_bytes": 8,
               "max_input_bytes": 1048576, "max_request_body_bytes": 4194304, "token_counter": "none"}
    def registration(port, name="dev", socket="8e84b04d471a546a.sock", transport="owner"):
        return {
            "version": 6, "op": "register_session", "instance": {"data_root": "/x", "name": name},
            "boot": {"owner_pid": owner.pid, "owner_start": process_start(owner.pid)},
            "nonce": "0" * 32,
            "socket": socket, "transport": transport,
            "global_limits": {"max_active_requests": 2, "max_queued_requests": 32,
                              "max_request_buffer_bytes": 67108864},
            "grants": [{"alias": "local-coder", "upstream_model": "real", "apis": ["openai-chat"],
                        "max_context_tokens": 32768, "default_output_tokens": 256,
                        "max_output_tokens": 1024,
                        "backend": {"port": port, "name": "fake", "max_active": 1,
                                    "front": "plain", "profile": profile}}]}

    outside = control(state, registration(backend_port + 1 if backend_port < 65535 else 1024))
    check("a backend port outside the launch list is refused", outside.get("ok") is False)
    registered = control(state, registration(backend_port))
    check("registration succeeds and names a worker key",
          registered.get("ok") is True and len(registered.get("worker_key", "")) == 64)
    session_socket, token = relay / registered["socket"], registered["capability"]
    check("the broker binds no session socket", not session_socket.exists())
    probe_broker = subprocess.run(
        ["/usr/bin/sandbox-exec", "-D", "INFERENCE_BIN=/usr/bin/nc", "-D", f"STATE_DIR={state}",
         "-f", str(profile_path), "/usr/bin/nc", "-z", "-w", "1",
         "127.0.0.1", str(backend_port)], capture_output=True, timeout=30)
    check("the broker's profile reaches no backend port", probe_broker.returncode != 0)
    probe = worker_command(session_socket, registered["session_id"], extra=["--jail-selftest"])
    check("the worker's jail self-test passes under its profile",
          subprocess.run(probe, capture_output=True, timeout=30).returncode == 0)
    unconfined_worker = subprocess.run(
        [binary, "--worker", "--broker", str(state / "workers.sock"), "--socket", str(session_socket),
         "--session", registered["session_id"]], input=b"0" * 64 + b"\n", capture_output=True,
        timeout=30)
    check("an unconfined worker refuses to start", unconfined_worker.returncode == 1)
    wrong_key = start_worker(registered, key="1" * 64)
    check("a worker with the wrong key is refused", wrong_key.wait(timeout=10) != 0
          and not session_socket.exists())
    # A session socket left by a crashed worker: the next worker replaces it.
    leftover = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    leftover.bind(str(session_socket))
    leftover.close()
    stale_inode = os.stat(session_socket).st_ino
    worker = start_worker(registered)
    for _ in range(100):
        if session_socket.exists() and os.stat(session_socket).st_ino != stale_inode:
            break
        time.sleep(0.05)
    check("the worker binds the session socket, replacing a stale one",
          session_socket.exists() and os.stat(session_socket).st_ino != stale_inode)
    second_worker = start_worker(registered)
    check("a second worker for the session is refused", second_worker.wait(timeout=10) != 0)
    state_after = control(state, {"version": 6, "op": "inspect"})["sessions"][0]
    check("the broker reports the worker ready, by pid",
          state_after.get("worker") == "ready" and state_after.get("worker_pid") == worker.pid)
    check("the session socket is owner-only (0600) in the relay directory",
          stat.S_IMODE(os.stat(session_socket).st_mode) == 0o600)
    listeners = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", f"{gateway.pid},{worker.pid}",
                                "-iTCP", "-sTCP:LISTEN", "-t"], capture_output=True, text=True).stdout.strip()
    check("neither the broker nor the worker listens on a TCP port", listeners == "")
    traversal = dict(registration(backend_port), socket="../escape.sock")
    check("a session socket name outside the relay directory is refused",
          control(state, traversal).get("ok") is False)
    body = json.dumps({"model": "local-coder", "messages": [{"role": "user", "content": "hi"}]}).encode()
    check("an inactive session admits no connection, even the owner's",
          owner.request(session_socket, token, body) == 0)

    def activation(carrier, session=None, **extra):
        session = session or registered
        return {"version": 6, "op": "activate_session", "session_id": session["session_id"],
                "epoch": session["epoch"], "transport": carrier.binding(), **extra}

    version_two = dict(registration(backend_port, name="old", socket="0123.sock"), version=2)
    check("a version 2 registration (no transport kind) is refused",
          control(state, version_two).get("ok") is False)

    wrong = control(state, activation(impostor))
    check("activation refuses a transport that is not the registered sandbox owner",
          wrong.get("ok") is False)
    activated = control(state, activation(owner, deadline_seconds=3600))
    check("activation binds the session to the sandbox owner process", activated.get("ok") is True)

    check("a request without the capability is refused",
          owner.request(session_socket, None, body) == 401)
    check("an authorized request from the bound owner is served",
          owner.request(session_socket, token, body) == 200)
    check("the backend saw the upstream model and no guest credential",
          received and received[-1][2]["model"] == "real" and "authorization" not in received[-1][1])
    seen = len(received)
    check("another process of this user, with the capability, is refused at connection",
          impostor.request(session_socket, token, body) == 0)
    check("so is this script's own process", http(session_socket, token, body)[0] == 0)
    check("a refused connection reaches no backend", len(received) == seen)
    impostor.kill()

    # A `forward` session (the brokered transport) binds the host's reverse
    # forward, another process than the owner; which program it runs is the
    # host controller's check.
    forwarded = control(state, registration(
        backend_port, name="brokered", socket="0abc.sock", transport="forward"))
    check("a forward registration succeeds", forwarded.get("ok") is True)
    forward_worker = start_worker(forwarded)
    # Each worker's profile admits only its own session socket: one worker
    # cannot reach the other's (nc stands in for a compromised worker).
    reach = lambda own, other: subprocess.run(
        worker_command(own, "c" * 32, program=["/usr/bin/nc", "-U", "-w", "1", str(other)]),
        stdin=subprocess.DEVNULL, capture_output=True, timeout=30).returncode
    check("a worker's profile refuses another session's socket",
          reach(session_socket, relay / forwarded["socket"]) != 0)
    check("but reaches the broker's worker socket", reach(session_socket, state / "workers.sock") == 0)
    forward = Carrier()
    time.sleep(0.5)
    check("forward activation refuses the sandbox owner",
          control(state, activation(owner, forwarded)).get("ok") is False)
    check("forward activation binds the declared forward",
          control(state, activation(forward, forwarded)).get("ok") is True)
    forward_socket = relay / forwarded["socket"]
    check("a forward session serves its forward",
          forward.request(forward_socket, forwarded["capability"], body) == 200)
    check("and refuses the owner's connections",
          owner.request(forward_socket, forwarded["capability"], body) == 0)
    forward.kill()
    time.sleep(1.5)
    live = [s["session_id"] for s in control(state, {"version": 6, "op": "inspect"})["sessions"]]
    check("the forward's exit revokes its session", forwarded["session_id"] not in live
          and registered["session_id"] in live)

    check("the forward's worker exits with its session", forward_worker.wait(timeout=30) == 0)

    owner.kill()
    time.sleep(1.5)
    sessions = control(state, {"version": 6, "op": "inspect"})["sessions"]
    check("the sandbox owner's exit revokes the session", sessions == [])
    check("and its worker exits", worker.wait(timeout=30) == 0)

    # A worker that dies takes its session with it.
    crashing = control(state, registration(backend_port, name="crash", socket="0def.sock"))
    crash_worker = start_worker(crashing)
    crash_worker.kill()
    crash_worker.wait()
    time.sleep(0.5)
    live = [s["session_id"] for s in control(state, {"version": 6, "op": "inspect"})["sessions"]]
    check("a worker's exit revokes its session", crashing["session_id"] not in live)
    try:
        http(session_socket, token, body)
        refused = False
    except OSError:
        refused = True
    check("a revoked session's socket refuses connections", refused)
    check("revocation removes the session socket file", not session_socket.exists())

    busy = control(state, {"version": 6, "op": "shutdown", "force": False})
    check("shutdown succeeds with no sessions", busy.get("ok") is True)
    gateway.wait(timeout=10)
    check("the gateway exits cleanly", gateway.returncode == 0)
    check("the socket is removed on exit", not (state / "control.sock").exists())
    audit = (state / "audit.log").read_text()
    check("the audit log holds no capability or prompt", token not in audit and '"hi"' not in audit)
    backend.shutdown()
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
