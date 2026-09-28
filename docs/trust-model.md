<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Trust model

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported. Source references below are to the Swift host
> (`Sources/`), the runtime (`coop-sandbox/`) and the proxy (`coop-proxy/`).

This is the engineering-facing trust model for `coop` — the authoritative list
of trust boundaries, taint sources, and the invariants that hold the isolation
together. The shared [`review`](../.agents/skills/review/SKILL.md) workflow
reads this file, and the root [`AGENTS.md`](../AGENTS.md) "Trust model" section
points here. Apply these checks whenever you build or review a change.

This complements — it does not replace — [`SECURITY.md`](../SECURITY.md), which
is the vulnerability-disclosure policy. `SECURITY.md` tells outsiders how to
report a problem; this document tells contributors where the boundaries are so
they don't introduce one.

## The core boundary: the VM

**coop's isolation boundary is the Linux guest VM itself** — an Apple
Containerization VM on a macOS 27+ Apple Silicon host. The point of the
tool is to run AI coding agents (Claude Code, Codex) with broad autonomy
*inside* that boundary, so the guest is deliberately permissive:

- The guest user has passwordless `sudo` (`NOPASSWD:ALL`).
- Claude runs with a managed `~/.claude/settings.json` carrying
  `defaultMode: bypassPermissions`; the `codex`/`claude` launchers pass
  `--dangerously-bypass-approvals-and-sandbox` / `--dangerously-skip-permissions`
  unless the user passes `--ask`.

This is intentional and correct: there is **no privilege boundary inside the
guest to protect** — the whole VM is the blast radius. The security model is
"anything the agent does stays in the VM." Every rule below exists to keep that
true: to stop guest-authored (therefore untrusted) data from escalating across
the VM boundary into host code execution, host filesystem escape, or credential
exposure.

Treat the guest as **untrusted** from the host's point of view, even though the
user launched it.

## Trust zones

| Zone | Trust | Notes |
|------|-------|-------|
| Host user + `config.jsonc` | Trusted | `cmd:` values run arbitrary `/bin/sh -c` on the host (`CredentialResolver` in `Sources/CoopHost/CredentialResolver.swift`), only when an operation needs the value — never merely by loading the configuration. The config file is a host code-execution surface; only the owner should write it. |
| coop process (host) | Trusted | Holds/relays secrets, constructs guest commands, drives `coop-sandbox`, `container build`, `ssh`, and `coop-proxy`. Every subprocess goes through `ProcessRunner` with an argv, never a shell string. |
| The guest VM | **Untrusted** | Agent-controlled. Anything it emits — file contents, paths, archive members, command output — is a taint source once it crosses back to the host. |
| GitHub API / model endpoints / DNS | External | `api.github.com` (PAT probe, release metadata), the model endpoint, `8.8.8.8`. Reached over the network; authenticated where applicable. |

## Taint sources (treat as untrusted)

- **Guest filesystem content pulled to the host.** `Workspace.pull`
  (`Sources/CoopHost/Workspace.swift`) brings guest-authored file contents,
  filenames, and symlinks onto the host filesystem. This is the **widest guest→host
  channel** and the primary place a path-traversal or symlink escape could land.
  A staged pull (`WorkspaceStage*.swift`) lands it in `<instance>/stage/`,
  walks it without following links, rejects special files, hard links,
  escaping symlinks and control-character names, enforces budgets, and applies
  descriptor-relative with a destination-drift and content-hash check.
- **Committed disks.** `coop commit` turns a guest-mutated disk into an image,
  so the guest authors every file on it. Host-key and machine-id removal runs
  in a maintenance VM, never on the host (see
  [Apple sandbox backend](#apple-sandbox-backend)).
- **Guest command output read by the host.** e.g. the workspace dirty check in
  `Workspace.swift` reads `git status --porcelain` from the guest. Today this only gates control flow /
  is printed to the user — it is never fed into `sh -c` on the host. Keep it
  that way.
- **A fetched `devcontainer.json`.** `DevcontainerGitRepo.swift` /
  `DevcontainerJSON.swift` / `DevcontainerModel.swift` parse devcontainer JSON
  that may originate from a remote repo. Its values configure the guest; they
  must never reach a host `cmd:` evaluation or host shell. Recursive parsers of
  untrusted input (devcontainer JSON, guest JSON, Codex TOML) run on a fixed
  8 MiB stack (`withParserStack`) below their depth caps.
- **Downloaded update artifacts.** `Update.swift` tarball + `SHA256SUMS` from the
  release host — gated by checksum and (best-effort) Sigstore attestation.
- **OCI feature blobs.** `DevcontainerOCI.swift` pulls devcontainer *Features*
  from GHCR; the install snippet runs **in the guest**, not the host. coop
  verifies the manifest against its own bytes (and any `@sha256:` pin and
  registry-claimed digest) and each layer against its descriptor digest, and
  reads `install.sh` only as a bounded regular file (never through a symlink).

## Secrets and how they cross into the guest

coop relays several secrets from the host into the guest: `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GITHUB_TOKEN`/PAT, `CLAUDE_CODE_OAUTH_TOKEN`, arbitrary
user `env_forward` entries, and the VM SSH key. The invariants:

- **Never on argv.** Secrets ride SSH `SendEnv` (env channel) or process env
  (`EnvForward` in `GuestSession.swift`), or are piped via **stdin**
  (`ProcessRunner` stdin, the git-clone credential helper, `curl -H @-` in
  `GitHubAPI.swift` / `Update.swift` / `DevcontainerGitRepo.swift`). Never
  build a command line with the secret as an argument — it is visible in
  `ps`/`/proc`. The one known exception is the macOS Keychain store step
  (`security add-generic-password -w`, `SecretStore.swift`), whose CLI offers
  no stdin path; it is documented at the call site and never appears in coop's
  messages. MCP server definitions (with resolved header secrets) reach
  `claude mcp add-json` on stdin, not the ssh command line.
- **Nothing else rides the SSH environment.** Guest-bound `ssh`/`scp`/`rsync`
  inherit only `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SHELL`, `TERM`,
  `LANG` and `LC_*` from the host, plus the variables coop forwards on purpose.
  A user's own `SendEnv` (the guest accepts any) therefore cannot carry a raw
  provider key into the guest in proxy mode. `guest_env.json` (start-time
  `--env` values) is owner-only, in an owner-only instance directory.
- **Proxy processes are identified, not assumed.** A proxy starts only on a
  free port and must be the sole listener afterwards (`lsof`), or startup fails
  closed before the credential is sent; a recorded proxy or tunnel PID is
  signalled only while it still names `coop-proxy` / `ssh`.
- **`GITHUB_TOKEN` defaults to Off.** A saved VM PAT assignment is also explicit
  opt-in; it stores only a validated existing entry key. Invocation-level
  `--no-github` suppresses the assignment before loading it. Active assignments
  reject both managed `GITHUB_TOKEN` and `GH_TOKEN` overrides and fail closed
  on missing references or failed retrieval. It is only forwarded with an explicit
  `github` `auto|env|pat` opt-in (`GitHubTokens.guestToken`). When
  forwarded, agent bootstrap runs `gh auth setup-git`, which makes the token
  **persistent guest state** (a git credential helper any guest process can
  read). A change that forwards it by default, or makes it persistent where it
  wasn't, is a finding. `up --no-github` / `start --no-github` override the
  strategy to Off and disable the PAT wizard for that invocation. This does
  not scrub existing guest credentials or block explicit environment entries
  or one-shot clone authentication; see [GitHub auth](configuration.md#github-auth).
- **Secret files stay `0600`, dirs `0700`.** coop stores secrets only in the
  macOS Keychain; there is no plaintext-file or other fallback store. All
  managed writes go through `AtomicFile` / `StateStore`, which never relax
  permissions.
- **Secrets stay out of logs.** `Secret<T>` (`Sources/CoopCore/Units.swift`)
  and `EnvForward` render as `<redacted>` in descriptions, debug output, and
  reflection; subprocess descriptions redact secret arguments. Configuration
  and decoding errors name field paths, never values. Do not log a resolved
  secret.
- **The stored token is indirected, never inlined.** The configuration holds a
  `cmd:...` retrieval command (`KeychainReference` in `SecretStore.swift` for
  coop-created items) or a `vault:NAME` reference to the local secret store,
  not the plaintext token; coop resolves it when it needs the value. Provider
  proxy credentials must be `cmd:` or `vault:` references; literal values are
  rejected.
- **The local secret store.** Its passphrase is read from `/dev/tty` or from
  the descriptor named by `COOP_SECRETS_PASSPHRASE_FD` (once per process),
  never argv or a plaintext variable, and `coop secrets set` takes values from
  a prompt or stdin. A `{vault:}` guest-environment reference is persisted in
  `guest_env.json` as a reference only; its value is resolved per session and
  is guest-visible by design, like any `--env` value. A reference on a
  provider credential variable is persisted as a `provider_secret`, resolved
  only into that VM's `coop-proxy` startup document, and never set in the
  guest environment; under `proxy.mode = "off"` it is an error. A generic
  reference may not name a secret a proxy credential also reads. `vault:` is
  refused for values placed in the guest (`claude.api_key`, `codex.api_key`,
  MCP headers).
- **Proxy mode keeps the model API keys out of the guest entirely** (issue #411,
  opt-in `proxy`). When enabled in remote model mode, `ANTHROPIC_API_KEY`
  (Claude) and/or `OPENAI_API_KEY` (Codex) are **not** forwarded
  (`suppressAnthropicKey` / `suppressOpenAIKey` in `Bootstrap.swift`, one per
  provider); the host-side `coop-proxy` holds the real credential and the
  guest gets only a per-instance capability token (Claude via `settings.json`,
  Codex via the `coop_local` provider's bearer `env_key`). In proxy mode Codex's
  `~/.codex/auth.json` is also **not** staged onto the guest disk (it holds a
  refreshable subscription token). Each credential is resolved on the host and
  handed to `coop-proxy` over **stdin**, never argv or disk; a resolution failure
  fails the boot closed. A per-VM override
  (`ProxyState.swift`, `<inst.dir>/proxy.json`) selects a different host-side
  credential for one VM — resolution is override → default → off — without
  changing the proxy binary or the capability token. See
  [`credential-proxy.md`](credential-proxy.md).
- **Codex ChatGPT account auth is persistent guest state.** With
  `codex.auth` `"chatgpt"`, coop suppresses `OPENAI_API_KEY` across config,
  process env, `env_forward`, and persisted `--env` overlays, writes
  `cli_auth_credentials_store = "keyring"` to guest `~/.codex/config.toml`, and
  excludes host `auth.json` from the guest copy. Codex stores its cached account
  credentials in the guest Linux Secret Service instead. This avoids API-key
  billing and host `auth.json` copying, but it does **not** keep the ChatGPT
  refresh token out of the guest. A compromised guest can use or extract any
  credential its keyring session can unlock. The keyring setting is written
  during agent bootstrap, so `--no-agents` skips it. On a guest where no
  earlier boot wrote it, the wrapper then falls through to plain Codex and
  `codex login` writes a plaintext `~/.codex/auth.json` instead. coop warns in
  exactly that case; the setting lives on the guest disk, so once written it
  survives a later `--no-agents` start. Two guardrails close the gaps that
  leaves: each bootstrap in this mode deletes any guest `~/.codex/auth.json`
  left by an earlier `api_key` boot or `--no-agents` login (dropping the file
  from the staged set only stops coop *copying* one, it removes nothing), and
  `coop codex` refuses to launch when the guest config does not actually
  select the keyring store — otherwise the wrapper would pass through to plain
  Codex and write the token in the clear. The wrapper also fails closed when a
  session-level `CODEX_HOME` is set while coop's managed
  `~/.codex/config.toml` selects keyring mode; coop does not otherwise stage or
  maintain an alternate Codex home.

## SSH boundary

- Every guest SSH connection pins the guest's host key. The options come from
  one place, `SSHTarget` (`Sources/CoopHost/SSH.swift`: `hostKeyOptions` and
  `transportOptions` — the one list `ssh`, `scp`, and rsync's `-e` all derive
  from — and the `~/.ssh/config` block in `SSHConfig.swift`):
  `StrictHostKeyChecking=yes` against a per-instance `known_hosts`,
  `GlobalKnownHostsFile=/dev/null`, `HostKeyAlias=<machine>.coop`,
  `UpdateHostKeys=no`, `ForwardAgent=no`, `IdentityAgent=none`, and
  `IdentitiesOnly=yes`, so coop's guest-facing SSH authenticates with its own
  key file and never consults the host agent. coop's own transports add
  `BatchMode=yes`, so a rejected key fails instead of falling back to a
  password prompt; the block written for the user's own `ssh coop-apple-<name>`
  deliberately does not.
- The Ed25519 host key is read once over the runtime's native control channel
  (`coop-sandbox exec` over vsock to the owned sandbox, never `ssh-keyscan`)
  and written by `HostKeyPin` (`HostKeys.swift`). A missing or changed key is a
  hard error. Pins written by older builds under the `.coop-apple` alias no
  longer match and must be re-enrolled. Flag any path that re-enrolls
  automatically or builds a target without the pinned options.
- The guest SSH key (`<data_dir>/backends/apple-container-v1/vm_key`, ed25519,
  **passphrase-less by design**) is a VM-access credential. Do not "harden" it
  with a passphrase (it must be used non-interactively), but do flag any change
  that exposes it or copies it off the host.

## Network

- **Port-forwards bind to `127.0.0.1` only** (`PortForwards.swift`): both the
  collision probe and the `ssh -L 127.0.0.1:<host>:127.0.0.1:<guest>` spec.
  There are **no `0.0.0.0` binds** anywhere in the tree. A new listener must
  bind loopback explicitly.
- **Guest VMs cannot reach each other by IP.** Each sandbox has its own vmnet
  network; see [Apple sandbox backend](#apple-sandbox-backend) for how that is
  demonstrated. **Accepted by design:** guests *can* reach the host — that path
  carries the local-model tunnels and the credential proxy's `ssh -R` tunnel. A
  change that widens guest egress or adds inbound reachability is a finding.
- A loopback local-model endpoint reaches the guest over a per-instance
  `ssh -R` reverse tunnel onto the guest's own loopback (`LocalEndpoints` in
  `ModelState.swift`); non-loopback URLs pass through unchanged.
- **The credential proxy (issue #411) binds host loopback** (`127.0.0.1`, it
  refuses an unspecified address at bind) and is exposed into the guest with a
  per-instance `ssh -R` reverse tunnel (`ProxyLifecycle.swift`), so — like the
  port-forwards above — it never binds a non-loopback interface and is
  reachable by exactly one guest. It is guarded
  by a per-instance capability token and forwards only its documented
  provider-specific operations to a fixed per-provider upstream
  (`api.anthropic.com` / `api.openai.com`), never a guest-supplied host — one
  proxy process and one tunnel per (VM, provider). Its own TLS-verifying
  outbound HTTPS is the intended egress; a change that lets the guest influence
  the upstream host, widens the operation policy without security review, or
  binds anything wider than loopback, is a finding. The proxy streams allowed
  request bodies opaquely, so this does not isolate provider objects referenced
  by ID within an allowed request.

- **The credential proxy is jailed.** The macOS 27+ Swift executable holds the
  real credential and accepts untrusted guest HTTP. The host wraps it in
  `sandbox-exec -p` with the Seatbelt profile embedded in
  `Sources/CoopHost/SeatbeltProfile.swift`.
  File writes and program execution are denied; outbound connections are
  restricted to ports 443 and 53. Startup probes the denials before binding.
  If confinement or HTTP readiness fails, VM startup aborts. The guest cannot
  select another implementation or supply a binary path.

  **Accepted limitations:**
  - Egress is port-scoped, not host-scoped. A compromised proxy could connect
    elsewhere on port 443. Application policy pins the provider hostname and
    verifies its identity through macOS system trust, including host-admin/MDM
    roots; the guest cannot alter either setting.
  - File reads remain available for runtime and resolver requirements. Existing
    stderr descriptors remain writable; no request/credential content is logged.
  - `sandbox-exec` is deprecated but remains the confinement primitive.

## Apple sandbox backend

The same VM boundary applies. The backend drives coop-sandbox
(`coop-sandbox`), a runtime coop builds on `apple/containerization`. The
isolation contract lives in two layers: the runtime cannot express host
exposure, and coop verifies the effective configuration anyway
(`AppleBackend`, `SandboxRuntime`, `IsolationGate` in `Sources/CoopHost/`).

- **Runtime shape.** Each instance is its own VM on its own vmnet network
  (`10.231.N.0/24`). The runtime's `SandboxRecord` has no field for a host
  mount, socket relay, published port, or agent forwarding, and its VM
  configuration is built in one function (`Owner.machineConfiguration`) with
  kernel pseudo-filesystems only. Its one network field, `network`, can only
  narrow reach: absent means vmnet shared (NAT) mode, `host_only` (from
  `egress: "none"`) means vmnet host mode with NAT44/NAT66, the DNS proxy,
  router advertisements and DHCP disabled. The gate checks the record against
  the configured `egress` and the interface label (`vmnet-shared:` /
  `vmnet-host:`) against the record. Adding any other such field, a widening
  network mode (bridged, shared-network, a published port), or a `create` flag
  for one is a finding.
- **Session TTL.** `limits.session_ttl` is enforced outside the guest: the
  runtime records the deadline (`record.expiresAt`, host wall clock) at
  `start`, the owner halts the VM when it passes and exits cleanly (so launchd
  does not restart it), a relaunched owner refuses to boot past it, and the
  isolation gate refuses to hand out an expired sandbox. Nothing the guest
  controls, including its clock, moves the deadline. Every halt (the TTL, a
  stop request or a signal) reaches the guest through guest-agent calls a root
  guest can wedge, so if the guest is still running ten seconds after the
  forced kill the owner exits, which ends the in-process VM.
- **Runtime qualification.** `SandboxRuntime` qualification accepts only `coop-sandbox`
  with protocol 4 and `containerization` 0.45.0. The runtime itself accepts
  only a kernel whose sha256 is in `KernelPin.allowed`. On first `coop setup`,
  `coop-sandbox init` pulls `ghcr.io/apple/containerization/vminit:0.45.0`
  (the runtime's only outbound fetch) and refuses it unless it resolves to the
  pinned digest. No config key or flag relaxes these checks; adding one is a
  finding.
- **Isolation gate.** Before first boot, on every restart, and before every SSH
  target is handed out, `IsolationGate.verifyEffective` checks the configuration
  the running VM's owner reports. The effective config is parsed with
  unknown-field rejection, so a new host-facing knob fails closed. It requires:
  - `/sbin/init`, without nested virtualization;
  - a root disk at exactly `<runtime root>/sandboxes/<id>/rootfs.ext4`;
  - only the seven kernel pseudo-filesystem mounts, each from its fixed source
    and destination;
  - zero socket relays and published ports, and no agent forwarding;
  - exactly one interface on a per-sandbox vmnet subnet, carrying the reported
    address;
  - CPUs, memory, owner, and image digest matching the record.

  The address must lie inside the reported subnet. The published-port count,
  agent-forwarding flag, and network mode are constants of the owner's code
  rather than values read back from the VM. Checking them catches a runtime
  that changes them, not a VM that differs from its configuration. The mount,
  root-disk, relay, and interface checks read the configuration the VM was
  created from. The proof (`IsolationGate.Ready`) is process-local and never persisted. The runtime
  root is canonicalized (realpath) on both sides, so the path comparison is
  exact.
- **Separate networks are not proof of isolation.** Guest-to-guest
  unreachability has to be demonstrated on real hardware for each qualified
  runtime. `tests/integration-apple-sandbox.sh` (`docs/testing.md`) does so
  for TCP, UDP, and ICMP over IPv4 and IPv6, plus
  forged routes, static neighbours, spoofed sources, and broadcast/multicast,
  from both sides and after restarts, with the host as the positive control.
  Guest firewall rules do not count, because the guest has root. Rerun it before
  changing the `containerization` pin or the VM configuration.
- **Guests can reach host services.** As noted under [Network](#network), a
  guest reaches the host through its NAT gateway and
  the host's LAN address. On a Mac that includes anything listening on all
  interfaces, such as sshd when Remote Login is on, AirPlay Receiver, and
  rapportd. **Accepted by design**: those services authenticate their clients, and coop's own host listeners bind
  loopback and reach a guest only through its SSH tunnel. vmnet has no
  per-network filter, so closing this would need a root-owned `pf` anchor on
  every Mac. The Apple default network (other workloads' containers) and host
  vsock are not reachable from a sandbox. A change that exposes a host
  *credential* service to guests is a finding.
- **Native control channel.** Host keys are read, and image checks run, through
  `coop-sandbox exec`: an argv delivered over vsock to the guest agent, never a
  shell string. Only fixed commands and coop-chosen paths go through it;
  guest-controlled text never does. The owner's control socket is `0600` in a
  `0700` per-user directory and checks the peer UID.
- **Host-key pinning and re-enrollment.** A changed key fails with
  `APPLE_HOST_KEY_CHANGED`. The only path that replaces a pin is a start after
  `coop restore`: coop replaced the disk itself, and the restore removed the
  host keys. That path is journaled with an operation id. After a crash, the
  runtime's record must show both a higher disk generation and that
  operation as its last committed one before the flag is set. Flag any other
  path that re-enrolls.
- **Runtime subprocesses** get a cleared environment. Only `HOME`, `USER`,
  `LOGNAME`, `TMPDIR`, locale, and a fixed `PATH` are passed
  (`SandboxRuntime.swift`), so
  `SSH_AUTH_SOCK`, provider and GitHub tokens, `DYLD_*`, and `CONTAINER_*`
  never reach the runtime or the builder. The launchd job that runs each owner
  gets a fixed `PATH`/`HOME` of its own. `EnvForward` is for SSH sessions only.
  Output is size-bounded and deadline-bound. A timeout means the outcome is
  uncertain, not that the operation failed. Only builds, creates, and boots
  honour Ctrl-C; stop/delete/cleanup never do.
- **Runtime binaries** are resolved only from the user's config or fixed
  install paths, never from `PATH` or project files. After symlinks are
  resolved, the binary must be a regular executable file owned by the user or
  root and not group- or world-writable. Every ancestor directory must also be
  owned by the user or root, and must not be world-writable unless it is
  sticky, nor group-writable unless it is sticky or its group is `wheel` or
  `admin` (whose members can already use sudo; Homebrew's prefix is
  `admin`-writable). The check reads mode bits only; an ACL that grants
  others write access is not detected. `scripts/build-coop-sandbox.sh` signs the runtime with the
  hardened runtime and refuses an install `bin/` that is owned by neither
  you nor root, world-writable, or group-writable by a group other than
  `wheel` or `admin`. The runtime runs with umask `077`
  and keeps its state directories `0700` and disk files `0600`.
- **Guest-controlled text** that coop displays (host-key comments,
  runtime/guest error text, console-log excerpts, and `coop logs` in both
  snapshot and `--follow` mode) has its control characters replaced first.
- **Local-model tunnels** (`ProxyLifecycle.swift`) are reconciled on
  every bootstrap, and every boot first closes those recorded for the
  previous boot. A tunnel the current model config no longer needs is
  closed, so switching local mode off really removes the guest's path to the
  host server. Tunnel PIDs are only trusted or signalled while `ps` still
  reports them as an `ssh` process.
- **Ownership.** Sandboxes and committed disks are named
  `coop-<owner8>-<random16>`. Nothing is deleted unless the local owner record
  and the instance record both match, and the runtime refuses to delete a
  sandbox recorded for another owner tag. The `coop-` prefix alone is never
  enough.
- **Image build context** is a private temporary directory holding rendered
  files and the VM-access **public** key only. There are no build args or
  secrets. The OCI build runs in stock `container`'s builder. The result is
  imported into the runtime's private store as an OCI archive, and the
  builder's copy is deleted.
- **Committed disks** (`coop commit`) have their SSH host keys and machine-id
  removed before they are saved, so instances created from them normally
  generate their own identity. This is not a uniqueness guarantee: the disk
  still boots guest-authored code, which can restore an identity it stashed.
  Pinning does not depend on it, since each instance's key is read from that
  sandbox over its own control channel. The removal runs in a maintenance VM
  booted from a disposable clone of the maintenance image (never the guest's
  own disk), with the committed disk mounted `nosuid,nodev,noexec` as data. It
  refuses a symlinked `/etc` or `/etc/ssh`, and removes a symlinked key or
  machine-id rather than following it. Disk growth runs the same way.
  Maintenance VMs have no network, and whatever they run stays inside that VM.
- **The maintenance image** is built by `coop setup` like the instance image
  (stock builder, the same digest-pinned Ubuntu base and apt, so no new
  outbound URL), from a fixed recipe with no build context beyond its
  Dockerfile: Ubuntu plus e2fsprogs. The runtime unpacks it into its own
  `maintenance/` directory, records its version and digest, checks that it
  holds the programs the maintenance scripts run, and keeps it apart from the
  image store; the store copy is deleted. No application image is ever used
  for maintenance.
- **Mutation integrity.** Disk and resource changes follow the invariants in
  [`design/apple-sandbox-transactions.md`](design/apple-sandbox-transactions.md)
  (INV-01…INV-10). The security-relevant ones:
  - no disk is replaced under a VM that can use it (the runtime's per-sandbox
    guard covers owner startup, including launchd respawns);
  - a rollback never overwrites a newer change;
  - a host key is re-pinned only after a restore correlated with coop's own
    operation id. The only exception is the pre-operation-id journal fallback
    described under host-key pinning above.

  Weakening any of these (skipping the guard, re-pinning on generation alone
  outside that fallback, or guessing at unreadable staged state) is a
  finding.

## `coop update` trust chain

Self-update (`Update.swift`, `UpdateRelease.swift`) must preserve, in order:

1. Metadata from the pinned `chr33s/coop` GitHub repo (compile-time const).
2. `normalizeTag` — the version tag is validated as semver **before** it enters
   the API URL path (path-traversal guard).
3. **Mandatory checksum.** The `SHA256SUMS` asset must be present (install is
   refused otherwise) and every downloaded tarball is verified against it
   (`verifySHA256`, fixed-size digest compare).
4. **Best-effort attestation.** `gh attestation verify --repo chr33s/coop
   --bundle attestations.jsonl` (Sigstore provenance), against the bundle asset
   downloaded from the same release.

   `--bundle` means **no attestations-API call and no credential** — `gh` marks
   the flag `DisableAuthCheckFlag`, so no token or `gh auth login` is needed.
   The bundle asset is fetched with a deliberately unauthenticated request
   (a bare `curl` in `Update.swift`, `download_bundle` in
   `install.sh`) rather than through `download_asset` / `gh release download`,
   which would re-attach the very credential this transport exists to avoid — a
   SAML-restricted token would then 403 on the fetch and drop the chain back to
   the API path. Keep both fetches credential-free. It is *not* offline:
   without `--custom-trusted-root`, `gh` still reaches `tuf-repo.github.com`
   and the Sigstore public-good CDN for the trust root (one-day cache) and
   fails if neither is reachable.

   It does *not* weaken the check materially, but the two transports are not
   interchangeable, and the differences are worth stating rather than arguing
   away:

   - **The bundle path accepts a superset.** The API path only returns
     attestations registered in the repo's attestation store, so minting one
     requires `attestations: write`. The `--bundle` path accepts any
     correctly-signed bundle sitting in a release, which requires only
     `contents: write`.
   - **The bundle path is unrevocable.** `DELETE
     /orgs/{org}/attestations/digest/{digest}` exists, Fulcio certificates
     carry no CRL or OCSP, and nothing in `gh`'s verification path consults a
     revocation source — so a bundle already saved by a client keeps verifying
     indefinitely after the attestation is deleted.

   What still defeats a substituted bundle is the **subject-digest binding** —
   `gh` digests the artifact and requires a matching subject. `--repo
   chr33s/coop` pins the source repository and constrains the signer SAN
   to that repo, but not to a specific workflow file or ref: any workflow on
   any ref in `chr33s/coop` holding `id-token: write` +
   `attestations: write` mints a bundle that satisfies it. `--signer-workflow`
   / `--cert-identity` are the tighter pin and neither client passes one — the
   API path is keyed by digest against the same repo-scoped store and is
   equally unpinned there.

   A release that publishes no bundle asset — or one whose download fails, or
   whose bundle is empty — falls back to the API path, where `gh` requires a
   credential authorized for the org even though the store itself is
   anonymously readable. `Update.swift` and `install.sh` treat all three
   identically, because for a client they are one situation: no bundle to read.
   An empty bundle is
   rejected rather than passed through because `gh` before 2.56.0
   (cli/cli#9541) reports success on one, having verified nothing;
   `release.yml` also fails the release rather than publish one. A bundle that
   downloads and fails to *verify* is refused outright, not retried through the
   API — that is no stricter on integrity, but a digest mismatch, a corrupt
   download and an unusable `gh` all surface here, and switching transports
   would mask them. Skipped with a logged note if `gh` is absent, and skipped
   entirely when `COOP_UPDATE_API_BASE_URL` is overridden (test mode). So
   provenance is *not* guaranteed on hosts without `gh` — checksum is the
   floor.
5. Extraction with `tar -xzf --no-same-owner --no-same-permissions` (path-escape
   safe), then an atomic `rename`-over-self.

`COOP_UPDATE_API_BASE_URL` redirects the update origin **and** disables
attestation; the checksum then only proves integrity against *that* server's own
`SHA256SUMS`, giving no provenance. Only the pinned `github.com` default +
attestation provide provenance. Flag any change that widens where that override
is honored, or that softens any step above.

## Documented, accepted trade-offs

These are deliberate and documented in [`AGENTS.md`](../AGENTS.md) /
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md). Don't "fix" them without
understanding the rationale; do flag a change that *widens* them:

- **Native agent installers are trusted build inputs.** Provisioning fetches
  Claude's installer from `claude.ai` and Codex's from
  `https://chatgpt.com/codex/install.sh` over HTTPS, then runs them as the
  configured guest user. Provisioning runs inside the `container build`
  builder VM, and live agent updates inside the instance VM. This build-time trust is distinct from the
  untrusted guest boundary described above.

## Stop-and-confirm checklist

Stop and get explicit human confirmation before merging a change that:

- adds an outbound URL, a network listener, or an egress/`FORWARD`/NAT rule —
  name the boundary it crosses and what authenticates it;
- forwards a new secret into the guest, or makes an existing one persistent
  inside the guest;
- runs a host subprocess on tainted (guest- or fetch-derived) bytes — no shell
  strings; use a `ProcessRunner` argv / `RemoteCommand.arg`;
- writes a **host** filesystem path derived from tainted data — validate against
  traversal first;
- logs or traces tainted or secret content — that channel becomes an
  exfiltration path;
- softens any step of the `coop update` verification chain.
