#!/usr/bin/env python3
"""Unprivileged regressions for controlled VM fixture cleanup."""
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
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fixture", ROOT / "tests/proxy_vm_forwarding.py")
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class FixtureCleanupTests(unittest.TestCase):
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
        with tempfile.TemporaryDirectory(prefix="coop-fixture-cleanup-") as temporary:
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
                self.assertFalse(cleanup.is_alive(), "idle TLS peer prevented cleanup")
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
