# macOS computer use: Q0 go/no-go spike

**Status:** Spike complete; Q0.1–Q0.5 pass in one owner topology, with one unexplained failure
**Date:** 2026-10-05
**Target:** a future macOS-guest backend for `chr33s/iso` (none exists today)
**Depends on:** [`macos-computer-use-qualification-plan.md`](macos-computer-use-qualification-plan.md)

> This record has the results of the plan's "minimal go/no-go spike" (Q0.1–Q0.5)
> and the design constraints they set. It does not qualify any gate (A–T). The
> harness is in [`spikes/macos-computer-use-q0/`](../../spikes/macos-computer-use-q0/);
> it is not part of the shipped product or the package gates.

## Verdict

Virtual display plus virtual HID plus a small vsock channel is technically
credible, but **only if the VM owner keeps its `VZVirtualMachineView` in a
window**. An offscreen window is enough, and it works from a launchd job in the
`Background` session with the host locked and the display asleep.
The current `iso-sandbox` owner shape, a windowless launchd job, does not
work: the view renders nothing and silently drops all input.

> **Correction (2026-10-06):** the "offscreen" window here was probably on
> screen. The harness set the origin to (−30000, −30000) on a titled window,
> then ordered it front. AppKit's `constrainFrameRect` moves such a window back
> onto a screen, and the follow-up experiment recorded exactly that
> (`[0, 0, 1440, 932]`, on screen). With the constraint overridden, a truly
> offscreen window, and an ordered-out window, still work from `user/$UID` and
> `gui/$UID`. Without a window, keyboard and scroll events still reach the
> guest. Frames and absolute-pointer input do not. See
> [`macos-vz-context-experiment.md`](macos-vz-context-experiment.md).

| Cell | Result | Topology |
|---|---|---|
| Q0.1 rendered native window | Pass: random token decoded exactly from host frames | visible, hidden, offscreen window |
| Q0.2 headless/offscreen | Pass with an offscreen window under launchd; no-window owner is refused (it cannot render) | launchd `Background` + offscreen window |
| Q0.3 absolute click | Pass: 1,000/1,000 on target, 0 missing, all within 1.5 px | launchd + offscreen window |
| Q0.4 keyboard | Pass: 176/176 events exact, no stuck modifiers, no host leakage | launchd + offscreen window |
| Q0.5 reboot identity | Pass: old session refused on every attempt from the moment the guest went down; new session bound to the new boot works; a replacement owner inherits no session | launchd + offscreen window (also visible window) |

Version matrix: host Mac17,7 (Apple M5 Max), macOS 27.0.1 (26A434); guest
macOS 27.0.1 (26A434) from `UniversalMac_27.0.1_26A434_Restore.ipsw`; Xcode 27.0
(27A266a); `iso` at `81f643e`; display 1920×1200 at 80 ppi (guest backing scale
1); `VZUSBScreenCoordinatePointingDevice`, `VZMacKeyboard`.

## Harness

Run it on a macOS 27 Apple Silicon host. VM state goes in `$Q0_STATE`
(default `~/.iso-q0`):

```sh
cd spikes/macos-computer-use-q0
./build.sh            # owner, guest fixture app and helper into .build/q0
./q0.py fetch         # newest restore image from Apple's public catalog
./q0.py install       # install, provisioning first boot, guest bootstrap
./q0.py all           # Q0.1–Q0.5 → $Q0_STATE/results/report.{json,md}
./q0.py display-sleep # owners started with the host display asleep
./q0.py first-boot    # fresh install, capture through the provisioning boot
./q0.py locked        # gui/$UID LaunchAgent vs user/$UID owner on a locked host
```

`display-sleep` sleeps and wakes the host display; `first-boot` needs an empty
`$Q0_STATE/vm`.

- **Owner** (Swift, `com.apple.security.virtualization`): boots the VM with
  `VZMacOSBootLoader`, one `VZMacGraphicsDisplayConfiguration`, NAT networking
  and a vsock device. It serves a JSON-lines Unix socket for `state`, `frame`,
  `session`, `click`, `move`, `key`, `stop`. Input is synthesized `NSEvent`s
  delivered directly to the `VZVirtualMachineView`, so the host's own pointer
  and keyboard are never involved. Coordinates are framebuffer pixels with a
  top-left origin.
- **Unattended setup:** macOS 27's `VZMacGuestProvisioningOptions` (user,
  password of at least 4 characters, autologin, Remote Login) on the first boot
  after restore. No Setup Assistant interaction. Install plus provisioning took
  161 s + about 40 s.
- **Boot identity:** a guest LaunchAgent connects to host vsock port 7700, sends
  `{"hello":1,"boot":"<kern.bootsessionuuid>"}` and holds the connection. A
  session is bound to the VM instance, boot ID, connection generation and
  display geometry. A disconnect or new hello invalidates it.
- **Oracles** (all independent of the owner's return values):
  - Frames: a guest AppKit fixture draws a random 32-bit token as a 4×4
    barcode under a calibration row. The host decodes the PNG by nearest
    calibration colour, which tolerates colour-space conversion.
  - Clicks: a full-screen 10×10 grid fixture logs which cell received each
    `mouseDown`/`mouseUp` and the location in screen pixels.
  - Keys: a key-logging fixture records every `keyDown`, `keyUp` and
    `flagsChanged`, plus the global modifier state.
  - Host leakage: host `NSEvent.mouseLocation` and `modifierFlags` are compared
    before and after each run.
- SSH used trust-on-first-use into a spike-local `known_hosts`. Pinning the
  host key over vsock is Gate J and was not part of Q0.

## Findings

1. **No window means no frames and no input, with no error.** Without a window,
   `cacheDisplay` frames are uniformly black, layer capture finds no contents,
   and 100/100 clicks and every key event never reach the guest while the call
   returns normally. This is the Cua #1162 failure class reproduced on the host
   side. The owner must refuse frames and input when the view has no window.
2. **Frame capture works in-process, without Screen Recording.** Two methods
   decoded tokens exactly: walking the view's layer tree to the framebuffer
   `IOSurface` (1920×1200, guest pixels), and `cacheDisplay(in:to:)` (scaled to
   the host backing, 3840×2400). Neither needs TCC. ScreenCaptureKit was
   refused (`SCStreamErrorDomain -3801`) throughout and is not needed. The
   layer-tree walk depends on the view's private layer structure, so it needs
   requalifying on every OS update. `cacheDisplay` is public API.
3. **A locked host does not matter, in either launchd domain.** With the host
   console locked (`IOConsoleLocked`) before the owner started and throughout,
   a `gui/$UID` LaunchAgent (`LimitLoadToSessionType=Aqua`) and a `user/$UID`
   job (`Background`), each holding only an offscreen window, both passed:
   4/4 tokens, 500/500 clicks, 176/176 key events, and no host input change.
   Not tested: no user logged in (where `gui/$UID` does not exist), fast user
   switching, and lock/unlock over long sessions.
4. **Display sleep does not matter.** With the owner started while
   the display was asleep and the host locked, 24/24 captures decoded exactly,
   both asleep and after wake, across visible, offscreen and launchd-offscreen
   owners.
5. **Modifiers are silently dropped without device-dependent bits.** The view
   ignores `flagsChanged` events unless `modifierFlags` carries the left/right
   device bits (`0x1` control, `0x2` shift, `0x20` option, `0x8` command, plus
   `0x100`), so text arrives unshifted and Command shortcuts arrive as plain
   keys. With the bits, the sequence is exact. (AppKit also never routes
   `keyUp` to a view while Command is held, so the fixture records key-ups with
   an app-level event monitor.)
6. **The VM reports "running" across a guest reboot.** `VZVirtualMachine.state`
   stays running and `guestDidStop` is not called. Only the vsock helper's
   disconnect and its new boot ID reveal the reboot (about 16 s). Gate K and
   Q0.5 cannot rely on host VM state alone.
7. **The auxiliary-storage lock prevents double boot.** A second owner on the
   same bundle fails `start` with "Failed to lock auxiliary storage" (`EAGAIN`)
   and does not disturb the running VM's frames. This is relevant to Gates L
   and M.
8. **Boot frames are legitimately blank.** For about 5–30 s after start, the
   view has no contents or is uniformly black. Capturing during that window
   must refuse rather than return a frame.

## Open issues

- **One unexplained black-frame episode.** The first visible-window owner,
  launched from a user terminal, returned black or empty frames about 14 min
  after start, while input and reboot identity on that same owner worked.
  Ruled out: host locked or display asleep (24/24 pass), the first boot after
  provisioning (frames recovered within 40 s on a fresh install), and a
  concurrent second owner (12/12 pass). Still possible: launch from a user
  terminal, or a display that had been asleep for hours before the owner
  started. Until this is reproduced, the owner treats a uniform frame as
  "framebuffer not observed" and refuses it (see Guards).
- **One silent click drop.** The first click of the first grid run never
  arrived, with no refusal. Later runs saw none in 2,500 clicks. Gate E
  requires delivery to be proven, so a production owner needs a delivery
  oracle (for example, a fixture-independent guest acknowledgement over vsock)
  rather than trusting the view.

## Guards added to the harness

- Frames, clicks, moves and keys are refused with
  `view has no window: …` when the `VZVirtualMachineView` is not in a window.
- A frame whose largest per-channel range over a 64×40 downsample is ≤ 3 is
  refused as `blank frame … framebuffer not observed`. Verified: early-boot
  frames are refused, then accepted once the guest draws (about 5 s).
- Actions are refused when the session's VM instance, boot ID, helper
  connection generation or display geometry no longer match.

## Implications for the qualification plan

- Gate D: the production owner is a launchd job that keeps an offscreen
  window. "No user-facing console" means no visible window, not no window.
- Gate C: in-process capture is the path. Requalify the layer-tree walk on
  every macOS update, or prefer `cacheDisplay` and accept the backing-scale
  resample.
- Gates E/G: drive input through the view with device-dependent modifier bits,
  and keep an independent delivery oracle. View-level success proves nothing.
- Gate K: guest reboot detection must come from the guest channel, not from
  `VZVirtualMachine.state`.
