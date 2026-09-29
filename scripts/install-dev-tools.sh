#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Install iso's pinned development tools and git hook with mise
# (https://mise.jdx.dev). Versions live in mise.toml: the Swift toolchain,
# Python, jq, yq, shellcheck, actionlint, zizmor and Apple's `container` CLI.
# Xcode 27 is still required for the macOS SDK and code signing.
#
# Usage:
#   scripts/install-dev-tools.sh    (`--all` is accepted and does the same)
#
# The pre-commit hook runs `mise run pre-commit`: hygiene, swift format lint,
# swift build and swift test (see mise.toml).

case "${1:-}" in
    "" | --all) ;;
    -h | --help)
        sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown argument: $1" >&2
        echo "usage: $0" >&2
        exit 2
        ;;
esac

if ! command -v mise >/dev/null 2>&1; then
    echo "mise not found on PATH — install it first: https://mise.jdx.dev/getting-started.html" >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode not found — install Xcode 27 first" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
mise trust
mise install
mise generate git-pre-commit --write --task=pre-commit
# Git runs the hook with the committing process's PATH, which often lacks
# mise's install directory (GUI clients, IDEs, non-interactive shells).
hook="$(git rev-parse --git-path hooks/pre-commit)"
# `command -v` would name the shell function `mise activate` defines.
sed -i '' "s|^exec mise |exec $(/usr/bin/which mise) |" "$hook"

echo "Done. The pre-commit hook runs 'mise run pre-commit'; run 'mise run check' any time."
