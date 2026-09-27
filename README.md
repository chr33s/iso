# coop

A fork of [Trail of Bits’ coop](https://github.com/trailofbits/coop) for running
Claude Code and Codex in isolated VMs, with a focused Swift credential proxy
and an Apple Containerization runtime. **Supported hosts: macOS 27+ on Apple
Silicon only.** Linux runs inside the guest VMs.

## Why this fork?

The use case is running coding agents with broad permissions inside disposable
VMs while keeping provider API keys on the host. This fork replaces the Rust
credential proxy with one Swift implementation on macOS 27+ and provides a
small, purpose-built Apple VM runtime. Keeping one proxy implementation and
removing its former Rust networking and TLS dependency tree reduces the code,
dependencies, and platform combinations that need security review and maintenance.
The aim is a smaller attack surface and fewer places for vulnerabilities to
arise; it is not a guarantee of fewer vulnerabilities or complete isolation.

The host CLI remains Rust. Source and release builds use the Apple runtime by
default; no Cargo feature flag is required. The root Swift packages are [`coop-proxy/`](coop-proxy/) and
[`coop-sandbox/`](coop-sandbox/). See the
[acceptance record](docs/design/swift-proxy-acceptance.md) for remaining validation
and distribution gates.

> **Pronunciation:** "coop" (/kuːp/) — one syllable, rhymes with "loop", like the thing you keep chickens in. Not "co-op".

coop is a Rust CLI that manages disposable virtual machines where Claude Code and Codex have full tool access: Docker, git, compilers, package managers, with the VM as the isolation boundary. Each VM is isolated, reproducible, and cheap to create and destroy.

## Setup

Build this fork from source (requires [Rust](https://rustup.rs/)):

```shell
git clone https://github.com/chr33s/coop.git
cd coop
cargo build --workspace --release
cp target/release/coop /usr/local/bin/
```

For credential-proxy mode on macOS 27+, also build and install the Swift
companion as described in [Build from source](docs/getting-started.md#build-from-source).

Then build the VM template image:

```shell
coop setup
```

Build and install `coop-sandbox` before setup; see
[Prerequisites](docs/getting-started.md#prerequisites) and
[Apple backend setup](docs/backends.md#macos--apple-sandbox).

The release channel targets `chr33s/coop`, with tagged commits from `swift`.
macOS release archives include `coop-proxy` and `coop-sandbox`.
Configuration defaults to `~/.coop/config.toml`. Existing `~/.coop-apple`
installations migrate only when `~/.coop` is absent; a compatibility symlink
preserves existing absolute paths. See [state migration](docs/backends.md#state).
See [release status](RELEASING.md) and [`coop update`](docs/commands.md#update).

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
