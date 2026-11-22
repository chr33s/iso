#!/usr/bin/env python3
"""A scripted local model backend for the inference integration phase.

    inference-backend.py PROTOCOL HOST PORT LOG

PROTOCOL is `anthropic-messages` or `openai-responses`. Every request is
appended to LOG as one JSON line (method, path, body; no header values), and
answered with a short streamed reply "ok" in that protocol. Nothing here
calls a network.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL, HOST, PORT, LOG = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]


def events(model):
    if PROTOCOL == "anthropic-messages":
        yield "message_start", {"type": "message_start", "message": {
            "id": "msg_1", "type": "message", "role": "assistant", "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 3, "output_tokens": 1}}}
        yield "content_block_start", {"type": "content_block_start", "index": 0,
                                      "content_block": {"type": "text", "text": ""}}
        yield "content_block_delta", {"type": "content_block_delta", "index": 0,
                                      "delta": {"type": "text_delta", "text": "ok"}}
        yield "content_block_stop", {"type": "content_block_stop", "index": 0}
        yield "message_delta", {"type": "message_delta",
                                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                "usage": {"output_tokens": 1}}
        yield "message_stop", {"type": "message_stop"}
    else:
        item = {"id": "msg_1", "type": "message", "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
        response = {"id": "resp_1", "object": "response", "created_at": int(time.time()),
                    "status": "in_progress", "model": model, "output": [], "usage": None}
        yield "response.created", {"type": "response.created", "sequence_number": 0,
                                   "response": response}
        yield "response.output_item.added", {"type": "response.output_item.added",
                                             "sequence_number": 1, "output_index": 0,
                                             "item": dict(item, status="in_progress", content=[])}
        yield "response.output_text.delta", {"type": "response.output_text.delta",
                                             "sequence_number": 2, "item_id": "msg_1",
                                             "output_index": 0, "content_index": 0, "delta": "ok"}
        yield "response.output_item.done", {"type": "response.output_item.done",
                                            "sequence_number": 3, "output_index": 0, "item": item}
        yield "response.completed", {"type": "response.completed", "sequence_number": 4,
                                     "response": dict(response, status="completed", output=[item],
                                                      usage={"input_tokens": 3, "output_tokens": 1,
                                                             "total_tokens": 4})}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0")))
        try:
            parsed = json.loads(body)
        except ValueError:
            parsed = None
        with open(LOG, "a") as log:
            log.write(json.dumps({"method": "POST", "path": self.path, "body": parsed}) + "\n")
        model = parsed.get("model", "?") if isinstance(parsed, dict) else "?"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()
        for name, data in events(model):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        with open(LOG, "a") as log:
            log.write(json.dumps({"method": "GET", "path": self.path, "body": None}) + "\n")
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
