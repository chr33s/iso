#!/usr/bin/env python3
"""Guest-side admission/slow-head pressure; no authentication or upstream I/O."""
from contextlib import ExitStack
import select
import socket
import sys
import time


def active(sockets, allow_refusal=False):
    readable, _, _ = select.select(sockets, [], [], 0)
    closed = set()
    for connection in readable:
        try:
            data = connection.recv(1, socket.MSG_PEEK)
        except ConnectionResetError:
            data = b""
        if not data:
            closed.add(connection)
        else:
            assert allow_refusal, "incomplete head was refused before its deadline"
            response = b""
            while True:
                try:
                    block = connection.recv(1024)
                except ConnectionResetError:
                    # Closing with unread slow-head bytes can reset TCP after
                    # the refusal. The complete response is still required.
                    break
                if not block:
                    break
                response += block
                assert len(response) <= 1024, "unbounded head-timeout response"
            assert response == (b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n"
                                b"Connection: close\r\n\r\n"), "unexpected head-timeout response"
            closed.add(connection)
    return [connection for connection in sockets if connection not in closed]


def exercise(port):
    for round_number in range(3):
        with ExitStack() as cleanup:
            started = time.monotonic()
            sockets = [cleanup.enter_context(socket.create_connection(("127.0.0.1", port), timeout=1))
                       for _ in range(160)]
            assert time.monotonic() - started < 2, "pressure ramp exceeded head-deadline control budget"
            deadline = started + 3
            live = sockets
            while len(live) > 128 and time.monotonic() < deadline:
                time.sleep(.02)
                live = active(live)
            assert len(live) == 128, f"socket admission bound: expected 128, observed {len(live)}"
            # Periodic fragments cannot extend the absolute five-second head
            # deadline. No CRLF terminator is ever sent.
            while time.monotonic() < started + 7:
                for connection in live:
                    try:
                        connection.sendall(b"X")
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                time.sleep(.25)
                live = active(live, allow_refusal=True)
                if not live:
                    break
            assert not live, "slow incomplete heads survived their absolute deadline"
        print(f"PASS pressure round {round_number + 1}: 128 admitted, overflow closed, slow heads expired", flush=True)


if __name__ == "__main__":
    exercise(int(sys.argv[1]))
