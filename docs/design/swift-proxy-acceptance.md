> **2026-09-27 cutover:** The user waived observation and authorized immediate
> Rust proxy deletion. Swift is now the sole implementation; the selector and
> rollback binary are removed. Earlier Rust/differential evidence below is
> historical. Live/platform/release gates remain open; deletion is not proof
> that those gates passed.

# Swift proxy acceptance map

Audit date: 2026-09-27. Contract: [approved specification](swift-proxy-spec.md).
This is a requirement/evidence map, **not a completion declaration**. The
[progress ledger](swift-proxy-progress.md) contains individual commands, faults,
results, and limits. Historical test results are not substitutes for the final
whole-branch review and required platform gates.

## Required next decisions and gates

| Requirement | Current evidence | What remains |
|---|---|---|
| §10.3: over-limit requests never reach the provider with the credential | User selected known-length admission: the Swift implementation rejects chunked bodies with 411 before upstream forwarding; declared lengths over 64 MiB receive 413. Neither framing header means an empty body. | Shared TLS boundary gate covers exact cap, cap + 1, and unknown length for both providers. See progress ledger for execution evidence and client compatibility limits. |
| §19.5: admitted traffic through real VM → SSH tunnel → confined Swift → controlled TLS upstream | Passed for both providers: request/response hashes, fixed identity and credential injection, header stripping, and first SSE event before completion. Full Apple gate exited 0; private VMs/images/listener cleaned up. | Run used a borrowed listener whose creator remained alive. The canonical sudo/privilege-drop helper also passed both provider preflights. Fixture uses a test CA and does not prove live-provider success. |
| §19.6: successful live provider and agent operations | Host API and guest tool-use runners exist; offline checks pass. Actual agents have only been verified on terminated-proxy errors. | Dedicated credential command references and approved models; successful Anthropic streaming/counting/Claude tool use and OpenAI Responses/Codex tool use, plus disconnect/recovery. |
| §20: same-revision signed/attested transition artifact | Local archive builder and manual workflow exist; local archive/signature checks passed. | Execute hosted CI and attestation from the actual source revision; inspect its resulting artifact and provenance. Local ad-hoc signatures and a workflow file do not prove this. |
| §16 phase 6: Swift default | Host resolves only `coop-proxy`; no selector or fallback remains. | User authorized immediate cutover. Validate Swift-only packaging/lifecycle; hosted distribution remains pending. |
| §16 phase 7 / §20: observation and Rust removal | User waived observation and authorized deletion. Rust proxy crate, dependencies, and selector removed; Swift retains language-neutral fixtures. | Other acceptance gates remain open independently of deletion. |
| §21 validation: final review | Independent whole-branch correctness/tests and security/API reviews of `2e1bf205` → `daca9ffd`, followed by release-channel delta reviews, found no surviving findings. | Review remains tied to that snapshot and the reviewed working delta; later changes require another review. External acceptance gates remain open. |
| Repository platform gates | Final standard Lima run at `daca9ffd`: 250 passed, 0 failed, 8 skipped across 52 phases. Controlled Apple gate passed. Prior Firecracker run had four lifecycle failures. | Firecracker shutdown durability and repaired-filesystem exit handling remain separate lifecycle follow-ups; affected source is unchanged from the approved baseline. Linux gate is not green. Full-only Lima tests were not run. |

## Specification coverage

“Recorded” below identifies evidence in the progress ledger. It does not assert
that every earlier result was rerun during this audit.

| Spec sections / deliverables | Implementation and evidence | Acceptance limit |
|---|---|---|
| §1 purpose; §2 D-001 process separation | Separate Swift executable, one process per VM/provider; Rust host CLI retained. | Controlled Apple VM forwarding passed; live-provider acceptance remains open. |
| §2 D-002; §12.1–12.3 system trust and identity | `UpstreamClient.tlsConfiguration`: full verification, `.default` roots, empty additional roots, HTTP/1.1 ALPN. Pinned NIOSSL Darwin trust path and confined native TLS probes recorded. Certificate tests include wrong host, expired, future, untrusted, and explicitly trusted self-signed fixtures. | Fixture-added roots are not evidence of administrator trust-store installation. Production system-trust evidence is the separate confined provider probe. |
| §2 D-003; §13 confinement | Checked-in deny-default Seatbelt profile; exact initial exec, denied writes/exec, loopback listener, port-scoped 443/53 egress, exact `com.apple.trustd.agent` addition documented. Process gate covers listener and denial probes; removing trustd permission broke TLS. | Port-scoped egress is not hostname-scoped egress. No sandbox technology migration is claimed. |
| §2 D-004; §8; §12.1 fixed providers/operations | Closed `Provider`, `RequestTarget`, `OperationPolicy`; provider-derived HTTPS host/443, raw origin-form policy before URL construction. Pure tests, mutation tests, refusal/forwarding corpora recorded. | Known-length admission does not alter permitted operations. |
| §2 D-005/D-006; §6 HTTP stack | Pinned NIO 2.100.0/NIOSSL 2.36.1. Native NIO/NIOSSL owned transport; HTTP/1 only; single request, no redirect loop. Redirect corpus verifies no second credentialed request. | Direct transport replaced the AHC pool after cancellation evidence; AHC request/body adapters remain. No HTTP/2 or custom HTTP framing parser. |
| §3.1–3.3 trust and protected credential | Host resolves secrets; stdin startup; guest receives capability. Process diagnostics redact input. Synthetic guest disk/env scans and canary validation recorded. | Synthetic scans are scoped evidence, not proof that arbitrary future logging cannot leak. Final review remains required. |
| §4.1–4.5 startup | Versioned strict `ProxyConfig`; unknown fields and invalid provider/scheme rejected. Bounded EOF read, stdin close, core limit and confinement before secrets/listener. Host clears child environment. Process gate covers malformed startup and no secrets in argv/logs. | Final release must retain the same launcher contract. |
| §5.1 listener | Validated loopback addresses; host's normal endpoint is 127.0.0.1; real HTTP readiness over reverse SSH tunnel. | §5.2 Unix listener is explicitly deferred. |
| §7.1–7.4 capability | 64 lowercase hex decoded to 32 bytes; CryptoKit HMAC authentication primitive; duplicate/conflicting presentations rejected; capability redacted. Unit, mutation, corpus, and cross-VM tests recorded. | Final review still checks all representations and callers. |
| §9.1–9.5 headers/trailers | `HeaderPolicy` strips guest credentials, Host, hop-by-hop and nominated fields; injects fixed Host and provider auth. Trailers refused. Shared admitted/refused corpora recorded. | An undeclared trailer discovered after streaming cannot undo earlier forwarding; no claim of retroactive withdrawal. |
| §10.1/10.2/10.4 streaming | `UploadStream`, `StreamingBridge`, `OwnedHTTPRequest`, `ResponseRelay`; flush acknowledgments and bounded queues. Single-stream and 256-client saturated response/upload RSS/progress/cleanup gates passed; retention faults caught. | Measurements include fixture peers and begin after TLS setup; not confined-process RSS. §10.3 remains open as above. |
| §11 constants and permit lifetime | `Limits`: 256 connections/requests, 16 KiB field, 64 KiB aggregate, 128 fields, 64 MiB body, 30s establishment/body idle, 10s header deadline. Header wire guard; capacity leases; bounded DNS/socket admission; cancellation/shutdown tests. Held streams and 257th request gate recorded. | No short total response timeout. Request framing decision must preserve these limits. |
| §13.1/13.2 self-test and fail closed | `Jail`, CLI `--jail-selftest`, process gate, and native DNS/system TLS. Missing/exiting Swift selection aborts real VM startup without Rust fallback; cleanup verified. | Controlled admitted Apple VM path passed; fixture-specific limits remain as documented. |
| §14 logs | Fixed error categories and redacted `Secret`/capability; no request/response logging in production path. Synthetic startup/process audit recorded. | Test observations must not be mistaken for production logging authorization. |
| §15 package structure | Pure `CoopProxyCore`, separate transport and executable targets. Core policy tests require no live network. | Recommended filenames/layout are organized into an additional transport target. |
| §16 phases 0–4 | Swift policy/server/TLS/confinement and known-length admission implemented with tests. Historical Rust oracle evidence is in the ledger. | Final whole-goal validation remains open. |
| §16 phase 5 | Historical differential suites and explicit rollback passed before Rust deletion. | Dual-binary distribution superseded by user decision. |
| §16 phases 6–7 | Swift-only cutover and Rust source/dependency removal applied at user request. | Validate the updated build/install/test paths; no observation period required. |
| §17–18 differential corpus/comparison | Shared refusal, forwarding, body-boundary, body-idle, disconnect, and capacity runners compare meaningful outcomes and forwarded properties. Raw adversarial fuzzing retained. | Earlier green subsets cannot waive later review or unexecuted VM/live gates. |
| §19.1–19.4 unit/embedded/mutation/fuzz | Swift Testing/XCTest, NIOEmbedded, Swift policy mutation tooling and targeted production faults; Rust mutation runs; language-neutral raw HTTP fuzz runner. Ledger records counts and timeouts. | Preserve timeout/unviable distinctions; final source changes need scoped revalidation. |
| §19.5 real VM | `/tmp/coop-listener-lifetime-result.json`: exit 0, both providers admitted through real guest tunnels, 19,501-file scan, two agent error observations, startup refusals, and verified cleanup. | `controlled_upstream: true`, `live_provider: false`; production profile unchanged, fixture CA and loopback upstream used. |
| §19.6 live tests | `scripts/test-proxy-live.py` and guest `agent-tool-smoke.py`; offline regressions/faults pass. | No successful live operation is claimed. |
| §20 release/rollback | Builder packages host/runtime plus Swift; installer/updater handle Swift-only companion and remove stale Rust files. Rollback implementation removed. | Channel configured for `chr33s/coop` with release commits from `swift`, Apple macOS artifacts, and matching installer/updater provenance. Hosted workflow execution and published-artifact verification remain open. |
| §21 architecture/secrets/HTTP/TLS/resource/sandbox/validation checklist | Sources and targeted evidence above cover individual assertions. | The checklist as a whole is **not achieved**: Live-provider tests, remaining platform gates and hosted release verification prevent completion. |
| §22 non-goals | No App Sandbox, Unix proxy listener, HTTP/2, arbitrary upstreams, certificate pinning, GitHub proxy, or shared provider process introduced. | Test-only loopback routing/CA seams are not production configuration. |
| §23 post-parity candidates | Deferred as specified. | These are not prerequisites to inflate the initial parity scope. |
| §24 invariants | Fixed identity, capability gate, stdin-only credential, confinement and streaming have implementation and scoped evidence. | Full completion remains unproven until all mandatory open items above are resolved. |

## Execution order

1. Known-length policy selected and applied; preserve its shared boundary gate
   when changing framing or client versions.
2. Controlled admitted Apple VM forwarding passed under the production profile;
   the canonical bind-helper preflight also passed. Preserve this gate.
3. Run dedicated live API and guest tool-use gates and inspect their observations.
4. Complete final scope-controlled security/correctness review and required gates.
5. Produce and verify the same-revision transition artifact; establish the intended
   install/update channel. Swift is already the sole proxy implementation.
6. User waived observation and requested immediate Rust proxy removal; validate
   Swift-only packaging and lifecycle.

Independent work can proceed while inputs are pending; none of the above may be
silently replaced by a narrower passing test or a prepared but unexecuted runner.
