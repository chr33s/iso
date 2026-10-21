# Xcode security settings

Security build-setting and entitlement decisions for iso, from an audit
adapted from Xcode's `audit-xcode-security-settings` skill (2026-10-21). iso
is built with SwiftPM, not an Xcode project. Each Xcode setting is therefore
mapped to what SwiftPM and `codesign` can express: entitlements, the hardened
runtime and the build triple.

Shipped executables: `iso`, `iso-proxy`, `iso-egress`, `iso-sandbox`,
`iso-macos-helper`. Each is signed with the hardened runtime. `iso-macos-helper`
runs inside macOS guests. `iso-ci` (built from source, unsigned) and
`IsoPolicyBench` (not shipped) are out of scope.

## Enabled settings

These entitlements live in
[`scripts/enhanced-security.entitlements`](../scripts/enhanced-security.entitlements).
[`iso-sandbox/iso-sandbox.entitlements`](../iso-sandbox/iso-sandbox.entitlements)
repeats them alongside `com.apple.security.virtualization`.
`scripts/build-release.py` refuses a bundle whose binaries lack any of these
keys.

- `com.apple.security.hardened-process`
- `com.apple.security.hardened-process.enhanced-security-version-string` to `"2"`
- `com.apple.security.hardened-process.hardened-heap`
- `com.apple.security.hardened-process.dyld-ro`
- `com.apple.security.hardened-process.platform-restrictions-string` to `"2"`:
  no first-party code uses raw Mach IPC or `dlopen`. Virtualization.framework
  and containerization use XPC.
- `com.apple.security.hardened-process.checked-allocations`: hardware memory
  tagging, enforced on M5 or later Macs. It also applies on plain `arm64`.
- `com.apple.security.hardened-process.checked-allocations.soft-mode`: memory
  tagging violations write a simulated crash report instead of terminating.
  Remove soft mode for enforcement once crash reports from M5 hosts have been
  reviewed.
- Hardened runtime (`codesign --options runtime`): already in place before
  this audit.

Plain `swift build` development binaries are linker-signed only and carry
none of these entitlements.

## Disabled settings

None.

## Deferred

Settings considered but not yet enabled. Revisit them later.

- `ENABLE_POINTER_AUTHENTICATION` (arm64e): the mise-pinned Swift 6.4.0
  toolchain cannot link arm64e, because its `usr/lib/swift/macosx` runtime
  stubs have only `x86_64,arm64` slices. With the default build system,
  `swift build --triple arm64e-…` silently emits `arm64`. Xcode 27's toolchain
  (`xcrun swift build --arch arm64 --arch arm64e`) builds a working universal
  binary. Adopting it means moving the release builds to Xcode's toolchain and
  updating `BUILD.json`'s `architecture` and `verify-candidate.py`.
  `#if arch(arm64)` still holds on arm64e.
- Strict memory safety (`.strictMemorySafety()` as an error) on targets other
  than `IsoConfiguration`: SwiftPM's nearest equivalent to the extra
  diagnostic settings. Each `unsafe` finding needs review.
- `com.apple.security.hardened-process.checked-allocations.enable-pure-data`
  and `checked-allocations.no-tagged-receive`: optional memory tagging
  sub-options, not part of the default set.

## Not applicable

- Compiler, static analyzer and clang-tidy warnings (`GCC_WARN_*`,
  `CLANG_WARN_*`, `CLANG_ANALYZER_SECURITY_*`, `CLANG_TIDY_*`): no first-party
  C, C++ or Objective-C ships. Vendored C in dependencies isn't configured here,
  and `fuzz/libfuzzer` is fuzz-only.
- `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` and
  `checked-allocations.enforce-checked-pointer-arithmetic-overflow`: iOS and
  watchOS only.
- `ENABLE_C_BOUNDS_SAFETY` and `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS`: no
  first-party C or C++ ships.
