"""Controlled TLS fixture shared by the host preflight and real-VM gate."""
import concurrent.futures
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
        self.active = set()
        self.active_lock = threading.Lock()

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
        try:
            request.do_handshake()
        except OSError:
            self.shutdown_request(request)
            return
        super().process_request_thread(request, client_address)

    def shutdown_request(self, request):
        with self.active_lock:
            self.active.discard(request)
        super().shutdown_request(request)

    def server_close(self):
        with self.active_lock:
            active = list(self.active)
        for connection in active:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        super().server_close()


def https_listener(work, log):
    """Use sudo only for bind; TLS and HTTP run as the calling user."""
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind(("127.0.0.1", 443))
        listener.listen(8)
        return listener
    except PermissionError:
        listener.close()
    with tempfile.TemporaryDirectory(prefix="coop-bind-", dir="/tmp") as directory, socket.socket(socket.AF_UNIX) as control:
        path = Path(directory) / "bind.sock"
        control.bind(str(path))
        control.listen(1)
        control.settimeout(5)
        try:
            subprocess.run(["sudo", "-n", "/usr/bin/python3",
                            str(ROOT / "tests/fixtures/credential-proxy/bind-test-https.py"), str(path)],
                           check=True, stdout=log, stderr=log, timeout=10)
            peer, _ = control.accept()
            with peer:
                peer.settimeout(5)
                _, ancillary, flags, _ = peer.recvmsg(32, socket.CMSG_SPACE(array.array("i").itemsize))
            assert not flags & socket.MSG_CTRUNC
            descriptors = array.array("i")
            for level, kind, data in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    descriptors.frombytes(data)
            assert len(descriptors) == 1
            return socket.socket(fileno=descriptors[0])
        finally:
            path.unlink(missing_ok=True)


def exercise(work, provider, port, token, credential, guest_command, log):
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
                assert self.path == path
                assert self.headers.get_all("Host") == ["api." + provider + ".com"]
                assert self.headers.get_all("Authorization") == ["Bearer " + credential]
                assert self.headers.get("x-api-key") is None
                assert self.headers.get("x-private") is None
                length = int(self.headers["Content-Length"])
                assert length == len(BODY)
                body = self.rfile.read(length)
                assert body == BODY
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
    server = ControlledTLSServer(https_listener(work, log), context, Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    fixture = None
    guest = None
    try:
        directory = subprocess.check_output(
            ["swift", "build", "--package-path", str(ROOT / "coop-proxy"), "--show-bin-path"], text=True).strip()
        xctest = subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
        bundle = Path(directory) / "CoopProxyTransportTests.xctest"
        command = ["/usr/bin/sandbox-exec", "-D", "PROXY_BIN=" + str(Path(xctest).resolve()),
                   "-f", str(ROOT / "src/seatbelt-proxy.sb"), xctest,
                   "-XCTest", "CoopProxyTransportTests.VMProxyFixture/testServe", str(bundle)]
        fixture = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=log, stderr=log,
                                   env={"COOP_VM_FIXTURE_CA": str(work / "forward_ca.der")}, start_new_session=True)
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
                assert first.result(timeout=20).strip() == "VM_GUEST_FIRST"
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
        for process in [guest, fixture]:
            stop_process_group(process)
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
