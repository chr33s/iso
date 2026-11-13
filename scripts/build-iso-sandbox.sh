#!/usr/bin/env bash
set -euo pipefail

# Build iso-sandbox, the macOS VM runtime that iso's `apple-container`
# backend drives, iso-macos-helper, the agent it installs in macOS guest
# templates, and iso-cu-mcp, the MCP server `desktop` Linux images get
# (scripts/build-iso-cu-mcp.sh, with the Swift Static Linux SDK), and install
# them into PREFIX/bin. PREFIX/bin must be owned by
# you or root and not writable by others except the wheel or admin group.
# Both are signed ad hoc with the hardened runtime and the Enhanced Security
# entitlements: iso-macos-helper with scripts/enhanced-security.entitlements,
# iso-sandbox with iso-sandbox.entitlements, which adds virtualization. No sudo.
#
# Usage:
#   scripts/build-iso-sandbox.sh [--experimental-coreai] [--require-cu-mcp | --skip-cu-mcp] [PREFIX]
#     PREFIX defaults to ~/.local/opt/iso-sandbox
#
# iso-cu-mcp needs the swift.org toolchain and the Static Linux SDK. On a host
# without them (Xcode's own Swift, or no network to fetch the SDK) it is
# skipped with a warning and any earlier PREFIX/bin/iso-cu-mcp is removed:
# everything but `desktop` images works without it. --require-cu-mcp fails
# instead (release builds); --skip-cu-mcp never builds it.
#
# iso finds <PREFIX>/bin/iso-sandbox at the default PREFIX; otherwise set
#   "apple_container": {"binary": "<PREFIX>/bin/iso-sandbox"}
# See docs/backends.md. Requires Xcode 27 and Swift 6.4 on an Apple Silicon Mac.
#
# --experimental-coreai instead builds iso-sandbox-coreai (with -DISO_COREAI)
# and signs it with iso-sandbox-coreai.entitlements, which adds the private
# com.apple.private.virtualization. That entitlement loads only on a host with
# AMFI relaxed, which weakens every process on the host; never released. See
# docs/coreai.md.

coreai=0
cu_mcp=auto
prefix=""
for arg in "$@"; do
    case "${arg}" in
        -h | --help)
            sed -n '4,32p' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        --experimental-coreai) coreai=1 ;;
        --require-cu-mcp) cu_mcp=require ;;
        --skip-cu-mcp) cu_mcp=skip ;;
        -*)
            echo "error: unknown option ${arg}" >&2
            exit 1
            ;;
        *)
            if [[ -n "${prefix}" ]]; then
                echo "error: more than one PREFIX" >&2
                exit 1
            fi
            prefix="${arg}"
            ;;
    esac
done
prefix="${prefix:-${HOME}/.local/opt/iso-sandbox}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "error: iso-sandbox needs an Apple Silicon Mac" >&2
    exit 1
fi
if [[ "${prefix}" != /* ]]; then
    echo "error: PREFIX must be an absolute path" >&2
    exit 1
fi

scripts="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "${scripts}/../iso-sandbox" && pwd)"
build=(swift build --package-path "${pkg}" -c release --force-resolved-versions)
if ((coreai)); then
    # A separate scratch path: the default build never sees -DISO_COREAI.
    build+=(--scratch-path "${pkg}/.build-coreai" -Xswiftc -DISO_COREAI)
fi
"${build[@]}"
bin="$("${build[@]}" --show-bin-path)"

# Another writer could swap the binary iso runs; check before `install -d`, which would silently
# reset an existing directory's mode.
if [[ -e "${prefix}/bin" ]]; then
    # iso's run-time rule (`untrusted_dir`) minus its sticky-directory exception: group-writable
    # only for wheel (0) or admin (80), who can already sudo (Homebrew's bin is admin-writable).
    read -r bin_uid bin_gid bin_mode < <(stat -L -f '%u %g %Lp' "${prefix}/bin")
    if [[ ! -d "${prefix}/bin" ]] || [[ "${bin_uid}" != "$(id -u)" && "${bin_uid}" != 0 ]] ||
        ((8#${bin_mode} & 8#002)) ||
        { ((8#${bin_mode} & 8#020)) && [[ "${bin_gid}" != 0 && "${bin_gid}" != 80 ]]; }; then
        echo "error: ${prefix}/bin must be a directory owned by you or root, not world-writable," \
            "and group-writable only by wheel or admin" >&2
        exit 1
    fi
else
    install -d -m 0755 "${prefix}/bin"
fi
install_signed() {
    local source="$1" name="$2"
    shift 2
    tmp="$(mktemp "${prefix}/bin/.${name}.XXXXXX")"
    trap 'rm -f "${tmp}"' EXIT
    cp "${bin}/${source}" "${tmp}"
    codesign --force --sign - --options runtime "$@" "${tmp}"
    chmod 0755 "${tmp}"
    mv -f "${tmp}" "${prefix}/bin/${name}"
    trap - EXIT
}
if ((coreai)); then
    # No Core AI code in the guest helper: keep the plain build's, so templates record one helper.
    if [[ ! -x "${prefix}/bin/iso-macos-helper" ]]; then
        install_signed iso-macos-helper iso-macos-helper \
            --entitlements "${scripts}/enhanced-security.entitlements"
    fi
    install_signed iso-sandbox iso-sandbox-coreai \
        --entitlements "${pkg}/iso-sandbox-coreai.entitlements"
    # `version` may not run on a fully secured host: the private entitlement
    # stops the binary from launching there.
    "${prefix}/bin/iso-sandbox-coreai" version ||
        echo "warning: iso-sandbox-coreai did not run; AMFI is probably enforcing (see docs/coreai.md)" >&2
    echo "Installed ${prefix}/bin/iso-sandbox-coreai"
    exit 0
fi
install_signed iso-macos-helper iso-macos-helper \
    --entitlements "${scripts}/enhanced-security.entitlements"
install_signed iso-sandbox iso-sandbox --entitlements "${pkg}/iso-sandbox.entitlements"
"${prefix}/bin/iso-sandbox" version
installed="${prefix}/bin/iso-sandbox and ${prefix}/bin/iso-macos-helper"

# The Linux `desktop` images' MCP server (ELF, not codesigned). Prerequisites are checked apart
# from the build so only a host that cannot build it is skipped; a failing build still fails.
if [[ "${cu_mcp}" == auto ]] && ! "${scripts}/build-iso-cu-mcp.sh" --check; then
    echo "warning: this host cannot build iso-cu-mcp (see above)" >&2
    cu_mcp=skip
fi
if [[ "${cu_mcp}" == skip ]]; then
    # Never leave one from an earlier build beside a newer runtime.
    rm -f "${prefix}/bin/iso-cu-mcp" "${prefix}/bin/iso-cu-mcp.sbom.spdx.json"
    echo "warning: iso-cu-mcp not built: \`desktop\` images cannot be set up from this PREFIX" >&2
    echo "Installed ${installed}"
    exit 0
fi
"${scripts}/build-iso-cu-mcp.sh" "${prefix}/bin/iso-cu-mcp"
echo "Installed ${installed}, and ${prefix}/bin/iso-cu-mcp"
