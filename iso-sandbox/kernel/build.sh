#!/bin/bash
# Derived from apple/containerization 0.54.0 kernel/build.sh
# (Copyright © 2025-2026 Apple Inc. and the Containerization project authors,
# Apache-2.0). Modified by chr33s: arm64 only, a native toolchain, a fixed
# build identity, and a check that the desktop options survive olddefconfig.
# SPDX-License-Identifier: Apache-2.0
#
# Runs inside the build container: /kernel holds source.tar.xz, config-arm64
# (already merged with desktop.config) and receives vmlinux-desktop.
set -euo pipefail
mkdir -p /kbuild
tar -xf /kernel/source.tar.xz -C /kbuild --strip-components=1
cp /kernel/config-arm64 /kbuild/.config
cd /kbuild
export KBUILD_BUILD_TIMESTAMP="1970-01-01 00:00:00 UTC" KBUILD_BUILD_USER=iso KBUILD_BUILD_HOST=iso
make ARCH=arm64 olddefconfig
missing=0
while IFS= read -r line; do
  case "$line" in CONFIG_*=*) ;; *) continue ;; esac
  grep -qxF "$line" .config || { echo "olddefconfig dropped $line" >&2; missing=1; }
done < /kernel/desktop.config
[ "$missing" -eq 0 ]
make ARCH=arm64 -j"$(nproc)" LOCALVERSION=-iso-desktop Image
cp arch/arm64/boot/Image /kernel/vmlinux-desktop
cp .config /kernel/final.config
gcc --version | head -1 > /kernel/toolchain.txt
