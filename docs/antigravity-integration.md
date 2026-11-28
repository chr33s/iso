# Antigravity Integration

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

isolate installs Google's Antigravity CLI (`agy`) into every guest image and
gives you an `iso antigravity` launcher (`iso agy` is the same). This guide
covers the launcher, the configuration that controls what reaches the guest,
and what bootstrap writes when a VM starts.

## Launching Antigravity

```bash
iso antigravity [instance-name] [-- extra-args...]
```

This SSHes into the guest and runs `/usr/local/bin/agy`. By default isolate
passes `--dangerously-skip-permissions`, so `agy` approves tool calls without
prompting, which matches `iso claude` and `iso codex`. The VM is the isolation
boundary. `agy` still blocks commands on its own system denylist in this mode.

To keep Antigravity's permission prompts for one session, pass `--ask`:

```bash
iso antigravity --ask
```

Trailing arguments go straight to `agy`:

```bash
iso antigravity -- --model gemini-4-neon-high
iso antigravity -- -p "summarize the README" --output-format json
```

isolate does not add the bypass flag to the `agy` subcommands `mcp`, `plugin`,
`update`, `install` and `acp`, or when you pass the flag yourself.

`iso run antigravity` launches the same built-in definition through the
project-environment flow (`--rm`, `--ask`, `--dry-run`). `iso host agent HOST
NAME antigravity` runs it on a remote VM; see [remote hosts](remote-hosts.md).

## Authentication

Antigravity reads a Gemini API key only from `GEMINI_API_KEY` in its process
environment, and only when `~/.gemini/antigravity-cli/settings.json` sets
`"modelProvider": "gemini"`. `GOOGLE_API_KEY` and `.env` files have no effect.
isolate manages that one settings key:

- When the configuration sends a key (the Google proxy, or a raw
  `GEMINI_API_KEY` from `antigravity.api_key`, `env_forward`, `guest_env` or
  `--env` that is not withheld), bootstrap sets `"modelProvider": "gemini"`.
  The decision comes from the configuration, not the shell that started the
  VM, so every session agrees with it.
- Otherwise it removes `modelProvider` if it is `"gemini"`. `agy` refuses to
  start when the provider is set and the key is missing.

Other settings in the file are preserved. If the file is not plain JSON (for
example JSONC), bootstrap warns and leaves it unchanged.

### Credential proxy (recommended)

```bash
iso proxy setup --google      # paste a Google AI Studio key
```

This stores the key in the macOS Keychain (`iso-google`) and writes
`proxy.google` to the configuration. For a remote-model VM, isolate starts a
confined `iso-proxy` for `generativelanguage.googleapis.com` and forwards
`127.0.0.1:<11788 + instance index>` into the guest. Antigravity sessions get:

- `GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:<port>`
- `GEMINI_API_KEY=<capability>`: a per-proxy token that only opens this proxy.

The proxy checks the capability, removes it, and injects the real key as
`x-goog-api-key`. It forwards only these operations:

- `POST /v1beta/models/{model}:generateContent`
- `POST /v1beta/models/{model}:streamGenerateContent`
- `POST /v1beta/models/{model}:countTokens`
- `GET /v1beta/models` (the model list `agy` loads)

`{model}` must be a plain id (lowercase letters, digits, `.`, `-`, `_`). Every
other request is refused. With the proxy configured, or under
`proxy.mode = "required"` or `egress = "none"`, a raw `GEMINI_API_KEY` from
`antigravity.api_key`, `env_forward`, `guest_env` or `--env` is withheld
from the guest. See
[credential-proxy.md](credential-proxy.md).

### Direct key

Under `proxy.mode = "auto"` with no `proxy.google`, `antigravity.api_key` is
forwarded into the guest in plain text, with a warning. Unlike Claude and
Codex, a `GEMINI_API_KEY` in the host environment is never forwarded on its
own; name it in `env_forward` (or set `api_key`) to send it.

### Google account sign-in

With no key, `agy` falls back to its own sign-in, which keeps tokens in the
guest's keyring. isolate does not manage that path. A remote-host Antigravity
requires the proxy and refuses to start without it.

## Configuration

```jsonc
"antigravity": {
  "api_key": "cmd:security find-generic-password -s gemini -w",
  "env_forward": ["CUSTOM_TOKEN"],
  "mcp_servers": {
    "fs": { "command": "/usr/bin/my-mcp-server", "args": ["--root", "/workspace"] },
    "docs": { "type": "http", "url": "https://mcp.example.com/mcp",
              "headers": { "Authorization": "cmd:printf 'Bearer …'" } }
  }
}
```

Only `api_key`, `env_forward` and `mcp_servers` are accepted. Unlike `claude`
and `codex`, other keys are errors. Antigravity has no `config_dir`,
`marketplaces`, `plugins` or `local_model` support in isolate.

MCP servers are stdio or streamable HTTP. `"type": "sse"` is refused because
`agy` does not support the legacy HTTP+SSE transport. A stdio `env` map is
also refused, because `agy` takes literal values rather than host variable
names. Forward the variable with `env_forward` instead. Bootstrap writes these
servers into `~/.gemini/config/mcp_config.json` on every start, deletes servers
it wrote earlier that are no longer configured (it records their names on the
host), and keeps servers it did not write. Header values are resolved on the host and sent
over SSH stdin, so they never appear on the ssh command line. They are
guest-visible by design. A remote-host VM does not receive header-bearing
servers.

## Install and updates

The image build runs Google's installer
(`https://antigravity.google/cli/install.sh`) as the guest user. The installer
checks the download's SHA-512 against its release manifest and installs
`~/.local/bin/agy`. isolate links it to `/usr/local/bin/agy`. macOS guests use
the same installer. Image preparation needs `antigravity.google`, the
installer's release host and `storage.googleapis.com`.

`agy` updates itself in the background. `iso agent update --antigravity` runs
`agy update` as the guest user, and `iso agent update` with no flag updates
every agent.

Images built before Antigravity support have no `agy`. Bootstrap skips the
agent there, and fails only when `proxy.google` or `antigravity.mcp_servers`
needs it. Run `iso setup --rebuild` to pick it up.
