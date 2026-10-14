<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Changelog

## Unreleased

## v0.5.0

- **Authorization policy**: an optional top-level `policy` (mode `off`,
  `shadow` or `enforce`) adds default-deny permit/forbid rules for
  `credential.use`, `proxy.request` and `workspace.pull.apply`, plus two
  guards: a sliding-window limit on requests admitted by the credential proxy
  (`429` with `Retry-After` when exhausted) and an inline, single-use approval
  of the exact stage at `iso pull --apply`. The policy is fixed per VM boot;
  `iso policy show` reports the active snapshot. An enforcing boot never
  relaunches its proxy, so quotas cannot be reset mid-boot. The shared
  evaluator is the new `iso-policy/` library package; policy-enabled proxies
  use startup protocol version 3 with signed readiness. See `docs/policy.md`.
- **Remote agent MCP headers**: `iso host agent` no longer stages MCP
  servers from the client's own `~/.codex/config.toml` that set
  `http_headers`, and every remote agent run rewrites the guest's Codex
  config, so header values an earlier build wrote there are removed on the
  next run rather than only when the config otherwise changed. See
  `docs/commands.md#host`.
- **Host service migration**: stopping the local host service (as
  `iso host migrate` does) now waits until the service process has released
  its lock, so a following start reaches a new service instead of the exiting
  one.

## v0.4.0

- **Remote execution hosts**: `iso host` runs Linux VMs on another trusted
  Apple Silicon Mac. `iso host add NAME --ssh ALIAS --agent-path PATH` enrolls
  a Mac over pinned SSH after verifying its installation identity; `list`,
  `inspect`, `disable`, `enable` and `remove` manage enrollments. On an
  enrolled host, `iso host image`, `vm create|start|stop|destroy|list|inspect`,
  `up`, `shell`, `session`, `push`, `pull`, `agent`, `editor`, `forward`,
  `run` and `operation` build images, manage VMs and reach them through a
  host-owned relay. Accepted operations are durable, and after a lost reply
  they can be retried with `--operation-id`; an unreachable host reports
  `unknown`, never `stopped`; remote
  boots always have a deadline (`--ttl`, default 8h). Provider credentials stay
  in the client's proxy. The remote Mac needs `iso setup` and the same `iso`
  build. Remote agents reach provider credentials only through this client's
  proxy and do not get MCP servers whose headers iso resolves; header values
  written to a remote VM by an earlier build are removed when Codex's config
  is next rewritten. Configure hosts under the new global `execution` section. See
  `docs/commands.md#host`, `docs/configuration.md#execution-section` and
  `docs/trust-model.md`.
- **Local host service**: `iso host migrate local --activate` hands stopped
  Linux instances to a per-user host service, after which they are managed as
  `iso host vm … local NAME`; `--rollback` undoes an incomplete migration.
  Older `iso` builds refuse an activated data root.
- **Machine interface**: `capabilities` adds a static `host_control` member,
  and `list --all-hosts` returns local and remote rows with `host` and
  `reachability`, listing hosts that could not be reached in `host_failures`.
- **Installer**: `install.sh` refuses `VERSION=v0.1.x`/`v0.2.x`, which predate
  `iso-macos-helper`, and prints the command that uses the installer from that
  release's tag.
- **Sandbox networking**: a sandbox now boots while vmnet still holds many
  subnets for owners that died uncleanly. The runtime tried at most 32
  subnets and could revisit ones it had already tried, so after enough
  crashes every new sandbox, including the one `iso setup` uses to verify
  an image, failed with `failed to create vmnet network` until reboot. It
  now tries each free subnet once.
- **SSH readiness**: every wait for a VM's SSH (`iso up`, `start` and the
  host service's `iso host vm create` and `start`) now cuts off each attempt
  after 20 seconds and retries, instead of spending the whole boot timeout on
  one stalled attempt. When no attempt completes, the error names macOS Local
  Network privacy, which holds back the launchd host service's connections
  until the `iso` binary is allowed under System Settings → Privacy & Security
  → Local Network. See `docs/commands.md#host`.

## v0.3.0

- **macOS guests**: `iso setup --guest macos --ipsw <restore image>` builds a
  macOS image from an Apple restore image you supply, provisioned with the
  `iso` guest user, `/workspace`, the Command Line Tools, a checksum-pinned
  GitHub CLI, Claude Code and Codex. Instances are per-instance clones with
  their own machine identity, SSH host key and network; `up`, `start`, `stop`,
  `destroy`, `shell`, `exec`, `status`, `claude` and `codex` work as for Linux
  guests. Linux-only options, disk resizing, snapshots, `iso logs` and Codex
  ChatGPT auth are refused for macOS guests. See
  `docs/images-and-profiles.md#macos-guests`.
- **Release archive**: adds the `iso-macos-helper` companion. `install.sh`
  and `iso update` install it with the other companions and refuse an archive
  without it, so `install.sh` from `main` needs this release or later.

## v0.2.0

- **Sandboxed editors by default**: `iso code`, `iso zed` and `iso editor` run
  the verified, signed editor application as a new instance in a
  deny-by-default Seatbelt enclave with a throwaway profile, none of the
  caller's environment, a per-session SSH key reached through an `iso`-owned
  loopback tunnel, and no access to host files, the keychain, the clipboard,
  other apps, local services or the internet. `iso` supervises the session and
  ends it when the editor quits, on Ctrl-C, or when the instance stops or loses
  its readiness proof. `editor.allow` / `--editor-allow` grant `clipboard` or
  `internet`; `editor.security` / `--editor-security unsafe` restores the
  editor CLI launch (now with a scrubbed environment and a boundary warning).
  Machine output reports the editor's security class and grants. A sandboxed
  VS Code needs the Remote - SSH extension installed in VS Code. See
  `docs/editor.md` and `docs/trust-model.md`.

## v0.1.0

### Agent sessions

- **Machine interface**: a global `--output json` emits one versioned
  `iso.machine/v1` document on stdout for `capabilities` (new), `list`,
  `status`, `up`, `start`, `stop`, `destroy` and `ssh-config`, with stable
  error codes and no prompts (a needed decision fails as
  `INTERACTION_REQUIRED`). `ssh-config` returns the managed alias, never key
  material. Text output and command-local `--json` are unchanged. See
  `docs/machine-interface.md`.
- **`iso code` and `iso zed`**: create, restart or reuse a project's
  instance exactly as `iso up` does, refresh its pinned `iso-<name>` SSH alias,
  then open it in Visual Studio Code or Zed. Each launches only its own editor.
- **Filtered address policy** parses IPv6 numerically, rejects unsupported
  transition and special-purpose ranges, and recognizes host-interface addresses
  across equivalent IPv6 spellings. The conservative policy is pinned to the
  IANA registries dated 2025-10-09.
- **Filtered allowlist changes** apply on the same VM after an explicit stop
  and successful start. Running boots retain their policy, failed boot validation
  preserves it, and the instance's egress mode remains fixed at creation.
- **Filtered workload handoffs**: shell, exec, Claude, Codex and `iso run`
  recheck authenticated readiness after environment preparation and just before
  SSH launch, retaining the original boot/policy and signing identities. A healthy
  replacement does not authorize reuse of a prepared session. Bootstrap remains
  transport-only; administrative SSH and workspace-transfer targets now retain
  and recheck the same original identity before guest operations. Readiness
  refusals propagate through hooks and agent updates.
- **`unhealthy` instance state**: `iso status` reports a running filtered
  instance whose live readiness proof fails as `unhealthy`, with the failed
  proof as its reason, instead of failing; `iso list` checks the host side of
  the same proof without connecting to the guest. Machine output adds the
  `unhealthy` state, a nullable `reason` on status entries, and the
  `INSTANCE_UNHEALTHY` error code for commands that need a healthy instance.
- **Startup order**: a first boot or restart refreshes the managed SSH alias
  and starts `--forward-port` forwards only after bootstrap has proved the
  instance (for filtered egress, the composite readiness proof), and `iso up`
  proves a running project instance before reporting it reused.
- **Local-model tunnels in the filtered proof**: every local-model reverse
  tunnel started during the current boot must still be its recorded `ssh` process for
  this guest and a destination the model configuration wants
  (`FILTERED_MODEL_TUNNEL_NOT_READY` otherwise), so losing one refuses new
  handoffs and makes the instance `unhealthy`.
- **Reverse-tunnel identity**: each credential-proxy, egress and local-model
  reverse tunnel records its master PID, unique control path and guest
  destination, and every readiness proof requires the recorded PID
  to still be that exact `ssh` master for this guest; a reused PID or another
  `ssh` no longer passes. Filtered instances started by an older `iso` report
  `unhealthy` until restarted.
- **Supervised filtered sessions**: while a shell, exec, Claude, Codex or
  `iso run` workload runs on a filtered instance, `iso` repeats its readiness
  proof every ten seconds and ends the session after two consecutive
  failures. The per-boot egress lease stops renewing, so the grant expires,
  and closes the instance's port forwards, once a companion or egress tunnel
  it has seen is missing for three consecutive checks.
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
  unapproved CONNECT denial, and direct Internet TCP denial. Real-VM
  qualification covers signed brokers, revocation, socket pressure, IPv4/IPv6
  peer isolation, and live Claude and Codex tool use with no approved CONNECT
  destinations (see `docs/testing.md`). The companion reads
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
  provider forwarding rules are unchanged.
- **Filtered CONNECT** requires a complete, bounded head, rejects malformed headers
  and conflicting or duplicate Host authorities, and leaves coalesced tunnel bytes
  on the socket. Refusals and successful handshakes use lease-aware, SIGPIPE-safe
  writes with a one-second monotonic deadline. A failed handshake never starts
  the relay. Local socket, confined-process and mutation gates cover these paths.
- **Filtered relay** drains queued bytes before forwarding half-closes, permits
  the opposite response direction, and stops on hard I/O errors instead of
  dropping data and continuing. Interrupted I/O is retried; paused hung-up
  sources do not spin under backpressure. Local socket and mutation tests cover
  these paths.
- **Filtered lease state** uses typed PID/date decoding and bounded regular
  control-file reads without following symlinks. Invalid identities, malformed
  deadlines, and lock-probe errors stop renewal; only an absent/null deadline
  permits unlimited TTL.
- **Apple owner startup** explicitly requests the bootstrapped launchd job
  without killing an already-started owner. A loaded but deferred `RunAtLoad`
  job no longer stalls first boot. Failed requests attempt to unload the job
  and preserve cleanup errors. Owners run in the background user launchd domain
  so a locked GUI session does not defer automatic respawn. Recovery qualification
  separately checks a new owner PID after SIGKILL; explicit startup alone does
  not establish that behavior.
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
- **Claude Code installer download** bounds each attempt (15-second connect,
  120-second total) and reports curl's real exit status when retries fail;
  it previously always reported 0.

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
