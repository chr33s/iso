<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Platform Backends

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

coop has one backend: Apple Containerization on macOS 27+ Apple Silicon. There
is no backend selection; unsupported operations fail explicitly.

## macOS / Apple sandbox

The host CLI is built from the root Swift package (`swift build`, or
`python3 scripts/build-release.py` for the full archive). **coop-sandbox** is coop's runtime on Apple's
[`containerization`](https://github.com/apple/containerization) package
([`coop-sandbox`](../coop-sandbox)).

Each instance is one Linux VM running systemd from its own ext4 disk, on its own vmnet network, with no host mounts, socket relays, published ports, or host SSH-agent forwarding. The runtime's sandbox record has no field for any of those, and coop verifies the running VM's effective configuration before every hand-out. [`design/apple-sandbox-runtime.md`](design/apple-sandbox-runtime.md) records why this replaced the earlier `container machine` fork.

### Prerequisites

- Apple Silicon, macOS 27 or later. The runtime’s underlying vmnet API has a
  macOS 26 floor, but this fork’s supported host minimum is macOS 27.
- `coop-sandbox`, built with `scripts/build-coop-sandbox.sh` (Xcode with Swift 6.2+ required).
- Stock Apple `container` 1.4.1 or later, with its service running (`container system start`). coop uses it only to **build** images (`container build`) and to supply the guest kernel it installs; instances never run on it. coop never starts, stops, or restarts that service.

Binaries come from `apple_container.binary` (coop-sandbox) and `apple_container.builder` (`container`), or else fixed install locations: `~/.local/opt/coop-sandbox/bin/coop-sandbox`, `/usr/local/bin/coop-sandbox`, `/opt/homebrew/bin/coop-sandbox`, and `/usr/local/bin/container`, `/opt/homebrew/bin/container`. `PATH` and project files are never consulted, and a binary that is group/world-writable or owned by neither you nor root is rejected, as is one under a directory that is owned by neither you nor root, world-writable without the sticky bit, or group-writable without the sticky bit unless its group is `wheel` or `admin` (Homebrew's prefix is `admin`-writable).

Host Docker is not needed. Docker runs *inside* the guest.

### Installing the runtime

```bash
scripts/build-coop-sandbox.sh            # installs ~/.local/opt/coop-sandbox/bin/coop-sandbox
```

It builds the Swift package in release mode, signs it ad hoc with the hardened runtime and its one entitlement (`com.apple.security.virtualization`), and installs it without `sudo`. It refuses an existing `bin/` that is owned by neither you nor root, world-writable, or group-writable by a group other than `wheel` or `admin`. Pass a different prefix as the first argument and set `apple_container.binary` to match. Rebuild after pulling changes to `coop-sandbox`; coop refuses a runtime whose protocol or `containerization` version differs from the one it was built for.

### Supported combinations

| coop-sandbox | containerization | macOS | Hardware | Evidence |
|---|---|---|---|---|
| 0.2.0 (protocol 2) | 0.45.0 | 27.0 | Apple Silicon | [`tests/integration-apple-sandbox.sh`](../tests/integration-apple-sandbox.sh) (all phases, including maintenance install, same-sandbox races, and the `coop` end-to-end phase): 103 passed, 1 skipped by design ([run record](design/apple-sandbox-transactions.md#4-validation)) |
| 0.1.0 (protocol 1), refused since protocol 2 | 0.45.0 | 27.0 | Apple Silicon | [`tests/integration-apple-sandbox.sh`](../tests/integration-apple-sandbox.sh) (isolation, host exposure, canary, pinning, persistence, resources, growth, commit/restore, crash recovery, concurrency), coop `setup`/`up`/`exec`/`stop`/`resize`/`commit`/`restore`/`destroy` end to end |

The runtime also pins its guest kernel by sha256 (`vmlinux-6.18.15-186`, the kernel `container` 1.4.1 installs) and its init image (`vminit:0.45.0` by digest). `coop setup` fails with `APPLE_RUNTIME_UNAVAILABLE` on any other kernel.

### Configuration

```jsonc
{
  "apple_container": {
    // "binary": "/absolute/path/to/coop-sandbox",
    // "builder": "/absolute/path/to/container",
    // "kernel": "/absolute/path/to/vmlinux",  // must be a kernel the runtime pins
    "probe_timeout_seconds": 10,       // version, inspect, list
    "operation_timeout_seconds": 60,   // resource changes, deletes, guest commands
    "create_timeout_seconds": 600,     // create (first unpack of an image), grow, commit, restore, init, maintenance install
    "boot_timeout_seconds": 120,       // boot to SSH-ready
    "stop_timeout_seconds": 90,        // clean systemd shutdown
    "build_timeout_seconds": 3600      // image build; `setup --builder-timeout` overrides
  }
}
```

Each timeout must be between 1 and 86400 seconds. Unknown keys are rejected, and there is no key to mount the home directory, forward the SSH agent, share a network, or skip qualification. The `vm` CPU/memory, image, guest-user, profile, and workspace settings apply; `vm.template_size_gib` is the default disk size.

### State

The config file defaults to `~/.coop/config.jsonc` (see
[Migrating from TOML](configuration.md#migrating-from-toml) for an older
`config.toml`), and `data_dir` defaults to `~/.coop`. A default `~/.coop` that holds upstream coop VM artifacts
(`images/`, `instances/`, `vm_key`, …) or is not a real directory is refused;
select a separate `data_dir` with `--config`. Custom config paths are not
checked. A directory left at `~/.coop-apple` by earlier fork releases is
neither read nor moved: move it to `~/.coop` by hand while no VM is running,
then recreate or re-enroll (`coop restore <name> --reprovision`) its
instances: host-key pins now use the `<machine>.coop` alias, and pins written
under the old `.coop-apple` alias are refused.

The local secret store (`coop secrets`) lives in `<data_dir>/secrets/`.
Backend state remains under `<data_dir>/backends/apple-container-v1/`:

- `owner.json` (installation owner ID) and `vm_key`
- `images/<name>/`: `template-config.json`, `apple-image.json`, and `build.log`
- `instances/<name>/`: `apple-machine.json`, `known_hosts`, `operation.json` while a mutation is pending, and the shared sidecars
- `runtime/`, the coop-sandbox state root: kernel, init filesystem, private OCI store, cached base disks, committed disks, the maintenance boot disk (`maintenance/`), lock files (`locks/`), and one directory per sandbox (disk, record, console and owner logs, launchd plist)

Control files are `0600`, directories `0700`. `uninstall --purge` destroys
owned instances and removes only `backends/apple-container-v1/`; config files,
the secret store (`<data_dir>/secrets/`) and unrelated files remain. Workspace copies skip `.coop/`. The
`coop-apple-<name>` SSH aliases and markers keep their names, so they do not
collide with upstream coop's `coop-<name>` entries. Paths may contain spaces but not quote or control characters.

Instances created by the retired `container machine` backend (schema 1) are refused, including by `coop destroy`, `destroy --all`, and `uninstall --purge`. Remove such an instance's directory under `backends/apple-container-v1/instances/` by hand, and delete its machine and network in Apple `container` (`container machine delete`, `container network delete`).

Fork macOS releases use this backend and include `coop-sandbox` beside `coop`.
The host prefers that adjacent runtime, then the manual install locations; an
explicit `apple_container.binary` still takes precedence. `coop update` targets
`chr33s/coop`.

### Setup process

`coop setup`:

1. Checks the platform, resolves and qualifies coop-sandbox (`coop-sandbox version`: protocol 2, containerization 0.45.0), and creates `owner.json` and the VM-access key pair.
2. Initializes the runtime root: copies the kernel after checking its pinned sha256, and pulls the pinned init image. Unless the runtime already has the current maintenance image, builds it (Ubuntu with e2fsprogs; log in `maintenance-build.log`), installs it with `coop-sandbox maintenance install`, and deletes the store copy.
3. Renders a minimal build context in a private temporary directory: a Dockerfile `FROM ubuntu:24.04` pinned by digest, the Apple provisioning script (packages, profiles, OCI features, guest user, Claude Code, Codex, Docker), and a machine-setup script. The context contains the coop **public** key only. There are no build arguments and no secrets.
4. Checks that the builder's service is running, then runs `container build --platform linux/arm64 -t local/coop-<owner>:<hash>-<nonce>`, with output in `images/<name>/build.log`. Every build gets a fresh tag, so a rebuild never retags an image in use.
5. Saves the image as an OCI archive, imports it into the runtime's private store, and deletes the builder's copy.
6. Boots the image in a disposable sandbox with no credentials, passing the same isolation gate an instance does. It checks the required guest binaries and the guest user's uid (1000), and waits (up to `boot_timeout_seconds`) for `ssh` and `docker`. Then it stops and deletes the sandbox. The unpacked disk stays cached for the first `coop up`.
7. Records the image digest and input hash in `apple-image.json` and `template-config.json`. A failed build or verification deletes the new image and leaves the previous manifest and image in place. After a successful rebuild, the superseded image is deleted.

The image carries no SSH host keys and an empty `/etc/machine-id`. Each sandbox generates its own on first boot and keeps them across restarts. `sshd` refuses passwords and root logins and disables agent forwarding. Units that would fight the runtime's addressing (networkd, resolved, udevd, timesyncd) are masked.

Marketplaces and plugins are not baked into the image. The first boot installs them through the shared bootstrap.

### How instances work

`coop up` creates one sandbox per instance, named `coop-<owner8>-<random16>`. The steps:

1. Write `operation.json`.
2. `coop-sandbox create` with explicit CPUs, memory (MiB), and disk (`--disk`, or the committed image's size, or `vm.template_size_gib`). The disk is an APFS clone of the image's cached base, so this takes milliseconds after an image's first use.
3. Check the runtime's record: owner tag, CPUs, and memory.
4. `coop-sandbox start` loads the sandbox's owner as a launchd job and returns once it answers. The owner process holds the VM and a dedicated `10.231.N.0/24` vmnet network.
5. The isolation gate reads the effective VM configuration from the owner and checks all of the following:
   - The sandbox runs `/sbin/init`, without nested virtualization.
   - It boots from its own disk under `runtime/sandboxes/<id>/`.
   - Its only mounts are the kernel pseudo-filesystems (`proc`, `sysfs`, `devtmpfs`, `mqueue`, `tmpfs` at `/dev/shm`, `cgroup2`, `devpts`) from their fixed sources.
   - It has no socket relays, published ports, or agent forwarding.
   - It has exactly one interface, on its own vmnet subnet, carrying the address the owner reports.
   - Its CPUs, memory, and image digest match the record.
6. Read `/etc/ssh/ssh_host_ed25519_key.pub` over the runtime's native control channel (vsock exec, an argv rather than a shell string), confirm the owner did not restart meanwhile, and pin the key in the instance's `known_hosts`.
7. Connect over SSH with `StrictHostKeyChecking=yes` against that pin, then hand off to the shared lifecycle: forwards, credentials, agent bootstrap, workspace copy, hooks.

Every later `ssh_target` (shell, exec, agent launch, push/pull, editor) re-inspects the sandbox and re-runs the gate before it returns a target. A sandbox keeps its address across restarts, unless its subnet had to be quarantined (see [Recovery](#stop-destroy-recovery)). Every start compares the host key with the pin. A changed or missing key fails with `APPLE_HOST_KEY_CHANGED`, and coop never re-enrolls on its own. The one exception is `coop restore`: coop replaced the disk itself (which removes the host keys), so the next start pins the key the guest generates.

Workspaces are always copied. `--mount` directories are synced once; use `coop push`/`coop pull`.

Local model servers on host loopback reach the guest over a per-instance `ssh -R 127.0.0.1:<guest-port>:<host-addr>:<host-port>` tunnel. The forward goes to the exact loopback address the URL names. The guest port is the same as the host port, except that a privileged port (below 1024) moves to port + 40000, so `https://localhost` becomes `https://localhost:40443` in the guest. `localhost` and `127.0.0.1` URLs keep their host, so TLS names still verify. Other `127.x` addresses are rewritten to `127.0.0.1` for plain HTTP only. IPv6-loopback endpoints are rejected. Every boot first closes the tunnels recorded for the previous boot. Each bootstrap then reconciles the tunnels for both agents: live tunnels are kept, tunnels the config no longer needs are closed, and two endpoints that need the same guest port with different destinations are an error.

### Resize, commit, restore

All three need the instance stopped.

- **`coop resize --mem/--vcpus`** records the new values with `coop-sandbox set`, tagged with an operation id, and reads them back. They apply at the next start. The change is journaled; an interrupted one is reconciled on the next `coop start` from the runtime's record. With `--start`, if the boot fails and the sandbox is confirmed stopped again, the previous values are restored through the same journaled update, and only if the runtime's last committed operation is still the forward change; otherwise, or if the rollback cannot be confirmed, the result is `APPLE_OPERATION_UNCERTAIN`. The guest sees one more vCPU than configured: the runtime's own overhead.
- **`coop resize --size`** grows the disk offline. The runtime clones the disk, extends it, and runs `e2fsck`/`resize2fs` in a short maintenance VM, with the instance's disk attached as data. It then publishes the grown disk and its new size as one recoverable update (a crash between the two is finished by the runtime's next operation on the sandbox), so this takes about a second. Shrinking is refused.
- **Maintenance image.** Maintenance VMs boot their own small image (Ubuntu with e2fsprogs), which `coop setup` builds with the stock builder and installs into the runtime outside its image store, then removes from the store. It does not depend on any instance's image, so deleting or replacing images never affects growth or commits. `coop setup` reinstalls it when its recipe version changes.
- **`coop commit --image <name>`** saves an APFS clone of the disk with its SSH host keys and machine-id removed. `coop up --image <name>` and `coop restore` then clone it, and every instance created from it generates its own identity.
- **`coop restore`** swaps in a clone of a committed disk, or a fresh copy of a base image with `--reprovision`. It then grows the new disk back to the instance's size if that is larger. The operation is journaled: a restore interrupted by a crash is reconciled on the next `coop start` from the runtime's record, and it re-pins the host key only if the runtime's last committed operation is that restore (a higher disk generation alone is not enough).

### Stop, destroy, recovery

- **Stop.** `stop` asks systemd to halt (the runtime forces the VM down after 60 s) and confirms the sandbox reached `stopped`. An unconfirmed stop is `APPLE_OPERATION_UNCERTAIN`, and nothing is deleted. When the normal liveness check fails (an unqualified runtime, a sandbox that fails the gate, or an unfinished journal), `coop stop` stops the owned sandbox through the runtime alone, with no SSH and no qualification, and keeps its disk. `coop status` lists such an instance as `unknown`. A boot that fails or times out during `coop start` stops the sandbox again.
- **Interrupts.** Ctrl-C interrupts only image builds, creates, and boots. Stop, delete, and cleanup commands always run to completion.
- **Destroy.** `destroy` acts only on sandboxes whose names and local records match this installation's owner ID; the runtime also refuses to delete a sandbox whose recorded owner differs. It stops and deletes the sandbox, confirms it is gone, then removes local state. If an operation was interrupted (`operation.json` exists), `destroy` checks what the runtime actually has and removes only what the journal says coop created.
- **Crashed owners.** The VM lives inside its owner process. If that process dies, the VM powers off (no VM is ever orphaned) and launchd starts the owner again, which boots the same disk. Journaled ext4 recovers, but unsynced guest writes can be lost.
- **Subnet leaks.** After an unclean exit, vmnet keeps the sandbox's subnet reserved for hours. The runtime then quarantines it and moves the sandbox to a free subnet, so its address changes while its identity does not.
- **Image deletion.** Only this installation's images and committed disks are deleted. Instances never depend on them after creation.

### Diagnostics

| Identifier | Meaning |
|---|---|
| `APPLE_RUNTIME_UNAVAILABLE` | No usable coop-sandbox or builder, builder service not running, kernel not accepted, or unsupported platform. |
| `APPLE_RUNTIME_UNQUALIFIED` | Unknown runtime, protocol, `containerization` version, or output schema (including an unknown field in the effective configuration). |
| `APPLE_NETWORK_ISOLATION` | Missing, extra, or foreign network interface, or an address that does not match. |
| `APPLE_HOST_EXPOSURE` | A host mount, socket relay, published port, agent forwarding, foreign root disk, or non-systemd init. |
| `APPLE_IDENTITY_CONFLICT` | Ownership, name, image, resource, or boot identity mismatch. |
| `APPLE_HOST_KEY_CHANGED` | Missing or changed pinned host key. |
| `APPLE_BOOT_TIMEOUT` | Boot or readiness failed or exceeded its deadline, or no valid host key appeared in time; the error includes the last lines of the console log. Disk and journal are kept. |
| `APPLE_OPERATION_UNCERTAIN` | Timed-out or cancelled runtime call, unconfirmed stop, a booting or crashed sandbox, or an unfinished journal; reconciled on retry. `coop list` shows a crashed sandbox as stopped, since `coop start` accepts it. |

`coop logs` (snapshot and `--follow`) replaces control characters in the guest's console output before printing it.

Runtime and builder commands run with a cleared environment: only `HOME`, `USER`, `LOGNAME`, `TMPDIR`, locale, and a fixed `PATH` pass through. `SSH_AUTH_SOCK`, API and GitHub tokens, `DYLD_*`, and `CONTAINER_*` overrides are dropped. The launchd job that runs each owner gets a fixed environment of its own. Guest-bound `ssh`, `scp` and `rsync` likewise inherit only a minimal host environment plus the values coop forwards, so a user's `SendEnv` patterns cannot leak an unrelated host variable.

### Validation status

Validated on macOS 27.0 (Apple M5 Max) with coop-sandbox 0.1.0 and containerization 0.45.0. Runtime 0.2.0 has re-run the runtime suite and the `coop` phase; see the table above.

- **Runtime ([`tests/integration-apple-sandbox.sh`](../tests/integration-apple-sandbox.sh); the selection experiment is in [`design/apple-sandbox-runtime.md`](design/apple-sandbox-runtime.md)):**
  - Peer isolation: a root guest cannot reach another sandbox by TCP, UDP, or ICMP over IPv4 or IPv6. That holds with forged on-link routes, static neighbour entries, spoofed source addresses, and broadcast/multicast, and after restarts; the host reaches each listener as the positive control.
  - Host exposure: no mounts, agent sockets, host canary file, or host vsock listeners reach the guest, and a canary secret never reaches the runtime, its logs, the image, or the guest.
  - Identity and lifecycle: pinned SSH over the native channel; 20 stop/start cycles with no loss of data or identity; CPU/memory changes, disk growth, and commit/restore.
  - Recovery and scale: every crash-injection scenario ends in a known state, and 1/4/8 concurrent sandboxes each get their own address and subnet.
- **coop end to end:** the suite's `coop` phase covers `setup` (build, import, verification), `up`, `exec`, `status`, `stop`/`start`, `resize --size/--mem/--vcpus`, rollback of a failed `resize --start`, `commit`, `restore` with host-key re-pinning, `destroy`, and image deletion. Run by hand on 0.1.0 only: `up` with an explicit disk, `logs`, `up --image` from a committed image with a fresh identity, and rejection of a guest-changed host key.

Not covered: other macOS releases or kernels, and live-provider API calls.
