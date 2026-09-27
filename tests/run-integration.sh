#!/usr/bin/env bash
set -euo pipefail

# Runner for coop integration tests.
#
# Usage:
#   Local:   ./tests/run-integration.sh [test flags...]
#   Remote:  ./tests/run-integration.sh --remote user@host [test flags...]
#
# Local mode builds the binary and runs tests/integration.sh directly.
# Remote mode detects the remote host's architecture, cross-compiles
# the matching musl binary, copies it and the test script, and runs tests there.
#
# --full also runs integration-network.sh on the test host before the VM suite.
# All flags other than --remote are forwarded to integration.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/integration.sh"

REMOTE_HOST=""
FULL="${TEST_FULL:-0}"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)  REMOTE_HOST="$2";  shift 2 ;;
        --full)    FULL=1; FORWARD_ARGS+=("$1"); shift ;;
        *)         FORWARD_ARGS+=("$1"); shift ;;
    esac
done

# ── Local mode ───────────────────────────────────────────────────

if [[ -z "$REMOTE_HOST" ]]; then
    if [[ "$FULL" == "1" ]]; then
        echo "Running bridge isolation integration test..."
        "$SCRIPT_DIR/integration-network.sh"
    fi

    echo "Building coop (release)..."
    cargo build --release --manifest-path "$PROJECT_DIR/Cargo.toml"

    if [[ "$(uname -s)" == Darwin && "$(sw_vers -productVersion | cut -d. -f1)" -ge 27 ]]; then
        swift build --package-path "$PROJECT_DIR/macos/coop-proxy" -c release --force-resolved-versions
        proxy_dir="$(swift build --package-path "$PROJECT_DIR/macos/coop-proxy" -c release --show-bin-path)"
        cp "$proxy_dir/coop-proxy-swift" "$PROJECT_DIR/target/release/coop-proxy"
    fi

    BINARY="$PROJECT_DIR/target/release/coop"
    exec "$TEST_SCRIPT" --binary "$BINARY" "${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}"
fi

# ── Remote mode ──────────────────────────────────────────────────

REMOTE_OS=$(ssh "$REMOTE_HOST" uname -s)
REMOTE_ARCH=$(ssh "$REMOTE_HOST" uname -m)

case "$REMOTE_OS-$REMOTE_ARCH" in
    Linux-x86_64)   TARGET="x86_64-unknown-linux-musl" ;;
    Linux-aarch64)  TARGET="aarch64-unknown-linux-musl" ;;
    Darwin-arm64)   TARGET="aarch64-apple-darwin" ;;
    Darwin-x86_64)  TARGET="x86_64-apple-darwin" ;;
    *)              echo "Unsupported remote platform: $REMOTE_OS $REMOTE_ARCH" >&2; exit 1 ;;
esac

echo "Cross-compiling coop for $TARGET..."
cargo build --release --target "$TARGET" \
    --manifest-path "$PROJECT_DIR/Cargo.toml"

LOCAL_BINARY="$PROJECT_DIR/target/$TARGET/release/coop"
build_swift_on_remote=0
if [[ "$REMOTE_OS" == Darwin ]]; then
    remote_macos_major=$(ssh "$REMOTE_HOST" sw_vers -productVersion | cut -d. -f1)
    if [[ "$remote_macos_major" -ge 27 ]]; then build_swift_on_remote=1; fi
fi
REMOTE_DIR=$(ssh "$REMOTE_HOST" mktemp -d)
source_archive=""
trap '[[ -z "$source_archive" ]] || rm -f "$source_archive"; ssh "$REMOTE_HOST" rm -rf "$REMOTE_DIR"' EXIT

echo "Copying binary and test script to $REMOTE_HOST:$REMOTE_DIR..."
scp -q "$LOCAL_BINARY" "$TEST_SCRIPT" "$REMOTE_HOST:$REMOTE_DIR/"

# The full network gate builds on the remote.
# Include tracked working-tree edits so the gate tests the same code as coop.
if [[ "$FULL" == "1" || "$build_swift_on_remote" == "1" ]]; then
    source_archive=$(mktemp "${TMPDIR:-/tmp}/coop-integration-src.XXXXXX.tar.gz")
    (
        cd "$PROJECT_DIR"
        git ls-files -z | while IFS= read -r -d '' source_path; do
            if [[ -f "$source_path" || -L "$source_path" ]]; then printf '%s\0' "$source_path"; fi
        done | tar --null -czf "$source_archive" -T -
    )
    scp -q "$source_archive" "$REMOTE_HOST:$REMOTE_DIR/coop-src.tar.gz"
    rm -f "$source_archive"
    source_archive=""
    # shellcheck disable=SC2029 # $REMOTE_DIR is a mktemp path
    ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR/src' && tar xzf '$REMOTE_DIR/coop-src.tar.gz' -C '$REMOTE_DIR/src'"
fi

if [[ "$FULL" == "1" ]]; then
    echo "Running bridge isolation integration test on $REMOTE_HOST..."
    # shellcheck disable=SC2029 # $REMOTE_DIR is a mktemp path
    ssh "$REMOTE_HOST" "
        set -e
        . \"\$HOME/.cargo/env\" 2>/dev/null || true
        cd '$REMOTE_DIR/src'
        ./tests/integration-network.sh
    "
fi

if [[ "$build_swift_on_remote" == "1" ]]; then
    # shellcheck disable=SC2029 # private mktemp directory, expanded on the client
    ssh "$REMOTE_HOST" "
        set -e
        cd '$REMOTE_DIR/src'
        swift build --package-path macos/coop-proxy -c release --force-resolved-versions
        proxy_dir=\$(swift build --package-path macos/coop-proxy -c release --show-bin-path)
        cp \"\$proxy_dir/coop-proxy-swift\" '$REMOTE_DIR/coop-proxy'
    "
fi

# Build the remote command as an array, then printf %q to safely quote for ssh.
# ssh doesn't forward arbitrary env vars, so pass opt-in flags explicitly.
REMOTE_CMD=()
if [[ "$FULL" == "1" ]]; then
    REMOTE_CMD+=("TEST_FULL=1")
fi
if [[ -n "${COOP_TEST_DESTRUCTIVE:-}" ]]; then
    REMOTE_CMD+=("COOP_TEST_DESTRUCTIVE=$COOP_TEST_DESTRUCTIVE")
fi
REMOTE_CMD+=("$REMOTE_DIR/integration.sh" --binary "$REMOTE_DIR/coop"
    "${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}")

echo "Running tests on $REMOTE_HOST..."
echo ""
# shellcheck disable=SC2029 # client-side expansion is intentional (printf %q handles quoting)
ssh "$REMOTE_HOST" "$(printf '%q ' "${REMOTE_CMD[@]}")"
