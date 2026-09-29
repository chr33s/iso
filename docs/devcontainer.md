# Reading `devcontainer.json`

isolate reads a **subset** of [devcontainer.json](https://containers.dev/) and maps recognised keys to its own primitives. This is not full devcontainer support — isolate builds its own rootfs and does not run Dockerfiles or compose files. The supported subset is listed below; everything else is reported as `unsupported` and skipped.

## How discovery and apply work

When you run `iso up <dir>`, `iso up --git-repo <url>`, or `iso setup --workspace <dir>`, isolate looks for `.devcontainer/devcontainer.json` in that workspace source (and in each mount host root, with the project directory winning ties). For `--git-repo` creation flows, isolate can discover `.devcontainer/devcontainer.json` from common GitHub repository URLs before creating the VM. `iso start --dry-run --workspace <dir>` also uses discovery as a translation preview; normal `iso start` only restarts stopped instances and does not create a VM or re-apply devcontainer changes.

If a file is found, isolate prompts:

```
Use devcontainer.json at <path>? [Y/n]
```

After your reply (or non-interactive escape hatches, below), isolate prints a per-key report showing exactly which devcontainer.json keys took effect, which were overridden by CLI flags, and which are unsupported.

When a local `devcontainer.json` is applied while creating a VM, isolate records the file path and SHA-256 content hash in the instance state. Later `iso up` reconnects and `iso start` restarts compare the current file at that path with the recorded hash. If it changed or disappeared, isolate prints an informational warning and leaves the existing VM unchanged. Destroy and recreate the VM to apply creation-time changes such as `features`, `hostRequirements`, `mounts`, `image`/`build`, or `remoteUser`. Start-time values from the old file, including `containerEnv`, `forwardPorts`, and `postStartCommand`, are not re-applied automatically on restart.

## Non-interactive escape hatches

For CI or scripted use, pass one of:

- `--devcontainer <path>` — use this specific file, skip the prompt
- `--no-devcontainer` — ignore any discovered file for this invocation
- `--dry-run` — print the report and exit before any VM work
- `iso devcontainer check <path>` — print setup/start translation reports for a file without loading isolate config or touching VM state

A non-TTY invocation that discovers a `devcontainer.json` without any of these flags errors out rather than silently choosing. For `iso up --git-repo <url>`, remote discovery is best-effort and currently limited to GitHub URLs that resolve to `owner/repo`; unsupported hosts continue without devcontainer translation unless you pass an explicit local `--devcontainer <path>`. `--git-repo` lives on `iso up`, not `iso start`.

## Persistent project opt-outs

If a project has a `devcontainer.json` that you do not want isolate to read, record an explicit opt-out:

```
iso devcontainer ignore <project-dir>
```

Future discovery for that project skips the file and prints a message explaining that the stored opt-out was used. `--devcontainer <path>` still applies an explicit file for a single run, and `--no-devcontainer` remains a non-persistent escape hatch.

Inspect and clear stored opt-outs with:

```
iso devcontainer status [project-dir]
iso devcontainer clear <project-dir>
```

`status` lists the stored absolute project path. If the original directory was moved or deleted, pass that listed path to `clear`.

## Precedence

CLI flags > `devcontainer.json` > defaults. The reporting table marks overrides explicitly so you can see when one of your CLI flags suppressed a devcontainer value.

## Supported keys

| devcontainer.json | isolate equivalent | Notes |
|---|---|---|
| `postStartCommand` | `post_start` | String or `[string,...]`; arrays are joined with ` && ` |
| `containerEnv` | `guest_env` (`--env KEY=VALUE`) | CLI `--env` wins on conflict |
| `forwardPorts` | `--forward-port` | Items may be integers or `"GUEST[:HOST]"` strings |
| `features` (`rust`, `node`, `python`, `go`, `c`, `fuzz`) | built-in `--profile` | Only at `iso setup`; ignored during VM start/restart |
| `features` (`ghcr.io/devcontainers/features/*`) | OCI Feature `install.sh` baked into the image | Public GHCR devcontainer Features only; report includes the resolved digest and script hash |
| `features` (anything else) | warn and skip | No silent fallback to a custom profile or unsupported registry |
| `hostRequirements.cpus` | `--vcpus` | |
| `hostRequirements.memory` | `--mem` | Accepts `4GB`/`4GiB`-style values |
| `hostRequirements.storage` | `--disk` | Start-time only; accepts `16GB`/`16GiB`-style values |
| `mounts` | `--mount` | Docker `type=bind,source=...,target=...` strings and objects supported; non-bind types are rejected |
| `remoteUser` | `--guest-user` at setup time | Baked into the image at setup; start reports a mismatch and skips `containerEnv` if the image uses a different guest user |
| `image`, `build`, `dockerComposeFile`, `customizations`, `name` | warn and skip | isolate manages its own rootfs |

## JSON with comments

`devcontainer.json` officially allows `//` and `/* */` comments and trailing commas. isolate parses these correctly.

## OCI Feature installs

For public `ghcr.io/devcontainers/features/<name>[:tag|@digest]` entries that do not map to a built-in profile, `iso setup --workspace ... --devcontainer ...` fetches the Feature manifest and layer from GHCR, verifies each against its content digest, validates that the layer contains `devcontainer-feature.json` and `install.sh`, and bakes the Feature payload into the image setup recipe. Features run in deterministic `features` key order after profile post-install scripts and guest-user setup, before isolate's agent setup.

Feature option values must be strings, numbers, booleans, or `null`. They are exposed to the Feature script as uppercased environment variables, along with `_REMOTE_USER` and `_REMOTE_USER_HOME`.

Treat Feature install scripts as untrusted project-provided code. isolate reads `install.sh` as a bounded regular file without following symlinks. The report prints the resolved digest and `install.sh` SHA-256 before setup continues; use `--dry-run` or `iso devcontainer check <path> --stage setup` to inspect this without building an image.

## Out of scope in v1

- OCI feature registries other than public `ghcr.io/devcontainers/features/*`
- `--git-repo` auto-detection for non-GitHub hosts
- Live re-application on an existing VM (destroy + `iso up` to pick up changes)
