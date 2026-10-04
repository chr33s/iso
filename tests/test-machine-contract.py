#!/usr/bin/env python3
"""`--output json` (iso.machine/v1) against the read-contract state and fake runtime.

Run with --swift .build/debug/iso. Checks stream purity (stdout is exactly one
JSON document), exit status, stable error codes, non-interactive behavior with
a terminal on stdin, and that configured secret references never appear.
"""

import argparse
import importlib.util
import json
import os
import pty
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("read_contract", ROOT / "tests" / "test-read-contract.py")
read_contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(read_contract)

API = "iso.machine/v1"
# Configured in the read-contract config; no document may carry it.
SECRET_REFERENCE = "security find-generic-password"


def run(binary, args, home, *, tty_stdin=False):
    if not tty_stdin:
        return read_contract.run(binary, args, home, home / "swift" / "config.jsonc")
    env = {"HOME": str(home), "PATH": f"{home}/bin:/usr/bin:/bin", "NO_COLOR": "1"}
    command = [binary, "--config", str(home / "swift" / "config.jsonc"), *args]
    # A prompt would block on the terminal until the timeout.
    controller, terminal = pty.openpty()
    try:
        result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=30, stdin=terminal)
    except subprocess.TimeoutExpired:
        return 124, "", "timed out (waiting on the terminal?)"
    finally:
        os.close(terminal)
        os.close(controller)
    return result.returncode, result.stdout, result.stderr


def document(stdout):
    """Exactly one JSON document and its newline, nothing before or after."""
    if not stdout.endswith("\n") or stdout.count("\n") != 1:
        raise AssertionError(f"stdout is not one line: {stdout!r}")
    value = json.loads(stdout)
    if value.get("api_version") != API or not isinstance(value.get("ok"), bool):
        raise AssertionError(f"not an {API} envelope: {value}")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--swift", required=True)
    binary = os.path.abspath(parser.parse_args().swift)
    failures = []

    def check(label, condition, detail=""):
        print(("ok    " if condition else "FAIL  ") + label)
        if not condition:
            failures.append(label)
            if detail:
                print("  " + detail.replace("\n", "\n  "))

    with tempfile.TemporaryDirectory(prefix="iso-machine-contract-") as directory:
        home = Path(os.path.realpath(directory))
        read_contract.build_state(home)
        project = home / "project"
        (project / ".devcontainer").mkdir(parents=True)
        (project / ".devcontainer" / "devcontainer.json").write_text('{"hostRequirements": {"cpus": 2}}')
        repository = home / "repository"
        repository.mkdir()
        for git in (["init", "-q"], ["remote", "add", "origin", "https://github.com/octo/widget.git"]):
            subprocess.run(["git", "-C", str(repository), *git], check=True, capture_output=True)

        cases = [
            # args, expected exit, expected command, ok, result/error check
            (["capabilities"], 0, "capabilities", True,
             lambda r: r["machine_api_versions"] == [API] and r["commands"]["up"] == {"machine_output": True}
             and r["commands"]["zed"] == r["commands"]["code"] == {"machine_output": True}
             and [p["id"] for p in r["editor_providers"]] == ["code", "zed"]),
            (["list"], 0, "list", True,
             lambda r: [(i["name"], i["state"]) for i in r["instances"]] == [
                 ("alpha", "running"), ("beta", "stopped"), ("delta", "unknown"),
                 ("epsilon", "unknown"), ("gamma", "stopped")]),
            (["status", "alpha"], 0, "status", True,
             lambda r: r["instance"]["state"] == "running" and r["usage"]["mem_total_mib"] == 2000),
            (["status", "beta"], 0, "status", True, lambda r: r["usage"] is None),
            (["status"], 0, "status", True, lambda r: len(r["instances"]) == 5),
            (["ssh-config", "alpha"], 0, "ssh-config", True,
             lambda r: r["connection"] == {
                 "kind": "ssh", "host_alias": "iso-alpha", "ssh_config_path": f"{home}/.ssh/config"}),
            (["status", "nobody"], 1, "status", False, lambda e: e["code"] == "INSTANCE_NOT_FOUND"),
            (["status", "epsilon"], 1, "status", False,
             lambda e: e["code"] == "APPLE_OPERATION_UNCERTAIN" and e["retryable"]),
            (["stop"], 1, "stop", False,
             lambda e: e["code"] == "AMBIGUOUS_INSTANCE" and "alpha" in e["details"]["instances"]),
            (["ssh-config", "beta"], 1, "ssh-config", False,
             lambda e: e["code"] == "INSTANCE_NOT_RUNNING" and e["details"] == {"name": "beta"}),
            (["start", "alpha"], 1, "start", False, lambda e: e["code"] == "INSTANCE_ALREADY_RUNNING"),
            (["logs", "alpha"], 2, "logs", False, lambda e: e["code"] == "UNSUPPORTED_MACHINE_OUTPUT"),
            (["shell", "alpha"], 2, "shell", False, lambda e: e["code"] == "UNSUPPORTED_MACHINE_OUTPUT"),
            (["secrets", "list"], 2, "secrets list", False,
             lambda e: e["code"] == "UNSUPPORTED_MACHINE_OUTPUT" and "`iso secrets list`" in e["message"]),
            (["secrets"], 2, "secrets", False, lambda e: e["code"] == "UNSUPPORTED_MACHINE_OUTPUT"),
            (["up", str(project)], 1, "up", False,
             lambda e: e["code"] == "INTERACTION_REQUIRED" and e["details"]["kind"] == "devcontainer"
             and e["details"]["accepted_flags"][-1] == "--no-devcontainer"),
            (["zed", str(project), "--no-launch"], 1, "zed", False,
             lambda e: e["code"] == "INTERACTION_REQUIRED" and e["details"]["kind"] == "devcontainer"),
            (["code", str(repository), "--no-devcontainer", "--no-launch"], 1, "code", False,
             lambda e: e["code"] == "INTERACTION_REQUIRED" and e["details"]["kind"] == "github-pat"),
            (["up", str(repository), "--no-devcontainer"], 1, "up", False,
             lambda e: e["code"] == "INTERACTION_REQUIRED" and e["details"] == {
                 "kind": "github-pat", "repo": "octo/widget", "accepted_flags": ["--no-prompt", "--no-github"]}),
            (["up", str(project), "--no-devcontainer", "--env", "TOKEN={vault:token}"], 1, "up", False,
             lambda e: e["code"] == "INTERACTION_REQUIRED" and e["details"] == {
                 "kind": "passphrase", "descriptor_variable": "ISO_SECRETS_PASSPHRASE_FD"}),
        ]
        for args, exit_code, command, ok, predicate in cases:
            label = "iso " + " ".join(args) + " --output json"
            status, stdout, stderr = run(binary, [*args, "--output", "json"], home, tty_stdin=True)
            try:
                value = document(stdout)
                payload = value["result"] if ok else value["error"]
                good = (status == exit_code and value["command"] == command and value["ok"] is ok
                        and predicate(payload) and SECRET_REFERENCE not in stdout)
            except (AssertionError, KeyError, TypeError, ValueError) as error:
                good = False
                stdout += f"\n({error})"
            check(label, good, f"exit {status}\nstdout: {stdout}\nstderr: {stderr[-600:]}")

        # --quiet: the document alone, nothing on stderr.
        status, stdout, stderr = run(binary, ["status", "nobody", "--output", "json", "--quiet"], home)
        check("--quiet discards stderr", status == 1 and stderr == "" and document(stdout)["ok"] is False, stderr)

        # Text output and legacy --json are unchanged by the new option.
        for args in (["list"], ["list", "--json"], ["status", "--json"]):
            legacy = run(binary, args, home)
            explicit = run(binary, [*args, "--output", "text"], home)
            check("iso " + " ".join(args) + " is unchanged by --output text", legacy[:2] == explicit[:2])
        status, stdout, _ = run(binary, ["list", "--json"], home)
        check("legacy list --json keeps its unversioned shape",
              status == 0 and isinstance(json.loads(stdout), list))

        # Closed standard descriptors at launch: one document still reaches
        # stdout, and a needed decision is still refused rather than read.
        env = {"HOME": str(home), "PATH": f"{home}/bin:/usr/bin:/bin", "NO_COLOR": "1"}
        config = ["--config", str(home / "swift" / "config.jsonc")]
        for label, closed in (("stdin", 0), ("stderr", 2)):
            result = subprocess.run(
                [binary, *config, "up", str(project), "--output", "json"], capture_output=True,
                text=True, env=env, timeout=30, preexec_fn=lambda fd=closed: os.close(fd))
            try:
                good = result.returncode == 1 and document(result.stdout)["error"]["code"] == "INTERACTION_REQUIRED"
            except (AssertionError, KeyError, ValueError):
                good = False
            check(f"closed {label} at launch still yields one document", good, result.stdout + result.stderr[-400:])

        # A passphrase descriptor that names the held document descriptor is refused.
        result = subprocess.run(
            [binary, *config, "up", str(project), "--no-devcontainer", "--env", "TOKEN={vault:token}",
             "--output", "json"], capture_output=True, text=True, timeout=30,
            env={**env, "ISO_SECRETS_PASSPHRASE_FD": "3"})
        try:
            value = document(result.stdout)
            good = result.returncode == 1 and value["ok"] is False and "ISO_SECRETS_PASSPHRASE_FD" in value["error"]["message"]
        except (AssertionError, KeyError, ValueError):
            good = False
        check("passphrase descriptor cannot take the document descriptor", good, result.stdout + result.stderr[-400:])

        # Usage conflicts fail before any document.
        for args in (["list", "--json", "--output", "json"], ["status", "--quiet"],
                     ["up", "--dry-run", "--output", "json"],
                     ["zed", "--project", "workspace", "--output", "json"],
                     ["code", "--editor", "zed", "--output", "json"]):
            status, stdout, _ = run(binary, args, home)
            check("iso " + " ".join(args) + " is a usage error", status == 2 and stdout == "")

    print(f"\n{len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
