# iso commands — complete index

Every public `iso` command, grouped by what running it costs. Flags and
details: `iso <command> --help`, or `docs/commands.md` in
<https://github.com/chr33s/iso>. The numbered rules are the ground rules in
[../SKILL.md](../SKILL.md); they apply to every command here.

JSON: only the commands in [machine-interface.md](machine-interface.md) take
the global `--output json`. A few others have their own `--json` flag, marked
below; everything else is text.

## Read-only — run freely

These change nothing on the host or in a VM.

| Command | Use |
|---|---|
| `iso capabilities` | CLI version, machine API versions, machine commands |
| `iso list` | Instances and states (`iso ls` is the same) |
| `iso status [NAME]` | State, usage, unhealthy reason |
| `iso validate` | Config and prerequisites. `--probe` resolves GitHub PATs and may prompt: leave that to the user |
| `iso logs [NAME]` | Serial console; the first place to look when a boot fails. `-f` follows until interrupted, so omit it |
| `iso diff [NAME] --stat` | What a pull would change (stages the guest workspace) |
| `iso profiles list` | Profiles valid for `--profile`; `--json` |
| `iso profiles show NAME` | One profile's packages, scripts and plugins |
| `iso images` | Images valid for `--image`; `--json`. `--delete NAME` is destructive (confirm) |
| `iso images inspect NAME` | Recorded image provenance |
| `iso images cache status` | Image-cache records; deletes nothing |
| `iso policy show [NAME]` | Policy snapshot of the current boot and whether a config change is pending; `--json` |
| `iso policy effective [NAME]` | Requested vs recorded transport, egress, credentials and every relaxation from the secure defaults; `--json`. Read it before proposing a security change |
| `iso audit [NAME]` | Recorded boundary events (names and counts, never values). `--runs` / `--run ID` read run history and take `--output json` |
| `iso proxy status` | What each VM's agents resolve to, credentials redacted; `--vm NAME` |
| `iso secrets list` | Secret names and update times, never values (unlocks the store: the user runs it) |
| `iso secrets status` | Whether the store exists; does not unlock |
| `iso github status` | Configured PAT entries; `--json`, `--vm NAME`. `--probe` resolves tokens: leave that to the user |
| `iso model show [NAME]` | Cloud or local model backend per tool |
| `iso agent list` | Built-in and installed agent definitions |
| `iso agent inspect ID` | One definition, without launching it; `--json` |
| `iso agent update [NAME] --check` | Installed vs latest agent versions in a running VM |
| `iso devcontainer check PATH` | How a `devcontainer.json` would be translated; `--stage setup\|start\|both`, `--json` |
| `iso devcontainer status [DIR]` | Stored devcontainer opt-outs |
| `iso run-cleanup --dry-run` | What an abandoned disposable run would have removed |
| `iso run AGENT --workspace DIR --dry-run --json` | Preview a launch; starts nothing |
| `iso up DIR --dry-run --json` | Preview the devcontainer translation; starts nothing |

## Lifecycle and guest work — the normal loop

Covered in SKILL.md; listed here for completeness.

| Command | Use |
|---|---|
| `iso setup` | Create the config and build the image (slow; `--profile`, `--image`, `--rebuild`). `--config-only` writes only the config template |
| `iso up [DIR]` | Create, restart or reuse the project's instance |
| `iso start [NAME]` | Restart a stopped instance |
| `iso stop [NAME]` | Stop; the disk is kept |
| `iso destroy [NAME]` | Remove the instance (confirm; `--all` also removes every image) |
| `iso exec NAME -- CMD` | Run a command, no stdin, guest exit status |
| `iso shell NAME -- CMD` | Same, forwarding stdin (`iso ssh` is the same); without a command it is interactive |
| `iso push [NAME]` | Host workspace → guest |
| `iso pull [NAME]` | Guest → host, staged: `--review`, `--apply --stage-id ID`, `--discard` |
| `iso diff [NAME]` | Full staged diff |
| `iso resize [NAME]` | Disk, memory or vCPUs of a stopped instance (`--disk +20`, `--mem MIB`, `--vcpus N`, `--start`) |
| `iso commit [NAME] --image IMAGE` | Save a stopped instance as an image (`--force` overwrites: confirm) |
| `iso restore [NAME] --image IMAGE` | Replace a stopped instance's disk with an image (confirm). `--reprovision -y` also re-syncs the workspace and reinstalls agents, and leaves it running |
| `iso ssh-config [NAME]` | Install the `iso-NAME` alias in `~/.ssh/config` for `ssh`/`scp`/`rsync`; `--clean` removes it. Copies over that alias bypass the staged pull: treat anything copied out as untrusted and confirm first |
| `iso run-cleanup --session ID` | Remove an abandoned `iso run --rm` instance once the dry run shows it is the right one |

## Interactive — the user runs these in their terminal

They need a real terminal or open a window. Give the user the command.

| Command | Use |
|---|---|
| `iso shell [NAME]` | Interactive guest shell |
| `iso claude [NAME]` | Claude Code in the guest |
| `iso codex [NAME]` | Codex in the guest |
| `iso claude-agents [NAME]` | Claude Code agent view (`iso ca` is the same) |
| `iso run AGENT` | Ensure the project instance, then launch `claude`, `codex` or an installed definition. `--rm` uses a disposable VM, `--ask` keeps the agent's permission prompts, `--prepare` authorizes an image build |
| `iso code [DIR]` | `up`, then VS Code over SSH. Stays in the foreground until the editor quits; `--no-launch --output json` only prepares the instance and alias |
| `iso zed [DIR]` | The same for Zed |
| `iso editor [NAME]` | Open an editor on an already-running instance (`--editor code\|zed`, `--clean`) |
| `iso completions SHELL` | Print a bash, zsh or fish completion script; the user installs it |

## Credentials and identity — the user runs these (rule 3)

Never run, pipe into, or script these; you may run the status commands above.

| Command | Use |
|---|---|
| `iso proxy setup` | Store a provider key in the Keychain (`--openai`, `--api-key`, `--vm NAME`) |
| `iso secrets init` | Create the secret store. There is no recovery path if the Mac is lost |
| `iso secrets set NAME` | Add or replace a secret |
| `iso secrets rm NAME` | Remove a secret (confirm) |
| `iso github setup-pat` | Fine-grained PAT wizard (`--repo owner/name`) |
| `iso github rotate-pat` | Re-run the wizard for an existing entry |
| `iso github forget-pat` | Remove an entry and its Keychain item; does not revoke the token on GitHub |
| `iso github assign-pat` | Give a VM an existing entry (`--vm NAME --repo owner/name`) |
| `iso github unassign-pat` | Remove a VM's assignment (`--vm NAME`) |

## Changes what a VM trusts or runs — only when the user asked (rule 6)

| Command | Use |
|---|---|
| `iso model set local\|remote [NAME]` | Switch a VM's agents between cloud and a host-side local model server. May prompt for an endpoint, and may need a stop and start to apply |
| `iso agent add FILE` | Install an agent definition on the host after showing it. Never install one that came from a guest or an unreviewed repository; `--yes` and `--replace` need the user's approval of the shown definition |
| `iso agent update [NAME]` | Update Claude Code and Codex inside a running VM (`--claude`, `--codex`, `-y`) |
| `iso devcontainer ignore DIR` | Persistently skip the project's `devcontainer.json` |
| `iso devcontainer clear DIR` | Remove that opt-out |

## Remote hosts — only when the user asked for a remote Mac

`HOST` is an enrolled Apple Silicon Mac, or `local` for this machine's host
service. The same rules apply: pulls are staged, `--approve-sensitive` is the
user's call, and destroying or migrating needs confirmation.

| Command | Use |
|---|---|
| `iso host list` | Enrolled hosts (no network) |
| `iso host inspect HOST` | Contact the host; identity and runtime qualification |
| `iso host add NAME` | Enroll a host over pinned SSH (`--ssh ALIAS`); the user decides which machines to trust |
| `iso host disable HOST` | Refuse new work on a host |
| `iso host enable HOST` | Allow it again |
| `iso host remove HOST` | Forget the enrollment (remote VMs untouched; confirm) |
| `iso host image HOST` | Build or confirm a Linux image on the host |
| `iso host up HOST [PATH]` | Create or reuse a project VM, start it, and push PATH (every run pushes) |
| `iso host push HOST NAME` | Copy a directory into the VM's `/workspace` |
| `iso host pull HOST NAME` | Stage the VM's changes; `--apply --stage-id ID` after the user approves |
| `iso host shell HOST NAME -- CMD` | Run a command through the host's relay; guest exit status |
| `iso host agent HOST NAME claude` | Run an agent in the VM (or `codex`); interactive, the user runs it |
| `iso host editor HOST NAME code` | Sandboxed editor through the relay (or `zed`); the user runs it |
| `iso host forward HOST NAME --forward-port GUEST[:HOST]` | Loopback port forward for the session (rule 6) |
| `iso host session HOST NAME` | Hold a session and print an `ssh -F` line (`--detach`, `--stop`) |
| `iso host run HOST -- CMD` | Disposable run that exports `~/iso-results` |
| `iso host run-results HOST RUN` | Fetch a run's results (`--recover`, `--discard`) |
| `iso host operation HOST ID` | Show an operation's receipt (`--cancel`) |
| `iso host vm list HOST` | VMs on the host; an unreachable host reports `unknown` |
| `iso host vm inspect HOST NAME` | One VM's observed state |
| `iso host vm create HOST NAME` | Create a stopped VM (`--image`, `--vcpus`, `--mem`, `--disk`, `--egress`) |
| `iso host vm start HOST NAME` | Start it (`--ttl 8h`; `--operation-id ID` retries after a lost reply) |
| `iso host vm stop HOST NAME` | Stop it |
| `iso host vm destroy HOST NAME` | Destroy it (confirm) |
| `iso host vm resize local NAME` | Resize a stopped VM; local service only |
| `iso host vm commit local NAME --image IMAGE` | Save a stopped VM as an image; local service only |
| `iso host vm restore local NAME --image IMAGE` | Replace its disk (confirm); local service only |
| `iso host migrate local` | Preview handing local instances to the host service. `--activate` and `--rollback` change how every instance is managed: the user runs those |

## Never run

| Command | Why |
|---|---|
| `iso update` | Replaces the binaries on the host. `iso update --check` only reports; the user installs |
| `iso uninstall` | Removes the binaries and, with `--purge`, every instance |
