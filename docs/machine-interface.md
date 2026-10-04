# Machine interface (`iso.machine/v1`)

`--output json` makes a supported command print one versioned JSON document on
stdout. It exists so editors, CI and launchers can drive `iso` without parsing
human text. It is still the CLI: there is no daemon, socket or RPC service.

```bash
iso capabilities --output json
iso up ~/code/project --no-devcontainer --output json
iso ssh-config project --output json
iso zed ~/code/project --no-launch --output json
```

Text output (the default, `--output text`) is unchanged. The command-local
`--json` flags on `list`, `status`, `images` and others keep their existing
**legacy, unversioned** shapes; `--json` cannot be combined with `--output json`.

## Supported commands

| Command | Result |
|---|---|
| `capabilities` | Versions, backend, machine commands, editor providers |
| `list` | `{ "instances": [InstanceRef] }` |
| `status [NAME]` | One `{ instance, usage }`, or `{ "instances": [...] }` |
| `up [DIR]` | `{ lifecycle, instance, workspace }` |
| `start [NAME]` | `{ lifecycle, instance }` |
| `stop [NAME]` | `{ lifecycle, instance }` |
| `destroy [NAME]` | `{ lifecycle, instance }`; with `--all`, `{ lifecycle, instances }` |
| `ssh-config [NAME]` | `{ instance, connection }` |
| `code [DIR]`, `zed [DIR]` | `{ lifecycle, instance, workspace, connection, editor, warnings }` |

Any other command (including a command group such as `secrets`) given
`--output json` prints an `UNSUPPORTED_MACHINE_OUTPUT` error document whose
`command` is the full path (`secrets list`) and exits 2. `--help` and
`--version` still print their text and exit 0. That includes the workload streams (`shell`,
`exec`, `logs`, `claude`, `codex`, `run`), whose stdout belongs to the guest.
`up --dry-run` and `start --dry-run` keep their own `--json` preview and refuse
`--output json`.

## Wire format

Success:

```json
{"api_version":"iso.machine/v1","command":"status","ok":true,"result":{...}}
```

Failure:

```json
{"api_version":"iso.machine/v1","command":"up","ok":false,"error":{"code":"INTERACTION_REQUIRED","message":"...","retryable":true,"details":{...}}}
```

`error.details` is an object or `null`. `error.message` is human text with
control characters replaced and a 4 KiB bound; never branch on it.

### Streams and exit status

- **stdout** carries exactly one compact UTF-8 JSON document and a newline,
  and nothing else. In machine mode everything else that would reach fd 1
  (progress, child processes, warnings) is sent to stderr.
- **stderr** carries diagnostics only and is outside the protocol. `--quiet`
  (only valid with `--output json`) discards it entirely.
- Exit status: `0` success, `1` operational failure (after the error
  document), `2` usage failure. A usage error that Argument Parser reports
  before the command runs (an unknown flag, `--json` with `--output json`,
  `--quiet` without it) is text on stderr with an empty stdout. A validation
  error raised while the command runs prints an `INVALID_ARGUMENT` document
  first and keeps the exit status text mode gives it.

## Non-interactive

Machine mode never prompts. stdin is replaced with `/dev/null`, and the
secret-store passphrase (which would otherwise be read from `/dev/tty`) is
refused. When a command needs a decision it fails with
`INTERACTION_REQUIRED`; `details.kind` says which one:

| `kind` | When | Details |
|---|---|---|
| `devcontainer` | `up` discovered a `devcontainer.json` | `path`, `accepted_flags` (rerun with one of them) |
| `passphrase` | A `{vault:}` reference must be resolved | `descriptor_variable`: pass the passphrase on that descriptor (`ISO_SECRETS_PASSPHRASE_FD`) |
| `github-pat` | `up`/`start` would offer the GitHub PAT setup for the project's repository | `repo`, `accepted_flags` (`--no-prompt` continues without it, `--no-github` disables GitHub auth); or run `iso github setup-pat --repo REPO` first |

The PAT offer is reported only where a terminal session would show it (not in
CI, with `--no-prompt`, or with a configured or skipped entry). No security decision is answered implicitly: discovered
devcontainers are never applied without `--devcontainer`, and the isolation
gate and pinned host keys apply exactly as in text mode.

## Compatibility

Consumers must ignore unknown fields, treat unknown enum values (including
error codes) as unsupported rather than fatal, branch on `api_version`, and
branch on `error.code`, never `error.message`.

Within `iso.machine/v1`, `iso` may add optional fields, enum values, error
codes and commands. It does not remove, rename or retype a field, change the
meaning of an enum value, or omit a field documented as nullable (`null` is
always present). Anything else is a new version (`iso.machine/v2`).
`capabilities` lists the versions a build speaks. The reviewed documents are
in [`tests/fixtures/machine/v1/`](../tests/fixtures/machine/v1/).

## Objects

**InstanceRef**

```json
{"name": "my-project", "state": "running", "image": "default", "backend": "apple-container"}
```

`state` is `running`, `stopped`, or `unknown` (a state that could not be
probed; `list` and the bare `status` report it rather than failing).

**WorkspaceRef**

```json
{"guest_path": "/workspace", "host_path": "/Users/me/code/my-project", "transport": "copy"}
```

`transport` is `copy`, `mount`, or `git-repo`; `host_path` is `null` for
`git-repo`. These are recorded values and are not display-sanitized.

**SSHConnectionRef**

```json
{"kind": "ssh", "host_alias": "iso-my-project", "ssh_config_path": "/Users/me/.ssh/config"}
```

Connect through `host_alias`. Key material, IP, port and user are never
included; the alias's config block pins the guest host key.

**LifecycleOutcome** — `{"action": ...}` with one of `created`, `started`,
`reused`, `stopped`, `destroyed`, `unchanged`.

## Commands

### capabilities

Side-effect free: no configuration, state, credentials, runtime or update
check.

```json
{
  "cli_version": "iso 0.1.0 (...)",
  "machine_api_versions": ["iso.machine/v1"],
  "backend": "apple-container",
  "commands": {"up": {"machine_output": true}, "...": {}},
  "editor_providers": [
    {"id": "code", "display_name": "Visual Studio Code", "remote_transport": "ssh"},
    {"id": "zed", "display_name": "Zed", "remote_transport": "ssh"}
  ]
}
```

Provider ids are lowercase ASCII letters, digits and `-`. Treat the list as
open-ended rather than hard-coding the current two.

### list

`{"instances": [InstanceRef, ...]}`, sorted by name. The state comes from the
runtime without connecting to the guest.

### status

With a name: `{"instance": InstanceRef, "usage": Usage|null}`. Without one:
`{"instances": [{"instance": ..., "usage": ...}, ...]}`. `Usage` is
`{"load_1m", "mem_used_mib", "mem_total_mib", "disk_used_mib", "disk_total_mib"}`
(`load_1m` may be `null`); `usage` is `null` when stopped or unavailable.

### up

`{"lifecycle": {"action": "created"|"started"|"reused"}, "instance": InstanceRef, "workspace": WorkspaceRef|null}`.
The action is the path the workflow took: a new instance, a restart of the
project's stopped instance, or reuse of its running one.

### start

`{"lifecycle": {"action": "started"}, "instance": InstanceRef}`. Starting a
running instance selected by name or `--workspace` is
`INSTANCE_ALREADY_RUNNING`; with no selection and no stopped instance it is
`INSTANCE_NOT_FOUND`, as in text mode.

### stop

`{"lifecycle": {"action": "stopped"|"unchanged"}, "instance": InstanceRef}`;
`unchanged` means the instance was already stopped.

### destroy

`{"lifecycle": {"action": "destroyed"}, "instance": {"name", "image"}}`, with
identifiers captured before deletion. `--all` returns `"instances": [...]`.
If `--all` fails partway, the error document keeps the failure's own code and
details and adds `"destroyed": [{"name", "image"}, ...]` for the instances it
had already removed; `details` stays `null` when nothing was removed.

### ssh-config

`{"instance": InstanceRef, "connection": SSHConnectionRef}`. The command runs
the same running proof, isolation check, pinned-host-key block and alias
collision check as in text mode; only the human usage text is omitted. With
`--clean`: `{"instance": {"name": ...}, "connection": null}`.

### code, zed

```json
{
  "lifecycle": {"action": "reused"},
  "instance": InstanceRef,
  "workspace": WorkspaceRef|null,
  "connection": SSHConnectionRef,
  "editor": {"provider": "zed", "launched": false, "launch_target": "ssh://iso-my-project/workspace"},
  "warnings": []
}
```

`lifecycle`, `instance` and `workspace` are `up`'s. `connection` is the alias
the editor was (or would be) pointed at, after the same running proof,
isolation check and pinned-host-key block as `ssh-config`. `launched` is
`false` with `--no-launch`. `launch_target` is the address the provider opens:
`ssh://<alias><path>` for Zed and `vscode-remote://ssh-remote+<alias><path>`
for VS Code, with the path percent-encoded. `warnings` holds advisory provider
diagnostics (for example Zed's `upload_binary_over_ssh` hint under restricted
egress). The editor's own output is never included, and neither is an SSH
command, key material or agent session state.

Any failure after the lifecycle step (`EDITOR_NOT_FOUND`,
`EDITOR_LAUNCH_FAILED`, an alias conflict in `~/.ssh/config`, an instance that
stopped before the editor attached, ...) means the instance may already exist
and be running: its `details` name it (`name`) and the step that ran
(`action`: `created`, `started` or `reused`). Editor codes keep `providers`
beside them; a failure with no other details carries just `name` and `action`.
As with `up`, an `--egress` / `--allow-host` that differs from a running
instance's boot policy, or a boot policy record that cannot be read, is
`INSTANCE_INCOMPATIBLE`.

## Error codes

| Code | Retryable | Meaning | `details` |
|---|---|---|---|
| `INVALID_ARGUMENT` | no | A usage error raised while the command ran | `null` |
| `UNSUPPORTED_MACHINE_OUTPUT` | no | The command has no machine output | `null` |
| `INSTANCE_NOT_FOUND` | no | No instance matches (or none exist) | `null` |
| `AMBIGUOUS_INSTANCE` | yes | Several match | `instances`, `resolution`: the argument of this command that picks one (e.g. `<NAME>`), or `null` when none does (`up` with several instances sharing the project) |
| `INSTANCE_ALREADY_RUNNING` | no | The command needs a stopped instance | `name` |
| `INSTANCE_NOT_RUNNING` | no | The command needs a running instance | `name`, or `null` when none is named |
| `INSTANCE_INCOMPATIBLE` | no | The existing instance cannot take the requested creation options, transport, or (when running) egress policy, or its boot policy record cannot be read | `name` |
| `PROJECT_ALREADY_ASSOCIATED` | no | The project or repository belongs to another instance | `name` (the associated instance) |
| `INTERACTION_REQUIRED` | yes | A decision is needed; see [Non-interactive](#non-interactive) | `kind`, ... |
| `EDITOR_NOT_FOUND` | no | No launch strategy of the requested editor reached an editor | `providers`, `name`, `action` (the instance and lifecycle step that already ran; `null` for none) |
| `EDITOR_LAUNCH_FAILED` | no | The editor was found but failed to start, timed out or exited unsuccessfully | `providers` (the one that failed), `name`, `action` |
| `APPLE_RUNTIME_UNAVAILABLE`, `APPLE_RUNTIME_UNQUALIFIED`, `APPLE_NETWORK_ISOLATION`, `APPLE_HOST_EXPOSURE`, `APPLE_IDENTITY_CONFLICT`, `APPLE_HOST_KEY_CHANGED`, `APPLE_SESSION_EXPIRED` | no | The runtime diagnostic classes in [backends.md](backends.md) | `null` |
| `APPLE_BOOT_TIMEOUT`, `APPLE_OPERATION_UNCERTAIN` | yes | The runtime's state had not settled | `null` |
| `OPERATION_INTERRUPTED` | yes | A signal stopped the command | `null` |
| `OPERATION_FAILED` | no | Any other failure | `null` |

A failure takes the most precise code found along its cause chain. The set is
open-ended; more precise codes may replace `OPERATION_FAILED` for specific
failures in later `v1` releases.
