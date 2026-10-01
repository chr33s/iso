<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Configuration Reference

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

isolate reads configuration from `~/.iso/config.jsonc` by default. Pass `--config <path>` to use a different file: a `.jsonc` path is read as JSONC, a `.json` path as strict JSON, and any other extension is rejected. There is no automatic `config.json` search.

**JSONC** here means RFC 8259 JSON plus `//` line comments and `/* ... */` block comments outside strings. Block comments do not nest. Trailing commas, single-quoted strings, unquoted keys, and other JSON5 extensions are rejected, as are duplicate object keys. Keys use snake_case; former TOML sections are nested objects. The document is limited to 1 MiB, nesting depth 32, 16,384 keys, 4,096 array elements, and 64 KiB strings.

If no configuration file exists, isolate uses built-in defaults. A valid minimal config is an empty object, `{}`. `iso setup --config-only` writes a commented template (the same content as [`config.example.jsonc`](../config.example.jsonc)); `iso init` is a deprecated alias for it.

Commands that edit the configuration (`iso proxy setup`, `iso github setup-pat` and related PAT commands) rewrite the file as formatted strict JSON: comments and formatting are not preserved, but unrelated keys are.

A leading `~` is expanded to the home directory in path-valued fields (`data_dir`, `claude.config_dir`, `codex.config_dir`, the `apple_container` paths, and the `claude.marketplaces` / `codex.marketplaces` / `profiles.<name>.marketplaces` lists). The shell does not expand `~` inside config-file values, so isolate does it when loading the file.

Run `iso validate` to surface errors and warnings before anything touches a VM. Errors name the field path and error category; they never print the file's contents or secret values.

## Migrating from TOML

isolate no longer reads TOML. If `--config` names a `.toml` file, or `~/.iso/config.toml` exists without a `~/.iso/config.jsonc`, isolate stops with instructions instead of starting with defaults. Convert the file once with the offline converter (Python 3.11+, standard library only):

```sh
python3 scripts/migrate-config-to-jsonc.py \
  --input ~/.iso/config.toml --output ~/.iso/config.jsonc
```

The converter leaves the source untouched, refuses an existing destination, writes the output with mode `0600`, and never executes `cmd:` values. It refuses:

- **Retired fields** — `firecracker_bin`, `vm.kernel_path`, `vm.boot_args`, and the `network` section (`host_ip`, `subnet_mask`, `host_iface`). These Firecracker settings have no effect on the Apple backend. Pass `--drop-retired-fields` to remove exactly those fields; the converter reports their paths, never their values.
- **Literal proxy credentials** — `proxy.anthropic.credential` and `proxy.openai.credential` must be `cmd:` references. Store the credential with [`iso proxy setup`](commands.md#proxy) (macOS Keychain) or write your own `cmd:` reference.
- Values without a lossless JSON form, such as TOML dates.

Comments are not carried over. Once `config.jsonc` exists, a remaining `config.toml` is ignored.

## Top-level fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `data_dir` | string (path) | `~/.iso` | Directory for VM artifacts: images, instances, keys. |
| `ssh_port` | integer | `22` | SSH port on the guest VM. Must be > 0. |
| `github` | string or object | unset (treated as `"off"`) | GitHub authentication strategy. See [GitHub auth](#github-auth). |
| `security` | object | unset | `{"preset": "networked" | "provider-only" | "offline"}`: defaults for the hardening settings. See [security presets](#security-presets). |
| `limits` | object | unset | Host-enforced budgets. See [limits](#limits). |
| `egress` | string | `"open"` | Guest network reach beyond the host: `"open"`, `"none"`, or `"filtered"`. See [egress](#egress). |
| `post_start` | string | unset | Shell command run in the guest after every successful boot, before any interactive `shell` / agent launch. Failure is logged at `WARN` and does not fail startup. Override per invocation with `iso up --post-start <cmd>` or `iso start --post-start <cmd>`. |

## GitHub auth

The `github` field determines how isolate obtains a `GITHUB_TOKEN` for the guest:

| Value | Behavior |
|-------|----------|
| `"auto"` | Checks `$GITHUB_TOKEN` first. Falls back to `gh auth token` if unset. |
| `"env"` | Reads `$GITHUB_TOKEN` from the environment only. Warns if unset. |
| `"off"` | No GitHub token forwarding. |
| `"pat"` | Uses a per-repo fine-grained PAT recorded under `github.pat`. GitHub enforces the permissions and repositories selected for that token. |

When a token is present, isolate runs `gh auth setup-git` inside the guest to wire up git credential helpers.

`iso up --no-github` and `iso start --no-github` force `"github": "off"`
for that invocation, regardless of the configured strategy, and suppress the
PAT setup prompt. Configured PAT retrieval commands are not evaluated. Model
credentials and other configuration remain in effect, and the config file is
not changed. `iso up` rejects this flag for an already-running instance;
stop it first, then repeat `up` with the flag.

This has the same scope as `"github": "off"`: it disables strategy-based token
forwarding, but does not block explicit `env_forward`, `guest_env`, or `--env`
entries, or the one-shot host-token fallback used for `--git-repo` clones.
It does not erase credentials already stored in the guest. Later invocations
(including `shell` and `exec`) use the configured strategy again.

### Fine-grained PAT (`"github": "pat"`)

In pat mode isolate forwards a *per-repo* fine-grained personal access token: the resolved `owner/repo` at VM startup selects the matching entry in `github.pat`. Compared with `"auto"` / `"env"`, the effective reach of a leaked token is bounded by the repos and permissions GitHub recorded when it was created — GitHub rejects out-of-scope operations (REST and GraphQL) server-side, not in isolate.

Configure via the wizard:

```sh
iso github setup-pat --repo trailofbits/coop
```

The wizard opens the PAT-creation form in your browser, validates the token via `/user` and `/repos/<repo>`, stores the token in the macOS Keychain (service `coop-github-pat`, account `owner-repo`), and writes a `github.pat["owner/repo"]` entry. The token itself is stored only in the Keychain — the config file holds a `cmd:` invocation that retrieves it. If the Keychain is unavailable the wizard fails; there is no fallback store.

#### Submodule discovery

A fine-grained PAT is scoped to specific repositories, so a token for the parent repo alone cannot clone its submodules. To help you scope the token correctly, the wizard inspects the parent repo's `.gitmodules` and classifies the submodule URLs it finds. This is advisory only — it never fails the wizard, and a discovery problem won't block writing a valid PAT entry.

Discovery makes outbound network calls:

- It fetches `.gitmodules` from the parent's default branch via the GitHub Contents API. Before you paste a token, it tries `gh auth token` (if `gh` is installed and authenticated) and otherwise falls back to an anonymous request, which can read the file when the parent repo is public. A `404` (no `.gitmodules`, or a private parent that an unauthenticated request can't see) is treated as a successful empty result — there is simply nothing to suggest. Only when both attempts fail to reach a definitive answer (e.g. rate-limited or a network error) does discovery defer until after you paste the token, using that token instead. A `gh auth token` value read here is used only for this fetch — it is never persisted or forwarded into the guest.
- For each candidate submodule it makes an anonymous `GET /repos/<slug>` to detect public repos. Public submodules clone without a token, so they are dropped from the suggestions. Unauthenticated GitHub API requests share a 60/hour per-IP rate limit, so a repo that can't be confirmed public (404, rate-limited, or a network error) is treated as private and kept in the suggestions.

The remaining (private) submodules are routed by resource owner:

- **Same owner as the parent** — a single PAT can cover these, so they are added to the form's "Only select repositories" list alongside the parent. The wizard then re-probes the pasted token against each and re-prompts you to widen the token until all are covered.
- **Other owners** — a fine-grained PAT is scoped to one resource owner, so each needs its own token. The wizard prints a follow-up `iso github setup-pat --repo <slug>` line per repo, grouped by owner.
- **Non-GitHub URLs** (e.g. GitLab) — listed as a warning; this token can't cover them.

Only depth-1 submodules are inspected. Submodules of submodules are not expanded and need their own `setup-pat` runs.

Multi-repo example:

```jsonc
{
  "github": {
    "mode": "pat",
    "pat": {
      "trailofbits/coop": {
        "token": "cmd:security find-generic-password -s coop-github-pat -a trailofbits-iso -w"
      },
      "trailofbits/coop-plugins": {
        "token": "cmd:security find-generic-password -s coop-github-pat -a trailofbits-iso-plugins -w"
      }
    }
  }
}
```

Bring-your-own-token (no wizard, useful for CI/Terraform). Any `cmd:` invocation that prints the token on stdout works. Examples:

```jsonc
{
  "github": {
    "mode": "pat",
    "pat": {
      // Vault
      "trailofbits/coop": {
        "token": "cmd:vault read -field=token secret/iso/github/trailofbits-iso"
      },
      // 1Password CLI
      "trailofbits/coop-plugins": {
        "token": "cmd:op read op://Private/coop-github-pat/password"
      }
    }
  }
}
```

isolate runs such a reference only when it needs the token and never creates, changes, or deletes what it points at.

Other subcommands:

| Command | Effect |
|---------|--------|
| `iso github status` | List configured entries and where they are stored; add `--probe` to test retrieval. Never prints token material. |
| `iso github rotate-pat --repo X/Y` | Re-run the wizard against an existing entry (PATs expire — max 1 year). |
| `iso github forget-pat --repo X/Y` | Remove the `github.pat["X/Y"]` entry and, for a iso-created Keychain item, the stored secret. Does **not** add a skip marker; the token may still be live on GitHub. |
| `iso validate --probe` | Resolves each entry and probes `GET /user` against api.github.com. May trigger a Keychain authorization prompt (or your own `cmd:` tool's prompt) the first time per session; `vault:` entries need one secret-store unlock. |

#### Assign an existing PAT to a VM

```sh
iso github assign-pat --vm projects --repo myorg/frontend
iso github status --vm projects
iso github unassign-pat --vm projects
```

`--repo` selects the **stored entry key**, not the workspace repository or the
PAT's permission scope. For example, a token stored under `myorg/frontend`
may also authorize `myorg/backend`; assigning it to a VM whose workspace is a
plain parent directory works without detecting either child repository.
Different VMs can select different entries for the same workspace.

Assignment is explicit opt-in and takes precedence over workspace detection.
Only the validated key is saved in owner-only, atomically written
`<instance>/github_pat.json`; the shared secret is resolved again for each
subsequent session or clone. Assignment works while the VM is stopped.
Restart/bootstrap, shell, exec, agent sessions, and restore/reprovision use it.
Existing shells, agents, and background processes are not updated. Restart
without `--no-agents` to establish the git credential helper on a guest that
has never had GitHub authentication bootstrapped.

`up --no-github` and `start --no-github` suppress assignment use and the PAT
setup prompt for that invocation, without removing the saved association.
The existing separate clone fallback remains: under opt-out, a GitHub HTTPS
clone may still use host credentials. Without an assignment, normal auth-mode
and repository selection are unchanged.

Missing entries, unreadable or malformed assignment state, and failed secret
retrieval fail instead of falling back. Restore a forgotten entry with
`setup-pat`, or remove the association with `unassign-pat`. Rotation affects
subsequent resolutions. Unassigning restores normal selection and neither
deletes the shared secret nor revokes it on GitHub. Destroying the VM removes
its association with the VM state, leaving the shared PAT intact.

An active assignment rejects managed `GITHUB_TOKEN` **and** `GH_TOKEN` entries
in `guest_env`, either agent's `env_forward`, or persisted `--env` /
`containerEnv` overrides. Remove these conflicting entries, including saved
keys in `<instance>/guest_env.json`, or unassign the PAT. This controls isolate's
delivery; the guest can still change its own environment. The VM receives the
token's actual authority over every repository it covers.

#### Auto-prompt at VM startup

When `iso up` or `iso start` runs with a resolvable repo (usually the synced workspace's `origin`) and `github` is `"off"` (or `"pat"` with no matching entry), isolate offers to run the wizard inline: `[y/N/never]`. Three answers:

- `y` — run the wizard, then continue the start.
- `N` (default) — start unauthenticated, ask again next time.
- `never` — record a skip marker under `github.skip` so isolate won't ask again for this repo.

Non-interactive contexts (`CI` is set, stdin is not a TTY) skip the prompt and log a one-line tip pointing at `iso github setup-pat`. The `--no-prompt` flag skips the prompt silently. Set `"setup": { "prompt_for_pat": false }` in the configuration to disable the prompt globally.

#### Skip markers

```jsonc
{
  "github": {
    "mode": "pat",
    "skip": ["trailofbits/big-repo"]
  }
}
```

`iso github setup-pat --repo X/Y` removes any skip marker for `X/Y` when it adds a new entry.

## `vm` section

VM resource allocation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `vcpu_count` | integer | `2` | Number of vCPUs for **new** instances. Must be > 0. Overridable with `--vcpus` on `setup` and `up`. Change an existing instance with `iso resize --vcpus`. |
| `mem_size_mib` | integer | `4096` | Memory in MiB for **new** instances. Must be >= 128. Overridable with `--mem` on `setup` and `up`. Change an existing instance with `iso resize --mem`. |
| `template_size_gib` | integer | `8` | Template rootfs disk size in GiB. Must be > 0. Overridable with `--template-size` on `setup`. |

The guest kernel is selected with [`apple_container.kernel`](#apple_container-section).

## Guest user

The guest VM runs as an unprivileged account, `ubuntu` (uid 1000) by default. Override the username at setup time with `iso setup --guest-user <name>`:

```sh
iso setup --guest-user vscode
```

The name is validated against the POSIX-portable pattern `[a-z_][a-z0-9_-]{0,31}`; `root` is rejected because isolate assumes an unprivileged uid-1000 account.

The guest user is **baked into the image at setup time and immutable for the image's lifetime** — it is persisted in the image's `template_config.json`, and `up` / `start` / `shell` / `exec` read it back from there. To change it, destroy and recreate the image: `iso destroy && iso setup --guest-user <name>`.

### devcontainer `remoteUser`

When a workspace's `devcontainer.json` declares a `remoteUser` (e.g. `vscode` for the Microsoft devcontainer base images), the handling depends on the stage:

- **At `iso setup`**, a valid `remoteUser` becomes the image's guest user unless `--guest-user` already pins one (the CLI flag wins, and the override is reported).
- **At `iso up` / `iso start`**, the guest user is already baked in. If the file's `remoteUser` matches the image's persisted user, it is applied; if it differs, isolate reports the mismatch, skips forwarding `containerEnv` (its values often reference a `/home/<remoteUser>/...` path that doesn't exist on disk), and points you at `iso destroy && iso setup --guest-user <remoteUser>` to switch.

See [Devcontainer support](devcontainer.md) for the full translation table.

## Guest PATH

Every guest SSH session — login, non-login, and `exec` — has the guest user's `~/.local/bin` on `PATH`. isolate prepends it to `PATH` in `/etc/environment`, which `pam_env` applies to all sessions. This is where the Claude Code installer places its per-user `claude` binary.

## `guest_env` section

Literal environment variables to set inside the guest, independent of the host process environment. Use this when you want a value that isn't (or shouldn't be) on the host — `env_forward` covers the inherit-from-host case.

```jsonc
{
  "guest_env": {
    "RUST_LOG": "info",
    "MY_FLAG": "1"
  }
}
```

Keys are env var names; values are the literals to inject. Entries here **override** any value resolved through other mechanisms for the same name (forwarded host env, `claude.api_key`, etc.), and the override is logged at `WARN`.

**Secrets:** values land in the guest's process environment in plain text and may be visible via `ps`/`/proc` to guest users. For credentials, prefer `env_forward` (host process env stays the source of truth) or one of the `cmd:` integrations on the structured fields (`claude.api_key`, etc.).

Override or extend per-invocation with `iso up --env KEY=VALUE` or `iso start --env KEY=VALUE` (repeatable).

## `claude` section

Claude Code configuration injected into the guest VM at start time. Every field is optional.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `api_key` | string | unset (reads `$ANTHROPIC_API_KEY` from environment) | Anthropic API key, literal or `cmd:` reference (run on the host with `sh -c` when needed). Forwarded to the guest via SSH `SendEnv`. Never written to disk inside the VM. |
| `config_dir` | string (path) or `false` | `~/.claude` | Source for `CLAUDE.md`, `keybindings.json`, `rules/`, `commands/`, `skills/`, `agents/`, `output-styles/`, `themes/`, and `workflows/`, copied into guest `~/.claude/` on each start. Complete bundles and narrow companion preferences are imported. Supports `~` expansion; `false` stops copying while retaining prior files/preferences. Host deletions do not delete guest files. See [import semantics and limitations](claude-integration.md#config-directory). |
| `env_forward` | array of strings | `[]` | Extra environment variable names to forward from host to guest via SSH `SendEnv`. `ANTHROPIC_API_KEY` and `GITHUB_TOKEN` are forwarded automatically when set; list additional variables here. |
| `marketplaces` | array of strings | `[]` | Plugin marketplace sources. Each entry is a GitHub repo URL or an absolute local directory path. Local directories are copied into the guest before registration. |
| `plugins` | array of strings | `[]` | Plugins to install from registered marketplaces. Format: `plugin-name@marketplace-name`. |
| `mcp_servers` | object | `{}` | MCP servers to register in the guest. Keys are server names; values are server definitions. See [MCP servers](#mcp-servers). |
| `local_model` | object | unset | Host-side model endpoint to route Claude Code at when the VM is in local mode (`iso model <vm> local`). See [Local-model routing](#local-model-routing). |

### MCP servers

Each key in `mcp_servers` maps a server name to its definition. Three transport types are supported.

**Stdio server** (spawns a process):

```jsonc
{
  "claude": {
    "mcp_servers": {
      "my-server": {
        "command": "/usr/bin/my-mcp-server",
        "args": ["--flag", "value"],
        "env": { "SERVER_API_KEY": "MY_HOST_ENV_VAR" }
      }
    }
  }
}
```

**HTTP server** (connects to a remote endpoint):

```jsonc
{
  "claude": {
    "mcp_servers": {
      "remote-server": {
        "type": "http",
        "url": "https://mcp.example.com/v1",
        "headers": { "Authorization": "Bearer token" }
      }
    }
  }
}
```

**SSE server** (connects to a remote endpoint over Server-Sent Events):

```jsonc
{
  "claude": {
    "mcp_servers": {
      "events-server": {
        "type": "sse",
        "url": "https://mcp.example.com/sse",
        "headers": { "Authorization": "Bearer token" }
      }
    }
  }
}
```

Definition fields:

| Field | Type | Description |
|-------|------|-------------|
| `command` | string | Command to run (stdio servers). |
| `args` | array of strings | Arguments for the command (stdio servers). Default: `[]`. |
| `type` | string | Server type: `"http"` or `"sse"` (HTTP servers). Omit for stdio. |
| `url` | string | Server URL (HTTP servers). |
| `env` | object | Environment variable mappings. Keys are the names the server expects; values are the host env var names to read. Default: `{}`. |
| `headers` | object | HTTP headers to send (HTTP servers). Default: `{}`. |

Servers are registered with `claude mcp add-json` at user scope; each definition is passed to it on stdin, not in its arguments.

## `codex` section

Codex configuration injected into the guest VM at start time. Every field is optional.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `auth` | string | `"api_key"` | Codex auth mode: `"api_key"` forwards an OpenAI API key; `"chatgpt"` uses ChatGPT account or workspace login through the guest Linux keyring. |
| `api_key` | string | unset (reads `$OPENAI_API_KEY` from environment) | OpenAI API key, literal or `cmd:` reference. Used only with `auth` `"api_key"`. Forwarded to the guest via SSH `SendEnv`. Never written to disk inside the VM. |
| `config_dir` | string (path) or `false` | `~/.codex` | Source directory for Codex config files. Copies an allowlist of entries (`AGENTS.md`, `prompts/`, `config.toml`, `auth.json`) from this directory to `~/.codex/` in the guest on start. `auth.json` is omitted when `auth` is `"chatgpt"` or `proxy.openai` is active. Set to `false` to disable. Supports `~` expansion. |
| `env_forward` | array of strings | `[]` | Extra environment variable names to forward from host to guest via SSH `SendEnv`. `OPENAI_API_KEY` and `GITHUB_TOKEN` are forwarded automatically when set; list additional variables here. |
| `marketplaces` | array of strings | `[]` | Codex plugin marketplace sources. Each entry is a `owner/repo`[`@ref`] shorthand, a git URL, or an absolute local directory path. Local directories are copied into the guest before registration. Baked into the golden image and delta-installed on first boot. |
| `plugins` | array of strings | `[]` | Codex plugins to install from registered marketplaces. Format: `plugin-name@marketplace-name`. |
| `mcp_servers` | object | `{}` | MCP servers to merge into the guest `~/.codex/config.toml`. Keys are server names; values are server definitions. See [MCP servers](#mcp-servers). |
| `local_model` | object | unset | Host-side model endpoint to route Codex at when the VM is in local mode (`iso model <vm> local`). See [Local-model routing](#local-model-routing). |

isolate preserves any other settings already present in the staged `config.toml`, but the `mcp_servers` table is owned by isolate when `codex.mcp_servers` is configured. With `auth` `"chatgpt"`, isolate also writes `cli_auth_credentials_store = "keyring"` so Codex caches account credentials in the guest OS credential store instead of `auth.json`.

## Local-model routing

`claude.local_model` and `codex.local_model` declare a host-side model
endpoint to route an agent at instead of the cloud. They are inert until the VM
is switched to local mode with [`iso model <vm> local`](commands.md#model);
`iso model <vm> remote` restores the cloud defaults. The two tools are
independent — configure one, both, or neither.

Each object takes the same fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host_url` | string (URL) | required | Endpoint as seen **on the host**, where the model server runs (Ollama / LM Studio / vLLM / llama.cpp). Must be an `http`/`https` URL with a host. A loopback endpoint (`localhost`, `127.0.0.1`) is carried into the guest over a per-instance SSH reverse tunnel to the guest's own loopback (a privileged port moves up by 40000; IPv6 loopback is refused); any other host passes through verbatim, so a LAN endpoint also works. |
| `model` | string | required | Model name to request. Must not be empty. For Claude, isolate pins every model tier (opus/sonnet/haiku and the small-fast model) to this name so any tier routes locally. |
| `auth_token` | string | unset | Auth token for the endpoint. Optional — permissive local servers (Ollama, LM Studio, vLLM) ignore it, and isolate sends a dummy value when it is omitted. The value is used verbatim; unlike `api_key` it does not resolve a `cmd:` prefix. |

```jsonc
{
  "claude": {
    "local_model": {
      "host_url": "http://localhost:11434",       // Anthropic Messages API
      "model": "qwen2.5-coder:32b"
    }
  },
  "codex": {
    "local_model": {
      "host_url": "http://localhost:11434/v1/",   // Responses API
      "model": "gpt-oss:120b"
    }
  }
}
```

An endpoint set here takes precedence over one entered interactively and saved
in the instance's `model.json` by `iso model … local`. See the local-model
sections of [docs/claude-integration.md](claude-integration.md) and
[docs/codex-integration.md](codex-integration.md) for how each endpoint is
materialized into guest config.

## `proxy` section

Credential-proxy mode requires macOS 27+ and the `iso-proxy` companion.

`proxy.anthropic` and `proxy.openai` declare host-side
credential-injecting upstreams for Claude Code and Codex. When an upstream is
configured, isolate runs a `iso-proxy` process on the host for the lifetime of
each remote-mode VM: the guest is pointed at the proxy (a base-URL override) and
holds only a per-instance capability token, while the real credential stays on
the host and is injected onto outbound requests the guest never sees. Absent
config means no proxy — credentials are forwarded into the guest exactly as
before, unless `proxy.mode` is `"required"` (below).

Every golden image installs the Secret Service packages this mode needs
(`dbus-user-session`, `gnome-keyring`, `libsecret-tools`) regardless of the
`auth` setting, because the image is built once and reused across configs —
gating them would let a later `"auth": "chatgpt"` edit meet an image that cannot
serve it.

`proxy.openai` is API-key based and cannot be combined with
`codex.auth` `"chatgpt"`. Use one Codex remote auth path per VM: the proxy
for an OpenAI API key, or ChatGPT auth for account/workspace access.

Proxy mode applies only in remote model mode
([`iso model <vm> remote`](commands.md#model)); local mode takes precedence.
Each provider is an optional default, and a VM can override its own credential
per provider with [`iso proxy setup --vm <name>`](commands.md#proxy) (stored in
the instance's `proxy.json`, not in the config file).

### `proxy.mode`

| Value | Behavior |
|-------|----------|
| `"auto"` (default) | A provider with an upstream (config default or per-VM override) runs through its proxy, and none of its credential variables reaches the guest. A provider without one keeps the legacy raw forwarding, with a warning at `up`/`start`. |
| `"required"` | No provider credential variable (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`) reaches the guest by any path. Values isolate would forward automatically (host environment, `api_key`) are withheld; declaring one in `env_forward`, `guest_env` or `--env` is an error. The host `~/.codex/auth.json` is not staged into the guest either. A remote-mode VM with agents must have at least one provider proxy, or `up`/`start` fails. |
| `"off"` | No proxy starts; configured upstreams and per-VM overrides are ignored, and credentials are forwarded as without a proxy. A `{vault:}` provider secret from `--env`/`--env-file` is an error rather than being forwarded. |

`proxy.<provider>.credential` and `github.pat` tokens also accept
`vault:<name>`, read from [`iso secrets`](commands.md#secrets) when the value
is needed. Fields whose value is placed in the guest (`claude.api_key`,
`codex.api_key`, MCP headers) refuse `vault:`, so a stored provider credential
never lands in the guest.

Both objects take the same fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `credential` | string | required | A `cmd:` reference that prints the real credential (an API key or a Claude `setup-token`), resolved at proxy start. Literal values are rejected; the error names the field without printing it. The resolved value is never written to disk and never forwarded into the guest. |
| `auth` | `api_key` \| `bearer` | `api_key` | How the proxy injects the credential upstream. `api_key` sends `x-api-key: <credential>` (the Anthropic API-key form); `bearer` sends `Authorization: Bearer <credential>`, used for a Claude `setup-token`. OpenAI keys are always Bearer. |

```jsonc
{
  "proxy": {
    "anthropic": {
      "credential": "cmd:security find-generic-password -s coop-anthropic -a anthropic -w",
      "auth": "api_key"
    },
    "openai": {
      "credential": "cmd:op read op://Private/OpenAI/credential",
      "auth": "bearer"
    }
  }
}
```

`iso proxy setup` writes these entries for you: it takes a pasted credential,
stores it in the macOS Keychain and fills in the `cmd:` reference. There is no
other built-in store and no fallback; if the Keychain is unavailable, setup
fails. Any other `cmd:` reference (1Password, Vault, a file you manage) is
yours to write; isolate runs it but never creates or deletes what it points at. See the
[credential proxy guide](credential-proxy.md) and
[`iso proxy`](commands.md#proxy) for the workflow.

## `profiles` section

Custom installation profiles for `iso setup --profile <name>`. Each profile declares packages and scripts that run during rootfs template creation.

```jsonc
{
  "profiles": {
    "my-tools": {
      "apt_packages": ["ripgrep", "fd-find", "jq"],
      "pre_install": "curl -fsSL https://example.com/setup.sh | bash",
      "post_install": "echo 'done'",
      "marketplaces": ["https://github.com/anthropics/claude-plugins-official"],
      "plugins": ["rust-analyzer-lsp@claude-plugins-official"]
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `apt_packages` | array of strings | `[]` | Apt packages to install in the guest template. |
| `pre_install` | string | unset | Shell commands to run before `apt-get install` (e.g., adding PPAs or GPG keys). |
| `post_install` | string | unset | Shell commands to run after `apt-get install`. |
| `marketplaces` | array of strings | `[]` | Plugin marketplace sources for this profile. Same format as `claude.marketplaces`. |
| `plugins` | array of strings | `[]` | Plugins to install for this profile. Same format as `claude.plugins`. |

Custom profiles compose with built-in ones (`python`, `node`, `c`, `fuzz`, `rust`, `go`). Combine them with commas: `iso setup --profile python,node,my-tools`.

## `forward_ports` field

Default host-to-guest TCP port forwards applied to every VM startup. Forwards are established as SSH `-L` tunnels after the VM is ready and torn down on `iso stop`.

Each entry accepts a bare port (host and guest match), a `"GUEST:HOST"` string, or an object.

```jsonc
{
  "forward_ports": [
    3000,                                            // host 3000 ⇒ guest 3000
    "8080:18080",                                    // host 18080 ⇒ guest 8080
    { "guest": 5432, "host": 15432, "label": "postgres" } // label is for your own bookkeeping
  ]
}
```

`--forward-port` on `iso up` or `iso start` appends to (or overrides on guest-port collision) the entries from config; later entries win. Each instance remembers its forward set across `iso stop` / `iso start`, so a restart without `--forward-port` re-establishes the same tunnels.

Collision with an in-use host port fails fast before the VM is created. The error names the offending port and suggests a `GUEST:HOST` override.

## `apple_container` section

See [Apple sandbox configuration](backends.md#configuration) for how each value is used. Unknown keys are rejected.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `binary` | string (absolute path) | search order in [backends.md](backends.md) | `iso-sandbox` runtime binary. |
| `builder` | string (absolute path) | search order in [backends.md](backends.md) | `container` binary used only to build images. |
| `kernel` | string (absolute path) | the kernel stock Apple `container` installs | Guest kernel; must be one the runtime pins. |
| `probe_timeout_seconds` | integer | `10` | `version`, `inspect`, `list`. |
| `operation_timeout_seconds` | integer | `60` | Resource changes, deletes, guest commands. |
| `create_timeout_seconds` | integer | `600` | Create, grow, commit, restore, init, maintenance install. |
| `boot_timeout_seconds` | integer | `120` | Boot to SSH-ready. |
| `stop_timeout_seconds` | integer | `90` | Clean guest shutdown. |
| `build_timeout_seconds` | integer | `3600` | Image build; `setup --builder-timeout` overrides. |

Each timeout must be between 1 and 86400 seconds.

## `egress`

`"none"` creates each new instance's sandbox in vmnet host mode with NAT
(IPv4 and IPv6), the vmnet DNS proxy, router advertisements and DHCP all
disabled, so the guest has no route beyond the Mac and no resolver. Host→guest
SSH still works, and so does everything isolate tunnels over it: the credential
proxy, local-model tunnels and `--forward-port`. It does **not** isolate the
guest from services on the Mac itself: like `"open"`, a guest can connect to
anything listening on the host's addresses (see the
[trust model](trust-model.md#apple-sandbox-backend)).

`"filtered"` uses the same host-only network as `"none"`. The separate
`iso-egress` package can parse an allowlist and a CONNECT request, but this
host build does not start or supervise that companion yet, so a filtered VM
has no general route and approved hosts are not reachable through it. It is
not credential protection: `proxy.mode` still decides whether raw provider
keys are forwarded. `egress_filter.allowed_hosts` is valid only with
`"filtered"`; an empty list approves nothing. Agent definition hints are not
added to that list. An existing instance cannot change its creation-time mode
through `--egress`.

The mode is fixed when an instance is created; `up`/`start` of an instance
created under another mode is refused rather than silently widened or
narrowed. Recreate the instance (`iso destroy`, then `iso up`) to change it.
No raw provider credential enters a `"none"` guest, whatever `proxy.mode`
says: provider variables are withheld (declaring one is an error) and the host
`~/.codex/auth.json` is not staged; a remote-model VM therefore needs a
provider proxy, or `up`/`start` fails. Package installs and other downloads
inside a `"none"` guest fail; bake them
into the image (`iso setup --profile …`) instead. Combine with
`"proxy": {"mode": "required"}` for a guest whose only way out is the
credential proxy.

## Security presets

```jsonc
{ "security": { "preset": "provider-only" } }
```

| Preset | `egress` | `proxy.mode` | `workspace.pull.mode` |
|--------|----------|--------------|-----------------------|
| `networked` (same as no preset) | `open` | `auto` | `direct` |
| `provider-only` | `none` | `required` | `stage` |
| `offline` | `none` | `off` | `stage` |

A preset only supplies defaults: any of those fields written explicitly wins.
`iso up --dry-run --json` (and `start`) prints the result under `security`.
`offline` is meant for local models or fully pre-provisioned images; leave
`github` unset (off) with it.

## `limits`

```jsonc
{ "limits": { "session_ttl": "8h" } }
```

`session_ttl` (seconds, or a number with an `s`/`m`/`h` suffix, from 1 minute
to 720 hours) ends each boot of an instance that long after `up`/`start`
began it. The sandbox's owner process halts the VM at the deadline using the
host's clock (the guest clock plays no part, and host sleep counts), a
relaunch after a crash refuses to boot past it, and isolate refuses to hand out
an instance whose deadline has passed (`APPLE_SESSION_EXPIRED`). `iso start`
begins a new session. Unknown `limits` members are rejected.

Host-side logs are already bounded without a setting: the guest console log
restarts after 8 MiB, and the owner log holds only the runtime's own lines.

## `workspace` section

How `iso pull` returns guest files. See [staged pulls](workspaces.md#staged-pulls).

```jsonc
{
  "workspace": {
    "pull": {
      "mode": "stage",          // "direct" (default) or "stage"
      "max_files": 50000,
      "max_bytes": "1GiB",
      "max_file_bytes": "256MiB"
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `pull.mode` | string | `"direct"` | `direct` pulls straight into the local directory; `stage` stages and reviews first |
| `pull.max_files` | integer | `50000` | Most staged entries of any type |
| `pull.max_bytes` | bytes | `"1GiB"` | Most regular-file bytes in one stage |
| `pull.max_file_bytes` | bytes | `"256MiB"` | Largest single staged file |

Byte fields take an integer or a string with a `KiB`, `MiB` or `GiB` suffix.
Unknown members of `workspace` and `workspace.pull` are rejected.

## `updates` section

Background update-check behavior for `iso update`. The fork channel targets
`chr33s/iso` releases from `swift`. Development builds suppress these checks
and refuse self-update.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | `"notify"` or `"off"` | `"notify"` | `"notify"` runs a background check at most once per `check_interval_hours` and prints a one-line stderr notice when a newer release is known. `"off"` disables both the check and the notice. |
| `check_interval_hours` | integer | `24` | Minimum hours between background release-metadata fetches. |

The background check is also silent when `ISO_NO_UPDATE_CHECK=1`, when `CI=true`, or when stdin is not a TTY. Dev builds (untagged or dirty trees) never run the check or notice.

```jsonc
{
  "updates": { "mode": "off" }
}
```

## CLI overrides

Several config values accept per-invocation overrides via flags:

| Flag | Applies to | Overrides |
|------|-----------|-----------|
| `--vcpus <N>` | `setup`, `up` | `vm.vcpu_count` |
| `--mem <MiB>` | `setup`, `up` | `vm.mem_size_mib` |
| `--template-size <GiB>` | `setup` | `vm.template_size_gib` |
| `--disk <GiB>` | `up` | Per-instance disk size (grows from template if larger) |
| `--env KEY=VALUE` | `up`, `start` | Adds or overrides a `guest_env` entry (repeatable); `{vault:NAME}` values are stored-secret references |
| `--env-file <path>` | `up`, `start` | Adds or overrides `guest_env` entries from a `.env` file; `--env` wins over it |
| `--config <path>` | all commands | Config file path, `.jsonc` or `.json` (default: `~/.iso/config.jsonc`) |

## Examples

### Minimal config

An empty object, `{}`, gives you all defaults (2 vCPUs, 4 GiB RAM, 8 GiB disk).

### Full config

```jsonc
{
  "data_dir": "~/.iso",
  "ssh_port": 22,
  "github": "auto",  // must be set explicitly; default is off
  "vm": {
    "vcpu_count": 4,
    "mem_size_mib": 8192,
    "template_size_gib": 20
  },
  "guest_env": { "RUST_LOG": "info" },
  "claude": {
    "config_dir": "~/.claude",
    "env_forward": ["CUSTOM_TOKEN"],
    "marketplaces": [
      "https://github.com/anthropics/claude-plugins-official",
      "/Users/me/local-marketplace"
    ],
    "plugins": ["rust-analyzer-lsp@claude-plugins-official"],
    "mcp_servers": {
      "my-server": {
        "command": "/usr/bin/my-mcp-server",
        "args": ["--verbose"],
        "env": { "API_KEY": "MY_API_KEY" }
      }
    }
  },
  "codex": {
    "auth": "api_key",
    "config_dir": "~/.codex",
    "env_forward": ["CUSTOM_TOKEN"],
    "mcp_servers": {
      "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"] }
    }
  },
  "profiles": {
    "my-tools": {
      "apt_packages": ["ripgrep", "fd-find"],
      "post_install": "npm install -g @ast-grep/cli"
    }
  },
  "forward_ports": [3000, "8080:18080"]
}
```

Data-root ownership and purge rules are documented in
[backend state](backends.md#state). Explicit `data_dir` values are preserved.
