<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Trust model

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported. Source references below are to the Swift host
> (`Sources/`), the runtime (`iso-sandbox/`) and the proxy (`iso-proxy/`).

This is the engineering-facing trust model for `iso` — the authoritative list
of trust boundaries, taint sources, and the invariants that hold the isolation
together. The shared [`review`](../.agents/skills/review/SKILL.md) workflow
reads this file, and the root [`AGENTS.md`](../AGENTS.md) "Trust model" section
points here. Apply these checks whenever you build or review a change.

This complements — it does not replace — [`SECURITY.md`](../SECURITY.md), which
is the vulnerability-disclosure policy. `SECURITY.md` tells outsiders how to
report a problem; this document tells contributors where the boundaries are so
they don't introduce one.

## The core boundary: the VM

**isolate's isolation boundary is the Linux guest VM itself** — an Apple
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
| Host user + `config.jsonc` | Trusted | `cmd:` values run arbitrary `/bin/sh -c` on the host (`CredentialResolver` in `Sources/IsoHost/Credentials/CredentialResolver.swift`), only when an operation needs the value — never merely by loading the configuration. The config file is a host code-execution surface; only the owner should write it. |
| isolate process (host) | Trusted | Holds/relays secrets, constructs guest commands, drives `iso-sandbox`, `container build`, `ssh`, and `iso-proxy`. Every subprocess goes through `ProcessRunner` with an argv, never a shell string. |
| The guest VM | **Untrusted** | Agent-controlled. Anything it emits — file contents, paths, archive members, command output — is a taint source once it crosses back to the host. |
| GitHub API / model endpoints / DNS | External | `api.github.com` (PAT probe, release metadata), the model endpoint, `8.8.8.8`. Reached over the network; authenticated where applicable. |

## Taint sources (treat as untrusted)

- **Guest filesystem content pulled to the host.** `Workspace.pull`
  (`Sources/IsoHost/Workspace/Workspace.swift`) brings guest-authored file contents,
  filenames, and symlinks onto the host filesystem. This is the **widest guest→host
  channel** and the primary place a path-traversal or symlink escape could land.
  A staged pull (`WorkspaceStage*.swift`) lands it in `<instance>/stage/`,
  walks it without following links, rejects special files, hard links,
  escaping symlinks and control-character names, enforces budgets, and applies
  descriptor-relative with a destination-drift and content-hash check.
- **Committed disks.** `iso commit` turns a guest-mutated disk into an image,
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
  release host — gated by a maintainer signature over `SHA256SUMS`, the
  checksum and (best-effort) Sigstore attestation.
- **Installed agent definitions.** `iso agent add` copies a reviewed JSON
  document into `<data_dir>/agents/`. The file is untrusted input: it can
  select an existing image or profile and a compiled adapter, and it can
  suggest hostnames, but it cannot grant network destinations, read a host
  secret, mount a host path, or run a host command. `iso run` builds guest
  argv with `RemoteCommand` escaping and does not re-read the file after the
  launch plan is frozen. A disposable instance is marked so `iso up` will not
  adopt it.
- **OCI feature blobs.** `DevcontainerOCI.swift` pulls devcontainer *Features*
  from GHCR; the install snippet runs **in the guest**, not the host. isolate
  verifies the manifest against its own bytes (and any `@sha256:` pin and
  registry-claimed digest) and each layer against its descriptor digest, and
  reads `install.sh` only as a bounded regular file (never through a symlink).

## Secrets and how they cross into the guest

isolate relays several secrets from the host into the guest: `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GITHUB_TOKEN`/PAT, `CLAUDE_CODE_OAUTH_TOKEN`, arbitrary
user `env_forward` entries, and the VM SSH key. The invariants:

- **Never on argv.** Secrets ride SSH `SendEnv` (env channel) or process env
  (`EnvForward` in `GuestSession.swift`), or are piped via **stdin**
  (`ProcessRunner` stdin, the git-clone credential helper, `curl -H @-` in
  `GitHubAPI.swift` / `Update.swift` / `DevcontainerGitRepo.swift`). Never
  build a command line with the secret as an argument — it is visible in
  `ps`/`/proc`. The one known exception is the macOS Keychain store step
  (`security add-generic-password -w`, `SecretStore.swift`), whose CLI offers
  no stdin path; it is documented at the call site and never appears in isolate's
  messages. MCP server definitions (with resolved header secrets) reach
  `claude mcp add-json` on stdin, not the ssh command line.
- **Nothing else rides the SSH environment.** Guest-bound `ssh`/`scp`/`rsync`
  inherit only `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SHELL`, `TERM`,
  `LANG` and `LC_*` from the host, plus the variables isolate forwards on purpose.
  A user's own `SendEnv` (the guest accepts any) therefore cannot carry a raw
  provider key into the guest in proxy mode. `guest_env.json` (start-time
  `--env` values) is owner-only, in an owner-only instance directory.
- **Proxy processes are identified, not assumed.** A proxy starts only on a
  free port and must be the sole listener afterwards (`lsof`), or startup fails
  closed before the credential is sent; a recorded proxy or tunnel PID is
  signalled only while it still names `iso-proxy` / `ssh`.
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
- **Secret files stay `0600`, dirs `0700`.** isolate stores secrets only in the
  macOS Keychain; there is no plaintext-file or other fallback store. All
  managed writes go through `AtomicFile` / `StateStore`, which never relax
  permissions.
- **Secrets stay out of logs.** `Secret<T>` (`Sources/IsoCore/Units.swift`)
  and `EnvForward` render as `<redacted>` in descriptions, debug output, and
  reflection; subprocess descriptions redact secret arguments. Configuration
  and decoding errors name field paths, never values. Do not log a resolved
  secret.
- **The stored token is indirected, never inlined.** The configuration holds a
  `cmd:...` retrieval command (`KeychainReference` in `SecretStore.swift` for
  iso-created items) or a `vault:NAME` reference to the local secret store,
  not the plaintext token; isolate resolves it when it needs the value. Provider
  proxy credentials must be `cmd:` or `vault:` references; literal values are
  rejected.
- **The local secret store.** Its passphrase is read from `/dev/tty` or from
  the descriptor named by `ISO_SECRETS_PASSPHRASE_FD` (once per process),
  never argv or a plaintext variable, and `iso secrets set` takes values from
  a prompt or stdin. A `{vault:}` guest-environment reference is persisted in
  `guest_env.json` as a reference only; its value is resolved per session and
  is guest-visible by design, like any `--env` value. A reference on a
  provider credential variable is persisted as a `provider_secret`, resolved
  only into that VM's `iso-proxy` startup document, and never set in the
  guest environment; under `proxy.mode = "off"` it is an error. A generic
  reference may not name a secret a proxy credential also reads. `vault:` is
  refused for values placed in the guest (`claude.api_key`, `codex.api_key`,
  MCP headers).
- **Proxy mode keeps the model API keys out of the guest entirely** (issue #411,
  opt-in `proxy`). When enabled in remote model mode, `ANTHROPIC_API_KEY`
  (Claude) and/or `OPENAI_API_KEY` (Codex) are **not** forwarded
  (`suppressAnthropicKey` / `suppressOpenAIKey` in `Bootstrap.swift`, one per
  provider); the host-side `iso-proxy` holds the real credential and the
  guest gets only a per-instance capability token (Claude via `settings.json`,
  Codex via the `iso_local` provider's bearer `env_key`). In proxy mode Codex's
  `~/.codex/auth.json` is also **not** staged onto the guest disk (it holds a
  refreshable subscription token). Each credential is resolved on the host and
  handed to `iso-proxy` over **stdin**, never argv or disk; a resolution failure
  fails the boot closed. A per-VM override
  (`ProxyState.swift`, `<inst.dir>/proxy.json`) selects a different host-side
  credential for one VM — resolution is override → default → off — without
  changing the proxy binary or the capability token. See
  [`credential-proxy.md`](credential-proxy.md).
- **Codex ChatGPT account auth is persistent guest state.** With
  `codex.auth` `"chatgpt"`, isolate suppresses `OPENAI_API_KEY` across config,
  process env, `env_forward`, and persisted `--env` overlays, writes
  `cli_auth_credentials_store = "keyring"` to guest `~/.codex/config.toml`, and
  excludes host `auth.json` from the guest copy. Codex stores its cached account
  credentials in the guest Linux Secret Service instead. This avoids API-key
  billing and host `auth.json` copying, but it does **not** keep the ChatGPT
  refresh token out of the guest. A compromised guest can use or extract any
  credential its keyring session can unlock. The keyring setting is written
  during agent bootstrap, so `--no-agents` skips it. On a guest where no
  earlier boot wrote it, the wrapper then falls through to plain Codex and
  `codex login` writes a plaintext `~/.codex/auth.json` instead. isolate warns in
  exactly that case; the setting lives on the guest disk, so once written it
  survives a later `--no-agents` start. Two guardrails close the gaps that
  leaves: each bootstrap in this mode deletes any guest `~/.codex/auth.json`
  left by an earlier `api_key` boot or `--no-agents` login (dropping the file
  from the staged set only stops isolate *copying* one, it removes nothing), and
  `iso codex` refuses to launch when the guest config does not actually
  select the keyring store — otherwise the wrapper would pass through to plain
  Codex and write the token in the clear. The wrapper also fails closed when a
  session-level `CODEX_HOME` is set while isolate's managed
  `~/.codex/config.toml` selects keyring mode; isolate does not otherwise stage or
  maintain an alternate Codex home.

## SSH boundary

- Every guest SSH connection pins the guest's host key. The options come from
  one place, `SSHTarget` (`Sources/IsoHost/Guest/SSH.swift`: `hostKeyOptions` and
  `transportOptions` — the one list `ssh`, `scp`, and rsync's `-e` all derive
  from — and the `~/.ssh/config` block in `SSHConfig.swift`):
  `StrictHostKeyChecking=yes` against a per-instance `known_hosts`,
  `GlobalKnownHostsFile=/dev/null`, `HostKeyAlias=<machine>.iso`,
  `UpdateHostKeys=no`, `ForwardAgent=no`, `IdentityAgent=none`, and
  `IdentitiesOnly=yes`, so isolate's guest-facing SSH authenticates with its own
  key file and never consults the host agent. isolate's own transports add
  `BatchMode=yes`, so a rejected key fails instead of falling back to a
  password prompt; the block written for the user's own `ssh iso-<name>`
  deliberately does not.
- The Ed25519 host key is read once over the runtime's native control channel
  (`iso-sandbox exec` over vsock to the owned sandbox, never `ssh-keyscan`)
  and written by `HostKeyPin` (`HostKeys.swift`). A missing or changed key is a
  hard error. Flag any path that re-enrolls
  automatically or builds a target without the pinned options.
- The guest SSH key (`<data_dir>/backends/apple-container-v1/vm_key`, ed25519,
  **passphrase-less by design**) is a VM-access credential. Do not "harden" it
  with a passphrase (it must be used non-interactively), but do flag any change
  that exposes it or copies it off the host.

## Local editors

A remote-development editor (VS Code Remote-SSH, Zed) talks to a server the
guest controls. Assume a guest with root can replace that server, emit any
editor-protocol message, and so run code in the **local editor process**. SSH
authentication and host-key pinning identify the peer; they do not limit what
an authenticated peer asks the editor to do. Design record:
[`design/editor-hardening.md`](design/editor-hardening.md).

`editor.security` (and `--editor-security`) selects the local editor's class:

- **`sandboxed` (default).** `EditorLauncher` runs the editor as a new,
  iso-owned process tree (`Sources/IsoHost/Editor/`):
  - The application is found only at `/Applications/<App>.app` or
    `~/Applications/<App>.app`, never from `PATH`. Its executable and bundle
    must be owned by root or the user and writable by no one else, and its
    signature must pass strict validation against the compiled-in bundle
    identifier and Developer ID team (`TrustedEditorApp`, Security.framework).
    A bundle that fails a check stops the launch; nothing falls back to
    another editor, the editor CLI or a URL scheme.
  - A per-session **enclave** under `/private/tmp/iso-editor-<uid>/` (a
    directory that must be the user's own with mode `0700`) holds HOME,
    `TMPDIR`, the editor's `--user-data-dir`, its extensions and its SSH
    files. The editor's environment is HOME, TMPDIR, a fixed system `PATH`,
    USER/LOGNAME and the locale; nothing else from the caller.
  - A fresh Ed25519 key is generated in the enclave and appended to the guest
    user's `authorized_keys` as `restrict,from="127.0.0.1,::1"` (VS Code
    re-enables port forwarding to guest loopback only). The editor reaches
    the guest only through a loopback `ssh -L` tunnel that `iso` runs outside
    the sandbox with the pinned transport, so `vm_key` never enters the
    enclave and the enclave's key authenticates to no other instance. The
    editor reads only the enclave's SSH config (`ssh -F`), which pins the
    host key with the instance's `HostKeyAlias`.
  - The editor runs under `sandbox-exec` with a deny-by-default profile
    (`EditorSandboxProfile.swift`): reads limited to the signed bundle, system
    frameworks and fonts, and the enclave; writes to the enclave only;
    execution of the bundle and `/usr/bin/ssh` only (VS Code's Remote-SSH
    also gets `/bin/sh` and the ptys it allocates itself, because it runs ssh
    in a hidden terminal); network to the tunnel port and, for VS Code, one
    fixed loopback forward port only, with no DNS. The Mach allowlist omits
    the pasteboard, LaunchServices' database (so the editor cannot open apps,
    URLs or documents), Apple Events, the keychain and Security services,
    and TCC. Chromium's own sandbox cannot nest inside Seatbelt, so VS Code
    runs with `--disable-chromium-sandbox`; the outer profile confines every
    helper.
  - `iso` stays in the foreground: every ten seconds it re-proves the
    instance (running, same isolation-gate result, pinned target and filtered
    handoff identity), and two consecutive failures, a closed tunnel, Ctrl-C
    or the editor quitting end the session. Ending kills the editor's process
    tree, closes the tunnel, removes the key from `authorized_keys` (best
    effort: the guest may keep the line, but the private key is gone) and
    deletes the enclave.
  - `editor.allow` / `--editor-allow` widen the profile explicitly:
    `clipboard` adds the pasteboard service; `internet` adds outbound TCP 443
    to any host, name resolution and TLS trust evaluation. Machine output
    reports the grants.
- **`unsafe`.** The editor's own CLI (`code`, `zed`) and URL fallbacks, which
  can reach an editor already running with the user's full authority. The
  CLI inherits only `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SHELL` and
  the locale. This mode crosses the VM boundary and prints a warning.

Residual risks in `sandboxed` mode, recorded rather than fixed:

- File metadata (`stat`) is readable everywhere; contents are not.
- The editor can check in with LaunchServices (`launchservicesd`), which
  AppKit requires to show a window; opening apps and URLs still fails
  without the LaunchServices database.
- The global and accessibility preference domains are readable.
- `internet` allows any HTTPS destination, including LAN and loopback
  services on port 443; Seatbelt cannot filter by host.
- The Mach allowlist and filesystem paths were derived on macOS 27 with
  VS Code 1.140 and Zed 1.22; a new OS or editor release can need more and
  then fails closed (the editor does not start or cannot connect).

## Machine output (`--output json`)

The `iso.machine/v1` document ([machine-interface.md](machine-interface.md))
is read by other programs, so it is a disclosure boundary like stderr:

- It never carries resolved secrets, `cmd:`/`vault:` values, proxy
  credentials or key material; `ssh-config` returns the managed alias and the
  config path only (`Sources/IsoCLI/Support/MachineResponses.swift`).
- Error messages and details are control-neutralized and bounded
  (`MachineFailure` in `MachineErrors.swift`); they carry the same text the
  stderr error already shows.
- Machine mode is non-interactive (stdin is `/dev/null`, the passphrase prompt
  is refused) and fails with `INTERACTION_REQUIRED` rather than answering a
  decision itself. It runs the same isolation gate, running proof and
  host-key pinning as text mode; flag any machine-only path that skips them.

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

- **Filtered-egress readiness is authenticated separately from guest access.**
  The existing `iso-egress` loopback listener accepts only an exact version-2
  `GET /__iso/egress-ready` challenge with the CONNECT capability and a fresh
  nonce. Its Ed25519 signature binds the nonce, immutable boot ID and computed
  allowlist hash; this operation never selects a target or performs DNS/upstream
  I/O. A separate per-boot private signing key goes transiently to the confined
  companion on stdin and remains only in process memory, never in a file, guest,
  or command line. Only its public verification key is persisted in owner-private
  host state (`egress-readiness-public-key`, removed on stop). Copying that public
  file into a workspace does not give the guest signing authority. The host
  authenticates bounded replies both directly and through pinned SSH plus guest
  loopback. A guest that knows
  the CONNECT capability still cannot forge a reply. This proves reachability
  of the keyed companion through that path, not every late session handoff.

- **Filtered credential-broker composition uses separate signatures.**
  Each effective remote provider broker must answer fresh direct and pinned-SSH
  guest-loopback challenges. Version-2 startup supplies a transient Ed25519 seed;
  only `proxy-<provider>-readiness-public-key` persists. The local
  `GET /__iso/broker-ready` challenge signs nonce, provider, boot ID and policy hash.
  It needs no provider capability, exposes no credential, and cannot select an
  upstream. Exact method, URI and three-header framing, no body/trailers, a
  two-second completion deadline and a one-second signed-reply write deadline keep
  this separate from provider forwarding. The existing capability gate, provider
  operation allowlist, confinement and credential persistence are unchanged.
  Local-model and proxy-off modes need no broker. Each reverse tunnel's recorded
  identity binds its PID to the unique control path and guest destination it was
  started with, so a reused PID or another `ssh` never stands in for it. Which
  sshd session holds the guest-side listener is reported only by the untrusted
  guest and is not relied on; a signed guest-loopback reply still requires a
  host-created forward to the signer.

- **Filtered workload sessions cannot reuse a cached readiness decision.**
  Shell, exec and agent launches take an opaque, process-local `WorkloadSession`.
  Its factory retains the boot/policy, owner/target and public keys actually
  authenticated during resolution, rechecks after environment preparation, and
  rechecks again immediately before workload SSH is spawned. A stopped/unhealthy
  instance fails; a healthy replacement identity also fails rather than adopting
  new authority for an old prepared environment. No private key or serialized
  proof is added. Nonfiltered behavior and intentional bootstrap preparation stay
  unchanged. Live administrative and workspace-transfer targets also retain the
  original proof in memory and check before SSH/SCP, tar/rsync, hook, editor and
  managed-alias operations. Bootstrap first establishes pinned transport and
  egress, then retains transport-only identity during broker preparation, with
  composite proof required before releasing hooks and initial transfers. A
  readiness refusal is distinct from an ordinary guest-command failure: hooks
  and agent updates propagate it rather than warn-and-continue. Best-effort
  capture/probe APIs return no result/false without launching the operation;
  subsequent transfer fallbacks must recheck. Local control-master cleanup is
  still permitted after refusal. While a filtered workload's `ssh` runs, `iso`
  repeats the same proof every ten seconds and kills the session (the `ssh` and
  its descendants) after two consecutive failures. The per-boot egress lease also
  supervises the companion and egress tunnel it has seen: three consecutive
  checks without either end the lease, so the grant expires, and close the
  instance's `ssh -L` forward master. Direct external SSH through the managed
  alias and `unsafe` editor sessions do not pass through `iso`; they are not
  supervised, and `iso status` reports the instance `unhealthy` instead. A
  `sandboxed` editor session is supervised (see [Local editors](#local-editors)).

- **The credential proxy is jailed.** The macOS 27+ Swift executable holds the
  real credential and accepts untrusted guest HTTP. The host wraps it in
  `sandbox-exec -p` with the Seatbelt profile embedded in
  `Sources/IsoHost/Guest/SeatbeltProfile.swift`.
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

The same VM boundary applies. The backend drives iso-sandbox
(`iso-sandbox`), a runtime isolate builds on `apple/containerization`. The
isolation contract lives in two layers: the runtime cannot express host
exposure, and isolate verifies the effective configuration anyway
(`AppleBackend`, `SandboxRuntime`, `IsolationGate` in `Sources/IsoHost/`).

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
- **Boundary audit.** `iso audit` reads `<instance>/audit.jsonl`, written
  by the host from host-side state only (configuration modes, proxied
  providers, variable names, counts); nothing guest-authored or secret is
  recorded, and the file is owner-only and bounded.
- **Session TTL.** `limits.session_ttl` is enforced outside the guest: the
  runtime records the deadline (`record.expiresAt`, host wall clock) at
  `start`, the owner halts the VM when it passes and exits cleanly (so launchd
  does not restart it), a relaunched owner refuses to boot past it, and the
  isolation gate refuses to hand out an expired sandbox. Nothing the guest
  controls, including its clock, moves the deadline. Every halt (the TTL, a
  stop request or a signal) reaches the guest through guest-agent calls a root
  guest can wedge, so if the guest is still running ten seconds after the
  forced kill the owner exits, which ends the in-process VM.
- **Runtime qualification.** `SandboxRuntime` qualification accepts `iso-sandbox`
  protocol 5 with `containerization` 0.45.0. Filtered egress requires
  protocol 5 and a live `bootId`. The runtime itself accepts
  only a kernel whose sha256 is in `KernelPin.allowed`. On first `iso setup`,
  `iso-sandbox init` pulls `ghcr.io/apple/containerization/vminit:0.45.0`
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
  rapportd. **Accepted by design**: those services authenticate their clients, and isolate's own host listeners bind
  loopback and reach a guest only through its SSH tunnel. vmnet has no
  per-network filter, so closing this would need a root-owned `pf` anchor on
  every Mac. The Apple default network (other workloads' containers) and host
  vsock are not reachable from a sandbox. A change that exposes a host
  *credential* service to guests is a finding.
- **Native control channel.** Host keys are read, and image checks run, through
  `iso-sandbox exec`: an argv delivered over vsock to the guest agent, never a
  shell string. Only fixed commands and iso-chosen paths go through it;
  guest-controlled text never does. The owner's control socket is `0600` in a
  `0700` per-user directory and checks the peer UID.
- **Host-key pinning and re-enrollment.** A changed key fails with
  `APPLE_HOST_KEY_CHANGED`. The only path that replaces a pin is a start after
  `iso restore`: isolate replaced the disk itself, and the restore removed the
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
  others write access is not detected. `scripts/build-iso-sandbox.sh` signs the runtime with the
  hardened runtime and refuses an install `bin/` that is owned by neither
  you nor root, world-writable, or group-writable by a group other than
  `wheel` or `admin`. The runtime runs with umask `077`
  and keeps its state directories `0700` and disk files `0600`.
- **Guest-controlled text** that isolate displays (host-key comments,
  runtime/guest error text, console-log excerpts, and `iso logs` in both
  snapshot and `--follow` mode) has its control characters replaced first.
- **Local-model tunnels** (`ProxyLifecycle.swift`) are reconciled on
  every bootstrap, and every boot first closes those recorded for the
  previous boot. A tunnel the current model config no longer needs is
  closed, so switching local mode off really removes the guest's path to the
  host server. Tunnel PIDs are only trusted or signalled while `ps` still
  reports them as an `ssh` process.
- **Ownership.** Sandboxes and committed disks are named
  `iso-<owner8>-<random16>`. Nothing is deleted unless the local owner record
  and the instance record both match, and the runtime refuses to delete a
  sandbox recorded for another owner tag. The `iso-` prefix alone is never
  enough.
- **Image build context** is a private temporary directory holding rendered
  files and the VM-access **public** key only. There are no build args or
  secrets. The OCI build runs in stock `container`'s builder. The result is
  imported into the runtime's private store as an OCI archive, and the
  builder's copy is deleted.
- **Committed disks** (`iso commit`) have their SSH host keys and machine-id
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
- **The maintenance image** is built by `iso setup` like the instance image
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
  - a host key is re-pinned only after a restore correlated with isolate's own
    operation id.

  Weakening any of these (skipping the guard, re-pinning on generation alone
  or guessing at unreadable staged state) is a
  finding.

## macOS guests

`iso-sandbox macos …` runs macOS guests with computer use
([design](design/macos-guest-computer-use.md)), and `iso` drives them for
images built with `iso setup --guest macos`. The same rule holds: the guest
is untrusted, and the whole VM is the boundary.

- **VM shape.** The configuration is built in one place (`MacConfig.make`):
  one display, one absolute pointer, one keyboard, one entropy device, one
  vsock device, the clone's own disk, and one network device on a vmnet
  network of the runtime's own. For a clone that is the sandbox's
  `10.231.N.0/24`; for a template build it is a network used by that build
  alone. It refuses to boot with directory shares, audio, serial or console
  ports, a memory balloon, USB controllers, or any other network attachment.
  `inspect` reports the effective configuration.
- **Helper channel (guest → host).** The guest helper's messages are tainted.
  They are line-bounded (64 KiB), limited to a closed message set, checked by
  `HelperMessage.parse`, and authenticated by an HMAC over a host nonce and
  the guest boot ID, using a per-clone key that only root can read in the
  guest.
  - At most 4 unauthenticated connections are held at once. A hello must
    arrive within 10 s of wall-clock time, and rejections are logged at most
    20 a minute.
  - The key is readable only by root in the guest. The guest user has
    passwordless sudo, so the HMAC keeps out non-root processes, not the
    agent. An agent acting as the helper can affect only its own sandbox.
  - Guest-authored strings are logged with control characters replaced.
  - An unauthenticated claim never changes host state.
  - Only an authenticated SSH host key that differs from the pin marks a
    sandbox `identity_mismatch`.
  - Guest-reported boot IDs only ever invalidate sessions.
  - The host sends the guest exactly five message types: `challenge`,
    `enroll` (helper key, authorized key, nothing secret from the host),
    `network`, `status` and `shutdown`. The helper runs fixed tools with an
    argv and no shell.
- **SSH pin.** Each clone generates its own host keys at first-boot
  enrollment. The runtime pins the key that arrives over the vsock channel,
  re-checks it over the authenticated channel on `inspect` and on every
  computer-use session, and exposes it as `inspect.sshHostKey`. Consumers
  must connect with `StrictHostKeyChecking=yes` against that pin, as the
  qualification driver does. There is no `ssh-keyscan` and no TOFU.
- **Template build (accepted trade-off).** Building a template uses one SSH
  session that trusts the guest's host key on first use, authenticated by a
  random password held in memory only. The password reaches ssh through an
  askpass child's environment and sudo through stdin, never argv or logs. The
  session runs on a vmnet network created for that build alone, so no other
  VM can answer for the guest. It uses no user ssh configuration
  (`-F /dev/null`), no agent and no forwarding. The guest was installed from
  the operator's IPSW moments earlier by the same process. The template ships
  no host keys and has password authentication off.
- **Frames (guest → host).** A frame is guest-rendered pixels. The owner
  re-encodes it from the view's bitmap at a fixed geometry and never parses
  guest-provided image formats. Uniform frames are refused.
- **Input (host → guest).** Actions are a closed, validated set (bounded
  coordinates, paths, key codes, ASCII text). They are synthesized into the
  view in-process and never posted to the host event system. The owner needs
  no Screen Recording or Accessibility permission.
- **Control socket.** It sits in the per-user `iso-sbx` directory, mode 0600,
  and accepts only the owning uid (`getpeereid`), as for Linux owners.
- **Host CLI.** `iso` hands out a macOS guest only after
  `IsolationGate.verifyMacEffective` accepts the owner's report: the record's
  owner, template, network mode and resources; one display; no shares,
  audio, serial, USB or console devices (a clipboard needs one); only the
  clone's own disk; only the helper's vsock listener; and the dedicated
  `10.231.N.0/24` network and address. The owner reads these from the
  configuration the VM booted with and the listeners it registered. Unknown
  effective fields fail closed. At boot the guest helper must also have
  confirmed the pinned host key; later handoffs rely on that pin, which the
  instance's `known_hosts` enforces, so a slow or reconnecting helper does
  not block them, though anything it reports must still match the boot. The
  SSH pin comes from the runtime (`inspect.sshHostKey`), never from the
  network, and later boots require the same key. The one installation public
  key (`vm_key.pub`) is the authorized key given at create; no host secret is
  given to the guest.
- **Template provisioning (accepted trade-off).** `iso setup --guest macos`
  gives the build a root script (`MacProvision`) that fetches the Command
  Line Tools through `softwareupdate`, a GitHub CLI release pinned by
  checksum, and the Claude Code and Codex installers from the same URLs the
  Linux image uses. It runs on the build's own vmnet network before the
  template is sealed; the template records the script's SHA-256 and iso
  refuses a template whose recorded script differs. The script sets
  `AcceptEnv *`, as the Linux image does, so forwarded variables reach the
  guest.
- **Filtered egress.** As on Linux: a host-only network with no route, the
  `iso-egress` companion behind an `ssh -R` tunnel on guest loopback, and
  the signed readiness proofs, read from the macOS sandbox's own runtime
  directory. The guest probe uses `/usr/bin/perl`'s alarm and `/bin/cat`,
  which both guest systems have. Command-line tools use the forwarded proxy
  variables; GUI applications do not read them and fail closed.

## `iso update` trust chain

Self-update (`Update.swift`, `UpdateRelease.swift`) must preserve, in order:

1. Metadata from the pinned `chr33s/iso` GitHub repo (compile-time const).
2. `normalizeTag` — the version tag is validated as semver **before** it enters
   the API URL path (path-traversal guard).
3. **Mandatory signature.** `SHA256SUMS.sig` must be present and must be an
   OpenSSH `SSHSIG` (`ssh-keygen -Y sign`) over the exact `SHA256SUMS` bytes,
   in namespace `release-sums@chr33s`, by a key in the compiled-in
   `ReleaseSigners.keys` (`ReleaseSignature.swift`); nothing in `SHA256SUMS`
   is read before it verifies. `install.sh` checks the same list with
   `ssh-keygen -Y verify`. This is the provenance floor that does not depend
   on `gh`, and it holds in test mode too.

   The key is a maintainer's SSH key held in their ssh-agent and never in CI:
   `release.yml` publishes a **draft**, and `scripts/sign-release.py` checks
   the draft's digests and pinned attestation before signing and publishing
   it. The key list is compiled in rather than fetched from
   `github.com/<user>.keys`, so a GitHub account compromise alone cannot
   re-key updates. It lives in three places — `ReleaseSigners.keys`,
   `.github/release-signers` and `ALLOWED_SIGNERS` in `install.sh` — which
   `signerListAgreesAcrossBinaryInstallerAndSigningScript` keeps equal.
   Rotation: a release signed by a listed key ships a binary that also lists
   the next key; the old key is dropped in a later release. Losing every
   listed private key strands installed binaries on their current version
   (reinstall through `install.sh`), so keep a second, offline key listed.
4. **Mandatory checksum.** The `SHA256SUMS` asset must be present (install is
   refused otherwise) and every downloaded tarball is verified against it
   (`verifySHA256`, fixed-size digest compare).
5. **Best-effort attestation.** `gh attestation verify --repo chr33s/iso
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
   `gh` digests the artifact and requires a matching subject — plus the
   **signer pin**. Both clients pass `--cert-identity
   https://github.com/chr33s/iso/.github/workflows/release.yml@refs/tags/<tag>`,
   `--source-ref refs/tags/<tag>` and `--deny-self-hosted-runners`
   (`Provenance.verifyArguments`, `signer_pin` in `install.sh`), on the bundle
   and the API path alike. A bundle minted by any other workflow in
   `chr33s/iso` — `candidate.yml` also holds `attestations: write` — or by
   `release.yml` for a different tag, or on a self-hosted runner, is refused.
   `--repo` alone would accept all of those.

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
   entirely when `ISO_UPDATE_API_BASE_URL` is overridden (test mode). So
   Sigstore provenance is *not* guaranteed on hosts without `gh` — the
   signature is the floor there.
6. Extraction with `tar -xzf --no-same-owner --no-same-permissions` (path-escape
   safe), then an atomic `rename`-over-self.

Neither signature layer can be revoked once a client holds it, so withdrawal
is by the next good release: **anti-rollback** refuses any target older than
the running binary — pinned `--version` and `--force` alike — unless
`--allow-downgrade` is passed, and `ReleaseRevocations.digests` lists archive
digests that are refused before the checksum is even compared. Together an
updated binary never moves back onto a withdrawn release without an explicit
opt-in. `install.sh` installs whatever `VERSION` names and has neither guard;
it is the deliberate recovery path.

`ISO_UPDATE_API_BASE_URL` redirects the update origin **and** disables
attestation; the release signature is still required, so that server must serve
`SHA256SUMS` signed by a listed key. Only the pinned `github.com` default +
attestation provide Sigstore provenance. Flag any change that widens where that override
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
- softens any step of the `iso update` verification chain.
