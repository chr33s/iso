# Linux-guest computer use: sketch

**Status:** Proposal (not implemented)
**Date:** 2026-10-05
**Target:** `chr33s/iso` Ubuntu guests on the Apple sandbox backend
**Depends on:** [macOS computer-use Q0 spike](macos-computer-use-q0-spike.md),
[trust model](../trust-model.md)

> Computer use for Linux apps (browsers, Electron, desktop tools), using the
> existing iso-sandbox VMs. macOS-guest computer use stays a separate, later
> track; the Q0 spike records what it would cost.

## Shape

The display lives inside the guest. A virtual X server (Xvfb) provides a fixed
1920×1200×24 framebuffer, a minimal window manager manages windows, and input
enters through the X input-test extension (XTEST). The host keeps the
iso-sandbox VM unchanged: no graphics device, no host window, no new socket
relay, port or network mode, and nothing that depends on the host login or
lock state.

```text
 guest VM (untrusted, unchanged boundary)
 ┌──────────────────────────────────────────────────────────┐
 │ Xvfb :1 ─ window manager ─ apps (browser, fixtures)      │
 │    ▲ XTEST input     │ XGetImage frames                  │
 │ iso-cu (guest helper: frame / act / state)               │
 │    ▲                                                     │
 │ agent's computer-use loop (mode A)                       │
 └────┼─────────────────────────────────────────────────────┘
      │ pinned SSH, RemoteCommand argv (mode B and tests only)
 host: iso / harness — validates and encodes frames, binds sessions
```

### Two operating modes

- **A. In-guest loop (default).** The agent's computer-use tool loop runs in
  the guest, next to the display, like every other agent action today. Frames
  and actions never cross the VM boundary. Model access goes through the
  existing credential proxy. iso's work is limited to building the image and
  managing the lifecycle. This adds **no host channel**.
- **B. Host-driven.** A host process observes and acts through the guest
  helper over the pinned SSH channel. It is needed for the Q0 oracles and for
  a host-side tool loop. It adds one bounded guest→host channel (frames) and
  one host→guest channel (actions), specified below.

Ship mode A first. Use mode B for qualification, and expose it only if a
host-side loop is needed.

## Guest image

A `desktop` profile on the Ubuntu 24.04 template:

- `xvfb`, a minimal window manager (`openbox`), `x11-xserver-utils`,
  `xdotool` / `libxtst6`, `fonts-dejavu`, `fonts-noto-core`, `dbus-x11`.
- A browser from a non-snap apt source. Ubuntu 24.04's `chromium` and
  `firefox` packages are snap shims, and snapd is not usable in the sandbox.
  Pin the source and key like the existing NodeSource and Docker repositories.
- `iso-cu`, a guest helper (a static binary or a Python script on the image),
  and `systemd --user` units for `Xvfb :1` and the window manager, started at
  login for the guest user with `DISPLAY=:1`.
- Fixtures for qualification only, not in the default profile: a Tk or GTK
  app with the spike's render, grid and keys modes, plus an Electron/Chromium
  page fixture.

## Guest helper (`iso-cu`)

Invoked per operation with an argv built by `RemoteCommand`. It is not a
listener and not a daemon.

| Operation | Input | Output |
|---|---|---|
| `state` | none | JSON: guest `boot_id`, X server PID and start time, screen geometry, damage sequence |
| `frame` | none | the raw frame below on stdout |
| `act` | one action as JSON on stdin | JSON: `ok` plus the X server request serial after `XSync` |
| `type` | UTF-8 text on stdin (bounded) | JSON ack |

Actions are `move`, `click{button,count}`, `down`/`up`, `drag{path}`,
`scroll{dx,dy}` and `key{keysym, modifiers}`. Keysyms come from a fixed
allowlist. Arbitrary text goes only through `type` on stdin, never through
argv. Every action carries the session token and is refused on any mismatch.
`act` releases every button and modifier it pressed if it is interrupted.

## Frame channel (mode B)

The frame is guest-authored, so it is a taint source. The host never hands it
to a general image parser:

```text
"ISOF" u8 version=1  u32 width  u32 height  u32 stride  u64 damage_seq  u8 format=BGRX
<height * stride bytes>
```

The host requires an exact header match, width and height equal to the
session geometry, `stride == width*4`, an exact total length (1920×1200×4 ≈
9.2 MB, capped) and a deadline. Anything else fails closed. The host builds
the image from the validated buffer itself (PNG for the model or evidence).
It also refuses uniform frames, as the spike's guard does, and frames whose
`damage_seq` went backwards.

## Session binding

A session is bound to all of the following. Any change refuses every pending
and later action:

- the host-generated runtime `live.bootId` (protocol 5) and the owner
  identity: host-anchored, so the guest cannot forge them;
- the guest `/proc/sys/kernel/random/boot_id` and the X server PID and start
  time: guest-reported, so they can only invalidate a session, never
  validate one;
- the geometry.

This is the same pattern as boot-bound egress supervision.

## Trust-model delta

| Item | Change |
|---|---|
| VM configuration, isolation gate, network, relays, ports | None |
| New image content | `desktop` profile packages and a pinned browser repository (build-time trust, like the existing installers) |
| Guest→host data (mode B) | Raw frame and helper JSON: bounded, fixed format, validated before use; never parsed by a third-party decoder; never logged |
| Host→guest commands (mode B) | `RemoteCommand` argv, allowlisted keysyms, text via stdin only |
| Host permissions | None: no Screen Recording, no Accessibility, no host window |
| Prompt injection via screen content | Out of iso's boundary in mode A (the agent is already untrusted in the guest). In mode B the host loop must treat model output as untrusted and only map it to guest actions. |

Mode B adds a guest→host channel, which is on the stop-and-confirm checklist.
It needs explicit review before it ships.

## Q0, restated for Linux

| Cell | Linux form | Oracle |
|---|---|---|
| Q0.1 rendered window | Tk fixture draws a random token and barcode; host decodes the raw frame | Barcode decode on the host, plus a fixture-reported window rect over SSH |
| Q0.2 headless | Host locked, host logged in, owner under launchd: expected to be irrelevant, so run once to prove it | Same as Q0.1 |
| Q0.3 absolute click | 1,000 XTEST clicks on the 10×10 grid | Fixture logs the target cell and position; XTEST serial ack |
| Q0.4 keyboard | The spike's 176-event sequence as keysyms with modifiers | Fixture event log; `xdotool getactivewindow` and `xinput` show no stuck modifiers |
| Q0.5 reboot identity | Guest reboot and owner restart | Session refused on `live.bootId`, guest `boot_id` or X-server change; a new session works |

The spike's harness carries over: the driver, oracles, barcode decoder and
grid/key scripts. Only the owner side changes, from a Virtualization.framework
view to `iso-cu` over SSH.

## Plan gates

Gone or mostly not applicable: A (Virtualization.framework macOS queueing),
B (macOS install and provisioning; replaced by the image build), D (host
offscreen/headless), R (macOS login UI), the macOS concurrency limit, and the
paravirtualized-GPU exposure in O.

Still needed in Linux form: C (framebuffer correctness, simpler with Xvfb), E,
F (fixed geometry), G, H, I (the helper protocol instead of vsock), J and K–N
(inherited from the existing backend's qualification), P, Q (Linux app tiers)
and T.

## Open questions

- Whether a guest reboot in place renews `live.bootId`, or only an owner boot
  does. If only an owner boot does, the guest `boot_id` is the reboot signal.
- Whether the browser needs `--no-sandbox` inside the VM (it should not: user
  namespaces are available in the guest), and its GPU flags under software
  rendering.
- Per-frame latency over SSH (about 9 MB per frame). A persistent
  `ssh -o ControlMaster` channel with the helper in a streaming mode may be
  needed to meet Gate S. Measure before optimizing.
