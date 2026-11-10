# iso.machine/v1 — condensed

Full contract: `docs/machine-interface.md` in <https://github.com/chr33s/iso>.

## Envelope

```json
{"api_version":"iso.machine/v1","command":"status","ok":true,"result":{}}
{"api_version":"iso.machine/v1","command":"up","ok":false,"error":{"code":"...","message":"...","retryable":true,"details":{}}}
```

- Stdout: one compact JSON document and a newline. Stderr: diagnostics only.
- Exit: `0` success, `1` operational failure (after the error document),
  `2` usage failure. A parse-time usage error prints text on stderr with empty
  stdout.
- Machine mode never prompts; stdin is `/dev/null`.
- Ignore unknown fields; treat unknown codes and enum values as unsupported,
  not fatal. Check `api_version`.

## Results

| Command | `result` |
|---|---|
| `capabilities` | `cli_version`, `machine_api_versions`, `backend`, `commands`, `editor_providers`, … |
| `list` | `{instances: [InstanceRef]}` |
| `status NAME` | `{instance, usage, reason}`; bare: `{instances: [...]}` |
| `up [DIR]` | `{lifecycle, instance, workspace}` |
| `start` / `stop` | `{lifecycle, instance}` |
| `destroy` | `{lifecycle, instance: {name, image}}`; `--all`: `instances` |
| `ssh-config` | `{instance, connection: {kind, host_alias, ssh_config_path}}` |
| `code` / `zed` | `up`'s fields plus `connection`, `editor`, `warnings` |
| `audit --runs` / `--run ID` | One page: `{selection, as_of, coverage, runs \| run + events, next_cursor}` |

- InstanceRef: `{name, state, image, backend}`; `state` is `running`,
  `stopped`, `unhealthy` or `unknown`.
- WorkspaceRef: `{guest_path, host_path, transport}`; `transport` is `copy`,
  `mount` or `git-repo` (`host_path` null).
- `lifecycle.action`: `created`, `started`, `reused`, `stopped`, `destroyed`,
  `unchanged`.
- Usage: `{load_1m, mem_used_mib, mem_total_mib, disk_used_mib, disk_total_mib}`
  or `null` when stopped.

Commands without machine output (`exec`, `shell`, `logs`, `claude`, `codex`,
`run`, `push`, `pull`, `diff`, `secrets`, …) return
`UNSUPPORTED_MACHINE_OUTPUT` with exit 2; run them in text mode.

## Error codes

| Code | Retry | What to do |
|---|---|---|
| `INVALID_ARGUMENT` | no | Fix the invocation |
| `INSTANCE_NOT_FOUND` | no | `list`; `up DIR` to create |
| `AMBIGUOUS_INSTANCE` | yes | Pick from `details.instances` and pass it as `details.resolution`; when that is `null` (`up` with several instances on one project) ask the user |
| `INSTANCE_ALREADY_RUNNING` | no | Already up; use it, or stop first to change boot options |
| `INSTANCE_NOT_RUNNING` | no | `start NAME` |
| `INSTANCE_UNHEALTHY` | no | `stop NAME` then `start NAME` |
| `INSTANCE_INCOMPATIBLE` | no | The instance cannot take the requested options: drop creation options, `iso resize` for vCPUs/memory/disk, stop first for boot options, or recreate (ask) |
| `PROJECT_ALREADY_ASSOCIATED` | no | Use `details.name`, or `--new-instance --name` (ask) |
| `INTERACTION_REQUIRED` | yes | Ask the user about `details.kind` (`devcontainer`, `github-pat`, `passphrase`) |
| `EDITOR_NOT_FOUND`, `EDITOR_LAUNCH_FAILED` | no | Instance may already be running (`details.name`, `details.action`) |
| `APPLE_RUNTIME_UNAVAILABLE` | no | Relay stderr; the user runs `container system start` only if it names that service |
| `APPLE_HOST_KEY_CHANGED` | no | Stop and report; do not bypass host-key pinning |
| `APPLE_*` (other) | no | Report; see `docs/backends.md` |
| `APPLE_BOOT_TIMEOUT`, `APPLE_OPERATION_UNCERTAIN` | yes | `status`, then retry once |
| `AUDIT_CURSOR_EXPIRED`, `AUDIT_RESET_REQUIRED` | no | Read again without `--after` |
| `AUDIT_*` (other) | no | Report; see `docs/audit.md` |
| `OPERATION_INTERRUPTED` | yes | Retry once |
| `OPERATION_FAILED` | no | Read stderr; report |
