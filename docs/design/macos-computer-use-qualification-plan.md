# macOS Computer-Use Qualification Plan for `chr33s/iso`

**Date:** 2026-10-05  
**Scope:** macOS guests under Apple Virtualization.framework, controlled primarily through host-side virtual display + virtual keyboard/pointer, with a minimal virtio/vsock management channel.

## Qualification goal

`iso` should call macOS computer use **qualified** only when real-hardware tests prove all of the following:

1. macOS installs/provisions reproducibly.
2. The host observes the pixels the guest is actually rendering.
3. Virtual keyboard/pointer actions land at the intended coordinates and controls.
4. VM lifecycle cannot leave stale “running” state or stale computer-use sessions.
5. The management channel preserves trusted SSH enrollment and boot identity.
6. Host/guest isolation remains at least as strong as the current Linux backend.
7. Behavior survives repeated boots, clones, concurrent VMs, sleep/wake, and supported macOS host/guest builds.

The important rule is: **do not treat a successful API return as proof that the action or frame is correct. Use independent oracles.**

---

## Why Cua’s failures matter

### Cua #1162 — pointer APIs silently succeeded but cursor did not move

Cua found that `CGEventPost(kCGEventMouseMoved)` / pynput could report success inside Apple Virtualization.framework macOS VMs while the cursor remained at the old location.

**Implication for `iso`:** a click test must independently verify which control actually received the click. API success is not enough.

### Cua #870 / #912 — windows existed but were absent from rendered output

Their Tahoe investigation found application windows registered in WindowServer while screenshots and VNC showed only the desktop/menu bar.

**Implication for `iso`:** framebuffer qualification must compare pixels against independently known application state. Window metadata alone is insufficient.

### Cua #1184 — guest shutdown did not terminate host VM state

**Implication for `iso`:** guest-initiated shutdown must be a lifecycle test, not just host-initiated stop.

### Cua #2696 — `VZMacOSInstaller` queue misuse caused SIGTRAP

**Implication for `iso`:** Virtualization.framework queue/thread requirements need explicit qualification.

---

# Release gates

## Gate A — Virtualization.framework queue and state discipline

**Release blocker.**

Test:

- VM configuration creation
- `VZMacOSInstaller` creation/start
- VM start
- stop/requestStop
- guest-initiated shutdown callback
- device access
- display/view attach/detach
- repeated create/destroy

Pass:

- no dispatch assertions/SIGTRAP/deadlocks
- every async transition has exactly one terminal host-visible state
- a guest that shut down is never reported as running

---

## Gate B — unattended install and provisioning

**Release blocker.**

From clean state:

1. validate restore image
2. install macOS
3. first-boot provision
4. create `iso` user
5. configure autologin if required
6. enable SSH
7. install/enable minimal management helper
8. shut down
9. publish template
10. clone
11. boot clone

Run at least five clean install cycles.

Pass:

- no Setup Assistant interaction
- deterministic expected user/home
- SSH + management channel become available
- clone identities are appropriately unique
- failures never publish a usable template

---

## Gate C — framebuffer correctness

**Highest-priority release blocker.**

Build a deterministic fixture app that renders:

- random per-run text
- high-contrast rectangles in known positions
- animated counter
- native button
- sheet/popover
- second child window

For each run:

1. launch fixture
2. obtain fixture state independently over SSH/test socket
3. capture host-side VM frame
4. verify expected pixels
5. mutate fixture state
6. capture again
7. verify exact expected visual change

Cover:

- Finder
- AppKit
- SwiftUI
- WKWebView
- Electron/Chromium
- Safari
- System Settings
- Terminal
- menus
- sheets/popovers
- full-screen mode if supported

Pass:

- no desktop-only, black, stale, duplicate, or partial frames
- app windows and child windows are visible
- dynamic visual state appears within a bounded interval
- works with human console closed
- works in the exact launchd/headless topology used by production

**Critical:** WindowServer presence is not a pass. Pixel presence is required.

---

## Gate D — offscreen/headless behavior

**Release blocker if `iso-sandbox` remains a background owner.**

Qualify:

| Host presentation | Required result |
|---|---|
| visible console | works |
| hidden window | works |
| offscreen window | works |
| no user-facing console | works |
| host app unfocused | works |
| host locked | explicitly supported or explicitly rejected |
| fast-user-switch | explicitly supported or explicitly rejected |

Pass:

- input does not depend on host first-responder/focus
- observation remains correct
- host pointer/keyboard are not moved
- `iso` does not steal host focus

---

## Gate E — absolute pointer correctness

**Release blocker.**

Use a full-screen grid fixture.

Test:

- center and edge coordinates
- corners
- menu bar
- Dock
- left/right/double click
- button down/up
- drag
- long drag
- scrolling
- rapid sequences
- after stop/start

Pass:

- zero wrong-target clicks in a large deterministic run, e.g. 10,000 actions
- no “success” if delivery cannot be proven
- drag paths stay within tolerance

This is the direct regression class from Cua #1162.

---

## Gate F — coordinate/scale model

**Release blocker.**

Recommended public contract:

```text
origin: top-left
units: framebuffer pixels
range: [0,width) × [0,height)
```

Qualify:

- logical points vs pixels
- backing scale/Retina
- PPI
- guest scaled modes
- resize/reconfigure if supported
- reconnect after geometry change

Pass:

- one unambiguous transform maps observed pixels to action coordinates
- geometry changes atomically update frame metadata or invalidate stale frames/sessions

For MVP, a fixed display geometry is preferable.

---

## Gate G — keyboard correctness

**Release blocker.**

Test:

- letters, numbers, punctuation
- Shift/Control/Option/Command
- Return, Tab, Escape, arrows, backspace/delete
- key down/up
- repeat policy
- common shortcuts
- interruption during modifier sequences

Use a fixture that records the actual event/text stream received.

Pass:

- no stuck modifiers
- no event leakage to host
- deterministic event order
- interrupted action releases pressed keys/buttons

Define whether arbitrary Unicode means physical-key semantics or a separate high-level text operation.

---

## Gate H — frame/action binding

**Strongly recommended release blocker.**

Every observed frame should include:

```text
frame_id
boot_id
width
height
sequence/timestamp
```

Actions may optionally carry:

```text
based_on_frame_id
```

Test:

- stale frame after resize
- stale frame after reboot
- VM destroyed/recreated with same name
- concurrent action callers
- delayed actions

Pass:

- boot mismatch always refuses
- replacement VM cannot inherit an old computer-use session
- geometry mismatch refuses rather than silently remapping

This follows Cua’s capture-bound action philosophy.

---

## Gate I — virtio/vsock management helper

**Release blocker.**

Minimal protocol can remain tiny:

```text
HELLO
STATUS
SSH_HOST_KEY
SHUTDOWN
```

Test:

- malformed frames
- oversized messages
- unknown protocol version
- wrong boot nonce
- missing/crashed helper
- owner restart
- helper replacement
- disconnect mid-request
- slow client

Pass:

- bounded messages/memory
- no arbitrary shell if it is not part of the contract
- SSH pin comes over the trusted channel
- helper identity is tied to current boot ID
- guest handoff fails closed on inconsistency

---

## Gate J — SSH enrollment/workspace

**Release blocker.**

Test:

1. clone
2. obtain SSH host key over management channel
3. pin
4. strict SSH connect
5. copy workspace
6. stop/start
7. reconnect
8. reset/recreate
9. require new enrollment when identity changes

Pass:

- no `ssh-keyscan`/TOFU fallback
- unexpected changed host key is refused
- stale SSH alias cannot hit a replacement VM
- workspace permissions/path are correct for the macOS guest user

---

## Gate K — lifecycle correctness

**Release blocker.**

Exercise:

- host start
- Apple-menu shutdown
- guest command-line shutdown
- host stop
- owner SIGKILL
- launchd respawn
- reboot
- VM crash
- session TTL expiry
- destroy
- host sleep/wake
- abrupt host restart where feasible

Pass:

- one authoritative state
- no owner process after stopped
- no “running” after guest shutdown
- computer-use session closes on boot change
- TTL halts VM even if guest control is wedged

Add a regression specifically for the class seen in Cua #1184.

---

## Gate L — clone/template identity

**Release blocker.**

Verify clones do not unintentionally share:

- machine identifier
- SSH host key
- helper boot identity
- ephemeral session token
- writable disk state

Verify they may share only intentionally immutable template layers.

Pass:

- write in A never appears in B
- destroying A cannot corrupt base/B
- multiple simultaneous clones are independent

---

## Gate M — storage crash consistency

**Release blocker for operations actually exposed.**

For MVP, qualify only:

- clone creation
- template publication
- reset/recreate
- deletion

Kill the client/owner at several fractions of each operation.

After reconciliation, state must be old or new, never a partial hybrid.

Do not claim Linux-style grow/commit parity until equivalent macOS semantics exist.

---

## Gate N — network isolation

**Release blocker.**

Repeat `iso`’s current real-VM network boundary tests for macOS:

- peer isolation
- IPv4/IPv6
- TCP/UDP/ICMP
- forged routes where possible
- open mode
- host-only/none
- DNS behavior
- restart/crash recovery

Do not mark filtered egress supported until separately qualified on macOS.

---

## Gate O — host exposure

**Release blocker.**

Canaries:

- host filesystem secret
- host environment secret
- SSH agent socket
- host clipboard
- host pointer/keyboard
- unrelated host vsock listeners
- other VM disks
- runtime control socket
- camera/mic/audio unless explicitly supported

Pass:

- none reachable unless deliberately exposed
- effective VZ configuration contains no unexpected directory share/device
- unknown configuration fails closed

---

## Gate P — multi-VM session isolation

**Release blocker.**

With 2+ VMs:

- action to A never reaches B
- frame from A never returns B
- reused VM name cannot reuse old session
- crash of A does not affect B
- concurrent frame requests cannot mix frame IDs

---

## Gate Q — representative application coverage

**Release blocker at a defined tier.**

Recommended MVP:

### Native apps
- Finder
- Terminal
- TextEdit
- Calculator
- System Settings
- Safari

### Frameworks
- AppKit fixture
- SwiftUI fixture
- WKWebView fixture
- Electron fixture

### Controls
- button
- text field
- multiline editor
- menu/context menu
- checkbox/radio
- popup/combo
- slider
- drag/drop
- sheet/modal
- child window
- scroll view
- browser page

The goal is framework coverage, not “all Mac apps work”.

---

## Gate R — login/system UI

**Important because virtual HID should work below the logged-in automation layer.**

Test observation/input at:

- boot progress
- login window
- auto-login transition
- lock screen if supported
- shutdown/restart dialogs
- TCC/system prompts
- macOS update prompts under the documented policy

Pass:

- screenshots show the actual visible UI
- virtual input reaches it
- host-side emergency stop remains possible without guest helper

---

## Gate S — performance

Measure:

- observe request → complete frame
- action request → fixture-observed input
- click → visible response
- sustained frame rate
- idle CPU
- capture CPU
- long-session RSS growth
- 1/4/8 VM scaling

Possible initial targets:

- p95 input delivery < 50 ms
- p95 fresh frame < 250 ms at MVP resolution
- no unbounded memory growth over 8 hours

Correctness comes first.

---

## Gate T — soak/recovery

**Release blocker.**

Run:

- 8-hour computer-use session
- 10,000 pointer actions
- 10,000 key events
- 1,000 frame captures
- 100 app launch/close cycles
- 20–100 stop/start cycles
- repeated owner crashes
- sleep/wake
- supported concurrency

Pass:

- zero cross-VM events
- zero stale-boot actions
- zero silently wrong clicks in fixture
- no leaked owner/control processes
- bounded resource growth
- no progressively stale/black frames

---

# Version matrix

Every result should record:

```text
host model / SoC
host macOS version + build
guest macOS version + build
Xcode/SDK version
iso commit
iso-sandbox commit / runtime protocol
template identifier/hash
display geometry
computer-use mode
```

A supported macOS host/guest point release should be considered unqualified after an OS update until the critical display/input/lifecycle gates rerun.

That is one of the clearest lessons from Cua’s VM-specific regressions.

---

# Independent-oracle pattern

The core test pattern should be:

```text
             +--------------------+
             | independent oracle |
             | app state / SSH    |
             +----------+---------+
                        |
host frame <--- macOS fixture <--- virtual HID
    |                   |
    +------ pixel -------+
           oracle
```

Example click:

1. request click `(x,y)`
2. fixture records which button actually received it
3. host captures changed visual state
4. both must agree

This detects:

- API success but wrong click
- correct app state but stale framebuffer
- visual change in the wrong target/application

---

# What `iso` does not need to copy from Cua initially

The proposed `iso` model does **not** initially require qualification for:

- background delivery
- per-PID input routing
- AX element addressing
- preserving focus for a human using the same desktop
- multiple independent guest-side cursors
- guest-side ScreenCaptureKit
- Accessibility permission for basic input
- private SkyLight APIs

For `iso`, the initial contract can be much smaller:

```text
one dedicated desktop
one pointer
one keyboard
foreground interaction
pixel observation
```

What `iso` should borrow is Cua’s **oracle rigor**, evidence retention, and refusal/error semantics.

---

# Minimal go/no-go spike

Before implementing the full macOS lifecycle, prove these five cells on real hardware.

## Q0.1 Rendered native window

- boot macOS
- launch AppKit fixture with random token
- host-side frame must contain exact fixture pixels/token

**Failure: stop; observation architecture is not viable.**

## Q0.2 Headless/offscreen frame

- close/hide user-facing VM console
- repeat Q0.1 using planned production owner topology

**Failure: redesign owner/display topology.**

## Q0.3 Absolute click

- 10×10 target grid
- 1,000 randomized host-side pointer actions
- fixture reports exact hit target

**Require zero wrong targets.**

## Q0.4 Keyboard

- send deterministic sequences with modifiers
- fixture compares exact input stream

**Require zero stuck/leaked modifiers.**

## Q0.5 Reboot identity

- establish computer-use session
- reboot VM
- old session must refuse
- fresh session must succeed

If these five pass, virtual display + virtual HID + tiny vsock is technically credible.

---

# MVP release bar

For a first supported release, I would require:

- Q0.1–Q0.5 pass
- Gates A–L pass
- Gates N–R pass for the declared scope
- Gate T soak pass
- AppKit, SwiftUI, WKWebView/Electron plus Safari/System Settings/Terminal covered
- at least 20 stop/start cycles
- at least 4 concurrent macOS VMs
- no known release-blocking Virtualization.framework bug on the exact supported host+guest build
- all critical tests performed using the production launchd/headless owner, not only an interactive debug app

The highest-risk unknown remains **host-side framebuffer correctness in production headless/offscreen operation**.

---

## Source references

- `trycua/cua`, `libs/cua-driver/docs/test-matrix.md`
- `trycua/cua`, `libs/cua-driver/tests/runners/macos-lume/README.md`
- `trycua/cua` issue #1162 — silent pointer movement failure in Virtualization.framework VMs
- `trycua/cua` issue #870 — Tahoe capture omits application windows
- `trycua/cua` issue #912 — Tahoe VM compositor investigation
- `trycua/cua` issue #1184 — guest shutdown leaves VM host process running
- `trycua/cua` issue #2696 — `VZMacOSInstaller` dispatch-queue crash
- `chr33s/iso`, `docs/testing.md` — existing real-hardware Apple runtime qualification model
