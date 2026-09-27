#!/usr/bin/env bash
set -euo pipefail

# Sign the macOS release binaries with a Developer ID Application certificate
# and notarize them, so Gatekeeper accepts a browser-downloaded copy without
# `xattr -d com.apple.quarantine`.
#
# Usage:
#   scripts/macos-sign-notarize.sh DIR
#     DIR holds coop, coop-proxy and coop-sandbox; each is re-signed in place.
#
# Environment (all required):
#   MACOS_CERTIFICATE_P12        base64 Developer ID Application .p12
#   MACOS_CERTIFICATE_PASSWORD   password for that .p12
#   MACOS_SIGNING_IDENTITY       e.g. "Developer ID Application: Name (TEAMID)"
#   NOTARY_API_KEY_P8            base64 App Store Connect API key (.p8)
#   NOTARY_API_KEY_ID            App Store Connect API key ID
#   NOTARY_API_ISSUER_ID         App Store Connect issuer ID
#
# Bare Mach-O binaries cannot carry a stapled ticket, so Gatekeeper looks the
# notarization up online on first launch.

case "${1:-}" in
    -h | --help)
        sed -n '4,21p' "$0" | sed -E 's/^# ?//'
        exit 0
        ;;
    "")
        echo "usage: $0 DIR" >&2
        exit 1
        ;;
esac
dir="$1"

for var in MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_SIGNING_IDENTITY \
    NOTARY_API_KEY_P8 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "error: ${var} is not set" >&2
        exit 1
    fi
done

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
keychain="${work}/signing.keychain-db"
keychain_password="$(uuidgen)"
cleanup() {
    security delete-keychain "${keychain}" 2>/dev/null || true
    rm -rf "${work}"
}
trap cleanup EXIT

printf '%s' "${MACOS_CERTIFICATE_P12}" | base64 --decode > "${work}/cert.p12"
security create-keychain -p "${keychain_password}" "${keychain}"
security set-keychain-settings -lut 21600 "${keychain}"
security unlock-keychain -p "${keychain_password}" "${keychain}"
security import "${work}/cert.p12" -k "${keychain}" -P "${MACOS_CERTIFICATE_PASSWORD}" \
    -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "${keychain_password}" "${keychain}" > /dev/null
rm -f "${work}/cert.p12"

sign() {
    codesign --force --timestamp --options runtime --keychain "${keychain}" \
        --sign "${MACOS_SIGNING_IDENTITY}" "$@"
    codesign --verify --strict --verbose=2 "${@: -1}"
}
sign "${dir}/coop"
sign "${dir}/coop-proxy"
sign --entitlements "${root}/coop-sandbox/coop-sandbox.entitlements" "${dir}/coop-sandbox"

printf '%s' "${NOTARY_API_KEY_P8}" | base64 --decode > "${work}/notary.p8"
ditto -c -k --keepParent "${dir}" "${work}/notarize.zip"
result="$(xcrun notarytool submit "${work}/notarize.zip" --wait --output-format json \
    --key "${work}/notary.p8" --key-id "${NOTARY_API_KEY_ID}" --issuer "${NOTARY_API_ISSUER_ID}")"
status="$(jq -r .status <<< "${result}")"
if [[ "${status}" != Accepted ]]; then
    echo "error: notarization status ${status}" >&2
    xcrun notarytool log "$(jq -r .id <<< "${result}")" \
        --key "${work}/notary.p8" --key-id "${NOTARY_API_KEY_ID}" --issuer "${NOTARY_API_ISSUER_ID}" >&2 || true
    exit 1
fi

for binary in coop coop-proxy coop-sandbox; do
    spctl --assess --type open --context context:primary-signature --verbose=2 "${dir}/${binary}"
done
