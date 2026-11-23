#!/usr/bin/env python3
"""The managed-backend launcher (Sources/IsoHost/Inference/Resources/inference-launcher.py)
against a stand-in `mlx_lm` and `mlx` (secure-local-inference spec §20.3).

    python3 tests/test-inference-launcher.py

Checks the bearer check, Origin refusal, the challenge (closing and kept
alive), the per-session prompt cache, model pinning, memory limits, the
loopback bind and the version gate. No MLX, model or network is needed.
"""

import hashlib
import hmac
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
LAUNCHER = ROOT / "Sources/IsoHost/Inference/Resources/inference-launcher.py"
TOKEN = "ab" * 32
failures = []

FAKE_SERVER = r'''
import argparse, json, os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from queue import Queue

RECORD = os.environ["FAKE_RECORD"]

def note(**kw):
    with open(RECORD, "a") as f:
        f.write(json.dumps(kw) + "\n")

class LRUPromptCache:
    # mlx-lm 0.31's interface: one cache for every request, keyed by the
    # model key and a token prefix.
    def __init__(self, max_size=10, max_bytes=1 << 63):
        self.entries = {}
    def fetch_nearest_cache(self, model, tokens):
        best = max((len(t) for (m, t) in self.entries
                    if m == model and tuple(tokens[:len(t)]) == t), default=0)
        return (["kv"] if best else None), tokens[best:]
    def insert_cache(self, model, tokens, prompt_cache, *, cache_type="assistant"):
        self.entries[(model, tuple(tokens))] = prompt_cache

class ModelProvider:
    def __init__(self, args):
        self.args = args
        self.model_key = ("default_model", None, "default_model")
    def load(self, model_path, adapter_path=None, draft_model_path=None):
        note(load=[model_path, adapter_path, draft_model_path])

class CompletionRequest:
    def __init__(self, prompt):
        self.prompt = prompt

class ResponseGenerator:
    # One generator thread serves every request, as in mlx-lm.
    def __init__(self, model_provider, prompt_cache):
        self.model_provider = model_provider
        self.prompt_cache = prompt_cache
        self.requests = Queue()
        threading.Thread(target=self._generate, daemon=True).start()
    def _is_batchable(self, args):
        return True
    def _generate(self):
        while True:
            rqueue, request, args = self.requests.get()
            if self._is_batchable(args):
                note(batched=True)
            self._serve_single((rqueue, request, args))
    def _serve_single(self, request):
        rqueue, request, args = request
        tokens = request.prompt.split()
        _, rest = self.prompt_cache.fetch_nearest_cache(self.model_provider.model_key, tokens)
        self.prompt_cache.insert_cache(self.model_provider.model_key, tokens, ["kv"])
        rqueue.put(len(tokens) - len(rest))
    def generate(self, request, generation_args, progress_callback=None):
        rqueue = Queue()
        self.requests.put((rqueue, request, generation_args))
        return rqueue.get()

class APIHandler(BaseHTTPRequestHandler):
    def __init__(self, response_generator, *args, **kwargs):
        self.response_generator = response_generator
        super().__init__(*args, **kwargs)
    def _set_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.response_generator.model_provider.load(
            body.get("model"), body.get("adapters"), body.get("draft_model"))
        cached = self.response_generator.generate(CompletionRequest(body.get("prompt", "")), None)
        out = json.dumps({"cached_tokens": cached}).encode()
        self.send_response(200)
        self._set_cors_headers()
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *a):
        pass

def _run_http_server(host, port, response_generator, server_class=ThreadingHTTPServer,
                     handler_class=APIHandler):
    note(bind=host)
    server_class((host, port),
                 lambda *a, **k: handler_class(response_generator, *a, **k)).serve_forever()

def run(host, port, model_provider):
    prompt_cache = LRUPromptCache(10)
    _run_http_server(host, port, ResponseGenerator(model_provider, prompt_cache))

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model"); p.add_argument("--host"); p.add_argument("--port", type=int)
    p.add_argument("--log-level")
    args = p.parse_args()
    note(argv=vars(args))
    run(args.host, args.port, ModelProvider(args))
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


def request(port, method="POST", headers=None, body=None, path="/v1/chat/completions"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    data = json.dumps(body).encode() if body is not None else None
    connection.request(method, path, body=data, headers=headers or {})
    response = connection.getresponse()
    text = response.read()
    return response.status, dict(response.getheaders()), text


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
        status, headers, _ = request(port, headers=good, body=payload)
        check("the right token is served", status == 200)
        check("no CORS headers are sent", not any(k.lower().startswith("access-control") for k in headers))
        check("GET also needs the token", request(port, method="GET")[0] == 401)
        nonce = "5a" * 32
        status, headers, body = request(port, method="GET", path="/iso/challenge/" + nonce)
        expected = hmac.new(TOKEN.encode(), nonce.encode(), hashlib.sha256).hexdigest()
        check("the challenge answers the token's HMAC of the nonce without the token",
              status == 200 and body.decode() == expected)
        check("the challenge never echoes the token", TOKEN.encode() not in body)
        check("a malformed challenge needs the token",
              request(port, method="GET", path="/iso/challenge/xyz")[0] == 401)
        check("a challenge with a browser Origin is refused",
              request(port, method="GET", path="/iso/challenge/" + nonce,
                      headers={"origin": "https://evil.example"})[0] == 401)
        # A challenge asked with keep-alive leaves the connection open, and
        # the next request on it still needs the token.
        data = json.dumps(payload).encode()
        for auth, served in ((f"Authorization: Bearer {TOKEN}\r\n", 200), ("", 401)):
            kept = socket.create_connection(("127.0.0.1", port), timeout=5)
            kept.sendall(f"GET /iso/challenge/{nonce} HTTP/1.1\r\nHost: x\r\n"
                         "Connection: keep-alive\r\n\r\n".encode())
            reader = kept.makefile("rb")
            status_line = reader.readline()
            headers_seen = {}
            while (line := reader.readline()) not in (b"\r\n", b""):
                name, _, value = line.decode().partition(":")
                headers_seen[name.strip().lower()] = value.strip()
            answer = reader.read(int(headers_seen.get("content-length", "0")))
            kept.sendall(f"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n{auth}"
                         f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n"
                         .encode() + data)
            second = reader.readline()
            check(f"a kept-alive challenge, then a request on the same connection: {served}",
                  status_line.startswith(b"HTTP/1.0 200") and answer.decode() == expected
                  and headers_seen.get("connection") == "keep-alive"
                  and second.split(b" ")[1:2] == [str(served).encode()])
            reader.close()
            kept.close()
        closing = socket.create_connection(("127.0.0.1", port), timeout=5)
        closing.sendall(f"GET /iso/challenge/{nonce} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
        received = b""
        while chunk := closing.recv(4096):
            received += chunk
        closing.close()
        check("a challenge asked with Connection: close closes the connection",
              received.endswith(expected.encode()) and b"Connection: close" in received)

        def cached(partition, prompt="one two three four"):
            headers = dict(good)
            if partition is not None:
                headers["x-iso-cache-partition"] = partition
            status, _, text = request(port, headers=headers, body=dict(payload, prompt=prompt))
            return json.loads(text)["cached_tokens"] if status == 200 else status

        a, b = "a" * 32, "b" * 32
        check("a session's first prompt finds nothing cached", cached(a) == 0)
        check("another session's identical prompt reuses none of it", cached(b) == 0)
        check("no partition is a partition of its own", cached(None) == 0)
        check("the same session reuses its own prefix", cached(a, "one two three four five") == 4)
        check("a malformed partition is refused", cached("A" * 32) == 401)
        twice = dict(good, **{"x-iso-cache-partition": a})
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.putrequest("POST", "/v1/chat/completions")
        for name, value in twice.items():
            connection.putheader(name, value)
        connection.putheader("x-iso-cache-partition", b)
        data = json.dumps(payload).encode()
        connection.putheader("content-length", str(len(data)))
        connection.endheaders(data)
        check("two partitions are refused", connection.getresponse().status == 401)
        connection.close()

        records = [json.loads(line) for line in record.read_text().splitlines()]
        loads = [r["load"] for r in records if "load" in r]
        check("every load is pinned to the default model",
              loads and all(load == ["default_model", None, "default_model"] for load in loads))
        check("requests are never batched across sessions", not any("batched" in r for r in records))
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
