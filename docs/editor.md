<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Editor Integration (VS Code, Zed)

isolate opens VS Code or Zed on a guest VM over SSH remote development. The
same managed SSH alias works with JetBrains IDEs, Cursor, and any editor that
supports SSH remote development.

## Quick start

```bash
iso code .
iso zed .
```

Each command:

1. Creates, restarts or reuses the project's instance exactly as
   [`iso up`](commands.md#up) does.
2. Writes or refreshes the pinned `iso-{name}` block in `~/.ssh/config`.
3. Launches only the named editor on `/workspace` through that alias.

## Project-aware commands vs. instance attach

| Command | Use it to |
|---|---|
| `iso code [DIR]`, `iso zed [DIR]` | Open a project: ensure its VM is running, then open the editor |
| `iso editor [NAME]` | Attach an editor to an instance that is already running |

```
iso code [DIR] [--project PATH] [--no-launch] [up options]
iso zed  [DIR] [--project PATH] [--no-launch] [up options]
iso editor [NAME] [--project PATH] [--editor code|zed] [--clean]
```

`iso code` and `iso zed` accept every `iso up` creation and restart option
(`--name`, `--mount`, `--image`, `--devcontainer`, `--egress`, ...) and apply
them with the same rules; devcontainer handling is identical. `--project` sets
the absolute guest directory to open (default `/workspace`); it is refused
when it names a directory in your home folder and no `DIR` is given, since
that path was almost certainly meant as `DIR` (guest paths such as `/opt` or
`/tmp` are fine). `--no-launch`
prepares the instance and alias without starting the editor; with
`--output json` it returns the alias and the editor's launch target
([machine interface](machine-interface.md#code-zed)).

These commands never fall back to a different editor: if Zed is not
installed, `iso zed` fails rather than opening VS Code.

`iso editor` keeps its auto-detection: with no `--editor`, it tries VS Code,
then Zed. A strategy that cannot be launched at all (binary missing, or
present but not executable) counts as a miss, so the chain continues. If an
editor starts but exits unsuccessfully or does not return within five
minutes (it is then killed), isolate tries only that editor's
remaining strategies and reports the failure instead of opening a different
editor. `iso editor` also prints the SSH config entry to stderr for manual use;
`iso code` / `iso zed` do not. `--clean` removes the instance's SSH config
entry and exits.

```bash
iso editor my-instance --project /workspace/frontend
iso editor my-instance --editor zed
```

## SSH boundary

Editors connect only through the managed `iso-{name}` alias, written after the
instance has passed the runtime's qualification and isolation checks. The
block pins the guest host key and disables agent forwarding
(`ForwardAgent no`, `IdentityAgent none`). isolate re-checks the instance's
readiness immediately before each editor launch; a changed host key or a
failed isolation check stops the launch.

The alias is a connection target, not an agent session. `iso claude` and
`iso codex` prepare credentials and their environment immediately before
launch, so `ssh iso-{name} claude` is not equivalent to them.

## VS Code

VS Code opens with `code --remote ssh-remote+iso-{name} /workspace`. If the
`code` CLI is not on `PATH`, isolate opens a
`vscode://vscode-remote/ssh-remote+iso-{name}/workspace` URL instead (path
percent-encoded), which reaches a VS Code that is already running. To install
the CLI, open VS Code and run:

> Cmd+Shift+P, then "Shell Command: Install 'code' command in PATH"

## Zed

Zed opens with `zed ssh://iso-{name}/workspace` (fallback: an
`open zed://ssh/...` URL when the `zed` CLI is not on `PATH`). Guest paths are
percent-encoded in the URL. Zed shells out to the system `ssh`, so it picks up
the alias with no extra setup. To install the `zed` CLI, open Zed and run:

> Cmd+Shift+P, then "cli: install"

Zed's protocol runs over the SSH channel, so anything the guest shell prints
on non-interactive startup corrupts the handshake (Zed hangs at "Starting
proxy…"). Keep guest rc files quiet for non-interactive shells.

## Restricted egress

isolate never widens egress for an editor. Both editors install a remote
server inside the guest on first connect, which needs network access:

- **Zed** downloads `zed-remote-server` from zed.dev. When egress is `none` or
  `filtered`, `iso zed` (and `iso editor` before it tries Zed) prints a
  warning recommending
  `upload_binary_over_ssh` for the alias in Zed's settings; isolate does not
  edit them:

  ```json
  {
    "ssh_connections": [
      { "host": "iso-my-instance", "upload_binary_over_ssh": true }
    ]
  }
  ```
- **VS Code** downloads VS Code Server. Under restricted egress, set
  Remote-SSH's `remote.SSH.localServerDownload` to `always` so the
  server is transferred over SSH.

## Adding a provider

Editor providers are compiled in (`Sources/IsoHost/Editor/`); there is no
plugin interface. A new provider is an `EditorProviderID` case, an
`EditorProvider` that turns the alias and guest path into launch strategies,
a top-level command, tests and docs. It needs no change to the lifecycle, runtime, SSH
config, workspace, credential proxy or isolation code.

## SSH config management

isolate writes SSH config entries to `~/.ssh/config`, delimited by marker comments:

```
# iso START iso-my-instance
Host iso-my-instance
    HostName 10.231.3.2
    Port 22
    User ubuntu
    IdentityFile /Users/me/.iso/backends/apple-container-v1/vm_key
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile /Users/me/.iso/backends/apple-container-v1/instances/my-instance/known_hosts
    GlobalKnownHostsFile /dev/null
    HostKeyAlias <machine>.iso
    UpdateHostKeys no
    ForwardAgent no
    IdentityAgent none
    LogLevel ERROR
# iso END
```

The block pins the guest's host key: a changed key is refused rather than
accepted. The `iso-` prefix and markers identify managed entries. An explicit
user-defined alias with the same name is refused.

Each run of `iso editor`, `iso code` or `iso zed` replaces the existing block for that instance, or creates one if none exists. To install the same block without launching an editor — for plain `ssh`/`scp`/`rsync` — use [`iso ssh-config`](commands.md#ssh-config).

### Cleanup

- **`iso editor NAME --clean`** (or **`iso ssh-config NAME --clean`**) removes the SSH config entry for the specified instance and exits. This cleans up the config without destroying the instance.
- **`iso destroy`** removes the SSH config block for the destroyed instance.
- **`iso destroy --all`** removes all isolate SSH config blocks.
- **`iso stop`** leaves the SSH config block in place. A stale entry has no effect when the VM is not running, and `iso start` refreshes it on the next boot (the guest address can change across starts).

## Other editors

Any SSH-capable editor can use the `iso-{name}` alias. Install it without
launching an editor with `iso ssh-config NAME`, or with `iso code . --no-launch`.

### JetBrains (IntelliJ, GoLand, CLion, etc.)

1. Run `iso ssh-config my-instance` to install the SSH alias.
2. In your JetBrains IDE, open **File > Remote Development > SSH Connection**.
3. Select the `iso-{name}` host.
4. Set the project directory to `/workspace`.

### Cursor

Cursor uses the same Remote SSH extension as VS Code. Run `iso ssh-config` and the host appears in Cursor's SSH targets. You can also launch it directly:

```bash
cursor --remote ssh-remote+iso-my-instance /workspace
```

### Manual SSH

The host alias works from any terminal:

```bash
ssh iso-my-instance
```

The SSH config block supplies the hostname, port, user, key, and host-key verification settings.

## Port forwarding

Use `--forward-port` with [`iso up`](commands.md#up) or
[`iso start`](commands.md#start) for forwards managed for the VM lifetime.
For a temporary forward while an editor is connected, use SSH directly:

```bash
ssh -L 3000:localhost:3000 iso-my-instance
```

This binds local port 3000 to port 3000 inside the guest. Stack multiple `-L` flags for additional ports:

```bash
ssh -L 3000:localhost:3000 -L 5432:localhost:5432 iso-my-instance
```

VS Code's Remote SSH extension exposes a Ports panel that handles forwarding once connected.

## Interaction with push and pull

`iso push` and `iso pull` sync files between host and guest. Both work while an editor is connected; there is no need to disconnect.

Watch for conflicts. `iso push` overwrites guest files, and `iso pull` overwrites local files. Both commands check for uncommitted git changes and refuse to proceed unless you pass `--force`.
