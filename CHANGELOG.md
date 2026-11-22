<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Changelog

## Unreleased

### Added

- **Guarded local inference:** `iso-inference`, a per-user host gateway,
  puts a policy boundary between guests and a host-side local model server.
  With `inference.mode: "required"` and an agent's `local_model: { "service":
  NAME }`, each running VM gets one gateway session with a fresh capability.
  The gateway accepts only the service's granted API routes (Chat
  Completions, Responses, Anthropic Messages) and a closed set of request
  fields, rebuilds each request for a fixed loopback backend and model,
  clamps output limits, and enforces per-session and shared budgets. Under
  `required`, no provider credential, credential proxy or raw model tunnel
  reaches the guest, and no failure falls back to a raw endpoint or the
  cloud. It is for Linux guests on either transport; macOS guests are
  refused. On `vmnet` the sandbox runtime relays the session into the guest
  over vsock. On the default `brokered` transport the boot's network policy
  names one `inference-gateway` local service, and iso carries the session
  over one fixed `ssh -R 127.0.0.1:11788:<session socket>` forward on the
  instance's pinned SSH connection, started after the guest is configured
  and closed by every revocation; the gateway binds the session to that
  forward's process. The forward is always `/usr/bin/ssh` (never an `ssh`
  from `PATH`, in debug builds too) and holds at most 32 guest connections
  at once: the gateway accepts 16 per session and a `forward` session's
  socket has a listen backlog of 16. A forward that exits revokes the
  instance as `iso inference revoke` does, until the VM restarts or `iso
  inference attach` grants it again; iso never silently registers a new
  session over a new forward. Agents use `http://127.0.0.1:11788` on both. See the
  [`inference` section](docs/configuration.md#inference-section) and the
  [design](docs/design/secure-local-inference-spec.md).
- **`iso inference` commands** ([reference](docs/commands.md#inference)):
  `status`, `doctor`, `attach`/`detach` (a service grant for applications,
  exposed as `ISO_INFERENCE_BASE_URL`, `ISO_INFERENCE_MODEL` and
  `ISO_INFERENCE_TOKEN`), `revoke`, `requalify [--restart]`,
  `stop [--force]`, and `init`, which writes a hardened configuration for a
  managed mlx-lm backend and leaves `network.transport` as configured. `provision`, `deprovision` and `restart-backend`
  manage that backend: a confined LaunchDaemon running as the
  `_isoinference` role account, authenticated with a token kept in the login
  Keychain, each with one `sudo` step. `iso uninstall` stops the gateway and
  names any managed backends left to deprovision.
- **Apple runtime protocol 6:** `iso-sandbox create --inference-relay` and
  `start --inference-relay on|off` relay the gateway's per-sandbox Unix
  socket into a Linux guest over vsock (host port 7803, at most 32
  connections at once, refused for brokered sandboxes), and `inspect`
  reports it. iso requires protocol 6. In the guest, a systemd socket on
  `127.0.0.1:11788` bridges to the relayed socket.
- **Gateway control protocol 3:** `register_session` declares the session's
  transport kind. `owner` (vmnet) activates bound to the registered sandbox
  owner; `forward` (brokered) activates bound to a live `/usr/bin/ssh` of the
  same user at the declared start time, while the owner still runs, and is
  revoked when either exits. Version 2 requests are refused.
- **Release archives** carry `iso-inference`.

### Changed

- **Install and update:** `install.sh` and `iso update` install the binaries
  the release's `BUILD.json` lists. Each listed binary must match its
  recorded digest, and `iso`, `iso-sandbox`, `iso-macos-helper`, `iso-proxy`
  and `iso-egress` must be listed. `iso-inference` is installed when listed
  and an installed copy is removed when not; a listed companion the
  installer does not know is installed too. After updating from v0.11.x or
  earlier, run `iso update --force` once to install the gateway.

## v0.11.0

### Security

- **Returned paths that hide a `/`:** a combining mark or joiner right
  after a `/` (or a prepended mark right before it) joins the separator into
  one Swift `Character`, so the host split such paths differently from the
  kernel. A guest could return a symlink such as `d/up -> ../\u{301}/../../x`
  that review counted as inside the workspace but that resolves outside it,
  and archive validation accepted `../\u{301}x` members and link targets.
  `iso pull`, returns and archive validation now refuse any name, link target
  or member that joins a `/` into a neighbouring character.
- **`iso diff` shows returned text exactly:** returned file content is split
  at every line feed and compared byte for byte. A returned `\r\n` could
  print an unmarked line that looked like unchanged context, and canonically
  equivalent edits (`;` to U+037E, NFC to NFD) showed as no change.
- **Workspace returns fold names like APFS:** returned names were compared
  with NFC plus `lowercased()`, which misses folds such as `ſ` (U+017F) → `s`.
  A guest could chain a symlink out of the destination on `iso pull`, or slip
  `.vſcode/tasks.json` past sensitive-path withholding. One shared full Unicode
  case fold (`IsoCore.NameFolding`) is now used by every return and archive
  check; C1 control characters in names and link targets are refused.
- **Guest computer use cannot crash the owner:** a scroll with `dx`/`dy` equal
  to `Int.min` trapped in `abs` and killed the sandbox owner and its VM; it is
  now refused as an invalid action.
- **GitHub tokens stay on github.com:** `gh auth token`, `gh api`,
  `gh release download` and `gh attestation verify` (in iso and `install.sh`)
  pin github.com, so `GH_HOST` or a sole GitHub Enterprise Server login can no
  longer put an Enterprise token into the guest or send it to api.github.com.
  `github: "auto"` clones and devcontainer discovery now prefer `GITHUB_TOKEN`.
- **iso-ci hooks:** `hooks install` refuses a hooks directory that is a symlink
  or lies outside the working tree, names any committed hooks that setting
  `core.hooksPath` would enable and refuses them without `--force`; `uninstall`
  says when and why it leaves `core.hooksPath` set.
- **Sandboxed editor:** when a session ends, every process its sandbox
  confines is ended, including ones that called `setsid()`.
- **Devcontainer Features:** `iso setup` resolves Features before its preview
  and shows each digest and `install.sh` SHA-256; a Feature that cannot be
  installed stops setup, and the guest runs exactly the hashed `install.sh`.
  devcontainer.json is read only as a regular file of at most 1 MiB.
- **Release candidates:** signing and notarization run in their own job, so
  the build-and-test job never holds the signing secrets.
- **Secrets in output:** `--env` parse errors no longer print the value, and
  the local-model auth token prompt no longer echoes.

### Fixed

- Reviewing a pulled workspace no longer reads past each directory entry's
  name (an out-of-bounds heap read AddressSanitizer reported).
- A workspace-return operation (`iso pull`, `--discard`, apply), grant write,
  proxy override or Claude plugin record racing `iso destroy` no longer
  recreates the destroyed instance's directory, which made every later
  `iso up` refuse to allocate.
- The credential proxy refuses request targets containing bytes the upstream
  URL parse would percent-encode (`"` `<` `>` `[` `]` `^` `` ` `` `{` `|` `}`);
  it had forwarded a re-encoded target (`%2F` became `%252F`), so the
  provider saw a different query than the guest sent.
- `iso audit` text output replaces every control character and line or
  paragraph separator in recorded values; a newline followed by a combining
  mark could break a listing line.
- An agent definition's `working_directory` is refused when a `/` is joined
  to a neighbouring combining or prepended mark, which hid `..` from the
  component check.
- `iso start` refuses a fenced instance until `iso stop` reconciles it.
- A restart that fails after a concurrent `iso destroy` no longer recreates
  the instance directory (which blocked every new instance).
- Subprocess deadlines are always enforced (devcontainer Feature downloads,
  `iso update` steps, Keychain writes); `iso update` downloads fail when
  stalled and are capped at 1 h. An attached `ssh` ends when iso gets SIGTERM.
- Host service: each socket has its own connection budget, idle connections
  close after 10 s, a lease that lapses during renewal or relay admission
  closes its relays, closing a session no longer removes the next session's
  guest key, and a service still running an old build is restarted on the
  first `iso host` request after an update; `iso uninstall` unloads it.
- Codex MCP servers get `http_headers` and `env_vars` (Codex ignored `headers`
  and read `env` literally); `type: "sse"` and renaming `env` entries are
  refused for Codex. Claude MCP `env` entries are registered as `${NAME}` so
  servers receive the value, not the name.
- Bootstrap and hook SSH commands no longer consume stdin piped to `iso run`.
- `iso status` probes guest usage with a 15 s deadline, concurrently.
- The Claude plugin IDs that select imported host preferences are kept on the
  host, not in the guest.
- Guest-agent calls of an `exec` have a 30 s host-side deadline.
- The audit checkpoint always fits its headroom; the oldest runs expire
  instead of capture being refused.
- `iso destroy`, `iso uninstall --purge`, host-control delete and
  `iso run --rm` delete the VM's `iso proxy setup --vm` Keychain items;
  `iso github forget-pat` fails and keeps the entry when the delete fails.
- `--help`/`iso help` with `--output json` print help; `--quiet` reaches group
  commands; `INVALID_ARGUMENT` means only a command's own usage error;
  `destroy` reports instances it removed even when later cleanup fails.
- `data_dir` must be absolute; `vault:` in guest-placed secrets is refused at
  load; a FIFO config path no longer hangs; the template's proxy and GitHub
  examples keep the secure defaults.
- devcontainer `mounts` are reported unsupported (they were never applied);
  the `iso run` summary reports the filtered-egress allowlist.
- iso-proxy raises its open-file limit to what its connection limits need.
- iso-ci: GitHub responses are capped while streaming, action archives up to
  64 MiB import, and confined preflight runs restore shared clean cache
  entries.
- CI checks every fault-injection anchor on each push; the nightly skips only
  when nothing but docs changed since its last successful run. Contract
  scripts compare exact exit codes.

### Changed

- **Upgrade notes — configurations now refused at load:** a relative or
  empty `data_dir`; a `vault:` value in `claude.api_key`, `codex.api_key` or
  an MCP header; `type: "sse"` under `codex.mcp_servers`; and a
  `codex.mcp_servers` `env` entry that maps a key to a different name. Each
  refusal names the field. devcontainer `mounts` are now reported as
  unsupported, and the first `iso host` request after updating restarts a
  host service that is still running the old build, ending its live sessions.
- **Upgrade notes — the credential proxy refuses more request targets:** a
  guest request whose target contains a raw `"` `<` `>` `[` `]` `^` `` ` ``
  `{` `|` or `}` now gets a 400 instead of being forwarded re-encoded;
  percent-encode those bytes in the client.
- Tests: seeded property tests now cover the configuration loader,
  `NameFolding`, Codex TOML, the instance lifecycle (against a state model),
  the iso-policy evaluator, iso-egress relaying and CONNECT parsing, and
  iso-proxy request targets, headers and capabilities.
- Performance: workspace re-staging and case-variant link checks are linear;
  audit `--follow` decodes only appended records; the host supervisor indexes
  pending work instead of rescanning its ledger; remote run results download
  in 512 KiB chunks; frame PNGs are encoded off the owner's main actor; the
  egress relay uses a ring buffer; iso-proxy builds one TLS context per
  process; egress and tunnel identity checks read process arguments in
  process instead of running `ps`; iso-ci looks up jobs only for busy runners.
- Fuzz targets cover the egress CONNECT parser and the proxy's request
  target, header policy and capability parsers.
- mise 2026.11.9 is the minimum; the Swift toolchain download is
  checksum-pinned in `mise.lock`. Dependabot covers `www/` and the
  Dockerfiles.

## v0.10.0

### Added

- **Audit of boots that ended on their own:** `boundary.guest_computer_use`
  and `boundary.live_view` were recorded only when `iso stop` stopped a
  running instance, so a boot ended by session expiry, guest poweroff, an
  owner crash or a failed stop left no record. A display or macOS owner now
  writes its changed counts to the sandbox's `boot-counts.json` every 30 s
  and when it stops, `inspect` lists ended boots as `endedBoots`, and the
  next `iso` command that inspects the instance records each boot once
  ([audit](docs/audit.md)).
- **Linux desktop images:** a built-in `desktop` profile (Xorg, openbox
  and fonts from Ubuntu, Firefox alone from Mozilla's pinned apt repository) whose
  instances get a virtio-gpu display and a USB keyboard and pointer, and
  boot a second, separately pinned kernel built by
  `scripts/build-desktop-kernel.sh`. Releases now carry that kernel
  (`vmlinux-desktop`) and `iso-cu-mcp`, the guest MCP server built with the
  Swift Static Linux SDK, and install them beside `iso-sandbox`;
  `apple_container.desktop_kernel` overrides the kernel. The host drives them with
  `iso-sandbox cu` (frames read from the VM view's framebuffer surface,
  input, `wait`, `hold`, the live view), and `computer_use.guest_access`
  now also gives their agents the `iso-cu` MCP server over vsock 7802. The
  runtime adds `init --desktop-kernel`, `create --display virtio` and the
  `linux-display` feature; the isolation gate checks a display instance's
  display, scanout and vsock ports, and headless instances are unchanged
  ([design](docs/design/linux-desktop-virtio-gpu.md)). `iso stop` audits a
  desktop instance's guest computer use and live view as it does a macOS
  guest's. `scripts/build-iso-sandbox.sh` skips `iso-cu-mcp`, with a
  warning, on a host without the swift.org toolchain or the Static Linux
  SDK (`--require-cu-mcp` fails instead).

- **Agent skill:** `skills/iso/`, an Agent Skill for a host coding agent to
  operate `iso` through `--output json`, with staged returns and no credential
  handling ([docs/agent-skill.md](docs/agent-skill.md)). Release archives carry
  it, `INSTALL_SKILL=1 install.sh` installs it into `~/.claude/skills` and
  `~/.agents/skills` (`SKILL_DIRS` overrides), and this repository links it as
  `.agents/skills/iso`.
- **Computer use, screen sync:** macOS frames and actions report a per-boot
  `damageSeq`, and a new `wait` operation (guest vsock 7802 and
  `iso-sandbox macos cu wait`) returns once the display, or a region of it,
  has been quiet for `idleMs` (`settled`, `unchanged` or `timedOut`). The
  guest `iso-cu` MCP server's input tools settle by default
  (`settle_ms`, 250 ms; 0 turns it off), and a new `wait_for_screen` tool
  waits and then takes one screenshot. The owner samples the display only on
  frames, before actions and while a wait runs; one wait runs per sandbox,
  for at most 30 s, and a host hold ends a guest's wait. The boundary audit
  adds `waits` and `wait_outcomes` to `boundary.guest_computer_use`
  ([design](docs/design/computer-use-screen-sync.md)).
- **Computer use, live view:** `iso-sandbox macos cu stream <name>` starts an
  opt-in browser view of a macOS guest and prints a
  `http://127.0.0.1:<port>/#<token>` URL; `--stop` ends it, as do 60 s with
  no viewer and the VM beginning to stop, however that was asked. The owner encodes the display to H.264 with
  VideoToolbox only while a viewer is connected, and the embedded page
  decodes it with WebCodecs. **Take control** takes the host hold (ending
  the guest's session), each input extends it to 60 s, and held keys are
  released on release or disconnect; a paste (at most 2000 characters) ends
  with its viewer's control. This adds a host loopback listener,
  gated by a 256-bit token and exact `Host` and `Origin` checks, whose
  messages are flat, rate limited (pings included) and refused unparsed
  when nested, and whose per-viewer queue is bounded; `inspect`
  reports `liveViewListening` and the audit records `boundary.live_view`
  counts. The stream is Constrained Baseline with a low-delay SPS, so
  browser hardware decoders show each frame as it arrives
  ([design](docs/design/computer-use-live-view.md)).
- **Computer use, frames:** the owner renders the guest display straight at
  framebuffer pixels instead of at the window's 2× backing and scaling
  down, cutting a frame or damage sample from ~75 ms to ~6 ms on a Retina
  host.

### Changed

- **Update:** `install.sh` and `iso update` remove an installed
  `iso-cu-mcp` or `vmlinux-desktop` that the release being installed does
  not carry. After updating from v0.9.0 or earlier, run `iso update --force`
  once so the new updater installs the `desktop` guest files.
- **Guest computer use:** a request line nested deeper than a request can
  be is refused before it is parsed.
- **Release builds:** the release and candidate workflows build the desktop
  kernel in a job on an arm64 Linux runner, because GitHub's hosted macOS
  runners cannot start Apple `container`'s build VM (the candidate workflow
  failed there). `scripts/build-desktop-kernel.sh` takes `--engine
  container|docker` and `--pinned`, and `scripts/build-release.py
  --desktop-kernel DIR` uses a kernel built earlier after checking it and
  its source tarball against the pins.
- **Apple runtime:** the owner of a Linux display sandbox refuses to boot
  if it was started without the AppKit loop that renders the display,
  rather than run a VM whose frames never arrive. The guest computer-use
  and live-view listeners now log how many refusals a minute's limit
  dropped, as the guest-helper listener does. The computer-use sources
  shared by macOS and Linux owners moved to
  `iso-sandbox/Sources/IsoSandboxCore/ComputerUse/`.
- **Apple runtime:** iso-sandbox links `apple/containerization` 0.54.0 (was
  0.45.0) and pins `vminit:0.54.0` by digest; the host qualifies only
  containerization 0.54.0. The runtime keys its init filesystem by
  containerization release (`initfs-<version>.ext4`), so the next `iso setup`
  pulls and verifies the new init image and removes the old one. Linux VMs
  keep the 0.45.0 sizing (requested vCPUs plus one, requested memory plus
  128 MiB): 0.54.0 sizes the VM separately and would otherwise boot every
  VM at its 4 vCPU / 1 GiB default.
- **Dependencies:** swift-crypto 5.0.3, swift-nio 2.104.0, swift-nio-ssl
  2.37.5, and updated GitHub Actions pins.

## v0.9.0

### Added

- **iso-ci:** runner scale-set pools (`provisioning_mode: scaleset`) with
  scale-to-zero, a default-deny job policy checked against GitHub's run record
  before a job is acquired (fork pull requests, public repositories, events,
  actors), one queue across pools with room reservation for the oldest starved
  job, `exclusive_host` profiles that drain their host, owner reservations and
  the two-macOS-VM ceiling counted from iso-sandbox VM leases
  (`~/.iso/run/leases`), per-allocation supervisor processes that keep
  registrations and VM sessions across controller restarts, and `serve
  --record-protocol-trace`. Non-elastic scale sets (all an App can create)
  gate jobs on assignment and start no runner while a refused or unvetted job
  is assigned; public repositories need an elastic scale set. C-T19–C-T22 and
  C-T24 passed live on an organization pool; see the [operator
  guide](docs/ci.md#scale-sets-and-shared-hosts) and the qualification
  record.
- **iso-ci:** `iso-ci hooks install|status|uninstall` writes a `pre-commit`
  or `pre-push` hook that blocks a commit or push to a protected branch
  (default `main`) unless the project's workflow passes in local preflight.
  `iso-ci run --snapshot staged` captures exactly the staged index and refuses
  paths whose working tree differs from it; `--timeout SECONDS` (with
  `--follow`) aborts an unsettled run. See [Running a project's CI from its
  Git hooks](docs/ci.md#running-a-projects-ci-from-its-git-hooks).
- **iso-sandbox:** each VM owner writes and holds a lease file describing the
  running VM (`iso.vm-lease/v1`).
- **macOS guests (experimental, source builds only):** paravirtualized Core
  AI. `"coreai": {"accelerators": ["gpu", "neural_engine"],
  "acknowledge_reduced_host_security": true}` attaches macOS 27.3's private
  GPU/Neural Engine accelerator devices to new instances, on a template built
  with `iso setup --guest macos --coreai`, through `iso-sandbox-coreai`
  (`scripts/build-iso-sandbox.sh --experimental-coreai`), which the release
  archive does not contain. Its private entitlement needs a host with AMFI
  relaxed. Reported as a relaxation by `iso policy effective` and audited as
  `mac.coreai.attached`, `mac.coreai.probe` and `host.security.reduced`. The
  release verifier refuses any `com.apple.private.*` entitlement. See
  `docs/coreai.md`.

### Changed

- **Apple `container` baseline 1.7.1** (was 1.4.1 minimum, 1.5.0 pinned in
  `mise.toml`). The runtime now pins the guest kernel container 1.7.1 installs,
  `vmlinux-6.18.56-208-debug` (Kata 4.3.1, sha256 `98a1005f…f7511`), in place
  of `vmlinux-6.18.15-186`. Existing hosts run `container system kernel set
  --recommended`, then `iso setup`; the kernel is part of the NET-HANDOFF-1
  tuple, so brokered hosts record new evidence.
- `proxy.openai.auth` defaults to `"bearer"`, and `"api_key"` is now a
  configuration error (OpenAI keys were always sent as Bearer).
- GitHub PAT Keychain accounts are keyed by `owner/repo`, so two repositories
  with the same name no longer share an entry.
- Usage errors exit 2. `iso uninstall` also removes the companion binaries.

### Fixed

- `iso setup` image builds failed with `APPLE_IDENTITY_CONFLICT` on container
  1.7, which saves `local/x` as `docker.io/local/x`. `iso-sandbox image import
  --name` re-tags exactly that registry-qualified alias; any other mismatch is
  still refused.
- `iso run --rm` destroys the VM on any failure before launch; `iso stop`
  stops the proxy and tunnels when the VM stop fails; instance locks never
  recreate a destroyed instance directory.
- Codex in macOS guests (`codex.sh` no longer uses GNU `mv -T`), and the
  Linux egress client setup is skipped on macOS guests. `restore
  --reprovision` refuses macOS guests up front.
- Git indexes with `skipHash` (zero trailer) are accepted; managed agent
  flags are recognised in `--flag=value` form.
- Integer overflows in guest disk-usage percentages,
  `hostRequirements.storage` parsing and client-assertion windows; an empty
  `uses:` in iso-ci is a compile error, not a crash.
- Filtered egress denies `192.0.0.0/24`; it denied all of `192.0.0.0/16`.

### Security

- **Archive validation:** `iso update` refuses non-directory members named
  `x/`, unknown ustar variants, and names or links set by both PAX and GNU
  headers, and indexes members as a tree so deep paths cost linear time.
  `SHA256SUMS` listings that name a file twice are refused.
- **Shell quoting:** escaping works per Unicode scalar, so an apostrophe
  followed by a combining mark can no longer break out of its quotes.
- **Local marketplaces:** copied into the guest as a confined snapshot
  instead of `scp -r`, which followed symlinks.
- **Devcontainer features:** references are quoted and tags must match the
  OCI grammar.
- **Tunnels:** a tunnel PID is signalled only when its identity matches.
- **Snapshots:** the default exclusions cover `.envrc`, `.env-*` and
  `.env_*`.

## v0.8.0

### Added

- **macOS guests:** guest-driven computer use. With
  `"computer_use": {"guest_access": true}`, an agent in a macOS guest gets an
  `iso-cu` MCP server (`iso-macos-helper cu-mcp`) whose tools take frames of
  its own display and send input through the VM's virtual keyboard and
  pointer, brokered by the host on vsock 7802. Off by default; fixed per
  instance at creation; `guest_frame_rate` (1–10, default 4). The host can
  take the display back with `iso-sandbox macos cu hold` (and release it),
  and `iso stop` audits the boot's counts as `boundary.guest_computer_use`.
  Templates built before this release need rebuilding for the `cu-mcp`
  subcommand.
- **macOS guests:** `iso-sandbox macos cu respond` answers one expected
  guest TCC folder-access prompt (observe or auto mode): one click at most,
  based on a fresh frame, with the dialog verified gone. Keychain, password
  and System Settings prompts are reported as `needs_user`,
  `needs_authentication` or `setup_required`. Gate R now uses it.
- **macOS guests:** refused computer-use control requests carry a
  `refusal` code and, for `cu-act`, `beforeInput`; clients branch on these
  rather than on `error` text.

### Security

- **Companion confinement:** `iso-proxy` and `iso-egress` can read only
  system paths and their own binary (home directories and iso state are
  unreadable), and reach only non-loopback ports 443 and 53 and the system
  resolver socket; every loopback service is denied. Each probes these
  denials before reading its startup input and refuses to start otherwise.
- **Companion identity:** release builds start `iso-proxy` and `iso-egress`
  only with a valid Developer ID signature of iso's own team (any valid
  signature for an ad hoc signed iso), from a binary and parent directories
  no other user can write. A recorded companion PID is signalled only while
  it is still the process recorded at spawn (start time and executable in
  `<name>.identity.json`), so a reused PID is never signalled.
- **Broker readiness probe:** now requires the guest capability as
  `Authorization: Bearer` and answers 401 without it, so other local
  processes cannot use it as a signing oracle.
- **Workspace pull:** the tar receiver runs under a deny-default Seatbelt
  profile that can write only beneath its receive tree, execute nothing and
  open no network connection.
- **Apple VM device inventory:** before the guest's init runs, every VM
  (brokered or vmnet) is stopped unbooted unless its devices are exactly the
  expected socket device, network device (none for brokered) and empty
  virtio-fs share, with no console, balloon, USB or graphics device.
- **Runtime control socket:** at most 64 concurrent connections, a 30 s
  request-line deadline, and every `iso-sandbox exec` bounded (600 s when no
  `--timeout` is given, at most 24 h). Guest-authored `e2fsck` output is
  truncated and control characters are replaced before it is logged.
- **Stop and TTL:** a guest cannot wedge a stop. Helper writes are bounded
  by their deadline, helper shutdown is abandoned after 20 s for a forced
  stop, and the owner exits 240 s after a stop begins. A stop, TTL expiry or
  signal during start is held until the start completes.
- **Guest package sources:** the Docker, GitHub CLI and NodeSource apt keys
  are checked against pinned fingerprints, NodeSource is configured directly
  rather than by running its setup script as root, and the `rust` profile
  installs a pinned, checksum-verified `rustup-init`.
- **iso-ci:** preflight snapshots exclude more credential files (`*.jks`,
  `.pgpass`, `terraform.tfstate`, `.config/gh/hosts.yml`, case-insensitive)
  and list them to the user; split or sparse indexes and tracked paths under
  a symlinked directory are refused. Only clean runs without mapped secrets
  save shared cache entries, installation tokens are narrowed per call, and
  mapped secrets are dropped when the run finishes.

## v0.7.0

### Breaking: secure defaults

New and omitted configuration now resolves to one hardened baseline. Run
`iso policy effective [NAME]` to see what a configuration or instance
requests, records and relaxes before upgrading existing workflows. An
instance's transport and egress stay as recorded at its creation.

- **Network:** `network.transport` defaults to `"brokered"` and `egress` to
  `"none"`. `vmnet` is an explicit choice, required for macOS guests and
  `egress: "open"`; brokered never falls back to it. The `networked` preset
  needs `"network": {"transport": "vmnet"}`; `provider-only` is now the
  same as no preset.
- **Provider credentials:** `proxy.mode` defaults to `"required"`; no
  provider credential variable reaches the guest.
- **Session lifetime:** `limits.session_ttl` defaults to 8h per boot.
  `"unlimited"` turns it off for an ordinary local instance only; `null` is
  rejected.
- **Agent config imports:** `claude.config_dir` and `codex.config_dir` are
  off by default; name a directory (for example `"~/.claude"`) to opt in. A
  named root is read once into a confined snapshot (links stay inside it,
  no special files, 10,000 entries / 256 MiB). Turning imports off does not
  remove files already copied into a retained guest.
- **GitHub:** an unset `github` is `"off"`, which also stops clone and
  devcontainer discovery from using ambient host tokens.
- **Pull:** `workspace.pull.mode` defaults to `"stage"`. A pull never runs
  host Git and never installs `.git`; one installer applies a validated
  stage. `--apply` now requires the exact `--stage-id` (no "latest"
  shortcut). Known execution-sensitive paths (`.husky/`, `.envrc`,
  `.vscode/tasks.json`) are withheld until each is approved with
  `--approve-sensitive PATH`.
  Direct mode applies additions; replacing files needs `--force`. On
  `iso host pull`, `--force` is deprecated and ignored.
- **Push and first copy (`workspace.input`):** transfers into the guest send
  one immutable snapshot of the Git index's tracked files (read inertly;
  Git never runs on the host) or of explicit `paths`, never `.git`, never
  the whole directory as a fallback, and never names in the
  `local-secret-names/1` table (`.env*`, keys, `.netrc`, `.aws/`, …) unless
  listed in `secret_allow`. Non-Git directories and unreadable indexes need
  `mode: "paths"`. The guest gets a fresh repository with one synthetic
  commit, not the host's history. `--exclude-git` is a deprecated no-op.
- **Scoped removal on push:** `iso push` and `iso host push` remove from the
  guest exactly the tracked files deleted on the host, by name; never
  directories, excluded or credential-looking paths. Without `--force` a
  file goes only if the guest holds it unchanged from HEAD.

### Added

- **`iso policy effective [NAME] [--json]`:** a read-only report of the
  requested policy, every relaxation from the defaults, and an instance's
  recorded transport, egress, saved environment, forwards and grants with
  their IDs and origin. `security.revoked_grant_ids` withdraws a saved
  `--env` grant or port forward by ID; a revoked environment entry reaches
  no later session, even on a running instance.
- **Run audit history:** every `iso run`, `claude`, `codex` and
  `claude-agents` invocation gets an audit run ID printed on stderr.
  `iso audit --runs`, `--run ID`, `--follow` and `--export PATH` read its
  request, effective environment, handoff, transport status, cleanup and
  boundary events (metadata only; 7 days / 128 MiB). `--output jsonl` is the
  new `iso.audit.stream/v1` protocol, and `iso audit` supports
  `--output json`. See [audit](docs/audit.md).
- **CLI help:** a misspelled subcommand suggests the nearest name, mutually
  exclusive flags are named as given, and static completion offers
  `.jsonc`/`.json` files for `--config` and directories where a directory is
  expected.

### Security

- **Managed SSH ignores ambient configuration:** iso's ssh, scp and rsync
  roles run with `-F none`, pinned tools and a fixed `ProxyCommand` shell, so
  a hostile `~/.ssh/config` cannot redirect them.
- **Guest environment separation:** forwarded guest variables travel as
  `ISO_SSH_ENV_<n>` aliases; guest variable names never configure host
  processes.
- **`iso update`:** binds the canonical release tag and exact
  `chr33s/iso` asset URLs, HTTPS only, and production builds refuse
  `ISO_UPDATE_API_BASE_URL`.
- **Release binaries:** all five binaries are signed with the hardened
  runtime and Enhanced Security entitlements, and the core, policy, proxy
  and egress packages build with strict memory safety.

### Fixed

- **`iso model set` on brokered VMs:** on a running brokered instance, a
  switch to or from a local model failed with
  `POLICY_CHANGE_REQUIRES_RESTART`, because local-model services are part of
  the boot's network policy. The selection is now saved and the command
  names the `iso stop NAME && iso start NAME` that applies it; vmnet VMs
  still switch live.
- **Port forwards with a long data root:** forwards failed at start when the
  instance path pushed ssh's control socket past macOS's 104-byte Unix path
  limit; the socket moves to a short private path when needed.
- **Sandboxed VS Code server upload:** with `internet` allowed and restricted
  egress, Remote-SSH's scp probe was refused by the session sandbox and the
  connection was abandoned; the session now gets the same scp/sftp rule as
  Zed's upload.

### Also in this release

- **iso-ci** (new, separately installed companion in `iso-ci/`; release
  qualification not yet recorded): isolated GitHub Actions execution in
  NIC-less iso VMs. GitHub-connected pools keep fresh single-use official
  runners ready (GitHub App via manifest flow, JIT registration, exact-owned
  cleanup, uncertain-registration resolution, pause/drain/remove). Local
  preflight compiles a declared workflow subset, runs it against an immutable
  working-tree snapshot through a confined local data plane, and supports
  debug, patch and fresh whole-job retry. Admission requires the host's
  `net-handoff-1` capability; there is no networked fallback. See
  [`docs/ci.md`](docs/ci.md), the
  [specification](docs/design/iso-ci-specification.md) and the [qualification
  record](docs/design/iso-ci-qualification.md).
- **Host run results:** a run's results archive no longer fails validation
  because guest `tar` (GNU or BSD) names the archive root `./`; only an empty
  root directory member is skipped, and every other check is unchanged.
- **Remote hosts with agent-held keys:** SSH to an enrolled remote Mac now
  uses your SSH agent (`SSH_AUTH_SOCK`), so a passphrase-protected key held by
  the agent, 1Password or Secretive works. The agent is never forwarded, and
  VM sessions still refuse it.
- **Filtered egress wildcards:** `egress_filter.allowed_hosts` accepts
  `*.<suffix>` for names one or more whole labels below a suffix of at least
  three labels (never the suffix itself), so services that assign per-job
  hosts, such as GitHub Actions under `actions.githubusercontent.com`, can be
  allowed without listing every shard. `*.com`, `*.github.io` and similar
  short suffixes are refused.
- **Filtered egress:** a CONNECT without the per-boot capability, or with a
  different one, now gets `407 Proxy Authentication Required` with a Basic
  challenge instead of `403`. Clients that send proxy credentials only when
  challenged (.NET, including the GitHub Actions runner) previously could not
  connect. Every other refusal is still `403`.
- **Host capabilities** (`iso.host/v1`): `host.capabilities` reports what a
  host can do now. `net-handoff-1` (the brokered execution handoff) is listed
  only while `network.transport` is brokered, the runtime is brokered-capable
  and an operator-installed NET-HANDOFF-1 evidence manifest names the running
  tuple with N-T01–N-T16 passed and has not expired; the result includes the
  brokered policy (digest, egress, provider grants, local services) a fresh
  run VM boots with. `scripts/record-net-handoff-evidence.py` installs the
  manifest from qualification results and refuses incomplete ones. See
  [brokered network isolation](docs/design/brokered-network-isolation.md).
- **Run retention**: `run.retain` keeps a disposable run under host deadlines:
  `live` (up to 4 h from the first live request, never past the VM's
  deadline; revokes the run's SSH access grants but not its boot network
  policy or guest state; stops without export at its end) or `stopped` (extends result retention up
  to 7 days from the first stop, never shortening it). `run.inspect` adds
  `live_retention_until` once live retention is set, and
  `run.results.discard` releases a live-retained run.
- **Filtered host-control VMs**: `vm.start` and `run.create` on a host now
  bring up the worker's `iso-egress` companion (lease, confinement, guest-path
  readiness and recorded boot policy, as `iso up --egress filtered` does) for
  a VM created with `egress: "filtered"`. Previously no companion ran, so
  every `access.open` to such a VM failed with `FILTERED_EGRESS_NOT_READY`. A
  companion that cannot start fails the start and stops the VM; stop and
  destroy stop it. Filtered `access.open` also failed because the worker's
  boot-policy hash (`sha256:<hex>`) was parsed as a boot id; it is now its own
  type. A refused filtered `access.open` names the failing proof component
  (sanitized) in its error and the service log. Filtered boots now also write
  the proxy variables to the guest's `/etc/environment`, so sessions opened
  through host control (whose client cannot read the worker's capability) use
  the companion.
- **Image digest binding**: `vm.create` and `run.create` with `image_digest`
  are refused unless the worker's prepared image of that name has exactly that
  manifest digest (it was previously only part of the policy hash).
  `host.capabilities` names the one qualified image as
  `network_handoff.qualified_image` while `net-handoff-1` is listed.
- **Client bridge**: `iso host-agent client --host ALIAS --stdio [--relay]`
  carries `iso.host/v1` frames or one relay stream for a companion process,
  through the local service's remote socket (remote-v1 restrictions apply) or
  an enrolled host's pinned management SSH. A remote relay returns ssh's exit
  status with one bounded, sanitized diagnostic. Disabled hosts are refused.

## v0.6.0

- **Brokered network isolation** (opt-in, Linux guests): `"network":
  {"transport": "brokered"}` creates new instances whose VM has **no network
  device**, proven from the live VM before the guest's init runs and again by
  the host gate. Everything iso does over SSH keeps working through the
  runtime's fixed vsock stream connector (`iso-sandbox connect`) as ssh's
  `ProxyCommand`. Each boot is bound to a digest of its resolved network
  policy; a stale boot or policy is refused and any change needs a restart.
  `egress: "open"`, macOS guests, old runtimes and images without the guest
  adapter are refused before a VM is created, never started on vmnet
  instead. Rebuild images with `iso setup --rebuild` to use it. vmnet stays the
  default and is unchanged. See [configuration](docs/configuration.md#network)
  and the [design record](docs/design/brokered-network-isolation.md).
- **Remote brokered proof**: `vm.inspect`/`vm.list` on `iso.host/v1` add a
  `network` object for a running brokered VM (zero external network devices,
  the boot's network- and channel-policy digests) from a fresh check on the
  worker, shown by `iso host vm inspect`. A brokered VM failing that check is
  `unhealthy`; vmnet observations are unchanged.
- **Filtered egress**: `iso-egress` tries each validated answer for an
  approved host in turn until one connects (the whole answer must still be
  public), so a dual-stack host works on a Mac without an IPv6 route. Filtered
  boots also point the guest's Docker daemon, the guest user's Docker client
  config and containers on Docker's default bridge at the companion, so
  approved registries work from Docker.
- **Host service after a worker reboot**: `vm.start` refused a VM that had
  stopped while the service was down (a reboot or a crashed runtime owner) as
  already running, until the periodic sweep caught up. Start admission and
  service startup now commit a stop the runtime reports.
- **Sandboxed Zed upload**: a sandboxed Zed with `--editor-allow internet`
  could not upload `zed-remote-server` to a guest without open egress, because
  its profile denied `sftp`/`scp`. That session's profile now allows those two
  OpenSSH tools, still confined.
- **iso-sandbox**: `create --network brokered`, `start --network-policy`,
  `connect`, and `streams list|close`, advertised as the `brokered-transport`
  feature on protocol 5. Output for vmnet sandboxes is unchanged.
- **Shared option parsing**: `up`, `code`, `zed` and `start` share one
  definition of the boot options (`--no-agents`, `--no-github`,
  `--no-prompt`, `--forward-port`, `--post-start`, `--env`, `--env-file`) and
  of `--devcontainer`/`--no-devcontainer`; `setup` uses the same devcontainer
  group. `--egress` (also on `run`, `host up`, `host run` and
  `host vm create`), `--allow-host` (`up`, `code`, `zed`, `start`, `run`) and
  `--ttl` (`host up`, `host run`, `host vm start`) are now checked when the
  command line is parsed, so a malformed value is a usage error (exit 2)
  before any configuration, network or VM work. The 24h ceiling on `--ttl` is
  still enforced by the host. `--profile` accepts repeated or comma-separated names on
  `setup`, `up`, `code`, `zed`, `run` and `host image` alike, and an empty
  name (`--profile a,,b`) is refused everywhere instead of being dropped by
  some commands.
- **Refused flag combinations**: these now fail with a usage error (exit 2)
  before any work, where one flag used to win silently: `destroy NAME --all`,
  `host migrate local --activate --rollback`, `host session --detach --stop`,
  `host run-results --recover --discard`, and `images --delete NAME --json`.
  `host pull` refuses flags of the other mode: `--stage-id` and `--force`
  need `--apply`, and `--dir` and `--exclude-git` cannot be used with it.
  `host vm create` and `host vm resize` refuse `--disk +20` (and
  `--disk-gib +20`) instead of reading it as 20 GiB.
- **`iso run` forwarding**: every token after the first `--` reaches the
  agent unchanged. `iso run claude -- --ask` no longer turns on iso's own
  `--ask`, and a second `--` is forwarded rather than dropped.
- **`host up --egress` on reuse**: an explicit `--egress` is compared with the
  egress of the VM being reused; a mismatch, or a host that does not report
  it, is refused instead of ignored. The VM is never recreated for it.
- **Exit status**: `exec`, `shell [NAME] -- COMMAND` and interactive
  `shell`/`claude`/`claude-agents`/`codex` sessions exit with the guest
  command's status instead of 1 (or 0 for an interactive session). A command
  ended by a signal exits 1; `host shell` and `host forward` no longer report
  success after a signal. `ssh`'s own failures (such as a refused pinned host
  key) now surface as its status 255 rather than 1. See
  `docs/commands.md#exit-status`.
- **Host receipts**: `host run-results` (with or without `--discard` or
  `--recover`) and `host run` exit 1 when a host receipt they wait on (discard,
  recovery, or the results acknowledgement) is not `succeeded`, even though
  the request was delivered. A lost reply only
  suggests `--operation-id` on commands that accept it.
- **`validate`**: the last line summarizes what was checked. A PAT that does
  not resolve, or a failed `--probe`, makes `validate` print
  `Config loads, but N requested checks failed` and exit 1 (it printed
  `Config OK` and exited 0). Unresolved `vault:` entries without `--probe`
  are reported as not checked, not as failures.
- **Dry runs**: `setup`, `up` and `start --dry-run` no longer show an update
  notice or schedule an update check (`run --dry-run` already did not).
- **Confirmation flags**: `agent add` accepts `-y`. `setup --yes`, which
  never did anything, is deprecated and warns that it does not accept a
  discovered devcontainer: answer the prompt, or pass `--devcontainer PATH`
  or `--no-devcontainer`.
- **Canonical spellings**: `--vcpus`, `--mem` and `--disk` on `host vm create`
  and `host vm resize`; `--disk` on `resize`; `--guest-path` on `code`,
  `zed`, `editor` and `host editor`; `--forward-port GUEST[:HOST]` on
  `host forward`; `--image` on `host vm commit`/`restore`;
  `model show [NAME]` and `model set local|remote [NAME]`. Every older
  spelling keeps working; see `docs/commands.md#compatibility-spellings-and-deprecations`.
- **Machine interface**: command discovery walks the whole command tree and
  names nested commands by their full path; the advertised set is unchanged.

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
