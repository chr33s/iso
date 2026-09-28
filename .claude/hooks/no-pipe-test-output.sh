#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // .tool_input.cmd // .command // .cmd // empty' <<<"$INPUT" 2>/dev/null || true)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Expensive commands: the Swift build and test gates, the fuzz runner, the
# fault-injection sweep, the release build, and the integration-test
# scripts. Anchored to a command position (start of line or after a
# `;`/`&`/`|` separator, optionally behind `python3`) so a string quoted
# inside a `grep`/`echo` argument is not mistaken for the command being run.
# POSIX classes only (`[[:space:]]`, no `\s`/`\b`) so it behaves the same under
# GNU and BSD/macOS grep.
EXPENSIVE='(^|[;&|][[:space:]]*)((swift[[:space:]]+(build|test))|((python3[[:space:]]+)?(\./)?(scripts/(fuzz\.sh|swift-host-fault-injection\.py|build-release\.py)|tests/(run-)?integration[a-z-]*\.(sh|py))))'

# A pipe (optionally `|&`) into a tool that inspects part of the output —
# i.e. the output is being searched, not viewed whole.
FILTERS='\|&?[[:space:]]*(grep|rg|head|tail|awk|sed)'

if printf '%s' "$COMMAND" | grep -qE "$EXPENSIVE" \
  && printf '%s' "$COMMAND" | grep -qE "$FILTERS"; then
  # Suggest a path without creating the file: the command is about to be
  # blocked, so nothing writes here, and a failed `mktemp` under `set -e` would
  # abort the hook with exit 1 (allow) instead of the intended exit 2 (block).
  OUTFILE="${TMPDIR:-/tmp}/test-output.$$"

  cat >&2 <<EOF
Do not pipe this output through grep/rg/head/tail/awk/sed — it forces the
command to run again every time you want to examine different parts of the
output. This applies to swift build/test, scripts/fuzz.sh,
scripts/swift-host-fault-injection.py, scripts/build-release.py, and the
tests/*integration* scripts.

Instead:
Redirect output to a file:  <command> > ${OUTFILE} 2>&1
Read the file:              Read tool or cat ${OUTFILE}
Search the file:            grep "pattern" ${OUTFILE}

This way the command runs once and you can inspect the results as many times
as needed. Do not forget to delete the file once you are done using it.
EOF
  exit 2
fi

exit 0
