#!/usr/bin/env bash
set -euo pipefail

# End-to-end test for `iso update`.
#
# Serves a synthetic GitHub-shaped fixture from a local HTTP server and
# verifies that the update flow downloads, checksums, and atomically
# replaces the running binary and its proxy companion. Also verifies checksum
# rollback, `--check` behaviour, and dev-build refusal. The release-kind test
# binary trusts a throwaway key generated here in place of the compiled-in
# release signer (see patch_release_signer); SHA256SUMS is signed with it.
#
# Run manually:   ./tests/integration-update.sh
# Run in CI:      same (fast — no VM, no external network)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Detach from the controlling terminal's stdin. iso gates interactive prompts
# (here, `update`'s confirmation) on stdin being a TTY. Every call below passes
# --yes or --check so no prompt fires today, but a future prompt-bearing case
# run from an interactive shell (the release preflight) would read real
# keystrokes and block — under CI stdin is already not a TTY, so it would never
# be caught there. Redirecting the whole script makes every iso subprocess see
# a non-TTY stdin regardless of how the suite is invoked. The script itself
# never reads stdin.
exec </dev/null

# ── Platform detection (matches install.sh) ─────────────────────────────────

detect_triple() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "${os}-${arch}" in
        Darwin-arm64)   echo "aarch64-apple-darwin" ;;
        Darwin-aarch64) echo "aarch64-apple-darwin" ;;
        *)
            echo "Unsupported platform: ${os}-${arch}" >&2
            exit 1
            ;;
    esac
}

TARGET_TRIPLE="$(detect_triple)"
FAKE_TAG="v9.9.9"
FAKE_DIR="iso-${FAKE_TAG}-${TARGET_TRIPLE}"
FAKE_TARBALL="${FAKE_DIR}.tar.gz"

# ── Temp workspace + server lifecycle ────────────────────────────────────────

TMPDIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2> /dev/null; then
        kill "$SERVER_PID" 2> /dev/null || true
        wait "$SERVER_PID" 2> /dev/null || true
    fi
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

FIXTURE="$TMPDIR/fixture"
mkdir -p "$FIXTURE/repos/chr33s/iso/releases/tags"
mkdir -p "$TMPDIR/bin" "$TMPDIR/build/${FAKE_DIR}"

# ── Helpers ──────────────────────────────────────────────────────────────────

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

if command -v sha256sum > /dev/null 2>&1; then
    SHA256_CMD=(sha256sum)
elif command -v shasum > /dev/null 2>&1; then
    SHA256_CMD=(shasum -a 256)
else
    echo "Neither sha256sum nor shasum is available" >&2
    exit 1
fi

sha_of() {
    "${SHA256_CMD[@]}" "$1" | cut -d' ' -f1
}

sha256sums_line() {
    "${SHA256_CMD[@]}" "$1"
}

SIGNING_KEY="$TMPDIR/release-key"
ssh-keygen -q -t ed25519 -N '' -C iso-test-release -f "$SIGNING_KEY"
NAMESPACE="release-sums@chr33s"

sign_sums() {
    ssh-keygen -q -Y sign -f "${1:-$SIGNING_KEY}" -n "$NAMESPACE" \
        < "$FIXTURE/SHA256SUMS" > "$FIXTURE/SHA256SUMS.sig"
}

write_sums() {
    (cd "$FIXTURE" && sha256sums_line "${FAKE_TARBALL}" > SHA256SUMS)
    sign_sums
}

# Swaps the one compiled-in release signer key in a copied binary for the test
# key (both are 68-character ssh-ed25519 base64 strings) and re-signs it ad
# hoc. Fails unless the shipped key occurs exactly once.
patch_release_signer() {
    local binary="$1" shipped test_key
    shipped="$(grep -o 'AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/=]*' "$PROJECT_DIR/.github/release-signers")"
    test_key="$(cut -d' ' -f2 "$SIGNING_KEY.pub")"
    python3 - "$binary" "$shipped" "$test_key" << 'PATCH'
import sys
path, old, new = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
data = open(path, "rb").read()
if len(old) != len(new) or data.count(old) != 1:
    sys.exit(f"FATAL: expected one {len(old)}-byte release signer in {path}, found {data.count(old)}")
open(path, "wb").write(data.replace(old, new))
PATCH
    codesign --force --sign - "$binary" 2> /dev/null
}

write_release_json() {
    local path="$1" tag="$2" assets_block="$3"
    cat > "$path" << JSON
{
  "tag_name": "${tag}",
  "assets": ${assets_block}
}
JSON
}

full_assets_block() {
    cat << JSON
[
  {"name": "${FAKE_TARBALL}", "browser_download_url": "${BASE_URL}/${FAKE_TARBALL}"},
  {"name": "SHA256SUMS", "browser_download_url": "${BASE_URL}/SHA256SUMS"},
  {"name": "SHA256SUMS.sig", "browser_download_url": "${BASE_URL}/SHA256SUMS.sig"}
]
JSON
}

# ── Build both iso binaries (real HOME, before isolation) ───────────────────
#
# Both `swift build` invocations must run before HOME is redirected — SwiftPM
# uses $HOME for its caches. A build is a release build only when compiled with
# `-D ISO_RELEASE_BUILD` (as scripts/build-release.py --release does); every
# other build is a dev build regardless of git state. The release-kind build
# gets its own scratch path so the flag never invalidates the ordinary one.
# ISO_SWIFT_SCRATCH_PATH overrides the default `.build` scratch path.

SWIFT_SCRATCH="${ISO_SWIFT_SCRATCH_PATH:-$PROJECT_DIR/.build}"

# Prints the built binary's path; build output goes to stderr.
build_iso() {
    local scratch="$1"
    shift
    swift build --package-path "$PROJECT_DIR" --scratch-path "$scratch" \
        --product iso --force-resolved-versions --quiet "$@" >&2
    printf '%s/iso\n' "$(swift build --package-path "$PROJECT_DIR" --scratch-path "$scratch" \
        --show-bin-path "$@")"
}

echo "==> Building release binary..."
# Copy both binaries out of the build tree: tests replace $ISO_BIN in place.
RELEASE_BIN="$TMPDIR/bin/iso-release"
cp "$(build_iso "${SWIFT_SCRATCH}-release-kind" -Xswiftc -DISO_RELEASE_BUILD)" "$RELEASE_BIN"
patch_release_signer "$RELEASE_BIN"
cp "$RELEASE_BIN" "$TMPDIR/bin/iso"
export ISO_BIN="$TMPDIR/bin/iso"

echo "==> Building dev binary..."
cp "$(build_iso "$SWIFT_SCRATCH")" "$TMPDIR/bin/iso-dev"

# ── Isolate test invocations from the real user environment ──────────────────
#
# `iso update --yes` writes an "update-check" bookkeeping file recording the
# latest release it learned about. Pointed at our local fixture, that file
# would record the synthetic v9.9.9 tag — and it lives under
# `$HOME/Library/Application Support/iso`, so without redirection the file
# lands in the user's real home and triggers a bogus "newer version available"
# warning on every later run.
#
# Redirecting $HOME (the XDG vars are kept for completeness) is enough: the
# update path doesn't read from anywhere else under the user's home.
export HOME="$TMPDIR/home"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$XDG_STATE_HOME" "$XDG_DATA_HOME"

# ── Fabricate a "newer" release tarball ──────────────────────────────────────

cat > "$TMPDIR/build/${FAKE_DIR}/iso" << 'EOF'
#!/bin/sh
echo "MARKER: fake-replacement-binary"
EOF
cat > "$TMPDIR/build/${FAKE_DIR}/iso-proxy" << 'EOF'
#!/bin/sh
echo "MARKER: fake-proxy-binary"
EOF
printf '#!/bin/sh\necho installed-iso-sandbox\n' >"$TMPDIR/build/${FAKE_DIR}/iso-sandbox"
chmod +x "$TMPDIR/build/${FAKE_DIR}/iso-sandbox"
chmod +x "$TMPDIR/build/${FAKE_DIR}/iso" "$TMPDIR/build/${FAKE_DIR}/iso-proxy"
(cd "$TMPDIR/build" && tar -czf "$FIXTURE/${FAKE_TARBALL}" "$FAKE_DIR")
write_sums

# ── Start local HTTP server ──────────────────────────────────────────────────

PICK_PORT='import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
PORT="$(python3 -c "$PICK_PORT")"
(cd "$FIXTURE" && python3 -m http.server "$PORT" > /dev/null 2>&1) &
SERVER_PID=$!
BASE_URL="http://127.0.0.1:${PORT}"

# Wait for server readiness
for _ in $(seq 1 30); do
    if curl -fsS "${BASE_URL}/SHA256SUMS" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if ! curl -fsS "${BASE_URL}/SHA256SUMS" > /dev/null 2>&1; then
    echo "FATAL: local HTTP server did not come up on ${BASE_URL}" >&2
    exit 1
fi

export ISO_UPDATE_API_BASE_URL="$BASE_URL"

# ── Test 1: success flow ─────────────────────────────────────────────────────

write_release_json \
    "$FIXTURE/repos/chr33s/iso/releases/latest" \
    "$FAKE_TAG" \
    "$(full_assets_block)"

echo "==> Test 1: successful update replaces binary"
if "$ISO_BIN" update --yes > "$TMPDIR/t1.log" 2>&1; then
    out="$("$ISO_BIN" 2>&1 || true)"
    if echo "$out" | grep -q "MARKER: fake-replacement-binary"; then
        pass "update --yes replaces binary with release contents"
    else
        fail "update --yes left binary unchanged" "got: ${out}"
    fi
else
    fail "update --yes returned non-zero" "$(tail -5 "$TMPDIR/t1.log")"
fi

if [[ "$TARGET_TRIPLE" == aarch64-apple-darwin ]]; then
    if [[ "$("$TMPDIR/bin/iso-sandbox")" == installed-iso-sandbox ]]; then
        pass "update installs the Apple runtime"
    else
        fail "update installs the Apple runtime"
    fi
fi
if [[ -x "$TMPDIR/bin/iso-proxy" ]] \
    && [[ "$("$TMPDIR/bin/iso-proxy")" == "MARKER: fake-proxy-binary" ]]; then
    pass "update installs the missing proxy companion"
else
    fail "update installs the missing proxy companion" "expected release proxy contents"
fi

# Confirm the update-check state file landed inside the test's tempdir,
# not somewhere under the developer's real home. Searching $TMPDIR (not
# $HOME) is deliberate: if a future edit accidentally drops the HOME
# export above, $HOME would point back at the real home and a leak there
# would still be "found" — the assertion would silently pass on the leak
# it was meant to catch. $TMPDIR is the known-isolated boundary.
state_under_tmpdir="$(find "$TMPDIR" -name update-check.json -print -quit 2> /dev/null)"
if [[ -n "$state_under_tmpdir" ]]; then
    pass "update-check state file confined to tempdir"
else
    fail "no update-check state file written under tempdir" \
        "either HOME redirection broke or the update-check state was not persisted"
fi

# ── Test 2: --check when already up to date ──────────────────────────────────

# Restore the real binary; point "latest" at its version.
cp "$RELEASE_BIN" "$ISO_BIN"
CURRENT_VERSION="$("$ISO_BIN" --version | awk '{print $2}')"
write_release_json \
    "$FIXTURE/repos/chr33s/iso/releases/latest" \
    "v${CURRENT_VERSION}" \
    "[]"

echo "==> Test 2: --check reports up-to-date"
if out="$("$ISO_BIN" update --check 2>&1)"; then
    if echo "$out" | grep -qi "up to date"; then
        pass "--check emits up-to-date message"
    else
        fail "--check did not mention up-to-date" "got: ${out}"
    fi
else
    fail "--check exited non-zero" "$out"
fi

# ── Test 3: checksum mismatch leaves binary unchanged ────────────────────────

cp "$RELEASE_BIN" "$ISO_BIN"
ORIG_SHA="$(sha_of "$ISO_BIN")"
printf '%s\n' 'keep-existing-proxy' > "$TMPDIR/bin/iso-proxy"
ORIG_PROXY_SHA="$(sha_of "$TMPDIR/bin/iso-proxy")"

# Restore the newer-release fixture but corrupt SHA256SUMS.
write_release_json \
    "$FIXTURE/repos/chr33s/iso/releases/latest" \
    "$FAKE_TAG" \
    "$(full_assets_block)"
echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ${FAKE_TARBALL}" \
    > "$FIXTURE/SHA256SUMS"
sign_sums

echo "==> Test 3: checksum mismatch aborts"
if "$ISO_BIN" update --yes > "$TMPDIR/t3.log" 2>&1; then
    fail "update --yes should have failed on checksum mismatch"
else
    new_sha="$(sha_of "$ISO_BIN")"
    if grep -q "SHA-256 mismatch" "$TMPDIR/t3.log" \
        && [[ "$new_sha" == "$ORIG_SHA" \
           && "$(sha_of "$TMPDIR/bin/iso-proxy")" == "$ORIG_PROXY_SHA" ]]; then
        pass "checksum mismatch leaves both binaries unchanged"
    else
        fail "checksum rejection must preserve both binaries" "$(tail -5 "$TMPDIR/t3.log")"
    fi
fi

# Restore valid SHA256SUMS for subsequent tests.
write_sums

# ── Test 3a: SHA256SUMS signature is mandatory ──────────────────────────────

echo "==> Test 3a: untrusted or missing signature aborts"
ssh-keygen -q -t ed25519 -N '' -C untrusted -f "$TMPDIR/untrusted-key"
sign_sums "$TMPDIR/untrusted-key"
if "$ISO_BIN" update --yes > "$TMPDIR/t3a.log" 2>&1; then
    fail "update --yes should have failed on an untrusted signer"
elif grep -q "not a trusted release signer" "$TMPDIR/t3a.log" \
    && [[ "$(sha_of "$ISO_BIN")" == "$ORIG_SHA" \
       && "$(sha_of "$TMPDIR/bin/iso-proxy")" == "$ORIG_PROXY_SHA" ]]; then
    pass "untrusted signer leaves both binaries unchanged"
else
    fail "untrusted signer must preserve both binaries" "$(tail -5 "$TMPDIR/t3a.log")"
fi

write_release_json \
    "$FIXTURE/repos/chr33s/iso/releases/latest" \
    "$FAKE_TAG" \
    "[{\"name\": \"${FAKE_TARBALL}\", \"browser_download_url\": \"${BASE_URL}/${FAKE_TARBALL}\"},
      {\"name\": \"SHA256SUMS\", \"browser_download_url\": \"${BASE_URL}/SHA256SUMS\"}]"
if "$ISO_BIN" update --yes > "$TMPDIR/t3b.log" 2>&1; then
    fail "update --yes should have failed without SHA256SUMS.sig"
elif grep -q "publishes no SHA256SUMS.sig" "$TMPDIR/t3b.log" \
    && [[ "$(sha_of "$ISO_BIN")" == "$ORIG_SHA" \
       && "$(sha_of "$TMPDIR/bin/iso-proxy")" == "$ORIG_PROXY_SHA" ]]; then
    pass "missing signature leaves both binaries unchanged"
else
    fail "missing signature must preserve both binaries" "$(tail -5 "$TMPDIR/t3b.log")"
fi
write_release_json \
    "$FIXTURE/repos/chr33s/iso/releases/latest" \
    "$FAKE_TAG" \
    "$(full_assets_block)"
sign_sums

# ── Test 4: dev build refuses to self-update ─────────────────────────────────

echo "==> Test 4: dev build refusal"
if "$TMPDIR/bin/iso-dev" update --yes > "$TMPDIR/t4.log" 2>&1; then
    fail "dev build should have refused"
else
    if grep -qi "dev build" "$TMPDIR/t4.log"; then
        pass "dev build refuses update"
    else
        fail "dev-build refusal message missing" "$(cat "$TMPDIR/t4.log")"
    fi
fi

# ── Test 5: update replaces an existing companion ───────────────────────────

echo "==> Test 5: update replaces both existing binaries"
cp "$RELEASE_BIN" "$ISO_BIN"
if "$ISO_BIN" update --yes > "$TMPDIR/t5.log" 2>&1 \
    && [[ "$("$ISO_BIN")" == "MARKER: fake-replacement-binary" \
       && "$("$TMPDIR/bin/iso-proxy")" == "MARKER: fake-proxy-binary" ]]; then
    pass "update replaces the existing iso and iso-proxy"
else
    fail "update replaces the existing iso and iso-proxy" "$(tail -5 "$TMPDIR/t5.log")"
fi

# ── Test 6: older packages without a companion remain supported ──────────────

echo "==> Test 6: legacy update without a proxy"
cp "$RELEASE_BIN" "$ISO_BIN"
rm "$TMPDIR/build/${FAKE_DIR}/iso-proxy"
(cd "$TMPDIR/build" && tar -czf "$FIXTURE/${FAKE_TARBALL}" "$FAKE_DIR")
write_sums
ORIG_PROXY_SHA="$(sha_of "$TMPDIR/bin/iso-proxy")"
if [[ "$TARGET_TRIPLE" == aarch64-apple-darwin ]]; then
    original_host="$(sha_of "$ISO_BIN")"
    if ! "$ISO_BIN" update --yes >"$TMPDIR/t6.log" 2>&1 \
        && [[ "$(sha_of "$ISO_BIN")" == "$original_host" \
           && "$(sha_of "$TMPDIR/bin/iso-proxy")" == "$ORIG_PROXY_SHA" ]]; then
        pass "Apple update rejects missing companion before replacement"
    else
        fail "Apple update rejects missing companion before replacement"
    fi
else
if "$ISO_BIN" update --yes > "$TMPDIR/t6.log" 2>&1 \
    && [[ "$("$ISO_BIN")" == "MARKER: fake-replacement-binary" \
       && "$(sha_of "$TMPDIR/bin/iso-proxy")" == "$ORIG_PROXY_SHA" ]]; then
    pass "legacy update replaces iso and preserves the existing companion"
else
    fail "legacy update replaces iso and preserves the existing companion" "$(tail -5 "$TMPDIR/t6.log")"
fi
fi

repack_transition_fixture() {
    (cd "$TMPDIR/build" && tar -czf "$FIXTURE/${FAKE_TARBALL}" "$FAKE_DIR")
    write_sums
}

echo "==> Test 7: verified Swift-only update installs its proxy"
cp "$RELEASE_BIN" "$ISO_BIN"
printf '#!/bin/sh\necho iso-proxy\n' >"$TMPDIR/build/${FAKE_DIR}/iso-proxy"
if [[ "$TARGET_TRIPLE" == aarch64-apple-darwin ]]; then
    mv "$TMPDIR/build/${FAKE_DIR}/iso-sandbox" "$TMPDIR/runtime-backup"
    repack_transition_fixture
    original_host="$(sha_of "$ISO_BIN")"
    printf '%s\n' keep-runtime >"$TMPDIR/bin/iso-sandbox"
    printf '%s\n' keep-proxy >"$TMPDIR/bin/iso-proxy"
    if ! "$ISO_BIN" update --yes >"$TMPDIR/missing-runtime.log" 2>&1 \
        && [[ "$(sha_of "$ISO_BIN")" == "$original_host" \
           && "$(cat "$TMPDIR/bin/iso-sandbox")" == keep-runtime \
           && "$(cat "$TMPDIR/bin/iso-proxy")" == keep-proxy ]]; then
        pass "missing Apple runtime preserves all installed binaries"
    else
        fail "missing Apple runtime preserves all installed binaries"
    fi
    mv "$TMPDIR/runtime-backup" "$TMPDIR/build/${FAKE_DIR}/iso-sandbox"
fi
repack_transition_fixture
if "$ISO_BIN" update --yes >"$TMPDIR/t7.log" 2>&1 \
    && [[ "$("$ISO_BIN")" == "MARKER: fake-replacement-binary" \
       && "$("$TMPDIR/bin/iso-proxy")" == iso-proxy ]]; then
    pass "transition update installs the Swift proxy"
else
    fail "transition update installs the Swift proxy" "$(tail -5 "$TMPDIR/t7.log")"
fi

echo "==> Test 8: obsolete Rust archive preserves the installed generation"
cp "$RELEASE_BIN" "$ISO_BIN"
ORIG_SHA="$(sha_of "$ISO_BIN")"
printf '%s\n' keep-rust >"$TMPDIR/bin/iso-proxy-rs"
printf '%s\n' keep-swift >"$TMPDIR/bin/iso-proxy-swift"
rm "$TMPDIR/build/${FAKE_DIR}/iso-proxy"
printf old-rust >"$TMPDIR/build/${FAKE_DIR}/iso-proxy-rs"
repack_transition_fixture
if "$ISO_BIN" update --yes >"$TMPDIR/t8.log" 2>&1; then
    fail "obsolete Rust update must fail"
elif grep -q 'obsolete proxy transition artifact' "$TMPDIR/t8.log" \
    && [[ "$(sha_of "$ISO_BIN")" == "$ORIG_SHA" \
       && "$(cat "$TMPDIR/bin/iso-proxy-rs")" == keep-rust \
       && "$(cat "$TMPDIR/bin/iso-proxy-swift")" == keep-swift ]]; then
    pass "obsolete Rust update preserves host and both proxy siblings"
else
    fail "obsolete Rust update preserves host and both proxy siblings" "$(tail -5 "$TMPDIR/t8.log")"
fi

echo "==> Test 9: legacy update removes stale transition names"
cp "$RELEASE_BIN" "$ISO_BIN"
rm "$TMPDIR/build/${FAKE_DIR}/iso-proxy-rs"
printf '#!/bin/sh\necho legacy-proxy\n' >"$TMPDIR/build/${FAKE_DIR}/iso-proxy"
repack_transition_fixture
if "$ISO_BIN" update --yes >"$TMPDIR/t9.log" 2>&1 \
    && [[ "$("$ISO_BIN")" == "MARKER: fake-replacement-binary" \
       && "$("$TMPDIR/bin/iso-proxy")" == legacy-proxy \
       && ! -e "$TMPDIR/bin/iso-proxy-rs" && ! -e "$TMPDIR/bin/iso-proxy-swift" ]]; then
    pass "legacy update removes stale transition siblings"
else
    fail "legacy update removes stale transition siblings" "$(tail -5 "$TMPDIR/t9.log")"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "  $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
