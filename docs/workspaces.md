# Workspace Sync

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

coop moves code between the host and guest VM. The normal way to get code in is `coop up`, with `push` and `pull` for ongoing sync.

## Getting Code into the VM

### Project environment (`coop up`)

```bash
coop up ./my-project
coop up ./my-project --mount
coop up --git-repo https://github.com/trailofbits/coop.git
```

`coop up` treats the directory as the project identity. Re-running the same
command finds the existing instance for that directory instead of allocating
another VM. The default transport is copy/sync into `/workspace`; `--mount`
uses mount transport for the project directory, which on the Apple backend is
a one-time sync (there are no host mounts). Use
`--extra-mount HOST:GUEST` for additional mounted data directories when
creating the project instance. If the instance already exists, destroy it
first to change creation-time choices such as transport, image, disk size, or
extra mounts.

`coop up` in copy mode tar-pipes the project into `/workspace` inside the
guest over SSH. Both sides independently SHA-256-hash the tar stream. If the
checksums diverge, the transfer aborts. coop persists the host-to-guest path
mapping in `workspace.json` so that later `push` and `pull` calls resolve paths
automatically.

`coop up --mount` syncs the project directory into the guest once. The Apple
backend gives the guest no host mounts, so this is not a live mount; use
`coop push` / `coop pull` to sync changes afterward.

Additional host data can be mounted at creation time with
`coop up --extra-mount HOST_PATH:GUEST_PATH`. In copy mode, extra mounts must
not target `/workspace`, because the copied project owns that path.

`coop up --git-repo <url>` clones the repository inside the guest at
`/workspace` and records the original URL in `workspace.json`. Because there
is no host workspace path for that source, later `push` and `pull` commands
need an explicit `--dir` if you want to sync files back to the host.

#### Pulling a git repository back (absolute-path caveat)

Git operations inside the guest can write absolute guest paths into the
workspace's `.git/config`. Common triggers:

- `git worktree add` records `core.worktree = /workspace/...` in the worktree's config.
- `prek install` (and `git config core.hooksPath`) records `core.hooksPath = /workspace/.git/hooks`.

The Apple backend has no live host mounts, so these entries stay in the guest
until you `coop pull`. Copy and mount transports both include `.git/` by
default, so a pull brings them to the host, where every `git` invocation then
fails with `fatal: Invalid path '/workspace': No such file or directory`. Remove
the offending lines from `.git/config` (and `.git/worktrees/*/config`), avoid
those commands in the guest, or pass `--exclude-git` on `coop pull`.

### Manual via SSH

```bash
coop shell
# then use git clone, scp, or any other tool inside the guest
```

No workspace state is recorded. `push` and `pull` will not work without a `workspace.json`.

## State file: `workspace.json`

Creating a project VM with `coop up` writes a `workspace.json` in the instance directory:

| Field        | Description                                                    |
|-------------|----------------------------------------------------------------|
| `host_path`  | Absolute path on the host for local workspace and mount sources |
| `guest_path` | Path inside the guest VM (always `/workspace`)                 |
| `source`     | How the workspace was created: `workspace`, `mount`, or `git_repo` |

`push` and `pull` read this file to resolve default paths.

## Pushing: host to guest

```bash
coop push                                    # uses host_path from workspace.json
coop push --dir ./other-dir                  # push a specific directory
coop push --force                            # skip guest dirty check
coop push my-instance                        # target a specific instance
coop push my-instance --dir ./src --force    # combined
```

Before overwriting guest files, `push` checks for in-guest work the host doesn't yet know about. Two signals are inspected:

- `git status --porcelain --untracked-files=no` — modifications to tracked files. Untracked files are skipped because they're usually host-side build artifacts that were copied into the guest at start time, not work done by an in-guest agent.
- `git rev-list --count '@{u}..HEAD'` — commits on the current branch that are ahead of its upstream. Catches in-guest commits that a host push would otherwise silently overwrite.

If either signal finds anything, push prints it and exits. `--force` overrides both.

Transfer method selection is automatic:

1. **rsync** if the guest has it. Uses `--delete` to mirror the host directory exactly. Reads `.gitignore` files via `--filter=':- .gitignore'`.
2. **tar-pipe** otherwise. Streams a tar archive over SSH with end-to-end SHA-256 verification.

## Pulling: guest to host

```bash
coop pull                                       # uses host_path from workspace.json
coop pull --dir ./local-copy                    # pull into a specific directory
coop pull --force                               # skip local dirty check
coop pull my-instance                           # target a specific instance
coop pull my-instance --dir ./local-copy        # combined
```

Before overwriting the local destination, `pull` runs `git status --porcelain` against it. If the directory has a `.git` and any uncommitted changes (tracked or untracked), pull refuses unless you pass `--force`. Unlike push's guest-side check, the local check does not inspect unpushed commits — committing your local work first is enough to satisfy it.

The destination directory is created if absent. Transport selection follows the same rsync-then-tar-pipe order. The tar-pipe fallback verifies SHA-256 checksums end-to-end.

## Staged pulls

`coop diff` (or `coop pull --review`, or any `coop pull` with
`workspace.pull.mode = "stage"`) pulls into a stage under the instance
directory instead of the local directory:

```bash
coop diff my-instance                         # stage + review
coop pull my-instance --apply --stage-id 1a2b3c4d
coop pull my-instance --discard
```

The stage is walked without following links and checked before anything is
applied:

- Only regular files, directories and symlinks are accepted. FIFOs, sockets,
  devices and hard links make the stage inapplicable.
- A symlink must be relative, stay inside the workspace, and not pass
  through another symlink.
- File names must be UTF-8 without control characters.
- `workspace.pull.max_files`, `max_bytes` and `max_file_bytes` are hard
  budgets; exceeding one discards the stage. While the transfer runs it is
  also sampled about twice a second against `max_files` and `max_bytes`
  (allocated bytes) and stopped once it exceeds either, so a guest cannot fill
  the host disk before the final check.
- Directories nested deeper than 64 levels make the stage inapplicable.
- Symlink names are compared case- and normalization-insensitively, as APFS
  resolves them.
- One stage operation runs at a time per instance; a second `coop pull` or
  `coop diff` waits for the first.
- A guest file where the host has a directory is reported for you to resolve.

The review lists every added (`A`), modified (`M`) and type-changed (`T`) path,
flags changes that can run commands on the host (anything under a `.git`
path, including a `.git` file that redirects the git directory; `.husky/`;
`.envrc`; `.vscode/tasks.json`), and prints text diffs for small UTF-8 files. `--apply` then:

- refuses if any reviewed destination path changed since the review, or a
  staged file no longer matches the hash in the manifest;
- writes each file through a temporary file and a rename, replacing a
  destination symlink rather than following it;
- on failure, lists what was already applied and keeps the stage.

Like a direct pull, a staged pull never deletes local files. `--force` skips
only the local uncommitted-changes check.

## Default exclusions

All transfers (rsync and tar-pipe) exclude these reproducible build and cache directories:

- `node_modules/`
- `target/`
- `__pycache__/`
- `.venv/`
- `.coop/`

When coop uses tar on a macOS host, host-side tar archive creation runs with
`COPYFILE_DISABLE=1`. This suppresses tar-generated AppleDouble (`._*`) entries
for resource forks or extended attributes while packing (the setting has no
effect on extraction). Without it, those metadata entries can land in a Linux
guest as ordinary files, including inside `.git/`, where they can break Git's
pack/ref discovery.

`.git/` is **included** by default so agents in the guest get full history, branches, and the ability to make commits that survive a `coop pull`. Pass `--exclude-git` to `coop up`, `coop push`, or `coop pull` to skip it on a per-transfer basis (useful for very large repos where transfer time dominates).

## .gitignore integration

When rsync is available, transfers pass `--filter=':- .gitignore'`. Rsync reads `.gitignore` files at each directory level and skips matching paths.

The tar-pipe fallback on Linux uses GNU tar's `--exclude-vcs-ignores` for the same effect. On macOS, BSD tar lacks this flag, so only the default exclusions above apply.

### `.git/` and .gitignore

A repo whose `.gitignore` lists `.git/` (rare, but legal — sometimes seen in dotfile repos or repos vendoring other repos) gets special handling so the new include-by-default behaviour is not silently undone:

- **rsync**: a protective `--filter=+ /.git/***` is prepended before the per-directory `.gitignore` merge, so `.git/` and its contents are always transferred unless `--exclude-git` is passed.
- **GNU tar (Linux)**: `--exclude-vcs-ignores` is all-or-nothing. If your `.gitignore` lists `.git/`, the tar-pipe transport will skip it. Pass `--exclude-git` explicitly if that is what you want, or remove the entry from `.gitignore`.
- **BSD tar (macOS)**: not affected — it doesn't read `.gitignore` at all.

## Checksum verification

Every tar-pipe transfer hashes the archive with SHA-256 on both the sending and receiving sides. A mismatch fails the transfer and reports both hash values. This detects truncated streams, network corruption, and disk errors.

Rsync handles integrity internally. No additional checksumming is layered on top.
