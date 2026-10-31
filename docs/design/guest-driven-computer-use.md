# Guest-driven computer use for macOS guests

**Status:** Approved (2026-10-31), including the vsock 7802 listener under
the stop-and-confirm rule. Implemented 2026-10-31 (see
[Implementation](#13-implementation)).
**Target:** `iso-sandbox` (owner, guest helper), `iso` (configuration,
isolation gate, bootstrap, audit)
**Builds on:** [macOS runtime design](macos-guest-computer-use.md) (Gates
C–H, O, R), [permission-dialog responder](permission-dialog-auto-response.md)

## 1. Summary

An agent running inside a macOS guest (Claude or Codex in bypass mode) gets
computer-use tools for its own desktop. The tools are served by a small MCP
server in the guest that forwards every request over vsock to the VM's owner
on the host. The owner captures frames and injects input exactly as it does
for host callers today: through the VM's own virtual USB pointer and Mac
keyboard (`VZUSBScreenCoordinatePointingDeviceConfiguration`,
`VZMacKeyboardConfiguration`), driven by `MacScreen`.

The guest therefore needs no Accessibility, Screen Recording or Input
Monitoring grant, no restricted entitlement, and no SIP change, and the
agent can work at the login window, lock screen and system dialogs, as Gate
R already shows for host callers.

The feature is off by default and enabled per instance.

## 2. Goals and non-goals

**Goals**

- An in-guest agent can take frames and send pointer and keyboard actions
  to its own VM's display, with the same validation, binding and refusal
  contract as host `cu` callers.
- No new guest permission, entitlement, system extension or SIP change.
- No new network path: vsock only, per VM.
- The host can always take control back.
- Opt-in per instance; when off, nothing listens and nothing is installed.

**Non-goals**

- Background, focus-preserving input into one app while another is in
  front. Hardware-level input has one cursor and acts on the frontmost
  window; that needs private WindowServer SPI (see §10).
- Accessibility-tree inspection or semantic actions. A possible later,
  separately permissioned helper.
- Linux guests ([separate sketch](linux-computer-use-sketch.md)).
- Video streaming. Frames are polled PNGs, as today.
- Driving the host desktop or any other VM.

## 3. Decision

Input stays on the VM's own virtual HID devices, injected by the host
owner. Only the request source changes: a guest agent instead of a host
process.

| Option | Guest needs | Verdict |
| --- | --- | --- |
| **Host-brokered (this spec)** | Nothing | Chosen: reuses the qualified path |
| In-guest `CGEventPost` + ScreenCaptureKit (as trycua/cua's `cua-driver`) | Accessibility and Screen Recording grants for a stable signed identity, a GUI-session agent; private SkyLight SPI for background input | Rejected: grants must be clicked through or written to `TCC.db` with SIP off |
| In-guest `IOHIDUserDeviceCreate` | Restricted `com.apple.developer.hid.virtual.device` entitlement (Apple provisioning profile) | Rejected: not loadable ad hoc with SIP on; capture still needs Screen Recording |
| In-guest HIDDriverKit virtual device | Apple-approved DriverKit entitlements, system-extension approval prompt | Rejected: approval prompt, entitlements; capture still needs Screen Recording |

## 4. User workflow

1. Build or reuse a macOS image: `iso setup --guest macos --ipsw … --image mac`.
   Every macOS template already has the guest helper at
   `/usr/local/libexec/iso-macos-helper` (root-owned, mode 0755); its
   `cu-mcp` subcommand is the MCP server. A template built before this
   change has a helper without it, and needs rebuilding.
2. Enable it in the instance's configuration:

   ```jsonc
   {
     "computer_use": {
       "guest_access": true, // default false; macOS images only
       "guest_frame_rate": 4 // frames per second, 1–10, default 4
     }
   }
   ```

3. `iso up . --image mac`. With `guest_access` on, the owner registers the guest
   computer-use listener and the bootstrap registers `iso-cu` as an MCP
   server for each configured agent (`claude mcp add-json -s user`, and the
   Codex equivalent), command `/usr/local/libexec/iso-macos-helper cu-mcp`,
   stdio.
4. `iso shell NAME`, run the agent. It sees the tools in §6.3 and works in
   a screenshot → decide → act loop.
5. Optional: the host user watches with `iso-sandbox macos cu frame`,
   which does not interrupt the agent, and takes over with `cu hold` (or
   any host action) and hands back with `cu release` (§5.4).
6. `iso stop` or the session TTL ends guest access for that boot.
   Turning `guest_access` off takes effect when the instance is recreated,
   since the setting is fixed in the sandbox record at creation (§5.1).

Setup items that a guest agent cannot click through stay as host
provisioning over SSH, as for host callers: task keychains with trusted-app
lists, quarantine removal (`xattr -dr com.apple.quarantine`). Password,
Touch ID and user-presence prompts remain unsupported.

## 5. Owner (iso-sandbox)

### 5.1 Listener

- A second vsock listener, port **7802** (`GuestCUProtocol.port` in
  `IsoMacProtocol`), registered only when the sandbox record has
  `guestComputerUse: {"frameRate": N}` (absent when off). The field is set
  at `macos create` from `--guest-computer-use [--guest-frame-rate N]` and
  changed only by recreating the sandbox.
- `inspect` reports the listener in the effective configuration
  (`vsockPorts: [7801, 7802]`) and the setting as
  `effective.guestComputerUse`, so `IsolationGate.verifyMacEffective` can
  check both against the record (§8). `inspect.runtime.guestComputerUse`
  carries the boot's counts (§8, audit).
- At most **2** connections at once; further ones are closed at accept. One
  request at a time per connection. An idle connection is kept until the
  guest closes it. Requests run on the owner's main actor, serialized with
  host computer-use requests.

### 5.2 Wire protocol

Newline-delimited JSON, one request then one response.

- **Guest → host requests**: at most 64 KiB per line
  (`HelperProtocol.maxLine`), parsed by a closed decoder that refuses
  unknown fields:

  | `op` | Fields | Host operation |
  | --- | --- | --- |
  | `session` | — | `MacScreen.newGuestSession()` |
  | `frame` | `session` | `MacScreen.frame(session:origin: .guest)` |
  | `act` | `session`, `action` (`CUActionRequest` field names), `basedOnFrame` (required) | `MacScreen.act(…, origin: .guest)` |
  | `status` | — | Controller state: `controller` (`idle`, `guest`, `host`) and `holdRemainingSeconds` (integer, 0 unless `host`) |

  `status` returns only those two fields: no host session ids, no
  `cu respond` expectations, nothing about other VMs. It needs no session
  and counts against the action rate limit.

  Nothing else: no `stop`, `inspect`, control-socket `status`,
  `cu respond`, or helper messages. `basedOnFrame` is required for guest actions.

- **Host → guest responses**: `ok`, plus `session`, `frame` (`frameId`,
  `width`, `height`, `png` as base64), `submitted`, or `controller` and
  `holdRemainingSeconds`; on refusal `error`, `refusal` (the control
  socket's codes) and, for `act`, `beforeInput`. A malformed request is
  refused as `invalid_action`. The guest reads response lines of up to
  16 MiB; each host write is bounded by a 10 s deadline, after which the
  connection is dropped.

- No authentication handshake. Any process in the guest may connect: the
  whole guest is one principal, and it can already do anything a
  computer-use client can (it owns the desktop). The helper's HMAC key is
  not reused, so non-root guest processes need no access to it.

### 5.3 Rate and size limits

Enforced per sandbox, not per connection:

- frames: `frame_rate` per second (token bucket, burst equal to the rate),
  from `computer_use.guest_frame_rate`, default **4**, accepted range 1–10;
- actions: 20 per second (burst 20); `type` text counts one action per 64
  characters;
- every request line, refused or malformed: 100 per second, charged before
  parsing and never refunded;
- sessions: one live guest session; opening another invalidates the first.
  A `session` or `status` request costs one action.

Over a limit, the request is refused with `refusal: "rate_limited"`,
`beforeInput: true`. A frame or action refused before it did its work
(no frame captured, no input sent; a blank frame was captured) gives its
token back, so the guest's retry after reopening a session preempted by a
host hold is not itself refused. The frame rate is the record's
`guestComputerUse.frameRate`, set at `macos create` (`--guest-frame-rate`)
and fixed for the sandbox's life. The action and session limits
stay constants until a workload shows they need tuning.

### 5.4 One controller: the host takes precedence

The owner tracks one controller per VM:

```text
idle ──guest session──▶ guest ──host hold──▶ host ──release / expiry──▶ idle
```

- **Explicit hold.** New control-socket operations `cu-hold` (`seconds`,
  1–3600, default 300) and `cu-release`, with CLI
  `iso-sandbox macos cu hold VM [--seconds N]` and `cu release VM`. A hold
  invalidates the live guest session (`refusal: "held_by_host"`) and refuses
  new guest sessions until it is released or expires. A hold never
  shortens one already longer: `cu-hold` while a hold is active extends it
  to the later end.
- **Implicit hold for host input.** A host `cu-act`, and therefore
  `cu respond`, takes a 60 s hold (or extends a shorter one) once its
  checks pass and before it sends any input, so host and guest input never
  interleave. A host action while a guest action is in progress is refused
  `busy` and takes no hold; `cu-hold` still works then.
- **Watching does not preempt.** Host `cu-session` and `cu-frame` take no
  hold: a host user can watch the guest agent work without stopping it.
- While a hold is active, guest `session`, `frame` and `act` requests are
  refused with `held_by_host`; the guest tool reports "the host has
  control" with the remaining seconds from `status`, so the agent can wait
  rather than retry. After the hold, the old guest session is gone
  (`unknown_session`) and the guest tool opens a new one.
- A guest action in progress when a hold starts stops at its next step,
  because its session was revoked, and is released as any interrupted
  action is (buttons and keys up).

New refusal codes: `held_by_host` and `rate_limited`.

## 6. Guest component: `iso-macos-helper cu-mcp`

### 6.1 Shape

A subcommand of the existing guest helper, so it ships, is signed and is
installed exactly as the helper is, with no new release artifact. It runs
as the agent's user, never as the LaunchDaemon, and touches none of the
helper's key or state. It speaks MCP over stdio to the agent and the §5.2
protocol to vsock CID 2, port 7802. It holds no credentials and makes no
other connection. The JSON-RPC mapping (`GuestCUMCP`) is in `IsoMacProtocol`
with an injected transport, so it is unit-tested on the host.

### 6.2 Behavior

- Opens a session lazily and reopens it once on `unknown_session` or
  `session_refused`; on `held_by_host` it calls `status` and returns a tool
  error naming the remaining hold, without retrying.
- A request whose connection fails is retried once on a new connection,
  except an `act` written in full whose reply was lost: that is never
  sent twice, and the tool reports that the action may have been applied.
- Every action tool takes the `frameId` of the screenshot it is based on;
  a call without one is refused locally, and the host refuses a frame from
  another binding. The tool does not check that it is the latest frame.
- Frames are returned to the agent as image content plus a text line with
  the `frameId`. Coordinates are framebuffer pixels (1920×1200), top-left
  origin, as on the host.
- MCP over newline-delimited JSON-RPC 2.0: `initialize` (protocol versions
  `2024-11-05`, `2025-03-26` and `2025-06-18`; anything else is answered
  with `2025-06-18`), `ping`, `tools/list` and `tools/call`; other methods
  get `-32601`. Refusals and transport failures are tool results with
  `isError`, not JSON-RPC errors.

### 6.3 Tools

| Tool | Arguments | Maps to |
| --- | --- | --- |
| `screenshot` | — | `frame` → image + `frameId` |
| `control_status` | — | `status` → `controller`, `holdRemainingSeconds` |
| `click` | `x`, `y`, `button?`, `count?`, `frameId` | `act` `click` |
| `move` | `x`, `y`, `frameId` | `act` `move` |
| `drag` | `path[]`, `button?`, `frameId` | `act` `drag` |
| `scroll` | `x`, `y`, `dx`, `dy`, `frameId` | `act` `scroll` |
| `key` | `keyCode`, `modifiers[]?`, `frameId` | `act` `key` |
| `type` | `text` (printable ASCII, `\n`, `\t`), `frameId` | `act` `type` |

`down`/`up` are not exposed; a held button left by a crashed agent would
outlive the call.

## 7. Trust model

This feature trips one stop-and-confirm item: **a new network listener**
(the vsock port). It adds no outbound URL, no egress rule, forwards no
secret, runs no subprocess on tainted bytes, writes no host path from
tainted data, and logs no tainted content.

Invariants to add under "macOS guests" in `docs/trust-model.md`:

- **Guest computer use (vsock 7802).** Off by default; registered only for
  sandboxes created with `guestComputerUse`. Requests are tainted: bounded
  lines, a closed four-operation set, the same action validation and frame
  binding as host callers, and per-sandbox rate limits (including 100
  requests a second of any kind). Its `status` operation reveals only
  whether the host holds control and for how long. Responses carry only
  the guest's own framebuffer and fixed-shape metadata.
- Input is synthesized into that VM's view only; nothing is posted to the
  host event system, and no other VM is reachable (vsock is per VM).
- The host always wins control (§5.4); the guest cannot hold input against
  a host caller.
- A guest that enables this can click its own consent dialogs. That is
  within the VM boundary and changes no host-side policy: `cu respond`
  expectations remain host-authored.

What a malicious guest can still do: drive its own desktop (it could
anyway), and spend up to the rate limits in host CPU and memory for frame
encoding. It cannot reach the host desktop, clipboard, files, other VMs, or
the control socket.

## 8. Host CLI (`iso`)

- **Configuration.** New `computer_use.guest_access` (bool, default
  `false`) and `computer_use.guest_frame_rate` (integer 1–10, default 4,
  valid only with `guest_access`; unknown members refused), documented in
  `config.example.jsonc`, `ConfigTemplate` and `docs/configuration.md`.
  `iso policy effective` does not report it. A Linux instance created while
  it is on runs without it, with a warning (one configuration serves every
  instance).
- **Create.** A new macOS instance's sandbox is created with
  `--guest-computer-use --guest-frame-rate N` when the setting is on, and
  `iso` refuses it unless the created record carries exactly that setting.
  The instance's `apple-machine.json` records it too
  (`guest_computer_use`), and `iso start` copies the record's setting into
  it if they differ (an instance created before the sidecar recorded it).
  `iso start` of an existing instance whose configuration has since
  changed warns and runs as created.
- **Isolation gate.** `verifyMacEffective` requires
  `effective.guestComputerUse` to equal the record's, and the vsock
  listeners to be `[7801]`, or `[7801, 7802]` when the record has it on
  (`IsolationGate.macVsockPorts(guestComputerUse:)`). Anything else fails
  closed as host exposure.
- **Bootstrap.** A macOS instance whose `apple-machine.json` records guest
  computer use (not the current configuration, which may have changed)
  gives both agents the stdio MCP server `iso-cu`
  (`/usr/local/libexec/iso-macos-helper cu-mcp`), registered like any
  configured MCP server; a user server with that name is an error. With it
  off nothing is registered: templates carry no registration, so there is
  nothing to remove.
- **Audit.** When `iso stop` stops a running macOS instance created with
  guest computer use, it first reads `inspect.runtime.guestComputerUse` and records
  `boundary.guest_computer_use`: `frame_rate`, and counts of `sessions`,
  `frames`, `actions`, `status_requests`, host-hold `preemptions` and
  `refusals` by code (only lowercase-and-underscore codes are kept). An
  invalid report (a negative count) is dropped at decode, so the boot's
  audit event is lost but `inspect` itself still succeeds. No
  pixels, coordinates or typed text. A boot that ends any other way (TTL,
  crash, `iso-sandbox` directly) is not recorded.

## 9. Testing

**Unit (iso-sandbox)**

`MacGuestComputerUseTests.swift`:

- Request decoder: unknown op or field (also inside `action`), oversize
  line, missing `session` or `basedOnFrame`, not JSON → refused.
- Guest actions decode as runtime actions field for field; unknown buttons
  fail.
- Control (`CUControl`): a hold ends the guest session and refuses new
  ones until it expires; holds extend but never shorten; release.
- Limits: bucket refill and one-second cap, separate frame and action
  limits, `type` cost (capped at a full second, so 4096 characters fit),
  refunds only for refusals that did no work.
- Link: malformed and over-limit requests never reach the screen; the
  connection cap; every line, malformed ones included, counts against the
  overall request cap.
- Frame-rate bounds; records without the field still decode.
- MCP: version negotiation, the tool list (no `down`/`up`), one session
  for several screenshots, frame-less actions refused locally, a forgotten
  session reopened once, an action cut short never resent, a hold
  reported with its remaining time; the transport's no-resend rule
  (`GuestCURequest.mayResend`).
- `LineReader`: lines found whatever the read boundaries.

The `MacScreen` paths (implicit hold on host input, watching without a
hold, a revoked session stopping an action) need a VM and are covered by
Gate U only.

**Fault injection** (`scripts/swift-host-fault-injection.py`): the closed
field set, the `basedOnFrame` requirement, the rate limit, the overall
request cap, the no-resend rule, a hold refusing new and existing guest
sessions, the gate's listener and record checks, and the audit's
refusal-code filter (`macos-guest-cu-*`).

**Host (iso)**: `LoaderTests` (config defaults, bounds, frame rate only
with access, unknown members, `addingMCPServer`), `MacGateTests` (setting
and listener must match the record; the port and frame-rate constants match
iso-sandbox's; the sidecar persists the setting and syncs from the record;
invalid counts lose only the counts), `BoundaryAuditTests` (the event's
fields and code filter), `BootstrapTests` (registration follows the
instance, not the configuration; the reserved name). The create-time record
check, the start warning and the Linux warning have no unit test.

**Qualification** (`tests/macos-guest-qualify.py`):

- Gate O (unchanged): a sandbox created without the feature accepts only
  vsock 7801, so 7802 refuses.
- New **Gate U** (guest-driven use), on a sandbox created with
  `--guest-computer-use --guest-frame-rate 1`, with this build's helper
  copied into the guest so the template need not be rebuilt:
  - `inspect` reports vsock `[7801, 7802]` and frame rate 1, and an
    in-guest probe finds exactly those two ports open;
  - `iso-macos-helper cu-mcp`, driven over pinned SSH as an agent would,
    initializes and lists its tools;
  - with TextEdit opened on a file (`open -a TextEdit` over SSH), it
    types a token and saves with Command-S; the file is read back over
    SSH;
  - a host `cu frame` does not interrupt it;
  - `cu hold` refuses its next screenshot with the remaining time and
    `status` reports `host`;
  - after `cu release` a screenshot works again and `status` reports
    `guest`;
  - back-to-back screenshots are rate limited;
  - the owner's counts show at least 3 frames, 2 actions, 1 preemption and
    `held_by_host` and `rate_limited` refusals.

## 10. Known limits

- One cursor and one keyboard focus: the agent works in the foreground, one
  app at a time. Background input into an unfocused app would need private
  SkyLight SPI (`SLEventPostToPid`), as `cua-driver` uses, and is out of
  scope.
- Frames are PNG polls (about 1–3 MB each); at the default 4 per second
  this is enough for agent loops, not for video. The 10 per second ceiling
  bounds host encoding cost.
- English-only concerns of the dialog responder do not apply here: the
  guest agent reads the screen itself.

## 11. Rollout

1. Approval of the listener (§7) and this spec: approved 2026-10-31.
2. `IsoMacProtocol` guest protocol, owner listener, controller arbitration,
   rate limits, with unit tests and faults.
3. `iso-macos-helper cu-mcp`, `iso` configuration, isolation gate,
   bootstrap and audit.
4. Gate U on the development host, and Gate O rerun; results in §13.

## 12. Decisions

**Decided (2026-10-31)**

- Host control is an explicit hold (`cu hold` / `cu release`); host input
  also takes an implicit hold; host watching does not preempt (§5.4).
- The guest frame rate is configurable, default 4, range 1–10 (§5.3).

- The guest may query control state with a `status` operation returning
  only `controller` and `holdRemainingSeconds`, rate-limited with actions
  (§5.2). Its only disclosure is host-hold timing, which `held_by_host`
  refusals already reveal; it adds precision, not new information.

No open questions remain.

## 13. Implementation

Implemented 2026-10-31 as specified, with these choices:

The sections above describe what was built. Where it differs from the
approved draft:

- **Instance record decides (§8).** Bootstrap and the stop-time audit
  follow the setting recorded in `apple-machine.json` at create, as the
  listener does; the draft keyed them on the current configuration.
- **Linux instances warn (§8)** instead of refusing, since one
  configuration serves every instance.
- **Guest server in the helper (§6.1).** The draft had a separate
  `iso-cu-mcp` binary, which would have been a new release artifact through
  the signed release, notarize and `iso update` verification chain. The
  helper's `cu-mcp` subcommand needs none of that.
- **Audit at `iso stop` only (§8).** Per-boot counts are read from the
  owner just before an `iso stop`; other ends of a boot are not recorded.
- **Gate from the record (§8).** The gate checks the listener against the
  sandbox record rather than the current configuration, which may have
  changed since the instance was created.
- **No `guest_access_off` code, no `iso policy effective` entry, no
  registration removal (§5.4, §8).**
- **Refunds and an overall request cap (§5.3)**, added after the first
  Gate U run.

**Qualified (development bar).** On the development host, template
`macos27` (macOS 27.0.1, build 26A434), with this build's helper copied in:

- Gate O (run `20261031T201117-6e1e`) passed: a sandbox without the
  feature accepts only vsock 7801.
- Gate U (run `20261031T201557-6708`, frame rate 1) passed:
  - 7801 and 7802 accept, and nothing else does;
  - the MCP server typed a token into TextEdit and saved it, read back
    over SSH;
  - host `cu frame` did not interrupt it;
  - `cu hold` refused it with the remaining time, and `status` reported
    `host`;
  - after `cu release` it resumed;
  - back-to-back frames were rate limited;
  - the owner counted 3 frames, 2 actions, 1 preemption and the refusals.

Gate U passed again after the review fixes (run `20261031T225403-6de7`).

An earlier Gate U run failed because a refused frame used up its token, so
the server's retry after a hold was itself rate limited. That led to the
refund rule in §5.3.

| Piece | Where |
| --- | --- |
| Wire types, refusal codes, MCP mapping | `iso-sandbox/Sources/IsoMacProtocol/GuestCUProtocol.swift`, `GuestCUMCP.swift` |
| Control and limits (pure) | `iso-sandbox/Sources/IsoSandboxCore/MacOS/CUControl.swift` |
| Listener, counts | `iso-sandbox/Sources/IsoSandboxCore/MacOS/MacGuestCULink.swift` |
| Holds, guest sessions | `MacScreen.swift`; `cu-hold`/`cu-release` in `MacOwner.swift`; CLI `macos cu hold|release`, `macos create --guest-computer-use [--guest-frame-rate N]` |
| Guest stdio server | `iso-sandbox/Sources/IsoMacHelper/CUMCP.swift` |
| `iso` | `ComputerUseConfig` (`IsoConfig.swift`, `ConfigDecoding.swift`), `MacLifecycle.swift`, `IsolationGate.verifyMacEffective`, `AgentBootstrap.withGuestComputerUse`, `BoundaryAudit.guestComputerUse` |
| Tests | `MacGuestComputerUseTests.swift` (iso-sandbox); `LoaderTests`, `MacGateTests`, `BoundaryAuditTests` (iso); `macos-guest-*` faults; Gate U |

