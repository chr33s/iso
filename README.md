# isolate

A fork of [Trail of Bits’ coop](https://github.com/trailofbits/coop) for running
Claude Code and Codex in isolated VMs, with a focused Swift credential proxy
and an Apple Containerization runtime. **Supported hosts: macOS 27+ on Apple
Silicon only.** Linux runs inside the guest VMs.

## Why this fork?

The use case is running coding agents with broad permissions inside disposable
VMs while keeping provider API keys on the host. This fork replaces the upstream Rust
host and credential proxy with Swift implementations on macOS 27+ and provides a
small, purpose-built Apple VM runtime. Keeping one proxy implementation and
removing its former Rust networking and TLS dependency tree reduces the code,
dependencies, and platform combinations that need security review and maintenance.
The aim is a smaller attack surface and fewer places for vulnerabilities to
arise; it is not a guarantee of fewer vulnerabilities or complete isolation.

The host CLI is Swift too: the root package builds `iso`, and the separate
[`iso-proxy/`](iso-proxy/) and [`iso-sandbox/`](iso-sandbox/) packages build
the credential proxy and the VM runtime. No Rust toolchain is needed to build
or run the host. See the
[acceptance record](docs/design/swift-host-acceptance.md) for remaining
validation and distribution gates.

> Renamed from `mews` (originally `coop`). The CLI binary is `iso`.

isolate is a CLI that manages disposable virtual machines where Claude Code and Codex have full tool access: Docker, git, compilers, package managers, with the VM as the isolation boundary. Each VM is isolated, reproducible, and cheap to create and destroy.

## Setup

Once a verified fork release is published, install `iso`, `iso-proxy`, and
`iso-sandbox` together with:

```shell
curl -fsSL https://raw.githubusercontent.com/chr33s/iso/swift/install.sh | bash
```

Until then, build from source with Xcode 27:

```shell
git clone https://github.com/chr33s/iso.git
cd iso
python3 scripts/build-release.py --release
```

The archive under `.build/release-archive/` holds all three executables;
install them in the same directory on `PATH`. `swift build` builds only the
host CLI (`.build/debug/iso`) for development. See
[Build from source](docs/getting-started.md#build-from-source),
[Prerequisites](docs/getting-started.md#prerequisites) and
[Apple backend setup](docs/backends.md#macos--apple-sandbox).

Then create the configuration and build the VM template image:

```shell
iso setup
```

The release channel targets `chr33s/iso`, with tagged commits from `swift`.
Configuration lives in `~/.iso/config.jsonc` (JSON with comments), with state
under `~/.iso`. `iso setup --config-only` writes a commented template.
Upstream TOML configurations are not read; convert one with
`python3 scripts/migrate-config-to-jsonc.py --input ~/.iso/config.toml --output ~/.iso/config.jsonc`
(see [Migrating from TOML](docs/configuration.md#migrating-from-toml)).
See [state](docs/backends.md#state), [release status](RELEASING.md) and
[`iso update`](docs/commands.md#update).

## Usage

Start an instance for the current project and launch an agent CLI:

```
cd ~/code/my-project
iso up
iso claude
# or
iso codex
```

## Hardening

Beyond the upstream feature set, this fork can narrow what crosses the VM
boundary. All of it is opt-in; with no configuration isolate behaves like
`networked` below.

- **Security presets.** `"security": {"preset": "provider-only"}` sets
  `egress: "none"`, `proxy.mode: "required"` and staged pulls in one line;
  `offline` is for local models or fully pre-provisioned images.
  See [Security presets](docs/configuration.md#security-presets).
- **Credential proxy by default.** Under `proxy.mode` `"auto"`, a provider
  with a configured upstream is reached through the host-side
  [credential proxy](docs/credential-proxy.md) and its API key never enters the
  guest; `"required"` withholds every provider credential variable.
  See [`proxy.mode`](docs/configuration.md#proxymode).
- **No-egress sandboxes.** `"egress": "none"` gives the guest no route beyond
  the Mac; SSH and the tunnels isolate runs over it keep working. It does not
  block services listening on the Mac itself.
  See [`egress`](docs/configuration.md#egress).
- **Local secret store.** `iso secrets` keeps secrets encrypted under a
  passphrase and this Mac's Secure Enclave key, with no recovery path.
  `--env NAME={vault:name}` or `--env-file` references resolve them per
  session. A reference on a provider key becomes the proxy credential
  and is never sent into the guest.
  See [`secrets`](docs/commands.md#secrets).
- **Staged pulls.** `iso diff` or `iso pull --review` copies guest files into
  a checked stage (file types, symlink targets, size budgets) that you apply or
  discard. See [Staged pulls](docs/workspaces.md#staged-pulls).
- **Session TTL.** `"limits": {"session_ttl": "8h"}` has the host halt each
  boot at a deadline on the host clock. See
  [`limits`](docs/configuration.md#limits).
- **Audit log.** `iso audit` shows each instance's recorded boundary events
  (egress, proxy mode, forwarded variable names, workspace returns), never
  values. `--suggest-config` proposes a narrower configuration.
  See [`audit`](docs/commands.md#audit).

## Documentation

- [Documentation index](docs/index.md)
- [Getting started](docs/getting-started.md)
- [Command reference](docs/commands.md)
- [Configuration reference](docs/configuration.md)
- [Images and profiles](docs/images-and-profiles.md)
- [Workspace sync](docs/workspaces.md)
- [Claude Code integration](docs/claude-integration.md)
- [Codex integration](docs/codex-integration.md)
- [Credential proxy](docs/credential-proxy.md)
- [Editor integration](docs/editor.md) and [devcontainers](docs/devcontainer.md)
- [Multi-instance](docs/multi-instance.md)
- [Platform backends](docs/backends.md)
- [Shell completion](docs/shell-completion.md)
- [Architecture](docs/ARCHITECTURE.md) and [trust model](docs/trust-model.md)
- [Contributing](CONTRIBUTING.md) and [security policy](SECURITY.md)
