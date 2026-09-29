#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# End-to-end test for install.sh's release provenance path. GitHub transports
# are stubbed, but the real installer performs signature and checksum
# verification, attestation dispatch, extraction, and installation. The
# installer under test is a copy whose ALLOWED_SIGNERS names a throwaway key
# generated here; every other line is the shipped install.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_PATH="$PATH"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64|Darwin-aarch64) TRIPLE="aarch64-apple-darwin" ;;
    *) echo "Unsupported test platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

VERSION="v9.9.9"
ARCHIVE_DIR="iso-${VERSION}-${TRIPLE}"
TARBALL="${ARCHIVE_DIR}.tar.gz"
FIXTURE="$TEST_ROOT/fixture"
MOCK_BIN="$TEST_ROOT/mock-bin"
INSTALL_DIR="$TEST_ROOT/install"
GH_LOG="$TEST_ROOT/gh.log"
CURL_LOG="$TEST_ROOT/curl.log"
mkdir -p "$FIXTURE/$ARCHIVE_DIR" "$MOCK_BIN" "$INSTALL_DIR"

cat >"$FIXTURE/$ARCHIVE_DIR/iso" <<'EOF'
#!/bin/sh
echo installed-iso
EOF
cat >"$FIXTURE/$ARCHIVE_DIR/iso-proxy" <<'EOF'
#!/bin/sh
echo installed-iso-proxy
EOF
printf '#!/bin/sh\necho installed-iso-sandbox\n' >"$FIXTURE/$ARCHIVE_DIR/iso-sandbox"
chmod +x "$FIXTURE/$ARCHIVE_DIR/iso-sandbox"
chmod +x "$FIXTURE/$ARCHIVE_DIR/iso" "$FIXTURE/$ARCHIVE_DIR/iso-proxy"
(cd "$FIXTURE" && tar -czf "$TARBALL" "$ARCHIVE_DIR")

SIGNING_KEY="$TEST_ROOT/release-key"
ssh-keygen -q -t ed25519 -N '' -C iso-test-release -f "$SIGNING_KEY"
NAMESPACE="release-sums@chr33s"
INSTALLER="$TEST_ROOT/install.sh"
test_signers="release namespaces=\"${NAMESPACE}\" $(cut -d' ' -f1,2 "$SIGNING_KEY.pub")"
awk -v line="ALLOWED_SIGNERS='${test_signers}'" \
    '/^ALLOWED_SIGNERS=/ { print line; next } { print }' \
    "$PROJECT_DIR/install.sh" >"$INSTALLER"
if [[ "$(diff "$PROJECT_DIR/install.sh" "$INSTALLER" | grep -c '^[<>]')" != 2 ]]; then
    echo "FATAL: could not substitute the test signer into install.sh" >&2
    exit 1
fi

sign_sums() {
    ssh-keygen -q -Y sign -f "${1:-$SIGNING_KEY}" -n "$NAMESPACE" \
        <"$FIXTURE/SHA256SUMS" >"$FIXTURE/SHA256SUMS.sig"
}

write_sums() {
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$FIXTURE" && sha256sum "$TARBALL" > SHA256SUMS)
    else
        (cd "$FIXTURE" && shasum -a 256 "$TARBALL" > SHA256SUMS)
    fi
    sign_sums
}

write_sums
printf '%s\n' '{"synthetic":"non-empty provenance bundle"}' \
    >"$FIXTURE/attestations.jsonl"

cat >"$MOCK_BIN/gh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$ISO_TEST_GH_LOG"

if [ "$1 $2" = "release download" ]; then
    pattern=""
    destination=""
    shift 2
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pattern) pattern="$2"; shift 2 ;;
            --dir) destination="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    cp "$ISO_TEST_FIXTURE/$pattern" "$destination/$pattern"
    exit 0
fi

if [ "$1 $2" = "attestation verify" ]; then
    [ "${ISO_TEST_GH_VERIFY_FAIL:-0}" != "1" ] || exit 42
    bundle=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--bundle" ]; then
            bundle="$2"
            break
        fi
        shift
    done
    if [ "${ISO_TEST_GH_REQUIRE_BUNDLE:-0}" = "1" ]; then
        [ -n "$bundle" ] && [ -s "$bundle" ] || exit 43
    fi
    exit 0
fi

exit 44
STUB

cat >"$MOCK_BIN/curl" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$ISO_TEST_CURL_LOG"
destination=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) destination="$2"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    */attestations.jsonl)
        [ "${ISO_TEST_BUNDLE_FAIL:-0}" != "1" ] || exit 22
        cp "$ISO_TEST_FIXTURE/attestations.jsonl" "$destination"
        ;;
    *) exit 45 ;;
esac
STUB
chmod +x "$MOCK_BIN/gh" "$MOCK_BIN/curl"

pass_count=0
fail_count=0

pass() {
    pass_count=$((pass_count + 1))
    echo "  PASS  $1"
}

fail() {
    fail_count=$((fail_count + 1))
    echo "  FAIL  $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

run_installer() {
    env PATH="$MOCK_BIN:$REAL_PATH" \
        VERSION="$VERSION" \
        INSTALL_DIR="$INSTALL_DIR" \
        GITHUB_TOKEN="restricted-token-must-not-reach-bundle-curl" \
        ISO_TEST_FIXTURE="$FIXTURE" \
        ISO_TEST_GH_LOG="$GH_LOG" \
        ISO_TEST_CURL_LOG="$CURL_LOG" \
        ISO_TEST_GH_REQUIRE_BUNDLE="${ISO_TEST_GH_REQUIRE_BUNDLE:-0}" \
        ISO_TEST_GH_VERIFY_FAIL="${ISO_TEST_GH_VERIFY_FAIL:-0}" \
        ISO_TEST_BUNDLE_FAIL="${ISO_TEST_BUNDLE_FAIL:-0}" \
        bash "$INSTALLER"
}

echo "==> Test 1: published bundle is downloaded anonymously and verified"
: >"$GH_LOG"
: >"$CURL_LOG"
ISO_TEST_GH_REQUIRE_BUNDLE=1
export ISO_TEST_GH_REQUIRE_BUNDLE
if run_installer >"$TEST_ROOT/t1.log" 2>&1; then
    pass "install succeeds with a published attestation bundle"
else
    fail "install succeeds with a published attestation bundle" \
        "$(tail -10 "$TEST_ROOT/t1.log")"
fi
unset ISO_TEST_GH_REQUIRE_BUNDLE

if "$INSTALL_DIR/iso" | grep -q '^installed-iso$' \
    && "$INSTALL_DIR/iso-proxy" | grep -q '^installed-iso-proxy$'; then
    pass "installer extracts iso and iso-proxy"
    if [[ "$TRIPLE" == aarch64-apple-darwin ]]; then
        if [[ "$("$INSTALL_DIR/iso-sandbox")" == installed-iso-sandbox ]]; then
            pass "installer installs the Apple runtime"
        else
            fail "installer installs the Apple runtime"
        fi
    fi
else
    fail "installer extracts iso and iso-proxy"
fi

SIGNER_PIN="--cert-identity https://github.com/chr33s/iso/.github/workflows/release.yml@refs/tags/${VERSION} --source-ref refs/tags/${VERSION} --deny-self-hosted-runners"
if grep -qF -- "--repo chr33s/iso ${SIGNER_PIN} --bundle " "$GH_LOG"; then
    pass "gh verifies the tarball with the downloaded bundle"
else
    fail "gh verifies the tarball with the downloaded bundle" "gh calls: $(cat "$GH_LOG")"
fi

if grep -Eq -- '-H|--header|restricted-token' "$CURL_LOG"; then
    fail "bundle download carries no GitHub credential" "curl args: $(cat "$CURL_LOG")"
else
    pass "bundle download carries no GitHub credential"
fi

echo "==> Test 2: bundle verification failure is fail-closed"
printf '%s\n' 'keep-existing-install' >"$INSTALL_DIR/iso"
printf '%s\n' 'keep-existing-proxy' >"$INSTALL_DIR/iso-proxy"
ISO_TEST_GH_VERIFY_FAIL=1
export ISO_TEST_GH_VERIFY_FAIL
if run_installer >"$TEST_ROOT/t2.log" 2>&1; then
    fail "failed bundle verification aborts installation" "installer exited 0"
elif grep -q "Attestation verification failed" "$TEST_ROOT/t2.log" \
    && [[ "$(cat "$INSTALL_DIR/iso")" == "keep-existing-install" \
       && "$(cat "$INSTALL_DIR/iso-proxy")" == "keep-existing-proxy" ]]; then
    pass "failed bundle verification leaves both installed binaries unchanged"
else
    fail "failed bundle verification leaves both installed binaries unchanged" \
        "$(tail -10 "$TEST_ROOT/t2.log")"
fi
unset ISO_TEST_GH_VERIFY_FAIL

echo "==> Test 3: releases without a usable bundle retain API fallback"
: >"$GH_LOG"
ISO_TEST_BUNDLE_FAIL=1
export ISO_TEST_BUNDLE_FAIL
if run_installer >"$TEST_ROOT/t3.log" 2>&1; then
    pass "installer falls back for a pre-bundle release"
else
    fail "installer falls back for a pre-bundle release" \
        "$(tail -10 "$TEST_ROOT/t3.log")"
fi
unset ISO_TEST_BUNDLE_FAIL

if grep -q -- "attestation verify .* --repo chr33s/iso ${SIGNER_PIN}\$" "$GH_LOG" \
    && ! grep -q -- '--bundle' "$GH_LOG"; then
    pass "legacy fallback verifies through the attestations API"
else
    fail "legacy fallback verifies through the attestations API" "gh calls: $(cat "$GH_LOG")"
fi

echo "==> Test 4: checksum rejection preserves both binaries"
printf '%s\n' 'keep-existing-install' >"$INSTALL_DIR/iso"
printf '%s\n' 'keep-existing-proxy' >"$INSTALL_DIR/iso-proxy"
printf '%064d  %s\n' 0 "$TARBALL" >"$FIXTURE/SHA256SUMS"
sign_sums
if run_installer >"$TEST_ROOT/t4.log" 2>&1; then
    fail "checksum mismatch aborts installation" "installer exited 0"
elif grep -q "Checksum mismatch" "$TEST_ROOT/t4.log" \
    && [[ "$(cat "$INSTALL_DIR/iso")" == "keep-existing-install" \
       && "$(cat "$INSTALL_DIR/iso-proxy")" == "keep-existing-proxy" ]]; then
    pass "checksum mismatch leaves both installed binaries unchanged"
else
    fail "checksum mismatch leaves both installed binaries unchanged" \
        "$(tail -10 "$TEST_ROOT/t4.log")"
fi

write_sums

echo "==> Test 5: reinstall replaces both existing binaries"
if run_installer >"$TEST_ROOT/t5.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/iso")" == "installed-iso" \
       && "$("$INSTALL_DIR/iso-proxy")" == "installed-iso-proxy" ]]; then
    pass "reinstall replaces both binaries with verified release contents"
else
    fail "reinstall replaces both binaries with verified release contents" \
        "$(tail -10 "$TEST_ROOT/t5.log")"
fi

echo "==> Test 5a: SHA256SUMS signature is mandatory"
ssh-keygen -q -t ed25519 -N '' -C untrusted -f "$TEST_ROOT/untrusted-key"
printf '%s\n' 'keep-existing-install' >"$INSTALL_DIR/iso"
printf '%s\n' 'keep-existing-proxy' >"$INSTALL_DIR/iso-proxy"
sign_sums "$TEST_ROOT/untrusted-key"
if run_installer >"$TEST_ROOT/t5a.log" 2>&1; then
    fail "untrusted signer aborts installation" "installer exited 0"
elif grep -q "not signed by a trusted release key" "$TEST_ROOT/t5a.log" \
    && [[ "$(cat "$INSTALL_DIR/iso")" == "keep-existing-install" \
       && "$(cat "$INSTALL_DIR/iso-proxy")" == "keep-existing-proxy" ]]; then
    pass "untrusted signer leaves both installed binaries unchanged"
else
    fail "untrusted signer leaves both installed binaries unchanged" \
        "$(tail -10 "$TEST_ROOT/t5a.log")"
fi

rm "$FIXTURE/SHA256SUMS.sig"
if run_installer >"$TEST_ROOT/t5b.log" 2>&1; then
    fail "missing signature aborts installation" "installer exited 0"
elif grep -q "publishes no SHA256SUMS.sig" "$TEST_ROOT/t5b.log" \
    && [[ "$(cat "$INSTALL_DIR/iso")" == "keep-existing-install" \
       && "$(cat "$INSTALL_DIR/iso-proxy")" == "keep-existing-proxy" ]]; then
    pass "missing signature leaves both installed binaries unchanged"
else
    fail "missing signature leaves both installed binaries unchanged" \
        "$(tail -10 "$TEST_ROOT/t5b.log")"
fi
sign_sums

echo "==> Test 6: missing companion policy"
rm "$FIXTURE/$ARCHIVE_DIR/iso-proxy"
(cd "$FIXTURE" && tar -czf "$TARBALL" "$ARCHIVE_DIR")
write_sums
printf '%s\n' 'old-iso' >"$INSTALL_DIR/iso"
if [[ "$TRIPLE" == aarch64-apple-darwin ]]; then
    if ! run_installer >"$TEST_ROOT/t6.log" 2>&1 \
        && [[ "$(cat "$INSTALL_DIR/iso")" == old-iso ]]; then
        pass "Apple install rejects missing companion before host replacement"
    else
        fail "Apple install rejects missing companion before host replacement"
    fi
else
if run_installer >"$TEST_ROOT/t6.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/iso")" == "installed-iso" \
       && "$("$INSTALL_DIR/iso-proxy")" == "installed-iso-proxy" ]]; then
    pass "legacy install replaces iso and preserves the existing companion"
else
    fail "legacy install replaces iso and preserves the existing companion" \
        "$(tail -10 "$TEST_ROOT/t6.log")"
fi
fi

repack_fixture() {
    (cd "$FIXTURE" && tar -czf "$TARBALL" "$ARCHIVE_DIR")
    write_sums
}

echo "==> Test 7: Swift-only package installs its proxy"
printf '#!/bin/sh\necho iso-proxy\n' >"$FIXTURE/$ARCHIVE_DIR/iso-proxy"
if [[ "$TRIPLE" == aarch64-apple-darwin ]]; then
    mv "$FIXTURE/$ARCHIVE_DIR/iso-sandbox" "$FIXTURE/runtime-backup"
    repack_fixture
    printf '%s\n' keep-host >"$INSTALL_DIR/iso"
    printf '%s\n' keep-runtime >"$INSTALL_DIR/iso-sandbox"
    printf '%s\n' keep-proxy >"$INSTALL_DIR/iso-proxy"
    if ! run_installer >"$TEST_ROOT/missing-runtime.log" 2>&1 \
        && [[ "$(cat "$INSTALL_DIR/iso")" == keep-host \
           && "$(cat "$INSTALL_DIR/iso-sandbox")" == keep-runtime \
           && "$(cat "$INSTALL_DIR/iso-proxy")" == keep-proxy ]]; then
        pass "missing Apple runtime preserves all installed binaries"
    else
        fail "missing Apple runtime preserves all installed binaries"
    fi
    mv "$FIXTURE/runtime-backup" "$FIXTURE/$ARCHIVE_DIR/iso-sandbox"
fi
repack_fixture
if run_installer >"$TEST_ROOT/t7.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/iso-proxy")" == iso-proxy ]]; then
    pass "verified transition package installs the Swift executable"
else
    fail "verified transition package installs the Swift executable" "$(tail -10 "$TEST_ROOT/t7.log")"
fi

echo "==> Test 8: obsolete Rust package is rejected before replacement"
rm "$FIXTURE/$ARCHIVE_DIR/iso-proxy"
printf old-rust >"$FIXTURE/$ARCHIVE_DIR/iso-proxy-rs"
printf '%s\n' keep-host >"$INSTALL_DIR/iso"
printf '%s\n' keep-rust >"$INSTALL_DIR/iso-proxy-rs"
printf '%s\n' keep-swift >"$INSTALL_DIR/iso-proxy-swift"
repack_fixture
if run_installer >"$TEST_ROOT/t8.log" 2>&1; then
    fail "obsolete Rust pair aborts installation"
elif grep -q 'obsolete proxy transition artifact' "$TEST_ROOT/t8.log" \
    && [[ "$(cat "$INSTALL_DIR/iso")" == keep-host \
       && "$(cat "$INSTALL_DIR/iso-proxy-rs")" == keep-rust \
       && "$(cat "$INSTALL_DIR/iso-proxy-swift")" == keep-swift ]]; then
    pass "obsolete Rust pair leaves all installed files unchanged"
else
    fail "obsolete Rust pair leaves all installed files unchanged" "$(tail -10 "$TEST_ROOT/t8.log")"
fi

echo "==> Test 9: legacy package removes stale transition selection"
rm "$FIXTURE/$ARCHIVE_DIR/iso-proxy-rs"
printf '#!/bin/sh\necho legacy-proxy\n' >"$FIXTURE/$ARCHIVE_DIR/iso-proxy"
repack_fixture
if run_installer >"$TEST_ROOT/t9.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/iso-proxy")" == legacy-proxy \
       && ! -e "$INSTALL_DIR/iso-proxy-rs" && ! -e "$INSTALL_DIR/iso-proxy-swift" ]]; then
    pass "legacy package removes stale transition siblings"
else
    fail "legacy package removes stale transition siblings" "$(tail -10 "$TEST_ROOT/t9.log")"
fi

echo
echo "  $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
