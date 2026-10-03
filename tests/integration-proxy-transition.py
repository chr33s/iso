#!/usr/bin/env python3
"""Real Apple sandbox gate for the Swift proxy, using fake credentials.

Builds the Swift host, iso-proxy and a private runtime and VM image (or uses
`--iso PATH` for a prebuilt host), checks guest refusal paths, checks Swift
proxy startup failures, and tears down.
The optional controlled-upstream phase sends allowed operations only to local
TLS fixtures.

`--live-agents` instead runs the H-07 in-guest agent tool-use check with real,
dedicated credentials: it boots one throwaway VM whose proxies read the
credentials through `cmd:` references (Keychain items by default), checks the
guest's loopback proxy endpoints and the running proxy binary, then runs
`agent-tool-smoke.py` once per model named with `--claude-model`/`--codex-model`.
No model is selected implicitly. Credential values never pass through this
script.
"""
import hashlib
import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

from proxy_vm_forwarding import exercise as exercise_controlled_upstream, https_listener

ROOT = Path(__file__).resolve().parents[1]
AGENT_PROBE = "/tmp/iso-agent-tool-smoke.py"
LIVE_CREDENTIALS = {
    provider_name: f"cmd:security find-generic-password -s iso-live-{provider_name} -a iso-live -w"
    for provider_name in ["anthropic", "openai"]
}
FAKES = ["proxy-vm-test-openai", "proxy-vm-test-anthropic", "proxy-vm-host-openai", "proxy-vm-host-anthropic"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controlled-upstream", action="store_true",
                        help="also test admitted streaming through local TLS; reserves port 443 before setup (may prompt for sudo)")
    parser.add_argument("--controlled-upstream-preflight", action="store_true",
                        help="test both local confined TLS streams on port 443 without building or booting VMs")
    parser.add_argument("--iso", "--swift-host", dest="iso", type=Path,
                        help="use this prebuilt iso host instead of building it with swift build")
    live = parser.add_argument_group("live agent tool use (H-07; real credentials, billed)")
    live.add_argument("--live-agents", action="store_true",
                      help="run only the in-guest agent tool-use check with dedicated credentials")
    live.add_argument("--filtered", action="store_true",
                      help="qualify live guest agents under filtered egress with no approved CONNECT destinations")
    live.add_argument("--claude-model", action="append", default=[], metavar="MODEL",
                      help="approved Anthropic model for `--agent claude` (repeatable)")
    live.add_argument("--codex-model", action="append", default=[], metavar="MODEL",
                      help="approved OpenAI model for `--agent codex` (repeatable)")
    live.add_argument("--anthropic-credential", default=LIVE_CREDENTIALS["anthropic"], metavar="CMD_REF",
                      help="`cmd:` reference for the dedicated Anthropic credential (default: iso-live-anthropic Keychain item)")
    live.add_argument("--anthropic-auth", choices=["api_key", "bearer"], default="api_key")
    live.add_argument("--openai-credential", default=LIVE_CREDENTIALS["openai"], metavar="CMD_REF",
                      help="`cmd:` reference for the dedicated OpenAI credential (default: iso-live-openai Keychain item)")
    args = parser.parse_args()
    if args.filtered and not args.live_agents:
        parser.error("--filtered requires --live-agents")
    if args.live_agents:
        if args.controlled_upstream or args.controlled_upstream_preflight:
            parser.error("--live-agents runs on its own; run --controlled-upstream separately")
        if not (args.claude_model or args.codex_model):
            parser.error("--live-agents needs at least one --claude-model or --codex-model")
        for reference in [args.anthropic_credential, args.openai_credential]:
            if not reference.startswith("cmd:"):
                parser.error("live credentials must be `cmd:` references, never values")
    elif args.claude_model or args.codex_model:
        parser.error("--claude-model/--codex-model require --live-agents")
    if args.controlled_upstream_preflight:
        args.controlled_upstream = True
    work = Path(tempfile.mkdtemp(prefix="iso-proxy-vm-"))
    print(f"Artifacts: {work}", flush=True)
    log = (work / "run.log").open("w")
    env = {key: os.environ[key] for key in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR"] if key in os.environ}
    env.update(OPENAI_API_KEY=FAKES[2], ANTHROPIC_API_KEY=FAKES[3])
    config = work / "iso.jsonc"
    host = work / "bin/iso"
    data = work / "data"
    state = data / "backends/apple-container-v1"
    provider = shutil.which("container")
    assert provider, "Apple container CLI is required"
    provider = Path(provider).resolve(strict=True)
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
    def iso(*args, **kwargs):
        return run([host, "--config", config, *args], **kwargs)
    def phase(name):
        print(name, flush=True)
        log.write(f"\n=== {name} ===\n")
        log.flush()
    def guest_proxy(name):
        guest_env = iso("exec", name, "--", "env", capture=True)
        assert all(secret not in guest_env for secret in FAKES), "provider credential leaked into guest environment"
        settings = iso("exec", name, "--", "cat", "./.codex/config.toml", capture=True)
        assert all(secret not in settings for secret in FAKES)
        endpoint = re.search(r"http://127\.0\.0\.1:[0-9]+", settings)
        assert endpoint, "guest configuration lacks proxy endpoint"
        token = next(line.partition("=")[2] for line in guest_env.splitlines() if line.startswith("ISO_LOCAL_API_KEY="))
        assert re.fullmatch(r"[0-9a-f]{64}", token), "guest lacks a valid capability"
        return endpoint[0], token
    def refused(name, endpoint, token, expected):
        headers = ["-H", f"Authorization: Bearer {token}"] if token else []
        status = iso("exec", name, "--", "curl", "--silent", "--max-time", "10",
                      "--output", "/dev/null", "--write-out", "%{http_code}", *headers,
                      endpoint + "/v1/responses", capture=True)
        assert status.strip() == str(expected), f"{name}: guest refusal status expected {expected}"
    def install_agent_probe(name):
        # Copy the probe in once over stdin so iso's command log stays one line.
        probe = (ROOT / "tests/fixtures/credential-proxy/agent-tool-smoke.py").read_text()
        iso("shell", name, "--", "sh", "-c", f"cat > {AGENT_PROBE}", input=probe)

    def live_agents(args):
        name = "proxy-live"
        phase("Live: boot a throwaway VM with dedicated credentials")
        profile = ["--profile", "proxy-filtered-acceptance"] if args.filtered else []
        iso("up", work / "project", "--name", name, "--no-github", "--no-devcontainer", *profile)
        if not args.filtered:
            iso("exec", name, "--", "sudo", "apt-get", "update")
            iso("exec", name, "--", "sudo", "apt-get", "install", "-y", "--no-install-recommends", "python3")
        else:
            # Dependencies were baked during image preparation; never open a
            # filtered workload's network to install them.
            iso("exec", name, "--", "python3", "--version")
            network = json.loads((state / "instances" / name / "network-policy.json").read_text())
            assert network["mode"] == "filtered" and network["allowedHosts"] == []
            phase("Live: filtered boot policy has no approved CONNECT destinations")
        phase("Live: guest endpoints and proxy identity")
        instance = state / "instances" / name
        expected = hashlib.sha256((work / "bin/iso-proxy").read_bytes()).hexdigest()
        endpoints = {}
        if args.claude_model:
            claude = json.loads(iso("exec", name, "--", "cat", "./.claude/settings.json", capture=True))["env"]
            endpoints["anthropic"] = claude["ANTHROPIC_BASE_URL"]
            assert re.fullmatch(r"[0-9a-f]{64}", claude["ANTHROPIC_AUTH_TOKEN"]), "Claude lacks a capability"
        if args.codex_model:
            settings = iso("exec", name, "--", "cat", "./.codex/config.toml", capture=True)
            endpoint = re.search(r"http://127\.0\.0\.1:[0-9]+", settings)
            assert endpoint, "Codex configuration lacks the proxy endpoint"
            endpoints["openai"] = endpoint[0]
        for provider_name, endpoint in endpoints.items():
            assert re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", endpoint), f"{provider_name}: endpoint is not guest loopback"
            pid = int((instance / f"proxy-{provider_name}.pid").read_text().strip())
            command = Path(run(["ps", "-p", str(pid), "-o", "comm="], capture=True, timeout=10).strip())
            assert command.resolve(strict=True) == (work / "bin/iso-proxy").resolve(strict=True), \
                f"{provider_name}: unexpected proxy executable {command}"
            actual = hashlib.sha256(command.read_bytes()).hexdigest()
            assert actual == expected, f"{provider_name}: proxy binary changed"
            record = {"provider": provider_name, "guest_endpoint": endpoint, "proxy_sha256": actual,
                      "egress": "filtered" if args.filtered else "open"}
            print(json.dumps(record), flush=True)
            log.write(json.dumps(record) + "\n")
        install_agent_probe(name)
        failures = []
        for agent, models in [("claude", args.claude_model), ("codex", args.codex_model)]:
            for model in models:
                phase(f"Live: {agent} tool use with {model}")
                output = iso("shell", name, "--", "python3", AGENT_PROBE,
                              "--agent", agent, "--model", model, capture=True, timeout=240, check=False)
                try:
                    observation = json.loads(output.strip().splitlines()[-1])
                    assert observation["tool_result_and_final_answer"] is True
                except (IndexError, ValueError, KeyError, AssertionError):
                    failures.append(f"{agent} {model}")
                    print(f"FAIL {agent} {model}; inspect {work / 'run.log'}", flush=True)
                    continue
                print(json.dumps(observation), flush=True)
                log.write(json.dumps(observation) + "\n")
        assert not failures, "live agent tool use failed: " + ", ".join(failures)
        iso("stop", name)
        phase("PASS live agent tool use through the guest proxy")

    succeeded = False
    listener_scope = contextlib.ExitStack()
    try:
        if args.controlled_upstream:
            phase("Reserve controlled TLS listener on 127.0.0.1:443")
            listener = listener_scope.enter_context(https_listener(work, log, interactive=sys.stdin.isatty()))
        if args.controlled_upstream:
            run(["swift", "test", "--package-path", ROOT / "iso-proxy",
                 "--force-resolved-versions", "--filter", "VMProxyFixture"])
            phase("Preflight both controlled TLS streams without VMs")
            for provider_name in ["openai", "anthropic"]:
                with socket.socket() as available:
                    available.bind(("127.0.0.1", 0))
                    port = available.getsockname()[1]
                result = exercise_controlled_upstream(
                    work / ("preflight-" + provider_name), provider_name, port,
                    "0" * 64, "synthetic-preflight-credential", [], log, listener=listener)
                log.write(json.dumps(result) + "\n")
                log.flush()
            if args.controlled_upstream_preflight:
                phase("PASS controlled TLS preflight (no VM coverage)")
                succeeded = True
                return
        phase("Build private runtime")
        run([ROOT / "scripts/build-iso-sandbox.sh", work])
        phase("Build iso and iso-proxy")
        if args.iso:
            iso_binary = args.iso
        else:
            run(["swift", "build", "--product", "iso", "--force-resolved-versions"])
            iso_binary = Path(run(["swift", "build", "--show-bin-path"], capture=True).strip()) / "iso"
        proxy_package = ROOT / "iso-proxy"
        run(["swift", "build", "--package-path", proxy_package, "--force-resolved-versions"])
        proxy_bin = Path(run(["swift", "build", "--package-path", proxy_package, "--show-bin-path"],
                             capture=True).strip())
        shutil.copy2(iso_binary, work / "bin/iso")
        shutil.copy2(proxy_bin / "iso-proxy", work / "bin/iso-proxy")
        if args.filtered:
            egress_package = ROOT / "iso-egress"
            run(["swift", "build", "--package-path", egress_package, "--force-resolved-versions"])
            egress_bin = Path(run(["swift", "build", "--package-path", egress_package, "--show-bin-path"],
                                  capture=True).strip())
            shutil.copy2(egress_bin / "iso-egress", work / "bin/iso-egress")
        kernel = (Path.home() / "Library/Application Support/com.apple.container/kernels/default.kernel-arm64").resolve(strict=True)
        # Proxy credentials are `cmd:` references; outside --live-agents the
        # values stay synthetic.
        if args.live_agents:
            proxies = {}
            if args.claude_model:
                proxies["anthropic"] = {"credential": args.anthropic_credential, "auth": args.anthropic_auth}
            if args.codex_model:
                proxies["openai"] = {"credential": args.openai_credential, "auth": "bearer"}
        else:
            proxies = {provider_name: {"credential": f"cmd:printf %s {fake}", "auth": "bearer"}
                       for provider_name, fake in [("openai", FAKES[0]), ("anthropic", FAKES[1])]}
        configuration = {
            "data_dir": str(data), "github": "off",
            "vm": {"vcpu_count": 2, "mem_size_mib": 4096, "template_size_gib": 16},
            "apple_container": {"binary": str(work / "bin/iso-sandbox"), "builder": str(provider),
                                "kernel": str(kernel)},
            "proxy": proxies,
        }
        if args.filtered:
            configuration.update(egress="filtered", egress_filter={"allowed_hosts": []},
                                 profiles={"proxy-filtered-acceptance": {"apt_packages": ["python3"]}})
        config.write_text(json.dumps(configuration, indent=2) + "\n")
        (work / "project").mkdir()
        (work / "peer-project").mkdir()
        phase("Build VM images")
        iso("setup", "-y", *(["--profile", "proxy-filtered-acceptance"] if args.filtered else []))
        if args.live_agents:
            live_agents(args)
            succeeded = True
            return
        phase(f"Boot and bootstrap with Swift")
        iso("up", work / "project", "--name", "proxy-gate", "--no-github", "--no-devcontainer")
        iso("up", work / "peer-project", "--name", "proxy-peer", "--no-github", "--no-devcontainer")
        phase("Install guest scanner dependency")
        iso("exec", "proxy-gate", "--", "sudo", "apt-get", "update")
        iso("exec", "proxy-gate", "--", "sudo", "apt-get", "install", "-y", "--no-install-recommends", "python3")
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
        observation = json.loads(iso("shell", "proxy-gate", "--", "sudo", "python3", "-c",
                                      scanner, input=json.dumps(FAKES), capture=True))
        assert observation["matches"] == 0 and observation["canary_detected_and_removed"]
        log.write(json.dumps(observation) + "\n")
        instance = state / "instances/proxy-gate"
        for name in ["openai", "anthropic"]:
            pid = int((instance / f"proxy-{name}.pid").read_text().strip())
            command = run(["ps", "-p", str(pid), "-o", "comm="], capture=True, timeout=10)
            expected = "iso-proxy"
            assert expected in command, "launcher selected the wrong implementation"
        phase(f"Swift: proxy termination is visible to the guest client")
        pid = int((instance / "proxy-openai.pid").read_text().strip())
        selected_name = "iso-proxy"
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
        status = iso("exec", "proxy-gate", "--", "curl", "--silent", "--show-error", "--max-time", "10",
                      "--output", "/dev/null", endpoint + "/v1/responses", check=False)
        log.flush()
        diagnostic = (work / "run.log").read_bytes()[offset:].decode(errors="replace")
        assert status != 0 and re.search(r"curl: \((7|52|56)\)", diagnostic), "guest did not report a curl transport failure"
        phase(f"Swift: actual agents report terminated proxy transport failure")
        # Stop the other provider too: these probes must never send a model
        # operation to an upstream, even with this gate's synthetic keys.
        claude_settings = json.loads(iso("exec", "proxy-gate", "--", "cat",
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
        install_agent_probe("proxy-gate")
        for agent in ["codex", "claude"]:
            observation = json.loads(iso(
                "shell", "proxy-gate", "--", "python3", AGENT_PROBE,
                "--agent", agent, "--model", "iso-transport-failure-probe",
                "--expect-transport-failure", capture=True, timeout=330))
            assert observation["terminal_transport_failure"] is True
            assert observation["tool_result_and_final_answer"] is False
            log.write(json.dumps(observation) + "\n")
        phase(f"Stop Swift and verify listener teardown")
        iso("stop", "proxy-gate")
        port = int(endpoint.rsplit(":", 1)[1])
        with socket.socket() as peer:
            peer.settimeout(1)
            assert peer.connect_ex(("127.0.0.1", port)) != 0, "proxy listener survived stop"
        selected = work / "bin/iso-proxy"
        saved = work / "bin/iso-proxy.saved"
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
                status = iso("start", "proxy-gate", "--no-github", check=False)
                assert status != 0, "failed Swift startup silently fell back or succeeded"
                log.flush()
                diagnostic = (work / "run.log").read_bytes()[offset:].decode(errors="replace")
                if failure == "missing":
                    assert "Swift proxy iso-proxy not found" in diagnostic
                else:
                    assert any(marker in diagnostic for marker in [
                        "credential proxy exited before it began serving",
                        "Failed to write proxy startup config to stdin",
                    ]), "launch failed for an unexpected reason"
                for name in ["openai", "anthropic"]:
                    assert not (instance / f"proxy-{name}.pid").exists(), "failed startup left a proxy running"
                iso("stop", "proxy-gate")
        finally:
            selected.unlink(missing_ok=True)
            saved.rename(selected)
        if args.controlled_upstream:
            phase("Controlled TLS upstream through the real guest reverse tunnels")
            iso("start", "proxy-gate", "--no-github")
            openai_endpoint, openai_token = guest_proxy("proxy-gate")
            claude = json.loads(iso("exec", "proxy-gate", "--", "cat", "./.claude/settings.json", capture=True))["env"]
            providers = [
                ("openai", openai_endpoint, openai_token, FAKES[0]),
                ("anthropic", claude["ANTHROPIC_BASE_URL"], claude["ANTHROPIC_AUTH_TOKEN"], FAKES[1]),
            ]
            for provider_name, endpoint, token, credential in providers:
                # Replace only this owned proxy process; keep its real SSH tunnel.
                pid = int((instance / f"proxy-{provider_name}.pid").read_text())
                command = run(["ps", "-p", str(pid), "-o", "comm="], capture=True, timeout=10).strip()
                assert Path(command).resolve(strict=True) == (work / "bin/iso-proxy").resolve(strict=True)
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
                    [str(host), "--config", str(config), "shell", "proxy-gate", "--"], log,
                    listener=listener)
                log.write(json.dumps(result) + "\n")
                log.flush()
            iso("stop", "proxy-gate")
        phase("PASS Swift launch, guest isolation checks, startup failures, and teardown")
        succeeded = True
    finally:
        cleanup_errors = []
        try:
            listener_scope.close()
        except Exception as error:
            cleanup_errors.append(error)
        if host.exists() and config.exists():
            phase("Cleanup private VMs")
            for name in ["proxy-live", "proxy-peer", "proxy-gate"]:
                if (state / "instances" / name).exists():
                    try:
                        iso("destroy", name, timeout=120)
                    except Exception as error:
                        cleanup_errors.append(error)
            owner_file = state / "owner.json"
            if owner_file.exists():
                owner = json.loads(owner_file.read_text())["owner_id"][:8]
                images = run([provider, "image", "list", "--quiet"], capture=True, check=False, timeout=30) or ""
                for image in images.splitlines():
                    if image.startswith(f"local/iso-{owner}"):
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
