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
# The installer reads these; a caller's values must not reach the default runs.
unset INSTALL_SKILL SKILL_DIRS
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
printf '#!/bin/sh\necho installed-iso-egress\n' >"$FIXTURE/$ARCHIVE_DIR/iso-egress"
chmod +x "$FIXTURE/$ARCHIVE_DIR/iso-egress"
printf '#!/bin/sh\necho installed-iso-macos-helper\n' >"$FIXTURE/$ARCHIVE_DIR/iso-macos-helper"
chmod +x "$FIXTURE/$ARCHIVE_DIR/iso-macos-helper"
chmod +x "$FIXTURE/$ARCHIVE_DIR/iso-sandbox"
chmod +x "$FIXTURE/$ARCHIVE_DIR/iso" "$FIXTURE/$ARCHIVE_DIR/iso-proxy"
# Linux `desktop` images' guest files (optional members of a release).
printf 'installed-iso-cu-mcp\n' >"$FIXTURE/$ARCHIVE_DIR/iso-cu-mcp"
printf 'installed-vmlinux-desktop\n' >"$FIXTURE/$ARCHIVE_DIR/vmlinux-desktop"
mkdir -p "$FIXTURE/$ARCHIVE_DIR/skills/iso/references"
printf '%s\n' 'release-skill' >"$FIXTURE/$ARCHIVE_DIR/skills/iso/SKILL.md"
printf '%s\n' 'release-reference' >"$FIXTURE/$ARCHIVE_DIR/skills/iso/references/machine-interface.md"
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
        HOME="$TEST_ROOT/home" \
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

for artifact in iso iso-proxy iso-sandbox iso-egress iso-macos-helper; do
    if [[ "$("$INSTALL_DIR/$artifact")" == "installed-$artifact" ]]; then
        pass "installer installs $artifact"
    else
        fail "installer installs $artifact"
    fi
done
for artifact in iso-cu-mcp vmlinux-desktop; do
    if [[ "$(cat "$INSTALL_DIR/$artifact" 2>/dev/null)" == "installed-$artifact" ]]; then
        pass "installer installs the Linux guest file $artifact"
    else
        fail "installer installs the Linux guest file $artifact"
    fi
done

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

repack_fixture() {
    (cd "$FIXTURE" && tar -czf "$TARBALL" "$ARCHIVE_DIR")
    write_sums
}

seed_install() {
    for artifact in iso iso-sandbox iso-proxy iso-egress iso-macos-helper; do
        printf '%s\n' "keep-$artifact" >"$INSTALL_DIR/$artifact"
    done
}

install_unchanged() {
    for artifact in iso iso-sandbox iso-proxy iso-egress iso-macos-helper; do
        [[ "$(cat "$INSTALL_DIR/$artifact")" == "keep-$artifact" ]] || return 1
    done
}

echo "==> Test 6: every release binary is required before replacement"
for missing in iso iso-sandbox iso-proxy iso-egress iso-macos-helper; do
    mv "$FIXTURE/$ARCHIVE_DIR/$missing" "$FIXTURE/missing-backup"
    repack_fixture
    seed_install
    if ! run_installer >"$TEST_ROOT/missing-$missing.log" 2>&1 \
        && grep -q "Release is missing a regular $missing binary" "$TEST_ROOT/missing-$missing.log" \
        && install_unchanged; then
        pass "missing $missing preserves every installed binary"
    else
        fail "missing $missing preserves every installed binary" "$(tail -10 "$TEST_ROOT/missing-$missing.log")"
    fi
    mv "$FIXTURE/missing-backup" "$FIXTURE/$ARCHIVE_DIR/$missing"
done

echo "==> Test 7: symlink artifacts are rejected before replacement"
mv "$FIXTURE/$ARCHIVE_DIR/iso-egress" "$FIXTURE/egress-backup"
ln -s iso-proxy "$FIXTURE/$ARCHIVE_DIR/iso-egress"
repack_fixture
seed_install
if ! run_installer >"$TEST_ROOT/symlink.log" 2>&1 \
    && grep -q "Release is missing a regular iso-egress binary" "$TEST_ROOT/symlink.log" \
    && install_unchanged; then
    pass "symlink companion preserves every installed binary"
else
    fail "symlink companion preserves every installed binary" "$(tail -10 "$TEST_ROOT/symlink.log")"
fi
rm "$FIXTURE/$ARCHIVE_DIR/iso-egress"
mv "$FIXTURE/egress-backup" "$FIXTURE/$ARCHIVE_DIR/iso-egress"
repack_fixture
if run_installer >"$TEST_ROOT/complete.log" 2>&1; then
    for artifact in iso iso-sandbox iso-proxy iso-egress iso-macos-helper; do
        if [[ "$("$INSTALL_DIR/$artifact")" == "installed-$artifact" ]]; then
            pass "complete release replaces $artifact"
        else
            fail "complete release replaces $artifact"
        fi
    done
else
    fail "complete release installs successfully" "$(tail -10 "$TEST_ROOT/complete.log")"
fi

echo "==> Test 8: releases before iso-macos-helper point to their own installer"
seed_install
: >"$GH_LOG"
if ! VERSION="v0.2.0" run_installer >"$TEST_ROOT/old.log" 2>&1 \
    && grep -q "raw.githubusercontent.com/chr33s/iso/v0.2.0/install.sh" "$TEST_ROOT/old.log" \
    && [[ ! -s "$GH_LOG" ]] && install_unchanged; then
    pass "v0.2.0 is refused before any download"
else
    fail "v0.2.0 is refused before any download" "$(tail -10 "$TEST_ROOT/old.log")"
fi

skill_installed() {
    local target
    for target in "$@"; do
        [[ "$(cat "$target/iso/SKILL.md")" == "release-skill" \
           && "$(cat "$target/iso/references/machine-interface.md")" == "release-reference" ]] \
            || return 1
    done
}

echo "==> Test 9: the agent skill is opt-in"
rm -rf "${TEST_ROOT:?}/home"
if run_installer >"$TEST_ROOT/skill-default.log" 2>&1 \
    && grep -q "INSTALL_SKILL=1" "$TEST_ROOT/skill-default.log" \
    && [[ ! -e "$TEST_ROOT/home/.claude" && ! -e "$TEST_ROOT/home/.agents" ]]; then
    pass "default install writes no skill directory and names the opt-in"
else
    fail "default install writes no skill directory and names the opt-in" \
        "$(tail -10 "$TEST_ROOT/skill-default.log")"
fi

if INSTALL_SKILL=0 run_installer >"$TEST_ROOT/skill-zero.log" 2>&1 \
    && [[ ! -e "$TEST_ROOT/home/.claude" && ! -e "$TEST_ROOT/home/.agents" ]]; then
    pass "INSTALL_SKILL=0 writes no skill directory"
else
    fail "INSTALL_SKILL=0 writes no skill directory" "$(tail -10 "$TEST_ROOT/skill-zero.log")"
fi

SKILL_A="$TEST_ROOT/skills-a"
SKILL_B="$TEST_ROOT/skills b"
mkdir -p "$SKILL_A/iso" "$SKILL_A/other"
printf '%s\n' 'stale' >"$SKILL_A/iso/stale.md"
printf '%s\n' 'keep' >"$SKILL_A/other/SKILL.md"
# The empty entries are skipped.
if INSTALL_SKILL=1 SKILL_DIRS=":$SKILL_A::$SKILL_B:" run_installer >"$TEST_ROOT/skill.log" 2>&1 \
    && skill_installed "$SKILL_A" "$SKILL_B" \
    && [[ ! -e "$SKILL_A/iso/stale.md" && "$(cat "$SKILL_A/other/SKILL.md")" == "keep" ]] \
    && [[ -z "$(find "$SKILL_A" "$SKILL_B" -name '.iso-skill.*')" ]]; then
    pass "INSTALL_SKILL replaces only each target's iso skill"
else
    fail "INSTALL_SKILL replaces only each target's iso skill" "$(tail -10 "$TEST_ROOT/skill.log")"
fi

rm -rf "${TEST_ROOT:?}/home"
if INSTALL_SKILL=1 run_installer >"$TEST_ROOT/skill-home.log" 2>&1 \
    && skill_installed "$TEST_ROOT/home/.claude/skills" "$TEST_ROOT/home/.agents/skills"; then
    pass "INSTALL_SKILL defaults to the Claude Code and shared agent skill directories"
else
    fail "INSTALL_SKILL defaults to the Claude Code and shared agent skill directories" \
        "$(tail -10 "$TEST_ROOT/skill-home.log")"
fi

# A replaced skill would lose this marker.
printf '%s\n' 'existing' >"$SKILL_A/iso/marker"
skill_untouched() {
    skill_installed "$SKILL_A" && [[ "$(cat "$SKILL_A/iso/marker")" == "existing" ]]
}

# Each fixture breaks one property of a regular skill; the installer must
# install the binaries, warn, and leave the existing skill alone.
SKILL_FIXTURE="$FIXTURE/$ARCHIVE_DIR/skills"
refuses_skill() {
    local label="$1" log="$TEST_ROOT/skill-refused.log"
    repack_fixture
    if INSTALL_SKILL=1 SKILL_DIRS="$SKILL_A" run_installer >"$log" 2>&1 \
        && grep -q "has no regular agent skill" "$log" \
        && skill_untouched; then
        pass "$label installs the binaries and leaves the existing skill"
    else
        fail "$label installs the binaries and leaves the existing skill" "$(tail -10 "$log")"
    fi
}

mv "$SKILL_FIXTURE" "$FIXTURE/skills-backup"
refuses_skill "a release without the skill"
if run_installer >"$TEST_ROOT/skill-absent-default.log" 2>&1 \
    && ! grep -q "INSTALL_SKILL=1" "$TEST_ROOT/skill-absent-default.log"; then
    pass "a release without the skill does not name the opt-in"
else
    fail "a release without the skill does not name the opt-in" \
        "$(tail -10 "$TEST_ROOT/skill-absent-default.log")"
fi
mv "$FIXTURE/skills-backup" "$SKILL_FIXTURE"

ln -s /etc/hosts "$SKILL_FIXTURE/iso/references/leak"
refuses_skill "a skill holding a symlink"
rm "$SKILL_FIXTURE/iso/references/leak"

mkfifo "$SKILL_FIXTURE/iso/references/pipe"
refuses_skill "a skill holding a special file"
rm "$SKILL_FIXTURE/iso/references/pipe"

mv "$SKILL_FIXTURE/iso" "$SKILL_FIXTURE/real"
ln -s real "$SKILL_FIXTURE/iso"
refuses_skill "a symlinked skill directory"
rm "$SKILL_FIXTURE/iso"
mv "$SKILL_FIXTURE/real" "$SKILL_FIXTURE/iso"

mv "$SKILL_FIXTURE/iso/SKILL.md" "$FIXTURE/skill-md-backup"
refuses_skill "a skill without SKILL.md"
mv "$FIXTURE/skill-md-backup" "$SKILL_FIXTURE/iso/SKILL.md"
repack_fixture

# An entry the installer cannot remove fails that target only: no staging
# directory is left behind, the other target is installed, and the run fails.
SKILL_LOCKED="$TEST_ROOT/skills-locked"
SKILL_C="$TEST_ROOT/skills-c"
mkdir -p "$SKILL_LOCKED/iso/locked"
: >"$SKILL_LOCKED/iso/locked/file"
chmod 555 "$SKILL_LOCKED/iso/locked"
if ! INSTALL_SKILL=1 SKILL_DIRS="$SKILL_LOCKED:$SKILL_C" run_installer >"$TEST_ROOT/skill-locked.log" 2>&1 \
    && grep -q "Could not install the agent skill to $SKILL_LOCKED/iso" "$TEST_ROOT/skill-locked.log" \
    && grep -q "the agent skill was not installed everywhere" "$TEST_ROOT/skill-locked.log" \
    && [[ -z "$(find "$SKILL_LOCKED" -name '.iso-skill.*')" ]] \
    && skill_installed "$SKILL_C" \
    && [[ "$("$INSTALL_DIR/iso")" == "installed-iso" ]]; then
    pass "a failed skill target is cleaned up, reported, and does not stop the others"
else
    fail "a failed skill target is cleaned up, reported, and does not stop the others" \
        "$(tail -10 "$TEST_ROOT/skill-locked.log")"
fi
chmod 755 "$SKILL_LOCKED/iso/locked"

echo
echo "  $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
