# Architecture

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported; Linux hosts are outside this fork's scope.

`coop` is a Swift CLI that orchestrates isolated VM environments for running AI
coding agents (Claude Code, Codex). It manages the full VM lifecycle — setup,
up/start, shell, stop, destroy, status, logs — on one backend: `coop-sandbox`
VMs on `apple/containerization` ([`coop-sandbox`](../coop-sandbox)). See
[`backends.md`](backends.md).

This document maps the modules, the backend, the data flow from host to guest,
and the architectural invariants. For the security view of the same system, see
[`trust-model.md`](trust-model.md); for Swift conventions, see
[`code-style.md`](code-style.md). The port from the former Rust host is
specified in [`design/swift-host-spec.md`](design/swift-host-spec.md).

## Executables and packages

A distribution holds three executables, each its own process:

| Executable | Package | Responsibility |
|---|---|---|
| `coop` | root [`Package.swift`](../Package.swift) | CLI, configuration, host state, workspace and agent orchestration |
| `coop-sandbox` | [`coop-sandbox/`](../coop-sandbox) | Apple Containerization VM ownership and runtime operations |
| `coop-proxy` | [`coop-proxy/`](../coop-proxy) | Confined, credential-bearing provider transport |

The host drives the runtime over its JSON CLI and starts the proxy through its
startup protocol; it never links either package. `coop` resolves
`coop-sandbox` and `coop-proxy` beside its own executable.

## Layout

```
coop/
├── Package.swift            # host package: CoopCore, CoopConfiguration, CoopSecrets, CoopHost, CoopCLI
├── Sources/
│   ├── CoopCore/            # validated values, AtomicFile/FileLock; no subprocess or network side effects
│   ├── CoopConfiguration/   # JSONC scanning, preflight, decoding, config edits
│   ├── CoopSecrets/         # Secure Enclave-bound local secret store
│   ├── CoopHost/            # filesystem, locks, subprocesses, SSH, lifecycle, agents, updater
│   └── CoopCLI/             # Argument Parser commands (executable `coop`)
├── tests/swift/             # Swift test targets (one per module + fuzz corpus replay)
├── tests/                   # integration, parity and migration scripts; baselines
├── fuzz/                    # libFuzzer harnesses (Targets/, Entrypoints/), corpus, vendored libFuzzer
├── coop-sandbox/            # Swift Apple Containerization VM runtime
├── coop-proxy/              # Swift credential proxy: injection, policy, TLS, Seatbelt
├── scripts/guest/           # guest-image provisioning scripts (embedded at build)
└── docs/                    # this tree
```

Target dependencies: `CoopConfiguration`, `CoopSecrets` and `CoopHost` depend
on `CoopCore`; `CoopSecrets` also uses swift-crypto's `CryptoExtras`;
`CoopHost` also depends on `CoopConfiguration`; `CoopCLI` assembles them with
Swift Argument Parser. Both external dependencies are pinned in
`Package.resolved`.

### `CoopCore`

Smart-constructor value types shared by configuration, state and commands:
`Names.swift` (instance, image, profile, host and environment-variable names;
the safe-name character class), `RuntimeNames.swift` (runtime object names and
identifiers persisted in host state), `Units.swift` (memory/disk quantities,
vCPU counts, the bootable RAM floor), `GitRepoURL.swift` (clone URL plus its
`owner/repo` slug), `RemoteCommand.swift` (injection-safe guest shell commands
and `GuestPath`), `OutputJSON*.swift` (`--json` output with the baseline's
exact member order and number formatting), and the state-write primitives
`AtomicFile.swift` and `FileLock.swift` (with `HostError`), shared with
modules that must not depend on `CoopHost`.

### `CoopConfiguration`

The JSONC pipeline (spec section 3): `JSONCScanner` (the one comment scanner,
shared with devcontainer input under explicit policies) → `JSONPreflight`
(UTF-8, duplicate keys by decoded name, trailing commas, resource limits,
fraction/exponent literals) → Foundation `JSONDecoder` into `JSONValue` →
`ConfigDecoding` (explicit absent/null/wrong-type handling, per-section
unknown-key policy, retired-field rejection) → the immutable `CoopConfig`.
`ConfigLoader` selects the file (`--config`, default `~/.coop/config.jsonc`,
legacy-TOML refusal); `ConfigValidation` checks environmental facts at
lifecycle boundaries; `ConfigEditor` and `GitHubConfigEdits` make structural
edits that keep unmodeled keys; `ConfigTemplate` is the template written by
`setup --config-only` (kept equal to [`config.example.jsonc`](../config.example.jsonc)
by a test).

### `CoopSecrets`

The local secret store ([design](design/embedded-secrets-spec.md)), with no
dependency on `CoopHost`: `SecretName`, `KDF` (bounded scrypt parameters via
swift-crypto's `CryptoExtras`, HKDF store key), `DeviceFactor` (the Secure
Enclave key, the digest-checked `device.sekey` file, the sealed device unlock
key), `StoreFormat` (the AES-GCM envelope and its bounds) and `EnclaveStore`
(init/set/rm/list/resolve, one unlock per call, owner-only files under a
`FileLock`).

### `CoopHost`

| Area | Files |
|---|---|
| Backend and runtime | `AppleBackend` (probes, liveness proofs, SSH target), `AppleLifecycle` (create/boot/stop/destroy/resize/commit/restore with journals), `AppleSetup` + `ImageBuild` + `ImageRecords` (image preparation and records), `SandboxRuntime` (the narrow runtime-client seam), `RuntimeOperations` (mutating runtime calls, deadlines, cancellability), `RuntimeProtocol` (typed parsers for untrusted runtime output) |
| Processes and signals | `ProcessRunner` (the one subprocess launcher: argv, environment, bounded capture, deadlines, process groups), `ChildGroups` (forward termination signals to child groups), `Shutdown` (sticky SIGINT/SIGTERM flag for interruptible operations) |
| SSH and workspace | `SSH` (pinned-host-key connections), `GuestSession` (`SendEnv` forwarding, minimal guest-bound environment), `SSHConfig` (managed `~/.ssh/config` aliases), `Workspace` (copy/clone/sync, push/pull), `WorkspaceStage` / `WorkspaceStageApply` / `WorkspaceStageReview` (staged pulls), `PortForwards` (`ssh -L` session per VM) |
| Guest bootstrap and state | `Bootstrap`, `BootstrapClaude`, `BootstrapCodex`, `BootstrapStaging`, `CodexTOML`, `AgentUpdate`, `ProxyLifecycle` (proxy processes and reverse tunnels), `ProxyState`, `ModelState`, `GuestEnvState`, `Profiles`, `SeatbeltProfile`, `EmbeddedResources` (generated from `scripts/guest/`) |
| GitHub and secrets | `GitHubAPI`, `GitHubPAT`, `GitHubTokens`, `SecretStore` (Keychain provisioning only), `CredentialResolver` (just-in-time `cmd:` resolution) |
| Devcontainer | `Devcontainer`, `DevcontainerJSON`, `DevcontainerModel`, `DevcontainerResolve`, `DevcontainerReport`, `DevcontainerState`, `DevcontainerGitRepo`, `DevcontainerOCI` (digest-verified Features) |
| Update and uninstall | `Update`, `UpdateRelease`, `UpdateVersion`, `UpdateCheck`, `BuildRevision`, `Uninstall` |
| Persistent state | `StateStore` (versioned records under `<data_dir>/backends/apple-container-v1`; writes through `CoopCore`'s `AtomicFile` and `FileLock`), `ConfigStore` (locked config edits), `DataRoot` (upstream-state guard) |
| Isolation | `IsolationGate` (effective VM configuration checked before a guest is handed out), `HostKeys` (ed25519 pins read over the runtime channel) |
| Support | `Diagnostics` (stderr), `Prompt`, `OrderedJSON`, `ParserStack` (8 MiB stack for recursive untrusted-input parsers) |

### `CoopCLI`

One file per command domain: `CoopCommand.swift` (root command, global
options, `init` alias, removed `quickstart`, exit-status mapping),
`ReadCommands.swift` (`CommandContext`, list/status/logs and other read-only
commands), `LifecycleCommands.swift` (setup, stop, destroy, resize, commit,
restore), `UpCommands.swift` (up/start/shell/exec and the shared start
machinery), `AgentCommands.swift` (claude/codex/agent/model), `WorkspaceCommands.swift`
(push/pull/editor/ssh-config), `DevcontainerCommands.swift`,
`GitHubCommands.swift`, and `AdminCommands.swift` (update, uninstall).

## The backend

There is one concrete backend, `AppleBackend` (spec S-01). There is no backend
trait, no compile-time or runtime backend selection, and no capability matrix.
`SandboxRuntime` is the only seam: a narrow runtime-client interface so tests
can script `coop-sandbox` responses. Disk and resource mutations follow the
invariants in [`design/apple-sandbox-transactions.md`](design/apple-sandbox-transactions.md):
each takes the per-instance lock, journals runtime calls whose interruption
could leave runtime and host records disagreeing, and verifies the runtime's
report instead of trusting an exit status.

### Liveness proofs

`AppleBackend.Running` and `AppleBackend.Stopped` carry the instance, its owned
sidecar and (for `Running`) the isolation-gate result and SSH target. Their
initializers are internal to `CoopHost`; commands obtain them only through
`asRunning` / `resolveRunning` / `asStopped`. Operations that need a live or
stopped VM take the proof, so the precondition is checked once and then
witnessed by the type.

## Command dispatch

`CoopCommand.main()` installs `ChildGroups` termination handlers, parses the
command line (usage errors exit 2, as before), and runs the subcommand.
Commands that must work without a loaded configuration — `completions`,
`setup --config-only`/`init`, `update`, `uninstall`, `devcontainer check` —
handle that themselves. Others build a `CommandContext` (S-02): the data-root
guard, one validated `CoopConfig` snapshot with explicit CLI overrides applied,
`Diagnostics`, the background update notice, the `AppleBackend`, and the SSH
client. Handlers receive immutable values; credentials are resolved separately
and only when an operation needs them. `CoopCLI.run` maps failures to a
sanitized `Error: …` line on stderr and exit status 1.

## Data flow: host → guest

The lifecycle is **setup → up/start → shell → stop → destroy**. A first boot
(`UpCommands.swift`, `startInstance` / `provisionFirstBoot`) runs roughly:

1. **Resolve** the repository (`--git-repo`, workspace origin, first mount) and
   optionally prompt for a GitHub PAT.
2. **Ports** — merge forward specs and fail on busy host ports before any VM cost.
3. **Boot** — `AppleLifecycle.createAndStart`: create and boot the sandbox,
   read and pin its host key, pass the isolation gate; then wait for SSH.
4. **Forwards and state** — refresh an installed SSH alias, persist and spawn
   port forwards, persist `guest_env.json` and devcontainer state.
5. **Bootstrap** — GitHub credential helper when a token is forwarded; Claude
   and Codex configuration injection; provider proxies and local-model tunnels;
   `postStartCommand`.
6. **Workspace** — `--workspace` copies via a tar pipe; `--git-repo` clones in
   the guest; mounts are a one-time sync (use `coop push` / `coop pull`).

A failed first boot tears down forwards, proxies, the sandbox and the SSH alias.
Config, secrets, and workspace all cross the host→guest boundary here; the
security-relevant details of each crossing are in [`trust-model.md`](trust-model.md).

### Configuration and state

Configuration is JSONC at `~/.coop/config.jsonc`, or strict JSON through an
explicit `--config *.json`; a `.toml` path or a lone legacy `config.toml`
stops with instructions for [`scripts/migrate-config-to-jsonc.py`](../scripts/migrate-config-to-jsonc.py).
See [`configuration.md`](configuration.md). Value bounds live in `CoopCore`
constructors, so validation only checks environmental facts. Proxy credentials
are `cmd:` references resolved just in time; `proxy setup` provisions them in
the macOS Keychain.

Host-owned state lives under `<data_dir>/backends/apple-container-v1`
(`data_dir` defaults to `~/.coop`) as versioned JSON records written through
`StateStore`/`AtomicFile`: owner and machine records, journals, per-instance
records (`instance.json`, `workspace.json`, `forwards.json`, `guest_env.json`,
`model.json`, `proxy.json`, devcontainer state), host-key pins and image
records. Instance directories are `0700` and records owner-only. The pinned
`HostKeyAlias` is `<machine>.coop`.

## `coop update`

`Update.swift` installs only from the pinned `chr33s/coop` release channel:
fetch release metadata, download the platform archive and `SHA256SUMS`, verify
the checksum (mandatory) and the Sigstore attestation, extract into a private
temporary directory with path validation, then replace `coop-sandbox`,
`coop-proxy` and finally `coop`. Any failure before a replacement leaves every
installed binary untouched; each replacement is atomic but the set is not a
single transaction. Only release builds (`-D COOP_RELEASE_BUILD`, set by
`scripts/build-release.py --release`) update themselves. A background notifier
checks for new versions on a 24-hour interval (disabled in dev/CI/non-TTY). The
full verification chain is in [`trust-model.md`](trust-model.md#coop-update-trust-chain).

## Guest image

`coop setup` builds a golden image in a disposable sandbox from the embedded
provisioning scripts in `scripts/guest/` plus the profile/package installers,
optionally with devcontainer Features, and publishes its record only after
verification. Instances boot from that image. See
[`images-and-profiles.md`](images-and-profiles.md).

## Architectural invariants

Hold these when changing the code; the review lenses check for their violation:

1. **The VM is the isolation boundary.** The guest is untrusted from the host's
   view; guest-authored data must not escalate into host code execution or
   filesystem escape. See [`trust-model.md`](trust-model.md).
2. **One concrete backend.** Don't add a backend protocol, selector, or
   cross-platform abstraction; unsupported operations fail explicitly.
3. **Liveness is a type, not a flag.** Route VM operations through
   `Running`/`Stopped` proofs and the isolation gate, not ad-hoc
   `isRunning` checks.
4. **Value invariants live in constructors.** Parse into a `CoopCore` type at
   the boundary; don't re-validate primitives downstream.
5. **Secrets never touch argv or logs.** Environment/`SendEnv`/stdin only;
   diagnostics never print a resolved secret.
6. **No shell interpolation.** Host processes start only through
   `ProcessRunner` with an explicit argv; guest commands are built with
   `RemoteCommand.arg` (untrusted values) and `.literal` (coop-authored
   fragments only).
7. **State is transparent JSON** written through `StateStore`/`AtomicFile`
   under the resource's `FileLock`, without widening permissions.
