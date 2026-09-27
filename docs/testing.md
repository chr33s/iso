# Testing

coop has four test layers: integration tests (the primary gate), unit tests,
and three manual quality checks — mutation testing, fuzzing, and formal
verification (kani). Only the integration and unit tests run in CI; the other
three are manual, run when a change warrants them.

## Integration tests

VM integration uses two scripts:

- `tests/integration.sh` — the test suite. Runs locally, requires `--binary`.
- `tests/run-integration.sh` — the runner. Builds, deploys (if remote), and
  invokes the test suite.

Run on **both platforms** before every commit:

```bash
# Local (macOS/Lima) — builds and runs automatically
./tests/run-integration.sh

# Remote (Linux/Firecracker) — detects remote arch, cross-compiles, copies, runs
./tests/run-integration.sh --remote user@remote-host

# With options (forwarded to integration.sh)
./tests/run-integration.sh --remote user@remote-host --full
./tests/run-integration.sh --profile python,node --name my-test
```

You can also run the suite directly if you already have a binary:

```bash
./tests/integration.sh --binary /path/to/coop --full
```

The test exercises the full VM lifecycle (setup → start → status → shell →
guest environment → docker → stop → destroy). CI additionally runs the fast,
host-only `tests/integration-install.sh`, `tests/integration-update.sh`, and
`tests/integration-uninstall.sh` suites.

The `--full` suite includes a dedicated `--no-github` phase. It captures the
boot session through `post_start` for fresh `up`, `start`, and a stopped-project
`up`, checks that model credentials still arrive, and witnesses normal GitHub
forwarding on an intervening invocation without the flag.

For the macOS 27+ Swift proxy transition, build the local dual artifacts and
run the dedicated Apple sandbox gate:

```bash
python3 scripts/build-proxy-transition.py
python3 tests/integration-proxy-transition.py
```

The transition builder enforces the checked-in Swift dependency resolutions;
it fails instead of updating transitive pins during an artifact build.

This gate builds a private runtime and VM image, boots two VMs with Swift, and
checks OpenAI guest 401/403 responses and rejection of the other VM's capability.
It scans regular guest files for synthetic provider credentials, excluding
`/proc`, `/sys`, and `/dev`; a temporary canary verifies the scanner before the
full scan. Search values enter the scanner over stdin. It stops the main VM and
starts it with Rust to exercise explicit rollback while the peer stays on Swift.
It checks both providers' selected proxy processes, listener teardown, and a
guest curl transport failure after terminating the OpenAI proxy. The curl check
does not prove how a real agent reports the failure. Credentials are synthetic
and all guest requests use denied GET operations; this does not replace admitted
VM forwarding, streaming, or live provider/agent smoke tests. It needs Apple's
container service running and removes its VMs and images on completion.
Failed runs retain diagnostic artifacts at the printed temporary path.
The gate also removes the selected Swift artifact and substitutes an executable
that exits immediately, checking that both starts fail with the expected reason
and create no proxy PID records while the Rust binary remains available.

The additional controlled-upstream phase is under development and has not yet
passed its real-VM gate:

```bash
sudo -v
python3 tests/integration-proxy-transition.py --controlled-upstream
```

It replaces each owned Swift proxy with an opt-in XCTest process using the same
server and streaming transport under the unchanged production Seatbelt profile.
It uses loopback routing and an additional fixture trust anchor. The fixture
bypasses production startup, resolver admission, and upstream work accounting;
it does not establish production system-trust or resource-limit parity. It checks
both providers' injected synthetic credential, fixed Host/SNI, request hash,
header stripping, and response hash. The TLS upstream withholds the last SSE
event until the guest acknowledges the first, to detect response aggregation.
macOS requires privilege for loopback port 443: a short-lived helper binds that
port and passes the listener to the unprivileged harness over a private Unix
socket. The helper handles no TLS or HTTP and receives no credentials. No host
trust-store changes or production endpoint overrides are made. Port 443 must be
free. This fixture is not linked into the production executable.

### Live proxy API smoke

After the controlled-upstream VM gate passes, use dedicated provider credentials
and explicitly approved model names. The opt-in runner reads a credential from
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
by the account. The default binary is `target/debug/coop-proxy-swift`; `--binary`
selects a specific built artifact. It runs under the production Seatbelt profile
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
or Claude/Codex tool-use gate. Live executions remain pending dedicated inputs.
`python3 tests/test-proxy-live.py` exercises the runner offline in CI and makes
no provider calls.

### Live guest agent tool use

After the controlled-upstream gate passes, prepare a disposable guest with the
Swift proxy selected, dedicated test credentials configured on the host, and
normal agent bootstrap enabled. Run the following from the repository root,
substituting its private coop config, VM name, and approved model:

```bash
target/debug/coop --config PRIVATE_CONFIG shell PRIVATE_VM -- python3 -c \
  "$(cat tests/fixtures/credential-proxy/agent-tool-smoke.py)" \
  --agent codex --model APPROVED_MODEL
target/debug/coop --config PRIVATE_CONFIG shell PRIVATE_VM -- python3 -c \
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

The shared malformed HTTP harness runs both real proxies under Seatbelt:

```bash
cargo build -p coop-proxy
swift build --package-path macos/coop-proxy
python3 scripts/test-proxy-contract.py --fuzz-cases 10000 --seed 20260927
python3 scripts/test-proxy-contract.py --replay /path/to/request.bin
```

The seeded mutations cover raw request lines, framing fields, binary/control
bytes, whitespace, and oversized fields. Fuzz inputs never contain a valid
capability and cannot authorize provider operations. The harness half-closes
each fuzz input, bounds response reads, checks process survival and secret-free
output, and periodically checks readiness. Fixed corpus cases separately assert
exact Rust/Swift status parity, including incomplete inputs without EOF. Fuzz
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
Linux CI runs them. The full VM suite additionally checks these probes against
real guests. A host FORWARD policy other than ACCEPT still causes an explicit
skip of the routed guest-isolation probe, since it would mask the coop rule.

Run `python3 tests/test-codex-account.py` for the account wrapper's argument,
login/logout, API-key passthrough, and `codex-yolo` regressions (also in Linux
CI). To additionally test implicit daemon reuse with a real Linux Codex binary:

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

## Host-only bridge isolation test

`./tests/run-integration.sh --full` runs the bridge isolation gate before
the VM suite, on the selected local or remote host. A failure stops the full
run; macOS explicitly skips this Linux-only gate. `TEST_FULL=1` also enables
both gates. Remote full runs copy the tracked working-tree source and require
the build and namespace prerequisites below on the remote host.

Run `./tests/integration-network.sh` directly on Linux to test bridge-port
isolation without KVM or VM images. It builds a library test as the current
user, then uses passwordless sudo to run it in disposable network, mount, UTS, and PID
namespaces. Prerequisites are Rust/Cargo, Python 3, sudo, iproute2, iptables,
iputils-ping, util-linux, hostname, and coreutils. Missing prerequisites fail
the gate; macOS reports an explicit skip. Linux CI runs this gate.

Two veth-backed endpoints first communicate through a bridge with no firewall
rules. The test calls the production isolation helper on each bridge port:
one isolated port still permits communication, while two block peer traffic
in both directions and preserve gateway access. Removing isolation restores
communication. Ping execution errors fail the test rather than counting as
isolation. The runner bounds execution and destroys the namespace resources
on success, failure, or timeout.

This exercises the bridge mechanism shared by veths and TAPs. The existing
Firecracker `--full` phase checks actual VM TAP flags and both direct and routed
traffic; it also detects removal of the helper call from `setup_tap`. This
host-only gate does not replace Firecracker or Lima VM integration.

## Host-only proxy reverse-forward test

Run `./tests/integration-proxy-forward.sh` on Linux to exercise the production
reverse-tunnel startup against real OpenSSH. It authenticates with throwaway
keys, witnesses traffic through an accepted forward, then occupies the guest
loopback port and requires startup to return an error without publishing a PID
or leaving the SSH master alive. Separate host and guest network namespaces
allow the destination and reverse listener to use the same port.

The runner requires Rust/Cargo, Python 3, passwordless sudo, iproute2,
util-linux, coreutils, hostname, and OpenSSH client/server tools. It builds
unprivileged, then confines the fixture to disposable mount, network, UTS, and
PID namespaces. No user SSH configuration or keys are used. Namespace teardown
removes all children and temporary files on success, failure, or timeout.
Linux CI and release preflight run this gate explicitly; ordinary unit tests
mark it ignored, and macOS preflight reports it as unrun. This host test does
not replace the Firecracker and Lima VM integration gates.

## Apple sandbox backend (macOS, opt-in)

The `apple-container` feature builds only on macOS. Its unit tests replace the
`coop-sandbox` runtime (and the stock `container` builder) with a scripted
executor, so they run without either installed. The runtime itself is a Swift
package with its own unit tests (IDs, records, subnet allocation, the control
protocol, reconcile, and in `TransactionTests.swift` disk-update failure
injection and same-sandbox locking); none of them boots a VM:

```bash
cargo clippy --all-targets --features apple-container -- -D warnings
cargo test --features apple-container
swift test --package-path macos/coop-sandbox --no-parallel
```

The Swift tests run serially: several take, release, and re-probe `flock`
locks, and in a parallel run about one in five runs sees a released lock as
still held. Serial runs have not shown it. The cause is not yet identified
(subprocesses started by other tests are the main suspect; switching them to
`posix_spawn` did not remove it).

Parser fixtures in `tests/fixtures/coop-sandbox/` are real `coop-sandbox`
output; the directory's README says how they were captured.

### Real-hardware checks

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
and an `apple-container` build of coop, all under a temporary work directory,
and removes its state root, sandboxes, and images on exit:

```bash
./tests/integration-apple-sandbox.sh                   # ~20 min
./tests/integration-apple-sandbox.sh --only isolation,snapshots
```

Run it before changing the `containerization` pin, the runtime's VM
configuration, or the isolation gate, and whenever the macOS major version
changes. [`design/apple-sandbox-runtime.md`](design/apple-sandbox-runtime.md)
records why this runtime was chosen;
[`design/apple-sandbox-transactions.md`](design/apple-sandbox-transactions.md)
lists the mutation invariants these tests defend and what is still untested.

## Mutation testing

Mutation testing finds unit tests that pass even when the code is broken — real
behavioral gaps. We use [`cargo-mutants`](https://mutants.rs/). It's a manual
quality check, not a CI gate.

**Install once** — via `./scripts/install-dev-tools.sh --all`, or directly:

```bash
cargo install cargo-mutants --locked
```

**When to run.** After significant edits to a logic-dense module, or before
refactoring one (capture surviving mutants first to know what behavior isn't
pinned down). Don't run it routinely — runs take minutes per module.

**Where it pays off in this crate.** Only on code with branches, arithmetic,
parsing, or state composition:

- `src/config.rs` — parsing, validation, defaults, env composition
- `src/workspace.rs` — rsync arg construction, mount-state record/remove
- `src/devcontainer.rs`, `src/guest_env_state.rs` — env merging and persistence
- `src/github_repo.rs`, `src/github_pat.rs`, `src/secret_store.rs` — slug
  parsing, secret routing
- `src/fs_util.rs` — path manipulation helpers
- `src/commands/` (`lifecycle.rs`, `profiles.rs`, `commands/devcontainer.rs`,
  `quickstart.rs`, `admin.rs`) — the pure helpers the command handlers were
  carved into: input-compatibility guards, summary/message builders, the
  `TranslatorInputs` builder, byte→GiB arithmetic kernels, and predicates like
  `discovered_local_devcontainer` / `is_sensitive_workspace`

- `src/apple_container/` — the sandbox backend's parsers, isolation gate,
  records, journal reconciliation, and lifecycle against a scripted runtime.
  The module compiles only with its feature on macOS, so sweep it separately:

  ```bash
  cargo mutants --features apple-container -f 'src/apple_container/*.rs'
  ```

**Don't bother with:** `backend.rs`, `lima.rs`, `setup.rs`, `update.rs`,
`shell.rs`, `port_forward.rs`, `cmd.rs`, `ssh.rs`, `vm.rs`, `prompt.rs` (TTY
prompts), `main.rs`, and — inside `src/commands/` — the `cmd_*` dispatch
entrypoints and the handlers that take a `&PlatformBackend`, write stdout, or
open a TTY prompt (e.g. `create_up_instance`, `restart_instance`,
`find_stopped_instance`, `resolve_running`, `resolve_devcontainer`,
`purge_all_data`, and `model.rs`'s `render_status`/`set_local`/`set_remote`/
`report_switch`/`apply_to_running`/`prompt_endpoint`), plus the `lib.rs`
`run`/`init_tracing` shims. These mostly shell out, run SSH, or talk to external
services — unit tests can't catch behavioral changes there. `tests/integration.sh`
does that job. This list is enforced (not just advised) by `.cargo/mutants.toml`
— see **Scoping** below.

### Scoping (`.cargo/mutants.toml`)

The mutation surface is curated in `.cargo/mutants.toml` so the `missed` list
means "real unit-test gap," not "code a `--lib` test structurally cannot reach."
cargo-mutants reads this file automatically on every run (`--list` included). It
scopes out three things:

- **The whole-module "Don't bother with" files above** (`main.rs`, and
  `prompt.rs` — every function short-circuits off a TTY and otherwise reads
  stdin, with no pure logic a `--lib` test can reach), via `exclude_globs`.
- **`cfg(kani)` proofs** (`config.rs mod proofs`), via `exclude_re = ["proofs::"]`
  — never compiled in a normal build, so every mutation is a silent no-op that
  always reports `missed`. They are exercised by `cargo kani`.
- **Individual shell-out / IO / terminal functions inside otherwise-logic-bearing
  modules** (`github_pat.rs`, `workspace.rs`, `devcontainer.rs`,
  `secret_store.rs`, `fs_util.rs`, `commands/model.rs`'s stdout/backend/TTY
  functions), via `exclude_re`. Each pattern is `\b`-anchored to a function name
  (or qualified `Type::method`) so it scopes the whole function without catching
  longer names that share a prefix. The module-agnostic `replace gh_auth_token ->`
  pattern also covers the identical `gh_auth_token` shell-out in
  `git_repo_devcontainer.rs`.
- **The `src/commands/` dispatch entrypoints and backend-driving / TTY handlers**,
  via `exclude_re`: a single `\bcmd_[a-z_]+\b` covers every `coop <subcommand>`
  entrypoint, plus `\b`-anchored names for the `&PlatformBackend` handlers
  (`create_*`, `restart_instance`, `start_instance`, `find_stopped_instance`,
  `resolve_running`, `preflight_start_target`, `current_disk_gib`, …), the IO
  handlers in `admin.rs`/`profiles.rs`/`commands/devcontainer.rs`/`quickstart.rs`,
  and the `lib.rs` `run`/`init_tracing` shims.

A cargo-mutants quirk to know about: `exclude_re` does **not** match `delete
field … from struct …` mutants — emitted for every struct literal that uses
`..Default::default()`, and no pattern filters them. In this crate they all
target `devcontainer::TranslatorInputs`, assembled in four places. The one pure
builder (`up_translator_inputs`) stays in scope and is unit-tested, which kills
its field-deletion mutants; the three shell-out handlers that build it inline
(`run`, `cmd_devcontainer_check`, `quickstart_fresh_start`) carry an in-source
`#[mutants::skip]` with a back-reference to `.cargo/mutants.toml`.

What is deliberately *kept* (a survivor here is a genuine coverage regression):
the pure-logic helpers the #321–#327 fixes carved the shell-out/IO functions
down to — `parse_curl_status_body`, `parse_user_login`, `github_pat.rs`'s
`render_status` (note `commands/model.rs` has a *different*, excluded
`render_status`, so its exclude is file-anchored), `parse_gh_token` /
`normalize_token`, `pick_backend`, `doc_contains_literal_token`, the SSH-config
marker-block helpers (`remove_marker_blocks` / `remove_named_marker_block` /
`remove_all_ssh_config_at` / `remove_ssh_config_at`), `CmdToken::from_words`'s
Linux/`op`/`cat` arms (only the macOS keychain arm is scoped, pinned on macOS by
`parse_recognises_macos_keychain`), `Report::push`, `atomic_write_with_mode`,
and the editor strategy helpers (`vscode_strategies` / `zed_strategies` /
`editor_strategies` / `install_hints` / `may_try_after_nonzero_exit`). The thin
wrappers those were split out of
(`probe_user_login`, `run_status`, `remove_*_ssh_config`, `gh_auth_token`) are
excluded — a `--lib` test can't reach them without a real `$HOME` or network.
When adding a new shell-out or IO function to one of these modules, add a
matching `exclude_re` line; when adding logic, leave it in scope.

The same split applies in `src/commands/`. Kept in scope: the
input-compatibility guards (`ensure_up_existing_inputs_are_compatible[_for_git_repo]`,
`up_has_restart_only_inputs`, `restart_has_ignored_creation_flags`,
`validate_copy_workspace_mounts`), the config-IO lookups
(`find_workspace_instance`, `find_git_repo_instance`), the message/summary
builders (`no_stopped_instance_message`, `creation_options_rejected_message`,
`builtin_summary`, `format_custom_summary`, `script_summary`), the
`up_translator_inputs` builder, the arithmetic kernels `bytes_to_gib` and
`format_dir_size`, `project_dir_to_str`, and the predicates
`discovered_local_devcontainer` / `is_sensitive_workspace`. The backend-driving
wrappers those kernels were carved out of (`current_disk_gib`,
`dir_size_display`) are excluded.

The `coop model` feature (#352) follows the same split. Kept in scope (and
unit-tested): `tools_needing_prompt`, `switch_report_lines`,
`ModelState::resolved_claude` / `resolved_codex` / `is_default` /
`load_or_default`, and `ModelMode::as_str`; plus `From<ModelAction> for
ModelMode` in `lib.rs`. Excluded as IO/backend/TTY: `model.rs`'s `render_status`
/ `write_tool_line` / `set_local` / `set_remote` / `report_switch` /
`apply_to_running` / `prompt_endpoint`, and `lifecycle.rs`'s
`bootstrap_and_post_start` / `prepare_session_from_target`.

**Keep `.cargo/mutants.toml` in sync in the same PR that adds the code** — this
is not a follow-up chore. #352 was merged without scoping its new IO/backend/TTY
functions, which silently broke the documented baseline and surfaced 22
survivors only at the next release preflight (#373). When a change adds a
function that shells out, drives a `&PlatformBackend`, reads a TTY, or writes
stdout, add its `exclude_re`/`exclude_globs` entry (and extract any pure logic
into a kept, tested helper) before merging. Verify with `cargo mutants -f
<touched files> -- --lib` — not just the `--in-diff` sweep, which only mutates
changed lines and so misses pre-existing same-class survivors in a touched file.
The [`mutation-check`](../.agents/skills/mutation-check/SKILL.md) skill walks
this workflow.

### Running it

Always scope with `-f`; all logic lives in the library crate, and every unit
test runs in the lib target, so pass `-- --lib`. (`-- --bins` runs zero tests
and reports every mutant as missed.)

```bash
# One file
cargo mutants -f src/config.rs -- --lib

# Several logic modules at once
cargo mutants -f src/config.rs -f src/workspace.rs -f src/devcontainer.rs -- --lib

# PR-scoped: mutate only lines changed vs main
cargo mutants --in-diff <(git diff origin/main -- 'src/*.rs') -- --lib

# Estimate cost without running
cargo mutants --list -f src/config.rs
```

A baseline run on `config.rs` (197 mutants) takes ~8 minutes on a workstation.

### Reading the output

Results land in `mutants.out/` (gitignored): `caught.txt` (killed — good),
`missed.txt` (not caught — the interesting ones), `unviable.txt` (broke the
build; ignore), `timeout.txt` (hung; rare). A kill rate around 70–80% on viable
mutants is healthy. Aim to drop the *number* of survivors, not chase 100% —
many remaining mutants are equivalent.

### Handling survivors

For each line in `missed.txt`:

1. **Real test gap.** The mutation alters observable behavior and nothing fails.
   Add a test that distinguishes the mutant from the original (assert on the
   actual value, not "it didn't panic"). Re-run to confirm.
2. **Equivalent mutant.** The mutation doesn't change behavior any caller can
   observe (`fmt::Display` returning `Ok(Default::default())`, getters returning
   a default that matches the real value, constant accessors). Skip with an
   attribute and a one-line reason:
   ```rust
   #[mutants::skip] // equivalent: Display output isn't asserted by callers
   fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { ... }
   ```
3. **Dead code.** If genuinely unused, delete it (per "replace, don't
   deprecate"). Surviving mutants on dead code are a useful smell.

### Baselines

- **2026-06-17 (after #329 scoping, #321–#330 fixes).** A sweep of the eight
  logic modules (`config.rs`, `workspace.rs`, `devcontainer.rs`,
  `guest_env_state.rs`, `github_repo.rs`, `github_pat.rs`, `secret_store.rs`,
  `fs_util.rs`) reports **0 missed**. Treat any *new* survivor as a coverage
  regression — first confirm it isn't a shell-out/IO function that belongs in
  `.cargo/mutants.toml`, then add a test.
- **2026-06-24 (issue #344).** A sweep of `lifecycle.rs`, `profiles.rs`,
  `commands/devcontainer.rs`, `quickstart.rs`, `admin.rs`, `commands/mod.rs`,
  `lib.rs`, and `jsonc.rs` reports **0 missed** out of 229 mutants. The
  non-caught results are `unviable` (~18) and `timeout` (~16–17, all `jsonc.rs`
  scanner-index increment mutants where mutating the step makes the loop never
  terminate).
- **2026-06-26 (issue #373).** After scoping the #352 local-model IO/backend/TTY
  functions and adding the `mode_as_str_round_trips`, `model_action_maps_to_mode`,
  and `load_or_default_returns_saved_state` tests, a sweep of
  `src/commands/model.rs`, `src/model_state.rs`, and `src/prompt.rs` reports
  **0 missed** (32 caught, 3 unviable), and a full `src/lib.rs` sweep reports
  **0 missed** (11 caught).

### Shared confined proxy refusal corpus

On macOS, build both proxy executables, then run
`python3 scripts/test-proxy-contract.py`. It runs 37 shared refusal cases for
both providers against each executable under the production Seatbelt profile.
The two slow-header cases retain an incomplete header, with one sending more
bytes after six seconds. Both require HTTP 408 and peer closure within 9–13
seconds, proving that partial progress does not reset the initial ten-second
deadline. The suite takes about 80 seconds plus startup time. These requests
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
shared Rust/Swift forwarding and early-disconnect corpora. The job raises its
file-descriptor limit for the 256-stream workloads. Release builds depend on
the reusable CI workflow, including this job.

The hosted runner label is documented in [GitHub's announcement](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/).
`.github/actionlint.yaml` adds that exact label because actionlint 1.7.12 predates
it. Opt-in RSS, live provider TLS/credentials, VM integration and observation
requirements remain separate gates; this CI job does not replace them.

### Historical AsyncHTTPClient TLS cancellation audit

The pinned AsyncHTTPClient 1.36.2 leaves connection establishment running when
its queued request is cancelled. Reproduce with a local TCP fixture that receives
the TLS ClientHello but never answers it:

```bash
COOP_PROXY_HANDSHAKE_AUDIT=1 swift test --package-path macos/coop-proxy --filter auditCancellationDuringTLSHandshake
```

This opt-in dependency audit fails the two-second upstream socket closure
assertion. Request cancellation returns immediately, while client shutdown waits
for the thirty-second establishment deadline. It uses the pinned client's TLS
configuration, a local synthetic destination, and no credentials. Forwarding now
uses direct SwiftNIO/NIOSSL with owned sockets; this audit preserves the reason
for that replacement and is not the acceptance test for the new bridge.
Run `swift test --package-path macos/coop-proxy --filter bridgeCancellationClosesStalledTLSHandshake`
for guest-disconnect coverage through the new bridge, for both provider identities.

### Cancellable Swift TLS connection component

Run `swift test --package-path macos/coop-proxy --filter ownedTLS` for the direct
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
swift test --package-path macos/coop-proxy --filter 'tlsProbeCancellation|productionClientSharesSocketBudget'
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
swift test --package-path macos/coop-proxy --filter 'cancelledDNS|dnsCancellation|dnsFailurePreserves|guestCancellationCannot|productionClientSharesSocketBudget|cancelledSocketKeepsAdmission'
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
Rust/Swift matrix. Each implementation runs 16 exchanges: both providers, closure
before headers or during the response body, abrupt TCP closure or clean TLS
shutdown, and two rounds. Raw observations and comparison results are saved in
the printed temporary directory. The runner checks the exact matrix and compares
status, partial provider body, guest EOF, and one-slot capacity recovery. Local
502 bodies are checked separately: Rust emits `upstream request failed`, while
Swift emits an empty body. No live credentials or provider network are used.

For the Swift matrix and complete-response regression alone, run:

```bash
swift test --package-path macos/coop-proxy --filter 'upstreamDisconnectClosesGuestAndRestoresPermits|completedResponseDrainsAfterUpstreamClosesDuringGuestWrite'
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
closure; Rust additionally checks permit recovery. The runner validates and
compares six complete records, retaining logs and raw observations in a printed
temporary directory. Test-only `COOP_BODY_LIMIT_OBSERVATIONS` captures counts
and digest. Individual gates are `cargo test -p coop-proxy real_tls_declared_body_limit`
and `swift test --package-path macos/coop-proxy --filter realTLSDeclaredBodyLimit`.
A chunked request with
`Expect: 100-continue` must receive 411 as its first response, with zero upstream
connections, requests, body bytes, or injected credentials. The shared runner
compares six provider/framing cases across both implementations.

Run `python3 scripts/test-proxy-body-idle.py` on macOS for the compared body-idle
gate. Both provider cases run concurrently within each implementation through
verified TLS. Each advertises three body bytes, sends one, waits 15 seconds,
and sends a second. Both bytes must reach the fixture before request completion,
then the guest must receive local 408 and EOF 44–51 seconds after its initial
write. The upload must remain incomplete and the upstream socket must close;
Rust additionally checks recovery of all permits. The runner validates and
compares both providers' status, partial body and closure observations, retaining
raw elapsed times while excluding scheduler timing from equality comparison.
Logs, raw observations and comparison evidence are retained in a printed
temporary directory. `COOP_IDLE_OBSERVATIONS` is consumed only by test code.
Individual gates are `cargo test -p coop-proxy real_tls_upload_idle_deadline`
and `swift test --package-path macos/coop-proxy --filter realTLSUploadIdleDeadline`.

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
cargo test -p coop-proxy real_tls_streams_hold_256_slots
swift test --package-path macos/coop-proxy --filter realTLSStreamsHold256Slots
```

For each provider they hold 256 responses after their first SSE chunk and
require closure of a 257th authenticated request. Three rounds exercise
disconnect, normal completion, then disconnect again. Refilling the complete
allowance proves capacity recovery after both paths, and each round requires
all upstream sockets to close. Rust additionally inspects its live permit
counts; Swift's separate embedded tests check request-lease lifetime because
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
same `tests/fixtures/credential-proxy/forwarding.json` cases through Rust and
Swift loopback TLS fixtures. It retains per-language logs, raw observations,
normalized comparison, command outcomes and the corpus SHA-256 in a printed
temporary directory, and rejects an empty test selection. Python 3 and OpenSSL
are required in addition to Rust and Swift.

Both tests generate disposable short-lived certificates with the shared
`generate-forwarding-certificates.py` fixture generator. Rust uses an explicit
test root; Swift keeps system trust evaluation with a per-evaluation extra
root. Neither test disables hostname/chain verification or changes host trust.
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
are implementation-specific and are not compared. Both implementations assert
that local diagnostics contain neither synthetic secret. The runner validates
the exact observation schema for each case type. Shared streaming/resource and
connect-timeout cases remain separate work before migration
cutover. The admitted fixtures leave the guest write side open and require one
complete response followed by peer EOF within five seconds. Rust uses a raw TCP
read through EOF; Swift observes channel inactivity without closing on the
response header/end. Removing Swift's successful-response close or enabling
Rust keep-alive in isolated source copies fails this deadline, confirming the
probes detect it.

The corpus also contains two stalled TLS-handshake cases, one per provider.
They use the real 30-second establishment deadline and require local 502,
zero HTTP requests and upstream socket release. Raw elapsed milliseconds are
retained and checked against the corpus's 29–35 second bounds; scheduler timing
need not be identical across implementations. Two additional cases route the
fixed provider endpoint to the reserved name `coop-proxy-test.invalid` in test
code only. They require a DNS failure, local 502, zero upstream HTTP requests
and physical guest closure. Swift checks the typed A/AAAA resolver errors and
the absence of TCP connection attempts; Rust first verifies that its resolver
rejects the fixture name, then exercises the normal forwarding failure path.
The complete 18-case run takes about two minutes plus build time. An unanswered
TCP connect remains a separate case.

### Swift proxy policy mutation sweep

`macos/coop-proxy/muter.conf.yml` scopes the four policy files required by the
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
finds panics/hangs/OOM, not correctness (there's no oracle), so a standing
harness only earns its keep where input crosses a trust boundary. A manual
check, not a CI gate. We use [`cargo-fuzz`](https://github.com/rust-fuzz/cargo-fuzz)
(libFuzzer), which needs a nightly toolchain.

Targets live in `fuzz/fuzz_targets/`. `coop` exposes a library target, so a
target depends on the crate directly and imports the parser under test with
`use coop::…` — no `#[path]` includes. `fuzz/Cargo.toml` is its own workspace,
so the main `cargo build`/`test`/`fmt`/`clippy`/`deny` never touch it.

**Install once** (or `./scripts/install-dev-tools.sh --all`): `cargo install
cargo-fuzz --locked`

```bash
cargo +nightly fuzz build                                       # compile all targets
cargo +nightly fuzz run parse_repo_slug                         # fuzz until a crash
cargo +nightly fuzz run parse_repo_slug -- -max_total_time=60   # bounded run
```

A crash is written to `fuzz/artifacts/<target>/`; reproduce with `cargo +nightly
fuzz run <target> <artifact-path>`.

**Current targets:**

- `parse_repo_slug` — `coop::github_repo::parse_repo_slug_from_url`, fed `git
  remote get-url` output and `--git-repo` CLI args. Property: never panics.
- `jsonc_to_json` — `coop::jsonc::jsonc_to_json`, fed hand-authored
  `devcontainer.json` text. Property: never panics.
- `config_load` — `toml::from_str` into `coop::config::CoopConfig` then
  `validate`, fed `config.toml` text. Exercises the custom `Deserialize`/
  `visit_map` impls (`SubnetMask`, `HostInterface`, `PortForward`). Property:
  never panics, only returns `Err`.

## Formal verification (kani)

[Kani](https://model-checking.github.io/kani/) is a bounded model checker that
proves the *absence* of a property (here: arithmetic overflow / panics) over all
inputs in a range, rather than sampling like proptest. It is a **narrow fit** —
the type system already makes most illegal states unrepresentable, so kani earns
its keep only on bounded integer/float arithmetic. A manual check, not a CI gate;
it needs its own toolchain.

Proofs live in a `#[cfg(kani)]` module so the normal build never compiles them.
They run as one module in `src/config.rs`.

**Install once** (or `./scripts/install-dev-tools.sh --all`): `cargo install
--locked kani-verifier && cargo kani setup`

```bash
cargo kani                                            # run every proof harness (~5s)
cargo kani --harness disk_relative_add_never_wraps    # one harness
```

**Current proofs (`src/config.rs`, `mod proofs`):**

- `disk_relative_add_never_wraps` — the arithmetic kernel of `DiskSize::resolve`'s
  relative branch (`current.checked_add(delta)`): for any two non-zero `u32`
  sizes it yields `Some(current + delta)` exactly when the sum fits, and `None`
  otherwise — never wraps, never panics.
- `mib_as_gib_f64_is_finite_and_positive` — `MiB::as_gib_f64` is finite and
  strictly positive across the whole non-zero range.
- `instance_index_octet_stays_in_range` — the guest IP/MAC last octet
  (`index + 2`) stays in `2..=254` for every valid `InstanceIndex` (`0..=252`).

A note on the disk proof: the harness verifies the `checked_add` kernel directly
rather than calling `DiskSize::resolve`, because `resolve` wraps the overflow
case with `anyhow`'s heap-allocating error construction, which CBMC cannot model
tractably. `resolve` adds only that infallible `.context()` on top of the
kernel; its end-to-end behavior is pinned by the deterministic unit tests
`disk_size_resolve_relative` / `disk_size_resolve_relative_overflows`. This is
the general rule for kani here: prove the arithmetic kernel, not code paths that
route through `anyhow`/allocation. The `InstanceIndex` range is also pinned the
cheaper way by the exhaustive `0..=252` unit test
`instance_network_derivations_over_full_range`, which the kani harness
demonstrates rather than replaces.
