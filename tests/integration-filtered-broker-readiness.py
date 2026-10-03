#!/usr/bin/env python3
"""Real-VM filtered transport, broker, pressure and peer-isolation probes.

Uses synthetic keys and a fail-on-use agent image, not native provider qualification.
CONNECT/HTTPS controls contact api.github.com; no provider operation is performed.
Build host/iso-egress/iso-proxy first. The runtime is installed and signed here.
"""
import hashlib
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from filtered_egress_readiness import exercise as exercise_egress
from filtered_network_boundary import exercise as exercise_network
from filtered_lifecycle_revocation import exercise as exercise_revocation

ROOT = Path(__file__).resolve().parents[1]
SECRETS = ["iso-broker-test-anthropic", "iso-broker-test-openai", "iso-broker-host-ant", "iso-broker-host-oai"]


def exercise(work, only=None):
    builder_cli = shutil.which("container")
    assert builder_cli, "Apple container CLI is required"
    builder_cli = Path(builder_cli).resolve(strict=True)
    print("builder", builder_cli, subprocess.check_output([builder_cli, "--version"], text=True).strip(), flush=True)
    env = {key: value for key, value in os.environ.items()
           if key in {"HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG"}}
    env.update(ANTHROPIC_API_KEY=SECRETS[2], OPENAI_API_KEY=SECRETS[3])
    config = work / "config.json"
    binary = work / "bin"
    binary.mkdir()
    for package, product, installed in [(ROOT, "iso", "iso"), (ROOT / "iso-egress", "iso-egress", "iso-egress"),
                                        (ROOT / "iso-proxy", "iso-proxy", "iso-proxy")]:
        directory = subprocess.check_output(["swift", "build", "--package-path", str(package), "--show-bin-path"], text=True).strip()
        shutil.copy2(Path(directory) / product, binary / installed)
    subprocess.run([str(ROOT / "scripts/build-iso-sandbox.sh"), str(work / "runtime")], check=True, env=env)
    runtime = work / "runtime/bin/iso-sandbox"
    subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", str(runtime)], check=True)
    print("revision", subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), flush=True)
    for path in [binary / "iso", binary / "iso-egress", binary / "iso-proxy", runtime]:
        print("binary", path.name, hashlib.sha256(path.read_bytes()).hexdigest(), flush=True)
    state = work / "data/backends/apple-container-v1/instances/brokers"
    config.write_text(json.dumps({
        "data_dir": str(work / "data"), "github": "off", "egress": "filtered",
        "egress_filter": {"allowed_hosts": ["api.github.com"] if only == "network" else []},
        "proxy": {"mode": "required", "anthropic": {"credential": "cmd:printf %s " + SECRETS[0]},
                  "openai": {"credential": "cmd:printf %s " + SECRETS[1], "auth": "bearer"}},
        "claude": {"config_dir": False}, "codex": {"config_dir": False},
        "post_start": "printf 'broker-proof-hook\\n' > /tmp/iso-broker-hook",
        "profiles": {"boundary-fixture": {
            "apt_packages": ["python3", "socat", "netcat-openbsd", "iputils-ping"],
            "post_install": (ROOT / "tests/fixtures/apple-sandbox/stub-agents.sh").read_text()}},
        "vm": {"vcpu_count": 2, "mem_size_mib": 2048, "template_size_gib": 8},
        "apple_container": {"binary": str(runtime), "builder": str(builder_cli),
                            "kernel": str((Path.home() / "Library/Application Support/com.apple.container/kernels/default.kernel-arm64").resolve())},
    }))
    os.chmod(config, 0o600)
    project = work / "project"
    project.mkdir()
    (project / "marker").write_text("broker-fixture\n")
    argv = [str(binary / "iso"), "--config", str(config)]

    # Trusted host-side interposer: release a genuine reply only after the
    # controller pauses a broker. No challenge/capability/reply is saved or logged.
    interposer = work / "ssh-interposer"
    interposer.mkdir(mode=0o700)
    counter, trigger, checkpoint, release = [work / name for name in
                                            ["probe-count", "probe-trigger", "probe-checkpoint", "probe-release"]]
    helper = interposer / "ssh"
    helper.write_text("#!" + sys.executable + "\n" + "work = " + repr(str(work)) + "\n" + '''
import os, pathlib, subprocess, sys, time
root = pathlib.Path(work)
if not sys.argv or "exec 3<>/dev/tcp/127.0.0.1/" not in sys.argv[-1]:
    os.execv("/usr/bin/ssh", ["/usr/bin/ssh"] + sys.argv[1:])
request = sys.stdin.buffer.read()
result = subprocess.run(["/usr/bin/ssh"] + sys.argv[1:], input=request, capture_output=True)
count = int((root / "probe-count").read_text()) + 1
(root / "probe-count").write_text(str(count))
if count == int((root / "probe-trigger").read_text()):
    (root / "probe-checkpoint").write_text(str(count))
    deadline = time.monotonic() + 4
    while not (root / "probe-release").exists():
        if time.monotonic() >= deadline:
            sys.exit(124)
        time.sleep(.005)
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
''')
    helper.chmod(0o700)
    for path in [counter, trigger]:
        path.write_text("0")
        path.chmod(0o600)

    def run(args, expected=0, contains=None, timeout=240, private=False, interpose=None, input=None):
        print("command", " ".join(args), flush=True)
        started = time.monotonic()
        with subprocess.Popen(argv + args, env=env, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
            paused = None
            try:
                if interpose is not None:
                    deadline = time.monotonic() + 15
                    while not checkpoint.exists():
                        assert process.poll() is None, "CLI exited before the selected proof boundary"
                        assert time.monotonic() < deadline, "proof boundary was not reached"
                        time.sleep(.005)
                    assert int(checkpoint.read_text()) == interpose
                    pid = int((state / "proxy-openai.pid").read_text())
                    command = subprocess.check_output(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], text=True)
                    assert str(binary / "iso-proxy") in command
                    os.kill(pid, signal.SIGSTOP)
                    paused = pid
                    release.write_text("release verified reply")
                    release.chmod(0o600)
                stdout, stderr = process.communicate(input=input, timeout=timeout)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
                raise
            finally:
                if paused is not None:
                    try:
                        os.kill(paused, signal.SIGCONT)
                    except ProcessLookupError:
                        pass
            result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        text = result.stdout + result.stderr
        if not private:
            print(text, end="", flush=True)
        assert result.returncode == expected, f"command exit {result.returncode}, expected {expected}"
        if contains is not None:
            assert contains in text, "expected result marker absent"
        elapsed = time.monotonic() - started
        print(f"elapsed {elapsed:.3f}s", flush=True)
        return text, elapsed

    def key(provider):
        return state / f"proxy-{provider}-readiness-public-key"

    cleanup_configuration = config.read_text()
    try:
        run(["setup", "-y", "--profile", "boundary-fixture"], timeout=1200)
        run(["up", str(project), "--name", "brokers", "--no-github", "--no-devcontainer"])
        run(["exec", "brokers", "--", "cat", "/tmp/iso-broker-hook"], contains="broker-proof-hook")
        run(["status", "brokers"], contains="running")
        values = [key(provider).read_bytes() for provider in ["anthropic", "openai"]]
        assert values[0] != values[1] and all(len(value) == 64 for value in values)
        assert all(key(provider).stat().st_mode & 0o777 == 0o600 for provider in ["anthropic", "openai"])
        text, _ = run(["exec", "brokers", "--", "sh", "-c", "env; cat ~/.claude/settings.json ~/.codex/config.toml"], private=True)
        assert all(secret not in text for secret in SECRETS), "raw provider key in guest session/config"
        assert "ANTHROPIC_BASE_URL" in text and "ISO_LOCAL_API_KEY" in text
        for path in state.iterdir():
            if path.is_file() and path.stat().st_size <= 1 << 20:
                assert all(secret.encode() not in path.read_bytes() for secret in SECRETS), "raw provider key in host instance state"
        assert not (state / "proxy-anthropic.token").exists(), "readiness persisted an Anthropic capability"
        print("PASS both required brokers bootstrap and prove live local/guest paths; no raw keys in guest env/config or host instance state", flush=True)
        selected = {"egress": lambda: exercise_egress(state, binary, config, run),
                    "revocation": lambda: exercise_revocation(state, binary, config, run),
                    "network": lambda: exercise_network(work, config, run)}
        if only in selected:
            selected[only]()
            print(f"PASS selected {only} VM gate (other phases not run)", flush=True)
            return
        original_path = env["PATH"]
        env["PATH"] = str(interposer) + ":" + original_path
        try:
            for boundary, label in [(3, "after resolution, before preparation completes"),
                                    (9, "after preparation, before final workload launch")]:
                counter.write_text("0")
                trigger.write_text(str(boundary))
                checkpoint.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                _, elapsed = run(["exec", "brokers", "--", "touch", "/tmp/iso-late-workload-marker"],
                                 expected=1, contains="FILTERED_BROKER_NOT_READY", timeout=25, interpose=boundary)
                assert elapsed < 15
                trigger.write_text("0")
                run(["exec", "brokers", "--", "test", "!", "-e", "/tmp/iso-late-workload-marker"])
                print("PASS broker paused", label, "refuses workload; resume restores fresh proof", flush=True)
            for arguments, boundary, label in [
                (["agent", "update", "brokers", "--check", "--claude"], 6, "administrative version query"),
                (["push", "brokers", "--force"], 3, "workspace push probe"),
                (["pull", "brokers", "--review", "--stat"], 3, "staged workspace pull probe"),
                (["push", "brokers", "--force"], 6, "workspace push launch"),
                (["pull", "brokers", "--review", "--stat"], 6, "staged workspace pull launch"),
            ]:
                (project / "marker").write_text("late-workspace-must-not-transfer\n")
                counter.write_text("0")
                trigger.write_text(str(boundary))
                checkpoint.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                refusal, _ = run(arguments, expected=1, contains="FILTERED_BROKER_NOT_READY", timeout=25, interpose=boundary)
                assert "rsync not available" not in refusal, "readiness refusal was reported as guest tool absence"
                trigger.write_text("0")
                run(["exec", "brokers", "--", "cat", "/workspace/marker"], contains="broker-fixture")
                assert not (state / "stage").exists(), "failed handoff retained a stage"
                print("PASS late broker revocation refuses", label, "without transferring data; fresh proof recovers", flush=True)
            # Positive witnesses use the same transport after the broker resumes.
            run(["push", "brokers", "--force"])
            run(["exec", "brokers", "--", "cat", "/workspace/marker"], contains="late-workspace-must-not-transfer")
            run(["pull", "brokers", "--review", "--stat"])
            run(["pull", "brokers", "--discard"])
        finally:
            env["PATH"] = original_path
            trigger.write_text("0")
        for provider in ["anthropic", "openai"]:
            for suffix in ["-fwd", ""]:
                pid = int((state / f"proxy-{provider}{suffix}.pid").read_text())
                command = subprocess.check_output(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], text=True)
                assert ("ssh" if suffix else str(binary / "iso-proxy")) in command
                os.kill(pid, signal.SIGSTOP)
                try:
                    os.kill(pid, 0)
                    _, elapsed = run(["exec", "brokers", "--", "true"], expected=1, contains="FILTERED_BROKER_NOT_READY", timeout=20)
                    assert elapsed < 10
                    run(["status", "brokers"], expected=1, contains="FILTERED_BROKER_NOT_READY", timeout=20)
                finally:
                    os.kill(pid, signal.SIGCONT)
                run(["exec", "brokers", "--", "true"])
                print("PASS alive-PID paused broker/tunnel is unhealthy then recovers:", provider + suffix, flush=True)
        original = key("anthropic").read_bytes()
        key("anthropic").write_bytes(key("openai").read_bytes())
        run(["exec", "brokers", "--", "true"], expected=1, contains="authenticated anthropic companion probe failed")
        key("anthropic").write_bytes(original)
        run(["exec", "brokers", "--", "true"])
        key("anthropic").unlink()
        run(["exec", "brokers", "--", "true"], expected=1, contains="missing readiness identity")
        key("anthropic").write_bytes(original)
        os.chmod(key("anthropic"), 0o600)
        run(["exec", "brokers", "--", "true"])
        print("PASS substituted and absent broker public keys reject new handoffs", flush=True)
        pid = int((state / "proxy-openai.pid").read_text())
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while subprocess.run(["/bin/ps", "-p", str(pid)], stdout=subprocess.DEVNULL).returncode == 0:
            assert time.monotonic() < deadline
            time.sleep(.03)
        run(["status", "brokers"], expected=1, contains="FILTERED_BROKER_NOT_READY")
        # Existing owner-controlled model state only: no new endpoint/listener or
        # provider request. Future brokers must be prepared under transport proof.
        model_path = state / "model.json"
        model = json.loads(model_path.read_text()) if model_path.exists() else {}
        model["mode"] = "local"
        model_path.write_text(json.dumps(model))
        model_path.chmod(0o600)
        before_transition = [key(provider).read_bytes() for provider in ["anthropic", "openai"]]
        run(["model", "brokers", "remote"])
        run(["exec", "brokers", "--", "true"])
        after_model = json.loads(model_path.read_text()) if model_path.exists() else {}
        assert after_model.get("mode", "remote") == "remote"
        assert all(key(provider).read_bytes() != old for provider, old in zip(["anthropic", "openai"], before_transition))
        print("PASS local-to-remote preparation avoids ordering deadlock and completes composite proof", flush=True)
        run(["stop", "brokers"])
        assert all(not key(provider).exists() for provider in ["anthropic", "openai"])
        run(["start", "brokers", "--no-github"])
        assert all(key(provider).read_bytes() != value for provider, value in zip(["anthropic", "openai"], values))
        run(["exec", "brokers", "--", "true"])
        print("PASS terminated broker becomes unhealthy; stop clears state, restart rotates keys and restores composite proof", flush=True)
        # Skipping broker bootstrap does not waive configured broker requirements.
        run(["stop", "brokers"])
        text, _ = run(["start", "brokers", "--no-agents", "--no-github"], expected=1, contains="FILTERED_BROKER_NOT_READY")
        assert "Running post_start hook" not in text, "hook release attempted without required brokers"
        print("PASS --no-agents does not release a project hook with missing configured brokers", flush=True)
        run(["stop", "brokers"])
        without_hook = json.loads(config.read_text())
        without_hook.pop("post_start")
        config.write_text(json.dumps(without_hook))
        run(["start", "brokers", "--no-agents", "--no-github"], expected=1, contains="FILTERED_BROKER_NOT_READY")
        run(["stop", "brokers"])
        run(["start", "brokers", "--no-github"])
        run(["exec", "brokers", "--", "true"])
        print("PASS no-hook startup still requires every broker; normal no-hook bootstrap restores healthy proof", flush=True)
        if only == "brokers":
            print("PASS selected brokers VM gate (other phases not run)", flush=True)
            return
        exercise_egress(state, binary, config, run)
        exercise_revocation(state, binary, config, run)
        exercise_network(work, config, run)
    finally:
        # A failed configuration probe must not prevent owned-resource cleanup.
        config.write_text(cleanup_configuration)
        run(["destroy", "--all"], timeout=240)
        owner_path = work / "data/backends/apple-container-v1/owner.json"
        if owner_path.exists():
            prefix = "local/iso-" + json.loads(owner_path.read_text())["owner_id"][:8]
            images = subprocess.check_output([builder_cli, "image", "list", "--quiet"], env=env, text=True)
            for image in images.splitlines():
                if image.startswith((prefix + ":", prefix + "-maintenance:")):
                    subprocess.run([builder_cli, "image", "delete", image], env=env, check=True)
        shutil.rmtree(work)
        print("cleaned private VM, images, workspace and binary copies", flush=True)
    print("PASS filtered transport, broker, pressure and network probes; native agents and full NET-20/F1 qualification remain separate", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=("brokers", "egress", "revocation", "network"),
                        help="run one phase for diagnosis; default runs all phases")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="iso-filtered-brokers-"))
    os.chmod(work, 0o700)
    print(f"Artifacts: {work}", flush=True)
    try:
        exercise(work, args.only)
    except BaseException:
        # Before VM/image setup there are only private binary/config copies.
        if work.exists() and not (work / "data").exists():
            shutil.rmtree(work)
        raise


if __name__ == "__main__":
    main()
