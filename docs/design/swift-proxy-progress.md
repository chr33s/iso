> **Host scope clarification:** This fork supports macOS 27+ Apple Silicon
> hosts only; guest VMs still run Linux. Earlier requirements to pass Linux/
> Firecracker host gates are superseded. Historical failures remain recorded
> as evidence, not current acceptance blockers. Applicable macOS VM, live
> provider/agent, review, and release-provenance gates remain required.
>
> Rust host references and `cargo` commands below are historical: the Swift
> host (`Sources/`) replaced the Rust host in 2026-09, and Cargo is no longer
> part of the build. Current commands are in [testing.md](../testing.md).

> The Python process/forwarding/disconnect/body/capacity and RSS test runners
> referenced below are historical. Their gates now run through the proxy Swift
> package tests; see [current commands](../testing.md#credential-proxy-iso-proxy).

# Swift proxy implementation progress

The governing specification is [the Swift proxy specification](swift-proxy-spec.md). This record tracks implementation evidence; it does not replace or narrow
the specification. Swift is now the sole credential-proxy implementation in
`iso-proxy/`; the Rust host CLI remains. Entries below are chronological
historical evidence, including the removed Rust implementation and the former
`macos/` package layout. See [current acceptance status](swift-proxy-acceptance.md)
for completed and outstanding gates.

## Phase 0: Rust reference

Implemented so far:

- Duplicate credential headers are rejected, and both credential forms must
  agree when supplied together.
- Absolute-form and authority-form targets cannot pass operation authorization.
- Headers nominated by any `Connection` field are removed before injection.
- The host launcher clears the child environment and uses the absolute macOS
  sandbox launcher path.

Additional reference hardening:

- Version 1 startup schema, closed provider enum, unknown-field rejection,
  loopback validation, exact lowercase 64-hex capabilities, and provider/scheme
  validation. Decoder diagnostics cannot echo startup values.
- Launcher emits the same versioned provider schema. Gate fixtures use a denied
  GET operation with a fixed provider. During fixture conversion one test still
  used POST and reached Anthropic with its fake credential; it returned 401.
  The corrected GET fixture passes locally with 403.
- Capability comparison uses `subtle` rather than a handwritten loop.
- HTTP/1 server only, 128 headers, 64 KiB parser buffer, 16 KiB field cap,
  and 10-second header timeout. HTTP/2 dependency features were removed.

Verification on 2026-09-26:

- `cargo test -p iso-proxy`: 27 unit and 9 process/socket tests passed.
- `cargo test --lib proxy::tests`: 26 tests passed.
- Earlier deliberate mutations disabling duplicate rejection, absolute-target
  rejection, and nominated-header stripping individually failed their tests.

Still required in phase 0: full transport validation of request-body limits,
idle timeout and trailer rejection, and broader adversarial transport tests.
Parser-buffer limits and parsed-header tests alone do not prove every resource
bound in the specification.

## Phase 1: Swift pure policy

`iso-proxy` now contains IsoProxyCore with fixed provider policy,
strict startup configuration, redacted secrets, CryptoKit HMAC verification of
capabilities, raw-target validation, exact operations, request/response header
filtering, and resource constants. It has no socket or process dependencies.

- `swift test --package-path iso-proxy`: 8 table-driven tests passed.
- `python3 scripts/test-swift-proxy-mutations.py`: all five required policy
  mutations were killed and the restored baseline passed. This targeted gate
  supplements a future full Swift mutation sweep.
- Host is Apple Silicon macOS 27.0, with Swift 6.4.

## Phase 2: inbound NIO transport

`IsoProxyTransport` now has a loopback socket listener and HTTP/1 inbound gate.
SwiftNIO 2.100.0 is pinned by exact version and revision in Package.resolved,
including all transitive dependencies. The decoder explicitly enforces 16 KiB
fields, 64 KiB aggregate headers, and 128 fields. Authentication, raw targets,
operation policy, declared and streamed body caps, trailer rejection, header/body
timeouts, connection capacity, and response-lifetime request leases are enforced
by the gate. Request buffers pass through incrementally without aggregation.

Evidence: `swift test --package-path iso-proxy` passes 8 pure policy and
11 transport tests. These include real socket rejection, malformed/incomplete
header limits, ambiguous framing, 64 MiB in chunks followed by a rejected excess
byte, 256 held responses with rejection of the 257th, long response survival,
timeout reset on body progress, disconnect release, and reuse after response end.

The targeted mutation gate also disables each decoder limit separately. All
eight policy/parser mutations were killed and the restored baseline passed.

## Phase 3: upstream client and streaming bridge

The transport now includes a dedicated AsyncHTTPClient 1.36.2 client with NIOSSL
2.36.1, both pinned in Package.resolved. Production configuration selects HTTPS
on the compiled provider host/443, HTTP/1 only, redirects disabled, no environment
proxy, no decompression, full certificate verification, `.default` trust roots,
no additional roots, and no client TLS identity. Its pool has 256 slots, no
prewarming, no connection-establishment retries, and one use per connection.
Delegate-only event-loop preference avoids the library's overflow-connection
exception for mandatory connection event-loop assignment.

The pinned NIOSSL `SSLContext.createConnection` source selects
`performSecurityFrameworkValidation` for `.default` on Darwin. That function
uses `SecPolicyCreateSSL` with the expected hostname and
`SecTrustEvaluateAsyncWithError`. The approved platform-trust choice therefore
uses the library's native Security.framework implementation, with no custom
certificate verifier or bundled root store. This source inspection is not a
substitute for the pending live TLS/Seatbelt tests.

`StreamingBridge` uses manual guest reads, a 16 KiB receive allocation, and one
read batch at a time. `UploadStream` waits for each upstream write future before
reading further and has a separate 64 KiB pending-input ceiling. ResponseRelay
returns guest flush futures to AHC for response backpressure. Disconnects cancel
the upload and upstream task. A 30-second establishment timer is cancelled when
the request head has been sent; streaming responses have no total timeout.
Guest connections close after one response, including early upstream responses.

New test evidence:

- Production request construction fixes host/port/TLS and preserves an encoded
  query; header injection/removal and TLS/client settings are asserted.
- Controlled upload-write promises prove a second body write waits for the first.
- A local socket test exercises the actual bridge and AHC against a controlled
  HTTP upstream. It verifies injected credentials, body bytes, host/query,
  request and response header stripping, and a returned 307 with no follow-up.
  Destination substitution exists only in the test's internal executor closure;
  production startup accepts no destination override. This test does not prove
  upstream TLS verification or bidirectional slow-reader memory bounds.

The chunked-body cap still forwards preceding parts to the downstream handler.
It cannot meet the spec's absolute no-credential-before-overlimit requirement
without the outstanding decision below. The standalone Swift executable now
exists for validation and host-only local selection; release installation has
not yet switched.

## Phase 4: executable and production confinement

`iso-proxy-swift` now disables core dumps, verifies file/exec/TCP restrictions
before reading secrets, bounds startup JSON to 64 KiB, decodes to EOF, closes
stdin, and only then binds. Only the normal stdin startup and `--jail-selftest`
are accepted; no unconfined switch exists. SIGTERM/SIGINT close the listener and
tracked child connections before shutting down the dedicated client/event loops.
The connection registry refuses child connections arriving after shutdown begins.

On macOS 27, credential-free system TLS succeeded unconfined, failed under the
old profile, and succeeded with only `com.apple.trustd.agent` lookup added.
Allowing `com.apple.trustd` instead did not fix it. The production profile now
allows the verified exact service and documents why. No keychain-service or
filesystem-write permission was added. The self-test uses `posix_spawn` directly:
Foundation Process obscured the sandbox permission errno as a file-not-found error.

Verification on 2026-09-27:

- Swift build passes; unit suite has 22 passing tests and one opt-in live test
  skipped during ordinary offline execution.
- `ISO_PROXY_LIVE_TLS_TEST=1 swift test --package-path iso-proxy --filter
  liveProviderSystemTrust` passes for both fixed providers without credentials.
- `python3 scripts/test-swift-proxy-process.py` passes: refusal while unconfined
  before stdin is supplied; invalid/oversized input rejection with redacted
  diagnostics; real HTTP readiness and policy rejection under the profile;
  secret-free argv/logs; and clean termination with an open guest socket.
- The same process gate passes file/exec/non-provider-egress denial and live
  DNS/system TLS under the production profile. Removing the exact trustd-agent
  permission causes the expected TLS failure, so the test detects that regression.

The CLI self-test and the process gate together cover bind/accept and TLS. A
passing public-provider certificate does not replace the credential-bearing live
smokes or real VM integration.

## Certificate matrix and host startup transaction

On 2026-09-27, `systemTrustCertificateMatrix` passes seven controlled cases:
trusted correct-host leaf; wrong-host, expired, and not-yet-valid leaves with
the same trusted CA; untrusted CA-issued leaf; untrusted self-signed leaf; and
the same self-signed leaf with explicit per-evaluation trust. Tests generate
fresh disposable certificates with localhost SANs and appropriate key usage.
The client retains `.default` trust roots, selecting Security.framework, and
adds anchors only to the test client's individual evaluations. Nothing is
installed in the host trust store and production configuration remains unchanged.
All denied cases assert that no HTTP request reached the TLS server, so the
synthetic credential never crosses an invalid TLS connection.

Disabling production `certificateVerification` deliberately caused the isolated
certificate-matrix test to fail, including its no-HTTP-delivery assertions.
The implementation was restored and the full Swift suite passed (23 offline
passes, one live test skipped). The expanded self-signed positive/negative
control also passed separately.

Host launcher readiness now requires a real HTTP/1.1 401 response, with bounded
connect/write/status-line reads. It rejects TCP-only, echo, truncated, and
wrong-status peers. Startup stdin delivery and readiness are one transaction:
a missing stdin handle or broken pipe kills and reaps the child, closing a
previous orphan path before readiness polling. Their IO helpers are excluded
in `.cargo/mutants.toml` and covered by socket/process tests. The focused host
suite (28 tests) and additional broken-pipe test passed; workspace clippy passes
with zero warnings.

## Shared raw HTTP refusal corpus

`scripts/test-proxy-contract.py` runs 32 raw-wire cases from
`tests/fixtures/credential-proxy/refusals.json` against both real executables,
each confined by the production Seatbelt profile with an empty environment,
for both providers. It checks status, connection closure, process survival,
and absence of startup secrets in local responses and process output. Cases
only use denied methods, so none invokes an allowed provider operation.

The first run exposed Rust/Swift disagreements in raw targets, ambiguous
framing, HTTP/1.0, and aggregate header size. Hyper normalizes some of this
evidence before constructing a request. Rust now uses httparse to validate the
bounded first header block before replaying those bytes into Hyper. Hyper
continues to own body framing and streaming. Connections serve one response,
matching the Swift bridge. A socket test verifies replay preserves both
prefetched body bytes and unread bytes exactly. Partial-header sockets test
connection capacity and release without relying on keep-alive responses.

On 2026-09-27 all 128 corpus executions passed; Rust passed 29 unit tests and
9 process/socket tests, and the Swift offline suite passed. Workspace clippy
passes with zero warnings. This is a refusal corpus; admitted forwarding,
streaming, cancellation, and TLS differential coverage remain open. Rust's
preflight memory is bounded. Subsequent partial-header coverage is recorded below.

Deliberately ignoring the raw-header validator's result caused the corpus to
fail, including target and aggregate-limit cases. Production validation was
restored and the Rust executable rebuilt afterward.

## Rust startup resource bounds

Rust now sets both core-dump resource limits to zero before reading secrets.
Startup reads at most 64 KiB plus one sentinel byte, rejects excess input, and
owns/closes the inherited stdin descriptor on all return paths before creating
runtime threads or sockets. UTF-8 and JSON failures expose no startup values.
The 64 KiB limit matches Swift. Exact-limit valid JSON with padding passes;
one excess byte fails. A real-process test holds the pipe writer open and
asserts that oversized input still causes a prompt, redacted failure.

On 2026-09-27, deliberately doubling the read ceiling caused that process test
to fail on its EOF-wait deadline. The original ceiling was restored; all 31
Rust unit tests, 10 process/socket tests, and 128 shared refusal executions
then passed. Workspace clippy, formatting, and diff whitespace checks pass.

## Rust response header policy

Rust now filters hop-by-hop response fields and all Connection nominations
before passing upstream metadata to the guest. Request and response paths share
the nomination parser. Invalid nominations become a generic local 502 without
upstream content. Redirect status/location, duplicate end-to-end headers, and
body bytes are preserved; the streaming wrapper retains its concurrency permit
through body consumption or drop. Focused tests cover these properties, malformed
and empty nomination lists, and permit release on header failure. Swift has
matching malformed-nomination cases. Deliberately disabling nominated-field
removal caused the Rust response test to fail; production filtering was restored.

This closes the response-head policy gap. It does not establish full upstream
wire parity or response-trailer behavior, which still require transport tests.
Verification on 2026-09-27: 33 Rust unit and 10 process/socket tests pass,
the focused Swift header-policy test passes, and all 128 shared refusal runs
pass after rebuilding the Rust executable. Workspace clippy, formatting, and
diff whitespace checks pass.

## Rust streaming upload guard

Rust now rejects declared Content-Length above 64 MiB and Trailer declarations
before upstream connection. A streaming body wrapper counts data across frames,
rejects the first frame that would exceed 64 MiB, rejects actual trailer frames,
and applies a 30-second idle deadline reset by nonempty body progress. It retains
no body queue. A typed shared failure reason survives Hyper's body-error wrapping
so send failures retain 413/400/408 instead of becoming generic 502 responses.

Tests cover the exact cap followed by an excess byte, header declarations,
undeclared trailers, idle expiration/reset including empty frames, and a real
Hyper client/server connection over an in-memory duplex stream. That connection
confirms a trailer rejection fails the sender while preserving its typed reason.
Deliberately breaking byte accumulation, trailer rejection, and timer reset each
failed its corresponding test; production guards were restored.

This guard shares Swift's unresolved streaming/over-limit contradiction: bytes
preceding an unknown-length overflow can already have reached the provider.
End-to-end guest status, early upstream responses, cancellation, and behavior
under upstream backpressure still need stronger wire-level coverage. The body
deadline is checked when Hyper polls the upload; this alone does not establish
deadline behavior while upstream writes are stalled.
Verification on 2026-09-27: the full Rust run passed 37 unit and 10 process/socket
tests; the subsequently added Hyper failure-reason test passed separately.
All 128 shared refusal executions, workspace clippy, formatting, and diff
whitespace checks pass with the restored production code.

## Swift disconnect cancellation

`LifecycleTests.swift` drives the real bridge and AHC through loopback sockets
against a controlled provider that never answers. It waits until body bytes
actually reach that provider, then disconnects the guest, and asserts that the
provider observes socket closure. Both unfinished uploads and completed uploads
waiting for response headers are covered, each with guest disconnect and proxy
child-registry shutdown, for four cases. The destination override exists only
in the test executable. Child registries bound cleanup on failed assertions.

The mock provider disables NIO pipelining assistance: otherwise that helper
suppresses reads after request end while awaiting a response and hides peer EOF,
producing a false cancellation failure. With direct EOF observation, both cases
pass. Deliberately removing upstream task cancellation makes the completed-upload
case fail its socket-closure assertion; the production code was restored.

On 2026-09-27 the restored full Swift suite passed (24 offline tests, one live
test skipped); the expanded four-case cancellation/shutdown matrix then passed
separately. Diff whitespace checks pass.

These tests establish socket cancellation for the two paths. They do not yet
prove cancellation under a stalled upstream writer, response backpressure,
or capacity recovery after repeated bridge-level cancellations.

## Swift early response during upload

The controlled lifecycle provider can now return 429 with a short response body
after receiving the first four bytes of a declared 100-byte upload. The real
bridge/HTTP-client test asserts that the guest receives exactly one complete
response with the provider's status and body, that the upload never completes,
and that both guest and provider sockets close. This exercises the early-response
path without contacting a real provider or changing production destinations.
Deliberately dropping response body writes caused the new test to fail. After
restoring production code, the full Swift suite passed on 2026-09-27 (25 offline
tests, one live test skipped), including all four disconnect/shutdown cases.
Diff whitespace checks pass.

## Local dual-build transition

The host now reads `ISO_PROXY_IMPLEMENTATION` as a strict Rust/Swift enum.
Unset means Rust. Swift is permitted only in a macOS apple-container build,
resolves only the sibling `iso-proxy-swift` executable, and never falls back
to Rust. Rust first resolves `iso-proxy-rs`, then the legacy name for existing
installations. The guest/startup schema has no selector and proxy child
environment clearing remains in effect. Unit tests cover defaults, unsupported
platform/backend rejection, invalid values, and the Swift-only candidate list.

`scripts/build-proxy-transition.py` builds the Apple-backend host plus both proxy
implementations and stages `iso-proxy-rs` and `iso-proxy-swift` beside `iso`,
using atomic replacement for each completed artifact. It supports debug and
release builds on macOS 27+ Apple Silicon. This enables local differential/VM
work; release archives, installers, and the production default are not switched.

On 2026-09-27 the debug transition script completed and the staged sibling
executables passed all 128 shared refusal executions under Seatbelt. Selector
tests passed with both default and apple-container host builds, and both
workspace and apple-container clippy passed with zero warnings. The subsequent
real VM launch and rollback result is recorded below.
Adding a Rust fallback candidate to the Swift branch deliberately caused the
selector test to fail; the original candidate list was restored and retested.

## Real VM transition gate

`tests/integration-proxy-transition.py` now provides a dedicated Apple sandbox
gate for the staged transition artifacts. It builds a private signed runtime,
uses an isolated isolate data directory and synthetic provider/host credentials,
then checks Swift launch, guest 401/403 responses, environment/config credential
suppression, selected process identity, stop teardown, and explicit Rust restart.
Only denied GET operations are issued. It cleans up its VM and owner-scoped
images; failed runs retain diagnostic files. This is separate from credentialed
live provider/agent smoke tests and from the Lima/Firecracker suites.

The first run passed on 2026-09-27 with exit zero: private runtime build/signing,
VM image setup, Swift bootstrap, guest denial/authentication and credential
suppression checks, selected process identity, Swift stop/listener teardown,
Rust restart and the same guest checks, Rust stop/listener teardown, and cleanup.
The host was macOS 27 arm64 with Apple's container service running. Workspace
tests also passed: 1,213 host unit tests, 38 proxy unit tests and 10 proxy process
tests; one documentation test was ignored. This is an Apple sandbox result,
not evidence for Lima, Firecracker, or credentialed model/agent smoke tests.

The expanded VM gate also passed with exit zero on 2026-09-27. With Rust present,
removing Swift fails startup with the missing-selected-binary diagnostic;
replacing Swift with a failing executable fails startup with the child-exit
diagnostic. Neither path creates proxy PID records. On this host the copied
system executable is terminated by a signal, covering abrupt child failure.
The same VM subsequently starts successfully with explicit Rust selection and
passes guest checks and teardown. The first attempt failed in fixture creation
because copying protected macOS file flags was denied; copying contents and
setting executable mode fixed the harness before the successful complete run.

## Swift upload queue bounds and stalled-write cancellation

Two controlled-writer tests now hold the upstream write future unresolved,
fill the pending queue to its 64 KiB bound, and verify rejection of one excess
byte. Cancellation resolves the upload exactly once as failed, discards queued
data, and prevents a late successful write acknowledgment from sending more
data or resuming guest reads. Another case fills the queue before the writer
attaches, then verifies ordered draining and successful completion after end.

The tests exposed a metadata-bound gap: empty buffers consumed no byte budget
but were appended to the pending array. UploadStream now discards empty buffers
before queuing. The test submits 1,000 empty buffers and verifies that only the
four nonempty chunks reach the writer. This proves the upload pump's queue and
cancellation behavior; whole-process memory under real slow sockets and response
backpressure remain separate open gates.
On 2026-09-27 both the empty-frame-guard removal and doubled pending-byte limit
were caught by assertion failures. The empty-frame test uses individually
acknowledged writes, avoiding recursive synchronous draining in the deliberately
broken version. After restoration, the full Swift suite passed: 27 offline tests
and one skipped opt-in live test. Diff whitespace checks pass.

## Swift response backpressure acknowledgment

`ResponseBackpressureTests.swift` runs the real bridge and AHC over loopback
sockets against a controlled provider returning 1 MiB. A test-only outbound
handler withholds completion of the first guest body write while letting its
bytes reach the guest. The test checks that only one body write reaches that
handler while completion remains pending, then releases it and verifies every
response byte and subsequent chunk delivery. This exercises the production
delegate's write-future propagation without changing its destination policy.

This proves that response delivery waits for guest write acknowledgment. It does
not measure whole-process memory or OS socket-buffer behavior under a truly slow
guest; those stress gates remain open.
On 2026-09-27, deliberately returning an already-completed future instead of
the guest write future failed the stalled-write assertion. Production code was
restored, and the full Swift suite passed with 28 offline tests and one skipped
live test. The restored build emitted no warnings; diff whitespace checks pass.

## Rust partial-header resource enforcement

Rust now accounts for unfinished header names/values and aggregate field bytes
while httparse reports a partial request. The accounting only enforces byte
budgets; httparse still owns syntax and framing. This prevents an oversized
unfinished field from occupying the connection until the 10-second header
deadline. Complete requests continue through the existing parsed-header checks.

The shared raw-wire corpus now includes unfinished oversized names, values,
and aggregate blocks. Each leaves the client socket open, requiring a prompt
431 response rather than relying on EOF. A pure boundary test covers an exact
16 KiB field and exact 64 KiB aggregate, followed by one excess byte.
On 2026-09-27, all 140 corpus executions passed across both providers and both
confined implementations. Disabling partial-header accounting caused the corpus
to fail on its read deadline; restored code passed. Rust's 39 unit and 10
process/socket tests pass, as do workspace clippy, formatting, and diff checks.

## Language-neutral raw HTTP fuzz gate

The shared socket harness now supports `--fuzz-cases`, deterministic `--seed`,
and saved-input `--replay`. Mutations affect request lines, framing headers,
control/binary bytes, whitespace and field lengths. Generated inputs never
contain the valid capability, so they cannot authorize provider operations.
Fuzz exchanges half-close their write side, bound response reads, check local
refusal status/process survival/secret-free output, and periodically verify
readiness. Fixed corpus cases continue to require exact Rust/Swift status parity.
Input exchange failures save wire bytes and seed/index metadata for reproduction.
Runtime panic diagnostics are also failures, including task panics that leave
the Rust process alive.

On 2026-09-27, seed 20260927 passed 10,000 inputs against each provider on each
confined executable: 40,000 fuzz exchanges plus all 140 fixed refusal checks.
The first large attempt exhausted the client's ephemeral ports on macOS; its
saved input passed replay. The harness now retries only EADDRNOTAVAIL for a
bounded 45 seconds. It does not retry parser/status/crash/response-timeout errors.
Authenticated streaming and TLS differential tests remain separate open gates.
An injected per-connection Rust panic was detected by the harness despite the
listener remaining alive. The production source was restored and rebuilt; the
140 fixed checks and a further 2,000 seeded fuzz exchanges passed afterward.

## Local transition archive

The dual-build script accepts `--archive PATH`, producing an atomically replaced
local tarball containing the Apple-backend `iso`, `iso-proxy-rs`,
`iso-proxy-swift`, project license, binary checksums, and build metadata.
Metadata records macOS 27/arm64, the Rust default, source revision, dirty-tree
status and local-build status. The runtime remains a separate installation.
This prepares a concrete dual-implementation artifact without changing the
published Lima release workflow, installer, or update verification chain.
On 2026-09-27 the debug archive was built and inspected: exact entries,
executable modes, backend/default/source metadata, and all binary SHA-256 values
matched the staged artifacts. Both rebuilt proxies then passed all 140 shared
refusal checks under Seatbelt. Published release packaging remains an open gate.

## Swift policy mutation tooling

The four required policy files now have a pinned Muter configuration and a
runner that uses a disposable package copy, records source/tool hashes, retains
logs, and rejects survivors or non-assertion failure outcomes. The initial
upstream run reported 30 survivors, but inspection showed zero generated
mutation switches; that run is invalid coverage evidence. A checked-in patch
retains SwiftSyntax node identity across discovery and instrumentation and
visits nested blocks before replacing their parents. The runner verifies each
file's switch count against its reported mutant count. The patched run has
all 30 switches and a passing baseline. On 2026-09-27 it reported:

| File | Test failures | Runtime traps | Survivors |
| --- | ---: | ---: | ---: |
| Capability | 7 | 0 | 0 |
| HeaderPolicy | 5 | 0 | 0 |
| OperationPolicy | 5 | 0 | 0 |
| RequestTarget | 12 | 1 | 0 |

The one runtime outcome replaces `index + 2 < bytes.count` with `>` in the
percent-escape bounds guard. Applying that exact change directly to the clean
disposable package reproduced `Index out of range` in
`rawTargetsCannotChangeAuthority`; restoring it passed all eight core tests.
This is a reviewed mutant-induced trap, not an assertion kill. The runner
continues to exit nonzero for this outcome so future runtime failures require
inspection. No build errors or timeouts occurred, and all four recorded input
hashes match production source. Artifacts are retained locally under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-proxy-muter-tti5n8zi`.
The separate mandatory targeted-regression mutation checks remain applicable.

## Rust mutation sweeps and survivor triage

On 2026-09-27, cargo-mutants 27.1.0 started full-file sweeps of host
`src/proxy.rs` (38 mutants, Apple backend feature, library tests) and reference
`config.rs`, `inbound.rs`, `request_body.rs`, `proxy.rs`, `startup.rs` (230
mutants, binary unit tests). Both unmutated baselines passed. These runs use isolated source copies.
The host sweep finished with 35 caught, two missed and one unviable mutant
(`ProxyImplementation` has no `Default`). Both misses were fixed and caught
in the targeted rerun: zero unresolved host survivors. The 230-mutant reference sweep finished with 119 caught, 46 missed, 63
unviable and two scanner-loop timeouts. Survivor dispositions follow below.

The first host survivors exposed missing assertions for non-UTF-8 selector
rejection and the unsupported-Swift platform diagnostic. Both assertions now
pass, and a targeted rerun caught both mutants (zero missed). Reference
preface survivors exposed absent tests for simultaneous maximum target/header
sizes and the exact raw buffer ceiling. New real-socket tests assert acceptance
at the valid maximum, rejection of an unfinished method without EOF, and that
bytes beyond the read budget remain unread. The targeted rerun caught all 12
selected preface mutants (zero missed, unviable or timeout).

`.cargo/mutants.toml` now narrowly excludes equivalent empty `Secret` Debug
output (still no credential disclosure), plus `read_config`, whose stdin pipe
is exercised by executable gates. `decode` remains in scope. The initially
proposed `disable_core_dumps` exclusion was removed after inspection showed
that existing gates did not check its limits: a new subprocess unit test now
checks both soft and hard limits are zero, starting with a nonzero soft limit
when the inherited hard limit permits it. Its targeted mutation run caught both mutants
under `/tmp/iso-core-limit-mutation`. Listing mutants verified the exclusions.
The original sweeps retain their original configuration and source snapshot,
so their reports still include these newly triaged cases.

Logs/artifacts:

- `/tmp/iso-host-proxy-mutation.log` and `/tmp/iso-host-proxy-mutation/mutants.out`
- `/tmp/iso-reference-proxy-mutation.log` and `/tmp/iso-reference-proxy-mutation/mutants.out`
- `/tmp/iso-selector-mutation-recheck/mutants.out` (2 caught)
- `/tmp/iso-preface-mutation-recheck/mutants.out` (12 caught)

Further survivors in `validate_head` prompted a direct table of exact/over-limit
field, aggregate and target sizes, HTTP version, absolute targets and conflicting
framing headers. All six inbound unit tests pass. The full `validate_head` mutation rerun
caught all 25 mutants (zero missed, unviable or timeout) under
`/tmp/iso-head-mutation-recheck`, with console log
`/tmp/iso-head-mutation-recheck.log`. Reference-proxy all-target
clippy passes with warnings denied. Host proxy unit tests passed. `taplo` is unavailable
on the current PATH, so its formatting check has not run for these exclusions.

The raw-target sweep exposed missing cases with one invalid percent-escape
nibble and invalid bytes after a valid escape. These cases are now in the
request-target test. The full `valid_target` rerun under `/tmp/iso-target-mutation-recheck`
finished with 26 caught and two timeouts, zero survivors. The timeouts replace
forward scanner increments with subtraction or multiplication, causing loops
on valid inputs; they are mutant-induced hangs, not assertion kills.

A new socket assertion checks the exact complete empty refusal response;
removing `refuse` is now caught (one-mutant rerun under
`/tmp/iso-refusal-mutation-recheck`). The response-body test now checks
`GuardedBody` end-of-stream and size hints before and after consuming its
payload; its targeted sweep finished with four caught, 15 unviable and zero
survivors under `/tmp/iso-guarded-body-mutation`. Corrected the executable-test header to avoid
claiming that the VM suite covers admitted forwarding.

The serving/admission rerun caught all 11 generated mutants (zero survivors,
unviable or timeout) under `/tmp/iso-admission-mutation-recheck`. New tests
check rejection of a non-loopback configuration at `serve`, exact field limits,
method denial, body-size/trailer rejection and capacity ordering over real
loopback HTTP. The test context has zero upstream permits, preventing provider
contact even if a gate mutation permits a denied request. Reference clippy
passes with warnings denied. The full reference package unit/executable test
suite passed after these changes (`/tmp/iso-reference-mutation-suite.log`).

One `operation_allowed` survivor changes the final `||` to `&&`. Inspection of
pinned `http` 1.4.2 `Uri::from_parts` confirms scheme requires authority, and
an authority with a path requires scheme. Authority-only targets have no
allowed operation path. Therefore the mutated condition accepts no additional
allowed operation: this survivor is equivalent for the parsed URI input type,
not a test kill. Its exact operator/column now has a documented exclusion;
method and other policy mutations remain listed. The static `Failure` Display
body replacement also has a narrow exclusion: rejection status comes from the
typed failure, and dropping its static text changes no secrecy/status contract.

### Completed reference survivor dispositions

| Initial survivor group | Count | Disposition |
| --- | ---: | --- |
| Preface buffer/read budget | 10 | New socket tests; targeted mutants caught |
| Complete header validation | 14 | Boundary/framing tests; targeted mutants caught |
| Raw target scanning | 2 | Mixed hex and post-escape invalid bytes; caught |
| Refusal write | 1 | Exact socket response; caught |
| Guarded response metadata | 3 | End/size assertions; caught |
| Serving/admission | 7 | Real local HTTP and bind-boundary tests; caught |
| Forwarding | 2 | Real local TLS fixture; caught |
| Upload size hint | 1 | Before/after metadata assertions; caught |
| Startup byte limit | 1 | Literal 65,536-byte contract test; caught |
| Core limits | 2 | Isolated-process limit inspection; caught |
| Secret Debug, Failure Display, URI connector | 3 | Reviewed equivalents, narrow exclusions |

All 46 original survivors are accounted for: 43 now caught and three reviewed
equivalents. The last targeted run (`/tmp/iso-forward-mutation-recheck`)
reported five caught, two unviable and zero missed. The host has zero unresolved
survivors as recorded above. `.cargo/mutants.toml` changed; listings confirm the
policy's method and other operators remain in scope.

The new Rust forwarding fixture in `iso-proxy/src/forward_tests.rs` exercises
both providers through the actual raw preface, authorization, rewrite, TLS,
Hyper forwarding and response-filter path. It verifies payload/query fidelity,
credential replacement, nominated-header removal, duplicate response headers,
redirect passthrough and no decompression. Only unit-test builds contain its
loopback destination override; TLS still validates the fixed provider hostname
against an explicit test CA. Public fixture keys/certificates are documented in
`iso-proxy/src/testdata/README.md`. The first fixture attempt revealed Hyper
was overwriting its Connection header when keep-alive was disabled; explicitly
sending `x-private, close` preserved the intended wire nomination and the test
then passed. This was a fixture issue, not evidence of a proxy filtering bug.

The full reference package suite passed after the fixture/helper edits, and
all-target clippy passed with warnings denied. This fixture was subsequently
extended into the shared admitted corpus described below.

## Shared admitted-request corpus

Six admitted cases now live in `tests/fixtures/credential-proxy/forwarding.json`
and are consumed by both Rust and Swift tests. They cover Anthropic API-key and
bearer injection, message creation and token counting, OpenAI responses, raw
queries (including empty query and mixed-case escapes), UTF-8 request data,
200/307/429/503 provider statuses, nominated header removal, duplicate response
headers and byte-preserving response passthrough. Both fixtures exercise real
TLS with compiled provider hostname verification and loopback-only destinations.

Apple SecTrust rejected the original ten-year leaf with an explicit maximum
validity-period error, while Rust accepted it. This was a fixture incompatibility:
shared tests now use the same generator to create one-day leaf certificates and
two-day test CAs in disposable directories. Swift retains `.default` trust plus
an additional test anchor. Host trust is unchanged; checked-in forwarding keys
were removed. The pre-existing untrusted-certificate rejection fixture remains.

`python3 scripts/test-proxy-forwarding-corpus.py` orchestrates both tests and
retains logs, selected commands and corpus hash. The combined run passed all
six cases in each implementation; evidence is retained under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-nnu1coku`.
Rust all-target clippy passed after the fixture changes. That initial run
checked shared expected values; observation comparison was added as described
below. Broader shared TLS-failure and streaming/resource cases remain open.

## Forwarding observation comparison

Both shared admitted-case tests now optionally write raw observed method,
path/query, upstream request count, request/response header pairs, response
status and body byte arrays. The runner computes SHA-256 over actual captured
bytes and compares every field across Rust and Swift. It normalizes only header
name case and pair ordering; duplicates and all header names/values remain.
Captured Host and injected credentials identify the selected provider. The
Connection header is compared; physical EOF checks were subsequently added as
described below.

The first comparison detected Hyper's auto-generated Date header, absent from
the NIO fixture. Both upstream fixtures now send the same explicit corpus Date,
so the proxies receive equivalent inputs. All six normalized observations then
matched. Altering captured request bytes, response bytes, path, status, duplicate
header cardinality or upstream count caused the comparison to fail; changing
only header case/order still passed. Evidence from the initial passing run is
under `/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-2pmix2n5`.
The final orchestrated rerun also passed under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-zxs8c40v`.
Rust all-target clippy and format checks passed. These observations close the
admitted-case comparison gap. Physical-close coverage was added next; shared
resource/timeout/TLS-failure cases remain open.

## Physical close after admitted responses

All six admitted corpus cases now use guest probes that keep their write side
open and do not close merely because a response advertises `Connection: close`.
Rust reads the socket through EOF with a five-second deadline and parses the
complete fixed-length response. Swift uses NIO's response decoder to collect
one head/body/end, then requires channel inactivity without a client-initiated
close. Both add `connection_closed` to the compared observations.

The combined run passed all cases with matching observations; evidence is in
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-6j0a4u1u`.
In isolated source copies, removing the successful-response close in Swift
failed the explicit peer-close assertion after five seconds; enabling Rust
keep-alive failed its socket EOF deadline. Both mutations compiled and failed
in tests. Artifacts are under `iso-peer-close-mutation-yafb0i9z` and
`iso-rust-close-mutation-l4row6nh` in the same temporary parent. The working
sources were not mutated. Rust clippy passed with warnings denied.

These checks cover ordinary admitted responses in the six current corpus
cases. Early disconnects, long streams, resource saturation and failure-path
close behavior still need their broader shared cases.

## Shared certificate-failure corpus

The shared corpus now contains 14 cases: six admitted forwards and eight TLS
failures, covering untrusted CA, self-signed leaf, wrong hostname and expired
leaf for both providers. The common generator produces these certificate
variants; trust remains fully enabled. Each failure requires a local 502,
physical peer closure and zero HTTP requests received by the TLS fixture.
Both tests also reject disclosure of either synthetic credential in diagnostics.

Failure observations compare status, upstream HTTP count and closure. They do
not compare local error prose or its content headers, consistent with the
spec's implementation-specific error-text allowance. Successful observations
still compare all captured headers and byte hashes. The runner validates the
complete schema for each case type, preventing omitted fields from silently
passing comparison.

The 14-case combined run passed with matching observations under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-n1ut_16h`.
Disabling Swift TLS verification in an isolated package copy caused all eight
negative cases to detect upstream HTTP delivery and fail (artifact:
`iso-corpus-tls-mutation-o_ptza0t` in the same temporary parent). This confirms
that a provider-style 502 cannot hide credential delivery from the assertions.
Working production sources were unchanged. Rust all-target clippy passes.
A final rerun including diagnostic-redaction assertions also passed under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-d4o6gp88`.
Shared DNS/connect-timeout and streaming/resource failures remain open.

## Shared establishment-deadline cases

The corpus has 16 cases after adding a peer that accepts TCP and then never
answers the TLS handshake, for both providers. Tests use the production
30-second establishment settings, require local 502 with zero HTTP requests,
and require closure of both guest and stalled upstream sockets. Raw elapsed
milliseconds are retained; comparison validates the same 29–35 second bounds
rather than requiring identical scheduler timing.

The combined run passed under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-5cpzwh67`.
Rust returned after 30,004 ms for each provider; Swift after 30,011 ms for each.
Upstream sockets were released in both implementations. Rust clippy passes.
These cases cover a stalled TLS handshake within the establishment budget;
they do not substitute for a DNS error or an unanswered TCP connect.

An isolated Swift mutation shortening the bridge establishment deadline to one
second was rejected. Its first run hit the upstream-release assertion because
the client retained its original 30-second connection deadline. Checking elapsed
time first made the focused rerun fail directly at 1,009 ms versus the 29,000 ms
lower bound (`/tmp/iso-short-deadline-recheck.log`). The mutation exists only in
`iso-deadline-mutation-9srg0j8s` in the temporary directory, not working sources.
The ordinary matching 30-second settings passed the release check; prompt
cancellation during an in-flight handshake remains a distinct case to audit.

## Shared DNS failures

The forwarding corpus now has 18 cases, including DNS failure for both
providers. Test-only destination routing uses `iso-proxy-test.invalid`; the
compiled provider hostname remains the TLS identity. Rust verifies resolver
rejection before exercising forwarding. Swift checks the A/AAAA errors inside
NIOConnectionError are typed UnknownHost failures for the reserved name, with
no TCP connection attempts. Both require local 502, zero upstream HTTP requests,
physical guest closure and no synthetic secrets in the response.

The complete 18-case run passed with matching observations under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-b2r2bw68`.
The first Swift assertion incorrectly expected an unwrapped resolver error;
inspection of pinned NIO's HappyEyeballs implementation identified its wrapper,
and the corrected typed assertion passed. Rust all-target clippy passed.
The negative-case manifest field is now `establishment_failure`, covering DNS
and TLS without implying that DNS failure reached a TLS handshake.
Swift fixture properties use camel case with explicit shared JSON key mappings;
strict Swift formatting lint and the final focused 18-case Swift rerun passed
(`/tmp/iso-dns-swift-naming-recheck.log`).

## Shared slow-header deadlines

The confined refusal corpus now has 37 cases. Two new cases hold an incomplete
header open; one also sends additional bytes after six seconds. They require
HTTP 408 and physical peer closure between nine and thirteen seconds from the
initial write. The harness enforces an absolute receive deadline, including
the deliberate delay, so resetting the proxy timer on progress cannot pass.

All 37 cases passed for both providers and both real executables under the
production Seatbelt profile (148 exchanges; `/tmp/iso-slow-headers-contract.log`).
An isolated copy of the current Rust proxy with its initial-header timeout
extended from ten to sixty seconds compiled successfully and was rejected by
the receive deadline in the first shared case. Evidence is under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-header-deadline-mutation-ksviejpp`.
No working production timeout was changed. This adds shared slow-header
coverage; body-idle, held-stream capacity and whole-process memory cases remain.

## Shared production idle-socket capacity

The confined raw harness now exercises the production 256-connection allowance
for each provider and implementation. It holds 256 idle sockets, requires eight
additional sockets to close without any HTTP input, then completes every held
socket with a local 401 and physical closure. It refills the entire allowance,
disconnects all guests, and refills/completes it once more. Five-second round
deadlines prevent the ten-second header timer from masking a leaked slot.
HTTP recovery probes verify admission rather than relying on successful TCP
connect alone. All sockets are closed on test failure.

The focused run passed all four implementation/provider combinations
(`/tmp/iso-idle-capacity.log`). Isolated copies of the current Rust proxy with
limits of 255 and 257 compiled and were rejected by the shared harness: 255 lost
a held socket and 257 left the excess socket open. Mutation logs and the report
are under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-idle-capacity-mutation-dnxf95av`.
`--capacity-only` runs this gate alone; the default refusal run also includes it.
This establishes idle connection capacity and reuse, not the distinct in-flight
upstream response limit or slow-reader memory bound.
The full run also passed all 148 refusal exchanges, including both slow-header
cases, after the shared response-reader extraction
(`/tmp/iso-capacity-full-contract.log`). Python parsing and whitespace checks
passed. Production proxy code was not changed for this gate.

## Rust real TLS stream capacity

Added `stream_capacity_tests.rs`, a socket-level test using the real Rust accept,
authentication, TLS forwarding and response-body paths. For both providers it
holds 256 responses after the first SSE chunk, asserts zero available request
and connection permits, and sends a 257th authenticated request which must be
closed. Two rounds verify full recovery: abrupt guest disconnects, then normal
response completion. Each round requires all 256 upstream TLS sockets to close
as well as both permit counts to recover. Guest HTTP client senders remain alive
while normal completion waits for the proxy's EOF.

The focused test passed for both providers (1,024 admitted TLS streams across
the four rounds), and all-target Rust clippy passed with warnings denied.
Logs: `/tmp/iso-rust-stream-capacity.log` and
`/tmp/iso-rust-stream-clippy.log`. An isolated mutation dropping the request
permit as soon as response headers arrive compiled and failed the explicit
held-permit assertion. Its evidence is under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-stream-permit-mutation-bwwm07fe`.
That mutation preceded the additional authenticated bytes on the excess socket;
the final working test including those bytes also passed. Production behavior
is unchanged; only test-fixture helpers gained sibling-module visibility.

Swift currently has an embedded 256-response permit test. A matching real TLS
socket test and shared observation comparison remain required; this Rust result
does not establish Swift's socket-level stream capacity.

## Swift real TLS stream capacity

Added the matching Swift socket test for both providers. It uses production
Server/StreamingBridge/client configuration with test-only DNS/port routing and
a per-evaluation test trust anchor. It holds 256 responses after their first SSE
chunk, rejects an excess authenticated request, completes or disconnects the
held streams, and requires all upstream sockets to close. Both implementations
now perform three rounds (disconnect, completion, disconnect), proving full
refill after both cleanup paths. Swift's embedded lease tests remain necessary
to isolate request-permit lifetime from the equal connection cap.

The first fixture incorrectly awaited a buffered write before flushing; that
was corrected. Its initial server pipeline also suppressed reads while waiting
for response completion. The labeled failure was upstream closure after the
first disconnect round, and live socket inspection showed fixture sockets in
CLOSE_WAIT. Disabling test-server pipelining assistance, as in the existing
lifecycle fixture, allowed it to observe peer EOF. The corrected two-round run
passed in 4.983 seconds (`/tmp/iso-swift-stream-capacity-fixed.log`).

An isolated Swift mutation lowering the connection cap to 255 was rerun with
the corrected fixture and failed at the first chunk of guest 256. Evidence:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-swift-stream-capacity-mutation-jbppk0iv/mutation-fixed.log`.
Its earlier failure with the faulty EOF fixture is not relied upon. Production
proxy behavior was not changed. Automatic comparison of the stream-capacity
observations remains open.
The final three-round runs passed for both languages and providers (1,536
admitted TLS streams per implementation). Logs are
`/tmp/iso-stream-capacity-rust-final.log` and
`/tmp/iso-stream-capacity-swift-final.log`; Swift completed in 7.278 seconds.
Strict Swift formatting lint and whitespace checks passed.

## Compared TLS stream-capacity observations

Both real TLS tests now emit optional structured observations through the
test-only `ISO_STREAM_OBSERVATIONS` path. Rust counts actual fixture HTTP
requests and socket closes atomically; Swift records admitted provider channels
and their close callbacks. Per-round observations include held responses,
upstream request/closure counts, bytes returned to the excess request and
normally completed responses. These are taken after the existing behavioral
assertions, not substituted for them.

`scripts/test-proxy-stream-capacity.py` runs both selected tests, rejects an
empty test selection, validates all six provider/round records against the
contract and compares them. It preserves raw observations, logs, commands and
outcomes. The combined run passed under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-stream-capacity-ncm5he39`.
All 1,536 streams per implementation were exercised. A later field-type check
was validated against these same captures without rerunning network work.

Ten deliberately corrupted captures (changed counts, missing/duplicate rounds,
an unexpected field and a boolean in place of an integer) were rejected, as was
an explicit comparison mismatch. Reordering records alone remained accepted.
The checks are recorded in `tripwire-check.json` beside the captured evidence.
Rust all-target clippy, strict Swift formatting lint and whitespace checks pass.
This completes the previously open automatic capacity comparison; body-idle,
long-lived response and whole-process memory gates remain separate work.

## SSE responses beyond the establishment budget

The compared capacity test now keeps all 256 completion-round responses open
for 31 seconds after the first SSE chunk, for each provider. It then sends the
final chunk and requires normal completion. Rust checks both live permit counts
and absence of upstream closure during the hold; Swift checks every guest is
still open. Existing final-body and closure assertions remain in place.
Observations retain the measured hold duration. The runner validates 31–36
seconds, then removes timing from equality comparison; disconnect rounds must
record zero hold time. This covers a silent response interval past the
30-second establishment budget, not arbitrary-duration timing claims.

An isolated Swift mutation removing the establishment-timer cancellation on
successful request-head transmission compiled and failed at the explicit
"stream closed before final SSE chunk" assertion. It finished in 35.500 seconds;
evidence is under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-long-sse-mutation-vhiblw7n`.
Six invalid duration variants were rejected by the validator, while two valid
durations normalized identically. Rust clippy and strict Swift formatting lint
passed. No production timeout was changed.
The combined run passed all six rounds with matching observations under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-stream-capacity-hfz497j6`.
The Rust wait was subsequently extracted into a test helper to satisfy clippy's
function-length limit; its operations are unchanged, and clippy checked the
extracted version. Body-idle timeout and whole-process memory gates remain open.

## Rust real TLS body-idle reset and cancellation

Added `body_idle_tests.rs`. For each provider, a raw guest advertises a
three-byte request body, sends `a`, waits 15 seconds, and sends `b`. The TLS
fixture must observe each byte before the guest finishes its upload. Guest
read-through-EOF then requires local 408 between 44 and 51 seconds after the
initial write. This distinguishes an idle timer reset by progress from a total
request timeout. The upstream upload must remain incomplete, its socket must
close, and both request/connection permit counts must recover to 256. Local
diagnostics are checked for synthetic credential disclosure.

The two provider cases run concurrently and passed in 45.44 seconds
(`/tmp/iso-rust-body-idle.log`). All-target clippy passed with warnings denied
(`/tmp/iso-rust-body-idle-clippy.log`). An isolated mutation removing the reset
in `Upload::poll_frame` compiled and failed the elapsed-time assertion at about
30 seconds. Evidence is under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-body-idle-mutation-w2ea2weu`.
Optional observations are available through test-only `ISO_IDLE_OBSERVATIONS`.
Production behavior is unchanged. A matching Swift socket-level body-idle case
and differential comparison remain open.

## Compared Swift/Rust body-idle behavior

Added Swift's matching real TLS upload test and
`scripts/test-proxy-body-idle.py`. The Swift cases run concurrently for both
providers and use production gate/bridge/client configuration with test-only
DNS/port routing and temporary trust anchors. The test observes both partial
bytes at the provider before timeout, local 408 and physical guest closure,
incomplete upload and upstream socket closure. A first focused run passed in
45.561 seconds (`/tmp/iso-swift-body-idle.log`).

The combined runner passed both implementations and both providers with
matching observations under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-body-idle-m5wms_qs`.
It validates the exact observation schema, status, body bytes, completion and
closure states, plus the 44–51 second bounds, before comparing. Twelve altered
captures were rejected, including missing/duplicate providers, wrong body/status,
incorrect closure states and invalid timing/types. Record order and valid timing
variation normalize equally; `tripwire-check.json` records this check.

Removing only Swift's body-progress timer reset in an isolated copy compiled
and failed at about 30 seconds (one recorded duration was 30,011 ms), confirming
the new test distinguishes idle from total request timeout. Evidence:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-swift-body-idle-mutation-bo0p5xtf/mutation.log`.
Strict Swift formatting lint and whitespace checks pass. Production behavior
is unchanged. The body-idle differential gate is complete; memory, additional
streaming failure/boundary cases, integrations and release gates remain.

## Rust real TLS declared-body boundary

Added `body_limit_tests.rs` for both providers. The exact-limit case streams
64 MiB from a bounded 64 KiB test buffer and requires the fixture to receive
the first chunk before the remainder is sent. The provider hashes each frame
incrementally; the guest and provider SHA-256 digests must match. The second
case sends only headers declaring 64 MiB plus one byte and requires local 413,
physical guest closure and zero upstream TCP connections/HTTP requests. Both
paths require complete permit recovery and any upstream socket closure.

The final focused run passed in 3.11 seconds
(`/tmp/iso-rust-body-limit-final.log`), and all-target clippy passed
(`/tmp/iso-rust-body-limit-clippy.log`). Captures are in
`/tmp/iso-rust-body-limit-observations.json`; an independent Python calculation
matched the 64 MiB patterned body's SHA-256:
`98dc891b284e4d84ac25b0c0a24fdbe39a7f0dbd643ad5e8aa06e02fc6258254`.
The proxy crate adds `sha2` only as a test dependency, using the version already
present for the host crate. Test helpers hash and forward incrementally.

Isolated mutations changing the cap by minus/plus one byte both compiled and
failed: the smaller cap prevented initial upstream progress on the exact-limit
case; the larger cap prevented the oversized header-only request from receiving
its timely refusal. Reports and logs are under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-body-limit-mutation-wbpgp8r1`.
No production limit changed. Swift's matching socket gate and automatic
comparison remain open. Unknown-length streaming policy remains the previously
requested decision; this known-length gate makes no claim to resolve it.

## Compared Swift/Rust declared-body limits

Added Swift's socket-level 64 MiB boundary test and
`scripts/test-proxy-body-limit.py`. The test uses production transport settings
with temporary test trust anchors and fixed-provider DNS/port routing. It
requires the first 64 KiB to arrive before sending the rest, hashes incrementally
with CryptoKit, checks the complete expected SHA-256, and verifies zero upstream
TCP connections for a declared length one byte over the cap. The focused Swift
run passed in 7.571 seconds (`/tmp/iso-swift-body-limit.log`).

The combined run passed four provider/length records in both implementations,
with matching counts, digests, status and closure under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-body-limit-w6pwffxv`.
Fifteen corrupted captures were rejected, including wrong digests, body lengths,
closure states, unexpected upstream activity, missing/duplicate cases and
invalid field types. The verifier preserves raw observations and command logs;
its deliberate-corruption checks are recorded in `tripwire-check.json`.

Isolated Swift cap mutations of minus/plus one byte both compiled and failed.
The smaller cap caused an I/O-on-closed-channel failure during the exact-limit
upload; the first mutation driver expected the later progress assertion, so its
result check was corrected to reflect that observed failure. The larger cap
failed the prompt-refusal/closure assertion. Logs and the final report are under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-swift-body-limit-mutation-qfo6oe0j`.
Strict Swift formatting lint and whitespace checks pass. Production behavior
is unchanged. The known-length differential boundary gate is complete; the
unknown-length policy decision and memory/integration/release gates remain.

## Swift stalled-reader RSS and socket backpressure

Added an opt-in, isolated-process memory test and
`scripts/test-swift-proxy-memory.py`. The test uses production transport/client
settings with a verified local TLS fixture and a guest socket that never reads.
The provider retains one 64 KiB buffer and awaits each flush. After TLS setup,
Mach resident-size samples measure the entire test process (proxy plus bounded
provider/guest fixtures). The gate checks less than 32 MiB growth, less than
16 MiB upstream progress, a three-second progress plateau within twenty seconds,
and upstream/producer cancellation when the guest closes.

The first timing assumption sampled progress at fixed two/five-second offsets
and rejected a further 320 KiB of socket-buffer progress. The revised gate waits
for an observed three-second plateau and preserves raw samples, including on
failure. It does not increase the memory or total-progress budgets.

Separate processes offering 256 MiB and 1 GiB passed under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-4tijl30g`.
Both plateaued after 1,048,576 upstream bytes. RSS growth was 704,512 and 688,128
bytes respectively. An isolated mutation ignoring ResponseRelay's guest-write
future sent all 268,435,456 offered bytes and grew RSS by 1,063,944,192 bytes,
failing the memory assertion. Evidence is under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-mutation-gwpu6vxr`.
Seven corrupted memory reports were rejected by the runner's validator.
Strict Swift formatting lint and whitespace checks pass.

These are regression budgets for one stalled response, not a production RSS
promise. Upload-direction, malformed-client and aggregate concurrent-client
memory measurements remain distinct work. The test does not run under Seatbelt;
the production-profile confinement gates remain separate. No production behavior
or sandbox permission changed.

## Full workspace and hook verification

The full `cargo test --workspace` run passed: 1,213 host tests, 51 proxy
unit tests and ten proxy integration gate tests; one doctest was ignored.
The full Swift package run passed its 26 transport and eight policy tests.
The opt-in live TLS and memory cases were skipped in that full run; their
separate evidence is recorded above. Logs are `/tmp/iso-full-workspace-tests.log`
and `/tmp/iso-full-swift-proxy-tests.log`.

Both workspace clippy configurations passed with warnings denied (default and
`apple-container`). Rust formatting, strict Swift formatting lint, pinned
Taplo 0.10.0 and cargo-deny 0.19.9 checks passed. Swift lint required replacing
two cleanup `forEach` calls with `for` loops in Jail and Signals. The executable
was rebuilt afterward and the production-profile process gate passed with
`--skip-tls`; the full Swift suite preceded those cleanup-only edits.

Pinned prek 0.4.8 checked the task files, excluding the user-provided specification.
Its trailing-whitespace hook cleaned the Muter patch. Reverse application was
checked successfully against the patched, exact pinned Muter revision
`7f1f2584e0a27fc05c952a5c8cdd52b10cc9513f`.
A subsequent hook run failed the existing
`port_forward::tests::collision_check_passes_when_ports_free` test. That test
passed immediately in isolation, and the final full hook rerun passed all hooks
(`/tmp/iso-prek-final.log`). The test releases selected ephemeral ports before
checking them, so concurrent reuse is a possible explanation, not an established
cause. No port-forward source changes were made. `git diff --check` also passed.

These checks do not substitute for the outstanding platform integration,
live provider, security review or release/observation gates.

## Confirmed TLS establishment cancellation gap

The previous verification turn completed gates and recorded evidence (progress).
The next audit reproduced a concrete unmet cancellation requirement in the
pinned AsyncHTTPClient 1.36.2 dependency. Added the opt-in
`auditCancellationDuringTLSHandshake` reproducer and documented its invocation
in `docs/testing.md`. It uses the production client configuration against a local
TCP fixture that receives ClientHello but never answers; no credential, trust
exception, or production endpoint is involved.

The final run (`/tmp/iso-handshake-cancellation-audit-final.log`) failed exactly
the prompt socket closure assertion. The request returned
`HTTPClientError.cancelled`, the upstream socket remained open two seconds later,
and client shutdown completed 30.0008 seconds after cancellation. After allowing
the fixture event loop to observe EOF, the socket was closed. The initial probe
also reproduced the delayed cleanup; its immediate post-shutdown snapshot had
not yet observed EOF. The final probe explicitly polls for that observation.

Source inspection confirms the mechanism: HTTP1StateMachine.cancelRequest
removes the queued request with connection action `.none`; HTTP1Connections
cleanup documents that connection starts cannot currently be cancelled.
ConnectionFactory invokes the public HTTP/1 debug initializer only after TLS
negotiation, so that hook cannot provide ownership of the stalled handshake
socket. A shorter bridge deadline or calling HTTPClient.shutdown does not fix
this. The transport needs cancellation ownership during connection establishment
before the cutover gate can pass. The reproducer is opt-in and explicitly marked
as currently failing; a default-suite skip must not be counted as acceptance.
Strict formatting lint and `git diff --check` pass. No production behavior was
changed in this audit.

## Owned TLS socket component for cancellation repair

The prior turn reproduced a concrete cancellation failure (progress). Added
`CancellableTLSConnection`, a direct SwiftNIO/NIOSSL component which registers
socket candidates before TCP connect and owns them throughout TLS. Cancellation
fails the pending result and closes all candidates; candidates created by late
DNS results are rejected before connect. The thirty-second establishment timer
covers TCP/TLS and is cancelled after verified TLS completes. Candidate ownership
is synchronized across cancellation and event-loop callbacks. TLS handlers are
installed only on the TCP winner, so losing Happy Eyeballs candidates cannot
fail its handshake.

Extracted the existing TLS configuration into `UpstreamClient.tlsConfiguration()`
for both clients to use. Full verification, system trust, no extra production
roots, and HTTP/1 ALPN remain selected. Added a direct NIOTLS target dependency
from the already pinned swift-nio package; no dependency version changed.
The internal fixture seam allows a local endpoint and deferred resolver without
adding startup options.

Four new tests cover both provider identities, prompt stalled/established socket
cancellation, late DNS candidates after cancellation, a short fixture handshake
deadline, removal of that deadline after success, untrusted CA and wrong-host
rejection. The restored-source run also included the existing upstream policy
configuration test: five tests passed in 2.552 seconds
(`/tmp/iso-owned-tls-restored.log`). Strict Swift lint and whitespace checks pass.
The production-profile process gate also passed with `--skip-tls`
(`/tmp/iso-owned-tls-process.log`), checking confined startup, bounded/redacted
startup handling, HTTP readiness, secret handling and shutdown.

Five deliberate mutations compiled and failed the relevant assertions: omitted
socket closure, disabled certificate verification, admitted late DNS candidate,
disabled hostname verification, and a timer left running after TLS succeeded.
The late-DNS mutation opened one unwanted TCP connection. The timer mutation
closed both successfully established provider sockets. Results and command logs
are `/tmp/iso-owned-tls-mutations.json` and the referenced log paths. Every
mutation was restored before the final passing run.

This component is deliberately staged and does not yet repair the forwarding
bridge: that bridge still uses AsyncHTTPClient. Next, attach the NIO HTTP pipeline
before TLS can deliver application bytes, adapt upload writers and response
callbacks to the owned connection, and change all controlled-upstream fixtures
to exercise that production path. Rerun streaming, cancellation, TLS, resource,
differential and confined-process gates on the replacement. A green component
test does not close the existing AsyncHTTPClient cancellation finding.

## HTTP forwarding now uses owned TLS connections

The prior component implementation and fault checks were progress. The production
StreamingBridge now calls OwnedHTTPRequest through UpstreamClient. Its HTTP/1
encoder/decoder and response handler are installed before TLS can emit decrypted
application bytes. AHC Request/Body values remain adapters, and the credential-free
TLS probe still uses the dedicated AHC client; forwarding no longer uses its pool.
ResponseRelay now exposes direct event-loop callbacks rather than an AHC delegate.
Every controlled bridge fixture was moved to the owned transport, including the
previous plaintext lifecycle, redirect and write-acknowledgment fixtures, which
now use verified local TLS with a per-evaluation CA.

The response pump gates further reads on guest flush completion and schedules
queue draining to avoid recursive completion through many tiny HTTP chunks.
UploadStream continues to await each actual upstream write. Informational heads
are skipped before the final response; upgrades are rejected. Cancellation closes
the underlying socket before the TLS handler, without waiting for close_notify.
The first corpus run took 90.515 seconds; after bypassing graceful TLS close on
cancellation/completion it returned to roughly sixty seconds, including the two
real thirty-second stalled-handshake cases.

Both provider cases of bridgeCancellationClosesStalledTLSHandshake passed in
0.029 seconds total. The migrated lifecycle tests cover partial/complete uploads,
guest disconnect, proxy shutdown and early responses; the exact guest-write
acknowledgment test passed too (`/tmp/iso-owned-http-lifecycle.log`). Mutating away
bridge cancellation failed both provider cases at the two-second assertion.
Ignoring the guest acknowledgment future also compiled and failed its dedicated
test. Logs and results are `/tmp/iso-owned-http-mutations.json`. Both mutations
were restored before the final full suite.

The final suite reported 32 transport and eight policy tests passed, with the
historical AHC audit, live TLS probe and opt-in memory test skipped. It includes
the migrated 64 MiB body boundary, forty-five-second body-idle reset, 256-stream
capacity and thirty-one-second silent-stream cases. Transport time was 71.323
seconds (`/tmp/iso-owned-http-final-suite.log`).

The native slow-reader memory gate passed for both offered sizes under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-wuxjdg3u`:
RSS growth was 311,296 bytes for 256 MiB and 344,064 bytes for 1 GiB, with upstream
progress plateauing at 1,048,576 bytes in both. This run preceded the final
upstream-header alignment below; it exercised the new asynchronous response pump.

The first differential comparison found only an extra upstream Connection: close
header in the six admitted cases. Removed that header; ownership already prevents
reuse. The failing comparison remains under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-a6ybyji1`.
The final rerun passed all eighteen cases in both implementations and exact
normalized observation comparison under
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-forwarding-corpus-3ejdzb3d`.
The production-profile process gate passed with `--skip-tls`
(`/tmp/iso-owned-http-process.log`); it waited for the live SwiftPM corpus process
before inspecting the built executable. Strict Swift lint and whitespace checks
also passed. This process gate covers startup, readiness, secrets and shutdown,
not a credentialed outbound request under confinement.

A concrete remaining resource audit is DNS/connection admission after cancellation.
Pinned NIO's GetaddrinfoResolver queues blocking resolution on an offload queue;
its cancelQueries is a no-op. Releasing guest/request capacity while those jobs
remain pending can admit further jobs. Happy Eyeballs also retains concurrent
candidate attempts. Add explicit admission ownership for underlying resolver work
and socket candidates, test it with deferred DNS under rapid cancellation, and
hold budgets through actual cleanup. This requirement is not satisfied merely by
closing a stalled TLS socket promptly. Production-profile outbound acceptance,
broader memory gates, integration, live agents and release gates remain open.

## DNS and socket admission survive request cancellation

The preceding owned-HTTP integration and verification were progress. Added a
client-wide budget of 256 underlying DNS lookups and a separate budget of 256
admitted upstream socket candidates. BoundedResolver starts one system lookup
through the pinned NIO resolver, preserves individual family results/errors, and
retains its lease until both underlying results finish. Cancellation fails the
request-facing futures but does not free that lease. Promises are created lazily,
so cancellation before lookup and literal-address bootstraps do not leave unused
promises. Socket candidates acquire admission before TCP connect, with the lease
owned by their close future rather than the request's cancellation state.

Controlled tests cancel 256 authenticated guest requests while DNS work remains
pending, verify that another lookup cannot start, finish the underlying work,
and verify recovery through the production UpstreamClient/Server path. Other
cases cover cancellation before start, completion of only one address family,
original lookup errors, and repeated access without another submission. Socket
fixtures cover both a one-socket budget (distinguishing it from guest admission)
and the actual default 256-socket budget, using two event loops. An initial
socket test caught that the new budget had not been passed into the request
constructor (`/tmp/iso-upstream-admission-tests.log`); correcting that wiring
made it pass. Internal resolver/capacity test seams add no startup options.

Four compiled mutations failed their relevant tests: releasing a DNS lease on
cancellation, releasing it after only one family, releasing socket admission
before close, and reducing the default socket budget to 255. Results/logs are
`/tmp/iso-admission-mutations.json`. The restored full Swift suite reported
37 transport and eight policy tests passed in 71.199 seconds
(`/tmp/iso-admission-full-suite.log`); the live TLS, memory and historical AHC
audit cases remained explicitly skipped.

A subsequent fixture deliberately delayed the transport close after cancellation.
It verified that the socket stayed active and its slot remained occupied until
close completed, then recovered that slot. The focused run passed in 0.030 seconds
(`/tmp/iso-delayed-close-admission.log`). Releasing admission early compiled and
failed exactly the still-open-slot assertion
(`/tmp/iso-delayed-close-mutation.log`). That mutation was restored before final
verification. All six focused admission tests then passed together in 0.629 seconds
(`/tmp/iso-admission-restored.log`). The rebuilt executable passed the confined
startup/readiness/secret/shutdown process checks with `--skip-tls`
(`/tmp/iso-admission-process.log`). Strict Swift lint and whitespace checks pass.

These tests establish admission and cleanup bounds, not aggregate RSS limits.
The production confinement probe still uses the dedicated AHC client; direct
owned-transport outbound confinement acceptance and broader memory, VM, live-agent,
security-review and release/observation gates remain open.

## Confined DNS/system TLS probe uses the owned transport

The preceding admission implementation and verification were progress. Replaced
the AHC-based HEAD probe with CancellableTLSConnection using the same bounded
resolver factory, socket budget, fixed provider identity and system-trust TLS
configuration as forwarding. It waits for verified TLS, closes the owned socket,
and awaits physical closure. Swift task cancellation cancels that connection.
The probe sends neither an HTTP request nor a credential. The existing AHC
object remains for its event-loop reference/lifecycle API; its connection pool
is no longer used by this probe or forwarding.

The rebuilt executable passed the complete production-profile process gate
(`/tmp/iso-native-probe-confined.log`): unconfined refusal, strict startup and
redacted errors, HTTP readiness and shutdown, file/exec/egress denials, and live
DNS/system TLS for both Anthropic and OpenAI. Removing the exact trustd permission
from a temporary copy of the profile caused the required NIOSSLError failure.
No profile permission was added or changed.

A local stalled-TLS fixture checks cancellation and subsequent reuse of a shared
one-socket budget for both provider identities. It passed in 0.010 seconds
(`/tmp/iso-native-probe-cancel.log`). A compiled mutation removing the task's
cancellation handler failed both cases: each waited for the actual thirty-second
establishment deadline and returned establishmentTimeout instead of cancelled.
The run took 60.014 seconds; evidence is
`/tmp/iso-native-probe-cancel-mutation.json` and its referenced log. The mutation
was restored before final checks. The final focused run passed probe cancellation,
production socket admission (one and 256 slots), and the 256-cancelled-DNS workload
in 0.621 seconds (`/tmp/iso-native-probe-restored.log`). Strict Swift lint and
whitespace checks pass.

This closes the native DNS/TLS confinement probe gap. It does not establish
credentialed HTTP streaming or real-agent compatibility; those gates still need
the requested dedicated credential/model references. Broader resource, VM,
security-review, release and observation requirements remain open.

## Upstream disconnects and complete-response draining

Added a verified local TLS matrix covering both providers, closure before headers
and during an incomplete body, abrupt TCP closure and clean TLS shutdown, with
two rounds of each combination (16 exchanges). Guests keep their write side
open. Each exchange must produce prompt EOF: a single local 502 before headers,
or the original 200 and partial body without an appended error after headers.
One-slot connection/request budgets must recover after every exchange. The
matrix passed in 1.530 seconds (`/tmp/iso-upstream-disconnect-matrix.log`).

Three compiled deliberate faults were detected: omitting upstream-inactive
failure, leaving a started guest response open on failure, and losing capacity
return. None survived or failed to compile; all were restored. Evidence is
`/tmp/iso-disconnect-mutations.json` and its referenced logs.

A deterministic regression exposed a separate bug: a complete HTTP response
queued behind a pending guest body acknowledgment was discarded when the upstream
closed. The original handler prematurely finished and omitted the response end
(`/tmp/iso-completed-response-close-baseline.log`). OwnedResponseHandler now
records decoded HTTP completion and preserves that bounded queue on upstream
closure. Incomplete responses still fail, with an explicit incompleteResponse
error instead of a misleading pre-handshake error. The regression exercises the
actual handler and relay, requiring head/body/end to survive and completion to
wait for the guest acknowledgment.

The final full Swift suite passed 41 transport tests in 70.952 seconds and eight
policy tests (`/tmp/iso-upstream-close-full-suite.log`); the historical AHC audit,
live-provider test, and opt-in RSS test were skipped. Strict Swift lint and
whitespace checks passed. Shared Rust/Swift early-disconnect comparison remains
open; this evidence covers the native Swift transport.

## Shared early-upstream-disconnect comparison

Extended the native Swift disconnect test to emit observations and added the
same 16-exchange matrix through the Rust production bridge, using verified local
TLS, synthetic credentials, and one-slot connection/request budgets. Both cover
the two providers, closure before headers or during an incomplete body, abrupt
TCP closure or clean TLS shutdown, and two rounds. Provider body closure waits
for the guest to receive the partial body; the guest leaves its write side open
and requires peer EOF within two seconds. Both slots must recover before reuse.

`scripts/test-proxy-upstream-disconnect.py` validates the full observation matrix
and compares status, partial provider body, guest EOF and capacity recovery.
The first Rust assertion exposed an existing local-error message difference:
Rust sends `upstream request failed` in its 502 body, whereas Swift sends an empty
body. The runner checks each exact value and retains both raw records; only that
local message is excluded from the cross-implementation comparison. Provider body
bytes remain compared exactly. No production behavior changed in this step.

The final paired run passed all 32 exchanges:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-upstream-disconnect-tkqefebp`
and `/tmp/iso-shared-upstream-disconnect-final.log`. Rust proxy clippy with all
targets and warnings denied passed, as did Rust formatting, strict Swift lint
and whitespace checks.

A deliberate Rust fault corrupting the forwarded partial body compiled and
failed the test's bounded exchange (`/tmp/iso-rust-disconnect-corruption-mutation.json`).
An earlier fault suppressing one body-error poll notification survived
(`/tmp/iso-rust-disconnect-mutation.json`); this test does not establish coverage
of that individual notification path. Both faults were restored before the final
paired run. The preceding Swift three-fault evidence remains recorded above.

This closes the shared early-disconnect comparison gap for this matrix. It does
not establish upload/aggregate RSS, production confinement HTTP streaming, or
real-provider/agent acceptance.

## Upload-direction memory and backpressure gate

Added an isolated Swift transport workload for declared uploads of 16 MiB and
64 MiB. A verified local TLS provider stops reading after the request headers;
the guest offers its body using one reused 64 KiB buffer and awaits each write.
The production parser, upload stream and owned transport remain in the path.
Mach RSS samples include the entire test process after TLS setup. The workload
requires less than 32 MiB RSS growth, guest progress below 8 MiB, and a three-second
progress plateau within twenty seconds. These are regression budgets, not
advertised production memory limits.

The first run showed that disabling autoRead does not retract an outstanding TLS
read: 49,152 body bytes reached the fixture after headers. The fixture now bounds
its receive allocation and messages per read, and permits at most 64 KiB of
residual input rather than incorrectly requiring zero. No production change was
needed. After sampling, guest closure must stop the guest producer. Provider reads
are then resumed to drain socket buffers and observe EOF; this proves cleanup
after resumption, not cancellation latency while provider reads remain paused.

The memory runner now accepts `--direction response|upload|both` (default both),
executes every size in a separate process, validates all samples and exact
selected-test success, and retains observations. The final combined run passed:

| Direction | Offered bytes | RSS growth | Producer bytes sent at plateau |
| --- | ---: | ---: | ---: |
| Response | 268435456 | 262144 | 1114112 |
| Response | 1073741824 | 311296 | 1769472 |
| Upload | 16777216 | 163840 | 1835008 |
| Upload | 67108864 | 163840 | 1835008 |

Evidence:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-kv24phii`
and `/tmp/iso-bidirectional-memory-final.log`. Strict Swift lint and whitespace
checks passed. A deliberate fault ignoring the upstream upload write acknowledgment
compiled and failed the new progress assertion: all 16 MiB were accepted while
the provider was stalled, with 32,686,080 bytes of RSS growth. Evidence is
`/tmp/iso-upload-memory-mutation.json` and its referenced log/observation file.
The fault was restored before the final combined run.

These measurements cover one stream per process through local verified TLS.
Aggregate slow/malformed-client RSS and production-confinement HTTP streaming
remain unverified; this is not evidence for those broader requirements.

## Native upstream shutdown ownership

The lifecycle audit found that UpstreamClient.shutdown still shut down an idle
AsyncHTTPClient object after forwarding moved to owned native sockets. CLI guest
registry cleanup triggered cancellation, but the client did not itself own active
native operations during shutdown.

Added UpstreamWork, which serializes operation creation and shutdown admission
under one lock. It registers native HTTP requests and credential-free TLS probes,
removes completed work, rejects starts after shutdown, cancels the current snapshot
outside the lock and awaits operation completion. Repeated shutdown is safe.
The unused AsyncHTTPClient instance was removed; its request/body values and test
configuration adapter remain. Shutdown still precedes termination of the externally
owned event loop group. Physical socket closure is observed separately from
operation completion, and underlying uncancellable DNS work retains its existing
bounded admission lease until the resolver actually completes.

Extended the socket-admission fixture to shut down one or 256 pending HTTP
requests during stalled TLS, require completion within two seconds, observe both
provider and guest closure, and reject a subsequent request without another
upstream socket. The probe fixture also checks shutdown during a stalled handshake,
post-shutdown refusal and repeated shutdown. The expanded focused run passed in
0.650 seconds (`/tmp/iso-native-shutdown-expanded.log`).

A deliberate fault omitting native cancellation compiled and failed: the probe
waited 30.009 seconds for establishmentTimeout, violating both the two-second
shutdown bound and the required cancelled result. Evidence is
`/tmp/iso-shutdown-mutation.json` and its referenced log. The fault was restored
before final checks. Strict Swift lint and whitespace checks passed.

The final full Swift suite passed 42 transport tests in 70.951 seconds and eight
policy tests (`/tmp/iso-native-shutdown-full-suite.log`); the historical AHC
audit, live-provider unit test and two opt-in RSS workloads were skipped. The
complete production-profile process gate also passed
(`/tmp/iso-native-shutdown-process.log`): unconfined refusal, strict startup,
redacted diagnostics, readiness and shutdown, file/exec/egress denials, live
DNS/system TLS for both providers, and failure when the exact trustd permission
is removed. Lima/Firecracker integration and live credentialed HTTP remain open.

## Aggregate partial/malformed-header memory gate

Added an isolated workload through the production listener, parser and inbound
gate: 256 simultaneous incomplete headers, each 49,179 bytes, followed by an
oversized-field suffix. Every round requires all 256 clients to remain admitted
while partial, an excess connection to close without a response, exactly one 431
and EOF per malformed client, and zero forwarded request parts. Subsequent rounds
must refill the full allowance. Fixture response storage is capped at 4 KiB and
clients share one immutable input buffer.

`scripts/test-swift-proxy-aggregate-memory.py` runs two and eight rounds in
separate processes. It validates four Mach RSS samples per round (three while
headers are held, one after rejection), less than 96 MiB growth from baseline,
and less than 32 MiB additional growth after the first round. Samples include
the entire test process and fixture clients; these are regression budgets, not
production RSS guarantees.

The final restored runs passed:

| Rounds | Malformed-client refusals | RSS growth | Growth after first round |
| ---: | ---: | ---: | ---: |
| 2 | 512 | 28311552 | 360448 |
| 8 | 2048 | 28459008 | 409600 |

Evidence:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-aggregate-memory-y4y2wqh2`
and `/tmp/iso-aggregate-memory-final.log`. Strict Swift lint and whitespace checks
passed. A deliberate fault in the input-observation handler retained every raw
input buffer across closed connections. It compiled and failed the RSS assertion:
193,527,808 bytes of total growth and 148,586,496 bytes after the first round.
Evidence is `/tmp/iso-aggregate-retention-fault.json` and the corresponding
log/observation files. This was a simulated buffer-retention fault in the fixture,
not a production mutation; it establishes that the RSS tripwire detects retained
input. The fault was restored before final validation.

This covers aggregate parser buffering and repeated malformed-client churn.
Aggregate RSS with 256 simultaneous streamed request/response bodies and the
confined executable remains unmeasured. No production implementation changed in
this step.

## Aggregate memory for held TLS response streams

Added an opt-in isolated RSS mode to the verified-TLS stream-capacity fixture.
It runs the existing disconnect/completion/disconnect rounds for both providers,
with 256 held responses and an excess request per round. Completion rounds sample
Mach RSS throughout the 31-second silent interval before the final SSE chunk.
Every round also samples after establishment and cleanup. The fixture now keeps
admission counts separately and releases its closed-channel array after each
round, avoiding accumulated fixture references in the memory measurement.

`scripts/test-swift-proxy-stream-memory.py` validates the existing six-round
capacity contract plus memory sample coverage, peak arithmetic, a 256 MiB RSS
growth budget per provider and 64 MiB growth after the first round. These budgets
include provider, guest and proxy within one test process; they are not production
RSS guarantees. Initial validation passed all six rounds in 69.443 seconds, with
45,416,448 bytes maximum growth and 524,288 bytes maximum growth beyond a
provider's first round (`/tmp/iso-stream-memory-first.log` and its observation
file).

A deliberate fixture fault retained a separate 1 MiB buffer for every provider
stream. It compiled and failed the RSS assertion during the first round:
314,523,648 bytes of growth. Evidence is
`/tmp/iso-stream-memory-retention-fault.json` and its referenced log. This is a
simulated excessive per-stream allocation in the fixture, not a production
mutation. It was restored before final validation. Strict Swift lint and
whitespace checks passed.

This workload measures many established, mostly idle streams and their cleanup.
It does not measure 256 continuously producing streams under guest backpressure,
simultaneous saturated uploads, or the confined executable.

The final runner passed all six capacity/memory records after restoring the
fixture fault. Anthropic peak growth across its three rounds was 44,711,936,
45,154,304 and 45,236,224 bytes; OpenAI growth was 81,920, 147,456 and 180,224
bytes relative to its later baseline in the same process. Maximum additional
growth beyond a provider's first round was 524,288 bytes. Evidence is
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-stream-memory-63s27qqg`
and `/tmp/iso-stream-memory-final.log`.

## Installer and updater transition-pair handling

Delivery inspection found that install.sh and the self-updater only copied the
legacy `iso-proxy` name. A release containing the specified transition pair
would omit both named siblings. Both paths now recognize `iso-proxy-rs` plus
`iso-proxy-swift`, reject incomplete pairs before replacing files, and install
both beside the host. A legacy archive containing `iso-proxy` removes stale
transition names so the host's Rust-name preference cannot select an older
sibling. Archives predating any proxy retain the existing no-companion behavior.
Checksum and attestation verification still precede extraction/installation.
The updater retains its existing refusal to replace an Apple-backend build with
a published Lima release.

The installer integration fixture covers the transition pair through the real
checksum/extraction/install path with stubbed GitHub transport/provenance calls,
incomplete-pair preservation of all installed files, and legacy cleanup. Its
final run passed 13 checks (`/tmp/iso-transition-installer-final.log`). The
updater's 40 unit tests passed, including both missing-member cases and executable
permissions for both siblings (`/tmp/iso-transition-update-final.log`). Host
all-target clippy with warnings denied, Rust formatting and whitespace checks
passed (`/tmp/iso-transition-clippy-final.log`).

Three deliberate faults were detected and restored: skipping Rust pair validation,
retaining stale transition names, and omitting Swift from shell installation.
Evidence is `/tmp/iso-transition-update-mutations.json` and
`/tmp/iso-installer-transition-mutation.json` with their referenced logs.
No whole-module mutation sweep was run for update.rs, which is an IO orchestration
exclusion; the new behavior was directly fault-checked instead.

Official release packaging remains incomplete: the workflow still builds the
default backend, lacks the Swift binary, and needs a matching Apple-backend
artifact/channel and actual signed/attested publication evidence. No release was
published. Existing replacement remains per-file, not a transaction spanning all
host/proxy files. End-to-end updater integration was not rerun in this step.

## Self-update integration and Swift CI admission

Extended the real updater integration fixture with verified transition archives:
install both named executable siblings, reject a missing Swift member without
changing the host or either installed sibling, then install a legacy proxy and
remove stale transition names. The full integration script passed 11 checks
(`/tmp/iso-transition-update-integration.log`). It builds release/dev host
binaries, serves synthetic artifacts over loopback, verifies checksums and runs
the real update path. Its existing API override intentionally bypasses provenance;
this is not evidence of published-artifact attestation.

Added a `swift-proxy` job to the reusable CI workflow, which the release workflow
already requires. It uses GitHub's `xcode-27` macOS 27 preview runner, strict Swift
lint, the full package suite with forced resolved dependencies, the confined
process test with live TLS skipped, and shared forwarding/disconnect corpora.
GitHub's hosted runner availability was checked against its primary announcement:
https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/
Actionlint 1.7.12 lacks that newly published label, so `.github/actionlint.yaml`
adds only that exact extra label; the workflow passes actionlint with this
documented compatibility setting. No self-hosted runner is selected.

The preflight regression test exposed a stale `--all-features` expectation; the
actual workspace clippy command intentionally excludes the macOS-only feature
on Linux. Corrected the expectation. All six preflight regression tests pass;
the integration-probe regression suite passes eight tests with one skip.
Shell syntax and whitespace checks pass. The new hosted CI job has not run;
no branch was pushed and no release was published.

The new CI job's first command group passed locally: strict Swift lint, 44
transport tests in 71.142 seconds and eight policy tests with forced resolved
dependencies, then the confined process gate with live TLS skipped. Six opt-in
tests were skipped by the ordinary suite (historical AHC audit, live TLS and four
RSS workloads). Evidence is `/tmp/iso-swift-ci-local-tests.log` and
`/tmp/iso-swift-ci-local-process.log`. The shared corpus scripts in the second
CI command group retain their previously recorded local evidence; they were not
rerun in this step. Hosted execution remains unverified.

## Preserve completed responses after late TLS errors

Audited the complete-response draining fix against error delivery as well as
channelInactive. The new regression reproduced a second truncation path:
NIOSSLError.uncleanShutdown after decoded HTTP completion failed the request
while a guest body-write acknowledgment was pending. The response end was lost
(two outbound parts instead of three), despite the complete message already
being queued (`/tmp/iso-complete-response-tls-error-baseline.log`).

OwnedResponseHandler now preserves the bounded queue when an upstream transport
error follows decoded HTTP completion. Errors before completion still fail the
request. Guest-write failures still fail directly through the write future and
must not emit a response end. The deterministic regression covers plain closure
and TLS error, each with successful or failed guest acknowledgment. These four
cases and the verified-TLS early-disconnect matrix passed in 1.686 seconds
(`/tmp/iso-complete-response-final.log`).

A deliberate fault continuing the response pump after failed guest writes
compiled and failed the new negative cases. Evidence is
`/tmp/iso-complete-response-guest-write-mutation.json` and its referenced log.
The fault was restored before final checks. Strict Swift lint and whitespace
checks passed. The pinned NIO decoder's default informational-response strategy
was also inspected: it drops interim responses, so those do not set the final
HTTP-completion flag used here.

Final verification passed the full pinned Swift suite: 44 transport tests in
70.986 seconds and eight policy tests (`/tmp/iso-response-error-full-suite.log`).
The six opt-in audit/live-TLS/RSS tests were skipped. This run includes the
controlled forwarding/TLS corpus, body deadlines/limits, stream capacity,
shutdown, and the new four-case response-drain regression. No production-profile
or VM integration run was repeated for this response-pump change.

## Standard Lima VM integration

Used the integration skill to run the real local Lima lifecycle suite with the
current release host and Rust proxy builds:
`./tests/run-integration.sh --name swift-port-lima-20260927`. Ambient Anthropic,
OpenAI, GitHub and Claude OAuth environment variables and the implementation
selector were removed for the invocation; destructive destroy-all was disabled.
The suite installed the python/node profiles and used its own named instances.

The runner exited zero: 250 passed, zero failed, eight skipped across 52 phases.
Setup, VM creation, SSH/editor/exec, Claude settings and onboarding, Codex paths
and account configuration, environment handling, network/Docker, stop/restart,
resize, commit/restore, reprovision, destroy and idempotency all passed their
applicable assertions. Cleanup removed the test instances and builder VM; the
pre-existing `iso-fc` VM remained stopped at that checkpoint.

The eight skips were the Firecracker PID check; the full-only Codex update;
Lima-owned hostname resolution and sudo-warning checks; reported disk size after
resize; reported guest IP after restore; and reported guest IP/disk size after
reprovision. This was the standard suite, not `--full`; its extended credential-
proxy phase did not run. It validates shared host lifecycle behavior on Lima,
not Swift execution (which remains selected only for the Apple sandbox backend).

The complete output was inspected. Following the integration skill's output
cleanup instruction, the raw log was removed after recording all phase counts,
skip reasons and its SHA-256 in `/tmp/iso-swift-port-lima-result.json`.
Firecracker verification used the pre-existing local nested-virtualization test
host `iso-fc`; its result is recorded below.

Firecracker prerequisites were checked in `iso-fc`: Linux aarch64, accessible
KVM API version 12, passwordless sudo, CMake/GCC and the pinned Rust 1.94.0
toolchain. The macOS host has no Linux Rust target installed, so the same
`tests/run-integration.sh` entrypoint is running natively inside the Linux VM
instead of the cross-compiling remote wrapper. A source snapshot includes tracked
working-tree files plus untracked source/test/script files needed by this branch;
its SHA-256 is recorded in `/tmp/iso-firecracker-source.sha256`. The snapshot is
at `/tmp/iso-swift-port-fc-20260927` inside the guest. The instance prefix is
`swift-port-fc-20260927`, ambient provider-token variables are removed and
destroy-all remained disabled. The runner exited 1: 253 passed, four failed,
three skipped across 52 phases. Failed assertions were Claude
`enabledPlugins survives restart`, committed contents in a new image instance,
restored committed contents, and disk growth before reprovision. Disk growth
failed because `e2fsck -fy` returned 1. Skips were the full-only Codex update and
the two disk-GiB status assertions (resize and reprovision). All other applicable
phase assertions passed, including reprovision and destroy. This was the
standard suite, not its extended credential-proxy phase.

A separate no-agent/no-proxy reproduction wrote a file, read its contents back,
then stopped and restarted the VM. The file was missing afterward. Repeating
with explicit guest `sync` preserved the sentinel. This supports a durability
problem during Firecracker shutdown; it does not establish the exact failure
inside the guest/VMM. `src/vm.rs`, `src/setup.rs`, and `src/backend.rs` are
unchanged from the review base. The failing platform gate remains unresolved;
it is not evidence of Swift forwarding behavior. Diagnostic output is
`/tmp/iso-fc-durability.log`.

The complete suite output was inspected, summarized with per-phase counts,
failures, skips and hashes in `/tmp/iso-swift-port-firecracker-result.json`, then
removed per the integration skill. Both suite and diagnostic VMs were removed;
`iso list --json` returned `[]` and no Firecracker process remained. The owned
source snapshot was removed and `iso-fc` was restored to `Stopped`.

## Enforce dependency pins in transition builds

The local dual-artifact builder now passes `--force-resolved-versions` to Swift
build and its binary-path query, matching CI's dependency-resolution policy.
This prevents an artifact build from silently changing transitive dependency
pins. A debug Apple-backend host/Rust/Swift build and archive completed with
exit zero (`/tmp/iso-swift-port-pinned-transition.log`). Inspection of
`/tmp/iso-swift-port-pinned-transition.tar.gz` verified all three binary hashes
against its internal SHA256SUMS and confirmed the manifest identifies a dirty,
local build with Rust as default. The pinned binary-path query and whitespace
check also passed. This is local packaging evidence, not signed publication.

## Independent review and Continue handshake

The review skill ran correctness/tests, security/API, and
design/conventions/docs/comments lenses through three independent reviewers.
The shared packet `/tmp/iso-swift-review-packet.json` identifies base
`f16382089a017516a7ec886865db8f59a50a42e7` and hashes of 99 changed/untracked files.
No high/critical security finding was validated in this pass; this does not
complete the outstanding acceptance requirements or final post-fix review.

Three findings survived: missing guest `100 Continue` handling, a Rust/Swift
aggregate-header-budget mismatch, and documentation incorrectly describing
Seatbelt egress as provider-scoped. The documentation now describes the actual
port-scoped confinement and separate application/TLS provider checks.

The Continue regression failed against the original code for both fixed-length
and chunked uploads (`/tmp/iso-continue-baseline.log`). InboundGate now emits an
interim head only after all admission checks and a request permit are acquired.
The test waits for this response before sending body bytes, verifies exact body
delivery and final response, and verifies that the permit remains held. It also
checks authentication/policy/size/capacity refusals never emit Continue and that
bodyless requests are admitted without it. The focused test and strict Swift
format lint passed (`/tmp/iso-continue-final.log`). The full pinned Swift suite
also exited zero (`/tmp/iso-continue-full-suite.log`); opt-in audit/live-TLS/RSS
workloads remain separate gates.

The aggregate-budget finding identified that NIO counts request-target bytes in
its 64 KiB aggregate limit while Rust counts only header names/values. The
reviewer reproduced Rust 401 versus Swift 431 for 128 fields totaling exactly
64 KiB plus a `/` target (`/tmp/iso-review-header-bound.json`). Hyper's separate
buffer-size hypothesis was not reproduced. Foundation query re-encoding was
observed but not established as a semantic difference, so it was not reported
as a validated finding.

## Aligned header metadata and wire budgets

Rust now includes the parsed request target in the 64 KiB aggregate metadata
limit for complete and partial heads, matching NIO. Swift additionally checks
each completed header's combined name/value size against 16 KiB before
authentication; NIO's native field limit applies to each component separately.
The shared refusal corpus gained exact/one-byte-excess cases for aggregate
metadata, the maximum-size target with headers, and combined field sizes.

Re-review caught a regression in reducing Rust's raw preface allowance: optional
whitespace is excluded from parsed metadata but occupies wire bytes. Rust keeps
its 82,496-byte raw cap, and Swift now enforces the same cap through
HeaderWireBudget. The guard uses NIO's decoded head notification to stop
counting, so a body coalesced with the last header bytes does not consume the
header budget. It rejects additional guest input while a response is pending;
the existing gate rejects pipelined request heads. A final response resets the
budget for a subsequent request. Tests cover exact/excess whitespace, coalesced
body delivery, reuse, and a held response followed by an unfinished second head.
The published contract now describes both parsed metadata and raw wire limits.

All 46 shared refusal cases passed for both providers and both real confined
executables, including the reviewer's exact-metadata case with 1,024 extra
spaces (`/tmp/iso-header-wire-contract.log`). Each run also exercised 256 idle
connections, excess rejection and full refill. This is 184 case exchanges;
credentialed forwarding is covered separately.

The mutation-check skill swept the complete Rust inbound module using its
binary unit-test target (the proxy has no library target). The final 89-mutant
sweep reported zero missed: 86 assertion/test failures, one unviable constant
division, and two 20-second timeouts from mutations that prevent target-parser
index progress. Both timeouts are detected nontermination, not surviving
behavior. The tool exited 3 because it reports timeouts separately. Evidence:
`/tmp/iso-header-wire-mutants.log` and
`/tmp/iso-header-wire-mutants/mutants.out`. No exclusions were added or changed
for this sweep. The earlier 87-mutant sweep also had zero missed before adding
the raw-whitespace regression.

Removing Swift's combined-field check compiled and failed its assertion
(`/tmp/iso-header-field-swift-mutation.json`). Four additional compiled faults
were caught: disable the raw cap, count body bytes as headers, omit the next-
request reset, and allow input during a held response
(`/tmp/iso-header-wire-mutations.json`). All faults were restored. Focused
tests, strict Swift format lint, Rust formatting, proxy clippy and whitespace
checks passed. Final full proxy suites exited zero: Rust ran 53 unit tests and
10 process tests (`/tmp/iso-header-wire-rust-final.log`); Swift reported 48
transport tests in 71.068 seconds and eight policy tests
(`/tmp/iso-header-wire-swift-final.log`). Six opt-in Swift audit/live-TLS/RSS
workloads were skipped. No VM or live-provider smoke was repeated for this
header-budget change.

## Remaining phases and gates

Phase 0 still has the open items above. Aggregate saturated-stream memory
measurements in both directions are recorded in the later sections below.
Credentialed provider/agent acceptance remains open. The owned HTTP bridge
repairs stalled-handshake socket cancellation; DNS/candidate admission and native
DNS/system TLS under the production profile have dedicated evidence above. Shared
forwarding, body-limit, body-idle and stream-capacity evidence is recorded above.
Remaining phase 3–7 work includes broader production-profile adversarial tests,
release transition packaging, Swift cutover, and eventual Rust removal. VM
integration, live provider/agent smoke tests, and security review remain required. Full workspace tests and the Apple proxy transition/rollback
gate passed. Standard Lima integration passed; Firecracker integration failed
the four lifecycle assertions recorded above.
Workspace clippy has passed. No default implementation change or Rust deletion is justified
by the current evidence.

## Apple VM guest isolation extension (2026-09-27)

`python3 tests/integration-proxy-transition.py` completed with exit 0 at
00:54:07 UTC on macOS 27 arm64. Both VMs initially ran Swift; the main VM then
restarted with Rust while the peer remained on Swift. All phases passed:

- OpenAI unauthenticated requests returned 401, own-capability denied GETs
  returned 403, and the other VM's capability returned 401 in both directions.
- Synthetic configured credentials and host environment credentials were absent
  from guest environment and regular files. The scanner covered 19,501 files
  under Swift and 19,510 after Rust rollback, including both agent configuration
  files, with zero matches. It excludes `/proc`, `/sys`, and `/dev`, does not
  follow symlinks, and fails on traversal/read errors. A temporary canary crossing
  a read boundary proved detection before each full scan and was removed.
- Both provider processes matched the selected implementation. Killing the
  OpenAI proxy closed its host listener and guest curl reported error 56
  (connection reset) for both implementations. Stop also left the listener closed.
- Missing Swift and substituted failing Swift executables caused startup failure
  without Rust fallback or leftover proxy PID records. Explicit Rust rollback
  then succeeded.
- Both private VMs and owner-tagged images were removed. No task processes
  remained; the two preexisting stock containers remained running.

Two preceding attempts exposed harness assumptions: the guest lacks Python by
default, and the launcher canonicalizes `/var` to `/private/var`. The gate now
installs its scanner dependency inside the test guest and compares resolved
executable paths before signaling. Scanner needles travel over stdin through
non-interactive `iso shell`; `iso exec` closes stdin. Guest curl failures are
checked by their diagnostic because isolate wraps the remote exit status.

The complete successful transcript was inspected, summarized with binary and
transcript hashes in `/tmp/iso-vm-isolation-result.json`, then removed. Its
SHA-256 was `1014f59d1f67e907cbd1601af170d39fa84887e27a1fb2d2a13609253253ebe7`.
Failed/interrupted private runtime artifacts were also removed. The harness now
prints its complete transcript before deleting successful run artifacts.

This is partial section 19.5 evidence: requests remain denied GETs. Admitted VM
forwarding and streaming through a controlled TLS upstream, and actual agent
failure reporting, remain open. The new cross-VM and termination checks cover
OpenAI; the process selection and disk scan include both providers. No new Lima
or Firecracker run was performed for these test-only changes.

## Controlled-upstream VM harness preparation (2026-09-27)

Added opt-in `--controlled-upstream` to the Apple transition gate, backed by
`tests/proxy_vm_forwarding.py` and the XCTest-only `VMProxyFixture`. It uses the
production server, inbound policy, streaming bridge, and owned TLS transport.
The test process runs under the unchanged production Seatbelt profile; its
existing internal fixture seams route the compiled provider identity to loopback
with an additional disposable CA. No production API, startup schema, or trust
store was changed.

The harness is designed to run an allowed POST for each provider through the
existing real guest reverse tunnel, checking injected synthetic credentials,
fixed Host/SNI, nominated-header removal, and request/response hashes. The final
SSE event is withheld until the guest reports receiving the first, so a bridge
that aggregates the response cannot complete the exchange.

Evidence so far: the fixture compiled; the normal test invocation skipped it as
intended; a separately confined XCTest invocation served a real HTTP 401 and
passed its file-write denial probe (`/tmp/iso-vm-fixture-confinement.log`). Swift
format lint and Python syntax checks passed. **Admitted forwarding and the VM
phase are not yet verified.** The first local TLS attempt failed binding
`127.0.0.1:443` with EPERM, and `sudo -n true` required authentication. A request
to enable `sudo -v` is pending. The prepared root helper only binds that fixed
loopback port and transfers the listener via SCM_RIGHTS; TLS/HTTP run without
root. Do not mark section 19.5 complete from this preparation.

An `xctest -help` discovery command unexpectedly printed its inherited
environment, including a Cloudflare credential, into tool output. The user was
notified to rotate it. All actual fixture invocations use an explicit minimal
environment; the credential was not copied into source or fixture files.

## Transition candidate packaging (2026-09-27)

Prepared `.github/workflows/swift-candidate.yml`, a manually triggered candidate
build gated by the existing reusable CI workflow. It builds the Apple-backend
host, both proxy implementations, and the VM runtime from the triggering commit,
checks the archive's per-binary hashes and Mach-O signatures, and prepares a
GitHub provenance attestation plus an outer archive checksum. It uploads a
workflow artifact; it does not publish a release or change the stable channel.
No hosted invocation or attestation has occurred yet.

`scripts/build-proxy-transition.py` now accepts `--include-runtime` and
`--expected-revision`. The latter requires release mode, a complete archive, and
an exact clean Git checkout before and after building. Both Rust builds use
`--locked`; both Swift package builds enforce their checked-in resolutions.
The manifest records runtime inclusion and distinguishes local builds from
clean revision-constrained candidates. Provenance still comes from external
attestation verification, not from trusting a manifest field.

Local evidence:

- `/tmp/iso-proxy-transition-runtime.tar.gz` built successfully in release mode
  with all four executables, `LICENSE`, `SHA256SUMS`, and `BUILD.json`.
- Exact archive members, regular-file types, all four hashes, and all four
  `codesign --verify --strict` checks passed after extraction. Host and runtime
  version probes passed. Its manifest correctly reports a dirty local build
  from `f16382089a017516a7ec886865db8f59a50a42e7`, with Rust still the default.
- `tests/test-proxy-transition-build.py` uses an isolated real Git repository:
  exact clean revision passes; wrong revision, tracked modifications, and
  untracked source fail. Removing expected-revision enforcement in memory made
  the test fail. The test is included in regular CI and the candidate workflow.
- Workflow validation found the existing release workflow's invalid
  `$/.github/workflows/ci.yml` reference. It is now the valid relative
  `./.github/workflows/ci.yml`; its package destination is also shell-quoted.
  Actionlint passes for the candidate and release workflows.

The Mach-O signatures are ad hoc, not Developer ID signatures or notarization.
The official signed/attested transition release, its installation channel, live
acceptance tests, and observation period remain open. The local archive is not
evidence of a published or attested release.

## Scoped fixture and candidate review (2026-09-27)

Reviewed the new controlled-upstream fixture and candidate packaging against
working-tree base `f16382089a017516a7ec886865db8f59a50a42e7`; the snapshot packet
with source hashes is `/tmp/iso-transition-review-packet.json`. Independent
reviewers covered correctness/tests and security/API usage; the coordinating
review covered design/conventions/docs/comments. This was a scoped follow-up,
not the final whole-branch security review.

Validated and fixed:

- Wrapping the listening socket caused Python's accept loop to perform TLS
  handshakes synchronously. An idle TCP peer blocked accept and shutdown.
  `ControlledTLSServer` now accepts without handshaking, applies a five-second
  socket timeout, performs TLS in workers, and closes accepted sockets before
  joining workers during cleanup.
- Killing only the isolate child left its SSH descendant holding stdout, so the
  reader executor could block indefinitely before VM cleanup. Fixture and guest
  subprocesses now own private sessions, and cleanup kills their process groups
  even if the direct child has already exited.
- Revision tests exercised only `source_state`, so deleting both enforcement
  calls in the builder still passed. Tests now execute the builder's main path
  with real Git state and stubbed compiler boundaries: dirty input must fail
  before any build, a clean revision must package, and a source change during
  compilation must prevent packaging.
- Narrowed the fixture's "only DNS and CA differ" claim. It bypasses production
  startup, bounded resolver admission, and upstream work accounting, and its
  additional CA does not prove exact production system-trust behavior.

`tests/test-proxy-vm-fixture.py` passed both unprivileged regressions: an idle TLS
peer neither blocks a second valid TLS request nor cleanup, and group cleanup
closes stdout held by a descendant. The candidate source test passed. Five
in-memory faults were detected: omit all revision enforcement, omit only the
post-build check, kill only the direct child, omit accepted-socket cleanup, and
perform the TLS handshake in accept. Evidence is in
`/tmp/iso-transition-review-mutations.log`; no source mutations remain. The new
cleanup tests run in regular CI. Actionlint, Swift format lint, and diff
whitespace checks passed.

No additional validated high/critical security issue was reported in this
scope. Before merge, the trust-model confirmation still applies to the new
loopback HTTPS and private Unix control listeners. No merge is requested or
performed. The privileged listener, admitted real-VM forwarding, live-provider
tests, and hosted candidate workflow remain unrun. No Lima/Firecracker rerun was
performed for these fixture/workflow-only changes.

## Opt-in live API smoke preparation (2026-09-27)

Added `scripts/test-proxy-live.py` for the live API portion of section 19.6.
It takes a dedicated credential only through stdin, requires an explicit model,
starts the selected proxy under the production Seatbelt profile with an empty
environment, and passes startup JSON over its stdin pipe. Core dumps are disabled
before reading the credential. It makes three bounded generation requests
(stream, client disconnect after first text, recovery), plus Anthropic token
counting. Each generation defaults to 256 output tokens, configurable within
16–1024. The overall run has a 180-second deadline.

The client requires nonempty text deltas and a provider terminal event, rejects
error/incomplete/truncated streams, and bounds SSE event and total response sizes.
Proxy stdout/stderr are drained in memory, checked for credential/capability
leaks across read boundaries, bounded by an output budget, and discarded.
The report contains only provider/model, binary hash, phase counts, and audit
status. Provider exceptions are not rendered because they may include response
content. Client disconnect and recovery do not establish remote generation or
billing cancellation; docs explicitly preserve that limitation.

Protocol references were checked against the official OpenAI Responses streaming
guide and Anthropic streaming/token-count docs (linked in `docs/testing.md`).
No model name or credential was inferred or retrieved.

Evidence: `python3 tests/test-proxy-live.py` passes seven offline tests, including
actual subprocess/loopback orchestration for both provider flows with a synthetic
server replacing the proxy process boundary. These tests do not claim TLS or
Seatbelt coverage. Four in-memory faults were caught: accept missing completion,
ignore provider error events, wait for completion on the disconnect phase, and
disable secret-output detection. Evidence:
`/tmp/iso-live-smoke-mutations.log`. No source mutations remain. The offline
tests are in regular CI; actionlint and diff whitespace checks pass.

**No live provider calls were made.** Run this only after the controlled-upstream
VM gate passes and dedicated credentials/model approvals arrive. Actual Claude
and Codex tool-use round trips still need their agent-level gate; this host API
runner does not substitute for it.

## Decisions requested

- Section 10 requires both incremental request forwarding and that an
  over-limit request never reach the provider with a credential. For unknown
  length/chunked requests these requirements conflict. Decide between requiring
  Content-Length and explicitly permitting cancellation after partial forwarding.
- The required observation period before Rust removal has no defined duration.
  Obtain the period and actual observation evidence before removal.
- Live provider/agent smoke tests need host credential command references and
  approved model names. The current process has none of the Anthropic/OpenAI
  credential environment variables; these references have been requested.

Neither unresolved decision prevents continued work on independent requirements.

### Guest agent tool-use runner prepared (2026-09-27)

Added `tests/fixtures/credential-proxy/agent-tool-smoke.py` for execution inside
an already bootstrapped disposable proxy guest. It accepts an explicit agent
and model, creates a random challenge file without including the nonce in the
prompt, and requires both a successful tool result and subsequent successful
model answer containing the nonce. Claude tool results must match an earlier
Read/Bash tool-use id; Codex command results must have successful status and
exit code. Missing terminal events and explicit errors fail the gate.

Raw agent stdout/stderr are not printed or persisted by the runner. Combined
output is bounded to 2 MiB, runtime to 180 seconds, and a private process group
is killed on all exits (including a direct parent exiting with live descendants).
The challenge directory is removed afterward. Claude uses four turns and a
USD 1 client budget; Codex needs a provider-side dedicated budget. The runner
preserves isolate's guest agent routing/configuration and accepts no real provider
credential. It must not be run on the host. Documentation gives guest-only
invocations and requires separate proxy identity/routing evidence and guest
teardown; this script does not itself provision or prove confinement.

Verification: `python3 tests/test-proxy-agent-smoke.py` passed all five tests;
Python compilation and `git diff --check` passed. In-memory faults accepting
missing tool results, failed commands, unmatched Claude results, and unbounded
output were each caught by those tests. No mutated source was written. Added
the offline suite to CI. Synthetic event tests do not establish installed CLI
schema compatibility. No provider calls, VM boot, or real Claude/Codex run was
performed. Controlled VM forwarding still needs port-443 access; live runs
still need dedicated credentials and approved models. Sections 19.5/19.6 remain
incomplete.

### Agent-visible terminated-proxy gate (2026-09-27, run in progress)

The previous VM gate used curl to observe a killed proxy. Section 19.5 explicitly
requires agent failure, so the gate now also kills the owned Anthropic proxy,
checks both host listeners are closed, and invokes both installed agents in the
private guest with a synthetic model name. The guest probe requires a nonzero
exit and a structured terminal connection error; generic configuration/model
errors and successful turns do not qualify. Raw agent output remains in guest
memory. No real provider credentials are used. This is separate from the
successful live tool-use round trip.

The offline suite now passes seven tests. In-memory faults accepting generic
failures and successful process exits were caught. `git diff --check` passed.
The real Apple VM transition suite was started with output redirected to
`/tmp/iso-agent-failure-vm.log`, exec session 44891. Its private directory is
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-proxy-vm-fmyviy4u`.
The last verified state was a running process after private runtime compilation
completed; no VM/agent result is claimed yet. Resume this same handle and inspect
the complete transcript, then clean up the raw log per the integration skill.

The agent-visible VM run above completed with exit 1. Swift boot, cross-VM
capability rejection, the 19,501-file credential scan (zero matches with canary
coverage), and curl transport failure passed. The installed guest Codex emitted
ten events and passed the terminal transport-failure check. Claude exited
unsuccessfully after approximately 177 seconds but failed with `missing terminal
agent transport failure`; its raw output was intentionally discarded, so the
cause is not yet established. Rust rollback phases were not reached in this run.
Both private VMs were destroyed, owned `local/iso-1407c6aa*` images were absent,
and the private artifact directory was removed after inspecting the transcript.
The summary and executable/transcript hashes are in
`/tmp/iso-agent-failure-vm-result.json`; raw logs were removed.

A minimal-environment host Claude reproduction against closed loopback port 1
was started in exec session 17696, using only a synthetic credential and a
private temporary HOME/config directory. It prints event keys and terminal
error fields, not general message contents or environment. It is diagnostic
only, not a replacement for the real guest gate. Resume this handle; no result
has yet been claimed.

The closed-port host reproduction (session 17696) completed: exit 1, ten
`system/api_retry` events, then a `result` with `subtype: success`, `is_error:
true`, and `API Error: Connection refused — a firewall or proxy may be blocking
it (ECONNREFUSED)`. The existing matcher accepts this shape. This does not explain
the guest failure, whose SSH tunnel resets the connection. A second isolated
host reproduction uses a loopback listener that immediately resets accepted TCP
connections, synthetic auth, and a 190-second deadline. Its exec handle is
recorded in the conversation; await its terminal result before changing the
matcher. No production behavior has been changed based on an inferred cause.

The reset reproduction (session 45398) completed with exit 1 and terminal
`result`/`subtype: success`/`is_error: true`, containing exactly
`API Error: Connection dropped (ECONNRESET)`. The checker now recognizes the
observed `connection dropped` wording while retaining its terminal-event and
unsuccessful-exit requirements. This explains a plausible mismatch for the SSH
reset case; the actual guest rerun must still prove it. Seven offline tests
passed, including this event, and removing `dropped` in memory was caught by
the regression test. `git diff --check` passed.

The complete Apple VM transition gate was restarted only after the prior run
was confirmed terminal and cleaned up. The new exec handle is 79434 and output
is `/tmp/iso-agent-failure-vm-retry.log`. It remains in progress; do not claim
Claude guest failure or Rust rollback passed until this run completes.

The rerun (79434) was terminal with exit 1: Codex again passed, while Claude
hit the probe's 180-second deadline. Guest versions were Codex 0.157.1 and Claude
Code 2.1.283. This is a test deadline failure, not evidence that the corrected
terminal-error matcher failed. The observed ten-retry diagnostic duration is
close enough to 180 seconds that jitter can cross it. Failure-only probes now
allow 300 seconds and the outer SSH command 330; successful live tool-use probes
remain bounded to 180. The event/error and unsuccessful-exit checks are unchanged.
Seven offline tests and whitespace checks pass.

The rerun's entire transcript was inspected, both VM removals verified, and
owned `local/iso-62fe4fba*` images checked absent. Its summary, versions, and
binary/log hashes are `/tmp/iso-agent-failure-vm-retry-result.json`. The raw
logs and private directory were removed. A new full VM run is active, output
`/tmp/iso-agent-failure-vm-final.log`; resume the exec handle in the conversation.
No acceptance result is claimed for the new run yet.

### Agent-visible VM termination and rollback PASS (2026-09-27)

The final full Apple sandbox transition gate (exec 21941) exited zero at
02:01:41 UTC. Both actual agents returned nonzero and emitted terminal transport
failure events after their owned host proxies were stopped: Codex had ten JSONL
events and Claude thirteen, for both Swift and explicit Rust rollback. Claude's
Swift diagnostic took about 192 seconds, confirming that the former 180-second
test deadline was too short. This completes the agent-visible killed-proxy
assertion for this gate without live provider credentials or model requests.

The same run passed guest capability rejection, cross-VM capability rejection,
credential scans (19,501 files on Swift, 25,006 after Rust restart; zero matches
and canary coverage), listener teardown, and both missing/exiting Swift
fail-closed startup checks. Rust was selected explicitly while the peer VM
remained on Swift. Both owned VMs were destroyed. The temporary runtime tree,
owned `local/iso-69e6cae2*` images, and task executable processes were verified
absent. The complete transcript was inspected and removed. Summary, observations,
and executable/transcript hashes are `/tmp/iso-agent-failure-vm-final-result.json`.

This run did not enable `--controlled-upstream`, did not exercise admitted
provider traffic or successful agent tool use, and did not rerun Lima or
Firecracker. Those scopes and the existing external inputs/decisions remain
open. It does not establish completion of section 19.5 as a whole or justify
Swift default/Rust deletion.

### Simultaneously saturated response memory gate (2026-09-27)

Extended the existing verified-TLS response pressure fixture to run with either
one or 256 stalled guests. All 256 provider requests are established before one
shared barrier releases their response producers. Every producer retains one
64 KiB buffer, awaits each flush, and offers 256 MiB or 1 GiB (64/256 GiB total).
Per-peer progress must be positive and below 16 MiB, aggregate progress must stop
for three seconds, and every upstream socket and producer must terminate after
guest closure. Whole-test-process RSS growth after TLS setup is limited to
256 MiB in this aggregate mode; the original one-client budget remains 32 MiB.
The runner records and validates peer counts, individual and summed progress,
samples, and cleanup. Use `--direction response --connections 256`.

The final restored-source aggregate run exited zero for both offered sizes:
48,644,096 and 48,676,864 bytes RSS growth; 273,743,872 and 274,923,520 bytes total
producer progress. Evidence directory:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-9d5i7573`,
runner log `/tmp/iso-saturated-response-memory-final.log`.
A bounded fixture fault retaining 2 MiB per active producer failed the real RSS
assertion at 587,743,232 bytes growth. It was restored before final runs; this is
assertion sensitivity evidence, not a mutation of production backpressure.
Fault artifacts: `/tmp/iso-saturated-memory-fault.{json,log}`. The runner also
rejected missing-peer, wrong-concurrency, and unfinished-cleanup observations.

All four original single-client response/upload workloads passed after the
fixture change (runner `/tmp/iso-memory-original-final.log` and evidence
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-4wluucd6`).
Strict Swift formatting and `git diff --check` passed. No fault remains in source.
This closes the previously unmeasured simultaneous response pressure scope; it
still does not measure simultaneous saturated uploads or the Seatbelt-confined
executable. No production source changed. Port 443 was rechecked this turn and
still fails with PermissionError/errno 13, so the controlled VM forwarding gate
remains unavailable without the previously requested privilege setup.

### Simultaneously saturated upload memory gate (2026-09-27)

Extended the verified-TLS stalled-upload fixture to one or 256 clients. All
provider peers stop reading after headers before guest producers start. Each
producer offers 16 MiB or 64 MiB (4/16 GiB total), retains one 64 KiB buffer,
and awaits each flush. Every sender must make positive progress but stall below
8 MiB; each provider may consume no more than 64 KiB while paused. Aggregate
progress must plateau for three seconds. The 256-client RSS growth budget is
256 MiB after TLS setup. Guest closure stops all producers, then provider reads
resume solely to drain socket buffers and establish EOF. The runner verifies
individual counts, totals, peer count, samples, and cleanup in either direction;
`--connections 256` now supports upload, response, or both.

Final aggregate uploads passed with 32,800,768/32,555,008 bytes RSS growth and
358,678,528/358,744,064 bytes total guest progress. Evidence:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-zjza5p4i`
and `/tmp/iso-saturated-upload-memory-final.log`. All four original single-client
workloads passed after restoration, with evidence in
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-memory-backpressure-c3yae9qt`
and `/tmp/iso-memory-both-single-final.log`.

A bounded fault retaining an extra 2 MiB per producer triggered the RSS assertion.
Its first attempt exposed slow error cleanup: fixture TLS peers remained paused
while sequential closes waited for shutdown. The owned helper was terminated,
and the source restored. Error cleanup now resumes those fixture peers after
closing guests, matching the normal cleanup path. Repeating the fault then
failed the RSS assertion and exited normally in 7.761 seconds, at 571,998,208 bytes
RSS growth (`/tmp/iso-saturated-upload-fault-final.{json,log}`). The fault was
restored before final validation. This is fixture assertion sensitivity, not a
production mutation. Corrupted observations for missing senders/receivers,
excess receive progress, and inconsistent totals were also rejected. Strict
Swift formatting and `git diff --check` passed. Production code was unchanged.

Together with the response gate, simultaneous saturation is now measured in
both directions. These whole-test-process measurements still do not establish
RSS for the Seatbelt-confined executable. The controlled VM/live-provider gates,
release/observation requirements, unresolved body-framing decision, and final
whole-branch acceptance review remain open.

### Current requirement/evidence audit (2026-09-27)

Added `docs/design/swift-proxy-acceptance.md` and linked it from the documentation
index. It maps all 24 specification sections, including startup subcontracts,
architecture decisions, test artifacts, phase ordering, and acceptance groups,
to current source/evidence and explicit limits. It is not a completion claim.
Re-inspection confirms `InboundGate` forwards chunked headers/body before final
size is known, so section 10.3's zero-credential-forwarding property is still
unmet for unknown-length requests. The Rust default, unexecuted hosted candidate
workflow, absence of admitted VM/live-provider results, undefined observation
period, and final-review/platform gaps are called out rather than hidden by
passing subsets. Dedicated inputs and the body/observation decisions were
requested again through the async user-input channel; no answer was inferred.
No code cutover or Rust removal occurred. Whitespace checks passed.

### Scoped agent/memory review and cleanup tripwire fix (2026-09-27)

Reviewed the ten-file agent-probe, integration-addition, aggregate-memory, and
associated documentation/CI scope captured in
`/tmp/iso-agent-memory-review-packet.json` (base
`f16382089a017516a7ec886865db8f59a50a42e7`, uncommitted content hashes).
Independent reviewers covered agent correctness/security/tests and memory
correctness/tests/pinned API behavior; root covered design, conventions, docs,
and comments. No lens was omitted. This was not a final full-branch review.

One P2 finding was validated: the forked-descendant test only asserted a timeout,
so replacing group kill with direct-child kill still passed all seven tests.
The replacement test records the descendant identity, allows its parent to exit,
requires the descendant to be gone or a zombie after capture, and independently
kills the process group in `finally`. The redundant old fork-only case was
removed. All eight tests pass; the in-memory killpg-to-kill fault now fails only
the descendant-liveness assertion and is independently cleaned. The reviewer
re-inspected the fix and marked it resolved. No mutated source was persisted.
Python compilation and `git diff --check` pass.

No additional validated memory/security/API finding survived. Memory evidence
remains growth after TLS setup through direct OwnedHTTPRequest fixtures, not
production DNS/admission orchestration or confined-executable RSS. The memory
runner's direct-child-only timeout cleanup was noted as a pre-existing adjacent
limitation; no newly introduced timeout path remained after fixture cleanup was
fixed. No production source change or new VM/provider execution was needed for
this regression-test fix. Final whole-branch review, live/controlled upstream
acceptance, body decision, release, observation, and platform gaps remain open.

## 2026-09-27 — installed-client request framing compatibility

Captured initial HTTP/1.1 model requests from installed macOS Codex CLI
0.157.1 (app-bundled executable) and Claude Code 2.1.283. Each used a
private temporary home/work directory, a cleared environment with fake capability
authentication, and iso-equivalent provider routing. Seatbelt denied network
access except the loopback capture port. Claude exposed Read/Bash tools; no
model response or tool execution occurred. The listener returned HTTP 400 after
reading the request, and each client process group was stopped and reaped.
Temporary directories/listeners were removed. No live provider call was made.

| Client | Prompt padding | Declared and received body bytes | Streaming response requested |
| --- | --- | --- | --- |
| codex-cli 0.157.1 | 32 | 32635 | true |
| codex-cli 0.157.1 | 131072 | 163675 | true |
| 2.1.283 (Claude Code) | 32 | 43172 | true |
| 2.1.283 (Claude Code) | 131072 | 174212 | true |

All four requests had one observed Content-Length value, no Transfer-Encoding,
and no Content-Encoding; declared lengths matched the complete captured bodies.
Codex used POST /v1/responses; Claude used POST /v1/messages?beta=true. This
supports requiring Content-Length for these initial streaming text requests.
It does not establish guest/Linux parity, retries, tool-result follow-up requests,
image/attachment requests, future client versions, or successful live operations.
The production body policy is unchanged.

Local probe and controlled metadata: `/tmp/iso-framing-probe.py` and
`/tmp/iso-framing-results.json`. Executable SHA-256:

- codex: `27ceb5f9b957b43a519efe4eaa3816a0bffb0a531a2c89af18840c0a3c016a7d`
- claude: `d8cb1e5c79684cc12a8bfc813e3a2073406921b6245744b3009be3ab5651d21e`

The Homebrew Codex executable timed out on --version at 10 and 60 seconds;
those processes were killed/reaped. The app-bundled executable reported its
version and completed all captures. An initial Seatbelt profile syntax error
was corrected before the successful runs; failed attempts provide no framing
evidence.

## 2026-09-27 — known-length body policy selected and applied

The user selected the known-length policy after the installed-client framing
probe. This resolves the unknown-length decision blocker in §10.3. Both Rust
`request_body::validate_headers` and Swift `InboundGate` reject chunked uploads
with 411 before forwarding, acquiring a request permit, or acknowledging
100 Continue. Ambiguous framing remains 400 at the parser/raw-header boundary.
Neither framing header means an empty HTTP/1.1 body. Declared bodies through
64 MiB retain streaming/backpressure; larger declarations receive 413.
Response/SSE streaming is unchanged. The spec, user documentation, testing
reference, and acceptance map now describe this contract.

The shared real-TLS body gate now compares six cases: each provider at exactly
64 MiB, one byte over, and unknown length with Expect: 100-continue. Both
implementations passed with identical observations. Exact-limit uploads reached
the fixture incrementally and matched SHA-256; both refusal cases had zero
upstream TCP connections, requests, body bytes, or credential-bearing requests.
Guest closure and upstream cleanup passed. Evidence:
`/var/folders/nd/0ftffstd2dz0bj7v78hwpf700000gn/T/iso-body-limit-6c6pxxzy`.
These are controlled TLS fixtures, not production provider or VM calls.

Validation for this change:

- Rust proxy binary unit suite: 54 passed; Swift transport suite: 48 passed.
- Swift wire tests cover header-only, empty, and nonempty chunked bodies,
  no forwarding/request-permit acquisition, no interim 100, bodyless admission,
  and incremental delivery of an accepted declared body.
- Full-file cargo-mutants sweep of `iso-proxy/src/request_body.rs`: 56 mutants,
  24 caught, 32 unviable, zero survivors/timeouts. This binary-only crate uses
  `--bin iso-proxy request_body::tests`, not the host library test target.
  No mutation exclusions changed. Evidence: `/tmp/iso-known-length-mutants`.
- Deliberately removing each implementation's unknown-length guard made its
  new regression fail. Both files were restored in finally blocks. Restored
  Rust body tests (7) and targeted Swift framing tests (3) passed.
- Proxy all-target clippy with warnings denied, Rust format, strict Swift
  format on changed files, Python compilation, and git diff --check passed.

No commit, merge, release, default switch, or goal-completion claim is made.
The broad goal remains blocked on its other prerequisites: controlled admitted
VM forwarding, successful dedicated live provider/agent operations, final
review/platform gates, hosted transition distribution, and agreed observation
before Rust removal. Lima/Firecracker integration was not rerun for this change;
the previously recorded Firecracker failures remain unresolved. The client
probe's limitations (initial macOS text requests only) still apply.

## 2026-09-27 — user-authorized Rust proxy removal and Swift-only cutover

The user waived the observation prerequisite and explicitly requested immediate
Rust proxy removal. Scope is the proxy, not the Rust host CLI or VM backends.
This supersedes the prior deletion sequence; it does not establish unexecuted
live/controlled-VM/release gates. The Rust proxy crate, tests, TLS fixtures,
Cargo member and Tokio/Hyper/Rustls/Landlock/aws-lc dependency closure are gone.
The host has no implementation selector or fallback and requires macOS for
credential-proxy mode. Linux host/Firecracker functionality remains; Linux
credential-proxy mode is unavailable. Active docs/config examples, Cargo license
exceptions, mutation exclusions, CI, release/preflight/build, installers,
updaters, and integration paths are synchronized.

SwiftPM's product remains `iso-proxy-swift`; the installed artifact is named
`iso-proxy`. This stable name is required because released v0.6.0 updaters only
replace that companion. The tagged installer behavior was reproduced against
the new layout, including replacing an old Rust companion with Swift bytes.
Both debug and release builders replace the canonical binary and remove stale
`iso-proxy-rs`/`iso-proxy-swift` siblings. Installer/update keep checksum and
provenance verification unchanged, reject obsolete transition artifacts before
replacement, and clean stale suffix companions. The neutral refusal/forwarding
fixtures and Swift boundary/cleanup validators remain; retired Rust commands
and comparisons have been removed.

Review target: base b13c0e0 (committed port), staged plus unstaged removal diff.
Independent correctness/tests and security/API reviews, plus root design,
conventions, docs, and comments review covered all eight lenses. Fixed findings:
old-updater canonical-name compatibility; builder mock reintroducing retired
artifacts; macOS <27 integration skip; remote macOS Swift delivery; stale release
preflight package/version assumptions. Final scoped review has no surviving
code finding. This is not the final whole-goal security/acceptance signoff.
Review packet: `/tmp/iso-swift-only-review.json`. No clean-commit marker was
written: the worktree is uncommitted and broader platform/live gates remain.

Validation:

- Default host suite: 1,215 passed. Apple-backend suite: 1,329 passed.
- Swift package: 48 transport and 8 policy tests passed; opt-in RSS/live/TLS-audit
  cases and standalone VM fixture serving remained skipped by that invocation.
- Default and Apple all-target clippy with warnings denied, Cargo format,
  cargo-deny, actionlint, shellcheck for changed runners/installers/preflight,
  Python compilation, and diff whitespace checks passed. Taplo was unavailable.
- Installer: 13 passed; real updater: 11 passed; release preflight: 7 passed;
  candidate-source/archive builder test passed. The builder asserts the actual
  canonical file is Swift bytes, exact archive membership and suffix cleanup.
- Deliberately removing builder cleanup fails its regression. Removing obsolete
  updater-archive rejection fails its regression; source restored, all 40 update
  and 30 host proxy tests passed afterward. Independently injected Swift-test
  and process-gate failures fail release preflight. No fault remains.
- Confined Swift process gate (offline) passed. Refusal corpus: 46 cases × two
  providers, plus connection-capacity recovery. Retained Swift runners passed:
  18 forwarding/TLS cases, 16 disconnect exchanges, six declared/unknown-length
  admission cases, two idle-upload cases, and six 256-stream capacity rounds.
- Actual debug and release archives were built and inspected. Release archive
  `/tmp/iso-swift-only-release.tar.gz` has host CLI, Swift proxy, runtime,
  LICENSE, SHA256SUMS and BUILD.json; all checksums and three Mach-O signatures
  verified. `/tmp/iso-swift-only-release-result.json` records hashes/manifest.
  It is a dirty local build, not a hosted attested release or publication.

Final canonical-name Apple VM gate exited zero. Complete 774-line transcript
was reviewed. Two VMs booted with both providers; capability and cross-VM
rejection passed; 19,501 regular guest files contained no fake provider secret,
with a successful canary and both configuration files witnessed. After proxy
termination curl returned transport error 56, Codex emitted 10 failure events,
and Claude 13; neither completed a tool/result answer. Missing canonical proxy
and pre-readiness substitute termination failed startup closed. The substitute
was killed by SIGKILL; this does not prove `/usr/bin/false` returned its normal
exit status. Listener teardown and both VM destroys passed. Owner cc300fc3's
containers/images and task processes were checked absent, and the private work
directory was removed. Structured evidence: `/tmp/iso-swift-only-vm-result.json`;
raw integration transcripts were removed after review. An earlier successful
pre-canonical run was superseded by this final run.

Observation and Rust-retention/removal are no longer blockers. Remaining full-
goal work includes admitted controlled-upstream VM forwarding, dedicated live
provider/agent success, final whole-goal review/platform gates, hosted artifact
verification and the intended Apple-backend install/update channel. Neither
Lima nor Firecracker was rerun here; prior Firecracker lifecycle failures are
not resolved by this removal. No commit, merge, push, or publication was done.


## 2026-09-27: retained listener and admitted Apple VM forwarding

The controlled fixture's 502/TLS EOF was reproduced without a VM: on this macOS
host a transferred socket failed TLS after its creator exited, including on an
unprivileged high port. Retaining the creator produced HTTP 204 in the minimal
reproduction and successful confined streams for both provider identities.
The bind helper now retains its socket until the control channel closes (bounded
to one hour), after dropping supplementary groups, GID, and UID. The harness
owns that lease across both providers. Cleanup no longer masks an exited-child
EPERM, and both upstream TLS errors and the Swift transport error are observable.
Six fixture regressions pass; removing the real helper's wait fails the lifetime
test. The privilege boundary is mocked in that regression.

The full Apple VM gate then exited 0 using a borrowed retained listener with the
unchanged production profile. Both providers passed real guest → SSH tunnel →
confined Swift → controlled TLS exchanges, with exact request/response hashes
and `first_event_before_completion: true`. The 19,501-file synthetic credential
scan, canary/configuration witnesses, cross-VM capability rejection, transport
failure observations (Codex 10 events, Claude 13), startup refusals, and cleanup
all passed. The substituted exiting binary was killed by SIGKILL; no normal
exit status is inferred. All 940 transcript lines were independently reviewed.
The private work directory and owner `8cfd51c0` containers/images were removed;
the retained listener and diagnostic helper were closed.

Evidence summary: `/tmp/iso-listener-lifetime-result.json`. This run validates
controlled admitted Apple VM traffic, not real provider calls, Lima, Firecracker,
production system-trust behavior against the fixture CA, or release provenance.
The canonical sudo/privilege-drop helper subsequently passed both confined TLS
preflights in the user's Terminal (12:56 local, artifact `iso-proxy-vm-hlr5h4gp`).
Both request/response hashes matched and the first SSE event preceded completion;
the complete user-supplied transcript reports PASS. The initial unconfigured
Swift fixture skip is expected; both configured fixture executions ran and passed.
The full VM run borrowed the diagnostic helper's retained socket; the separate
canonical preflight validates the final privileged helper path.


## 2026-09-27: final review, Lima gate, and fork release channel

The user selected `chr33s/iso` and `swift` for the release channel. Installer,
updater, and repository provenance checks now use that fork. Release CI rejects
tagged commits outside `swift` ancestry; macOS builds use `apple-container` and
bundle `iso`, Swift `iso-proxy`, and signed `iso-sandbox`. Linux retains
Firecracker. The host prefers an adjacent runtime with the existing path trust
and runtime qualification checks. Lima source builds refuse self-update to avoid
a backend switch. Missing Apple companions are rejected before replacement.
File replacements are atomic individually, not as a set; a later filesystem
failure may require reinstalling the same release to restore matching files.

The manual workflow is now `.github/workflows/swift-candidate.yml`, displayed as
**Swift release candidate**, and is restricted to this fork's `swift` branch.
This is channel preparation, not hosted execution or publication.

Independent correctness/tests and security/API reviews covered the full goal
branch (`2e1bf205` through `daca9ffd`), then the release-channel working delta.
No findings remained. The security audit additionally passed 46 refusal cases,
100 malformed cases, and 256-connection saturation/recovery per provider, plus
certificate-matrix and capability tests. Release-delta validation passed 15
installer checks, 13 real updater checks, eight preflight regressions, 1,216
Lima/default unit tests, and 1,329 Apple unit tests followed by both newly added
backend/runtime-selection tests. Default and Apple clippy with warnings denied,
format, actionlint, and diff checks passed. Deliberately omitting runtime
installation in an isolated copy made the new installer witness fail.

The standard Lima suite at `daca9ffd` exited zero: **250 passed, zero failed,
eight skipped across 52 phases**. All lifecycle phases passed, including settings
persistence, commit/restore, and reprovision. Skips: Firecracker PID, full-only
Codex update, two Lima hostname checks, two disk-size status assertions, and two
guest-IP assertions. The full-only workspace/multi-instance suite was not run.
The Swift build emitted stale-cache path warnings after package relocation,
then completed successfully. The complete transcript was inspected and its
per-phase counts and SHA-256 retained in `/tmp/iso-final-lima-result.json`.
Owned test instances were removed; the pre-existing `iso-fc` host was restored
to Stopped. The raw Lima transcript was removed after review.

The previous Firecracker result remains 253 passed, four failed, three skipped.
Shutdown durability and `e2fsck -fy` exit handling are separate lifecycle
follow-ups: `src/vm.rs`, `src/setup.rs`, and `src/backend.rs` are unchanged from
the approved proxy baseline. The earlier sync-before-stop reproduction remains
evidence of the durability symptom, not proof of its exact cause. No fresh
Firecracker suite was run and the Linux platform gate is not claimed green.

Remaining external gates: dedicated live-provider credential references and
approved models; hosted same-revision candidate/attestation execution and
artifact verification; and a published, verified fork release. No push, tag,
workflow dispatch, or publication was performed in this work.


## Host support decision: macOS 27+ only

The user clarified that this fork is macOS-host-only and selected macOS 27+
as the minimum. This applies to the whole fork, not only credential-proxy
mode. Apple Silicon is the release architecture; Linux remains the guest OS.
The four historical Firecracker lifecycle failures do not block acceptance.
No Linux rerun or lifecycle fix is required to validate the Apple candidate.

Documentation and contributor/agent gates now reflect that scope. Retained
Linux source and implementation notes are not a support commitment. This was
a documentation change: workflow matrices, installer platform selection, and
preflight still need alignment before the next release. Standalone runtime
API/deployment compatibility with macOS 26 does not lower the fork’s macOS 27
host requirement. Live provider/agent success and artifact provenance remain
independent acceptance requirements.


## Candidate artifact naming

The candidate workflow is now `.github/workflows/candidate.yml`, displayed as
**Release candidate**. New archives are named
`iso-<commit>-aarch64-apple-darwin.tar.gz` and contain a `iso/` directory.
The downloadable GitHub artifact is
`iso-candidate-<commit>-aarch64-apple-darwin`. The existing builder command
`scripts/build-proxy-transition.py` now writes this layout. Historical archive
names and workflow identities above describe the artifacts produced then;
previous downloads and attestations are unchanged. New attestation verification
must pin `.github/workflows/candidate.yml` as the signer workflow.
