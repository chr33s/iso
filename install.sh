#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Installer for iso — downloads a prebuilt binary from GitHub Releases.
#
# Usage:
#   ./install.sh                          # latest version, uses gh or GITHUB_TOKEN
#   VERSION=v0.3.0 ./install.sh           # specific version (v0.3.0 or later)
#   INSTALL_DIR=/usr/local/bin ./install.sh
#   INSTALL_SKILL=1 ./install.sh          # also install the agent skill into
#                                         # ~/.claude/skills and ~/.agents/skills
#                                         # (override with SKILL_DIRS=dir1:dir2)

REPO="chr33s/iso"
BINARY="iso"
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

# Failure commentary shares a stream with `gh` output and `die` so a redirected `curl | bash` keeps the report ordered.
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
    # Auth header on stdin (`-H @-`) keeps $GITHUB_TOKEN off argv (/proc, `set -x`).
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
    # Auth header on stdin (`-H @-`) keeps $GITHUB_TOKEN off argv (/proc, `set -x`).
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf 'Authorization: token %s\n' "${GITHUB_TOKEN}" \
            | curl -fsSL -H @- -o "$dest" "$url"
    else
        curl -fsSL -o "$dest" "$url"
    fi
}

# Fetch the provenance bundle credential-free. Not `download_asset`: its gh/token fallback
# would re-attach the credential `--bundle` avoids, and a token without org SSO would 403 here
# and drop the chain to the API path.
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
        die "Neither sha256sum nor shasum found; the checksum check is mandatory"
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
    # the repository: see the `iso update` trust chain in docs/trust-model.md.
    local signer_pin=(
        --cert-identity "https://github.com/${REPO}/${SIGNER_WORKFLOW}@refs/tags/${VERSION}"
        --source-ref "refs/tags/${VERSION}"
        --deny-self-hosted-runners
    )
    # Prefer the release's bundle: without --bundle, `gh` attaches its stored token, which 403s
    # without org SSO on anonymously readable data. See the `iso update` trust chain in
    # docs/trust-model.md.
    #
    # The probe is silenced (a missing bundle is expected on older releases) and an empty file
    # is rejected: `gh` before 2.56.0 reports success on an empty bundle.
    if download_bundle "${TMPDIR}/${BUNDLE}" > /dev/null 2>&1 \
        && [ -s "${TMPDIR}/${BUNDLE}" ]; then
        # Not retried via the API: a digest mismatch (tampered tarball with a matching SHA256SUMS)
        # is caught only here, and switching transports would mask it.
        gh attestation verify "$file" --repo "$REPO" "${signer_pin[@]}" --bundle "${TMPDIR}/${BUNDLE}" \
            || die "Attestation verification failed for $(basename "$file") — refusing to install"
        info "Attestation verified against ${BUNDLE} — no attestations-API call, no credential."
        return 0
    fi

    # Fallback: without `--bundle` gh requires login and attaches its token, so this needs a
    # credential authorized for the org.
    info "Could not use ${BUNDLE} for ${VERSION} (not published, download failed, or empty) —"
    info "verifying through the GitHub API instead."
    local out
    if out="$(gh attestation verify "$file" --repo "$REPO" "${signer_pin[@]}" 2>&1)"; then
        info "Attestation verified through the GitHub API."
        return 0
    fi
    printf '%s\n' "$out" >&2
    # Also fails on network errors, an old gh, or a real mismatch: explain the credential
    # requirement only when gh reported its symptoms.
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

# Replace <target>/iso with the skill at <source>. The copy is staged inside
# the target, outside $TMPDIR, so a failure removes it here.
install_skill() {
    local source="$1" target="$2" staged=""
    if mkdir -p "$target" \
        && staged="$(mktemp -d "${target}/.iso-skill.XXXXXX")" \
        && cp -R "${source}/." "$staged/" \
        && chmod 755 "$staged" \
        && rm -rf "${target:?}/iso" \
        && mv "$staged" "${target}/iso"; then
        info "Agent skill installed to ${target}/iso"
        return 0
    fi
    [ -z "$staged" ] || rm -rf "$staged" || true
    warn "Could not install the agent skill to ${target}/iso"
    return 1
}

# --- main -------------------------------------------------------------------

need curl
need ssh-keygen
detect_platform

# `|| true`: under `set -e` a failed lookup would exit here, before the
# message below.
VERSION="${VERSION:-$(latest_version || true)}"
[ -n "$VERSION" ] || die "Could not determine latest version. Set VERSION= explicitly."
# v0.1.0 and v0.2.0 predate iso-macos-helper, which this installer requires.
# The install.sh at their own tag installs them.
case "$VERSION" in
    v0.[0-2].*)
        die "${VERSION} predates this installer; use the one from its tag:
  curl -fsSL https://raw.githubusercontent.com/${REPO}/${VERSION}/install.sh | VERSION=${VERSION} bash"
        ;;
esac

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
# awk exits 0 without a match, so the message below is reached.
EXPECTED="$(awk -v name="${TARBALL}" '$2 == name { print $1 }' "${TMPDIR}/SHA256SUMS")"
[ -n "$EXPECTED" ] || die "Tarball ${TARBALL} not found in SHA256SUMS"
verify_checksum "${TMPDIR}/${TARBALL}" "$EXPECTED"

verify_attestation "${TMPDIR}/${TARBALL}"

info "Extracting..."
tar -xzf "${TMPDIR}/${TARBALL}" -C "${TMPDIR}"

info "Installing to ${INSTALL_DIR}..."
EXTRACTED_DIR="${TMPDIR}/${BINARY}-${VERSION}-${TRIPLE}"
# A release is one complete set. Check every member before changing the install.
for artifact in "$BINARY" iso-sandbox iso-macos-helper iso-proxy iso-egress; do
    [ -f "${EXTRACTED_DIR}/${artifact}" ] && [ ! -L "${EXTRACTED_DIR}/${artifact}" ] \
        || die "Release is missing a regular ${artifact} binary"
done
mkdir -p "$INSTALL_DIR"
# Linux `desktop` images' MCP server and kernel. A release before them has
# none (build-release.py requires them); its install removes any copy another
# release left, so none stays beside a runtime it was not built with.
for artifact in iso-cu-mcp vmlinux-desktop; do
    if [ -f "${EXTRACTED_DIR}/${artifact}" ] && [ ! -L "${EXTRACTED_DIR}/${artifact}" ]; then
        mv "${EXTRACTED_DIR}/${artifact}" "${INSTALL_DIR}/${artifact}"
        chmod 0755 "${INSTALL_DIR}/${artifact}"
    else
        rm -f "${INSTALL_DIR}/${artifact}"
    fi
done
for artifact in iso-sandbox iso-macos-helper iso-proxy iso-egress "$BINARY"; do
    mv "${EXTRACTED_DIR}/${artifact}" "${INSTALL_DIR}/${artifact}"
    chmod +x "${INSTALL_DIR}/${artifact}"
done

printf '\n  %s %s installed to %s/%s\n' "$BINARY" "$VERSION" "$INSTALL_DIR" "$BINARY"

# Opt-in: the host agent skill (docs/agent-skill.md), from the same verified
# archive. Each target's existing `iso` entry is replaced. The binaries are
# already installed, so a failed target is reported and the rest still run.
SKILL_SOURCE="${EXTRACTED_DIR}/skills/iso"
SKILL_FAILED=0
if [ "${INSTALL_SKILL:-0}" = "1" ]; then
    # Regular files and directories only: `find` also reports a symlinked root.
    if [ -f "${SKILL_SOURCE}/SKILL.md" ] \
        && [ -z "$(find "$SKILL_SOURCE" ! -type f ! -type d)" ]; then
        IFS=: read -r -a SKILL_TARGETS <<< "${SKILL_DIRS:-${HOME}/.claude/skills:${HOME}/.agents/skills}"
        for target in "${SKILL_TARGETS[@]}"; do
            [ -n "$target" ] || continue
            install_skill "$SKILL_SOURCE" "$target" || SKILL_FAILED=1
        done
    else
        warn "Release ${VERSION} has no regular agent skill; INSTALL_SKILL skipped."
    fi
elif [ -f "${SKILL_SOURCE}/SKILL.md" ]; then
    printf '\nInstall the iso agent skill for Claude Code and Codex:\n'
    printf '  re-run with INSTALL_SKILL=1 (see docs/agent-skill.md)\n'
fi

# Check if INSTALL_DIR is on PATH
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        printf '\nAdd %s to your PATH:\n' "$INSTALL_DIR"
        # shellcheck disable=SC2016
        printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
        ;;
esac

[ "$SKILL_FAILED" = "0" ] || die "${BINARY} ${VERSION} is installed, but the agent skill was not installed everywhere"
