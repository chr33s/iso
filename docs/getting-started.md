<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Getting Started

isolate runs Claude Code and Codex inside isolated Linux guest VMs on
**macOS 27+ Apple Silicon hosts only**. Release builds use the Apple
Containerization backend for both source and release builds.

## Prerequisites

- macOS 27 or later on Apple Silicon (arm64).
- Apple backend: stock Apple `container` service and guest kernel. See
  [Apple backend setup](backends.md#macos--apple-sandbox).
- Source builds: Xcode 27 (Swift 6). No Rust toolchain is needed.

Linux hosts and macOS 26 are outside this fork’s support scope.

## Install

Until a verified fork release is published, follow [Build from source](#build-from-source).
The configured release channel is `chr33s/iso`, built from tagged commits on
`main`. Its macOS archives install `iso`, `iso-proxy`, `iso-egress`, and
`iso-sandbox` together; see [Apple prerequisites](backends.md).
Once the macOS channel has a verified release:

```sh
curl -fsSL https://raw.githubusercontent.com/chr33s/iso/main/install.sh | bash
```

`install.sh` verifies the downloaded tarball's SHA-256 against the release's
`SHA256SUMS` and, when the [GitHub CLI](https://cli.github.com/) is installed,
also verifies its Sigstore build-provenance attestation. `iso update` runs the
same verification, except that it treats the checksum as mandatory and refuses
to install without it. To verify a tarball by hand, download
`attestations.jsonl` from the same release and pass `--bundle` (this needs no
GitHub credential — releases up to v0.5.4 predate the bundle asset and do
not publish it):

```sh
gh attestation verify iso-<version>-<triple>.tar.gz --repo chr33s/iso \
  --bundle attestations.jsonl
```

Dropping `--bundle` makes `gh` fetch the attestation from the GitHub API
instead, which it will only do when `gh` is logged in. `install.sh` and `iso
update` use that API path themselves for releases published without a usable
bundle.

## Switching from upstream

Run the fork installer to install all matching components. An upstream updater
continues to target its own repository. Fork releases use the Apple backend
only; instances created by another backend are not managed by this build.

## Build from source

With Xcode 27 installed:

```sh
git clone https://github.com/chr33s/iso.git
cd iso
python3 scripts/build-release.py --release
```

This is the one release build entrypoint. It builds `iso` (this package),
`iso-proxy`, `iso-egress`, and `iso-sandbox` (ad-hoc signed with its
entitlement) from a staged copy of the checkout and writes
`iso-<revision>-aarch64-apple-darwin.tar.gz` plus `SHA256SUMS` under
`.build/release-archive/`. Add `--test` to run every package's tests first.
Extract the archive and install its executables in the same directory on
`PATH`. A missing `iso-egress` blocks only filtered boots.

For a development build of the host CLI alone:

```sh
swift build --force-resolved-versions   # .build/debug/iso
```

`iso-sandbox` must still be built and installed with
`./scripts/build-iso-sandbox.sh`; see
[Apple backend setup](backends.md#macos--apple-sandbox) for prerequisites.
Until a verified fork release exists, update by pulling and rebuilding.
The configured `iso update` channel is `chr33s/iso`.

## Configuration

isolate reads `~/.iso/config.jsonc` by default: JSON plus `//` and `/* */`
comments (no trailing commas). Override the path with `--config`; a `.json`
path is read as strict JSON. If no configuration file exists, isolate uses
built-in defaults. Run `iso setup --config-only` to write a commented
starter template.

A minimal config (an empty object is valid; all fields have defaults):

```jsonc
{}
```

Defaults: 2 vCPUs, 4 GiB RAM, 8 GiB template disk. Override any of them:

```jsonc
{
  "vm": {
    "vcpu_count": 4,
    "mem_size_mib": 8192,
    "template_size_gib": 20
  }
}
```

All VM artifacts (rootfs images, instance disks, keys) live under `~/.iso/`.

The guest runs as an unprivileged user (`ubuntu`, uid 1000, by default) with `~/.local/bin` on `PATH` for every session. Override the username at setup with `iso setup --guest-user <name>`; see [Guest user](configuration.md#guest-user) for details.

### Claude Code and Codex integration

Forward your API keys and GitHub credentials into the guest:

```jsonc
{
  "github": "auto",
  "vm": { "vcpu_count": 4, "mem_size_mib": 8192 },
  "claude": { "config_dir": "~/.claude" },
  "codex": { "auth": "api_key", "config_dir": "~/.codex" }
}
```

The `github` field controls how isolate resolves a GitHub token for the guest:

- `"off"` (default): disables GitHub auth forwarding
- `"auto"`: checks `$GITHUB_TOKEN` env var first, falls back to `gh auth token` if unset
- `"env"`: requires `GITHUB_TOKEN` in your environment
- `"pat"`: forwards a per-repo fine-grained PAT recorded under `github.pat["owner/repo"]`. GitHub enforces the token's scope server-side — see [GitHub auth](configuration.md#fine-grained-pat-github-pat) for the full reference.

GitHub auth is off by default. Set `"github": "auto"` (or run `iso github setup-pat --repo owner/name` for a scoped PAT) to enable it. `iso up` offers to run the PAT wizard inline the first time you bring up a project backed by a GitHub repo without auth configured.

isolate picks up `ANTHROPIC_API_KEY` and, in the default Codex API-key mode,
`OPENAI_API_KEY` from your environment automatically. Setting them explicitly
under `claude.api_key` or `codex.api_key` (preferably as a `cmd:` reference)
also works, but environment variables are preferred.

For Codex account or workspace access without OpenAI API billing, set
`"codex": { "auth": "chatgpt" }` and rebuild any old image with `iso setup
--rebuild`. An existing VM keeps its own guest disk across a restart, so also
run `iso restore <vm> --image <image> --reprovision` (see
[Codex integration](codex-integration.md)) to pick up the rebuilt image.
Reprovisioning replaces the guest disk, so save guest-only work first. Then
run `iso codex -- login --device-auth` once.

## First run

The steps below are explicit: `iso setup` prepares the image, `iso up`
brings up an instance, and `iso claude` or `iso codex` launches an agent.

### 1. Setup

`iso setup` creates a missing default configuration template, then builds a template rootfs image with the Apple runtime. The template ships with base packages (git, curl, build-essential, Docker, and others), the GitHub CLI, Claude Code, and Codex.

```
iso setup
```

Install language toolchains into the template with `--profile`:

```
iso setup --profile python,node
```

Built-in profiles: `python`, `node`, `c`, `fuzz`, `rust`, `go`. Combine them with commas (e.g. `--profile python,node,rust`). Use `iso profiles list` to inspect what each one installs.

You can also let `up` build a profile-derived image on demand:

```
iso up --profile python,node
```

This creates or refreshes an image named from the sorted profile list
(`node-python` here), then creates the project instance from it.

Skip confirmation prompts with `-y`:

```
iso setup -y --profile python
```

Setup is idempotent. Rerunning with the same profiles skips completed work. Pass `--rebuild` to force a fresh template build.

### 2. Bring up a project environment

For normal project work, use `iso up` from your project directory:

```
cd ~/code/my-project
iso up
```

`iso up` is project-oriented and re-runnable. It creates an instance the
first time, reuses it if it is already running, and restarts it after
`iso stop`. By default it copies/syncs the project into `/workspace`.

Choose mount transport explicitly:

```
iso up . --mount
```

The Apple backend has no host mounts, so `--mount` is a one-time sync; use
`iso push` / `iso pull` to sync changes afterward.

Mount additional data directories when creating the project instance:

```
iso up . --extra-mount ~/data:/data
```

Or clone a remote repository directly into `/workspace` inside the guest:

```
iso up --git-repo https://github.com/chr33s/iso.git
```

Tune a project environment at startup (each flag is repeatable where it makes sense, and works on both `iso up` and `iso start`):

```
iso up --forward-port 3000        # tunnel a guest port to the host
iso up --env RUST_LOG=debug       # set a guest env var
iso up --post-start "npm install" # run a command after every boot
```

See the [command reference](commands.md) and [configuration reference](configuration.md) for the full behavior of `--forward-port`, `--env`, and `--post-start`.
After the environment is running, connect to it:

```
iso shell
iso claude
iso codex
```

### 3. Restart a stopped instance

```
iso start
```

`iso start` starts existing stopped instances. Use it after `iso stop` when
you want to boot the same VM disk again. If exactly one stopped instance
exists, the name is optional.

Restart a specific stopped instance:

```
iso start my-project
```

Restart by project path when the instance was created for that project:

```
iso start --workspace ~/code/my-project
```

Project creation options belong to `iso up`, not `iso start`:

```
iso up ~/code/my-project --disk 40 --mount
iso up ~/code/my-project --profile python,node
iso up --git-repo https://github.com/chr33s/iso.git
```

Skip Claude Code and Codex credential/config injection:

```
iso start my-project --no-agents
```

### 4. Connect

**Launch Claude Code inside the VM:**

```
iso claude
```

During VM startup, isolate writes `~/.claude/settings.json` in the guest with `defaultMode: bypassPermissions` and `skipDangerousModePermissionPrompt: true`, so Claude Code runs without permission prompts by default. The VM itself is the isolation boundary. For permission prompts (isolate launches `claude` with `--permission-mode default`):

```
iso claude --ask
```

Pass extra arguments through to `claude`:

```
iso claude -- --model opus
```

**Launch Codex inside the VM:**

```
iso codex
```

With `"codex": { "auth": "chatgpt" }`, first sign in from the guest:

```
iso codex -- login --device-auth
```

Pass extra arguments through to `codex`:

```
iso codex -- --model gpt-5
```

**Open a shell in the VM:**

```
iso shell
```

**Run a command non-interactively:**

```
iso shell -- ls /workspace
iso exec -- docker ps
```

### 5. Check status

```
iso status
```

For a specific instance:

```
iso status my-project
```

Running instances report resource usage: load average, memory, and disk.

### 6. Sync files

Push local changes into a running VM:

```
iso push
```

Pull guest changes back to the host:

```
iso pull
```

Both commands default to the workspace path recorded by `iso up`. Override with `--dir`:

```
iso push --dir ~/other-dir
iso pull --dir ~/other-dir
```

### 7. Tear down

Stop an instance (preserves disk state):

```
iso stop my-project
```

Destroy an instance (deletes its disk and resources):

```
iso destroy my-project
```

Also remove every image and the VM access key:

```
iso destroy --all
```

## Named images

Build multiple template images with different profiles:

```
iso setup --image python-dev --profile python
iso setup --image polyglot --profile python,node,rust
```

Create a project environment from a specific image:

```
iso up . --image python-dev
```

List images:

```
iso images
```

Delete an image:

```
iso images --delete python-dev
```

## Other commands

| Command | Description |
|---------|-------------|
| `iso validate` | Check config and prerequisites without changing anything |
| `iso logs` | Stream VM serial console logs (`-f` to follow) |
| `iso code [DIR]` / `iso zed [DIR]` | Ensure the project's VM is running, then open it in VS Code or Zed over SSH |
| `iso editor` | Open VS Code or Zed connected to an already-running guest via SSH |
| `iso ssh-config` | Install a `iso-<name>` SSH alias for ad-hoc `ssh`/`scp`/`rsync` |
| `iso resize --size +20` | Grow a stopped instance's disk by 20 GiB |
| `iso resize --size 100` | Set a stopped instance's disk to 100 GiB |
| `iso resize --mem 8192 --vcpus 4` | Change a stopped instance's memory and vCPUs |

## Further reading

- [Configuration reference](configuration.md)
- [Command reference](commands.md)
- [Images and profiles](images-and-profiles.md)
- [Workspace sync](workspaces.md)
- [Claude Code integration](claude-integration.md)
- [Codex integration](codex-integration.md)
- [Editor integration](editor.md)
- [Running multiple instances](multi-instance.md)
- [Platform backends](backends.md)
