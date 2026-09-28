<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# coop

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

The host CLI is Swift too: the root package builds `coop`, and the separate
[`coop-proxy/`](coop-proxy/) and [`coop-sandbox/`](coop-sandbox/) packages build
the credential proxy and the VM runtime. No Rust toolchain is needed to build
or run the host. See the
[acceptance record](docs/design/swift-host-acceptance.md) for remaining
validation and distribution gates.

> **Pronunciation:** "coop" (/kuːp/) — one syllable, rhymes with "loop", like the thing you keep chickens in. Not "co-op".

coop is a CLI that manages disposable virtual machines where Claude Code and Codex have full tool access: Docker, git, compilers, package managers, with the VM as the isolation boundary. Each VM is isolated, reproducible, and cheap to create and destroy.

## Setup

Once a verified fork release is published, install `coop`, `coop-proxy`, and
`coop-sandbox` together with:

```shell
curl -fsSL https://raw.githubusercontent.com/chr33s/coop/swift/install.sh | bash
```

Until then, build from source with Xcode 27:

```shell
git clone https://github.com/chr33s/coop.git
cd coop
python3 scripts/build-release.py --release
```

The archive under `.build/release-archive/` holds all three executables;
install them in the same directory on `PATH`. `swift build` builds only the
host CLI (`.build/debug/coop`) for development. See
[Build from source](docs/getting-started.md#build-from-source),
[Prerequisites](docs/getting-started.md#prerequisites) and
[Apple backend setup](docs/backends.md#macos--apple-sandbox).

Then create the configuration and build the VM template image:

```shell
coop setup
```

The release channel targets `chr33s/coop`, with tagged commits from `swift`.
Configuration lives in `~/.coop/config.jsonc` (JSON with comments), with state
under `~/.coop`. `coop setup --config-only` writes a commented template.
Upstream TOML configurations are not read; convert one with
`python3 scripts/migrate-config-to-jsonc.py --input ~/.coop/config.toml --output ~/.coop/config.jsonc`
(see [Migrating from TOML](docs/configuration.md#migrating-from-toml)).
See [state](docs/backends.md#state), [release status](RELEASING.md) and
[`coop update`](docs/commands.md#update).

## Usage

Start an instance for the current project and launch an agent CLI:

```
cd ~/code/my-project
coop up
coop claude
# or
coop codex
```

## Documentation

- [Documentation index](docs/index.md)
- [Getting started](docs/getting-started.md)
- [Command reference](docs/commands.md)
- [Configuration reference](docs/configuration.md)
- [Images and profiles](docs/images-and-profiles.md)
- [Workspace sync](docs/workspaces.md)
- [Claude Code integration](docs/claude-integration.md)
- [Codex integration](docs/codex-integration.md)
- [Editor integration](docs/editor.md)
- [Multi-instance](docs/multi-instance.md)
- [Platform backends](docs/backends.md)
- [Shell completion](docs/shell-completion.md)
- [Architecture](docs/ARCHITECTURE.md) and [trust model](docs/trust-model.md)
- [Contributing](CONTRIBUTING.md) and [security policy](SECURITY.md)
