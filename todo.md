# First fork release TODO

Remaining work for `v0.1.0`. Record the final revision, toolchain, commands,
results and artifact digests. Earlier results do not qualify changed binaries.
See [release validation](docs/release-validation.md), [testing](docs/testing.md)
and [releasing](RELEASING.md).

## Acceptance gates

- [ ] Run `python3 tests/integration-proxy-transition.py --controlled-upstream`
  for guest SSH forwarding, streaming, leak scans, disconnects and cleanup.
  The local TLS fixture needs sudo authentication to bind port 443.
- [ ] Complete live-provider acceptance with approved models and dedicated
  credentials: Anthropic streaming/token counting, OpenAI Responses,
  disconnect/recovery and successful Claude/Codex guest tool use.
  Run `scripts/test-proxy-live.py` per approved model and
  `tests/integration-proxy-transition.py --live-agents` with approved model
  arguments; add `--filtered` for F1 native-agent acceptance.
- [ ] Complete filtered-egress NET-20/F1 qualification against the final
  candidate, or defer the capability from the first release. NET-20 is
  implemented (1907ea5..02f2cf6); the filtered VM gate (38/38) and
  `--live-agents --filtered` passed at 9c2d632, but not yet on a hosted
  candidate of the final revision. Include the full
  DNS/connect/relay pressure matrix and native-agent behavior. Follow the
  [transport](docs/testing.md#authenticated-filtered-transport-checks) and
  [broker](docs/testing.md#signed-broker-composition-checks) checklists.

## Final-candidate evidence

- [ ] Qualify the exact final revision with format, warning-free builds and
  tests for all four packages; host behavior/CLI contracts; and host-only
  install/update/uninstall regressions.
- [ ] Record applicable fault-injection, parser corpus, fuzz and sanitizer
  evidence. Mutations must fail running tests, not merely fail compilation.
- [ ] Qualify the final binaries with `./tests/run-integration.sh` and, if
  filtered egress ships, `python3 tests/integration-filtered-broker-readiness.py`.
  Cover lifecycle/isolation, recovery, host-key continuity, transfers,
  forwarding and changed devcontainer behavior.
- [ ] Confirm every required CI job is present and green on the final revision;
  record hardware gates separately.
- [ ] Run full `./scripts/preflight-release.sh` and the release build from a
  clean tree, resolving skipped gates and warnings before tagging.

## Distribution and publication

- [ ] Verify the hosted release environment's Developer ID/notary configuration,
  trusted maintainer release-signing key and backup-key readiness.
- [ ] Build a signed, notarized hosted candidate from the final revision.
- [ ] Verify archive checksums, all four binary digests, clean source metadata,
  tested/release flags, Developer ID signatures, notarization and pinned
  workflow attestation.
- [ ] Exercise clean-machine install, execution, update and uninstall with that
  candidate. Local ad-hoc signing does not qualify hosted distribution.
- [ ] Review release notes after final qualification; version, notes and tag
  must agree. Do not publish while NET-20/F1 remains unfinished.
- [ ] Before merging, obtain the repository-required confirmation for the
  host-gateway listener added by the reachability fixture. Re-review any further
  code or test repairs before landing the release content.
- [ ] Tag the final merge commit, verify the release workflow, then sign and
  publish the draft. A failed tag run spends the version; never move or reuse it.
- [ ] After publication, verify release assets and run the credential-free,
  version-pinned installer smoke test, including checksum signatures and
  bundled attestation verification.

## Follow-ups

- [x] Correct Claude installer retry diagnostics: capture curl's failure status
  inside the failed branch and bound each download attempt. Update
  `scripts/guest/claude-code.sh` and regenerate its embedded copy together.
  The earlier setup timeouts remain unexplained; stage markers distinguish
  downloading from installer execution if the stall recurs.
