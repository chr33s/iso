<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Command Reference

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

isolate creates isolated VM environments for running Claude Code and Codex. Supported hosts are macOS 27+ Apple Silicon, using the Apple sandbox backend.

## Global Flags

| Flag | Description |
|------|-------------|
| `--config <path>` | Path to config file, `.jsonc` or strict `.json` (default: `~/.iso/config.jsonc`). A `.toml` path stops with a [migration hint](configuration.md#migrating-from-toml). |
| `-v`, `--verbose` | Increase log verbosity. Once for debug, twice for trace. |
| `--version` | Print version and exit. |

## Instance Name Resolution

Most commands accept an optional instance name. isolate resolves the target instance with three rules:

- **Zero instances exist.** The command fails and tells you to run `iso up`.
- **One instance exists.** The name is optional. isolate selects it automatically.
- **Multiple instances exist.** The name is required. isolate lists available instances on error.

## Commands

### `up`

Ensure an environment exists and is running for a project directory.

```
iso up [DIR] [FLAGS]
```

`DIR` defaults to the current directory. isolate canonicalizes it and uses it as
the project identity for instance naming, devcontainer discovery, GitHub PAT
lookup, and future `iso up DIR` affinity. If a matching instance is already
running, `up` reports success without creating another VM. If a matching
instance is stopped, `up` restarts it. If no matching instance exists, `up`
creates one. Pass `--new-instance` with `--name` to skip the lookup and create
a second, separately named instance for the same directory or `--git-repo`
URL. That leaves the project with two matching instances, so later `iso up`
runs report the ambiguity instead of choosing one — address the instances by
name (`iso start <name>`, `iso shell <name>`) from then on.

By default, `up` copies/syncs the project into `/workspace`. Pass `--mount`
to use the mount transport for the project at `/workspace` instead. The Apple
backend has no host mounts, so this is a one-time sync at creation; use
`iso push` / `iso pull` afterwards. `--copy` is accepted as an explicit spelling of the default.
Use `--git-repo <url>` instead of `DIR` to clone a remote repository into
`/workspace` inside the guest.

| Flag | Description |
|------|-------------|
| `DIR` | Project directory (default: current directory) |
| `--name <name>` | Instance name to use when creating the project environment |
| `--new-instance` | Create a separate instance even when the project already has one (requires `--name`) |
| `--copy` | Copy/sync `DIR` into `/workspace` (default) |
| `--mount` | Mount `DIR` at `/workspace` instead of using `--copy` |
| `--extra-mount <spec>` | Additional host directory to mount into the guest (`HOST_PATH[:GUEST_PATH]`, repeatable; specify a guest path other than `/workspace` when using `--copy`) |
| `--git-repo <url>` | Clone a git repository into `/workspace` instead of copying a local project directory |
| `--vcpus <N>` | Number of vCPUs when creating a new instance |
| `--mem <MiB>` | Memory in MiB when creating a new instance |
| `--disk <GiB>` | Instance disk size when creating a new instance |
| `--no-agents` | Skip injecting Claude Code and Codex credentials/config into the VM |
| `--no-github` | Use `github = "off"` for this invocation and suppress the PAT setup prompt. See [scope and limitations](configuration.md#github-auth). |
| `--image <name>` | Named image to use when creating a new instance (default: `default`) |
| `--profile <list>` | Build or reuse a profile-derived image when creating a new instance, named from the sorted profiles (for example `node-python`) |
| `--exclude-git` | Skip `.git/` when copying/syncing local directories; does not strip `.git` from a `--git-repo` clone |
| `--no-prompt` | Suppress the interactive prompt to set up a scoped GitHub PAT when one is missing for the resolved repo |
| `--forward-port <spec>` | Forward a guest port to the host (`GUEST[:HOST]`, repeatable) |
| `--post-start <cmd>` | Shell command to run inside the guest after boot |
| `--env KEY=VALUE` | Env var to set in the guest (repeatable). A whole value `{vault:NAME}` is resolved from [`iso secrets`](#secrets) for each session |
| `--env-file <path>` | A `.env` file of guest env vars (`KEY=value`, quoted values, `export`, comments; `{vault:NAME}` references). Parsed strictly, never by a shell. `--env` wins over it |
| `--devcontainer <path>` | Explicit path to a `devcontainer.json` to use (skips discovery and prompt) |
| `--no-devcontainer` | Ignore any discovered `devcontainer.json` for this invocation |
| `--dry-run` | Translate `devcontainer.json` and print the report, then exit before any VM work |
| `--json` | With `--dry-run`, emit the resolved plan as JSON on stdout (`{ report, profiles, guest_user, vm }`) instead of the text report on stderr |

```
iso up .
iso up ~/code/my-project --mount
iso up . --profile python,node
iso up . --copy --forward-port 3000
iso up . --extra-mount ~/data:/data
iso up --git-repo https://github.com/trailofbits/coop.git
```

Creation options such as `--vcpus`, `--mem`, `--disk`, `--image`,
`--profile`, `--extra-mount`, `--git-repo`, `--exclude-git`, and
`--devcontainer` are applied only when `up` creates a new instance. `iso up
--profile <list>`
derives an image name from the sorted profile list, runs the same stale-image
check as `iso setup`, and builds or rebuilds that image if needed. Explicit
named images are unchanged: use `iso setup --image <name> --profile ...`
followed by `iso up --image <name>` when you want to choose the image name
yourself. If a matching project instance already exists, destroy it first to
recreate it with different creation options. Runtime startup options such as
`--forward-port`, `--post-start`, and `--env` can be used when `up` creates or
restarts an instance; if the matching instance is already running, stop it
first so those options can take effect.

When a local `devcontainer.json` was applied while creating the instance, isolate stores
its path and content hash. Later `iso up` reconnects or restarts warn if that
file changed, but the existing VM is not mutated automatically. Destroy and
recreate the instance to apply creation-time devcontainer changes such as
`features`, `hostRequirements`, `mounts`, `image`/`build`, or `remoteUser`.

### `quickstart` (removed)

`iso quickstart` has been removed. It now exits with an error that names the
replacement sequence: `iso setup` (create the config and build the image),
`iso up [DIR]`, then `iso claude` or `iso codex`.

### `init`

Deprecated alias for [`iso setup --config-only`](#setup). Prints a
deprecation note on stderr, then runs the same implementation.

```
iso init
```

No additional flags.

### `setup`

Run this once after installing isolate. It creates `~/.iso/config.jsonc` from
the commented template when no configuration exists, checks prerequisites, and
builds a template root filesystem with the Apple runtime. It never boots an
instance or launches an agent; follow it with `iso up`.

With `--config-only`, setup only writes the JSONC template and exits: it
installs nothing, provisions no credentials, and builds no image. An existing
configuration file is reported and left unchanged. Image options (such as
`--profile`, `--image`, `--rebuild`) are rejected with `--config-only`.

```
iso setup [FLAGS]
```

| Flag | Description |
|------|-------------|
| `--config-only` | Only create the JSONC configuration template, then exit |
| `-y`, `--yes` | Skip confirmation prompts (accept all) |
| `--vcpus <N>` | Number of vCPUs (overrides config) |
| `--mem <MiB>` | Memory in MiB (overrides config) |
| `--rebuild` | Force rebuild of template rootfs |
| `--profile <list>` | Comma-separated install profiles: `python`, `node`, `c`, `fuzz`, `rust`, `go` |
| `--extra-packages <list>` | Accepted for compatibility; the Apple backend ignores it with a warning (use a [custom profile](configuration.md#profiles-section)) |
| `--post-install <path>` | Accepted for compatibility; the Apple backend ignores it with a warning (use a custom profile's `post_install`) |
| `--template-size <GiB>` | Template rootfs size in GiB (default: 8) |
| `--image <name>` | Named image to build (default: `default`) |
| `--guest-user <name>` | Guest username to bake into the image (default: `ubuntu`). Use this for devcontainers that declare another `remoteUser`, such as `vscode`. |
| `--builder-timeout <duration>` | Duration to wait for setup image build commands before timing out. Accepts seconds by default, or `s`, `m`, and `h` suffixes. |
| `--workspace <dir>` | Scan for `.devcontainer/devcontainer.json` and offer to apply its `features` / `hostRequirements` to this setup. Supported public `ghcr.io/devcontainers/features/*` entries are resolved and baked into the image. |
| `--devcontainer <path>` | Explicit path to a `devcontainer.json` to use (skips discovery and prompt). |
| `--no-devcontainer` | Ignore any discovered `devcontainer.json` for this invocation. |
| `--dry-run` | Translate `devcontainer.json` and print the report, then exit before any setup work. |

```
iso setup -y --profile python,node --template-size 12
iso setup --config-only
iso setup --image ml-dev --profile python
iso setup -y --workspace . --devcontainer .devcontainer/devcontainer.json
```

See [docs/devcontainer.md](devcontainer.md) for the subset of `devcontainer.json` isolate reads.

### `devcontainer check`

Parse a `devcontainer.json` file and print the same translation report that `setup --dry-run` and `start --dry-run` use, without loading isolate config, checking for updates, setting up an image, or starting a VM. Setup-stage checks resolve supported public GHCR OCI Features so the report can show the digest and `install.sh` hash that would run.

```
iso devcontainer check <path> [--stage setup|start|both]
```

| Flag | Description |
|------|-------------|
| `<path>` | Path to the `devcontainer.json` file to inspect |
| `--stage <stage>` | Which lifecycle translation to report: `setup`, `start`, or `both` (default: `both`) |
| `--json` | Emit the report as JSON on stdout instead of the text table on stderr |

Use `--stage setup` to inspect setup-time keys such as `features`, `hostRequirements.cpus`, `hostRequirements.memory`, and `remoteUser`. Use `--stage start` to inspect start-time keys such as `postStartCommand`, `containerEnv`, `forwardPorts`, `mounts`, and `hostRequirements.storage`.

With `--json`, a single stage emits one report object (`{ entries, source_path, ignored_paths }`, or `null` when no file applied); `--stage both` emits `{ "setup": <report>, "start": <report> }`. Each entry is `{ key, status, source, value, note }`, with `status` one of `applied`/`overridden`/`unsupported`/`invalid` and `source` one of `cli`/`devcontainer`. CI can branch on the translation without scraping the table.

### `devcontainer ignore`

Record a persistent opt-out for a project directory. Future automatic discovery for that project skips `.devcontainer/devcontainer.json` and reports that the stored preference was used. Explicit `--devcontainer <path>` still applies a file for that run.

```
iso devcontainer ignore <project-dir>
```

### `devcontainer status`

Inspect persistent devcontainer opt-outs. With no project argument, this lists all stored opt-outs.

```
iso devcontainer status [project-dir]
```

### `devcontainer clear`

Remove a persistent devcontainer opt-out for a project. If the project directory was moved or deleted, use the absolute path shown by `iso devcontainer status`.

```
iso devcontainer clear <project-dir>
```

### `start`

Restart a stopped VM.

```
iso start [NAME] [FLAGS]
```

`start` normally restarts existing stopped instances. Use `iso up [DIR]` to
create or reconnect to a project environment. Without `NAME`, `start` restarts
the only stopped instance if exactly one exists; with multiple stopped
instances, pass the instance name.

| Flag | Description |
|------|-------------|
| `NAME` | Stopped instance name (optional only when exactly one stopped instance exists) |
| `--workspace <dir>` | Restart the stopped instance associated with this project path |
| `--no-agents` | Skip injecting Claude Code and Codex credentials/config into the VM |
| `--no-github` | Use `github = "off"` for this invocation and suppress the PAT setup prompt. See [scope and limitations](configuration.md#github-auth). |
| `--forward-port <spec>` | Forward a guest port to the host (`GUEST[:HOST]`, repeatable). Lives for the lifetime of the VM; torn down on `iso stop`. |
| `--no-prompt` | Suppress the interactive prompt to set up a scoped GitHub PAT when one is missing for the resolved repo (see [`iso github setup-pat`](#github)). |
| `--post-start <cmd>` | Shell command to run inside the guest after boot. Overrides the `post_start` configuration field. Failure is logged but does not fail the start. |
| `--env KEY=VALUE` | Env var to set in the guest (repeatable); a whole value `{vault:NAME}` is resolved from [`iso secrets`](#secrets). Overrides `--env-file`, `guest_env` config entries and any forwarded values with the same name. |
| `--env-file <path>` | A `.env` file of guest env vars, as for `up`. |
| `--devcontainer <path>` | Dry-run translation aid; normal restarts reject devcontainer creation options. |
| `--no-devcontainer` | Ignore any discovered `devcontainer.json` for this invocation (escape hatch for CI). |
| `--dry-run` | Translate `devcontainer.json` and print the report, then exit before any VM work. |
| `--json` | With `--dry-run`, emit the resolved plan as JSON on stdout instead of the text report on stderr. |

Normal `start` restarts an existing VM without re-reading or re-applying
`devcontainer.json`. If the instance was created with a devcontainer file, isolate
warns when the recorded file path now has different contents. See
[docs/devcontainer.md](devcontainer.md) for the supported keys, discovery
rules, and recreate guidance.

```
iso start
iso start my-project
iso start my-project --no-agents
iso start my-project --no-github
iso start --env RUST_LOG=info --env MY_FLAG=1
iso start --forward-port 3000 --forward-port 8080:18080
```

`--no-claude` is accepted as a deprecated alias for `--no-agents` and will be removed in a future release. Using it prints a deprecation warning.

### `shell`

Open an interactive shell in the VM, or run a single command non-interactively.

```
iso shell [NAME] [FLAGS] [-- COMMAND...]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `-- COMMAND...` | Command to run non-interactively (no PTY allocated) |

Without a trailing command, `shell` drops you into an interactive shell at `/workspace`. With a trailing command, it executes the command and returns its exit code.

```
iso shell
iso shell my-project
iso shell my-project -- cat /etc/os-release
```

### `claude`

Launch Claude Code inside the VM. The guest's `~/.claude/settings.json` (written during VM startup) sets `defaultMode: bypassPermissions` and `skipDangerousModePermissionPrompt: true`, so Claude Code runs without permission prompts — the VM itself is the isolation boundary. Use `--ask` to override the guest default for that session (isolate passes `--permission-mode default`).

```
iso claude [NAME] [FLAGS] [ARGS...]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--ask` | Prompt for permissions instead of skipping them |
| `ARGS...` | Extra arguments passed through to `claude` |

```
iso claude
iso claude my-project --ask
iso claude my-project -- --model sonnet
```

### `claude-agents`

Open the Claude Code agent view (`claude agents`) inside the VM. Claude Code's background agents are managed by its own daemon, so closing the terminal does not stop in-flight sessions; reconnect with `iso claude-agents` to see them again.

If the remote TUI stops responding, type Enter, then `~.` to disconnect the SSH session. isolate forces OpenSSH's interactive escape character to `~`, so this works even if your user SSH config disables or changes `EscapeChar`. If the terminal remains in a broken raw/no-echo state afterward, run `stty sane`.

```
iso claude-agents [NAME] [FLAGS] [ARGS...]
iso ca [NAME] [FLAGS] [ARGS...]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `ARGS...` | Extra arguments passed through to `claude agents` |

Alias: `ca`.

```
iso claude-agents
iso ca my-project
iso ca my-project -- --cwd /workspace
```

### `codex`

Launch Codex inside the VM. By default isolate passes `--dangerously-bypass-approvals-and-sandbox`, so Codex runs without its sandbox or approval prompts — parity with `iso claude`. The VM is the isolation boundary, and Codex's own Linux sandbox does not work in the guest (no functioning bubblewrap), so leaving it enabled makes every shell command Codex runs fail. Use `--ask` to keep Codex's sandbox and approval prompts for that session. With `"codex": { "auth": "chatgpt" }`, `iso codex` launches through the guest keyring wrapper. The `login` and `logout` subcommands are always launched without the bypass flag: they never start an agent session, so there is nothing to sandbox.

```
iso codex [NAME] [FLAGS] [ARGS...]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--ask` | Keep Codex's sandbox and approval prompts instead of bypassing them |
| `ARGS...` | Extra arguments passed through to `codex` |

```
iso codex
iso codex my-project --ask
iso codex my-project -- --model gpt-5
iso codex my-project -- login --device-auth
```

### `exec`

Run a command in the VM and print its output. No PTY is allocated and stdin is not forwarded; use `shell` for interactive work.

The command and its arguments must follow `--` so they are not mistaken for the instance name.

```
iso exec [NAME] -- COMMAND...
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `COMMAND...` | Command and arguments to run after `--` (required) |

```
iso exec -- uname -a
iso exec my-project -- docker ps
```

### `stop`

Gracefully stop a running VM. The instance disk is preserved. Use `start` to relaunch or `destroy` to remove it.

```
iso stop [NAME]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |

```
iso stop
iso stop my-project
```

### `destroy`

Stop the VM and remove its resources: disk, config, and SSH entries. Images are preserved unless you pass `--all`.

```
iso destroy [NAME] [FLAGS]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--all` | Also remove every image and the VM access key |

```
iso destroy my-project
iso destroy --all
```

### `list`

Print every instance with its state: `running`, `stopped`, or `unknown` when the backend cannot determine it (shown with a warning, for example an Apple sandbox instance with an unfinished operation). It never connects to a guest over SSH, so it returns quickly even when VMs are unreachable; the state comes from the runtime (`iso-sandbox inspect`). Use `status` instead when you need resource usage or per-instance detail.

```
iso list
iso ls
```

Alias: `ls`.

| Flag | Description |
|------|-------------|
| `--json` | Emit a JSON array (`[{ "name", "state" }, …]`) instead of the text table |

### `status`

Print instance status. Without a name, lists every instance with its state, image, backend, and resource usage (for running instances). An instance whose state cannot be probed is listed as `unknown` with a warning, rather than failing the whole listing. With a name, prints detailed status for that instance.

```
iso status [NAME]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (shows all if omitted) |
| `--json` | Emit machine-readable JSON instead of the text output |

```
iso status
iso status my-project
```

With `--json`, a bare `iso status` emits a JSON array and `iso status NAME`
emits a single object. Each carries the common fields — `name`, `state`
(`running`/`stopped`, or `unknown` in the bare-`status` array), `image`, `backend`
(always `apple-container`), and `usage`
(raw MiB / load, or `null` when stopped or the query fails). The rich
single-instance text report (guest IP, PID, SSH port, …) is text-only. JSON goes
to stdout; tracing stays on stderr, so `iso status --json | jq` stays clean.

```
$ iso status my-project --json
{
  "name": "my-project",
  "state": "running",
  "image": "default",
  "backend": "apple-container",
  "usage": { "load_1m": 0.12, "mem_used_mib": 512, "mem_total_mib": 2048,
             "disk_used_mib": 8192, "disk_total_mib": 20480 }
}
```

### `run`

Ensure a project environment is running, then launch an agent. This reuses
`up`'s project affinity. A running match is not pushed, rebuilt, or
bootstrapped again, and guest output is not copied back.

```
iso run <agent> [--workspace DIR] [--name NAME]
        [--image NAME | --profile LIST]
        [--prepare] [--rm] [--ask] [--dry-run] [--json]
        [-- AGENT_ARGS...]
```

| Flag | Description |
|------|-------------|
| `<agent>` | `claude`, `codex`, or an installed definition id |
| `--workspace <dir>` | Project directory (default: current directory) |
| `--name <name>` | Instance name. Must match the recorded workspace when both are set |
| `--image <name>` | Image for a new instance. Mutually exclusive with `--profile` |
| `--profile <list>` | Profile set for a new instance. Replaces a definition's environment selector |
| `--prepare` | Authorize image preparation. Preparation uses the host network and receives neither the workspace nor provider credentials |
| `--rm` | Create a new disposable instance and destroy it after the agent exits. Never attaches cleanup to an existing VM |
| `--ask` | Use the adapter's permission prompts instead of its default bypass |
| `--dry-run` | Print the prospective launch. Does not start a VM, build an image, resolve a credential, or check for updates |
| `--json` | With `--dry-run`, emit a versioned preview on stdout |
| `-- AGENT_ARGS` | Arguments forwarded to the agent. They are not interpreted by a host shell |

Filtered egress is not enabled. Definition network hints are shown and are not grants. `iso claude` and `iso codex` keep their existing behavior. A disposable instance is not adopted by a later `iso up`.

```
iso run claude
iso run codex --name payments
iso run claude --rm --workspace ./scratch
iso run codex --workspace ./service --dry-run --json
```

### `run-cleanup`

Reconcile an abandoned disposable run. Deletes an instance only when the session record, owner, marker, and sandbox id agree. A pending staged pull is retained.

```
iso run-cleanup --dry-run
iso run-cleanup --session <ID>
```

### `agent list`

List built-in and installed agent definitions. Invalid catalog files are reported and are not used.

```
iso agent list
```

### `agent inspect`

Show one definition without launching it, resolving a credential, or making a network request.

```
iso agent inspect <id> [--json]
```

### `agent add`

Validate a `.json` or `.jsonc` definition, show the canonical copy, and install it under `<data_dir>/agents/<id>.json`. Repository files are not discovered or approved automatically. `--yes` confirms installation; replacement also requires `--replace`.

```
iso agent add ./repo-helper.jsonc
iso agent add ./claude-review.jsonc --yes
```

A definition selects an image or profile and a reviewed adapter (`none`, `claude`, or `codex`). It cannot grant mounts, credentials, host commands, or network destinations.

### `agent update`

Update the coding agents (Claude Code and Codex) installed inside a running VM
to their latest versions, without rebuilding the golden image. Both agents are
installed "latest at build time" during `iso setup`, so they can go stale in
long-running VMs and in new VMs created from an old image. To refresh the image
itself instead, rebuild it with `iso setup --rebuild`.

```
iso agent update [NAME] [--claude] [--codex] [--check] [-y]
```

| Argument / Flag | Description |
|-----------------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--claude` | Update Claude Code |
| `--codex` | Update Codex |
| `--check` | Only report installed vs. latest versions — change nothing |
| `-y`, `--yes` | Skip the confirmation prompt |

With no agent flag, both agents are updated; passing both `--claude` and
`--codex` is the same as passing neither. The VM must be running.

`iso agent update --codex` re-runs OpenAI's native installer as the guest
user, including when migrating an older direct-binary installation. The full
package stays in the user's home directory, with `/usr/local/bin/codex` linked
to `~/.local/bin/codex`. The guest user can also run `codex update` directly
without sudo. Claude Code already auto-updates in the background;
`iso agent update --claude` runs `claude update` now, synchronously — a
convenience rather than a fix.

`--check` reports each agent's installed version and, for Codex, the latest
release on GitHub, changing nothing:

```
$ iso agent update my-project --check
Claude Code  1.2.3            up to date (auto-updates in background)
Codex        0.4.1 → 0.5.0    update available — run: iso agent update --codex
```

```
iso agent update                 # both agents, resolved instance
iso agent update my-project      # both agents, instance "my-project"
iso agent update --codex         # Codex only
iso agent update --check         # report versions, change nothing
```

### `model`

Show or switch a VM's model backend between cloud (Anthropic / OpenAI) and a
host-side local model server. The selection is per-instance and persists across
restarts. Switching rewrites the guest agent config; it never rebuilds or
restarts the VM.

```
iso model [NAME] [local|remote]
```

| Argument | Description |
|----------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `local` | Route this VM's agents at a host-side local model server |
| `remote` | Restore cloud defaults (Anthropic / OpenAI) |

With no subcommand, `model` prints the current mode and the endpoint each tool
(Claude, Codex) resolves to:

```
$ iso model my-project
Instance: my-project
Mode:     local
Claude   local — qwen2.5-coder:32b @ http://localhost:11434
Codex    cloud (no local endpoint configured)
```

`iso model NAME local` switches the VM to local mode. Each tool routes locally
only if it resolves an endpoint — from `claude.local_model` /
`codex.local_model` in the configuration, or from one saved earlier. For any tool
that has neither, and only in an interactive terminal, isolate prompts for a host
URL, model name, and optional auth token, then saves that endpoint for the
instance. (A non-interactive run declines the prompt.) If no tool ends up with
an endpoint, the command fails. Claude and Codex are independent: you can put
one on a local model and leave the other on cloud.

`iso model NAME remote` switches back to cloud defaults for both tools. Saved
endpoints are kept, so a later `local` does not re-prompt.

Switching never requires a VM restart — isolate rewrites the guest config live over
SSH when the VM is running, or saves it to apply on the next start. An
already-running `claude`/`codex` reads its config at launch, so relaunch the
agent (for example `iso claude NAME`) to pick up the change.

```
iso model
iso model my-project
iso model my-project local
iso model my-project remote
```

See the [`local_model`](configuration.md#local-model-routing) configuration
reference and the local-model sections of
[docs/claude-integration.md](claude-integration.md) and
[docs/codex-integration.md](codex-integration.md) for the resolution and
materialization details.

### `logs`

Stream the VM serial console output.

```
iso logs [NAME] [FLAGS]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `-f`, `--follow` | Follow log output (like `tail -f`) |

```
iso logs
iso logs my-project -f
```

### `push`

Copy a local directory into the running VM at `/workspace`. Defaults to the
host path recorded when the instance was created with `iso up`.

```
iso push [NAME] [FLAGS]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--dir <dir>` | Local directory to push (defaults to the workspace host path) |
| `--force` | Overwrite guest changes without confirmation |
| `--exclude-git` | Skip the `.git/` directory in this transfer |

```
iso push
iso push my-project --dir ./src --force
```

### `pull`

Copy the VM's `/workspace` to a local directory. Defaults to the host path
recorded when the instance was created with `iso up`.

```
iso pull [NAME] [FLAGS]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--dir <dir>` | Local directory to pull into (defaults to the workspace host path) |
| `--force` | Overwrite local changes without confirmation |
| `--exclude-git` | Skip the `.git/` directory in this transfer |
| `--review` | Pull into a host-side stage and print it for review instead of writing the local directory |
| `--stat` | With `--review`, print only the summary, not text diffs |
| `--apply` | Apply the current stage to the directory it was created for, then remove it |
| `--stage-id <id>` | With `--apply`, the id printed at review; any other stage is refused |
| `--discard` | Delete the current stage |

With `workspace.pull.mode = "stage"` ([configuration](configuration.md#workspace-section)),
a plain `iso pull` behaves like `--review`. See
[staged pulls](workspaces.md#staged-pulls).

```
iso pull
iso pull my-project --dir ./local-copy --force
iso pull my-project --review
iso pull my-project --apply --stage-id 1a2b3c4d
```

### `diff`

Stage the guest workspace and print what `iso pull --apply` would change:
added, modified and type-changed paths, then text diffs. Equivalent to
`iso pull --review`.

```
iso diff [NAME] [--dir <dir>] [--exclude-git] [--stat]
```

### `editor`

Open an editor (VS Code or Zed) connected to the guest VM over SSH remote.
`iso vscode` remains as an alias.

```
iso editor [NAME] [--project PATH] [--editor code|zed] [--clean]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--project <path>` | Remote path to open in the editor (default: `/workspace`) |
| `--editor <code\|zed>` | Editor to launch. Omitted: try VS Code first, then Zed. |
| `--clean` | Remove the SSH config entry for this instance and exit |

```
iso editor
iso editor my-project --project /workspace/subdir
iso editor my-project --editor zed
iso editor my-project --clean
```

### `ssh-config`

Install a `coop-apple-<name>` alias into `~/.ssh/config` so plain `ssh`, `scp`, and
`rsync` reach the guest without remembering its host, port, user, or key. This
is the same SSH config block `iso editor` writes, but without launching an
editor.

```
iso ssh-config [NAME] [--clean]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--clean` | Remove the SSH config entry for this instance and exit |

```
iso ssh-config
iso ssh-config my-project
ssh coop-apple-my-project
scp ./file coop-apple-my-project:/workspace/
rsync -az ./dir/ coop-apple-my-project:/workspace/dir/
iso ssh-config my-project --clean
```

The alias is created only when you run `iso ssh-config` (or `iso editor`).
The lifecycle keeps it tidy: `iso stop` and `iso destroy` remove the block,
and `iso start` refreshes an already-installed block so it stays valid across
a restart, since the guest address can change.

The block pins each guest's host key: it sets `StrictHostKeyChecking yes` with
the instance's own `known_hosts` and `HostKeyAlias <machine>.iso`, plus
`ForwardAgent no` and `IdentityAgent none`, and a changed key is refused. Pins
recorded by older builds under the `.coop-apple` alias no longer match and the
instance is refused until you re-enroll it (`iso restore <name> --reprovision`)
or recreate it.

Use `ssh-config` for ad-hoc copies of arbitrary paths. To sync the tracked
workspace directory in bulk, use [`push`](#push) / [`pull`](#pull) instead.

### `images`

List or delete golden images. Without flags, prints every image with its profiles, creation date, and size.

```
iso images [FLAGS]
```

| Flag | Description |
|------|-------------|
| `--delete <name>` | Delete a named image |
| `--json` | Emit a JSON array instead of the text table |

```
iso images
iso images --delete old-image
iso images inspect default
iso images cache status
```

`inspect` reports host-recorded provenance. Unknown legacy fields stay unknown. Runtime cache allocation is reported as unavailable rather than guessed. `cache status` distinguishes manifests from instance records and does not sum shared disk space. Prune and edit are not available.

With `--json`, each element is `{ "name", "profiles", "created", "size_bytes" }`.
Absence is modelled honestly: `profiles` is `[]` (not `"none"`), `created` is
`null` (not `"unknown"`), and `size_bytes` is the raw byte count (the text path's
`"8.0 GiB"` is presentation only), or `null` on the Apple sandbox backend,
whose images live in the runtime's image store rather than isolate's data
directory.

### `resize`

Change a stopped instance's disk size, memory, or vCPU count. The VM must
be stopped first. At least one of `--size`, `--mem`, or `--vcpus` is required;
they can be combined in a single command.

```
iso resize [NAME] [--size <SIZE>] [--mem <MIB>] [--vcpus <N>] [--start]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--size <size>` | New disk size. Absolute: `150` or `150G`. Relative: `+20` or `+20G`. |
| `--mem <mib>` | New memory in MiB (minimum 128). |
| `--vcpus <n>` | New vCPU count (> 0). |
| `--start` | Start the instance after applying the change instead of leaving it stopped. |

Absolute disk values set the disk to that exact size; a `+` prefix adds to the
current size. Memory and vCPU changes are written to the instance's backend
record in the runtime, which is authoritative — the value survives restarts
and is reported by `iso status`. The global `vm` settings in the
configuration only seed these values for *new* instances.

By default the instance is left stopped and the change takes effect on the next
`iso start`. Pass `--start` to boot it immediately. The resource change is
journaled, so an interrupted change is recovered by the next command that
touches the instance.

Combining `--size` with `--mem`/`--vcpus` applies the disk change first, then the
machine-resource change; the two are separate artifacts and are not applied
transactionally, so if the second step fails the disk change has already taken
effect.

```
iso resize my-project --size 150G
iso resize --size +20
iso resize my-project --mem 8192 --vcpus 4
iso resize my-project --mem 4096 --start
```

### `commit`

Save a stopped instance's filesystem as a reusable image, like `docker container commit`. The committed image is an ordinary isolate image: `iso images` lists it and `iso up --image <name>` launches new instances from it. The instance must be stopped first so the filesystem is consistent.

```
iso commit [NAME] --image <name> [FLAGS]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--image <name>` | Name of the image to create (required) |
| `--force` | Overwrite an existing image with the same name |

```
iso stop my-project
iso commit my-project --image my-project-baseline
iso up . --image my-project-baseline --name fork
```

### `restore`

Roll a stopped instance back to an image's filesystem in place. The instance keeps its name, index, IP, and workspace association — only the disk is replaced and its recorded image is updated. Run `iso start` afterwards to bring it back up.

On the Apple sandbox backend, the restored disk has no SSH host keys, so the next `iso start` pins the key the guest generates. The address is not guaranteed either: a sandbox moves to a new subnet when its old one has been quarantined (see [backends.md](backends.md#stop-destroy-recovery)).

This pairs with `commit` for a known-good checkpoint before a risky run:

```
iso stop my-project
iso commit my-project --image safe-point   # checkpoint
iso start my-project
# ... a bypass-permissions agent run trashes the environment ...
iso stop my-project
iso restore my-project --image safe-point   # back to the checkpoint, same VM
iso start my-project
```

```
iso restore [NAME] [--image <name>] [--reprovision] [-y] [--no-agents] [--no-prompt]
```

| Flag | Description |
|------|-------------|
| `NAME` | Instance name (required if multiple instances exist) |
| `--image <name>` | Image to restore from. Required on its own; with `--reprovision` it defaults to the image the instance already records |
| `--reprovision` | Provision the new disk as a first boot and leave the instance running (see below) |
| `-y`, `--yes` | Skip the `--reprovision` confirmation prompt (required when stdin is not a TTY). Requires `--reprovision` |
| `--no-agents` | Skip injecting Claude Code and Codex credentials/config into the VM. Requires `--reprovision` |
| `--no-prompt` | Suppress the interactive prompt to set up a scoped GitHub PAT. Requires `--reprovision` |

Unlike `destroy` + `up --image`, `restore` keeps the same instance identity (name, index, IP) instead of allocating a new one. The disk is reset to the image's size, so restoring an image built before a `iso resize` returns the instance to the smaller size.

#### `--reprovision`

The `iso start` in the checkpoint recipe above deliberately does *not* re-sync `/workspace` or reinstall plugins: a checkpoint image already carries both, and overwriting them would defeat the rollback. Restoring a **base** image is the other case — nothing on that disk to preserve — so a plain `iso start` there leaves an empty `/workspace` and no plugins.

`--reprovision` is that case. Unlike a plain `restore`, which requires a stopped instance, it also accepts a running one and stops it itself. The disk is replaced as usual, and the guest is then provisioned as a **first boot**: the recorded workspace is re-synced, re-cloned or re-mounted, agents are re-bootstrapped, and plugins, marketplaces and MCP servers are reinstalled. The instance is left **running** rather than stopped, so no follow-up `iso start` is needed.

It is also the way to start an instance over without re-typing every flag it was created with — the inverse of "destroy it and remember what I passed":

```
iso restore my-project --reprovision                  # confirm, then reset to the recorded image
iso restore my-project --reprovision -y               # no prompt (required in scripts)
iso restore my-project --reprovision --image rust-24  # reset onto a different image
```

Kept across the wipe, because isolate persists them host-side:

| Setting | Where it lives |
|---------|----------------|
| Name, index, guest IP | `instance.json` |
| Image | `instance.json` (updated when `--image` is given) |
| Disk size | read before the swap and re-grown after it, since the image's disk is template-sized |
| vCPUs and memory | backend VM config, which the swap does not touch |
| Workspace association (copy, git clone, or mount) | `workspace.json` |
| Port forwards, including a devcontainer's `forwardPorts` | `forwards.json` |
| Guest env, including a devcontainer's `containerEnv` | `guest_env.json` |
| Model mode and proxy settings | `model.json` / `proxy.json` |
| Credentials saved in the host secret store | unchanged; guest forwarding depends on the configured auth mode |

**Not replayed**, because isolate does not persist them:

- Extra `--extra-mount` directories. Only the *primary* workspace source is recorded in `workspace.json`, so isolate replays none of them. isolate does not guarantee that such a mount is served again after the reboot. There is no way to re-add a mount to an existing instance — `--extra-mount` is creation-only, and `iso push` writes to the recorded workspace path — so recovering one means `iso destroy` and a fresh `iso up`.
- `--exclude-git`. A workspace originally pushed without `.git/` is re-synced with it.
- A devcontainer's `postStartCommand`, which reaches the guest only during `iso up`. Its `features` are baked into the image and so do survive. (`postCreateCommand` is unaffected because isolate does not implement it — it is reported as an unrecognised `devcontainer.json` key.)

Before replacing the disk, isolate checks that the image exists, the state files
parse, the recorded workspace directory is still there, and host ports for
forwards are available. A later failure leaves the instance in place with a
partly provisioned guest. Re-running the command replaces the disk again and
restarts provisioning; save any guest-only work before retrying.

Compared with the neighbouring commands:

| Command | Disk | Instance identity | Workspace / plugins | Left |
|---------|------|-------------------|---------------------|------|
| `destroy` + `up` | fresh | **new** name, index, IP | re-synced; every flag re-typed | running |
| `restore` + `start` | replaced | kept | left as the image had them | running |
| `restore --reprovision` | replaced | kept | re-synced, plugins reinstalled | running |

### `profiles`

List or inspect available profiles. With no subcommand, lists every profile (builtin and custom).

```
iso profiles [SUBCOMMAND]
```

| Subcommand | Description |
|------------|-------------|
| `list` | List builtin and custom profiles with a one-line summary each (default) |
| `show <name>` | Print the full definition of a profile: apt packages, pre/post-install scripts, marketplaces, plugins |

```
iso profiles
iso profiles list
iso profiles list --json
iso profiles show rust
```

`list` groups builtin and custom profiles separately. `show` resolves the name against custom profiles first, then builtins, and prints `(custom)` or `(builtin)` next to the name.

`iso profiles list --json` emits `{ "builtin": [...], "custom": [...] }`, each entry `{ "name", "summary" }`.

### `update`

Replace the running isolate binary with a release from `github.com/chr33s/iso`.
Release tags come from `swift`. The updater verifies the platform tarball's
SHA-256 and, when `gh` is installed, its repository build-provenance attestation.
The updater installs the bundled `iso-sandbox` and `iso-proxy` before replacing
the host. Each file replacement is atomic; the set of files is not a single
transaction. If a later replacement fails, rerun the installer for the same
release to restore a matching set. Missing companions are rejected before replacement.
Until a fork release is published and verified, rebuild from source.

No authentication is required. When [`gh`](https://cli.github.com/) is authenticated against `github.com` or `GITHUB_TOKEN` is set, `iso update` uses it, which helps avoid GitHub API rate limits.

```
iso update [FLAGS]
```

| Flag | Description |
|------|-------------|
| `--check` | Report whether a newer release exists. Do not download or install. |
| `--force` | Reinstall even if the current binary is already at the target version. |
| `--version <VERSION>` | Install a specific release tag (e.g. `v0.3.2` or `0.3.2`). |
| `--allow-downgrade` | Permit installing a release older than the current binary; refused otherwise. |
| `-y`, `--yes` | Skip the interactive confirmation prompt. |

If isolate is installed in a protected directory (e.g. `/usr/local/bin`), run with `sudo`. Dev builds (built from an untagged or dirty tree) refuse to self-update; use `install.sh` to replace them.

```
iso update --check
iso update
iso update --yes
iso update --version v0.3.2
iso update --force
iso update --version v0.3.1 --allow-downgrade
```

See also the [`updates` section](configuration.md#updates-section) of the configuration reference for the background-notification settings.

### `uninstall`

Remove the isolate binary and, optionally, its data directories (`~/.iso` and the update-check state). Refuses to remove the binary when it lives in a build-output directory (`.build/debug/`, `.build/release/`, or `.build/<triple>/…`) so `swift run iso uninstall` does not delete your build artifact.

```
iso uninstall [FLAGS]
```

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Skip interactive confirmation prompts. Removes data unless `--keep-data` is set. |
| `--keep-data` | Remove only the binary; preserve `~/.iso` and the update-check state. Conflicts with `--purge`. |
| `--purge` | Also remove `~/.iso` and the update-check state without prompting. Conflicts with `--keep-data`. Pairs with `--yes` for CI. |

Without `--yes`, the command prints a summary (binary path, data directory, instance and image counts) and asks for confirmation. A second prompt asks whether to also remove the data directory unless `--keep-data` or `--purge` is set. Non-interactive runs require `--yes`.

If the binary lives in a protected directory (e.g. `/usr/local/bin`), run with `sudo`. A config file outside the data directory is left in place and a note is printed.

```
iso uninstall                       # interactive: prompts for binary and data
iso uninstall --yes                 # CI: remove binary and data, no prompts
iso uninstall --yes --keep-data     # CI: remove binary only
iso uninstall --yes --purge         # CI: remove binary and data, explicit
```

### `completions`

Print a static shell completion script for bash, zsh, or fish. Completion covers commands, options, and fixed values only; instance, image, and profile names are not completed (use `iso list`, `iso images`, `iso profiles`). See [docs/shell-completion.md](shell-completion.md) for full setup recipes per shell.

```
iso completions <SHELL>
```

| Argument | Description |
|----------|-------------|
| `SHELL` | Target shell: `bash`, `zsh`, or `fish`. `powershell` and `elvish` are no longer provided and fail with an error. |

```
iso completions bash | sudo tee /etc/bash_completion.d/iso > /dev/null
iso completions bash > ~/.local/share/bash-completion/completions/iso
iso completions zsh > ~/.zfunc/_iso
iso completions fish > ~/.config/fish/completions/iso.fish
```

### `github`

Manage GitHub authentication. Specifically, the scoped fine-grained PAT (FGPAT) workflow that pairs `"pat"` mode with per-repo `github.pat["owner/repo"]` entries in the configuration. See the [GitHub auth section](configuration.md#github-auth) of the configuration reference for the full data model.

```
iso github <subcommand>
```

| Subcommand | Effect |
|------------|--------|
| `assign-pat --vm NAME --repo owner/name` | Persist selection of an existing stored entry for this VM; `--repo` is the entry key, not its full permission scope. Works while stopped. |
| `unassign-pat --vm NAME` | Remove only the VM association; leave the shared credential intact. |
| `setup-pat [--repo owner/name]` | Run the wizard end-to-end: open the GitHub PAT-creation form, validate the pasted token against `api.github.com`, store it in the macOS Keychain (no fallback store), and write a `github.pat["owner/repo"]` entry that references it with `cmd:`. The repo is auto-detected from `git remote get-url origin` when `--repo` is omitted. |
| `rotate-pat --repo owner/name` | Re-run the wizard for an existing entry (FGPATs expire — max 1 year). |
| `status [--vm NAME] [--probe] [--json]` | List configured entries and whether they are stored in the macOS Keychain. By default the `cmd:` reference is *not* resolved (so no Keychain or other prompt fires). Pass `--probe` to also resolve each entry (one secret-store unlock covers every `vault:` entry) and report whether the secret store still serves it. Pass `--json` for machine-readable output. |
| `forget-pat --repo owner/name` | Drop the `github.pat["owner/repo"]` entry and, when it references isolate's Keychain item, delete that item. A user-authored `cmd:` reference is left for you to clean up. Does **not** add a skip marker — use the auto-prompt's `never` answer if you want isolate to stop asking about this repo. Does **not** revoke the PAT on GitHub. |

```
iso github setup-pat --repo trailofbits/coop
iso github status
iso github status --probe
iso github status --json
iso github rotate-pat --repo trailofbits/coop
iso github forget-pat --repo trailofbits/coop
```

`iso github status --json` emits `{ "mode", "entries", "skip" }`. `mode` is
`off`/`auto`/`env`/`pat`; each entry is `{ "repo", "storage", "probe" }` with
`storage` either `macos_keychain` (isolate's Keychain reference) or `null` (any
other `cmd:` reference) and `probe` (`ok`/`unexpected_format`/
`resolve_failed`, or `null` unless `--probe`). The token value is never emitted.

With `--vm NAME`, status also includes `vm: { "name", "assigned_entry", "source" }`.
`assigned_entry` is a stored entry key or `null`; `source` is `assignment`,
`missing_assignment`, `repository`, `auto`, `env`, `off`, or `no_matching_entry`.
The configured entry list remains present. `missing_assignment` means restore
the entry or unassign it; malformed state produces an error. `--probe` tests
retrieval, not GitHub permissions. See [VM PAT assignments](configuration.md#assign-an-existing-pat-to-a-vm)
for precedence, opt-out, conflicts, rotation, and bootstrap timing.

### `proxy`

Manage the host-side credential-injecting proxy. When a `proxy.<provider>`
upstream is configured, isolate runs a `iso-proxy` process on the host for the
lifetime of each remote-mode VM: the guest is pointed at the proxy and holds
only a per-instance capability token, while the real API key stays on the host
and is injected onto outbound requests the guest never sees. Applies only in
remote model mode (`iso model <vm> remote`); local mode takes precedence. See
the [credential proxy guide](credential-proxy.md) and the
[`proxy` configuration reference](configuration.md#proxy-section) for the data
model.

| Subcommand | Effect |
|------------|--------|
| `setup [--anthropic] [--openai] [--vm <name>] [--api-key]` | Store a provider credential in the macOS Keychain and wire its `cmd:` reference into `proxy.<provider>` (the default) or a per-VM override. There is no fallback store; if the Keychain is unavailable, setup fails. Anthropic (Claude) is the default provider; pass `--openai` for Codex. `--vm <name>` stores the credential as a per-VM override in that instance's state instead of the global default. Anthropic only: `--api-key` stores an API key (`x-api-key`) instead of a Claude `setup-token`; ignored for `--openai`, whose keys are always injected as `Authorization: Bearer`. |
| `status [--vm <name>]` | Show what each VM's agents resolve to (per-VM override → default → off), with credentials redacted. Pass `--vm <name>` for the effective resolution of a single VM instead of all. |

```
iso proxy setup
iso proxy setup --openai
iso proxy setup --vm my-project
iso proxy setup --api-key
iso proxy status
iso proxy status --vm my-project
```

### `secrets`

Manage the local secret store under `<data_dir>/secrets/`. Unlocking it
needs both your passphrase (scrypt) and this Mac's Secure Enclave key (Touch ID
or password), every time; nothing stays unlocked between commands.
**There is no recovery path**: if this Mac or its Secure Enclave key is lost,
the stored secrets are gone, even with the passphrase and a copy of the files.
See [the design](design/embedded-secrets-spec.md).

```
iso secrets init [--accept-no-recovery]
iso secrets set <name> [--stdin]
iso secrets rm <name>
iso secrets list
iso secrets status
```

| Subcommand | Description |
|------|-------------|
| `init` | Create the store after the no-recovery warning. `--accept-no-recovery` skips the confirmation prompt (automation). |
| `set <name>` | Add or replace a secret. The value is prompted without echo, or read byte for byte from stdin with `--stdin`; it never appears on the command line. |
| `rm <name>` | Remove a secret. It cannot un-send a value already given to a running VM or proxy. |
| `list` | Print secret names and update times; never values. |
| `status` | Report whether the store exists and the Secure Enclave is usable, without unlocking. |

`iso uninstall --purge` does not remove the store; delete `<data_dir>/secrets/`
yourself if you want it gone.

Names match `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`. The passphrase is read from the
terminal (`/dev/tty`) with echo off; for automation, pass it on an inherited
descriptor named by `ISO_SECRETS_PASSPHRASE_FD` (a regular file must not be
group- or world-readable). There is no passphrase flag or plaintext variable.

#### Secrets in the guest environment

`--env NAME={vault:secret}` or a `NAME={vault:secret}` line in an `--env-file`
puts a stored secret into the guest environment. Only the reference is saved
with the instance; the value is resolved each time isolate opens a session, so
every `iso shell`, `exec` and agent launch of that instance asks for the
passphrase and Touch ID once. **The value is visible to everything in the
guest** — the Secure Enclave protects it at rest on the host only. The
reference must be the whole value (`URL=postgres://u:{vault:pw}@h` is
rejected).

A reference on a provider credential variable (`ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`) is
different: it never enters the guest. It becomes that instance's
[credential proxy](credential-proxy.md) credential, ahead of any per-VM
override or config default, and the guest gets only the proxy's capability
token. At most one per provider; under `proxy.mode = "off"` it is an error.
A generic reference may not name a secret that a proxy credential also reads. `up`, `start` and
`restore --reprovision` resolve every reference before doing VM work, so a
wrong passphrase or a missing secret stops them early. References work only
in `--env` and `--env-file`; a `{vault:` in devcontainer `containerEnv` or
config `guest_env` is passed as literal text (with a warning for
`containerEnv`). Once an instance stores a reference, its `guest_env.json`
uses a newer format that older isolate releases refuse to read; downgrading such
an instance is unsupported.

### `audit`

Show the boundary events isolate recorded for an instance: each boot's egress,
`proxy.mode`, proxied providers, provider-secret variable names and the
number of stored-secret references; raw provider variables forwarded into the
guest (names only); stops; and workspace returns (counts). Values, tokens,
file contents and request bodies are never recorded. The log is
`<instance>/audit.jsonl`, owner-only, capped at 1 MiB (older entries are
dropped first).

```
iso audit [NAME] [--suggest-config]
```

`--suggest-config` prints an advisory JSONC fragment that only narrows what
was observed (for example `proxy.mode` `required` when every boot was proxied
and no raw key was forwarded). Guest network use is not observed, so `egress`
is suggested only when every boot already ran without it.

### `validate`

Check the configuration file and prerequisites. Prints warnings and confirms the config loads correctly. A `github.pat` entry stored with `vault:` is reported as `stored secret, not resolved` and never unlocks the secret store. With `--probe`, also exercises each `github.pat` entry against `api.github.com` to confirm the token is still live; `vault:` entries are resolved in one unlock.

```
iso validate
iso validate --probe
```

| Flag | Description |
|------|-------------|
| `--probe` | For each `github.pat` entry, resolve the token and call `GET /user` on `api.github.com` to confirm it authenticates. Network-dependent; may trigger a Keychain (or your own `cmd:` tool's) prompt, and asks for the secret-store passphrase and Touch ID once when an entry is a `vault:` reference. |
