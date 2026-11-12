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
#   scripts/build-desktop-kernel.sh [--source linux-6.18.5.tar.xz]
#                                   [--engine container|docker] [--pinned] OUT_DIR
#     --source  use a local copy of the source tarball instead of fetching
#               it from cdn.kernel.org (checked against the same SHA-256)
#     --engine  what builds and runs the build image: Apple `container`
#               (the default on macOS) or `docker` (the default elsewhere)
#     --pinned  fail unless the kernel built is one KernelPin.desktopAllowed
#               pins (the release workflows; omit it to build a kernel to pin)
#
# Writes OUT_DIR/vmlinux-desktop, its configuration, and its corresponding
# source (linux-6.18.5.tar.xz, vmlinux-desktop.input.config), and prints the
# kernel's SHA-256, which must be in
# KernelPin.desktopAllowed (iso-sandbox Layout.swift) for `iso-sandbox init
# --desktop-kernel` to accept it. Needs an arm64 host: an Apple Silicon Mac
# with Apple `container`, or arm64 Linux with Docker. GitHub's hosted macOS
# runners cannot start the `container` build VM, so the release workflows
# build the kernel on an arm64 Linux runner
# (.github/workflows/desktop-kernel.yml).

KVER=6.18.5
SOURCE_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz"
SOURCE_SHA256=189d1f409cef8d0d234210e04595172df392f8cb297e14b447ed95720e2fd940
BASE_CONFIG_SHA256=dedb03de6d686534efbca3a90bac304721e818bd96bc421b4d2213724a4e260b

source_tarball=""
engine=""
pinned=0
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            sed -n '4,32p' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        --source)
            source_tarball="$2"
            shift 2
            ;;
        --engine)
            engine="$2"
            shift 2
            ;;
        --pinned)
            pinned=1
            shift
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
if [[ -z "${engine}" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then engine=container; else engine=docker; fi
fi
case "${engine}" in
    container | docker) ;;
    *) echo "error: --engine must be container or docker" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    arm64 | aarch64) ;;
    *) echo "error: the desktop kernel is built natively on arm64" >&2; exit 1 ;;
esac

scripts="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${scripts}/.." && pwd)"
kernel_dir="${repo}/iso-sandbox/kernel"
base_config="${repo}/iso-sandbox/.build/checkouts/containerization/kernel/config-arm64"
if [[ ! -f "${base_config}" ]] && command -v swift >/dev/null; then
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

if [[ ! -f "${base_config}" ]]; then
    # No Swift toolchain (the Linux runner): the same file from the
    # containerization revision iso-sandbox/Package.resolved pins. Its
    # SHA-256 is checked below either way.
    revision="$(python3 -I - "${repo}/iso-sandbox/Package.resolved" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next(p["state"]["revision"] for p in pins if p["identity"] == "containerization"))
PY
)"
    git init --quiet "${work}/containerization"
    git -C "${work}/containerization" fetch --quiet --depth 1 \
        https://github.com/apple/containerization.git "${revision}"
    git -C "${work}/containerization" show FETCH_HEAD:kernel/config-arm64 >"${work}/base-config-arm64"
    base_config="${work}/base-config-arm64"
fi

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
"${engine}" build -t "${image}" -f "${kernel_dir}/Dockerfile" "${kernel_dir}"
# Apple `container` runs the build in a VM that must be sized; Docker on
# Linux shares the host's processors and memory.
limits=()
if [[ "${engine}" == container ]]; then limits=(--cpus 8 --memory 8g); fi
"${engine}" run --rm ${limits[@]+"${limits[@]}"} -v "${work}:/kernel" "${image}" /bin/bash /kernel/build.sh

install -m 0644 "${work}/vmlinux-desktop" "${out}/vmlinux-desktop"
install -m 0644 "${work}/final.config" "${out}/vmlinux-desktop.config"
# The corresponding source (GPL-2.0): the exact tarball and the merged
# configuration it was built from.
install -m 0644 "${work}/source.tar.xz" "${out}/linux-${KVER}.tar.xz"
install -m 0644 "${work}/config-arm64" "${out}/vmlinux-desktop.input.config"
echo "toolchain: $(cat "${work}/toolchain.txt")"
built="$(shasum -a 256 "${out}/vmlinux-desktop" | cut -d' ' -f1)"
echo "sha256: ${built}  ${out}/vmlinux-desktop"
if [[ "${pinned}" -eq 1 ]]; then
    # The quoted 64-hex strings of KernelPin.desktopAllowed, as
    # scripts/build-release.py reads them.
    layout="${repo}/iso-sandbox/Sources/IsoSandboxCore/Layout.swift"
    if ! sed -n '/package static let desktopAllowed/,/\]/p' "${layout}" | grep -qF "\"${built}\""; then
        echo "error: vmlinux-desktop (sha256 ${built}) is not a pinned desktop kernel" >&2
        exit 1
    fi
fi
