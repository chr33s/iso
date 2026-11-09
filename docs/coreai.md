# Paravirtualized Core AI for macOS guests (experimental)

> **This weakens your whole Mac.** The private entitlement that loads the
> accelerator devices works only with AMFI relaxed, which turns off
> code-signing enforcement for every process on the host. It may stop
> working in any macOS point release. Use a dedicated development Mac.

macOS 27.3 can forward a macOS guest's Core AI work to the host's GPU and
Neural Engine through paravirtual devices. iso exposes this as an opt-in,
per-instance setting. It suits perception and batch models (YOLO, CLIP,
depth estimation), at about 1 ms extra per call. Design and trust analysis:
[design/paravirtualized-coreai.md](design/paravirtualized-coreai.md),
[trust model](trust-model.md#experimental-paravirtualized-core-ai-off-outside-the-stated-boundary).

## What it unlocks

Without `coreai`, Core AI in a guest runs on the guest's virtual CPUs.
With it:

- **Accelerated on-device models in the sandbox.** Vision and batch models
  run at roughly 50–100% of host speed, up to 7× faster than guest CPU in
  the source measurements on an M4 Max.
- **Local models with no egress.** Inference stays inside the VM, so it
  works under the `offline` security preset.
- **ML-heavy macOS work in a guest**, for example local screen-understanding
  models for an agent using [guest-driven computer use](configuration.md#computer_use),
  test suites for apps built on Core AI, Core ML or Vision, or batch
  image and video processing that never leaves the sandbox.

It does not give fast LLM token generation (about 10% of host speed in the
same tests), Linux guests, VM save/restore, or general GPU access: no Metal
rendering, display acceleration or other GPU use beyond Core AI.

## Requirements

- An Apple Silicon host on macOS 27.3 or later, with AMFI relaxed (reduced
  security in Startup Security Utility and an `amfi_get_out_of_my_way=1`
  boot-arg). iso never changes boot-args or SIP. It reads them and refuses a
  fully secured host.
- A macOS 27.3 or later restore image (`.ipsw`).
- The unreleased `iso-sandbox-coreai` build. It is never in a release
  archive.

## Setup

1. Build and install the experimental runtime next to the normal one:

   ```bash
   scripts/build-iso-sandbox.sh --experimental-coreai
   ```

   This builds with `-DISO_COREAI` (a separate `.build-coreai` scratch path)
   and signs the binary ad hoc with `iso-sandbox/iso-sandbox-coreai.entitlements`,
   which adds `com.apple.private.virtualization`. The binary does not start on
   a fully secured host.

2. Enable it in `~/.iso/config.jsonc` (macOS guests need the vmnet transport):

   ```jsonc
   "network": { "transport": "vmnet" },
   "coreai": {
     "accelerators": ["gpu", "neural_engine"],
     "acknowledge_reduced_host_security": true
   }
   ```

   With `coreai` set, iso uses `iso-sandbox-coreai` from the usual install
   locations; `apple_container.binary` still overrides the path. A release
   build of iso also checks that the binary is signed with the private
   entitlement. Linux images are refused while `coreai` is set.

3. Build a Core AI template. Its guest setup writes the feature flag
   `ParavirtualizedCoreAI/enable_pv_delegate` and its name ends in `-coreai`:

   ```bash
   iso setup --guest macos --coreai --ipsw ~/Downloads/macOS-27.3.ipsw --image mac-coreai
   ```

4. Start an instance:

   ```bash
   iso up --image mac-coreai
   ```

   `up` prints `core ai: gpu, neuralEngine (paravirtualized; host security
   reduced)`. If the guest reports fewer compute kinds than requested, iso
   prints a warning instead and the instance still starts.

## What iso checks

- Nothing is attached unless the instance was created with `coreai`. The
  setting is fixed at creation: changing the configuration later only warns
  until the instance is recreated.
- The owner refuses to boot on a host older than 27.3, on a fully secured
  host, or when the private device classes do not resolve.
- The isolation gate requires exactly the recorded accelerator classes, read
  back from the booted configuration. Any other set fails as host exposure.
- `iso policy effective` lists `coreai` as a relaxation. `iso audit` records
  `mac.coreai.attached`, `mac.coreai.probe` and `host.security.reduced` as
  metadata only.

## Turning it off

Remove `coreai` from the configuration and recreate Core AI instances.
Existing ones keep their setting until then: iso still boots them through
`iso-sandbox-coreai` from its install locations (or refuses, naming it, if
`apple_container.binary` points elsewhere). Restore your host's normal security in
Startup Security Utility and remove the boot-arg.

## Not supported

Linux guests, VM save/restore (see the design's §11), and remote execution
hosts other than as a fully separate, reduced-security host running its own
`iso-sandbox-coreai`.
