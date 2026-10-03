<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Testing

isolate's host is the Swift package at the repository root (`Package.swift`:
`IsoCore`, `IsoConfiguration`, `IsoSecrets`, `IsoHost`, `IsoCLI`). Its test
layers are:

- **Swift package tests** (`tests/swift/`) — unit and contract tests for every
  host target, plus replay of the fuzz corpus. CI gate.
- **Host checks in Python** — read/lifecycle contracts, data-root safety, and every
  registered CLI help path. CI gate.
- **Fault injection** (`scripts/swift-host-fault-injection.py`) — shows that
  critical tests fail when their protected behavior is removed. Replaces
  mutation testing for the host.
- **Fuzzing** (`scripts/fuzz.sh`) — coverage-guided libFuzzer campaigns for the
  host parsers. CI runs a bounded smoke; longer campaigns are manual.
- **Integration tests** — real Apple Containerization VMs. Manual; run for
  guest-visible and lifecycle changes.

The credential proxy (`iso-proxy/`) and the Apple runtime (`iso-sandbox/`)
are separate Swift packages with their own tests (below).

Supported host: **macOS 27+ Apple Silicon only**. Linux guests are in scope;
Linux hosts are not.

## Swift host checks

```bash
swift build --force-resolved-versions
swift test --force-resolved-versions          # IsoCore/Configuration/Host/CLI + corpus replay
swift format lint --strict -r Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints iso-sandbox/Package.swift iso-sandbox/Sources iso-sandbox/Tests
swift test --sanitize=address --scratch-path .build-asan     # also:
swift test --sanitize=thread --scratch-path .build-tsan
swift test --sanitize=undefined --scratch-path .build-ubsan

python3 tests/test-release-legal.py           # legal bytes and nested release notices
python3 tests/test-read-contract.py --swift .build/debug/iso
python3 tests/test-lifecycle-contract.py --swift .build/debug/iso
python3 tests/test-data-root-contract.py --swift .build/debug/iso
python3 tests/test-cli-surface.py --swift .build/debug/iso
python3 scripts/swift-host-fault-injection.py # critical tests fail under injected faults
python3 scripts/generate-embedded-resources.py  # after editing scripts/guest/*
```

Use a separate `--scratch-path` per sanitizer so instrumented builds do not
invalidate `.build`. The package tests use synthetic credentials and isolated
temporary state; they never touch `~/.iso`.

The read and lifecycle checks use synthetic state and fake runtime/SSH/builder
processes. Reviewed iso expectations live in `tests/fixtures/contracts/`.
Read checks cover command output and failures; lifecycle checks also cover
runtime calls, resulting state, image recipes and interrupted journal recovery.
JSON output is compared structurally. Update a fixture only after inspecting the
behavior change; do not regenerate expectations merely to silence a failure.
The data-root check covers absent, regular, file and symlink roots and missing
explicit configuration. The CLI surface check discovers and exercises every
registered help path, including newly added command families.

Configuration fixtures live in
`tests/swift/IsoConfigurationTests/Fixtures/config/`: each `.jsonc` has an
`.expected.json` recording its domain values. They exercise defaults, complete
configuration, GitHub modes, proxy credentials and URL spelling without an
external implementation oracle.

`python3 scripts/build-release.py --release --test` builds and tests all four
packages from a staged copy and assembles the release archive; see
[RELEASING.md](../RELEASING.md).

## Integration tests

`tests/run-integration.sh` runs the Apple Containerization VM suite,
`tests/integration-apple-sandbox.sh` (see [below](#apple-runtime-real-hardware-checks)):

```bash
./tests/run-integration.sh                        # every phase, ~20 min
./tests/run-integration.sh --only iso            # iso end to end
./tests/run-integration.sh --only isolation,snapshots --keep
```

CI additionally runs the fast, host-only `tests/integration-install.sh`,
`tests/integration-update.sh`, and `tests/integration-uninstall.sh` suites.

For the credential proxy, build the local Swift artifacts and run the Apple
sandbox proxy gate against the Swift host:

```bash
swift build --force-resolved-versions
python3 scripts/build-proxy-transition.py
python3 tests/integration-proxy-transition.py
```

The transition builder enforces the checked-in Swift dependency resolutions;
it fails instead of updating transitive pins during an artifact build. The
gate writes a JSONC config and supplies its synthetic credentials as `cmd:`
references (C-04 rejects literal proxy credentials).

This gate builds a private runtime and VM image, boots two VMs, and
checks OpenAI guest 401/403 responses and rejection of the other VM's capability.
It scans regular guest files for synthetic provider credentials, excluding
`/proc`, `/sys`, and `/dev`; a temporary canary verifies the scanner before the
full scan. Search values enter the scanner over stdin. It stops the main VM and tests missing/exiting Swift artifacts.
It checks both providers' selected proxy processes, listener teardown, and a
guest curl transport failure after terminating the OpenAI proxy. The curl check
does not prove how a real agent reports the failure. Credentials are synthetic
and all guest requests use denied GET operations; this does not replace admitted
VM forwarding, streaming, or live provider/agent smoke tests. It needs Apple's
container service running and removes its VMs and images on completion.
Failed runs retain diagnostic artifacts at the printed temporary path.
The gate also removes the selected Swift artifact and substitutes an executable
that exits immediately, checking that both starts fail with the expected reason
and create no proxy PID records without a fallback implementation.

The controlled-upstream phase passed for both providers on the Apple backend
using a retained port-443 listener; see the [release validation](release-validation.md)
for its fixture boundaries and remaining acceptance/distribution gates:

```bash
python3 tests/integration-proxy-transition.py --controlled-upstream

# Diagnose confined local TLS on port 443 first, without building or booting VMs:
python3 tests/integration-proxy-transition.py --controlled-upstream-preflight
```

It replaces each owned Swift proxy with an opt-in XCTest process using the same
server and streaming transport under the unchanged production Seatbelt profile.
It uses loopback routing and an additional fixture trust anchor. The fixture
bypasses production startup, resolver admission, and upstream work accounting;
it does not establish production system-trust or resource-limit parity. It checks
both providers' injected synthetic credential, fixed Host/SNI, request hash,
header stripping, and response hash. The TLS upstream withholds the last SSE
event until the guest acknowledges the first, to detect response aggregation.
macOS requires privilege for loopback port 443: a helper binds that port, drops
its root UID/GID and supplementary groups, and passes the listener over a private
Unix socket. It stays alive until the harness closes the control connection
(or one hour elapses): on the tested macOS host, TLS on transferred sockets
reset when their creator exited. The helper handles no TLS or HTTP and receives
no credentials. No host
trust-store changes or production endpoint overrides are made. Port 443 must be
free. The runner reserves it before any build or VM setup and retains it across
both provider exchanges. In an interactive Terminal, sudo can prompt at that
initial step; unattended runs require noninteractive sudo authorization. No
later phase needs a refreshed sudo timestamp. This fixture is not linked into
the production executable.

### Dedicated live-test credentials

The live gates below use their own provider credentials, never everyday ones.
Create an Anthropic workspace and an OpenAI project for them, each with a low
spend limit and access to the approved models. Keep them in Keychain items of
their own. Do not use `iso proxy setup` for this, because it writes the
`iso-anthropic`/`iso-openai` items your normal install reads.

Do not type or paste a key at the `security add-generic-password ... -w`
prompt. The prompt keeps only the first 128 characters, so a longer key (OpenAI
`sk-proj-` keys are about 164) is stored truncated. The provider then answers
401 `invalid_api_key` and shows a different last four characters than the
console. Instead, copy the key to the clipboard and send the whole command to
`security` on stdin. This keeps the key out of argv and shell history:

```bash
{ printf 'add-generic-password -U -s iso-live-anthropic -a iso-live -w '; pbpaste; echo; } | security -i
{ printf 'add-generic-password -U -s iso-live-openai -a iso-live -w '; pbpaste; echo; } | security -i
pbcopy </dev/null   # clear the clipboard
```

(Run one line per key, copying that key first.) Check each item's length and
last four characters against the provider console, without printing the key:

```bash
security find-generic-password -s iso-live-openai -a iso-live -w |
  awk '{print length($0), substr($0, length($0)-3)}'
```

If the provider rejects a key, this shows its error message. The key goes into
curl's header on stdin (`-H @-`):

```bash
security find-generic-password -s iso-live-openai -a iso-live -w |
  sed 's/^/Authorization: Bearer /' |
  curl -sS -H @- -H 'Content-Type: application/json' \
    -d '{"model":"APPROVED_MODEL","input":"ping","max_output_tokens":16}' \
    https://api.openai.com/v1/responses
```

The Keychain Access app (File → New Password Item: name `iso-live-openai`,
account `iso-live`) also stores the full value. When finished, delete both
items with `security delete-generic-password -s iso-live-<provider> -a iso-live`
and revoke the keys.

For the guest gate, point a private config at these items. Give it its own
`data_dir` so it never touches `~/.iso`:

```jsonc
{
  "data_dir": "~/iso-live/data",
  "github": "off",
  "proxy": {
    "anthropic": { "credential": "cmd:security find-generic-password -s iso-live-anthropic -a iso-live -w", "auth": "api_key" },
    "openai": { "credential": "cmd:security find-generic-password -s iso-live-openai -a iso-live -w", "auth": "bearer" }
  }
}
```

### Live proxy API smoke

After the controlled-upstream VM gate passes, use dedicated provider credentials
(above) and explicitly approved model names. The opt-in runner reads a credential from
stdin and sends three bounded generation requests: normal streaming, disconnect
after the first text delta, and recovery. Anthropic also exercises token counting.
Replace the credential-command and model placeholders below with the approved
values; never put the credential value in argv or a file:

```bash
your-dedicated-openai-credential-command | python3 scripts/test-proxy-live.py \
  --provider openai --model APPROVED_MODEL
your-dedicated-anthropic-credential-command | python3 scripts/test-proxy-live.py \
  --provider anthropic --scheme x_api_key --model APPROVED_MODEL
```

The default token ceiling is 256 per generation request; an approved test may
select 16–1024 with `--max-output-tokens`. No model is selected implicitly.
Use `--scheme bearer` for a dedicated Anthropic bearer credential when supported
by the account. Pass `--binary` to select the built artifact (for example
`iso-proxy/.build/debug/iso-proxy`, the default, after `swift build --package-path iso-proxy`). It runs under the production Seatbelt profile
with an empty child environment and startup JSON over stdin. Core dumps are
disabled before reading the credential. Output contains phase counts, model,
binary hash, and secret-audit status, without response bodies or proxy logs.

The runner requires nonempty text plus the provider's terminal streaming event,
following the [OpenAI streaming contract](https://developers.openai.com/api/docs/guides/streaming-responses)
and [Anthropic streaming contract](https://platform.claude.com/docs/en/build-with-claude/streaming).
It checks [Anthropic token counting](https://platform.claude.com/docs/en/api/typescript/messages/count_tokens)
for a positive `input_tokens` result. A disconnect result proves client-side
closure followed by a successful request; it does not prove when provider-side
generation or billing stopped. This is a host API smoke gate, not the real-VM
or Claude/Codex tool-use gate. Recorded results are in the H-07 row of
[release-validation.md](release-validation.md).
`python3 tests/test-proxy-live.py` exercises the runner offline in CI and makes
no provider calls.

### Live guest agent tool use

After the controlled-upstream gate passes, the proxy gate script can run this
check unattended:

```bash
python3 tests/integration-proxy-transition.py --live-agents \
  --claude-model APPROVED_MODEL [--claude-model ...] \
  --codex-model APPROVED_MODEL [--codex-model ...]
```

It builds a private runtime and one throwaway VM, `proxy-live`, whose proxies
read the dedicated credentials through `cmd:` references. By default these are
the `iso-live-anthropic`/`iso-live-openai` Keychain items above. Use
`--anthropic-credential`/`--openai-credential` to pass other `cmd:` references;
the script rejects anything that is not a `cmd:` reference. It configures only
the providers that have models. The script then:

- checks that each agent's guest endpoint is a loopback address;
- checks that each running proxy is the built `iso-proxy` and prints its
  sha256;
- runs the agent check below once per model and prints each summary.

It fails if any model fails, and destroys the VM and its images either way.
Credential values never pass through the script. It does not repeat the
synthetic-credential guest scan; that is covered by the base gate.

To run it by hand instead, prepare a disposable guest with the Swift proxy
selected, dedicated test credentials configured on the host, and normal agent
bootstrap enabled. Run the following from the repository root, substituting its
private isolate config, VM name, and approved model:

```bash
iso --config PRIVATE_CONFIG shell PRIVATE_VM -- python3 -c \
  "$(cat tests/fixtures/credential-proxy/agent-tool-smoke.py)" \
  --agent codex --model APPROVED_MODEL
iso --config PRIVATE_CONFIG shell PRIVATE_VM -- python3 -c \
  "$(cat tests/fixtures/credential-proxy/agent-tool-smoke.py)" \
  --agent claude --model APPROVED_MODEL
```

This script must run **inside the guest**. It uses the existing isolate agent
configuration and capability; it accepts no provider credential. It creates a
temporary challenge file whose random contents are absent from the prompt,
requires a successful tool result containing those contents, then requires a
successful final model answer containing them. Raw JSONL and stderr stay in
guest memory and are discarded. Runtime is limited to 180 seconds and combined
output to 2 MiB; the process group is killed on every exit. Claude additionally
uses a four-turn and USD 1 client budget limit. Codex has no spending cap here;
use a provider-side test budget. This runs one conversation per invocation.

The summary alone does not prove routing or confinement: record the selected
host proxy executable/hash and guest endpoint configuration separately, and
destroy the disposable guest after the test. Both live runs remain pending.
`python3 tests/test-proxy-agent-smoke.py` checks successful and failed JSONL
round trips and process bounds offline; it does not validate an installed
agent's event schema or make provider calls.

The synthetic-credential transition VM gate also runs both installed agents
after terminating both owned provider proxies and verifying their listeners
closed. It uses `--expect-transport-failure` with a synthetic model name and
requires a nonzero agent exit plus a structured terminal connection error.
Configuration/model errors and successful turns fail that check. This exercises
agent-visible proxy termination without a live provider request; it does not
replace the successful live tool-use gate. Failure probes allow 300 seconds
for the agent's own transport retries (Claude's observed ten retries take about
three minutes), with a 330-second outer SSH deadline. The successful live
tool-use probe retains its 180-second limit.

### Shared proxy contract gates

The shared malformed HTTP harness runs the real Swift proxy under Seatbelt:

```bash
swift build --package-path iso-proxy
python3 scripts/test-proxy-contract.py --fuzz-cases 10000 --seed 20260927
python3 scripts/test-proxy-contract.py --replay /path/to/request.bin
```

The seeded mutations cover raw request lines, framing fields, binary/control
bytes, whitespace, and oversized fields. Fuzz inputs never contain a valid
capability and cannot authorize provider operations. The harness half-closes
each fuzz input, bounds response reads, checks process survival and secret-free
output, and periodically checks readiness. Fixed corpus cases separately assert
exact expected Swift statuses, including incomplete inputs without EOF. Fuzz
input-exchange failures save the wire bytes and seed/index metadata for replay. Only local
ephemeral-port exhaustion is retried, for at most 45 seconds; other failures
remain errors. This does not replace authenticated streaming/TLS differential
tests or memory stress tests.

When adding new features, consider whether they should be covered here. New
commands or guest-visible changes are good candidates for a new test phase.

Run `python3 tests/test-integration-probes.py` for host-only regression tests
of Codex installer failure propagation, update/config assertions, address
discovery, ping result handling, and bounded HTTP retries. These use a
temporary loopback HTTP server and require Python 3, Bash, and curl;
CI runs them. The full VM suite additionally checks these probes against
real guests. A host FORWARD policy other than ACCEPT still causes an explicit
skip of the routed guest-isolation probe, since it would mask the isolate rule.

Run `python3 tests/test-codex-account.py` for the account wrapper's argument,
login/logout, API-key passthrough, and `codex-yolo` regressions (also in
CI). To additionally test implicit daemon reuse with a real Linux Codex binary
(on a Linux machine, since the wrapper runs in the Linux guest):

```bash
ISO_TEST_CODEX="$(command -v codex)" python3 tests/test-codex-account.py
```

This requires `dbus-run-session`, `gnome-keyring-daemon`, `secret-tool`, and
`strace`. It uses temporary homes and disposable keyring passwords, starts a
real app-server on a separate unusable keyring session, and observes terminal
socket connections. It checks that sign-in is reached without reusing that
server and that removing the wrapper override restores reuse. No account login
or real tokens are needed. Run it when upgrading Codex: daemon selection is
version-dependent. This opt-in test does not replace either VM backend gate.

The full Codex update tests install native release `0.153.0` before running
`codex update` as the guest user, and require the installed version to change.
They compare the actual `config.toml` contents across host updates, self-updates,
and migration from a profile-provided system command. Package layout and
completeness remain the native installer's responsibility.


## Apple runtime (`iso-sandbox`)

The host's own tests (`IsoHostTests`) replace the `iso-sandbox` runtime (and
the stock `container` builder) with scripted fakes, so they run without either
installed. The runtime itself is a Swift package with its own unit tests (IDs,
records, subnet allocation, the control protocol, reconcile, and in
`TransactionTests.swift` disk-update failure injection and same-sandbox
locking); none of them boots a VM:

```bash
swift test --package-path iso-sandbox --no-parallel
```

The runtime tests run serially: several take, release, and re-probe `flock`
locks, and in a parallel run about one in five runs sees a released lock as
still held. Serial runs have not shown it. The cause is not yet identified
(subprocesses started by other tests are the main suspect; switching them to
`posix_spawn` did not remove it).

Parser fixtures in `tests/fixtures/iso-sandbox/` are real `iso-sandbox`
output; the directory's README says how they were captured.

### Apple runtime real-hardware checks

`tests/integration-apple-sandbox.sh` boots real `iso-sandbox` VMs and checks
what unit tests cannot:

- peer isolation between sandboxes over IPv4/IPv6 TCP, UDP, and ICMP,
  including forged routes, static neighbours, spoofed sources, and
  broadcast/multicast;
- host exposure (mounts, agent sockets, a host canary file, vsock) and a canary
  secret in the caller's environment;
- pinned SSH over the native channel;
- stop/start persistence, CPU/memory changes, disk sizes and offline growth,
  commit/restore (including a guest that disables its own `rm`), and crash
  recovery with launchd respawn;
- interrupted mutations: a `grow`, `commit`, or `restore` client killed at
  fractions of its uninterrupted duration (`KILL_FRACTIONS`) must reconcile
  to the old or the new state, with no staged or scratch files and a record
  that matches the installed disk;
- rounds of 1, 4, and 8 sandboxes booted at once (`CONCURRENCY`), each
  running the full peer probe against a fixed peer and its ring neighbour
  in parallel;
- the maintenance image (install, and survival after its store image is
  deleted) and same-sandbox races (concurrent grows, start against grow);
- `iso` itself end to end (the `iso` phase): `setup`, `up`, `status`,
  `exec`, `stop`/`start`, `resize --mem/--vcpus/--size`, rollback of a
  `resize --start` whose boot fails, `commit`, `restore` with host-key
  re-pinning, `destroy`, and image deletion. The phase also checks isolate's
  own sandbox for host mounts, agent forwarding, and canary leakage. It
  requires isolate to refuse a changed host key and a restore it did not
  make. It kills `iso restore` and `iso resize --size` partway
  (`ISO_KILL_FRACTIONS`), and the next `start` must recover.

It builds the runtime, a small test image (`tests/fixtures/apple-sandbox/`),
and `iso`, all under a temporary work directory. The `iso` phase uses an explicit
`boundary-fixture` profile with Claude/Codex stubs that exit 125 if invoked;
all its successful guest boots use `--no-agents`. This phase qualifies VM
lifecycle and isolation, not native agent installation or execution. Native
agent checks remain part of the separate proxy/agent gates.

The suite removes its state root, sandboxes, and images on exit. On failure,
it first copies build/setup and other top-level logs into a private
`iso-sandbox-failure.*` directory and prints that path; no VM or disk is kept.
`--keep` instead retains the complete work directory and its resources.
Run `python3 tests/test-apple-integration-harness.py` for offline cleanup and
agent-stub regressions (also in CI):

```bash
./tests/integration-apple-sandbox.sh                   # ~20 min
./tests/integration-apple-sandbox.sh --only isolation,snapshots
```

Phases: `setup disks machine isolation exposure identity persistence
resources growth snapshots recovery concurrency iso`. It needs Apple Silicon,
macOS 27+, Xcode 27, `jq`, and stock Apple `container` with its service
running.

Run it before changing the `containerization` pin, the runtime's VM
configuration, or the isolation gate, and whenever the macOS major version
changes. [`design/apple-sandbox-runtime.md`](design/apple-sandbox-runtime.md)
records why this runtime was chosen;
[`design/apple-sandbox-transactions.md`](design/apple-sandbox-transactions.md)
lists the mutation invariants these tests defend and what is still untested.

## Fault injection

Fault injection replaces mutation testing for the host. It shows that a
critical test fails when the behavior it protects is removed — an assertion
that still passes without that behavior is not coverage.

```bash
python3 scripts/swift-host-fault-injection.py                 # every fault
python3 scripts/swift-host-fault-injection.py --only scanner-strings --verbose
```

Each entry in the script's `FAULTS` list names an id, a production source
file, the exact original text, its faulty replacement, and the `swift test`
filter expected to catch it. The script copies the package into a scratch
directory (the working tree is never modified), first runs every covered test
unmodified there as a control, then applies each fault in turn. A fault counts
as detected only when a test runs and fails; a fault that stops the package
compiling proves nothing and fails the run. Exit status is non-zero if any
fault survives or its original text no longer matches.

**When to add a fault.** When a change adds or alters security-relevant host
behavior — parsing of untrusted or user-edited input, credential handling,
argv/environment construction, path or symlink checks, host-key pinning,
ownership/lock/atomic-write checks, process cleanup, update verification — add
an entry that removes that behavior and names the test that must catch it. Add
it in the same change as the behavior. When refactoring code a fault targets,
update the fault's original text so it still applies (a stale entry fails the
run). The [`mutation-check`](../.agents/skills/mutation-check/SKILL.md) skill
walks this workflow.

Entries whose source is under `iso-sandbox/` run that package's tests with
`--force-resolved-versions --no-parallel`; controls are grouped by package.
The runtime owner-demand, non-killing startup, rollback, and failure propagation
entries target `Launchd.bootstrap`. Other entries retain the host test target.

The `guest-exec-*` faults check awaited deletion, kill-on-timeout, cancellation
shielding, and avoiding a kill after normal exit. The `guestExec` runtime tests
also cover partial startup and preservation of the operation error when cleanup
fails. The `ordered-json-*` faults retain the depth and trailing-input checks
while parsing borrowed UTF-8. Run those filters directly with:

```bash
swift test --package-path iso-sandbox --force-resolved-versions --no-parallel --filter guestExec
swift test --force-resolved-versions --filter orderedJSON
swift test --package-path iso-egress --force-resolved-versions --filter concurrent
```

The ordinary host build enforces strict memory safety in `IsoConfiguration`;
unacknowledged unsafe operations in that target are compiler errors.
The Apple VM suite's `machine` phase proves an exec reached the guest before
timing out and cannot complete its delayed work afterward.

The credential proxy has its own policy mutation sweep (Muter) and targeted
mutation script; see [Swift proxy policy mutation
sweep](#swift-proxy-policy-mutation-sweep).

## Credential proxy (`iso-proxy`)

The proxy is a separate Swift package. When changing it, run at least:

```bash
swift format lint --recursive --strict iso-proxy/Sources iso-proxy/Tests
swift test --package-path iso-proxy --force-resolved-versions
```

Ordinary package tests include `IsoProxyProcessE2ETests`, which launches the
production executable under `Sources/IsoHost/Guest/Resources/seatbelt-proxy.sb` with an empty
environment and startup JSON on stdin. It verifies unconfined refusal before
reading stdin, strict bounded startup, redacted diagnostics, real HTTP admission,
secret-free argv, signed readiness for both providers, and shutdown/guest EOF.
The pinned SwiftPM toolchain builds the executable alongside the active test
bundle; discovery works with custom scratch paths and release configurations.
To select an exact artifact explicitly (as CI and release preflight do):

```bash
swift build --package-path iso-proxy --force-resolved-versions
bin_dir="$(swift build --package-path iso-proxy --show-bin-path)"
ISO_PROXY_E2E_BINARY="$bin_dir/iso-proxy" \
  swift test --package-path iso-proxy --force-resolved-versions
```

Set `ulimit -n 8192` before capacity/resource gates. Swift tests retain observations
and process diagnostics in printed private temporary directories. Credentials
are synthetic; test trust anchors never change the host trust store. Observation
validation runs without environment variables, checks exact keys and JSON types,
and rejects missing/duplicate cases. `observationContractsRejectDeliberateBreakages`
and `forwardingRejectsIncompleteAndDuplicateCorpusEvidence` exercise corrupted
records to keep those assertions discriminating.

The sections below describe its additional gates.

### Shared confined proxy refusal corpus

On macOS 27+, build the Swift proxy, then run
`python3 scripts/test-proxy-contract.py`. It runs 46 refusal cases for
both providers against the executable under the production Seatbelt profile.
The two slow-header cases retain an incomplete header, with one sending more
bytes after six seconds. Both require HTTP 408 and peer closure within 9–13
seconds, proving that partial progress does not reset the initial ten-second
deadline. The suite takes about 40 seconds plus startup time. These requests
use denied methods and cannot issue a model operation.

The same harness also holds 256 idle guest sockets and requires eight excess
sockets to close without sending any HTTP bytes. It completes all held sockets
with local 401 responses, refills the full allowance, disconnects all guests,
then refills and completes it again. This checks the production limit and
capacity recovery after both response completion and abrupt disconnect. Each
round must finish within five seconds, before header timeouts can release slots.
Use `--capacity-only` to run this check without the refusal/fuzz cases.

Use `--fuzz-cases N --seed S` to append deterministic malformed requests.
Failures retain the raw request and replay metadata; `--replay PATH` runs a
saved request. All startup credentials are synthetic, and responses and process
output are checked for disclosure.

### Swift proxy CI gate

The `swift-proxy` job in `.github/workflows/ci.yml` uses GitHub's `xcode-27`
macOS 27 preview runner. It checks strict Swift formatting, the full pinned
package test suite, the confined-process gate without live provider TLS, and the
Swift forwarding and early-disconnect corpora. The job raises its
file-descriptor limit for the 256-stream workloads. Release builds depend on
the reusable CI workflow, including this job.

The hosted runner label is documented in [GitHub's announcement](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/).
actionlint is pinned in `mise.toml` to the [kjanat/actionlint](https://github.com/kjanat/actionlint)
fork, which recognizes that label. Opt-in RSS, live provider TLS/credentials, VM integration and live-validation
requirements remain separate gates; this CI job does not replace them.

### Historical AsyncHTTPClient TLS cancellation audit

The pinned AsyncHTTPClient 1.36.2 leaves connection establishment running when
its queued request is cancelled. Reproduce with a local TCP fixture that receives
the TLS ClientHello but never answers it:

```bash
ISO_PROXY_HANDSHAKE_AUDIT=1 swift test --package-path iso-proxy --filter auditCancellationDuringTLSHandshake
```

This opt-in dependency audit fails the two-second upstream socket closure
assertion. Request cancellation returns immediately, while client shutdown waits
for the thirty-second establishment deadline. It uses the pinned client's TLS
configuration, a local synthetic destination, and no credentials. Forwarding now
uses direct SwiftNIO/NIOSSL with owned sockets; this audit preserves the reason
for that replacement and is not the acceptance test for the new bridge.
Run `swift test --package-path iso-proxy --filter bridgeCancellationClosesStalledTLSHandshake`
for guest-disconnect coverage through the new bridge, for both provider identities.

### Cancellable Swift TLS connection component

Run `swift test --package-path iso-proxy --filter ownedTLS` for the direct
SwiftNIO/NIOSSL connection component. It owns candidate sockets before TCP
connect and retains that ownership through TLS. Local tests cover cancellation
of stalled and established TLS sockets, late DNS results after cancellation,
establishment timeout, timer removal after successful TLS, system-trust
configuration with a per-test CA, and certificate/hostname rejection.

The forwarding bridge uses this component with SwiftNIO HTTP/1 framing and
per-write upload/response backpressure. The HTTP pipeline is attached before TLS
can deliver application bytes. Cancellation closes the underlying socket without
waiting for the peer's TLS close notification. Controlled forwarding, lifecycle,
body-limit, body-idle, stream-capacity and memory fixtures exercise this path.
The historical AsyncHTTPClient audit above continues to reproduce that library's
behavior. `ISO_PROXY_LIVE_TLS_GATE=1 swift test --package-path iso-proxy --filter IsoProxyProcessE2ETests` runs the production-profile
DNS/TLS probe through the owned connection and shared admission budgets. It verifies
both provider identities without sending HTTP requests or credentials, then checks
that removing the exact trustd permission breaks system verification. It does not
replace credentialed provider/agent smoke tests or broader memory measurements.
`python3 scripts/test-swift-egress-jail.py` runs `iso-egress --jail-selftest`
under `seatbelt-egress.sb` and checks write, exec, and non-443 denial. It does
not open a public connection or boot a VM.

After `swift build --package-path iso-egress --force-resolved-versions`, run
`python3 scripts/test-swift-egress-lease.py`. It starts the production companion
under the unchanged Seatbelt profile with startup JSON on stdin and a real
renewal pipe on fd 3. A test-only native Ed25519 verifier checks fresh signed
boot/policy challenges and malformed/unauthorized denials on the existing listener;
its key is anchored to independently generated OpenSSL vectors and a bad-signature
control must fail. The verifier is compiled with the pinned Swift toolchain and
selected macOS SDK; no extra crypto dependency is needed. These probes make no
upstream request. An unapproved CONNECT authority checks a delayed terminator,
continued input under the absolute five-second head deadline, partial EOF,
32 reset clients and subsequent service recovery without dialing upstream.
Synthetic denied CONNECTs must keep working beyond the initial
two-second grace period; pipe EOF and missed renewals must terminate
the process and close its listener and an unfinished guest request. This does
not exercise the host supervisor, runtime owner/boot checks, successful tunnels,
public DNS/HTTPS, or a VM. CI and release preflight run these package/process gates.

`swift test --package-path iso-egress --force-resolved-versions --filter
'resolver|productionResolver|deadlineRejects'` covers the DNS work budget and
address-list ownership. Sixteen controlled workers stay blocked beyond their
callers' deadlines; another lookup cannot start until one worker finishes.
The fixtures check slot recovery and exactly-once cleanup for late, successful,
and failed results. A native numeric lookup exercises the production resolver
without DNS traffic or dialing a socket. The wait uses a monotonic dispatch
deadline; finishing after it cannot deliver a result. libc `getaddrinfo` is not
cancelled: stuck work remains charged until it returns or the companion exits.

`swift test --package-path iso-egress --force-resolved-versions --filter relay`
covers queued EOF, bidirectional half-closes, partial writes, backpressure,
interrupted reads/writes, hard write errors, and budget release after idle or
revocation. Socket fixtures verify data and FIN ordering in both directions.
A full destination socket plus an injected HUP event verifies that paused reads
do not turn `poll` into a busy loop; the local socketpair did not reliably
report HUP without read interest. These fixtures bypass no production address
policy: they call the transport directly without invoking a connector.

`swift test --package-path iso-egress --force-resolved-versions --filter
'connect|tunnelRequires|tunnelDoes'` covers complete framing, header grammar and
control bytes, duplicate/conflicting Host authorities, unchanged authentication,
16 KiB/64-header boundaries, fragmented/coalesced input, interrupted/idle polls,
late completion and lease revocation. Optional Host metadata must agree with
CONNECT's canonical host and, if supplied, port 443. Content-Length and
Transfer-Encoding are refused. Local socketpairs test complete success/refusal
writes, SIGPIPE suppression, flag restoration and a stalled one-second writer.
A saturated client socket proves failed success-response writes neither relay
queued payload nor retain the connected upstream. These fixtures do not dial
public targets or change the production connector/address policy.

`python3 scripts/test-swift-egress-mutations.py` runs clean controls in a private
package copy, then deliberately releases DNS slots early, removes result cleanup,
accepts late results, and breaks relay error, EOF, half-close, retry, budget and
paused-hangup behavior. Eighteen CONNECT/handshake faults remove complete-head,
size, grammar, authority, framing, retry, payload, lease, deadline or response-write
checks. Six readiness faults remove capability, lease, nonce,
framing, computed-policy or SIGPIPE checks. Each named test must run and fail;
compilation errors and empty selections do not count. CI and release preflight run this gate.
These are local worker/ownership and socket tests, not a filtered VM exhaustion
or lifecycle-revocation gate.

DNS/candidate admission for the credential proxy has the dedicated tests below.

### Filtered handoff boot/policy checks

`filteredHandoffRefusesAChangedBoot` and
`filteredHandoffBindsProtocolPolicyAndOwner` pair a valid handoff control with
protocol, boot, policy, owner, lock and process failures. Network policy tests
reject forged hashes, noncanonical/invalid hosts and inconsistent modes;
boot-policy record tests cover bounded no-symlink reads, schema/backend checks,
owner-only writes and boot identity validation. A lifecycle test checks removal
of the boot record and capability on repeated stop.
Malformed or unreadable boot-policy state throws rather than masquerading as
an absent file. Ten new host faults remove protocol, policy, owner, hash,
host/mode, record schema/identity/read-error or cleanup checks; the existing
`filtered-handoff-boot` fault remains
applicable. These tests do not authenticate the live companion, prove the
reverse transport or required credential brokers, or complete NET-20.

### Authenticated filtered-transport checks

`FilteredReadinessTests` and the companion's `ReadinessTests` use independently
computed OpenSSL Ed25519 vectors to pin the version-2 wire contract. They check
valid proof, forgeries, correctly signed wrong-boot/wrong-policy replies and nonce replay,
HTTP framing, bounded no-symlink key reads, and owner-only writes/stop cleanup.
The guest request contains only a public challenge and the already guest-visible
capability on stdin, never the private signing key or raw provider environment.
A real tar fixture with a custom data directory inside the workspace positively
copies the public key and proves the private seed is absent. Knowing those public
bytes cannot forge a signature. CryptoKit may randomize signatures, so tests
verify actual signatures rather than demanding deterministic byte equality.
The guest probe uses base-image Bash/coreutils, not an optional Python profile.
Host-local exchange has a two-second monotonic deadline; the guest command has
a two-second timeout and a five-second host process deadline, with 1024-byte output
bounds. Native socketpairs check SIGPIPE protection, restored flags and a paused
writer's monotonic one-second deadline.

Ten `filtered-readiness-*` host faults remove signature, nonce, boot, policy,
version, framing, read-error distinction, public-only persistence or verification-key
cleanup. The existing boot-policy
cleanup fault is kept synchronized. These tests and the confined process gate
are not VM evidence. Real-VM checks must separately witness startup, hooks,
healthy recovery from a paused tunnel, permanent lease expiry after a paused
companion, and rejection of a wrong/missing public verification key. Every late
handoff, previous-boot capability replay, exhaustion and full NET-20/F1
qualification remain unverified.

### Signed broker-composition checks

Host `BrokerReadinessTests` and proxy transport `ReadinessTests` verify independent
Ed25519 vectors, correctly signed wrong nonce/provider/boot/policy replies,
forgeries, framing, version-1 compatibility, strict version-2 identities,
public-only persistence and cleanup after a spoofed unsigned startup response.
Provider requirements follow effective remote upstreams without resolving
credentials; local-model and proxy-off modes require none. Eleven
`broker-readiness-*` host faults and seven broker policy/timeout mutations make
these assertions discriminating. The confined process gate
`swift test --package-path iso-proxy --filter signedReadinessUsesIndependentPublicKey` independently verifies
fresh replies from both production providers without DNS or upstream requests.

For a narrow real-VM gate, build the host, `iso-egress` and `iso-proxy`, then run:

```bash
python3 tests/integration-filtered-broker-readiness.py
```

It installs a signed private runtime and uses the fail-on-use boundary image,
synthetic credentials, and an empty destination allowlist. It exercises both
broker startups and a post-start hook, paused live-PID brokers and tunnels,
wrong/missing public keys, termination, stop cleanup, restart rotation, and
refusal to complete startup with or without a hook when `--no-agents` leaves
required brokers absent, and healthy no-hook bootstrap. The no-hook refusal
regression fails against the deliberately unchecked early-return behavior.
A trusted host SSH interposer also pauses a required broker after a genuine signed
reply at two boundaries: initial resolution and completed session preparation.
Both must refuse the later exec without creating its guest marker; resume restores
fresh proof. The interposer keeps challenges and replies in memory, not artifacts.
`WorkloadHandoffTests` separately cover all four interactive launch methods,
post-preparation invalidation, fresh-probe failures, unchanged-identity controls,
owner/target/boot/policy/key/provider-set replacement, and nonfiltered compatibility.
Ten `workload-*` host faults remove the preparation/launch checks, fresh inspection,
identity comparisons and compatibility bypass. `AdministrativeHandoffTests` pair
healthy and revoked controls for 19 SSH/SCP, tar/rsync, forward, hook, alias and editor
operations, original-identity retention, nonfiltered compatibility, preparation
invalidation, and distinct readiness errors in hooks/agent updates. Pure stage
controls ensure transport proof does not demand future brokers while composite
proof does. Thirty-six `admin-*` faults remove binding, operation checks, hook
error propagation or the proof-stage distinction. The same VM interposer also
checks late version-query, workspace-push and staged-pull refusals at probe and
transfer-launch boundaries, followed by healthy transfer controls; a failed pull
must not retain a stage. Readiness refusal remains distinct from an unsuccessful
rsync availability probe. Reverse-forward controls check master/request boundaries
and PID-file cleanup. The local-to-remote model-state fixture requires future
brokers to prepare without an ordering deadlock before composite completion.
Completion controls and faults reject changed owner, target, boot/policy or egress
signer even when the later composite proof is otherwise healthy; intentional new
broker keys remain permitted during bootstrap.
Key-replacement decision fixtures
are not real-VM broker-restart or capability-replay evidence.
It removes its owned VMs, images and binary copies. This is not native-agent,
provider-forwarding, exhaustion, lifecycle-revocation or full NET-20/F1 evidence.
The ordinary VM and proxy-transition suites remain separate required gates.

### Filtered lease-record checks

Lease-record tests exercise typed PID/date decoding, native ISO8601 date
encoding, absent/null TTL compatibility, and bounded no-symlink control reads.
A real socket descriptor produces `ENOTSUP` from `flock`, which must not be
mistaken for owner contention. Six `filtered-lease-*` faults remove decoding,
positive-PID validation, lock-error classification, or control-file checks;
the deadline/owner renewal faults also remain applicable. These local tests do
not qualify live filtered-VM revocation or composite readiness.

### Native owner startup and launchd scheduling

`iso-sandbox start` loads its owner into `user/<uid>`, with
`LimitLoadToSessionType = Background`, and explicitly requests `launchctl
kickstart DOMAIN/LABEL` without `-k`. A nonzero request attempts `bootout` for
that exact job; both failure statuses remain visible if cleanup also fails.
Readiness still requires the owner's control response. Stop and delete also
unload GUI-domain jobs left by older runtimes.

With the GUI session locked, `gui/<uid>` was in on-demand-only mode. On macOS
27.0 (26A428), launchd deferred automatic VM-owner respawn after SIGKILL and
reported a pending semaphore spawn. Independent `/bin/sleep` jobs reproduced
that deferral. Explicit startup succeeded, so startup readiness alone did not
qualify recovery. The background user domain continued automatic respawn while
the same GUI session stayed locked; omitting the Background session type made
user-domain bootstrap fail with status 5.

The `recovery` phase verifies a new live owner PID after SIGKILL, synced data
survival, and no respawn after a clean guest poweroff, including a wait beyond
the launchd throttle interval. The `iso` phase also verifies that session TTL
stops the VM and that an explicit start begins a new session. The
`runtime-owner-background-*` faults pin the domain/session pair alongside the
existing demand, non-killing startup, rollback, and error-propagation faults.

### Local filtered-VM evidence (partial)

At commit `97725551b1e7a13ecdf66744f72394220c2d4b9a`, a one-off diagnostic
runner (`python3 /tmp/iso-filtered-vm-check.py`, not a checked-in or CI gate)
exited **0** on Apple Silicon macOS 27.0 (26A428), Swift 6.4
(`swift-6.4-RELEASE`), and stock `container` client/service 1.5.0.
The host and egress binaries were debug builds; the runtime was a release
build signed ad hoc with its virtualization entitlement. SHA-256:

| Binary | Hash |
| --- | --- |
| `iso` | `48b213e5f9a021496d11245bf75d02311bb8f2b94f7ea110038a3222661997b5` |
| `iso-egress` | `33faa679c93d1efa65579cefb071fe8051d89cdfcb74c406840bd05e25d7d137` |
| `iso-sandbox` | `789143ad28cda75c3352ba46d44c035e441dcccc1d801206323a9ca2aadaca7c` |

The runner used private config/data directories, the `boundary-fixture`
profile, `proxy.mode: "off"`, an environment stripped of provider credentials,
and separate project directories for open/filtered instances. It ran
`setup -y --profile boundary-fixture` and `up --no-agents --no-github`.
It checked the runtime's effective interface and executed these guest probes
through `iso exec NAME -- ...`:

- `curl -sS --max-time 15 -o /dev/null -w '%{http_code}' https://api.github.com`
  returned **200** in both the open control VM and the filtered VM whose
  sole approved host was `api.github.com`. This exercised production confined
  DNS/connect, the authenticated reverse tunnel, and verified end-to-end TLS.
- `curl -sS --max-time 10 -o /dev/null https://api.openai.com` was refused
  with **CONNECT 403** in the filtered VM, before any provider request.
- A guest shell checked that `timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'`
  failed, then returned `blocked` with exit **0** over the still-working SSH
  connection. The filtered VM had one `vmnet-host:` interface, zero runtime
  socket relays, and zero published ports. Both instances were destroyed.

This is a narrow live-VM witness, **not F1 qualification**:
cross-VM capability misuse, IPv6/adversarial routing, lifecycle revocation,
resource exhaustion, full NET-20 composite readiness, credential brokers,
native agents, and release/install/update acceptance remain unrun here.

### Native upstream client shutdown

Run:

```bash
swift test --package-path iso-proxy --filter 'tlsProbeCancellation|productionClientSharesSocketBudget'
```

The client registers native HTTP requests and DNS/TLS probes before admitting
them to shutdown ownership. Shutdown permanently closes admission, cancels every
registered operation and awaits operation completion; repeated calls are safe.
The CLI still closes guest connections first and stops its event loop group last.
AsyncHTTPClient request/body values remain adapters, but no idle client or
connection pool is created for this lifecycle.

Controlled tests keep TLS handshakes stalled while shutting down one or 256
requests, require shutdown within two seconds and observe peer/guest closure.
They also cover an active credential-free probe, repeat shutdown, and reject
post-shutdown requests/probes without new upstream connections. Physical socket
closure is observed separately after shutdown returns; operation completion does
not itself assert that every socket close future has completed.

### Swift DNS and socket admission under cancellation

Run:

```bash
swift test --package-path iso-proxy --filter 'cancelledDNS|dnsCancellation|dnsFailurePreserves|guestCancellationCannot|productionClientSharesSocketBudget|cancelledSocketKeepsAdmission'
```

The production client shares budgets for 256 underlying DNS lookups and 256
upstream socket candidates across its requests. A cancelled lookup retains its
slot until both underlying address-family results finish. A socket retains its
slot until its close future completes. Candidate admission happens before TCP
connect, so concurrent Happy Eyeballs attempts share the same socket budget.

Controlled tests hold DNS results pending while 256 authenticated guest requests
start and disconnect, then check refusal and recovery through the production
bridge. They also check cancellation before lookup, one-family completion,
original failure reasons, and the default 256-socket capacity across two event
loops. A one-socket fixture distinguishes socket admission from the guest request
limit. A delayed transport-close fixture also verifies that cancellation returns
while the still-open socket continues to occupy its slot. Resolver and capacity
overrides are internal test seams; startup does not
accept alternate destinations or guest-controlled budgets. These are admission
and cleanup tests, not aggregate process RSS measurements.

### Shared upstream disconnects and Swift response completion

The Swift matrix runs 16 exchanges: both providers, closure before headers or
during the response body, abrupt TCP closure or clean TLS shutdown, and two rounds.
It saves raw observations in the printed temporary directory and validates the
exact matrix, status, partial provider body, guest EOF, and one-slot capacity
recovery. Local 502 responses must have empty bodies. All provider traffic uses
local verified TLS fixtures with synthetic credentials.

For the Swift matrix and complete-response regression alone, run:

```bash
swift test --package-path iso-proxy --filter 'upstreamDisconnectClosesGuestAndRestoresPermits|completedResponseDrainsAfterUpstreamClosesDuringGuestWrite'
```

The verified local TLS fixture closes before response headers or during an
incomplete response body, using both abrupt TCP closure and clean TLS shutdown.
Both provider identities run twice with one connection slot and one request
slot. The guest keeps its write side open; the test requires prompt EOF, a local
502 before response headers, preservation of a started response without an
appended error, and recovery of both slots after every exchange.

A deterministic channel test holds the guest body write acknowledgment while a
complete upstream response closes. It requires the queued response end to drain
after acknowledgment, including when a TLS `uncleanShutdown` error precedes socket
closure. A failed guest write must still abort without emitting a response end.
The complete-response drain regression exercises the native
Swift transport separately from the shared disconnect matrix.

### Swift upload and response memory gates

Run the opt-in Swift resource suite on macOS:

```bash
ulimit -n 8192
ISO_PROXY_RESOURCE_GATE=1 swift test --package-path iso-proxy --filter ProxyMemoryE2ETests
```

The suite serializes its gates and launches a fresh Swift Testing helper process
for every workload, using the active built transport test bundle. It never
invokes a nested build. Each child has a private process group, a real deadline,
retained stdout/stderr and observations, and cleanup on success, failure, timeout
or cancellation. Missing or skipped worker selections fail the parent test.
Mach resident-size samples measure the entire isolated worker, including local
proxy/provider/guest fixtures after TLS setup. These are regression budgets,
rather than advertised production memory limits or confined-executable RSS.

`responseAndUploadMatrix` runs both directions at one and 256 connections:

- Responses offer 256 MiB and 1 GiB per peer while guests disable reads. Each
  producer must advance by more than zero and less than 16 MiB, then plateau
  for three seconds within a 20-second sampling budget.
- Uploads declare 16 MiB and 64 MiB per peer while providers stop reading after
  headers. Each guest must stall below 8 MiB sent, and each provider may consume
  at most 64 KiB while stalled. The same plateau requirement applies.
- RSS growth must remain below 32 MiB for one peer or 256 MiB for 256 peers.
  Guest closure must stop producers and close upstream sockets. For uploads,
  providers resume reads solely to drain socket buffers and observe EOF; this
  does not establish cancellation latency while provider reads remain paused.

Use `--filter responseAndUploadMatrix` to select this gate alone. Worker variables
`ISO_PROXY_MEMORY_GATE`, `ISO_PROXY_UPLOAD_MEMORY_GATE`, `ISO_MEMORY_RESPONSE_BYTES`,
`ISO_MEMORY_UPLOAD_BYTES` and `ISO_MEMORY_CONNECTIONS` remain test-only controls;
the parent supplies the complete matrix automatically.

### Swift aggregate partial/malformed-header memory gate

With `ISO_PROXY_RESOURCE_GATE=1`, select `partialAndMalformedHeadersMatrix` to
run two and eight rounds in separate processes. Each round holds 256 simultaneous
incomplete headers of roughly 48 KiB and requires refusal of an excess connection.
Appending an oversized field must produce exactly one 431 and EOF for every
admitted client with zero forwarded parts, then refill all 256 slots.

Mach RSS is sampled three times while headers are held and once after rejection
per round. The gate requires less than 96 MiB growth from baseline and less than
32 MiB additional growth after the first round. Schema, sample coverage, recorded
counts and cleanup are validated by the parent. The worker's opt-in variable is
`ISO_PROXY_AGGREGATE_MEMORY_GATE`.

### Swift held-stream aggregate memory gate

With `ISO_PROXY_RESOURCE_GATE=1`, select `heldStreamsMatrix` for one isolated
worker running six verified-TLS capacity rounds: 256 held responses, excess
connection refusal, and disconnect/completion/disconnect for both providers.
RSS is sampled after establishing each batch, throughout the 31-second silent
interval in completion rounds, and after cleanup. Fixture bookkeeping releases
closed channels after every round.

The parent validates capacity, memory sample coverage, less than 256 MiB RSS
growth per provider, and less than 64 MiB additional growth after that provider's
first round. The worker's opt-in variable is `ISO_PROXY_STREAM_MEMORY_GATE`.
This measures mostly idle streams; continuously producing stalled streams are
covered by `responseAndUploadMatrix`.

### Shared proxy forwarding and TLS corpus

These tests run during ordinary `swift test --package-path iso-proxy`; narrow
selections are available:

```bash
swift test --package-path iso-proxy --filter realTLSDeclaredBodyLimit
swift test --package-path iso-proxy --filter realTLSUploadIdleDeadline
swift test --package-path iso-proxy --filter realTLSStreamsHold256Slots
swift test --package-path iso-proxy --filter sharedForwardingCorpusThroughTLS
```

The body-limit gate streams exactly 64 MiB for both providers through verified
TLS using bounded 64 KiB buffers. The first chunk must arrive before the rest
is sent, and incremental SHA-256 must match the expected patterned body.
Declarations of 64 MiB plus one receive 413 with zero upstream TCP/HTTP requests.
Chunked requests with `Expect: 100-continue` receive 411 first, with no upstream
connections, body or credentials. All six records require guest EOF and the
appropriate upstream closure counts.

The body-idle cases run concurrently for both providers. Each advertises three
bytes, sends one, waits 15 seconds, then sends another. Both bytes must arrive
before completion, followed by local 408 and EOF 44–51 seconds after the initial
write. The upload remains incomplete and the upstream socket closes.

The stream-capacity gate holds 256 responses after their first SSE chunk and
requires closure of a 257th authenticated connection. Both providers run
disconnect/completion/disconnect rounds, refill the complete allowance, and
require closure of every upstream socket. Completion rounds stay silent for
31 seconds before delivering the final SSE chunk and closing normally; observed
hold durations must be 31–36 seconds. Disconnect rounds record zero hold time.
Embedded tests separately verify request-lease lifetime because the production
connection limit prevents the excess socket reaching request admission.

The forwarding gate reads `tests/fixtures/credential-proxy/forwarding.json`,
validates its schema and unique nonempty IDs, and requires one observation per
case. It checks method, raw path/query, upstream count, request/response headers,
status, body bytes and physical guest EOF. The 18 cases include untrusted issuer,
self-signed, wrong-hostname and expired certificates for both providers, two
stalled TLS handshakes with the real 30-second establishment deadline (29–35
second bounds), and two DNS failures using `iso-proxy-test.invalid`. Failures
must produce local 502, zero upstream HTTP requests and secret-free diagnostics.
Admitted replies must complete and close within five seconds while the guest
keeps its write side open. Swift checks typed resolver errors and absence of
TCP attempts for DNS failures. An unanswered TCP connect remains a separate case.

Fixtures use the shared Python/OpenSSL disposable certificate generator, system
trust with an extra per-test root, and verified provider hostnames. Destination
substitutions exist only in tests. No production endpoint override is added.
Each test retains its complete observation records in a printed private temporary
directory. Optional `ISO_FORWARD_OBSERVATIONS`, `ISO_BODY_LIMIT_OBSERVATIONS`,
`ISO_IDLE_OBSERVATIONS`, `ISO_STREAM_OBSERVATIONS` and `ISO_DISCONNECT_OBSERVATIONS`
paths remain available to test tooling, but validation does not depend on them.
The forwarding and capacity runs each take roughly two minutes plus build time.

### Swift proxy policy mutation sweep

`iso-proxy/muter.conf.yml` scopes the four policy files required by the
port specification. Build [Muter](https://github.com/muter-mutation-testing/muter)
at revision `7f1f2584e0a27fc05c952a5c8cdd52b10cc9513f`. In that checkout, apply
`scripts/patches/muter-preserve-syntax-identity.patch` from this repository using
`git apply`, then build with `swift build -c release --product muter` and run:

```bash
python3 scripts/run-swift-proxy-muter.py --muter /absolute/path/to/muter
```

The runner copies the package without build caches, records source/tool hashes,
and keeps logs and a JSON report in the printed temporary directory. It uses
all generated operators on Capability, OperationPolicy, HeaderPolicy and
RequestTarget, without filtering away uncovered files. Survivors, compilation
errors, timeouts and runtime-error outcomes require review; the wrapper only
automatically accepts assertion-killed mutants. The pinned tool reads the
timeout from `mutationTestTimeout`; use the checked-in configuration.

The patch preserves parsed syntax nodes between discovery and instrumentation.
The upstream revision discards them and reparses, so its node-keyed mutation
mapping misses every insertion in this package. It also visits nested blocks
before replacing their parents, preserving their mutation switches. The runner checks generated
switch counts against reported mutants and rejects absent instrumentation.

The targeted `scripts/test-swift-proxy-mutations.py` remains a separate check
for the spec's mandatory deny/method/path/header/equality regressions and the
three explicit HTTP parser limits.

## Fuzzing

Fuzzing is reserved for parsers of **untrusted or user-editable input** — it
finds traps, hangs and unbounded resource use, and harness properties catch
some correctness failures, so a standing harness only earns its keep where
input crosses a trust boundary. CI replays the corpus and runs a bounded smoke
of every target; longer campaigns are manual.

Harness bodies live in `fuzz/Targets/` (the `IsoFuzzHarnesses` package
target) and libFuzzer entrypoints in `fuzz/Entrypoints/`. `scripts/fuzz.sh`
compiles LLVM libFuzzer from the sources vendored in `fuzz/libfuzzer/` (see its
README; the file manifest must match the SHA-256 pinned in the script, or
`ISO_LIBFUZZER_SRC` supplies another checkout) with Xcode `clang++`, and the
production Swift sources from this revision with Xcode `swiftc`,
AddressSanitizer and SanitizerCoverage (inline 8-bit counters, PC tables,
comparison tracing). Campaigns use libFuzzer value profiling.

```bash
scripts/fuzz.sh build                        # instrumented targets in fuzz/.build
scripts/fuzz.sh replay ConfigLoad            # committed corpus, no mutation
scripts/fuzz.sh run ConfigLoad 600 20260927  # bounded campaign (seconds, seed)
scripts/fuzz.sh smoke 30                     # replay + bounded run, all targets (CI)
scripts/fuzz.sh minimize ConfigLoad fuzz/artifacts/ConfigLoad/crash-…
scripts/fuzz.sh merge ConfigLoad             # fold new inputs into fuzz/corpus
scripts/fuzz.sh qualify                      # toolchain qualification checks
```

Per-input limits: `-max_len=65536 -timeout=10 -rss_limit_mb=2048
-malloc_limit_mb=1024`. A crash is written to `fuzz/artifacts/<target>/`;
reproduce it with `scripts/fuzz.sh replay <target> <artifact>`.

**Current targets:**

- `ParseRepoSlug` — the production repository URL/slug parser (`--git-repo`
  arguments, `git remote get-url` output). Property: round trips.
- `JSONCToJSON` — the shared JSONC scanner under both the configuration and
  devcontainer policies. Properties: output length and newline preservation,
  idempotence.
- `ConfigLoad` — JSONC scanning, duplicate/limit preflight, Foundation
  decoding, domain validation and structural/domain round trips of accepted
  configurations; text placed in a secret-bearing field never appears in an
  error.

The ordinary `swift test` suite replays `fuzz/corpus/` through the same
harness bodies (`IsoFuzzReplayTests`); that is regression coverage, not
fuzzing. Promote a minimized, synthetic reproducer into
`fuzz/corpus/<target>/` so it runs in both. Qualification results and
campaign records are in the
[release validation](release-validation.md).

The untrusted-input parsers added later (devcontainer JSON, guest JSON, Codex
TOML) have unit and sanitizer coverage but no fuzz target yet.
