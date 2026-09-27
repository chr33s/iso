#!/usr/bin/env python3
"""Run INSIDE a disposable, proxy-configured guest with dedicated credentials.

No provider credential is accepted here. coop must already have configured the
agent's local endpoint and per-VM capability. Raw agent output is never printed.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import selectors
import re
import signal
import subprocess
import tempfile
import time


class GateFailure(Exception):
    pass


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(block.get("text", "") for block in value
                         if isinstance(block, dict) and block.get("type") == "text")
    return ""


def verify_events(agent, output, nonce):
    """Require a successful tool result followed by the model's final answer."""
    calls = set()
    result_seen = False
    final_seen = False
    completed = False
    count = 0
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            raise GateFailure("agent emitted invalid JSONL") from None
        if not isinstance(event, dict):
            raise GateFailure("agent emitted a non-object event")
        count += 1
        kind = event.get("type")
        if kind in ("error", "turn.failed") or event.get("is_error"):
            raise GateFailure("agent reported failure")
        if agent == "codex":
            item = event.get("item", {})
            if kind == "item.completed" and isinstance(item, dict):
                if (item.get("type") == "command_execution"
                        and item.get("exit_code") == 0
                        and item.get("status") == "completed"
                        and nonce in item.get("aggregated_output", "")):
                    result_seen = True
                if item.get("type") == "agent_message" and result_seen:
                    final_seen = nonce in item.get("text", "")
            if kind == "turn.completed":
                completed = final_seen
        else:
            message = event.get("message", {})
            blocks = message.get("content", []) if isinstance(message, dict) else []
            if isinstance(blocks, list):
                for block in blocks:
                    if not isinstance(block, dict):
                        continue
                    if kind == "assistant" and block.get("type") == "tool_use":
                        if block.get("name") in ("Read", "Bash") and isinstance(block.get("id"), str):
                            calls.add(block["id"])
                    if (kind == "user" and block.get("type") == "tool_result"
                            and block.get("tool_use_id") in calls and not block.get("is_error")
                            and nonce in text_content(block.get("content"))):
                        result_seen = True
            if kind == "result":
                completed = (event.get("subtype") == "success" and result_seen
                             and nonce in event.get("result", ""))
                final_seen = completed
    if not (result_seen and final_seen and completed):
        raise GateFailure("missing successful tool result and subsequent final answer")
    return count


def verify_transport_failure(agent, output):
    """A generic CLI/configuration error is not evidence of proxy failure."""
    failed = False
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            raise GateFailure("agent emitted invalid JSONL") from None
        if not isinstance(event, dict):
            raise GateFailure("agent emitted a non-object event")
        if event.get("type") == "turn.completed" or (
                agent == "claude" and event.get("type") == "result"
                and event.get("is_error") is not True):
            raise GateFailure("agent unexpectedly completed successfully")
        if agent == "codex" and event.get("type") == "turn.failed":
            error = event.get("error", {})
            message = error.get("message", "") if isinstance(error, dict) else ""
        elif (agent == "claude" and event.get("type") == "result"
              and event.get("is_error") is True):
            message = event.get("result", "")
        else:
            continue
        if isinstance(message, str) and re.search(
                r"connection (?:error|refused|reset|closed|dropped)|error sending request|stream disconnected",
                message, re.IGNORECASE):
            failed = True
    if not failed:
        raise GateFailure("missing terminal agent transport failure")


def capture(argv, directory, timeout=180, limit=2 * 1024 * 1024, expected_failure=False):
    """Bound both pipes together, and kill descendants even after parent exit."""
    process = subprocess.Popen(argv, cwd=directory, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    output = bytearray()
    total = 0
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            selector.register(process.stderr, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise GateFailure("agent exceeded deadline")
                for key, _ in selector.select(min(remaining, 0.5)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(chunk)
                    if total > limit:
                        raise GateFailure("agent exceeded output budget")
                    if key.fileobj is process.stdout:
                        output.extend(chunk)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise GateFailure("agent exceeded deadline")
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                raise GateFailure("agent exceeded deadline") from None
            if bool(code) != expected_failure:
                raise GateFailure("agent exited unsuccessfully")
        return bytes(output)
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        process.stdout.close()
        process.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", choices=("claude", "codex"), required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--expect-transport-failure", action="store_true",
                        help="require a terminal connection failure after the host proxy was stopped")
    args = parser.parse_args()
    # No nonce in the prompt: the model must obtain it from a real guest tool.
    nonce = secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix="coop-agent-smoke-") as directory:
        Path(directory, "challenge.txt").write_text(nonce + "\n")
        prompt = ("Use your file-reading or shell tool to read challenge.txt in the current directory. "
                  "Then reply with exactly its contents. Do not use any other files or tools.")
        if args.agent == "codex":
            argv = ["codex", "exec", "--json", "--ephemeral", "--ignore-rules",
                    "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox",
                    "--model", args.model, prompt]
        else:
            argv = ["claude", "-p", "--output-format", "stream-json", "--verbose",
                    "--no-session-persistence", "--max-turns", "4", "--max-budget-usd", "1",
                    "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                    "--tools", "Read,Bash", "--dangerously-skip-permissions",
                    "--model", args.model, prompt]
        # Claude's observed ten transport retries take about three minutes and
        # include jitter. Leave bounded headroom for its own terminal diagnostic.
        output = capture(argv, directory, timeout=300 if args.expect_transport_failure else 180,
                         expected_failure=args.expect_transport_failure)
        if args.expect_transport_failure:
            verify_transport_failure(args.agent, output)
            count = len(output.splitlines())
        else:
            count = verify_events(args.agent, output, nonce)
    print(json.dumps({"agent": args.agent, "model": args.model, "events": count,
                      "tool_result_and_final_answer": not args.expect_transport_failure,
                      "terminal_transport_failure": args.expect_transport_failure}))


if __name__ == "__main__":
    try:
        main()
    except GateFailure as error:
        raise SystemExit(str(error)) from None
    except Exception as error:
        # Never include raw subprocess output, configuration, or credentials.
        raise SystemExit(type(error).__name__) from None
