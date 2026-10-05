#!/usr/bin/env bash
# Coverage-guided fuzzing for the Swift host parsers; see docs/testing.md.
#
#   scripts/fuzz.sh build                      # instrumented targets
#   scripts/fuzz.sh run TARGET [SECONDS] [SEED] # bounded campaign
#   scripts/fuzz.sh smoke [SECONDS]            # every target, bounded (CI)
#   scripts/fuzz.sh replay TARGET [FILE...]    # corpus (default) or given inputs
#   scripts/fuzz.sh merge TARGET               # minimize work corpus into fuzz/corpus
#   scripts/fuzz.sh minimize TARGET CRASH      # shrink a crashing input
#   scripts/fuzz.sh qualify                    # toolchain qualification checks
#
# Campaigns use libFuzzer value profiling: 1- and 2-byte comparisons (key
# bytes, tokens) otherwise give no guidance.
#
# Engine: LLVM libFuzzer built from the vendored sources in fuzz/libfuzzer
# (or `ISO_LIBFUZZER_SRC`), verified against LIBFUZZER_MANIFEST_SHA256, with
# the pinned Xcode `clang++`. Targets are built with the pinned `swiftc`,
# AddressSanitizer and SanitizerCoverage. Production sources are compiled from
# this revision; harness bodies live in fuzz/Targets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/fuzz/.build"
TARGETS=(ParseRepoSlug JSONCToJSON ConfigLoad)

# LLVM libFuzzer at commit a47b42eb9f9b (release/22.x), vendored in
# fuzz/libfuzzer (see its README). SHA-256 over the sorted `shasum -a 256`
# listing of the top-level *.cpp, *.h and *.def files.
LIBFUZZER_MANIFEST_SHA256="0b52df7b0808e66eb5efdd5c3fbcaf72335279ba90e1f26e04f4c2bab7e6fd32"
DEFAULT_LIBFUZZER_SRC="$ROOT/fuzz/libfuzzer"
LIBFUZZER_SRC="${ISO_LIBFUZZER_SRC:-$DEFAULT_LIBFUZZER_SRC}"

MAX_LEN=65536
TIMEOUT_SECONDS=10
RSS_LIMIT_MB=2048
MALLOC_LIMIT_MB=1024

SWIFT_FLAGS=(
  -O -g -parse-as-library -swift-version 6 -package-name iso
  -target arm64-apple-macosx27.0
  -sanitize=address
  -sanitize-coverage=edge,trace-cmp
  -Xllvm -sanitizer-coverage-inline-8bit-counters
  -Xllvm -sanitizer-coverage-pc-table
)

die() { echo "fuzz.sh: $*" >&2; exit 1; }

is_target() {
  local t
  for t in "${TARGETS[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

libfuzzer_manifest() {
  (cd "$1" && find . -maxdepth 1 -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.def' \) \
    | LC_ALL=C sort | xargs shasum -a 256) | shasum -a 256 | cut -d' ' -f1
}

build_libfuzzer() {
  [[ -d "$LIBFUZZER_SRC" ]] || die "libFuzzer sources not found at $LIBFUZZER_SRC
Set ISO_LIBFUZZER_SRC to an LLVM compiler-rt/lib/fuzzer checkout matching
LIBFUZZER_MANIFEST_SHA256."
  local actual
  actual="$(libfuzzer_manifest "$LIBFUZZER_SRC")"
  [[ "$actual" == "$LIBFUZZER_MANIFEST_SHA256" ]] \
    || die "libFuzzer source manifest mismatch: $actual (expected $LIBFUZZER_MANIFEST_SHA256)"
  if [[ -f "$BUILD/libFuzzer.a" && -f "$BUILD/libFuzzer.sha256" \
    && "$(cat "$BUILD/libFuzzer.sha256")" == "$actual" ]]; then
    return
  fi
  mkdir -p "$BUILD/libfuzzer-obj"
  local source
  for source in "$LIBFUZZER_SRC"/*.cpp; do
    case "$source" in *Windows*|*Fuchsia*|*Linux*) continue ;; esac
    xcrun clang++ -std=c++17 -O2 -fPIC -c "$source" -o "$BUILD/libfuzzer-obj/$(basename "$source" .cpp).o"
  done
  rm -f "$BUILD/libFuzzer.a"
  xcrun libtool -static -no_warning_for_no_symbols -o "$BUILD/libFuzzer.a" "$BUILD"/libfuzzer-obj/*.o
  echo "$actual" > "$BUILD/libFuzzer.sha256"
}

swift_module() { # name, sources...
  local name="$1"
  shift
  xcrun swiftc "${SWIFT_FLAGS[@]}" -module-name "$name" -I "$BUILD" \
    -emit-module -emit-module-path "$BUILD/$name.swiftmodule" \
    -emit-library -static -o "$BUILD/lib$name.a" "$@"
}

link_target() { # target, entrypoint
  xcrun swiftc "${SWIFT_FLAGS[@]}" -I "$BUILD" "$2" \
    "$BUILD/libIsoFuzzHarnesses.a" "$BUILD/libIsoConfiguration.a" "$BUILD/libIsoCore.a" \
    "$BUILD/libFuzzer.a" -lc++ -o "$BUILD/$1"
}

cmd_build() {
  mkdir -p "$BUILD"
  build_libfuzzer
  swift_module IsoCore "$ROOT"/Sources/IsoCore/*.swift
  swift_module IsoConfiguration "$ROOT"/Sources/IsoConfiguration/*.swift
  swift_module IsoFuzzHarnesses "$ROOT"/fuzz/Targets/*.swift
  local t
  for t in "${TARGETS[@]}"; do link_target "$t" "$ROOT/fuzz/Entrypoints/$t.swift"; done
  echo "built: ${TARGETS[*]} in $BUILD" >&2
}

limits() {
  echo "-max_len=$MAX_LEN" "-timeout=$TIMEOUT_SECONDS" "-rss_limit_mb=$RSS_LIMIT_MB" \
    "-malloc_limit_mb=$MALLOC_LIMIT_MB"
}

cmd_run() { # target [seconds] [seed]
  is_target "${1:-}" || die "usage: run {${TARGETS[*]}} [SECONDS] [SEED]"
  local target="$1" seconds="${2:-60}" seed="${3:-0}"
  [[ -x "$BUILD/$target" ]] || cmd_build
  local work="$BUILD/corpus/$target" artifacts="$ROOT/fuzz/artifacts/$target/"
  mkdir -p "$work" "$artifacts"
  echo "campaign: target=$target seconds=$seconds seed=$seed revision=$(git -C "$ROOT" rev-parse HEAD)" >&2
  # shellcheck disable=SC2046
  "$BUILD/$target" $(limits) -max_total_time="$seconds" -seed="$seed" -print_final_stats=1 -use_value_profile=1 \
    -artifact_prefix="$artifacts" "$work" "$ROOT/fuzz/corpus/$target"
}

cmd_smoke() { # [seconds]
  local t
  for t in "${TARGETS[@]}"; do
    cmd_replay "$t"
    cmd_run "$t" "${1:-30}" 1
  done
}

cmd_replay() { # target [files...]
  is_target "${1:-}" || die "usage: replay {${TARGETS[*]}} [FILE...]"
  local target="$1"
  shift
  [[ -x "$BUILD/$target" ]] || cmd_build
  local inputs=("$@")
  if [[ ${#inputs[@]} -eq 0 ]]; then
    while IFS= read -r -d '' file; do inputs+=("$file"); done \
      < <(find "$ROOT/fuzz/corpus/$target" -type f ! -name '.*' -print0 | sort -z)
  fi
  [[ ${#inputs[@]} -gt 0 ]] || die "no inputs for $target"
  # shellcheck disable=SC2046
  "$BUILD/$target" $(limits) "${inputs[@]}"
}

cmd_merge() { # target
  is_target "${1:-}" || die "usage: merge {${TARGETS[*]}}"
  [[ -x "$BUILD/$1" ]] || cmd_build
  # shellcheck disable=SC2046
  "$BUILD/$1" $(limits) -merge=1 "$ROOT/fuzz/corpus/$1" "$BUILD/corpus/$1"
}

cmd_minimize() { # target crash
  is_target "${1:-}" && [[ -f "${2:-}" ]] || die "usage: minimize {${TARGETS[*]}} CRASH_FILE"
  [[ -x "$BUILD/$1" ]] || cmd_build
  # shellcheck disable=SC2046
  "$BUILD/$1" $(limits) -minimize_crash=1 -runs=100000 -exact_artifact_path="$2.min" "$2"
  echo "minimized: $2.min" >&2
}

# Qualification (section 7.1 items 1-5). Builds a throwaway harness in the
# build directory with deliberate faults reached only through the production
# parser; nothing here is added to production sources.
cmd_qualify() {
  cmd_build
  local q="$BUILD/qualification"
  rm -rf "$q"
  mkdir -p "$q/artifacts" "$q/corpus"
  cat > "$q/Qualify.swift" <<'SWIFT'
import IsoConfiguration

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  let bytes = size == 0 ? [] : Array(UnsafeBufferPointer(start: data, count: size))
  guard let value = try? ConfigLoader.parse(bytes, format: .jsonc, path: "q", limits: .configuration),
    case .object(let members) = value
  else { return 0 }
  // Byte-wise gates (not a hashed lookup) so comparison tracing can guide
  // the search to a parsed key "qz".
  for key in members.keys {
    let k = Array(key.utf8)
    if k.count == 2, k[0] == 0x71, k[1] == 0x7A {
      // Deliberate heap-use-after-free, reachable only through the parser.
      let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
      pointer.deallocate()
      pointer.pointee = 1
    }
  }
  if members["hq"] != nil { while true {} }
  return 0
}
SWIFT
  link_target Qualify "$q/Qualify.swift"
  printf '{"a": 1}' > "$q/corpus/seed"

  echo "== 1-3: coverage-guided discovery of an ASan fault through the parser" >&2
  local status=0
  "$BUILD/Qualify" -max_total_time=600 -seed=1 -use_value_profile=1 -artifact_prefix="$q/artifacts/" \
    -only_ascii=1 "$q/corpus" > "$q/discover.log" 2>&1 || status=$?
  grep -q "ERROR: AddressSanitizer: heap-use-after-free" "$q/discover.log" \
    || die "qualification: fault not found (status $status); see $q/discover.log"
  local crash
  crash="$(ls "$q"/artifacts/crash-* | head -1)"
  echo "found: $(basename "$crash")" >&2

  echo "== 4: replay and minimize the saved crash" >&2
  if "$BUILD/Qualify" "$crash" > "$q/replay.log" 2>&1; then die "qualification: replay did not crash"; fi
  grep -q "heap-use-after-free" "$q/replay.log" || die "qualification: replay lost the fault"
  printf '{"pad": [1, 2, 3, "%s"], "qz": {"x": [true, null]}, "tail": "%s"}' \
    "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" > "$q/padded"
  if "$BUILD/Qualify" "$q/padded" > /dev/null 2>&1; then die "qualification: padded input does not crash"; fi
  "$BUILD/Qualify" -minimize_crash=1 -runs=50000 -exact_artifact_path="$q/minimized" "$q/padded" \
    > "$q/minimize.log" 2>&1 || true
  [[ -f "$q/minimized" ]] || die "qualification: minimization produced no artifact"
  local before after
  before="$(wc -c < "$q/padded" | tr -d ' ')"
  after="$(wc -c < "$q/minimized" | tr -d ' ')"
  [[ "$after" -lt "$before" ]] || die "qualification: minimization did not shrink ($before bytes)"
  if "$BUILD/Qualify" "$q/minimized" > /dev/null 2>&1; then die "qualification: minimized input does not crash"; fi
  echo "minimized $before -> $after bytes; still reproduces" >&2

  echo "== 4: per-input timeout detection" >&2
  printf '{"hq": 0}' > "$q/hang"
  if "$BUILD/Qualify" -timeout=2 "$q/hang" > "$q/hang.log" 2>&1; then die "qualification: hang not detected"; fi
  grep -q "ERROR: libFuzzer: timeout" "$q/hang.log" || die "qualification: no timeout report"

  echo "== 2: instrumentation reaches production decoding and validation" >&2
  mkdir -p "$q/cov-a" "$q/cov-b"
  printf '{}' > "$q/cov-a/1"
  cp "$q/cov-a/1" "$q/cov-b/1"
  printf '{"vm": {"vcpu_count": 0}, "proxy": {"openai": {"credential": "literal"}}}' > "$q/cov-b/2"
  local a b
  a="$("$BUILD/ConfigLoad" -runs=0 "$q/cov-a" 2>&1 | sed -n 's/.*INITED cov: \([0-9]*\).*/\1/p')"
  b="$("$BUILD/ConfigLoad" -runs=0 "$q/cov-b" 2>&1 | sed -n 's/.*INITED cov: \([0-9]*\).*/\1/p')"
  [[ -n "$a" && -n "$b" && "$b" -gt "$a" ]] || die "qualification: coverage did not grow ($a -> $b)"
  echo "coverage: $a edges for {} -> $b with validation-failure input" >&2

  echo "== 5: production corpus replays under the fuzz toolchain" >&2
  local t
  for t in "${TARGETS[@]}"; do cmd_replay "$t" > "$q/replay-$t.log" 2>&1 || die "replay failed: $t"; done
  echo "qualification passed; logs in $q" >&2
}

case "${1:-}" in
  build) cmd_build ;;
  run) shift; cmd_run "$@" ;;
  smoke) shift; cmd_smoke "$@" ;;
  replay) shift; cmd_replay "$@" ;;
  merge) shift; cmd_merge "$@" ;;
  minimize) shift; cmd_minimize "$@" ;;
  qualify) cmd_qualify ;;
  *) sed -n '2,15p' "$0" >&2; exit 2 ;;
esac
