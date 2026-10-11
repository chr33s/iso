#!/usr/bin/env python3
"""Q0 go/no-go spike driver for macOS computer use under Virtualization.framework.

    ./build.sh                      build owner, fixture app and helper into .build/q0
    ./q0.py fetch                   download the latest macOS restore image from Apple's catalog
    ./q0.py install                 install it into $Q0_STATE/vm and bootstrap the guest
    ./q0.py all                     run Q0.1-Q0.5; writes $Q0_STATE/results/report.{json,md}
    ./q0.py q0.1|q0.2|q0.3|q0.4|q0.5 [--clicks N]
    ./q0.py display-sleep           owners started with the host display asleep
    ./q0.py first-boot              fresh install, capture through the provisioning boot
    ./q0.py locked [--clicks N]     gui/$UID LaunchAgent vs user/$UID owner on a locked host

State (restore image, VM bundle, results) lives in $Q0_STATE, default ~/.iso-q0.
The production topology under test is a launchd owner holding an offscreen window.

Oracles are independent of the host API: frames are decoded and checked against a
token the fixture renders; clicks and keys are checked against what the fixture
inside the guest recorded.
"""

import argparse
import json
import os
import queue
import random
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / ".build" / "q0"
STATE = Path(os.environ.get("Q0_STATE", Path.home() / ".iso-q0"))
IPSW = STATE / "restore.ipsw"
VM = STATE / "vm"
RESULTS = STATE / "results"
HOST = OUT / "q0-owner"
CATALOG = "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml"
PRODUCTION = ("offscreen", True)  # (window mode, launchd: False | True/"user" | "gui")
# launchd domain -> LimitLoadToSessionType: a user-domain background job, or a
# gui-domain LaunchAgent in the Aqua (login) session.
DOMAINS = {"user": "Background", "gui": "Aqua"}
SOCK = Path(os.environ.get("Q0_SOCK", f"/tmp/q0spike-{os.getuid()}.sock"))  # sun_path is 104 bytes
KEY = VM / "id_ed25519"
KNOWN = VM / "known_hosts"
LABEL = "dev.iso.q0spike.owner"
USER = "iso"
PASSWORD = "iso-q0-spike"


def say(*a):
    print("q0:", *a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- owner control


class Owner:
    def __init__(self, mode, capture="layer", launchd=False):
        self.mode, self.capture = mode, capture
        self.launchd = "user" if launchd is True else launchd
        self.proc = None

    def start(self):
        stop_any_owner()
        argv = [str(HOST), "run", str(VM), "--mode", self.mode, "--capture", self.capture, "--socket", str(SOCK)]
        logf = VM / f"owner-{self.mode}{'-launchd-' + self.launchd if self.launchd else ''}.log"
        if self.launchd:
            plist = VM / f"{LABEL}.plist"
            plist.write_text(launchd_plist(argv, logf, DOMAINS[self.launchd]))
            run(["launchctl", "bootstrap", f"{self.launchd}/{os.getuid()}", str(plist)])
        else:
            self.proc = subprocess.Popen(argv, stdout=open(logf, "ab"), stderr=subprocess.STDOUT)
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                if call({"op": "state"}).get("state") == "running":
                    return self
            except OSError:
                pass
            time.sleep(0.5)
        raise SystemExit(f"owner did not reach running; see {logf}")

    def stop(self):
        try:
            call({"op": "stop"}, timeout=60)
            call({"op": "quit"})
        except OSError:
            pass
        if self.launchd:
            subprocess.run(["launchctl", "bootout", f"{self.launchd}/{os.getuid()}/{LABEL}"], capture_output=True)
        if self.proc:
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        time.sleep(2)


def launchd_plist(argv, logf, session):
    args = "".join(f"<string>{a}</string>" for a in argv)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{LABEL}</string>
<key>ProgramArguments</key><array>{args}</array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>{session}</string>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>{logf}</string>
<key>StandardErrorPath</key><string>{logf}</string>
</dict></plist>
"""


def stop_any_owner():
    for domain in DOMAINS:
        subprocess.run(["launchctl", "bootout", f"{domain}/{os.getuid()}/{LABEL}"], capture_output=True)
    if SOCK.exists():
        try:
            call({"op": "stop"}, timeout=60)
            call({"op": "quit"})
            time.sleep(2)
        except OSError:
            pass


def call(req, timeout=30):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(SOCK))
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)


def wait_for(pred, timeout, what, interval=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(interval)
    raise SystemExit(f"timed out waiting for {what}")


# ---------------------------------------------------------------- guest access


def run(argv, **kw):
    return subprocess.run(argv, check=True, **kw)


def guest_ip():
    mac = (VM / "mac.txt").read_text().strip().lower()
    want = ":".join(p.lstrip("0") or "0" for p in mac.split(":"))
    try:
        text = Path("/var/db/dhcpd_leases").read_text()
    except OSError:
        return None
    ip = None
    for block in text.split("}"):
        fields = dict(
            line.strip().split("=", 1) for line in block.splitlines() if "=" in line
        )
        if fields.get("hw_address", "").split(",", 1)[-1] == want:
            ip = fields.get("ip_address")
    return ip


def ssh_base(ip, password=False):
    opts = [
        "-o", f"UserKnownHostsFile={KNOWN}",
        # Spike only: TOFU into a spike-local known_hosts. Gate J requires the pin from vsock.
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=5",
        "-o", "ControlPath=/tmp/q0ssh-%C", "-o", "ControlMaster=auto", "-o", "ControlPersist=120",
    ]
    if password:
        opts += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no",
                 "-o", "ControlMaster=no"]
    else:
        opts += ["-i", str(KEY), "-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey"]
    return opts


def ssh(cmd, check=True, password=False, timeout=60, input=None):
    ip = guest_ip()
    if not ip:
        raise SystemExit("guest has no DHCP lease yet")
    env = dict(os.environ)
    if password:
        askpass = VM / "askpass.sh"
        askpass.write_text(f"#!/bin/sh\necho {PASSWORD}\n")
        askpass.chmod(0o700)
        env.update(SSH_ASKPASS=str(askpass), SSH_ASKPASS_REQUIRE="force", DISPLAY="none")
    r = subprocess.run(["ssh", *ssh_base(ip, password), f"{USER}@{ip}", cmd], capture_output=True, text=True,
                       env=env, timeout=timeout, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"ssh {cmd!r} failed: {r.stderr.strip()}")
    return r.stdout


def scp(src, dst):
    ip = guest_ip()
    run(["scp", "-q", "-r", *ssh_base(ip), str(src), f"{USER}@{ip}:{dst}"])


def bootstrap_guest():
    """Enroll our key with the provisioned password, then install fixture + vsock helper."""
    if not KEY.exists():
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(KEY)])
    wait_for(guest_ip, 600, "guest DHCP lease", 5)
    say("guest ip", guest_ip())

    def key_ok():
        try:
            ssh("true", timeout=15)
            return True
        except (RuntimeError, subprocess.TimeoutExpired):
            return False

    if not key_ok():
        pub = (KEY.with_suffix(".pub")).read_text()

        def enroll():
            try:
                ssh("mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
                    password=True, input=pub, timeout=20)
                return True
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                say("waiting for ssh:", str(e)[:120])
                return False

        wait_for(enroll, 900, "provisioned ssh login", 10)
    ssh("mkdir -p ~/q0 ~/Library/LaunchAgents")
    ssh("rm -rf ~/q0/Q0Fixture.app")
    scp(OUT / "Q0Fixture.app", "q0/")
    scp(OUT / "q0helper", "q0/")
    plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>dev.iso.q0helper</string>
<key>ProgramArguments</key><array><string>/Users/iso/q0/q0helper</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
"""
    ssh("cat > ~/Library/LaunchAgents/dev.iso.q0helper.plist", input=plist)
    ssh("launchctl bootout gui/$(id -u)/dev.iso.q0helper 2>/dev/null; "
        "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.iso.q0helper.plist", check=False)
    wait_for(lambda: call({"op": "state"}).get("boot_id"), 60, "vsock helper hello")


def wait_guest_ready():
    wait_for(lambda: call({"op": "state"}).get("boot_id"), 600, "vsock helper hello after boot", 2)
    wait_for(lambda: guest_ip() and _ssh_ok(), 300, "ssh after boot", 3)


def _ssh_ok():
    try:
        ssh("true", timeout=10)
        return True
    except (RuntimeError, subprocess.TimeoutExpired):
        return False


class Fixture:
    """Launch the fixture in the guest GUI session and stream its event log."""

    def __init__(self, mode, *args):
        self.mode, self.args = mode, args
        self.q = queue.Queue()

    def __enter__(self):
        ssh("pkill -x Q0Fixture; rm -f ~/q0/state.json ~/q0/events.jsonl; true", check=False)
        time.sleep(0.5)
        ssh(f"open -n ~/q0/Q0Fixture.app --args {self.mode} {' '.join(self.args)}")
        wait_for(lambda: ssh("test -s ~/q0/state.json && echo y", check=False).strip() == "y", 30, "fixture state")
        self.state = json.loads(ssh("cat ~/q0/state.json"))
        ip = guest_ip()
        self.tail = subprocess.Popen(["ssh", *ssh_base(ip), f"{USER}@{ip}", "tail -n +1 -F ~/q0/events.jsonl"],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self._pump, daemon=True).start()
        self.expect(lambda e: e["ev"] == "ready", 10)
        time.sleep(0.8)  # let the window composite
        return self

    def _pump(self):
        for line in self.tail.stdout:
            try:
                self.q.put(json.loads(line))
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

    def __exit__(self, *a):
        self.tail.terminate()
        ssh("pkill -x Q0Fixture; true", check=False)


# ---------------------------------------------------------------- PNG oracle


def read_png(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos, idat = 8, b""
    while pos < len(data):
        (n,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    assert interlace == 0 and ctype in (2, 6) and depth in (8, 16), f"unsupported png {ctype}/{depth}"
    ch = 3 if ctype == 2 else 4
    bpp = ch * depth // 8
    stride = w * bpp
    raw = zlib.decompress(idat)
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line

    def px(x, y):
        r = rows[y]
        o = x * bpp
        if depth == 8:
            return tuple(r[o:o + 3])
        return tuple(r[o + 2 * k] for k in range(3))  # high byte of each 16-bit sample

    return w, h, px


def sample(px, x, y):
    vals = [px(x + dx, y + dy) for dx in (-3, 0, 3) for dy in (-3, 0, 3)]
    return tuple(sorted(v[k] for v in vals)[4] for k in range(3))


def dist(a, b):
    return sum((p - q) ** 2 for p, q in zip(a, b)) ** 0.5


def decode_barcode(png, frame, state):
    """Classify each data cell by its nearest calibration cell. Returns (token, detail)."""
    w, h, px = read_png(png)
    sx, sy = w / frame["width"], h / frame["height"]
    win, cp = state["window"], state["cell_px"]

    def at(cx, cy):
        return sample(px, int((win["x"] + cx * cp) * sx), int((win["y"] + cy * cp) * sy))

    calib = [at(i + 0.5, 0.5) for i in range(4)]
    spread = min(dist(a, b) for i, a in enumerate(calib) for b in calib[i + 1:])
    v = 0
    margins = []
    for i in range(16):
        c = at(i % 4 + 0.5, i // 4 + 1.5)
        d = sorted((dist(c, k), j) for j, k in enumerate(calib))
        margins.append(d[1][0] - d[0][0])
        v = (v << 2) | d[0][1]
    return f"{v:08x}", {"calibration": calib, "calibration_spread": round(spread, 1),
                        "min_margin": round(min(margins), 1), "image": [w, h]}


# ---------------------------------------------------------------- Q0 cells


def frame(path, capture=None):
    req = {"op": "frame", "path": str(path)}
    if capture:
        req["capture"] = capture
    return call(req)


def check_render(tag, capture=None):
    """Q0.1 core: two different tokens, both must decode exactly from host frames."""
    results = []
    for n in range(2):
        token = secrets.token_hex(4)
        with Fixture("render", token) as fx:
            png = RESULTS / f"{tag}-{n}-{token}.png"
            f = frame(png, capture)
            if not f.get("ok"):
                results.append({"token": token, "ok": False, "error": f.get("error")})
                continue
            got, detail = decode_barcode(png, f, fx.state)
            ok = got == token and detail["calibration_spread"] > 60 and detail["min_margin"] > 20
            results.append({"token": token, "decoded": got, "ok": ok, "frame": f, **detail})
            say(f"{tag}: token {token} decoded {got} ok={ok} spread={detail['calibration_spread']}")
    return {"pass": all(r["ok"] for r in results), "runs": results}


def q01(_args):
    owner = Owner("visible").start()
    try:
        wait_guest_ready()
        by_capture = {c: check_render(f"q01-visible-{c}", c) for c in ("layer", "cache", "sck")}
    finally:
        owner.stop()
    return {"pass": any(r["pass"] for r in by_capture.values()), "by_capture": by_capture}


def q02(_args):
    out = {}
    for mode, launchd in (("hidden", False), ("offscreen", False), ("nowindow", True), PRODUCTION):
        name = mode + ("-launchd" if launchd else "")
        owner = Owner(mode, launchd=launchd).start()
        try:
            wait_guest_ready()
            caps = ("layer", "cache") if mode == "nowindow" else ("layer", "cache", "sck")
            out[name] = {c: check_render(f"q02-{name}-{c}", c) for c in caps}
        finally:
            owner.stop()
    prod = out["offscreen-launchd"]
    return {"pass": any(r["pass"] for r in prod.values()), "production_topology": "offscreen-launchd", "by_mode": out}


def grid_target(state, rng, margin=4):
    win, n = state["window"], state["grid"]
    cw, ch = win["w"] / n, win["h"] / n
    r, c = rng.randrange(n), rng.randrange(n)
    x = win["x"] + c * cw + rng.uniform(margin, cw - margin)
    y = win["y"] + r * ch + rng.uniform(margin, ch - margin)
    return r * n + c, x, y


def q03(args, mode=PRODUCTION[0], launchd=PRODUCTION[1]):
    owner = Owner(mode, launchd=launchd).start()
    rng = random.Random(args.seed)
    wrong, missing, offpos, refused = [], [], [], []
    try:
        wait_guest_ready()
        before = call({"op": "hostinput"})
        with Fixture("grid") as fx:
            sess = call({"op": "session"})["session"]
            for i in range(args.clicks):
                cell, x, y = grid_target(fx.state, rng)
                r = call({"op": "click", "session": sess, "x": x, "y": y})
                if not r.get("ok"):
                    refused.append({"i": i, "error": r.get("error")})
                    continue
                down = fx.expect(lambda e: e["ev"] == "down", 3)
                up = fx.expect(lambda e: e["ev"] == "up", 3)
                if not down or not up:
                    missing.append({"i": i, "cell": cell, "x": x, "y": y, "down": down, "up": up})
                    continue
                if down["cell"] != cell or up["cell"] != cell:
                    wrong.append({"i": i, "want": cell, "got": down["cell"], "x": x, "y": y})
                if abs(down["px"] - x) > 1.5 or abs(down["py"] - y) > 1.5:
                    offpos.append({"i": i, "want": [round(x, 1), round(y, 1)], "got": [down["px"], down["py"]]})
                if i % 100 == 99:
                    say(f"q0.3: {i + 1} clicks, wrong={len(wrong)} missing={len(missing)} offpos={len(offpos)}")
            extra = fx.drain()
        after = call({"op": "hostinput"})
    finally:
        owner.stop()
    host_moved = (before["x"], before["y"], before["flags"]) != (after["x"], after["y"], after["flags"])
    return {
        "pass": not wrong and not missing and not refused and not offpos and not host_moved
        and not [e for e in extra if e["ev"] in ("down", "up")],
        "clicks": args.clicks, "seed": args.seed, "topology": f"{mode}{'-launchd' if launchd else ''}",
        "wrong_target": wrong[:20], "missing": missing[:20], "off_position_gt_1_5px": offpos[:20], "refused": refused[:20],
        "counts": {"wrong": len(wrong), "missing": len(missing), "offpos": len(offpos), "refused": len(refused)},
        "spurious_events": [e for e in extra if e["ev"] in ("down", "up")][:20],
        "host_input_before": before, "host_input_after": after, "host_input_changed": host_moved,
    }


# macOS virtual key codes (US ANSI)
KC = {**{c: k for c, k in zip("asdfhgzxcv", (0, 1, 2, 3, 4, 5, 6, 7, 8, 9))},
      "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
      "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
      "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
      " ": 49, "`": 50}
SPECIAL = {"return": 36, "tab": 48, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
           "fwddelete": 117}
MOD = {"shift": (56, 1 << 17), "control": (59, 1 << 18), "option": (58, 1 << 19), "command": (55, 1 << 20)}
SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': '-', '+': '=', '{': '[', '}': ']', '|': '\\', ':': ';', '"': "'", '<': ',', '>': '.', '?': '/', '~': '`'}


def key_script():
    """Deterministic sequence: (host events, expected fixture (ev, keyCode, flags) stream)."""
    events, expect = [], []

    def tap(code, chars, flags):
        events.append({"type": "down", "keyCode": code, "chars": chars, "flags": flags})
        events.append({"type": "up", "keyCode": code, "chars": chars, "flags": flags})
        expect.append(("down", code, flags))
        expect.append(("up", code, flags))

    def mods(names, press):
        flags = 0
        for n in names:
            code, bit = MOD[n]
            flags |= bit
        cur = 0
        seq = names if press else list(reversed(names))
        if not press:
            cur = flags
        for n in seq:
            code, bit = MOD[n]
            cur = cur | bit if press else cur & ~bit
            events.append({"type": "flags", "keyCode": code, "flags": cur})
            expect.append(("flags", code, cur))
        return flags

    for ch in "Hello, World! 0123456789 the quick brown fox; [x]=\\/'`":
        if ch.isupper() or ch in SHIFTED:
            base = ch.lower() if ch.isalpha() else SHIFTED[ch]
            f = mods(["shift"], True)
            tap(KC[base], ch, f)
            mods(["shift"], False)
        else:
            tap(KC[ch], ch, 0)
    for name in ("return", "tab", "escape", "left", "right", "up", "down", "delete", "fwddelete"):
        tap(SPECIAL[name], "", 0)
    for combo, key in ((["command"], "j"), (["control"], "a"), (["option"], "x"), (["shift", "command"], "k"),
                       (["control", "option"], "b"), (["control", "option", "command"], "m"), (["shift"], "left")):
        f = mods(combo, True)
        code = SPECIAL[key] if key in SPECIAL else KC[key]
        tap(code, key if key not in SPECIAL else "", f)
        mods(combo, False)
    # interrupted modifier sequence: press shift+option, tap, release in non-LIFO order
    f = mods(["shift", "option"], True)
    tap(KC["z"], "Z", f)
    events.append({"type": "flags", "keyCode": 56, "flags": MOD["option"][1]})
    expect.append(("flags", 56, MOD["option"][1]))
    events.append({"type": "flags", "keyCode": 58, "flags": 0})
    expect.append(("flags", 58, 0))
    tap(KC["q"], "q", 0)  # sentinel: global flags must be clear here
    # VZVirtualMachineView ignores modifiers unless the event carries the
    # device-dependent (left/right) bits that real hardware events have.
    for e in events:
        e["flags"] = with_device_bits(e["flags"])
    return events, expect


DEVICE_BITS = {1 << 17: 0x2, 1 << 18: 0x1, 1 << 19: 0x20, 1 << 20: 0x8}  # left shift/control/option/command


def with_device_bits(flags):
    dev = 0
    for bit, d in DEVICE_BITS.items():
        if flags & bit:
            dev |= d
    return flags | dev | (0x100 if dev else 0)


def q04(_args, mode=PRODUCTION[0], launchd=PRODUCTION[1]):
    owner = Owner(mode, launchd=launchd).start()
    try:
        wait_guest_ready()
        before = call({"op": "hostinput"})
        events, expect = key_script()
        with Fixture("keys") as fx:
            sess = call({"op": "session"})["session"]
            r = call({"op": "key", "session": sess, "events": events}, timeout=120)
            got = fx.drain(settle=2.0)
        after = call({"op": "hostinput"})
    finally:
        owner.stop()
    observed = [(e["ev"], e["keyCode"], e["flags"] & 0x1F0000) for e in got if e["ev"] in ("down", "up", "flags")]
    want = [(k, c, f & 0x1F0000) for k, c, f in expect]
    first_diff = next((i for i, (a, b) in enumerate(zip(observed, want)) if a != b), None)
    if first_diff is None and len(observed) != len(want):
        first_diff = min(len(observed), len(want))
    last = got[-1] if got else {}
    stuck = last.get("global_flags", -1) & 0x1F0000
    host_changed = (before["x"], before["y"], before["flags"]) != (after["x"], after["y"], after["flags"])
    ctx = slice(max(0, (first_diff or 0) - 3), (first_diff or 0) + 6)
    return {
        "pass": r.get("ok") and first_diff is None and stuck == 0 and not host_changed,
        "topology": f"{mode}{'-launchd' if launchd else ''}",
        "sent": len(events), "expected": len(want), "observed": len(observed),
        "first_diff_index": first_diff,
        "diff_context": None if first_diff is None else {"want": want[ctx], "got": observed[ctx]},
        "chars_observed": "".join(e.get("chars", "") for e in got if e["ev"] == "down"),
        "final_global_flags": stuck, "host_input_changed": host_changed,
    }


def q05(_args, mode=PRODUCTION[0], launchd=PRODUCTION[1]):
    owner = Owner(mode, launchd=launchd).start()
    out = {}
    try:
        wait_guest_ready()
        st0 = call({"op": "state"})
        s1 = call({"op": "session"})
        out["session1"] = s1
        with Fixture("grid") as fx:
            cell, x, y = grid_target(fx.state, random.Random(5))
            r = call({"op": "click", "session": s1["session"], "x": x, "y": y})
            hit = fx.expect(lambda e: e["ev"] == "down", 3)
            out["s1_before_reboot"] = {"resp": r, "hit_ok": bool(hit and hit["cell"] == cell)}
        try:
            ssh(f"echo {PASSWORD} | sudo -S shutdown -r now", check=False, timeout=20)
        except subprocess.TimeoutExpired:
            pass
        # immediately after the reboot request, and through the reboot
        refusals = []
        t0 = time.time()
        while time.time() - t0 < 600:
            r = call({"op": "click", "session": s1["session"], "x": 10, "y": 10})
            refusals.append({"t": round(time.time() - t0, 1), "ok": r.get("ok"), "error": r.get("error")})
            st = call({"op": "state"})
            if st.get("boot_id") and st["boot_id"] != st0["boot_id"]:
                break
            if st.get("state") != "running":
                out["host_state_during_reboot"] = st
                break
            time.sleep(1)
        st1 = call({"op": "state"})
        out["state_before"], out["state_after"] = st0, st1
        accepted_after_request = [x for x in refusals if x["ok"]]
        out["s1_attempts"] = {"count": len(refusals), "accepted": accepted_after_request[:10],
                              "errors": sorted({x["error"] for x in refusals if x["error"]})}
        late = call({"op": "click", "session": s1["session"], "x": 10, "y": 10})
        out["s1_after_reboot"] = late
        wait_guest_ready()
        s2 = call({"op": "session"})
        out["session2"] = s2
        with Fixture("grid") as fx:
            cell, x, y = grid_target(fx.state, random.Random(6))
            r = call({"op": "click", "session": s2["session"], "x": x, "y": y})
            hit = fx.expect(lambda e: e["ev"] == "down", 3)
            out["s2_after_reboot"] = {"resp": r, "hit_ok": bool(hit and hit["cell"] == cell)}
            # stale-frame check: a frame from boot 1 carries the old boot id
            f = frame(RESULTS / "q05-after.png")
            out["frame_after_boot_id"] = f.get("boot_id")
    finally:
        owner.stop()
    # Owner restart (replacement owner, same VM bundle): s2 must not survive.
    owner = Owner(mode, launchd=launchd).start()
    try:
        wait_guest_ready()
        out["s2_after_owner_restart"] = call({"op": "click", "session": s2["session"], "x": 10, "y": 10})
    finally:
        owner.stop()
    # The reboot request races the click loop: actions accepted *before* the guest
    # actually went down are legitimate (same boot). What must never happen is an
    # accepted action once a different boot identity is visible.
    out["pass"] = bool(
        out["s1_before_reboot"]["hit_ok"]
        and st1["boot_id"] and st1["boot_id"] != st0["boot_id"]
        and not late.get("ok")
        and out["s2_after_reboot"]["hit_ok"]
        and s2["boot_id"] == st1["boot_id"]
        and not out["s2_after_owner_restart"].get("ok")
    )
    return out


# ---------------------------------------------------------------- matrix + main


def matrix():
    def sh(*a):
        try:
            return subprocess.run(a, capture_output=True, text=True, timeout=20).stdout.strip()
        except Exception as e:  # noqa: BLE001
            return f"error: {e}"

    m = {
        "host_model": sh("sysctl", "-n", "hw.model"),
        "host_soc": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "host_os": sh("sw_vers", "--productVersion") + " " + sh("sw_vers", "--buildVersion"),
        "xcode": sh("xcodebuild", "-version").replace("\n", " "),
        "iso_commit": sh("git", "-C", str(HERE), "rev-parse", "HEAD"),
        "display": "1920x1200 @ 80ppi (VZMacGraphicsDisplayConfiguration)",
        "pointing": "VZUSBScreenCoordinatePointingDevice (absolute)",
        "keyboard": "VZMacKeyboard",
        "computer_use_mode": "host-synthesized NSEvents into VZVirtualMachineView",
    }
    try:
        m["guest_os"] = ssh("sw_vers --productVersion; sw_vers --buildVersion", timeout=10).replace("\n", " ").strip()
    except Exception as e:  # noqa: BLE001
        m["guest_os"] = f"unavailable: {e}"
    return m


def cmd_fetch(_args):
    """Newest restore image from Apple's public catalog (no Virtualization XPC needed)."""
    import re
    import urllib.request
    xml = urllib.request.urlopen(CATALOG, timeout=60).read().decode()
    urls = sorted(set(re.findall(r"https://[^<]+UniversalMac_[^<]+_Restore\.ipsw", xml)))
    if not urls:
        raise SystemExit("no restore images in catalog")
    STATE.mkdir(parents=True, exist_ok=True)
    say("downloading", urls[-1])
    run(["curl", "-fL", "-C", "-", "-o", str(IPSW), urls[-1]])


def cmd_install(_args):
    if not IPSW.exists():
        raise SystemExit(f"missing {IPSW}; run ./q0.py fetch")
    if VM.exists():
        raise SystemExit(f"{VM} exists; move it aside first")
    run([str(HOST), "install", str(VM), str(IPSW)])
    owner = Owner("visible").start()
    try:
        bootstrap_guest()
    finally:
        owner.stop()
    say("installed, provisioned and bootstrapped")


def frame_stats(png):
    w, h, px = read_png(png)
    pts = [px(int(w * (i + 0.5) / 16), int(h * (j + 0.5) / 10)) for i in range(16) for j in range(10)]
    return {"mean": round(sum(sum(p) for p in pts) / (3 * len(pts)), 1), "distinct": len(set(pts)), "image": [w, h]}


def display_sleep(_args):
    """Owners started while the host display is asleep: capture asleep, then wake and capture again."""

    def display_state():
        out = subprocess.run(["pmset", "-g", "log"], capture_output=True, text=True).stdout
        lines = [x for x in out.splitlines() if "Display is turned" in x]
        return lines[-1].split("Display is turned")[1].split()[0] if lines else "?"

    def capture(tag):
        return {c: [(r["token"], r.get("decoded"), r["ok"], (r.get("error") or "")[:80])
                    for r in check_render(f"disp-{tag}-{c}", c)["runs"]] for c in ("layer", "cache")}

    results = {}
    for mode, launchd in (("visible", False), ("offscreen", False), PRODUCTION):
        name = mode + ("-launchd" if launchd else "")
        stop_any_owner()
        run(["pmset", "displaysleepnow"])
        time.sleep(8)
        row = {"display_at_start": display_state()}
        owner = Owner(mode, launchd=launchd).start()
        try:
            wait_guest_ready()
            row["display_at_capture"] = display_state()
            row["asleep"] = capture(name + "-asleep")
            run(["caffeinate", "-u", "-t", "3"])
            time.sleep(4)
            row["display_after_wake"] = display_state()
            row["awake"] = capture(name + "-awake")
        finally:
            owner.stop()
        results[name] = row
        print(name, json.dumps(row), flush=True)
    (RESULTS / "display_sleep.json").write_text(json.dumps(results, indent=2))


def console_locked():
    out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, text=True).stdout
    i = out.find("IOConsoleLocked")
    return None if i < 0 else "<true/>" in out[i:i + 60]


def locked(args):
    """LaunchAgent (gui/$UID, Aqua) vs user/$UID Background owner, both with an
    offscreen window, started and exercised while the host console is locked."""
    rng = random.Random(args.seed)
    results = {}
    for domain in ("gui", "user"):
        stop_any_owner()
        run(["pmset", "displaysleepnow"])
        time.sleep(8)
        row = {"locked_before_start": console_locked()}
        if not row["locked_before_start"]:
            raise SystemExit("host did not lock on display sleep; set 'require password immediately'")
        owner = Owner("offscreen", launchd=domain).start()
        try:
            job = subprocess.run(["launchctl", "print", f"{domain}/{os.getuid()}/{LABEL}"],
                                 capture_output=True, text=True).stdout
            row["job"] = [x.strip() for x in job.splitlines() if x.strip().startswith(("state =", "pid =", "session ="))][:3]
            wait_guest_ready()
            row["locked_at_exercise"] = console_locked()
            before = call({"op": "hostinput"})
            row["frames"] = {c: [(r["token"], r.get("decoded"), r["ok"], (r.get("error") or "")[:80])
                                 for r in check_render(f"locked-{domain}-{c}", c)["runs"]] for c in ("layer", "cache")}
            miss = wrong = 0
            with Fixture("grid") as fx:
                sess = call({"op": "session"})["session"]
                for _ in range(args.clicks):
                    cell, x, y = grid_target(fx.state, rng)
                    r = call({"op": "click", "session": sess, "x": x, "y": y})
                    d = fx.expect(lambda e: e["ev"] == "down", 3)
                    fx.expect(lambda e: e["ev"] == "up", 3)
                    if not r.get("ok") or not d:
                        miss += 1
                    elif d["cell"] != cell:
                        wrong += 1
            row["clicks"] = {"sent": args.clicks, "missing": miss, "wrong": wrong}
            events, expect = key_script()
            with Fixture("keys") as fx:
                sess = call({"op": "session"})["session"]
                call({"op": "key", "session": sess, "events": events}, timeout=120)
                got = fx.drain(settle=2.0)
            obs = [(e["ev"], e["keyCode"], e["flags"] & 0x1F0000) for e in got if e["ev"] in ("down", "up", "flags")]
            row["keys"] = {"exact": obs == [(k, c, f & 0x1F0000) for k, c, f in expect], "observed": len(obs),
                           "expected": len(expect), "final_global_flags": got[-1].get("global_flags") if got else None}
            after = call({"op": "hostinput"})
            row["host_input_unchanged"] = (before["x"], before["y"], before["flags"]) == (after["x"], after["y"], after["flags"])
            row["locked_after_exercise"] = console_locked()
        finally:
            owner.stop()
        frames_ok = all(ok for runs in row["frames"].values() for _, _, ok, _ in runs)
        row["pass"] = bool(frames_ok and not row["clicks"]["missing"] and not row["clicks"]["wrong"]
                           and row["keys"]["exact"] and row["keys"]["final_global_flags"] == 0
                           and row["host_input_unchanged"] and row["locked_at_exercise"] and row["locked_after_exercise"])
        results[domain] = row
        print(domain, json.dumps(row), flush=True)
    (RESULTS / "locked.json").write_text(json.dumps(results, indent=2))


def first_boot(_args):
    """Fresh install, then capture every 10 s through the provisioning first boot."""
    stop_any_owner()
    cmd_install_only = [str(HOST), "install", str(VM), str(IPSW)]
    if VM.exists():
        raise SystemExit(f"{VM} exists; move it aside first")
    run(cmd_install_only)
    t0 = time.time()
    snaps, done = [], {}

    def snap(tag):
        row = {"t": round(time.time() - t0, 1), "tag": tag, "boot_id": call({"op": "state"}).get("boot_id")}
        for c in ("layer", "cache"):
            path = RESULTS / f"fb-{int(row['t']):05d}-{c}.png"
            f = frame(path, c)
            row[c] = frame_stats(path) if f.get("ok") else {"error": f.get("error", "")[:100]}
        snaps.append(row)
        print(json.dumps(row), flush=True)

    def boot():
        try:
            bootstrap_guest()
            done["ok"] = True
        except BaseException as e:  # noqa: BLE001
            done["error"] = repr(e)

    owner = Owner("visible").start()
    th = threading.Thread(target=boot, daemon=True)
    th.start()
    try:
        while th.is_alive() and time.time() - t0 < 1800:
            snap("first-boot")
            time.sleep(10)
        for _ in range(6):
            snap("post-bootstrap")
            time.sleep(10)
        render = {c: check_render(f"fb-render-{c}", c)["pass"] for c in ("layer", "cache")}
        print("render", render, flush=True)
    finally:
        (RESULTS / "first_boot.json").write_text(json.dumps({"snaps": snaps, "bootstrap": done}, indent=2))
        owner.stop()


CELLS = {"q0.1": q01, "q0.2": q02, "q0.3": q03, "q0.4": q04, "q0.5": q05}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["fetch", "install", "bootstrap", "all", "display-sleep", "first-boot", "locked", *CELLS])
    ap.add_argument("--clicks", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=20261005)
    args = ap.parse_args()
    if args.cmd == "fetch":
        return cmd_fetch(args)
    if not HOST.exists():
        raise SystemExit(f"missing {HOST}; run ./build.sh")
    RESULTS.mkdir(parents=True, exist_ok=True)
    if args.cmd == "install":
        return cmd_install(args)
    if args.cmd == "display-sleep":
        return display_sleep(args)
    if args.cmd == "first-boot":
        return first_boot(args)
    if args.cmd == "locked":
        return locked(args)
    if args.cmd == "bootstrap":
        owner = Owner("visible").start()
        try:
            bootstrap_guest()
        finally:
            owner.stop()
        return
    report_path = RESULTS / "report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {"cells": {}}
    owner = Owner("visible").start()
    try:
        wait_guest_ready()
        report["matrix"] = matrix()
    finally:
        owner.stop()
    for name in CELLS if args.cmd == "all" else [args.cmd]:
        say(f"=== {name}")
        t0 = time.time()
        try:
            res = CELLS[name](args)
        except SystemExit as e:
            res = {"pass": False, "error": str(e)}
        except Exception as e:  # noqa: BLE001
            res = {"pass": False, "error": f"{type(e).__name__}: {e}"}
        res["seconds"] = round(time.time() - t0, 1)
        report["cells"][name] = res
        report_path.write_text(json.dumps(report, indent=2, default=str))
        say(f"{name}: {'PASS' if res['pass'] else 'FAIL'}")
    lines = ["# Q0 spike results", "", "```", *[f"{k}: {v}" for k, v in report["matrix"].items()], "```", ""]
    for name, res in sorted(report["cells"].items()):
        lines.append(f"- **{name}**: {'PASS' if res['pass'] else 'FAIL'}" + (f" — {res['error']}" if res.get("error") else ""))
    (RESULTS / "report.md").write_text("\n".join(lines) + "\n")
    print((RESULTS / "report.md").read_text())


if __name__ == "__main__":
    main()
