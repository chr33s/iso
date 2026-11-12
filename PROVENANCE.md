# Provenance and Swift history

isolate is a Swift-based derivative of coop, originally developed by
Trail of Bits and contributors: https://github.com/trailofbits/coop.
The project retains the upstream Apache 2.0 `LICENSE` unchanged.

The last upstream revision merged before the full Swift host port was
`6ac6c2c5e739aadae3f6735f4f3348f2f2671d30` (the second parent of
`aefc996ec7ae4c1836d602c1192c054245587ba3`). Its tracked distribution
contains `LICENSE` and no `NOTICE` file. isolate's `NOTICE` consolidates
the derivative attribution; it does not replace upstream file notices.

Git history has been pruned to focus on the Swift implementation.
This history rewrite does not alter the licensing or attribution of
upstream-derived material. The new root is the tree of the first complete
Swift host port, formerly `994614756369f14555f5a495b24c05a1de74354e`,
with legal notices added. Later Swift-era commits retain their ordering,
messages, author identities and timestamps, with rewritten commit identities
and attribution added to applicable files. No historical Rust host commit
is required to build, test or use this branch.

Files translated or adapted from upstream carry modification notices.
JSON files use adjacent `.license` files because JSON has no comment syntax.
New fork-specific implementations do not acquire upstream-derivation notices
merely because they implement new features in this project. LLVM libFuzzer
remains unmodified with its own license and exceptions.

## Desktop guest kernel

`scripts/build-desktop-kernel.sh` builds the kernel `desktop` instances boot
([design](docs/design/linux-desktop-virtio-gpu.md) §5) from:

- Linux 6.18.5, `linux-6.18.5.tar.xz` from cdn.kernel.org, sha256
  `189d1f409cef8d0d234210e04595172df392f8cb297e14b447ed95720e2fd940`
  (GPL-2.0);
- apple/containerization 0.54.0 `kernel/config-arm64`, sha256
  `dedb03de6d686534efbca3a90bac304721e818bd96bc421b4d2213724a4e260b`
  (Apache-2.0), with the options in `iso-sandbox/kernel/desktop.config`;
- `iso-sandbox/kernel/build.sh`, derived from that release's
  `kernel/build.sh` (Apache-2.0; notice in the file), run in
  `iso-sandbox/kernel/Dockerfile` on the guest images' pinned Ubuntu 24.04
  base, with the toolchain from the Ubuntu archive snapshot dated in that
  file.

With gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1) the resulting
`vmlinux-desktop` has sha256
`c8a260548646e0863547d2207c24e12b8444ed7731b5b24222908fd154e1201c`, pinned in
`KernelPin.desktopAllowed` (`iso-sandbox/Sources/IsoSandboxCore/Layout.swift`).
Release archives carry it as `vmlinux-desktop`, with its configuration
and source pins under `third-party/vmlinux-desktop/`, and publish its
corresponding source as `iso-<tag>-vmlinux-desktop-source.tar.gz`; the
release build refuses a kernel whose sha256 is not pinned. The script runs
the build image under Apple `container` on a Mac or Docker on arm64 Linux
(`--engine`); the release workflows use the latter and require the pinned
hash (`--pinned`).
