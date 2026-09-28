#!/usr/bin/env bash
set -euo pipefail

# PostToolUse formatter: run swift-format in place on the Swift file Claude
# just wrote or edited, so in-progress edits stay formatted and don't surface
# later as `swift format lint --strict` failures in the pre-commit hook or CI.
#
# Only the edited file is formatted (never the whole package): an edit in a
# linked worktree must not rewrite files elsewhere. Lint findings the
# formatter cannot fix (line length in literals, naming) are left to
# `swift format lint --strict`.
#
# The hook must never block the tool, so a formatter failure is surfaced on
# stderr (with the file and swift-format's own error) but does not propagate.

INPUT=$(cat)
FILE=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' <<<"$INPUT" 2>/dev/null || true)

if [ -z "$FILE" ] || [ "${FILE##*.}" != "swift" ] || [ ! -f "$FILE" ]; then
  exit 0
fi

command -v swift >/dev/null 2>&1 || exit 0

if ! err=$(swift format --in-place "$FILE" 2>&1); then
  printf 'swift-format hook: swift format failed on %s\n%s\n' "$FILE" "$err" >&2
fi

exit 0
