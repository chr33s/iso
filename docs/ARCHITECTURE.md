# Architecture

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported; Linux hosts are outside this fork's scope.

`iso` is a Swift CLI that orchestrates isolated VM environments for running AI
coding agents (Claude Code, Codex). It manages the full VM lifecycle — setup,
up/start, shell, stop, destroy, status, logs — on one backend: `iso-sandbox`
VMs on `apple/containerization` ([`iso-sandbox`](../iso-sandbox)). See
[`backends.md`](backends.md).

This document maps the modules, the backend, the data flow from host to guest,
and the architectural invariants. For the security view of the same system, see
[`trust-model.md`](trust-model.md); for Swift conventions, see
[`code-style.md`](code-style.md). The port from the former Rust host is
specified in [`design/swift-host-spec.md`](design/swift-host-spec.md).

## Executables and packages

A distribution holds four executables, each its own process:

| Executable | Package | Responsibility |
|---|---|---|
| `iso` | root [`Package.swift`](../Package.swift) | CLI, configuration, host state, workspace and agent orchestration |
| `iso-sandbox` | [`iso-sandbox/`](../iso-sandbox) | Apple Containerization VM ownership and runtime operations |
| `iso-proxy` | [`iso-proxy/`](../iso-proxy) | Confined, credential-bearing provider transport |
| `iso-inference` | [`iso-proxy/`](../iso-proxy) (`IsoInferenceCore`, `IsoInferenceGateway`) | Confined per-user gateway that exposes host-side local models to VMs through per-session capabilities ([design](design/secure-local-inference-spec.md)) |

The host drives the runtime over its JSON CLI, starts the proxy through its
startup protocol and talks to the gateway over its owner-only control socket;
it never links those packages. `iso` resolves `iso-sandbox`, `iso-proxy` and
`iso-inference` beside its own executable.

## Layout

```
iso/
├── Package.swift            # host package: IsoCore, IsoConfiguration, IsoSecrets, IsoHost, IsoCLI
├── Sources/
│   ├── IsoCore/            # validated values, AtomicFile/FileLock; no subprocess or network side effects
│   ├── IsoConfiguration/   # JSONC scanning, preflight, decoding, config edits
│   ├── IsoSecrets/         # Secure Enclave-bound local secret store
│   ├── IsoHost/            # filesystem, locks, subprocesses, SSH, lifecycle, agents, updater
│   └── IsoCLI/             # Argument Parser commands (executable `iso`)
├── tests/swift/             # Swift test targets (one per module + fuzz corpus replay)
├── tests/                   # integration, parity and migration scripts; baselines
├── fuzz/                    # libFuzzer harnesses (Targets/, Entrypoints/), corpus, vendored libFuzzer
├── iso-sandbox/            # Swift Apple Containerization VM runtime
├── iso-proxy/              # Swift credential proxy and the iso-inference gateway (shared transport)
├── scripts/guest/           # guest-image provisioning scripts (embedded at build)
└── docs/                    # this tree
```

Target dependencies: `IsoConfiguration`, `IsoSecrets` and `IsoHost` depend
on `IsoCore`; `IsoSecrets` also uses swift-crypto's `CryptoExtras`;
`IsoHost` also depends on `IsoConfiguration`; `IsoCLI` assembles them with
Swift Argument Parser. Both external dependencies are pinned in
`Package.resolved`.

### `IsoCore`

Smart-constructor value types shared by configuration, state and commands:
`Names.swift` (instance, image, profile, host and environment-variable names;
the safe-name character class), `RuntimeNames.swift` (runtime object names and
identifiers persisted in host state), `Units.swift` (memory/disk quantities,
vCPU counts, the bootable RAM floor), `GitRepoURL.swift` (clone URL plus its
`owner/repo` slug), `RemoteCommand.swift` (injection-safe guest shell commands
and `GuestPath`), `OutputJSON*.swift` (`--json` output with the baseline's
exact member order and number formatting), and the state-write primitives
`AtomicFile.swift` and `FileLock.swift` (with `HostError`), shared with
modules that must not depend on `IsoHost`.

### `IsoConfiguration`

The JSONC pipeline (spec section 3): `JSONCScanner` (the one comment scanner,
shared with devcontainer input under explicit policies) → `JSONPreflight`
(UTF-8, duplicate keys by decoded name, trailing commas, resource limits,
fraction/exponent literals) → Foundation `JSONDecoder` into `JSONValue` →
`ConfigDecoding` (explicit absent/null/wrong-type handling, per-section
unknown-key policy, retired-field rejection; `InferenceDecoding` for the
closed `inference` section and the `local_model` endpoint/service union) → the
immutable `IsoConfig`.
`ConfigLoader` selects the file (`--config`, default `~/.iso/config.jsonc`,
legacy-TOML refusal); `ConfigValidation` checks environmental facts at
lifecycle boundaries; `ConfigEditor` and `GitHubConfigEdits` make structural
edits that keep unmodeled keys; `ConfigTemplate` is the template written by
`setup --config-only` (kept equal to [`config.example.jsonc`](../config.example.jsonc)
by a test).

### `IsoSecrets`

The local secret store ([design](design/embedded-secrets-spec.md)), with no
dependency on `IsoHost` (its `SecretName` identifier type lives in `IsoCore`): `KDF` (bounded scrypt parameters via
swift-crypto's `CryptoExtras`, HKDF store key), `DeviceFactor` (the Secure
Enclave key, the digest-checked `device.sekey` file, the sealed device unlock
key), `StoreFormat` (the AES-GCM envelope and its bounds) and `EnclaveStore`
(init/set/rm/list/resolve, one unlock per call, owner-only files under a
`FileLock`).

### `IsoHost`

| Area | Files |
|---|---|
| Backend and runtime | `AppleBackend` (probes, liveness proofs, SSH target), `AppleLifecycle` (create/boot/stop/destroy/resize/commit/restore with journals), `AppleSetup` + `ImageBuild` + `ImageRecords` (image preparation and records), `SandboxRuntime` (the narrow runtime-client seam), `RuntimeOperations` (mutating runtime calls, deadlines, cancellability), `RuntimeProtocol` (typed parsers for untrusted runtime output) |
| Processes and signals | `ProcessRunner` (the one subprocess launcher: argv, environment, bounded capture, deadlines, process groups), `ChildGroups` (forward termination signals to child groups), `Shutdown` (sticky SIGINT/SIGTERM flag for interruptible operations) |
| SSH and workspace | `SSH` (pinned-host-key connections), `GuestSession` (`SendEnv` forwarding, minimal guest-bound environment), `SSHConfig` (managed `~/.ssh/config` aliases), `Workspace` (copy/clone/sync, push/pull), `WorkspaceStage` / `WorkspaceStageApply` / `WorkspaceStageReview` (staged pulls), `PortForwards` (`ssh -L` session per VM) |
| Guest bootstrap and state | `Bootstrap`, `BootstrapClaude`, `BootstrapCodex`, `BootstrapStaging`, `CodexTOML`, `AgentUpdate`, `ProxyLifecycle` (proxy processes and reverse tunnels), `InferenceLifecycle` + `BootstrapInference` (the `iso-inference` gateway controller: start, register, forward, activate, revoke; guest agent configuration under `inference.mode = "required"`), `ManagedBackend` + `InferenceBackendChecks` (the root provisioning step for a managed mlx-lm LaunchDaemon, and the `run_as`, authentication and confinement checks), `EmbeddedManagedBackend` (generated from `inference-launcher.py` and `seatbelt-inference-backend.sb`), `ProxyState`, `ModelState`, `GuestEnvState`, `Profiles`, `SeatbeltProfile`, `EmbeddedResources` (generated from `scripts/guest/`) |
| GitHub and secrets | `GitHubAPI`, `GitHubPAT`, `GitHubTokens`, `SecretStore` (Keychain provisioning only), `CredentialResolver` (just-in-time `cmd:` and `vault:` resolution) |
| Devcontainer | `Devcontainer`, `DevcontainerJSON`, `DevcontainerModel`, `DevcontainerResolve`, `DevcontainerReport`, `DevcontainerState`, `DevcontainerGitRepo`, `DevcontainerOCI` (digest-verified Features) |
| Update and uninstall | `Update`, `UpdateRelease`, `UpdateVersion`, `UpdateCheck`, `BuildRevision`, `Uninstall` |
| Boundary audit | `BoundaryAudit` (`<instance>/audit.jsonl`: host-recorded boot policy, raw provider forwards, stops, workspace returns; `iso audit`) |
| Persistent state | `StateStore` (versioned records under `<data_dir>/backends/apple-container-v1`; writes through `IsoCore`'s `AtomicFile` and `FileLock`), `ConfigStore` (locked config edits), `DataRoot` (upstream-state guard) |
| Isolation | `IsolationGate` (effective VM configuration checked before a guest is handed out), `HostKeys` (ed25519 pins read over the runtime channel) |
| Support | `Diagnostics` (stderr), `Prompt`, `OrderedJSON`, `ParserStack` (8 MiB stack for recursive untrusted-input parsers) |

### `IsoCLI`

One file per command domain: `IsoCommand.swift` (root command, global
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
can script `iso-sandbox` responses. Disk and resource mutations follow the
invariants in [`design/apple-sandbox-transactions.md`](design/apple-sandbox-transactions.md):
each takes the per-instance lock, journals runtime calls whose interruption
could leave runtime and host records disagreeing, and verifies the runtime's
report instead of trusting an exit status.

### Liveness proofs

`AppleBackend.Running` and `AppleBackend.Stopped` carry the instance, its owned
sidecar and (for `Running`) the isolation-gate result and SSH target. Their
initializers are internal to `IsoHost`; commands obtain them only through
`asRunning` / `resolveRunning` / `asStopped`. Operations that need a live or
stopped VM take the proof, so the precondition is checked once and then
witnessed by the type.

## Command dispatch

`IsoCommand.main()` installs `ChildGroups` termination handlers, parses the
command line (usage errors exit 2, as before), and runs the subcommand.
Commands that must work without a loaded configuration — `completions`,
`setup --config-only`/`init`, `update`, `uninstall`, `devcontainer check` —
handle that themselves. Others build a `CommandContext` (S-02): the data-root
guard, one validated `IsoConfig` snapshot with explicit CLI overrides applied,
`Diagnostics`, the background update notice, the `AppleBackend`, and the SSH
client. Handlers receive immutable values; credentials are resolved separately
and only when an operation needs them. `IsoCLI.run` maps failures to a
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
   and Codex configuration injection; provider proxies and local-model tunnels,
   or, under `inference.mode = "required"`, a verified `iso-inference` session
   (register, sole-listener check, pinned `ssh -R` forward, nonce check,
   activation bound to the forward process) instead of both;
   `postStartCommand`.
6. **Workspace** — `--workspace` copies via a tar pipe; `--git-repo` clones in
   the guest; mounts are a one-time sync (use `iso push` / `iso pull`).

A failed first boot tears down forwards, proxies, the sandbox and the SSH alias.
Config, secrets, and workspace all cross the host→guest boundary here; the
security-relevant details of each crossing are in [`trust-model.md`](trust-model.md).

### Configuration and state

Configuration is JSONC at `~/.iso/config.jsonc`, or strict JSON through an
explicit `--config *.json`; a `.toml` path or a lone legacy `config.toml`
stops with instructions for [`scripts/migrate-config-to-jsonc.py`](../scripts/migrate-config-to-jsonc.py).
See [`configuration.md`](configuration.md). Value bounds live in `IsoCore`
constructors, so validation only checks environmental facts. Proxy credentials
are `cmd:` references resolved just in time; `proxy setup` provisions them in
the macOS Keychain.

Host-owned state lives under `<data_dir>/backends/apple-container-v1`
(`data_dir` defaults to `~/.iso`) as versioned JSON records written through
`StateStore`/`AtomicFile`: owner and machine records, journals, per-instance
records (`instance.json`, `workspace.json`, `forwards.json`, `guest_env.json`,
`model.json`, `proxy.json`, devcontainer state), host-key pins and image
records. Instance directories are `0700` and records owner-only. The pinned
`HostKeyAlias` is `<machine>.iso`.

## `iso update`

`Update.swift` installs only from the pinned `chr33s/iso` release channel:
fetch release metadata, download the platform archive, `SHA256SUMS` and
`SHA256SUMS.sig`, verify the maintainer signature against the compiled-in
`ReleaseSigners` (mandatory), the checksum (mandatory) and the Sigstore
attestation, extract into a private
temporary directory with path validation, then replace `iso-sandbox`,
`iso-proxy`, `iso-inference` and finally `iso`. Any failure before a replacement leaves every
installed binary untouched; each replacement is atomic but the set is not a
single transaction. Only release builds (`-D ISO_RELEASE_BUILD`, set by
`scripts/build-release.py --release`) update themselves. A background notifier
checks for new versions on a 24-hour interval (disabled in dev/CI/non-TTY). The
full verification chain is in [`trust-model.md`](trust-model.md#iso-update-trust-chain).

## Guest image

`iso setup` builds a golden image in a disposable sandbox from the embedded
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
4. **Value invariants live in constructors.** Parse into a `IsoCore` type at
   the boundary; don't re-validate primitives downstream.
5. **Secrets never touch argv or logs.** Environment/`SendEnv`/stdin only;
   diagnostics never print a resolved secret.
6. **No shell interpolation.** Host processes start only through
   `ProcessRunner` with an explicit argv; guest commands are built with
   `RemoteCommand.arg` (untrusted values) and `.literal` (iso-authored
   fragments only).
7. **State is transparent JSON** written through `StateStore`/`AtomicFile`
   under the resource's `FileLock`, without widening permissions.
