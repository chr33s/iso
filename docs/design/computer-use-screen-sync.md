# Computer-use screen sync: damage sequence and wait

**Status:** Implemented and qualified on one host (2026-11-10: macOS 27.2
guest 26B131 on a macOS 27.2 Apple Silicon host; §9 measured, Gate W and
Gate U pass). See §12 for where the code differs from this text.
**Date:** 2026-11-10
**Target:** `iso-sandbox` (owner, guest helper `cu-mcp`, `cu` CLI)
**Builds on:** [guest-driven computer use](guest-driven-computer-use.md)
(wire protocol §5.2, limits §5.3, controller §5.4, tools §6.3),
[trust model](../trust-model.md)
**Inspired by:** `tembo/voxl`'s `/wait` endpoint. Nothing here depends on
voxl's code or wire format, and its behavior was not verified for this
record.

## 1. Summary

After an input action an agent cannot tell when the screen has stopped
changing. It either takes a screenshot too early or spends frames polling.
This adds a per-boot **damage sequence** for the VM's display and a **wait**
operation that returns once a region of the screen has been quiet for a
given time.

The change is confined to the existing computer-use paths. It adds no
listener, port, permission, or host-visible window, and no pixels cross a
boundary that they do not cross today.

## 2. Goals and non-goals

**Goals**

- Screenshots and actions report a monotonic `damageSeq`.
- A `wait` operation with `since`, `idleMs`, `timeoutMs`, `until` and
  `region`, for guest and host callers.
- Input tools settle by default, so the usual `click` → `screenshot` pair
  needs no explicit wait.
- No cost while nobody waits.

**Non-goals**

- A continuous capture loop or video. See
  [live view](computer-use-live-view.md).
- ScreenCaptureKit dirty rectangles. The view's window is ordered out, so
  there is nothing on screen to capture, and the owner holds no Screen
  Recording permission by design.
- Linux guests ([separate proposal](linux-desktop-virtio-gpu.md)).

## 3. Damage grid

`DamageGrid` is a pure value type in `IsoSandboxCore/MacOS`, fed whole
frames, so it is unit-testable with synthetic buffers.

- **Geometry.** 16×16-pixel tiles over the fixed 1920×1200 framebuffer:
  120×75 = 9,000 tiles.
- **State.** `seq: UInt64` (starts at 0), `tileSeq: [UInt64]` (the `seq` at
  which each tile last changed), and the previous sample (RGBX, 9.2 MB).
- **Sample.** Each new frame is compared with the previous one tile by tile,
  over every byte of the tile (`memcmp` per tile row). Sampled or strided
  comparison is not used: a missed change would report a false "settled".
  If any tile differs, `seq` increases by one and those tiles take the new
  value.
- **The first sample** sets the baseline and marks nothing dirty.

### On-demand sampling

Nothing samples in the background. `VMScreen` takes a sample:

- on every `frame` (the pixels it is already rendering, before PNG
  encoding);
- immediately before an action sends its first input event;
- on entry to a wait and then on every tick while it runs.

Changes between two samples are attributed to the later one. That is
sufficient because every wait is anchored to a sample: the one before the
action, or the caller's last screenshot. With no waiter the cost is zero.

The sample reuses the existing render in `VMScreen.frame`
(`cacheDisplay` into a 1920×1200 RGBX context) and stops before the
blank-frame check and PNG encoding. A uniform sample is still diffed; it is
never returned to a caller.

`damageSeq` restarts at 0 with each owner boot. A session is bound to the
boot (`CUBinding`), so a value is only ever compared within one binding.

## 4. Wait

`ScreenWait` is a pure state machine: it is fed `(instant, maxTileSeq in
region)` and returns continue or an outcome. `VMScreen` drives it with a
clock and samples, so tests use a fake clock.

| Parameter | Type | Default | Range |
|---|---|---|---|
| `since` | `UInt64?` | the `seq` of the entry sample | ≤ current `seq` |
| `idleMs` | `Int` | 250 | 50–2000 |
| `timeoutMs` | `Int` | 5000 | 100–30000 |
| `until` | `idle` \| `change` | `change` | |
| `region` | `{x, y, width, height}?` | whole screen | inside 1920×1200, `width`, `height` ≥ 1 |

- **`until: idle`** returns once the region has had no change for `idleMs`,
  counted from the later of entry and the last change. If nothing changed
  after `since`, the outcome is `unchanged`.
- **`until: change`** first waits for a tile in the region to exceed
  `since`, then for `idleMs` of quiet.

Outcomes are one enum, not three booleans:

| `outcome` | Meaning |
|---|---|
| `settled` | Changed after `since`, then quiet for `idleMs` |
| `unchanged` | `until: idle` only: quiet for `idleMs`, nothing changed |
| `timedOut` | `timeoutMs` passed first. `damageSeq > since` tells the caller whether anything changed |

The response carries `outcome`, `damageSeq` and `elapsedMs`.

Rules:

- **Tick.** 30 Hz while a wait runs, subject to the measurement in §9. Quiet
  time is measured between samples, so it has one tick of resolution.
- **Caret.** A text caret toggles every ~500 ms. With `idleMs` below that a
  wait settles between toggles; at 500 or above it times out. The default
  stays at 250, and the tool description says so.
- **Content that never settles** (video, spinners) ends in `timedOut`. The
  caller narrows `region` or takes the frame anyway.
- **One wait per sandbox for each caller.** A second concurrent wait from
  the guest is refused `busy`, as is a second from the host. The guest link
  serves two connections, each blocking a thread for the request; this keeps
  one free for `status`. The host's slot is its own, so a guest that waits
  in a loop cannot refuse `cu wait`.
- **Cancellation.** A wait ends at once with the existing refusal when the
  host takes a hold (`held_by_host`) or the session or binding breaks
  (`unknown_session` and the rest). A caller that disconnects is noticed at
  the next write, so a wait is bounded by `timeoutMs` in every case.
- **Host callers** take no hold by waiting, as with frames.

## 5. Wire protocol (vsock 7802)

The channel is guest → host, one JSON object per line, a closed operation
set that refuses unknown fields (`GuestCURequest.parse`). Changes:

- **New operation `wait`.** Requires `session`. New request fields: `since`,
  `idleMs`, `timeoutMs`, `until`, `region`. `region` is closed too (`x`,
  `y`, `width`, `height`, integers). Out-of-range values, an unknown
  `until`, or `since` above the current `seq` are refused `invalid_action`.
- **`frame` and `act` responses** gain `damageSeq`. For `act` it is the
  value sampled before the first input event.
- **`wait` response** gains `wait: {outcome, elapsedMs}` and `damageSeq`.
- **`status` response** gains `damageSeq`. Its presence is how the guest
  helper learns that the host supports `wait`.

Rate limits: a `wait` costs one action token. Samples cost no frame tokens
because their pixels never leave the owner.

### Version skew

The MCP server lives in the guest template and the owner on the host, so
they can differ.

| Host | Helper | Behavior |
|---|---|---|
| new | old | The helper sends no new operation. It must ignore the new response fields: confirm with a test that the released helper's decoder does |
| old | new | `status` has no `damageSeq`. The helper sends no `wait`, omits `settle_ms` handling, and `wait_for_screen` returns "not supported by this host" |

## 6. MCP tools (`iso-cu`)

- **`screenshot`**: the text part gains `damageSeq`.
- **`click`, `move`, `drag`, `scroll`, `key`, `type`**: a new optional
  `settle_ms` (default 250, 0 disables, maximum 2000). When it is above 0
  the helper sends `act`, then `wait` with `since` = the action's
  `damageSeq`, `until: idle`, `idleMs: settle_ms`, `timeoutMs: 3000`. The
  result reports `damageSeq` and the outcome. An action that changes
  nothing returns after `settle_ms`, not after the timeout.
- **`wait_for_screen`** (new): `since`, `idle_ms`, `timeout_ms`, `until`,
  `region`, and `include_screenshot` (default true). The screenshot is a
  separate `frame` request by the helper and counts against the frame rate.
  If that is refused `rate_limited`, the tool returns the wait result alone
  and says so.

`frameId` is unchanged: an action still names the screenshot it was decided
on.

## 7. Host CLI

`iso-sandbox macos cu frame` and `cu act` print `damageSeq`. A new
`iso-sandbox macos cu wait <name> --session … [--since N] [--idle-ms N]
[--timeout-ms N] [--until idle|change] [--region x,y,w,h]` runs the same
wait over the control socket.

## 8. Trust-model delta

| Item | Change |
|---|---|
| Listeners, ports, network, VM configuration, isolation gate | None |
| Host permissions | None |
| Guest → host input | One more operation in the closed set; five more fields, each bounded and validated before use |
| Host → guest data | `damageSeq`, an outcome enum and a duration: fixed-shape metadata about the guest's own display |
| Host resources a guest can consume | One guest wait at a time per sandbox, at most 30 s, sampling at the tick rate; one retained 9.2 MB frame |
| Logging and audit | Counters only (`waits`, outcomes by kind). No region, coordinates or pixels |

Nothing here is on the stop-and-confirm list. `docs/trust-model.md` ("Guest
computer use") changes from "four-operation set" to five.

## 9. Open measurement

Before the tick rate is fixed, measure on the supported hardware:

1. The cost of one sample (render plus diff) at 1920×1200. Target: under
   8 ms on the main actor. If it is higher, lower the tick to 10 Hz and
   raise the minimum `idleMs` to 200.
2. A static guest screen sampled for 60 s reports zero dirty tiles. If the
   rescale in `VMScreen.frame` is not deterministic, diff the unscaled
   bitmap instead.

## 10. Testing

- **`DamageGrid`**: one changed byte dirties exactly its tile; tiles on the
  right and bottom edges; identical frames leave `seq` alone; `seq` never
  decreases.
- **`ScreenWait`** with a fake clock: a 600 ms animation followed by quiet
  settles about `idleMs` later; a 500 ms caret with `idleMs: 250` settles;
  the same caret with `idleMs: 500` times out; `until: idle` with no change
  returns `unchanged` after `idleMs`; a change outside `region` is ignored.
- **Protocol**: unknown fields in `region` are refused; out-of-range values
  are refused; a second wait is `busy`; a hold during a wait returns
  `held_by_host`.
- **Fault injection** (`scripts/swift-host-fault-injection.py`): region
  bounds check removed; hold no longer cancels a wait; the one-wait limit
  removed.
- **Qualification** (`tests/macos-guest-qualify.py`): a fixture with a
  600 ms transition; `click` then `wait_for_screen` returns one settled
  frame.

## 11. Acceptance

1. `click` on a control that starts a 600 ms transition, then
   `wait_for_screen(idle_ms: 250)`, returns `settled` between 850 ms and
   1100 ms with a higher `damageSeq`.
2. `move` over static content with the default `settle_ms` returns
   `unchanged` in under 400 ms.
3. A focused text field with a blinking caret does not time out at the
   default `idle_ms`.
4. With no wait in flight the owner takes no samples.

## 12. Implementation notes

The code is `DamageGrid`, `ScreenWait` and `VMScreen.wait` in
`iso-sandbox/Sources/IsoSandboxCore` and the wire types and tools in
`IsoGuestCU` (tests: `MacScreenSyncTests.swift`; faults `macos-cu-wait-*` in
`scripts/swift-host-fault-injection.py`). The guest boundary is in the
[trust model](../trust-model.md#macos-guests) ("Guest computer use"), the
audit fields in [audit](../audit.md) and the tools in
[configuration](../configuration.md). Where the build departs from or
settles the proposal above:

- **Tick.** 30 Hz (`ScreenWait.tickMs`), kept after §9.
- **§9 results** (one macOS 27.2 host). Caching the view at the window's
  2× backing scale and rescaling cost ~75 ms a sample, so `VMScreen` caches
  straight into a 1920×1200 bitmap: about 6 ms a sample (cache, draw,
  diff), under the 8 ms target. A static screen sampled for 60 s gave zero
  dirty tiles below the menu-bar clock.
- **Memory.** Two framebuffer-sized buffers, not one: the previous sample
  and a render context reused for every sample.
- **Anchoring.** A guest wait is anchored to its entry sample; quiet time
  counts from entry.
- **Live view.** A [live view](computer-use-live-view.md) viewer's sampling
  feeds the same `DamageGrid`, so §11 item 4 holds only with no viewer.
- **§11 results.** Gate W (`tests/macos-guest-qualify.py`) passes items
  1–3 through the guest's MCP server; its times include the SSH round
  trip. Item 4 was checked once with an instrumented owner; nothing outside
  the owner can observe it.

**Open:** the measurement has run on one host only and is worth repeating
on a slower Apple Silicon machine.
