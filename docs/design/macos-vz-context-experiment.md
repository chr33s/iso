# macOS VZ process context, headless display and virtual HID: results

**Status:** Development-bar results on one host. C3–C5, several session
transitions and the qualification counts were not run.
**Date:** 2026-10-06
**Spec:** [`macos-vz-context-headless-experiment-spec.md`](macos-vz-context-headless-experiment-spec.md)
**Harness:** [`experiments/macos-vz-context-probe/`](../../experiments/macos-vz-context-probe/)
(experiment code; not part of the shipped product)
**Follows:** [`macos-computer-use-q0-spike.md`](macos-computer-use-q0-spike.md)

## Verdict

On the tested build the results point to **decision A** of spec §20. The
current `user/$UID` + `Background` ownership model (C1) can host both the VM
and computer use:

1. **The runtime does not depend on a GUI.** A headless owner starts and stops
   the VM in 10/10 runs each from C0, C1 and C2. It uses no view, no AppKit
   and no WindowServer connection.
2. **Computer use needs a `VZVirtualMachineView` inside an `NSWindow`, but the
   window does not have to be visible.** These windows all gave fresh frames
   and exact pointer and keyboard input:
   - a window ordered out (V5) or placed at (−30000, −30000) on no screen (V6),
     under both C1 and C2;
   - a minimized (V4) or occluded (V2) window under C2.

   V5 under C1 reached the development bar: 1,000/1,000 fresh captures in one
   consecutive streak, and 1,000 random clicks with 0 wrong, 0 missing and
   0 more than 1.5 px off target. With no window (V7), frames are black and
   absolute-pointer input is lost without an error.
3. **`requestStop()` did not stop a macOS guest in 0/30 runs.** A guest-side
   shutdown request over vsock stopped it in every run.

Not established:

- pre-login operation (C3–C5, hypothesis H3);
- root versus non-root (H2);
- unlock, inactive-Space, fast-user-switch and host-sleep transitions;
- the spec §22 qualification counts.

## Environment

```text
host            Mac17,7 (Apple M5 Max), macOS 27.0.1 (26A434)
xcode / sdk     Xcode 27.0 (27A266a), macOS SDK 27.0
guest           macOS 27.0.1 (26A434); the Q0 spike's preinstalled bundle (same hardware
                model, machine id, aux storage and disk for every run); guest user
                auto-logged-in; guest time zone America/Los_Angeles
display         VZMacGraphicsDisplayConfiguration 1440x900 @ 80 ppi (guest scale 1),
                automaticallyReconfiguresDisplay = false
devices         VZUSBScreenCoordinatePointingDevice, VZMacKeyboard, virtio-net (NAT),
                virtio-vsock, virtio-block; 4 vCPU / 8 GiB
iso             81f643e + this harness
host session    locked with the display off until 08:53 local; unlocked during run
                085316 and in use by a person until 09:30; locked again for the
                last two runs (093444, 093834)
driver shell    a non-Aqua session (launchd manager "Background", remote, tty)
```

The harness does not assume the session labels. It derives them from the
observed `IOConsoleLocked` value and the display state. Because the host was
locked at the start, spec state S0 (logged in and unlocked) was observed only
in the later `user/$UID` view runs.

## Results

Evidence: `~/.iso-vz-probe/results/<run-id>/` on the test host, in the spec §18
layout. Phase 2–4 and E9 runs from before the harness review are kept
separately in `~/.iso-vz-probe/superseded/` and are not counted.

Phase 1 is the exception. Its 30 runs predate the review and used an earlier
build. They still count, because the review's runtime fixes did not change
anything they depend on, and they were re-evaluated against the stricter
criteria afterwards. Every run had `state_before_stop: running` and a
successful `requestStop` call. Their session labels were re-derived from each
run's recorded host state.

Some statuses were changed by hand after review. Each such `result.json` has a
`reclassified` field:

- **Host in use.** In 8 runs a person was using the host, and the harness
  recorded host-focus `fail`. Those layers became `environment_error`.
- **Fixture defect.** In 3 runs a harness defect put a stale fixture in front.
  Those layers became `environment_error` too.

The harness itself never writes `environment_error` for either case.

### Phase 1: VM ownership, no view (E0, E1)

| Context | Runs | Runtime | Host state |
|---|---|---|---|
| C0 direct child | 10 | 10/10 pass | S1+S2 (locked, display off) |
| C1 `user/$UID` + `Background` | 10 | 10/10 pass | S1+S2 |
| C2 `gui/$UID` + `Aqua` | 10 | 10/10 pass | S1+S2 |
| C3 system daemon, root | — | not_run | needs sudo |
| C4 system daemon, `UserName` | — | not_run | needs sudo and the `iso-vz-test` user |
| C5 cold boot, never logged in | — | not_run | needs a disposable host and a power cycle |

A pass required all of the following:

- the configuration validated;
- the VM started on an explicit serial queue and reached `running`;
- the guest LaunchDaemon helper sent a vsock hello carrying the boot ID and
  build;
- the guest returned an SSH banner, and an SSH login read a boot ID equal to
  the one in the hello;
- the VM reached `stopped` after a stop that the owner requested while the VM
  was still `running`;
- the owner exited with status 0.

No run crashed, raised SIGTRAP or deadlocked. The guest became reachable
5.9–7.8 s after start. Every stop took the guest-helper path (see Findings).
The C0 positive control was not an unlocked interactive Terminal: its parent
was a Background-session shell on a locked host.

### Phase 2: host session transitions, runtime only (C1)

| Row | State observed | Result |
|---|---|---|
| S0 | not reached: the host was already locked | — |
| S1+S2, checked at +0, +20, +40 and +60 s | locked, display off | pass |
| S3 | display woken, still locked | pass |
| S4/S5 fast user switch, S6 host sleep | — | not_run (needs an operator) |

Checks in each row: the VM stayed `running`, the owner pid was unchanged, the
guest boot ID read over SSH was unchanged, and the status heartbeat was less
than 5 s old. The graceful stop while locked passed. The only real transition
observed was the display waking. `pmset displaysleepnow` ran against a display
that was already off.

### Phase 3: view topology

Each run: O1 `cacheDisplay` captures, each checked against the token and the
frame counter read from the guest over SSH, with freshness enforced
(development counts 100 or 50; one 1,000-capture run); random grid clicks
(200 or 100; one 1,000-click run); pointer coverage; 180 keyboard events;
host-focus snapshots around each batch. A run counts only for the topology
it actually reached, so the harness checks the window state before testing.

**`gui/$UID` (C2), host locked**

| Topology | Window observed | Observation | Pointer | Keyboard |
|---|---|---|---|---|
| V0 visible, key | not reached (`key` false on a locked host) | not_run | not_run | not_run |
| V1 visible, not key | visible, on screen | 100/100 | 200/200, coverage pass | 180/180 |
| V2 fully occluded | own opaque window above it | 100/100 | pass | pass |
| V3 inactive Space | not reached (needs an operator) | not_run | not_run | not_run |
| V4 minimized | `miniaturized`, not visible | 100/100 | pass | pass |
| V5 ordered out | not visible | 100/100 | pass | pass |
| V6 offscreen | frame at (−30000, −30000), on no screen | 100/100 | pass | pass |
| V7 no window | view only | **0/20, black** | **20/20 missing** | 180/180 delivered |
| V8 no view | — | not_supported | not_supported | not_supported |

**`user/$UID` + `Background` (C1)**

| Topology | Runs | Probe-side oracles | Host focus checked and unchanged | Excluded |
|---|---|---|---|---|
| V1 | 1 | 1/1 pass | 1 | — |
| V5 | 11 | 9/9 pass, including 1,000 captures and 1,000 clicks | 6 | 2 environment_error (fixture defect, below) |
| V6 | 10 | 9/9 pass | 4 | 1 environment_error (fixture defect) |

Several C1 runs took place while the host was unlocked and a person was using
it. The cursor moved, Command was held, and the frontmost app changed between
Chrome, Zed, Music and Fork. In 8 of those runs the host-focus oracle saw
changes it cannot attribute. The harness recorded those layers as `fail`.
After review they were changed by hand to `environment_error` (see the
`reclassified` field). Their probe-side oracles (frames, clicks, keys) all
passed. A focus check that means anything needs an idle host.

These checks held in every passing topology:

- **Clicks:** 0 wrong-target, 0 missing, and 0 more than 1.5 px from target.
  Targets came from the magenta grid markers in the captured framebuffer,
  which were within 0.25 px of the fixture's own layout.
- **Pointer coverage:**
  - 50 moves and 8 edge or corner positions;
  - 20 double clicks;
  - separate button down/up, checked against the guest-observed
    `buttons_down`;
  - 8 drags, at 20 and 300 steps;
  - scrolling with direction checked, where opposite inputs moved the region
    in opposite directions;
  - 20 right clicks.
- **Keyboard:** the event order matched exactly and the text field received
  the exact text. Nothing was left stuck afterwards: `keys_down` was empty and
  the modifiers were 0. The fixture was still alive after the Cmd-S and Cmd-Q
  key-downs, which it swallows. Cmd-Tab was not claimed and was not run.
- **O2 (ScreenCaptureKit):** not run. It is a diagnostic only, and O1 already
  qualifies.

### Phase 4: computer use across session changes (V6, C2)

| Transition | State observed | VM | SSH | Fresh frames | 50 clicks | Keys | Host focus |
|---|---|---|---|---|---|---|---|
| baseline | locked, display off | pass | pass | pass | pass | pass | unchanged |
| display sleep | already locked and off | pass | pass | pass | pass | pass | unchanged |
| display wake | locked, display on | pass | pass | pass | pass | pass | unchanged |
| unlock, inactive Space, fast user switch, host sleep | — | not_run | | | | | needs an operator |

### E9: identity binding

Both runs passed.

**First run** (V6, C2). This was the original check:

1. A session clicked correctly before a guest reboot.
2. No action on the old session was accepted once the new boot ID was seen,
   and it was refused from then on. Attempts made while the guest was down
   were not checked.
3. A new session on the new boot clicked correctly.
4. A replacement owner process refused the second session. This step is weak
   by construction, because a new process starts with no sessions.

**Strengthened runs** (V6, C1: `20261006T110240-e9-V6-C1-cfe7`, and
`20261006T112228-e9-V6-C1-b0ee`, which also records each attempt in order).
Both use the strengthened check, in a single owner:

1. A session clicked correctly before a guest reboot.
2. In b0ee the recorded attempts run: accepted, then
   `boot identity changed (session bound to 8CE013B6…, now none)`, then
   `unknown session` from then on. The first refusal is the staleness check
   itself, and no action was accepted after the boot changed.
3. A new session on the new boot clicked correctly.
4. `restart_vm` replaced the VM inside the same owner. In b0ee the VM
   instance changed from `E127BD9D` to `744711A6`, and the stop took the
   guest-helper path. The previous session was refused with
   `vm instance changed`.
5. A fresh session on the new VM clicked correctly.

### Vsock helper authentication (`auth-check`, C1)

Pass in two runs (`20261006T105047-auth-C1-3368`, `20261006T112610-auth-C1-84c0`).

- The helper's hello is now a challenge-response:
  `HMAC-SHA256(helper.key, nonce|boot)`.
- The guest user could not read `/usr/local/etc/iso-vz-probe-helper.key`.
- The real helper binary, run as the unprivileged guest user with its own
  key, was rejected 3 times as `bad mac`.
- The accepted boot identity and its generation were unchanged afterwards.

### Lifecycle refactor check

Both owners now share one `VMHost` type for construction, state, start and the
stop sequence. After the refactor these runs passed with the same criteria:

- Phase 1 C1, 3/3;
- V5 under C1;
- Phase 4 under V6/C2;
- the E9 run above.

Every stop took the guest-helper path.

## Findings

1. **The runtime has no GUI dependency (H1 pass).** The C1 owner's security
   session reports no graphic access, and `vm-run` never connects to
   WindowServer. It still passed 10/10.
2. **The view needs a window but not a visible one (H5 pass, conditional).**
   V5 and V6 work under both C1 and C2. Without a window (V7), frames are
   black and absolute-pointer input is lost silently: clicks, moves and drags
   never reach the guest. Keyboard events and scroll events still arrive (the
   scroll region did not move).
   This refines Q0 finding 1, which described all input as dropped. A
   production owner must refuse frames and pointer input when
   `view.window == nil`.
3. **H4 does not apply on this build:** the view works in `user/$UID`. Q0
   reported that `user/$UID` worked with an offscreen window. Q0 built that
   window the same way as this harness did at first, and AppKit's
   `constrainFrameRect` pulled it back onto the screen. Before this harness
   was fixed, its V6 window recorded frame `[0, 0, 1440, 932]` with
   `on_screen: true` (for example, superseded run
   `20261006T060711-p3-V6-C2-51dd`). Q0's "offscreen" results were therefore probably
   measured on an on-screen window. With `constrainFrameRect` overridden, a
   truly offscreen window works under C1 and C2.
4. **`requestStop()` does not stop a macOS guest:** 0/30 within 60 s in
   Phase 1, and none in the later view-owner runs, all with an
   auto-logged-in guest user. The guest helper, a LaunchDaemon, runs
   `shutdown -h now` when the host asks over vsock. It stopped the guest in
   every run, about 5 s after the request, and `guestDidStop` fired each
   time. A macOS-guest backend needs this kind of guest-side path, with
   `stop()` as the forced fallback.
5. **`NSEvent.mouseEvent` cannot express a right click.** A synthesized
   `.rightMouseDown` arrived in the guest as a **left** click every time (0/20
   right clicks per topology), because the API cannot set `buttonNumber`. An
   NSEvent built from a `CGEvent` with `.right`, handed to the view and never
   posted, arrived as a right click at the exact position (20/20 in every
   passing topology). `NSEvent(cgEvent:)` derived `locationInWindow` without
   the window origin in a visible window at (80, 80), so the probe checks the
   derived location and corrects it once.
6. **The guest coalesces synthesized drags.** About 14 of 20 `mouseDragged`
   events arrived, and every drag reached the correct target. Drag oracles
   should check the endpoint, not the event count.
7. **Scroll direction follows the guest's natural-scrolling setting**
   (`wheel1` +200 arrived as `scrollingDeltaY` −200).
8. **Local Network privacy blocks the owner's own TCP to the NAT guest.**
   Direct `connect()` from the ad-hoc-signed probe failed with
   `EHOSTUNREACH` (65), recorded as `direct_connect_errno` on every Phase 1
   `guest_ssh_banner` event. `/usr/bin/nc` and `/usr/bin/ssh` connected.
   `iso` uses `/usr/bin/ssh` today. Any in-process guest networking in a
   future owner needs Local Network approval, or should use vsock.
9. **A host lock and a display wake affect neither runtime nor computer use**
   under C2, and V5/V6 also passed under C1 while locked. One unlock happened
   inside a C1 run (`085316`, V6), and one lock inside another (`093045`, V5).
   The probe-side oracles passed in both. Their host-focus checks were
   confounded by the person using the host.
10. **Guest login relaunch can corrupt computer-use oracles.** In three C1
    runs the guest's saved application state relaunched the fixture at login.
    In one boot the relaunched instance crashed in `BarcodeView.draw`, 15 s
    after boot and before fonts were ready. The relaunch also raced the
    harness, which left a default-token instance in front. Token decoding
    caught all three, and those runs were changed by hand to
    `environment_error`. After run `084134` the harness was changed to disable
    login relaunch and to check that exactly one fixture instance is running.
    Something still relaunched the fixture at guest login after that. It was
    not a login item, a saved state or loginwindow's relaunch list, and the
    cause is unknown. The relaunched instance runs without arguments, so the
    fixture now exits at once when it has no `--token`.
    A production guest image should do the same for its computer-use
    components.

## Decision against spec §20

| Row | Condition | Result |
|---|---|---|
| A ideal | C1 runtime passes; non-visible V5/V6/V7 observation passes; HID without host focus; lock behaviour acceptable | **Met for V5/V6** (V7 fails), on a locked host. Host-focus evidence is clean in 11 C1 runs and confounded by a person's activity in 8 |
| B split | view/HID requires `gui/$UID` | no: V1, V5 and V6 pass under C1 |
| C GUI owner required | C1 fails, C2 passes | no |
| D pre-login works | C5 passes | not_run |
| E root fails, user succeeds | — | C3 not_run |
| F visible or focused window required | only V0 reliable | no: V0 was never reached, and V2/V4/V5/V6 pass |

Spec §21, minimum sequence:

| Step | Status |
|---|---|
| E0 | pass |
| E1 | pass |
| E2 (C5) | not_run |
| E3 (V0) | not reached; V1 shows fresh pixels in a visible window |
| E4 (V7) | run: fails as expected |
| E5 (V5/V6) | pass |
| E6 | 1,000 clicks with 0 wrong targets (V5, C1) |
| E7 | pass |
| E8 | lock and display behaviour pass; one unlock and one lock observed inside C1 runs, probe-side pass |
| E9 | pass (boot change and VM-instance change both refused) |

None of the stop-and-redesign conditions triggered.

## Not done, and how to run it

- **C3–C5 (E2, H2, H3).** Run `./probe.py daemon-plan --context C3|C4|C5`.
  It writes a plist and a `sudo` install script that clones the VM bundle into
  a root-owned `/Library/Application Support/iso-vz-probe`. C4 and C5 also
  need the standard user `iso-vz-test`. C5 needs a full power cycle with no
  login, followed by `./probe.py collect <run-dir> --boot-log`.
- **Session transitions.** For unlock, inactive Space (V3), V0, fast user
  switch and host sleep, rerun with `--operator-wait 60` and someone at the
  console. For the host-focus oracle, do not otherwise use the host.
- **Qualification (spec §22):**
  - 100 C1 cycles: `phase1 --context C1 --runs 100`;
  - 10,000 clicks and 1,000 captures on the chosen topology and domain;
  - all on the exact release host and guest builds.
- **O2:** `phase3 --topology V5 --sck`, with Screen Recording granted, as a
  diagnostic.
- **Installer (Phase 7):** not started.

## Follow-ups

Done after the first write-up:

- The Q0 spike record now carries a correction for its offscreen claim.
- `vm-run` and `vm-view` share `VMHost`.
- E9 has the in-owner `restart_vm` check.
- Phase 4 and E9 write a result row when they fail part-way.
- The vsock helper is authenticated.

Open: none from this experiment beyond the not-done items above.
