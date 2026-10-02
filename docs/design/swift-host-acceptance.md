# Swift host acceptance ledger

Contract: [Swift host specification](swift-host-spec.md). This is a
requirement/evidence ledger, **not a completion declaration**: every gate
starts pending and stays open until it has passing evidence on the revision
being cut over. The Rust host remains the shipped CLI; the Swift `iso`
executable is a development build with only the commands listed under H-02.

## Tested revision and toolchain

| Item | Value |
|---|---|
| Baseline (Rust) | `e3ba69eccfcc92d4ebe964ed2a7b2bcbc5e02ae9` (branch `swift`). The spec names `143fdda`; the two differ only in test scripts and `docs/index.md`, not in host sources. |
| Tested revision | Uncommitted working tree on `e3ba69e`, 2026-09-27. Record the commit when this work is committed. |
| Host | macOS 27.0 (26A428), arm64 |
| Release toolchain | Xcode 27.0 (27A266a); Apple Swift 6.4 (`swiftlang-6.4.0.34.1`); Swift 6 language mode; deployment target macOS 27.0 |
| Resolutions | `Package.resolved`: swift-argument-parser 1.8.2 (`6a52f325…`), sha256 `8fe88f18…c326dea` |
| Fuzz engine | LLVM libFuzzer at `a47b42eb9f9b` (`release/22.x`) from the `libfuzzer-sys` 0.4.13 crate (checksum `a9fd2f41…29d2` in `fuzz/Cargo.lock`), compiled with Xcode `clang++` (Apple clang 21.0.0, `clang-2100.3.34.2`); source manifest sha256 `0b52df7b…e6fd32` |
| Fuzz instrumentation | Xcode `swiftc` `-sanitize=address -sanitize-coverage=edge,trace-cmp -Xllvm -sanitizer-coverage-inline-8bit-counters -Xllvm -sanitizer-coverage-pc-table`; campaigns add `-use_value_profile=1` |
| Python | Converter and its tests need Python 3.11+ (`tomllib`); run with CPython 3.14.7. `/usr/bin/python3` on this host is 3.9.6. |

## Gates

| ID | Status | Evidence | What remains |
|---|---|---|---|
| H-01 Configuration parity | **Open — phase 1 evidence recorded** | JSONC pipeline in `IsoConfiguration`: scanner → UTF-8 → strict structural preflight (duplicates by decoded, canonically-equivalent key; limits; trailing commas; BOM) → Foundation `JSONDecoder` into `JSONValue` → typed decoding with explicit absent/null/wrong-type handling. 8 parity fixtures: Rust loader output (`tests/baseline/config-normalize`) equals Swift output for every field except C-01 removals and the enumerated URL difference. Converter (`scripts/migrate-config-to-jsonc.py`) with 12 tests. `proxy setup` structural editor with round-trip and concurrent-edit tests. | Resolve CFG-120 (URL normalization) before porting model routing/MCP registration. Per-instance `proxy.json` literal overrides (C-04) when proxy orchestration is ported. Keychain provisioning (`proxy setup`). |
| H-02 CLI parity | **Passed for phase 4 (pending candidate rerun)** | Every baseline command is ported; `quickstart` is removed under C-03 and explains its replacement. `tests/test-swift-host-cli-surface.py`: 50/50 baseline command paths expose the baseline options (allowed differences listed with their decision). Read parity 35/35, lifecycle parity 30/30 (exit status, stdout, runtime call sequence, state files, build contexts; no recorded call differences), data-root parity 7/7, devcontainer `check`/dry-run byte-identical, GitHub `status` and `validate --probe` identical, uninstall non-TTY/flag errors identical. | Help-text layout is Argument Parser's (recorded, not normalized); stderr diagnostic format decision; rerun on the phase-5 candidate. |
| H-03 State compatibility | **Open — read and write paths** | Owner, machine record, journal, instance, image manifest and template records read and written in the Rust format (field names, `null` optionals, modes). On real hardware (isolated data directory): Rust `iso up` created an instance from a Swift-built image; Swift then operated it (status, logs, stop, grow, resources + boot with the Rust-enrolled pin, commit, restore + re-enroll); Rust read the Swift-written state and booted against the Swift-enrolled pin. Default-root guard parity 7/7 (upstream state and symlinked roots refused, explicit `--config` unchecked, leftover `~/.coop-apple` ignored); the `~/.coop-apple` migration and `.coop-apple` host-key alias were dropped in both hosts by user-approved change (2026-09-28). Journal recovery parity (set-resources applied, restore not applied, create taken over by destroy). | Existing long-lived installations (real upgrade of a user's state). |
| H-04 Ownership and security | **Passed for phase 4 (pending candidate rerun)** | 42 injected faults, each detected by a test that runs and fails; the harness now runs a clean control first and treats a fault that only breaks compilation as a harness failure (the earlier harness counted build failures as detections and dropped `fuzz/` and `tests/fixtures/iso-sandbox` from its copy, so the phase 1–3 count of 25 is superseded). Phase-4 faults: remote-command escaping, `EnvForward` redaction, workspace excludes, foreign SSH alias, `/workspace` mount collision, host-port probe, GitHub token on stdin only, update checksum, attestation repository pin, proxy fail-closed, Keychain without fallback; phase-5 additions: MCP definition on stdin, guest transport environment, PID identity before signalling, free proxy port, feature layer digest, no-follow feature reads. | Secret-leak scan of real guests beyond the proxy gate; interactive TTY/signal behavior. |
| H-05 Apple runtime integration | **Passed for phase 4 (pending candidate rerun)** | Real hardware, isolated state: Swift `setup`; Swift `up` (copy) with `--env` and `--post-start`, idempotent re-run, `exec`/`shell`, `stop`/`start` keeping the persisted env, `restore --reprovision -y` (guest wiped, host key re-pinned, workspace re-synced, env kept), `destroy`; Swift push/pull/ssh-config against a Rust-created VM; full agent bootstrap inside the proxy gate (H-06). | Port forwards on hardware (this scratch path exceeds the 104-byte Unix socket limit for `forwards.sock`, as it would for the Rust host); devcontainer Feature image build on hardware. |
| H-06 Proxy integration | **Passed** | `tests/integration-proxy-transition.py --swift-host .build/debug/iso` on real VMs with synthetic `cmd:` credentials: Swift bootstrap starts both provider proxies, guest gate and cross-VM capability rejection, synthetic-credential scan of guest files, proxy termination visible to guest clients and agents, startup failures, teardown — PASS. `--controlled-upstream` (user, 2026-09-28): `VMProxyFixture` preflight, both controlled TLS streams without VMs, then OpenAI and Anthropic TLS streaming through the real guest reverse tunnels (first event before completion) — PASS; private VMs destroyed. | — |
| H-07 Live acceptance | **Passed** | Approved models (user, 2026-09-28): Anthropic `claude-fable-5-1`, `claude-opus-5-5`, `claude-sonnet-5`; OpenAI `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`. All runs used dedicated `iso-live-*` Keychain credentials and `iso-proxy-swift` sha256 `4aec641d77f13ec48d725d6d8aef6bcdbedac4bc734072bc5032118ce4227c96` (user, 2026-09-28). Host API smoke (`scripts/test-proxy-live.py`, 256 output tokens): Anthropic (x-api-key) count_tokens, stream, client disconnect and recovery completed for all three models; OpenAI (bearer) stream, client disconnect and recovery completed for all three models; proxy output secret-free in every run — PASS. In-guest agent tool use (`tests/integration-proxy-transition.py --live-agents`, throwaway VM `proxy-live`): guest endpoints loopback (Anthropic `127.0.0.1:8788`, OpenAI `127.0.0.1:9788`), both running proxies the built binary with the hash above; `agent-tool-smoke.py` reported a successful tool result and final answer for `claude` with each Claude model and `codex` with each gpt-6 model; VM destroyed — PASS. An earlier OpenAI host run returned 401 `invalid_api_key` because the key had been stored through the `security -w` prompt, which keeps only 128 characters (test-setup error, not a proxy fault; see docs/testing.md "Dedicated live-test credentials"). | — |
| H-08 Swift build and tests | **Open — package, sanitizer and release-build tests passed** | `swift test --force-resolved-versions`: all targets pass; `swift format lint --strict` clean. Sanitizers: the full suite passes under `--sanitize=address`, `--sanitize=thread` and `--sanitize=undefined`. The ASan run found that the recursive parsers for untrusted input (devcontainer JSON, guest JSON, Codex TOML) could overflow a small caller stack below their depth caps; they now run on a fixed 8 MiB stack (`withParserStack`). `scripts/build-release.py --release --test` runs the host, `iso-proxy` (48+8) and `iso-sandbox` (82) tests from a staged copy; it found the Swift seed corpus was gitignored (fixed in `fuzz/.gitignore`). Fuzz qualification passed; corpus replay in `swift test`. | Mutation/Kani replacement evidence (fault injection stands in for mutation testing); the phase-4 untrusted-input parsers (devcontainer JSON, guest JSON, Codex TOML) have unit and sanitizer coverage but no fuzz target yet;  |
| H-09 Distribution | **Passed — hosted candidate** | Unsigned local candidates (debug and `--release --test --tag v0.6.0`) with verified `SHA256SUMS`, `BUILD.json` binary digests and `--version` stamping. Hosted candidate (user, 2026-09-28): `candidate.yml` run 36375672631 at `9946147` — same-revision CI passed, then `build-release.py --release --test --sign`; `iso`, `iso-proxy`, `iso-sandbox` each `codesign --verify --strict` and `spctl` "accepted, source=Notarized Developer ID", binary digests match `BUILD.json` (`release_build`, `developer_id_signed`, `tested`, clean source), `iso 0.6.0 (9946147)`, `iso-sandbox` 0.2.0 (containerization 0.45.0, protocol 2), `SHA256SUMS` OK, build provenance attested; artifact `iso-candidate-9946147…-aarch64-apple-darwin` (sha256:d409e032…5a9c). | Clean-machine install/run/update/uninstall from the candidate. |
| H-10 Rust removal | **Passed** | Removed 2026-09-28 (user-approved): `src/`, `Cargo.toml`/`Cargo.lock`, `build.rs`, `rust-toolchain.toml`, `deny.toml`, `.cargo/`, `fuzz/Cargo.*`, `fuzz/fuzz_targets`, `tests/baseline/config-normalize`. Before removal the read, lifecycle and data-root differentials were recorded from the Rust host into `tests/baseline/parity/*.json` (a fixed synthetic key and a byte-deterministic Feature archive make them reproducible); they replay against the Swift host with no Rust (35/35, 30/30, 7/7). libFuzzer is vendored in `fuzz/libfuzzer` (LLVM `a47b42eb9f9b`, Apache-2.0 WITH LLVM-exception, manifest SHA unchanged). With `PATH=/usr/bin:/bin:/usr/sbin:/sbin` (no `cargo`/`rustc`/`rustup`) and a fresh scratch path: `swift build` and the full `swift test` pass; `scripts/fuzz.sh smoke` builds libFuzzer and all three targets and runs them (also with no `HOME`). The inventory's `src/` references now use the recorded source-path and SHA-256 manifest, independent of the pruned Git history. CI without Rust (user, 2026-09-28): run 36373948109 at `9946147` — Host and runtime, Credential proxy and Workflow security audit passed with mise-pinned tools; no Cargo, `rustc` or rustup invocation in the logs. Final audit and reruns (2026-09-28, working tree after `9946147`): no Rust-era tool, config or dependency remains (the only SwiftPM pin is swift-argument-parser 1.8.2; `Package.resolved` files unchanged); `SECURITY.md`, `docs/trust-model.md` and `docs/platform-notes.md` no longer describe Firecracker/Lima hosts or the Firecracker kernel workarounds the Apple image does not apply; stale `.gitignore` entries removed. Gates, all PASS: hygiene (all files), `swift format lint --strict`, warning-free build, host tests, companion packages (proxy incl. confined-process, forwarding corpus and upstream-disconnect; sandbox 82 tests), read/lifecycle/data-root parity, CLI surface, inventory, migrate-config, preflight, proxy runner regressions, install/update/uninstall integration, ASan/TSan/UBSan, fuzz smoke, fault injection 43/43 detected, and `build-release.py --release --test --tag v0.6.0`. Follow-up (2026-09-28): removed the unused Firecracker/Lima-era guest scripts (`guest/init.sh`, `scripts/guest/cleanup.sh`, `guest-config.sh`, `preamble.sh`); `generate-embedded-resources.py` now emits `swift format`-clean output; replaced two deprecated `String(cString:)` array calls (a clean build of product and tests has 0 warnings; the earlier warning-free claim came from an incremental build); fixed two stale comments inside the guest image script, which changes the image hash (users' next `iso setup` rebuilds the image) — the lifecycle golden records this as a `revisions` entry of old→new hash substitutions, verified to reproduce the previous golden exactly when reversed. Reran: clean build, hygiene, lint, host tests, ASan, read/lifecycle (30/30)/data-root parity, CLI surface, inventory, fault injection 43/43 — PASS. | — |
| H-11 Final review | **Open — first independent review done** | Independent security and correctness reviews (review agents, read-only) of the Swift host against the Rust reference. Fixed: `AtomicFile` took a symlink's own mode (a rewritten 0600 dotfile link came back 0755/0644) — now follows the link like Rust; own-group children were orphaned when a signal ended isolate outside `Shutdown` scopes — `ChildGroups` forwards SIGINT/SIGTERM/SIGHUP to every live child group, verified end to end (`cmd:` child gone after Ctrl-C, exit 130); host-port probe lacked `SO_REUSEADDR` (TIME_WAIT reported busy); `iso exec` passed the caller's stdin to ssh (Rust: `/dev/null`); `Duration` milliseconds could trap on huge `--builder-timeout`; committed-disk rounding could overflow; dirty checks failed on >1 MiB output; corrupted instance dirs were skipped silently; the SSH probe left its master on timeout; TOML dotted keys were not depth-bounded (guest config could crash the host); guest/runtime text now has control characters neutralized in errors and diagnostics; `guest_env.json` is 0600 and instance directories 0700 (Rust: 0644/0755); one `.literal` interpolation. Carried-over findings fixed as accepted behavior changes (2026-09-28): MCP definitions go to `claude mcp add-json` on stdin; guest-bound ssh/scp/rsync inherit only a minimal host environment plus forwarded values (a user's `SendEnv` cannot leak a raw key); proxy/tunnel PIDs are signalled only while they still name `iso-proxy`/`ssh`; the proxy starts only on a free port and must be the sole listener (`lsof`) before the credential is sent; devcontainer Feature manifests and layers are digest-verified and `install.sh` is read as a bounded regular file without following links. | Review of the final revision after phase 6. |
| H-12 Simplification and scope | **Open — S-05 implemented** | S-05: `scripts/build-release.py` is the one release entrypoint: stages this checkout (tracked + untracked-unignored files) and stamps the revision, builds `iso` (release: `-D ISO_RELEASE_BUILD`), `iso-proxy`, `iso-sandbox`; `--test` runs all three packages; `--sign` (Developer ID + notarization, the only stage given signing secrets) is explicit and requires `--release --expected-revision`; the archive `iso-<tag|rev>-aarch64-apple-darwin.tar.gz` (isolate, iso-proxy, iso-sandbox, LICENSE, BUILD.json) plus `SHA256SUMS` matches the updater's layout. Unsigned dev and release (`--release --test --tag v0.6.0`) paths verified locally; `candidate.yml` uses it. S-01…S-04, S-06 and C-01…C-04 as recorded for phase 4. | Signed/notarized candidate path (needs the release environment's secrets); `release.yml` switches at cutover (phase 6); user docs at cutover. |

## Fuzz toolchain qualification (section 7.1)

`scripts/fuzz.sh qualify` builds a throwaway harness in `fuzz/.build` whose
deliberate faults are reachable only through the production parser; nothing
is added to production sources. Result on the tested revision: **passed**.

| Item | Evidence |
|---|---|
| 1. Links and runs with the libFuzzer entrypoint, no Rust tooling | Xcode `swiftc` + source-built `libFuzzer.a`; no Cargo invoked by `fuzz.sh` (Cargo only fetched the pinned source during the port). |
| 2. Coverage reaches production code | `ConfigLoad` loads 1,367 edges for `{}` and 1,461 once an input fails vm/proxy validation; the harness does not branch on those. The discovery run reached 1,052 coverage points (parser and harness together) before finding the key. |
| 3. ASan active in harness and source-built code | Deliberate heap-use-after-free behind a parsed key `"qz"` found by coverage-guided search (value profile) after ~7.5M executions (~200 s); reported as `AddressSanitizer: heap-use-after-free`. Foundation/system libraries are prebuilt and uninstrumented: no coverage or sanitizer claim for their internals. |
| 4. Save, replay, minimize, time bounds | Crash artifact saved and replayed; a 189-byte padded crash minimized to 9 bytes (`{"qz":""}`) and still reproduces; a deliberate hang is reported as `libFuzzer: timeout` at `-timeout=2`. Campaign limits: `-max_len=65536 -timeout=10 -rss_limit_mb=2048 -malloc_limit_mb=1024`. |
| 5. Same deterministic corpus under both toolchains | All three corpora replay under the fuzz build and in `swift test`. |

Limits: without value profiling, 12M executions did not find a 2-byte key
behind hashed or byte-compare gates, so campaigns enable
`-use_value_profile=1`. The libFuzzer sources are vendored in
`fuzz/libfuzzer` (the same files the Cargo registry supplied during the port;
the manifest SHA-256 is unchanged), so fuzzing needs neither Cargo nor a
download.

## Fuzz campaigns

Revision: tested working tree. Seed 20260927, 600 s per target, corpus
`fuzz/corpus` at this revision plus a work corpus in `fuzz/.build/corpus`.

| Target | Executions | Coverage | Peak RSS | Crashes / timeouts / OOM |
|---|---|---|---|---|
| ParseRepoSlug | 6,860,688 | 331 edges, 2,868 features | 1,552 MB | none |
| JSONCToJSON (after fix) | 5,674,841 | 171 edges, 1,816 features | 1,617 MB | none |
| ConfigLoad | 2,207,633 | 3,331 edges, 17,202 features | 566 MB | none |

### Phase 5 candidate-revision campaigns (2026-09-28)

Tested working tree after the phase 4 merge and H-11 fixes. Seed 20260927,
600 s per target, same limits, corpus `fuzz/corpus` (now tracked; see H-08).

| Target | Executions | Coverage | Peak RSS | Crashes / timeouts / OOM |
|---|---|---|---|---|
| ParseRepoSlug | 4,711,644 | 331 edges, 2,904 features | 617 MB | none |
| JSONCToJSON | 4,842,591 | 171 edges, 1,841 features | 960 MB | none |
| ConfigLoad | 2,162,335 | 3,380 edges, 18,299 features | 585 MB | none |

The first JSONCToJSON campaign found a real defect: under the devcontainer
policy only the last comma of a run such as `[2, ,]` was blanked, so
stripping was not idempotent (and diverged from the baseline, which drops
the whole run). Fixed in `JSONCScanner`; the minimized input is in
`fuzz/corpus/JSONCToJSON/regression-comma-run` and in `ScannerTests`, and
the campaign was rerun on the fixed build.

A harness property error (a repository named `y.git` loses its suffix on
re-parse, as the baseline intends) was found by corpus replay on first build
and fixed in the harness, not the parser.

## Recorded compatibility decisions

- **Format** (CFG-100): `~/.iso/config.jsonc`; `.json` is strict JSON via
  `--config`; `.toml` and a lone legacy `config.toml` stop with migration
  instructions; no `config.json` search.
- **Numbers** (CFG-121): Foundation decodes `2.0` and `2e0` as `Int64`; the
  preflight records fraction/exponent literals by path so integer fields reject
  them as the baseline did. Re-encoding cannot keep a literal's spelling, so
  `proxy setup` edits only configurations that already decode.
- **Duplicate keys**: compared with Swift `String` equality (canonical
  equivalence), matching how Foundation keys a dictionary; `"a"`/`"a"`
  and NFC/NFD spellings are duplicates.
- **Limits**: 1 MiB document, depth 32, 16,384 keys, 4,096 array elements,
  64-byte number literals, 64 KiB strings. The baseline TOML loader had no
  explicit limits; no known configuration approaches them.
- **Devcontainer scanner** (CFG-124): comments become spaces instead of being
  removed, so tokens on either side of a comment no longer merge.
- **`init`/`setup --config-only` with an existing file**: reports and leaves it
  unchanged (exit 0); the baseline `init` exited 1.
- **`proxy status` header**: names the configuration file generically
  instead of `[proxy] in config.toml`.
- **Display sanitizing**: the Swift host replaces every Unicode format
  (`Cf`) character; the Rust host used a fixed list of them.
- **Instance records**: `instance.json` is read without following a symlink,
  like other control files (the Rust host followed it).
- **Global options** may follow the subcommand as well as precede it.
- **Setup flags**: `--extra-packages` and `--post-install` warn that the Apple
  backend ignores them (the Rust host ignored them silently).
- **Open — CFG-120**: the Rust `url` crate normalizes URLs (empty path becomes
  `/`); Foundation keeps the configured spelling.
