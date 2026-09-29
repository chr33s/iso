# Images and Profiles

isolate builds **golden images** (templates) once and copies them to create VM instances. `iso setup` builds the template. `iso up` copies it when creating a project instance. Profiles control which development tools go into the template.

## How templates work

A template is a fully provisioned Ubuntu image held by the Apple runtime. The
build process (see [Apple setup](backends.md#setup-process) for every step):

1. Renders a build context: a Dockerfile `FROM ubuntu:24.04` pinned by digest and the provisioning script
2. Installs base packages, Docker, GitHub CLI, Claude Code, and Codex
3. Applies requested profiles and devcontainer Features
4. Builds it with Apple `container build`, imports it into the runtime's private image store, and verifies it in a disposable sandbox

isolate records the result under
`~/.iso/backends/apple-container-v1/images/<name>/`. Creating an instance
takes an APFS clone of the image's cached base disk, so it is fast and shares
storage until written. The template disk size (default 8 GiB) is set with
`--template-size`.

## What every template includes

Every template installs these packages regardless of profile selection.

**Base packages:** `openssh-server`, `dbus-user-session`, `curl`, `wget`, `git`, `build-essential`, `ca-certificates`, `gnupg`, `lsb-release`, `sudo`, `iproute2`, `iptables`, `kmod`, `procps`, `util-linux`, `jq`, `rsync`, `unzip`, `zip`, `file`, `gnome-keyring`, `less`, `libsecret-tools`

**Docker:** `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`

**GitHub CLI:** `gh`

**Claude Code CLI:** installed via the native installer during the template build.

**Codex CLI:** installed with OpenAI's native installer as the guest user during
the template build. The full package, including bundled tools, stays under the
user's home directory. `~/.local/bin/codex` is the native launcher;
`/usr/local/bin/codex` is a compatibility link. The guest user can run
`codex update` directly without sudo.
The image also installs `/usr/local/bin/codex-account`, a wrapper used by
`"codex": { "auth": "chatgpt" }` to run Codex with a D-Bus session and guest Linux
Secret Service storage. The wrapper and its three supporting packages
(`dbus-user-session`, `gnome-keyring`, `libsecret-tools`) are installed in every
image, not gated on the `auth` setting: an image is built once and reused across
configs, so gating them would let a later `"auth": "chatgpt"` edit meet an image
that cannot serve it. When that mode is not configured the wrapper simply execs
Codex, so it costs nothing at run time.

Both agents are installed at whatever version was current when the template was built, and that version is not part of the staleness hash — a plain `iso setup` does not refresh them. There are two ways to get newer agents:

- **A live instance:** run `codex update` inside the VM, or `iso agent update [--claude] [--codex]` from the host (see [`agent update`](commands.md#agent-update)). Claude Code also auto-updates itself in the background.
- **The golden image:** `iso setup --rebuild` rebuilds the template from a fresh base, so every new instance ships the latest agents.

## Built-in profiles

Profiles layer language-specific toolchains on top of the base install. Pass them to `--profile` during setup:

```bash
iso setup --profile python
iso setup --profile python,node,rust
```

| Profile | Packages and scripts |
|---------|---------------------|
| `python` | `python3`, `python3-pip`, `python3-venv` |
| `node` | `nodejs` (NodeSource repository added via pre-install script) |
| `c` | `clang`, `llvm`, `gdb`, `valgrind`, `cmake`. Installs plugin: `clangd-lsp@claude-plugins-official` |
| `fuzz` | `clang`, `llvm`, `afl++`, `lcov` |
| `rust` | Rust toolchain via post-install script (not apt). Installs plugin: `rust-analyzer-lsp@claude-plugins-official` |
| `go` | `golang` |

Plugins listed above are installed by the profile and do not need to be listed separately in config. The Apple backend does not bake marketplaces and plugins into the image; the first boot of each instance installs them.

## Custom profiles

Define profiles in the configuration under `profiles`:

```jsonc
{
  "profiles": {
    "ml": {
      "apt_packages": ["python3", "python3-pip", "python3-venv"],
      "pre_install": "add-apt-repository -y ppa:some/repo",
      "post_install": "pip3 install torch numpy pandas",
      "marketplaces": ["https://registry.example.com/plugins"],
      "plugins": ["my-linter@my-marketplace"]
    }
  }
}
```

Five fields per profile:

- **`apt_packages`**: apt packages to install.
- **`pre_install`**: shell script that runs before `apt-get install`. Use this to add package repositories.
- **`post_install`**: shell script that runs after `apt-get install`. Use this for pip installs, binary downloads, or other setup.
- **`marketplaces`**: plugin marketplace sources (URLs or local paths) to register.
- **`plugins`**: plugins to install from the registered marketplaces.

Custom profiles override built-in ones. A custom profile named `python` replaces the built-in `python` profile entirely.

Use them the same way:

```bash
iso setup --profile ml
iso setup --profile ml,node
```

## Build-on-demand from `up`

For profile-only workflows, `iso up --profile <list>` builds the matching
image automatically before starting a new instance. The image name is derived
from the sorted profile list, so these commands all target the same
`node-python` image:

```bash
iso up --profile python,node
iso up --profile node,python
```

isolate runs the same recipe-hash staleness check used by `iso setup`. If the
derived image is missing or stale, it is built or rebuilt first; if it is
current, startup reuses it.

Explicitly named images are not affected by this shorthand. To choose the
image name yourself, build it with `setup` and start a project from that image:

```bash
iso setup --image ml-dev --profile python,node
iso up . --image ml-dev
```

## Extra packages and post-install scripts

`iso setup` still accepts `--extra-packages` and `--post-install`, but the
Apple backend ignores them and prints a warning. Put one-off packages and
setup steps in a [custom profile](#custom-profiles) (`apt_packages`,
`pre_install`, `post_install`) instead; profile changes are part of the
recipe hash and trigger a rebuild.

## Named images

By default, isolate builds an image called `default`. Build multiple images with different configurations using `--image`:

```bash
iso setup --profile python --image py-dev
iso setup --profile python,node,rust --image polyglot

iso up . --image py-dev
iso up . --image polyglot
```

Each named image has its own record under `~/.iso/backends/apple-container-v1/images/<name>/` with independent versioning and staleness tracking.

## Managing images

List all images:

```
$ iso images
default              profiles: python, node              created: 2026-03-20T14:30:00Z     size: 4.2 GiB
polyglot             profiles: python, node, rust        created: 2026-03-22T09:15:00Z     size: 6.1 GiB
```

Output includes the image name, installed profiles, creation timestamp, and disk size (the size is unavailable on the Apple backend, whose images live in the runtime's store).

Delete a named image:

```bash
iso images --delete polyglot
```

## Committing an instance to an image

`iso commit` captures a stopped instance's filesystem as a new image, the inverse of the template-to-instance copy `iso up` performs. Like `docker container commit`, it saves files — not live memory.

```bash
iso stop my-project
iso commit my-project --image my-project-baseline
```

The committed image is an ordinary isolate image (an APFS clone of the disk with its SSH host keys and machine-id removed, recorded under `~/.iso/backends/apple-container-v1/images/<name>/`): it carries over the source image's `template-config.json` (profiles, guest user, hashes) with a fresh creation timestamp, so `iso images` lists it and `iso up --image <name>` launches new instances from it. The instance must be stopped first for filesystem consistency. Committing onto an existing image name requires `--force`.

`iso restore` rolls a stopped instance back to an image's filesystem in place:

```bash
iso commit my-project --image safe-point   # checkpoint
# ... a risky run trashes the environment ...
iso stop my-project
iso restore my-project --image safe-point   # back to the checkpoint
iso start my-project
```

Restore keeps the instance's name, index, IP, and workspace association — only the disk is replaced and the instance's recorded image is updated. That makes it the ergonomic choice over `destroy` + `up --image` for the destructive-undo loop, which would allocate a different instance.

The `iso start` in that recipe does not re-sync `/workspace` or reinstall plugins, which is correct for a checkpoint — the restored disk already carries both. Restoring a **base** image is different: nothing on that disk to preserve, so `start` would leave an empty `/workspace` and no plugins. Use `iso restore --reprovision` to reset an instance onto a base image; see [commands.md](commands.md#--reprovision).

## Template versioning and staleness

isolate records what went into each template in a `template-config.json` file alongside the image. This config contains:

- **Version number**: a monotonic counter that increments when base install logic changes. A newer isolate version triggers a rebuild.
- **Install script hash**: SHA-256 of the composed install recipe (base + profiles + devcontainer Features). Changing profiles changes this hash.
- **Profile list, guest user, and OCI Features**: the exact inputs used to build the template.
- **Marketplaces and plugins**: always empty on the Apple backend, which bakes none; on VM startup isolate installs the configured set.
- **Creation timestamp**: when the template was built.

On every `iso setup`, isolate computes the current recipe hash and compares it to the stored config. If the hashes differ, the template is stale and isolate rebuilds it. A missing config file (orphaned image) also triggers a rebuild.

When you omit `--profile`, `iso setup` reuses the values from the existing template config. Running `iso setup` with no flags only rebuilds if the underlying install logic changed.

## Rebuilding

Force a rebuild regardless of staleness:

```bash
iso setup --rebuild
iso setup --rebuild --image py-dev
```

The build is crash-safe. Every build gets a fresh image tag; a failed build or verification deletes the new image and leaves the previous manifest and image in place. After a successful rebuild, the superseded image is deleted.

## Instance creation from templates

`iso up` creates an instance from a template when no project instance exists:

1. Clones the image's cached base disk (APFS clone) for the instance
2. Sizes the disk from `--disk`, the committed image's size, or `vm.template_size_gib`
3. Creates and boots a sandbox on its own vmnet network, then passes the isolation gate and pins the guest's SSH host key

See [How instances work](backends.md#how-instances-work) for every step.

```bash
iso up .
iso up . --disk 50
iso up . --image py-dev --disk 100
```

Shrinking below the image size is not supported. Each instance gets its own
disk clone. Changes in one instance do not affect the template or other
instances.
