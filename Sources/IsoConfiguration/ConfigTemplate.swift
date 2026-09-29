/// The JSONC template `iso setup --config-only` writes. Must equal
/// `config.example.jsonc` at the repository root (enforced by a test).
public enum ConfigTemplate {
  public static let jsonc = #"""
    // iso configuration (JSONC: JSON plus // and /* */ comments).
    // `iso setup --config-only` writes this template to ~/.iso/config.jsonc.
    // Uncomment members to override defaults; an empty object gives the defaults.
    // Trailing commas are not accepted. Run `iso validate` to check the file.
    {
      // "data_dir": "~/.iso",        // VM artifacts: images, instances, keys
      // "ssh_port": 22,               // Guest SSH port

      // GitHub auth strategy: a string ("auto", "env", "off", "pat") or an object
      // with per-repo PAT entries. `iso github setup-pat --repo owner/name`
      // populates it; `iso github assign-pat --vm NAME --repo owner/name` selects
      // an entry for one VM.
      // "github": "auto",
      // "github": {
      //   "mode": "pat",
      //   "skip": ["owner/big-repo"],   // repos to skip the auto-prompt for
      //   "pat": {
      //     "owner/repo": {
      //       "token": "cmd:security find-generic-password -s coop-github-pat -a owner-repo -w"
      //     }
      //   }
      // },

      // "setup": { "prompt_for_pat": true },   // auto-prompt for a PAT at `iso start`

      // "vm": {
      //   "vcpu_count": 2,            // vCPUs per VM (override: --vcpus)
      //   "mem_size_mib": 4096,       // memory in MiB, at least 128 (override: --mem)
      //   "template_size_gib": 8      // template disk in GiB (override: --template-size)
      // },

      // Literal environment variables for the guest. They override forwarded
      // values with the same name. Do not put secrets here; use env_forward.
      // "guest_env": { "RUST_LOG": "info" },

      // "claude": {
      //   // Copies CLAUDE.md, keybindings.json, rules/, commands/, skills/,
      //   // agents/, output-styles/, themes/ and workflows/ from this directory;
      //   // false stops copying.
      //   "config_dir": "~/.claude",
      //   "env_forward": ["CUSTOM_TOKEN"],
      //   "marketplaces": ["https://github.com/anthropics/claude-plugins-official"],
      //   "plugins": ["rust-analyzer-lsp@claude-plugins-official"],
      //   // Secret-bearing values accept "cmd:<command>": the command runs on the
      //   // host via `sh -c` when needed and its trimmed stdout is used.
      //   "api_key": "cmd:security find-generic-password -s anthropic -w",
      //   "mcp_servers": {
      //     "my-server": {
      //       "command": "/usr/bin/my-mcp-server",
      //       "args": ["--verbose"],
      //       "env": { "API_KEY": "MY_HOST_ENV_VAR" }
      //     }
      //   },
      //   // Route Claude Code at a host-side model; enable per VM with
      //   // `iso model <vm> local`. A localhost host is rewritten to the
      //   // guest's view of the host.
      //   "local_model": {
      //     "host_url": "http://localhost:11434",
      //     "model": "qwen2.5-coder:32b"
      //   }
      // },

      // "codex": {
      //   "auth": "api_key",          // or "chatgpt" for account/workspace auth
      //   "config_dir": "~/.codex",
      //   "env_forward": ["CUSTOM_TOKEN"],
      //   "marketplaces": ["trailofbits/codex-plugins"],
      //   "plugins": ["my-lsp@codex-plugins"],
      //   "local_model": {
      //     "host_url": "http://localhost:11434/v1/",
      //     "model": "gpt-oss:120b"
      //   }
      // },

      // Host-side credential-injecting proxy. `iso proxy setup [--openai]`
      // stores the credential in the macOS Keychain and writes the `cmd:`
      // reference here. Credentials must be `cmd:` or `vault:NAME` (iso secrets)
      // references; literal values are rejected. Cannot be combined with codex auth "chatgpt".
      // "proxy": {
      //   "mode": "auto",             // "required": never forward a raw provider key;
      //                               // "off": start no proxy
      //   "anthropic": {
      //     "credential": "cmd:security find-generic-password -s coop-anthropic -a anthropic -w",
      //     "auth": "api_key"         // "api_key" (x-api-key) or "bearer" (setup-token)
      //   },
      //   "openai": {
      //     "credential": "cmd:security find-generic-password -s coop-openai -a openai -w",
      //     "auth": "bearer"
      //   }
      // },

      // "profiles": {
      //   "my-tools": {
      //     "apt_packages": ["ripgrep", "fd-find", "jq"],
      //     "pre_install": "curl -fsSL https://example.com/setup.sh | bash",
      //     "post_install": "echo done"
      //   }
      // },

      // "post_start": "make dev-setup",          // runs in the guest after each boot
      // "forward_ports": [3000, "8080:18080", { "guest": 5432, "label": "db" }],

      // Defaults for egress, proxy.mode and workspace.pull.mode: "networked",
      // "provider-only" or "offline". Explicit fields still win.
      // "security": { "preset": "provider-only" },

      // Host-enforced session length per boot ("30m", "8h", or seconds).
      // "limits": { "session_ttl": "8h" },

      // "open" (default) or "none": no route beyond the host, fixed per instance
      // at creation. Guest→host SSH tunnels still work. See docs/configuration.md.
      // "egress": "open",

      // `iso pull` return path. "stage" pulls into a host-side stage for review;
      // nothing reaches the local directory until `iso pull --apply`.
      // "workspace": {
      //   "pull": {
      //     "mode": "direct",           // or "stage"
      //     "max_files": 50000,
      //     "max_bytes": "1GiB",
      //     "max_file_bytes": "256MiB"
      //   }
      // },

      // "updates": {
      //   "mode": "notify",           // "off" or "notify"
      //   "check_interval_hours": 24
      // },

      // Apple sandbox backend. Unknown members are rejected.
      // "apple_container": {
      //   "binary": "/absolute/path/to/iso-sandbox",
      //   "builder": "/absolute/path/to/container",
      //   "kernel": "/absolute/path/to/vmlinux",
      //   "probe_timeout_seconds": 10,
      //   "operation_timeout_seconds": 60,
      //   "create_timeout_seconds": 600,
      //   "boot_timeout_seconds": 120,
      //   "stop_timeout_seconds": 90,
      //   "build_timeout_seconds": 3600
      // }
    }

    """#
}
