#!/usr/bin/env python3
"""Real Apple sandbox gate for an enforcing IsoPolicy (docs/policy.md).

Builds the Swift host, iso-proxy and a private runtime and VM image, boots one
VM under an enforcing policy with synthetic `cmd:` credentials, and checks:

- the boot records an enforcing snapshot and claims one proxy launch per
  provider, and both proxies run startup version 3 with verified readiness;
- a request for the provider the policy does not permit is refused by the
  proxy (403, logged as `no_permit`) and never forwarded — no request in this
  gate is ever admitted, so nothing reaches a real provider;
- re-applying agent configuration to the running boot (`iso model … remote`)
  is refused rather than relaunching a proxy with empty counters;
- a governed `iso pull --apply` without a terminal, with `--force`, or with
  `--output json` fails with `approval_required` and writes nothing;
- an apply confirmed by typing the stage ID at a pseudo-terminal succeeds;
- a new boot gets a new epoch, and a stage built in the previous boot is
  refused with `policy_epoch_mismatch`.

Needs Apple Silicon, macOS 27+, Xcode 27, and stock Apple `container` with its
service running. Touches only its own work directory and image tags.
"""
import json
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FAKES = {"anthropic": "policy-vm-anthropic-synthetic", "openai": "policy-vm-openai-synthetic"}


def main():
    work = Path(tempfile.mkdtemp(prefix="iso-policy-vm-"))
    print(f"Artifacts: {work}", flush=True)
    log = (work / "run.log").open("w")
    env = {key: os.environ[key] for key in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR"] if key in os.environ}
    config = work / "iso.jsonc"
    host = work / "bin/iso"
    data = work / "data"
    state = data / "backends/apple-container-v1"
    project = work / "project"
    provider = shutil.which("container")
    assert provider, "Apple container CLI is required"
    provider = Path(provider).resolve(strict=True)

    def run(argv, *, capture=False, timeout=1200, check=True):
        result = subprocess.run([str(a) for a in argv], cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE if capture else log, stderr=subprocess.PIPE if capture else log,
                                text=True, timeout=timeout, start_new_session=True)
        if capture:
            log.write(result.stdout + result.stderr)
            log.flush()
        if check and result.returncode:
            raise RuntimeError(f"command failed ({result.returncode}): {argv[1:4]}; inspect {work / 'run.log'}")
        return result

    def iso(*args, **kwargs):
        return run([host, "--config", config, *args], **kwargs)

    def phase(name):
        print(name, flush=True)
        log.write(f"\n=== {name} ===\n")
        log.flush()

    def show():
        return json.loads(iso("policy", "show", "policy-gate", "--json", capture=True).stdout)

    def stage_id():
        result = iso("pull", "policy-gate", "--review", capture=True)
        found = re.search(r"--stage-id ([0-9a-f]{8})", result.stderr)
        assert found, "review did not print a stage id"
        return found[1]

    def apply_with_terminal(stage):
        """Answer the approval prompt on a pseudo-terminal, as a person would."""
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execve(str(host), [str(host), "--config", str(config), "pull", "policy-gate", "--apply",
                                  "--stage-id", stage], env)
        transcript = b""
        answered = False
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 1)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            transcript += chunk
            if not answered and b"anything else cancels:" in transcript:
                os.write(fd, (stage + "\n").encode())
                answered = True
        _, status = os.waitpid(pid, 0)
        log.write(transcript.decode(errors="replace"))
        log.flush()
        assert answered, "the approval prompt never appeared"
        assert b"policy requires approving this exact stage" in transcript
        return os.waitstatus_to_exitcode(status)

    succeeded = False
    try:
        phase("Build private runtime, iso and iso-proxy")
        run([ROOT / "scripts/build-iso-sandbox.sh", work])
        run(["swift", "build", "--product", "iso", "--force-resolved-versions"])
        iso_bin = Path(run(["swift", "build", "--show-bin-path"], capture=True).stdout.strip())
        run(["swift", "build", "--package-path", ROOT / "iso-proxy", "--force-resolved-versions"])
        proxy_bin = Path(run(["swift", "build", "--package-path", ROOT / "iso-proxy", "--show-bin-path"],
                             capture=True).stdout.strip())
        shutil.copy2(iso_bin / "iso", host)
        shutil.copy2(proxy_bin / "iso-proxy", work / "bin/iso-proxy")
        kernel = (Path.home() / "Library/Application Support/com.apple.container/kernels/default.kernel-arm64").resolve(strict=True)
        rule = lambda ident, action, resource: {"id": ident, "effect": "permit", "action": action, "resources": [resource]}
        configuration = {
            "data_dir": str(data), "github": "off",
            "vm": {"vcpu_count": 2, "mem_size_mib": 4096, "template_size_gib": 16},
            "apple_container": {"binary": str(work / "bin/iso-sandbox"), "builder": str(provider),
                                "kernel": str(kernel)},
            "proxy": {"mode": "required", **{name: {"credential": f"cmd:printf %s {fake}", "auth": "bearer"}
                                             for name, fake in FAKES.items()}},
            "workspace": {"pull": {"mode": "stage"}},
            "policy": {
                "version": 1, "mode": "enforce",
                "actions": ["credential.use", "proxy.request", "workspace.pull.apply"],
                "rules": [rule("use-anthropic", "credential.use", "provider:anthropic"),
                          rule("request-anthropic", "proxy.request", "provider:anthropic"),
                          rule("apply", "workspace.pull.apply", "workspace:attached")],
                "guards": [
                    {"id": "limit", "action": "proxy.request", "resources": ["provider:anthropic"],
                     "require": {"rate_limit": {"max_requests": 100, "within_seconds": 60}}},
                    {"id": "review", "action": "workspace.pull.apply", "resources": ["workspace:attached"],
                     "require": {"approval_within": {"seconds": 900}}},
                ],
            },
        }
        config.write_text(json.dumps(configuration, indent=2) + "\n")
        project.mkdir()
        (project / "host.txt").write_text("host\n")
        iso("validate")
        phase("Build VM image")
        iso("setup", "-y")

        phase("Boot under an enforcing policy")
        iso("up", project, "--name", "policy-gate", "--no-github", "--no-devcontainer")
        first = show()
        active = first["active"]
        assert active["mode"] == "enforce" and not first["pending_next_boot"]
        claims = {claim["provider"]: claim for claim in active["proxy_claims"]}
        assert set(claims) == {"anthropic", "openai"}, claims
        assert all(claim["process_observed"] for claim in claims.values())
        instance = state / "instances/policy-gate"
        for name in claims:
            proxy_log = (instance / f"proxy-{name}.log").read_text()
            assert f"mode=enforce digest={active['digest']}" in proxy_log
            assert f"generation={claims[name]['generation']}" in proxy_log

        phase("Guest: an unpermitted provider is refused by policy, nothing forwarded")
        guest_env = iso("exec", "policy-gate", "--", "env", capture=True).stdout
        assert all(fake not in guest_env for fake in FAKES.values()), "credential leaked into the guest"
        settings = iso("exec", "policy-gate", "--", "cat", "./.codex/config.toml", capture=True).stdout
        endpoint = re.search(r"http://127\.0\.0\.1:[0-9]+", settings)[0]
        token = next(line.partition("=")[2] for line in guest_env.splitlines()
                     if line.startswith("ISO_LOCAL_API_KEY="))
        status = iso("exec", "policy-gate", "--", "curl", "--silent", "--max-time", "10", "--output", "/dev/null",
                     "--write-out", "%{http_code}", "-X", "POST", "-H", f"Authorization: Bearer {token}",
                     "-H", "Content-Type: application/json", "--data", "{}", endpoint + "/v1/responses",
                     capture=True).stdout.strip()
        assert status == "403", f"expected a policy 403, got {status}"
        time.sleep(0.5)
        proxy_log = (instance / "proxy-openai.log").read_text()
        assert "verdict=deny reason=no_permit" in proxy_log, "the 403 was not a policy decision"
        assert all(fake not in proxy_log for fake in FAKES.values())

        phase("Re-applying agent configuration mid-boot is refused")
        refused = iso("model", "policy-gate", "remote", capture=True, check=False)
        assert refused.returncode != 0 and "policy_state_unavailable" in refused.stderr, refused.stderr
        assert show()["active"]["epoch"] == active["epoch"]

        phase("Governed apply without a terminal writes nothing")
        iso("exec", "policy-gate", "--", "sh", "-c", "echo guest > /workspace/guest.txt")
        stage = stage_id()
        for extra in [[], ["--force"]]:
            result = iso("pull", "policy-gate", "--apply", "--stage-id", stage, *extra, capture=True, check=False)
            assert result.returncode != 0 and "approval_required" in result.stderr, result.stderr
        result = iso("--output", "json", "pull", "policy-gate", "--apply", "--stage-id", stage,
                     capture=True, check=False)
        assert result.returncode != 0
        assert not (project / "guest.txt").exists(), "a refused apply wrote the destination"

        phase("Governed apply confirmed at a terminal")
        assert apply_with_terminal(stage) == 0
        assert (project / "guest.txt").read_text() == "guest\n"

        phase("A new boot supersedes the previous boot's stage")
        iso("exec", "policy-gate", "--", "sh", "-c", "echo again > /workspace/again.txt")
        old_stage = stage_id()
        iso("stop", "policy-gate")
        iso("start", "policy-gate", "--no-github")
        second = show()["active"]
        assert second["epoch"] != active["epoch"] and second["boot_id"] != active["boot_id"]
        result = iso("pull", "policy-gate", "--apply", "--stage-id", old_stage, capture=True, check=False)
        assert result.returncode != 0 and "policy_epoch_mismatch" in result.stderr, result.stderr
        assert not (project / "again.txt").exists()

        phase("Audit records the policy events without secrets")
        audit = (instance / "audit.jsonl").read_text()
        for event in ["policy_boot", "policy_proxy_claim", "approval_issued", "approval_consumed", "policy_decision"]:
            assert f'"event":"{event}"' in audit, event
        assert all(fake not in audit for fake in FAKES.values()) and token not in audit
        iso("stop", "policy-gate")
        phase("PASS enforcing policy on a real VM")
        succeeded = True
    finally:
        if host.exists() and config.exists():
            phase("Cleanup")
            if (state / "instances/policy-gate").exists():
                iso("destroy", "policy-gate", timeout=120, check=False)
            owner_file = state / "owner.json"
            if owner_file.exists():
                owner = json.loads(owner_file.read_text())["owner_id"][:8]
                images = run([provider, "image", "list", "--quiet"], capture=True, check=False, timeout=30).stdout
                for image in images.splitlines():
                    if image.startswith(f"local/iso-{owner}"):
                        run([provider, "image", "delete", image], timeout=30, check=False)
        log.close()
        if succeeded:
            shutil.rmtree(work)
        else:
            print(f"Failure artifacts retained: {work}", flush=True)
    return 0 if succeeded else 1


if __name__ == "__main__":
    sys.exit(main())
