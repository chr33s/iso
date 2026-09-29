#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Installer for coop — downloads a prebuilt binary from GitHub Releases.
#
# Usage:
#   ./install.sh                          # latest version, uses gh or GITHUB_TOKEN
#   VERSION=v0.2.1 ./install.sh           # specific version
#   INSTALL_DIR=/usr/local/bin ./install.sh

REPO="chr33s/coop"
BINARY="coop"
BUNDLE="attestations.jsonl"
# The only workflow whose attestations count; candidate.yml also attests.
SIGNER_WORKFLOW=".github/workflows/release.yml"
# Release SHA256SUMS signers (`ssh-keygen -Y` allowed_signers). Keep in sync
# with .github/release-signers and ReleaseSigners.keys.
SIGNATURE_NAMESPACE="release-sums@chr33s"
ALLOWED_SIGNERS='release namespaces="release-sums@chr33s" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGpguyE19BveEWHxNaowpmslcC3WE4BKZlXl4dgSmOmx'
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"

# --- helpers ----------------------------------------------------------------

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

info() { printf '  %s\n' "$1"; }

# Failure commentary belongs on the same stream as the `gh` output it explains
# and the `die` that follows it, so a redirected `curl … | bash` keeps the whole
# report together and in order.
warn() { printf '  %s\n' "$1" >&2; }

need() {
    command -v "$1" > /dev/null 2>&1 || die "'$1' is required but not found"
}

has() {
    command -v "$1" > /dev/null 2>&1
}

detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Linux)  OS="linux" ;;
        Darwin) OS="darwin" ;;
        *)      die "Unsupported OS: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *)             die "Unsupported architecture: $arch" ;;
    esac
}

target_triple() {
    case "${OS}-${ARCH}" in
        darwin-aarch64) echo "aarch64-apple-darwin" ;;
        *)              die "No prebuilt binary for ${OS}-${ARCH}" ;;
    esac
}

latest_version() {
    if has gh; then
        gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null && return
    fi
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    # Pass the auth header on stdin (`-H @-`) so $GITHUB_TOKEN never appears
    # on argv where it would be visible in /proc/<pid>/cmdline or `set -x`.
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf 'Authorization: token %s\n' "${GITHUB_TOKEN}" \
            | curl -fsSL -H @- "$url" \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
    else
        curl -fsSL "$url" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
    fi
}

# Download a release asset. Tries gh first, then curl with token, then plain curl.
download_asset() {
    local filename="$1" dest="$2"

    if has gh; then
        info "Downloading ${filename} (via gh)..."
        gh release download "$VERSION" --repo "$REPO" --pattern "$filename" --dir "$(dirname "$dest")" 2>/dev/null \
            && return
        info "gh download failed, falling back to curl..."
    fi

    local url="https://github.com/${REPO}/releases/download/${VERSION}/${filename}"

    info "Downloading ${filename}..."
    # Pass the auth header on stdin (`-H @-`) so $GITHUB_TOKEN never appears
    # on argv where it would be visible in /proc/<pid>/cmdline or `set -x`.
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf 'Authorization: token %s\n' "${GITHUB_TOKEN}" \
            | curl -fsSL -H @- -o "$dest" "$url"
    else
        curl -fsSL -o "$dest" "$url"
    fi
}

# Fetch the release's provenance bundle with no credential attached.
#
# Deliberately not `download_asset`: that prefers `gh` and then falls back to
# curl carrying $GITHUB_TOKEN, which would re-attach the credential `--bundle`
# exists to avoid. A token with no SSO session for the org would 403 on this one
# step and drop the whole chain back to the API path, failing with the original
# error. The bundle is a public release file, so a bare curl reaches it and
# keeps the path credential-free end to end.
download_bundle() {
    local dest="$1"
    curl -fsSL -o "$dest" \
        "https://github.com/${REPO}/releases/download/${VERSION}/${BUNDLE}"
}

# Mandatory: SHA256SUMS must carry a signature from a key listed above, made
# by a maintainer after release.yml built the draft. Nothing in SHA256SUMS is
# trusted before this passes.
verify_signature() {
    local sums="$1" signature="$2"
    printf '%s\n' "$ALLOWED_SIGNERS" > "${TMPDIR}/allowed_signers"
    ssh-keygen -Y verify -f "${TMPDIR}/allowed_signers" -I release \
        -n "$SIGNATURE_NAMESPACE" -s "$signature" < "$sums" > /dev/null \
        || die "SHA256SUMS is not signed by a trusted release key — refusing to install"
    info "SHA256SUMS signature verified."
}

verify_checksum() {
    local file="$1" expected="$2"
    local actual
    if command -v sha256sum > /dev/null 2>&1; then
        actual="$(sha256sum "$file" | cut -d' ' -f1)"
    elif command -v shasum > /dev/null 2>&1; then
        actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    else
        info "Warning: no sha256sum or shasum found, skipping checksum verification"
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        die "Checksum mismatch for $(basename "$file"): expected $expected, got $actual"
    fi
}

verify_attestation() {
    local file="$1"
    if ! has gh; then
        info "Note: \`gh\` not installed — skipped cryptographic attestation verification."
        info "The download was verified against the published \`SHA256SUMS\` checksum, which"
        info "is the same assurance level as most \`curl | bash\` installers. For end-to-end"
        info "Sigstore verification, install \`gh\` (https://cli.github.com) and re-run, or"
        info "verify manually: \`gh attestation verify <tarball> --repo ${REPO} \\"
        info "  --bundle ${BUNDLE}\` against the ${BUNDLE} asset from the same release."
        return 0
    fi

    info "Verifying attestation..."
    # Pin the signer to the release workflow run for this exact tag, not just
    # the repository: see the `coop update` trust chain in docs/trust-model.md.
    local signer_pin=(
        --cert-identity "https://github.com/${REPO}/${SIGNER_WORKFLOW}@refs/tags/${VERSION}"
        --source-ref "refs/tags/${VERSION}"
        --deny-self-hosted-runners
    )
    # Prefer the bundle published with the release: without --bundle, `gh`
    # refuses to run unauthenticated and then attaches its stored token to the
    # attestations API call, so a token with no SSO session for the org 403s on
    # data that is anonymously readable. See the `coop update` trust chain in
    # docs/trust-model.md for what each transport does and does not pin.
    #
    # The probe is silenced because a missing bundle is expected on older
    # releases, so curl's bare "404" would read as a hard error — which means
    # it cannot tell "not published" from a failed download. The message below
    # says so rather than picking one. An empty file is rejected here too: `gh`
    # before 2.56.0 reports success on an empty bundle, having verified nothing.
    if download_bundle "${TMPDIR}/${BUNDLE}" > /dev/null 2>&1 \
        && [ -s "${TMPDIR}/${BUNDLE}" ]; then
        # Not retried through the API. A digest mismatch — a tampered tarball
        # published with a matching SHA256SUMS — is caught here and nowhere
        # else in this script, and a bundle that downloaded but will not verify
        # is equally a broken download or a `gh` that cannot read it. Switching
        # transports would mask all three.
        gh attestation verify "$file" --repo "$REPO" "${signer_pin[@]}" --bundle "${TMPDIR}/${BUNDLE}" \
            || die "Attestation verification failed for $(basename "$file") — refusing to install"
        info "Attestation verified against ${BUNDLE} — no attestations-API call, no credential."
        return 0
    fi

    # Verifying through the API is exactly what every release did before the
    # bundle asset existed. Without `--bundle`, `gh` gates the command on being
    # logged in and attaches its token, so this path needs a credential
    # authorized for the org — which is why it is the fallback, not the default.
    info "Could not use ${BUNDLE} for ${VERSION} (not published, download failed, or empty) —"
    info "verifying through the GitHub API instead."
    local out
    if out="$(gh attestation verify "$file" --repo "$REPO" "${signer_pin[@]}" 2>&1)"; then
        info "Attestation verified through the GitHub API."
        return 0
    fi
    printf '%s\n' "$out" >&2
    # This path also fails on a network error, a gh too old for the command, or
    # a genuine provenance mismatch, so only explain the credential requirement
    # when gh actually reported one of its symptoms.
    case "$out" in
        *403* | *SAML* | *"gh auth login"*)
            warn "Verification used the GitHub API because ${BUNDLE} was unavailable for"
            warn "${VERSION}, and without \`--bundle\` \`gh\` requires a credential authorized"
            warn "for the org. Confirm ${BUNDLE} is on the release page; a release that"
            warn "publishes it needs no credential to verify."
            ;;
    esac
    die "Attestation verification failed for $(basename "$file") — refusing to install"
}

# --- main -------------------------------------------------------------------

need curl
need ssh-keygen
detect_platform

VERSION="${VERSION:-$(latest_version)}"
[ -n "$VERSION" ] || die "Could not determine latest version. Set VERSION= explicitly."

TRIPLE="$(target_triple)"
TARBALL="${BINARY}-${VERSION}-${TRIPLE}.tar.gz"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

printf 'Installing %s %s (%s)\n' "$BINARY" "$VERSION" "$TRIPLE"

download_asset "$TARBALL" "${TMPDIR}/${TARBALL}"
download_asset "SHA256SUMS" "${TMPDIR}/SHA256SUMS"
download_asset "SHA256SUMS.sig" "${TMPDIR}/SHA256SUMS.sig" \
    || die "Release ${VERSION} publishes no SHA256SUMS.sig — refusing to install an unsigned release"
verify_signature "${TMPDIR}/SHA256SUMS" "${TMPDIR}/SHA256SUMS.sig"

info "Verifying checksum..."
EXPECTED="$(grep "${TARBALL}" "${TMPDIR}/SHA256SUMS" | cut -d' ' -f1)"
[ -n "$EXPECTED" ] || die "Tarball ${TARBALL} not found in SHA256SUMS"
verify_checksum "${TMPDIR}/${TARBALL}" "$EXPECTED"

verify_attestation "${TMPDIR}/${TARBALL}"

info "Extracting..."
tar -xzf "${TMPDIR}/${TARBALL}" -C "${TMPDIR}"

info "Installing to ${INSTALL_DIR}..."
EXTRACTED_DIR="${TMPDIR}/${BINARY}-${VERSION}-${TRIPLE}"
EXTRACTED="${EXTRACTED_DIR}/${BINARY}"
[ -f "$EXTRACTED" ] || die "Binary not found in tarball"
for obsolete in "${BINARY}-proxy-rs" "${BINARY}-proxy-swift"; do
    [ ! -e "${EXTRACTED_DIR}/${obsolete}" ] || die "Release contains an obsolete proxy transition artifact"
done
PROXY_NAME="${BINARY}-proxy"
if [ -e "${EXTRACTED_DIR}/${PROXY_NAME}" ] && [ ! -f "${EXTRACTED_DIR}/${PROXY_NAME}" ]; then
    die "Proxy artifact is not a regular file"
fi
if [ "$TRIPLE" = "aarch64-apple-darwin" ]; then
    [ -f "${EXTRACTED_DIR}/coop-sandbox" ] || die "Release is missing the coop-sandbox runtime"
    [ -f "${EXTRACTED_DIR}/${PROXY_NAME}" ] || die "Release is missing the coop-proxy companion"
fi
mkdir -p "$INSTALL_DIR"
if [ "$TRIPLE" = "aarch64-apple-darwin" ]; then
    mv "${EXTRACTED_DIR}/coop-sandbox" "${INSTALL_DIR}/coop-sandbox"
    chmod +x "${INSTALL_DIR}/coop-sandbox"
fi
if [ -f "${EXTRACTED_DIR}/${PROXY_NAME}" ]; then
    mv "${EXTRACTED_DIR}/${PROXY_NAME}" "${INSTALL_DIR}/${PROXY_NAME}"
    chmod +x "${INSTALL_DIR}/${PROXY_NAME}"
    for stale in "${BINARY}-proxy-rs" "${BINARY}-proxy" "${BINARY}-proxy-swift"; do
        [ "$stale" = "$PROXY_NAME" ] || rm -f "${INSTALL_DIR}/${stale}"
    done
fi
mv "$EXTRACTED" "${INSTALL_DIR}/${BINARY}"
chmod +x "${INSTALL_DIR}/${BINARY}"

printf '\n  %s %s installed to %s/%s\n' "$BINARY" "$VERSION" "$INSTALL_DIR" "$BINARY"

# Check if INSTALL_DIR is on PATH
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        printf '\nAdd %s to your PATH:\n' "$INSTALL_DIR"
        # shellcheck disable=SC2016
        printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
        ;;
esac
