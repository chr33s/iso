#!/usr/bin/env bash
set -euo pipefail

# Build iso-sandbox, the macOS VM runtime that iso's `apple-container`
# feature build drives, and install it into a directory only you (or root)
# can write.
#
# iso-sandbox (iso-sandbox) runs each iso instance as a persistent
# Linux VM on apple/containerization, with its own vmnet network and no host
# mounts, socket relays, published ports, or SSH-agent forwarding. This script
# builds it in release mode, signs it ad hoc with the hardened runtime and the
# one entitlement it needs (com.apple.security.virtualization), and copies it
# into PREFIX/bin, which must be owned by you or root and not writable by
# other users except the wheel or admin group. It never uses sudo.
#
# Usage:
#   scripts/build-iso-sandbox.sh [PREFIX]
#     PREFIX defaults to ~/.local/opt/iso-sandbox
#
# iso finds <PREFIX>/bin/iso-sandbox at the default PREFIX; otherwise set
#   "apple_container": {"binary": "<PREFIX>/bin/iso-sandbox"}
# See docs/backends.md. Requires Xcode 27 and Swift 6.4 on an Apple Silicon Mac.

case "${1:-}" in
    -h | --help)
        sed -n '4,22p' "$0" | sed -E 's/^# ?//'
        exit 0
        ;;
esac
prefix="${1:-${HOME}/.local/opt/iso-sandbox}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "error: iso-sandbox needs an Apple Silicon Mac" >&2
    exit 1
fi
if [[ "${prefix}" != /* ]]; then
    echo "error: PREFIX must be an absolute path" >&2
    exit 1
fi

pkg="$(cd "$(dirname "$0")/../iso-sandbox" && pwd)"
swift build --package-path "${pkg}" -c release --force-resolved-versions
built="$(swift build --package-path "${pkg}" -c release --show-bin-path)/iso-sandbox"

# Another user who can write here could swap the binary iso runs. Checked
# before `install -d`, which would silently reset an existing directory's mode.
if [[ -e "${prefix}/bin" ]]; then
    # iso's run-time rule (`untrusted_dir`), minus its sticky-directory
    # exception: group-writable
    # is allowed only for wheel (0) or admin (80), whose members can already
    # sudo; Homebrew's /opt/homebrew/bin is admin-writable.
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
tmp="$(mktemp "${prefix}/bin/.iso-sandbox.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
cp "${built}" "${tmp}"
codesign --force --sign - --options runtime --entitlements "${pkg}/iso-sandbox.entitlements" "${tmp}"
chmod 0755 "${tmp}"
mv -f "${tmp}" "${prefix}/bin/iso-sandbox"
trap - EXIT

"${prefix}/bin/iso-sandbox" version
echo "Installed ${prefix}/bin/iso-sandbox"
