#!/usr/bin/env python3
"""Shared raw HTTP refusal corpus against the real confined Swift executable.

Uses synthetic startup credentials. Cases are restricted to unauthenticated or
GET/DELETE/TRACE/CONNECT requests; no allowed model operation is sent. Forwarding
and TLS semantics have separate controlled-upstream gates and remain separate
from this refusal corpus.
"""
import argparse
import errno
import json
import random
import tempfile
from pathlib import Path
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "a" * 64
SECRET = "contract-test-only-not-a-provider-key"
READINESS = b"GET / HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n\r\n"


def read_response(peer, *, deadline=None):
    data = bytearray()
    closed = False
    while len(data) < 131072:
        if deadline is not None:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "response exceeded the absolute deadline"
            peer.settimeout(remaining)
        try:
            part = peer.recv(4096)
        except ConnectionResetError:
            closed = True
            break
        if not part:
            closed = True
            break
        data.extend(part)
    assert closed, "response did not close within the read budget"
    first = data.split(b"\r\n", 1)[0].split(b" ")
    status = int(first[1]) if len(first) >= 2 and first[0] == b"HTTP/1.1" else None
    assert SECRET.encode() not in data and TOKEN.encode() not in data, "local response leaked startup secrets"
    return status, closed


def exchange(port, wire, *, eof=False, timing=None):
    # Fast malformed-input runs can exhaust the test client's ephemeral ports
    # in TIME_WAIT. Retry only that local allocation error, with a fixed budget.
    deadline = time.monotonic() + 45
    while True:
        try:
            peer = socket.create_connection(("127.0.0.1", port), timeout=2)
            break
        except OSError as error:
            if error.errno != errno.EADDRNOTAVAIL or time.monotonic() >= deadline:
                raise
            time.sleep(0.1)
    with peer:
        started = time.monotonic()
        if timing:
            peer.settimeout(timing["maximum_elapsed_ms"] / 1000)
        try:
            peer.sendall(wire)
            if timing and "resume_after_ms" in timing:
                time.sleep(timing["resume_after_ms"] / 1000)
                peer.sendall(timing["suffix"].encode("ascii"))
            if eof:
                peer.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError):
            pass  # An early parser refusal may close during the write.
        deadline = started + timing["maximum_elapsed_ms"] / 1000 if timing else None
        result = read_response(peer, deadline=deadline)
        if timing:
            elapsed_ms = (time.monotonic() - started) * 1000
            assert timing["minimum_elapsed_ms"] <= elapsed_ms <= timing["maximum_elapsed_ms"], elapsed_ms
        return result


def idle_connection_capacity(port):
    # Refill the entire production allowance after response completion and
    # after abrupt guest disconnect. No capability or admitted request is sent.
    for finish in ["response", "disconnect", "response"]:
        held = []
        deadline = time.monotonic() + 5  # Before the ten-second header timeout.
        try:
            for _ in range(256):
                held.append(socket.create_connection(("127.0.0.1", port), timeout=1))
            # Allow accepts to be dispatched across the server event loops.
            # Later 401 responses prove every held socket actually survived.
            time.sleep(0.05)
            for _ in range(8):
                with socket.create_connection(("127.0.0.1", port), timeout=1) as excess:
                    # Capacity rejection must not require any HTTP input.
                    assert read_response(excess, deadline=min(deadline, time.monotonic() + 1)) == (None, True)
            if finish == "response":
                for peer in held:
                    peer.sendall(READINESS)
                for index, peer in enumerate(held):
                    assert read_response(peer, deadline=deadline) == (401, True), f"held socket {index} lost"
        finally:
            for peer in held:
                peer.close()
        # A successful HTTP exchange, rather than TCP connect alone, proves
        # admission resumes after disconnect/response cleanup.
        recovery = time.monotonic() + 2
        while exchange(port, READINESS) != (401, True):
            assert time.monotonic() < recovery, "connection capacity did not recover"
            time.sleep(0.01)


def fuzz_inputs(seed, count):
    rng = random.Random(seed)
    seeds = [
        b"GET /v1/messages HTTP/1.1\r\nHost: guest\r\n\r\n",
        b"POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer wrong\r\nContent-Length: 0\r\n\r\n",
        b"POST /v1/messages HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n",
        b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: guest\r\n\r\n",
    ]
    fragments = [b"\r", b"\n", b"\x00", b"\xff", b"%00", b"%zz", b"//", b"#", b"\t",
                 b"Content-Length: 1\r\n", b"Transfer-Encoding: chunked\r\n",
                 b"Authorization: Bearer wrong\r\n", b"Connection: x-private,\r\n"]
    for _ in range(count):
        wire = bytearray(rng.choice(seeds))
        for _ in range(rng.randint(1, 8)):
            position = rng.randrange(len(wire) + 1)
            operation = rng.randrange(4)
            if operation == 0:
                wire[position:position] = rng.choice(fragments)
            elif operation == 1:
                del wire[position:position + rng.randint(1, 32)]
            elif operation == 2:
                wire[position:position + 1] = bytes([rng.randrange(256)])
            else:
                wire[position:position] = rng.choice([b"x", b" ", b"\t"]) * rng.choice([1, 128, 16385])
        # No fuzz input may contain the valid capability. Thus even mutations
        # into an allowlisted POST cannot attach the provider credential.
        yield bytes(wire[:96 * 1024]).replace(TOKEN.encode(), b"x" * len(TOKEN))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path)
    parser.add_argument("--fuzz-cases", type=int, default=0)
    parser.add_argument("--seed", type=int, default=20260927)
    parser.add_argument("--capacity-only", action="store_true", help="run only idle socket saturation and recovery")
    parser.add_argument("--replay", type=Path, help="replay a saved unauthenticated request.bin")
    args = parser.parse_args()
    if not 0 <= args.fuzz_cases <= 100000:
        parser.error("--fuzz-cases must be between 0 and 100000")
    if args.replay and args.fuzz_cases:
        parser.error("choose --replay or --fuzz-cases")
    if args.capacity_only and (args.replay or args.fuzz_cases):
        parser.error("--capacity-only cannot be combined with fuzzing or replay")
    replay = args.replay.read_bytes() if args.replay else None
    if replay is not None and (len(replay) > 96 * 1024 or TOKEN.encode() in replay):
        parser.error("replay must be at most 96 KiB and contain no valid capability")
    fuzz_count = 1 if replay is not None else args.fuzz_cases
    if args.swift is None:
        directory = subprocess.check_output(["swift", "build", "--package-path", str(ROOT / "coop-proxy"),
                                             "--show-bin-path"], text=True).strip()
        args.swift = Path(directory) / "coop-proxy-swift"
    cases = json.loads((ROOT / "tests/fixtures/credential-proxy/refusals.json").read_text())
    if args.capacity_only:
        cases = []
    results = {}
    failures = []
    for label, binary in [("swift", args.swift.resolve())]:
        for provider in ["anthropic", "openai"]:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            config = {"version": 1, "listen": f"127.0.0.1:{port}", "provider": provider,
                      "capability_token": TOKEN, "injection": {"scheme": "bearer", "credential": SECRET}}
            command = ["/usr/bin/sandbox-exec", "-D", "PROXY_BIN=" + str(binary),
                       "-f", str(ROOT / "src/seatbelt-proxy.sb"), str(binary)]
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env={})
            try:
                child.stdin.write(json.dumps(config).encode())
                child.stdin.close()
                child.stdin = None
                deadline = time.monotonic() + 5
                while True:
                    assert child.poll() is None, f"{label} exited before readiness"
                    try:
                        assert exchange(port, b"GET / HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n\r\n")[0] == 401
                        break
                    except (ConnectionError, TimeoutError):
                        if time.monotonic() >= deadline:
                            raise AssertionError(f"{label} readiness timeout")
                        time.sleep(0.03)
                idle_connection_capacity(port)
                print(f"PASS {label}/{provider}: 256 idle sockets, excess closure, complete refill after response/disconnect", flush=True)
                for case in cases:
                    wire_text = case["wire"]
                    for marker, repeat in case.get("repeat", {}).items():
                        assert 0 < repeat["count"] <= 65536
                        wire_text = wire_text.replace(marker, repeat["text"] * repeat["count"])
                    wire = wire_text.replace("$TOKEN", TOKEN).encode("ascii")
                    # Prevent fixture edits from accidentally issuing a model call.
                    assert wire.split(b" ", 1)[0] in [b"GET", b"DELETE", b"TRACE", b"CONNECT"], case["name"]
                    actual = exchange(port, wire, timing=case.get("timing"))
                    results[(label, provider, case["name"])] = actual
                    if actual[0] != case["status"]:
                        failures.append(f"{label}/{provider}/{case['name']}: expected {case['status']}, got {actual[0]}")
                for index, wire in enumerate([replay] if replay is not None else fuzz_inputs(args.seed, args.fuzz_cases)):
                    try:
                        assert TOKEN.encode() not in wire
                        status, _ = exchange(port, wire, eof=True)
                        assert status in [None, 400, 401, 408, 413, 414, 431, 505], f"unexpected status {status}"
                        assert child.poll() is None, "proxy crashed"
                        if index % 25 == 0 or index == fuzz_count - 1:
                            assert exchange(port, b"GET / HTTP/1.1\r\nHost: guest\r\n\r\n")[0] == 401
                    except Exception as error:
                        directory = Path(tempfile.mkdtemp(prefix="coop-proxy-fuzz-failure-"))
                        (directory / "request.bin").write_bytes(wire)
                        (directory / "replay.json").write_text(json.dumps({
                            "implementation": label, "provider": provider,
                            "seed": args.seed, "index": index, "eof": True,
                        }, indent=2) + "\n")
                        raise AssertionError(f"fuzz failure {label}/{provider}, seed {args.seed}, case {index}; saved {directory}") from error
                assert child.poll() is None, f"{label} crashed during corpus"
            finally:
                if child.poll() is None:
                    child.terminate()
                try:
                    stdout, stderr = child.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    stdout, stderr = child.communicate(timeout=5)
                assert SECRET.encode() not in stdout + stderr and TOKEN.encode() not in stdout + stderr
                assert b"panicked at" not in stderr and b"Fatal error:" not in stderr, "proxy reported a runtime panic"
    if failures:
        raise SystemExit("\n".join(failures))
    if cases:
        print(f"PASS {len(cases)} shared refusal cases x 2 providers x 1 confined Swift implementation")
    if fuzz_count:
        source = str(args.replay) if replay is not None else f"seed {args.seed}"
        print(f"PASS {fuzz_count} raw HTTP inputs x 2 providers x 1 confined Swift implementation; {source}")


if __name__ == "__main__":
    main()
