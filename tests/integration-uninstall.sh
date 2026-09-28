#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# End-to-end test for `coop uninstall`.
#
# Runs the uninstall flow with HOME pointed at a throwaway tempdir, so the
# tests never touch the developer's real ~/.coop. Verifies:
#
#   1. --yes --keep-data removes the binary and leaves the data dir alone.
#   2. --yes --purge removes binary, data dir, update-check state, and
#      any coop SSH config blocks.
#   3. Non-interactive (non-TTY) without --yes exits non-zero with a hint.
#   4. The dev-build guard refuses to remove a binary that lives in a SwiftPM
#      build tree (`.build/{debug,release}` or `.build/<triple>/{debug,release}`).
#
# Run manually:   ./tests/integration-uninstall.sh
# Run in CI:      same (fast — no VM, no network)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Detach from the controlling terminal's stdin. coop gates interactive prompts
# (here, `uninstall`'s confirmation) on stdin being a TTY. The --yes calls skip
# it and Test 3 pins its own stdin to /dev/null, so nothing blocks today, but a
# future prompt-bearing case run from an interactive shell (the release
# preflight) would read real keystrokes and block — under CI stdin is already
# not a TTY, so it would never be caught there. Redirecting the whole script
# makes every coop subprocess see a non-TTY stdin regardless of how the suite is
# invoked. The script itself never reads stdin.
exec </dev/null

# ── Temp workspace ───────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

mkdir -p "$TMPDIR/bin" "$TMPDIR/home"

pass_count=0
fail_count=0

pass() {
    pass_count=$((pass_count + 1))
    echo "  PASS  $1"
}

fail() {
    fail_count=$((fail_count + 1))
    echo "  FAIL  $1"
    # Detail line ($2) is optional. Return 0 explicitly so that calling `fail`
    # with one argument under `set -e` doesn't abort the whole script — the
    # short-circuit `[[ -n "" ]] && echo` would otherwise propagate rc=1 out of
    # the function.
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
    return 0
}

# ── Build a binary and copy it out of the build tree ────────────────────────
#
# The uninstall command refuses to delete binaries under a SwiftPM build tree
# (`.build/{debug,release}` or `.build/<triple>/{debug,release}` — the
# dev-build guard). For the success-path tests we need a binary that *isn't*
# under that pattern, so we stash a copy in $TMPDIR/bin. Test 4 copies it into
# build-tree-shaped paths to exercise the guard without touching the real one.
# COOP_SWIFT_SCRATCH_PATH overrides the default `.build` scratch path.

echo "==> Building coop..."
SWIFT_SCRATCH="${COOP_SWIFT_SCRATCH_PATH:-$PROJECT_DIR/.build}"
swift build --package-path "$PROJECT_DIR" --scratch-path "$SWIFT_SCRATCH" \
    --product coop --force-resolved-versions --quiet
BUILT_BIN="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$SWIFT_SCRATCH" \
    --show-bin-path)/coop"
STABLE_BIN="$TMPDIR/bin/coop-stable"
cp "$BUILT_BIN" "$STABLE_BIN"

# ── Isolate $HOME / XDG dirs ─────────────────────────────────────────────────

export HOME="$TMPDIR/home"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$HOME/.ssh"

# Where coop writes the background update-check state. Must mirror
# `UpdateCheckState` in Sources/CoopHost/UpdateCheck.swift
# (~/Library/Application Support/coop/update-check.json on macOS).
case "$(uname -s)" in
    Darwin) STATE_FILE="$HOME/Library/Application Support/coop/update-check.json" ;;
    *)      STATE_FILE="$XDG_STATE_HOME/coop/update-check.json" ;;
esac

# Pre-populate the state file so we can assert it's wiped by --purge.
seed_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" << 'JSON'
{"last_checked_at": 0, "latest_known_version": "v9.9.9"}
JSON
}

# Match the owned state and SSH namespace of this target's default backend.
if [[ "$(uname -s)" == Darwin ]]; then
    DATA_DIR="$HOME/.coop/backends/apple-container-v1"
    CONFIG_DIR="$HOME/.coop"
    SSH_PREFIX="coop-apple"
else
    DATA_DIR="$HOME/.coop"
    CONFIG_DIR="$HOME/.coop"
    SSH_PREFIX="coop"
fi

# Pre-populate ~/.coop with stub files so we can assert it's preserved or wiped.
seed_data_dir() {
    local data_dir="$DATA_DIR"
    mkdir -p "$data_dir/images" "$data_dir/instances"
    # Write a config so configPathIsUnderDataDirectory has something to look at.
    mkdir -p "$CONFIG_DIR"
    printf '{}\n' > "$CONFIG_DIR/config.jsonc"
}

# Pre-populate ~/.ssh/config with a coop marker block; uninstall should strip
# it. Markers must match the `SSHConfigBlocks` markers in
# Sources/CoopHost/Uninstall.swift (`# <prefix> START <host>` and `# <prefix> END`).
SSH_MARKER_BEGIN="# $SSH_PREFIX START $SSH_PREFIX-uninstall-test"
SSH_MARKER_END="# $SSH_PREFIX END"
seed_ssh_config() {
    cat > "$HOME/.ssh/config" << EOF
$SSH_MARKER_BEGIN
Host $SSH_PREFIX-uninstall-test
    HostName 172.16.0.42
$SSH_MARKER_END

# unrelated user block
Host github.com
    User git
EOF
}

# Fresh copy of the binary at $TMPDIR/bin/coop for each test that removes it.
fresh_binary() {
    cp "$STABLE_BIN" "$TMPDIR/bin/coop"
}

if [[ "$(uname -s)" == Darwin ]]; then
    mkdir -p "$HOME/.coop/unrelated"
    printf '%s\n' unrelated >"$HOME/.coop/unrelated/sentinel"
fi

# ── Test 1: --yes --keep-data preserves the data directory ───────────────────

echo "==> Test 1: --yes --keep-data removes binary, keeps data"
fresh_binary
seed_data_dir
seed_state
seed_ssh_config

if "$TMPDIR/bin/coop" uninstall --yes --keep-data > "$TMPDIR/t1.log" 2>&1; then
    if [[ -e "$TMPDIR/bin/coop" ]]; then
        fail "binary still present after uninstall"
    else
        pass "binary removed"
    fi
    if [[ -d "$DATA_DIR" ]]; then
        pass "data directory preserved"
    else
        fail "data directory was removed despite --keep-data"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        pass "update-check state preserved"
    else
        fail "update-check state was removed despite --keep-data"
    fi
    if grep -q "$SSH_MARKER_BEGIN" "$HOME/.ssh/config"; then
        fail "SSH coop block not stripped" "blocks should be removed even with --keep-data"
    else
        pass "SSH coop blocks stripped"
    fi
    if grep -q "github.com" "$HOME/.ssh/config"; then
        pass "unrelated SSH blocks preserved"
    else
        fail "unrelated SSH content was clobbered"
    fi
else
    fail "uninstall --yes --keep-data exited non-zero" "$(tail -5 "$TMPDIR/t1.log")"
fi

# ── Test 2: --yes --purge wipes everything ───────────────────────────────────

echo "==> Test 2: --yes --purge removes binary + data + update-check state"
fresh_binary
seed_data_dir
seed_state
seed_ssh_config

if "$TMPDIR/bin/coop" uninstall --yes --purge > "$TMPDIR/t2.log" 2>&1; then
    if [[ -e "$TMPDIR/bin/coop" ]]; then
        fail "binary still present after --purge"
    else
        pass "binary removed"
    fi
    if [[ -d "$DATA_DIR" ]]; then
        fail "data directory still present after --purge"
    else
        pass "data directory removed"
    fi
    if [[ -e "$STATE_FILE" ]]; then
        fail "update-check state survived --purge" "expected $STATE_FILE to be removed"
    else
        pass "update-check state removed"
    fi
    if grep -q "$SSH_MARKER_BEGIN" "$HOME/.ssh/config" 2> /dev/null; then
        fail "SSH coop block survived --purge"
    else
        pass "SSH coop blocks stripped"
    fi
else
    fail "uninstall --yes --purge exited non-zero" "$(tail -5 "$TMPDIR/t2.log")"
fi

if [[ "$(uname -s)" == Darwin ]]; then
    if [[ -f "$CONFIG_DIR/config.jsonc" && "$(cat "$HOME/.coop/unrelated/sentinel")" == unrelated ]]; then
        pass "purge preserves config outside the owned backend root"
    else
        fail "purge removed config outside the owned backend root"
    fi
fi

# ── Test 3: non-TTY without --yes fails with a helpful message ───────────────

echo "==> Test 3: non-TTY without --yes errors"
fresh_binary
seed_data_dir

# stdin is already not a TTY when running under bash via the script harness;
# redirect from /dev/null to be explicit.
if "$TMPDIR/bin/coop" uninstall < /dev/null > "$TMPDIR/t3.log" 2>&1; then
    fail "uninstall without --yes succeeded in non-interactive mode"
elif grep -qi "not a tty" "$TMPDIR/t3.log" && grep -q -- "--yes" "$TMPDIR/t3.log"; then
    pass "non-TTY without --yes errors with --yes hint"
else
    fail "exit was non-zero but message lacks the --yes hint" \
        "$(tail -5 "$TMPDIR/t3.log")"
fi

if [[ -e "$TMPDIR/bin/coop" ]]; then
    pass "binary preserved after refusal"
else
    fail "binary removed despite refusal"
fi

# ── Test 4: dev-build guard refuses to remove SwiftPM build outputs ─────────

echo "==> Test 4: dev-build guard refuses .build binaries"
seed_data_dir

for guarded in "$TMPDIR/project/.build/debug/coop" \
    "$TMPDIR/project/.build/arm64-apple-macosx/release/coop"; do
    mkdir -p "$(dirname "$guarded")"
    cp "$STABLE_BIN" "$guarded"
    label="${guarded#"$TMPDIR/project/"}"
    if "$guarded" uninstall --yes --keep-data > "$TMPDIR/t4.log" 2>&1; then
        if [[ -e "$guarded" ]]; then
            if grep -qi "build artifact" "$TMPDIR/t4.log"; then
                pass "dev-build guard refused to remove $label"
            else
                fail "binary preserved but guard message missing" \
                    "$(tail -5 "$TMPDIR/t4.log")"
            fi
        else
            fail "guard failed — $label was deleted"
        fi
    else
        fail "uninstall returned non-zero on dev-build guard path ($label)" \
            "$(tail -5 "$TMPDIR/t4.log")"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "  $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
