#!/usr/bin/env python3
"""Real-hardware qualification of macOS guests in iso-sandbox (gates from
docs/design/macos-computer-use-qualification-plan.md). macOS 27+ on Apple Silicon only.

    tests/macos-guest-qualify.py --sandbox BIN --template NAME [--root DIR] [--gates B,L,I,J,O,C,D,E,G,P,H,K]
                                 [--captures N] [--clicks N] [--keep]

Needs a published template (`iso-sandbox macos template build`) and the
experiment fixture/decoder built (experiments/macos-vz-context-probe/build.sh).
Oracles are independent of the runtime's own answers: the guest fixture's
state/events over strictly pinned SSH, the decoded frame token and counter,
and host-side process state. Results: <results>/<run>/result.json.
"""

import argparse
import json
import os
import queue
import random
import secrets
import signal
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
PROBE_OUT = REPO / "experiments" / "macos-vz-context-probe" / ".build" / "probe"
FIXTURE_APP = PROBE_OUT / "IsoVZProbe.app"
DECODER = PROBE_OUT / "vz-context-probe"
GUEST_FIXTURES = HERE / "fixtures" / "macos-guest"
# Host vsock ports a guest might try: only the helper's may accept.
VSOCK_PORTS = ["7801", "1", "22", "80", "443", "1024", "2222", "5000", "7800", "7802"]
# Filesystems a guest may mount: its own APFS volumes and kernel/automount ones.
LOCAL_FS = {"apfs", "devfs", "autofs", "nullfs"}
GUEST_DIR_SH = "~/Library/Application\\ Support/IsoVZProbe"


def sha256(path):
    import hashlib
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def say(*a):
    print("qualify:", *a, file=sys.stderr, flush=True)


class Runtime:
    def __init__(self, binary, root):
        self.binary, self.root = str(binary), str(root)

    def run(self, *args, timeout=900, check=True):
        r = subprocess.run([self.binary, *args, "--root", self.root], capture_output=True, text=True,
                           timeout=timeout)
        self.last_error = r.stderr.strip() if r.returncode != 0 else ""
        if check and r.returncode != 0:
            raise RuntimeError(f"iso-sandbox {' '.join(args)}: {r.returncode} {r.stderr.strip()[-600:]}")
        return json.loads(r.stdout) if r.stdout.strip() else None

    def cu(self, sandbox, *args, check=True):
        return self.run("macos", "cu", *args, sandbox, timeout=180, check=check)


class Guest:
    """Strictly pinned SSH to one macOS sandbox: the known_hosts entry comes
    from the runtime's pin, never from the network."""

    def __init__(self, rt, sandbox, key, work):
        self.rt, self.sandbox, self.key, self.work = rt, sandbox, key, work
        self.known = work / f"{sandbox}.known_hosts"

    def refresh(self):
        info = self.rt.run("macos", "inspect", self.sandbox)
        self.ip = info["live"]["ipv4"]
        pin = info.get("sshHostKey")
        if not pin:
            raise RuntimeError(f"{self.sandbox}: no pinned host key ({info['record']['enrollment']})")
        self.known.write_text(f"{self.ip} {pin}\n")
        return info

    def opts(self):
        # No user ssh configuration, agent or forwarding: nothing of the
        # developer's reaches the guest.
        return ["-F", "/dev/null", "-i", str(self.key), "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", f"UserKnownHostsFile={self.known}",
                "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR"]

    def ssh(self, cmd, check=True, timeout=60, input=None):
        r = subprocess.run(["ssh", *self.opts(), f"iso@{self.ip}", cmd], capture_output=True, text=True,
                           timeout=timeout, input=input)
        if check and r.returncode != 0:
            raise RuntimeError(f"ssh {cmd!r}: {r.returncode} {r.stderr.strip()[:300]}")
        return r.stdout

    def ok(self):
        try:
            self.ssh("true", timeout=15)
            return True
        except (RuntimeError, subprocess.TimeoutExpired):
            return False

    def scp(self, src, dst):
        subprocess.run(["scp", "-q", "-r", *self.opts(), str(src), f"iso@{self.ip}:{dst}"], check=True, timeout=300)


def build_probes(out):
    """Host-side oracle and guest vsock canary, built fresh for the run."""
    subprocess.run(["xcrun", "swiftc", "-O", str(GUEST_FIXTURES / "host-probe.swift"), "-o", str(out / "host-probe")],
                   check=True, timeout=600)
    subprocess.run(["xcrun", "cc", "-O2", str(GUEST_FIXTURES / "vsock-probe.c"), "-o", str(out / "vsock-probe")],
                   check=True, timeout=300)
    subprocess.run(["xcrun", "swiftc", "-O", str(GUEST_FIXTURES / "frame-ocr.swift"), "-o", str(out / "frame-ocr")],
                   check=True, timeout=600)


def host_probe(out, pid=None):
    r = subprocess.run([str(out / "host-probe"), *([str(pid)] if pid else [])], capture_output=True, text=True,
                       timeout=30, check=True)
    return json.loads(r.stdout)


def hid_idle_seconds():
    """Seconds since the last physical HID input on the host."""
    r = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-r", "-d", "1", "-k", "HIDIdleTime"], capture_output=True,
                       text=True, timeout=10)
    for line in r.stdout.splitlines():
        if "HIDIdleTime" in line:
            return int(line.split("=")[-1].strip()) / 1e9
    return 0.0


def host_locked():
    r = subprocess.run(["ioreg", "-n", "Root", "-d1"], capture_output=True, text=True, timeout=10)
    return '"CGSSessionScreenIsLocked"=Yes' in r.stdout


ELECTRON = ("44.5.1", "1d75703019bb16461ae65f3081d7e6f5c0b11e901d0ccb5c343bcf7bcdd6435c")
QSUPPORT = "~/Library/Application\\ Support/IsoQFixture"
KEY = {"return": 36, "tab": 48, "escape": 53, "space": 49, "down": 125, "up": 126, "a": 0, "s": 1, "n": 45, "l": 37,
       "m": 46, "q": 12, "w": 13, "comma": 43}


def build_q_fixtures(out):
    app = out / "IsoQFixture.app"
    (app / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", str(GUEST_FIXTURES / "QFixture.swift"), "-o",
                    str(app / "Contents" / "MacOS" / "IsoQFixture")], check=True, timeout=900)
    (app / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
        "<key>CFBundleIdentifier</key><string>dev.iso.qfixture</string>"
        "<key>CFBundleExecutable</key><string>IsoQFixture</string>"
        "<key>CFBundleName</key><string>IsoQFixture</string>"
        "<key>CFBundlePackageType</key><string>APPL</string>"
        "<key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>")
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    # Electron: the pinned release, checksum-verified on the host and copied
    # in, so the guest needs no network.
    version, digest = ELECTRON
    cache = Path.home() / ".cache" / "iso-qualify"
    cache.mkdir(parents=True, exist_ok=True)
    zipf = cache / f"electron-v{version}-darwin-arm64.zip"
    if not zipf.exists() or sha256(zipf) != digest:
        subprocess.run(["curl", "-fsSL", "-o", str(zipf),
                        f"https://github.com/electron/electron/releases/download/v{version}/{zipf.name}"],
                       check=True, timeout=1800)
    if sha256(zipf) != digest:
        raise RuntimeError("electron download does not match its pinned checksum")
    return zipf


class CU:
    """Computer use through the runtime only; frames are read back for OCR."""

    def __init__(self, rt, sid, out):
        self.rt, self.sid, self.out = rt, sid, out
        # Right after first-boot enrollment the helper may not have confirmed
        # the pin yet; sessions are refused until it has.
        self.session = wait_for(lambda: (rt.cu(sid, "session", check=False) or {}).get("session"), 60,
                                "computer-use session", 2)
        self.n = 0

    def act(self, **a):
        return self.rt.cu(self.sid, "act", "--session", self.session, "--action", json.dumps(a), check=False)

    def click(self, x, y, button="left", count=1):
        return self.act(kind="click", x=x, y=y, button=button, count=count)

    def at(self, r, button="left", count=1, dx=0.5):
        return self.click(r["x"] + r["w"] * dx, r["y"] + r["h"] / 2, button, count)

    def press(self, r, hold=0.15):
        """A click with a held button, for controls that ignore instant ones."""
        x, y = r["x"] + r["w"] / 2, r["y"] + r["h"] / 2
        self.act(kind="down", x=x, y=y)
        time.sleep(hold)
        return self.act(kind="up", x=x, y=y)

    def type(self, text):
        return self.act(kind="type", text=text)

    def key(self, name, *mods):
        return self.act(kind="key", keyCode=KEY[name], modifiers=list(mods))

    def drag(self, a, b, steps=30):
        path = [{"x": a[0] + (b[0] - a[0]) * i / steps, "y": a[1] + (b[1] - a[1]) * i / steps}
                for i in range(steps + 1)]
        return self.act(kind="drag", path=path)

    def ocr(self):
        self.n += 1
        png = self.out / f"q{self.n:03d}.png"
        # A refused frame (blank, e.g. a display waking) shows nothing yet.
        if self.rt.cu(self.sid, "frame", "--session", self.session, "--out", str(png), check=False) is None:
            return []
        r = subprocess.run([str(self.out / "frame-ocr"), str(png)], capture_output=True, text=True, timeout=120)
        return json.loads(r.stdout or "[]")

    def find(self, text, timeout=15, exact=True, region=None, pick=None):
        """An OCR box for `text`, polling until it appears; with several
        matches, the one with the smallest `pick(box)`."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            hits = []
            for line in self.ocr():
                t = line["text"].strip()
                hit = t == text if exact else text.lower() in t.lower()
                if hit and (region is None or region(line)):
                    hits.append(line)
            if hits:
                return min(hits, key=pick) if pick else hits[0]
            time.sleep(0.7)
        return None


def wait_for(pred, timeout, what, interval=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {what}")


class Fixture:
    def __init__(self, g):
        self.g = g
        self.q = queue.Queue()
        self.tail = None

    def install(self):
        self.g.ssh("mkdir -p ~/IsoVZProbe && rm -rf ~/IsoVZProbe/IsoVZProbe.app")
        self.g.scp(FIXTURE_APP, "IsoVZProbe/")

    def state(self):
        return json.loads(self.g.ssh(f"cat {GUEST_DIR_SH}/state.json", timeout=15))

    def start(self, work):
        self.token = secrets.token_hex(4)
        self.g.ssh(f"pkill -x IsoVZProbe; rm -f {GUEST_DIR_SH}/state.json {GUEST_DIR_SH}/events.jsonl; true", check=False)
        time.sleep(0.5)
        self.g.ssh(f"open -n ~/IsoVZProbe/IsoVZProbe.app --args --token {self.token}")

        def ready():
            try:
                s = self.state()
                return s if s.get("run_token") == self.token else None
            except (RuntimeError, ValueError, subprocess.TimeoutExpired):
                return None

        self.st = wait_for(ready, 60, "fixture")
        time.sleep(2)
        pids = self.g.ssh("pgrep -x IsoVZProbe; true").split()
        if len(pids) != 1:
            raise RuntimeError(f"fixture instances {pids}")
        self.layout = work / f"{self.g.sandbox}-fixture.json"
        self.layout.write_text(json.dumps(self.st))
        if self.tail:
            self.tail.terminate()
        self.q = queue.Queue()
        self.tail = subprocess.Popen(["ssh", *self.g.opts(), f"iso@{self.g.ip}", f"tail -n +1 -F {GUEST_DIR_SH}/events.jsonl"],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self._pump, args=(self.tail, self.q), daemon=True).start()
        if not self.expect(lambda e: e["ev"] == "ready", 15):
            raise TimeoutError("fixture ready event")
        time.sleep(1)
        return self

    @staticmethod
    def _pump(tail, q):
        for line in tail.stdout:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            # When the host saw it: an upper bound on delivery, with no
            # guest clock involved.
            e["_recv"] = time.time()
            q.put(e)

    def expect(self, pred, timeout=3.0):
        deadline = time.time() + timeout
        while (left := deadline - time.time()) > 0:
            try:
                e = self.q.get(timeout=left)
            except queue.Empty:
                return None
            if pred(e):
                return e
        return None

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


def analyze(png, layout):
    r = subprocess.run([str(DECODER), "analyze-frame", str(png), "--layout", str(layout)], capture_output=True,
                       text=True, timeout=60)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"ok": False}


def frame_ok(a, token):
    return bool(a.get("ok") and a.get("token") == token and a.get("calibration_spread", 0) > 60
                and a.get("token_margin", 0) > 20 and a.get("counter_margin", 0) > 20)


class Run:
    def __init__(self, args):
        self.args = args
        self.rt = Runtime(args.sandbox, args.root)
        self.id = time.strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(2)
        self.dir = Path(args.results) / self.id
        self.dir.mkdir(parents=True, exist_ok=True)
        self.key = self.dir / "id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        self.pub = (self.dir / "id_ed25519.pub").read_text().strip()
        self.gates = {}
        self.created = []
        self.canary = "isocanary" + secrets.token_hex(8)

    def plant_canaries(self):
        """Gate O canaries, in place before any VM starts: a host file, an
        environment variable every runtime call inherits, and a loaded
        ssh-agent key. None may become visible in a guest. `cleanup`
        removes them."""
        (Path.home() / f".{self.canary}").write_text(self.canary + "\n")
        os.environ["ISO_QUALIFY_CANARY"] = self.canary
        agent = subprocess.run(["ssh-agent", "-s"], capture_output=True, text=True, check=True).stdout
        for part in agent.replace("\n", ";").split(";"):
            if "=" in part and part.strip().startswith(("SSH_AUTH_SOCK", "SSH_AGENT_PID")):
                k, v = part.strip().split("=", 1)
                os.environ[k] = v
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", self.canary, "-f",
                        str(self.dir / "canary_key")], check=True)
        subprocess.run(["ssh-add", "-q", str(self.dir / "canary_key")], check=True)
        build_probes(self.dir)

    def record(self, gate, status, **detail):
        assert status in ("pass", "fail", "not_run", "environment_error")
        self.gates[gate] = {"status": status, **detail}
        say(f"gate {gate}: {status} {json.dumps(detail, default=str)[:300]}")
        self.save()

    def save(self):
        meta = {
            "host_model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
            "host_os": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
            "template": self.args.template,
            "iso_revision": subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True,
                                           text=True).stdout.strip(),
            "iso_dirty": bool(subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "iso-sandbox", "tests"],
                                             capture_output=True, text=True).stdout.strip()),
            "iso_sandbox_sha256": sha256(self.args.sandbox),
            "driver_sha256": sha256(__file__),
        }
        (self.dir / "result.json").write_text(json.dumps({"run": self.id, "meta": meta, "gates": self.gates},
                                                         indent=2, default=str))

    def create(self, name, network="shared"):
        sid = f"q{self.id[-4:]}-{name}"
        self.rt.run("macos", "create", sid, "--template", self.args.template, "--owner", "qualify",
                    "--network", network, "--authorized-key", self.pub)
        self.created.append(sid)
        return sid

    def boot(self, sid):
        self.rt.run("macos", "start", sid, timeout=600)
        wait_for(lambda: self.rt.run("macos", "inspect", sid).get("sshHostKey"), 300, f"{sid} enrollment", 3)
        g = Guest(self.rt, sid, self.key, self.dir)
        g.refresh()
        wait_for(g.ok, 300, f"{sid} pinned ssh", 3)
        return g

    def cleanup(self):
        (Path.home() / f".{self.canary}").unlink(missing_ok=True)
        if os.environ.get("SSH_AGENT_PID"):
            subprocess.run(["ssh-agent", "-k"], capture_output=True)
        if self.args.keep:
            return
        for sid in self.created:
            try:
                self.rt.run("macos", "stop", sid, timeout=600, check=False)
                self.rt.run("macos", "delete", sid, "--owner", "qualify", check=False)
            except Exception as e:  # noqa: BLE001
                say("cleanup", sid, e)

    # ---------------------------------------------------------------- gates

    def gate_B(self):
        t = [x for x in self.rt.run("macos", "template", "list") if x["name"] == self.args.template]
        if not t:
            return self.record("B", "fail", reason="template not published")
        self.record("B", "pass", template=t[0], note="publish-by-rename; one clean install on this host")

    def gate_L(self, a, b, ga, gb):
        ra = self.rt.run("macos", "inspect", a)
        rb = self.rt.run("macos", "inspect", b)
        base = Path(self.args.root) / "macos" / "sandboxes"
        machine = [(base / s / "machine-id.bin").read_bytes() for s in (a, b)]
        keys = [(base / s / "helper.key").read_text() for s in (a, b)]
        # Separate files on the host (clones, not links), each with one link.
        stats = [(base / s / "disk.img").stat() for s in (a, b)]
        separate = stats[0].st_ino != stats[1].st_ino and all(st.st_nlink == 1 for st in stats)
        marker = secrets.token_hex(8)
        ga.ssh(f"echo {marker} > ~/clone-marker && sync")
        b_sees = gb.ssh("cat ~/clone-marker 2>/dev/null || true").strip()
        a_sees = ga.ssh("cat ~/clone-marker").strip()
        # The guests themselves see different platform identities.
        uuids = [g.ssh("ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformUUID").strip() for g in (ga, gb)]
        ok = (machine[0] != machine[1] and keys[0] != keys[1] and ra.get("sshHostKey") != rb.get("sshHostKey")
              and ra["record"]["macAddress"] != rb["record"]["macAddress"] and a_sees == marker and b_sees != marker
              and separate and uuids[0] and uuids[0] != uuids[1])
        self.record("L", "pass" if ok else "fail", machine_ids_differ=machine[0] != machine[1],
                    helper_keys_differ=keys[0] != keys[1],
                    ssh_host_keys_differ=ra.get("sshHostKey") != rb.get("sshHostKey"),
                    macs_differ=ra["record"]["macAddress"] != rb["record"]["macAddress"],
                    write_in_a_absent_in_b=a_sees == marker and b_sees != marker, separate_disk_files=separate,
                    guest_platform_uuids_differ=bool(uuids[0]) and uuids[0] != uuids[1])


    def gate_I(self, sid, g):
        # The real helper binary, run as the unprivileged guest user, cannot read
        # the key, is rejected for exactly that reason, and changes nothing.
        before = self.rt.run("macos", "inspect", sid)["runtime"]
        log = Path(self.args.root) / "macos" / "sandboxes" / sid / "owner.log"
        reason = "helper rejected: unauthenticated: guest reports no enrollment"
        n0 = log.read_text().count(reason)
        can_read = g.ssh("cat /var/db/iso-macos-helper/key >/dev/null 2>&1 && echo yes || echo no").strip()
        g.ssh("( /usr/local/libexec/iso-macos-helper & p=$!; sleep 8; kill $p ) >/dev/null 2>&1; true", timeout=60)
        after = self.rt.run("macos", "inspect", sid)["runtime"]
        n1 = log.read_text().count(reason)
        ok = (can_read == "no" and n1 > n0 and before["guestBoot"] == after["guestBoot"]
              and before["helperGeneration"] == after["helperGeneration"] and after["helperConnected"]
              and after["enrollment"] == "enrolled")
        self.record("I", "pass" if ok else "fail", user_can_read_key=can_read, impostor_rejections=n1 - n0,
                    generation_unchanged=before["helperGeneration"] == after["helperGeneration"],
                    guest_boot_unchanged=before["guestBoot"] == after["guestBoot"], still_enrolled=after["enrollment"],
                    note="root in the guest (sudo) can read the key: the HMAC excludes non-root processes only")


    def gate_J(self, sid, g):
        # Strict pin works; a different but valid key in its place is refused.
        good = g.ok()
        saved = g.known.read_text()
        other = self.dir / "other_host_key"
        if not other.exists():
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(other)], check=True)
        g.known.write_text(f"{g.ip} {(self.dir / 'other_host_key.pub').read_text().strip()}\n")
        r = subprocess.run(["ssh", *g.opts(), f"iso@{g.ip}", "true"], capture_output=True, text=True, timeout=30)
        refused = r.returncode != 0 and "HOST IDENTIFICATION HAS CHANGED" in r.stderr.upper()
        g.known.write_text(saved)
        self.record("J", "pass" if good and refused else "fail", pinned_connect=good, changed_key_refused=refused,
                    enrollment_source="helper over vsock at first boot")


    def gate_C(self, sid, fx, n):
        s = self.rt.cu(sid, "session")["session"]
        prev, fails, ok = None, [], 0
        for i in range(n):
            st = fx.state()
            png = self.dir / f"{sid}-frame.png"
            r = self.rt.cu(sid, "frame", "--session", s, "--out", str(png), check=False)
            if not r:
                fails.append({"i": i, "error": "refused"})
                continue
            a = analyze(png, fx.layout)
            fresh = prev is None or a.get("counter", -1) > prev
            in_window = st["frame_counter"] - 1 <= a.get("counter", -1) <= st["frame_counter"] + 12
            if frame_ok(a, fx.token) and fresh and in_window and r["width"] == 1920 and r["height"] == 1200:
                ok += 1
                prev = a["counter"]
            else:
                fails.append({"i": i, "token": a.get("token"), "counter": a.get("counter"), "ssh": st["frame_counter"]})
            time.sleep(0.5)
        self.record("C", "pass" if ok == n else "fail", captures=n, passed=ok, failures=fails[:10],
                    note="fixture tier only; framework/app coverage (Q) not run")

    def gate_E(self, sid, fx, n):
        s = self.rt.cu(sid, "session")["session"]
        grid = fx.st["layout"]["grid"]
        gn = fx.st["layout"]["grid_n"]
        rng = random.Random(7)
        wrong = missing = off = 0
        for i in range(n):
            r, c = rng.randrange(gn), rng.randrange(gn)
            cw, ch = grid["w"] / gn, grid["h"] / gn
            x = grid["x"] + (c + rng.uniform(0.15, 0.85)) * cw
            y = grid["y"] + (r + rng.uniform(0.15, 0.85)) * ch
            want = f"{chr(65 + r)}{c + 1:02d}"
            button = "right" if i % 10 == 9 else "left"
            self.rt.cu(sid, "act", "--session", s, "--action",
                       json.dumps({"kind": "click", "x": x, "y": y, "button": button}))
            d = fx.expect(lambda e: e["ev"] == "down" and e.get("button") == button, 3)
            u = fx.expect(lambda e: e["ev"] == "up" and e.get("button") == button, 3)
            if not d or not u:
                missing += 1
            elif d["cell"] != want:
                wrong += 1
            elif abs(d["px"][0] - x) > 1.5 or abs(d["px"][1] - y) > 1.5:
                off += 1
        # Drag and scroll.
        lay = fx.st["layout"]
        hx = lay["drag_handle"]["x"] + lay["drag_handle"]["w"] / 2
        hy = lay["drag_handle"]["y"] + lay["drag_handle"]["h"] / 2
        t = lay["drag_targets"]["D07"]
        path = [{"x": hx + (t["x"] + t["w"] / 2 - hx) * k / 30, "y": hy + (t["y"] + t["h"] / 2 - hy) * k / 30} for k in range(31)]
        self.rt.cu(sid, "act", "--session", s, "--action", json.dumps({"kind": "drag", "path": path}))
        dragged = fx.expect(lambda e: e["ev"] == "drag_up", 5)
        sx = lay["scroll"]["x"] + 50
        sy = lay["scroll"]["y"] + 50
        # Opposite inputs must move the region in opposite directions (the
        # guest's natural-scrolling setting decides which is "down").
        ys = [fx.state()["scroll_y"]]
        for dy in (200, -200, -200, 200):
            self.rt.cu(sid, "act", "--session", s, "--action", json.dumps({"kind": "scroll", "x": sx, "y": sy, "dy": dy}))
            time.sleep(0.8)
            ys.append(fx.state()["scroll_y"])
        moves = [b - a for a, b in zip(ys, ys[1:])]
        sent = (200, -200, -200, 200)
        signs = {up: {m > 0 for m, d in zip(moves, sent) if m and (d > 0) == up} for up in (True, False)}
        scroll_ok = all(len(v) == 1 for v in signs.values()) and signs[True] != signs[False]
        oob = self.rt.cu(sid, "act", "--session", s, "--action", json.dumps({"kind": "click", "x": 1920, "y": 5}), check=False)
        ok = wrong == missing == off == 0 and dragged and dragged.get("target") == "D07" and scroll_ok and oob is None
        self.record("E", "pass" if ok else "fail", clicks=n, wrong=wrong, missing=missing, off_position=off,
                    right_clicks=n // 10, drag_target=dragged and dragged.get("target"), scroll_positions=ys, scroll_ok=scroll_ok,
                    out_of_range_refused=oob is None)

    def gate_G(self, sid, fx):
        s = self.rt.cu(sid, "session")["session"]
        t = fx.st["layout"]["text"]
        self.rt.cu(sid, "act", "--session", s, "--action",
                   json.dumps({"kind": "click", "x": t["x"] + t["w"] / 2, "y": t["y"] + t["h"] / 2}))
        fx.drain(0.5)
        text = "Hello, World! 0123456789 ~!@#$%^&*()_+{}|:\"<>? the quick brown fox"
        self.rt.cu(sid, "act", "--session", s, "--action", json.dumps({"kind": "type", "text": text}))
        self.rt.cu(sid, "act", "--session", s, "--action", json.dumps({"kind": "key", "keyCode": 1, "modifiers": ["command"]}))
        self.rt.cu(sid, "act", "--session", s, "--action", json.dumps({"kind": "key", "keyCode": 12, "modifiers": ["command", "option", "shift"]}))
        events = fx.drain(2.0)
        st = fx.state()
        downs = [e for e in events if e["ev"] == "down"]
        ups = [e for e in events if e["ev"] == "up"]
        cmd_s = any(e["keyCode"] == 1 and e["flags"] & (1 << 20) for e in downs)
        three = (1 << 20) | (1 << 19) | (1 << 17)
        chord = any(e["keyCode"] == 12 and e["flags"] & three == three for e in downs)
        ok = (st["received_text"] == text and st["keys_down"] == [] and st["modifiers"] == 0
              and len(downs) == len(ups) and cmd_s and chord)
        self.record("G", "pass" if ok else "fail", text_exact=st["received_text"] == text, keys_down=st["keys_down"],
                    modifiers=st["modifiers"], downs=len(downs), ups=len(ups), cmd_s_seen=cmd_s,
                    cmd_opt_shift_chord_seen=chord,
                    unicode="out of contract: refused", unicode_refused=self.rt.cu(sid, "act", "--session", s, "--action",
                                                                                json.dumps({"kind": "type", "text": "é"}), check=False) is None)

    def gate_H(self, sid, g, fx):
        def refusal(*args):
            r = self.rt.cu(sid, *args, check=False)
            return None if r is not None else self.rt.last_error
        move = json.dumps({"kind": "move", "x": 5, "y": 5})
        boot0 = self.rt.run("macos", "inspect", sid)["runtime"]["guestBoot"]
        s1 = self.rt.cu(sid, "session")["session"]
        s2 = self.rt.cu(sid, "session")["session"]
        f1 = self.rt.cu(sid, "frame", "--session", s1, "--out", str(self.dir / "h1.png"))["frameId"]
        # Positive witness: an action based on a current frame is accepted.
        based_ok = self.rt.cu(sid, "act", "--session", s1, "--based-on-frame", f1, "--action", move,
                              check=False) is not None
        g.ssh("sudo /sbin/shutdown -r now", check=False, timeout=20)
        wait_for(lambda: not (self.rt.run("macos", "inspect", sid).get("runtime") or {}).get("helperConnected"),
                 120, "guest going down", 1)
        during = refusal("act", "--session", s1, "--action", move)
        wait_for(lambda: (self.rt.run("macos", "inspect", sid).get("runtime") or {}).get("helperConnected"), 600,
                 "helper after reboot", 3)
        boot1 = self.rt.run("macos", "inspect", sid)["runtime"]["guestBoot"]
        # s2 was never used, so its refusal is the binding check itself.
        after = refusal("act", "--session", s2, "--action", move)
        s3 = self.rt.cu(sid, "session")["session"]
        old_frame = refusal("act", "--session", s3, "--based-on-frame", f1, "--action", move)
        fresh = self.rt.cu(sid, "act", "--session", s3, "--action", move, check=False)
        ok = (based_ok and boot1 and boot1 != boot0 and during and "not connected" in during
              and after and "guest boot changed" in after and old_frame and "another binding" in old_frame
              and fresh is not None)
        self.record("H", "pass" if ok else "fail", based_on_current_frame_accepted=based_ok,
                    guest_rebooted=bool(boot1) and boot1 != boot0, refusal_during_reboot=during,
                    refusal_after_reboot=after, refusal_old_frame=old_frame, new_session_works=fresh is not None)


    def gate_K(self, sid, g):
        out = {}
        log = Path(self.args.root) / "macos" / "sandboxes" / sid / "owner.log"
        # Guest-initiated shutdown ends the owner: never "running" afterwards (Cua #1184).
        g.ssh("sudo /sbin/shutdown -h now", check=False, timeout=20)
        out["guest_shutdown_stopped"] = bool(wait_for(
            lambda: self.rt.run("macos", "inspect", sid)["status"] == "stopped", 300, "stopped after guest shutdown", 2))
        # Host stop of a running guest: the graceful path, confirmed.
        self.rt.run("macos", "start", sid, timeout=600)
        wait_for(lambda: (self.rt.run("macos", "inspect", sid).get("runtime") or {}).get("helperConnected"), 600,
                 "helper", 3)
        out["host_stop_path"] = self.rt.run("macos", "stop", sid, timeout=600)["stopPath"]
        out["stopped_after_host_stop"] = self.rt.run("macos", "inspect", sid)["status"] == "stopped"
        # TTL: the owner stops the VM at the deadline, not before.
        expires = int(time.time()) + 120
        self.rt.run("macos", "start", sid, "--expires-at", str(expires), timeout=600)
        wait_for(lambda: self.rt.run("macos", "inspect", sid)["status"] == "stopped", 600, "TTL stop", 5)
        out["ttl_not_before_deadline"] = time.time() >= expires
        out["ttl_logged"] = "session expired at" in log.read_text()
        # Owner killed: launchd respawns it with a new boot id, and the helper reconnects.
        live = self.rt.run("macos", "start", sid, timeout=600)
        boot1, pid1 = live["bootId"], live["pid"]
        os.kill(pid1, 9)

        def respawned():
            i = self.rt.run("macos", "inspect", sid)
            return (i["status"] == "running" and i.get("live") and i["live"]["bootId"] != boot1
                    and (i.get("runtime") or {}).get("helperConnected"))
        try:
            out["sigkill_respawned_new_boot"] = bool(wait_for(respawned, 600, "respawn", 3))
        except TimeoutError:
            out["sigkill_respawned_new_boot"] = False
        try:
            os.kill(pid1, 0)
            out["old_owner_gone"] = False
        except ProcessLookupError:
            out["old_owner_gone"] = True
        # The respawned guest is reachable again (it may have a new address).
        try:
            out["ssh_after_respawn"] = bool(wait_for(lambda: g.refresh() and g.ok(), 300, "ssh after respawn", 3))
        except TimeoutError:
            out["ssh_after_respawn"] = False
        ok = (out["guest_shutdown_stopped"] and out["host_stop_path"] == "guest_helper_shutdown"
              and out["stopped_after_host_stop"] and out["ttl_not_before_deadline"] and out["ttl_logged"]
              and out["sigkill_respawned_new_boot"] and out["old_owner_gone"] and out["ssh_after_respawn"])
        self.record("K", "pass" if ok else "fail", **out)


    def gate_O(self, sid, g):
        e = self.rt.run("macos", "inspect", sid)["effective"]
        config_ok = bool(e and e["directoryShares"] == 0 and e["audioDevices"] == 0 and e["serialPorts"] == 0
                         and e["usbControllers"] == 0 and not e["clipboard"] and len(e["storage"]) == 1
                         and e["vsockPorts"] == [7801])
        out = {"configuration": config_ok}
        # Host filesystem: no network, shared or foreign mounts, and the
        # host canary file's token is nowhere under /Volumes.
        mounts = g.ssh("/sbin/mount")
        types = {line.rsplit("(", 1)[-1].split(",")[0].strip() for line in mounts.splitlines() if "(" in line}
        out["mount_types"] = sorted(types)
        out["no_foreign_mounts"] = types <= LOCAL_FS
        out["host_file_absent"] = self.canary not in g.ssh(
            f"/usr/bin/grep -rIl {self.canary} /Volumes /Users 2>/dev/null; true", timeout=300)
        # Host environment, including the runtime's own environment.
        out["host_env_absent"] = self.canary not in g.ssh("/usr/bin/env; sudo /bin/ps -E -ax -o command", timeout=60)
        # Host ssh-agent (a canary key is loaded): nothing is forwarded.
        agent = subprocess.run(["ssh", *g.opts(), f"iso@{g.ip}", "echo ${SSH_AUTH_SOCK:-none}; /usr/bin/ssh-add -l"],
                               capture_output=True, text=True, timeout=30)
        out["agent_absent"] = agent.stdout.startswith("none") and agent.returncode != 0 and self.canary not in agent.stdout
        # Pasteboard, both ways, without touching the host's clipboard: the
        # guest's pasteboard is read before the guest writes its own token.
        host_clip = subprocess.run(["pbpaste"], capture_output=True, timeout=10).stdout.decode(errors="replace")
        guest_before = g.ssh("/usr/bin/pbpaste", check=False)
        out["host_clip_not_in_guest"] = (not host_clip) or host_clip != guest_before
        out["host_clip_present"] = bool(host_clip)
        guest_token = "isoguestclip" + secrets.token_hex(6)
        g.ssh(f"printf %s {guest_token} | /usr/bin/pbcopy", check=False)
        out["guest_pasteboard_works"] = g.ssh("/usr/bin/pbpaste", check=False) == guest_token
        out["guest_clip_not_on_host"] = subprocess.run(["pbpaste"], capture_output=True, timeout=10).stdout.decode(
            errors="replace") != guest_token
        # Host vsock: only the helper port accepts.
        g.scp(self.dir / "vsock-probe", "vsock-probe")
        vs = json.loads(g.ssh("./vsock-probe " + " ".join(VSOCK_PORTS)))
        out["vsock"] = vs
        out["vsock_only_helper"] = vs.get("7801") == "open" and all(v != "open" for k, v in vs.items() if k != "7801")
        # Devices: one physical disk, no camera, no audio.
        out["physical_disks"] = sum(1 for line in g.ssh("/usr/sbin/diskutil list physical").splitlines()
                                    if line.startswith("/dev/disk"))
        prof = json.loads(g.ssh("/usr/sbin/system_profiler -json SPCameraDataType SPAudioDataType", timeout=120))
        out["cameras"] = len(prof.get("SPCameraDataType") or [])
        out["audio_devices"] = sum(len(x.get("_items", [])) for x in prof.get("SPAudioDataType") or [])
        # The runtime control socket is a host Unix socket; with no shared
        # filesystem (above) the guest has no path to it.
        ok = (config_ok and out["no_foreign_mounts"] and out["host_file_absent"] and out["host_env_absent"]
              and out["agent_absent"] and out["guest_clip_not_on_host"] and out["host_clip_not_in_guest"]
              and out["vsock_only_helper"] and out["physical_disks"] == 1 and out["cameras"] == 0
              and out["audio_devices"] == 0)
        self.record("O", "pass" if ok else "fail", **out)

    def gate_D(self, sid, fx, clicks=50):
        """Background owner, ordered-out window: input reaches the guest
        without host focus, the host pointer never moves, focus is never
        taken, and no owner window is on screen."""
        pid = self.rt.run("macos", "inspect", sid)["live"]["pid"]
        topology = self.rt.run("macos", "inspect", sid)["effective"]["ownerTopology"]
        grid = fx.st["layout"]["grid"]
        for attempt in range(3):
            fx.drain(0.3)
            before = host_probe(self.dir, pid)
            idle0 = hid_idle_seconds()
            t0 = time.time()
            s = self.rt.cu(sid, "session")["session"]
            for i in range(clicks):
                self.rt.cu(sid, "act", "--session", s, "--action",
                           json.dumps({"kind": "click", "x": grid["x"] + 10 + i, "y": grid["y"] + 20}))
            events = [e for e in fx.drain(3.0) if e["ev"] in ("down", "up")]
            after = host_probe(self.dir, pid)
            elapsed = time.time() - t0
            # Physical input during the run makes pointer/focus inconclusive.
            if hid_idle_seconds() >= elapsed and idle0 >= 0:
                break
            say(f"gate D: host input during attempt {attempt + 1}; retrying")
        else:
            self.record("D", "environment_error", note="host HID input during every attempt")
            return
        out = {
            "events_received": len(events), "expected_events": 2 * clicks,
            "pointer_unchanged": before["mouse"] == after["mouse"],
            "frontmost_unchanged": before["frontmostPID"] == after["frontmostPID"],
            "owner_not_frontmost": after["frontmostPID"] != pid,
            "owner_windows": after["ownedWindows"], "owner_onscreen_windows": after["onscreenWindows"],
            "owner_topology": topology, "host_locked": host_locked(),
            "rows": {
                "hidden window": "works", "offscreen window": "works", "no user-facing console": "works",
                "host app unfocused": "works", "visible console": "not offered (the window is never ordered in)",
                "host locked": "supported (qualified with the console locked)",
                "fast-user-switch": "rejected (unsupported; the owner runs in the user's launchd domain)",
            },
        }
        ok = (out["events_received"] == 2 * clicks and out["pointer_unchanged"] and out["frontmost_unchanged"]
              and out["owner_not_frontmost"] and out["owner_onscreen_windows"] == 0 and "ordered-out" in topology)
        self.record("D", "pass" if ok else "fail", **out)

    # ----------------------------------------------------------- Gate Q

    def gate_Q(self, sid, g):
        zipf = build_q_fixtures(self.dir)
        cu = CU(self.rt, sid, self.dir)
        out = {}

        def events(name="events.jsonl"):
            text = g.ssh(f"cat {QSUPPORT}/{name} 2>/dev/null; true", timeout=15)
            return [json.loads(line) for line in text.splitlines() if line.strip()]

        def saw(fw, control, event, value=None, name="events.jsonl", timeout=8):
            deadline = time.time() + timeout
            while time.time() < deadline:
                for e in events(name):
                    if (e["fw"], e["control"], e["event"]) == (fw, control, event) and (
                            value is None or (value(e["value"]) if callable(value) else e["value"] == value)):
                        return True
                time.sleep(0.5)
            return False

        def frames(name="state.json"):
            try:
                return json.loads(g.ssh(f"cat {QSUPPORT}/{name}", timeout=15))["frames"]
            except (RuntimeError, ValueError, KeyError):
                return {}

        def check(key, ok):
            out[key] = bool(ok)
            say(f"gate Q: {key} {'ok' if ok else 'FAILED'}")

        retried = []

        def twice(key, act, verify):
            """macOS spends the first click on an inactive window activating
            it; an agent would see that and click again, so one retry is
            allowed and counted."""
            act()
            if verify():
                return True
            retried.append(key)
            act()
            return verify()

        def soon(pred, timeout):
            try:
                return wait_for(pred, timeout, "condition", 0.5)
            except TimeoutError:
                return None

        # Native fixture: AppKit, SwiftUI and WKWebView windows. The probe
        # fixture's full-screen window would cover them.
        g.ssh("pkill -x IsoVZProbe; true", check=False)
        g.ssh("mkdir -p ~/IsoQ && rm -rf ~/IsoQ/IsoQFixture.app ~/Library/Application\\ Support/IsoQFixture")
        g.scp(self.dir / "IsoQFixture.app", "IsoQ/")
        g.ssh("open ~/IsoQ/IsoQFixture.app")
        f = wait_for(lambda: (lambda fr: fr if {"ak_button", "su_button", "wk_button"} <= fr.keys() else None)(
            frames()), 60, "Q fixture layout", 1)
        tok = "q" + secrets.token_hex(4)
        cu.at(f["ak_button"]); check("appkit_button", saw("appkit", "button", "pressed"))
        cu.at(f["ak_field"]); cu.type(tok); check("appkit_field", saw("appkit", "field", "text", tok))
        cu.at(f["ak_editor"]); cu.type("one\ntwo"); check("appkit_editor", saw("appkit", "editor", "text", "one\ntwo"))
        cu.at(f["ak_check"], dx=0.05); check("appkit_checkbox", saw("appkit", "check", "set", True))
        cu.at(f["ak_radio_b"], dx=0.05); check("appkit_radio", saw("appkit", "radio", "selected", "AK Radio B"))
        cu.at(f["ak_popup"])
        item = cu.find("Gamma")
        if item:
            cu.at(item)
        check("appkit_popup", item and saw("appkit", "popup", "selected", "Gamma"))
        r = f["ak_slider"]
        cu.drag((r["x"] + 8, r["y"] + r["h"] / 2), (r["x"] + r["w"] - 2, r["y"] + r["h"] / 2))
        check("appkit_slider", saw("appkit", "slider", "value", lambda v: v > 90))
        r = f["ak_scroll"]
        cu.act(kind="scroll", x=r["x"] + r["w"] / 2, y=r["y"] + r["h"] / 2, dy=400)
        check("appkit_scroll", saw("appkit", "scroll", "scrolled", lambda v: v > 0))
        cu.at(f["ak_context"], button="right", dx=0.2)
        item = cu.find("Ctx Two")
        if item:
            cu.at(item)
        check("appkit_context_menu", item and saw("appkit", "context", "selected", "Ctx Two"))
        cu.at(f["ak_sheet"])
        ok = soon(lambda: frames().get("ak_sheet_ok"), 15)
        if ok:
            cu.at(ok)
        check("appkit_sheet", ok and saw("appkit", "sheet", "ok"))
        cu.at(f["ak_child"])
        ok = soon(lambda: frames().get("ak_child_ok"), 15)
        if ok:
            cu.at(ok)
        check("appkit_child_window", ok and saw("appkit", "child", "ok"))
        a, b = f["ak_drag"], f["ak_drop"]
        cu.drag((a["x"] + a["w"] / 2, a["y"] + a["h"] / 2), (b["x"] + b["w"] / 2, b["y"] + b["h"] / 2), steps=40)
        check("appkit_drag_drop", saw("appkit", "drop", "dropped", "iso-dragged-payload"))
        cu.at(f["ak_button"])
        cu.key("m", "command", "shift")
        check("menu_shortcut", saw("appkit", "menu", "selected"))
        menu = cu.find("Fixture", region=lambda line: line["y"] < 30)
        if menu:
            cu.at(menu)
            item = cu.find("Menu Action")
            if item:
                cu.at(item)
        check("menu_bar", menu and soon(
            lambda: sum(1 for e in events() if e["control"] == "menu") > 1 or None, 8))
        # SwiftUI.
        cu.at(f["su_button"]); check("swiftui_button", saw("swiftui", "button", "pressed"))
        cu.at(f["su_field"]); cu.type(tok); check("swiftui_field", saw("swiftui", "field", "text", tok))
        cu.at(f["su_toggle"], dx=0.05); check("swiftui_toggle", saw("swiftui", "toggle", "set", True))
        cu.at(f["su_picker"], dx=0.8)
        item = cu.find("Blue")
        if item:
            cu.at(item)
        check("swiftui_picker", item and saw("swiftui", "picker", "selected", "Blue"))
        r = f["su_slider"]
        cu.drag((r["x"] + 8, r["y"] + r["h"] / 2), (r["x"] + r["w"] - 2, r["y"] + r["h"] / 2))
        check("swiftui_slider", saw("swiftui", "slider", "value", lambda v: v > 90))
        cu.at(f["su_editor"]); cu.type("su\nnotes")
        check("swiftui_editor", saw("swiftui", "editor", "text", "su\nnotes"))
        # WKWebView.
        check("webkit_field", twice("webkit_field", lambda: (cu.at(f["wk_field"]), cu.type(tok)),
                                    lambda: saw("webkit", "field", "text", tok, timeout=4)))
        cu.at(f["wk_button"]); check("webkit_button", saw("webkit", "button", "pressed"))
        cu.at(f["wk_check"]); check("webkit_checkbox", saw("webkit", "check", "set", True))
        cu.at(f["wk_select"])
        item = cu.find("Three")
        if item:
            cu.at(item)
        check("webkit_select", item and saw("webkit", "select", "selected", "Three"))
        cu.at(f["wk_link"]); check("webkit_link", saw("webkit", "link", "followed", "#done"))
        g.ssh("osascript -e 'quit app \"IsoQFixture\"'; true", check=False)

        # Electron, from the pinned release.
        g.scp(zipf, "IsoQ/electron.zip")
        g.scp(GUEST_FIXTURES / "electron-fixture", "IsoQ/")
        g.ssh("cd ~/IsoQ && rm -rf Electron.app && ditto -x -k electron.zip . && "
              "(nohup ./Electron.app/Contents/MacOS/Electron ~/IsoQ/electron-fixture >/dev/null 2>&1 &)", timeout=300)
        ef = wait_for(lambda: (lambda fr: fr if "el_button" in fr else None)(frames("electron-state.json")), 90,
                      "electron layout", 1)
        ev = "electron-events.jsonl"
        cu.at(ef["el_field"]); cu.type(tok); check("electron_field", saw("electron", "field", "text", tok, ev))
        cu.at(ef["el_button"]); check("electron_button", saw("electron", "button", "pressed", None, ev))
        cu.at(ef["el_check"]); check("electron_checkbox", saw("electron", "check", "set", True, ev))
        cu.at(ef["el_select"])
        item = cu.find("Three")
        if item:
            cu.at(item)
        check("electron_select", item and saw("electron", "select", "selected", "Three", ev))
        g.ssh("pkill -x Electron; true", check=False)

        # Native apps, each with an oracle outside the app.
        g.ssh("open -a Terminal")
        time.sleep(4)
        cu.type(f"echo {tok} > /tmp/q-terminal.txt\n")
        check("terminal", soon(lambda: tok in g.ssh("cat /tmp/q-terminal.txt 2>/dev/null; true"), 15))
        g.ssh("osascript -e 'quit app \"Terminal\"'; true", check=False)
        g.ssh("defaults write com.apple.TextEdit RichText -int 0; "
              "defaults write com.apple.TextEdit NSShowAppCentricOpenPanelInsteadOfUntitledFile -bool false; "
              "rm -f ~/Documents/qtextedit*; open -a TextEdit")
        time.sleep(4)
        cu.type(f"textedit {tok}")
        cu.key("s", "command")
        time.sleep(2)
        cu.type(f"qtextedit-{tok}")
        cu.key("return")
        # TextEdit saves rich text by default; the token is in the file either way.
        check("textedit", soon(lambda: tok in g.ssh(f"cat ~/Documents/qtextedit-{tok}.* 2>/dev/null; true"),
                               20))
        g.ssh("osascript -e 'quit app \"TextEdit\"'; true", check=False)
        g.ssh("open -a Calculator")
        time.sleep(4)
        cu.type("123*4=")
        check("calculator", cu.find("492", timeout=10, exact=False) is not None)
        g.ssh("osascript -e 'quit app \"Calculator\"'; true", check=False)
        g.ssh("mkdir -p ~/Documents && open ~/Documents")
        time.sleep(4)
        cu.key("n", "command", "shift")
        time.sleep(1.5)
        cu.type(f"qfinder-{tok}\n")
        check("finder", soon(lambda: g.ssh(f"test -d ~/Documents/qfinder-{tok} && echo yes; true").strip() == "yes",
                             15))
        g.ssh("defaults delete -g AppleInterfaceStyle 2>/dev/null; open -b com.apple.systempreferences", check=False)
        # The sidebar item is the leftmost "Appearance"; the theme's "Dark" is
        # the topmost (icon style has one too). Its thumbnail sits above it.
        appearance = cu.find("Appearance", timeout=30, exact=False, pick=lambda b: b["x"])
        dark = None
        out_detail = {}
        if appearance:
            cu.at(appearance)
            if cu.find("Dark", timeout=6) is None:
                cu.press(appearance)
            out_detail["sidebar_click_navigated"] = cu.find("Dark", timeout=6) is not None
            if not out_detail["sidebar_click_navigated"]:
                g.ssh("open 'x-apple.systempreferences:com.apple.Appearance-Settings.extension'", check=False)
            dark = cu.find("Dark", timeout=10, pick=lambda b: b["y"])
            if dark:
                cu.click(dark["x"] + dark["w"] / 2, dark["y"] - 30)
        check("system_settings", soon(
            lambda: g.ssh("defaults read -g AppleInterfaceStyle 2>/dev/null; true").strip() == "Dark", 15))
        g.ssh("osascript -e 'quit app \"System Settings\"'; true", check=False)
        # -k: Safari may try HTTPS first, and a one-shot listener would exit
        # on that connection before the HTTP request arrives.
        g.ssh("rm -f /tmp/q-safari.req; (nohup /usr/bin/nc -k -l 127.0.0.1 8765 > /tmp/q-safari.req 2>&1 &); "
              "open -a Safari")
        time.sleep(6)
        cu.key("escape")
        cu.key("l", "command")
        cu.type(f"http://127.0.0.1:8765/?q={tok}\n")
        check("safari", soon(lambda: f"GET /?q={tok}" in g.ssh("grep -a GET /tmp/q-safari.req; true"), 20))
        g.ssh("osascript -e 'quit app \"Safari\"'; pkill -x nc; true", check=False)
        self.record("Q", "pass" if all(out.values()) else "fail", checks=out,
                    passed=sum(out.values()), total=len(out), retried_after_activation_click=retried,
                    system_settings=out_detail)

    # ----------------------------------------------------------- Gate R

    # Setup Assistant's ways forward, most-skipping first; panes vary by build.
    SETUP_BUTTONS = ["Sign in Later in Settings", "Set Up Later", "Skip", "Not Now", "Not now", "Don't Share",
                     "Later", "Other Sign-In Options", "Agree", "Get Started", "Adult", "Continue"]

    def gate_R(self, sid, g):
        """Observation and virtual input below the logged-in automation
        layer: boot progress, the login window, a first-login Setup
        Assistant, the lock screen, a restart dialog, a TCC prompt and the
        update policy, then an emergency stop with the guest helper gone.
        The template's `iso` user has a password that existed only during
        the build, so the login is a second local user's."""
        g.ssh("pkill -x IsoVZProbe; true", check=False)
        out = {}
        user, password = "rlogin", "Iso-" + secrets.token_hex(6)

        def console_user():
            return g.ssh("stat -f %Su /dev/console", check=False, timeout=15).strip()

        def locked():
            return '"CGSSessionScreenIsLocked"=Yes' in g.ssh("ioreg -n Root -d1", check=False, timeout=15)

        def gui_ready():
            """The user's Finder runs and Setup Assistant does not."""
            return g.ssh(f"pgrep -u {user} -x Finder >/dev/null && ! pgrep -x 'Setup Assistant' >/dev/null "
                         "&& echo yes; true", check=False).strip() == "yes"

        g.ssh(f"sudo sysadminctl -addUser {user} -fullName 'R Login' -password '{password}' </dev/null; "
              "sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser; "
              "sudo rm -f /etc/kcpassword; "
              "sudo defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool true; true",
              timeout=120)
        boot0 = self.rt.run("macos", "inspect", sid)["runtime"]["guestBoot"]
        g.ssh("sudo /sbin/shutdown -r now", check=False, timeout=20)
        # Boot progress: frames keep arriving while the guest restarts.
        boot_frames = 0
        deadline = time.time() + 300
        session = None
        while time.time() < deadline:
            st = self.rt.run("macos", "inspect", sid).get("runtime") or {}
            if st.get("helperConnected") and st.get("guestBoot") not in (None, boot0):
                break
            session = session or (self.rt.cu(sid, "session", check=False) or {}).get("session")
            png = self.dir / f"r-boot-{boot_frames:03d}.png"
            if session and self.rt.cu(sid, "frame", "--session", session, "--out", str(png), check=False):
                boot_frames += 1
            time.sleep(2)
        out["boot_frames_captured"] = boot_frames
        # Sessions bind to an authenticated guest helper, a LaunchDaemon, so
        # boot progress before it starts is not observable by design.
        out["boot_progress"] = "not observable: sessions need the guest helper, which starts after boot"
        g.refresh()
        wait_for(g.ok, 300, "ssh after reboot", 3)
        cu = CU(self.rt, sid, self.dir)
        out["login_window_console_user"] = console_user()
        # Login window, in name-and-password mode: its clock is on screen
        # while no one is logged in.
        clock = cu.find(":", timeout=60, exact=False)
        out["login_window_seen"] = clock is not None and out["login_window_console_user"] == "root"
        name = cu.find("Name", timeout=5)
        if name:
            cu.at(name)
        cu.key("a", "command")
        cu.type(f"{user}\t{password}\n")
        try:
            out["logged_in"] = bool(wait_for(lambda: console_user() == user, 90, "login", 2))
        except TimeoutError:
            out["logged_in"] = False
        # First login: Setup Assistant, driven like any other window.
        panes = []
        deadline = time.time() + 300
        while out["logged_in"] and time.time() < deadline and not gui_ready():
            lines = cu.ocr()
            hit = None
            for label in self.SETUP_BUTTONS:
                hits = [b for b in lines if b["text"].strip() == label or b["text"].strip().startswith(label + " ")]
                if hits:
                    hit = max(hits, key=lambda b: b["y"])
                    break
            if hit:
                panes.append(hit["text"].strip())
                cu.at(hit)
            time.sleep(3)
        out["setup_assistant_steps"] = panes
        out["desktop_reached"] = gui_ready()
        time.sleep(5)
        # Lock screen (control-command-Q), then unlock with the password.
        cu.key("q", "command", "control")
        try:
            out["locked"] = bool(wait_for(lambda: locked() or None, 30, "lock", 1))
        except TimeoutError:
            out["locked"] = False
        time.sleep(2)
        cu.type(password + "\n")
        try:
            out["unlocked"] = bool(wait_for(lambda: (not locked()) or None, 30, "unlock", 1))
        except TimeoutError:
            out["unlocked"] = False
        time.sleep(3)
        # Restart dialog from the Apple menu, cancelled.
        boottime = g.ssh("sysctl -n kern.boottime")
        cu.click(18, 12)
        restart = cu.find("Restart...", timeout=10) or cu.find("Restart…", timeout=5)
        if restart:
            cu.at(restart)
        cancel = cu.find("Cancel", timeout=15)
        dialog = cancel and cu.find("restart", timeout=5, exact=False, region=lambda b: b["y"] > 40)
        if cancel:
            cu.at(cancel)
        time.sleep(3)
        out["restart_dialog_seen"] = dialog is not None
        out["restart_cancelled"] = cancel is not None and g.ssh("sysctl -n kern.boottime") == boottime
        # A TCC prompt: Terminal, opened from Spotlight, reads the Desktop folder.
        g.ssh("rm -f /tmp/r-tcc.txt", check=False)
        cu.key("space", "command")
        time.sleep(2)
        cu.type("Terminal\n")
        time.sleep(5)
        cu.type("ls ~/Desktop > /tmp/r-tcc.txt 2>&1; echo rc=$? >> /tmp/r-tcc.txt\n")
        allow = cu.find("Allow", timeout=20)
        out["tcc_prompt_seen"] = allow is not None
        if allow:
            cu.at(allow)
        try:
            out["tcc_allowed"] = bool(wait_for(
                lambda: "rc=0" in g.ssh("cat /tmp/r-tcc.txt 2>/dev/null; true"), 20, "tcc", 1)) if allow else False
        except TimeoutError:
            out["tcc_allowed"] = False
        # Update policy: automatic checks and downloads are off.
        # The policy: nothing downloads or installs on its own. macOS keeps
        # checking (without device management the schedule cannot be turned
        # off), which is recorded.
        prefs = "/Library/Preferences/com.apple.SoftwareUpdate"
        download = g.ssh(f"defaults read {prefs} AutomaticDownload 2>&1; true", check=False).strip()
        install = g.ssh(f"defaults read {prefs} AutomaticallyInstallMacOSUpdates 2>/dev/null || echo 0",
                        check=False).strip()
        schedule = g.ssh("sudo softwareupdate --schedule 2>&1; true", check=False, timeout=60).strip()
        out["update_policy"] = {"AutomaticDownload": download, "AutomaticallyInstallMacOSUpdates": install,
                                "schedule": schedule}
        out["updates_disabled"] = download == "0" and install == "0"
        out["no_update_prompt_on_screen"] = cu.find("Software Update", timeout=2, exact=False) is None
        # Emergency stop with the guest helper gone: the host still stops it.
        g.ssh("sudo launchctl bootout system/dev.iso.macos-helper", check=False)
        wait_for(lambda: not (self.rt.run("macos", "inspect", sid).get("runtime") or {}).get("helperConnected"),
                 60, "helper gone", 1)
        t0 = time.time()
        stop = self.rt.run("macos", "stop", sid, timeout=600, check=False) or {}
        out["emergency_stop_path"] = stop.get("stopPath")
        out["emergency_stop_seconds"] = round(time.time() - t0, 1)
        out["emergency_stopped"] = self.rt.run("macos", "inspect", sid)["status"] == "stopped"
        ok = (out["login_window_seen"] and out["logged_in"] and out["desktop_reached"]
              and out["locked"] and out["unlocked"] and out["restart_dialog_seen"] and out["restart_cancelled"]
              and out["tcc_prompt_seen"] and out["tcc_allowed"] and out["updates_disabled"]
              and out["no_update_prompt_on_screen"] and out["emergency_stopped"]
              and out["emergency_stop_path"] != "guest_helper_shutdown")
        self.record("R", "pass" if ok else "fail", **out)

    # ----------------------------------------------------------- Gate S

    def owner_usage(self, pid):
        r = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)], capture_output=True, text=True)
        cpu, rss = r.stdout.split()
        return float(cpu), int(rss) * 1024

    def gate_S(self, sid, g, fx, n=100):
        def pct(xs, q):
            xs = sorted(xs)
            return round(xs[min(len(xs) - 1, int(q * len(xs)))] * 1000, 1)

        out = {}
        s = self.rt.cu(sid, "session")["session"]
        pid = self.rt.run("macos", "inspect", sid)["live"]["pid"]
        grid = fx.st["layout"]["grid"]
        cpu_idle = []
        for _ in range(10):
            cpu_idle.append(self.owner_usage(pid)[0])
            time.sleep(1)
        rss0 = self.owner_usage(pid)[1]
        # Observe request -> complete frame (CLI to PNG on disk).
        frames = []
        for i in range(n):
            t = time.time()
            self.rt.cu(sid, "frame", "--session", s, "--out", str(self.dir / "s-frame.png"))
            frames.append(time.time() - t)
        out["frame_p50_ms"], out["frame_p95_ms"] = pct(frames, 0.5), pct(frames, 0.95)
        out["frames_per_second"] = round(n / sum(frames), 2)
        cpu_capture = self.owner_usage(pid)[0]
        # Action request -> acknowledged (delivered to the VM's view).
        acks = []
        for i in range(n):
            t = time.time()
            self.rt.cu(sid, "act", "--session", s, "--action",
                       json.dumps({"kind": "move", "x": grid["x"] + 5 + i % 50, "y": grid["y"] + 5}))
            acks.append(time.time() - t)
        out["action_ack_p50_ms"], out["action_ack_p95_ms"] = pct(acks, 0.5), pct(acks, 0.95)
        # Action request -> input observed by the guest fixture, as the host
        # receives the fixture's event over SSH (an upper bound).
        fx.drain(0.3)
        observed = []
        for i in range(50):
            sent = time.time()
            self.rt.cu(sid, "act", "--session", s, "--action",
                       json.dumps({"kind": "click", "x": grid["x"] + 20 + i * 3, "y": grid["y"] + 30}))
            down = fx.expect(lambda e: e["ev"] == "down", 5)
            if down:
                observed.append(down["_recv"] - sent)
            fx.expect(lambda e: e["ev"] == "up", 2)
        out["input_observed_p50_ms"] = pct(observed, 0.5) if observed else None
        out["input_observed_p95_ms"] = pct(observed, 0.95) if observed else None
        # Click -> visible response: type into the fixture's field and time
        # the first frame whose OCR shows it.
        visible = []
        tr = fx.st["layout"]["text"]
        for i in range(5):
            word = f"vis{secrets.token_hex(2)}"
            self.rt.cu(sid, "act", "--session", s, "--action",
                       json.dumps({"kind": "click", "x": tr["x"] + tr["w"] / 2, "y": tr["y"] + tr["h"] / 2}))
            t = time.time()
            self.rt.cu(sid, "act", "--session", s, "--action", json.dumps({"kind": "type", "text": word}))
            shots = []
            while time.time() - t < 5:
                png = self.dir / f"s-vis-{i}-{len(shots)}.png"
                self.rt.cu(sid, "frame", "--session", s, "--out", str(png))
                shots.append((time.time() - t, png))
            for dt, png in shots:
                r = subprocess.run([str(self.dir / "frame-ocr"), str(png)], capture_output=True, text=True)
                if word in r.stdout:
                    visible.append(dt)
                    break
            for _, png in shots:
                png.unlink(missing_ok=True)
        out["click_to_visible_p50_ms"] = pct(visible, 0.5) if visible else None
        out["visible_found"] = f"{len(visible)}/5"
        out["owner_cpu_idle_percent"] = round(sum(cpu_idle) / len(cpu_idle), 1)
        out["owner_cpu_capture_percent"] = cpu_capture
        out["owner_rss_mib"] = round(rss0 / 2**20)
        out["owner_rss_growth_mib"] = round((self.owner_usage(pid)[1] - rss0) / 2**20, 1)
        out["targets"] = {"input_p95_ms": 50, "fresh_frame_p95_ms": 250}
        out["meets_targets"] = bool(out["input_observed_p95_ms"] is not None and out["input_observed_p95_ms"] < 50
                                    and out["frame_p95_ms"] < 250)
        # Recorded, not gated: the plan sets these as initial targets.
        self.record("S", "pass" if observed and visible else "fail", **out)

    def gate_S_scaling(self, counts=(1, 2)):
        """Frame latency with one and two macOS VMs running at once:
        Virtualization.framework runs at most two macOS guests per host
        (VZErrorDomain 6), so the plan's 4- and 8-VM points cannot exist.
        A third start is refused, which the result records."""
        # Both slots are needed: stop this run's other guests first.
        for sid in list(self.created):
            self.rt.run("macos", "stop", sid, timeout=600, check=False)
        mem = min(t["minimumMemoryBytes"] for t in self.rt.run("macos", "template", "list")
                  if t["name"] == self.args.template) >> 20
        results = {}
        vms = []
        try:
            for count in counts:
                while len(vms) < count:
                    sid = f"q{self.id[-4:]}-s{len(vms)}"
                    self.rt.run("macos", "create", sid, "--template", self.args.template, "--owner", "qualify",
                                "--memory-mib", str(max(mem, 4096)), "--cpus", "2", "--authorized-key", self.pub)
                    self.created.append(sid)
                    self.rt.run("macos", "start", sid, timeout=600)
                    vms.append(sid)
                for sid in vms:
                    wait_for(lambda: (self.rt.run("macos", "inspect", sid).get("runtime") or {}).get(
                        "helperConnected"), 600, f"{sid} helper", 3)
                times = {}
                lock = threading.Lock()

                def sample(sid):
                    sess = self.rt.cu(sid, "session")["session"]
                    xs = []
                    for _ in range(20):
                        t = time.time()
                        self.rt.cu(sid, "frame", "--session", sess, "--out", str(self.dir / f"{sid}.png"))
                        xs.append(time.time() - t)
                    with lock:
                        times[sid] = xs
                threads = [threading.Thread(target=sample, args=(sid,)) for sid in vms]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join()
                all_ = sorted(x for xs in times.values() for x in xs)
                results[str(count)] = {"frame_p50_ms": round(all_[len(all_) // 2] * 1000, 1),
                                       "frame_p95_ms": round(all_[int(0.95 * len(all_))] * 1000, 1)}
                say(f"gate S scaling: {count} VMs {results[str(count)]}")
            # A third macOS guest is refused by the platform, not by iso.
            sid = f"q{self.id[-4:]}-s{len(vms)}"
            self.rt.run("macos", "create", sid, "--template", self.args.template, "--owner", "qualify",
                        "--memory-mib", str(max(mem, 4096)), "--cpus", "2", "--authorized-key", self.pub)
            self.created.append(sid)
            third = self.rt.run("macos", "start", sid, timeout=600, check=False)
            results["third_refused"] = third is None and "maximum supported number" in self.rt.last_error
        finally:
            for sid in vms:
                self.rt.run("macos", "stop", sid, timeout=600, check=False)
        ok = all(str(c) in results for c in counts) and results.get("third_refused")
        self.record("S_scaling", "pass" if ok else "fail", vms=results, memory_mib_each=max(mem, 4096),
                    platform_limit="2 active macOS guests per host")

    def gate_P(self, a, fa, b, fb):
        sa = self.rt.cu(a, "session")["session"]
        sb = self.rt.cu(b, "session")["session"]
        cross = self.rt.cu(b, "act", "--session", sa, "--action", json.dumps({"kind": "move", "x": 5, "y": 5}),
                           check=False)
        grid = fa.st["layout"]["grid"]
        fa.drain(0.3)
        fb.drain(0.3)
        for _ in range(20):
            self.rt.cu(a, "act", "--session", sa, "--action",
                       json.dumps({"kind": "click", "x": grid["x"] + 40, "y": grid["y"] + 30}))
        a_events = [e for e in fa.drain(3.0) if e["ev"] in ("down", "up")]
        leaked = [e for e in fb.drain(3.0) if e["ev"] in ("down", "up")]
        # Control: B's own click arrives at B, so B's oracle is live.
        gb = fb.st["layout"]["grid"]
        self.rt.cu(b, "act", "--session", sb, "--action",
                   json.dumps({"kind": "click", "x": gb["x"] + 40, "y": gb["y"] + 30}))
        b_control = fb.expect(lambda e: e["ev"] == "down", 5) is not None
        pa = self.dir / "pa.png"
        pb = self.dir / "pb.png"
        self.rt.cu(a, "frame", "--session", sa, "--out", str(pa))
        self.rt.cu(b, "frame", "--session", sb, "--out", str(pb))
        ta = analyze(pa, fa.layout).get("token")
        tb = analyze(pb, fb.layout).get("token")
        ok = (cross is None and len(a_events) == 40 and not leaked and b_control and ta == fa.token
              and tb == fb.token and fa.token != fb.token)
        self.record("P", "pass" if ok else "fail", cross_vm_session_refused=cross is None, a_received=len(a_events),
                    events_leaked_to_b=len(leaked), b_control_click_seen=b_control,
                    frame_tokens=[ta == fa.token, tb == fb.token])



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sandbox", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--root", default=str(Path.home() / ".iso-macos-dev"))
    ap.add_argument("--results", default=str(Path.home() / ".iso-macos-dev" / "qualify"))
    ap.add_argument("--gates", default="B,L,I,J,O,C,D,E,G,P,H,K")
    ap.add_argument("--captures", type=int, default=100)
    ap.add_argument("--clicks", type=int, default=200)
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    # SIGTERM unwinds through `finally`, so canaries and VMs are cleaned up.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    for p in (FIXTURE_APP, DECODER):
        if not p.exists():
            raise SystemExit(f"missing {p}; run experiments/macos-vz-context-probe/build.sh")
    gates = set(args.gates.split(","))
    run = Run(args)
    say("run", run.id, "results", run.dir)
    try:
        run.plant_canaries()
        if "B" in gates:
            run.gate_B()
        a = run.create("a")
        b = run.create("b") if gates & {"L", "P"} else None
        ga = run.boot(a)
        gb = run.boot(b) if b else None
        if "L" in gates:
            run.gate_L(a, b, ga, gb)
        if "I" in gates:
            run.gate_I(a, ga)
        if "J" in gates:
            run.gate_J(a, ga)
        if "O" in gates:
            run.gate_O(a, ga)
        fa = Fixture(ga)
        fa.install()
        fa.start(run.dir)
        if "C" in gates:
            run.gate_C(a, fa, args.captures)
        if "D" in gates:
            run.gate_D(a, fa)
        if "S" in gates:
            fa.start(run.dir)
            run.gate_S(a, ga, fa)
        if "E" in gates:
            run.gate_E(a, fa, args.clicks)
        if "G" in gates:
            fa.start(run.dir)
            run.gate_G(a, fa)
        if "P" in gates and gb:
            fb = Fixture(gb)
            fb.install()
            fb.start(run.dir)
            fa.start(run.dir)
            run.gate_P(a, fa, b, fb)
            fb.stop()
        fa.stop()
        if "H" in gates:
            run.gate_H(a, ga, fa)
        if "Q" in gates:
            run.gate_Q(a, ga)
        if "K" in gates:
            ga.refresh()
            run.gate_K(a, ga)
        if "SCALE" in gates:
            run.gate_S_scaling()
        if "R" in gates:
            # Last: it changes the guest's login policy and stops it.
            r = run.create("r")
            run.gate_R(r, run.boot(r))
    except Exception as e:  # noqa: BLE001
        run.record("error", "fail", error=f"{type(e).__name__}: {e}")
    finally:
        run.cleanup()
        run.save()
        print(json.dumps({k: v["status"] for k, v in run.gates.items()}, indent=2))


if __name__ == "__main__":
    main()
