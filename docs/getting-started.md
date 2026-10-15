<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Getting started

Run your first coding agent in a Linux VM on macOS 27+ Apple Silicon.

## Prerequisites

- macOS 27 or later on Apple Silicon.
- Apple's `container` service and the supported guest kernel. Follow the
  [Apple backend prerequisites](backends.md#prerequisites), then start the
  service with `container system start`.
- An agent API key or account. See [Claude Code](claude-integration.md) or
  [Codex](codex-integration.md) for authentication options.

## Install

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/chr33s/iso/main/install.sh | bash
```

The installer verifies signed release checksums and, when `gh` is installed,
build provenance. For manual verification, source builds, or switching from
upstream, see [installation](installation.md).

## First run

### 1. Build the template

```sh
iso setup
```

Setup writes `~/.iso/config.jsonc` if it is missing and builds the default
Linux image with Docker, git, Claude Code, and Codex. VM state lives under
`~/.iso/`. Rerunning setup skips completed work.

### 2. Start your project

```sh
cd ~/code/my-project
iso up
```

This creates a VM and copies the project into `/workspace`. Running `iso up`
again reuses the instance or restarts it after a stop.

### 3. Connect

Launch either agent:

```sh
iso claude
# or
iso codex
```

Agents run with permission bypass enabled inside the VM. The VM is the
isolation boundary. Provider API keys are read from `ANTHROPIC_API_KEY` or
`OPENAI_API_KEY` in your host environment; account sign-in is covered in the
agent guides above.

For a shell, use `iso shell`. Exit the agent or shell to return to the host;
the VM keeps running. `iso status` shows its state and resource usage.

### 4. Bring changes back

From the host, review guest changes before applying them:

```sh
iso pull --review
```

The command prints the diff and a stage ID. After reviewing the changes,
apply that stage:

```sh
iso pull --apply --stage-id <stage-id>
```

Use `iso push` to send later host edits into the guest. See
[workspace sync](workspaces.md) for exclusions and conflict behavior.

### 5. Stop the VM

```sh
iso stop
```

Stopping preserves the disk. Next time, run `iso up` from the same project
directory. To delete the VM when you have saved its work, run `iso destroy`.

These examples assume one instance. With several instances, specify the name
for commands such as `iso shell` and `iso stop`; see
[running multiple instances](multi-instance.md).

## Next steps

- [Images and profiles](images-and-profiles.md): language toolchains, named
  images, and macOS guests.
- [Editor integration](editor.md): VS Code and Zed over SSH.
- [Devcontainers](devcontainer.md): use a project's existing configuration.
- [Security controls](credential-proxy.md): keep provider API keys on the host;
  review the [trust model](trust-model.md) for boundary limits.
- [Configuration](configuration.md) and [commands](commands.md): complete
  settings and CLI reference.
