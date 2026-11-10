#!/usr/bin/env bash
set -euo pipefail

# Build iso's desktop kernel: the kernel `iso-sandbox` boots for Linux
# sandboxes created with `--display virtio` (docs/design/linux-desktop-virtio-gpu.md
# §5). Inputs are pinned: the Linux source tarball by SHA-256, the base
# configuration (apple/containerization 0.54.0 kernel/config-arm64) by
# SHA-256, the options in iso-sandbox/kernel/desktop.config, and the build
# image in iso-sandbox/kernel/Dockerfile by digest, with its toolchain from
# a dated snapshot of the Ubuntu archive. The build identity
# (timestamp, user, host, local version) is fixed, so the same inputs and
# toolchain give the same vmlinux.
#
# Usage:
#   scripts/build-desktop-kernel.sh [--source linux-6.18.5.tar.xz] OUT_DIR
#     --source  use a local copy of the source tarball instead of fetching
#               it from cdn.kernel.org (checked against the same SHA-256)
#
# Writes OUT_DIR/vmlinux-desktop, its configuration, and its corresponding
# source (linux-6.18.5.tar.xz, vmlinux-desktop.input.config), and prints the
# kernel's SHA-256, which must be in
# KernelPin.desktopAllowed (iso-sandbox Layout.swift) for `iso-sandbox init
# --desktop-kernel` to accept it. Needs Apple `container` and an Apple
# Silicon Mac.

KVER=6.18.5
SOURCE_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz"
SOURCE_SHA256=189d1f409cef8d0d234210e04595172df392f8cb297e14b447ed95720e2fd940
BASE_CONFIG_SHA256=dedb03de6d686534efbca3a90bac304721e818bd96bc421b4d2213724a4e260b

source_tarball=""
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            sed -n '4,24p' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        --source)
            source_tarball="$2"
            shift 2
            ;;
        -*)
            echo "error: unknown option $1" >&2
            exit 1
            ;;
        *)
            [[ -z "${out}" ]] || { echo "error: more than one OUT_DIR" >&2; exit 1; }
            out="$1"
            shift
            ;;
    esac
done
[[ -n "${out}" ]] || { echo "error: OUT_DIR is required" >&2; exit 1; }

scripts="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${scripts}/.." && pwd)"
kernel_dir="${repo}/iso-sandbox/kernel"
base_config="${repo}/iso-sandbox/.build/checkouts/containerization/kernel/config-arm64"
if [[ ! -f "${base_config}" ]]; then
    swift package --package-path "${repo}/iso-sandbox" resolve --force-resolved-versions
fi

check_sha() {
    local got
    got="$(shasum -a 256 "$1" | cut -d' ' -f1)"
    if [[ "${got}" != "$2" ]]; then
        echo "error: $1 has sha256 ${got}, expected $2" >&2
        exit 1
    fi
}

mkdir -p "${out}"
work="$(mktemp -d "${TMPDIR:-/tmp}/iso-desktop-kernel.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

if [[ -n "${source_tarball}" ]]; then
    cp "${source_tarball}" "${work}/source.tar.xz"
else
    curl --fail --location --proto '=https' --tlsv1.2 -sS -o "${work}/source.tar.xz" "${SOURCE_URL}"
fi
check_sha "${work}/source.tar.xz" "${SOURCE_SHA256}"
check_sha "${base_config}" "${BASE_CONFIG_SHA256}"

# The base configuration with each fragment option replacing any setting of
# the same option.
python3 -I - "${base_config}" "${kernel_dir}/desktop.config" "${work}/config-arm64" <<'PY'
import re, sys
base, fragment, out = sys.argv[1:]
options = [l.strip() for l in open(fragment) if l.startswith("CONFIG_")]
names = {o.split("=", 1)[0] for o in options}
kept = []
for line in open(base):
    m = re.match(r"^(?:# )?(CONFIG_[A-Za-z0-9_]+)(?:=| is not set)", line)
    if m and m.group(1) in names:
        continue
    kept.append(line)
open(out, "w").write("".join(kept) + "\n".join(options) + "\n")
PY
cp "${kernel_dir}/desktop.config" "${kernel_dir}/build.sh" "${work}/"

image="iso-desktop-kernel-build:$(shasum -a 256 "${kernel_dir}/Dockerfile" | cut -c1-12)"
container build -t "${image}" -f "${kernel_dir}/Dockerfile" "${kernel_dir}"
container run --rm --cpus 8 --memory 8g -v "${work}:/kernel" "${image}" /bin/bash /kernel/build.sh

install -m 0644 "${work}/vmlinux-desktop" "${out}/vmlinux-desktop"
install -m 0644 "${work}/final.config" "${out}/vmlinux-desktop.config"
# The corresponding source (GPL-2.0): the exact tarball and the merged
# configuration it was built from.
install -m 0644 "${work}/source.tar.xz" "${out}/linux-${KVER}.tar.xz"
install -m 0644 "${work}/config-arm64" "${out}/vmlinux-desktop.input.config"
echo "toolchain: $(cat "${work}/toolchain.txt")"
echo "sha256: $(shasum -a 256 "${out}/vmlinux-desktop" | cut -d' ' -f1)  ${out}/vmlinux-desktop"
