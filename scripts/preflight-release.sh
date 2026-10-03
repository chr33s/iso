#!/usr/bin/env bash
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Release preflight for iso.
#
# Runs every check that gates a release from one machine, mirroring the CI
# jobs (swift format, build, test, the current contract checks, the
# lightweight integration scripts) so a doomed tag is never pushed, and adds
# the checks CI does not perform:
#   - Swift package version (Sources/IsoHost/Update/UpdateVersion.swift) / CHANGELOG
#     / git-tag agreement
#   - the release archive, built through scripts/build-release.py exactly as
#     release.yml builds it (a break otherwise first surfaces on the tag,
#     which burns the version under immutable releases)
#   - opt-in fuzzing of the Swift host parsers
#   - the Apple VM integration suite, driven through the native runtime as
#     tests/run-integration.sh does (these need Apple virtualization hardware and
#     cannot run in GitHub-hosted CI)
#
# The full integration suite runs on this macOS 27+ Apple Silicon host.
#
# Usage:
#   ./scripts/preflight-release.sh [options]
#
# Options:
#   --fuzz               Replay the corpora and briefly fuzz every target.
#   --quick              Skip the slow gates: release archive, full integration, fuzz.
#   -h, --help           Show this help.
#
# Environment:
#   FUZZ_SECONDS   Per-target fuzz budget when --fuzz is set (default 30).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

RUN_FUZZ=0
QUICK=0

usage() {
  sed -n '/^# Release preflight/,/^# *FUZZ_SECONDS/p' "${BASH_SOURCE[0]}" |
    sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fuzz) RUN_FUZZ=1; shift ;;
    --quick) QUICK=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

FAILURES=()
WARNINGS=()

section() { printf '\n========== %s ==========\n' "$1"; }
warn() {
  printf 'WARN: %s\n' "$1"
  WARNINGS+=("$1")
}
have() { command -v "$1" >/dev/null 2>&1; }

# step "Name" cmd args... — runs cmd, records a failure on non-zero exit but
# keeps going so one preflight run reports every problem.
step() {
  local name="$1"
  shift
  section "$name"
  if "$@"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name"
    FAILURES+=("$name")
  fi
}

# The version `iso --version` reports and scripts/build-release.py checks
# the tag against.
package_version() {
  sed -n 's/.*package static let packageVersion = "\([^"]*\)".*/\1/p' \
    Sources/IsoHost/Update/UpdateVersion.swift | head -n 1
}

macos_27() {
  [[ "$(uname -s)" == Darwin ]] && [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 27 ]]
}

check_worktree() {
  local dirty=0
  if ! git diff --quiet || ! git diff --cached --quiet; then
    printf 'Tracked changes are uncommitted:\n'
    git status --short --untracked-files=no
    dirty=1
  fi
  if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    warn "Untracked files present — confirm they are not meant for the release"
  fi
  return "$dirty"
}

check_versions() {
  local v tag
  v="$(package_version)"
  if [[ -z "$v" ]]; then
    echo "Could not read packageVersion from Sources/IsoHost/Update/UpdateVersion.swift" >&2
    return 1
  fi
  tag="v$v"
  printf 'Package version: %s  (release tag: %s)\n' "$v" "$tag"

  # release.yml extracts notes with an exact whole-line match ($0 == "## vX.Y.Z"),
  # so the header must match exactly — a trailing date would pass a looser check
  # here yet make the release run find no notes. Mirror that exact-match.
  if ! grep -qxF "## $tag" CHANGELOG.md; then
    printf 'CHANGELOG.md has no exact "## %s" header — promote "## Unreleased" (header must be exactly "## %s", no trailing text)\n' "$tag" "$tag"
    return 1
  fi

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    printf 'Tag %s already exists — bump packageVersion in Sources/IsoHost/Update/UpdateVersion.swift first\n' "$tag"
    return 1
  fi

  printf 'Version sources agree; tag %s is free.\n' "$tag"
}

run_format() {
  swift format lint --recursive --strict Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints \
    iso-proxy/Sources iso-proxy/Tests iso-egress/Package.swift iso-egress/Sources iso-egress/Tests scripts/verify-egress-readiness.swift iso-sandbox/Package.swift iso-sandbox/Sources iso-sandbox/Tests
}

run_host_tests() {
  swift build --force-resolved-versions || return
  swift test --force-resolved-versions || return
  git diff --exit-code -- Package.resolved
}

# The recorded-baseline replays CI runs against the debug build.
run_contracts() {
  local iso=.build/debug/iso failed=0
  python3 tests/test-read-contract.py --swift "$iso" || failed=1
  python3 tests/test-lifecycle-contract.py --swift "$iso" || failed=1
  python3 tests/test-data-root-contract.py --swift "$iso" || failed=1
  python3 tests/test-cli-surface.py --swift "$iso" || failed=1
  return "$failed"
}

run_swift_proxy() {
  if ! macos_27; then
    warn "Swift proxy validation requires macOS 27+ — run its package/process gates before tagging"
    return 0
  fi
  local bin_dir
  ulimit -n 8192 || return
  swift build --package-path iso-proxy --force-resolved-versions || return
  bin_dir="$(swift build --package-path iso-proxy --show-bin-path)" || return
  ISO_PROXY_E2E_BINARY="$bin_dir/iso-proxy" \
    swift test --package-path iso-proxy --force-resolved-versions
}

run_swift_egress() {
  if ! macos_27; then
    warn "Swift egress validation requires macOS 27+ — run its package/lease gates before tagging"
    return 0
  fi
  swift test --package-path iso-egress --force-resolved-versions || return
  swift build --package-path iso-egress --force-resolved-versions || return
  python3 scripts/test-swift-egress-jail.py || return
  python3 scripts/test-swift-egress-lease.py || return
  python3 scripts/test-swift-egress-mutations.py
}

run_sandbox_tests() {
  swift test --package-path iso-sandbox --force-resolved-versions --no-parallel
}

# The unsigned release archive, built as release.yml builds it (signing and
# publication stay in the workflow).
run_release_archive() {
  if ! macos_27; then
    warn "release archive not built locally (needs macOS 27+ on Apple Silicon) — release.yml builds it on the tag (a failure there burns the version)."
    return 0
  fi
  python3 scripts/build-release.py --release --tag "v$(package_version)" \
    --out .build/preflight-release
}

run_zizmor() {
  if ! have zizmor; then
    warn "zizmor not installed — workflow audit skipped (CI still runs it; pipx install zizmor)"
    return 0
  fi
  zizmor .github/workflows/
}

run_fuzz() {
  scripts/fuzz.sh smoke "${FUZZ_SECONDS:-30}"
}

# ── Run ──────────────────────────────────────────────────────────

step "Working tree clean" check_worktree
step "Version consistency" check_versions
step "Format (swift format lint --strict)" run_format
step "Swift host build and tests" run_host_tests
step "Host behavior contracts" run_contracts
step "Swift proxy tests" run_swift_proxy
step "Swift egress tests and confined lease" run_swift_egress
step "iso-sandbox tests" run_sandbox_tests
step "Workflow audit (zizmor)" run_zizmor
step "Release preflight regression tests" python3 tests/test-preflight-release.py
step "Integration — installer provenance" ./tests/integration-install.sh
step "Integration — iso update" ./tests/integration-update.sh
step "Integration — iso uninstall" ./tests/integration-uninstall.sh

if [[ "$RUN_FUZZ" == 1 ]]; then
  step "Fuzzing" run_fuzz
elif [[ "$QUICK" != 1 ]]; then
  warn "Fuzzing not run — pass --fuzz if this release touches parsers of user-editable input"
fi

if [[ "$QUICK" == 1 ]]; then
  warn "--quick: release archive build and Apple VM integration suite skipped"
else
  step "Release archive (scripts/build-release.py)" run_release_archive
  step "Apple VM integration" ./tests/run-integration.sh
fi

# ── Summary ──────────────────────────────────────────────────────

section "Summary"
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  printf 'Warnings (%d):\n' "${#WARNINGS[@]}"
  printf '  - %s\n' "${WARNINGS[@]}"
fi
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf '\nFailed checks (%d):\n' "${#FAILURES[@]}"
  printf '  - %s\n' "${FAILURES[@]}"
  printf '\nPreflight FAILED — do not tag the release.\n'
  exit 1
fi
version="$(package_version)"
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  printf 'Completed checks passed for v%s; resolve the warnings and unrun gates before tagging.\n' "$version"
  exit 0
fi
printf 'All required checks passed for v%s.\n' "$version"
printf 'Next: tag v%s on the merge commit and push to trigger release.yml.\n' "$version"
