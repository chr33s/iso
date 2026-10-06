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
3. Launches only the named editor on `/workspace`, by default as a new,
   sandboxed instance (see [Editor security](#editor-security)) that `iso`
   supervises until you quit it.

## Editor security

The guest is untrusted, and so is the editor server running in it: a guest
with root can replace VS Code Server or `zed-remote-server` and send the local
editor anything its protocol allows. isolate therefore treats a compromised
local editor as the expected case and confines it.

```
iso code . --editor-security sandboxed   # default
iso code . --editor-security unsafe
iso zed . --editor-allow clipboard
```

or in `~/.iso/config.jsonc`:

```jsonc
"editor": { "security": "sandboxed", "allow": [] }
```

**`sandboxed`** (default) runs the signed application from `/Applications`
(or `~/Applications`) directly, never its CLI, as a new instance with:

- a throwaway profile, HOME and temporary directory in
  `/private/tmp/iso-editor-<uid>/`, deleted when the session ends. Your normal
  editor settings, extensions, sign-ins and running windows are never used;
- none of your shell environment (no API keys, `SSH_AUTH_SOCK`, proxies or
  `NODE_OPTIONS`);
- a fresh SSH key, authorized in the guest for this session only and usable
  only through a loopback tunnel `iso` runs; isolate's own VM key never
  reaches the editor;
- a deny-by-default macOS Seatbelt profile: no access to your files, the
  keychain, the clipboard, other apps (no opening URLs or documents), other
  local services or the internet;
- supervision: `iso` stays in the foreground and ends the session (editor,
  tunnel, key and profile) when you quit the editor, press Ctrl-C, or the
  instance stops or fails its readiness proof.

The editor is verified before launch: owned by root or you, writable by no
one else, and signed by the expected developer (Microsoft for VS Code, Zed
Industries for Zed). A copy that fails these checks is refused.

What you give up in a sandboxed editor: copy and paste with other apps,
opening links in your browser, local terminals, extensions beyond Remote-SSH,
the Ports panel (use [`--forward-port`](#port-forwarding) instead), settings
sync, and AI features signed in on the host. Settings you change last only for
the session.

`editor.allow` / `--editor-allow` widen the sandbox, each one a capability the
guest then has too:

| Capability | Grants |
|---|---|
| `clipboard` | Read and replace your clipboard |
| `internet` | HTTPS to any host (port 443, including LAN and local services on that port), for downloading editor server binaries on the host |

**`unsafe`** is the previous behavior: the editor's own CLI (`code`, `zed`),
falling back to its URL scheme, which can open the remote in an editor you
already have running, with your full authority. A compromised guest can then
act through that editor on your machine. `iso` prints a warning, passes the
CLI only `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SHELL` and the locale,
and returns once the editor has opened.

The full boundary and its residual risks are in the
[trust model](trust-model.md#local-editors).

## Project-aware commands vs. instance attach

| Command | Use it to |
|---|---|
| `iso code [DIR]`, `iso zed [DIR]` | Open a project: ensure its VM is running, then open the editor |
| `iso editor [NAME]` | Attach an editor to an instance that is already running |

```
iso code [DIR] [--project PATH] [--no-launch] [--editor-security MODE] [--editor-allow CAP]... [up options]
iso zed  [DIR] [--project PATH] [--no-launch] [--editor-security MODE] [--editor-allow CAP]... [up options]
iso editor [NAME] [--project PATH] [--editor code|zed] [--editor-security MODE] [--editor-allow CAP]... [--clean]
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
then Zed. In sandboxed mode it opens the first one installed in
`/Applications` or `~/Applications`; a copy that fails verification stops
the launch. In unsafe mode a strategy that cannot be launched at all (binary
missing, or present but not executable) counts as a miss, so the chain
continues. If an editor starts but exits unsuccessfully or does not return
within five minutes (it is then killed), isolate tries only that editor's
remaining strategies and reports the failure instead of opening a different
editor. `iso editor` also prints the SSH config entry to stderr for manual use;
`iso code` / `iso zed` do not. `--clean` removes the instance's SSH config
entry and exits.

```bash
iso editor my-instance --project /workspace/frontend
iso editor my-instance --editor zed
```

## SSH boundary

An `unsafe` editor connects through the managed `iso-{name}` alias, written
after the instance has passed the runtime's qualification and isolation
checks. The block pins the guest host key and disables agent forwarding
(`ForwardAgent no`, `IdentityAgent none`). A `sandboxed` editor reads only its
session's own SSH config, which pins the same host key and reaches the guest
through `iso`'s loopback tunnel with the session key. isolate re-checks the
instance's readiness immediately before each editor launch; a changed host
key or a failed isolation check stops the launch.

The alias is a connection target, not an agent session. `iso claude` and
`iso codex` prepare credentials and their environment immediately before
launch, so `ssh iso-{name} claude` is not equivalent to them.

## VS Code

A sandboxed VS Code needs the **Remote - SSH** extension
(`ms-vscode-remote.remote-ssh`) installed in your normal VS Code; isolate
copies the newest installed version into each session and nothing else.
Remote-SSH there uses one fixed local port and runs `ssh` in a hidden
terminal. Workspace Trust is off in the session profile: Remote-SSH's hidden
terminal needs the remote folder trusted before it can connect, so the prompt
would only be a mandatory click, and the sandbox, not Workspace Trust, is the
boundary.

In unsafe mode VS Code opens with
`code --remote ssh-remote+iso-{name} /workspace`. If the `code` CLI is not on
`PATH`, isolate opens a
`vscode://vscode-remote/ssh-remote+iso-{name}/workspace` URL instead (path
percent-encoded), which reaches a VS Code that is already running. To install
the CLI, open VS Code and run:

> Cmd+Shift+P, then "Shell Command: Install 'code' command in PATH"

## Zed

A sandboxed Zed asks zed.dev from the host where to download
`zed-remote-server` before the guest fetches it. Without `internet`, that fails
the first time a guest meets a new Zed version; run that once with
`--editor-allow internet` (the server then stays in the guest's
`~/.zed_server`). AI features are disabled in the session profile.

In unsafe mode Zed opens with `zed ssh://iso-{name}/workspace` (fallback: an
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

- **Zed** downloads `zed-remote-server` from zed.dev. A sandboxed Zed with
  `--editor-allow internet` uploads it over SSH itself when egress is `none`
  or `filtered`. In unsafe mode, `iso zed` (and `iso editor` before it tries
  Zed) prints a warning recommending `upload_binary_over_ssh` for the alias
  in Zed's settings; isolate does not edit them:

  ```json
  {
    "ssh_connections": [
      { "host": "iso-my-instance", "upload_binary_over_ssh": true }
    ]
  }
  ```
- **VS Code** downloads VS Code Server. A sandboxed VS Code with
  `--editor-allow internet` transfers it over SSH under restricted egress. In
  unsafe mode, set Remote-SSH's `remote.SSH.localServerDownload` to `always`
  so the server is transferred over SSH.

## Adding a provider

Editor providers are compiled in (`Sources/IsoHost/Editor/`); there is no
plugin interface. A new provider is an `EditorProviderID` case, an
`EditorProvider` with the signed bundle's identity, a sandboxed plan (argv and
the settings it writes into the session profile) and unsafe launch
strategies, a top-level command, tests and docs. Its Seatbelt needs must be
derived on real hardware and security-reviewed. It needs no change to the lifecycle, runtime, SSH
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
