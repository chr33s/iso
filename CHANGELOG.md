<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Changelog

## Unreleased

### Agent sessions

- **Filtered workload handoffs**: shell, exec, Claude, Codex and `iso run`
  recheck authenticated readiness after environment preparation and just before
  SSH launch, retaining the original boot/policy and signing identities. A healthy
  replacement does not authorize reuse of a prepared session. Bootstrap remains
  separate; administrative/transfer handoffs and full NET-20 are still unfinished.
- **`iso run`**: one command resolves a project the way `iso up` does, then
  launches Claude, Codex, or an installed agent definition. A warm match is
  not pushed, rebuilt, or bootstrapped again. `--dry-run` does not start a
  VM, build an image, resolve a credential, or check for updates.
- **Agent definitions**: `iso agent list|inspect|add` installs a host-owned
  JSON definition. Definitions request a reviewed `none`, `claude`, or
  `codex` adapter and may suggest hosts; they do not grant network,
  credentials, or mounts. `iso agent update` is unchanged.
- **`--rm`**: creates a new disposable instance, marks it ineligible for
  project affinity, and destroys it only when the session record proves
  ownership. A pending staged pull is retained. `iso run-cleanup` reconciles
  abandoned records.
- **`iso images inspect` and `iso images cache status`**: host-recorded image
  provenance. Runtime cache allocation is reported as unavailable. Prune and
  edit are not available.
- **Filtered egress** starts `iso-egress` for `egress: "filtered"` and renews
  it only while the protocol-5 live `bootId` still matches. A protocol-4
  runtime cannot start that mode. A local real-VM check passed approved HTTPS,
  unapproved CONNECT denial, and direct Internet TCP denial; full filtered
  qualification remains open (see `docs/testing.md`). The companion reads
  renewals from the supervisor's pipe, and a queued renewal cannot revive an
  expired lease. GitHub auth changes and devcontainer overlays preserve the
  configured allowlist. Timed-out DNS waits retain their work slots until
  libc resolution finishes, and address lists are freed even when they arrive late.

### Boundary hardening and local secrets

- **Filtered handoff state** rechecks runtime protocol 5, live boot/owner
  identity and the boot's policy hash. Frozen policies reject inconsistent
  hashes, hosts and modes. An atomic owner-only boot-policy record replaces
  the boot-id-only file; older filtered sessions must be stopped and restarted.
  Fresh challenges authenticate the live companion locally and through guest
  loopback, bound to its boot ID and computed allowlist hash. The Ed25519 private
  signing key stays in process memory; only its public key is persisted, so
  workspace copies do not grant signing authority. No upstream request is needed.
  Startup and post-start hooks fail closed on missing proof. Filtered running-instance
  resolution also requires signed direct and guest-loopback proof from every effective
  remote credential broker, bound to provider, nonce, boot and policy. Broker signing
  keys remain in memory; only public keys persist. Nonfiltered version-1 startup and
  provider forwarding rules are unchanged. Every late handoff and full NET-20 remain
  unfinished.
- **Filtered relay** drains queued bytes before forwarding half-closes, permits
  the opposite response direction, and stops on hard I/O errors instead of
  dropping data and continuing. Interrupted I/O is retried; paused hung-up
  sources do not spin under backpressure. Local socket and mutation tests cover
  these paths; full filtered-VM qualification remains open.
- **Filtered lease state** uses typed PID/date decoding and bounded regular
  control-file reads without following symlinks. Invalid identities, malformed
  deadlines, and lock-probe errors stop renewal; only an absent/null deadline
  permits unlimited TTL. This hardening does not qualify full filtered egress.
- **Apple owner startup** explicitly requests the bootstrapped launchd job
  without killing an already-started owner. A loaded but deferred `RunAtLoad`
  job no longer stalls first boot. Failed requests attempt to unload the job
  and preserve cleanup errors. Automatic crash-respawn qualification remains
  blocked on the local host; explicit-start evidence does not prove it.
- **Staged pulls**: `iso diff` and `iso pull --review` pull the guest
  workspace into a host-side stage and print it for review; `iso pull --apply
  [--stage-id ID]` applies it and `--discard` drops it. Special files, hard
  links, escaping or chained symlinks and control-character names make a stage
  inapplicable, and `workspace.pull` budgets bound it.
  `workspace.pull.mode = "stage"` makes a plain `iso pull` stage too; the
  default `direct` mode is unchanged.
- **Local secret store**: `iso secrets init|set|rm|list|status` keeps
  secrets under `<data_dir>/secrets/`, encrypted with a key that needs both a
  passphrase (scrypt) and this Mac's Secure Enclave (Touch ID). There is no
  recovery path. Adds the swift-crypto 5.0.0 dependency (scrypt).
- **`proxy.mode`** (`auto`, `required`, `off`). Under `auto` a proxied
  provider now withholds all of its credential variables
  (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `OPENAI_API_KEY`); `required` never forwards any of them and fails
  `up`/`start` without a provider proxy.
- **`--env-file`** on `up`/`start`, and whole-value `{vault:NAME}` references
  in `--env`/`--env-file` values, resolved from `iso secrets` per session and
  persisted only as references.
- **Stored provider credentials**: `ANTHROPIC_API_KEY={vault:NAME}` (and the
  other provider variables) goes only to that VM's credential proxy, never the
  guest. `proxy.<provider>.credential` and `github.pat` tokens accept
  `vault:NAME`.
- **`egress: "none"`**: new instances get a vmnet host-only network with no
  route beyond the Mac and no resolver; SSH and isolate's tunnels keep working.
  No raw provider credential is forwarded into such a guest, whatever
  `proxy.mode` says.
  Requires iso-sandbox 0.3.0 or later (protocol 3).
- **`limits.session_ttl`**: each boot ends at a host-clock deadline enforced
  by the sandbox owner (`APPLE_SESSION_EXPIRED` after it). iso-sandbox 0.4.0
  (protocol 4) is now required; 0.3.0 and older are refused.
- **`security.preset`** (`networked`, `provider-only`, `offline`) supplies
  defaults for `egress`, `proxy.mode` and `workspace.pull.mode`, and
  **`iso audit [--suggest-config]`** shows the boundary metadata isolate records
  per instance (never values).

### Swift host

- **The host CLI is Swift.** The Rust `iso` host, its Cargo manifests,
  toolchain pin and cargo-fuzz workspace are removed; building isolate no longer
  needs Rust. The root `Package.swift` builds `iso` (modules `IsoCore`,
  `IsoConfiguration`, `IsoHost`, `IsoCLI`), with one concrete Apple backend.
  `iso-proxy` and `iso-sandbox` remain separate packages and processes.
  `python3 scripts/build-release.py` builds and archives all three; parser
  fuzzing uses Swift libFuzzer harnesses (`scripts/fuzz.sh`).
- **Configuration is JSONC** at `~/.iso/config.jsonc` (strict JSON through
  an explicit `--config *.json`). TOML is no longer read: a `.toml` path or a
  lone legacy `config.toml` stops with instructions to convert it with
  `scripts/migrate-config-to-jsonc.py --input PATH --output PATH
  [--drop-retired-fields]` (Python 3.11+). `config.example.jsonc` replaces
  `config.example.toml`.
- **Removed Firecracker configuration**: `firecracker_bin`, `vm.kernel_path`,
  `vm.boot_args` and the `network` object are rejected by name; the converter
  refuses them unless `--drop-retired-fields` is given.
- **Static shell completions only**: `iso completions bash|zsh|fish`. Runtime
  `COMPLETE=<shell>` hooks, instance/image name completion, and PowerShell and
  Elvish output are removed.
- **Setup consolidation**: `iso setup --config-only` writes the JSONC template
  and does nothing else; `iso init` is a deprecated alias for it.
  `iso quickstart` is removed and explains its replacement (`setup`, then `up`,
  then `claude`/`codex`).
- **Credential provisioning**: `iso proxy setup` stores provider credentials
  only in the macOS Keychain and writes a `cmd:` reference; the 1Password,
  plaintext-file and Secret Service adapters are removed. Literal credentials in
  `proxy.anthropic.credential`, `proxy.openai.credential` and per-VM overrides
  are rejected; use a `cmd:` reference.
- **`~/.coop-apple` is no longer read or migrated.** Host-key pins use the
  `HostKeyAlias` `<machine>.iso`; instances pinned under the former
  `.coop-apple` alias must be re-enrolled (recreate or restore the instance).
- **Security changes** (accepted 2026-09-28): MCP server definitions are passed
  to `claude mcp add-json` on stdin instead of argv; guest-bound `ssh`/`scp`/`rsync`
  inherit only a minimal host environment plus the forwarded values; proxy and
  tunnel PIDs are signalled only while they still name `iso-proxy`/`ssh`; the
  proxy starts only on a free port and must be its sole listener before the
  credential is sent; devcontainer Feature manifests and layers are
  digest-verified and `install.sh` is read as a bounded regular file without
  following links; `guest_env.json` is written `0600` and instance directories
  `0700`; guest and runtime text in errors and diagnostics has control
  characters neutralized.

### Fork rewrite

- Replace the Rust credential proxy with the Swift-only macOS 27+ implementation;
  retain the Rust host CLI and Linux/Firecracker support without proxy mode.
- Move the Swift packages to root-level `iso-proxy/` and `iso-sandbox/` and
  update build, test, workflow, and documentation paths.
- Document the fork’s reduced proxy implementation/dependency surface, source
  installation, and outstanding acceptance and distribution gates.

### New features

- **Opt-in Apple sandbox backend (macOS)** — building with
  `--features apple-container` replaces Lima with iso-sandbox
  ([`iso-sandbox`](iso-sandbox)), a Swift runtime on Apple's
  `containerization` 0.45.0 built with `scripts/build-iso-sandbox.sh`. Each
  instance is its own VM on its own vmnet network with no host mounts, socket
  relays, published ports, or host SSH-agent forwarding. isolate verifies the
  running VM's effective configuration and pins its SSH host key before every
  hand-out; workspaces are copied. It supports explicit disk sizes, offline
  disk growth (`iso resize --size`), CPU/memory changes, and
  `iso commit`/`iso restore`. Committed disks have their guest identity
  removed, and a restore re-pins the new host key. Sandbox owners run as
  launchd jobs, and a crash restarts them on the same disk. Stock Apple
  `container` 1.4.1 is used only to build images and supply the guest kernel.
  State lives in `~/.coop-apple`, and `iso update` is disabled for this
  build. See [`docs/backends.md`](docs/backends.md). The choice over stock
  Apple containers and a `container machine` fork is recorded in
  [`docs/design/apple-sandbox-runtime.md`](docs/design/apple-sandbox-runtime.md);
  [`tests/integration-apple-sandbox.sh`](tests/integration-apple-sandbox.sh)
  checks it on real hardware.

### Fixes

- **`iso stop` no longer reports an instance stopped when its liveness probe
  fails** — a failed probe used to be treated as "not running", so `iso stop`
  printed "stopped" while the VM kept running. It now tears down the
  credential proxy and stops the instance through the backend's control plane
  (PID file, `limactl`, or the runtime), or returns an error if that fails.
- **`iso status` lists every instance even when one cannot be probed** — that
  instance is shown as `unknown` (JSON `"state": "unknown"`) with a warning,
  instead of the whole listing failing.
- **rsync transfers work when the VM key path contains a space** — SSH options
  containing whitespace are now quoted in rsync's `-e` command.
- **Editor SSH aliases work when the VM key path contains a space** — the
  `IdentityFile` in the `iso-<name>` block of `~/.ssh/config` is now quoted.
- **Lima: an instance starts again after `iso resize --size`** — Lima 2.x
  refuses to boot ("disk shrinking is not supported") when `lima.yaml` records
  a smaller disk than the file on disk. Growing the disk now updates `disk:`
  in `lima.yaml` too.

### Internal

- **CI no longer runs clippy with `--all-features`**; the macOS-only
  `apple-container` feature is linted and tested in its own macOS job, and
  Linux checks that enabling it fails to compile.

## v0.6.0

### Upgrading from v0.5.4

- Rerun the [installer](docs/getting-started.md#install) to install both `iso`
  and the new `iso-proxy` companion in the same directory. The v0.5.4 updater
  replaces only `iso`, so its first upgrade does not install the companion
  required for proxy mode. Preserve your `INSTALL_DIR` if you used a custom
  installation directory.
- The published v0.5.4 Linux ARM64 binary reports
  `iso 0.5.4-dev (8e24729+dirty)` and refuses self-update as a development
  build. Use the installer to upgrade it.
- Restart all running Linux VMs after upgrading to apply guest-to-guest
  network isolation. Every VM on the shared bridge needs the restart; a
  pre-upgrade VM leaves peers reachable. macOS is unaffected.
- Save guest-only work before `restore --reprovision`: it replaces the guest
  disk, including any guest keyring and cached account login. Rebuilding an
  image alone does not update existing VM disks.

### New features

- **Codex ChatGPT account auth** — New `[codex] auth = "chatgpt"` mode for
  account/workspace access without OpenAI API billing. isolate installs Linux
  Secret Service support in the guest image, writes Codex's
  `cli_auth_credentials_store = "keyring"` setting, launches Codex through a
  D-Bus/GNOME Keyring wrapper (`/usr/local/bin/codex-account`, which the
  in-guest `codex-yolo` shortcut also uses and which execs Codex unchanged when
  the mode is off), suppresses every `OPENAI_API_KEY` forwarding path, and stops
  copying host `auth.json` into the guest. Sign in with `iso codex -- login
  --device-auth`; `login` and `logout` now run without the sandbox-bypass flag,
  which is meaningless on subcommands that never start an agent session.
  Existing images must be rebuilt with `iso setup --rebuild` before using this
  mode. A restart reuses the old guest disk, so an existing VM also needs
  `iso restore <vm> --image <image> --reprovision` (or a destroy and
  recreate) to pick up the new guest packages.
- **`iso restore --reprovision` — start over without re-typing anything**
  (#432) — Replaces a clobbered or bloated guest filesystem with a fresh copy of
  the instance's image, then provisions it as a first boot: `/workspace` is
  restored from the source the instance recorded — re-synced, re-cloned or
  re-mounted — agents are re-bootstrapped, and plugins, marketplaces and MCP
  servers are reinstalled. The instance is left running, so no follow-up
  `iso start` is needed. It keeps its name, index, IP, image, disk size, port
  forwards and guest env — including a devcontainer's `containerEnv` and
  `forwardPorts` — so those flags do not have to be remembered. GitHub PATs and
  provider credentials live in the host-side secret store and are untouched.
  Extra `--extra-mount` directories, `--exclude-git` and a devcontainer's
  `postStartCommand` are not replayed, because isolate does not persist them.

  This is what `iso restore` + `iso start` could not do: a restart skips the
  workspace sync and the plugin install on the assumption that both survived on
  the guest disk — which holds for a `iso commit` checkpoint, but not after the
  disk is replaced with a base image. Plain `restore` + `start` remains the
  checkpoint rollback; `--reprovision` is the base-image case.

  `--image` becomes optional under `--reprovision`, defaulting to the image the
  instance already records; it stays required otherwise. `-y` skips the
  confirmation and is required off a TTY. `-y`, `--no-agents` and `--no-prompt`
  are rejected without `--reprovision`, since none of them mean anything to a
  plain disk swap. Unlike a plain `restore`, which requires a stopped instance,
  `--reprovision` also accepts a running one and stops it itself. `iso restore`
  without `--reprovision` is unchanged.

- **Credential-injecting proxy — keep the model API keys out of the guest**
  (#411) — New opt-in `[proxy]` config. When set, isolate runs a small host-side
  reverse proxy (`iso-proxy`, a new binary shipped in the same tarball) — one
  process per (VM, provider) — for the lifetime of a remote-mode VM: the guest
  is pointed at it and holds only a per-instance capability token, while the
  real credential stays on the host and is injected onto requests upstream.
  - **Claude Code** (`[proxy.anthropic]`) is pointed at the proxy via
    `ANTHROPIC_BASE_URL`; supports an API key (`x-api-key`) or a Claude
    `setup-token` (`Authorization: Bearer`).
  - **Codex** (`[proxy.openai]`) is pointed at the proxy via a
    `[model_providers.iso_local]` block (Responses API) with the capability
    token as the provider bearer; OpenAI API keys inject as
    `Authorization: Bearer`. In proxy mode Codex's `~/.codex/auth.json` is no
    longer staged onto the guest disk; Codex subscription is out of scope — use
    an API key.

  The raw `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` is no longer forwarded into the
  guest, so a prompt-injected or rogue agent cannot read a usable key.
  Resolution fails closed — a bad credential aborts the boot rather than booting
  without injection. `iso model <vm> local` takes precedence and tears the
  proxy down. The proxy binds host loopback and is reverse-tunnelled (`ssh -R`)
  into the guest, so it works on both backends (Firecracker and Lima). GitHub
  is a tracked follow-up. `iso update` keeps `iso` and `iso-proxy` in
  lockstep.

- **The credential proxy is jailed** (#411) — the host-side `iso-proxy`
  process runs confined so a proxy exploit cannot write files or execute
  programs, and — on a new enough kernel — cannot reach any host beyond the
  upstream `:443` and DNS `:53`. On Linux it self-applies Landlock before
  serving, tiered by kernel capability: filesystem-write and program-exec are
  always denied (kernel ≥5.13) and fail-closed — the VM start aborts rather
  than running the proxy without that floor; TCP egress is port-scoped only on
  kernel ≥6.7, and on kernels 5.13–6.6 (which have no Landlock network rules)
  that scoping is dropped and egress is left open. On macOS the launcher wraps
  it in `sandbox-exec` with a Seatbelt profile. The jail is port-scoped, not
  host-scoped (upstream identity is enforced by the proxy's TLS verification),
  and does not restrict UDP on Linux; see
  [`docs/trust-model.md`](docs/trust-model.md).

- **Per-VM credential overrides + `iso proxy status`** (#411) — A single VM can
  use a different credential than the `[proxy.<provider>]` default — for
  per-project billing, scope, or revocation — via `iso proxy setup [--openai]
  --vm <name>`. The override is stored in that instance's state
  (`<inst.dir>/proxy.json`), not a growing config table, and its secret is
  namespaced separately. Resolution is override → default → off. `iso proxy
  status [--vm <name>]` shows what each VM resolves to, with credentials
  redacted.

- **`iso proxy setup` — store a provider credential like a GitHub PAT** (#411)
  — Mirrors the `iso github` PAT wizard: paste a credential, pick a secret
  backend (macOS Keychain / Linux secret-service / 1Password / 0600 file), and
  isolate stores it and writes the `cmd:` reference into `[proxy.<provider>]` — the
  credential is never plaintext in the config. Anthropic is the default;
  `--openai` configures Codex. The secret store is namespaced per service, so
  proxy secrets live under their own directory rather than among the GitHub PATs.

- **`iso editor` — VS Code or Zed** — `iso vscode` is now `iso editor`
  (the old name remains as an alias). `--editor` takes `code` or `zed`;
  when omitted, isolate tries VS Code first, then Zed. Zed connects with
  `zed ssh://iso-<name>/<path>`, reusing the same `~/.ssh/config` alias
  block that VS Code's Remote-SSH uses.

- **`iso up --new-instance` — a second instance for the same project** — `up`
  normally reuses the instance recorded for a project directory or `--git-repo`
  URL. `--new-instance` skips that lookup and creates a sibling instance
  instead, so two agents can work from one source tree. It requires `--name`,
  since the project-derived name is already taken. Once a project has siblings,
  `iso up` reports the ambiguity rather than picking one, so address them by
  name (`iso start <name>`, `iso shell <name>`).

### Fixes

- **Firecracker guests can no longer reach each other by IP** — Instances on the
  same host share the `br0` bridge and a single subnet, so any guest could reach
  any other guest's SSH and forwarded ports. isolate now marks every TAP as an
  isolated bridge port and inserts a `FORWARD -i br0 -o br0 -j DROP` rule; both are
  needed, since the bridge flag alone leaves a guest able to route around it via
  the host's bridge address. Guest→host and guest→internet are unaffected. A
  host that cannot apply the flag fails the VM start instead of booting an
  unisolated guest; this needs Linux ≥ 4.18 and iproute2 ≥ 4.19. **Restart any running VMs after
  upgrading** — isolation applies per start, and because the kernel requires
  both ports to be isolated, one pre-upgrade VM leaves the whole bridge
  unisolated. This blocks reachability, not impersonation; see
  [`docs/trust-model.md`](docs/trust-model.md) for the residuals. macOS is
  unaffected — Lima gives each guest its own user-mode NAT.

- **Guest transports fail instead of hanging when a VM stops responding** — A
  paused VM, a wedged sshd, or a lost TAP device left `ssh`, `scp`, and `rsync`
  calls blocked on a dead socket with no deadline, so lifecycle commands,
  `iso exec`, and `iso push`/`pull` hung until interrupted. Every transport
  now derives from one option list that sets `BatchMode`, a connect timeout,
  and a liveness probe, so a guest whose sshd stops answering fails after ~90s
  — the bound interactive sessions already had.

- **The guest hostname resolves, so `sudo` stops warning** — Instance creation
  renamed the Firecracker guest to `claude-<name>` in `/etc/hostname` but left
  the image's `127.0.1.1 claude-vm` entry in `/etc/hosts`, so every `sudo` in
  the guest printed `sudo: unable to resolve host claude-<name>` before running.
  Both files are now written together at create and restore, and the guest
  hostname is clamped to fit the kernel's 64-byte hostname limit so long
  instance names still get a resolvable name. No image rebuild is needed — the patch is
  per-instance, and the image's own entry is what gets overwritten — but
  `patch_guest_network` runs only on create and restore, so an existing VM
  keeps the stale entry until `iso restore <vm> --image <image>` or a destroy
  and recreate.

- **Fail closed on an unmanaged `CODEX_HOME` in ChatGPT auth mode** (#441) —
  The guest wrapper now refuses an explicitly set `CODEX_HOME` when isolate's
  managed `~/.codex/config.toml` selects keyring storage. This prevents `codex
  login` from silently writing a plaintext refresh token to the alternate
  directory, including a workspace path that syncs back to the host.

- **Install the full native Codex package** (#442) — Image provisioning and
  `iso agent update --codex` use OpenAI's native installer, preserving bundled
  tools and upstream setup. The guest user owns the installation and can run
  `codex update` directly. `/usr/local/bin/codex` remains a compatibility link,
  and host-driven updates migrate older direct-binary installations.

- **`install.sh` and `iso update` verify provenance without a GitHub
  credential** (#421) — Verification ran `gh attestation verify --repo
  trailofbits/coop`, which reads the Sigstore bundle from the attestations
  API. `gh` refuses to run that command unless it is logged in, and then
  attaches its stored token, so a token with no SSO session for the
  `trailofbits` org got `HTTP 403` and the install was refused; the same path
  failed outright for anyone with `gh` installed but not authenticated.
  Releases now publish the provenance bundle as an `attestations.jsonl` asset,
  and both clients fetch it with an unauthenticated request and verify against
  it with `--bundle`, which makes no attestations-API call and needs no
  credential. Releases published before the asset existed are still verified
  through the API path, unchanged.

## v0.5.4

### New features

- **`iso agent update` — refresh in-guest Claude Code and Codex** (#403) —
  Agents are installed "latest at build time" during `iso setup` and are not
  part of the image-staleness hash, so a plain `iso setup` never refreshes
  them; they go stale in long-running VMs and in new VMs built from an old
  image. `iso agent update [NAME] [--claude] [--codex] [--check] [-y]` updates
  the agent binaries inside a *running* instance without rebuilding the golden
  image. No agent flag updates both; `--check` reports installed vs. latest and
  changes nothing. Codex (root-owned `/usr/local/bin/codex`, no background
  updater) is reinstalled from the current release via isolate's own installer
  over SSH; Claude Code (`~/.local/bin`, already self-updating) runs
  `claude update` synchronously. Versions are parsed to semver so "update
  available" is a comparison, not a string diff; an unparseable version
  degrades to `Unknown` rather than erroring.

- **Codex plugins and marketplaces** (#407) — New `[codex] marketplaces` /
  `[codex] plugins` config fields (with `~` expansion and local-path
  validation), mirroring the existing Claude Code mechanism. On Lima the set is
  baked into the golden image and staleness-checked; on Firecracker it installs
  on first boot. isolate preserves the guest's own `[marketplaces.*]`/`[plugins.*]`
  tables across the per-boot `~/.codex/config.toml` rewrite — so plugins
  installed in-guest and manual `/plugins` toggles survive stop/start — while
  dropping any that came from the host config. Local marketplace directories
  are copied into a per-tool guest subdir so same-basename marketplaces from
  the two agents don't collide. Behavior change: marketplaces/plugins set
  directly in the host `~/.codex/config.toml` (rather than in isolate's `[codex]`)
  are now stripped from the guest; declarative `[codex]` is the source of
  truth.

### Fixes

- **Guest-memory floor enforced by construction** (#404) — `iso up --mem 16`,
  `iso setup --mem 16`, a `config.toml` with `mem_size_mib = 16`, and a
  cloned repo whose `devcontainer.json` sets `hostRequirements.memory` below
  the 128 MiB minimum are now all rejected up front, instead of booting an
  unbootable VM that never comes up on SSH. The floor lives in a new
  `VmMemory` type whose constructor every entry point routes through (CLI,
  `config.toml`, `iso resize`, the devcontainer translator), so no lifecycle
  path can hold a sub-floor value. The stale `Validated` witness — which
  vouched for a config that lifecycle commands mutated afterward, and which
  the actual VM boot (`create_and_start`) never even consumed — is removed;
  the environmental (path-existence) checks it stood in for now run at the
  backend boot choke point on the freshest filesystem state, so a new
  lifecycle path cannot skip them. The start-time mount set gains a
  `ValidatedMounts` constructor that enforces guest-path uniqueness on every
  path, closing a gap where `iso quickstart` skipped the check.

- **Firecracker CI artifact listing fetched over HTTPS** (#401) — the S3
  `ListObjectsV2` request that discovers kernel/rootfs versions during
  setup used plain HTTP: the bucket name contains dots, which breaks TLS
  certificate matching for the virtual-hosted URL. It now uses the same
  path-style HTTPS endpoint as the downloads themselves, so a network
  attacker can no longer steer version selection.

### Documentation

- **Docs describe the public repository** (#401) — removed the
  transitional "while `trailofbits/coop` is private" wording from the
  README and `docs/commands.md`. `iso update` and `install.sh` work
  anonymously and use `gh`/`GITHUB_TOKEN` opportunistically when present.

### Internal

- **`repository` metadata added to Cargo.toml** (#401).

## v0.5.3

### New features

- **`iso resize` changes memory and vCPUs in place** (#397) —
  `iso resize` now accepts `--mem <MiB>` and `--vcpus <N>` alongside the
  existing `--size`, so a stopped instance's RAM and vCPU count can be
  changed without destroy-and-recreate. At least one of the three is
  required; `--start` boots the instance after applying the change
  instead of leaving it stopped. The backend config artifact is now the
  source of truth for mem/vcpu (mirroring how disk already works): on
  Firecracker the per-instance JSON is read back and only the infra
  fields are regenerated on restart, so a change to the global `[vm]`
  config no longer silently alters RAM for every existing instance; on
  Lima the `cpus`/`memory` keys in `lima.yaml` are rewritten atomically.
  `iso status` reads mem/vcpu from the artifact. A failed `--start`
  boot rolls the values back so the instance stays bootable.

- **`--json` output on read/query commands** (#386) — An opt-in `--json`
  flag on the highest-value read commands emits machine-readable output
  for reliable parsing; the human-readable default is unchanged. Covered:
  `status`, `list`/`ls`, `images`, `devcontainer check`, `github status`,
  `profiles list`, and `up`/`start --dry-run`. Each command builds one
  `Serialize` view model and `--json` switches only the final render
  step, so the human and JSON outputs cannot drift; absence is
  `null`/`[]` rather than sentinel strings. For `devcontainer check` and
  `up`/`start --dry-run` the JSON payload goes to stdout while the human
  report stays on stderr, so `… --json | jq` stays clean. See
  `docs/json-output-design.md`.

### Fixes

- **AppleDouble sidecars no longer copied on macOS hosts** (#376) —
  macOS creates `._`-prefixed AppleDouble sidecar files when archiving
  through the system `tar`. isolate now sets `COPYFILE_DISABLE=1` when
  creating workspace archives on macOS so these sidecars are not written
  into the guest transfer.

### Internal

- **`.editorconfig`** (#395) — declares the repo's indentation and
  whitespace rules so editors match the project's formatting.

- **License field in `Cargo.toml`** (#387).

- **Release workflow sets the release title** (#382).

### Documentation

- **`CONTRIBUTING.md`** (#393) and **`SECURITY.md`** (#394) added.

- **Pronunciation guide in `README`** (#383).

### Dependencies

- `anyhow` 1.0.102 → 1.0.103 (#377)
- `clap_complete` 4.6.5 → 4.6.7 (#398)
- `actions/attest-build-provenance` 4.1.0 → 4.1.1 (#399)
- `actions/cache` v5.0.5 → v6.1.0, `cargo-bins/cargo-binstall` v1.20.0 →
  v1.20.1, `zizmorcore/zizmor-action` v0.5.6 → v0.5.7 (#384)

## v0.5.2

### New features

- **`iso model` — route a VM at a host-side local model** (#352) —
  Points Claude Code and Codex at a local model server (Ollama, LM
  Studio, vLLM, llama.cpp) running on the host instead of the cloud,
  configured per tool under `[claude.local_model]` /
  `[codex.local_model]` in `config.toml`. `iso model <vm>` reports the
  per-tool mode and resolved endpoint; `iso model <vm> local` routes
  the VM at the local model(s) and `iso model <vm> remote` restores
  the cloud defaults. The selection is a persisted per-VM setting (not
  a per-launch flag), so it applies to `iso shell`, `iso claude`,
  `iso codex`, and VS Code alike; switching writes guest config over
  SSH with no rebuild and is re-applied on the next boot. A
  `localhost`/loopback `host_url` is rewritten to the backend's
  guest-visible host automatically.

- **`iso codex` bypasses Codex's sandbox by default** (#353) — `iso codex`
  now launches Codex with `--dangerously-bypass-approvals-and-sandbox`, so it
  runs unrestricted like `iso claude`. The VM is the isolation boundary, and
  Codex's Linux sandbox does not work in the guest (no functioning bubblewrap),
  which previously made every shell command Codex ran fail on sandbox setup.
  Pass `iso codex --ask` to keep Codex's sandbox and approval prompts.

- **`iso commit` + `iso restore` — checkpoint and roll back an instance** (#289) —
  `iso commit <name> --image <image>` saves a stopped instance's
  filesystem as a reusable image, a `docker container commit`-style
  backup (files, not live memory). The committed image is an ordinary
  isolate image: `iso images` lists it and `iso up --image` launches new
  instances from it. `iso restore <name> --image <image>` rolls a
  stopped instance back to an image's filesystem in place, keeping the
  instance's name, index, IP, and workspace association. Both require a
  stopped instance; `commit --force` overwrites an existing image name.

### Fixes

- **OAuth-token users no longer land in Claude Code's onboarding wizard**
  (#87) — Running `iso claude` with subscription auth
  (`CLAUDE_CODE_OAUTH_TOKEN` forwarded into the guest) dropped the user
  into the first-run theme/login wizard, whose login step ignores the
  token. Claude Code gates the wizard on `hasCompletedOnboarding` in
  `~/.claude.json`, which isolate never staged. isolate now seeds that flag on
  boot when an OAuth token is forwarded and the flag is not already set.
  Idempotent and a no-op for API-key and no-credential users. Reverts
  when anthropics/claude-code#8938 is fixed upstream.

- **Installed Claude plugins survive a stop/start cycle** (#350) —
  `write_managed_claude_settings` rewrote `~/.claude/settings.json` from
  scratch on every boot with only a `permissions` block, deleting the
  `enabledPlugins` and `extraKnownMarketplaces` keys Claude Code uses to
  track installed plugins and marketplaces. Plugins installed on first
  boot then showed as uninstalled in `/plugins` after a restart. isolate now
  merges its managed `permissions` into the existing file, preserving
  those keys.

- **`~` is expanded in every `config.toml` path field** (#349, #351) — A
  leading `~` was only expanded for `claude.config_dir`,
  `codex.config_dir`, and `claude.marketplaces`; other host-path fields
  (`data_dir`, `firecracker_bin`, `vm.kernel_path`, per-profile
  `marketplaces`) kept a literal `~`, so e.g. `data_dir = "~/iso-data"`
  resolved to a literal `./~/iso-data` directory. Expansion now happens
  at deserialization via a `ConfigPath` newtype, so every path field —
  including ones added later — is expanded on every load path.

## v0.5.1

### New features

- **`iso ssh-config` — install a `iso-<name>` SSH alias** (#294) —
  Writes the same `~/.ssh/config` block `iso vscode` produces, but
  without launching an editor, so plain `ssh`, `scp`, and `rsync` reach
  the guest by alias. `--clean` removes the block. The alias now
  survives `iso stop` and is refreshed on `iso start` (the Lima SSH
  port changes per boot), so it stays valid across restarts;
  `iso destroy` and `--clean` remove it.

- **`iso setup --builder-timeout <duration>`** (#315) — bounds how long
  setup waits for image-build commands before timing out. Accepts bare
  seconds or an `s`/`m`/`h` suffix (e.g. `60m`, `2h`). Applies across
  both backends.

### Removed

- **`scripts/build-rootfs.sh`** (#293) — the standalone `debootstrap`
  rootfs builder is removed. Image creation runs through `iso setup`,
  which downloads a Firecracker CI squashfs and provisions it with
  `scripts/guest/guest-config.sh`; the standalone script duplicated that
  provisioning, omitted the CI-kernel workarounds (iptables-legacy,
  static `resolv.conf`, Docker's `DOCKER_INSECURE_NO_IPTABLES_RAW`), and
  produced an image the current flow does not consume. The rootfs
  discovery error no longer points at it.

## v0.5.0

### Breaking changes

- **`iso build` removed; creation flags moved off `iso start`** (#269,
  #281) — `iso start` no longer accepts `--profile`, `--git-repo`,
  `--vcpus`, `--mem`, `--disk`, `--mount`, `--image`, or `--exclude-git`;
  those flags now live on `iso up`. clap reports them as unexpected
  arguments instead of accepting them and bailing at runtime. The
  standalone `iso build` command and the `scripts/fetch-kernel.sh`
  helper are removed — `iso setup` and `iso up --profile` cover image
  creation end-to-end. `scripts/build-rootfs.sh` stays as a documented
  manual fallback. Restart still works against existing instances; the
  flags above only take effect at create time (via `iso up`).

- **`--git-repo` moved from `iso start` to `iso up`** (#264) —
  `iso up --git-repo <url>` clones a remote repository into
  `/workspace` and is idempotent across re-runs, matching the rest of
  `up`: an instance already associated with the URL is reused if
  running, restarted if stopped, and created otherwise. The instance
  name is derived from the repo basename when `--name` is not given.

- **tmux session wrapping removed** (#183, #184) — `iso shell`,
  `iso claude`, and `iso codex` no longer wrap the remote session in
  tmux, and the `--session <name>` / `--no-tmux` flags are gone. The
  `tmux` package is also dropped from the guest base image. Claude
  Code's `claude agents` daemon (`iso claude-agents`) already
  provides session persistence without a terminal multiplexer; users
  who still want detachable terminals can install tmux themselves via
  `iso setup --extra-packages tmux` and start it manually inside
  `iso shell`.

- **Devcontainer auto-discovery prompts on `up` / `setup --workspace`**
  (#129, #130, #242) — When the workspace contains
  `.devcontainer/devcontainer.json` and no escape hatch flag is set,
  isolate prompts before applying it. Non-TTY callers must pass
  `--devcontainer <path>`, `--no-devcontainer`, or `--dry-run`; the
  prompt never silently chooses. Precedence is
  `CLI > devcontainer.json > defaults`, and the report column makes
  overrides explicit.

### New features

- **`iso up` — project-oriented environment command** (#230, #264) —
  `iso up [DIR]` ensures an environment for a project directory
  exists and is running, idempotently. `DIR` defaults to the current
  directory and is canonicalized for affinity; a matching instance is
  reconnected if running, restarted if stopped, or created otherwise.
  `--git-repo <url>` uses a remote repository as the workspace instead
  of a local directory. Creation-time flags (`--vcpus`, `--mem`,
  `--disk`, `--image`, `--profile`, `--extra-mount`,
  `--devcontainer`, `--exclude-git`) only take effect when the
  instance is created and are rejected against existing instances with
  a `iso destroy` hint; runtime flags (`--forward-port`,
  `--post-start`, `--env`) take effect on create or restart but are
  ignored when reconnecting to a running VM.

- **`iso quickstart` — one-shot setup + start + claude** (#74, #213)
  — Chains `ensure-image → ensure-instance → launch-claude`,
  short-circuiting any step that's already done. Setup runs only when
  the `default` template image is missing; workspace affinity
  reconnects to a running instance for the current directory (or
  restarts a stopped one) instead of allocating fresh. `--no-workspace`
  opts out of the cwd mount; sensitive directories (`$HOME`, `/`)
  prompt default-no on a TTY and bail non-interactively.

- **`devcontainer.json` support** (#129, #130, #131, #134) — A new
  translator maps recognised keys to isolate's existing primitives:
  `hostRequirements` → `--vcpus`/`--mem`/`--disk`, `containerEnv` →
  guest env, `forwardPorts` → `--forward-port`, `postStartCommand` →
  `post_start`, `features` → built-in profiles, `mounts` →
  `--mount`, `remoteUser` → `--guest-user`. New flags on
  `setup` / `up`: `--devcontainer PATH` (opt in to a specific file),
  `--no-devcontainer` (opt out entirely), and `--dry-run` (print the
  per-key report and exit before any side effects). JSONC (`//`,
  `/* */` comments, trailing commas) parses cleanly. CLI `--env` and
  devcontainer `containerEnv` are persisted to `guest_env.json` so
  `iso shell` / `iso exec` see the same values without re-parsing
  config.

- **OCI devcontainer features** (#245) — Supported public
  `ghcr.io/devcontainers/features/*` entries declared in
  `devcontainer.json` are resolved at `iso setup` and baked into the
  image alongside the existing built-in profiles. `iso up --profile`
  continues to compose the built-in profile set.

- **`iso devcontainer` subcommands** (#234, #247, #287) —
  `iso devcontainer check <path>` translates a `devcontainer.json`
  and prints the report without running any setup or VM work
  (`--stage setup|start|both`). `iso devcontainer ignore <project>`
  persistently opts a project out of discovery; `... status` lists
  current opt-outs; `... clear` removes one. Symlinked project
  prefixes are resolved when clearing, so a directory that was moved
  or unlinked doesn't leave a stale opt-out behind.

- **`iso setup --guest-user` and `remoteUser` handling** (#217, #218)
  — Bake a configurable guest username (default `ubuntu`, validated
  against POSIX rules and not `root`) into the image at setup time.
  `start`/`shell`/`exec` read the value from the image's
  `template_config.json`. A `devcontainer.json` that declares a
  different `remoteUser` is honored when its value matches the
  persisted setup user; mismatches surface an actionable diagnostic
  instead of silently writing a wrong home path. Backward-compatible
  for pre-existing images.

- **`--forward-port` / `forward_ports` config** (#125, #128) — Forward
  guest TCP ports to the host for the lifetime of the VM.
  `iso up --forward-port 3000` exposes guest 3000 on host 3000;
  `3000:18080` remaps to a different host port. The flag is
  repeatable, supported by a config-level `forward_ports = [...]`
  default, persisted across `stop`/`start`, and torn down cleanly on
  `iso stop`. Collision with an already-bound host port fails fast
  before the VM is created.

- **`post_start` hook** (#123, #126) — `post_start` in `config.toml`
  (or `--post-start <cmd>` on `iso up` / `iso start`) runs a shell
  command in the guest after SSH is ready and before any interactive
  shell or agent launch. Maps to `postStartCommand` in
  `devcontainer.json`. Failure is logged at WARN and does not fail
  the start, so a transient hook problem can't strand the VM.

- **`[guest_env]` config block + `--env KEY=VALUE`** (#127, #131,
  #134) — Set literal env vars inside the guest without forwarding
  from the host. CLI overrides win over config and devcontainer
  values; `--env` is persisted to `guest_env.json` so
  `iso shell` / `iso exec` see the same values without rerunning
  `start`. `iso start --env` and `--devcontainer`-derived
  `containerEnv` survive `stop`/`start` cycles.

- **Build profile images on demand from `iso up`** (#235) —
  `iso up --profile <list>` derives an image name from the sorted
  profile list, runs the same stale-image check as `iso setup`, and
  builds or rebuilds that image if needed. Explicit named images
  (`--image`) are unchanged.

- **Submodule discovery in `iso github setup-pat`** (#219, #221,
  #223) — The wizard pre-discovers submodule repositories via the
  local `gh` install (no network round-trip per submodule) and offers
  to set up a PAT for each one.

- **Guest PATH set via `/etc/environment`** (#248, #249) —
  `~/.local/bin` is now reliably on `PATH` for non-interactive SSH
  sessions, including `iso claude` and Claude Code's Bash-tool
  subshells. Previously these sessions skipped `~/.profile` and
  `~/.bashrc`'s PATH export, hiding `uv`/`pipx`/user tools and
  triggering `claude doctor` warnings. `pam_env` reads
  `/etc/environment` for every PAM session regardless of shell mode,
  so the prepend reaches remote commands, their subshells, and
  VS Code remote sessions.

- **Docker buildx in guest images** (#288) — `docker buildx` is
  installed in every isolate image so multi-arch and `buildkit`-driven
  builds work without manual setup.

- **Secrets redacted from `Debug` output** (#79, #121, #262) — A new
  `Secret<T>` newtype with redacting `Debug`, transparent serde, and
  an explicit `expose()` accessor wraps `ClaudeConfig.api_key`,
  `CodexConfig.api_key`, and `PatEntry.token`. MCP header secrets
  and forwarded env values render as `<redacted>` in error chains,
  tracing events, `dbg!`, and panics.

- **Hint at `--workspace`/`--mount` when `start` name looks like a
  path** (#226) — Running `iso start ./my-project` now surfaces a
  hint to use `iso up` (which interprets `DIR` correctly) instead of
  failing with an opaque "instance not found".

- **Warn when `--mount` source is a live git repo** (#102, #122) —
  Live mounts share filesystem state with the host, so in-guest
  changes affect the host checkout immediately. isolate now warns when
  the mount source looks like a working tree.

### Fixes

- **Survive mid-session SSH exit 255 in interactive sessions** (#224,
  #227) — A network blip that produced SSH exit 255 mid-session no
  longer kills the wrapping isolate process; the session reattaches.

- **Interactive SSH escape path hardened** (#232) — Closes a regression
  in escape-sequence handling on the interactive path.

- **`workspace.json` parse errors surfaced** (#225) — Three call sites
  previously swallowed parse errors; all now report them with context.

- **Bare `iso start --mount` allocates a fresh instance** (#214,
  #215) — Earlier this collided with the auto-resolve path and
  produced a confusing error.

- **`iso up` workspace sync no longer drops `--extra-mount` on
  Firecracker** (#264) — The workspace-sync block now always syncs
  extra mounts; only mount-only instances record the workspace
  identity. Also fixes a tar-pipe fallback that extracted to
  `/workspace` regardless of the mount's guest path.

- **`iso start` devcontainer lifecycle ordering** (#241) — Devcontainer
  translation now runs before the SSH-ready probe, so per-key
  reporting reflects what will actually be applied.

- **Skip redundant `is_running()` in stop / stream-logs** (#195,
  #205) — These were probing the running state twice on the
  SSH-readiness path; collapsed to a single probe.

- **Direct-probe `resolve_instance` fast path for by-name lookups**
  (#202, #203, #211, #212) — Defers `IsoConfig::validate` until
  commands that touch probed paths actually need it, and skips the
  generic search when an instance name is supplied.

- **Lima SSH-readiness probe via `ssh.config` instead of
  `limactl list`** (#201, #210) — Cuts a 0.4–1.5 s `limactl`
  invocation off the resolve fast path on macOS.

- **Firecracker CI kernel fallback** (#290) — When the latest
  Firecracker CI minor has no assets published yet (transient
  release-pipeline gap), setup falls back to the previous minor
  instead of failing.

- **Integration tests** — Forward-port test uses a `python3` listener
  instead of `nc` (Firecracker CI rootfs ships no netcat) (#132).
  `test_list_empty` tolerates pre-existing instances on a shared
  host (#133). `--forward-port` collision test reads `$HARNESS_ERR`
  instead of an outer redirect (#135). Devcontainer opt-out test
  assertions match the actual message text (#286). Stop idempotency
  test reuses a stopped instance (#240). Bare `iso start --mount`
  `pipefail`+`grep -q` race fixed (#220).

### Internal

- **VM lifecycle type-state** (#153, #180, #275) — `RunningInstance`
  and `StoppedInstance` carry lifecycle state in the type, eliminating
  runtime state checks on operations like `resize_disk`, `status`,
  and `stop`. The `RunningInstance` proof extends across both
  backends.

- **Newtype / enum survey across module boundaries** —
  `InstanceName` (#192, #199), `RepoSlug` (#149, #171),
  `ImageName` (#157, #181), `Hostname` and `SshUser` (#154, #187),
  `GuestUser` (#217, #218), `ToolName` and `AccountName` (#165,
  #190), `EnvVarName` (#151, #177, #196, #206), `MemorySpec` (#163,
  #188), `MiB`/`GiB` (#194, #207), `Sha256Hash` (#161, #189),
  `Architecture` (#169, #173), `PortForward` and `Mount` (#179),
  `HostInterface` (#159, #186), `SubnetMask(u8)` (#150, #176),
  `InstanceIndex` 0..=252 bound (#162, #175), `TmuxSessionName` +
  `RemoteCommand` (#166, #182, later removed with #183),
  `GuestPath` round-trips dropped (#193, #204). Profile names
  resolved at the config boundary (#156, #172).
  `--mount`/`--env`/`--forward-port` and disk size / devcontainer
  path / repo slug parsed by clap value-parsers (#179, #285).
  `redacted_args: Vec<usize>` replaced with typed `Arg` variants
  (#160, #185). `McpServerDef` replaced with a transport-tagged
  enum (#148, #178). `WorkspaceState` optionals collapsed into
  `WorkspaceSource` variants (#170). `restart: bool` and
  `follow: bool` replaced with two-variant enums (#174).
  Correlated `bool` fields replaced with enums (#266, #280).
  `cmd:` string reverse-parsing replaced with a structured
  `CmdToken` (#277). Guest-env precedence merge unified (#276).
  PAT repo probe typed with a `ProbeError` enum (#282). Dead
  wrappers removed and over-broad visibility tightened (#283).
  Near-identical function pairs extracted into shared helpers
  (#284). Newtypes threaded through boundaries instead of decaying
  to `String` (#279). A four-PR survey of smaller newtype / struct
  refactors (#191).

- **Mutation-testing baseline on `config.rs`** (#136, #137, #138,
  #139, #140, #141, #143, #144, #145, #146) — Adds the
  mutation-testing guidance now in `CLAUDE.md`, pins
  `IsoConfig::validate`, `Instance::is_running`,
  `is_firecracker_process`, and `MiB::as_gib_f64` with tests, and
  annotates equivalent mutants (`fmt::Display` impls, default-value
  getters, serde `Visitor` methods) with `#[mutants::skip]` and a
  one-line justification.

- **Port-forward integration test covers restart re-establishment**
  (#260).

- **`[guest_env]` config block integration phase** (#263).

- **OCI devcontainer feature install integration phase** (#261).

### Documentation

- **`iso up`, `iso quickstart`, and the devcontainer workflow**
  documented in `docs/commands.md`, `docs/getting-started.md`, and
  `docs/devcontainer.md` (#213, #230, #234, #257).

- **Guest user, guest PATH, and startup flag pointers** (#259).

- **Submodule discovery in setup-pat wizard** (#258).

- **Mutation-testing guidance** (#136) added to `CLAUDE.md`.

### Dependencies

- `serde_json` 1.0.149 → 1.0.150 (#228)
- `zizmorcore/zizmor-action` 0.5.3 → 0.5.5 → 0.5.6 (#198, #229)

## v0.4.4

### Breaking changes

- **`iso push` / `iso pull` / `iso exec` take the instance name as a
  positional argument** (#90) — these three commands previously accepted
  `--name <name>` while the other eleven subcommands took `name`
  positionally. The flag is removed; pass the name positionally instead.
  Because `push` and `pull` already had `[DIR]` as a positional, the
  directory is now a `--dir` flag. Because `exec` had `COMMAND...` as a
  positional, the command must follow `--`. Examples:
  `iso push my-vm --dir ./src --force`,
  `iso pull my-vm --dir ./out --force`,
  `iso exec my-vm -- ls -la`.

### New features

- **`iso ca` / `iso claude-agents` shortcut** (#80, #82, #99, #100, #101) —
  Runs `claude agents` inside the VM in one command. Claude Code's daemon
  manages background-session lifetime itself, so closing the terminal
  does not interrupt running agents. The guest is now bootstrapped with
  a managed `~/.claude/settings.json` that pre-accepts
  `bypassPermissions`, so dispatched sessions no longer prompt for
  tool permissions; `iso claude --ask` explicitly opts back into the
  prompting default.

- **`iso github setup-pat` wizard** (#85, #88) — Walks the user
  through creating a fine-grained personal access token scoped to one
  repo, stores it in the user's preferred secret store (Keychain,
  Secret Service, 1Password, or file), and forwards it to the guest as
  `GITHUB_TOKEN` keyed off the resolved repo slug. Adds a new
  `github = "pat"` config mode.

- **`iso list` / `iso ls`** (#89, #94) — Local-only enumeration of
  instance name + state. Reads on-disk metadata and `be.is_running`
  without SSH probes so it stays fast even when VMs are unreachable.
  `iso status` keeps its richer per-instance and resource-usage
  output.

- **`iso uninstall`** (#93, #96) — Reverses what `install.sh` does:
  removes the running isolate binary and, with confirmation, the data
  directory (`~/.iso`) and XDG update-check state. Flags
  `--yes` / `--keep-data` / `--purge`. Refuses to delete
  `target/{debug,release}/iso` and surfaces EPERM with a
  `sudo iso uninstall` hint. Bails on non-TTY stdin without `--yes`
  so CI misuse fails loud.

- **Shell completion** (#92, #98) — `iso completions <shell>` prints
  a static completion script for bash, zsh, fish, powershell, and
  elvish. Adding `source <(COMPLETE=<shell> iso)` to a shell rc
  additionally fills in live values via clap_complete's dynamic
  engine — instance, image, and profile names are read from `~/.iso`
  on each TAB.

- **`--git-repo` clones authenticate against private GitHub repos**
  (#78, #119) — On the host, resolve a token in order: a configured
  `[github.pat."<slug>"]` entry for the repo, then `gh auth token`,
  then `GITHUB_TOKEN`. Forward it to git in the guest via stdin and
  a one-shot `credential.helper`. The token never appears on argv,
  stays out of `/proc/<pid>/cmdline` and the ssh debug log, and is
  not persisted in the cloned repo's `.git/config`. Opportunistic:
  GitHub HTTPS URLs only; non-GitHub and SSH-style URLs pass through
  untouched. A misconfigured PAT entry fails at start time rather
  than silently substituting a broader identity.

- **`.git/` included in workspace transfers by default** (#95) —
  `iso start --workspace`, `iso push`, and `iso pull` previously
  hardcoded `.git/` into the default exclusion list, breaking
  in-guest git history and rendering `check_guest_dirty` a no-op.
  Now transferred by default, with an `--exclude-git` opt-out on
  `start` / `push` / `pull` for repos large enough that the transfer
  cost dominates. `check_guest_dirty` also now detects unpushed
  commits (`@{u}..HEAD`) so in-guest commits aren't silently
  destroyed by a host push.

### Fixes

- **`integration-uninstall.sh` state path on macOS** (#106) —
  `dirs::state_dir()` returns `None` on macOS, so `state_path()` in
  `src/update.rs` falls back to `~/Library/Application Support/iso/`.
  The test seeded `$XDG_STATE_HOME/iso/update-check.json` but the
  binary never wrote there, so the `--purge` assertion failed. The
  test now uses the same platform branching the binary does.

- **SIGPIPE flake in bash completion integration check** (#105) —
  `echo "$HARNESS_OUT" | grep -q "iso,$sub"` against the ~48 KB
  completion script flaked under `set -o pipefail`: when `grep -q`
  matched early it closed the pipe, bash's `echo` builtin exited 141
  (SIGPIPE), and the pipeline status masked `grep`'s success (~60%
  of trials on Linux 6.17 / bash 5.2.21). Replaced the pipe with a
  here-string.

- **`destroy --all` integration phase gated behind
  `ISO_TEST_DESTRUCTIVE=1`** (#104) — `iso destroy --all` removes
  every iso-managed instance on the host, not just the ones the
  test created. The phase is now skipped by default; remote mode
  forwards the opt-in env var explicitly.

### Internal

- **`open_ssh_session` helper extracted** (#81, #83) — The five-line
  `resolve_running` + `prepare_env_forwarding` + `SshSession` setup
  repeated across Claude, ClaudeAgents, Codex, plus `cmd_shell` and
  `cmd_exec`, collapses to a single `open_ssh_session` call.
  `SshSession` is now owned rather than borrowing target/env;
  removing the lifetime parameter drops `SshSession<'_>` from nine
  downstream signatures. Incidental behavior change: with
  `--no-agents`, a misconfigured `cmd:` secret source no longer
  fails the boot path.

### Documentation

- **Rust authoring + review guidance in CLAUDE.md** (#84) —
  Project-specific patterns for using the type system to eliminate
  error states: parse-don't-validate, smart constructors, type-state
  for the VM lifecycle, newtypes that earn their keep, and error
  design. Includes prioritized review and authoring checklists.

### Dependencies

- `cargo-bins/cargo-binstall` 1.18.1 → 1.19.1 (#86)

## v0.4.3

### Fixes

- **`iso update` works on the private/internal `trailofbits/coop` repo**
  (#70, #71) — Previously the in-binary update shelled out to bare
  `curl`, which the GitHub API answers with 404 for unauthenticated
  requests against private repos, surfacing as `curl exited with exit
  status: 22`. The update path now authenticates the same way
  `install.sh` already did: prefer `gh` (when installed and authenticated
  against `github.com`), fall back to `GITHUB_TOKEN`, then bare curl
  (which works once the repo is public).

- **GitHub token no longer appears on argv** (#71) — Both `src/update.rs`
  and `install.sh` now feed the `Authorization` header to curl on stdin
  (`curl -H @-`) instead of as a command-line argument, so
  `$GITHUB_TOKEN` is no longer visible in `/proc/<pid>/cmdline` or in
  `iso -v update`'s tracing debug log.

### Documentation

- README and `docs/commands.md` note that `iso update` requires `gh` or
  `GITHUB_TOKEN` while the repository is private (#71).

## v0.4.2

### Fixes

- **SSH connections respect `IdentitiesOnly`** (#68) — When `ssh-agent`
  holds many keys, ssh offered all of them before the explicit `-i` key,
  hitting sshd's default `MaxAuthTries=6` and producing "SSH not ready"
  on `iso start`. SSH/SCP/rsync invocations and the generated
  `~/.ssh/config` block now set `IdentitiesOnly=yes`, matching Lima's
  own probes.

- **Workspace tar-pipe transfer** (#66, #67) — Surface SSH stderr (with
  a `iso start --disk` hint when the message mentions "no space left
  on device") instead of a generic "tar archive truncated" error. Peak
  guest disk usage during transfer is now the extracted tree, not 2× —
  the temp-file/SHA-256 dance was redundant since SSH already MACs the
  channel. Dedicated background threads drain remote and local tar
  stderr to prevent deadlocks when warnings fill the 64K pipe buffer
  during extraction.

- **Integration test no longer pollutes user state** (#63, #64) —
  `tests/integration-update.sh` redirects `$HOME` and XDG vars to a
  tempdir before invoking isolate, so the synthetic `v9.9.9` release
  served by the test fixture no longer lands in
  `~/.local/state/iso/update-check.json` and surfaces as a bogus
  update notification on later runs.

### Dependencies

- `libc` 0.2.185 → 0.2.186, `semver` 1.0.27 → 1.0.28 (#65)

## v0.4.1

Re-release of v0.4.0. The v0.4.0 tag did not produce release artifacts
because `tests/integration-update.sh` Test 4 ("dev build refusal") fails
whenever CI runs on a commit tagged `v{cargo_version}` — `build.rs`
correctly bakes `ISO_BUILD_KIND=release` for that commit, so the test's
unset-override path produced a release binary instead of a dev one. Test 4
now sets `ISO_FORCE_BUILD_KIND=dev` explicitly, mirroring Test 1's
`=release` override. No functional changes to `iso` itself since v0.4.0.

## v0.4.0

### New features

- **Codex CLI support** (#44, #49) — `iso codex` launches OpenAI's Codex
  inside the guest, alongside Claude Code. `~/.codex` config and auth are
  staged into the VM, `OPENAI_API_KEY` is forwarded, and MCP servers
  configured under `[codex.mcp_servers]` are merged into the guest's
  `~/.codex/config.toml`. A `codex-yolo` guest alias mirrors the existing
  `claude-yolo` shortcut. Thanks to Artem Dinaburg for contributing the
  initial Codex integration.

- **`iso update`** (#34, #55) — Self-updates the isolate binary from GitHub
  Releases. Downloads the tarball matching the host triple, verifies
  SHA-256 against the release's `SHA256SUMS`, and (when `gh` is installed)
  verifies the build-provenance attestation before atomically replacing
  the running binary. Flags: `--check` (probe only), `--force` (reinstall
  same version), `--version <tag>` (pin), and `-y`/`--yes` (skip
  confirmation). Dev builds refuse to self-update; re-run `install.sh`
  to replace them.

- **Background update-check notifications** (#55) — On every command,
  isolate reads the persisted state in `$XDG_STATE_HOME/iso/update-check.json`;
  if a newer release is known, isolate prints a one-line notice to stderr.
  The refresh runs in a detached thread and never blocks the command.
  Disable globally with `updates.mode = "off"` in `config.toml`, or
  per-invocation with `ISO_NO_UPDATE_CHECK=1`. The check stays silent
  when `CI=true` or when stdin is not a TTY.

- **`install.sh` verifies build-provenance attestations** (#56) — When
  `gh` is installed, the installer runs `gh attestation verify` after
  the SHA-256 check, matching `iso update`. Without `gh`, both paths
  fall back to checksum verification and print a note describing what
  the checksum covers and what attestation verification would add.
  README documents the manual `gh attestation verify` one-liner.

- **`iso --version` includes git metadata** (#55) — Release builds
  display the short commit sha (e.g. `iso 0.3.1 (a1b2c3d)`); dev builds
  add `-dev` and a `+dirty` suffix when the working tree has
  uncommitted changes.

### Deprecations

- **`--no-claude` is deprecated** (#49) — Use `--no-agents` instead.
  The old flag still works as a hidden alias and emits a runtime
  warning. A future release will remove it.

### Dependencies

- New: `semver` 1
- Cargo dependency updates (`clap`, `indexmap`, `libc`)
- GitHub Actions bumps (`actions/cache`, `actions/upload-artifact`,
  `cargo-bins/cargo-binstall`, `zizmorcore/zizmor-action`)

## v0.3.1

Re-release of v0.3.0. The v0.3.0 release artifacts failed to publish because
the release workflow conflicted with a pre-created GitHub release. Release
notes are now sourced from `CHANGELOG.md` so the workflow owns the full
release end-to-end.

No functional changes since v0.3.0.

## v0.3.0

### Breaking changes

- **`ssh` subcommand renamed to `shell`** (#25) — `iso ssh` is now `iso shell`.
  A hidden `ssh` alias exists for backward compatibility, but scripts and docs
  should migrate to `shell`.

- **`full` meta-profile removed** (#31) — `--profile full` no longer exists.
  Use `--profile python,node,c,fuzz,rust,go` explicitly.

- **Instance names derived from workspace path** (#33) — `iso start --workspace
  <path>` without `--name` now derives the instance name from the directory
  basename (e.g. `~/projects/myapp` → `myapp`). Existing stopped instances
  created under the old numeric naming scheme won't match by workspace affinity.
  Destroy and recreate them, or reference by their old name explicitly.

- **`start` rejects creation-time flags on restart** (#24) — Passing `--mount`,
  `--workspace`, `--git-repo`, or `--disk` when restarting a stopped instance
  now errors instead of silently dropping those flags. Destroy and recreate the
  instance to change these settings.

### New features

- **`iso profiles list` / `iso profiles show`** (#31) — Discover builtin and
  custom profiles without reading source or config. Bare `iso profiles`
  defaults to `list`.

- **`--session <name>` flag for `shell` and `claude`** (#25) — Named tmux
  sessions enable parallel interactive sessions against the same VM.

- **Workspace affinity** (#33) — `iso start --workspace <path>` finds and
  restarts a stopped instance that previously used that workspace instead of
  creating a duplicate.

- **`cmd:` prefix for secret manager integration** (#35) — Config values for
  `claude.api_key` and MCP server headers support `cmd:<command>` syntax. The
  command runs at VM start time (10s timeout) and stdout becomes the resolved
  value. Works with 1Password, `aws secretsmanager`, etc.

- **`push`/`pull` without prior `--workspace`** (#26) — `iso push` and
  `iso pull` now work even if the instance wasn't started with `--workspace`,
  syncing the current directory.

### Fixes

- **Lima v2.1.0 support** (#38) — Handle the `diffdisk` → `disk` rename in
  Lima v2.1.0. Falls back to `diffdisk` for older versions.

- **HTTPS for chroot apt sources** (#39) — Guest package installation uses
  HTTPS mirrors.

### Dependencies

- `sha2` 0.10.9 → 0.11.0
- Cargo dependency updates (`clap`, `serde`)
- `actions/upload-artifact` bump in release workflow

## v0.2.5

Initial public release.
