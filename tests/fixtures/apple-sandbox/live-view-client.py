#!/usr/bin/env python3
"""A minimal live-view viewer for the integration suite
(docs/design/computer-use-live-view.md): open the viewer's WebSocket with
the URL `cu stream` printed, authenticate with its token, and wait for one
binary (H.264) frame. Prints the frame's size; exits non-zero on timeout.

    live-view-client.py URL [SECONDS]
"""

import base64
import json
import os
import socket
import struct
import sys
import time
from urllib.parse import urlsplit


def frame(opcode, payload):
    mask = os.urandom(4)
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 1 << 16:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def read_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise EOFError("closed")
        data += chunk
    return data


def read_frame(sock):
    b0, b1 = read_exact(sock, 2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", read_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", read_exact(sock, 8))[0]
    return b0 & 0x0F, read_exact(sock, n)


def main():
    url = urlsplit(sys.argv[1])
    deadline = time.time() + float(sys.argv[2] if len(sys.argv) > 2 else 15)
    hostport = f"{url.hostname}:{url.port}"
    sock = socket.create_connection((url.hostname, url.port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET /ws HTTP/1.1\r\nHost: {hostport}\r\nOrigin: http://{hostport}\r\n"
                  f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                  "Sec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += read_exact(sock, 1)
    if not head.startswith(b"HTTP/1.1 101"):
        sys.exit(f"upgrade refused: {head.splitlines()[0]!r}")
    sock.sendall(frame(0x1, json.dumps({"type": "auth", "token": url.fragment}).encode()))
    while time.time() < deadline:
        try:
            opcode, payload = read_frame(sock)
        except socket.timeout:
            continue
        if opcode == 0x2:
            print(f"binary frame {len(payload)} bytes")
            return
        if opcode == 0x8:
            sys.exit("closed by the server")
    sys.exit("no binary frame before the deadline")


if __name__ == "__main__":
    main()
