# Testing

coop's host is the Swift package at the repository root (`Package.swift`:
`CoopCore`, `CoopConfiguration`, `CoopHost`, `CoopCLI`). Its test layers are:

- **Swift package tests** (`tests/swift/`) — unit and contract tests for every
  host target, plus replay of the fuzz corpus. CI gate.
- **Host checks in Python** — configuration migration, compatibility
  inventory, golden parity against recorded baseline results, and the CLI
  surface. CI gate.
- **Fault injection** (`scripts/swift-host-fault-injection.py`) — shows that
  critical tests fail when their protected behavior is removed. Replaces
  mutation testing for the host.
- **Fuzzing** (`scripts/fuzz.sh`) — coverage-guided libFuzzer campaigns for the
  host parsers. CI runs a bounded smoke; longer campaigns are manual.
- **Integration tests** — real Apple Containerization VMs. Manual; run for
  guest-visible and lifecycle changes.

The credential proxy (`coop-proxy/`) and the Apple runtime (`coop-sandbox/`)
are separate Swift packages with their own tests (below).

Supported host: **macOS 27+ Apple Silicon only**. Linux guests are in scope;
Linux hosts are not.

## Swift host checks

```bash
swift build --force-resolved-versions
swift test --force-resolved-versions          # CoopCore/Configuration/Host/CLI + corpus replay
swift format lint --strict -r Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints
swift test --sanitize=address --scratch-path .build-asan     # also:
swift test --sanitize=thread --scratch-path .build-tsan
swift test --sanitize=undefined --scratch-path .build-ubsan

python3 tests/test-migrate-config.py          # TOML -> JSONC converter (Python 3.11+)
python3 tests/test-swift-host-inventory.py    # compatibility inventory completeness
python3 tests/test-swift-host-read-parity.py --swift .build/debug/coop
python3 tests/test-swift-host-lifecycle-parity.py --swift .build/debug/coop
python3 tests/test-swift-host-data-root-parity.py --swift .build/debug/coop
python3 tests/test-swift-host-cli-surface.py --swift .build/debug/coop
python3 scripts/swift-host-fault-injection.py # critical tests fail under injected faults
python3 scripts/generate-embedded-resources.py  # after editing scripts/guest/*
```

Use a separate `--scratch-path` per sanitizer so instrumented builds do not
invalidate `.build`. The package tests use synthetic credentials and isolated
temporary state; they never touch `~/.coop`.

The parity checks replay results recorded from the former Rust host (baseline
`e3ba69e`) in `tests/baseline/parity/`; no Rust toolchain is needed. The
read-parity check runs the Swift host against a synthetic state tree, with a
stand-in `coop-sandbox` (answering from `tests/fixtures/coop-sandbox`) and a
stand-in `ssh` on `PATH`, and compares stdout and exit status command by
command; recorded differences are listed in the script. The lifecycle check
does the same for `setup`, `resize`, `commit`, `restore`, `stop`, `destroy`,
`images --delete` and interrupted-journal recovery against the stateful fake
runtime in `tests/fixtures/fake-runtime/` (also a fake `container` builder),
and also compares the runtime call sequence, the resulting state files, and
the captured image build contexts byte for byte. An intended change to the
guest image changes those contexts and every hash derived from them; record it
in the golden's `revisions` list as the old→new hash substitutions (applied to
the golden), and confirm that reversing them reproduces the previous golden
exactly, so nothing else changed. The data-root check covers
the refusal of upstream coop state in the default `~/.coop`. The CLI-surface
check compares every baseline command path and option in
`tests/fixtures/baseline-cli/commands.json` with the Swift host's `--help`;
allowed differences are listed with their decision in the script.

Configuration parity fixtures live in
`tests/swift/CoopConfigurationTests/Fixtures/parity/`: each `.toml` has the
baseline loader's normalized result (`.baseline.json`) and its conversion to
`.jsonc` by `scripts/migrate-config-to-jsonc.py`; the Swift loader must produce
the same values, except for enumerated differences (C-01 retired fields and
the recorded URL spelling difference).

`python3 scripts/build-release.py --release --test` builds and tests all three
packages from a staged copy and assembles the release archive; see
[RELEASING.md](../RELEASING.md).

## Integration tests

`tests/run-integration.sh` runs the Apple Containerization VM suite,
`tests/integration-apple-sandbox.sh` (see [below](#apple-runtime-real-hardware-checks)):

```bash
./tests/run-integration.sh                        # every phase, ~20 min
./tests/run-integration.sh --only coop            # coop end to end
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
using a retained port-443 listener; see the [acceptance map](design/swift-proxy-acceptance.md)
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
their own. Do not use `coop proxy setup` for this, because it writes the
`coop-anthropic`/`coop-openai` items your normal install reads.

Do not type or paste a key at the `security add-generic-password ... -w`
prompt. The prompt keeps only the first 128 characters, so a longer key (OpenAI
`sk-proj-` keys are about 164) is stored truncated. The provider then answers
401 `invalid_api_key` and shows a different last four characters than the
console. Instead, copy the key to the clipboard and send the whole command to
`security` on stdin. This keeps the key out of argv and shell history:

```bash
{ printf 'add-generic-password -U -s coop-live-anthropic -a coop-live -w '; pbpaste; echo; } | security -i
{ printf 'add-generic-password -U -s coop-live-openai -a coop-live -w '; pbpaste; echo; } | security -i
pbcopy </dev/null   # clear the clipboard
```

(Run one line per key, copying that key first.) Check each item's length and
last four characters against the provider console, without printing the key:

```bash
security find-generic-password -s coop-live-openai -a coop-live -w |
  awk '{print length($0), substr($0, length($0)-3)}'
```

If the provider rejects a key, this shows its error message. The key goes into
curl's header on stdin (`-H @-`):

```bash
security find-generic-password -s coop-live-openai -a coop-live -w |
  sed 's/^/Authorization: Bearer /' |
  curl -sS -H @- -H 'Content-Type: application/json' \
    -d '{"model":"APPROVED_MODEL","input":"ping","max_output_tokens":16}' \
    https://api.openai.com/v1/responses
```

The Keychain Access app (File → New Password Item: name `coop-live-openai`,
account `coop-live`) also stores the full value. When finished, delete both
items with `security delete-generic-password -s coop-live-<provider> -a coop-live`
and revoke the keys.

For the guest gate, point a private config at these items. Give it its own
`data_dir` so it never touches `~/.coop`:

```jsonc
{
  "data_dir": "~/coop-live/data",
  "github": "off",
  "proxy": {
    "anthropic": { "credential": "cmd:security find-generic-password -s coop-live-anthropic -a coop-live -w", "auth": "api_key" },
    "openai": { "credential": "cmd:security find-generic-password -s coop-live-openai -a coop-live -w", "auth": "bearer" }
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
`coop-proxy/.build/debug/coop-proxy-swift`, the default, after `swift build --package-path coop-proxy`). It runs under the production Seatbelt profile
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
[`design/swift-host-acceptance.md`](design/swift-host-acceptance.md).
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
the `coop-live-anthropic`/`coop-live-openai` Keychain items above. Use
`--anthropic-credential`/`--openai-credential` to pass other `cmd:` references;
the script rejects anything that is not a `cmd:` reference. It configures only
the providers that have models. The script then:

- checks that each agent's guest endpoint is a loopback address;
- checks that each running proxy is the built `coop-proxy` and prints its
  sha256;
- runs the agent check below once per model and prints each summary.

It fails if any model fails, and destroys the VM and its images either way.
Credential values never pass through the script. It does not repeat the
synthetic-credential guest scan; that is covered by the base gate.

To run it by hand instead, prepare a disposable guest with the Swift proxy
selected, dedicated test credentials configured on the host, and normal agent
bootstrap enabled. Run the following from the repository root, substituting its
private coop config, VM name, and approved model:

```bash
coop --config PRIVATE_CONFIG shell PRIVATE_VM -- python3 -c \
  "$(cat tests/fixtures/credential-proxy/agent-tool-smoke.py)" \
  --agent codex --model APPROVED_MODEL
coop --config PRIVATE_CONFIG shell PRIVATE_VM -- python3 -c \
  "$(cat tests/fixtures/credential-proxy/agent-tool-smoke.py)" \
  --agent claude --model APPROVED_MODEL
```

This script must run **inside the guest**. It uses the existing coop agent
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
swift build --package-path coop-proxy
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
skip of the routed guest-isolation probe, since it would mask the coop rule.

Run `python3 tests/test-codex-account.py` for the account wrapper's argument,
login/logout, API-key passthrough, and `codex-yolo` regressions (also in
CI). To additionally test implicit daemon reuse with a real Linux Codex binary
(on a Linux machine, since the wrapper runs in the Linux guest):

```bash
COOP_TEST_CODEX="$(command -v codex)" python3 tests/test-codex-account.py
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


## Apple runtime (`coop-sandbox`)

The host's own tests (`CoopHostTests`) replace the `coop-sandbox` runtime (and
the stock `container` builder) with scripted fakes, so they run without either
installed. The runtime itself is a Swift package with its own unit tests (IDs,
records, subnet allocation, the control protocol, reconcile, and in
`TransactionTests.swift` disk-update failure injection and same-sandbox
locking); none of them boots a VM:

```bash
swift test --package-path coop-sandbox --no-parallel
```

The runtime tests run serially: several take, release, and re-probe `flock`
locks, and in a parallel run about one in five runs sees a released lock as
still held. Serial runs have not shown it. The cause is not yet identified
(subprocesses started by other tests are the main suspect; switching them to
`posix_spawn` did not remove it).

Parser fixtures in `tests/fixtures/coop-sandbox/` are real `coop-sandbox`
output; the directory's README says how they were captured.

### Apple runtime real-hardware checks

`tests/integration-apple-sandbox.sh` boots real `coop-sandbox` VMs and checks
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
- `coop` itself end to end (the `coop` phase): `setup`, `up`, `status`,
  `exec`, `stop`/`start`, `resize --mem/--vcpus/--size`, rollback of a
  `resize --start` whose boot fails, `commit`, `restore` with host-key
  re-pinning, `destroy`, and image deletion. The phase also checks coop's
  own sandbox for host mounts, agent forwarding, and canary leakage. It
  requires coop to refuse a changed host key and a restore it did not
  make. It kills `coop restore` and `coop resize --size` partway
  (`COOP_KILL_FRACTIONS`), and the next `start` must recover.

It builds the runtime, a small test image (`tests/fixtures/apple-sandbox/`),
and `coop`, all under a temporary work directory, and removes its state root,
sandboxes, and images on exit (`--keep` retains the work directory):

```bash
./tests/integration-apple-sandbox.sh                   # ~20 min
./tests/integration-apple-sandbox.sh --only isolation,snapshots
```

Phases: `setup disks machine isolation exposure identity persistence
resources growth snapshots recovery concurrency coop`. It needs Apple Silicon,
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

The credential proxy has its own policy mutation sweep (Muter) and targeted
mutation script; see [Swift proxy policy mutation
sweep](#swift-proxy-policy-mutation-sweep).

## Credential proxy (`coop-proxy`)

The proxy is a separate Swift package. When changing it, run at least:

```bash
swift format lint --recursive --strict coop-proxy/Sources coop-proxy/Tests
swift test --package-path coop-proxy --force-resolved-versions
python3 scripts/test-swift-proxy-process.py --skip-tls
```

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
COOP_PROXY_HANDSHAKE_AUDIT=1 swift test --package-path coop-proxy --filter auditCancellationDuringTLSHandshake
```

This opt-in dependency audit fails the two-second upstream socket closure
assertion. Request cancellation returns immediately, while client shutdown waits
for the thirty-second establishment deadline. It uses the pinned client's TLS
configuration, a local synthetic destination, and no credentials. Forwarding now
uses direct SwiftNIO/NIOSSL with owned sockets; this audit preserves the reason
for that replacement and is not the acceptance test for the new bridge.
Run `swift test --package-path coop-proxy --filter bridgeCancellationClosesStalledTLSHandshake`
for guest-disconnect coverage through the new bridge, for both provider identities.

### Cancellable Swift TLS connection component

Run `swift test --package-path coop-proxy --filter ownedTLS` for the direct
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
behavior. `python3 scripts/test-swift-proxy-process.py` runs the production-profile
DNS/TLS probe through the owned connection and shared admission budgets. It verifies
both provider identities without sending HTTP requests or credentials, then checks
that removing the exact trustd permission breaks system verification. It does not
replace credentialed provider/agent smoke tests or broader memory measurements.
DNS/candidate admission has the dedicated tests below.

### Native upstream client shutdown

Run:

```bash
swift test --package-path coop-proxy --filter 'tlsProbeCancellation|productionClientSharesSocketBudget'
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
swift test --package-path coop-proxy --filter 'cancelledDNS|dnsCancellation|dnsFailurePreserves|guestCancellationCannot|productionClientSharesSocketBudget|cancelledSocketKeepsAdmission'
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

Run `python3 scripts/test-proxy-upstream-disconnect.py` on macOS for the shared
Swift matrix. It runs 16 exchanges: both providers, closure
before headers or during the response body, abrupt TCP closure or clean TLS
shutdown, and two rounds. Raw observations and comparison results are saved in
the printed temporary directory. The runner checks the exact matrix and validates
status, partial provider body, guest EOF, and one-slot capacity recovery. Local
502 responses must have empty bodies. No live credentials or provider network are used.

For the Swift matrix and complete-response regression alone, run:

```bash
swift test --package-path coop-proxy --filter 'upstreamDisconnectClosesGuestAndRestoresPermits|completedResponseDrainsAfterUpstreamClosesDuringGuestWrite'
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

Run `python3 scripts/test-swift-proxy-memory.py` on macOS for both directions;
`--direction response` or `--direction upload` selects one. It starts separate
selected-test processes for every workload, avoiding RSS
interference from other unit tests. The production transport talks to a local
verified TLS fixture. Each producer retains one 64 KiB buffer and awaits every
write. Mach resident-size samples cover the entire test
process, including proxy, provider and guest, after TLS setup.

For responses offering 256 MiB and 1 GiB, the guest disables socket reads.
The gate requires less than 32 MiB RSS growth, less than 16 MiB upstream progress,
and at least three seconds with no further upstream progress within a 20-second
sampling budget. Closing the guest must close the upstream socket and stop its
producer. Raw samples and command outcomes are retained. The thresholds are
test regression budgets, not advertised production memory limits.

For declared uploads of 16 MiB and 64 MiB, the provider stops reading after
request headers. An outstanding TLS read may consume at most 64 KiB afterward.
The guest must stop advancing below 8 MiB sent, with less than 32 MiB RSS growth
and the same three-second plateau within 20 seconds. Closing the guest must stop
its producer; the provider then resumes reads to drain socket buffers and observe
EOF. This cleanup check does not establish upstream cancellation latency while
provider reads remain paused.

For aggregate response pressure, run
`python3 scripts/test-swift-proxy-memory.py --direction response --connections 256`.
It establishes all 256 TLS requests before releasing their producers together.
Every guest disables reads. Each producer must advance by more than zero and
less than 16 MiB, aggregate progress must plateau for three seconds, and all
upstream sockets/producers must terminate after guest closure. The aggregate
RSS growth budget is 256 MiB, measured after connection setup. The offered sizes
are per stream (64 GiB and 256 GiB total), so passing requires backpressure well
before the offered responses are exhausted. Per-peer progress is recorded.

For aggregate uploads, use the same runner with
`--direction upload --connections 256`. All 256 TLS peers stop reading before
guest producers start. Offered sizes are 16 MiB and 64 MiB per stream (4/16 GiB
total). Each guest must stall below 8 MiB sent, each provider may consume at most
64 KiB while stalled, aggregate progress must plateau for three seconds, and
RSS growth after setup must remain below 256 MiB. Guest closure stops every
producer; providers then resume reads solely to verify EOF after draining their
socket buffers. Per-peer sent/received counts and cleanup are recorded. Omit
`--direction` to run both aggregate directions.

Neither mode measures a
Seatbelt-confined process. Tests are opt-in through `COOP_PROXY_MEMORY_GATE` and
`COOP_PROXY_UPLOAD_MEMORY_GATE`; the runner sets the selected variable and rejects
skipped test selections.

### Swift aggregate partial/malformed-header memory gate

Run `python3 scripts/test-swift-proxy-aggregate-memory.py` on macOS. Separate
processes run two and eight rounds of 256 simultaneous incomplete headers, each
roughly 48 KiB. The production listener/parser/gate must retain all 256 admitted
connections and close an excess connection. Appending an oversized field must
produce exactly one 431 and EOF for every admitted client, without forwarding any
request parts. The next round must refill all 256 slots.

The test samples whole-process Mach RSS three times while the headers are held
and once after rejection in every round. It requires less than 96 MiB growth
from baseline and less than 32 MiB additional growth after the first round.
These are regression budgets that include fixture clients and allocator reuse.
The runner checks sample coverage and recorded outcomes and rejects a skipped
test. This workload covers concurrent parser buffering and malformed-client
churn; it does not measure 256 simultaneous streamed request/response bodies or
the confined executable. Its opt-in variable is
`COOP_PROXY_AGGREGATE_MEMORY_GATE`.

### Swift held-stream aggregate memory gate

Run `python3 scripts/test-swift-proxy-stream-memory.py` on macOS. It selects one
isolated test process and uses the existing six verified-TLS capacity rounds:
256 held responses, excess-connection refusal, and disconnect/completion/disconnect
for both providers. RSS is sampled after establishing each batch, throughout the
31-second silent interval in completion rounds, and after cleanup. Fixture
bookkeeping releases closed channels after every round.

The gate requires less than 256 MiB whole-process RSS growth per provider and
less than 64 MiB additional growth after that provider's first round. The runner
also validates the existing stream-capacity contract and memory sample coverage.
These regression budgets include all local provider/guest TLS fixtures. The test
is opt-in through `COOP_PROXY_STREAM_MEMORY_GATE`. This measures many established,
mostly idle streams; saturation with 256 continuously producing stalled streams
and the confined executable are separate workloads.

### Shared proxy forwarding and TLS corpus

Run `python3 scripts/test-proxy-body-limit.py` on macOS for the compared
declared-length and unknown-length boundary gate. For each provider it streams
exactly 64 MiB
through verified TLS using bounded 64 KiB test buffers. The first chunk must
reach the fixture before the guest sends the remainder; the receiver hashes
incrementally and its SHA-256 must match the expected patterned body. A separate
request declaring 64 MiB plus one byte must receive 413 with zero upstream TCP
connections or HTTP requests. Both paths require guest EOF and upstream socket
closure. The runner validates six complete records, retaining logs and raw observations in a printed
temporary directory. Test-only `COOP_BODY_LIMIT_OBSERVATIONS` captures counts
and digest. The individual gate is `swift test --package-path coop-proxy --filter realTLSDeclaredBodyLimit`.
A chunked request with
`Expect: 100-continue` must receive 411 as its first response, with zero upstream
connections, requests, body bytes, or injected credentials. The shared runner
compares six provider/framing cases for the Swift implementation.

Run `python3 scripts/test-proxy-body-idle.py` on macOS for the compared body-idle
gate. Both provider cases run concurrently within each implementation through
verified TLS. Each advertises three body bytes, sends one, waits 15 seconds,
and sends a second. Both bytes must reach the fixture before request completion,
then the guest must receive local 408 and EOF 44–51 seconds after its initial
write. The upload must remain incomplete and the upstream socket must close.
The runner validates both providers' status, partial body and closure observations, retaining
raw elapsed times while excluding scheduler timing from equality comparison.
Logs, raw observations and comparison evidence are retained in a printed
temporary directory. `COOP_IDLE_OBSERVATIONS` is consumed only by test code.
The individual gate is `swift test --package-path coop-proxy --filter realTLSUploadIdleDeadline`.

Run the compared TLS stream-capacity gate on macOS:

```bash
python3 scripts/test-proxy-stream-capacity.py
```

It retains logs, command outcomes and per-implementation observations in a
printed temporary directory. It validates six complete, unique rounds against
the contract and compares held-response count, upstream request/closure counts,
excess-response bytes and completed-response count. Unexpected fields and
incorrect field types fail validation. Record order is ignored. The optional
`COOP_STREAM_OBSERVATIONS` path is read only by test code. Individual gates are:

```bash
swift test --package-path coop-proxy --filter realTLSStreamsHold256Slots
```

For each provider they hold 256 responses after their first SSE chunk and
require closure of a 257th authenticated request. Three rounds exercise
disconnect, normal completion, then disconnect again. Refilling the complete
allowance proves capacity recovery after both paths, and each round requires
all upstream sockets to close. Separate embedded tests check request-lease lifetime because
the production connection limit prevents a 257th socket reaching admission.
Synthetic credentials and the same disposable certificate generator are used.
The fixture server disables HTTP pipelining assistance so it continues reading
peer EOF while a response is held open. These gates supplement the shared
forwarding corpus. The comparison was checked by deliberately altering each
count, dropping/duplicating rounds, adding a field and substituting a boolean
for an integer; these alterations are rejected.

The completion round holds every stream open for 31 seconds after its first
SSE chunk, then requires delivery of the final chunk and normal closure. This
checks survival beyond the 30-second establishment budget, including a silent
response interval. Captures retain `held_duration_ms`; the runner checks a
31–36 second interval and omits scheduler timing from equality comparison.
Disconnect rounds record zero hold time. The combined gate takes about two
minutes plus build time.

On macOS, run `python3 scripts/test-proxy-forwarding-corpus.py`. This runs the
`tests/fixtures/credential-proxy/forwarding.json` cases through Swift loopback
TLS fixtures. It retains logs, raw observations,
normalized comparison, command outcomes and the corpus SHA-256 in a printed
temporary directory, and rejects an empty test selection. Python 3 and OpenSSL
are required in addition to Swift.

Both tests generate disposable short-lived certificates with the shared
`generate-forwarding-certificates.py` fixture generator. Swift keeps system
trust evaluation with a per-evaluation extra root. Neither test disables hostname/chain verification or changes host trust.
Destination substitutions exist only in tests; all credentials are synthetic.

For admitted requests, this gate checks shared expectations and compares
captured method, raw path/query, upstream request count, all request/response
headers, response status, peer connection closure, and SHA-256 of both bodies.
Header names are lowercased and pairs sorted; duplicate entries are retained.
No headers are omitted. Both fixture servers send the same explicit Date
header. Raw byte arrays and headers remain in the observation files for
inspection. The optional observation path is consumed only by test code
(`COOP_FORWARD_OBSERVATIONS`).

The comparison tripwire was checked by changing captured request/response
bytes, path, status, duplicate header count, and upstream count: each
alteration was rejected, while header-order/case-only changes compared equal.
This gate complements the raw refusal/fuzz harness. The eight certificate-
failure cases cover untrusted issuer, self-signed, wrong hostname and expired
certificates for each provider. They compare local 502, zero upstream HTTP
requests and physical peer closure; local error prose and its content headers
are not compared. The fixtures assert
that local diagnostics contain neither synthetic secret. The runner validates
the exact observation schema for each case type. Shared streaming/resource and
connect-timeout cases remain separate work before migration
cutover. The admitted fixtures leave the guest write side open and require one
complete response followed by peer EOF within five seconds. Swift observes
channel inactivity without closing on the response header/end. Removing
Swift's successful-response close in an isolated source copy fails this
deadline, confirming the probe detects it.

The corpus also contains two stalled TLS-handshake cases, one per provider.
They use the real 30-second establishment deadline and require local 502,
zero HTTP requests and upstream socket release. Raw elapsed milliseconds are
retained and checked against the corpus's 29–35 second bounds; scheduler timing
need not be identical across implementations. Two additional cases route the
fixed provider endpoint to the reserved name `coop-proxy-test.invalid` in test
code only. They require a DNS failure, local 502, zero upstream HTTP requests
and physical guest closure. Swift checks the typed A/AAAA resolver errors and
the absence of TCP connection attempts.
The complete 18-case run takes about two minutes plus build time. An unanswered
TCP connect remains a separate case.

### Swift proxy policy mutation sweep

`coop-proxy/muter.conf.yml` scopes the four policy files required by the
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

Harness bodies live in `fuzz/Targets/` (the `CoopFuzzHarnesses` package
target) and libFuzzer entrypoints in `fuzz/Entrypoints/`. `scripts/fuzz.sh`
compiles LLVM libFuzzer from the sources vendored in `fuzz/libfuzzer/` (see its
README; the file manifest must match the SHA-256 pinned in the script, or
`COOP_LIBFUZZER_SRC` supplies another checkout) with Xcode `clang++`, and the
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
harness bodies (`CoopFuzzReplayTests`); that is regression coverage, not
fuzzing. Promote a minimized, synthetic reproducer into
`fuzz/corpus/<target>/` so it runs in both. Qualification results and
campaign records are in the
[acceptance ledger](design/swift-host-acceptance.md#fuzz-toolchain-qualification-section-71).

The untrusted-input parsers added later (devcontainer JSON, guest JSON, Codex
TOML) have unit and sanitizer coverage but no fuzz target yet.
