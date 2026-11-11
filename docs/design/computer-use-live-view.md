# Computer-use live view and browser takeover

**Status:** Implemented. The listener in §5 was approved under
stop-and-confirm on 2026-11-10. The §3 spike and §9 acceptance ran on one
host on 2026-11-10. See §11.
**Date:** 2026-11-10
**Target:** `iso-sandbox` (owner, `cu` CLI), `iso` (isolation gate, audit)
**Builds on:** [screen sync](computer-use-screen-sync.md) (`DamageGrid`),
[guest-driven computer use](guest-driven-computer-use.md) (§5.4 controller),
[macOS runtime design](macos-guest-computer-use.md),
[trust model](../trust-model.md)
**Inspired by:** `tembo/voxl`'s single-WebSocket H.264 viewer. Compatibility
with voxl's framing or client is not a requirement, and its behavior was
not verified for this record.

## 1. Summary

A macOS guest's display lives in an ordered-out window, so an operator
cannot watch an agent work or step in without the `cu` CLI. This proposes
an opt-in, per-VM live view: the owner encodes the display to H.264 with
VideoToolbox and serves it to a browser on host loopback, with a "Take
control" mode that uses the existing host hold.

This reverses one non-goal of
[guest-driven computer use](guest-driven-computer-use.md) §2 ("Video
streaming"). The reversal covers human viewers only: agents keep polled
PNG frames.

## 2. Goals and non-goals

**Goals**

- Watch a macOS guest from a browser on the same Mac, with nothing to
  install.
- Take control from the browser, with the same precedence rules as
  `cu hold`.
- No cost when no viewer is connected.

**Non-goals**

- Remote viewing through `iso host`. A tunnel turns this into remote input
  to a VM; it needs its own review.
- Clipboard sharing in either direction. The VM has no clipboard device and
  the isolation gate refuses one.
- A fixed 60 fps promise. The rate comes out of §3.
- Linux guests ([separate proposal](linux-desktop-virtio-gpu.md)).

## 3. Gate: capture spike

Frames today are pulled one at a time (`VMScreen.frame`: `cacheDisplay`,
a rescale, PNG). There is no capture loop, and its cost at video rates is
unknown. Before any other work:

| Question | Method | Pass |
|---|---|---|
| S1. Cost of a BGRA frame from the ordered-out view | `cacheDisplay` at 10, 30 and 60 Hz on the main actor for 60 s, guest idle and guest playing video | Owner CPU and main-actor stall per frame recorded; `cu act` latency unchanged within 10 % |
| S2. A cheaper source | Whether the view's layer exposes an `IOSurface` through public API | Recorded. Private API is a rejection, not an option |
| S3. Encoder | `VTCompressionSession` at 1920×1200 from those frames | Encode time per frame; hardware encoder confirmed in use |

ScreenCaptureKit is rejected without a spike: the window is never on a
screen, and the owner holds no Screen Recording permission by design.

The frame-rate cap and the idle-cost criterion in §9 are set from these
results. If S1 fails at 10 Hz, this proposal stops.

## 4. Pipeline

- **Sampling runs only while a viewer is connected.** It is adaptive:
  the cap from §3 while `DamageGrid` saw damage in the last second or the
  viewer sent input, falling to 2 Hz on a static screen. With no viewer
  there is no sampling and no compression session.
- **Encoding.** One `VTCompressionSession` per stream: H.264 Main,
  automatic level, real time, no frame reordering. A frame is submitted
  only when `DamageGrid` reports damage, or as a forced keyframe when a
  viewer joins. Output is converted from AVCC to Annex-B with SPS/PPS
  before each keyframe.
- **Pixels.** The stream is encoded by the owner from the view's bitmap, as
  PNG frames are. The browser never receives guest-authored bytes.
- **Backpressure.** Each viewer has a bounded queue (8 MiB). On overflow the
  owner drops that viewer's frames up to the next keyframe, and asks for
  that keyframe once, when the viewer's queue has drained: the encode is
  shared, so asking on every overflow would make every frame a keyframe
  for every viewer while one is behind. Pongs and state text are never
  dropped, so a viewer whose queue they would overfill is disconnected. A
  viewer that stops reading for 10 s is disconnected.

## 5. Listener (stop-and-confirm)

This adds a host network listener, so it needed explicit approval under
[AGENTS.md](../../AGENTS.md). It was approved on 2026-11-10 as an opt-in,
per-start `127.0.0.1` listener on an ephemeral port, gated by a 256-bit
token carried in the URL fragment, with exact `Host` and `Origin` checks
before the token is read, iso's own embedded page, and bounded connections,
viewers and client messages. The authoritative rules and limits are in
[trust model: Live view (`cu stream`)](../trust-model.md#macos-guests).

## 6. Takeover

Control uses `CUControl` as it is. No new state or refusal is added.

- A viewer starts **view-only**; its input messages are dropped.
- **Take control** calls `VMScreen.hold(seconds: CUControl.implicitHold)`
  (60 s). This ends the guest's session, as any host hold does: the guest
  gets `held_by_host` and opens a new session afterwards.
- **Each input event** extends the hold to 60 s from now.
- **Release** calls `VMScreen.releaseImplicitHold()`: it ends the hold
  viewers and host input take, and a `cu hold` taken from the CLI runs on.
  Only `cu release` ends that one.
- **A closed tab** releases nothing. The hold expires within 60 s, so a
  viewer can never hold a display indefinitely, and a longer `cu hold`
  taken from the CLI is left alone.

## 7. Input

`CUActionRequest` models whole actions (`click`, `drag`, a key chord). A
viewer sends raw events, so this needs a second, equally closed path into
`VMScreen`:

| Message | Fields | Validation |
|---|---|---|
| `pointer` | `kind` (`move`, `down`, `up`), `x`, `y`, `button` | Framebuffer pixels in range; button enum |
| `scroll` | `x`, `y`, `dx`, `dy` | In range; deltas bounded |
| `key` | `kind` (`down`, `up`), `code` | `KeyboardEvent.code` looked up in a fixed table of Mac virtual key codes; anything else is dropped |
| `text` | `text` | The existing `type` rules: ASCII, at most 2000 characters (each may take two bytes of JSON, and a message is at most 4 KiB) |
| `control` | `take` \| `release` | |

- **Paste** is the `text` message: the page reads the browser's paste event
  and the owner types it. The owner never touches `NSPasteboard`, and
  nothing flows from the guest to the host clipboard. A paste takes 12 ms a
  key event, so a long one runs for over a minute: it is typed apart from
  the viewer's connection, each key is sent only while that viewer still
  controls and extends its control as any input does, and a release, a
  disconnect, a lapse or a stream stop ends it and lets go of what it
  pressed. A second paste while one is being typed is refused `busy`.
- **Ordering.** Viewer input is refused `busy` while a host `cu act` is in
  flight, except a key or button up: the browser has already let go, so a
  refused up would leave it down in the guest. A guest action in flight is ended by the hold, which already
  releases what it pressed.
- **Stuck input.** The owner tracks the buttons and keys a viewer holds
  down and releases them on release, disconnect, hold expiry and stream
  stop.
- Events are synthesized into the view in-process, as today. Nothing is
  posted to the host event system.

## 8. Trust-model delta

| Item | Change |
|---|---|
| Host listeners | **New:** one loopback TCP listener per streaming VM, opt-in, token-gated, self-expiring |
| Guest → host data | None new. The stream is host-encoded from the same bitmap as frames |
| Host → guest input | A second closed input set, from an authenticated local browser |
| Host clipboard, files, other VMs | None |
| Host permissions | None |
| VM configuration | None |
| `inspect` and the isolation gate | `inspect` reports whether a stream is listening. `IsolationGate.verifyMacEffective` must accept the new field explicitly; unknown fields still fail closed |
| Audit | Per-boot counters: streams started, viewers, takeovers, input events. No token, pixels, coordinates or text |
| Guest-controlled load | A guest that animates constantly costs encoding at the frame-rate cap, only while a viewer is connected |

Fault injections to add: `Origin` check removed; `Host` check removed;
token comparison skipped; view-only input accepted; hold not extended by
input; pressed keys not released on disconnect.

## 9. Acceptance

1. With no stream started, nothing listens and the owner takes no samples.
2. With a viewer on a static screen, the owner encodes no frames and its
   CPU stays under the figure recorded in §3.
3. Safari and Chrome on the host render the guest at the cap from §3.
   Latency is measured with a guest-side timestamp fixture and recorded,
   not asserted in advance.
4. A WebSocket upgrade from another origin, with another `Host`, or with a
   wrong token is refused.
5. After **Take control**, a guest `act` is refused `held_by_host` until
   release or 60 s after the last viewer input.
6. Closing the tab with a key held leaves no key down in the guest.

## 10. Open questions

- Whether `cu stream` should also open the browser, or only print the URL.
- Whether a view-only viewer should count as watching for `status`, so a
  guest agent could tell it is observed. Today `status` reveals only holds.
- Configuration: a `computer_use` field in `config.example.jsonc` and
  `ConfigTemplate` to allow or forbid streams per instance, or CLI only.

As implemented: `cu stream` only prints the URL; a view-only viewer is not
reported to the guest; streams are CLI only, with no configuration field.

## 11. Implementation notes

The code is `iso-sandbox/Sources/IsoSandboxCore/MacOS/LiveView*.swift`
(tests: `MacLiveViewTests.swift`; faults `macos-live-view-*` in
`scripts/swift-host-fault-injection.py`). The listener's rules and limits
are in the [trust model](../trust-model.md#macos-guests); the audit
counters are in [audit](../audit.md). Where the build departs from the
proposal above:

- **Profile.** Constrained Baseline, not Main (§4), with a VUI bitstream
  restriction (`max_num_reorder_frames = 0`): without it Chrome's hardware
  decoder buffered every frame and the page stayed black. After a keyframe
  the owner encodes one trailing frame, for decoders with one frame of
  latency.
- **Rate.** `LiveView.frameRateCap` is 30 Hz (2 Hz on a static screen).
  §3 on a macOS 27.2 host: ~6 ms a sample (S1, see
  [screen sync](computer-use-screen-sync.md) §12), `cu act` latency
  unchanged; the view's `IOSurface` is reachable only through
  Virtualization.framework's undocumented layer layout, so it is not used
  (S2); the hardware encoder is in use (S3).
- **Releases** (key up, button up, release of control) have their own
  message budget, and the page sends Command-V as Command up plus `text`.
- **§9** passed on one host (Chrome, WebKit and Safari 27.2 rendered the
  guest; refusals are unit-tested over real loopback sockets).

**Open:** §3 and §9 have run on one host only; the 30 Hz cap is provisional.
