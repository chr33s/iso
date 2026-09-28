#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# End-to-end test for install.sh's release provenance path. GitHub transports
# are stubbed, but the real installer performs checksum verification,
# attestation dispatch, extraction, and installation.

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
ARCHIVE_DIR="coop-${VERSION}-${TRIPLE}"
TARBALL="${ARCHIVE_DIR}.tar.gz"
FIXTURE="$TEST_ROOT/fixture"
MOCK_BIN="$TEST_ROOT/mock-bin"
INSTALL_DIR="$TEST_ROOT/install"
GH_LOG="$TEST_ROOT/gh.log"
CURL_LOG="$TEST_ROOT/curl.log"
mkdir -p "$FIXTURE/$ARCHIVE_DIR" "$MOCK_BIN" "$INSTALL_DIR"

cat >"$FIXTURE/$ARCHIVE_DIR/coop" <<'EOF'
#!/bin/sh
echo installed-coop
EOF
cat >"$FIXTURE/$ARCHIVE_DIR/coop-proxy" <<'EOF'
#!/bin/sh
echo installed-coop-proxy
EOF
printf '#!/bin/sh\necho installed-coop-sandbox\n' >"$FIXTURE/$ARCHIVE_DIR/coop-sandbox"
chmod +x "$FIXTURE/$ARCHIVE_DIR/coop-sandbox"
chmod +x "$FIXTURE/$ARCHIVE_DIR/coop" "$FIXTURE/$ARCHIVE_DIR/coop-proxy"
(cd "$FIXTURE" && tar -czf "$TARBALL" "$ARCHIVE_DIR")

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$FIXTURE" && sha256sum "$TARBALL" > SHA256SUMS)
else
    (cd "$FIXTURE" && shasum -a 256 "$TARBALL" > SHA256SUMS)
fi
printf '%s\n' '{"synthetic":"non-empty provenance bundle"}' \
    >"$FIXTURE/attestations.jsonl"

cat >"$MOCK_BIN/gh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$COOP_TEST_GH_LOG"

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
    cp "$COOP_TEST_FIXTURE/$pattern" "$destination/$pattern"
    exit 0
fi

if [ "$1 $2" = "attestation verify" ]; then
    [ "${COOP_TEST_GH_VERIFY_FAIL:-0}" != "1" ] || exit 42
    bundle=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--bundle" ]; then
            bundle="$2"
            break
        fi
        shift
    done
    if [ "${COOP_TEST_GH_REQUIRE_BUNDLE:-0}" = "1" ]; then
        [ -n "$bundle" ] && [ -s "$bundle" ] || exit 43
    fi
    exit 0
fi

exit 44
STUB

cat >"$MOCK_BIN/curl" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$COOP_TEST_CURL_LOG"
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
        [ "${COOP_TEST_BUNDLE_FAIL:-0}" != "1" ] || exit 22
        cp "$COOP_TEST_FIXTURE/attestations.jsonl" "$destination"
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
        COOP_TEST_FIXTURE="$FIXTURE" \
        COOP_TEST_GH_LOG="$GH_LOG" \
        COOP_TEST_CURL_LOG="$CURL_LOG" \
        COOP_TEST_GH_REQUIRE_BUNDLE="${COOP_TEST_GH_REQUIRE_BUNDLE:-0}" \
        COOP_TEST_GH_VERIFY_FAIL="${COOP_TEST_GH_VERIFY_FAIL:-0}" \
        COOP_TEST_BUNDLE_FAIL="${COOP_TEST_BUNDLE_FAIL:-0}" \
        bash "$PROJECT_DIR/install.sh"
}

echo "==> Test 1: published bundle is downloaded anonymously and verified"
: >"$GH_LOG"
: >"$CURL_LOG"
COOP_TEST_GH_REQUIRE_BUNDLE=1
export COOP_TEST_GH_REQUIRE_BUNDLE
if run_installer >"$TEST_ROOT/t1.log" 2>&1; then
    pass "install succeeds with a published attestation bundle"
else
    fail "install succeeds with a published attestation bundle" \
        "$(tail -10 "$TEST_ROOT/t1.log")"
fi
unset COOP_TEST_GH_REQUIRE_BUNDLE

if "$INSTALL_DIR/coop" | grep -q '^installed-coop$' \
    && "$INSTALL_DIR/coop-proxy" | grep -q '^installed-coop-proxy$'; then
    pass "installer extracts coop and coop-proxy"
    if [[ "$TRIPLE" == aarch64-apple-darwin ]]; then
        if [[ "$("$INSTALL_DIR/coop-sandbox")" == installed-coop-sandbox ]]; then
            pass "installer installs the Apple runtime"
        else
            fail "installer installs the Apple runtime"
        fi
    fi
else
    fail "installer extracts coop and coop-proxy"
fi

if grep -q 'attestation verify .* --repo chr33s/coop --bundle ' "$GH_LOG"; then
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
printf '%s\n' 'keep-existing-install' >"$INSTALL_DIR/coop"
printf '%s\n' 'keep-existing-proxy' >"$INSTALL_DIR/coop-proxy"
COOP_TEST_GH_VERIFY_FAIL=1
export COOP_TEST_GH_VERIFY_FAIL
if run_installer >"$TEST_ROOT/t2.log" 2>&1; then
    fail "failed bundle verification aborts installation" "installer exited 0"
elif grep -q "Attestation verification failed" "$TEST_ROOT/t2.log" \
    && [[ "$(cat "$INSTALL_DIR/coop")" == "keep-existing-install" \
       && "$(cat "$INSTALL_DIR/coop-proxy")" == "keep-existing-proxy" ]]; then
    pass "failed bundle verification leaves both installed binaries unchanged"
else
    fail "failed bundle verification leaves both installed binaries unchanged" \
        "$(tail -10 "$TEST_ROOT/t2.log")"
fi
unset COOP_TEST_GH_VERIFY_FAIL

echo "==> Test 3: releases without a usable bundle retain API fallback"
: >"$GH_LOG"
COOP_TEST_BUNDLE_FAIL=1
export COOP_TEST_BUNDLE_FAIL
if run_installer >"$TEST_ROOT/t3.log" 2>&1; then
    pass "installer falls back for a pre-bundle release"
else
    fail "installer falls back for a pre-bundle release" \
        "$(tail -10 "$TEST_ROOT/t3.log")"
fi
unset COOP_TEST_BUNDLE_FAIL

if grep -q 'attestation verify .* --repo chr33s/coop$' "$GH_LOG" \
    && ! grep -q -- '--bundle' "$GH_LOG"; then
    pass "legacy fallback verifies through the attestations API"
else
    fail "legacy fallback verifies through the attestations API" "gh calls: $(cat "$GH_LOG")"
fi

echo "==> Test 4: checksum rejection preserves both binaries"
printf '%s\n' 'keep-existing-install' >"$INSTALL_DIR/coop"
printf '%s\n' 'keep-existing-proxy' >"$INSTALL_DIR/coop-proxy"
printf '%064d  %s\n' 0 "$TARBALL" >"$FIXTURE/SHA256SUMS"
if run_installer >"$TEST_ROOT/t4.log" 2>&1; then
    fail "checksum mismatch aborts installation" "installer exited 0"
elif grep -q "Checksum mismatch" "$TEST_ROOT/t4.log" \
    && [[ "$(cat "$INSTALL_DIR/coop")" == "keep-existing-install" \
       && "$(cat "$INSTALL_DIR/coop-proxy")" == "keep-existing-proxy" ]]; then
    pass "checksum mismatch leaves both installed binaries unchanged"
else
    fail "checksum mismatch leaves both installed binaries unchanged" \
        "$(tail -10 "$TEST_ROOT/t4.log")"
fi

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$FIXTURE" && sha256sum "$TARBALL" > SHA256SUMS)
else
    (cd "$FIXTURE" && shasum -a 256 "$TARBALL" > SHA256SUMS)
fi

echo "==> Test 5: reinstall replaces both existing binaries"
if run_installer >"$TEST_ROOT/t5.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/coop")" == "installed-coop" \
       && "$("$INSTALL_DIR/coop-proxy")" == "installed-coop-proxy" ]]; then
    pass "reinstall replaces both binaries with verified release contents"
else
    fail "reinstall replaces both binaries with verified release contents" \
        "$(tail -10 "$TEST_ROOT/t5.log")"
fi

echo "==> Test 6: missing companion policy"
rm "$FIXTURE/$ARCHIVE_DIR/coop-proxy"
(cd "$FIXTURE" && tar -czf "$TARBALL" "$ARCHIVE_DIR")
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$FIXTURE" && sha256sum "$TARBALL" > SHA256SUMS)
else
    (cd "$FIXTURE" && shasum -a 256 "$TARBALL" > SHA256SUMS)
fi
printf '%s\n' 'old-coop' >"$INSTALL_DIR/coop"
if [[ "$TRIPLE" == aarch64-apple-darwin ]]; then
    if ! run_installer >"$TEST_ROOT/t6.log" 2>&1 \
        && [[ "$(cat "$INSTALL_DIR/coop")" == old-coop ]]; then
        pass "Apple install rejects missing companion before host replacement"
    else
        fail "Apple install rejects missing companion before host replacement"
    fi
else
if run_installer >"$TEST_ROOT/t6.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/coop")" == "installed-coop" \
       && "$("$INSTALL_DIR/coop-proxy")" == "installed-coop-proxy" ]]; then
    pass "legacy install replaces coop and preserves the existing companion"
else
    fail "legacy install replaces coop and preserves the existing companion" \
        "$(tail -10 "$TEST_ROOT/t6.log")"
fi
fi

repack_fixture() {
    (cd "$FIXTURE" && tar -czf "$TARBALL" "$ARCHIVE_DIR")
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$FIXTURE" && sha256sum "$TARBALL" > SHA256SUMS)
    else
        (cd "$FIXTURE" && shasum -a 256 "$TARBALL" > SHA256SUMS)
    fi
}

echo "==> Test 7: Swift-only package installs its proxy"
printf '#!/bin/sh\necho coop-proxy\n' >"$FIXTURE/$ARCHIVE_DIR/coop-proxy"
if [[ "$TRIPLE" == aarch64-apple-darwin ]]; then
    mv "$FIXTURE/$ARCHIVE_DIR/coop-sandbox" "$FIXTURE/runtime-backup"
    repack_fixture
    printf '%s\n' keep-host >"$INSTALL_DIR/coop"
    printf '%s\n' keep-runtime >"$INSTALL_DIR/coop-sandbox"
    printf '%s\n' keep-proxy >"$INSTALL_DIR/coop-proxy"
    if ! run_installer >"$TEST_ROOT/missing-runtime.log" 2>&1 \
        && [[ "$(cat "$INSTALL_DIR/coop")" == keep-host \
           && "$(cat "$INSTALL_DIR/coop-sandbox")" == keep-runtime \
           && "$(cat "$INSTALL_DIR/coop-proxy")" == keep-proxy ]]; then
        pass "missing Apple runtime preserves all installed binaries"
    else
        fail "missing Apple runtime preserves all installed binaries"
    fi
    mv "$FIXTURE/runtime-backup" "$FIXTURE/$ARCHIVE_DIR/coop-sandbox"
fi
repack_fixture
if run_installer >"$TEST_ROOT/t7.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/coop-proxy")" == coop-proxy ]]; then
    pass "verified transition package installs the Swift executable"
else
    fail "verified transition package installs the Swift executable" "$(tail -10 "$TEST_ROOT/t7.log")"
fi

echo "==> Test 8: obsolete Rust package is rejected before replacement"
rm "$FIXTURE/$ARCHIVE_DIR/coop-proxy"
printf old-rust >"$FIXTURE/$ARCHIVE_DIR/coop-proxy-rs"
printf '%s\n' keep-host >"$INSTALL_DIR/coop"
printf '%s\n' keep-rust >"$INSTALL_DIR/coop-proxy-rs"
printf '%s\n' keep-swift >"$INSTALL_DIR/coop-proxy-swift"
repack_fixture
if run_installer >"$TEST_ROOT/t8.log" 2>&1; then
    fail "obsolete Rust pair aborts installation"
elif grep -q 'obsolete proxy transition artifact' "$TEST_ROOT/t8.log" \
    && [[ "$(cat "$INSTALL_DIR/coop")" == keep-host \
       && "$(cat "$INSTALL_DIR/coop-proxy-rs")" == keep-rust \
       && "$(cat "$INSTALL_DIR/coop-proxy-swift")" == keep-swift ]]; then
    pass "obsolete Rust pair leaves all installed files unchanged"
else
    fail "obsolete Rust pair leaves all installed files unchanged" "$(tail -10 "$TEST_ROOT/t8.log")"
fi

echo "==> Test 9: legacy package removes stale transition selection"
rm "$FIXTURE/$ARCHIVE_DIR/coop-proxy-rs"
printf '#!/bin/sh\necho legacy-proxy\n' >"$FIXTURE/$ARCHIVE_DIR/coop-proxy"
repack_fixture
if run_installer >"$TEST_ROOT/t9.log" 2>&1 \
    && [[ "$("$INSTALL_DIR/coop-proxy")" == legacy-proxy \
       && ! -e "$INSTALL_DIR/coop-proxy-rs" && ! -e "$INSTALL_DIR/coop-proxy-swift" ]]; then
    pass "legacy package removes stale transition siblings"
else
    fail "legacy package removes stale transition siblings" "$(tail -10 "$TEST_ROOT/t9.log")"
fi

echo
echo "  $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
