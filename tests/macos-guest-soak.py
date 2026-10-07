#!/usr/bin/env python3
"""Gate T soak for macOS guests in iso-sandbox: several VMs under sustained
computer use for hours, with stop/start cycles, owner crashes and app
launch/close cycles. macOS 27+ on Apple Silicon only.

    tests/macos-guest-soak.py --sandbox BIN --template NAME [--hours 8] [--vms 2]
                              [--root DIR] [--results DIR]

Oracles as in tests/macos-guest-qualify.py: each VM's guest fixture reports
the input it received over pinned SSH, and frames are decoded for the VM's
own token and a fresh counter. Results (updated as the soak runs):
<results>/<run>/soak.json.
"""

import argparse
import importlib.util
import json
import random
import secrets
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("qualify", HERE / "macos-guest-qualify.py")
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)

TARGETS = {"pointer_actions": 10_000, "key_events": 10_000, "frames": 1_000, "app_cycles": 100,
           "stop_start_cycles": 20, "owner_crashes": 5}
APPS = ["TextEdit", "Calculator", "Preview", "Notes"]


def inserted_once(before, after, word):
    """`after` is `before` with `word` inserted at a single position."""
    if len(after) != len(before) + len(word):
        return False
    start = 0
    while (i := after.find(word, start)) >= 0:
        if after[:i] + after[i + len(word):] == before:
            return True
        start = i + 1
    return False


class VM:
    def __init__(self, run, sid):
        self.run, self.sid = run, sid
        self.g = run.boot(sid)
        self.fx = q.Fixture(self.g)
        self.fx.install()
        self.restart_fixture()

    def restart_fixture(self):
        self.g.refresh()
        # Right after a boot the app can exit as it launches; one retry.
        try:
            self.fx.start(self.run.dir)
        except (RuntimeError, TimeoutError):
            time.sleep(5)
            self.fx.start(self.run.dir)
        self.session = self.run.rt.cu(self.sid, "session")["session"]
        self.counter = -1

    def act(self, action, session=None):
        return self.run.rt.cu(self.sid, "act", "--session", session or self.session, "--action", json.dumps(action),
                              check=False)


class Soak:
    def __init__(self, args):
        self.args = args
        self.run = q.Run(args)
        self.stats = {k: 0 for k in TARGETS}
        self.stats.update({"wrong_clicks": 0, "missing_clicks": 0, "cross_vm_events": 0, "stale_boot_accepted": 0,
                           "stale_frames": 0, "wrong_token_frames": 0, "text_mismatches": 0, "errors": 0})
        self.samples = []
        self.log = []
        self.started = time.time()

    def note(self, what):
        self.log.append({"t": round(time.time() - self.started), "what": what})
        q.say(what)

    def others_quiet(self, vms, active):
        """Events seen by any VM other than `active` are cross-VM leaks."""
        for vm in vms:
            if vm is active:
                continue
            leaked = [e for e in vm.fx.drain(0.05) if e["ev"] in ("down", "up", "key", "text")]
            self.stats["cross_vm_events"] += len(leaked)

    def pointer(self, vm):
        grid = vm.fx.st["layout"]["grid"]
        n = vm.fx.st["layout"]["grid_n"]
        r, c = random.randrange(n), random.randrange(n)
        cw, ch = grid["w"] / n, grid["h"] / n
        x = grid["x"] + (c + random.uniform(0.25, 0.75)) * cw
        y = grid["y"] + (r + random.uniform(0.25, 0.75)) * ch
        want = f"{chr(65 + r)}{c + 1:02d}"
        vm.act({"kind": "click", "x": x, "y": y})
        self.stats["pointer_actions"] += 1
        down = vm.fx.expect(lambda e: e["ev"] == "down", 5)
        if down is None:
            self.stats["missing_clicks"] += 1
        elif down.get("cell") != want:
            self.stats["wrong_clicks"] += 1
        vm.fx.expect(lambda e: e["ev"] == "up", 3)

    def keys(self, vm):
        """The fixture's field keeps its text (it has no Edit menu, so no
        select all) and the click leaves the caret where it lands: the word
        must appear once, contiguous and in order, with nothing else changed."""
        t = vm.fx.st["layout"]["text"]
        vm.act({"kind": "click", "x": t["x"] + t["w"] / 2, "y": t["y"] + t["h"] / 2})
        before = vm.fx.state().get("received_text", "")
        word = "".join(random.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(20))
        vm.act({"kind": "type", "text": word})
        self.stats["key_events"] += len(word)
        time.sleep(0.3)
        if not inserted_once(before, vm.fx.state().get("received_text", ""), word):
            self.stats["text_mismatches"] += 1
        vm.fx.drain(0.2)

    def frame(self, vm):
        png = self.run.dir / f"soak-{vm.sid}.png"
        if self.run.rt.cu(vm.sid, "frame", "--session", vm.session, "--out", str(png), check=False) is None:
            self.stats["errors"] += 1
            return
        self.stats["frames"] += 1
        a = q.analyze(png, vm.fx.layout)
        if a.get("token") != vm.fx.token:
            self.stats["wrong_token_frames"] += 1
        elif a.get("counter", -1) <= vm.counter:
            self.stats["stale_frames"] += 1
        vm.counter = a.get("counter", vm.counter)

    def app_cycle(self, vm):
        app = APPS[self.stats["app_cycles"] % len(APPS)]
        vm.g.ssh(f"open -a {app}", check=False, timeout=60)
        time.sleep(3)
        vm.g.ssh(f"osascript -e 'quit app \"{app}\"'; pkill -x {app}; true", check=False, timeout=60)
        self.stats["app_cycles"] += 1
        # The fixture must still own input afterwards.
        vm.g.ssh("open -a IsoVZProbe 2>/dev/null; true", check=False)
        vm.restart_fixture()

    def stop_start(self, vm):
        old = vm.session
        self.run.rt.run("macos", "stop", vm.sid, timeout=900)
        self.run.rt.run("macos", "start", vm.sid, timeout=900)
        q.wait_for(lambda: (self.run.rt.run("macos", "inspect", vm.sid).get("runtime") or {}).get("helperConnected"),
                   600, "helper", 3)
        if vm.act({"kind": "move", "x": 5, "y": 5}, session=old) is not None:
            self.stats["stale_boot_accepted"] += 1
        # A respawned owner may move to another subnet when the previous
        # vmnet network is not yet released; read the address again.
        q.wait_for(lambda: vm.g.refresh() and vm.g.ok(), 300, "ssh", 3)
        vm.restart_fixture()
        self.stats["stop_start_cycles"] += 1

    def crash(self, vm):
        old = vm.session
        pid = self.run.rt.run("macos", "inspect", vm.sid)["live"]["pid"]
        subprocess.run(["kill", "-9", str(pid)])

        def back():
            i = self.run.rt.run("macos", "inspect", vm.sid)
            return (i["status"] == "running" and i.get("live") and i["live"]["pid"] != pid
                    and (i.get("runtime") or {}).get("helperConnected"))
        q.wait_for(back, 600, "respawn", 3)
        if vm.act({"kind": "move", "x": 5, "y": 5}, session=old) is not None:
            self.stats["stale_boot_accepted"] += 1
        # A respawned owner may move to another subnet when the previous
        # vmnet network is not yet released; read the address again.
        q.wait_for(lambda: vm.g.refresh() and vm.g.ok(), 300, "ssh", 3)
        vm.restart_fixture()
        self.stats["owner_crashes"] += 1

    def sample(self, vms):
        owners = []
        for vm in vms:
            live = self.run.rt.run("macos", "inspect", vm.sid).get("live") or {}
            if live.get("pid"):
                cpu, rss = self.run.owner_usage(live["pid"])
                owners.append({"sid": vm.sid, "pid": live["pid"], "cpu": cpu, "rss_mib": round(rss / 2**20)})
        procs = subprocess.run(["pgrep", "-f", "iso-sandbox macos run"], capture_output=True, text=True).stdout.split()
        self.samples.append({"t": round(time.time() - self.started), "owners": owners,
                             "owner_processes": len(procs)})

    def save(self, vms, done=False):
        stats = dict(self.stats)
        hours = (time.time() - self.started) / 3600
        rss = {}
        for s in self.samples:
            for o in s["owners"]:
                rss.setdefault(o["sid"], []).append(o["rss_mib"])
        # Growth: last hour's median against the second hour's median, so
        # warm-up does not count.
        growth = {}
        for sid, xs in rss.items():
            if len(xs) >= 20:
                head = sorted(xs[len(xs) // 8: len(xs) // 4])
                tail = sorted(xs[-len(xs) // 8:])
                growth[sid] = tail[len(tail) // 2] - head[len(head) // 2]
        leaked = [s for s in self.samples if s["owner_processes"] > len(vms)]
        met = {k: stats[k] >= v for k, v in TARGETS.items()}
        ok = (all(met.values()) and hours >= self.args.hours * 0.99 and stats["wrong_clicks"] == 0
              and stats["cross_vm_events"] == 0 and stats["stale_boot_accepted"] == 0
              and stats["wrong_token_frames"] == 0 and stats["stale_frames"] == 0
              and stats["text_mismatches"] == 0 and stats["missing_clicks"] == 0 and stats["errors"] == 0
              and not leaked
              and all(g < 256 for g in growth.values()))
        result = {"run": self.run.id, "hours": round(hours, 2), "vms": [vm.sid for vm in vms], "stats": stats,
                  "targets": TARGETS, "targets_met": met, "rss_growth_mib": growth,
                  "leaked_owner_samples": len(leaked), "sleep_wake": "not run: host sleep would end the session",
                  "status": ("pass" if ok else "fail") if done else "running", "log": self.log[-200:],
                  "samples": self.samples}
        (self.run.dir / "soak.json").write_text(json.dumps(result, indent=2))
        return result

    def main(self):
        vms = []
        try:
            self.run.plant_canaries()
            for i in range(self.args.vms):
                sid = self.run.create(f"t{i}")
                vms.append(VM(self.run, sid))
                self.note(f"booted {sid}")
            deadline = self.started + self.args.hours * 3600
            # Space the disruptive operations evenly over the run.
            period = self.args.hours * 3600
            next_stop = self.started + period / (TARGETS["stop_start_cycles"] + 1)
            next_crash = self.started + period / (TARGETS["owner_crashes"] + 1)
            next_app = self.started + period / (TARGETS["app_cycles"] + 1)
            next_sample = self.started
            i = 0
            while time.time() < deadline:
                vm = vms[i % len(vms)]
                i += 1
                try:
                    now = time.time()
                    if now >= next_sample:
                        self.sample(vms)
                        self.save(vms)
                        next_sample = now + 60
                    if now >= next_stop:
                        self.stop_start(vm)
                        next_stop += period / (TARGETS["stop_start_cycles"] + 1)
                        self.note(f"stop/start {vm.sid} ({self.stats['stop_start_cycles']})")
                    elif now >= next_crash:
                        self.crash(vm)
                        next_crash += period / (TARGETS["owner_crashes"] + 1)
                        self.note(f"owner crash {vm.sid} ({self.stats['owner_crashes']})")
                    elif now >= next_app:
                        self.app_cycle(vm)
                        next_app += period / (TARGETS["app_cycles"] + 1)
                    for _ in range(3):
                        self.pointer(vm)
                    if i % 2 == 0:
                        self.keys(vm)
                    if i % 8 == 0:
                        self.frame(vm)
                    self.others_quiet(vms, vm)
                except Exception as e:  # noqa: BLE001
                    self.stats["errors"] += 1
                    self.note(f"error on {vm.sid}: {type(e).__name__}: {e}")
                    try:
                        vm.restart_fixture()
                    except Exception as again:  # noqa: BLE001
                        self.note(f"fixture restart failed on {vm.sid}: {again}")
            result = self.save(vms, done=True)
            print(json.dumps({k: result[k] for k in ("status", "hours", "stats", "targets_met")}, indent=2))
        finally:
            for vm in vms:
                vm.fx.stop()
            self.run.cleanup()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sandbox", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--root", default=str(Path.home() / ".iso-macos-dev"))
    ap.add_argument("--results", default=str(Path.home() / ".iso-macos-dev" / "qualify"))
    ap.add_argument("--hours", type=float, default=8.0)
    # Virtualization.framework runs at most two macOS guests per host.
    ap.add_argument("--vms", type=int, default=2)
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    # SIGTERM unwinds through `finally`, so canaries and VMs are cleaned up.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    Soak(args).main()


if __name__ == "__main__":
    main()
