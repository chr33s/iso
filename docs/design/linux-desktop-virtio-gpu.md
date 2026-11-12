# Linux-guest computer use through a virtio-gpu display

**Status:** Implemented (2026-11-10); the remaining questions are in §13. The
checks and the spike in §3 ran on 2026-11-10 against the pinned
dependencies. The pinned Kata kernel lacks the drivers (§5), so `desktop`
sandboxes boot a second, iso-built kernel. Display, input, capture,
guest access, `wait` and the live view were run against the implementation
on one host, the integration suite's `display` phase passed on the pinned
kernel, and an image built by `iso setup --profile desktop` booted and was
driven through `iso` (§13).
**Date:** 2026-11-10
**Target:** `iso-sandbox` (VM configuration, owner, device inventory), the
guest kernel pin, the Ubuntu `desktop` image profile, and `iso`
(configuration, isolation gate, bootstrap)
**Builds on:** [guest-driven computer use](guest-driven-computer-use.md),
[screen sync](computer-use-screen-sync.md),
[live view](computer-use-live-view.md),
[trust model](../trust-model.md)
**Chosen over:** an in-guest `voxl` helper, whose upstream check did not
pass, and the in-guest helper of the
[Linux computer-use sketch](linux-computer-use-sketch.md), which stays the
fallback (§12)

## 1. Summary

Give a Linux VM a real display device and drive it from the host the way
macOS guests are driven today. The VM gets a
`VZVirtioGraphicsDeviceConfiguration` scanout, a USB keyboard and a USB
absolute pointer. The owner renders the VM's display in a
`VZVirtualMachineView` and injects input as `NSEvent`s into it, as
`MacScreen` already does. It captures frames by reading the view's
framebuffer surface, which `MacScreen` does not do today (§6). The guest
runs an ordinary display server on `/dev/dri/card0` and reads input from
`/dev/input`.

Nothing in the guest captures, encodes or injects. Pixels and input travel
through the hypervisor's own devices, so no guest-authored bytes become a
host data path for them. H.264 for the live view comes from VideoToolbox in
the owner, so there is no x264 and no GPL binary in the image.

An agent in the guest reaches its display through the existing
guest-driven computer-use channel (vsock 7802, MCP server in the guest),
extended from macOS guests to Linux guests. Host `cu` callers use the same
owner surface.

The cost is a guest kernel iso builds and pins itself: neither the pinned
kernel nor containerization's reference config has the drivers (§3).

## 2. Goals and non-goals

**Goals**

- An agent in a Linux guest can take frames and send pointer and keyboard
  actions to its own VM's display, with the same MCP tool names, binding
  and refusal contract as macOS guests.
- Host `cu` commands, `wait_for_screen` and the live view work for Linux
  guests through the code the macOS path already has.
- No guest capture or input helper, no third-party encoder, no GPL
  component.
- A VM without the `desktop` profile is unchanged: same kernel decision
  (§5), same device inventory, same isolation-gate report.

**Non-goals**

- GPU acceleration in the guest. virtio-gpu here is a 2D scanout;
  rendering is in software (llvmpipe), as in the sketch.
- Audio.
- Multiple displays or runtime resizing.
- Sharing the Linux and macOS guest images. The two share the owner's
  screen code and the MCP tool names only.

## 3. Gate: checks and spike

### Checks (2026-11-10, read from the pinned sources)

Nothing was booted for these. Where the spike below later confirmed or
contradicted a verdict, the verdict says so.

| Item | Found | Verdict |
|---|---|---|
| Adding devices to a Linux VM | `containerization` 0.54.0 has `VZInstanceExtension.configureVZ(_:allocator:storageDeviceCount:mountsByID:)` (`VZVirtualMachineInstance.swift:148`), called on the finished `VZVirtualMachineConfiguration` just before `validate()` | **Pass.** The extension can set `graphicsDevices`, `keyboards` and `pointingDevices` |
| Reaching that hook from `LinuxContainer` | `LinuxContainer` builds its `VMConfiguration` without `extensions` (`LinuxContainer.swift:794`); only `LinuxPod` forwards them. `VirtualMachineManager` is a one-method protocol, `create(config:)`, and `StandardVMConfig.configuration.extensions` is a public `var` | **Pass with a shim.** An iso `VirtualMachineManager` wraps `VZVirtualMachineManager` and appends the extension in `create(config:)`. An upstream change forwarding `extensions` from `LinuxContainer.Configuration` would remove the shim |
| Capture | `MacScreen` renders a `VZVirtualMachineView` and captures with `cacheDisplay(in:to:)` (`MacScreen.capture()`). `VZVirtualMachineView` displays any VZ graphics device, including virtio-gpu | **Does not carry over.** The view displays the guest, but `cacheDisplay` returns black for it (K3) |
| Input | `MacScreen` sends `NSEvent`s into the view; VZ forwards them to the VM's USB pointer and keyboard. Linux takes USB HID through xHCI and `usbhid` | **Carries over** (K4) |
| Devices in the container | The guest's `/sbin/init` runs as a container; its default mounts put devtmpfs on `/dev` (`LinuxContainer.swift:545`), so `/dev/dri/card0` and `/dev/input/event*` would be visible | **Pass** under `vmexec` (K2). The cgroup device rules of an OCI runtime are not checked |
| Device inventory | `VMDevices` (`Devices.swift`) rejects any graphics, USB, keyboard or pointing device on a Linux VM | **Change needed** (§6) |
| Pinned kernel | The embedded config of `vmlinux-6.18.56-208-debug` (sha256 `98a1005f…`, the Kata 4.3.1 kernel, [backends.md](../backends.md)) has `CONFIG_DRM`, `CONFIG_USB_SUPPORT`, `CONFIG_INPUT_EVDEV` and `CONFIG_VIRTIO_INPUT` all unset | **Fails.** No display or input driver |
| containerization's reference kernel | `kernel/config-arm64` (Linux 6.18.5) has `CONFIG_DRM=y` and `CONFIG_INPUT_EVDEV=y`, but `CONFIG_DRM_VIRTIO_GPU` and `CONFIG_USB_SUPPORT` unset | **Fails** as shipped; a starting point for §5 |

Taken together: the framework allows this, the owner's input code carries
over, its capture code does not, and the pinned kernel lacks the drivers.

### Spike (2026-11-10)

A standalone probe booted a Linux VM the way the owner does
(`VZVirtualMachineManager`, `LinuxContainer`, `/sbin/init`, all
capabilities, default mounts, no network) and added the §4 devices through
the shim.

- Host: one Mac, macOS 27.2, containerization 0.54.0.
- Kernel: Linux 6.18.5 from containerization's `kernel/` with the §5
  options.
- Guest: Ubuntu 24.04 with systemd, Xorg 21.1.12 `modesetting` and
  libinput. Not an iso image.
- Contexts: a terminal, and a launchd agent in `user/$UID` with
  `LimitLoadToSessionType` `Background`.
- Harness: `experiments/linux-virtio-gpu-probe/` on the
  `worktree-spike-linux-virtio-gpu` worktree. It is not committed.

| Step | Pass condition | Result |
|---|---|---|
| K1. Kernel | A 6.18 arm64 build from containerization's config plus the §5 options boots the current `vminit` and guest image unchanged, and passes the existing integration suite | **Partial.** The kernel boots `vminit` 0.54.0 and a systemd Ubuntu guest, with and without the display devices. iso's guest image and the integration suite were not run on it |
| K2. Display | With the shim adding a 1920×1200 virtio-gpu scanout, `/dev/dri/card0` appears in the container and a display server shows a test pattern in a host `VZVirtualMachineView` | **Pass.** `card0-Virtual-1` is connected with 1920×1200 preferred. Xorg starts as root with no seat manager. A `modetest` pattern and an X root fill both reach the host view |
| K3. Capture | `cacheDisplay` returns the test pattern at 1920×1200, and `DamageGrid` sees a change when the guest draws | **Fails as written; passes with a surface read.** `cacheDisplay` returns black. Reading the IOSurface behind the view returns 1920×1200 BGRA with exact colours, and a red fill then a blue fill each read back. `DamageGrid` was not run |
| K4. Input | An `NSEvent` click and key press in the view arrive as evdev events in the guest and as X or Wayland input at the expected coordinates | **Pass.** Clicks at (400, 300), (1500, 900) and (1919, 1199) arrive as evdev absolute events and as X root coordinates within 0.5 px. `a` and Return arrive as evdev `KEY_A` and `KEY_ENTER` and as X keycodes 38 and 36 |
| K5. Headless | K2–K4 pass in the owner as a launchd user agent, with the view in an ordered-out `NSWindow`, as the [process-context experiment](macos-vz-context-experiment.md) showed for macOS guests (V5) | **Pass for the probe** as the launchd agent with an ordered-out window. The owner itself was not run |

The VM's live inventory with the devices, read as `VMDevices` reads it:
`graphics=1 usbControllers=0 socket=1 directorySharing=1`. The guest sees
the keyboard and pointer on a USB bus, but VZ reports no USB controller.

The kernel's fbcon draws nothing on the scanout; the first frame comes
from the display server.

### Capture methods

Every method on the same frame (an X root window filled red), per window
placement. The ordered-out column gave the same results in both contexts.

| Method | Visible window | Ordered in, off every screen | Ordered out |
|---|---|---|---|
| `cacheDisplay` | black | black | black |
| `CALayer.render(in:)` | black | black | black |
| `screencapture -l` | frame | fails | frame in 7 of 8 attempts |
| ScreenCaptureKit | frame | fails (`SCStreamErrorDomain` −3811) | frame |
| IOSurface read | frame | frame | frame |

`cacheDisplay` was also black on the framebuffer subview directly, after a
forced display, and 3 s later.

**Cause of the black capture.** The guest's XRGB8888 framebuffer leaves the
unused byte at 0. VZ passes it through to a BGRA IOSurface, and Core
Animation's CPU renderer, which `cacheDisplay` and `render(in:)` use,
treats those pixels as transparent. The layer is not opaque and has a black
background, so the result is opaque black.

- Filling `/dev/fb0` with red and the unused byte at `0x00` gives a surface
  pixel of `0x00ff0000` and a black `cacheDisplay`. The same fill with
  `0xFF` gives `0xffff0000` and a red `cacheDisplay`.
- A control view whose layer's contents is an IOSurface made by the probe
  behaves the same way: `cacheDisplay` shows its alpha-`0xFF` half and not
  its alpha-`0x00` half, and the window server shows both.

So `cacheDisplay` is content-dependent for a Linux guest, not always black:
it would show whichever pixels a desktop writes with `0xFF`. Xorg at depth
24 and `modetest` both write 0.

**The surface read**, measured in every run:

- VZ rotates between surfaces: two IDs alternate while the guest redraws,
  and three or more appear over a run.
- No torn frame in about 1,700 reads per run, taken while the guest made
  about 5,000 full-screen fills.
- A read taken when a guest command returns is often the previous frame.
  The new frame arrived 0–53 ms later.
- Before a display server starts, the surface exists and is black.

**Not tested:** window-server capture without Screen Recording access (the
preflight check returned true in both contexts on this host), a macOS
guest, a desktop's real mix of alpha bytes, a rootless display server,
reboot identity, and timing.

### What still gates the work

- The rest of K1: iso's guest image and the integration suite on the new
  kernel. If it fails, fall back to the sketch.
- K3's `DamageGrid` half and K5 in the owner, which need the §6 capture
  change first.

## 4. VM configuration

For an instance with the `desktop` profile only, a `VZInstanceExtension`
in `iso-sandbox` adds:

- `VZVirtioGraphicsDeviceConfiguration` with one
  `VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)`.
  The geometry matches `MacDisplay` and the sketch, so coordinates mean
  the same thing on both guest families.
- `VZUSBKeyboardConfiguration`.
- `VZUSBScreenCoordinatePointingDeviceConfiguration`.

The shim manager (§3) appends the extension; `Owner` passes the shim
instead of the bare `VZVirtualMachineManager`. The extension is a value
built from the instance record's display mode, never from guest data.

## 5. Guest kernel

iso builds, publishes and pins its own kernel for this. Options it adds to
containerization's `config-arm64`:

- `CONFIG_DRM_VIRTIO_GPU=y`
- `CONFIG_USB_SUPPORT=y`, `CONFIG_USB=y`, `CONFIG_USB_PCI=y`,
  `CONFIG_USB_XHCI_HCD=y`, `CONFIG_USB_XHCI_PCI=y`
- `CONFIG_USB_HID=y` (with the existing `CONFIG_HID_GENERIC=y`)
- whatever the rest of K1 shows iso's guest needs from the Kata kernel and
  containerization's config lacks

The spike built Linux 6.18.5 with exactly the first three items and passed
K2–K5 on it (§3).

Decision (2026-11-10): **two kernels.**

| | One kernel for every VM | A second kernel for `desktop` VMs |
|---|---|---|
| Pins | Replace `98a1005f…` in `KernelPin.allowed` | Add one; select by display mode |
| Attack surface | DRM and USB code in every guest kernel, reachable only through devices the VM does not have | Unchanged for non-desktop VMs |
| Maintenance | One build, one qualification | Two builds, two qualifications, a selection path that must not fail open |

iso uses **two kernels**: a non-desktop VM keeps the qualified kernel, and
the selection is a closed enum on the instance record (`DisplayMode`). Either way the kernel becomes an iso release artifact with a
`PROVENANCE.md` entry, a reproducible build from a pinned source tarball
and config, and the same SHA-256 check `KernelPin` applies today.
Publishing a kernel is a new release artifact, and fetching it is a new
outbound URL at setup, both on the stop-and-confirm list.

## 6. Owner and device inventory

- **Inventory.** `VMDevices` gets an expected inventory per display mode,
  a closed enum (`headless`, `virtioDisplay`), not a boolean.
  `virtioDisplay` expects exactly one virtio graphics device with one
  1920×1200 scanout, one USB keyboard and one USB screen-coordinate
  pointer, and no USB controller: VZ reports none for these devices (§3).
  Everything else is checked as today. A headless instance still rejects
  all of them.
- **Screen.** `MacScreen`'s input, damage and wait code moves to a
  guest-neutral type that takes a `VZVirtualMachineView`, a key mapping
  and a capture method. The macOS owner and the Linux owner both use it.
- **Capture.** For a Linux guest the type reads the IOSurface that VZ sets
  as the `contents` of the layer of its framebuffer subview
  (`_VZFramebufferView`, a private class), and ignores the alpha byte.
  - It looks up `layer.contents` on every capture, because VZ rotates
    surfaces.
  - It needs no window on screen and no host permission.
  - If no IOSurface-backed layer is found, capture fails with a typed
    error. It does not fall back to `cacheDisplay`, which would return a
    frame missing every pixel the guest wrote with alpha 0.
  - The macOS path keeps `cacheDisplay` until the surface read is tested
    against a macOS guest (§10).
  - Window-server capture is rejected: it needs Screen Recording access,
    which the owner does not have today.
- **Keys.** The macOS path sends Mac virtual key codes into the view, and
  VZ maps them to the guest keyboard. With a USB keyboard VZ produces HID
  usages; the guest's keymap turns them into keysyms. The guest image pins
  a US layout so `CUKeys.events(forText:)` stays correct (§10).
- **Live view.** `LiveViewEncoder` encodes the frames the screen type
  captures, so it needs no change of its own for Linux guests. It stays
  opt-in.

## 7. Guest image

In the sketch's `desktop` profile, replacing its Xvfb:

- Xorg with the `modesetting` driver on `/dev/dri/card0` and `libinput`, or
  a Wayland compositor. Xorg is the default because the sketch's fixtures
  and the existing X tooling assume it.
- `openbox` and the sketch's fonts and browser source.
- No capture, input or encoder packages, and no third-party download for
  the display path.
- A US keyboard layout set in the X configuration, not taken from the
  host.

Xorg as root with no seat manager works under the container's
`/sbin/init` (§3, K2). Whether to run it rootless, through logind or
`seatd`, is open (§10).

## 8. Guest access

Guest-driven computer use (vsock 7802, `computer_use.guest_access`) is
macOS-only today. This extends it to Linux guests with the `desktop`
profile:

- The owner registers the 7802 listener for a Linux `desktop` VM under the
  same opt-in, binding, frame-rate cap and host-hold rules.
- The guest's MCP server speaks the existing `GuestCUProtocol`; the Linux
  image ships it the way the macOS image ships its helper.
- The isolation gate accepts 7802 for a Linux VM only with the opt-in set,
  as for macOS.

Accepting a vsock listener on a Linux VM is a new listener, on the
stop-and-confirm list. Today vsock 7802 is the macOS guest-to-host
listener and is not accepted for Linux VMs; this changes that for the
`desktop` profile only.

## 9. Trust-model delta

| Item | Change |
|---|---|
| VM devices | `desktop` VMs gain virtio-gpu, a USB keyboard and a USB pointer, which the guest sees on a USB bus; headless VMs unchanged |
| Kernel | A new iso-built kernel, pinned by SHA-256 (§5) |
| Guest → host data for pixels and input | None new: the owner reads the surface VZ renders the hypervisor's display device into. The owner parses nothing guest-authored; it copies a fixed-size pixel buffer |
| Private framework structure | Capture depends on `VZVirtualMachineView` keeping an IOSurface-backed layer under it. A macOS update can break capture; it then fails closed (§6) and a test catches it (§11) |
| Guest → host channel | vsock 7802 for Linux `desktop` VMs with the opt-in (§8), same protocol and limits as macOS |
| Host permissions | None new. The owner already renders a `VZVirtualMachineView` for macOS guests |
| Image content | Distribution packages only for the display path; no third-party binary |
| Guest-controlled load | A guest that redraws constantly costs damage tracking and, with a viewer connected, encoding at the frame-rate cap, as for macOS |

The new hypervisor-exposed devices are a larger guest-reachable surface in
Virtualization.framework (virtio-gpu, xHCI). That surface is Apple's and
is the same one every graphical Linux VM on macOS uses.

## 10. Open questions

- One kernel or two (§5), and who maintains the kernel build.
- Whether to propose forwarding `extensions` from
  `LinuxContainer.Configuration` upstream, so the shim can go.
  containerization issue 480 and pull request 569 ask for a graphics
  device; both were open on 2026-11-10, and the pull request adds no input
  devices or kernel options.
- Whether the macOS path should move to the surface read too, so both
  guest families capture one way. It needs a run against a macOS guest.
- Whether to report the private-structure dependency to Apple and ask for
  a supported way to read a VM's framebuffer.
- Whether a frame returned after an action needs a settle time or a wait
  for the surface to change, given the 0–53 ms lag (§3).
- Whether the display server runs as root or rootless (§7).
- Whether an OCI runtime's cgroup device rules allow `/dev/dri` and
  `/dev/input`, or whether `iso-sandbox` must add them.
- Key mapping: whether VZ's NSEvent-to-HID translation preserves every key
  `CUKeys` sends, and how non-US text should be typed.
- How the profile is selected, shared with the sketch.

## 11. Testing and acceptance

- The spike steps K1–K5 as an integration phase on macOS 27+ Apple
  Silicon, with K3 using the surface read.
- A capture tripwire in that phase: the guest fills the screen with a
  known colour and alpha 0, and the test fails if the surface lookup
  misses or the frame is not that colour. Removing the surface lookup must
  make it fail.
- A unit test that the surface conversion ignores the alpha byte.
- The sketch's Q0 cells (rendered window, absolute click, keyboard, reboot
  identity) through host `cu` commands and through the guest MCP server.
- `wait_for_screen` and the live view against a Linux `desktop` VM, with
  the screen-sync and live-view tests run for both guest families.
- Device-inventory tests for both display modes, and a fault in
  `scripts/swift-host-fault-injection.py` that lets a headless VM accept a
  graphics device, which a test must catch.
- The isolation gate's report for a headless Linux VM is unchanged.

## 12. Alternatives considered

**In-guest `voxl` (rejected 2026-11-10).** The proposal was to ship
`tembo/voxl` in the image as the sketch's guest helper, behind an MCP
adapter, with no host channel. Its upstream check, read from the repository
and the v0.3.4 release and not run, did not pass:

- **License.** voxl's code is MIT, but the binary links x264 (GPL-2.0).
  Its README says a voxl binary, and anything that bundles one, is
  distributed under the GPL.
- **Release artifact.** v0.3.4 has one asset, a `.crate`. There is no
  Linux binary and no checksum file. The image build would need a Rust
  toolchain and the x264, libyuv, opus and libpulse development packages.
- **Interface.** Screenshots and waits are HTTP, but input goes over a
  WebSocket. The viewer page and `/ws` cannot be disabled.
- **Scope.** Host `cu` commands and the live view were non-goals for Linux
  guests there. This design provides both through the macOS path's code.

**The sketch's own in-guest helper (fallback).** The
[sketch](linux-computer-use-sketch.md) runs Xvfb and XTEST in the guest
and needs a capture and input helper written for it. It needs no kernel
change. It remains the fallback if the rest of K1 fails (§3).

## 13. Implementation (2026-11-10)

Where the built system is described now:

- **Boundary:** [trust model: Linux guests with a display](../trust-model.md#linux-guests-with-a-display)
  (devices, kernel pin, frame capture, binding, guest access, image,
  release).
- **Image and use:** [images and profiles: Linux desktop images](../images-and-profiles.md#linux-desktop-images).
- **Kernel build and pins:** `scripts/build-desktop-kernel.sh`,
  `iso-sandbox/kernel/`, [PROVENANCE.md](../../PROVENANCE.md) and
  [THIRD_PARTY_LICENSES.md](../../THIRD_PARTY_LICENSES.md).
- **Code:** `iso-sandbox` `LinuxDisplay.swift`, `LinuxDesktop.swift`,
  `ComputerUse/FramebufferSurface.swift`, `Devices.swift`; host
  `Sources/IsoHost/Runtime/LinuxDisplay.swift`; tests and faults
  `linux-display-*` in `scripts/swift-host-fault-injection.py`.

Decisions made while building (2026-11-10):

- The kernel and `iso-cu-mcp` ship in the verified release archive and are
  installed beside `iso-sandbox` by `install.sh` and `iso update`, so they
  reach a host without a second download at setup. Each release also
  publishes the kernel's corresponding source (GPL-2.0),
  `iso-<tag>-vmlinux-desktop-source.tar.gz`, checksummed and attested with
  the archive.
- The owner of a display sandbox runs AppKit's main loop, which the view
  needs to draw; `iso-sandbox run` chooses the loop from the record before
  the owner starts. The owner then checks that choice against the record
  it loads and refuses to boot a display sandbox under the plain dispatch
  loop (`Owner.requireLoop`).
- Firefox comes from Mozilla's apt repository: Ubuntu's `firefox` and
  `chromium` are snap shims, which do not run in iso guests. Only `firefox`
  is taken from that repository; its other packages are pinned so apt never
  installs them.
- iso images mask udev, so Xorg runs the evdev driver on a configuration
  written at boot that names the hypervisor's USB devices, not libinput.
- `iso-cu-mcp` is the same `GuestCUMCP` as `iso-macos-helper cu-mcp`,
  built with the Swift Static Linux SDK, so one implementation serves both
  guest families (it replaced a first Python port).
- A uniform frame is refused only from the macOS `viewCache` capture, where
  it is how a missing framebuffer looks; from the surface it is what the
  guest drew.

Qualified on one macOS 27.2 host: the integration suite's `display` phase
(`tests/run-integration.sh --only display` with `ISO_TEST_DESKTOP_KERNEL`)
and its `iso` phase pass, the kernel build is reproducible, and macOS guests
re-passed `tests/macos-guest-qualify.py` after the shared-code refactor.
With the surface lookup removed, every rendering check fails, as §11's
tripwire requires.

**Open.**

- Headless sandboxes keep the qualified kernel, so the other integration
  phases exercise it, not the desktop kernel.
- The release and candidate workflows' new steps (the `container` service,
  the SDK and kernel-source downloads) have not run in CI; the local
  `build-release.py` dry run produced and verified both archives.
- §10's remaining questions: the surface read for macOS guests, reporting
  the private-structure dependency, settle time after actions (the MCP
  server's `settle_ms` waits for damage to settle), rootless Xorg, OCI
  cgroup device rules, and non-US text.
