#!/usr/bin/env bash
set -euo pipefail

# Build iso-cu-mcp, the computer-use MCP server iso installs in Linux
# `desktop` images (docs/design/linux-desktop-virtio-gpu.md §8): the
# iso-sandbox package's IsoCUMCP target, cross-compiled for arm64 Linux with
# the Swift Static Linux SDK (musl, statically linked) and stripped.
#
# Usage:
#   scripts/build-iso-cu-mcp.sh OUT
#     OUT  the path to write the binary to; the SDK's SBOM goes to
#          OUT.sbom.spdx.json
#   scripts/build-iso-cu-mcp.sh --check
#     only checks the toolchain and installs the SDK if it is missing; exits
#     non-zero when this host cannot build iso-cu-mcp
#
# The SDK must match the toolchain (mise.toml's `swift`); it is pinned below
# by URL and SHA-256 and installed with `swift sdk install` when missing.
# Needs an Apple Silicon Mac with the swift.org toolchain mise installs.

SWIFT_VERSION=6.4.0
SDK_ID="swift-${SWIFT_VERSION}-RELEASE_static-linux-0.1.0"
SDK_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/static-sdk/swift-${SWIFT_VERSION}-RELEASE/${SDK_ID}.artifactbundle.tar.gz"
SDK_SHA256=47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e

case "${1:-}" in
    -h | --help | "")
        sed -n '4,18p' "$0" | sed -E 's/^# ?//'
        [[ -n "${1:-}" ]] && exit 0 || exit 1
        ;;
esac
out="$1"

scripts="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "${scripts}/../iso-sandbox" && pwd)"

toolchain="$(swift --version 2>/dev/null | head -1)"
if [[ "${toolchain}" != *"swift-${SWIFT_VERSION%.0}-RELEASE"* && "${toolchain}" != *"swift-${SWIFT_VERSION}-RELEASE"* ]]; then
    echo "error: the Static Linux SDK ${SDK_ID} needs the swift.org ${SWIFT_VERSION} toolchain; found: ${toolchain}" >&2
    exit 1
fi
if ! swift sdk list 2>/dev/null | grep -qxF "${SDK_ID}"; then
    swift sdk install "${SDK_URL}" --checksum "${SDK_SHA256}"
fi
[[ "${out}" == --check ]] && exit 0

build=(swift build --package-path "${pkg}" -c release --force-resolved-versions
    --swift-sdk aarch64-swift-linux-musl --scratch-path "${pkg}/.build-linux"
    --product iso-cu-mcp -Xswiftc -gnone -Xlinker -s)
"${build[@]}"
bin="$("${build[@]}" --show-bin-path)/iso-cu-mcp"

tmp="$(mktemp "$(dirname "${out}")/.iso-cu-mcp.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
cp "${bin}" "${tmp}"
chmod 0755 "${tmp}"
mv -f "${tmp}" "${out}"
trap - EXIT
# The statically linked SDK components (musl, Foundation, ICU and others)
# with their licenses, for the release bundle's third-party notices.
bundle_dir="${HOME}/Library/org.swift.swiftpm/swift-sdks/${SDK_ID}.artifactbundle"
if [[ -f "${bundle_dir}/sbom.spdx.json" ]]; then
    install -m 0644 "${bundle_dir}/sbom.spdx.json" "${out}.sbom.spdx.json"
else
    echo "error: no SBOM for ${SDK_ID} at ${bundle_dir}" >&2
    exit 1
fi
echo "Built ${out} ($(shasum -a 256 "${out}" | cut -d' ' -f1))"
