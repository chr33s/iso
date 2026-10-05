<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# isolate

isolate is a Swift fork of [Trail of Bits’ coop](https://github.com/trailofbits/coop)
for running Claude Code and Codex in disposable Linux VMs on **macOS 27+ Apple
Silicon**. It replaces the Rust host and credential proxy with Swift and uses a
purpose-built runtime on Apple Containerization. Focusing on one host platform
and removing the former Rust networking and TLS dependency tree reduces what
needs maintenance and security review. The aim is a smaller attack surface;
Swift alone does not guarantee fewer vulnerabilities or complete isolation.

Agents get full tool access inside the VM: Docker, git, compilers and package
managers. The VM is the isolation boundary. A host credential proxy can keep
provider API keys out of the guest.

## Setup

Build from source with Xcode 27 until a verified fork release is published:

```shell
git clone https://github.com/chr33s/iso.git
cd iso
python3 scripts/build-release.py --release
```

Install all four executables from the archive in `.build/release-archive/`
into the same directory on `PATH`: `iso`, `iso-proxy`, `iso-egress` and
`iso-sandbox`. See [prerequisites](docs/getting-started.md#prerequisites),
[build instructions](docs/getting-started.md#build-from-source) and
[Apple backend setup](docs/backends.md#macos--apple-sandbox).

Once a verified release is available, you can install the bundle with:

```shell
curl -fsSL https://raw.githubusercontent.com/chr33s/iso/main/install.sh | bash
```

Create the configuration and build the VM template:

```shell
iso setup
```

Configuration lives in `~/.iso/config.jsonc`; state lives under `~/.iso`.
Use `iso setup --config-only` to write just the commented configuration template.
See [release status](RELEASING.md) and [`iso update`](docs/commands.md#update).

## Usage

Start a VM for your project, then launch an agent:

```shell
cd ~/code/my-project
iso up
iso claude
# or
iso codex
```

Open the project's VM in an editor over the pinned SSH alias (creating or
starting it first, like `iso up`; see [editor integration](docs/editor.md)):

```shell
iso code .
iso zed .
```

## Security controls

Default VMs have network access. The [credential proxy](docs/credential-proxy.md)
is automatic for providers with a configured upstream; other restrictions are
opt-in.

- [Security presets](docs/configuration.md#security-presets):
  `"security": {"preset": "provider-only"}` requires the proxy, disables direct
  egress and stages file returns for review. `offline` suits local models or
  pre-provisioned images.
- [Credential handling](docs/configuration.md#proxymode): `proxy.mode: "required"`
  withholds all provider credential variables from the guest.
- [Network limits](docs/configuration.md#egress): `"egress": "none"` blocks routes
  beyond the Mac while preserving SSH and its tunnels. **Guests can still reach
  services on the Mac.**
- [Secret storage](docs/commands.md#secrets): `iso secrets` encrypts local secrets
  with a passphrase and this Mac's Secure Enclave key, with no recovery path.
- [File review](docs/workspaces.md#staged-pulls): `iso diff` or `iso pull --review`
  stages guest files for inspection before you apply or discard them.
- [Session limits](docs/configuration.md#limits):
  `"limits": {"session_ttl": "8h"}` stops each boot at a host-clock deadline.
- [Audit records](docs/commands.md#audit): `iso audit` reports boundary events and
  forwarded variable names, never their values.

Read the [trust model](docs/trust-model.md) for the boundaries and their limits.

## Documentation

- [Getting started](docs/getting-started.md), [commands](docs/commands.md) and
  [configuration](docs/configuration.md)
- [Machine interface](docs/machine-interface.md) for editors, CI and other
  integrations
- [Full documentation index](docs/index.md)
- [Architecture](docs/ARCHITECTURE.md) and [release validation](docs/release-validation.md)
- [Contributing](CONTRIBUTING.md) and [security policy](SECURITY.md)
- Attribution: [NOTICE](NOTICE), [provenance](PROVENANCE.md) and
  [third-party licenses](THIRD_PARTY_LICENSES.md)
