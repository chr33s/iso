<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Workspace Sync

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

isolate moves code between the host and guest VM. The normal way to get code in is `iso up`, with `push` and `pull` for ongoing sync.

## Getting Code into the VM

### Project environment (`iso up`)

```bash
iso up ./my-project
iso up ./my-project --mount
iso up --git-repo https://github.com/chr33s/iso.git
```

`iso up` treats the directory as the project identity. Re-running the same
command finds the existing instance for that directory instead of allocating
another VM. The default transport is copy/sync into `/workspace`; `--mount`
uses mount transport for the project directory, which on the Apple backend is
a one-time sync (there are no host mounts). Use
`--extra-mount HOST:GUEST` for additional mounted data directories when
creating the project instance. If the instance already exists, destroy it
first to change creation-time choices such as transport, image, disk size, or
extra mounts.

`iso up` in copy mode tar-pipes the project into `/workspace` inside the
guest over SSH. Both sides independently SHA-256-hash the tar stream. If the
checksums diverge, the transfer aborts. isolate persists the host-to-guest path
mapping in `workspace.json` so that later `push` and `pull` calls resolve paths
automatically.

`iso up --mount` syncs the project directory into the guest once. The Apple
backend gives the guest no host mounts, so this is not a live mount; use
`iso push` / `iso pull` to sync changes afterward.

Additional host data can be mounted at creation time with
`iso up --extra-mount HOST_PATH:GUEST_PATH`. In copy mode, extra mounts must
not target `/workspace`, because the copied project owns that path.

`iso up --git-repo <url>` clones the repository inside the guest at
`/workspace` and records the original URL in `workspace.json`. Because there
is no host workspace path for that source, later `push` and `pull` commands
need an explicit `--dir` if you want to sync files back to the host.

#### Guest Git configuration stays in the guest

Git operations inside the guest can write absolute guest paths into
`/workspace/.git/config` (for example `git worktree add`, `prek install` or
`git config core.hooksPath`). A pull never installs Git administration on the
host (see [Git administration](#git-administration)), so these entries and
guest commits stay in the guest; push commits to a remote from there.

### Manual via SSH

```bash
iso shell
# then use git clone, scp, or any other tool inside the guest
```

No workspace state is recorded. `push` and `pull` will not work without a `workspace.json`.

## State file: `workspace.json`

Creating a project VM with `iso up` writes a `workspace.json` in the instance directory:

| Field        | Description                                                    |
|-------------|----------------------------------------------------------------|
| `host_path`  | Absolute path on the host for local workspace and mount sources |
| `guest_path` | Path inside the guest VM (always `/workspace`)                 |
| `source`     | How the workspace was created: `workspace`, `mount`, or `git_repo` |

`push` and `pull` read this file to resolve default paths.

## Pushing: host to guest

```bash
iso push                                    # uses host_path from workspace.json
iso push --dir ./other-dir                  # push a specific directory
iso push --force                            # skip guest dirty check
iso push my-instance                        # target a specific instance
iso push my-instance --dir ./src --force    # combined
```

Before overwriting guest files, `push` checks for in-guest work the host doesn't yet know about. Two signals are inspected:

- `git status --porcelain --untracked-files=no` — modifications to tracked files. Untracked files are skipped because they're usually host-side build artifacts that were copied into the guest at start time, not work done by an in-guest agent.
- `git rev-list --count '@{u}..HEAD'` — commits on the current branch that are ahead of its upstream. Catches in-guest commits that a host push would otherwise silently overwrite.

If either signal finds anything, push prints it and exits. The check fails
closed: a `.git` file (linked worktree, submodule) counts as a repository, a
failed Git or SSH step, malformed or truncated output, and a configured
upstream that no longer resolves all block the push as "cannot tell". A
branch with no upstream configured at all is allowed when clean, though its
commits may exist only in the guest. `--force` is the explicit authority to
overwrite guest work. The check runs in the guest and protects a cooperative
guest; it is not a security boundary.

What is sent is one immutable snapshot of the selected files
([`workspace.input`](configuration.md#workspaceinput)): by default the
working-tree bytes of the files in the Git index, read as data without running
Git on the host. `.git`, original history and credential-looking names
(`.env`, keys, `.npmrc`, …) are never sent unless a name is explicitly allowed;
omissions are listed. The snapshot travels as a tar stream; a push never
deletes guest files, so files deleted on the host are reported rather than
removed in the guest. A non-Git directory needs an explicit
`workspace.input.mode = "paths"` selection.

## Pulling: guest to host

Every pull is received into a host-side stage, validated, and installed by
one native installer. No receiver writes the local directory, and host Git
never runs during a return (no `git status`, hooks, filters, pagers or
editors), so a guest cannot steer host Git through the destination.

```bash
iso diff my-instance                                     # stage + review
iso pull my-instance --review                            # the same
iso pull my-instance --apply --stage-id 1a2b3c4d5e6f7a8b # apply exactly that stage
iso pull my-instance --apply --stage-id 1a2b3c4d5e6f7a8b \
  --approve-sensitive .envrc                             # name each sensitive path
iso pull my-instance --discard
iso pull my-instance                                     # direct mode (below)
```

`--apply` always needs the exact `--stage-id` printed at review; it never
infers the latest stage. With `workspace.pull.mode = "direct"` a plain
`iso pull` stages and applies in one step through the same validation: a
plan of additions applies at once, while replacing existing files needs
`--force`. A held direct pull keeps the whole stage, prints it, writes
nothing, and exits nonzero. `--exclude-git` is accepted on `pull` and `diff`
for compatibility and has no effect.

### Destination

- The destination is resolved once and bound by directory identity. A
  destination that does not exist yet must have an existing parent; it is
  created only by an authorized apply, after complete preflight, and that
  creation is reported as a change even if a later write fails.
- It must be disjoint from iso control state: the instance directory, the
  backend state root (other instances, remote shadows, keys) and `~/.iso`,
  as ancestor or descendant. A home directory that contains `~/.iso` is
  therefore refused; return into a project or export directory.
- A destination inside `.git` is refused, as is one with a `.git` symlink in
  its root or a directory the plan touches.

### Git administration

`.git` at any depth, of any object type and any spelling APFS treats as the
same name, is never requested, installed, replaced or traversed. What
arrives anyway is counted against the budgets and summarized at review.
Existing host `.git` directories stay untouched. Supported layouts are
ordinary worktrees, standard linked worktrees and submodules, and plain
export directories: an existing gitfile (`gitdir: …`) is read natively and
must point outside the returned tree or beneath a protected `.git`; any other
gitfile makes the destination inapplicable. Arbitrary bare repositories and
custom `GIT_DIR` layouts are outside this guarantee.

### What a stage may contain

The stage is walked without following links and checked before anything is
applied:

- Only regular files, directories and symlinks are accepted. FIFOs, sockets,
  devices and hard links make the stage inapplicable.
- A symlink must be relative and stay inside the workspace. Every component
  of its target, the last one included, is checked against the planned final
  tree: a target through or onto another link, or into `.git`, makes the stage
  inapplicable.
- File names must be UTF-8 without control characters. Two names that the
  destination volume treats as one (case or Unicode normalization), or a
  name that differs only in that way from the host's existing entry, make the
  stage inapplicable. A case-insensitive staging volume can already merge some
  guest names before inspection; only the received tree is validated.
- A host directory replaced by a file or link, or a file or link replaced by a
  directory, is reported for you to resolve.
- Only permission bits up to `0755` are installed: no owner, setuid/setgid,
  ACLs, extended attributes or flags from the guest.
- `workspace.pull.max_files`, `max_bytes` and `max_file_bytes` are hard
  acceptance budgets; exceeding one discards the stage. While the transfer
  runs it is also sampled about twice a second and stopped once it exceeds
  `max_files` or `max_bytes` (allocated bytes). Sampling can overshoot between
  samples: it is not a hard disk quota. An inspection failure stops the
  transfer.
- Directories nested deeper than 64 levels make the stage inapplicable.

### Receiving

Receives use only the system `/usr/bin/bsdtar` (bsdtar 3) and
`/usr/bin/rsync` (openrsync) with a fixed environment and a pinned
`/usr/bin/ssh`; a tool that is not root-owned and of the qualified family is
refused, never replaced from `PATH`. Each receive goes to a fresh,
owner-private incoming directory with an unpredictable ID. Its writers inherit
a lock lease, so a receiver that outlives a killed `iso` keeps the tree busy:
it is never validated, reused, promoted or deleted until the lease is free. A
failed receive leaves the previously selected stage in place; at most one
selected stage and one incoming receive are kept per instance. Receivers are
ordinary processes, not sandboxed.

### Review and apply

The review lists every added (`A`), modified (`M`) and type-changed (`T`)
path and prints text diffs for small UTF-8 files, read without following links
and checked against the manifest's hashes (a mismatch marks the review stale).
Known execution-sensitive paths (`.husky/` anywhere, `.envrc`,
`.vscode/tasks.json`, and links resolving to them) are **withheld**: the whole
stage applies only when every one is named with `--approve-sensitive PATH`
(exact paths, no globs or prefixes) alongside `--apply --stage-id`. `--force`,
direct mode and the stage id never approve them. This list is intentionally
incomplete; returned source stays untrusted for later host use.

`--apply` then:

- re-validates the manifest, the destination identity, every expected old
  object and parent, gitfiles and every staged byte before the first write;
- records a durable attempt before writing: each stage gets one apply
  attempt, and a crashed or failed attempt is never replayed;
- writes each file through a temporary file and a rename, rechecking the
  destination entry immediately before the replace, and replaces a
  destination symlink rather than following it;
- on failure, reports what was written, whether the failed entry changed,
  and whether the destination was created, and keeps the stage. Re-stage
  with `iso diff` to review what remains. Applies are per-file atomic; the
  whole workspace is not.

A pull never deletes local files. One apply runs at a time per user, across
instances and data roots.

## Default exclusions

Pulls (rsync and tar-pipe receives) and recursive
[`workspace.input`](configuration.md#workspaceinput) `paths` selections skip
these reproducible build and cache directories:

- `node_modules/`
- `target/`
- `__pycache__/`
- `.venv/`
- `.iso/`

The default `index` selection sends exactly the files in the Git index, so
these names are not filtered there.

When isolate uses tar on a macOS host, host-side tar archive creation runs with
`COPYFILE_DISABLE=1`. This suppresses tar-generated AppleDouble (`._*`) entries
for resource forks or extended attributes while packing (the setting has no
effect on extraction). Without it, those metadata entries can land in a Linux
guest as ordinary files.

## `.git` and `.gitignore`

Every transfer into the guest (first copy, push, mount sync) is one tar stream
of an immutable host-side snapshot selected by `workspace.input`: the files in
the Git index, or explicit paths. It never carries `.git` or the host's
history, and it never reads `.gitignore` or other ignore files. After the
first copy the guest gets a new repository with one synthetic commit of the
sent files. `--exclude-git` is a deprecated no-op.

Pulls never request or install `.git` (see
[Git administration](#git-administration)). When the guest has rsync, a pull
passes `--filter=':- .gitignore'`, so the guest's `.gitignore` files can skip
paths it would otherwise send. This only shrinks the transfer; it is not an
authority, since the guest controls those files and every received entry is
validated in the stage. The tar-pipe receive does not read `.gitignore`.

## Checksum verification

Every tar-pipe transfer hashes the archive with SHA-256 on both the sending and receiving sides. A mismatch fails the transfer and reports both hash values. This detects truncated streams, network corruption, and disk errors.

Rsync handles integrity internally. No additional checksumming is layered on top.
