#!/usr/bin/env python3
"""Production-profile process gate. Uses only synthetic credentials.

Default execution includes credential-free live-provider system TLS probes.
--skip-tls runs the offline startup/listener/shutdown cases only.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SECRET = "coop-process-test-secret-never-real"
TOKEN = "a" * 64


def config(port):
    return {"version": 1, "listen": f"127.0.0.1:{port}", "provider": "anthropic",
            "capability_token": TOKEN, "injection": {"scheme": "x_api_key", "credential": SECRET}}


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def request(port, headers=""):
    with socket.create_connection(("127.0.0.1", port), timeout=0.5) as peer:
        peer.sendall(("GET /v1/messages HTTP/1.1\r\nHost: guest\r\n" + headers +
                      "Connection: close\r\n\r\n").encode())
        response = b""
        while True:
            chunk = peer.recv(4096)
            if not chunk:
                return response
            response += chunk
            if len(response) > 65536:
                raise AssertionError("unbounded local response")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-tls", action="store_true")
    args = parser.parse_args()
    directory = subprocess.check_output(
        ["swift", "build", "--package-path", str(ROOT / "macos/coop-proxy"), "--show-bin-path"], text=True).strip()
    binary = (Path(directory) / "coop-proxy-swift").resolve()
    command = ["/usr/bin/sandbox-exec", "-D", "PROXY_BIN=" + str(binary),
               "-f", str(ROOT / "src/seatbelt-proxy.sb"), str(binary)]

    # Keep stdin open and unwritten: an unconfined process must fail before
    # waiting for a credential, much less binding a listener.
    child = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env={})
    try:
        assert child.wait(timeout=5) != 0, "unconfined startup accepted"
    finally:
        if child.poll() is None:
            child.kill()
        child.communicate(timeout=5)
    print("PASS unconfined startup refuses before stdin", flush=True)

    for mutate in [lambda value: value.update(version=2),
                   lambda value: value.update(listen="0.0.0.0:8788"),
                   lambda value: value.update(capability_token="bad"),
                   lambda value: value.update(upstream_host=SECRET),
                   lambda value: value["injection"].update(scheme=SECRET)]:
        value = config(free_port())
        mutate(value)
        result = subprocess.run(command, input=json.dumps(value), capture_output=True,
                                text=True, env={}, timeout=5)
        assert result.returncode != 0, "invalid startup accepted"
        assert SECRET not in result.stdout + result.stderr, "startup diagnostic leaked input"
    oversized = subprocess.run(command, input="x" * 65537, capture_output=True, text=True, env={}, timeout=5)
    assert oversized.returncode != 0, "oversized startup accepted"
    print("PASS strict bounded startup and redacted diagnostics", flush=True)

    port = free_port()
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env={})
    try:
        child.stdin.write(json.dumps(config(port)).encode())
        child.stdin.close()
        child.stdin = None
        deadline = time.monotonic() + 5
        while True:
            assert child.poll() is None, "confined proxy exited before readiness"
            try:
                response = request(port)
                assert response.startswith(b"HTTP/1.1 401"), response
                break
            except (ConnectionError, TimeoutError):
                if time.monotonic() >= deadline:
                    raise AssertionError("proxy failed real HTTP readiness")
                time.sleep(0.03)
        response = request(port, "Authorization: Bearer " + TOKEN + "\r\n")
        assert response.startswith(b"HTTP/1.1 403"), response
        argv = subprocess.check_output(["/bin/ps", "-ww", "-p", str(child.pid), "-o", "command="], text=True)
        assert SECRET not in argv and TOKEN not in argv, "startup secret on argv"
        # Termination must close an accepted, incomplete request too.
        with socket.create_connection(("127.0.0.1", port), timeout=1) as held:
            held.sendall(b"POST /v1/")
            child.terminate()
            stdout, stderr = child.communicate(timeout=5)
            assert child.returncode == 0, stderr
            assert SECRET.encode() not in stdout + stderr and TOKEN.encode() not in stdout + stderr
            try:
                assert held.recv(1) == b"", "shutdown retained guest connection"
            except ConnectionResetError:
                pass  # closing a socket with unread request bytes may send RST

    finally:
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=5)
    print("PASS production profile binds/accepts HTTP, keeps secrets off argv/logs, and shuts down", flush=True)

    if not args.skip_tls:
        result = subprocess.run(command + ["--jail-selftest"], capture_output=True, text=True, env={}, timeout=65)
        assert result.returncode == 0, result.stderr
        assert "DNS/system TLS passed" in result.stderr
        print("PASS production profile file/exec/egress denial and live DNS/system TLS", flush=True)
        profile = (ROOT / "src/seatbelt-proxy.sb").read_text()
        permission = '(allow mach-lookup (global-name "com.apple.trustd.agent"))'
        assert profile.count(permission) == 1
        with tempfile.TemporaryDirectory(prefix="coop-proxy-profile-") as directory:
            mutant = Path(directory) / "without-trustd.sb"
            mutant.write_text(profile.replace(permission, ""))
            restricted = command.copy()
            restricted[restricted.index("-f") + 1] = str(mutant)
            result = subprocess.run(restricted + ["--jail-selftest"], capture_output=True,
                                    text=True, env={}, timeout=65)
            assert result.returncode != 0, "trustd permission removal was not detected"
            assert "self-test failure category: NIOSSLError" in result.stderr, result.stderr
        print("PASS removing the exact trustd permission breaks the TLS gate", flush=True)



if __name__ == "__main__":
    main()
