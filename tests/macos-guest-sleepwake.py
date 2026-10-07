#!/usr/bin/env python3
"""Host sleep and wake during a macOS guest session (the Gate T row the soak
cannot run unattended). macOS 27+ on Apple Silicon; needs `sudo` once, to
schedule the wake (`pmset relative wake`). The Mac sleeps for about a
minute: save your work first.

    tests/macos-guest-sleepwake.py --sandbox BIN --template NAME [--root DIR] [--sleep 60]

Before and after one host sleep, a guest fixture must receive clicks and
typed text through computer use and report them over pinned SSH, and frames
must show the fixture's token with a fresh counter. It records whether the
owner, its boot and the session survived, or how the binding refused them.
"""

import argparse
import importlib.util
import json
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("qualify", HERE / "macos-guest-qualify.py")
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


def exercise(run, sid, fx, session):
    """Clicks, text and frames through one session; None when the session
    is refused."""
    grid = fx.st["layout"]["grid"]
    fx.drain(0.3)
    if run.rt.cu(sid, "act", "--session", session, "--action",
                 json.dumps({"kind": "click", "x": grid["x"] + 30, "y": grid["y"] + 30}), check=False) is None:
        return None
    clicked = fx.expect(lambda e: e["ev"] == "down", 5) is not None
    t = fx.st["layout"]["text"]
    run.rt.cu(sid, "act", "--session", session, "--action",
              json.dumps({"kind": "click", "x": t["x"] + t["w"] / 2, "y": t["y"] + t["h"] / 2}))
    before = fx.state().get("received_text", "")
    run.rt.cu(sid, "act", "--session", session, "--action", json.dumps({"kind": "type", "text": "sleepwake"}))
    time.sleep(0.5)
    typed = len(fx.state().get("received_text", "")) == len(before) + len("sleepwake")
    png = run.dir / "sleepwake.png"
    frame = run.rt.cu(sid, "frame", "--session", session, "--out", str(png), check=False) is not None
    decoded = q.analyze(png, fx.layout) if frame else {}
    return {"clicked": clicked, "typed": typed, "frame_token": decoded.get("token") == fx.token,
            "counter": decoded.get("counter")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sandbox", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--root", default=str(Path.home() / ".iso-macos-dev"))
    ap.add_argument("--results", default=str(Path.home() / ".iso-macos-dev" / "qualify"))
    ap.add_argument("--sleep", type=int, default=60)
    args = ap.parse_args()
    args.keep = False
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    subprocess.run(["sudo", "-v"], check=True)
    run = q.Run(args)
    out = {}
    try:
        run.plant_canaries()
        sid = run.create("sw")
        g = run.boot(sid)
        fx = q.Fixture(g)
        fx.install()
        fx.start(run.dir)
        session = run.rt.cu(sid, "session")["session"]
        before = run.rt.run("macos", "inspect", sid)
        out["before"] = exercise(run, sid, fx, session)
        fx.stop()
        subprocess.run(["sudo", "pmset", "relative", "wake", str(args.sleep)], check=True)
        started = time.strftime("%Y-%m-%d %H:%M:%S")
        subprocess.run(["pmset", "sleepnow"], check=True)

        def cycle():
            """The power log's first sleep after `started`, and a wake after it.
            Network traffic can wake the host before the scheduled wake."""
            lines = [line for line in subprocess.run(["pmset", "-g", "log"], capture_output=True,
                                                    text=True).stdout.splitlines() if line[:19] >= started]
            sleeps = [i for i, line in enumerate(lines) if "Entering Sleep" in line]
            wakes = [i for i, line in enumerate(lines) if sleeps and i > sleeps[0] and "\tWake " in line]
            return (lines[sleeps[0]], lines[wakes[0]]) if wakes else None

        slept, woke = q.wait_for(cycle, args.sleep + 600, "host sleep and wake", 2)
        out["host_sleep"] = slept[:19]
        out["host_wake"] = woke[:19]
        out["wake_reason"] = woke.split("due to", 1)[-1].strip()[:120]
        time.sleep(15)
        after = run.rt.run("macos", "inspect", sid)
        out["owner_survived"] = (after.get("live") or {}).get("pid") == before["live"]["pid"]
        out["boot_survived"] = (after.get("live") or {}).get("bootId") == before["live"]["bootId"]
        out["guest_boot_survived"] = ((after.get("runtime") or {}).get("guestBoot")
                                      == (before.get("runtime") or {}).get("guestBoot"))
        out["helper_connected"] = (after.get("runtime") or {}).get("helperConnected")
        g.refresh()
        out["ssh_after_wake"] = bool(q.wait_for(g.ok, 300, "ssh after wake", 3))
        fx.start(run.dir)
        out["old_session"] = exercise(run, sid, fx, session)
        out["old_session_refusal"] = run.rt.last_error if out["old_session"] is None else None
        out["new_session"] = exercise(run, sid, fx, run.rt.cu(sid, "session")["session"])
        fx.stop()
        works = lambda r: bool(r and r["clicked"] and r["typed"] and r["frame_token"])
        # The old session may survive (same boot and helper) or be refused by
        # the binding; it must never act on a changed boot.
        consistent = (works(out["old_session"]) if out["guest_boot_survived"] and out["boot_survived"]
                      else out["old_session"] is None)
        ok = works(out["before"]) and works(out["new_session"]) and out["ssh_after_wake"] and consistent
        out["status"] = "pass" if ok else "fail"
    except Exception as e:  # noqa: BLE001
        out["status"] = "fail"
        out["error"] = f"{type(e).__name__}: {e}"
    finally:
        run.gates["T_sleep_wake"] = out
        run.save()
        run.cleanup()
        print(json.dumps(out, indent=2, default=str))
    sys.exit(0 if out.get("status") == "pass" else 1)


if __name__ == "__main__":
    main()
