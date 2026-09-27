#!/usr/bin/env python3
"""Offline assertions for the live smoke runner; never contacts a provider."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("live", ROOT / "scripts/test-proxy-live.py")
live = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live)


class Response(io.BytesIO):
    status = 200
    def getheader(self, _name, _default):
        return "text/event-stream; charset=utf-8"


def response(*events):
    return Response(b"".join(b"data: " + json.dumps(value).encode() + b"\n\n" for value in events))


class LiveSmokeTests(unittest.TestCase):
    def test_orchestration_against_synthetic_loopback_process(self):
        server = r'''
import http.server,json,signal,socketserver,sys
config=json.load(sys.stdin)
token=config["capability_token"]
provider=config["provider"]
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*args): pass
    def do_GET(self):
        self.send_response(401); self.send_header("Content-Length","0"); self.end_headers()
    def do_POST(self):
        assert self.headers["Authorization"] == "Bearer " + token
        body=json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["model"] == "offline-model"
        if self.path == "/v1/messages/count_tokens":
            assert provider == "anthropic" and "stream" not in body and "max_tokens" not in body
            data=b'{"input_tokens":7}'
            content_type="application/json"
        else:
            expected="/v1/messages" if provider == "anthropic" else "/v1/responses"
            assert self.path == expected and body["stream"]
            if provider == "anthropic":
                assert body["max_tokens"] == 256
                values=[{"type":"content_block_delta","delta":{"type":"text_delta","text":"OK"}}, {"type":"message_stop"}]
            else:
                assert body["max_output_tokens"] == 256 and body["store"] is False
                values=[{"type":"response.output_text.delta","delta":"OK"}, {"type":"response.completed"}]
            data=b''.join(b'data: '+json.dumps(value).encode()+b'\n\n' for value in values)
            content_type="text/event-stream"
        self.send_response(200); self.send_header("Content-Type",content_type)
        self.send_header("Content-Length",str(len(data))); self.send_header("Connection","close")
        self.end_headers(); self.wfile.write(data)
signal.signal(signal.SIGTERM,lambda *_: sys.exit(0))
class Server(http.server.HTTPServer):
    # Skip HTTPServer's reverse DNS lookup; it stalls before listen() on macOS CI runners.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name,self.server_port="localhost",self.server_address[1]
Server(("127.0.0.1",int(config["listen"].rsplit(":",1)[1])),Handler).serve_forever()
'''
        original = subprocess.Popen
        for provider in ["anthropic", "openai"]:
            def spawn(command, **kwargs):
                self.assertEqual(kwargs["env"], {})
                self.assertNotIn("offline-credential", " ".join(command))
                return original([sys.executable, "-c", server], **kwargs)
            output = io.StringIO()
            stdin = io.TextIOWrapper(io.BytesIO(b"offline-credential\n"))
            arguments = ["live", "--provider", provider, "--model", "offline-model", "--binary", sys.executable]
            with patch.object(live.subprocess, "Popen", side_effect=spawn), \
                 patch("sys.argv", arguments), patch("sys.stdin", stdin), redirect_stdout(output):
                live.main()
            report = json.loads(output.getvalue())
            self.assertTrue(report["secret_free_proxy_output"])
            phases = [item["phase"] for item in report["phases"]]
            self.assertEqual(phases, (["count_tokens"] if provider == "anthropic" else []) +
                             ["stream", "disconnect", "recovery"])

    def test_requires_text_and_provider_completion(self):
        for provider, delta, done in [
            ("openai", {"type": "response.output_text.delta", "delta": "OK"}, {"type": "response.completed"}),
            ("anthropic", {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "OK"}}, {"type": "message_stop"}),
        ]:
            with self.subTest(provider=provider):
                observed = live.inspect_stream(response(delta, done), provider)
                self.assertEqual(observed, {"events": 2, "text_deltas": 1, "completed": True})
                for items in [[], [delta], [done], [delta, {"type": "error"}, done]]:
                    with self.assertRaises(live.SmokeFailure):
                        live.inspect_stream(response(*items), provider)

    def test_disconnect_does_not_wait_for_completion(self):
        stream = response({"type": "response.output_text.delta", "delta": "first"})
        self.assertEqual(live.inspect_stream(stream, "openai", cancel=True),
                         {"events": 1, "text_deltas": 1, "client_disconnect": True})

    def test_bounded_and_truncated_events_fail(self):
        for body in [b"data: " + b"x" * live.MAX_EVENT,
                     b"data: {}\n", b"data: []\n\n"]:
            with self.assertRaises(live.SmokeFailure):
                list(live.events(Response(body)))
        event = b"data: " + b"x" * (live.MAX_EVENT // 2) + b"\n"
        with self.assertRaisesRegex(live.SmokeFailure, "SSE event exceeded"):
            list(live.events(Response(event * 3)))
        with self.assertRaises(live.SmokeFailure):
            list(live.events(Response(b": keepalive\n\n" * (live.MAX_STREAM // 10))))

    def test_http_and_incomplete_errors_fail(self):
        stream = response({"type": "response.completed"})
        stream.status = 429
        with self.assertRaisesRegex(live.SmokeFailure, "429"):
            live.inspect_stream(stream, "openai")
        with self.assertRaisesRegex(live.SmokeFailure, "incomplete"):
            live.inspect_stream(response({"type": "response.output_text.delta", "delta": "OK"},
                                         {"type": "response.incomplete"},
                                         {"type": "response.completed"}), "openai")

    def test_audit_catches_split_secret_and_output_overflow(self):
        class Fragments:
            def __init__(self, fragments):
                self.fragments = iter(fragments)
            def read(self, _size):
                return next(self.fragments, b"")
            def close(self):
                pass
        for fragments in [[b"prefix sec", b"ret suffix"], [b"x" * 65537]]:
            audit = live.OutputAudit([Fragments(fragments)], [b"secret"])
            with self.assertRaises(live.SmokeFailure):
                audit.check()
        live.OutputAudit([Fragments([b"ready\n"])], [b"secret"]).check()

    def test_credential_input_errors_do_not_echo_input(self):
        marker = b"private-test-credential"
        result = subprocess.run([sys.executable, str(ROOT / "scripts/test-proxy-live.py"),
                                 "--provider", "openai", "--model", "explicit-test-model"],
                                input=marker + b"\x00", capture_output=True, env={}, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(marker, result.stdout + result.stderr)
        self.assertIn(b"invalid credential input", result.stderr)


if __name__ == "__main__":
    unittest.main()
