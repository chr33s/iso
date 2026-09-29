#!/usr/bin/env python3
"""Opt-in live API smoke through a confined Swift proxy; credential on stdin only.

Uses three generation requests (stream, disconnect, recovery), plus Anthropic
count_tokens. Does not run agents or prove provider-side cancellation billing.
"""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import resource
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
MAX_EVENT = 64 * 1024
MAX_STREAM = 2 * 1024 * 1024


class SmokeFailure(Exception):
    pass


def events(response):
    """Read bounded SSE JSON records, without retaining or printing text."""
    total = 0
    data = []
    size = 0
    while True:
        line = response.readline(MAX_EVENT + 1)
        total += len(line)
        if len(line) > MAX_EVENT or total > MAX_STREAM:
            raise SmokeFailure("stream exceeded smoke-test budget")
        if not line:
            if data:
                raise SmokeFailure("truncated SSE event")
            return
        line = line.rstrip(b"\r\n")
        if not line:
            if data:
                value = json.loads(b"\n".join(data))
                if not isinstance(value, dict):
                    raise SmokeFailure("invalid SSE record")
                yield value
            data, size = [], 0
        elif line.startswith(b"data:"):
            value = line[5:].lstrip(b" ")
            size += len(value)
            if size > MAX_EVENT:
                raise SmokeFailure("SSE event exceeded smoke-test budget")
            data.append(value)


def inspect_stream(response, provider, cancel=False):
    if response.status != 200:
        raise SmokeFailure(f"provider HTTP status {response.status}")
    if response.getheader("Content-Type", "").split(";", 1)[0].strip() != "text/event-stream":
        raise SmokeFailure("provider did not return SSE")
    count = 0
    text_deltas = 0
    terminal = "message_stop" if provider == "anthropic" else "response.completed"
    for event in events(response):
        count += 1
        kind = event.get("type")
        if kind in {"error", "response.failed", "response.incomplete"}:
            raise SmokeFailure("provider stream failed or was incomplete")
        delta = None
        if provider == "anthropic" and kind == "content_block_delta":
            value = event.get("delta")
            if isinstance(value, dict) and value.get("type") == "text_delta":
                delta = value.get("text")
        elif provider == "openai" and kind == "response.output_text.delta":
            delta = event.get("delta")
        if isinstance(delta, str) and delta:
            text_deltas += 1
            if cancel:
                return {"events": count, "text_deltas": text_deltas, "client_disconnect": True}
        if kind == terminal:
            if not text_deltas:
                raise SmokeFailure("stream completed without text")
            return {"events": count, "text_deltas": text_deltas, "completed": True}
    raise SmokeFailure("stream ended before completion")


def payload(provider, model, tokens, cancel=False):
    prompt = "Count from 1 to 100, one number per line." if cancel else "Reply with exactly the word OK."
    if provider == "anthropic":
        return {"model": model, "messages": [{"role": "user", "content": prompt}],
                "max_tokens": tokens, "stream": True}
    return {"model": model, "input": prompt, "max_output_tokens": tokens,
            "stream": True, "store": False}


def request(port, token, path, body):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        connection.request("POST", path, json.dumps(body), {
            "Authorization": "Bearer " + token, "Content-Type": "application/json",
            "anthropic-version": "2023-06-01", "Connection": "close"})
        return connection, connection.getresponse()
    except BaseException:
        connection.close()
        raise


class OutputAudit:
    def __init__(self, pipes, needles):
        self.leaked = False
        self.overflow = False
        self.threads = []
        for pipe in pipes:
            worker = threading.Thread(target=self.read, args=(pipe, needles), daemon=True)
            worker.start()
            self.threads.append(worker)

    def read(self, pipe, needles):
        tail = b""
        total = 0
        overlap = max(map(len, needles)) - 1
        try:
            while True:
                chunk = pipe.read(4096)
                if not chunk:
                    break
                total += len(chunk)
                if total > 65536:
                    self.overflow = True
                data = tail + chunk
                if any(value in data for value in needles):
                    self.leaked = True
                tail = data[-overlap:] if overlap else b""
        finally:
            pipe.close()

    def check(self):
        for worker in self.threads:
            worker.join(timeout=5)
            if worker.is_alive():
                raise SmokeFailure("proxy output pipe did not close")
        if self.leaked or self.overflow:
            raise SmokeFailure("proxy output failed secret/budget audit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=["anthropic", "openai"], required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--scheme", choices=["bearer", "x_api_key"], default="bearer")
    parser.add_argument("--max-output-tokens", type=int, default=256)
    parser.add_argument("--binary", type=Path, default=ROOT / "iso-proxy/.build/debug/iso-proxy-swift",
                        help="Swift proxy executable (swift build --package-path iso-proxy)")
    args = parser.parse_args()
    if not 16 <= args.max_output_tokens <= 1024:
        parser.error("output token budget must be 16..1024 per generation request")
    if args.provider == "openai" and args.scheme != "bearer":
        parser.error("OpenAI requires bearer injection")
    if sys.stdin.isatty():
        parser.error("pipe a dedicated credential into stdin; do not type it interactively")
    def timeout(_signal, _frame):
        raise SmokeFailure("live smoke exceeded its 180-second deadline")
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(180)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    raw = sys.stdin.buffer.read(65537)
    if len(raw) > 65536:
        raise SmokeFailure("credential exceeds startup budget")
    credential = raw.decode().rstrip("\r\n")
    if not credential or any(ord(char) < 32 or ord(char) > 126 for char in credential):
        raise SmokeFailure("invalid credential input")
    token = secrets.token_hex(32)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    binary = args.binary.resolve(strict=True)
    command = ["/usr/bin/sandbox-exec", "-D", "PROXY_BIN=" + str(binary),
               "-f", str(ROOT / "Sources/IsoHost/seatbelt-proxy.sb"), str(binary)]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env={}, start_new_session=True)
    audit = OutputAudit([child.stdout, child.stderr], [credential.encode(), token.encode()])
    records = []
    try:
        config = {"version": 1, "listen": f"127.0.0.1:{port}", "provider": args.provider,
                  "capability_token": token, "injection": {"scheme": args.scheme, "credential": credential}}
        child.stdin.write(json.dumps(config).encode())
        child.stdin.close()
        deadline = time.monotonic() + 5
        while True:
            if child.poll() is not None:
                raise SmokeFailure("confined proxy exited before readiness")
            probe = http.client.HTTPConnection("127.0.0.1", port, timeout=.2)
            try:
                probe.request("GET", "/")
                if probe.getresponse().status != 401:
                    raise SmokeFailure("proxy readiness did not reject unauthenticated request")
                break
            except (ConnectionError, TimeoutError) as error:
                if time.monotonic() >= deadline:
                    raise SmokeFailure("proxy readiness deadline: " + type(error).__name__)
                time.sleep(.03)
            finally:
                probe.close()
        if args.provider == "anthropic":
            body = payload(args.provider, args.model, args.max_output_tokens)
            body.pop("max_tokens")
            body.pop("stream")
            connection, response = request(port, token, "/v1/messages/count_tokens", body)
            try:
                if response.status != 200:
                    raise SmokeFailure(f"token count HTTP status {response.status}")
                value = response.read(MAX_EVENT + 1)
                if len(value) > MAX_EVENT:
                    raise SmokeFailure("token count response exceeded budget")
                count = json.loads(value).get("input_tokens")
                if type(count) is not int or count <= 0:
                    raise SmokeFailure("invalid token count response")
                records.append({"phase": "count_tokens", "input_tokens": count})
            finally:
                response.close()
                connection.close()
        path = "/v1/messages" if args.provider == "anthropic" else "/v1/responses"
        for phase in ["stream", "disconnect", "recovery"]:
            connection, response = request(port, token, path,
                payload(args.provider, args.model, args.max_output_tokens, phase == "disconnect"))
            try:
                observation = inspect_stream(response, args.provider, phase == "disconnect")
                records.append(dict(phase=phase, **observation))
            finally:
                response.close()
                connection.close()
        child.terminate()
        if child.wait(timeout=5) != 0:
            raise SmokeFailure("proxy shutdown failed")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        audit.check()
        signal.alarm(0)
    print(json.dumps({"provider": args.provider, "proxy_binary": binary.name,
                      "proxy_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                      "model": args.model, "max_output_tokens": args.max_output_tokens,
                      "phases": records, "secret_free_proxy_output": True}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Provider/HTTP/JSON exceptions can embed credential-bearing response
        # content. Print only our controlled messages or the exception class.
        message = str(error) if isinstance(error, SmokeFailure) else type(error).__name__
        print("Live proxy smoke failed: " + message, file=sys.stderr)
        sys.exit(1)
