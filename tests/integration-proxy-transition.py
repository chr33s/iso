#!/usr/bin/env python3
"""Real Apple sandbox gate for the Swift proxy, using fake credentials.

Requires scripts/build-proxy-transition.py first. Builds a private runtime and
VM image, checks guest refusal paths, checks Swift startup failures, and tears down.
The optional controlled-upstream phase sends allowed operations only to local
TLS fixtures. Live agent/provider smoke is separate.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time

from proxy_vm_forwarding import exercise as exercise_controlled_upstream

ROOT = Path(__file__).resolve().parents[1]
FAKES = ["proxy-vm-test-openai", "proxy-vm-test-anthropic", "proxy-vm-host-openai", "proxy-vm-host-anthropic"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controlled-upstream", action="store_true",
                        help="also test admitted streaming through local TLS; requires sudo access to bind 443")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="coop-proxy-vm-"))
    print(f"Artifacts: {work}", flush=True)
    log = (work / "run.log").open("w")
    env = {key: os.environ[key] for key in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR"] if key in os.environ}
    env.update(OPENAI_API_KEY=FAKES[2], ANTHROPIC_API_KEY=FAKES[3])
    config = work / "coop.toml"
    host = work / "bin/coop"
    data = work / "data"
    state = data / "backends/apple-container-v1"
    provider = next((Path(p) for p in ["/opt/homebrew/bin/container", "/usr/local/bin/container"] if Path(p).is_file()), None)
    assert provider, "Apple container CLI is required"
    def run(argv, *, capture=False, timeout=1200, check=True, input=None):
        with subprocess.Popen([str(a) for a in argv], cwd=ROOT, env=env,
                              stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                              stdout=subprocess.PIPE if capture else log, stderr=log,
                              text=True, start_new_session=True) as process:
            try:
                output, _ = process.communicate(input=input, timeout=timeout)
            except BaseException:
                # Every spawned build/SSH child belongs to this private group.
                # Stop the whole group on timeout or interruption before cleanup.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise
            result = subprocess.CompletedProcess(process.args, process.returncode, output)
        if check and result.returncode:
            raise RuntimeError(f"command failed ({result.returncode}); inspect {work / 'run.log'}")
        return result.stdout if capture else result.returncode
    def coop(*args, **kwargs):
        return run([host, "--config", config, *args], **kwargs)
    def phase(name):
        print(name, flush=True)
        log.write(f"\n=== {name} ===\n")
        log.flush()
    def guest_proxy(name):
        guest_env = coop("exec", name, "--", "env", capture=True)
        assert all(secret not in guest_env for secret in FAKES), "provider credential leaked into guest environment"
        settings = coop("exec", name, "--", "cat", "./.codex/config.toml", capture=True)
        assert all(secret not in settings for secret in FAKES)
        endpoint = re.search(r"http://127\.0\.0\.1:[0-9]+", settings)
        assert endpoint, "guest configuration lacks proxy endpoint"
        token = next(line.partition("=")[2] for line in guest_env.splitlines() if line.startswith("COOP_LOCAL_API_KEY="))
        assert re.fullmatch(r"[0-9a-f]{64}", token), "guest lacks a valid capability"
        return endpoint[0], token
    def refused(name, endpoint, token, expected):
        headers = ["-H", f"Authorization: Bearer {token}"] if token else []
        status = coop("exec", name, "--", "curl", "--silent", "--max-time", "10",
                      "--output", "/dev/null", "--write-out", "%{http_code}", *headers,
                      endpoint + "/v1/responses", capture=True)
        assert status.strip() == str(expected), f"{name}: guest refusal status expected {expected}"
    succeeded = False
    try:
        phase("Build private runtime")
        run([ROOT / "scripts/build-coop-sandbox.sh", work])
        if args.controlled_upstream:
            run(["swift", "test", "--package-path", ROOT / "coop-proxy",
                 "--force-resolved-versions", "--filter", "VMProxyFixture"])
        for name in ["coop", "coop-proxy"]:
            shutil.copy2(ROOT / "target/debug" / name, work / "bin" / name)
        kernel = (Path.home() / "Library/Application Support/com.apple.container/kernels/default.kernel-arm64").resolve(strict=True)
        # JSON string quoting is compatible with TOML basic strings for these host paths.
        config.write_text(f'''data_dir = {json.dumps(str(data))}
github = "off"
[vm]
vcpu_count = 2
mem_size_mib = 4096
template_size_gib = 16
[apple_container]
binary = {json.dumps(str(work / "bin/coop-sandbox"))}
builder = {json.dumps(str(provider))}
kernel = {json.dumps(str(kernel))}
[proxy.openai]
credential = "{FAKES[0]}"
auth = "bearer"
[proxy.anthropic]
credential = "{FAKES[1]}"
auth = "bearer"
''')
        (work / "project").mkdir()
        (work / "peer-project").mkdir()
        phase("Build VM images")
        coop("setup", "-y")
        phase(f"Boot and bootstrap with Swift")
        coop("up", work / "project", "--name", "proxy-gate", "--no-github", "--no-devcontainer")
        coop("up", work / "peer-project", "--name", "proxy-peer", "--no-github", "--no-devcontainer")
        phase("Install guest scanner dependency")
        coop("exec", "proxy-gate", "--", "sudo", "apt-get", "update")
        coop("exec", "proxy-gate", "--", "sudo", "apt-get", "install", "-y", "--no-install-recommends", "python3")
        endpoint, token = guest_proxy("proxy-gate")
        peer_endpoint, peer_token = guest_proxy("proxy-peer")
        assert token != peer_token, "VMs share a capability"
        # GET is always forbidden, so even a broken capability gate cannot
        # cause a model operation or deliver the synthetic credential.
        phase(f"Swift: guest gate and cross-VM capability rejection")
        refused("proxy-gate", endpoint, None, 401)
        refused("proxy-gate", endpoint, token, 403)
        refused("proxy-gate", endpoint, peer_token, 401)
        refused("proxy-peer", peer_endpoint, peer_token, 403)
        refused("proxy-peer", peer_endpoint, token, 401)
        phase(f"Swift: scan guest files for synthetic credentials")
        scanner = (ROOT / "tests/fixtures/credential-proxy/scan-guest-secrets.py").read_text()
        observation = json.loads(coop("shell", "proxy-gate", "--", "sudo", "python3", "-c",
                                      scanner, input=json.dumps(FAKES), capture=True))
        assert observation["matches"] == 0 and observation["canary_detected_and_removed"]
        log.write(json.dumps(observation) + "\n")
        instance = state / "instances/proxy-gate"
        for name in ["openai", "anthropic"]:
            pid = int((instance / f"proxy-{name}.pid").read_text().strip())
            command = run(["ps", "-p", str(pid), "-o", "comm="], capture=True, timeout=10)
            expected = "coop-proxy"
            assert expected in command, "launcher selected the wrong implementation"
        phase(f"Swift: proxy termination is visible to the guest client")
        pid = int((instance / "proxy-openai.pid").read_text().strip())
        selected_name = "coop-proxy"
        command = run(["ps", "-p", str(pid), "-o", "comm="], capture=True, timeout=10).strip()
        assert Path(command).resolve(strict=True) == (work / "bin" / selected_name).resolve(strict=True), \
            f"proxy identity changed before termination: {command}"
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while True:
            with socket.socket() as peer:
                peer.settimeout(1)
                if peer.connect_ex(("127.0.0.1", int(endpoint.rsplit(":", 1)[1]))) != 0:
                    break
            assert time.monotonic() < deadline, "terminated proxy listener remains open"
            time.sleep(0.02)
        log.flush()
        offset = os.lseek(log.fileno(), 0, os.SEEK_CUR)
        status = coop("exec", "proxy-gate", "--", "curl", "--silent", "--show-error", "--max-time", "10",
                      "--output", "/dev/null", endpoint + "/v1/responses", check=False)
        log.flush()
        diagnostic = (work / "run.log").read_bytes()[offset:].decode(errors="replace")
        assert status != 0 and re.search(r"curl: \((7|52|56)\)", diagnostic), "guest did not report a curl transport failure"
        phase(f"Swift: actual agents report terminated proxy transport failure")
        # Stop the other provider too: these probes must never send a model
        # operation to an upstream, even with this gate's synthetic keys.
        claude_settings = json.loads(coop("exec", "proxy-gate", "--", "cat",
                                         "./.claude/settings.json", capture=True))["env"]
        claude_endpoint = claude_settings["ANTHROPIC_BASE_URL"]
        assert re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", claude_endpoint)
        claude_pid = int((instance / "proxy-anthropic.pid").read_text().strip())
        command = run(["ps", "-p", str(claude_pid), "-o", "comm="], capture=True, timeout=10).strip()
        assert Path(command).resolve(strict=True) == (work / "bin" / selected_name).resolve(strict=True)
        os.kill(claude_pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while True:
            with socket.socket() as probe:
                probe.settimeout(1)
                if probe.connect_ex(("127.0.0.1", int(claude_endpoint.rsplit(":", 1)[1]))) != 0:
                    break
            assert time.monotonic() < deadline, "terminated Anthropic listener remains open"
            time.sleep(0.02)
        agent_probe = (ROOT / "tests/fixtures/credential-proxy/agent-tool-smoke.py").read_text()
        for agent in ["codex", "claude"]:
            observation = json.loads(coop(
                "shell", "proxy-gate", "--", "python3", "-c", agent_probe,
                "--agent", agent, "--model", "coop-transport-failure-probe",
                "--expect-transport-failure", capture=True, timeout=330))
            assert observation["terminal_transport_failure"] is True
            assert observation["tool_result_and_final_answer"] is False
            log.write(json.dumps(observation) + "\n")
        phase(f"Stop Swift and verify listener teardown")
        coop("stop", "proxy-gate")
        port = int(endpoint.rsplit(":", 1)[1])
        with socket.socket() as peer:
            peer.settimeout(1)
            assert peer.connect_ex(("127.0.0.1", port)) != 0, "proxy listener survived stop"
        selected = work / "bin/coop-proxy"
        saved = work / "bin/coop-proxy.saved"
        selected.rename(saved)
        try:
            for failure in ["missing", "exits"]:
                phase(f"Swift {failure}: launch must fail closed")
                if failure == "exits":
                    # Do not copy macOS protected-system file flags.
                    shutil.copyfile("/usr/bin/false", selected)
                    selected.chmod(0o755)
                log.flush()
                offset = os.lseek(log.fileno(), 0, os.SEEK_CUR)
                status = coop("start", "proxy-gate", "--no-github", check=False)
                assert status != 0, "failed Swift startup silently fell back or succeeded"
                log.flush()
                diagnostic = (work / "run.log").read_bytes()[offset:].decode(errors="replace")
                if failure == "missing":
                    assert "Swift proxy coop-proxy not found" in diagnostic
                else:
                    assert any(marker in diagnostic for marker in [
                        "credential proxy exited before it began serving",
                        "Failed to write proxy startup config to stdin",
                    ]), "launch failed for an unexpected reason"
                for name in ["openai", "anthropic"]:
                    assert not (instance / f"proxy-{name}.pid").exists(), "failed startup left a proxy running"
                coop("stop", "proxy-gate")
        finally:
            selected.unlink(missing_ok=True)
            saved.rename(selected)
        if args.controlled_upstream:
            phase("Controlled TLS upstream through the real guest reverse tunnels")
            coop("start", "proxy-gate", "--no-github")
            openai_endpoint, openai_token = guest_proxy("proxy-gate")
            claude = json.loads(coop("exec", "proxy-gate", "--", "cat", "./.claude/settings.json", capture=True))["env"]
            providers = [
                ("openai", openai_endpoint, openai_token, FAKES[0]),
                ("anthropic", claude["ANTHROPIC_BASE_URL"], claude["ANTHROPIC_AUTH_TOKEN"], FAKES[1]),
            ]
            for provider_name, endpoint, token, credential in providers:
                # Replace only this owned proxy process; keep its real SSH tunnel.
                pid = int((instance / f"proxy-{provider_name}.pid").read_text())
                command = run(["ps", "-p", str(pid), "-o", "comm="], capture=True, timeout=10).strip()
                assert Path(command).resolve(strict=True) == (work / "bin/coop-proxy").resolve(strict=True)
                os.kill(pid, signal.SIGTERM)
                port = int(endpoint.rsplit(":", 1)[1])
                deadline = time.monotonic() + 5
                while True:
                    with socket.socket() as probe:
                        probe.settimeout(1)
                        if probe.connect_ex(("127.0.0.1", port)) != 0:
                            break
                    assert time.monotonic() < deadline, "production proxy did not release fixture port"
                    time.sleep(0.02)
                result = exercise_controlled_upstream(
                    work / ("tls-" + provider_name), provider_name, port, token, credential,
                    [str(host), "--config", str(config), "shell", "proxy-gate", "--"], log)
                log.write(json.dumps(result) + "\n")
                log.flush()
            coop("stop", "proxy-gate")
        phase("PASS Swift launch, guest isolation checks, startup failures, and teardown")
        succeeded = True
    finally:
        cleanup_errors = []
        if host.exists() and config.exists():
            phase("Cleanup private VMs")
            for name in ["proxy-peer", "proxy-gate"]:
                if (state / "instances" / name).exists():
                    try:
                        coop("destroy", name, timeout=120)
                    except Exception as error:
                        cleanup_errors.append(error)
            owner_file = state / "owner.json"
            if owner_file.exists():
                owner = json.loads(owner_file.read_text())["owner_id"][:8]
                images = run([provider, "image", "list", "--quiet"], capture=True, check=False, timeout=30) or ""
                for image in images.splitlines():
                    if image.startswith(f"local/coop-{owner}"):
                        try:
                            run([provider, "image", "delete", image], timeout=30)
                        except Exception as error:
                            cleanup_errors.append(error)
        log.close()
        succeeded = succeeded and not cleanup_errors
        if succeeded:
            # Preserve the complete transcript for callers that redirect stdout
            # before removing the private runtime and disks.
            print((work / "run.log").read_text(), flush=True)
            shutil.rmtree(work)
        else:
            print(f"Failure artifacts retained: {work}", flush=True)
        if cleanup_errors:
            raise RuntimeError(f"VM gate cleanup failed; inspect {work / 'run.log'}") from cleanup_errors[0]


if __name__ == "__main__":
    main()
