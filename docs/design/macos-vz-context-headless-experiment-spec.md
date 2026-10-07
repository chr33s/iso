# Experiment Spec: macOS VM Process Context, Headless Display, and Virtual HID

**Repository:** `chr33s/iso`  
**Date:** 2026-10-06  
**Status:** proposed real-hardware experiment  
**Target:** Apple Silicon host, macOS 27+ host and macOS guest  
**Primary decision:** determine the minimum host process/session/UI context required to run a macOS `VZVirtualMachine` and expose reliable computer-use observation + input.

## 1. Questions

### Q1 — VM ownership

Can a macOS `VZVirtualMachine` reliably start, run, stop, and restart in each context?

1. Interactive process in a logged-in user session.
2. `user/$UID` background launchd job — current `iso-sandbox` model.
3. `gui/$UID` LaunchAgent.
4. System LaunchDaemon as root.
5. System LaunchDaemon with `UserName` set to a non-root standard user.
6. System LaunchDaemon with `UserName` before that user has logged in.

### Q2 — computer-use UI

What host GUI state is required for `VZVirtualMachineView`-based observation and keyboard/pointer delivery?

Test whether a view:

- needs an `NSWindow`;
- needs the window visible;
- needs it key/focused;
- works while occluded;
- works on an inactive Space;
- works minimized;
- works hidden or offscreen;
- works with the host screen locked;
- can produce capturable pixels without a visible window;
- can receive synthetic input without moving the host cursor or stealing host focus.

Q1 and Q2 must be evaluated independently.

---

## 2. Apple-documented controls

Treat these as established by Apple documentation:

- The VM-owning process needs the `com.apple.security.virtualization` entitlement.
- `VZVirtualMachine` can use a specific dispatch queue.
- VM lifecycle/state is exposed through `VZVirtualMachine`.
- macOS guests use `VZMacPlatformConfiguration`.
- Graphics, keyboards, pointing devices, sockets, network, and storage are configured on `VZVirtualMachineConfiguration`.
- Apple's documented graphical interaction path is `VZVirtualMachineView`.
- `VZVirtualMachineViewAdaptor` bridges a VM on its VM queue to a view on the main actor.
- `VZMacGraphicsDisplayConfiguration` configures a display shown in `VZVirtualMachineView`.

Apple's Virtualization documentation does **not** establish these as requirements:

- Aqua session;
- logged-in console user;
- unlocked login keychain;
- visible `NSWindow`;
- LaunchAgent instead of LaunchDaemon;
- non-root execution;
- automatic login.

Those are experiment hypotheses.

Official references:

- https://developer.apple.com/documentation/virtualization
- https://developer.apple.com/documentation/virtualization/vzvirtualmachine
- https://developer.apple.com/documentation/virtualization/vzvirtualmachineview
- https://developer.apple.com/documentation/virtualization/vzvirtualmachineviewadaptor
- https://developer.apple.com/documentation/virtualization/vzmacgraphicsdisplayconfiguration
- https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project

---

## 3. Current `iso` baseline

`iso-sandbox` currently supervises each VM owner in:

```text
user/<uid>
LimitLoadToSessionType = Background
```

The dynamically generated plist is stored in sandbox state and written mode `0600`.

Preferred outcome: macOS guests preserve this ownership model. Move to a GUI domain only if the experiment proves it necessary.

Relevant source:

```text
iso-sandbox/Sources/IsoSandboxCore/Launchd.swift
```

---

## 4. Hypotheses

### H1 — runtime is GUI-independent

A macOS `VZVirtualMachine` starts and operates from `user/$UID` background launchd ownership without a `VZVirtualMachineView`.

**Preferred:** pass.

### H2 — root is unnecessary

Running the VM as root provides no required capability.

**Preferred:** non-root ownership works reliably.

### H3 — pre-login runtime may work

A preinstalled VM can start before GUI login from a system LaunchDaemon running as a standard user through `UserName`.

This is a hypothesis only.

### H4 — GUI context may be needed only for the view

The VM remains headless while display/input requires a `gui/$UID` AppKit helper.

This is an acceptable result.

### H5 — visible/focused window is not required

Computer use works without a visible focused host window.

A requirement for a visible focused host window is a failure for the proposed production architecture.

---

## 5. Hardware and host setup

Use a dedicated Apple Silicon Mac with no production secrets.

Record:

```text
host model / SoC
RAM
host macOS version + build
Xcode version
SDK version
probe build hash
guest macOS version + build
```

Create a dedicated standard host account:

```text
iso-vz-test
```

Do not sign it into iCloud or production accounts.

Probe entitlement starts with:

```text
com.apple.security.virtualization
```

---

## 6. Test VM

### 6.1 Use a preinstalled guest first

Do not start with `VZMacOSInstaller`.

Create one known-good guest under the interactive baseline and persist:

```text
hardware model
machine identifier
auxiliary storage
main disk
display configuration
network configuration
```

Use that same VM identity across process-context tests.

This isolates process/session behavior from installation behavior.

### 6.2 Guest setup

Initial configuration:

- one fixed display;
- fixed geometry, e.g. 1440×900;
- automatic display reconfiguration disabled;
- one network device;
- one keyboard;
- one absolute-coordinate pointing device;
- optional virtio socket;
- SSH enabled;
- test user auto-logged in for GUI phases;
- guest sleep/lock disabled.

Use CPU/RAM values supported by the restore image rather than imposing a value below Apple's requirements.

---

## 7. Guest fixture

Install a small AppKit test application.

Visible content:

```text
random run token
frame counter incrementing every 250 ms
10x10 clickable grid
text field
key/modifier event display
drag target
scroll region
```

Each grid cell has a unique ID.

The fixture atomically writes:

```text
~/Library/Application Support/IsoVZProbe/state.json
```

Example:

```json
{
  "run_token": "7cd9...",
  "frame_counter": 1842,
  "last_clicked_cell": "G07",
  "received_text": "hello",
  "keys_down": [],
  "drag_target": "D04"
}
```

The host reads this via SSH as an independent oracle.

---

## 8. Host probe program

Create a standalone Swift experiment target, not production code:

```text
experiments/macos-vz-context-probe/
```

Suggested commands:

```text
vz-context-probe report-context
vz-context-probe vm-run
vz-context-probe vm-view
```

Output JSONL.

At startup record:

```text
pid / ppid
uid / euid / gid
HOME
whether user/$UID exists
whether gui/$UID exists
virtualization support
VM validation result
```

### Keychain diagnostic rule

Keychain state is metadata only.

Do not:

- make it a primary pass condition;
- auto-unlock it in baseline tests;
- put passwords in plists, argv, logs, or repository files.

Only test keychain correlation later if pre-login VM start fails.

---

# 9. Phase 1 — VM ownership context

## Context matrix

| ID | Context | Host login state |
|---|---|---|
| C0 | Interactive Terminal | logged in/unlocked |
| C1 | `user/$UID` + `Background` | logged in |
| C2 | `gui/$UID` LaunchAgent | logged in |
| C3 | system LaunchDaemon, root | no login requirement |
| C4 | system LaunchDaemon + `UserName=iso-vz-test` | logged in |
| C5 | system LaunchDaemon + `UserName=iso-vz-test` | cold boot, user never logged in |

C0 is the positive control.

C1 is the preferred `iso` architecture.

C2 is the fallback.

C3-C5 establish technical feasibility only.

## No-view procedure

For each context:

1. create VM configuration;
2. validate it;
3. construct `VZVirtualMachine` on an explicit serial queue;
4. do not instantiate `VZVirtualMachineView`;
5. start;
6. observe state;
7. wait for guest network;
8. wait for SSH;
9. read guest build/fixture state;
10. request graceful stop;
11. require stopped state;
12. exit owner cleanly.

### Pass

- validation succeeds;
- start succeeds;
- VM reaches running;
- guest independently becomes reachable;
- stop succeeds;
- no SIGTRAP/crash/deadlock;
- owner exits cleanly.

### Repetition

Development:

```text
10 runs per cell
```

Qualification:

```text
100 start/stop cycles for every context intended for support
```

---

# 10. Phase 2 — host session transitions

For Phase-1 contexts that pass, test:

| ID | Host state |
|---|---|
| S0 | logged in/unlocked |
| S1 | screen locked |
| S2 | display asleep |
| S3 | wake from display sleep |
| S4 | fast-user-switch away |
| S5 | switch back |
| S6 | host sleep/wake if intended |

For VM runtime only, verify:

```text
VM state
SSH
owner process
boot identity
stop behavior
```

Do not mix graphical view behavior into this phase.

---

# 11. Phase 3 — `VZVirtualMachineView` topology

Start in `gui/$UID`.

Use `VZVirtualMachineViewAdaptor` when appropriate.

Set:

```text
automaticallyReconfiguresDisplay = false
```

## View/window matrix

| ID | Topology |
|---|---|
| V0 | visible window, key/focused |
| V1 | visible window, not key |
| V2 | visible but fully occluded |
| V3 | window on inactive Space |
| V4 | minimized |
| V5 | hidden / ordered out |
| V6 | fully offscreen |
| V7 | view retained but unattached to `NSWindow` |
| V8 | no view |

The objective is to find the least-visible topology that still supports correct observation/input.

---

# 12. Observation tests

Apple does not document a raw framebuffer callback for `VZVirtualMachineView`, so test observation mechanisms explicitly.

## O1 — AppKit view capture

Attempt capture using supported AppKit view rendering/caching mechanisms.

Record:

```text
capture success
image dimensions
frame hash
fixture token present
frame counter freshness
```

If GPU content is absent, mark O1 unsupported. Do not call the VM display broken based on O1 alone.

## O2 — ScreenCaptureKit diagnostic control

For window-backed topologies, use a separate signed host diagnostic app with Screen Recording permission to capture the VM window/display.

This is a diagnostic control, not automatically the production design.

It answers:

> Is the VM content rendered by WindowServer even if AppKit snapshotting cannot access it?

## Observation oracle

For each capture:

1. SSH-read fixture token/counter;
2. capture host-side image;
3. verify known fixture pattern/token;
4. wait 500 ms;
5. capture again;
6. require fresh counter/pixel change.

### Qualifying result

A topology qualifies only if:

- application pixels are present;
- token matches current guest;
- frames refresh;
- no black/desktop-only/stale result;
- at least 1,000 consecutive captures succeed.

---

# 13. Virtual HID/input tests

Primary input path should not inject global host events.

Construct synthetic `NSEvent` objects and exercise the `VZVirtualMachineView`/`NSResponder` path under test.

Before/after every batch record:

```text
host frontmost app
host key window
host cursor position
```

Unintended host cursor movement or focus theft is a failure unless explicitly accepted.

## 13.1 Absolute pointer

Using the 10×10 fixture grid:

1. choose random cell;
2. derive coordinate from observed framebuffer;
3. inject move/click;
4. read `last_clicked_cell` via SSH;
5. compare.

Development:

```text
1,000 randomized clicks
```

Qualification:

```text
10,000 randomized clicks
```

Require:

```text
0 wrong-target clicks
0 silent-success mismatches
```

## 13.2 Pointer coverage

Test:

- move;
- left/right/double click;
- down/up;
- drag;
- long drag;
- scroll;
- edges/corners.

## 13.3 Keyboard

Test:

```text
letters
digits
punctuation
Shift / Control / Option / Command
Return / Tab / Escape
arrows
delete / backspace
Cmd-S
Cmd-Q
Cmd-Tab if claimed
```

Require:

- exact event ordering;
- no stuck modifiers;
- complete key-up pairs;
- guest receives events;
- host app receives none.

---

# 14. Phase 4 — computer use across host session changes

Take the best non-visible topology from Phase 3.

Test during:

1. lock;
2. unlock;
3. inactive Space;
4. fast-user-switch;
5. display sleep/wake;
6. host sleep/wake if supported.

Record independently:

```text
VM running
SSH alive
frame fresh
pointer correct
keyboard correct
host focus unchanged
```

A valid documented result may be:

```text
VM runtime works while locked
computer-use display/input unavailable while locked
```

provided it is deterministic.

---

# 15. Phase 5 — cold boot / no login

This directly tests the claims about login/session/Secure Enclave/keychain dependence.

Use a disposable test host.

Procedure:

1. configure C3 and C5;
2. fully shut down;
3. power on;
4. do not log into any GUI account;
5. allow job to attempt VM start;
6. retrieve logs through independent administration if available;
7. determine whether guest reaches SSH;
8. only then log into host for inspection.

Do not:

- auto-login;
- auto-unlock keychain;
- create a GUI session before recording result.

Record:

```text
validation result
start result
VZ error domain/code
owner exit status
system log excerpt
guest SSH reached: yes/no
```

Do not infer "keychain" or "Secure Enclave" solely from human-readable error text.

---

# 16. Phase 6 — keychain correlation diagnostic

Run only if C5 fails.

Compare:

```text
D0  no GUI login, default keychain state
D1  same process context after manual test-keychain unlock
D2  same user after one GUI login, then locked
D3  gui/$UID LaunchAgent after login
```

This is empirical correlation, not proof of an Apple API contract.

---

# 17. Phase 7 — installer context

Only after runtime ownership is understood, test `VZMacOSInstaller`.

Primary intended control:

```text
interactive `iso setup --guest macos`
```

Require:

- installer created/driven on the correct VM queue;
- progress behaves coherently;
- failed install never publishes a template;
- five clean installs succeed.

Do not require all runtime-owner contexts to support installation unless the product intends that.

---

# 18. Evidence

Each run writes:

```text
results/<run-id>/
  metadata.json
  context.json
  vm-events.jsonl
  host-session-events.jsonl
  capture-events.jsonl
  input-events.jsonl
  owner.stdout.log
  owner.stderr.log
  guest-state/
  screenshots/
```

Result schema:

```json
{
  "run_id": "...",
  "context": "C1",
  "session_state": "S0",
  "view_topology": "V7",
  "vm_runtime": "pass",
  "observation": "pass",
  "pointer": "pass",
  "keyboard": "pass",
  "failure_code": null
}
```

Statuses:

```text
pass
fail
not_supported
environment_error
not_run
```

Missing tests are never passes.

---

# 19. Secret/privacy rules

Do not collect:

- passwords;
- Keychain contents;
- provider credentials;
- SSH private keys;
- unrelated screenshots of the operator desktop.

Use only synthetic guest content.

---

# 20. Decision table

## A — ideal

```text
C1 runtime passes
non-visible V5/V6/V7 observation passes
HID works without host focus
lock behavior acceptable
```

Keep current-style background ownership.

## B — split architecture

```text
C1 runtime passes
view/HID requires gui/$UID
```

Keep background lifecycle if possible and introduce a GUI-session computer-use component, subject to a safe ownership/IPC design.

## C — GUI owner required

```text
C1 fails
C2 passes reliably
```

macOS guests require a logged-in GUI-domain owner.

Linux keeps current background ownership.

## D — pre-login runtime works

```text
C5 passes
```

A system LaunchDaemon with `UserName` is technically viable for lifecycle on the tested build, but should only be adopted if it is operationally/security-wise better than C1/C2.

## E — root fails, user succeeds

Do not run macOS VM owners as root.

Record exact failures; do not generalize beyond tested OS builds.

## F — visible/focused window required

```text
only V0 is reliable
```

Reject `VZVirtualMachineView` as the production computer-use path.

Evaluate guest-side display/input streaming or standard remote desktop. Virtual HID may remain useful for setup/login/recovery.

---

# 21. Minimum go/no-go sequence

Run in this order:

```text
E0  C0: preinstalled VM starts/stops, no view
E1  C1: current user/$UID Background owner starts/stops, no view
E2  C5: pre-login non-root LaunchDaemon test
E3  V0: visible VZ view shows fresh guest pixels
E4  V7: unattached-view capture test
E5  V5/V6: hidden/offscreen-view test
E6  1,000 random absolute clicks, 0 wrong targets
E7  keyboard/modifier exactness
E8  lock/unlock behavior
E9  reboot invalidates prior computer-use session
```

Stop and redesign before integration if:

- E1 fails and only root works;
- no host-side observation works without a visible focused window;
- input requires moving/focusing the host UI;
- clicks can silently land on wrong targets;
- framebuffer freshness cannot be independently proven.

---

# 22. Architecture acceptance bar

Approve background-owner + host-side computer use only if:

1. C1 passes 100 start/stop cycles.
2. One non-visible topology passes 1,000 fresh captures.
3. 10,000 randomized pointer actions yield zero wrong targets.
4. Keyboard tests yield zero stuck/leaked modifiers.
5. Host focus/cursor remain unchanged.
6. Supported host-session transitions are deterministic.
7. Old computer-use sessions fail after reboot/replacement.
8. The result reproduces on the exact host/guest build intended for release.

Report failures by layer:

```text
VM runtime
AppKit/view
observation
HID
host session transition
identity/session binding
```

Do not conclude broadly that "headless Virtualization.framework does not work" when only one layer fails.

---

# 23. Relationship to broader qualification

This is the **architecture-selection spike** that precedes the full macOS computer-use qualification plan.

It must establish:

- owner process context;
- view/window topology;
- observation path;
- input path;
- host session limitations.

Only then should broader application/network/storage/security qualification begin.
