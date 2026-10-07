#!/usr/bin/env bash
set -euo pipefail

# Sign the macOS release binaries with a Developer ID Application certificate
# and notarize them, so Gatekeeper accepts a browser-downloaded copy without
# `xattr -d com.apple.quarantine`.
#
# Usage:
#   scripts/macos-sign-notarize.sh DIR
#     DIR holds iso, iso-proxy, iso-egress, iso-sandbox and iso-macos-helper; each is re-signed
#     in place.
#   scripts/macos-sign-notarize.sh --check-env
#     Check required variables and the P12 without signing or contacting Apple.
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
        sed -n '4,23p' "$0" | sed -E 's/^# ?//'
        exit 0
        ;;
    "")
        echo "usage: $0 DIR | --check-env" >&2
        exit 1
        ;;
esac
dir="$1"

missing=0
for var in MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_SIGNING_IDENTITY \
    NOTARY_API_KEY_P8 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "error: ${var} is not set" >&2
        missing=1
    fi
done
if [[ "$missing" == 1 ]]; then
    echo "error: configure the required signing and notarization secrets in the release GitHub environment" >&2
    exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
umask 077
work="$(mktemp -d)"
keychain="${work}/signing.keychain-db"
# Keep the existing search list for certificate-chain lookup, and restore it
# even if importing, signing, or notarization fails. Never eval security output.
original_keychains=()
search_list_changed=0
keychain_created=0
cleanup() {
    if [[ "$search_list_changed" == 1 ]]; then
        security list-keychains -d user -s ${original_keychains[@]+"${original_keychains[@]}"} || true
    fi
    if [[ "$keychain_created" == 1 ]]; then
        security delete-keychain "${keychain}" 2>/dev/null || true
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

# Validate before a release spends time building. Suppress decoder/parser output:
# diagnostics must name the secret to repair without printing its contents.
if ! printf '%s' "${MACOS_CERTIFICATE_P12}" | base64 --decode > "${work}/cert.p12" 2>/dev/null \
    || [[ ! -s "${work}/cert.p12" ]]; then
    echo "error: MACOS_CERTIFICATE_P12 must be base64 of a nonempty Developer ID Application .p12 file" >&2
    exit 1
fi
if ! openssl pkcs12 -in "${work}/cert.p12" -passin env:MACOS_CERTIFICATE_PASSWORD \
    -noout > /dev/null 2>&1 \
    && ! openssl pkcs12 -legacy -in "${work}/cert.p12" -passin env:MACOS_CERTIFICATE_PASSWORD \
        -noout > /dev/null 2>&1; then
    echo "error: cannot read MACOS_CERTIFICATE_P12 with MACOS_CERTIFICATE_PASSWORD" >&2
    echo "error: export the Developer ID Application certificate and private key as .p12 from Keychain Access, then base64-encode the file; an Apple .cer download is not a .p12" >&2
    exit 1
fi
if [[ "$dir" == --check-env ]]; then
    exit 0
fi

keychain_password="$(uuidgen)"
security list-keychains -d user > "${work}/keychains"
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*\"(.*)\"[[:space:]]*$ ]]; then
        original_keychains+=("${BASH_REMATCH[1]}")
    else
        echo "error: cannot parse the user keychain search list" >&2
        exit 1
    fi
done < "${work}/keychains"

security create-keychain -p "${keychain_password}" "${keychain}"
keychain_created=1
security set-keychain-settings -lut 21600 "${keychain}"
security unlock-keychain -p "${keychain_password}" "${keychain}"
# --keychain restricts identity selection, but codesign still uses the user's
# search list to construct the certificate chain.
search_list_changed=1
security list-keychains -d user -s "${keychain}" ${original_keychains[@]+"${original_keychains[@]}"}
if ! security import "${work}/cert.p12" -f pkcs12 -k "${keychain}" -P "${MACOS_CERTIFICATE_PASSWORD}" \
    -T /usr/bin/codesign; then
    echo "error: macOS cannot import MACOS_CERTIFICATE_P12; re-export the certificate and private key as .p12 from Keychain Access and update its base64 and password in the release environment" >&2
    exit 1
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "${keychain_password}" "${keychain}" > /dev/null
rm -f "${work}/cert.p12"

# Resolve the configured name or SHA-1 to one valid Developer ID Application
# identity in this keychain. Do not print certificate names or secret values.
identities="$(security find-identity -v -p codesigning "${keychain}")"
signing_hash=""
identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Developer ID Application: .*)"$'
while IFS= read -r line; do
    if [[ "$line" =~ $identity_pattern ]]; then
        hash="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        if [[ "$MACOS_SIGNING_IDENTITY" == "$name" || "$MACOS_SIGNING_IDENTITY" == "$hash" ]]; then
            if [[ -n "$signing_hash" ]]; then
                echo "error: MACOS_SIGNING_IDENTITY matches multiple valid Developer ID Application identities" >&2
                exit 1
            fi
            signing_hash="$hash"
        fi
    fi
done <<< "$identities"
if [[ -z "$signing_hash" ]]; then
    echo "error: MACOS_SIGNING_IDENTITY does not match a valid Developer ID Application identity in MACOS_CERTIFICATE_P12" >&2
    echo "error: export the certificate with its private key; check expiry, certificate trust, and the exact identity name or SHA-1" >&2
    exit 1
fi

sign() {
    codesign --force --timestamp --options runtime --keychain "${keychain}" \
        --sign "${signing_hash}" "$@"
    codesign --verify --strict --verbose=2 "${@: -1}"
}
sign "${dir}/iso"
sign "${dir}/iso-proxy"
sign "${dir}/iso-egress"
sign "${dir}/iso-macos-helper"
sign --entitlements "${root}/iso-sandbox/iso-sandbox.entitlements" "${dir}/iso-sandbox"

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

for binary in iso iso-proxy iso-egress iso-sandbox iso-macos-helper; do
    spctl --assess --type open --context context:primary-signature --verbose=2 "${dir}/${binary}"
done
