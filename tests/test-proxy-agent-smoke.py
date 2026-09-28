#!/usr/bin/env python3
"""Offline checks: no installed agent, VM, or provider credential required."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

PATH = Path(__file__).resolve().parent / "fixtures/credential-proxy/agent-tool-smoke.py"
spec = importlib.util.spec_from_file_location("agent_smoke", PATH)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
NONCE = "nonce-only-obtainable-from-file"


def events(agent):
    if agent == "codex":
        return [
            {"type": "item.completed", "item": {"type": "command_execution", "status": "completed",
             "exit_code": 0, "aggregated_output": NONCE}},
            {"type": "item.completed", "item": {"type": "agent_message", "text": NONCE}},
            {"type": "turn.completed"},
        ]
    return [
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "id": "call1"}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "call1", "content": NONCE}]}},
        {"type": "result", "subtype": "success", "result": NONCE},
    ]


def encode(rows):
    return ("\n".join(json.dumps(row) for row in rows) + "\n").encode()


class AgentSmokeTests(unittest.TestCase):
    def test_complete_roundtrip_and_every_required_event(self):
        for agent in ("claude", "codex"):
            rows = events(agent)
            self.assertEqual(gate.verify_events(agent, encode(rows), NONCE), len(rows))
            for index in range(len(rows)):
                with self.subTest(agent=agent, missing=index), self.assertRaises(gate.GateFailure):
                    gate.verify_events(agent, encode(rows[:index] + rows[index + 1:]), NONCE)
            with self.assertRaises(gate.GateFailure):
                gate.verify_events(agent, encode(list(reversed(rows))), NONCE)
            with self.assertRaises(gate.GateFailure):
                gate.verify_events(agent, encode(rows), "different nonce")

    def test_failed_tools_unmatched_calls_and_failed_turns(self):
        rows = events("codex")
        for key, value in (("exit_code", 1), ("status", "failed"), ("aggregated_output", "")):
            broken = copy.deepcopy(rows)
            broken[0]["item"][key] = value
            with self.assertRaises(gate.GateFailure):
                gate.verify_events("codex", encode(broken), NONCE)
        for change in ({"is_error": True}, {"tool_use_id": "unmatched"}, {"content": ""}):
            broken = events("claude")
            broken[1]["message"]["content"][0].update(change)
            with self.assertRaises(gate.GateFailure):
                gate.verify_events("claude", encode(broken), NONCE)
        for agent in ("claude", "codex"):
            with self.assertRaises(gate.GateFailure):
                gate.verify_events(agent, encode(events(agent) + [{"type": "error"}]), NONCE)
        rows = events("claude")
        rows[-1]["subtype"] = "error_max_turns"
        with self.assertRaises(gate.GateFailure):
            gate.verify_events("claude", encode(rows), NONCE)

    def test_structured_claude_result(self):
        rows = events("claude")
        rows[1]["message"]["content"][0]["content"] = [{"type": "text", "text": NONCE}]
        self.assertEqual(gate.verify_events("claude", encode(rows), NONCE), 3)

    def test_invalid_event_stream(self):
        for raw in (b"not json\n", b"[]\n", b"\xff\n", b""):
            with self.assertRaises(gate.GateFailure):
                gate.verify_events("codex", raw, NONCE)

    def test_transport_failure_requires_terminal_connection_error(self):
        for agent, row in (
            ("codex", {"type": "turn.failed", "error": {"message": "error sending request for url (http://127.0.0.1:123/v1/responses)"}}),
            ("claude", {"type": "result", "is_error": True, "result": "API Error: Connection error."}),
            ("claude", {"type": "result", "subtype": "success", "is_error": True,
                        "result": "API Error: Connection dropped (ECONNRESET)"}),
        ):
            gate.verify_transport_failure(agent, encode([row]))
            for invalid in (events(agent), [{"type": "error", "message": "Connection refused"}],
                            [{"type": "result", "is_error": True, "result": "Unknown model"}],
                            [{"type": "turn.failed", "error": {"message": "invalid configuration"}}]):
                with self.subTest(agent=agent), self.assertRaises(gate.GateFailure):
                    gate.verify_transport_failure(agent, encode(invalid))

    def test_failure_capture_requires_unsuccessful_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(gate.capture([sys.executable, "-c", "print('failed'); raise SystemExit(1)"],
                                          directory, expected_failure=True), b"failed\n")
            with self.assertRaises(gate.GateFailure):
                gate.capture([sys.executable, "-c", "print('ok')"], directory, expected_failure=True)

    def test_capture_terminates_descendant_after_parent_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            program = """
import os, time
from pathlib import Path
Path('group.pid').write_text(str(os.getpid()))
if os.fork():
    os._exit(0)
Path('descendant.pid').write_text(str(os.getpid()))
time.sleep(30)
"""
            try:
                with self.assertRaises(gate.GateFailure):
                    gate.capture([sys.executable, "-c", program], directory, timeout=0.5)
                descendant = int(Path(directory, "descendant.pid").read_text())
                deadline = time.monotonic() + 2
                while True:
                    status = subprocess.run(["ps", "-p", str(descendant), "-o", "stat="],
                                            capture_output=True, text=True, check=False, timeout=5)
                    # An orphan may remain a zombie until its adopter reaps it.
                    stopped = status.returncode == 1 or status.stdout.strip().startswith("Z")
                    if stopped or time.monotonic() >= deadline:
                        break
                    time.sleep(0.02)
                self.assertTrue(stopped, "capture left the descendant running")
            finally:
                group_file = Path(directory, "group.pid")
                if group_file.exists():
                    try:
                        os.killpg(int(group_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_capture_deadline_output_and_exit_bounds(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(gate.capture([sys.executable, "-c", "print('ok')"], directory), b"ok\n")
            for program, options in (
                ("import time; time.sleep(10)", {"timeout": 0.1}),
                ("import sys; sys.stderr.write('x'*10000)", {"limit": 100}),
                ("raise SystemExit(1)", {}),
                ("import os,time; os.close(1); os.close(2); time.sleep(10)", {"timeout": 0.1}),
            ):
                with self.subTest(program=program), self.assertRaises(gate.GateFailure):
                    gate.capture([sys.executable, "-c", program], directory, **options)


if __name__ == "__main__":
    unittest.main()
