# macOS guests with computer use: runtime design

**Status:** Implemented in `iso-sandbox` (runtime) and in `iso` (host CLI,
`iso setup --guest macos`), and qualified at the development bar on one host
(see below).
**Date:** 2026-10-06
**Plan:** [`macos-computer-use-qualification-plan.md`](macos-computer-use-qualification-plan.md)
(gates A–T)
**Evidence this design rests on:**
[`macos-vz-context-experiment.md`](macos-vz-context-experiment.md),
[`macos-computer-use-q0-spike.md`](macos-computer-use-q0-spike.md)

## Scope

`iso-sandbox macos …` adds macOS guests to the existing runtime. A macOS
guest uses the same state root, launchd supervision, vmnet networks, subnet
allocator, control-socket conventions and ownership locks as a Linux sandbox.
It has its own records and commands. A macOS guest does not boot through
`apple/containerization`, which runs Linux only, so it never shares a code
path with Linux VM creation. The Linux sandbox protocol (`protocolVersion`)
does not change.

The computer-use contract is the plan's minimal one: one dedicated desktop,
one pointer, one keyboard, foreground interaction, and pixel observation.

**Platform limit.** Virtualization.framework runs at most two macOS guests
per host at once. A third start fails with `VZErrorDomain` code 6 ("The
maximum supported number of active virtual machines has been reached"),
which `macos start` reports. A template build counts as one. Linux sandboxes
are not affected.

## Shape

```text
 host (trusted)                                 guest macOS VM (untrusted)
 ┌────────────────────────────────────────────┐ ┌──────────────────────────────┐
 │ iso-sandbox macos run <id>   (launchd       │ │ iso-macos-helper (root        │
 │  user/$UID, Background)                     │ │  LaunchDaemon, pre-login)     │
 │  VM on its own serial queue (MacVM)         │ │   vsock 7801: challenge/HMAC  │
 │  VZVirtualMachineView in an ordered-out     │◀┼── hello, enroll, status,      │
 │   window (V5)                               │ │   network, shutdown           │
 │  vsock listener ── MacHelperLink ───────────┼─┤                              │
 │  control socket (0600, owner uid only):     │ │ sshd (key-only, pinned)       │
 │   ping inspect stop status                  │ │ autologin user `iso`          │
 │   cu-session cu-frame cu-act                │ └──────────────────────────────┘
 └────────────────────────────────────────────┘
```

- **Owner topology (Gate D).** The owner is a `user/$UID` launchd job in the
  `Background` session, as Linux sandboxes are today. Its
  `VZVirtualMachineView` sits in an ordered-out window (V5), with
  `automaticallyReconfiguresDisplay = false`. The context experiment
  qualified this at the development bar. A view without a window renders
  nothing and drops pointer input, so frames and pointer actions are refused
  when the view has no window.
- **Queue discipline (Gate A).** One serial queue per VM. Every VZ call,
  including installer creation and start, is made on that queue, and the
  delegate runs there. Each start, install or stop resolves to exactly one
  terminal result. Guest-initiated shutdown (`guestDidStop`) and errors
  (`didStopWithError`) end the owner, so the runtime never reports a stopped
  guest as running.

## State layout

Everything lives under the existing state root:

```text
<root>/macos/templates/<name>/          published only by rename after a full build
  template.json  disk.img  aux.img  hardware-model.bin
<root>/macos/sandboxes/<id>/
  record.json  disk.img  aux.img  machine-id.bin
  helper.key   (0600, set at enrollment)   ssh_host_ed25519.pub (pin)
  live.json  owner.log  launchd.plist  owner.lock  owner.failed
<root>/locks/macos-<id>.lock            mutation guard, as for Linux sandboxes
```

Sandbox identifiers share one namespace with Linux sandboxes, and the subnet
allocator counts both kinds.

## Template build (Gate B, Gate M)

`iso-sandbox macos template build --ipsw <file> --name <name> [--helper <bin>]`
builds a template in `macos/templates/.build-<uuid>`. `--helper` defaults to
the `iso-macos-helper` beside `iso-sandbox`.

1. Load and validate the restore image (`mostFeaturefulSupportedConfiguration`,
   hardware-model support, minimum CPUs and memory).
2. Create the auxiliary storage, a sparse disk and a machine identifier, then
   install with `VZMacOSInstaller` on the VM queue. Progress is logged.
3. First boot with `VZMacGuestProvisioningOptions`: user `iso`, a random
   password that is held only in memory, automatic login, and Remote Login.
   No Setup Assistant interaction is needed.
4. Over SSH (password auth is used only here; see below), install:
   - the helper and its LaunchDaemon;
   - `NOPASSWD` sudo for `iso`, as in Linux guests;
   - sshd set to key-only;
   - sleep, display sleep and the screensaver off, so nothing triggers a
     screen lock;
   - app relaunch at login off;
   - no automatic update download or macOS install (macOS still checks:
     without device management its schedule cannot be turned off);
   - and, last, removal of the SSH host keys, then a scheduled shutdown.

   The account keeps the random build password. It is never stored or
   reused, and password authentication is off.
5. Write `template.json`, recording the build, OS version, the restore
   image's and helper's sha256, and the minimum CPUs and memory. The hardware
   model is in `hardware-model.bin`. Then rename the build directory into
   place. A build
   that fails at any step is deleted and never published. `reconcile` removes
   abandoned `.build-*` directories.

**Accepted trade-off.** The template build's SSH session trusts the guest's
host key on first use. That session runs on a vmnet network created for the
build alone: the build VM is its only peer, so no other VM can answer for the
guest's address. The guest was installed from the operator's IPSW a moment
earlier by the same process. The session ignores the user's ssh
configuration and agent, and forwards nothing. Nothing from that session
reaches a clone. Clones regenerate their host keys, and the
host pins those through the helper (Gate J). Password authentication is off
in every published template.

## Clone identity (Gate L)

`iso-sandbox macos create <id> --template <name>` does the following:

- `clonefile` copies the disk and auxiliary storage (copy-on-write, so
  writes in one clone never reach another);
- generates a new `VZMacMachineIdentifier` and a new locally administered MAC
  address;
- allocates a vmnet subnet.

At first boot, enrollment generates a per-clone helper key, `authorized_keys`
and SSH host keys. No two clones share a machine identifier, MAC address,
helper key, SSH host key or writable disk state.

## Helper channel (Gate I, Gate J)

The helper channel is vsock port 7801, with one JSON object per line. Lines
are capped at 64 KiB, and at most 4 connections may be waiting to
authenticate. The hello must arrive within 10 s of wall-clock time and
enrollment's reply within 120 s. Rejections are logged at most 20 a minute. The host speaks first on every
connection.

```text
host → {"v":1,"type":"challenge","nonce":<32 hex>}
guest→ {"v":1,"type":"hello","boot":<guest boot uuid>,"build":..,"product_version":..,
        "helper_version":..,"enrolled":bool,"mac":<HMAC-SHA256(key, nonce|boot) hex, if enrolled>}
```

**Enrollment** happens only on the first boot of a clone, when both sides say
they are unenrolled:

```text
host → {"type":"enroll","key":<64 hex>,"authorized_key":"ssh-ed25519 …"}
guest→ {"type":"enrolled","ssh_host_key":"ssh-ed25519 …","mac":<HMAC over nonce|boot with the new key>}
```

- The host stores the key in `helper.key` (0600) and pins the SSH host key.
- Like the Linux first-boot pin, this relies on a clone's first boot running
  only template software.
- While the host's record is pending it enrolls whatever hello arrives,
  including one claiming a key: the guest saves its key before the host
  saves the record, so an enrollment interrupted between the two leaves
  exactly that state, and the host has pinned nothing yet. Once the host is
  enrolled, a hello claiming no key is dropped and changes nothing: any
  guest process can make that claim, so it must not be able to disable the
  sandbox. A sandbox whose guest has lost its key never authenticates
  again, so it gets no sessions until it is recreated.
- Only authenticated evidence marks a sandbox `identity_mismatch`: an SSH
  host key reported over the authenticated channel that differs from the
  pin. The owner then refuses SSH details and computer-use sessions.

**Later boots.** The hello must carry a valid MAC. After every accepted
hello, including the first boot's enrollment, the host sends:

- `network` {address, prefix, gateway, dns}: the guest applies a static
  address, so host-only sandboxes work without DHCP.

On demand, the host also sends:

- `status`, on `inspect` and on every `cu-session`: the guest reports its SSH
  host key, which must equal the pin. A session is opened only when it does.
- `shutdown`, from the stop sequence: the guest runs `shutdown -h now`.

The helper runs no other commands. A hello from another guest process
without the key is rejected and cannot replace the accepted connection.
Requests are answered only by the active connection. Replacing a connection
shuts the old one down.

**What the key proves.** The key is readable only by root in the guest, and
the guest user has passwordless sudo. The HMAC therefore keeps out non-root
guest processes, not the agent. An agent with root can impersonate the
helper. All it can reach that way is its own sandbox: it can end its own
sessions, ignore a shutdown (the stop sequence then forces one), or get its
sandbox marked `identity_mismatch`.

The guest boot ID that the helper reports can only invalidate a session,
never validate one. The host-generated `bootId` in `live.json` (new for
every owner) and the VM instance are host-anchored.

## Lifecycle (Gate K)

`stop` runs the same sequence the experiment validated:

1. `requestStop`, then wait 15 s (macOS guests ignored it in every qualification run);
2. helper `shutdown`, then wait 120 s;
3. `VZVirtualMachine.stop()`.

The owner then exits 0. A guest-initiated shutdown or a VM error also ends
the owner. `start --expires-at` enforces a TTL: the owner runs the stop
sequence at the deadline. The forced `stop()` is bounded at 30 s, after which
the owner exits anyway, and that ends the in-process VM. A stop requested
while the VM is still starting is not remembered as done, so a later request
runs the sequence again. A crashed owner is restarted by launchd only after an
abnormal exit. A restarted owner has a new `bootId`, so every earlier session
is refused.

## Computer use (Gates C, E, F, G, H)

Control-socket operations. Clients must be the owning uid.

| Op | Request | Response |
|---|---|---|
| `cu-session` | — | `session`, `binding` {`bootId`, `vmInstance`, `guestBoot`, `helperGeneration`, `width`, `height`} |
| `cu-frame` | `session` | `frame` {`frameId`, `seq`, `width`, `height`, `bootId`, `guestBoot`, `vmInstance`, `sha256`, `timestamp`, `png` (base64)} |
| `cu-act` | `session`, `action`, optional `basedOnFrame` | `ok`, `submitted` (input events handed to the view) |

The CLI (`iso-sandbox macos cu session|frame|act`) writes the PNG to
`--out` and prints the rest.

- **Coordinates (Gate F).** Origin top-left, in framebuffer pixels, within
  `[0,width) × [0,height)`. The geometry is fixed for the life of the VM:
  1920×1200 at 80 ppi, guest scale 1. Coordinates out of range are refused,
  never clamped.
- **Session binding (Gate H).** A session is bound to all of the following,
  and any change refuses the session:
  - the owner `bootId`;
  - the VM instance;
  - the guest boot ID and helper connection generation;
  - the geometry;
  - a `basedOnFrame` from this session's current boot.
- **Frames (Gate C).**
  - Frames come from `cacheDisplay`, scaled to framebuffer pixels.
  - A frame whose per-channel range is 3 or less counts as not observed and
    is refused (blank).
  - Frames are refused when the view has no window.
- **Actions (Gates E, G).** The action types are `move`, `click`
  (left/right/middle, count 1–3), `down`/`up`, `drag` (2–1000 points),
  `scroll`, `key` (key code 0–127 plus a modifier set), and `type` (printable
  ASCII up to 4,096 characters, mapped to US-ANSI key codes).
  - Input is synthesized `NSEvent`s handed to the view. The right and
    middle buttons use `CGEvent`-built events, which are never posted:
    `NSEvent.mouseEvent` cannot set the button number.
  - One action runs at a time. A second concurrent action is refused.
  - Modifiers carry device-dependent bits, without which the view drops them
    (Q0 finding 5).
  - An action that fails part-way releases every button (where the pointer
    is) and every key and modifier it pressed.
  - The response says `submitted`, not `delivered`. The runtime cannot prove
    delivery, so qualification proves it with guest-side oracles.
- **No host side effects.** Nothing is posted to the host event system. The
  owner needs no Screen Recording or Accessibility permission, and never
  activates.

## Effective configuration (Gate O)

`inspect` reports what the VM booted with, read from its configuration
object and the listeners the owner registered:

- displays;
- pointing devices and keyboards;
- the network: the one attachment's vmnet subnet, read from the network
  object, with the mode from the record (vmnet does not expose it);
- storage: each storage device's image path;
- `directoryShares`, `audioDevices`, `serialPorts` and `usbControllers`,
  counted;
- `vsockPorts`: the ports with a registered listener on the one socket
  device;
- `clipboard`: whether there is any console device (the SPICE agent that
  carries a clipboard needs one).

The configuration also has one entropy device. The owner refuses to boot
with any other device, a different device count, or a network attachment
that is not one of its own vmnet networks.

## Host CLI integration

`iso` drives macOS guests through the same backend and state as Linux
instances. The guest kind is recorded twice, so every later command
dispatches without asking the runtime: the image manifest's `platform` is
`darwin/arm64` (its `image_ref` names the runtime template), and the instance
sidecar has `guest_os: "macos"` (absent for Linux, whose records are
unchanged).

- **Setup.** `iso setup --guest macos --ipsw <file> [--image <name>]` calls
  `macos template build --provision <script>` with `MacProvision.script()`,
  then records the template in `images/<name>/apple-image.json` with
  `digest` = `macos:<build>:helper-<sha256>` and `manifest_id` =
  `macos-provision-<sha256>`. The next `iso setup --guest macos` rebuilds the
  image when the restore image or the script changed; the previous template
  is deleted once no image or instance records it, since every boot reads
  the template's hardware model. No kernel,
  maintenance image or Apple `container` service is needed.
- **Provisioning.** The script makes the guest present iso's Linux
  conventions (`/workspace`, `/home/iso`, the `iso` group, `timeout`,
  `AcceptEnv *`, `PATH` through `/etc/zshenv`) and installs the Command
  Line Tools, a pinned GitHub CLI, Claude Code and Codex. Most guest-side
  host code therefore needs no macOS branch.
- **Create and boot.** `macos create … --authorized-key <vm_key.pub>`, then
  `macos start`, then poll `macos inspect` until the helper has enrolled and
  confirmed the pinned host key on this boot (at least five minutes are
  allowed). `IsolationGate.verifyMacEffective` then gates the boot, and the
  pin from the runtime is written to the instance's `known_hosts`. Later
  handoffs gate the same configuration but rely on that pin rather than a
  fresh confirmation, so a helper that is slow or reconnecting does not
  block `iso shell` or `iso exec`; plain status checks use `macos list`,
  which does not ask the helper at all.
- **Everything else.** `stop`, `destroy`, `status`, `list` and the
  filtered-egress proofs dispatch on the sidecar's kind. `resize`, `commit`,
  `restore`, `--disk` and `iso logs` are refused for macOS guests.

## Qualification on this host (development bar)

These results come from `tests/macos-guest-qualify.py` against the runtime,
with gates from the plan. The host is a Mac17,7 (M5 Max) on macOS 27.0.1. The
guest is template `macos27`, macOS 27.0.1 (26A434), built from the
operator's IPSW. The owner is `user/$UID` + `Background`, with the view in an
ordered-out window. The host console was locked throughout.

| Gate | Result | Evidence |
|---|---|---|
| B install/provision | pass | Template built on a dedicated vmnet build network (10.232.91.0/24) and published by rename |
| L clone identity | pass | Two clones: machine IDs, helper keys, SSH host keys, MACs and guest platform UUIDs all differ; separate disk files on the host; a write in A is absent in B |
| I helper channel | pass | The real helper, run as the unprivileged guest user, cannot read the key; its 4 hellos are rejected; the sandbox stays enrolled with the same helper generation and guest boot |
| J SSH enrollment | pass | Strict connect against the pin from the helper; a different valid host key is refused; no TOFU |
| O host exposure (configuration) | pass | Effective configuration has 0 shares, audio, serial or USB, no clipboard, one display, one disk, a vmnet network and vsock port 7801 |
| C framebuffer | pass | 100/100 frames at 1920×1200, token decoded and counter fresh |
| E pointer | pass | 1,000/1,000 random clicks with 0 wrong, missing or off-position, including 100 right clicks; drag to target; scroll in opposite directions; out-of-range input refused |
| G keyboard | pass | Exact text including shifted punctuation, 68/68 key-downs and ups, Cmd-S and Cmd-Opt-Shift chords seen, nothing stuck, Unicode refused |
| P multi-VM | pass | A session from VM A is refused on VM B; A receives all 40 events, 0 leak to B, and a control click on B arrives; each frame carries its own VM's token |
| H frame/action binding | pass | An action based on a current frame is accepted; the old session is refused during and after a guest reboot; a frame from the old boot is refused; a new session works |
| K lifecycle | pass | Guest shutdown ends the owner; host stop takes the guest-helper path; the TTL stops the VM no earlier than its deadline and logs it; SIGKILL leads to a launchd respawn with a new boot ID, the helper reconnects and the old owner is gone |

Run `20261006T154146-5b5c`, all gates in one run on the runtime in this
change (`iso-sandbox` SHA-256 `f16ce982…a534`), with a freshly built template.

Later runs on the same host and template added the remaining gates:

| Gate | Result | Evidence |
|---|---|---|
| O host exposure (guest canaries) | pass | Planted on the host: a file token in `$HOME`, an environment token every runtime call inherits, and a loaded ssh-agent key. None appears in the guest (`/Volumes`, `/Users`, every process environment, `ssh-add -l`). Only `apfs`, `autofs` and `devfs` mounts; the pasteboard does not cross either way; of ten host vsock ports only 7801 accepts; one physical disk, no camera, no audio |
| D background owner | pass | 50 clicks reach the guest fixture while the host's pointer and frontmost app are unchanged, the owner is never frontmost and has no window on screen; physical HID input during a run voids and repeats it. The host was locked. Visible console: not offered. Fast user switching: not supported (the owner runs in the user's launchd domain) |
| Q application coverage | pass, 35/35 | AppKit (button, field, editor, checkbox, radio, popup, slider, scroll, context menu, sheet, child window, drag and drop, menu shortcut and menu bar), SwiftUI (button, field, toggle, picker, slider, editor), WKWebView (field, button, checkbox, select, link) and Electron 44.5.1 (field, button, checkbox, select) fixtures; Terminal, TextEdit (save), Calculator, Finder (new folder), System Settings (Dark appearance) and Safari (typed URL reaching a guest listener), each checked outside the app. The first click into an inactive window only activates it; one such retry is allowed and counted (WebKit field). System Settings' sidebar did not take synthesized clicks in that run, so the pane was opened by URL before the Dark click |
| S performance | recorded | Frame request p50/p95 152/164 ms (6.5 frames/s through the CLI); action acknowledged p50/p95 14/16 ms; input observed by the guest fixture p50/p95 43/51 ms (host receipt over SSH, an upper bound); click to visible change p50 379 ms; owner CPU 0.3 % idle. The 250 ms frame target is met; the 50 ms input target is met at p50 and missed by 1 ms at p95 |
| R login and system UI | pass | Reboot to the login window (name and password mode) and log in as a second local user through computer use; drive that user's first-login Setup Assistant (11 steps, from Accessibility to Get Started) to the desktop; lock with Control-Command-Q and unlock with the password; open and cancel the Apple-menu restart dialog; allow a TCC prompt (Terminal reading Desktop) and see the command succeed; no update prompt; with the guest helper booted out, `macos stop` still stops the VM (forced, 16.5 s). Boot progress is not observable: sessions need the helper, which starts after boot |
| T soak | pass | 8 hours, two guests (`20261006T223607-6279`): 72,798 clicks, 242,660 keystrokes, 3,033 frames, 100 app launch/quit cycles, 20 stop/start cycles and 5 owner SIGKILLs. 0 wrong or missing clicks, 0 lost or misplaced keystrokes, 0 cross-VM events, 0 actions accepted on a stale boot, 0 stale or foreign frames, 0 driver errors; owner RSS 54–343 MiB with no growth between the second and last hour; no leaked owner process |
| T host sleep and wake | pass | `tests/macos-guest-sleepwake.py` (`20261007T104119-4bc6`): the host entered sleep (the power log's "Software Sleep") and woke; network traffic woke it after 2 s each time, before the scheduled wake. The owner, its boot, the guest boot and the helper connection survived; SSH, clicks, typed text and frames with the fixture's token worked before and after, through both the session from before the sleep and a new one |
| S scaling | pass | One VM: frames p50/p95 196/206 ms; two VMs at once: 205/215 ms. A third macOS guest is refused by the platform (VZErrorDomain 6) |

`iso` itself is checked end to end by `tests/macos-iso-e2e.py` (25/25 on
this host). Before that script existed, the same checks were run by hand
with an image from `iso setup --guest macos` (about 25 minutes): `up` (22 s), `exec` with the
workspace at `/workspace` and Claude Code, Codex, `gh` and `git` present,
`status`, `list`, `stop` (17 s), `start` with agent bootstrap (23 s) and
`destroy`; and with `egress: "filtered"` and `api.github.com` allowed, the
allowed host answered through the forwarded proxy, another host got 403 from
the companion, a direct connection had no route, DNS resolved nothing, and
`status`, `stop` and `start` re-proved readiness.

## Not covered

- **Unicode text input beyond ASCII,** display resizing, and multiple
  displays.
- **More than two macOS guests per host:** a Virtualization.framework limit.
- **Boot progress through computer use:** sessions bind to an authenticated
  guest helper, a LaunchDaemon that starts once macOS has booted.
- **GUI applications under filtered egress:** they do not read the proxy
  variables and have no route.
- **Long host sleep:** with Wi-Fi active the host woke after 2 s; a longer
  sleep (for example on a laptop with the lid closed) was not exercised.
