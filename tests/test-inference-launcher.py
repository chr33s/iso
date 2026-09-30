#!/usr/bin/env python3
"""The managed-backend launcher (Sources/IsoHost/inference-launcher.py)
against a stand-in `mlx_lm` and `mlx` (secure-local-inference spec §20.3).

    python3 tests/test-inference-launcher.py

Checks the bearer check, Origin refusal, model pinning, memory limits, the
loopback bind and the version gate. No MLX, model or network is needed.
"""

import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "Sources/IsoHost/inference-launcher.py"
TOKEN = "ab" * 32
failures = []

FAKE_SERVER = r'''
import argparse, json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RECORD = os.environ["FAKE_RECORD"]

def note(**kw):
    with open(RECORD, "a") as f:
        f.write(json.dumps(kw) + "\n")

class ModelProvider:
    def __init__(self, args):
        self.args = args
    def load(self, model_path, adapter_path=None, draft_model_path=None):
        note(load=[model_path, adapter_path, draft_model_path])

class APIHandler(BaseHTTPRequestHandler):
    def __init__(self, provider, *args, **kwargs):
        self.provider = provider
        super().__init__(*args, **kwargs)
    def _set_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.provider.load(body.get("model"), body.get("adapters"), body.get("draft_model"))
        self.send_response(200)
        self._set_cors_headers()
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *a):
        pass

def _run_http_server(host, port, provider, server_class=ThreadingHTTPServer, handler_class=APIHandler):
    note(bind=host)
    server_class((host, port), lambda *a, **k: handler_class(provider, *a, **k)).serve_forever()

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model"); p.add_argument("--host"); p.add_argument("--port", type=int)
    p.add_argument("--log-level")
    args = p.parse_args()
    note(argv=vars(args))
    _run_http_server(args.host, args.port, ModelProvider(args))
'''

FAKE_CORE = r'''
import json, os
def _note(**kw):
    with open(os.environ["FAKE_RECORD"], "a") as f:
        f.write(json.dumps(kw) + "\n")
def set_memory_limit(v): _note(memory_limit=v)
def set_wired_limit(v): _note(wired_limit=v)
'''


def check(label, condition):
    print(("  PASS  " if condition else "  FAIL  ") + label, flush=True)
    if not condition:
        failures.append(label)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def fake_modules(root, version):
    (root / "mlx_lm").mkdir(parents=True)
    (root / "mlx_lm/__init__.py").write_text(f'__version__ = "{version}"\n')
    (root / "mlx_lm/server.py").write_text(FAKE_SERVER)
    (root / "mlx").mkdir()
    (root / "mlx/__init__.py").write_text("")
    (root / "mlx/core.py").write_text(FAKE_CORE)


def request(port, method="POST", headers=None, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    data = json.dumps(body).encode() if body is not None else None
    connection.request(method, "/v1/chat/completions", body=data, headers=headers or {})
    response = connection.getresponse()
    response.read()
    return response.status, dict(response.getheaders())


def main():
    work = Path(tempfile.mkdtemp(prefix="iso-launcher-"))
    modules = work / "modules"
    fake_modules(modules, "0.31.3")
    model = work / "model"
    model.mkdir()
    token_file = work / "token"
    token_file.write_text(TOKEN + "\n")
    record = work / "record.jsonl"
    port = free_port()
    env = dict(os.environ, PYTHONPATH=str(modules), FAKE_RECORD=str(record))
    process = subprocess.Popen(
        [sys.executable, str(LAUNCHER), "--model", str(model), "--port", str(port),
         "--token-file", str(token_file), "--memory-limit", str(8 << 30)],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        good = {"authorization": f"Bearer {TOKEN}", "content-type": "application/json"}
        payload = {"model": "/etc/evil", "adapters": "/tmp/x", "draft_model": "/tmp/y", "messages": []}
        check("no token is refused (401)", request(port, body=payload)[0] == 401)
        check("a wrong token is refused (401)",
              request(port, headers={"authorization": "Bearer " + "0" * 64}, body=payload)[0] == 401)
        check("a browser Origin is refused (401)",
              request(port, headers=dict(good, origin="https://evil.example"), body=payload)[0] == 401)
        check("OPTIONS is refused", request(port, method="OPTIONS", headers=good)[0] == 401)
        status, headers = request(port, headers=good, body=payload)
        check("the right token is served", status == 200)
        check("no CORS headers are sent", not any(k.lower().startswith("access-control") for k in headers))
        check("GET also needs the token", request(port, method="GET")[0] == 401)
        records = [json.loads(line) for line in record.read_text().splitlines()]
        loads = [r["load"] for r in records if "load" in r]
        check("every load is pinned to the default model",
              loads == [["default_model", None, "default_model"]])
        check("the server binds 127.0.0.1", {"bind": "127.0.0.1"} in records)
        argv = next(r["argv"] for r in records if "argv" in r)
        check("the server gets the model, loopback and the port only",
              argv == {"model": str(model), "host": "127.0.0.1", "port": port, "log_level": "WARNING"})
        check("the memory limit is applied", {"memory_limit": 8 << 30} in records)
    finally:
        process.kill()
        process.wait()

    fake_modules(work / "old", "0.30.0")
    old = subprocess.run(
        [sys.executable, str(LAUNCHER), "--model", str(model), "--port", str(free_port()),
         "--token-file", str(token_file)],
        env=dict(env, PYTHONPATH=str(work / "old")), capture_output=True, text=True, timeout=30)
    check("an unqualified mlx-lm version is refused", old.returncode != 0 and "not qualified" in old.stderr)
    token_file.write_text("short\n")
    bad = subprocess.run(
        [sys.executable, str(LAUNCHER), "--model", str(model), "--port", str(free_port()),
         "--token-file", str(token_file)], env=env, capture_output=True, text=True, timeout=30)
    check("a malformed token file is refused", bad.returncode != 0)
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
