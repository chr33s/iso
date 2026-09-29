<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Running Multiple Instances

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

isolate runs multiple VM instances simultaneously. Each instance gets its own name, disk, network identity, and lifecycle.

## Named vs. auto-named instances

Every instance has a name. By default, `iso up` derives it from the project directory. You can provide one explicitly with `--name`.

```
# Project-derived instance
iso up ./my-project

# Explicit instance name
iso up ./my-project --name my-project
```

Named instances pay off when you have several running at once. The name appears in `iso list` / `iso status` output and targets commands at a specific instance.

### Several instances for one project

`iso up` normally reuses the instance already recorded for a project directory (or `--git-repo` URL). Add `--new-instance` to create another one alongside it — useful for running two agents against the same source tree. It requires `--name`, since the project-derived name is already taken.

```
iso up ./my-project                                  # first instance
iso up ./my-project --new-instance --name worker-2   # sibling instance
```

Each sibling is an independent instance with its own disk and workspace copy; the project directory is not shared state between them unless you use `--mount`.

Once a directory has more than one instance, `iso up ./my-project` can no longer pick one for you: it reports the ambiguity and lists the names. Address the instances by name from then on — `iso start worker-2`, `iso shell worker-2` — or destroy the extra one.

### Name validation rules

Instance names must satisfy all of the following:

- 1 to 64 characters long
- Characters limited to `a-z`, `A-Z`, `0-9`, `-`, `_`

Names that violate these rules are rejected at creation time.

## Addressing instances

Most commands accept an optional instance name. Resolution follows three cases:

- **Zero instances exist.** The command fails with a message to run `iso up`.
- **Exactly one instance exists.** The name is optional. isolate auto-selects it.
- **Multiple instances exist.** The name is required. isolate lists the available names in the error if you omit it.

```
# With one instance, these are equivalent:
iso shell
iso shell my-project

# With multiple instances, you must specify:
iso shell my-project
iso shell another-project
```

This applies to `shell`, `stop`, `destroy`, `status <name>`, `logs`, `push`, `pull`, `exec`, `editor`, `resize`, `model`, `claude`, and `codex`.

## Checking status

### Just the names

`iso list` (alias `ls`) prints a minimal name/state table. It reads from local on-disk state only, so it's fast and works even when VMs are unreachable. Use it when you just need to remember what's available:

```
$ iso list
NAME             STATE
another-project  stopped
my-project       running
```

### All instances

`iso status` with no arguments lists every instance in a richer table, including image, backend, and resource usage for running instances:

```
$ iso status
my-project       running    default    apple-container   load=0.42 mem=50% disk=25%
another-project  stopped    default    apple-container
```

Each row shows the instance name, state (`running` or `stopped`), the image it was created from, the backend (always `apple-container`), and a resource usage summary for running instances: 1-minute load average, memory percentage, and disk percentage.

### Single instance

Pass a name to get detailed information for one instance:

```
$ iso status my-project
```

It includes the full resource breakdown: load average, memory used/total in MiB, disk used/total in MiB.

## Per-instance image selection

Each instance can use a different golden image. Build images with `iso setup --image <name>`, then select one when creating the project instance:

```
iso setup --image python --profile python
iso setup --image node --profile node

iso up ./py-work --image python
iso up ./js-work --image node
```

Omitting `--image` selects the image named `default`.

## Per-instance disk sizing

### At creation time

`--disk` sets the instance disk size in GiB:

```
iso up ./big-project --disk 100
```

The instance disk grows from the template size when the requested size is larger.

### After creation

`iso resize` changes the disk size, memory, or vCPU count of a stopped instance:

```
# Absolute disk size
iso resize --size 150
iso resize my-project --size 150

# Relative disk size (grow by 20 GiB)
iso resize my-project --size +20

# Memory and/or vCPUs (combine with disk if you like)
iso resize my-project --mem 8192 --vcpus 4

# Apply and boot in one step
iso resize my-project --mem 4096 --start
```

The instance must be stopped first. isolate rejects the resize and tells you to stop the instance if it is running. Memory and vCPU changes persist in the runtime's record for the instance (authoritative over the global `vm` defaults, which only apply to new instances) and take effect on the next `iso start`, or immediately with `--start`.

## Independent lifecycle

Each instance is fully independent. Start, stop, and destroy instances without affecting others:

```
iso up ./frontend --name frontend
iso up ./backend --name backend
iso stop frontend        # backend keeps running
iso destroy frontend     # backend unaffected
```

To destroy all instances and shared resources (images and the VM access key) at once:

```
iso destroy --all
```

## Instance directory structure

Instance data lives under
`<data_dir>/backends/apple-container-v1/instances/<name>/` (by default
`~/.iso/backends/apple-container-v1/instances/<name>/`). Directories are
`0700` and control files `0600`. Each instance directory contains:

| File | Purpose |
|------|---------|
| `instance.json` | Instance metadata (name, index, image) |
| `apple-machine.json` | The runtime sandbox this instance owns |
| `known_hosts` | The pinned guest SSH host key |
| `operation.json` | Journal of a pending runtime mutation (present only while one is unfinished) |
| `workspace.json` | Workspace sync state (host path, guest path, source) |
| `forwards.json`, `guest_env.json`, `model.json`, `proxy.json`, `github_pat.json` | Per-instance port forwards, guest environment, model mode, proxy overrides and PAT assignment, when set |

The VM disk itself lives in the runtime's state root, not in this directory;
see [backend state](backends.md#state).

## Concurrent access and file locking

When allocating a new instance, isolate acquires an exclusive file lock (`flock`) on the instances directory. This prevents two concurrent `iso up` invocations from claiming the same index or name. The lock is held only during index allocation and released automatically when the operation completes.

## Index allocation

Each instance is assigned a numeric index (0 through 252), which isolate uses for per-instance port ranges such as the credential proxy's. Allocation starts from the highest existing index plus one. When the ceiling is reached, it wraps around to fill gaps at the low end, so at most 253 instances can exist. Network addresses come from the runtime, which gives each sandbox its own vmnet subnet.
