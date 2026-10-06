# Hardened `iso $EDITOR` Design

**Status:** P0 and P1 implemented for `sandboxed` and `unsafe`; `strict` (P2) remains a proposal. See [§22](#22-implementation-record).  
**Date:** 2026-10-06  
**Scope:** `chr33s/iso`, macOS 27+ host, Linux guest VMs, native VS Code/Zed remote-development providers

## 1. Decision

`iso` should stop treating an authenticated SSH connection as sufficient protection for a native remote-development editor.

The hardened threat model is:

> The guest has root, can replace or instrument the remote editor server, and can emit arbitrary editor-protocol messages. Assume this can achieve arbitrary code execution in the **local editor process**. The host still must not expose ordinary host files, credentials, Keychain items, clipboard contents, arbitrary local services, or arbitrary host process execution.

The recommended architecture is:

1. **Default native mode: `sandboxed`** — run each local editor in a per-session **Editor Enclave** enforced by macOS Seatbelt, with an isolated HOME/profile, scrubbed environment, dedicated SSH identity/config, no reuse of an existing editor process, and supervised lifetime.
2. **Compatibility mode: `unsafe`** — current behavior, explicit opt-in, with a clear warning that the remote editor protocol is outside the VM containment boundary.
3. **Future highest-assurance mode: `strict`** — the editor/server executes entirely in the VM (or another disposable VM) and the host runs only a deliberately narrow, sandboxed viewer/web client. This removes the native editor RPC surface from the normal host user session.

SSH hardening, Workspace Trust, a fresh VS Code Server download, or editor-version pinning are useful secondary controls, but none of them restore the VM boundary by themselves.

---

## 2. Why the current implementation does not satisfy the VM trust model

`docs/trust-model.md` defines the Linux VM as untrusted and states that guest-authored data should not escalate into host code execution, filesystem escape, or credential exposure.

The editor path currently violates the spirit of that invariant in several ways.

### 2.1 Full host environment is inherited

`Sources/IsoHost/Editor/EditorLauncher.swift` is constructed with `context.environment.variables` and passes that complete environment to `code`/`zed`.

That can expose credentials such as cloud tokens, provider keys, debugging variables, proxy credentials, `SSH_AUTH_SOCK`, or other application secrets to a compromised local editor process.

**Required change:** editor processes must start from an allowlisted environment, not the caller environment.

### 2.2 Existing unsandboxed editor instances can be reused

The current VS Code provider launches:

```text
code --remote ssh-remote+iso-<name> /workspace
```

and falls back to a `vscode://...` URL. The Zed provider similarly uses `zed ssh://...` and a `zed://...` fallback.

Those mechanisms can rendezvous with an already-running normal user editor. Wrapping only the CLI launcher in a sandbox would therefore be insufficient: the privileged process receiving the remote session may already be outside the sandbox.

**Required change:** hardened mode must create a new isolated editor instance and must not use URL/open fallbacks.

### 2.3 The editor has the normal user's ambient authority

Without additional confinement, native VS Code/Zed can normally reach some combination of:

- the user's filesystem;
- the editor's normal profile and extension state;
- Keychain-backed authentication state;
- clipboard/pasteboard;
- local TCP and Unix-domain services;
- LaunchServices / external applications;
- arbitrary child processes;
- network services and account/sync features.

A malicious remote editor peer does not need to break SSH to attack those capabilities; SSH authenticates the peer rather than constraining what the authenticated peer may ask the editor to do.

### 2.4 Editor sessions are not supervised after handoff

The current trust-model documentation explicitly notes that external SSH and editor Remote-SSH sessions do not pass through `iso` and are not supervised.

**Required change:** the hardened editor must remain an `iso`-owned process tree whose lifetime is tied to the running proof / boot identity / session TTL.

---

## 3. Security properties

### 3.1 Attacker capabilities

Assume an attacker can:

- execute arbitrary code as root in the guest;
- modify the remote VS Code Server, Zed server, extensions, shell startup files, project settings, language servers, and protocol implementation;
- send arbitrary bytes over every guest→editor protocol channel after SSH authentication;
- create arbitrary project files and project-local configuration;
- intentionally crash or fuzz the host editor protocol implementation.

### 3.2 Required guarantees for `sandboxed`

Compromise of the native local editor process must not give the attacker:

1. read access to normal host-user files outside the editor enclave;
2. write access outside the editor enclave;
3. access to the user's login Keychain or existing editor authentication state;
4. clipboard access by default;
5. access to arbitrary host TCP/Unix-domain services;
6. arbitrary internet access;
7. arbitrary host program execution;
8. LaunchServices, Apple Events, or equivalent ways to cause an unsandboxed application to act on the attacker's behalf;
9. the long-lived `iso` VM private key or other instances' SSH credentials;
10. persistence in the user's normal VS Code/Zed profile;
11. continued access after the VM proof is revoked, the VM stops, or the editor session ends.

### 3.3 Explicit non-goals

Even hardened mode cannot protect information the user deliberately places into the enclave, types into the editor, or explicitly grants through an opt-in capability.

It also relies on the macOS kernel/Seatbelt enforcement and on the correctness of the minimal GUI services necessarily exposed to a native editor.

---

## 4. New abstraction: `EditorSession` / Editor Enclave

Replace the current "turn an alias into argv" launch contract with a security-aware plan.

Suggested shape:

```swift
package struct EditorSessionPlan: Sendable {
  let provider: EditorProviderID
  let executable: TrustedEditorExecutable
  let instance: InstanceName
  let guestPath: GuestPath
  let stateDirectory: URL
  let environment: [String: String]
  let ssh: EditorSSHSession
  let sandbox: EditorSandboxPolicy
  let arguments: [String]
  let supervision: EditorSupervisionPolicy
}
```

An `EditorProvider` should describe how to construct this plan, not merely return arbitrary executable names and arguments.

Suggested provider capabilities:

```swift
package protocol EditorProvider: Sendable {
  var id: EditorProviderID { get }
  var displayName: String { get }

  func resolveExecutable(_ host: HostEnvironment) throws -> TrustedEditorExecutable
  func prepareSession(_ context: EditorPreparationContext) throws -> EditorSessionPlan
}
```

The generic launcher owns confinement, environment sanitization, supervision, cleanup, and fail-closed behavior.

---

## 5. Per-session filesystem state

Create a private editor session directory, for example:

```text
<instance>/editor-sessions/<random-id>/
├── home/                 # HOME presented to editor
├── user-data/            # VS Code/Zed isolated state
├── extensions/           # only explicitly allowed local extensions
├── tmp/                  # TMPDIR
├── ssh/
│   ├── config
│   ├── id_ed25519
│   ├── id_ed25519.pub
│   └── known_hosts
├── settings/
└── logs/                 # sanitized; no protocol payload/secrets
```

Permissions:

- directory tree: `0700`;
- private key/control files: `0600`;
- no symlinked components;
- canonicalize paths before generating Seatbelt rules;
- remove the whole session directory on clean shutdown; stale directories are safe to remove during reconciliation because they contain only editor-scoped state.

The editor's `HOME`, configuration, extension storage, caches, logs, temporary files, and IPC sockets must resolve inside this directory.

---

## 6. Environment isolation

Do **not** inherit `context.environment.variables`.

Resolve the trusted editor executable first, then launch it with a fresh environment such as:

```text
HOME=<session>/home
USER=<local user>
LOGNAME=<local user>
TMPDIR=<session>/tmp
LANG=<allowlisted locale>
LC_*=<allowlisted locale values>
PATH=/usr/bin:/bin:/usr/sbin:/sbin
```

Add only provider variables proven necessary by integration tests.

Explicitly omit at least:

- `SSH_AUTH_SOCK`;
- `GITHUB_TOKEN`, `GH_TOKEN`;
- `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and other model/provider keys;
- AWS/GCP/Azure credentials;
- `DOCKER_HOST` / container sockets;
- proxy credentials;
- `NODE_OPTIONS`, `DYLD_*`, `VSCODE_*`, `ZED_*` inherited from the caller unless the provider itself creates a known-safe value;
- arbitrary shell/session variables.

This should use the same design principle already applied to `SandboxRuntime` and guest-bound SSH transports: ambient host environment is not part of the security contract.

---

## 7. Trusted editor executable resolution

Hardened mode must not resolve `code`/`zed` from arbitrary `PATH` entries and must not invoke `open` or a URL scheme.

The trusted `iso` process should:

1. locate an application bundle through fixed known locations or LaunchServices **before** entering the editor sandbox;
2. resolve symlinks;
3. require a regular executable and safe ownership/mode on the executable and ancestors;
4. verify the application's code signature and expected bundle identity/team for compiled-in providers;
5. record the resolved executable path in the `EditorSessionPlan`;
6. execute that binary directly under the sandbox.

Use the same philosophy as `iso`'s runtime-binary validation: project content, shell aliases, and project-influenced `PATH` must not select the editor executable.

### Never do this in hardened mode

```text
open vscode://...
open zed://...
code ...            # without an isolated user-data-dir
zed ...             # if it can attach to normal running state
```

An inability to create a distinct confined process is a hard launch failure, not a reason to fall back to the user's existing editor.

---

## 8. macOS Seatbelt Editor Sandbox

`iso` already uses `sandbox-exec`/Seatbelt to confine `iso-proxy`. Reuse the same enforcement model for native editors, with a dedicated editor profile and real-hardware qualification tests.

The sandbox should be **deny-by-default**.

### 8.1 Filesystem allows

Read-only:

- the exact editor application bundle;
- the minimal macOS runtime/framework/library/font paths required for the tested editor version;
- `/usr/bin/ssh` and any other exact system binary explicitly required by the provider;
- the session's SSH config/key/known-hosts;
- system files proven necessary for GUI/runtime startup.

Read/write:

- only the Editor Enclave session directory;
- necessary system-created per-process shared-memory objects, if they cannot be redirected into the session.

Do **not** globally allow `file-read*`; that would preserve the most important host-secret exposure.

### 8.2 Process controls

Allow execution only for:

- the exact editor executable and required helper executables inside its signed application bundle;
- the exact system `ssh` binary if the stock provider requires it;
- any additional executable demonstrated by provider integration tests and security-reviewed.

Deny shells and generic host tools such as:

```text
/bin/sh
/bin/bash
/bin/zsh
/usr/bin/osascript
/usr/bin/open
/usr/bin/security
/usr/bin/curl
/usr/bin/python*
```

unless a provider cannot function without one and an equally narrow replacement has been designed.

The editor must not be able to use LaunchServices or launchd to create an unsandboxed process outside the inherited Seatbelt policy.

### 8.3 Clipboard

**Deny pasteboard access by default.**

This is necessary because clipboard read is already a normal host-side capability exposed by remote-editor APIs in VS Code. A normal clipboard grant collapses that part of the boundary.

If users demand clipboard integration, make it an explicit degraded capability such as:

```text
iso code . --editor-allow clipboard
```

and state precisely that a compromised guest may then read or replace the host clipboard for the lifetime of that editor session.

Do not silently grant clipboard access because copy/paste is convenient.

### 8.4 Keychain and authentication services

Deny access to the user's normal Keychain and security services used for application credentials.

The isolated editor profile must not depend on host sign-in, Settings Sync, Copilot credentials, Zed AI credentials, GitHub authentication sessions, or other login state.

Keychain access should not be treated as a per-item capability: from the `iso` threat model's perspective it is too broad to grant to a process controlled by an untrusted remote peer.

### 8.5 GUI and IPC

Allow only the minimal services needed to create and interact with windows.

Explicitly deny capabilities that can be used to leave the sandbox or inspect/control other applications, including:

- LaunchServices-mediated process/app launching;
- Apple Events to other apps;
- pasteboard (unless opted in);
- raw HID / input-capture interfaces not required for ordinary focused-window input;
- screen/audio/camera capture services;
- process inspection/debugging of unrelated host processes;
- arbitrary Unix-domain sockets.

The exact Mach/XPC allowlist must be derived empirically on qualified macOS/editor versions and regression-tested. Avoid a blanket `(allow mach-lookup)`.

Zed's own current macOS agent sandbox is a useful reference: its documentation says it deliberately prevents access to LaunchServices/launchd, the pasteboard, and audio services while allowing only a developer-tool-oriented Mach-service allowlist.

### 8.6 Network

The ideal native-editor profile permits only:

- the target VM's current address on TCP/22;
- provider-internal local IPC that is unavoidable and whose endpoint is bounded to the editor session;
- no general internet;
- no arbitrary LAN;
- no arbitrary `127.0.0.1` / Unix-socket access to host developer services.

The last point matters: localhost often contains Docker APIs, local model servers, databases, debug servers, browser automation endpoints, or credential-bearing development services.

If stock Remote-SSH forces a broad loopback allowance, record that as a residual risk and pursue a provider-specific broker or Remote-SSH integration that gives the sandbox a fixed, session-specific endpoint rather than all loopback ports.

---

## 9. Dedicated editor SSH identity

Do not expose the long-lived `iso` VM private key to the editor sandbox.

For each editor session:

1. generate a fresh Ed25519 keypair in `<session>/ssh`;
2. install the public key into the target guest through the already-qualified `iso` control/SSH path;
3. create a private SSH config containing only the one target instance;
4. copy/use only the target instance's pinned host key;
5. configure the editor to use that exact config and identity;
6. remove/revoke the key on session end; the private key is destroyed with the Editor Enclave.

Key-level SSH restrictions should disable everything the editor does not need, including agent forwarding, X11 forwarding, PTYs where unnecessary, and reverse forwarding. Permit only the forwarding mode required for the provider's remote-server transport.

Benefits:

- compromise of a local editor does not disclose the shared VM key;
- one editor session cannot authenticate to every other `iso` VM;
- session lifetime is cryptographically bounded by destruction of its private key even if the guest retained the public key entry.

The hardened editor should use an ephemeral config file directly; it should not need to parse the user's global `~/.ssh/config`.

---

## 10. VS Code provider

VS Code supports isolated instances using distinct `--user-data-dir` values and a separate `--extensions-dir`. Use both.

Example shape (illustrative, not final argv):

```text
<signed VS Code executable>
  --user-data-dir <session>/user-data
  --extensions-dir <session>/extensions
  --new-window
  --remote ssh-remote+iso-editor-<session>
  /workspace
```

### 10.1 Local extension set

The isolated local extension directory should contain only what is required for the transport (normally Remote - SSH) plus explicitly reviewed built-ins.

Do not copy the user's normal extension directory into the enclave.

Remote/workspace extensions remain guest-controlled and must therefore be assumed malicious; that is acceptable only because the host editor is sandboxed.

### 10.2 Generated VS Code settings

At minimum generate an isolated profile/settings file equivalent to:

```jsonc
{
  "chat.disableAIFeatures": true,
  "telemetry.telemetryLevel": "off",
  "remote.SSH.defaultExtensions": [],
  "remote.SSH.enableRemoteCommand": false,
  "remote.SSH.configFile": "<session>/ssh/config",
  "security.workspace.trust.enabled": true
}
```

Consider enabling Remote-SSH's server Unix-socket mode after changing the guest SSH configuration and verifying it on hardware:

```jsonc
{
  "remote.SSH.remoteServerListenOnSocket": true
}
```

Microsoft documents that this requires `AllowStreamLocalForwarding yes` on the SSH server. It narrows the remote server's own listening surface but does **not** replace the host Editor Enclave.

### 10.3 Server artifact installation

Do not grant general internet access to the sandboxed VS Code process merely so it can fetch server bits.

Preferred options, in order:

1. a trusted pre-launch artifact preparation step performed by `iso`, outside the untrusted editor session, with provenance/integrity validation where available;
2. guest-side download when the VM's configured egress permits it;
3. a narrowly scoped host artifact broker/proxy restricted to the official update origin.

`remote.SSH.localServerDownload=always` is useful for restricted guests but is not, by itself, a security boundary if it requires giving the compromised editor broad host internet access.

### 10.4 Do not rely on Workspace Trust

Keep Workspace Trust enabled because it reduces project-triggered execution, but the guest-root threat model includes replacing the remote extension host/server itself. Workspace Trust therefore cannot be the primary defense for `iso`.

---

## 11. Zed provider

Zed currently supports a distinct data directory:

```text
zed --user-data-dir <DIR>
```

and a foreground mode. Hardened launch should use a unique data directory and a distinct foreground/new instance rather than attach to the user's normal Zed process.

Illustrative shape:

```text
<signed Zed executable>
  --foreground
  --new
  --user-data-dir <session>/user-data
  ssh://iso-editor-<session>/workspace
```

### 11.1 Generated hardened settings

Use a fresh settings file/data dir, not the user's existing `~/.zed` state.

Recommended baseline:

```jsonc
{
  "disable_ai": true,
  "granted_extension_capabilities": [],
  "ssh_connections": [
    {
      "host": "iso-editor-<session>",
      "upload_binary_over_ssh": true
    }
  ]
}
```

Keep Zed's worktree in Restricted Mode unless/until the user explicitly trusts project behavior.

Zed's documentation states that local Zed handles UI, Tree-sitter, unsaved changes and AI while the remote server handles source, terminals, tasks, and language servers. This makes isolation of the **local** Zed state especially important: its normal profile should not be reused for an untrusted `iso` guest.

As with VS Code, pre-cache/upload the matching remote server through a trusted artifact path rather than granting the native editor arbitrary network access.

---

## 12. Supervision and revocation

A hardened editor must remain owned by `iso` after launch.

Replace the current "CLI returned successfully, therefore launch succeeded" behavior with a long-lived `EditorSessionSupervisor`.

Responsibilities:

1. spawn the real editor process as a new process group under Seatbelt;
2. verify that the editor did not delegate to an already-running external process;
3. periodically re-run the same administrative handoff / isolation proof used by managed workloads;
4. track the VM boot identity and session TTL;
5. on proof failure, VM stop/destroy, TTL expiry, or user-requested close:
   - terminate the sandboxed editor process group;
   - terminate editor-created transport processes;
   - revoke/delete the per-session SSH private key and guest authorization;
   - remove session-local sockets and state;
6. never signal a PID unless its executable/process identity still matches the expected sandboxed editor session.

This should reuse the repository's existing patterns for supervised workload sessions, PID identity checks, and fail-closed cleanup.

---

## 13. Host capability model

Make every widening of the host editor sandbox explicit and machine-readable.

For example:

```swift
enum EditorHostCapability: String, Codable, Sendable {
  case clipboard
  case externalLinks
  case internet
}
```

Default hardened set: **empty**.

Capabilities that should not be grantable in hardened mode:

- arbitrary host filesystem;
- login Keychain;
- arbitrary host process execution;
- arbitrary localhost/LAN services;
- SSH agent forwarding;
- reuse of the user's normal editor profile.

The machine interface should report the effective editor security class and grants:

```json
{
  "editor": {
    "provider": "code",
    "security": "sandboxed",
    "host_capabilities": [],
    "isolated_profile": true,
    "ephemeral_ssh_identity": true,
    "supervised": true
  }
}
```

---

## 14. CLI / configuration proposal

Suggested user-facing model:

```text
iso code .                         # sandboxed by default
iso zed .                          # sandboxed by default
iso code . --editor-security strict
iso code . --editor-security unsafe
iso code . --editor-allow clipboard
```

Configuration:

```jsonc
{
  "editor": {
    "security": "sandboxed",
    "allow": []
  }
}
```

Rules:

- `sandboxed` fails closed if the provider cannot launch as a distinct confined process;
- `strict` is provider-dependent and initially may be unsupported for some editors;
- `unsafe` is the only mode allowed to reuse the ordinary user editor/URL scheme and must print a boundary warning;
- adding `clipboard`, `internet`, etc. changes machine output and audit output so downstream tooling can see that the editor session is degraded.

---

## 15. Future `strict` mode

The strongest design is to keep the full editor implementation out of the normal host user session.

### Option A: browser/web editor inside the guest

```text
macOS host
  └── minimal sandboxed browser/viewer
        │ authenticated loopback/SSH tunnel
        ▼
untrusted iso VM
  └── complete editor server + extensions + terminals + tasks
```

The host-side viewer should have:

- a fresh ephemeral browser profile;
- no browser extensions;
- no host file access;
- no persistent cookies/accounts;
- no clipboard except explicit user-mediated grants;
- navigation restricted to the one session origin;
- no external URL launching;
- a connection token generated per session.

Current VS Code source includes a `serve-web` CLI/server path with connection-token support, so a VS Code-specific prototype is technically plausible. Product/licensing/update requirements should be checked before making it a supported provider.

### Option B: disposable editor-sidecar VM

Run the native/graphical editor client in another disposable VM and expose only a remote-display surface to macOS. This is heavier but creates a clearer privilege boundary for editors without a suitable web client.

### Why this is stronger

A hostile editor protocol peer then attacks a browser/viewer or another disposable VM rather than a normal desktop editor process carrying the user's host authority.

---

## 16. What not to use as the primary fix

### Host-key pinning

Necessary for peer identity; irrelevant when the correctly identified VM is malicious.

### `ForwardAgent no`

Necessary and already correct; it protects the SSH agent, not VS Code/Zed host RPC services.

### Workspace Trust / Zed worktree trust

Useful for project-triggered execution. It does not protect against a guest that can replace the remote server process itself.

### Reinstall/checksum the remote editor server

A guest with root can modify, inject into, ptrace, replace, or proxy that server after any integrity check. A clean install is hygiene, not a trust boundary.

### Disable all extensions

For VS Code, Remote-SSH itself is an extension, and a compromised remote server does not need a normal extension to emit malicious protocol traffic. Use a minimal local extension set but still sandbox the client.

### A protocol MITM/firewall inside `iso`

The private remote protocols are large, version-coupled, and intentionally expose many editor APIs. A partial parser/filter would become a fragile security-critical reimplementation. Prefer OS containment. Protocol-level capability reduction should be implemented upstream in the editor where message semantics are known.

---

## 17. Upstream editor improvements worth requesting

Both VS Code and Zed would benefit from an explicit **untrusted remote peer** mode.

For VS Code, such a mode could prevent a remote extension host from invoking host-sensitive main-thread services, including classes of operations such as:

- clipboard reads/writes;
- SecretStorage/authentication access;
- arbitrary local command execution;
- opening external URLs/applications;
- local filesystem APIs;
- host-side tunnel/local-service access;
- account/sync/AI services.

For Zed, a similar remote capability model could separate local UI rendering from local AI/account/host-service authority.

`iso` should still keep the OS sandbox even if such upstream modes are added: defense in depth is appropriate when the guest is intentionally root-compromisable.

---

## 18. Test plan

The feature is not complete until tested against a deliberately malicious remote peer on real macOS hardware.

### 18.1 Environment tests

Plant canary values in the caller environment:

```text
OPENAI_API_KEY=ISO_EDITOR_MUST_NOT_SEE_ME
AWS_SECRET_ACCESS_KEY=ISO_EDITOR_MUST_NOT_SEE_ME
SSH_AUTH_SOCK=<real socket>
```

Verify they are absent from the editor and every child/helper process.

### 18.2 Filesystem tests

From a compromised editor process, verify failure reading/writing:

```text
~/.ssh/
~/.aws/
~/.config/
~/Library/Keychains/
~/Library/Application Support/Code/
~/Library/Application Support/Zed/
~/.iso/                    # except the exact session files intentionally exposed
/tmp/other-user/session sockets
```

Positive control: read/write inside `<session>/` succeeds.

### 18.3 Clipboard test

Exercise the known VS Code remote clipboard API path and direct native pasteboard APIs. Reads and writes must fail in default `sandboxed` mode.

Positive control: `--editor-allow clipboard` makes the capability available and machine/audit output records it.

### 18.4 Keychain/authentication test

Attempt to access editor SecretStorage/authentication APIs and direct Security.framework/keychain operations. No normal-user secret may be returned.

### 18.5 Process escape tests

From a compromised editor/main process, attempt:

```text
/bin/sh
/usr/bin/open
/usr/bin/osascript
/usr/bin/security
launchctl
arbitrary binaries in /Applications or $HOME
```

All must fail except the exact provider helper/SSH executables declared by policy.

Also verify that no LaunchServices/XPC path can start an unsandboxed helper.

### 18.6 Network tests

Plant authenticated canary services on:

- `127.0.0.1`;
- a Unix socket under the user's home/runtime directory;
- the host LAN address;
- an internet listener.

The sandboxed editor must reach only the endpoints explicitly required by its session policy.

### 18.7 Cross-instance SSH test

Start two `iso` VMs. Compromise the editor attached to A and verify it cannot authenticate to B with any credential available inside the Editor Enclave.

### 18.8 Existing-process reuse test

Start normal VS Code/Zed with host secrets available. Then run hardened `iso code` / `iso zed`.

Verify:

- a distinct process/profile is created;
- no remote window appears in the normal editor instance;
- killing the sandboxed process does not kill or affect the normal instance;
- the hardened instance cannot read the normal instance's state/IPC socket.

### 18.9 Supervision test

Invalidate the running proof / stop the VM while the editor is connected.

Verify the editor process tree is terminated, its ephemeral identity is revoked, and reconnection cannot occur without creating a new qualified session.

### 18.10 Sandbox inheritance test

Enumerate the full editor process tree (Electron/Zed helpers, SSH, extension processes). Every process must remain under the intended Seatbelt policy. Attempt known re-launch mechanisms and verify they cannot create an unsandboxed child.

---

## 19. Implementation order

### P0 — close accidental host exposure

1. Replace full editor environment inheritance with an allowlist.
2. Add explicit documentation that ordinary remote-editor mode crosses the VM boundary.
3. Introduce per-session `HOME`, user-data, extension, temp and SSH directories.
4. Stop using `vscode://` / `zed://` fallbacks in hardened mode.
5. Force distinct VS Code/Zed instances (`--user-data-dir` or equivalent).
6. Disable AI/account/sync features in generated isolated profiles.
7. Use a dedicated SSH config rather than the user's global config.

These are worthwhile immediately, but **P0 alone is not a restored containment boundary**.

### P1 — make native editor compromise survivable

1. Add `EditorSandboxPolicy` and a deny-by-default Seatbelt profile.
2. Deny host filesystem, Keychain, clipboard, LaunchServices, Apple Events, arbitrary IPC, arbitrary execution, and general network.
3. Add per-session SSH identities.
4. Add long-lived `EditorSessionSupervisor` and proof revocation.
5. Add provider-specific real-hardware qualification tests.
6. Make `sandboxed` the default and move current behavior behind `--editor-security unsafe`.

### P2 — remove the native remote-protocol trust path

1. Prototype VS Code web/serve-web inside the guest with a minimal host viewer.
2. Evaluate an editor-sidecar VM for providers without a suitable browser client.
3. Pursue upstream untrusted-remote capability modes in VS Code and Zed.

---

## 20. Acceptance gate

Do not describe `iso $EDITOR` as preserving the VM containment boundary until all of the following are true for that provider/security mode:

| Property | Required |
|---|---|
| Separate editor instance/profile | Yes |
| Full host environment excluded | Yes |
| Normal host filesystem inaccessible | Yes |
| Normal Keychain inaccessible | Yes |
| Clipboard denied by default | Yes |
| Arbitrary process execution denied | Yes |
| LaunchServices/Apple Events escape denied | Yes |
| Arbitrary localhost/LAN/internet access denied | Yes |
| Long-lived/shared VM key absent | Yes |
| Existing normal editor cannot be reused | Yes |
| Editor process tree is supervised | Yes |
| Proof revocation terminates session | Yes |
| Real-hardware adversarial tests | Yes |

If any item is not enforceable, report the mode as `unsafe` or `degraded`, not as equivalent to the VM boundary.

---

## 21. References

Repository areas inspected:

- `Sources/IsoHost/Editor/EditorLauncher.swift`
- `Sources/IsoHost/Editor/EditorProvider.swift`
- `Sources/IsoHost/Editor/VSCodeEditorProvider.swift`
- `Sources/IsoHost/Editor/ZedEditorProvider.swift`
- `Sources/IsoHost/Guest/SSH.swift`
- `Sources/IsoHost/Guest/SSHConfig.swift`
- `Sources/IsoHost/Guest/SeatbeltProfile.swift`
- `docs/trust-model.md`
- `docs/editor.md`
- `docs/design/editor-providers-spec.md`

External references consulted:

- VS Code Remote SSH: https://code.visualstudio.com/docs/remote/ssh
- VS Code remote extensions architecture: https://code.visualstudio.com/api/advanced-topics/remote-extensions
- VS Code CLI isolated `--user-data-dir` / `--extensions-dir`: https://code.visualstudio.com/docs/configure/command-line
- VS Code AI disable setting: https://code.visualstudio.com/docs/supporting/faq
- Zed Remote Development: https://zed.dev/docs/remote-development
- Zed CLI (`--user-data-dir`, `--foreground`): https://zed.dev/docs/reference/cli
- Zed extension capabilities: https://zed.dev/docs/extensions/capabilities
- Zed worktree trust: https://zed.dev/docs/worktree-trust
- Zed macOS agent sandboxing / Seatbelt behavior: https://zed.dev/docs/ai/sandboxing

---

## 22. Implementation record

Current behavior is in [editor integration](../editor.md#editor-security), the
[trust model](../trust-model.md#local-editors) and the
[machine interface](../machine-interface.md#code-zed). The Seatbelt profile,
Mach allowlist and launch arguments were derived on macOS 27.0.1 with VS Code
1.140.0 (Remote-SSH 0.128.0) and Zed 1.22.0 by running each editor under a
deny-by-default profile, collecting kernel sandbox denials, and connecting to a
real `iso` VM. Where the shipped design differs from §§4–14, the reason is
recorded here.

| Design | Implemented | Why |
|---|---|---|
| Enclave under `<instance>/editor-sessions/` (§5) | `/private/tmp/iso-editor-<uid>/iso-ed-<id>/`, which must be the user's own `0700` directory | Editors bind Unix sockets deep inside it (Zed's askpass socket under `TMPDIR`, VS Code's IPC socket under its user data); macOS caps socket paths at 104 bytes and data directories are often long. |
| SSH straight to the VM's address on TCP 22 (§8.6) | The editor's ssh connects to a loopback `ssh -L` tunnel that `iso` runs outside the sandbox with the pinned transport | Seatbelt filters network rules by port only (`*` or `localhost`), so allowing `*:22` would allow any host on port 22. macOS Local Network privacy also blocks unsigned helpers from reaching the VM network. The session key carries `from="127.0.0.1,::1"`. |
| No shells (§8.2) | VS Code's profile may exec `/bin/sh` (→ `/bin/bash`) and use ptys it allocates (`com.apple.sandbox.pty` extension) | Remote-SSH hard-codes running ssh through a hidden terminal (`/bin/sh -c` on a pty). The shell inherits the same profile and can exec nothing else; the user's own terminal ptys stay unreachable. Zed needs neither. |
| Narrow local IPC (§8.6) | VS Code gets one fixed loopback port (`remote.SSH.preferredLocalPortRange`, dynamic forwarding and the local server off) | Remote-SSH's SOCKS mode binds an arbitrary port; a fixed `-L` port keeps loopback access to that port and the tunnel port only. |
| Workspace Trust enabled (§10.2) | Disabled in the session profile | Remote-SSH's hidden terminal requires the (remote) folder to be trusted before it connects, so the prompt is a mandatory click with the same outcome. The sandbox is the boundary (§10.4). |
| Chromium sandbox | `--disable-chromium-sandbox` | Seatbelt forbids re-initializing a sandbox (`forbidden-sandbox-reinit`); every helper inherits the outer profile instead. |
| Remote-SSH from a reviewed source (§10.1) | Copied from the user's own `~/.vscode/extensions` (newest `ms-vscode-remote.remote-ssh-*`, user-owned real directory) | No network fetch by `iso`; a missing extension fails with an install hint. |
| Trusted server pre-provisioning (§§10.3, 11) | Not implemented | VS Code Server downloads in the guest under open egress. Zed resolves `zed-remote-server`'s URL from the host, so a sandboxed Zed needs `internet` once per Zed version unless the guest already has it. Both providers warn. |
| `externalLinks` capability (§13) | Not implemented | Opening URLs needs the LaunchServices database, which also opens apps and `.command` files: not narrowly grantable. `internet` is HTTPS (443) only. |
| No LaunchServices (§8.5) | `com.apple.coreservices.launchservicesd` is allowed; `com.apple.lsd.mapdb`/`modifydb` are not | AppKit cannot show a window without checking in. Probes from inside the profile confirmed that opening an app, an `https:` URL, an app URL scheme and a `.command` file all fail. |
| Session TTL tracking (§12) | Covered by the readiness proof | The VM owner halts the instance at `limits.session_ttl`, after which the proof (and the tunnel) fail. |
| `strict` mode (§15) | Not implemented; `--editor-security strict` is rejected | P2. |

Also observed: the pasteboard (`com.apple.pasteboard.1`) and keychain
(`SecurityServer`, `securityd.xpc`) are denied, and Zed's credential reads fail
with `-50`. Zed's single-instance handoff port is unreachable, so it never
joins a running Zed. The guest may keep a session's `authorized_keys` line when
the instance stops first; the private key is deleted with the enclave.

Remaining from §18: the adversarial matrix runs as unit tests for
environment, filesystem, process-execution and loopback confinement under the
real kernel (`EditorSandboxTests`), plus the manual probes above; an
integration phase that drives real editors against a malicious guest is not
yet part of `tests/run-integration.sh`.
