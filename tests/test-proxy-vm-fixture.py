#!/usr/bin/env python3
"""Unprivileged regressions for controlled VM fixtures and egress pressure."""
import concurrent.futures
import http.server
import importlib.util
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fixture", ROOT / "tests/proxy_vm_forwarding.py")
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)
PRESSURE_SPEC = importlib.util.spec_from_file_location(
    "pressure", ROOT / "tests/fixtures/credential-proxy/egress-pressure.py")
pressure = importlib.util.module_from_spec(PRESSURE_SPEC)
PRESSURE_SPEC.loader.exec_module(pressure)


class EgressPressureTests(unittest.TestCase):
    REFUSAL = (b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n"
               b"Connection: close\r\n\r\n")

    def test_complete_refusal_accepts_eof_or_reset(self):
        for ending in (b"", ConnectionResetError()):
            with self.subTest(ending=ending):
                connection = mock.Mock()
                connection.recv.side_effect = [b"H", self.REFUSAL[:20], self.REFUSAL[20:], ending]
                with mock.patch.object(pressure.select, "select", return_value=([connection], [], [])):
                    self.assertEqual(pressure.active([connection], allow_refusal=True), [])

    def test_reset_does_not_hide_incomplete_or_invalid_refusal(self):
        for response in (b"", self.REFUSAL[:-1], self.REFUSAL.replace(b"403", b"200")):
            with self.subTest(response=response):
                connection = mock.Mock()
                connection.recv.side_effect = [b"H", response, ConnectionResetError()]
                with mock.patch.object(pressure.select, "select", return_value=([connection], [], [])):
                    with self.assertRaisesRegex(AssertionError, "unexpected head-timeout response"):
                        pressure.active([connection], allow_refusal=True)


class FixtureCleanupTests(unittest.TestCase):
    def test_bind_helper_lives_until_listener_lease_closes(self):
        child_code = """import os,runpy,socket,sys
from unittest import mock
helper, endpoint = sys.argv[1:]
sys.argv = [helper, endpoint]
os.environ.update(SUDO_UID=str(os.getuid()), SUDO_GID=str(os.getgid()))
real_bind = socket.socket.bind
def bind(sock, address):
    return real_bind(sock, ('127.0.0.1', 0) if address == ('127.0.0.1', 443) else address)
with mock.patch.object(os, 'geteuid', return_value=0), mock.patch.object(socket.socket, 'bind', bind), \
     mock.patch.object(os, 'setgroups') as groups, mock.patch.object(os, 'setgid') as gid, \
     mock.patch.object(os, 'setuid') as uid:
    runpy.run_path(helper, run_name='__main__')
    groups.assert_called_once_with([])
    gid.assert_called_once_with(os.getgid())
    uid.assert_called_once_with(os.getuid())
"""
        real_bind = socket.socket.bind
        real_popen = subprocess.Popen
        children = []
        def bind(sock, address):
            if address == ("127.0.0.1", 443):
                raise PermissionError("test requires helper path")
            return real_bind(sock, address)
        def spawn(command, **kwargs):
            child = real_popen([sys.executable, "-c", child_code, *command[-2:]], **kwargs)
            children.append(child)
            return child
        with tempfile.TemporaryDirectory() as temporary, open(os.devnull, "w") as log:
            try:
                with mock.patch.object(socket.socket, "bind", bind), mock.patch.object(fixture.subprocess, "Popen", spawn):
                    with fixture.https_listener(Path(temporary), log) as listener:
                        self.assertEqual(len(children), 1)
                        with self.assertRaises(subprocess.TimeoutExpired):
                            children[0].wait(timeout=0.2)
                        with socket.create_connection(listener.getsockname(), timeout=1):
                            peer, _ = listener.accept()
                            peer.close()
                    self.assertEqual(children[0].poll(), 0)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)

    def test_exited_group_permission_error_is_reaped(self):
        process = mock.Mock(pid=123, poll=mock.Mock(return_value=1))
        with mock.patch.object(fixture.os, "killpg", side_effect=PermissionError):
            fixture.stop_process_group(process)
        process.wait.assert_called_once_with(timeout=5)

    def test_live_group_permission_error_is_not_suppressed(self):
        process = mock.Mock(pid=123, poll=mock.Mock(return_value=None))
        with mock.patch.object(fixture.os, "killpg", side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                fixture.stop_process_group(process)
        process.wait.assert_not_called()

    def test_reserved_listener_survives_sequential_provider_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="iso-reserved-listener-") as directory:
            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                reserved.listen(8)
                address = reserved.getsockname()
                for provider in ["openai", "anthropic"]:
                    # Fail after server startup: exercise must clean up its
                    # duplicate without consuming the caller's reservation.
                    with mock.patch.object(fixture.subprocess, "check_output",
                                           side_effect=RuntimeError("fixture startup failure")):
                        with self.assertRaisesRegex(RuntimeError, "fixture startup failure"):
                            fixture.exercise(Path(directory) / provider, provider, 0,
                                             "0" * 64, "synthetic", [], sys.stderr,
                                             listener=reserved)
                    self.assertEqual(reserved.getsockname(), address)
            with socket.socket() as probe:
                probe.bind(address)

    def test_cleanup_closes_descendant_stdout(self):
        command = "import subprocess,sys,time; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print(child.pid,flush=True); time.sleep(60)"
        process = subprocess.Popen([sys.executable, "-c", command], stdout=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            self.assertGreater(int(process.stdout.readline()), 0)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as readers:
                pending = readers.submit(process.stdout.read)
                try:
                    fixture.stop_process_group(process)
                    self.assertEqual(pending.result(timeout=1), "")
                finally:
                    # Independent cleanup also bounds deliberately broken variants.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        finally:
            process.wait(timeout=5)
            process.stdout.close()

    def test_idle_tls_peer_does_not_block_accept_or_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="iso-fixture-cleanup-") as temporary:
            work = Path(temporary)
            subprocess.run([sys.executable, str(ROOT / "tests/fixtures/credential-proxy/generate-forwarding-certificates.py"), str(work)], check=True)
            for source, kind, destination in [("forward_leaf.der", "x509", "leaf.pem"),
                                              ("forward_leaf.pkcs8.der", "pkey", "key.pem")]:
                subprocess.run(["openssl", kind, "-inform", "DER", "-in", str(work / source),
                                "-out", str(work / destination)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(work / "leaf.pem", work / "key.pem")
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(204)
                    self.end_headers()
                def log_message(self, *_):
                    pass
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen(8)
            server = fixture.ControlledTLSServer(listener, context, Handler)
            serving = threading.Thread(target=server.serve_forever, daemon=True)
            serving.start()
            idle = socket.create_connection(listener.getsockname(), timeout=2)
            cleanup = None
            try:
                deadline = time.monotonic() + 2
                while True:
                    with server.active_lock:
                        if server.active:
                            break
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.01)
                client = ssl.create_default_context()
                client.load_verify_locations(cadata=ssl.DER_cert_to_PEM_cert((work / "forward_ca.der").read_bytes()))
                with socket.create_connection(listener.getsockname(), timeout=2) as raw:
                    with client.wrap_socket(raw, server_hostname="api.openai.com") as peer:
                        peer.sendall(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
                        self.assertIn(b" 204 ", peer.recv(1024))
                def close():
                    server.shutdown()
                    server.server_close()
                cleanup = threading.Thread(target=close, daemon=True)
                cleanup.start()
                cleanup.join(timeout=2)
                if cleanup.is_alive():
                    stacks = "".join(
                        f"\n--- {thread.name}\n" + "".join(traceback.format_stack(sys._current_frames()[thread.ident]))
                        for thread in threading.enumerate() if thread.ident in sys._current_frames())
                    self.fail("idle TLS peer prevented cleanup" + stacks)
            finally:
                idle.close()
                if cleanup:
                    cleanup.join(timeout=6)
                else:
                    server.shutdown()
                    server.server_close()
                serving.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
