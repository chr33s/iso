#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# End-to-end test for `iso uninstall`.
#
# Runs the uninstall flow with HOME pointed at a throwaway tempdir, so the
# tests never touch the developer's real ~/.iso. Verifies:
#
#   1. --yes --keep-data removes the binary and leaves the data dir alone.
#   2. --yes --purge removes binary, data dir, update-check state, and
#      any iso SSH config blocks.
#   3. Non-interactive (non-TTY) without --yes exits non-zero with a hint.
#   4. The dev-build guard refuses to remove a binary that lives in a SwiftPM
#      build tree (`.build/{debug,release}` or `.build/<triple>/{debug,release}`).
#
# Run manually:   ./tests/integration-uninstall.sh
# Run in CI:      same (fast — no VM, no network)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# iso gates interactive prompts on stdin being a TTY. Detach it so a future
# prompt-bearing case can't block on real keystrokes in an interactive shell
# (CI is already non-TTY and would never catch it).
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
    # $2 is optional; the `if` keeps a one-argument call from returning 1 under `set -e`.
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
    return 0
}

# ── Build a binary and copy it out of the build tree ────────────────────────
#
# The dev-build guard refuses binaries under a SwiftPM build tree, so
# success-path tests use a copy in $TMPDIR/bin; Test 4 copies it into
# build-tree-shaped paths. ISO_SWIFT_SCRATCH_PATH overrides `.build`.

echo "==> Building iso..."
SWIFT_SCRATCH="${ISO_SWIFT_SCRATCH_PATH:-$PROJECT_DIR/.build}"
swift build --package-path "$PROJECT_DIR" --scratch-path "$SWIFT_SCRATCH" \
    --product iso --force-resolved-versions --quiet
BUILT_BIN="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$SWIFT_SCRATCH" \
    --show-bin-path)/iso"
STABLE_BIN="$TMPDIR/bin/iso-stable"
cp "$BUILT_BIN" "$STABLE_BIN"

# ── Isolate $HOME / XDG dirs ─────────────────────────────────────────────────

export HOME="$TMPDIR/home"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$HOME/.ssh"

# Where iso writes the background update-check state. Must mirror
# `UpdateCheckState` in Sources/IsoHost/Update/UpdateCheck.swift
# (~/Library/Application Support/iso/update-check.json on macOS).
case "$(uname -s)" in
    Darwin) STATE_FILE="$HOME/Library/Application Support/iso/update-check.json" ;;
    *)      STATE_FILE="$XDG_STATE_HOME/iso/update-check.json" ;;
esac

seed_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" << 'JSON'
{"last_checked_at": 0, "latest_known_version": "v9.9.9"}
JSON
}

# Match the owned state and SSH namespace of this target's default backend.
if [[ "$(uname -s)" == Darwin ]]; then
    DATA_DIR="$HOME/.iso/backends/apple-container-v1"
    CONFIG_DIR="$HOME/.iso"
    SSH_PREFIX="iso"
else
    DATA_DIR="$HOME/.iso"
    CONFIG_DIR="$HOME/.iso"
    SSH_PREFIX="iso"
fi

seed_data_dir() {
    local data_dir="$DATA_DIR"
    mkdir -p "$data_dir/images" "$data_dir/instances"
    # Write a config so configPathIsUnderDataDirectory has something to look at.
    mkdir -p "$CONFIG_DIR"
    printf '{}\n' > "$CONFIG_DIR/config.jsonc"
}

# Pre-populate ~/.ssh/config with a iso marker block; uninstall should strip
# it. Markers must match the `SSHConfigBlocks` markers in
# Sources/IsoHost/Update/Uninstall.swift (`# <prefix> START <host>` and `# <prefix> END`).
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

# Fresh copy of the binary at $TMPDIR/bin/iso for each test that removes it.
fresh_binary() {
    cp "$STABLE_BIN" "$TMPDIR/bin/iso"
}

if [[ "$(uname -s)" == Darwin ]]; then
    mkdir -p "$HOME/.iso/unrelated"
    printf '%s\n' unrelated >"$HOME/.iso/unrelated/sentinel"
fi

# ── Test 1: --yes --keep-data preserves the data directory ───────────────────

echo "==> Test 1: --yes --keep-data removes binary, keeps data"
fresh_binary
seed_data_dir
seed_state
seed_ssh_config

if "$TMPDIR/bin/iso" uninstall --yes --keep-data > "$TMPDIR/t1.log" 2>&1; then
    if [[ -e "$TMPDIR/bin/iso" ]]; then
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
        fail "SSH iso block not stripped" "blocks should be removed even with --keep-data"
    else
        pass "SSH iso blocks stripped"
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

if "$TMPDIR/bin/iso" uninstall --yes --purge > "$TMPDIR/t2.log" 2>&1; then
    if [[ -e "$TMPDIR/bin/iso" ]]; then
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
        fail "SSH iso block survived --purge"
    else
        pass "SSH iso blocks stripped"
    fi
else
    fail "uninstall --yes --purge exited non-zero" "$(tail -5 "$TMPDIR/t2.log")"
fi

if [[ "$(uname -s)" == Darwin ]]; then
    if [[ -f "$CONFIG_DIR/config.jsonc" && "$(cat "$HOME/.iso/unrelated/sentinel")" == unrelated ]]; then
        pass "purge preserves config outside the owned backend root"
    else
        fail "purge removed config outside the owned backend root"
    fi
fi

# ── Test 3: non-TTY without --yes fails with a helpful message ───────────────

echo "==> Test 3: non-TTY without --yes errors"
fresh_binary
seed_data_dir

if "$TMPDIR/bin/iso" uninstall < /dev/null > "$TMPDIR/t3.log" 2>&1; then
    fail "uninstall without --yes succeeded in non-interactive mode"
elif grep -qi "not a tty" "$TMPDIR/t3.log" && grep -q -- "--yes" "$TMPDIR/t3.log"; then
    pass "non-TTY without --yes errors with --yes hint"
else
    fail "exit was non-zero but message lacks the --yes hint" \
        "$(tail -5 "$TMPDIR/t3.log")"
fi

if [[ -e "$TMPDIR/bin/iso" ]]; then
    pass "binary preserved after refusal"
else
    fail "binary removed despite refusal"
fi

# ── Test 4: dev-build guard refuses to remove SwiftPM build outputs ─────────

echo "==> Test 4: dev-build guard refuses .build binaries"
seed_data_dir

for guarded in "$TMPDIR/project/.build/debug/iso" \
    "$TMPDIR/project/.build/arm64-apple-macosx/release/iso"; do
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
