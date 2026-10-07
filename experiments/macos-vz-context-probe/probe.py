#!/usr/bin/env python3
"""Driver for the macOS VZ process-context / headless-display / virtual-HID experiment.

See docs/design/macos-vz-context-headless-experiment-spec.md and README.md.

    ./build.sh
    ./probe.py bootstrap-guest              install fixture + helper into the preinstalled guest
    ./probe.py report-context
    ./probe.py phase1 --context C0|C1|C2 [--runs N]
    ./probe.py daemon-plan --context C3|C4|C5 [--cycles N]   operator runs the generated sudo script
    ./probe.py collect <run-dir>            evaluate a daemon run after the fact
    ./probe.py phase2 --context C1 [--operator-wait S]
    ./probe.py phase3 --topology V0..V8 [--domain gui|user|direct] [--captures N] [--clicks N]
    ./probe.py phase4 --topology V6 [--operator-wait S]
    ./probe.py e9 --topology V6
    ./probe.py auth-check                   forged vsock hellos are rejected
    ./probe.py report

Every run writes $VZPROBE_STATE/results/<run-id>/ (spec §18). Statuses are
pass | fail | not_supported | environment_error | not_run; a missing test is never a pass.

Oracles are independent of the host probe's return values: the guest fixture's
state.json / events.jsonl (read over SSH) and the guest helper's vsock hello.
"""

import argparse
import json
import os
import queue
import random
import secrets
import shlex
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / ".build" / "probe"
PROBE = OUT / "vz-context-probe"
STATE = Path(os.environ.get("VZPROBE_STATE", Path.home() / ".iso-vz-probe"))
RESULTS = STATE / "results"
# The preinstalled guest (spec §6.1). Default: the bundle the Q0 spike installed.
VM = Path(os.environ.get("VZPROBE_VM", Path.home() / ".iso-q0" / "vm"))
KEY = VM / "id_ed25519"
KNOWN = VM / "known_hosts"
SOCK = Path(os.environ.get("VZPROBE_SOCK", STATE / "vzprobe.sock"))  # per-user dir, not /tmp
USER = "iso"
GUEST_DIR = "Library/Application Support/IsoVZProbe"
GUEST_DIR_SH = "~/" + GUEST_DIR.replace(" ", "\\ ")  # for remote shell commands
LABEL = "dev.iso.vzprobe.owner"
DOMAINS = {"user": "Background", "gui": "Aqua"}
CONTEXT_DOMAIN = {"C0": "direct", "C1": "user", "C2": "gui"}
DOMAIN_CONTEXT = {v: k for k, v in CONTEXT_DOMAIN.items()}
STATUSES = ("pass", "fail", "not_supported", "environment_error", "not_run")


def say(*a):
    print("probe:", *a, file=sys.stderr, flush=True)


def guest_password():
    """Synthetic guest password for guest sudo, never written to argv, logs or this repository."""
    pw = os.environ.get("VZPROBE_GUEST_PASSWORD")
    if pw:
        return pw
    askpass = VM / "askpass.sh"  # written by the Q0 harness outside the repository
    if askpass.exists():
        return askpass.read_text().split("echo", 1)[1].strip()
    raise SystemExit("set VZPROBE_GUEST_PASSWORD for guest sudo")


def sh(*argv, timeout=30):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


# ---------------------------------------------------------------- runs / evidence


def new_run(tag):
    rid = time.strftime("%Y%m%dT%H%M%S") + f"-{tag}-{secrets.token_hex(2)}"
    rd = RESULTS / rid
    for sub in ("guest-state", "screenshots"):
        (rd / sub).mkdir(parents=True, exist_ok=True)
    for f in ("host-session-events.jsonl", "capture-events.jsonl", "input-events.jsonl"):
        (rd / f).touch()
    return rid, rd


_METADATA = None


def metadata():
    global _METADATA
    if _METADATA is None:
        _METADATA = {
            "host_model": sh("sysctl", "-n", "hw.model"),
            "host_soc": sh("sysctl", "-n", "machdep.cpu.brand_string"),
            "host_ram_bytes": int(sh("sysctl", "-n", "hw.memsize") or 0),
            "host_os": sh("sw_vers", "--productVersion") + " " + sh("sw_vers", "--buildVersion"),
            "xcode": sh("xcodebuild", "-version").replace("\n", " "),
            "sdk": sh("xcrun", "--show-sdk-version"),
            "probe_build_hash": (OUT / "build-hash").read_text().strip() if (OUT / "build-hash").exists() else None,
            "probe_build_commit": (OUT / "build-commit").read_text().strip() if (OUT / "build-commit").exists() else None,
            "vm_bundle": str(VM),
            "display": "1440x900 @ 80ppi, automaticallyReconfiguresDisplay=false",
            "pointing": "VZUSBScreenCoordinatePointingDevice (absolute)",
            "keyboard": "VZMacKeyboard",
        }
    return dict(_METADATA)


def append(path, obj):
    with open(path, "a") as f:
        f.write(json.dumps({"t": time.time(), **obj}, default=str) + "\n")


def write_result(rd, rid, context, session_state, topology, **fields):
    res = {
        "run_id": rid, "context": context, "session_state": session_state, "view_topology": topology,
        "vm_runtime": "not_run", "observation": "not_run", "pointer": "not_run", "keyboard": "not_run",
        "failure_code": None,
    }
    res.update(fields)
    for k in ("vm_runtime", "observation", "pointer", "keyboard"):
        assert res[k] in STATUSES, (k, res[k])
    (rd / "result.json").write_text(json.dumps(res, indent=2, default=str))
    say(f"{rid}: vm_runtime={res['vm_runtime']} observation={res['observation']} pointer={res['pointer']} "
        f"keyboard={res['keyboard']} failure={res['failure_code']}")
    return res


def host_session_state():
    out = sh("ioreg", "-n", "Root", "-d1", "-a")
    i = out.find("IOConsoleLocked")
    locked = None if i < 0 else "<true/>" in out[i:i + 60]
    pm = sh("pmset", "-g", "log", timeout=60)
    lines = [x for x in pm.splitlines() if "Display is turned" in x]
    display = lines[-1].split("Display is turned")[1].split()[0] if lines else "?"
    return {"console_locked": locked, "display": display, "console_user": sh("stat", "-f", "%Su", "/dev/console")}


# ---------------------------------------------------------------- owners


class Owner:
    """A probe owner process in one launch context: direct child, user/$UID Background job, or gui/$UID LaunchAgent."""

    def __init__(self, domain, argv, rd):
        self.domain, self.argv, self.rd = domain, [str(a) for a in argv], rd
        self.proc = None

    def start(self):
        stop_stale_owners()
        out, err = self.rd / "owner.stdout.log", self.rd / "owner.stderr.log"
        if self.domain == "direct":
            self.proc = subprocess.Popen(self.argv, stdout=open(out, "ab"), stderr=open(err, "ab"),
                                         stdin=subprocess.DEVNULL, start_new_session=True)
        else:
            plist = self.rd / f"{LABEL}.plist"
            plist.write_text(launchd_plist(LABEL, self.argv, out, err, session=DOMAINS[self.domain]))
            plist.chmod(0o600)
            r = subprocess.run(["launchctl", "bootstrap", f"{self.domain}/{os.getuid()}", str(plist)],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise EnvironmentError(f"launchctl bootstrap {self.domain}: {r.returncode} {r.stderr.strip()}")
        return self

    def target(self):
        return f"{self.domain}/{os.getuid()}/{LABEL}"

    def running(self):
        if self.proc:
            return self.proc.poll() is None
        r = subprocess.run(["launchctl", "print", self.target()], capture_output=True, text=True)
        # Loaded and not yet exited ("spawn scheduled", "running", ...) counts as running.
        return r.returncode == 0 and "state = not running" not in r.stdout

    def exit_status(self):
        if self.proc:
            return self.proc.returncode
        out = sh("launchctl", "print", self.target())
        for line in out.splitlines():
            if "last exit code" in line:
                try:
                    return int(line.split("=")[1].split(":")[0].strip())
                except ValueError:
                    return line.split("=", 1)[1].strip()
        return None

    def wait(self, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline and self.running():
            time.sleep(0.5)
        status = None if self.running() else self.exit_status()
        return status

    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if not self.proc:
            subprocess.run(["launchctl", "bootout", self.target()], capture_output=True)


def launchd_plist(label, argv, out, err, session=None, user_name=None):
    def esc(s):
        return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    args = "".join(f"<string>{esc(a)}</string>" for a in argv)
    extra = ""
    if session:
        extra += f"<key>LimitLoadToSessionType</key><string>{session}</string>"
    if user_name:
        extra += f"<key>UserName</key><string>{esc(user_name)}</string>"
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array>{args}</array>
<key>RunAtLoad</key><true/>
{extra}
<key>ProcessType</key><string>Interactive</string>
<key>ExitTimeOut</key><integer>200</integer>
<key>StandardOutPath</key><string>{esc(out)}</string>
<key>StandardErrorPath</key><string>{esc(err)}</string>
</dict></plist>
"""


def stop_stale_owners():
    # Direct (C0) owners have no launchd job and, for vm-run, no socket: find them by argv.
    pids = sh("pgrep", "-f", f"vz-context-probe vm-(run|view) {VM}").split()
    for pid in pids:
        subprocess.run(["kill", "-TERM", pid], capture_output=True)
    if pids:
        deadline = time.time() + 60
        while time.time() < deadline and sh("pgrep", "-f", f"vz-context-probe vm-(run|view) {VM}"):
            time.sleep(1)
    for domain in DOMAINS:
        subprocess.run(["launchctl", "bootout", f"{domain}/{os.getuid()}/{LABEL}"], capture_output=True)
    for label in ("dev.iso.q0spike.owner",):  # the Q0 harness owns the same VM bundle
        for domain in DOMAINS:
            subprocess.run(["launchctl", "bootout", f"{domain}/{os.getuid()}/{label}"], capture_output=True)
    if SOCK.exists():
        try:
            call({"op": "stop"}, timeout=200)
            call({"op": "quit"})
            time.sleep(2)
        except (OSError, ValueError):
            SOCK.unlink(missing_ok=True)  # nobody listening


def events(rd):
    p = rd / "vm-events.jsonl"
    if not p.exists():
        return []
    out = []
    for line in p.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def wait_event(rd, pred, timeout, owner=None):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for e in events(rd):
            if pred(e):
                return e
        if owner and not owner.running():
            time.sleep(1)
            return next((e for e in events(rd) if pred(e)), None)
        time.sleep(1)
    return None


def call(req, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(SOCK))
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 16)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)


# ---------------------------------------------------------------- guest access


def guest_ip():
    mac = (VM / "mac.txt").read_text().strip().lower()
    want = ":".join(p.lstrip("0") or "0" for p in mac.split(":"))
    try:
        text = Path("/var/db/dhcpd_leases").read_text()
    except OSError:
        return None
    ip = None
    for block in text.split("}"):
        fields = dict(line.strip().split("=", 1) for line in block.splitlines() if "=" in line)
        if fields.get("hw_address", "").split(",", 1)[-1] == want:
            ip = fields.get("ip_address")
    return ip


def ssh_opts():
    # Experiment only: trust-on-first-use into the bundle's known_hosts.
    return ["-i", str(KEY), "-o", f"UserKnownHostsFile={KNOWN}", "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", f"ControlPath={STATE}/ssh-%C",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=120"]


def ssh(cmd, check=True, timeout=60, input=None, ip=None):
    ip = ip or guest_ip()
    if not ip:
        raise RuntimeError("guest has no DHCP lease")
    r = subprocess.run(["ssh", *ssh_opts(), f"{USER}@{ip}", cmd], capture_output=True, text=True,
                       timeout=timeout, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"ssh {cmd!r}: {r.returncode} {r.stderr.strip()[:200]}")
    return r.stdout


def sudo(cmd, timeout=60):
    """Guest sudo; the password goes over stdin only."""
    return ssh(f"sudo -S -p '' sh -c {json.dumps(cmd)}", input=guest_password() + "\n", timeout=timeout)


def scp(src, dst):
    subprocess.run(["scp", "-q", "-r", *ssh_opts(), str(src), f"{USER}@{guest_ip()}:{dst}"], check=True)


def ssh_ok():
    try:
        ssh("true", timeout=10)
        return True
    except (RuntimeError, subprocess.TimeoutExpired):
        return False


def wait_for(pred, timeout, what, interval=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {what}")


def guest_state():
    return json.loads(ssh(f"cat {GUEST_DIR_SH}/state.json", timeout=15))


class Fixture:
    """(Re)start the guest fixture with a fresh token and stream its event log."""

    def __init__(self, rd):
        self.rd = rd
        self.q = queue.Queue()
        self.tail = None

    def start(self):
        self.token = secrets.token_hex(4)
        ssh(f"pkill -x IsoVZProbe; rm -f {GUEST_DIR_SH}/state.json {GUEST_DIR_SH}/events.jsonl; true", check=False)
        time.sleep(0.5)
        ssh(f"open -n ~/IsoVZProbe/IsoVZProbe.app --args --token {self.token}")

        def ready():
            try:
                st = guest_state()
                return st if st.get("run_token") == self.token else None
            except (RuntimeError, ValueError, subprocess.TimeoutExpired):
                return None

        self.state = wait_for(ready, 30, "fixture state.json")
        time.sleep(2)
        # Exactly one fixture instance: any other (e.g. relaunched at login) would take input and the screen.
        pids = ssh("pgrep -x IsoVZProbe; true").split()
        if len(pids) != 1 or str(guest_state().get("pid")) not in pids:
            raise EnvironmentError(f"fixture instances {pids}, state pid {guest_state().get('pid')}")
        self.layout_path = self.rd / "guest-state" / "fixture-state.json"
        self.layout_path.write_text(json.dumps(self.state, indent=2))
        if self.tail:
            self.tail.terminate()
        self.q = queue.Queue()
        self.tail = subprocess.Popen(["ssh", *ssh_opts(), f"{USER}@{guest_ip()}", f"tail -n +1 -F {GUEST_DIR_SH}/events.jsonl"],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self._pump, args=(self.tail, self.q), daemon=True).start()
        if not self.expect(lambda e: e["ev"] == "ready", 10):
            raise TimeoutError("fixture ready event")
        time.sleep(1.0)
        return self

    @staticmethod
    def _pump(tail, q):
        for line in tail.stdout:
            try:
                q.put(json.loads(line))
            except ValueError:
                pass

    def expect(self, pred, timeout=2.0):
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                return None
            try:
                e = self.q.get(timeout=left)
            except queue.Empty:
                return None
            if pred(e):
                return e

    def drain(self, settle=0.5):
        out = []
        while True:
            try:
                out.append(self.q.get(timeout=settle))
            except queue.Empty:
                return out

    def stop(self):
        if self.tail:
            self.tail.terminate()


# ---------------------------------------------------------------- bootstrap


def headless_owner(rd, rid, context, domain, hold="-1"):
    argv = [PROBE, "vm-run", VM, "--run-dir", rd, "--run-id", rid, "--context", context,
            "--hold", hold, "--stop-file", rd / "stop"]
    return Owner(domain, argv, rd).start()


def cmd_bootstrap(_args):
    # The key must exist before the owner starts: the owner loads it once, and
    # without it no hello is accepted and the stop has no guest-side path.
    key_file = VM / "helper.key"
    if not key_file.exists():
        fd = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(secrets.token_hex(32) + "\n")
    key_file.chmod(0o600)
    rid, rd = new_run("bootstrap")
    owner = headless_owner(rd, rid, "C0", "direct")
    try:
        ev = wait_event(rd, lambda e: e["event"] in ("guest_ssh_banner", "cycle_result"), 900, owner)
        if not ev or ev["event"] != "guest_ssh_banner":
            raise SystemExit(f"guest not reachable; see {rd}")
        wait_for(ssh_ok, 120, "ssh login")
        ssh("mkdir -p ~/IsoVZProbe && rm -rf ~/IsoVZProbe/IsoVZProbe.app")
        scp(OUT / "IsoVZProbe.app", "IsoVZProbe/")
        scp(OUT / "iso-vz-probe-helper", "IsoVZProbe/")
        plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>dev.iso.vzprobe.helper</string>
<key>ProgramArguments</key><array><string>/usr/local/libexec/iso-vz-probe-helper</string>
<string>/Users/{USER}/{GUEST_DIR}/state.json</string>
<string>/usr/local/etc/iso-vz-probe-helper.key</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
"""
        ssh("cat > ~/IsoVZProbe/dev.iso.vzprobe.helper.plist", input=plist)
        # Per-bundle key for the helper's vsock hello (see BootIdentity). Host copy 0600 in
        # the bundle; guest copy 0600 root. Sent over SSH stdin only.
        key_file = VM / "helper.key"
        # sudo -k first: with a cached ticket sudo would not read the password line,
        # and the password would land in the key file.
        ssh("sudo -k; sudo -S -p '' sh -c 'mkdir -p /usr/local/etc && umask 077 && "
            "head -c 64 > /usr/local/etc/iso-vz-probe-helper.key && chown root:wheel /usr/local/etc/iso-vz-probe-helper.key'",
            input=guest_password() + "\n" + key_file.read_text().strip())
        # A script file, not `sh -c "..."`: no second layer of shell quoting.
        ssh("cat > ~/IsoVZProbe/install-helper.sh", input="""set -eu
mkdir -p /usr/local/libexec
install -m 0755 /Users/iso/IsoVZProbe/iso-vz-probe-helper /usr/local/libexec/
install -m 0644 -o root -g wheel /Users/iso/IsoVZProbe/dev.iso.vzprobe.helper.plist /Library/LaunchDaemons/
launchctl bootout system/dev.iso.vzprobe.helper 2>/dev/null || true
# bootout is asynchronous; bootstrapping before the job is gone fails with EIO.
i=0
while launchctl print system/dev.iso.vzprobe.helper >/dev/null 2>&1 && [ "$i" -lt 40 ]; do
  sleep 0.25
  i=$((i + 1))
done
launchctl bootstrap system /Library/LaunchDaemons/dev.iso.vzprobe.helper.plist
pmset -a displaysleep 0 sleep 0 disksleep 0
""")
        sudo("sh /Users/iso/IsoVZProbe/install-helper.sh")
        ssh("defaults -currentHost write com.apple.screensaver idleTime 0", check=False)
        # No app relaunch at login: a relaunched fixture races Fixture.start (stale instance in front).
        ssh("defaults write com.apple.loginwindow TALLogoutSavesState -bool false; "
            "defaults write -g NSQuitAlwaysKeepsWindows -bool false; "
            "rm -rf ~/Library/Saved\\ Application\\ State/dev.iso.vzprobe.fixture.savedState; "
            "rm -f ~/Library/Preferences/ByHost/com.apple.loginwindow.*.plist", check=False)
        if not wait_event(rd, lambda e: e["event"] == "guest_hello", 60):
            raise SystemExit("no authenticated helper hello after install")
        ssh("sync", check=False)
        say("guest bootstrapped:", ssh("sw_vers").replace("\n", " "))
    finally:
        (rd / "stop").touch()
        owner.wait(300)
        owner.kill()


# ---------------------------------------------------------------- phase 1


def phase1_once(context, domain):
    rid, rd = new_run(f"p1-{context}")
    (rd / "metadata.json").write_text(json.dumps({**metadata(), "phase": 1, "context": context, "domain": domain}, indent=2))
    start_state = host_session_state()
    label = session_label(start_state)
    append(rd / "host-session-events.jsonl", {"event": "start", **start_state})
    try:
        owner = headless_owner(rd, rid, context, domain)
    except EnvironmentError as e:
        return write_result(rd, rid, context, label, "none", vm_runtime="environment_error", failure_code=str(e))
    guest, failure = {}, None
    try:
        ev = wait_event(rd, lambda e: e["event"] in ("guest_ssh_banner", "cycle_result"), 900, owner)
        if ev and ev["event"] == "guest_ssh_banner":
            try:
                wait_for(lambda: ssh_ok(), 120, "ssh login")
                guest["sw_vers"] = ssh("sw_vers", ip=ev["ip"])
                guest["boot_id"] = ssh("sysctl -n kern.bootsessionuuid", ip=ev["ip"]).strip()
                guest["fixture_state"] = ssh(f"cat {GUEST_DIR_SH}/state.json", check=False, ip=ev["ip"])
            except (RuntimeError, TimeoutError, subprocess.TimeoutExpired) as e:
                failure = f"ssh_login: {e}"
        for k, v in guest.items():
            (rd / "guest-state" / f"{k}.txt").write_text(str(v))
    finally:
        (rd / "stop").touch()
        status = owner.wait(300)
        if status is None:
            failure = failure or "owner_did_not_exit"
            owner.kill()
        elif not owner.proc:
            owner.kill()  # bootout the finished job
    evs = events(rd)
    cycle = next((e for e in reversed(evs) if e["event"] == "cycle_result"), None)
    hello = next((e for e in evs if e["event"] == "guest_hello"), None)
    crashed = status not in (0, None) and not cycle
    ok = bool(cycle and cycle.get("pass") and status == 0 and guest.get("boot_id")
              and hello and hello.get("boot_id") == guest.get("boot_id") and not failure)
    if not ok and not failure:
        if not cycle:
            failure = f"no_cycle_result (owner exit {status})"
        elif cycle.get("validation") != "pass":
            failure = f"validation: {cycle.get('validation_error')}"
        elif cycle.get("start") != "pass":
            failure = f"start: {cycle.get('start_error')}"
        elif not cycle.get("guest_hello"):
            failure = "guest_hello_timeout"
        elif not cycle.get("guest_ssh_banner"):
            failure = "guest_ssh_timeout"
        elif cycle.get("state_before_stop") != "running":
            failure = f"vm stopped on its own before the stop request ({cycle.get('state_before_stop')})"
        elif not cycle.get("graceful_stop"):
            failure = f"stop: {cycle.get('stop_event')}"
        elif status != 0:
            failure = f"owner_exit_{status}"
        else:
            failure = "boot_identity_mismatch"
    append(rd / "host-session-events.jsonl", {"event": "end", **host_session_state()})
    return write_result(rd, rid, context, label, "none", vm_runtime="pass" if ok else "fail", failure_code=failure,
                        owner_exit=status, crashed=crashed, cycle=cycle, guest_boot_id=guest.get("boot_id"),
                        stop_path=(cycle or {}).get("stop_path"))


def cmd_phase1(args):
    if args.context not in CONTEXT_DOMAIN:
        raise SystemExit("phase1 runs C0-C2 directly; use daemon-plan for C3-C5")
    results = [phase1_once(args.context, CONTEXT_DOMAIN[args.context]) for _ in range(args.runs)]
    passed = sum(r["vm_runtime"] == "pass" for r in results)
    say(f"phase1 {args.context}: {passed}/{len(results)} pass")


# ---------------------------------------------------------------- daemon contexts (C3-C5)

# Root-owned base for daemon runs: never a world-writable parent such as /Users/Shared.
DAEMON_BASE = Path("/Library/Application Support/iso-vz-probe")
DAEMON_LABEL = "dev.iso.vzprobe.daemon"
TEST_USER = "iso-vz-test"


def cmd_daemon_plan(args):
    """Write a LaunchDaemon plist and the sudo script the operator runs (C3 root, C4/C5 UserName)."""
    ctx = args.context
    if ctx not in ("C3", "C4", "C5"):
        raise SystemExit("daemon-plan is for C3, C4, C5")
    rid = time.strftime("%Y%m%dT%H%M%S") + f"-p1-{ctx}-daemon"
    plan = STATE / "daemon" / rid
    plan.mkdir(parents=True, exist_ok=True)
    base = DAEMON_BASE
    run_dir = base / "results" / rid
    user = None if ctx == "C3" else TEST_USER
    argv = [base / "bin" / "vz-context-probe", "vm-run", base / "vm", "--run-dir", run_dir, "--run-id", rid,
            "--context", ctx, "--hold", str(args.hold), "--cycles", str(args.cycles)]
    plist = plan / f"{DAEMON_LABEL}.plist"
    plist.write_text(launchd_plist(DAEMON_LABEL, argv, run_dir / "owner.stdout.log", run_dir / "owner.stderr.log",
                                   user_name=user))
    owner_user = user or "root"
    q = shlex.quote
    files = " ".join(q(str(VM / f)) for f in ("hardware-model.bin", "machine-id.bin", "aux.img", "disk.img",
                                               "mac.txt", "helper.key"))
    (plan / "metadata.json").write_text(json.dumps({**metadata(), "phase": 1, "context": ctx,
                                                     "daemon_user": owner_user, "run_dir": str(run_dir)}, indent=2))
    if ctx == "C5":
        load = ("echo 'C5: installed but not loaded. Fully shut down the host (not restart into a login),'\n"
                "echo 'power on, do NOT log in; wait >= 15 minutes; then log in and run:'\n"
                f"echo {q('  ./probe.py collect ' + q(str(run_dir)) + ' --boot-log')}")
    else:
        load = (f"launchctl bootstrap system /Library/LaunchDaemons/{DAEMON_LABEL}.plist\n"
                f"echo {q('loaded; when it exits: ./probe.py collect ' + q(str(run_dir)))}")
    need_user = "" if not user else (
        f'id {user} >/dev/null 2>&1 || {{ echo "create the standard user first: '
        f'sudo sysadminctl -addUser {user} -fullName \\"iso VZ test\\" -password -"; exit 1; }}')
    script = f"""#!/bin/sh
# Generated by probe.py daemon-plan for {ctx}. Run with sudo. Experiment host only.
set -eu
{need_user}
BASE={q(str(base))}
# The base must be a real root-owned directory: the daemon runs a binary from it.
if [ -L "$BASE" ] || {{ [ -e "$BASE" ] && {{ [ ! -d "$BASE" ] || [ "$(stat -f %Su "$BASE")" != root ]; }}; }}; then
  echo "refusing: $BASE exists and is not a root-owned directory"; exit 1
fi
# Never run this VM identity concurrently with the original bundle.
launchctl bootout system/{DAEMON_LABEL} 2>/dev/null || true
install -d -m 0755 -o root -g wheel "$BASE" "$BASE/bin" "$BASE/results"
install -m 0755 -o root -g wheel {q(str(PROBE))} "$BASE/bin/vz-context-probe"
# Fresh APFS clone of the VM files every time; nothing from a previous context is reused.
rm -rf "$BASE/vm"
install -d -m 0700 -o root -g wheel "$BASE/vm"
for f in {files}; do cp -c "$f" "$BASE/vm/"; done
chown -R {owner_user} "$BASE/vm"
install -d -m 0755 -o {owner_user} {q(str(run_dir))}
install -m 0644 -o root -g wheel {q(str(plist))} /Library/LaunchDaemons/{DAEMON_LABEL}.plist
{load}
"""
    (plan / "install.sh").write_text(script)
    (plan / "install.sh").chmod(0o700)
    (plan / "uninstall.sh").write_text(f"""#!/bin/sh
set -u
launchctl bootout system/{DAEMON_LABEL} 2>/dev/null
rm -f /Library/LaunchDaemons/{DAEMON_LABEL}.plist
echo {q(f"removed {DAEMON_LABEL}; results remain in {base}/results")}
""")
    (plan / "uninstall.sh").chmod(0o700)
    print(f"plan: {plan}\n  sudo {plan / 'install.sh'}\n  later: sudo {plan / 'uninstall.sh'}")


def cmd_collect(args):
    """Evaluate a run directory written by an owner the driver did not supervise (C3-C5)."""
    rd = Path(args.run_dir)
    evs = events(rd)
    rid = rd.name
    # A RunAtLoad daemon reruns on every boot and appends: evaluate only the first owner session.
    starts = [i for i, e in enumerate(evs) if e["event"] == "owner_start"]
    later_sessions = max(0, len(starts) - 1)
    if len(starts) > 1:
        evs = evs[:starts[1]]
    start = next((e for e in evs if e["event"] == "owner_start"), {})
    ctx = start.get("context", "unknown")
    cycles = [e for e in evs if e["event"] == "cycle_result"]
    exit_ev = next((e for e in reversed(evs) if e["event"] == "owner_exit"), None)
    out = rd if os.access(rd, os.W_OK) else RESULTS / rid
    out.mkdir(parents=True, exist_ok=True)
    if args.boot_log:
        log = sh("log", "show", "--last", "boot", "--style", "compact", "--predicate",
                 'process == "vz-context-probe" OR subsystem BEGINSWITH "com.apple.Virtualization"', timeout=300)
        (out / "system-log-excerpt.txt").write_text(log[-200000:])
    passed = sum(1 for c in cycles if c.get("pass"))
    argv = start.get("argv") or []
    requested = int(argv[argv.index("--cycles") + 1]) if "--cycles" in argv else 1
    signalled = any(e["event"] == "owner_signal" for e in evs)
    ok = (len(cycles) == requested and passed == requested and not signalled
          and exit_ev and exit_ev.get("status") == 0)
    failure = None
    if not ok:
        bad = next((c for c in cycles if not c.get("pass")), None)
        failure = ("no_cycle_result" if not cycles else
                   f"start: {bad.get('start_error')}" if bad and bad.get("start") != "pass" else
                   f"cycle {bad.get('cycle')} failed" if bad else
                   f"{len(cycles)}/{requested} cycles (signalled={signalled})" if len(cycles) != requested else
                   f"owner_exit {exit_ev}")
    hc = start.get("host_context") or {}
    # "pre-login" only when the owner itself saw no console user and no gui domain.
    no_login = hc.get("console_user") in (None, "loginwindow") and not hc.get("gui_domain_exists")
    label = "pre-login" if no_login else ("S1" if hc.get("console_locked") else "S0")
    write_result(out, rid, ctx, label, "none", vm_runtime="pass" if ok else "fail", later_owner_sessions=later_sessions,
                 failure_code=failure, cycles=len(cycles), cycles_requested=requested, cycles_passed=passed,
                 host_context=start.get("host_context"), owner_exit=exit_ev,
                 ssh_check="banner only (owner-side TCP); no login performed before inspection")


# ---------------------------------------------------------------- phase 2


def cmd_phase2(args):
    ctx = args.context
    rid, rd = new_run(f"p2-{ctx}")
    (rd / "metadata.json").write_text(json.dumps({**metadata(), "phase": 2, "context": ctx}, indent=2))
    owner = headless_owner(rd, rid, ctx, CONTEXT_DOMAIN[ctx])
    hs = rd / "host-session-events.jsonl"
    states = {}
    try:
        ev = wait_event(rd, lambda e: e["event"] in ("guest_ssh_banner", "cycle_result"), 900, owner)
        if not ev or ev["event"] != "guest_ssh_banner":
            return write_result(rd, rid, ctx, session_label(), "none", vm_runtime="fail",
                                failure_code="guest not reachable")
        wait_for(ssh_ok, 120, "ssh login")
        boot0 = ssh("sysctl -n kern.bootsessionuuid").strip()
        pid0 = json.loads((rd / "status.json").read_text())["pid"]

        def check(name, expect):
            st = json.loads((rd / "status.json").read_text())
            try:
                boot = ssh("sysctl -n kern.bootsessionuuid", timeout=20).strip()
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                boot = f"error: {e}"
            row = {"vm_state": st["vm_state"], "owner_pid": st["pid"], "owner_alive": owner.running(),
                   "status_age_s": round(time.time() - st["t"], 1), "ssh_boot_id": boot, **host_session_state()}
            # Whether the host was actually in the named state; a row is evidence only for the state reached.
            row["expected"] = expect
            row["state_reached"] = all(row[k] == v for k, v in expect.items())
            row["session_label"] = session_label(row)
            row["pass"] = (st["vm_state"] == "running" and st["pid"] == pid0 and row["owner_alive"]
                           and boot == boot0 and row["status_age_s"] < 5)
            states[name] = row
            append(hs, {"event": "check", "state": name, **row})
            say(name, json.dumps(row))

        check("S0", {"console_locked": False})
        append(hs, {"event": "transition", "to": "S1/S2", "action": "pmset displaysleepnow"})
        subprocess.run(["pmset", "displaysleepnow"])
        time.sleep(15)
        check("S1+S2 locked, display asleep", {"console_locked": True, "display": "off"})
        for i in range(3):
            time.sleep(20)
            check(f"S1+S2 +{20 * (i + 1)}s", {"console_locked": True, "display": "off"})
        append(hs, {"event": "transition", "to": "S3", "action": "caffeinate -u"})
        subprocess.run(["caffeinate", "-u", "-t", "5"])
        time.sleep(6)
        check("S3 display woken (still locked)", {"display": "on"})
        for name, instruction in (("S4", "fast-user-switch to another account"), ("S5", "switch back to this account"),
                                  ("S6", "sleep the host, then wake it")):
            if args.operator_wait:
                say(f"OPERATOR: {instruction} within {args.operator_wait}s")
                append(hs, {"event": "operator_prompt", "state": name, "instruction": instruction})
                time.sleep(args.operator_wait)
                check(name, {})
            else:
                states[name] = {"status": "not_run", "reason": "needs operator (--operator-wait)"}
    finally:
        (rd / "stop").touch()
        status = owner.wait(300)
        if status is None:
            owner.kill()
        elif not owner.proc:
            owner.kill()
    cycle = next((e for e in reversed(events(rd)) if e["event"] == "cycle_result"), {})
    checked = {k: v for k, v in states.items() if "pass" in v}
    ok = all(v["pass"] for v in checked.values()) and cycle.get("graceful_stop") and status == 0
    reached = sorted({v["session_label"] for v in checked.values() if v.get("state_reached")})
    write_result(rd, rid, ctx, "+".join(reached) or "none", "none",
                 vm_runtime="pass" if ok else "fail",
                 failure_code=None if ok else next((k for k, v in checked.items() if not v["pass"]), "stop_or_exit"),
                 session_states=states, stop=cycle, owner_exit=status)


# ---------------------------------------------------------------- phase 3/4: view owner


def view_owner(rd, rid, topology, domain):
    argv = [PROBE, "vm-view", VM, "--topology", topology, "--socket", SOCK, "--run-dir", rd, "--run-id", rid,
            "--context", DOMAIN_CONTEXT[domain]]
    owner = Owner(domain, argv, rd).start()
    try:
        wait_for(lambda: _sock_state().get("vm_state") == "running", 90, "view owner running", 0.5)
        wait_for(lambda: _sock_state().get("boot_id"), 600, "guest helper hello", 2)
        wait_for(ssh_ok, 300, "ssh", 3)
    except BaseException:
        stop_view_owner(owner)  # never leave a VM running behind a failed start
        raise
    return owner


def _sock_state():
    try:
        return call({"op": "state"}, timeout=10)
    except OSError:
        return {}


def stop_view_owner(owner, rd=None):
    """Stop the VM and the owner. With `rd`, a stop that was not graceful fails the run's runtime."""
    try:
        reply = call({"op": "stop"}, timeout=240)
        call({"op": "quit"})
    except (OSError, ValueError) as e:
        reply = {"ok": False, "error": f"control socket: {e}"}
    owner.wait(30)
    owner.kill()
    res = rd / "result.json" if rd else None
    if res and res.exists():
        r = json.loads(res.read_text())
        r["stop"] = reply
        if not reply.get("ok"):
            r["vm_runtime"] = "fail"
            r["failure_code"] = "; ".join(x for x in (r.get("failure_code"), f"stop: {reply}") if x)
        res.write_text(json.dumps(r, indent=2, default=str))
    return reply


def analyze(png, layout):
    r = subprocess.run([str(PROBE), "analyze-frame", str(png), "--layout", str(layout)], capture_output=True,
                       text=True, timeout=60)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"ok": False, "error": r.stderr.strip()[:200]}


def frame_ok(a, token):
    return (a.get("ok") and a.get("token") == token and a.get("calibration_spread", 0) > 60
            and a.get("token_margin", 0) > 20 and a.get("counter_margin", 0) > 20
            and (a.get("channel_range") or 0) > 3)


def wait_first_frame(rd, fx, timeout=90):
    """Boot frames are legitimately blank for a while: wait (bounded) for a first good frame."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        png = rd / "screenshots" / "first.png"
        f = call({"op": "frame", "path": str(png), "method": "cache"})
        if f.get("ok") and frame_ok(analyze(png, fx.layout_path), fx.token):
            return True
        time.sleep(2)
    return False


def observe(rd, fx, method, n, keep=3):
    """Spec §12 oracle loop: SSH-read the guest counter, capture, decode, require token + freshness."""
    ce = rd / "capture-events.jsonl"
    prev, streak, best, fails, ok_count = None, 0, 0, [], 0
    for i in range(n):
        try:
            st = guest_state()
        except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
            fails.append({"i": i, "error": f"guest state: {e}"})
            streak = 0
            continue
        t_read = time.time()
        png = rd / "screenshots" / f"{method}-{i:05d}.png"
        f = call({"op": "frame", "path": str(png), "method": method})
        rec = {"i": i, "method": method, "ssh_counter": st["frame_counter"], "frame": f}
        if not f.get("ok"):
            rec["status"] = "refused"
        else:
            a = analyze(png, fx.layout_path)
            elapsed = time.time() - t_read
            rec["analysis"] = {k: a.get(k) for k in ("token", "counter", "token_margin", "counter_margin",
                                                    "calibration_spread", "channel_range", "pixel_sha256")}
            fresh = prev is None or (a.get("counter") or -1) > prev
            in_window = st["frame_counter"] - 1 <= (a.get("counter") or -1) <= st["frame_counter"] + elapsed / 0.25 + 4
            good = bool(frame_ok(a, fx.token) and fresh and in_window and st["run_token"] == fx.token)
            rec.update(token_ok=a.get("token") == fx.token, fresh=fresh, counter_in_window=in_window,
                       status="pass" if good else "fail")
            if good:
                prev = a["counter"]
        append(ce, rec)
        if rec["status"] == "pass":
            ok_count += 1
            streak += 1
            best = max(best, streak)
            if i >= keep:
                png.unlink(missing_ok=True)
        else:
            streak = 0
            fails.append({k: rec.get(k) for k in ("i", "status", "token_ok", "fresh", "counter_in_window", "ssh_counter")}
                         | {"error": f.get("error"), "decoded": rec.get("analysis")})
            if len(fails) >= 20 and ok_count == 0:
                break  # no point continuing: nothing observable
        time.sleep(0.5)
    attempted = i + 1 if n else 0
    return {"method": method, "requested": n, "attempted": attempted, "passed": ok_count,
            "longest_streak": best, "failures": fails[:20],
            "status": "pass" if n and ok_count == attempted == n else "fail",
            "qualifying": best >= 1000}


def observe_sck(rd, fx, n=3):
    st = _sock_state()
    w = st.get("window") or {}
    if not w.get("present"):
        return {"status": "not_supported", "reason": "no window"}
    runs = []
    for i in range(n):
        png = rd / "screenshots" / f"sck-{i}.png"
        r = subprocess.run([str(PROBE), "sck-capture", "--window-id", str(w["window_number"]), "--out", str(png)],
                           capture_output=True, text=True, timeout=60)
        try:
            res = json.loads(r.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            res = {"ok": False, "error": r.stderr.strip()[:200]}
        if res.get("ok"):
            res["analysis"] = analyze(png, fx.layout_path)
            res["token_ok"] = frame_ok(res["analysis"], fx.token)
        runs.append(res)
        append(rd / "capture-events.jsonl", {"method": "sck", "i": i, **res})
        time.sleep(0.6)
    if all(not r.get("ok") for r in runs):
        return {"status": "environment_error", "runs": runs,
                "reason": "ScreenCaptureKit refused (Screen Recording permission for the capturing process?)"}
    return {"status": "pass" if all(r.get("token_ok") for r in runs) else "fail", "runs": runs}


def grid_geometry(rd, fx):
    """Grid rectangle derived from the observed framebuffer (magenta corner markers)."""
    png = rd / "screenshots" / "grid-geometry.png"
    f = call({"op": "frame", "path": str(png), "method": "cache"})
    lay = fx.state["layout"]["grid"]
    if f.get("ok"):
        a = analyze(png, fx.layout_path)
        g = a.get("grid_observed")
        if g:
            delta = max(abs(g[k] - lay[k]) for k in ("x", "y", "w", "h"))
            return g, {"source": "framebuffer", "max_delta_vs_fixture_px": round(delta, 2)}
    return lay, {"source": "fixture_layout", "reason": f.get("error") or "markers not found"}


def cell_target(g, n, rng, margin=0.15):
    r, c = rng.randrange(n), rng.randrange(n)
    cw, chh = g["w"] / n, g["h"] / n
    x = g["x"] + (c + rng.uniform(margin, 1 - margin)) * cw
    y = g["y"] + (r + rng.uniform(margin, 1 - margin)) * chh
    return f"{chr(65 + r)}{c + 1:02d}", x, y


def center(rect):
    return rect["x"] + rect["w"] / 2, rect["y"] + rect["h"] / 2


def pointer_tests(rd, fx, sess, clicks, seed):
    ie = rd / "input-events.jsonl"
    rng = random.Random(seed)
    g, geo = grid_geometry(rd, fx)
    n = fx.state["layout"]["grid_n"]
    wrong, missing, offpos, refused = [], [], [], []
    done = 0
    for i in range(clicks):
        cell, x, y = cell_target(g, n, rng)
        r = call({"op": "click", "session": sess, "x": x, "y": y})
        done += 1
        if not r.get("ok"):
            refused.append({"i": i, "error": r.get("error")})
            append(ie, {"test": "click", "i": i, "want": cell, "refused": r.get("error")})
            if len(refused) >= 20 and done == len(refused):
                break
            continue
        down = fx.expect(lambda e: e["ev"] == "down" and e.get("button") == "left", 3)
        up = fx.expect(lambda e: e["ev"] == "up" and e.get("button") == "left", 3)
        rec = {"test": "click", "i": i, "want": cell, "x": round(x, 2), "y": round(y, 2),
               "got": down and down["cell"], "px": down and down["px"]}
        append(ie, rec)
        if not down or not up:
            missing.append(rec)
            if len(missing) >= 20 and len(missing) == done:
                break  # silent drop of everything: stop early, this is a fail
            continue
        if down["cell"] != cell or up["cell"] != cell:
            wrong.append(rec)
        if abs(down["px"][0] - x) > 1.5 or abs(down["px"][1] - y) > 1.5:
            offpos.append(rec)
        if i % 100 == 99:
            st = guest_state()
            if st.get("last_clicked_cell") != cell:
                wrong.append({**rec, "ssh_last_clicked_cell": st.get("last_clicked_cell")})
            say(f"clicks {i + 1}: wrong={len(wrong)} missing={len(missing)} offpos={len(offpos)}")
    clicks_res = {"requested": clicks, "attempted": done, "wrong": len(wrong), "missing": len(missing),
                  "off_position_gt_1_5px": len(offpos), "refused": len(refused), "geometry": geo,
                  "examples": (wrong + missing + offpos + refused)[:20]}
    clicks_res["status"] = "pass" if done == clicks and not (wrong or missing or offpos or refused) else "fail"

    cov = {}

    def moved_to(x, y):
        call({"op": "move", "session": sess, "x": x, "y": y})
        e = fx.expect(lambda e: e["ev"] == "move" and abs(e["px"][0] - x) <= 1.5 and abs(e["px"][1] - y) <= 1.5, 2)
        return bool(e)

    W, H = fx.state["screen_px"]["w"], fx.state["screen_px"]["h"]
    pts = [(rng.uniform(0, W - 1), rng.uniform(0, H - 1)) for _ in range(50)]
    cov["move"] = sum(moved_to(x, y) for x, y in pts) == len(pts)
    edges = [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1), (W / 2, 0), (0, H / 2), (W - 1, H / 2), (W / 2, H - 1)]
    cov["edges_corners"] = {f"{int(x)},{int(y)}": moved_to(x, y) for x, y in edges}

    # NSEvent.mouseEvent cannot set buttonNumber; a CGEvent-built (never posted)
    # NSEvent can. Both are recorded; the cgevent source is the one under test.
    by_source = {}
    for source in ("nsevent", "cgevent"):
        rc = []
        for _ in range(20):
            cell, x, y = cell_target(g, n, rng)
            call({"op": "click", "session": sess, "x": x, "y": y, "button": "right", "source": source})
            got = [e for e in fx.drain(0.8) if e["ev"] != "move"]
            d = next((e for e in got if e["ev"] == "down" and e.get("button") == "right"), None)
            u = next((e for e in got if e["ev"] == "up" and e.get("button") == "right"), None)
            rc.append(bool(d and u and d["cell"] == cell and abs(d["px"][0] - x) <= 1.5 and abs(d["px"][1] - y) <= 1.5))
            append(ie, {"test": "right_click", "source": source, "want": cell, "x": x, "y": y, "events": got})
            call({"op": "key", "session": sess, "events": [
                {"type": "down", "keyCode": 53, "chars": "\x1b", "flags": 0},
                {"type": "up", "keyCode": 53, "chars": "\x1b", "flags": 0}]})
            fx.drain(0.3)
        by_source[source] = sum(rc)
    cov["right_click"] = by_source["cgevent"] == 20
    cov["right_click_by_source"] = by_source
    dc = []
    for _ in range(20):
        cell, x, y = cell_target(g, n, rng)
        call({"op": "click", "session": sess, "x": x, "y": y, "count": 2})
        downs = [fx.expect(lambda e: e["ev"] == "down" and e.get("button") == "left", 3) for _ in range(2)]
        dc.append(all(downs) and downs[1]["click_count"] == 2 and all(d["cell"] == cell for d in downs))
        fx.drain(0.3)
        time.sleep(0.6)  # outlast the double-click interval
    cov["double_click"] = all(dc)

    cell, x, y = cell_target(g, n, rng)
    call({"op": "move", "session": sess, "x": x, "y": y})
    call({"op": "button", "session": sess, "x": x, "y": y, "button": "left", "down": True})
    time.sleep(0.4)
    held = guest_state().get("buttons_down")
    call({"op": "button", "session": sess, "x": x, "y": y, "button": "left", "down": False})
    time.sleep(0.4)
    released = guest_state().get("buttons_down")
    cov["down_up"] = held == ["left"] and released == []

    lay = fx.state["layout"]
    hx, hy = center(lay["drag_handle"])
    drags = []
    for steps, label in ((20, "drag"), (300, "long_drag")):
        res = []
        for tid in (rng.sample(sorted(lay["drag_targets"]), 4)):
            tx, ty = center(lay["drag_targets"][tid])
            call({"op": "drag", "session": sess, "x0": hx, "y0": hy, "x1": tx, "y1": ty, "steps": steps}, timeout=120)
            e = fx.expect(lambda e: e["ev"] == "drag_up", 5)
            # The guest coalesces mouseDragged events; require movement, not a count.
            res.append(bool(e and e["on_handle"] and e["target"] == tid and e["steps"] >= 1))
            drags.append({"label": label, "target": tid, "event": e})
        cov[label] = all(res)
    append(ie, {"test": "drag", "drags": drags})

    # Scroll each way; the guest's natural-scrolling setting decides which way is "down",
    # so require only that opposite inputs move the region in opposite directions.
    sx, sy = center(lay["scroll"])
    detail = []
    for dy in (200, -200, -200, 200):
        fx.drain(0.3)
        before = guest_state().get("scroll_y")
        call({"op": "scroll", "session": sess, "x": sx, "y": sy, "dy": dy, "dx": 0})
        se = fx.expect(lambda e: e["ev"] == "scroll" and e.get("dy"), 3)
        time.sleep(0.8)
        after = guest_state().get("scroll_y")
        detail.append({"sent_dy": dy, "event": se, "scroll_y_before": before, "scroll_y_after": after,
                       "moved": (after or 0) - (before or 0)})
    # Steps 1 and 2 start from the top in opposite directions; 2 and 4 are a matched pair.
    signs = {d["sent_dy"] > 0: [] for d in detail}
    for d in detail:
        if d["moved"]:
            signs[d["sent_dy"] > 0].append(d["moved"] > 0)
    consistent = all(len(set(v)) == 1 for v in signs.values() if v) and len(signs[True]) and len(signs[False])
    opposite = consistent and signs[True][0] != signs[False][0]
    cov["scroll"] = bool(all(d["event"] for d in detail) and opposite)
    cov["scroll_detail"] = detail
    append(ie, {"test": "coverage", **cov})
    cov_ok = all(v if isinstance(v, bool) else all(v.values()) for k, v in cov.items()
                 if k not in ("scroll_detail", "right_click_by_source"))
    return clicks_res, {"status": "pass" if cov_ok else "fail", **cov}


# macOS virtual key codes (US ANSI)
KC = {**{c: k for c, k in zip("asdfhgzxcv", range(10))},
      "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
      "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
      "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
      " ": 49, "`": 50}
SPECIAL = {"return": 36, "tab": 48, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
           "fwddelete": 117}
MOD = {"shift": (56, 1 << 17), "control": (59, 1 << 18), "option": (58, 1 << 19), "command": (55, 1 << 20)}
SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': '-', '+': '=', '{': '[', '}': ']', '|': '\\', ':': ';', '"': "'", '<': ',', '>': '.', '?': '/', '~': '`'}
# VZVirtualMachineView ignores modifiers unless the event carries the
# device-dependent (left/right) bits that hardware events have (Q0 finding 5).
DEVICE_BITS = {1 << 17: 0x2, 1 << 18: 0x1, 1 << 19: 0x20, 1 << 20: 0x8}
TEXT = "Hello, World! 0123456789 the quick brown fox; [x]=\\/'`"


def with_device_bits(flags):
    dev = 0
    for bit, d in DEVICE_BITS.items():
        if flags & bit:
            dev |= d
    return flags | dev | (0x100 if dev else 0)


class KeyScript:
    def __init__(self):
        self.events, self.expect = [], []

    def tap(self, code, chars, flags):
        for kind in ("down", "up"):
            self.events.append({"type": kind, "keyCode": code, "chars": chars, "flags": with_device_bits(flags)})
            self.expect.append((kind, code, flags))

    def mods(self, names, press):
        cur = 0 if press else sum(MOD[n][1] for n in names)
        for n in (names if press else list(reversed(names))):
            code, bit = MOD[n]
            cur = cur | bit if press else cur & ~bit
            self.events.append({"type": "flags", "keyCode": code, "flags": with_device_bits(cur)})
            self.expect.append(("flags", code, cur))
        return sum(MOD[n][1] for n in names)

    def text(self, s):
        for ch in s:
            if ch.isupper() or ch in SHIFTED:
                base = ch.lower() if ch.isalpha() else SHIFTED[ch]
                f = self.mods(["shift"], True)
                self.tap(KC[base], ch, f)
                self.mods(["shift"], False)
            else:
                self.tap(KC[ch], ch, 0)
        return self


def key_batch_b():
    k = KeyScript()
    for name in ("return", "tab", "escape", "left", "right", "up", "down", "delete", "fwddelete"):
        k.tap(SPECIAL[name], "", 0)
    for combo, key in ((["command"], "s"), (["command"], "q"), (["control"], "a"), (["option"], "x"),
                       (["shift", "command"], "k"), (["control", "option"], "b"),
                       (["control", "option", "command"], "m"), (["shift"], "left")):
        f = k.mods(combo, True)
        k.tap(SPECIAL.get(key, KC.get(key)), "" if key in SPECIAL else key, f)
        k.mods(combo, False)
    # Interrupted modifier sequence: shift+option down, tap, release in non-LIFO order.
    f = k.mods(["shift", "option"], True)
    k.tap(KC["z"], "Z", f)
    for code, flags in ((56, MOD["option"][1]), (58, 0)):
        k.events.append({"type": "flags", "keyCode": code, "flags": with_device_bits(flags)})
        k.expect.append(("flags", code, flags))
    k.tap(KC["q"], "q", 0)  # sentinel: modifiers must be clear here
    return k


def run_keys(fx, sess, script):
    r = call({"op": "key", "session": sess, "events": script.events}, timeout=300)
    got = fx.drain(settle=2.0)
    observed = [(e["ev"], e["keyCode"], e["flags"] & 0x1F0000) for e in got if e["ev"] in ("down", "up", "flags")]
    want = [(a, c, f & 0x1F0000) for a, c, f in script.expect]
    diff = next((i for i, (a, b) in enumerate(zip(observed, want)) if a != b), None)
    if diff is None and len(observed) != len(want):
        diff = min(len(observed), len(want))
    ctx = slice(max(0, (diff or 0) - 3), (diff or 0) + 6)
    return {"ok": bool(r.get("ok")), "error": r.get("error"), "sent": len(script.events), "expected": len(want),
            "observed": len(observed), "first_diff": diff,
            "diff_context": None if diff is None else {"want": want[ctx], "got": observed[ctx]}}


def keyboard_tests(rd, fx, sess):
    lay = fx.state["layout"]
    tx, ty = center(lay["text"])
    call({"op": "click", "session": sess, "x": tx, "y": ty})
    time.sleep(0.5)
    fx.drain(0.5)
    a = run_keys(fx, sess, KeyScript().text(TEXT))
    st = guest_state()
    a["received_text"] = st.get("received_text")
    a["text_exact"] = st.get("received_text") == TEXT
    pid0 = st.get("pid")
    b = run_keys(fx, sess, key_batch_b())
    st = guest_state()
    b["keys_down_after"] = st.get("keys_down")
    b["modifiers_after"] = st.get("modifiers")
    time.sleep(0.6)
    later = guest_state()
    # Liveness only: the fixture swallows Command key-downs, so Cmd-Q cannot quit it.
    b["fixture_alive_after"] = later.get("pid") == pid0 and later["frame_counter"] > st["frame_counter"]
    append(rd / "input-events.jsonl", {"test": "keyboard", "batch_a": a, "batch_b": b})
    ok = (a["ok"] and a["first_diff"] is None and a["text_exact"] and b["ok"] and b["first_diff"] is None
          and b["keys_down_after"] == [] and b["modifiers_after"] == 0 and b["fixture_alive_after"])
    return {"status": "pass" if ok else "fail", "text": a, "specials_modifiers": b,
            "cmd_tab": "not_run (not claimed)"}


def host_focus_delta(before, after):
    keys = ("cursor", "modifier_flags", "pressed_mouse_buttons", "frontmost_pid", "front_window")
    d = {k: (before.get(k), after.get(k)) for k in keys if before.get(k) != after.get(k)}
    if after.get("probe_app_key_events", 0) != before.get("probe_app_key_events", 0):
        d["probe_app_key_events"] = (before.get("probe_app_key_events"), after.get("probe_app_key_events"))
    return d


def session_label(state=None):
    """Spec §10 label from the observed host state, never assumed."""
    st = state or host_session_state()
    if st.get("console_locked") is None or st.get("display") not in ("on", "off"):
        return "unknown"
    if st["console_locked"] is False:
        return "S0" if st["display"] != "off" else "S2"
    return "S1+S2" if st["display"] == "off" else "S1"


def topology_reached(topo, w):
    """The window state each topology claims; a run is only evidence for the topology it reached."""
    w = w or {}
    checks = {
        "V0": w.get("visible") and w.get("key"),
        "V1": w.get("visible") and w.get("on_screen") and not w.get("key"),
        "V2": w.get("visible") and w.get("occluded_by_cover") and not w.get("occlusion_visible"),
        "V3": w.get("present") and not w.get("on_active_space", True),
        "V4": w.get("miniaturized") and not w.get("visible"),
        "V5": w.get("present") and not w.get("visible"),
        "V6": w.get("present") and w.get("visible") and not w.get("on_screen"),
        "V7": w.get("view_present") and not w.get("present"),
        "V8": not w.get("view_present") and not w.get("present"),
    }
    return bool(checks[topo])


def vm_runtime_now():
    return "pass" if _sock_state().get("vm_state") == "running" else "fail"


def cmd_phase3(args):
    topo, domain = args.topology, args.domain
    ctx = DOMAIN_CONTEXT[domain]
    rid, rd = new_run(f"p3-{topo}-{ctx}")
    (rd / "metadata.json").write_text(json.dumps({**metadata(), "phase": 3, "topology": topo, "domain": domain}, indent=2))
    start_state = host_session_state()
    append(rd / "host-session-events.jsonl", {"event": "start", **start_state})
    label = session_label(start_state)
    fields = {}
    statuses = {}
    try:
        owner = view_owner(rd, rid, topo, domain)
    except (EnvironmentError, TimeoutError) as e:
        return write_result(rd, rid, ctx, label, topo, vm_runtime="fail", failure_code=f"owner: {e}")
    fx = Fixture(rd)
    try:
        fx.start()
        fields["window"] = _sock_state().get("window")
        if topo == "V3" and args.operator_wait:
            say(f"OPERATOR: move the probe window to another Space within {args.operator_wait}s")
            time.sleep(args.operator_wait)
            fields["window"] = _sock_state().get("window")
        fields["topology_reached"] = topology_reached(topo, fields["window"])
        if not fields["topology_reached"]:
            return write_result(rd, rid, ctx, label, topo, vm_runtime=vm_runtime_now(),
                                failure_code=f"topology {topo} not reached: window {fields['window']}", **fields)
        focus = {}

        def batch(name, fn):
            # Host state around each batch (spec §13); the owner and its topology already exist.
            before = call({"op": "hostinput"})
            out = fn()
            focus[name] = host_focus_delta(before, call({"op": "hostinput"}))
            return out

        if topo == "V8":
            fields["observation_detail"] = {"status": "not_supported", "reason": "no view"}
            for k in ("observation", "pointer", "keyboard"):
                statuses[k] = "not_supported"
        else:
            fields["first_good_frame"] = wait_first_frame(rd, fx)
            obs_cache = batch("observation", lambda: observe(rd, fx, "cache", args.captures))
            obs_layer = observe(rd, fx, "layer", args.layer_captures)
            obs = {"status": obs_cache["status"], "O1_cache": obs_cache, "O1_layer_diagnostic": obs_layer}
            fields.update(observation_detail=obs, qualifying_captures=obs_cache["qualifying"])
            statuses["observation"] = obs["status"]
            fields["o2_sck"] = observe_sck(rd, fx) if args.sck else {"status": "not_run"}
            sess = call({"op": "session"})
            if not sess.get("ok"):
                raise RuntimeError(f"session: {sess}")
            clicks, coverage = batch("pointer", lambda: pointer_tests(rd, fx, sess["session"], args.clicks, args.seed))
            pointer = {"status": "pass" if clicks["status"] == "pass" and coverage["status"] == "pass" else "fail",
                       "random_clicks": clicks, "coverage": coverage}
            fields.update(pointer_detail=pointer, qualifying_clicks=clicks["status"] == "pass" and args.clicks >= 10000)
            statuses["pointer"] = pointer["status"]
            keyboard = batch("keyboard", lambda: keyboard_tests(rd, fx, sess["session"]))
            fields["keyboard_detail"] = keyboard
            statuses["keyboard"] = keyboard["status"]
        fields["host_focus_changed"] = {k: v for k, v in focus.items() if v}
        fields["host_focus_note"] = ("host console locked: cursor and frontmost app cannot change"
                                     if start_state["console_locked"] else None)
        failure = None
        for k in ("pointer", "keyboard", "observation"):
            # Unintended host cursor movement / focus theft fails the batch (spec §13).
            if focus.get(k) and statuses.get(k) == "pass":
                statuses[k] = "fail"
                failure = failure or f"host focus/cursor changed during {k}: {sorted(focus[k])}"
        failure = failure or next((k for k in ("observation", "pointer", "keyboard") if statuses.get(k) == "fail"), None)
        return write_result(rd, rid, ctx, label, topo, vm_runtime=vm_runtime_now(), failure_code=failure,
                            **statuses, **fields)
    except Exception as e:  # noqa: BLE001
        # Keep whatever was measured before the error.
        return write_result(rd, rid, ctx, label, topo, vm_runtime=vm_runtime_now(),
                            failure_code=f"{type(e).__name__}: {e}", **statuses, **fields)
    finally:
        fx.stop()
        stop_view_owner(owner, rd)
        append(rd / "host-session-events.jsonl", {"event": "end", **host_session_state()})


def quick_checks(rd, fx, sess, rng, name, expect):
    """Phase 4 per-transition check: VM, SSH, fresh frames, pointer, keyboard, host focus."""
    row = {"state": name, **host_session_state()}
    row["expected"] = expect
    row["state_reached"] = all(row[k] == v for k, v in expect.items())
    row["session_label"] = session_label(row)
    st = _sock_state()
    row["vm_running"] = st.get("vm_state") == "running"
    row["ssh_alive"] = ssh_ok()
    before = call({"op": "hostinput"})
    o = observe(rd, fx, "cache", 5, keep=1)
    row["frame_fresh"] = o["status"] == "pass"
    g, _ = grid_geometry(rd, fx)
    ok = 0
    for _ in range(50):
        cell, x, y = cell_target(g, fx.state["layout"]["grid_n"], rng)
        r = call({"op": "click", "session": sess, "x": x, "y": y})
        d = fx.expect(lambda e: e["ev"] == "down" and e.get("button") == "left", 3)
        fx.expect(lambda e: e["ev"] == "up", 3)
        ok += bool(r.get("ok") and d and d["cell"] == cell)
    row["pointer_correct"] = ok == 50
    tx, ty = center(fx.state["layout"]["text"])
    call({"op": "click", "session": sess, "x": tx, "y": ty})
    fx.drain(0.5)
    k = run_keys(fx, sess, KeyScript().text("abc XYZ 123"))
    row["keyboard_correct"] = k["ok"] and k["first_diff"] is None
    after = call({"op": "hostinput"})
    row["host_focus_unchanged"] = not host_focus_delta(before, after)
    row["pass"] = all(row[k] for k in ("vm_running", "ssh_alive", "frame_fresh", "pointer_correct",
                                       "keyboard_correct", "host_focus_unchanged"))
    append(rd / "host-session-events.jsonl", {"event": "check", **row})
    say(name, json.dumps(row))
    return row


def cmd_phase4(args):
    topo, domain = args.topology, args.domain
    ctx = DOMAIN_CONTEXT[domain]
    rid, rd = new_run(f"p4-{topo}-{ctx}")
    (rd / "metadata.json").write_text(json.dumps({**metadata(), "phase": 4, "topology": topo, "domain": domain}, indent=2))
    try:
        owner = view_owner(rd, rid, topo, domain)
    except Exception as e:  # noqa: BLE001
        return write_result(rd, rid, ctx, session_label(), topo, vm_runtime="fail", failure_code=f"owner: {e}")
    fx = Fixture(rd)
    rng = random.Random(args.seed)
    rows = {}
    error = None
    try:
        fx.start()
        window = _sock_state().get("window")
        if not topology_reached(topo, window):
            return write_result(rd, rid, ctx, session_label(), topo, vm_runtime=vm_runtime_now(),
                                failure_code=f"topology {topo} not reached: window {window}")
        wait_first_frame(rd, fx)
        sess = call({"op": "session"})["session"]
        rows["baseline"] = quick_checks(rd, fx, sess, rng, "baseline", {})
        subprocess.run(["pmset", "displaysleepnow"])
        time.sleep(15)
        rows["lock+display_sleep"] = quick_checks(rd, fx, sess, rng, "lock+display_sleep",
                                                  {"console_locked": True, "display": "off"})
        subprocess.run(["caffeinate", "-u", "-t", "5"])
        time.sleep(6)
        rows["display_wake_locked"] = quick_checks(rd, fx, sess, rng, "display_wake_locked",
                                                   {"console_locked": True, "display": "on"})
        for name, instruction in (("unlock", "unlock the host"), ("inactive_space", "switch to another Space"),
                                  ("fast_user_switch", "fast-user-switch away and back"),
                                  ("host_sleep_wake", "sleep and wake the host")):
            if args.operator_wait:
                say(f"OPERATOR: {instruction} within {args.operator_wait}s")
                time.sleep(args.operator_wait)
                rows[name] = quick_checks(rd, fx, sess, rng, name, {})
            else:
                rows[name] = {"status": "not_run", "reason": "needs operator (--operator-wait)"}
    except Exception as e:  # noqa: BLE001
        error = f"{type(e).__name__}: {e}"  # keep the rows measured so far
    finally:
        fx.stop()
        stop = stop_view_owner(owner, rd)
    checked = {k: v for k, v in rows.items() if "pass" in v}
    ok = bool(checked) and all(v["pass"] for v in checked.values()) and stop.get("ok") and not error

    def status(key):
        return "not_run" if not checked else "pass" if all(v[key] for v in checked.values()) else "fail"

    reached = sorted({v["session_label"] for v in checked.values() if v["state_reached"]})
    failure = None if ok else (error or next((k for k, v in checked.items() if not v["pass"]), f"stop: {stop}"))
    write_result(rd, rid, ctx, "+".join(reached) or "unknown", topo,
                 vm_runtime=status("vm_running") if stop.get("ok") else "fail", stop=stop,
                 observation=status("frame_fresh"), pointer=status("pointer_correct"),
                 keyboard=status("keyboard_correct"), failure_code=failure, transitions=rows)


def cmd_e9(args):
    """E9: sessions die with the guest boot and with the VM instance.

    One owner: a session works; a guest reboot must refuse it ("boot identity
    changed") and never accept it on the new boot; a new session works; then the
    owner replaces its VM (`restart_vm`, new instance, same process and session
    table) and must refuse the previous session with "vm instance changed".
    """
    topo, domain = args.topology, args.domain
    ctx = DOMAIN_CONTEXT[domain]
    rid, rd = new_run(f"e9-{topo}-{ctx}")
    (rd / "metadata.json").write_text(json.dumps({**metadata(), "phase": "E9", "topology": topo, "domain": domain}, indent=2))
    try:
        owner = view_owner(rd, rid, topo, domain)
    except Exception as e:  # noqa: BLE001
        return write_result(rd, rid, ctx, session_label(), topo, vm_runtime="fail", failure_code=f"owner: {e}")
    out, error, stop = {}, None, {}
    fx = Fixture(rd)

    def hit(session, seed):
        g, _ = grid_geometry(rd, fx)
        cell, x, y = cell_target(g, fx.state["layout"]["grid_n"], random.Random(seed))
        r = call({"op": "click", "session": session, "x": x, "y": y})
        d = fx.expect(lambda e: e["ev"] == "down", 3)
        return bool(r.get("ok") and d and d["cell"] == cell)

    try:
        fx.start()
        st0 = _sock_state()
        if not topology_reached(topo, st0.get("window")):
            return write_result(rd, rid, ctx, session_label(), topo, vm_runtime=vm_runtime_now(),
                                failure_code=f"topology {topo} not reached: window {st0.get('window')}")
        wait_first_frame(rd, fx)
        s1 = call({"op": "session"})["session"]
        out["s1_before_reboot"] = hit(s1, 1)
        fx.stop()
        try:
            sudo("shutdown -r now", timeout=20)
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        attempts, t0 = [], time.time()
        while time.time() - t0 < 600:
            r = call({"op": "click", "session": s1, "x": 10, "y": 10})
            st = _sock_state()
            attempts.append({"t": round(time.time() - t0, 1), "ok": r.get("ok"), "error": r.get("error"),
                             "boot": st.get("boot_id")})
            if st.get("boot_id") and st["boot_id"] != st0["boot_id"]:
                break
            time.sleep(1)
        new_boot = _sock_state().get("boot_id")
        out["new_boot_seen"] = bool(new_boot) and new_boot != st0["boot_id"]
        out["accepted_after_boot_change"] = [a for a in attempts if a["ok"] and a["boot"] != st0["boot_id"]]
        out["attempts"] = attempts  # ordered: the first refusal must be the staleness check
        out["refusals"] = sorted({a["error"] for a in attempts if a["error"]})
        # The refusal must be the staleness check, not a generic one.
        first_refusal = next((a["error"] for a in attempts if a["error"]), "")
        out["refused_as_stale"] = "boot identity changed" in first_refusal
        out["old_session_after_reboot"] = call({"op": "click", "session": s1, "x": 10, "y": 10})
        wait_for(ssh_ok, 300, "ssh after reboot", 3)
        fx = Fixture(rd).start()
        s2 = call({"op": "session"})["session"]
        out["s2_after_reboot"] = hit(s2, 2)
        fx.stop()

        out["restart_vm"] = call({"op": "restart_vm"}, timeout=600)
        out["s2_after_vm_restart"] = call({"op": "click", "session": s2, "x": 10, "y": 10})
        wait_for(lambda: _sock_state().get("boot_id"), 600, "guest helper hello after restart", 2)
        wait_for(ssh_ok, 300, "ssh after restart", 3)
        fx = Fixture(rd).start()
        wait_first_frame(rd, fx)
        s3 = call({"op": "session"})["session"]
        out["s3_after_vm_restart"] = hit(s3, 3)
    except Exception as e:  # noqa: BLE001
        error = f"{type(e).__name__}: {e}"
    finally:
        fx.stop()
        stop = stop_view_owner(owner, rd)
    instance_refusal = (out.get("s2_after_vm_restart") or {}).get("error") or ""
    ok = bool(not error and out.get("s1_before_reboot") and out.get("new_boot_seen")
              and not out.get("accepted_after_boot_change") and out.get("refused_as_stale")
              and not out["old_session_after_reboot"].get("ok") and out.get("s2_after_reboot")
              and (out.get("restart_vm") or {}).get("ok") and "vm instance changed" in instance_refusal
              and out.get("s3_after_vm_restart"))
    write_result(rd, rid, ctx, session_label(), topo, vm_runtime="pass" if stop.get("ok") else "fail",
                 pointer="pass" if ok else "fail", stop=stop,
                 failure_code=None if ok and stop.get("ok") else (error or ("e9" if not ok else f"stop: {stop}")),
                 e9=out)


def cmd_auth_check(_args):
    """A non-root guest process cannot read the helper key, and a hello signed with
    any other key is rejected without disturbing the accepted one."""
    rid, rd = new_run("auth-C1")
    (rd / "metadata.json").write_text(json.dumps({**metadata(), "phase": "auth"}, indent=2))
    owner = headless_owner(rd, rid, "C1", "user")
    out = {}
    try:
        ev = wait_event(rd, lambda e: e["event"] in ("guest_ssh_banner", "cycle_result"), 900, owner)
        if not ev or ev["event"] != "guest_ssh_banner":
            raise RuntimeError("guest not reachable")
        wait_for(ssh_ok, 120, "ssh")
        wait_for(lambda: json.loads((rd / "status.json").read_text()).get("boot_id"), 120, "authenticated hello")
        before = json.loads((rd / "status.json").read_text())
        rejected0 = sum(1 for e in events(rd) if e["event"] == "guest_hello_rejected")
        out["user_can_read_key"] = ssh("cat /usr/local/etc/iso-vz-probe-helper.key >/dev/null 2>&1 && echo yes || echo no").strip()
        # The real helper binary, as the unprivileged guest user, with a key of its own.
        ssh("umask 077; head -c 32 /dev/urandom | xxd -p -c 64 > /tmp/forged.key; "
            "( ~/IsoVZProbe/iso-vz-probe-helper /dev/null /tmp/forged.key & p=$!; sleep 8; kill $p ); rm -f /tmp/forged.key")
        time.sleep(2)
        after = json.loads((rd / "status.json").read_text())
        rejected = [e for e in events(rd) if e["event"] == "guest_hello_rejected"][rejected0:]
        out.update(rejected=[e.get("reason") for e in rejected], boot_before=before.get("boot_id"),
                   boot_after=after.get("boot_id"), generation_before=before.get("helper_generation"),
                   generation_after=after.get("helper_generation"))
    except Exception as e:  # noqa: BLE001
        out["error"] = f"{type(e).__name__}: {e}"
    finally:
        (rd / "stop").touch()
        status = owner.wait(300)
        owner.kill()
    ok = (not out.get("error") and out.get("user_can_read_key") == "no" and "bad mac" in out.get("rejected", [])
          and out.get("boot_before") == out.get("boot_after")
          and out.get("generation_before") == out.get("generation_after"))
    write_result(rd, rid, "C1", session_label(), "none", vm_runtime="pass" if status == 0 else "fail",
                 failure_code=None if ok else f"auth check: {out}", auth_check="pass" if ok else "fail", auth=out)


# ---------------------------------------------------------------- report


def cmd_report(_args):
    rows = []
    for p in sorted(RESULTS.glob("*/result.json")):
        r = json.loads(p.read_text())
        rows.append(r)
    lines = ["# VZ context experiment results", "", "```"] + [f"{k}: {v}" for k, v in metadata().items()] + ["```", "",
             "| run | context | session | topology | runtime | observation | pointer | keyboard | qualifying | failure |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['run_id']} | {r['context']} | {r['session_state']} | {r['view_topology']} | "
                     f"{r['vm_runtime']} | {r['observation']} | {r['pointer']} | {r['keyboard']} | "
                     f"{'yes' if r.get('qualifying_clicks') and r.get('qualifying_captures') else 'no'} | "
                     f"{(r.get('failure_code') or '')[:80]} |")
    agg = {}
    for r in rows:
        if "-p1-" in r["run_id"]:
            a = agg.setdefault(r["context"], [0, 0])
            a[0] += r["vm_runtime"] == "pass"
            a[1] += 1
    lines += ["", "## Phase 1 runtime by context", ""] + [f"- {c}: {p}/{n} pass" for c, (p, n) in sorted(agg.items())]
    (RESULTS / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("bootstrap-guest")
    sub.add_parser("report-context")
    p = sub.add_parser("phase1")
    p.add_argument("--context", required=True)
    p.add_argument("--runs", type=int, default=1)
    p = sub.add_parser("daemon-plan")
    p.add_argument("--context", required=True)
    p.add_argument("--cycles", type=int, default=1)
    p.add_argument("--hold", type=int, default=30)
    p = sub.add_parser("collect")
    p.add_argument("run_dir")
    p.add_argument("--boot-log", action="store_true")
    p = sub.add_parser("phase2")
    p.add_argument("--context", default="C1")
    p.add_argument("--operator-wait", type=int, default=0)
    for name in ("phase3", "phase4", "e9"):
        p = sub.add_parser(name)
        p.add_argument("--topology", required=True, choices=[f"V{i}" for i in range(9)])
        p.add_argument("--domain", default="gui", choices=["gui", "user", "direct"])
        if name != "e9":
            p.add_argument("--seed", type=int, default=20261006)
            p.add_argument("--operator-wait", type=int, default=0)
        if name == "phase3":
            p.add_argument("--captures", type=int, default=100)
            p.add_argument("--layer-captures", type=int, default=20)
            p.add_argument("--clicks", type=int, default=1000)
            p.add_argument("--sck", action="store_true", help="O2 ScreenCaptureKit diagnostic (needs Screen Recording)")
    sub.add_parser("auth-check")
    sub.add_parser("report")
    args = ap.parse_args()
    if args.cmd not in ("report", "collect", "daemon-plan") and not PROBE.exists():
        raise SystemExit(f"missing {PROBE}; run ./build.sh")
    RESULTS.mkdir(parents=True, exist_ok=True)
    {
        "bootstrap-guest": cmd_bootstrap,
        "report-context": lambda a: print(sh(str(PROBE), "report-context", "--window-server")),
        "phase1": cmd_phase1, "daemon-plan": cmd_daemon_plan, "collect": cmd_collect, "phase2": cmd_phase2,
        "phase3": cmd_phase3, "phase4": cmd_phase4, "e9": cmd_e9, "auth-check": cmd_auth_check,
        "report": cmd_report,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
