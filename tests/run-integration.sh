#!/usr/bin/env bash
set -euo pipefail

# Run the Apple Containerization VM suite on macOS 27+ Apple Silicon.
# Usage: tests/run-integration.sh [--only PHASE[,PHASE...]] [--keep]
# See tests/integration-apple-sandbox.sh for phases and prerequisites.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/integration-apple-sandbox.sh" "$@"
