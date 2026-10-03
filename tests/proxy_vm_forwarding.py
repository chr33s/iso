"""Controlled TLS fixture shared by the host preflight and real-VM gate."""
import concurrent.futures
import contextlib
import array
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import socket
import ssl
import subprocess
import threading
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BODY = b"vm-stream-request-" * 4096
FIRST = b"data: first\n\n"
LAST = b"data: last\n\n"
GUEST = r'''
import hashlib, http.client, json, sys
value = json.load(sys.stdin)
body = b"vm-stream-request-" * 4096
connection = http.client.HTTPConnection("127.0.0.1", value["port"], timeout=20)
connection.putrequest("POST", value["path"], skip_host=True)
connection.putheader("Host", "guest.invalid")
connection.putheader("Authorization", "Bearer " + value["token"])
connection.putheader("Content-Length", str(len(body)))
connection.putheader("Connection", "x-private")
connection.putheader("x-private", "must-disappear")
connection.endheaders()
for offset in range(0, len(body), 1024):
    connection.send(body[offset:offset + 1024])
response = connection.getresponse()
assert response.status == 200, response.status
first = response.readline() + response.readline()
assert first == b"data: first\n\n", first
print("VM_GUEST_FIRST", flush=True)
rest = response.read()
assert rest == b"data: last\n\n", rest
print(json.dumps({"response_sha256": hashlib.sha256(first + rest).hexdigest()}), flush=True)
connection.close()
'''


def stop_process_group(process):
    if process is None:
        return
    # Every caller starts a private session. Descendants may retain stdout even
    # after the direct child exits, so do not gate group cleanup on poll().
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin can report EPERM for a group whose last process has exited.
        # Do not suppress a denial while the owned child is still running.
        if process.poll() is None:
            raise
    process.wait(timeout=5)


class ControlledTLSServer(http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, listener, context, handler):
        super().__init__(listener.getsockname(), handler, bind_and_activate=False)
        self.socket.close()
        self.socket = listener
        self.context = context
        self.server_name = "localhost"
        self.server_port = listener.getsockname()[1]
        self.failures = queue.Queue()
        self.active = set()
        self.active_lock = threading.Lock()
        self.closing = threading.Event()

    def get_request(self):
        connection, address = self.socket.accept()
        connection.settimeout(5)
        try:
            connection = self.context.wrap_socket(
                connection, server_side=True, do_handshake_on_connect=False)
        except BaseException:
            connection.close()
            raise
        with self.active_lock:
            self.active.add(connection)
        return connection, address

    def process_request_thread(self, request, client_address):
        # Poll so server_close() never depends on another thread's shutdown()
        # waking a blocked handshake read, which is platform-dependent.
        deadline = time.monotonic() + 5
        try:
            request.settimeout(.1)
            while True:
                try:
                    request.do_handshake()
                    break
                except socket.timeout:
                    if self.closing.is_set() or time.monotonic() > deadline:
                        raise
            request.settimeout(5)
        except OSError as error:
            self.failures.put(RuntimeError("controlled upstream TLS handshake failed: " + type(error).__name__))
            self.shutdown_request(request)
            return
        super().process_request_thread(request, client_address)

    def shutdown_request(self, request):
        with self.active_lock:
            self.active.discard(request)
        super().shutdown_request(request)

    def server_close(self):
        self.closing.set()
        with self.active_lock:
            active = list(self.active)
        for connection in active:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        super().server_close()


@contextlib.contextmanager
def https_listener(work, log, *, interactive=False):
    """Reserve HTTPS and keep its socket creator alive until the lease ends."""
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", 443))
        except PermissionError:
            pass
        else:
            listener.listen(8)
            yield listener
            return
    with tempfile.TemporaryDirectory(prefix="iso-bind-", dir="/tmp") as directory, socket.socket(socket.AF_UNIX) as control:
        path = Path(directory) / "bind.sock"
        control.bind(str(path))
        control.listen(1)
        control.settimeout(0.2)
        helper = subprocess.Popen(
            ["sudo", *([] if interactive else ["-n"]), "/usr/bin/python3",
             str(ROOT / "tests/fixtures/credential-proxy/bind-test-https.py"), str(path)],
            stdout=log, stderr=None if interactive else log)
        peer = None
        try:
            deadline = time.monotonic() + (120 if interactive else 10)
            while peer is None:
                try:
                    peer, _ = control.accept()
                except socket.timeout:
                    if helper.poll() is not None:
                        raise RuntimeError("HTTPS bind helper exited before socket handoff; inspect run.log")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("HTTPS bind helper handoff timed out")
            peer.settimeout(5)
            _, ancillary, flags, _ = peer.recvmsg(32, socket.CMSG_SPACE(array.array("i").itemsize))
            descriptors = array.array("i")
            for level, kind, data in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    descriptors.frombytes(data)
            with contextlib.ExitStack() as received:
                sockets = [received.enter_context(socket.socket(fileno=fd)) for fd in descriptors]
                assert not flags & socket.MSG_CTRUNC and len(sockets) == 1
                yield sockets[0]
        finally:
            if peer is not None:
                peer.close()
            control.close()
            path.unlink(missing_ok=True)
            try:
                helper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # The sudo monitor may still be waiting for authentication.
                helper.terminate()
                helper.wait(timeout=5)


def exercise(work, provider, port, token, credential, guest_command, log, *, listener):
    """One admitted operation; host releases the last SSE event only after guest ACK."""
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    subprocess.run(["python3", str(ROOT / "tests/fixtures/credential-proxy/generate-forwarding-certificates.py"), str(work)],
                   check=True, stdout=log, stderr=log)
    for source, kind, destination in [("forward_leaf.der", "x509", "leaf.pem"),
                                      ("forward_leaf.pkcs8.der", "pkey", "key.pem")]:
        subprocess.run(["openssl", kind, "-inform", "DER", "-in", str(work / source),
                        "-out", str(work / destination)], check=True, stdout=log, stderr=log)
    path = "/v1/messages?vm=1" if provider == "anthropic" else "/v1/responses?vm=1"
    release = threading.Event()
    observed = queue.Queue()
    names = queue.Queue()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                self.connection.settimeout(20)
                assert self.path == path, "upstream path mismatch"
                assert self.headers.get_all("Host") == ["api." + provider + ".com"], "upstream Host mismatch"
                assert self.headers.get_all("Authorization") == ["Bearer " + credential], "upstream credential mismatch"
                assert self.headers.get("x-api-key") is None, "unexpected upstream API key header"
                assert self.headers.get("x-private") is None, "nominated header reached upstream"
                length = int(self.headers["Content-Length"])
                assert length == len(BODY), "upstream body length mismatch"
                body = self.rfile.read(length)
                assert body == BODY, "upstream body content mismatch"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(FIRST) + len(LAST)))
                self.end_headers()
                self.wfile.write(FIRST)
                self.wfile.flush()
                assert release.wait(20), "guest did not receive first event before response completion"
                self.wfile.write(LAST)
                self.wfile.flush()
                observed.put({"provider": provider, "request_sha256": hashlib.sha256(body).hexdigest()})
            except BaseException as error:
                observed.put(error)
                self.close_connection = True

    # Seatbelt permits only 443/53. Never change the production profile for fixtures.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / "leaf.pem", work / "key.pem")
    context.set_servername_callback(lambda _socket, name, _context: names.put(name))
    # Each provider owns a duplicate; closing its server preserves the reserved
    # listener so later phases never need to authenticate to sudo again.
    server = ControlledTLSServer(
        listener.dup(), context, Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    fixture = None
    guest = None
    try:
        directory = subprocess.check_output(
            ["swift", "build", "--package-path", str(ROOT / "iso-proxy"), "--show-bin-path"], text=True).strip()
        xctest = subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
        bundle = Path(directory) / "IsoProxyTransportTests.xctest"
        command = ["/usr/bin/sandbox-exec", "-D", "PROXY_BIN=" + str(Path(xctest).resolve()),
                   "-f", str(ROOT / "Sources/IsoHost/Guest/Resources/seatbelt-proxy.sb"), xctest,
                   "-XCTest", "IsoProxyTransportTests.VMProxyFixture/testServe", str(bundle)]
        fixture = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=log, stderr=log,
                                   env={"ISO_VM_FIXTURE_CA": str(work / "forward_ca.der")}, start_new_session=True)
        startup = {"version": 1, "listen": "127.0.0.1:" + str(port), "provider": provider,
                   "capability_token": token, "injection": {"scheme": "bearer", "credential": credential}}
        fixture.stdin.write(json.dumps(startup).encode())
        fixture.stdin.close()
        deadline = time.monotonic() + 15
        while True:
            assert fixture.poll() is None, "confined fixture exited before readiness"
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2) as peer:
                    peer.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
                    assert peer.recv(1024).startswith(b"HTTP/1.1 401")
                    break
            except (ConnectionError, TimeoutError):
                assert time.monotonic() < deadline, "fixture readiness timed out"
                time.sleep(0.05)
        guest_env = {key: os.environ[key] for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] if key in os.environ}
        guest_env["PATH"] = "/usr/bin:/bin"
        guest = subprocess.Popen(guest_command + ["python3", "-c", GUEST], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=log, text=True, env=guest_env, start_new_session=True)
        guest.stdin.write(json.dumps({"port": port, "path": path, "token": token}))
        guest.stdin.close()
        guest.stdin = None
        # Bounded wait: an aggregating bridge cannot obtain the final event.
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as readers:
            first = readers.submit(guest.stdout.readline)
            try:
                if first.result(timeout=20).strip() != "VM_GUEST_FIRST":
                    # Give XCTest time to emit the client-side TLS error before
                    # cleanup terminates it. The wait remains bounded.
                    try:
                        fixture.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        pass
                    for failures in [observed, server.failures]:
                        try:
                            failure = failures.get_nowait()
                        except queue.Empty:
                            continue
                        if isinstance(failure, BaseException):
                            raise failure
                    raise RuntimeError("guest exited before first SSE event; inspect guest stderr in run.log")
            except BaseException:
                stop_process_group(guest)
                raise
            finally:
                release.set()
        stdout, _ = guest.communicate(timeout=25)
        assert guest.returncode == 0, "guest streaming request failed"
        response = json.loads(stdout)
        assert response["response_sha256"] == hashlib.sha256(FIRST + LAST).hexdigest()
        observation = observed.get(timeout=5)
        if isinstance(observation, BaseException):
            raise observation
        assert names.get(timeout=5) == "api." + provider + ".com", "guest changed SNI"
        assert fixture.wait(timeout=10) == 0, "confined fixture failed"
        return dict(observation, **response, first_event_before_completion=True)
    finally:
        release.set()
        # Attempt every cleanup even when one process refuses a signal.
        with contextlib.ExitStack() as cleanup:
            cleanup.callback(thread.join, timeout=5)
            cleanup.callback(server.server_close)
            cleanup.callback(server.shutdown)
            for process in [fixture, guest]:
                cleanup.callback(stop_process_group, process)
