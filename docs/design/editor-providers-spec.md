# Project-aware editor commands and editor providers

**Status:** Implemented (`iso code`, `iso zed`); native-app directions remain proposals
**Date:** 2026-10-04
**Target:** `chr33s/iso` host CLI
**Depends on:** the [`iso.machine/v1` machine interface](../machine-interface.md)

> Current behavior is in the [command reference](../commands.md#code--zed),
> [editor integration](../editor.md) and the
> [machine interface](../machine-interface.md#code-zed). This record keeps the
> decisions and boundaries behind them, and the directions not yet built.

## 1. Decision summary

`iso code [DIR]` and `iso zed [DIR]` turn `iso up . && iso editor <name>`
into one command. Each runs `iso up`'s project lifecycle (`UpWorkflow`),
refreshes the pinned `iso-<name>` alias through `SSHConfigFile`, and launches
exactly one compiled-in **editor provider**. iso remains the authority for VM
lifecycle, isolation checks, SSH identity and host-key pinning, workspace
transport, egress, credential proxying and devcontainer translation; a
provider only turns the alias and guest path into argv.

The provider command name selects the provider. There is no generic
`iso open --editor`, no silent fallback to another editor, and no dynamic
plugin ABI: a new editor is a source change, a top-level command and tests.
`iso editor` stays as the lower-level "attach to a running instance" command
with its VS Code-then-Zed auto-detection.

## 2. Integration model

iso exposes two post-lifecycle abstractions above the same verified running
instance, and they must not be merged:

| Abstraction | Consumers | What it carries |
|---|---|---|
| `SSHConnectionTarget` | VS Code, Zed, Cursor, JetBrains, `ssh`/`scp`/`rsync` | Instance, managed alias, guest path, egress mode. Never key bytes, resolved secrets, credentials or runtime handles. |
| `WorkloadSession` | Claude Code, Codex, future agent CLIs | An ephemeral, host-prepared session: provider-key forwarding or proxy-mode suppression, GitHub token, `env_forward`, `guest_env` secrets, filtered-egress capability, local-model routing, Codex account checks, and a late identity revalidation before spawn. |

The alias is safe for editors once iso has a qualified running instance, the
isolation gate has passed, the host key is pinned and the alias block is
published (`ForwardAgent no`, `IdentityAgent none`). It is **not** an agent
launch contract: `ssh -t iso-<name> 'cd /workspace && claude'` skips session
preparation and is useful only for debugging.

Rules:

- Editor providers never receive a `WorkloadSession`.
- Claude/Codex launch is never reduced to a published alias plus a guest
  command string.
- Machine output never serializes a prepared workload environment, resolved
  secrets, or a ready-to-run SSH command.
- Do not define one generic "provider" protocol spanning editors and agents;
  their trust and lifecycle requirements differ.

Both can share project resolution up to the verified running instance:

```text
UpWorkflow -> AppleBackend.Running
                 |-> SSHConnectionTarget -> EditorProvider (code, zed, ...)
                 '-> AgentBootstrap.openSession() -> WorkloadSession (claude, codex)
```

## 3. Editor launch invariants

1. The running instance comes from the backend's qualified running path.
2. `SSHConfigFile.update` checks the handoff before publishing the alias.
3. `EditorLauncher` checks the handoff again immediately before each spawn.
4. A host-key mismatch or isolation-gate failure aborts the launch.
5. No provider builds its own SSH invocation or enables agent forwarding.
6. Once a provider's editor has been found and failed, no other provider is
   tried; only that provider's remaining strategies may run.
7. Restricted egress is never widened for an editor; providers may emit
   advisory warnings (Zed's `upload_binary_over_ssh`) but never edit editor
   settings.
8. A running instance keeps its boot policy; `UpWorkflow` refuses a differing
   `--egress` or `--allow-host` (or an unreadable boot policy record) for
   `up`, `code` and `zed` alike, using the handoff's own `NetworkPolicy.enforce`.
9. Each strategy has a deadline, enforced by `ProcessRunner.attached`; a hung
   editor CLI is killed and reported as `EDITOR_LAUNCH_FAILED`, and in
   `iso editor`'s auto-detection it stops the chain like a nonzero exit.
10. Fallback launchers open URLs (`vscode://`, `zed://`), which reach an
    editor that is already running; `open -a … --args` would not.
11. Every failure after the lifecycle step names the instance and the step
    that ran, so a client can find a VM it just created or started.

Fault injection covers the late handoff check, the no-fallback rules, the
deadline (in the launcher and in `ProcessRunner.attached`), the
single-provider selection of the project commands and the
egress refusal.

## 4. Non-goals (v1)

- Dynamically loaded editor plugins or a plugin ABI.
- A second VM backend; providers are launch adapters, not backends.
- Rewriting VS Code or Zed settings.
- Nested VS Code Dev Containers. `devcontainer.json` is translated once, by
  iso; a later provider capability (`workspace_mode = vm | devcontainer`)
  could add it without double-applying the file.
- Treating Claude Code or Codex as editor providers.
- MCP as the bridge between Claude's native app and iso.
- An editor default in configuration (the command name selects the provider).

## 5. Adding an editor provider

1. Add a case to `EditorProviderID` and its `provider`.
2. Implement `EditorProvider` (`launchTarget`, `strategies`, optional
   `warnings`).
3. Add the top-level command (a `ProjectEditorCommand`).
4. Add unit tests for argv and URL encoding, and docs.

This must need no change to `UpWorkflow`, `AppleBackend`, `SSHConfigFile`,
workspace transfer, the credential proxy, devcontainer translation, the
isolation gate, `AgentBootstrap` or `WorkloadSession`. Likewise, a new managed
agent must not touch `EditorProviderID`.

## 6. Future directions (not implemented)

### 6.1 Project-aware agent commands

Once `UpWorkflow` returns a reusable outcome, `iso claude .` / `iso codex .`
(or `iso agent . --agent claude`) may reuse it for create/start/reuse and then
dispatch through the existing `AgentBootstrap.openSession()` /
`WorkloadSession` path, keeping its late revalidation. They must not go
through the editor providers. If agent extensibility grows, keep an
`AgentAdapterRegistry` separate from `EditorProviderID`; only the agent
registry may request `WorkloadSession` preparation.

### 6.2 Claude native/web/mobile UI: remote-control

```text
Claude native/web/mobile UI
   -> Claude Code remote-control
      -> Claude Code CLI session inside the iso VM (/workspace)
```

The VM-resident Claude Code process stays the execution authority; iso owns
project resolution, VM lifecycle, readiness checks, Claude bootstrap,
credential and proxy preparation, and the `WorkloadSession` that launches it.
Remote-control only attaches a UI to that session and must not replace the
launch path. A future flag (for example `iso claude . --remote-control`)
should follow Claude Code's documented CLI contract at implementation time.
Closing the UI must not bypass iso's lifecycle ownership.

Safe machine metadata may describe the session class:

```json
{"workload": {"kind": "managed", "agent": "claude", "control": "remote-control", "launch_via": "iso"}}
```

It must not export credentials, provider keys, forwarded environment values,
an SSH command that bypasses `AgentBootstrap`, or remote-control
authentication material. A purpose-built handoff token, if Claude introduces
one, would be a separate bounded object with explicit lifetime and secrecy
rules, never folded into `SSHConnectionTarget`.

### 6.3 Codex native/hosted UI

Codex stays distinct from the Claude model. The CLI path remains
`iso codex -> WorkloadSession`. A stable connected-host API could be given a
verified project environment without raw secret state; a hosted executor
running inside the VM would be a third class, `HostedEnvironmentSession`,
separate from both `SSHConnectionTarget` and `WorkloadSession`.

```text
                  verified iso project environment
              +---------------+----------------+
       SSH connection     managed CLI      hosted/native
           target           workload          control
        code / zed        claude / codex   Claude remote-control,
        cursor / ssh                       future Codex host/executor
```

### 6.4 Additive capability fields

`iso capabilities` may add per-provider fields such as
`supports_custom_guest_path`, `supports_nested_devcontainer` and
`supports_settings_bootstrap`. Clients must not hard-code the provider list.

## 7. Implementation notes

- `UpOutcome` carries only the action and instance; the editor workflow takes
  a fresh running proof with `AppleBackend.asRunning` immediately before the
  handoff rather than threading `Running` through `ProjectLifecycle`.
- `EDITOR_NOT_FOUND` / `EDITOR_LAUNCH_FAILED` details name the instance and
  the lifecycle step that already ran, since the VM may now be running.
- Host-key and isolation failures keep their existing codes
  (`APPLE_HOST_KEY_CHANGED`, `APPLE_NETWORK_ISOLATION`).
- VS Code's machine `launch_target` is
  `vscode-remote://ssh-remote+iso-<name><path>`; Zed's is
  `ssh://iso-<name><path>`, both percent-encoded.
- `--project` naming a directory in the user's home with no `DIR` is
  refused, so a mistyped host path never makes the current directory the
  project; other guest paths that also exist on macOS are accepted.
- `UpWorkflow` refusal messages name the invoking command (`iso zed --image
  ...`), not always `iso up`.
