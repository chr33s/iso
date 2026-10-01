#!/usr/bin/env python3
"""Process-level checks of the confined iso-inference gateway.

    python3 scripts/test-inference-gateway-process.py [--binary PATH]

Starts the real binary under `sandbox-exec` with
Sources/IsoHost/seatbelt-inference.sb and a private state directory, then
drives it over its control socket: a stand-in sandbox owner process (a
sleeper built as `iso-sandbox`) as the session's
transport, a loopback fake backend, and a raw HTTP client. No network, VM or
credential is used. Build first:

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
PROFILE = ROOT / "Sources/IsoHost/seatbelt-inference.sb"
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
    return int(data.split(b" ")[1]), data


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", default=str(ROOT / "iso-proxy/.build/debug/iso-inference"))
    args = parser.parse_args()
    binary = os.path.realpath(args.binary)
    if not os.path.isfile(binary):
        raise SystemExit(f"{binary} not found; build iso-inference first")
    state = Path(os.path.realpath(tempfile.mkdtemp(prefix="iso-inference-")))
    os.chmod(state, 0o700)
    # Short, so session socket paths fit sun_path (the runtime uses the
    # per-user temp directory).
    relay = Path(os.path.realpath(tempfile.mkdtemp(prefix="ir-", dir="/tmp")))
    os.chmod(relay, 0o700)
    backend = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    backend_port = backend.server_address[1]
    # The launcher renders one outbound rule per backend port (§20.5).
    profile_text = PROFILE.read_text().replace(
        ";; @BACKEND_PORTS@", f'(allow network-outbound (remote ip "localhost:{backend_port}"))')
    profile_path = state.parent / (state.name + ".sb")
    profile_path.write_text(profile_text)
    confined = ["/usr/bin/sandbox-exec", "-D", f"INFERENCE_BIN={binary}", "-D", f"STATE_DIR={state}",
                "-D", f"RELAY_DIR={relay}", "-f", str(profile_path), binary, "--state-dir", str(state),
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

    profile = {"name": "p", "protocol": "openai-chat", "completion_evidence": "drain",
               "stream_close_drain_ms": 100, "context_overflow": "reject",
               "overhead_per_request_bytes": 64, "overhead_per_message_bytes": 8,
               "max_input_bytes": 1048576, "max_request_body_bytes": 4194304, "token_counter": "none"}
    def registration(port):
        return {
            "version": 2, "op": "register_session", "instance": {"data_root": "/x", "name": "dev"},
            "boot": {"owner_pid": 1, "owner_start": "1.0"}, "nonce": "0" * 32,
            "socket": "8e84b04d471a546a.sock",
            "global_limits": {"max_active_requests": 2, "max_queued_requests": 32,
                              "max_request_buffer_bytes": 67108864},
            "grants": [{"alias": "local-coder", "upstream_model": "real", "apis": ["openai-chat"],
                        "max_context_tokens": 32768, "default_output_tokens": 256,
                        "max_output_tokens": 1024,
                        "backend": {"port": port, "name": "fake", "max_active": 1,
                                    "profile": profile}}]}

    outside = control(state, registration(backend_port + 1 if backend_port < 65535 else 1024))
    check("a backend port outside the launch list is refused", outside.get("ok") is False)
    registered = control(state, registration(backend_port))
    check("registration succeeds", registered.get("ok") is True)
    session_socket, token = relay / registered["socket"], registered["capability"]
    check("the session socket is owner-only (0600) in the relay directory",
          stat.S_IMODE(os.stat(session_socket).st_mode) == 0o600)
    listeners = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(gateway.pid), "-iTCP",
                                "-sTCP:LISTEN", "-t"], capture_output=True, text=True).stdout.strip()
    check("the gateway listens on no TCP port", listeners == "")
    traversal = dict(registration(backend_port), socket="../escape.sock")
    check("a session socket name outside the relay directory is refused",
          control(state, traversal).get("ok") is False)
    body = json.dumps({"model": "local-coder", "messages": [{"role": "user", "content": "hi"}]}).encode()
    check("an inactive session refuses requests", http(session_socket, token, body)[0] == 401)

    # The transport is the instance's sandbox owner, whose command is
    # `iso-sandbox`; a tiny sleeper built under that name stands in for it
    # (copies and symlinks of /bin/sleep keep the name `sleep`).
    owner_binary = state.parent / (state.name + "-bin") / "iso-sandbox"
    owner_binary.parent.mkdir()
    subprocess.run(["/usr/bin/cc", "-x", "c", "-", "-o", str(owner_binary)], check=True,
                   input=b"#include <stdlib.h>\n#include <unistd.h>\n"
                         b"int main(int c, char **v) { sleep(atoi(v[1])); return 0; }\n")
    owner = subprocess.Popen([str(owner_binary), "60"])
    time.sleep(0.5)
    sleeper = subprocess.Popen(["/bin/sleep", "60"])
    def activation(pid, **extra):
        return {"version": 2, "op": "activate_session", "session_id": registered["session_id"],
                "epoch": registered["epoch"],
                "transport": {"pid": pid, "start": process_start(pid)}, **extra}

    wrong = control(state, activation(sleeper.pid))
    check("activation refuses a transport that is not the sandbox owner", wrong.get("ok") is False)
    sleeper.kill()
    activated = control(state, activation(owner.pid, deadline_seconds=3600))
    check("activation binds the session to the sandbox owner process", activated.get("ok") is True)

    check("a request without the capability is refused", http(session_socket, None, body)[0] == 401)
    status, reply = http(session_socket, token, body)
    check("an authorized request is served", status == 200 and b'"local-coder"' in reply)
    check("the backend saw the upstream model and no guest credential",
          received and received[-1][2]["model"] == "real" and "authorization" not in received[-1][1])

    owner.kill()
    time.sleep(1.5)
    sessions = control(state, {"version": 2, "op": "inspect"})["sessions"]
    check("the sandbox owner's exit revokes the session", sessions == [])
    try:
        http(session_socket, token, body)
        refused = False
    except OSError:
        refused = True
    check("a revoked session's socket refuses connections", refused)

    busy = control(state, {"version": 2, "op": "shutdown", "force": False})
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
