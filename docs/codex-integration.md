# Codex Integration

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

isolate installs Codex into every guest image and gives you a dedicated `iso codex` launcher. This guide covers the `iso codex` command, the configuration that controls what gets injected into the guest, and the bootstrap sequence that runs when a VM starts.

## Launching Codex

```bash
iso codex [instance-name] [-- extra-args...]
```

This SSHes into the guest and runs the `codex` CLI. By default isolate passes `--dangerously-bypass-approvals-and-sandbox`, so Codex runs without its sandbox or approval prompts — parity with how `iso claude` runs unrestricted. The VM is the isolation boundary, so Codex's own sandbox is redundant; it also does not work in the guest, which lacks a functioning bubblewrap, so leaving it enabled makes every shell command Codex runs fail.

When `"codex": { "auth": "chatgpt" }` is set, `iso codex` launches a small
guest wrapper (`/usr/local/bin/codex-account`) that starts a D-Bus session,
unlocks GNOME Keyring, and then runs the real Codex binary. In keyring mode
each launch gets a fresh private D-Bus session, so the wrapper asks for the
guest keyring password every time before Codex starts.

The wrapper also supplies `-c 'cli_auth_credentials_store="keyring"'`.
In Codex 0.153.0 and 0.154.0, this override prevents implicit reuse of a desktop
app-server whose D-Bus session may have an unusable keyring. Terminal sign-in
then uses the session unlocked by the wrapper, including through `codex-yolo`.
Caller arguments follow this default and retain their precedence; explicitly
selecting a remote app-server still selects that server and its auth session.
API-key mode remains a passthrough. This daemon-selection behavior is
version-dependent and should be rechecked when updating Codex.

The in-guest `codex-yolo` shortcut routes through the same wrapper, so it works
in either auth mode. Running the bare `codex` binary from `iso shell` does
not: it has no D-Bus session, and `keyring` credential storage has no
`auth.json` fallback, so Codex will not find its credentials. Inside the guest,
run `codex-account` (or `codex-yolo`) instead of `codex`. The wrapper is a
transparent passthrough unless the guest `~/.codex/config.toml` asks for
keyring storage, so it is safe to use in either mode. It gates on the guest
file rather than on isolate's `auth` setting, which is what keeps `codex-yolo`
working from inside the guest; isolate keeps that file in step when you switch
modes, rewriting it on the next `iso start` to drop the keyring setting.

To keep Codex's sandbox and approval prompts for a single session, pass `--ask`. isolate then launches `codex` with no bypass flag, so Codex applies its normal defaults:

```bash
iso codex --ask
```

Use `--ask` too if you want to supply your own sandbox or approval flags (`--sandbox`, `-a`) as trailing arguments — otherwise isolate's bypass flag takes precedence.

Trailing arguments go straight through to the `codex` CLI:

```bash
iso codex -- --model gpt-5
```

## Configuration

Codex-related settings live under the `codex` object in `~/.iso/config.jsonc`, except `github` which is a top-level field:

```jsonc
{
  "github": "auto",
  "codex": {
    "auth": "api_key",
    "api_key": "cmd:security find-generic-password -s openai -w",
    "env_forward": ["MYORG_KEY"],
    "config_dir": "~/.codex",
    "mcp_servers": {
      "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"] }
    }
  }
}
```

Every field is optional. An empty `codex` object (or omitting it entirely) keeps the historical API-key mode and skips all Codex-specific bootstrap steps unless host config, MCP servers, plugins, or local-model routing need to be applied.

### API key forwarding

The default auth mode is `"auth": "api_key"`. In this mode, isolate forwards
`OPENAI_API_KEY` to the guest via SSH `SendEnv` on every session: `iso codex`,
`iso shell`, and `iso exec` alike. The key is never written to disk inside
the guest.

Resolution order:

1. `codex.api_key` in the configuration (a literal or a `cmd:` reference run on the host)
2. `OPENAI_API_KEY` environment variable on the host

If neither is set, the guest starts without an API key. You can authenticate interactively the first time you run `codex` inside the VM.

### ChatGPT account auth

Set `"auth": "chatgpt"` to use a ChatGPT account or ChatGPT Business workspace
with Codex instead of an OpenAI API key:

```jsonc
{ "codex": { "auth": "chatgpt" } }
```

This mode follows Codex's ChatGPT sign-in path, so usage is tied to the
selected ChatGPT workspace rather than standard API billing. isolate writes
`cli_auth_credentials_store = "keyring"` into the guest `~/.codex/config.toml`
so Codex uses Linux Secret Service storage, and it launches Codex through
`/usr/local/bin/codex-account` so a headless guest has a D-Bus session and an
unlocked GNOME Keyring. See OpenAI's
[authentication documentation](https://learn.chatgpt.com/docs/auth#credential-storage)
for the Codex credential-store setting and device-code login flow.

The first login should use device-code auth from inside the guest:

```bash
iso codex -- login --device-auth
```

Then open the shown URL in your browser, sign in to the intended ChatGPT
workspace, and enter the one-time code. Later `iso codex` launches reuse the
cached account credentials from the guest keyring. (`iso codex` launches
`login` and `logout` without the sandbox-bypass flag — they never start an
agent session, so there is nothing to sandbox — and no `--ask` is needed.)

#### The guest keyring password

A fresh VM has no keyring, so the first prompt is *choosing* a password, not
entering one. The wrapper says so and asks for confirmation. That password
encrypts the Codex account credentials at rest inside the guest and is
requested again on later launches; it is unrelated to your ChatGPT or host
credentials. Because it is per-guest, `iso destroy` discards it along with the
cached login.

The prompt needs a terminal. `iso codex` provides one. Anything that runs
the wrapper without one — invoking `codex-account` yourself through
`iso exec`, or a `post_start` script — fails with a clear message rather than
hanging.

Security and billing guardrails in this mode:

- `OPENAI_API_KEY` is not forwarded, even if it is configured, present in the
  host environment, listed in `env_forward`, or persisted from `iso start
  --env`.
- `auth.json` from the host Codex config directory is not copied into the
  guest. Account tokens are stored in the guest OS credential store instead.
- `CODEX_HOME` cannot redirect Codex around keyring storage in this mode. When
  isolate's managed config selects the keyring, the guest wrapper refuses any
  explicitly set `CODEX_HOME`, preventing Codex from writing account
  credentials to an unmanaged `auth.json`; unset `CODEX_HOME` when using
  ChatGPT account auth.
- `proxy.openai` is rejected with `"auth": "chatgpt"`, because the proxy path
  uses an OpenAI API key and would switch Codex back to API billing.

Because isolate must keep `cli_auth_credentials_store` in the guest
`~/.codex/config.toml`, this mode rewrites that file on every start. Codex's
own state in it — installed marketplaces and plugins, and the
`[projects.*]` workspace-trust records — is read back and preserved across the
rewrite, so you are not re-approving workspace trust after each restart.

Images built before this support existed need a rebuild:

```bash
iso setup --rebuild
```

A rebuild only changes the golden image. An existing VM keeps its own guest
disk across `iso stop` / `iso start`, so it will not pick up the new guest
packages. Swap the rebuilt image in without losing the instance:

```bash
iso restore my-project --image default --reprovision
```

[`--reprovision`](commands.md#--reprovision) keeps the instance's name, index,
IP, and workspace association, accepts a running instance, and leaves it
running. It provisions the replaced disk as a first boot, so `/workspace` is
restored and the agent plugins are reinstalled — a plain `restore` here would
leave both empty, because the base image carries neither. Both reprovisioning
and destroying/recreating replace the guest disk. Save
guest-only work first (for example with `iso pull`); the replacement also
discards any guest keyring and cached account login.

### GitHub auth

The `github` field controls how isolate obtains a `GITHUB_TOKEN` for the guest. This token enables private repo cloning and `gh` CLI usage inside the VM.

| Value    | Behavior |
|----------|----------|
| `"auto"` | Check the `GITHUB_TOKEN` env var first. If unset, run `gh auth token` on the host to extract a token from the GitHub CLI. |
| `"env"`  | Require `GITHUB_TOKEN` in the host environment. Warns if missing. |
| `"off"`  | Skip GitHub token forwarding entirely. This is the default when `github` is unset. |

When a token is available, isolate runs `gh auth setup-git` in the guest during bootstrap.

### Config directory

`config_dir` specifies a host directory from which isolate copies an allowlist of entries (`AGENTS.md`, `prompts/`, `config.toml`, `auth.json`) into `~/.codex/` in the guest. This provides Codex's global instructions, prompt files, baseline user configuration, and local Codex authentication state.

When `auth` is `"chatgpt"` or `proxy.openai` is active, `auth.json` is excluded
from the copy. In ChatGPT account mode, isolate stores cached account credentials
through the guest keyring instead.

```jsonc
{ "codex": { "config_dir": "~/.codex" } }
```

The default is `~/.codex`. Set to `false` to disable config file copying entirely.

### Environment variable forwarding

`env_forward` lists additional environment variable names to forward from the host to the guest via SSH `SendEnv`. These are forwarded on every SSH session, not just during bootstrap.

`OPENAI_API_KEY` and `GITHUB_TOKEN` are handled through their own mechanisms and do not need to appear here.

### MCP server registration

`mcp_servers` maps server names to their definitions. isolate merges these definitions into the guest `~/.codex/config.toml` under `mcp_servers`.

Definitions use the same schema as Claude integration:

```jsonc
{
  "codex": {
    "mcp_servers": {
      "my-tool": { "command": "npx", "args": ["-y", "@example/mcp-server"] },
      "sentry": { "type": "http", "url": "https://mcp.sentry.dev/mcp" }
    }
  }
}
```

**NOTE**: MCP server commands must be installed in the guest. For example, to make `npx` available when creating a new instance, use `iso up --profile node`. If your image already includes the required tools, no additional profile flag is needed. Profiles do not add tools to an existing instance; see [Images and Profiles](images-and-profiles.md) for image setup options.

If `config_dir` also provides a `config.toml`, isolate preserves its other settings but replaces the `mcp_servers` table with the one derived from `codex.mcp_servers`. When the VM is in [local-model mode](#local-model-support), isolate also owns the `model` and `model_provider` keys and a `[model_providers.iso_local]` block; these are written on a switch to local and removed on a switch back to remote, so they are not preserved across a mode change.

### Plugin marketplaces

`marketplaces` and `plugins` declare Codex [plugin marketplaces](https://learn.chatgpt.com/docs/plugins) and the plugins to install from them, mirroring the same fields under `claude`:

```jsonc
{
  "codex": {
    "marketplaces": ["trailofbits/codex-plugins"], // owner/repo, owner/repo@ref, git URL, or local path
    "plugins": ["my-lsp@codex-plugins"]            // plugin@marketplace
  }
}
```

Each marketplace source is registered with `codex plugin marketplace add` and each plugin installed with `codex plugin add`. A source that is an absolute local directory is copied into the guest first; a `owner/repo`, `owner/repo@ref`, or git URL is passed through unchanged.

The Apple backend does not bake them into the golden image; the full set installs on a VM's first boot. Like Claude plugins, they are installed on **first boot only** — they persist on the guest disk across stop/start.

Codex stores marketplace registrations under `[marketplaces.*]` and per-plugin enabled/disabled state under `[plugins.*]` in `~/.codex/config.toml`. Because isolate rewrites that file on every boot, it reads the guest's current tables back first and preserves them across the rewrite (dropping any that came from the host's own `config.toml`), so installed plugins — and any manual enable/disable toggles you make with `/plugins` — survive a restart.

## Bootstrap sequence

When `iso up` creates/restarts a project VM or `iso start` restarts a stopped VM (without `--no-agents`), isolate executes the following steps after the VM boots and SSH becomes available:

1. **GitHub auth**: If a `GITHUB_TOKEN` is available, run `gh auth setup-git` in the guest.
2. **User content**: Copy the allowlisted Codex entries (`AGENTS.md`,
   `prompts/`, `config.toml`, `auth.json`) from `config_dir` to `~/.codex/` in
   the guest, preserving the guest's installed `[marketplaces.*]`/`[plugins.*]`
   tables. `auth.json` is omitted when ChatGPT account auth or proxy mode is
   active.
3. **Auth storage**: In ChatGPT account mode, write
   `cli_auth_credentials_store = "keyring"` into `~/.codex/config.toml`.
4. **MCP servers**: Merge configured MCP server definitions into `~/.codex/config.toml`.
5. **Marketplaces & plugins** (first boot only): Install the configured `marketplaces`/`plugins` not already baked into the golden image.

On restart (`iso start` of a stopped instance), the same Codex config files are refreshed so host-side updates are reflected in the guest; marketplaces and plugins are not reinstalled, but the guest's installed plugin state is preserved.

### Skipping bootstrap

To create or restart a VM without any Claude Code or Codex configuration:

```bash
iso up . --no-agents
iso start --no-agents
```

This skips the guest bootstrap sequence entirely. The VM still includes both CLIs because they are baked into the image during `iso setup`.

## Updating Codex

`iso setup` uses [OpenAI's native installer](https://developers.openai.com/codex/cli/)
to install the full Codex package, including bundled tools, as the configured
guest user. The installer manages its package under the user's home directory
and exposes `~/.local/bin/codex`. isolate retains `/usr/local/bin/codex` as a
compatibility link for existing wrappers and scripts.

To update directly inside the VM, run `codex update` as the guest user; sudo
is not required. To update from the host:

```bash
iso agent update --codex          # update Codex to the latest release
iso agent update --check          # report installed vs. latest, change nothing
```

`iso agent update --codex` re-runs the native installer as the guest user and
refreshes the compatibility link. It also migrates older direct-binary
installations without rebuilding the VM or replacing the user's Codex config.
A profile-provided `/usr/local/bin/codex` is preserved during image setup;
an explicit update replaces it with the native installation.

Updates affect that VM. To refresh the golden image for new VMs, run
`iso setup --rebuild`. See [`agent update`](commands.md#agent-update).

## Local model support

A VM can route Codex at a host-side local model server (Ollama / LM Studio /
vLLM / llama.cpp) instead of OpenAI's cloud. The endpoint must serve the
Responses API — the only wire API Codex currently supports. Switch a VM with
[`iso model <vm> local`](commands.md#model) and back with
`iso model <vm> remote`; configure the endpoint under
[`codex.local_model`](configuration.md#local-model-routing) or interactively
at the `iso model … local` prompt.

The selection is per VM and independent of Claude — Codex can run on a local
model while Claude stays on cloud, or the reverse. The endpoint Codex resolves
is the `codex.local_model` config object if present, otherwise an endpoint
saved interactively for the instance, otherwise none (it stays on cloud).
Config takes precedence over the saved endpoint.

In local mode isolate injects three iso-owned keys into `~/.codex/config.toml`:
`model` (the configured model), `model_provider` (`iso_local`), and a
`[model_providers.iso_local]` block pointing `base_url` at the guest-visible
endpoint with `wire_api = "responses"`. The provider reads its API key from the
`ISO_LOCAL_API_KEY` env var, which isolate forwards with the configured (or dummy)
token. These keys are iso-owned: they are written on a switch to local and
removed on a switch back to remote, so they are not preserved across a mode
change.

Switching takes effect without a VM restart: isolate rewrites `config.toml` live
over SSH on a running VM (or saves the selection to apply on the next start). A
running `codex` reads its config at launch, so relaunch it (`iso codex <vm>`)
to pick up the change.
