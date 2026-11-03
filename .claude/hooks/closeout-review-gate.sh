#!/usr/bin/env bash
set -euo pipefail

# PreToolUse gate: block `gh pr create` until a closeout review has run to a
# clean verdict on the branch the PR is created FROM, at that branch's current
# tip. The closeout-review skill records the marker as its final step; this
# hook only checks it.
#
# Worktree-aware: the branch under review usually lives in a linked worktree
# while this hook runs from the main checkout (CLAUDE_PROJECT_DIR). So we
# (a) resolve the git context from the command's `cd` prefix or the hook-
# provided cwd instead of the hook's own PWD, (b) take the target branch from
# `--head` when it is given (a PR can be opened for a branch you are not on),
# and (c) store markers under the shared git common dir so a marker written
# from a worktree is visible from every other worktree and the main checkout.
#
# Fail-open by design: anything that isn't an identifiable `gh pr create` (or
# its alias `gh pr new`) in a git repo is allowed through, so the gate never
# wedges unrelated work.

INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // .tool_input.cmd // .command // .cmd // empty' <<<"$INPUT" 2>/dev/null || true)

[ -z "$COMMAND" ] && exit 0

# Split a command into shell words with a quote-aware scan. Quoted text stays
# inside its word, so `git commit -m "... gh pr create ..."` or a `--body`
# naming `--head` is never read as the command itself. Unquoted `;`, `&` and
# `|` end a word and are emitted as a `;` separator word.
TOKS=()
tokenize() {
  local s="$1" c i n q="" tok=""
  TOKS=()
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=""; else tok+="$c"; fi
    elif [ "$c" = '"' ] || [ "$c" = "'" ]; then
      q="$c"
    elif [[ "$c" == [[:space:]] || "$c" == ";" || "$c" == "&" || "$c" == "|" ]]; then
      if [ -n "$tok" ]; then
        TOKS+=("$tok")
        tok=""
      fi
      [[ "$c" == [[:space:]] ]] || TOKS+=(";")
    else
      tok+="$c"
    fi
  done
  [ -n "$tok" ] && TOKS+=("$tok")
  return 0
}

# Only gate PR creation: a `gh` word (any path, e.g. /opt/homebrew/bin/gh)
# followed by `pr create` or `pr new`, unless that command only asks for help.
# Sets PR_WORDS to the words of that one command.
PR_WORDS=()
pr_create_command() {
  local i j n=${#TOKS[@]}
  for ((i = 0; i + 2 < n; i++)); do
    [ "${TOKS[i]##*/}" = gh ] && [ "${TOKS[i + 1]}" = pr ] || continue
    case "${TOKS[i + 2]}" in create | new) ;; *) continue ;; esac
    PR_WORDS=()
    for ((j = i; j < n; j++)); do
      [ "${TOKS[j]}" = ";" ] && break
      case "${TOKS[j]}" in --help | -h) continue 2 ;; esac
      PR_WORDS+=("${TOKS[j]}")
    done
    return 0
  done
  return 1
}

tokenize "$COMMAND"
pr_create_command || exit 0

# Locate the directory the command actually runs git/gh in: an explicit
# `cd <dir> && ...` prefix wins, else the cwd the hook was invoked with.
WORKDIR=""
if [[ "$COMMAND" =~ ^[[:space:]]*cd[[:space:]]+([^[:space:]\&\;\|]+) ]]; then
  WORKDIR="${BASH_REMATCH[1]}"
  WORKDIR="${WORKDIR%[\"\']}"
  WORKDIR="${WORKDIR#[\"\']}"
  # A `cd` target we can't resolve — unexpanded `~`/`$VAR`, or a path truncated
  # at its first space — must NOT suppress the fallbacks below, or the gate
  # fails open on idiomatic `cd ~/wt && gh pr create`. Drop it and let the
  # hook-provided cwd / $PWD decide.
  [ -d "$WORKDIR" ] || WORKDIR=""
fi
[ -z "$WORKDIR" ] && WORKDIR=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)
[ -z "$WORKDIR" ] && WORKDIR="$PWD"
[ -d "$WORKDIR" ] || exit 0

git -C "$WORKDIR" rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

# Read the value of an actual `--head`/`-H` flag from the words of the PR
# command. A regex over the raw command takes the leftmost match, so a
# `--head`/`-H` token quoted inside a `--body`/`--title` string would hijack
# branch selection whenever it names a resolvable ref (`main`, `develop`). The
# tokenizer keeps such a token bound inside its quoted argument, where it is
# never the flag.
head_flag_value() {
  local tok want=0
  for tok in "${PR_WORDS[@]}"; do
    if [ "$want" = 1 ]; then
      printf '%s' "$tok"
      return
    fi
    case "$tok" in
      --head | -H) want=1 ;;
      --head=*)
        printf '%s' "${tok#--head=}"
        return
        ;;
      -H=*)
        printf '%s' "${tok#-H=}"
        return
        ;;
      -H?*)
        printf '%s' "${tok#-H}"
        return
        ;;
    esac
  done
}

# Target branch: the `--head`/`-H` value (strip any `owner:` fork prefix) when it
# names a real ref, else the branch currently checked out in WORKDIR. A head
# that does not resolve to a commit falls back to the current branch, so the
# gate still evaluates a real branch.
BRANCH=""
candidate=$(head_flag_value)
candidate="${candidate##*:}"
if [ -n "$candidate" ] &&
  git -C "$WORKDIR" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
  BRANCH="$candidate"
fi
if [ -z "$BRANCH" ]; then
  BRANCH=$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
fi

HEAD_SHA=$(git -C "$WORKDIR" rev-parse --verify "${BRANCH}^{commit}" 2>/dev/null) || exit 0

# Markers live under the shared git common dir so one written from any linked
# worktree is found from every other worktree (and the main checkout).
COMMON_DIR=$(git -C "$WORKDIR" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$COMMON_DIR" in
  /*) ;;
  *) COMMON_DIR="$WORKDIR/$COMMON_DIR" ;;
esac
COMMON_DIR=$(cd "$COMMON_DIR" 2>/dev/null && pwd) || exit 0

MARKER="${COMMON_DIR}/closeout-review/$(echo "$BRANCH" | tr '/' '-')"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$HEAD_SHA" ]; then
  exit 0
fi

cat >&2 <<EOF
Closeout gate: a closeout review has not run on this branch at the current
commit, so this PR cannot be created yet.

Branch: ${BRANCH}
HEAD:   ${HEAD_SHA}

Run the closeout-review skill now (invoke it via the Skill tool). Work the
diff to a clean verdict — fix in-scope blockers, defer follow-ups. As its
final step it records the gate marker for this exact commit, after which
\`gh pr create\` is allowed.

If you commit again after the review, re-run it: the marker is bound to the
reviewed commit, so new commits re-arm the gate.
EOF
exit 2
