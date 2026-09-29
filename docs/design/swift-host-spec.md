# Specification: Swift host CLI and build toolchain

**Status:** Implementation in progress (phase 1 and the phase 2 foundation);
see the [acceptance ledger](swift-host-acceptance.md). Every gate remains open.  
**Requested:** 2026-09-27.  
**Repository baseline:** `143fddaf23df43a15de5bf81320f6fbb97b23c1b`.  
**Scope:** `chr33s/iso`, macOS 27+ on Apple Silicon; Linux guests.  
**Configuration decision:** JSONC, decoded with Foundation `JSONDecoder` after
comment scanning. This supersedes the earlier TOML dependency selection.

MUST and MUST NOT are acceptance requirements. SHOULD permits a documented,
reviewed exception. This document authorizes no publication, merge, live API
spending, or access to ambient credentials. Creating this specification is
separate from implementing it.

## 1. Objective and boundary

Replace the Rust `iso` host CLI with Swift while preserving the supported
Apple backend's behavior, persistent state, security boundaries, and release
verification. The final supported build MUST require Swift/Xcode and no Rust,
Cargo, rustup, or Rust compiler invoked through another build tool.

The final distribution MUST retain three executables:

| Executable | Responsibility |
|---|---|
| `iso` | User interface, configuration, state, workspace and agent orchestration |
| `iso-sandbox` | Apple Containerization VM ownership and runtime operations |
| `iso-proxy` | Confined credential-bearing provider transport |

The host MUST continue using the runtime JSON CLI and proxy startup protocol.
It MUST NOT link the runtime or credential proxy into the host process as a
shortcut. Shared language does not remove a process or isolation boundary.

Lima and Firecracker host implementations are not porting targets. Guest Linux
support, guest scripts, Docker, and optional guest Rust development profiles
remain in scope where currently supported. Existing unsupported configuration
fields MUST follow the compatibility policy in section 4 rather than silently
acquiring new meaning.

Expected benefits are one host implementation language, common development
tools, fewer platform-specific host branches, and no additional TOML parser
dependency. Smaller binaries, faster builds, lower memory use, and fewer
vulnerabilities MUST be measured or left unclaimed. Foundation and other
dependencies remain part of the runtime and security inventory.

## 2. Build and package architecture

Add a root `Package.swift` for the host executable. Retain the independent
`iso-proxy/` and `iso-sandbox/` packages and their lockfiles.

Proposed target boundaries:

| Target | Owns | Constraints |
|---|---|---|
| `IsoCLI` | Argument parsing, command dispatch, human/JSON presentation | Thin executable; logs on stderr |
| `IsoCore` | Validated names, units, config models, plans, state schemas | No subprocess or network side effects |
| `IsoConfiguration` | JSONC scanning, Foundation decoding, schema checks, config edits | No TOML or configuration-provider dependency |
| `IsoHost` | Filesystem, locks, subprocesses, SSH, lifecycle, agents, updater | Explicit ownership and cancellation |
| Test targets | Contract fixtures, unit and host integration tests | Synthetic credentials; isolated state |

`IsoConfiguration` and `IsoHost` depend on `IsoCore`; `IsoCLI` assembles
these components. Do not introduce a new generic cross-platform backend
framework. Split further only when a concrete ownership boundary warrants it.

Requirements:

- Use Swift 6 language mode, a pinned Xcode 27 toolchain, and macOS 27 deployment
  targets. Reconcile existing companion manifest targets at cutover.
- Use Swift Argument Parser for the command surface; preserve
  the retained static completion contract in C-02, including tested script output.
- Commit all `Package.resolved` files. CI MUST build from recorded resolutions
  and fail unexpected lockfile changes.
- Provide one documented release build entrypoint that builds the three packages,
  signs their executables, assembles the archive, and produces `BUILD.json`.
- Keep build, signing, entitlements, notarization, and runtime execution distinct.
  A successful `swift build` alone is not a distributable release.
- Rust may remain as an explicitly selected development reference during the
  port. Production MUST NOT fall back to Rust when the Swift host fails.

### 2.1 Required simplifications

These are implementation requirements for the port. They consolidate ownership
while applying only the user-facing cuts enumerated in section 4.1. Each MUST have evidence under
H-12 in addition to the behavior/security gates that apply.

| ID | Requirement | Boundary and verification |
|---|---|---|
| S-01 | One concrete Apple backend | Remove backend selection, platform capability matrices, and unsupported host branches. Keep a narrow runtime-client interface for controlled tests; verify that supported commands use the Apple runtime and unsupported operations fail explicitly. |
| S-02 | One validated config snapshot per command | Centralize load, defaults, validation, and explicit overrides. Hand immutable values to handlers; resolve credentials separately and only when needed. Test consistent values across a command and absence of credential execution during loading. |
| S-03 | One subprocess runner | Centralize argv construction, environment filtering, output bounds, deadlines, cancellation, process-group ownership and cleanup. Keep explicit interactive/TTY and captured-output modes. Test each mode and failure path without duplicating independent launch implementations. |
| S-04 | One persistent-state layer | Centralize ownership checks, versioned decoding, compatible locks, atomic writes and journal access. Keep resource-specific transactions explicit. Test partial failure, recovery, contention and foreign-state refusal. |
| S-05 | One release build entrypoint | Coordinate building and testing all three packages and assembling a same-revision archive. Keep signing, notarization, attestation and publication explicit stages; ordinary builds must not publish or require signing secrets. Verify both unsigned development and signed candidate paths. |
| S-06 | One JSONC scanner | Share one tested scanner for host configuration and devcontainer input, with explicit syntax policies if their contracts differ. Test shared string/comment handling and policy differences; do not maintain copied scanners. |

S-02 does not cache persistent state indefinitely or freeze credential results
across commands. A config-editing command MUST reread its source under the writer
lock to preserve concurrent changes; that structural edit transaction is distinct
from its immutable execution configuration. Changes take effect on a later command
unless a command explicitly validates and uses its own newly written result.

S-03 does not force interactive SSH through buffered output capture. Different
I/O modes share process ownership machinery, while preserving TTY, signal and
exit-code behavior. Never close an asynchronous process's resources merely
because its launching function returned.

S-04 does not mean one global lock, a new database, or a generic object store.
Preserve per-resource concurrency and existing cross-language lock semantics.
The layer belongs inside the host package and MUST NOT merge runtime-owned
storage with host-owned storage.

Avoid introducing a plugin system, service locator, general dependency-injection
framework, or cross-platform abstraction to implement these requirements. Use
small concrete components and narrow test interfaces where needed. Preserve the
three executables, runtime JSON protocol, ownership journals, pinned SSH keys,
migration safeguards and update verification.

## 3. JSONC configuration contract

### 3.1 Format and dependencies

The default configuration file becomes **`~/.iso/config.jsonc`**. The Swift
host MUST use a tested comment scanner followed by Foundation `JSONDecoder`.
It MUST NOT depend on `swift-configuration-toml`, `swift-toml`, toml++, or
`swift-configuration` for host configuration. This replaces the previous TOML
selection; it is an intentional file-format change, not a claim of byte-level
compatibility with existing TOML files.

Define JSONC narrowly as RFC 8259 JSON plus `//` line comments and `/* ... */`
block comments outside strings. Block comments do not nest. Trailing commas,
single-quoted strings, unquoted keys, non-finite numeric literals, and other
JSON5 extensions MUST be rejected. `.json` files remain supported as strict
JSON, selected through `--config`; `.jsonc` files enable the comment scanner.
Other extensions MUST produce a format diagnostic rather than content sniffing.
This extension policy is an intentional change from the baseline TOML fallback.

Keys retain their existing snake_case spelling. TOML sections become nested
JSON objects; arrays of tables become arrays of objects. Dynamic names remain
literal object keys: `"a.b"` MUST remain distinct from `{ "a": { "b": ... } }`.
TOML date literals are not part of the new format; any supported domain date
field must have an explicitly defined string representation.

### 3.2 Scanner and loading pipeline

`IsoConfiguration` MUST implement this ordered pipeline:

1. Resolve `--config`, default-path selection, directory migration, and
   command-specific missing-file behavior under section 3.4.
2. Read a bounded immutable byte snapshot and require valid UTF-8. A malformed,
   unreadable, or wrong-type value MUST NOT become a default value.
3. For JSONC, scan bytes with explicit normal/string/escape/line-comment/
   block-comment states. Replace comment bytes with whitespace, preserving
   line breaks and token separation. Reject unterminated block comments.
   Never use regex replacement or remove comment-like text inside strings.
4. Preflight JSON structure for duplicate object keys and configured resource
   limits. Duplicate detection must compare decoded key names, so `"a"` and
   `"\u0061"` cannot evade it. Do not rely on Foundation's winner for duplicates.
   Leave full JSON syntax and value decoding to Foundation; this check must
   not become a separately implemented permissive JSON parser.
5. Decode the clean bytes with `JSONDecoder` into explicit configuration models
   and a lossless structural representation where dynamic fields or editing
   require one. Preserve numeric distinctions and exact supported integer
   values; do not route every number through `Double` or untyped `NSNumber`.
6. Validate section-specific unknown-key policies and field types, apply
   defaults and explicit CLI overrides, then construct immutable domain values.
   Do not introduce environment providers, file watching, or new search paths.
7. Resolve credential commands only when the selected operation needs them.
   Loading, inspecting, or validating configuration MUST NOT accidentally
   execute a command or print a resolved secret.

The existing JSONC scanner used for devcontainer input is the starting
behavioral reference, not assumed proof of configuration compatibility. Share
its Swift scanner implementation where semantics match. If devcontainer
compatibility requires different syntax, expose explicit policies and test both;
do not silently broaden host configuration syntax.

Required scanner cases include URLs containing `//`, literal `/*` inside a
string, escaped quotes, runs of backslashes, Unicode, comments at EOF, adjacent
tokens separated by comments, CRLF/LF, and invalid UTF-8. Preserving newlines
allows useful diagnostics, but Foundation errors MUST still be sanitized.

### 3.3 Defaults, diagnostics, and config writing

- Missing, empty, explicit `false`, zero, `null`, and invalid values MUST remain
  distinct. Preserve each field's accepted absence/null behavior from the
  baseline or record an intentional change. No permissive `try?` plus default.
- Preserve unknown-key policy per section. `[apple_container]` in the baseline
  becomes the `apple_container` object and continues to reject unknown keys.
  Default `JSONDecoder` behavior does not enforce this: implement explicit
  key checks in strict sections. Do not reject arbitrary user-defined map keys.
- Use explicit coding keys; no blanket snake-case conversion across dynamic
  maps, environment variables, provider names, or paths.
- Never log the source document, decoded config, secret-bearing values, or raw
  decoding errors. Emit sanitized field paths/error categories, with safe
  locations where available. JSON itself provides no secret classification.
- Input size, nesting depth, key count, array length, and numeric bounds MUST
  be explicit, enforced before unsafe resource growth, and tested. Phase 1
  records numeric limits and their compatibility impact. A post-decode depth
  check alone does not protect the decoder from excessive nesting.
- `init` MUST create a documented JSONC template. `proxy setup` MUST edit the
  selected JSON/JSONC file using a structural representation and `JSONEncoder`,
  preserving unrelated keys, including unmodeled values. It MUST NOT write a
  fixed config struct back over fields the struct did not decode.
- Comments and formatting may be lost during edits; this is documented behavior,
  consistent with the old TOML writer. The resulting strict JSON is valid JSONC.
  Comment-preserving editing is outside this port's required scope.
- Config updates MUST use the compatible writer lock, atomic replacement, and
  existing permission/security policy, with no permission widening. Read-back
  parsing and round-trip fixtures MUST prove semantic retention. Failure leaves
  the prior file intact.

### 3.4 Existing configuration migration and precedence

The final Swift host MUST NOT parse TOML or invoke a converter implicitly.
Provide an explicit, offline migration utility before cutover:

```text
scripts/migrate-config-to-jsonc.py --input PATH --output PATH [--drop-retired-fields]
```

The utility uses Python 3.11+ standard-library `tomllib` and `json`; Python is a
one-time migration prerequisite, not a runtime or release-build prerequisite.
It MUST NOT install packages, execute `cmd:` values, contact providers, or load
ambient credentials. It MUST:

- Preserve nested keys, strings, booleans, arrays, and supported exact integers,
  subject to C-01 retired-field handling and C-04 rejection of literal proxy
  credentials. Preserve credential references as strings without resolving them.
- Reject non-finite numbers, TOML date/time objects without an explicit domain
  mapping, and other values that cannot be converted losslessly. Report safe
  field paths; never silently stringify or drop unsupported values.
- Preserve explicit `data_dir`; other configs retain the current default.
  (User-approved change, 2026-09-28: `~/.coop-apple` support is dropped.)
- Leave the source untouched; refuse any existing destination, including
  symlinks. Publish a complete file with exclusive destination semantics and
  mode `0600`; clean up temporary files on failure. Never dump config to stdout.
- Validate structural round-trip equivalence before publishing. Acceptance
  additionally compares normalized baseline and Swift domain values for every
  supported fixture, accounting explicitly for C-01 removals. Do not carry
  retired fields into the Swift host as inert data.

The converter need not preserve TOML comments. Its output may be formatted
strict JSON with a `.jsonc` extension. Include usage and prerequisite instructions
in the release migration notes and make the utility available with the release.

Selection rules:

| Situation | Required behavior |
|---|---|
| Explicit `.jsonc` path | Load JSONC at that path only |
| Explicit `.json` path | Load strict JSON at that path only |
| Explicit `.toml` path | Stop with a migration instruction; never use defaults or reinterpret it |
| Default `config.jsonc` exists | Load it; any retained `config.toml` is an inactive migration source, never merged |
| No default JSONC, but legacy `config.toml` exists | Stop with migration instructions; do not silently start with default settings |
| Neither default file exists | Preserve command-specific no-config behavior; `init` creates JSONC |
| Selected JSON/JSONC file malformed or unreadable | Report a sanitized error; no alternate-format fallback |

There is no automatic `config.json` search; existing JSON users retain explicit
`--config` selection. Do not implement layered loading across formats.

Legacy TOML must never be silently ignored. There is no directory migration:
`~/.coop-apple` is neither read nor moved (user-approved change, 2026-09-28).

Do not add `.jsonc` support to runtime state records or protocol payloads;
those remain strict JSON with their existing schemas.

## 4. Behavioral compatibility inventory

Before porting command handlers, generate a machine-readable inventory from the
baseline revision. Each item needs a reference fixture, Swift test, and disposition
of preserved, intentionally removed, or intentionally changed. The latter two
require a documented scope decision; missing coverage is not a disposition.

| Surface | Required coverage |
|---|---|
| CLI | Commands, aliases, arguments, defaults, errors, exit codes, help, completions, non-TTY behavior |
| Output | JSON schemas/types/backend token, stdout/stderr separation; wording changes classified |
| Configuration | Every field/default, JSONC and strict JSON, TOML conversion, custom profiles, MCP, auth unions, disabled config paths, environment precedence |
| State | Owner IDs, schema versions, instance/image records, journals, host-key pins, modes, atomicity |
| VM lifecycle | Setup/create/start/stop/destroy/status/logs, resource changes, snapshots/restore, failed operations and recovery |
| Workspace | Guest path validation, copy/sync, exclusions, symlinks, SSH aliases, editor integrations |
| Agents | Bootstrap, credentials/account modes, launch arguments, config forwarding, provider failure behavior |
| Integrations | GitHub/PAT scopes, repository/submodule handling, devcontainer translation, local model routing |
| Administration | Init/validate/quickstart/profiles, proxy setup, update, uninstall and purge |

Port supported host behavior from `src/`, particularly `config.rs`,
`commands/`, `apple_container/`, `workspace.rs`, `ssh.rs`, `proxy*.rs`,
`guest*.rs`, `devcontainer*.rs`, `github*.rs`, `update.rs`, and
`data_migration.rs`. These paths are a starting map, not an exhaustive waiver.

Inherited Linux-only handlers are not ported. The retired configuration fields
below are rejected by the Swift host and removed only through the explicit
conversion policy. They MUST NOT remain accepted as inert compatibility fields.

### 4.1 Approved feature cuts

**Status: approved for the Swift host port by the user's instruction to include
feature cuts.** These decisions replace the earlier optional candidates.
Implementation MUST apply them before porting the retired behavior. Changes to
unlisted features remain outside this approval.

| ID | Required cut | Retained contract | Acceptance evidence |
|---|---|---|---|
| C-01 | Remove inherited Firecracker configuration and host handlers | Apple VM resource settings, runtime kernel selection, SSH and model routing remain | Rejected-field registry, converter fixtures, unchanged supported Apple behavior |
| C-02 | Remove custom dynamic completion and unsupported completion generators | Argument Parser-generated static completions for bash, zsh and fish | Generated-script checks and installation tests for the three retained shells; no runtime instance/image discovery |
| C-03 | Consolidate initial configuration and image preparation under `setup`; remove `quickstart` | `setup --config-only` creates config; `setup` prepares the image; `up` and agent commands remain explicit | Command/flag migration table, non-TTY checks, idempotency and partial-failure tests |
| C-04 | Remove multiple built-in secret-store provisioning adapters and literal proxy credentials | macOS Keychain provisioning plus explicit `cmd:` references for provider proxy credentials | No implicit fallback storage; redaction, resolver failure and existing-reference tests |

#### C-01 — Retired configuration

The initial closed list of retired paths is:

- `firecracker_bin`;
- `vm.kernel_path` and `vm.boot_args`;
- `network.host_ip`, `network.subnet_mask`, and `network.host_iface`, and the
  now-obsolete top-level `network` object.

Keep `vm.vcpu_count`, `vm.mem_size_mib`, `vm.template_size_gib`,
`apple_container.kernel`, `ssh_port`, and local-model endpoint/routing settings.
Do not interpret the removal of Firecracker networking as removal of guest
network isolation or host-to-guest routing controls.

The converter MUST refuse a source containing retired fields by default and
list their paths without values. An explicit `--drop-retired-fields` option
permits removing only the closed list, with a paths-only removal report. An
empty obsolete `network` object may be removed under the same option; unknown
children MUST cause refusal, not broad subtree deletion. Preserve the source.
The host MUST reject these names even where generic unknown keys would otherwise
be ignored. Additional removals require a separately recorded scope decision.

#### C-02 — Static completion only

Retain `iso completions <shell>` for bash, zsh and fish, backed by Argument
Parser-generated scripts. Remove `COMPLETE=<shell>` runtime hooks, filesystem
scans for instance/image names, and custom completion providers. Static candidates
for declared options and enums may remain. Profile/image/instance discovery is
performed through normal commands, not shell completion.

Retire PowerShell and Elvish completion output in this macOS-focused host.
A request for a retired shell MUST return an actionable unsupported-shell error.
Update shell installation docs and remove old completion-hook instructions.
Completion generation MUST not load secrets, migrate state, or invoke the runtime.

#### C-03 — Setup workflow

The new command contract is:

| Old operation | Swift host operation |
|---|---|
| `iso init` | `iso setup --config-only`; retain `init` as a thin compatibility alias with a stderr deprecation hint |
| `iso setup` | `iso setup`, preserving supported image/profile/builder options |
| `iso quickstart` | Removed; diagnostic directs users to `setup`, then `up`, then their chosen `claude` or `codex` command |

`setup --config-only` creates the JSONC template and exits. It MUST NOT install
software, provision credentials, build an image, boot a VM or launch an agent.
An existing config remains untouched unless an explicit documented replacement
operation is selected. `init` MUST dispatch to this same implementation and
must not retain a separate initialization workflow.

Normal `setup` MAY create a missing default template, then performs image
preparation. Existing custom configuration, profile selection, provisioning,
builder deadlines and safe retries MUST retain their supported behavior. Flags
that request image operations MUST be rejected with `--config-only` rather
than ignored. There is no implicit `up` or agent launch at the end of setup.
The command/flag inventory MUST give actionable replacements for retired
`quickstart` options and preserve noninteractive invocation of retained operations.

#### C-04 — Credential provisioning and resolution

For provider proxy credentials, retain one built-in provisioning destination:
**macOS Keychain**. `proxy setup` stores a credential there and writes its `cmd:`
reference, using the existing service/account naming and ownership conventions.
If Keychain storage fails or is unavailable, fail explicitly; do not fall back
to a plaintext file or another secret store.

Keep explicit user-authored `cmd:` references as the single configurable lookup
mechanism. These can call 1Password, Vault, Keychain, or another trusted host
command without isolate implementing a provider-specific provisioning adapter.
Remove built-in 1Password creation/management, plaintext-file storage, and
Linux Secret Service support from the host's secret-store layer, including any
shared setup flows that offered those adapters. Existing references remain
opaque commands; removing an adapter MUST NOT delete external secrets or files.

Reject literal values in `proxy.anthropic.credential`,
`proxy.openai.credential`, and corresponding per-instance credential overrides.
Diagnostics MUST identify the field without printing its contents. Conversion
MUST refuse these literals and explain how to provision Keychain or supply a
`cmd:` reference; it MUST NOT execute lookups or import secrets automatically.
Existing stored literal overrides need the same explicit remediation before use.

Keep `api_key` versus `bearer` injection semantics, provider capability isolation,
and just-in-time resolution. This cut changes acquisition/provisioning, not
provider protocols. GitHub auth modes, repository-scoped PAT behavior, agent
account-login modes, local-model auth, and non-proxy credential forwarding are
not retired by C-04; preserve their existing trust boundaries and validation.
Any retained use of the shared store gets the Keychain/explicit-command model.

#### Cut tracking

For each cut, record affected commands, fields, scripts, tests and docs in the
machine-readable compatibility inventory and H-12 ledger. Include migration
instructions, expected baseline differences, error behavior, and proof that
retired code paths and dependencies are absent. Do not normalize away failures
to make differential tests pass. Add no usage telemetry and do not inspect
credential contents to justify a cut.

The cuts MUST NOT bypass live-provider, isolation, state migration or release
verification gates. Source configuration and external secret stores remain
untouched by removal unless a user explicitly invokes the documented operation.

## 5. Persistent state and migration

The Swift host MUST operate on existing owned Apple state without rebuilding
VMs or changing ownership IDs merely because the host implementation changed.

Preserve:

- `~/.iso/config.jsonc`, legacy format conversion, and explicit
  `--config`/`data_dir` behavior under section 3.4;
- `<data_dir>/backends/apple-container-v1/` and current record versions;
- stopped-VM compatibility and rejection of foreign or unsupported schemas;
- refusal of upstream coop state in the default `~/.iso`;
- SSH config aliases and marker namespaces, pinned host keys, and absolute
  paths. The pin's `HostKeyAlias` is `<machine>.iso`; the former
  `~/.coop-apple` migration, its lock and the `.coop-apple` alias were dropped
  by user-approved change (2026-09-28), so pins written under the old alias
  must be re-enrolled;
- purge limited to owned backend state, preserving config and unrelated files.

Cross-language lock names and flock semantics MUST match during development.
Every filesystem operation that can partially complete needs a tested recovery
path. Do not change the state schema as an incidental porting convenience.

## 6. Security and resource ownership

The [trust model](../trust-model.md), [runtime transactions](apple-sandbox-transactions.md),
and [proxy specification](swift-proxy-spec.md) remain authoritative for their
respective boundaries. This host port extends the earlier proxy port's scope;
it does not retroactively mark that port's acceptance gates complete.

Requirements:

- Guest content MUST remain untrusted when used in paths, archives, commands,
  JSON responses, terminal output, or persistent metadata.
- Build subprocess argv without shell interpolation. Explicit trusted `cmd:`
  configuration retains its existing execution policy; it is not a template
  for executing guest-authored strings.
- Process ownership MUST cover pipes, bounded output capture, deadlines,
  cancellation, signals, process groups, and confirmed cleanup. Draining stdout
  and stderr MUST not deadlock a child.
- Use explicit scoped cleanup and state machines. Do not rely on ARC `deinit`
  alone to stop VMs, terminate subprocesses, release credentials, or roll back
  multi-step operations. Actors do not replace interprocess locks.
- Preserve proxy confinement-before-secret startup, stdin-only secret transfer,
  synthetic guest capability, approved upstream identity, reverse-tunnel
  readiness checks, and fail-closed behavior. No raw provider credential may
  appear in guest files, argv, logs, state records, or diagnostic fixtures.
- Preserve the known-length proxy policy and existing body-boundary acceptance.
  Rewriting the host does not authorize a new transport policy.
- Preserve SSH host-key verification and the runtime isolation gate before
  handing a guest to an agent or user.
- Preserve updater provenance, repository/channel restrictions, archive/path
  validation, checksum verification, companion compatibility, and transactional
  replacement. Errors MUST NOT trigger installation of unverified binaries.
- Any newly required egress, listener, entitlement, or secret route requires its
  own reviewed change; this spec does not preapprove one.

## 7. Validation and acceptance gates

Maintain `docs/design/swift-host-acceptance.md` during implementation. Record
requirement ID, exact tested revision, toolchain/dependency resolutions,
command, result, evidence path, and limits. Every gate below starts **pending**.

| ID | Gate | Required evidence |
|---|---|---|
| H-01 | Configuration parity | Complete field inventory, TOML-to-JSONC migration and baseline/Swift normalized results, malformed and boundary corpus, writer round trips |
| H-02 | CLI parity | Command/flag/output/exit-code matrix, completion and non-TTY checks |
| H-03 | State compatibility | Existing fixtures plus real stopped state reopened by Swift; migration interruption/collision/live-owner cases |
| H-04 | Ownership and security | Failure injection for subprocesses, filesystem escape, stale pins, secret leakage, lock contention, cancellation and cleanup |
| H-05 | Apple runtime integration | Real macOS 27+ Apple Silicon VM lifecycle, workspace/agent setup, resize/restore recovery, teardown |
| H-06 | Proxy integration | Controlled TLS through real guest tunnels for both providers, credential scan, streaming, termination and startup failures |
| H-07 | Live acceptance | Dedicated credential references and approved models; successful provider and agent operations, disconnect/recovery |
| H-08 | Swift build and tests | Formatting, warnings policy, all package tests, parser sanitizers, and mandatory fuzz replacement under section 7.1 |
| H-09 | Distribution | Same-revision hosted candidate, signatures/notarization/attestation, clean-machine install/run/update/uninstall |
| H-10 | Rust removal | Clean release build and CI without Rust/Cargo available; no shipped Rust host or fallback; tool/dependency/document audit |
| H-11 | Final review | Independent correctness/security review of the final revision; every blocking finding resolved |
| H-12 | Simplification and scope | S-01 through S-06 ownership/behavior evidence; C-01 through C-04 implemented cuts, migration tests, matching docs and absence of retired paths |

Configuration fixtures MUST include literal dotted keys versus nested objects,
arrays of objects, nested dynamic maps, heterogeneous/empty arrays, unknown keys,
invalid UTF-8, duplicate/escaped-equivalent keys, integer bounds, null/boolean/path
unions, comment/escape interactions, rejected trailing commas, migration-only
TOML date literals, missing files, format precedence, read failures, secret
redaction, and concurrent edits.

Differential tests MUST use isolated HOME/state and synthetic secrets. Do not
run Rust and Swift mutating the same live installation concurrently. Normalize
only enumerated nondeterministic fields such as timestamps and generated IDs;
never normalize away error categories, security decisions, or secret exposure.

Port relevant Rust unit tests by behavior, not line-for-line translation. Map
existing property, fuzz, mutation, and Kani coverage to replacement evidence.
A smaller test count or lack of a direct Swift tool equivalent is not a waiver.
Use targeted fault injection to show that critical tests fail when their
protected behavior is removed.

Benchmark representative cold/warm CLI invocations and peak memory against the
baseline on the same machine. VM boot and provider latency MUST be reported
separately from host overhead. Performance claims require those measurements.

### 7.1 Replacement for `./fuzz`

Retain `fuzz/` as the home of coverage-guided parser fuzzing. Replace its
`cargo-fuzz` workspace with Swift harnesses using **LLVM libFuzzer**, subject to
qualification below. Removing Cargo MUST NOT remove this coverage. Randomized
unit tests and corpus replay supplement fuzzing; neither alone satisfies this gate.

| Existing target | Required Swift target | Required behavior |
|---|---|---|
| `parse_repo_slug` | `ParseRepoSlug` | Exercise the production repository URL/slug parser on arbitrary input |
| `jsonc_to_json` | `JSONCToJSON` | Exercise the production JSONC scanner and explicit host/devcontainer syntax policies |
| `config_load` | `ConfigLoad` | Exercise JSONC scanning, duplicate/limit checks, Foundation decoding, domain validation and config round trips |

All targets MUST reject invalid input without unexpected traps, aborts, hangs,
or unbounded resource use. Expected parse/validation errors are normal outcomes.
The configuration target MUST also exercise literal dotted keys, escaped duplicate keys, comment/string interactions,
dynamic maps, arrays of objects, wrong types, secret redaction, and structural write/read
round trips. Round-trip properties compare semantic values, not formatting.

Proposed layout:

```text
fuzz/
  Targets/
    ParseRepoSlug.swift
    JSONCToJSON.swift
    ConfigLoad.swift
  corpus/<target>/
  artifacts/<target>/
scripts/
  fuzz.sh
```

The build manifest/location may be adjusted during qualification, but the
three target identities and coverage obligations MUST remain traceable. Reuse
existing corpus inputs and minimized reproducers where present. Add synthetic
seeds for the JSONC configuration pipeline; never collect developer configuration or secrets.
Generated artifacts stay out of version control unless sanitized, minimized,
and deliberately promoted to regression fixtures.

#### Toolchain qualification

A local probe on 2026-09-27 used Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), targeting
`arm64-apple-macosx27.0.0`. Compiling a minimal `LLVMFuzzerTestOneInput` entrypoint
with `swiftc -parse-as-library -sanitize=fuzzer,address` failed with:

```text
error: unsupported option '-sanitize=fuzzer' for target 'arm64-apple-macosx27.0.0'
```

This establishes that the tested Xcode compiler does not provide that invocation;
it does not establish support in another toolchain. Qualify a separately pinned
fuzzing toolchain, potentially a Swift.org distribution, on **macOS 27+ ARM64**.
Do not assume that installing another compiler is sufficient. Record its origin,
version, checksum, SDK, runtime libraries, compiler/linker flags, and dependency
resolutions. Release builds continue to use the pinned Xcode toolchain.

Qualification MUST demonstrate:

1. Each harness links and runs with the libFuzzer entrypoint and no Rust tooling.
2. Coverage instrumentation reaches production Swift scanner, structural checks,
   decoding adapters, validation, and editing code, not just the harness. Verify instrumentation
   and observed coverage changes with known branch-triggering inputs.
3. AddressSanitizer instrumentation is active in the harness and code built
   from source. Record prebuilt Foundation/system components as an instrumentation
   limit; do not claim their internals have compiler coverage or sanitizer checks
   solely because callers do. Foundation decoding must still execute on fuzz
   inputs. A deliberate test-only fault is found and reproducible; it is not
   retained in production sources.
4. The runner saves, replays, and minimizes a deliberate crash, and enforces
   input-size, memory, and per-input time bounds. A deliberate hang verifies
   timeout handling. Record exact limits in the acceptance ledger.
5. Production and fuzz toolchains pass the same deterministic parser corpus,
   so coverage from a different compiler is not treated as release validation
   by itself. Every discovered regression also runs in ordinary Xcode tests.

Swift supports sanitizer builds separately from libFuzzer integration; an ASan
unit-test run MUST NOT be reported as coverage-guided fuzzing.
[Swift sanitizer documentation](https://www.swift.org/documentation/server/guides/llvm-sanitizers.html).

If no suitable toolchain can be qualified, H-08 and deletion of the Rust fuzz
workspace remain blocked. Choosing a different fuzzing engine or reducing the
coverage requires a documented change to this contract.

#### Runner and execution requirements

`scripts/fuzz.sh` MUST expose build, bounded run, artifact replay, corpus merge,
and crash minimization operations without requiring Cargo. It MUST instrument
production code built from the tested revision; copied parser implementations
are not valid fuzz targets.

Targets MUST run against in-memory inputs and pure validation. No fuzz input may
execute a credential command, access ambient secrets, make a network request,
or launch a guest or agent. Any filesystem fixture must be confined to private
temporary state. Expected parser errors MUST be handled narrowly; harnesses
MUST NOT hide assertions, sanitizer failures, or unexpected errors as parse
rejections. Failure artifacts and diagnostics MUST contain synthetic data only.

CI MUST replay the regression corpus and run a bounded fuzz smoke test for all
three targets. Longer campaigns MUST run on a scheduled or manual macOS worker.
Set and record campaign duration, seed, limits, corpus revision, tested commit,
coverage observations, sanitizer failures, and timeout/OOM outcomes. An empty
corpus or a successful build is not evidence of a successful fuzz run.

Before deleting `fuzz/Cargo.toml`, its lockfile, Rust harnesses, and cargo-fuzz
installation hooks, H-08 MUST contain passing qualification, all three Swift
targets, corpus replay, bounded campaign results, and demonstrated crash/hang
sensitivity. Keep the replacement directory, runner, corpus, and regression
fixtures after Rust removal.

## 8. Implementation sequence and exit criteria

1. **Freeze contracts and qualify JSONC and fuzz tooling.** Capture the baseline
   inventory, assign S-01 through S-06 ownership, and record C-01 through C-04
   removal/migration inventories before their affected work begins. Build the scanner/decoder spike
   and offline TOML converter. Prove
   conversion parity, strict typing, duplicate detection, limits, redaction, and
   config writing. Exit: H-01 fixtures exist, the section 7.1 toolchain qualification
   passes, and configuration migration has no unresolved compatibility gaps.
2. **Build the host foundation.** Introduce the root package, typed models,
   config adapter, output contracts, process/lock/filesystem primitives, and
   read-only commands. Implement S-01 through S-04 and S-06 at their owning
   boundaries. Exit: relevant H-01/H-02/H-04 and H-12 coverage passes.
3. **Port persistent state and lifecycle.** Implement the runtime CLI adapter,
   migrations, setup/provisioning, recovery and image operations. Exit: H-03
   and the lifecycle portion of H-05 pass on real hardware.
4. **Port workspace, agents, integrations, and administration.** Complete the
   command inventory, proxy orchestration, updater and uninstall. Exit: H-02,
   H-04, H-05 and H-06 pass; no supported command delegates to Rust.
5. **Validate a Swift candidate.** Implement S-05; run H-07 through H-09, H-11
   and H-12 against the
   candidate revision, including all three Swift fuzz targets and their campaigns.
   Keep the Rust reference available for development until
   parity and review are complete; ship no automatic implementation selector.
6. **Remove Rust and revalidate the final revision.** Delete the Rust host,
   Cargo manifests/lockfile/build script/toolchain pin, Rust-only proof/fuzz
   harnesses only after their replacement gates pass, cargo tooling hooks and
   CI steps. Retain the Swift `fuzz/` replacement defined in section 7.1.
   Update contributor skills and documentation. Run H-10, rebuild the final
   hosted artifact, and rerun affected acceptance/review gates on that revision.

The port is complete only when every gate has passing evidence or an explicit
user-approved change to the acceptance contract. A package scaffold, successful
compile, dependency selection, or deletion of Rust files is not completion.

## 9. Remaining implementation decisions

These do not block reviewing this spec, but MUST be resolved and recorded in
phase 1 or the relevant gate before production cutover:

- Complete C-01 through C-04 field/flag/reference inventories and migration
  fixtures before porting affected surfaces; the cuts themselves are decided.
- Concrete structural JSON editing and duplicate-key preflight design, with
  exact-number preservation and Foundation compatibility evidence.
- Numeric parser/input resource limits and any baseline compatibility impact.
- Concrete process/SSH adapter implementation and its cancellation tests.
- Exact macOS ARM64 libFuzzer-capable Swift toolchain and campaign limits
  (resolved: Xcode 27 `swiftc`/`clang++`, libFuzzer vendored in `fuzz/libfuzzer`),
  qualified under section 7.1.
- Replacement coverage for remaining Rust analysis tools (mutation and Kani).
- Dedicated live-provider credential references/models and hosted signing inputs.

Do not include secret values in the spec, acceptance ledger, or test artifacts.
