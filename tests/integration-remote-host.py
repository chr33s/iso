#!/usr/bin/env python3
"""Native host-control qualification (Q1 slice).

With --remote it drives an enrolled second Mac. With --local it builds a
scratch data root on this Mac (like tests/integration-apple-sandbox.sh: real
iso-sandbox, real VMs, stub agents) and drives the same cases through the
local host service, which uses the same supervisor, ledger and relay.

Runs the real `iso` client against an enrolled remote Mac: enrollment and
identity, hello latency, durable create/start, a pinned sentinel round trip
through the owned guest relay, session revocation, stop/destroy and exact
cleanup. See docs/design/local-and-remote-hosts-spec.md section 18 and
docs/testing.md.

Every case records pass, fail or blocked with its evidence. A missing remote,
tool or qualified runtime blocks the cases that need it; nothing unexecuted is
reported as passing. Exit status: 0 all executed cases passed and none were
blocked, 1 any case failed, 2 no failure but some case was blocked.
Evidence never contains bearers, private keys or credentials.
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Scratch-root proxy credentials; never real, and never expected in a guest.
FAKE_CREDENTIALS = {"openai": "sk-iso-hc-fake-openai-7f3a", "anthropic": "sk-ant-iso-hc-fake-2c9e"}


class Runner:
    def __init__(self, args):
        self.args = args
        self.iso = args.iso
        self.cases = []
        self.environment = dict(os.environ)
        self.cleanup = []

    # -- evidence ---------------------------------------------------------

    def record(self, case, status, started, **evidence):
        entry = {
            "case": case,
            "status": status,
            "elapsed_seconds": round(time.monotonic() - started, 3),
            **evidence,
        }
        self.cases.append(entry)
        print(f"{case}: {status}" + (f" ({evidence.get('reason')})" if evidence.get("reason") else ""), flush=True)
        return status == "pass"

    def blocked(self, case, reason):
        return self.record(case, "blocked", time.monotonic(), reason=reason)

    def iso_cmd(self, *argv, timeout=900, check=False):
        command = [self.iso] + (["--config", self.args.config] if self.args.config else []) + list(argv)
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, env=self.environment)
        if check and result.returncode != 0:
            raise RuntimeError(f"{' '.join(argv[:3])} exited {result.returncode}: {tail(result.stderr)}")
        return result

    # -- stages -----------------------------------------------------------

    def preparation(self):
        started = time.monotonic()
        problems = []
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            problems.append(f"unsupported client platform {platform.system()}/{platform.machine()}")
        if not Path(self.iso).is_file():
            problems.append(f"iso binary not found at {self.iso}")
        if not shutil.which("ssh") or not shutil.which("scp"):
            problems.append("ssh/scp not installed")
        if problems:
            return self.record("preparation", "blocked", started, reason="; ".join(problems))
        return self.record("preparation", "pass", started)

    def enroll(self):
        started = time.monotonic()
        if self.args.local:
            return self.prepare_local(started)
        if self.args.loopback:
            if not self.prepare_local(started, record=False):
                return False
            if not self.prepare_loopback(started):
                return False
        if not self.args.remote:
            return self.blocked(
                "enroll", "no --remote host given (use --local for this Mac, or two prepared Macs)")
        if not self.args.agent_path:
            return self.blocked("enroll", "no --agent-path given")
        result = self.iso_cmd(
            "host", "add", self.args.name, "--ssh", self.args.remote, "--agent-path", self.args.agent_path,
            timeout=120)
        if result.returncode != 0:
            return self.record("enroll", "fail", started, reason=tail(result.stderr))
        return self.record("enroll", "pass", started, output=tail(result.stdout))

    def prepare_loopback(self, started):
        """This Mac as its own SSH worker, touching neither ~/.iso nor ~/.ssh:
        the worker is the scratch root behind an agent wrapper that pins its
        config, the client gets a second scratch root, and ssh pins localhost
        in a scratch known_hosts through a PATH wrapper."""
        work = self.work
        worker_config = self.args.config
        agent = work / "agent"
        agent.write_text(f"#!/bin/sh\nexec '{self.iso}' --config '{worker_config}' \"$@\"\n")
        agent.chmod(0o755)
        scan = subprocess.run(["ssh-keyscan", "-t", "ed25519", "127.0.0.1"], capture_output=True, text=True, timeout=30)
        if scan.returncode != 0 or not scan.stdout.strip():
            return self.record("enroll", "blocked", started, reason="sshd on 127.0.0.1 did not offer an ed25519 key")
        (work / "known_hosts").write_text(scan.stdout)
        bin_dir = work / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "ssh"
        # Only the management hop gets the scratch pin; guest hops carry their own.
        wrapper.write_text(
            "#!/bin/sh\ncase \"$1 $*\" in *UserKnownHostsFile=*|-F*) exec /usr/bin/ssh \"$@\" ;; esac\n"
            "exec /usr/bin/ssh -o UserKnownHostsFile=" + str(work / "known_hosts")
            + " -o GlobalKnownHostsFile=/dev/null \"$@\"\n")
        wrapper.chmod(0o755)
        self.environment["PATH"] = f"{bin_dir}:{self.environment.get('PATH', '/usr/bin:/bin')}"
        probe = subprocess.run(["ssh", "-o", "BatchMode=yes", "127.0.0.1", "true"],
                               capture_output=True, text=True, timeout=30, env=self.environment)
        if probe.returncode != 0:
            return self.record("enroll", "blocked", started,
                               reason="non-interactive ssh to 127.0.0.1 failed: " + tail(probe.stderr, 200))
        client = json.loads(Path(worker_config).read_text())
        client["data_dir"] = str(work / "client-data")
        (work / "client.jsonc").write_text(json.dumps(client))
        self.args.config = str(work / "client.jsonc")
        self.args.remote = "127.0.0.1"
        self.args.agent_path = str(agent)
        self.args.name = "loop"
        return True

    def ttl_enforcement(self):
        """Q2: an offline client's VM is stopped by the worker at its deadline."""
        started = time.monotonic()
        observation = self.iso_cmd("host", "vm", "inspect", self.args.name, self.instance, timeout=120)
        if "running" not in observation.stdout.split("\n")[0]:
            stop = self.iso_cmd("host", "vm", "stop", self.args.name, self.instance, timeout=600)
            if stop.returncode != 0:
                return self.record("ttl-offline-client", "fail", started, reason=tail(stop.stderr))
        else:
            self.iso_cmd("host", "vm", "stop", self.args.name, self.instance, timeout=600)
        ttl = 60
        start = self.iso_cmd("host", "vm", "start", self.args.name, self.instance, "--ttl", f"{ttl}s", timeout=600)
        if start.returncode != 0:
            return self.record("ttl-offline-client", "fail", started, reason=tail(start.stderr))
        booted = time.monotonic()
        # No session, no renewals: only the worker may stop it.
        while time.monotonic() - booted < ttl + 180:
            inspect = self.iso_cmd("host", "vm", "inspect", self.args.name, self.instance, timeout=120)
            if inspect.returncode == 0 and ": stopped" in inspect.stdout:
                observed = round(time.monotonic() - booted, 1)
                ok = observed <= ttl + 120
                return self.record("ttl-offline-client", "pass" if ok else "fail", started,
                                   ttl_seconds=ttl, observed_stop_seconds=observed, bound_seconds=ttl + 120)
            time.sleep(5)
        return self.record("ttl-offline-client", "fail", started, reason="the VM was still running past the bound")

    def ttl_wedged_guest(self):
        """Q2 (A15): a guest whose root defeats graceful shutdown is still
        verified stopped by deadline + 120 s with the client offline."""
        started = time.monotonic()
        self.iso_cmd("host", "vm", "stop", self.args.name, self.instance, timeout=600)
        ttl = 60
        start = self.iso_cmd("host", "vm", "start", self.args.name, self.instance, "--ttl", f"{ttl}s", timeout=600)
        if start.returncode != 0:
            return self.record("ttl-wedged-guest", "fail", started, reason=tail(start.stderr))
        booted = time.monotonic()
        wedge = self.iso_cmd(
            "host", "shell", self.args.name, self.instance, "--", "sudo", "sh", "-c",
            "systemctl mask --runtime poweroff.target halt.target reboot.target >/dev/null 2>&1; "
            "nohup sh -c 'trap \"\" TERM INT HUP; while :; do sleep 1; done' >/dev/null 2>&1 & echo wedged",
            timeout=120)
        if wedge.returncode != 0 or "wedged" not in wedge.stdout:
            return self.record("ttl-wedged-guest", "fail", started, reason="could not wedge the guest: " + tail(wedge.stderr))
        while time.monotonic() - booted < ttl + 180:
            inspect = self.iso_cmd("host", "vm", "inspect", self.args.name, self.instance, timeout=120)
            if inspect.returncode == 0 and ": stopped" in inspect.stdout:
                observed = round(time.monotonic() - booted, 1)
                ok = observed <= ttl + 120
                return self.record("ttl-wedged-guest", "pass" if ok else "fail", started,
                                   ttl_seconds=ttl, observed_stop_seconds=observed, bound_seconds=ttl + 120)
            time.sleep(5)
        return self.record("ttl-wedged-guest", "fail", started, reason="the wedged VM was still running past the bound")

    def sleep_wake(self):
        """Q4 (sleep/wake): a session lease lapses across host sleep, and a
        deadline that passed during sleep is enforced on wake."""
        started = time.monotonic()
        ttl = 240
        self.iso_cmd("host", "vm", "stop", self.args.name, self.instance, timeout=600)
        start = self.iso_cmd("host", "vm", "start", self.args.name, self.instance, "--ttl", f"{ttl}s", timeout=600)
        if start.returncode != 0:
            return self.record("sleep-wake", "fail", started, reason=tail(start.stderr))
        deadline_wall = time.time() + ttl
        session = self.iso_cmd("host", "session", self.args.name, self.instance, "--detach", timeout=120)
        line = session.stdout.strip().split("\n")[-1].split()
        if session.returncode != 0 or len(line) != 4:
            return self.record("sleep-wake", "fail", started, reason=tail(session.stderr))
        config, alias = line[2], line[3]
        before = subprocess.run(["ssh", "-F", config, alias, "true"], capture_output=True, timeout=60, env=self.environment)
        slept_at, mono_at = time.time(), time.monotonic()
        subprocess.run(["pmset", "sleepnow"], capture_output=True, timeout=30)
        print("sleep-wake: put this Mac to sleep now if it is still awake (waiting up to 10 minutes)", flush=True)
        # Python's monotonic clock stops during sleep on macOS; wall time does not.
        while time.time() - slept_at < 600:
            if (time.time() - slept_at) - (time.monotonic() - mono_at) > 30:
                break
            time.sleep(1)
        host_slept = round((time.time() - slept_at) - (time.monotonic() - mono_at), 1)
        if host_slept <= 30:
            self.iso_cmd("host", "session", self.args.name, self.instance, "--stop", timeout=60)
            return self.record("sleep-wake", "blocked", started,
                               reason="the host did not sleep within 10 minutes", host_slept_seconds=host_slept)
        woke_after = round(time.time() - slept_at, 1)
        after = subprocess.run(["ssh", "-F", config, alias, "true"], capture_output=True, timeout=60, env=self.environment)
        past_deadline = time.time() >= deadline_wall
        stopped = None
        if past_deadline:
            for _ in range(36):
                inspect = self.iso_cmd("host", "vm", "inspect", self.args.name, self.instance, timeout=120)
                if ": stopped" in inspect.stdout:
                    stopped = True
                    break
                time.sleep(5)
            stopped = bool(stopped)
        self.iso_cmd("host", "session", self.args.name, self.instance, "--stop", timeout=60)
        ok = before.returncode == 0 and after.returncode != 0 and (stopped is not False)
        return self.record(
            "sleep-wake", "pass" if ok else "fail", started, slept_seconds=woke_after,
            host_slept_seconds=host_slept,
            access_before_sleep=before.returncode == 0, access_refused_after_wake=after.returncode != 0,
            deadline_passed_during_sleep=past_deadline, vm_stopped_after_wake=stopped)

    def prepare_local(self, started, record=True):
        """Scratch data root, `iso setup` with stub agents, service activation."""
        sandbox = self.args.sandbox
        container = shutil.which("container")
        kernel = Path.home() / "Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
        if not sandbox or not Path(sandbox).is_file() or not container or not kernel.exists():
            return self.record("enroll", "blocked", started,
                               reason="--local needs --sandbox PATH, the container CLI and its kernel")
        work = Path(tempfile.mkdtemp(prefix="iso-hc-local-"))
        self.work = work
        stubs = (ROOT / "tests/fixtures/apple-sandbox/stub-agents.sh").read_text()
        config = {
            "data_dir": str(work / "data"), "github": "off",
            "profiles": {"boundary-fixture": {"post_install": stubs}},
            "vm": {"vcpu_count": 2, "mem_size_mib": 2048, "template_size_gib": 8},
            "apple_container": {"binary": sandbox, "builder": container, "kernel": str(kernel.resolve())},
            # Synthetic values: the stub agents never call a provider.
            "proxy": {provider: {"credential": f"cmd:printf %s {fake}", "auth": "bearer"}
                      for provider, fake in FAKE_CREDENTIALS.items()},
        }
        (work / "iso.jsonc").write_text(json.dumps(config))
        if self.args.quarantine_subnets:
            # vmnet keeps subnets of uncleanly ended VMs reserved for hours, and
            # a fresh root allocates from 10.231.1.0/24 with a bounded number of
            # retries. Seed the runtime's own quarantine record so this scratch
            # root skips subnets another run left reserved.
            low, high = (int(n) for n in self.args.quarantine_subnets.split("-"))
            runtime = work / "data/backends/apple-container-v1/runtime"
            runtime.mkdir(parents=True)
            now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            (runtime / "subnets.json").write_text(
                json.dumps({"quarantined": {str(n): now for n in range(low, high + 1)}}))
        self.args.config = str(work / "iso.jsonc")
        self.args.name = "local"
        setup = self.iso_cmd("setup", "--profile", "boundary-fixture", timeout=3_600)
        if setup.returncode != 0 and "failed to create vmnet network" in setup.stderr + setup.stdout:
            # The host cannot create VM networks (no GUI session, missing
            # entitlement or a sandboxed parent): a prerequisite, not a result.
            return self.record("enroll", "blocked", started,
                               reason="this Mac cannot create vmnet networks for VMs: " + tail(setup.stderr, 300))
        if setup.returncode != 0:
            return self.record("enroll", "fail", started, reason="iso setup: " + tail(setup.stderr + setup.stdout))
        # Migration recovery ends with the root activated.
        recovered = record and self.migration_recovery()
        if record and not recovered and self.cases[-1]["status"] == "fail":
            return self.record("enroll", "fail", started, reason="migration recovery failed")
        activate = None
        if not recovered:
            activate = self.iso_cmd("host", "migrate", "local", "--activate", timeout=120)
            if activate.returncode != 0:
                return self.record("enroll", "fail", started, reason=tail(activate.stderr + activate.stdout))
        if record:
            # Rollback refuses an active migration and leaves the service up.
            started_rollback = time.monotonic()
            rollback = self.iso_cmd("host", "migrate", "local", "--rollback", timeout=120)
            inspect = self.iso_cmd("host", "inspect", self.args.name, timeout=120)
            ok = rollback.returncode != 0 and "active" in rollback.stderr and inspect.returncode == 0
            self.record("migrate-rollback-active-refused", "pass" if ok else "fail", started_rollback,
                        reason=None if ok else tail(rollback.stderr + rollback.stdout + inspect.stderr))
        if not record:
            return True
        return self.record("enroll", "pass", started, output=tail(activate.stdout) if activate else None)

    def migration_recovery(self):
        """An activation the service cannot complete leaves the migration
        prepared with the service up; rollback stops that service and undoes
        it, and a later --activate restarts the still-prepared service so it
        completes. The service refuses to complete while another process
        named `iso` runs; the CLI ignores its own parent, so a stand-in named
        `iso` runs the command as its child and only the service counts it."""
        started = time.monotonic()
        blocker_dir = self.work / "blocker"
        blocker_dir.mkdir()
        (blocker_dir / "iso.c").write_text(
            "#include <sys/wait.h>\n#include <unistd.h>\n"
            "int main(int argc, char **argv) {\n"
            "  if (argc < 2) return 2;\n"
            "  pid_t child = fork();\n"
            "  if (child == 0) { execl(\"/bin/sh\", \"sh\", argv[1], (char *)0); _exit(127); }\n"
            "  int status = 0;\n"
            "  if (child < 0 || waitpid(child, &status, 0) < 0) return 2;\n"
            "  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;\n"
            "}\n")
        build = subprocess.run(["cc", "-o", str(blocker_dir / "iso"), str(blocker_dir / "iso.c")],
                               capture_output=True, text=True, timeout=120)
        if build.returncode != 0:
            return self.record("migrate-recovery", "blocked", started,
                               reason="cc could not build the iso stand-in: " + tail(build.stderr, 200))

        # The command is in a script, not the stand-in's argv: the service
        # skips processes whose arguments name `host migrate`.
        script = blocker_dir / "activate.sh"
        script.write_text(
            f"exec '{self.iso}' --config '{self.args.config}' host migrate local --activate\n")

        def blocked_activate():
            return subprocess.run(
                [str(blocker_dir / "iso"), str(script)],
                capture_output=True, text=True, timeout=180, env=self.environment)

        first = blocked_activate()
        if first.returncode == 0 or "could not complete activation" not in first.stderr:
            return self.record("migrate-recovery", "fail", started,
                               reason="first activation: " + tail(first.stderr + first.stdout))
        rollback = self.iso_cmd("host", "migrate", "local", "--rollback", timeout=180)
        if rollback.returncode != 0:
            return self.record("migrate-recovery", "fail", started,
                               reason="rollback of a pending activation: " + tail(rollback.stderr))
        again = blocked_activate()
        if again.returncode == 0 or "could not complete activation" not in again.stderr:
            return self.record("migrate-recovery", "fail", started,
                               reason="second activation: " + tail(again.stderr + again.stdout))
        # The service from the refused attempt is still running and prepared.
        resumed = self.iso_cmd("host", "migrate", "local", "--activate", timeout=180)
        ok = resumed.returncode == 0 and "Active:" in resumed.stdout
        return self.record("migrate-recovery", "pass" if ok else "fail", started,
                           reason=None if ok else tail(resumed.stderr + resumed.stdout))

    def cleanup_local(self):
        """Stop the scratch service and delete what the scratch root created."""
        work = getattr(self, "work", None)
        if not work:
            return
        data = work / "data/backends/apple-container-v1"
        installation = data / "host-control/installation.json"
        if installation.exists():
            host_id = json.loads(installation.read_text())["hostID"]
            label = "dev.iso.host-control." + host_id.replace("-", "")[:12]
            subprocess.run(["launchctl", "bootout", f"user/{os.getuid()}/{label}"], capture_output=True)
        owner = data / "owner.json"
        if owner.exists():
            short = json.loads(owner.read_text())["owner_id"][:8]
            listing = subprocess.run(["container", "image", "list", "--quiet"], capture_output=True, text=True)
            images = [line for line in listing.stdout.split() if line.startswith(f"local/iso-{short}")]
            if images:
                subprocess.run(["container", "image", "delete", *images], capture_output=True)
        if not self.args.keep:
            subprocess.run(["chmod", "-R", "u+rwX", str(work)], capture_output=True)
            shutil.rmtree(work, ignore_errors=True)

    def push_and_stage(self):
        """One-way push, staged pull through the relay, offline apply."""
        started = time.monotonic()
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            project.mkdir()
            marker = uuid.uuid4().hex
            (project / "marker").write_text(marker)
            push = self.iso_cmd("host", "push", self.args.name, self.instance, "--dir", str(project), timeout=600)
            if push.returncode != 0:
                return self.record("workspace-push", "fail", started, reason=tail(push.stderr))
            self.record("workspace-push", "pass", started)
            started = time.monotonic()
            shell = self.iso_cmd(
                "host", "shell", self.args.name, self.instance, "--", "sh", "-c",
                "echo changed > /workspace/marker", timeout=300)
            stage = self.iso_cmd("host", "pull", self.args.name, self.instance, "--dir", str(project), timeout=600)
            unchanged = (project / "marker").read_text() == marker
            apply = self.iso_cmd("host", "pull", self.args.name, self.instance, "--apply", timeout=120)
            applied = (project / "marker").read_text().strip() == "changed"
            ok = shell.returncode == 0 and stage.returncode == 0 and unchanged and apply.returncode == 0 and applied
            return self.record(
                "staged-pull", "pass" if ok else "fail", started,
                reason=None if ok else tail(shell.stderr + stage.stderr + apply.stderr + stage.stdout))

    def remote_agent(self):
        """`iso host agent` through the relay: each agent starts with the
        client proxy required, and the guest gets the proxy endpoint, no
        provider credential and no Codex auth.json."""
        started = time.monotonic()
        proxy = Path(self.iso).parent / "iso-proxy"
        if not proxy.is_file():
            return self.blocked("remote-agent", f"iso-proxy is not beside iso ({proxy}); build iso-proxy and copy it there")
        outcomes = {}
        for agent in ("claude", "codex"):
            result = subprocess.run(
                [self.iso] + (["--config", self.args.config] if self.args.config else [])
                + ["host", "agent", self.args.name, self.instance, agent, "--", "--version"],
                capture_output=True, text=True, timeout=600, env=self.environment,
                stdin=subprocess.DEVNULL)
            # The stub agents of a scratch root exit 125 once launched.
            launched = result.returncode == 0 or (
                result.returncode == 125 and "agent execution is not supported" in result.stderr)
            if not launched:
                return self.record("remote-agent", "fail", started, agent=agent,
                                   reason=tail(result.stderr + result.stdout))
            outcomes[agent] = result.returncode
        probe = self.iso_cmd(
            "host", "shell", self.args.name, self.instance, "--", "sh", "-c",
            "cat ~/.codex/config.toml; echo ---; test -e ~/.codex/auth.json && echo AUTH_JSON; "
            "cat ~/.claude/settings.json 2>/dev/null; echo ---; env", timeout=300)
        text = probe.stdout
        checks = {
            "codex_proxy_endpoint": "http://127.0.0.1:" in text.split("---")[0],
            "no_codex_auth_json": "AUTH_JSON" not in text,
            "no_provider_credential": all(fake not in text for fake in FAKE_CREDENTIALS.values()),
        }
        ok = probe.returncode == 0 and all(checks.values())
        return self.record("remote-agent", "pass" if ok else "fail", started, exits=outcomes,
                           reason=None if ok else tail(probe.stderr) or "guest checks failed", **checks)

    def inspect(self):
        started = time.monotonic()
        result = self.iso_cmd("host", "inspect", self.args.name, timeout=120)
        if result.returncode != 0:
            return self.record("inspect", "fail", started, reason=tail(result.stderr))
        fields = dict(
            line.split(": ", 1) for line in result.stdout.splitlines() if ": " in line)
        self.remote_identity = {k: fields.get(k) for k in ("Installation", "Owner", "Service epoch", "Runtime")}
        if not fields.get("Runtime", "").startswith("qualified"):
            return self.record(
                "inspect", "blocked", started, reason="remote runtime is not qualified",
                identity=self.remote_identity)
        return self.record("inspect", "pass", started, identity=self.remote_identity)

    def latency(self):
        started = time.monotonic()
        samples = []
        for _ in range(self.args.samples):
            t = time.monotonic()
            result = self.iso_cmd("host", "inspect", self.args.name, timeout=120)
            if result.returncode != 0:
                return self.record("control-latency", "fail", started, reason=tail(result.stderr))
            samples.append(time.monotonic() - t)
        rtt = []
        for _ in range(min(5, self.args.samples) if self.args.remote else 0):
            t = time.monotonic()
            subprocess.run(["ssh", "-o", "BatchMode=yes", self.args.remote, "true"],
                           capture_output=True, timeout=60, env=self.environment)
            rtt.append(time.monotonic() - t)
        return self.record(
            "control-latency", "pass", started,
            hello_p50=round(statistics.median(samples), 3),
            hello_p95=round(sorted(samples)[max(0, int(len(samples) * 0.95) - 1)], 3),
            ssh_setup_p50=round(statistics.median(rtt), 3) if rtt else None, samples=len(samples))

    def lifecycle(self):
        name = self.instance
        started = time.monotonic()
        result = self.iso_cmd("host", "vm", "create", self.args.name, name, "--egress", "none", timeout=1_800)
        if result.returncode != 0:
            return self.record("create", "fail", started, reason=tail(result.stderr + result.stdout))
        self.cleanup.append(name)
        self.record("create", "pass", started, receipt=tail(result.stdout))
        started = time.monotonic()
        result = self.iso_cmd("host", "vm", "start", self.args.name, name, "--ttl", "30m", timeout=900)
        if result.returncode != 0:
            return self.record("start", "fail", started, reason=tail(result.stderr + result.stdout))
        return self.record("start", "pass", started, receipt=tail(result.stdout))

    def relay_round_trip(self):
        started = time.monotonic()
        command = [self.iso] + (["--config", self.args.config] if self.args.config else []) + [
            "host", "session", self.args.name, self.instance]
        session = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.environment)
        try:
            line = session.stdout.readline().strip()
            parts = line.split()
            if len(parts) != 4 or parts[0] != "ssh":
                return self.record("relay-round-trip", "fail", started, reason=f"unexpected session output {line!r}")
            config, alias = parts[2], parts[3]
            with tempfile.TemporaryDirectory() as directory:
                sentinel = Path(directory) / "sentinel"
                sentinel.write_bytes(os.urandom(4096))
                remote = f"/tmp/iso-q1-{uuid.uuid4().hex}"
                up = subprocess.run(["scp", "-F", config, str(sentinel), f"{alias}:{remote}"], capture_output=True, text=True, timeout=120, env=self.environment)
                back = Path(directory) / "back"
                down = subprocess.run(["scp", "-F", config, f"{alias}:{remote}", str(back)], capture_output=True, text=True, timeout=120, env=self.environment)
                if up.returncode or down.returncode:
                    return self.record("relay-round-trip", "fail", started, reason=tail(up.stderr + down.stderr))
                same = hashlib.sha256(sentinel.read_bytes()).hexdigest() == hashlib.sha256(back.read_bytes()).hexdigest()
                if not same:
                    return self.record("relay-round-trip", "fail", started, reason="sentinel digest mismatch")
            self.record("relay-round-trip", "pass", started)
            # Revocation: ending the coordinator closes the grant; a new
            # stream through the same descriptor must be refused.
            started = time.monotonic()
            session.send_signal(signal.SIGTERM)
            session.wait(timeout=30)
            probe = subprocess.run(["ssh", "-F", config, alias, "true"], capture_output=True, text=True, timeout=60, env=self.environment)
            if probe.returncode == 0:
                return self.record("session-revocation", "fail", started, reason="ssh succeeded after the session closed")
            return self.record("session-revocation", "pass", started)
        finally:
            if session.poll() is None:
                session.kill()

    def teardown(self):
        ok = True
        for name in self.cleanup:
            started = time.monotonic()
            stop = self.iso_cmd("host", "vm", "stop", self.args.name, name, timeout=900)
            ok &= self.record("stop", "pass" if stop.returncode == 0 else "fail", started, reason=tail(stop.stderr) or None)
            started = time.monotonic()
            destroy = self.iso_cmd("host", "vm", "destroy", self.args.name, name, timeout=900)
            listing = self.iso_cmd("host", "vm", "list", self.args.name, timeout=120)
            absent = destroy.returncode == 0 and name not in listing.stdout.split()
            ok &= self.record(
                "destroy", "pass" if absent else "fail", started,
                reason=None if absent else tail(destroy.stderr + listing.stdout))
        self.cleanup.clear()
        return ok

    # -- driver -----------------------------------------------------------

    def run(self):
        try:
            self.run_cases()
        finally:
            if self.args.local or self.args.loopback:
                self.cleanup_local()

    def run_cases(self):
        self.instance = f"q1-{uuid.uuid4().hex[:8]}"
        if not self.preparation():
            for case in ("enroll", "inspect", "control-latency", "create", "start", "relay-round-trip", "session-revocation"):
                self.blocked(case, "preparation blocked")
            return
        enrolled = self.enroll()
        inspected = self.inspect() if enrolled else self.blocked("inspect", "enrollment did not pass")
        if not inspected:
            for case in ("control-latency", "create", "start", "relay-round-trip", "session-revocation"):
                self.blocked(case, "enrollment or runtime qualification did not pass")
            return
        self.latency()
        try:
            if self.lifecycle():
                if self.args.sleep_wake:
                    self.sleep_wake()
                    return
                self.relay_round_trip()
                self.push_and_stage()
                self.remote_agent()
                self.ttl_enforcement()
                self.ttl_wedged_guest()
            else:
                self.blocked("relay-round-trip", "the VM did not start")
        finally:
            self.teardown()


def tail(text, limit=600):
    text = (text or "").strip()
    return text[-limit:]


def environment_evidence(iso):
    def run(argv):
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=30).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
    digest = None
    if Path(iso).is_file():
        digest = hashlib.sha256(Path(iso).read_bytes()).hexdigest()
    return {
        "client_os": run(["sw_vers", "-productVersion"]),
        "client_arch": platform.machine(),
        "swift": run(["swift", "--version"]),
        "source_revision": run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]),
        "source_dirty": bool(run(["git", "-C", str(ROOT), "status", "--porcelain"])),
        "iso_binary": iso,
        "iso_sha256": digest,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--iso", default=str(ROOT / ".build/debug/iso"))
    parser.add_argument("--config", help="client iso config (default: iso's own default)")
    parser.add_argument("--remote", help="ssh_config alias of the prepared remote Mac")
    parser.add_argument("--agent-path", help="absolute path of iso on the remote Mac")
    parser.add_argument("--name", default="q1-remote", help="host name to enroll it under")
    parser.add_argument("--local", action="store_true", help="qualify through this Mac's own host service")
    parser.add_argument("--loopback", action="store_true",
                        help="this Mac as an SSH worker for itself (scratch roots only)")
    parser.add_argument("--sandbox", help="iso-sandbox binary for --local/--loopback (scripts/build-iso-sandbox.sh)")
    parser.add_argument("--keep", action="store_true", help="keep the --local work directory")
    parser.add_argument("--sleep-wake", action="store_true",
                        help="run only the Q4 sleep/wake case (puts this Mac to sleep)")
    parser.add_argument("--quarantine-subnets", metavar="LOW-HIGH",
                        help="--local: skip 10.231.LOW..HIGH (subnets vmnet still holds)")
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--output", default="remote-host-evidence.json")
    args = parser.parse_args()

    runner = Runner(args)
    started = time.time()
    try:
        runner.run()
    except Exception as error:  # Recorded, never swallowed into a pass.
        runner.record("runner", "fail", time.monotonic(), reason=f"{type(error).__name__}: {error}")
        runner.teardown()
    statuses = {case["status"] for case in runner.cases}
    evidence = {
        "gate": "Q1 native slice (" + ("local host service" if args.local
                                       else "loopback SSH worker" if args.loopback else "remote Mac") + ")",
        "started_at": started,
        "environment": environment_evidence(args.iso),
        "remote": {"alias": args.remote, "agent_path": args.agent_path,
                   "identity": getattr(runner, "remote_identity", None)},
        "cases": runner.cases,
        "result": "fail" if "fail" in statuses else ("blocked" if "blocked" in statuses else "pass"),
    }
    Path(args.output).write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"result: {evidence['result']} ({args.output})")
    return 1 if "fail" in statuses else (2 if "blocked" in statuses else 0)


if __name__ == "__main__":
    sys.exit(main())
