# Paravirtualized Core AI accelerators for macOS guests

**Status:** Implemented (2026-11-09), unqualified: Gate AI and the §13
open questions need a 27.3 host. Experimental; never in the release archive.
User guide: [`docs/coreai.md`](../coreai.md).
**Target:** `iso-sandbox` (owner, `MacConfig`, `MacTemplates`, helper
protocol), `iso` (configuration, `policy effective`, audit, `up` reporting),
`scripts/build-release.py` (exclusion), `scripts/build-iso-sandbox.sh`.
**Builds on:** [macOS runtime design](macos-guest-computer-use.md) (Gates
C–H, O, R), [guest-driven computer use](guest-driven-computer-use.md),
[trust model](../trust-model.md), [Xcode security
settings](../xcode-security-settings.md).
**Source finding:** itspdfu on X, 2026-11-08 — macOS 27.3 adds paravirtualized
Core AI (GPU + Neural Engine) for Mac VMs behind private API, a restricted
entitlement and guest feature flags.

## 1. Summary

A macOS guest gets the host's GPU and Neural Engine for Core AI through two
new Virtualization.framework accelerator devices,
`_VZMacCoreAIDeviceConfiguration` and
`_VZMacNeuralEngineDeviceConfiguration`, attached with the private
`-[VZVirtualMachineConfiguration _setAcceleratorDevices:]`. In the guest a
feature flag (`ParavirtualizedCoreAI/enable_pv_delegate`) turns the
paravirtualized delegate on; `ComputeUnitKind.availableKinds` then lists
`gpu` and `neuralEngine`.

iso exposes this as an **opt-in, per-template, experimental** capability:

- a separate host build, `iso-sandbox-coreai`, signed with
  `com.apple.private.virtualization`, never shipped in the release archive;
- a `coreai` configuration object that must also acknowledge the reduced
  host security the private entitlement requires;
- a template variant whose guest setup writes the feature flag;
- `MacConfig` attaching exactly the requested accelerators and the Gate O
  device check, effective-config record, `iso policy effective` and audit
  all reporting them;
- a handshake probe so `iso up` says whether acceleration actually landed.

Everything else — default build, default templates, `provider-only` — is
unchanged and never sees the private API.

## 2. Goals and non-goals

**Goals**

- Let a user who runs a 27.3 development host enable GPU/ANE Core AI in a
  macOS guest with one config key and one template rebuild.
- Fail closed: no accelerator device unless requested; refuse to boot if
  the attached set differs from the requested set; refuse on hosts or
  guests older than 27.3; refuse unless the host's weakened state is
  explicitly acknowledged in config.
- Make the relaxation visible everywhere iso reports boundaries: `iso
  policy effective`, `iso audit`, `MacEffectiveConfig`, the `up` banner.
- Keep the release build free of private entitlements and private
  selectors so the signed, attested artifact is unaffected.

**Non-goals**

- Linux guests (Apple Containerization has no equivalent path).
- VM save/restore. The host-side `ParavirtualizedCoreAIHost/
  enable_save_restore` flag is tracked in §11 but not implemented.
- LLM token generation performance. The paravirtualized path re-maps
  large KV-cache buffers per token and ran Qwen3-0.6B at ~10% of host
  speed in the source tests; this spec optimizes for perception/batch
  models (YOLO, CLIP, Depth Anything class, 50–100% of host).
- Relaxing AMFI for the user. iso detects the host state and refuses; it
  never changes boot-args or SIP.

## 3. Background

Core AI in a VM today runs on the guest's virtual CPUs. 27.3's
paravirtualized devices forward Core AI work to the host's GPU (a new
`PVAIDevice` in the guest) and to the existing ANE accelerator device,
which gains Core AI support. The source measured up to 7× over guest CPU on
an M4 Max, ~1 ms added latency per inference call for the VM crossing.

Requirements, from the finding:

| Side | Requirement |
| --- | --- |
| Host | macOS 27.3; VM app entitled `com.apple.security.virtualization` **and** `com.apple.private.virtualization`; the latter loads only with AMFI relaxed |
| Host | `_setAcceleratorDevices:` on `VZVirtualMachineConfiguration` with `_VZMacCoreAIDeviceConfiguration`, `_VZMacNeuralEngineDeviceConfiguration` |
| Guest | macOS 27.3; `/Library/Preferences/FeatureFlags/Domain/ParavirtualizedCoreAI.plist` → `enable_pv_delegate = {Enabled = true}`; reboot |

## 4. Trust-model cost

This is the first iso feature that **weakens the host** to strengthen the
guest. It must be documented as such in `trust-model.md`:

1. **AMFI relaxation.** A private entitlement on a non-Apple binary
   requires reduced security / `amfi_get_out_of_my_way`-class boot-args.
   That disables code-signing enforcement for every process on the host,
   not only iso-sandbox. Enhanced Security entitlements on the other iso
   executables still apply but are no longer verified by AMFI.
2. **New shared-hardware surface.** The guest now talks to the host GPU
   and ANE drivers through a paravirtual device. Bugs in that path are a
   guest→host escape class the current design explicitly excludes (Gate
   O: no shares, no audio, no USB).
3. **Private API.** Selectors and classes may change or vanish in any
   point release; iso resolves them at runtime and treats absence as
   "unavailable", never as a crash.

Consequence: `coreai` is reported as a **relaxation** by `iso policy
effective`, and the `up` banner for such an instance carries a one-line
warning. `trust-model.md` gets a section "Experimental: paravirtualized
Core AI (off; outside the stated boundary)".

## 5. Configuration

New top-level object in `~/.iso/config.jsonc`, macOS guests only:

```jsonc
"coreai": {
  // Which accelerators to attach. Both, one, or omit the key for none.
  "accelerators": ["gpu", "neural_engine"],
  // Required true. iso refuses to start a Core AI instance without it,
  // because the host must run with AMFI relaxed for the private entitlement.
  "acknowledge_reduced_host_security": true
}
```

Decoding (`ConfigDecoding.swift`, alongside `computer_use`):

- `rejectUnknown(allowing: ["accelerators", "acknowledge_reduced_host_security"])`.
- `accelerators`: non-empty array of `"gpu" | "neural_engine"`, duplicates
  rejected. Empty object or omitted key → off.
- `acknowledge_reduced_host_security` must be `true` when `accelerators`
  is present; otherwise `FieldError("needs \"acknowledge_reduced_host_security\": true")`.
- Refused outside macOS guests (image kind check at instance create, same
  path that refuses `iso logs` for macOS guests).
- `config.example.jsonc` and `ConfigTemplate.swift` gain a commented block.

New type in `IsoConfig.swift`:

```swift
package struct CoreAIConfig: Sendable, Equatable {
  package enum Accelerator: String, Sendable, CaseIterable { case gpu, neuralEngine = "neural_engine" }
  package var accelerators: [Accelerator]   // non-empty when enabled
  package var acknowledged: Bool
}
```

Fixed at instance create, like `computer_use`: stored on
`MacSandboxRecord.coreAI: MacCoreAI?` (accelerators as strings, plus the
template variant used), nil when off.

## 6. Host build: `iso-sandbox-coreai`

- New entitlements file `iso-sandbox/iso-sandbox-coreai.entitlements` =
  `iso-sandbox.entitlements` + `com.apple.private.virtualization`.
- `scripts/build-iso-sandbox.sh` (the script `docs/backends.md` describes)
  gains `--experimental-coreai`: builds the same Swift package with
  `-DISO_COREAI` and signs with the coreai entitlements, installing the
  binary as `iso-sandbox-coreai` next to `iso-sandbox`.
- `scripts/build-release.py` **never** includes the coreai entitlements or
  binary; `verify()` additionally asserts that no release executable
  carries any `com.apple.private.*` entitlement.
- `iso` selects the binary: when the effective instance config has
  `coreai`, `apple_container.binary` resolves to `iso-sandbox-coreai` (or
  a configured path); if the file is missing or its signature lacks the
  private entitlement (`codesign -d --entitlements -`), `iso up` fails
  with "Core AI requires the experimental iso-sandbox-coreai build; see
  docs/coreai.md".
- Host preflight in `iso-sandbox-coreai` before building the VM:
  - `ProcessInfo.operatingSystemVersion >= 27.3`;
  - `csrutil status` / `sysctl kern.bootargs` show reduced security or
    AMFI relaxed; if the host is fully secured the private entitlement
    will not have loaded and `_setAcceleratorDevices:` fails — report that
    plainly instead of a generic VZ error.
- All private-API code is under `#if ISO_COREAI`; the default build
  contains no reference to the private classes or selectors.

## 7. `MacConfig` changes

New file `MacOS/MacAccelerators.swift` (`#if ISO_COREAI`):

```swift
package enum MacAccelerators {
  package static func isAvailable() -> Bool  // classes + selector resolve
  package static func apply(_ kinds: [CoreAIConfig.Accelerator],
                            to c: VZVirtualMachineConfiguration) throws
  package static func attached(_ c: VZVirtualMachineConfiguration) -> [String]
}
```

- `apply` instantiates `_VZMacCoreAIDeviceConfiguration` for `gpu` and
  `_VZMacNeuralEngineDeviceConfiguration` for `neural_engine` via
  `NSClassFromString`, and calls `_setAcceleratorDevices:` with
  `perform(NSSelectorFromString(...))`. Any unresolved class or selector
  → `SandboxError("Core AI accelerators unavailable on this host")`.
- `attached` reads `_acceleratorDevices` back (same runtime lookup) and
  returns class names; `[]` when the selector is absent.

`MacConfig.make` gains `coreAI: CoreAIConfig?`; after the existing devices
and before `validate()`, `if let coreAI { try MacAccelerators.apply(...) }`.

`requireOnlyExpectedDevices` gains the accelerator check and becomes
`requireOnlyExpectedDevices(_:expectedAccelerators:)`:

- attached accelerator count must equal the requested count (0 when off);
- each attached class must be one of the two known classes;
- in the default build `attached` is always `[]`, so a zero expectation
  holds and nothing changes.

`MacEffectiveConfig` gains `accelerators: [String]`, read back from the
booted configuration, not restated from the record; the owner's Gate O
comparison fails if record and configuration disagree.

## 8. Template and guest

- `MacTemplates.build` gains `coreAI: Bool`. When true, the template name
  is suffixed (`<name>-coreai`) and the manifest records
  `coreai_feature_flag: true`, so a plain template is never mistaken for
  an enabled one.
- `guestSetupScript(provision:coreAI:)` appends, when enabled:

  ```sh
  # Paravirtualized Core AI delegate (macOS 27.3+). Experimental.
  mkdir -p /Library/Preferences/FeatureFlags/Domain
  defaults write /Library/Preferences/FeatureFlags/Domain/ParavirtualizedCoreAI \
    enable_pv_delegate -dict Enabled -bool true
  ```

  The script already ends in a clean shutdown, which satisfies the
  required restart.
- Template build refuses an IPSW whose `productVersion < 27.3` when
  `coreAI` is set, with the version in the message.
- `iso up` refuses `coreai` on a template whose manifest lacks the flag
  ("rebuild the template with `iso setup --guest macos --coreai`").

CLI: `iso setup --guest macos --coreai --ipsw … --image mac-coreai`.

## 9. Probe, reporting and audit

**Helper protocol.** `HelperProtocol` gains a request
`coreAIStatus → { availableKinds: [String], delegateEnabled: Bool }`. The
guest helper implements it by reading
`ComputeUnitKind.availableKinds` and the feature-flag plist. The owner
calls it once after enrollment.

**`iso up`** prints one line for a Core AI instance:

```
core ai: gpu, neuralEngine (paravirtualized; host security reduced)
```

or, if the probe shows fewer kinds than requested, a warning and the
kinds found — the instance still starts, because the guest is otherwise
sound.

**`iso policy effective`** lists `coreai` under relaxations with the
accelerators, the template variant and the acknowledgement.

**`iso audit`** records, metadata only:

- `mac.coreai.attached` at boot: accelerator classes, template, build id;
- `mac.coreai.probe` after enrollment: available kinds, delegate state;
- `host.security.reduced` once per boot when the preflight detects the
  relaxed host, so the audit stream shows the weakened window even for
  instances that never used Core AI.

## 10. Policy interactions

- Security presets are unchanged; `coreai` is orthogonal to network
  posture and is allowed under all three, including `offline`, which is
  its natural home (local perception models with no egress).
- Because it is a relaxation, `security.revoked_grant_ids` does not apply
  (it is config, not a grant); turning it off is removing the key, and
  existing instances keep their recorded setting until recreated.
- `iso host up` (remote Macs): the remote agent's `iso-sandbox-coreai`
  and its preflight run there; the acknowledgement travels in the
  effective config, and the remote host's reduced state is audited on the
  remote.

## 11. Save/restore (tracked, not implemented)

The host flag `ParavirtualizedCoreAIHost/enable_save_restore` makes the
accelerator advertise save/restore support. iso has no VM snapshot feature
today. When it does (warm template clones, fast resume), this flag is a
prerequisite for snapshotting Core AI instances; without it, save fails
and iso must fall back to shutdown. Record in `docs/design/index.md` as a
follow-up.

## 12. Testing and qualification

**Unit (default build, no 27.3 needed)**

- `ConfigDecoding`: accepts both accelerators, rejects unknown kinds,
  duplicates, empty array, and missing acknowledgement.
- `requireOnlyExpectedDevices`: zero expected and `attached == []` passes;
  non-zero expected in the default build fails (accelerators unavailable).
- `MacEffectiveConfig.from` carries `accelerators: []`.
- `build-release.py verify()` fails on a fixture binary carrying a
  `com.apple.private.*` entitlement.

**Qualification (27.3 host and guest, dev Mac, `--experimental-coreai`)**
Add to `macos-computer-use-qualification-plan.md` as Gate AI:

| Check | Pass |
| --- | --- |
| Preflight on a fully secured host | refused with the AMFI message, no VM created |
| Boot with `["gpu","neural_engine"]` | `MacEffectiveConfig.accelerators` has both classes; Gate O passes |
| Boot with `["gpu"]` | exactly one class attached |
| Guest probe | `availableKinds` ⊇ `{gpu, neuralEngine}`, `delegateEnabled` |
| Plain template + `coreai` | refused before boot |
| Perf smoke | a public YOLO/CLIP Core AI model in the guest ≥ 3× guest-CPU time; record host ratio |
| Audit | three events above present, values absent |

## 13. Open questions

1. Does an **ad hoc** signature with `com.apple.private.virtualization`
   load under reduced security, or is a Developer ID / development
   certificate required? Determines whether `--experimental-coreai` can
   stay ad hoc like the rest of iso.
2. Is `_setAcceleratorDevices:` on `VZVirtualMachineConfiguration` (as
   reported) or on `VZMacPlatformConfiguration`? Runtime lookup covers
   both; confirm which before writing `attached`.
3. Does `_VZMacNeuralEngineDeviceConfiguration` exist on 27.2 hosts (the
   finding calls it "existing")? If so, `neural_engine` alone may not
   need 27.3 on the host, only the guest flag — but keep a single ≥27.3
   floor until measured.
4. Does the attached GPU device require `VZMacGraphicsDeviceConfiguration`
   to remain, or is display-less operation possible for headless
   instances (`macos-vz-context-headless-experiment-spec.md`)?
5. Will Apple remove the feature flags or gate the devices behind a
   public API in 27.4+? Plan for `MacAccelerators.isAvailable()` to go
   false silently and for the docs to say "may stop working".

## 14. Rollout

1. Config schema, record field, `requireOnlyExpectedDevices` extension,
   unit tests, `trust-model.md` section — mergeable without a 27.3 host.
2. `MacAccelerators`, `#if ISO_COREAI`, build script flag, entitlements
   file, release-verify guard.
3. Template variant, guest flag, helper probe, `up`/`policy`/`audit`
   reporting.
4. Gate AI qualification on a 27.3 dev Mac; publish `docs/coreai.md`
   with the setup steps and the trust-model warning.

## 15. References

- itspdfu, X, 2026-11-08: paravirtualized Core AI in macOS 27.3 VMs
  (private API, entitlements, feature flags, benchmarks).
- `iso-sandbox/Sources/IsoSandboxCore/MacOS/MacConfig.swift` (Gate O
  device check, `MacEffectiveConfig`).
- `iso-sandbox/Sources/IsoSandboxCore/MacOS/MacTemplates.swift`
  (`guestSetupScript`).
- `Sources/IsoConfiguration/ConfigDecoding.swift` (`computer_use` pattern).
- `docs/xcode-security-settings.md`, `scripts/build-release.py`.

## 16. Implementation notes

Where the implementation settles what the draft left open:

- **Signature check.** A release build of iso reads the runtime's
  entitlements with the Security framework (no `codesign` subprocess);
  debug builds check only the `macos-coreai` feature that the `-DISO_COREAI`
  build advertises, as for companions (`CompanionSignature.verifyForRelease`).
- **Binary selection.** With `coreai` set, the default runtime name becomes
  `iso-sandbox-coreai` for every command; `apple_container.binary` overrides
  it. Starting an instance recorded with Core AI uses the experimental build
  even after `coreai` is removed. Linux images are refused while `coreai` is
  set (§5).
- **Guest probe retries.** The owner re-probes every 5 s (up to a minute)
  until the report covers the requested kinds; `up` waits up to 20 s for such
  a report after SSH is ready, then warns with what it has.
- **Effective config.** `MacEffectiveConfig` also carries
  `hostSecurityReduced` from the owner's preflight; the gate requires it for
  any attached accelerator.
- **Records.** `MacSandboxRecord.coreAI` holds the accelerators; the
  template (recorded alongside, name ending in `-coreai`, template manifest
  `coreAIFeatureFlag`) is the variant. iso's image manifest carries it in
  `manifest_id` (suffix `-coreai`), which `verifyImage` checks against the
  runtime template. iso's sidecar keeps the same under
  `coreai`, which `iso policy effective` reports for an instance.
- **Guest probe.** The 27.2 SDK's Core AI module has no `ComputeUnitKind`,
  so the helper reports `cpu` plus kinds whose paravirtual IOKit devices are
  present (`PVAIDevice` for `gpu`, `H11ANEIn` for `neuralEngine`), and reads
  the feature-flag plist for `delegateEnabled`. Gate AI confirms the class
  names; switch to `ComputeUnitKind.availableKinds` once the SDK has it.
- **Probe timing.** The owner probes on every authenticated helper
  connection and reports only the current guest boot's answer.
