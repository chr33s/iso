# `iso audit` run history: design and implementation status

**Status:** implemented on `audit-run-history` (first release: local capture,
store, reader and renderers). Agent adapter reports, structured proxy/egress
observations and remote provenance remain planned and appear as `unsupported`
coverage sources. The supported contract is [`../audit.md`](../audit.md); this
record keeps the design review it was built from (revision 3, 18 October 2026,
baseline `d27752a`), unchanged below the implementation notes.

## Implementation notes

Where the implementation settles something the sketch left open, or departs
from it:

| Topic | Implementation |
| --- | --- |
| Code | `Sources/IsoHost/State/AuditEvent.swift` (typed events, `AuditRecord`), `AuditStore.swift` (segments, checkpoint, retention, lock-free snapshots), `AuditReader.swift` (reducer, selection, cursors, coverage), `AuditRecorder.swift` (`AuditInvocation`); `Sources/IsoCLI/Commands/AuditCommand.swift` (text, JSON, JSONL, follow, export) |
| Capture seams | `RunWorkflow` (stages, environment, cleanup), `iso claude`/`codex`/`claude-agents`, `InteractiveSSH.attach` (handoff, transport outcome, refused revalidation), `run-cleanup` (linked by disposable session id), `BoundaryAudit.record` (boundary events by VM identity and boot) |
| Subjects | `invocation`, `vm` (`vm_id`, `boot_id`), `operation` (`run_cleanup` only) and `journal`; no separate workspace-operation subject was needed |
| VM and boot identity | The instance's `policy-instance.json` id and its host boot binding (`policy-binding.json`); boundary events without an identity are not attributed |
| Defaults | 7 days, 128 MiB (8 MiB checkpoint headroom), 4 MiB segments, 16 KiB events, 64 KiB JSONL lines, 1 MiB pages, 4096 retained run summaries, 64 retained gaps; compiled in, not configurable |
| Run expiry | A run expires as a whole only when it is older than the age limit and has no retained event; the oldest summaries past 4096 expire too, counted in `coverage.retained.expired_runs` |
| Writer lock | Owner-only and no-follow, with a bounded two-second wait; a record that cannot be placed is counted as refused and later recorded as a `capture_degraded` gap |
| `reset_required` | Returned to a follower resumed with `--after` whose cursor predates a new association; a running follower re-reads under a fresh `state` and writes only events it has not written |
| Instance view | Text only; `--output json` or `jsonl` without `--runs`/`--run` is `INVALID_ARGUMENT` |
| Transport failures | `revalidation_failed` (the isolation recheck refused the handoff) is distinct from `session_error` |
| Unreadable records | The environment's `unreadable` list names host records that exist but could not be read, so their fields are unknown rather than absent |

### Section 8 checks and their evidence

| Check | Evidence |
| --- | --- |
| 1 Distinct launch kinds | `aRunThatFailsToResolveRecordsItsStageAndNoHandoff`, `failuresBeforeTheHandoffAreRecordedAtTheirStage`, `auditSelectsExactlyOneViewAndMode`; integration `iso` phase (`iso run` of a probe agent) |
| 2 Shared VM attribution | `runsSharingAVMNeverAcquireEachOthersEvents`, `withoutAKnownBootTheVMContextIsOmittedAndSaidSo`; fault `audit-vm-context-exact-boot` |
| 3 Deletion, pruned opener, long runs | `retentionRetiresSegmentsBehindACheckpointAndKeepsRunIdentity`, `aLongRunningRunKeepsItsSummaryWhileItHasRetainedEvents`, `oldRunsExpireWholeAndAreCounted`, `retentionCapsRetainedRunSummaries` |
| 4 Crash around the checkpoint | `aCrashBetweenCheckpointAndDeletionReplaysNothingTwice`, `aCheckpointThatCannotBePublishedKeepsHistoryAndDegradesCapture`; fault `audit-checkpoint-before-retire` |
| 5 One `H`, explicit expiry, follow advances | `pagesStayAtOneSnapshotWhileRecordsArrive`, `pagesEndEarlyAtTheByteBudgetAndListingsStayAtOneSnapshot`, `cursorsExpireWhenTheJournalIsReplacedOrRetentionPassesAFollower`, `followDrainsThenEmitsOnlyForAdvancedSnapshots`; fault `audit-fixed-cursor-expiry` |
| 6 Complete exports only | `exportDrainsEveryPageIntoANewPrivateFile`, `anExportThatFailsAfterItsFirstPagePublishesNothing`, `exportNeverReplacesAFileCreatedDuringTheDrain`; fault `audit-export-no-overwrite` |
| 7 No invented success | `runSummaryDerivesOnlyWhatWasObserved`, `partialCleanupFailedTransportsAndSignalsNeverBecomeSuccess`, `textNeverClaimsMoreThanWasObserved` |
| 8 Canaries, hostile records, failing logging | `secretCanariesNeverReachTheStore`, `invocationRecorderNamesOnlyAndNeverFailsTheWorkload`, `missingJournalsSymlinksAndForeignCheckpointsAreRefused`, `aBusyStoreRefusesWithinItsBoundAndCountsTheRefusal`, `aRefusalIsCountedOnceWhenTheAppendAfterItsGapFails`, `tests/test-audit-contract.py` (hostile stored records); integration canary check; faults `audit-handoff-excludes-defaults`, `audit-store-real-directory`, `audit-refusal-counted-once` |
| 9 Existing contracts | The read, lifecycle, data-root, machine and CLI-surface contract scripts; the instance-view checks in `tests/test-audit-contract.py` |
| 10 JSONL lines | `finiteJSONLPagesAreIndependentBoundedLines`, `finiteJSONAndJSONLSelectTheSameRecords`; pipe flushing and stream purity in `tests/test-audit-contract.py` |
| 11 Catch-up, resume, deduplication | `aBootBecomingKnownRequiresAResetOfAResumedFollower`, `aLiveFollowerCatchesUpWhenItsRunsBootBecomesKnown`, `theTextFollowerShowsEachEventOnceAndLateContext`; rolling resume in `tests/test-audit-contract.py` |
| 12 Slow consumers, corruption, broken pipes | `tornTailIsNeverWrittenAfterAndItsSequenceIsSkipped`, `unparseableAndOutOfOrderRecordsAreReportedNotBridged`, `aFailedWriteEndsTheStreamWithoutAnErrorRecord`; lock-free and broken-pipe checks against the real binary in `tests/test-audit-contract.py`; fault `audit-torn-tail-sealed` |

## Design review (revision 3)

**Revision 3 · JSONL streaming added · 18 October 2026**  
**Status:** proposal only; repository code has not been changed.  
**Baseline:** [chr33s/iso at d27752a7fd1b1731c8dd700e2e9457c119e2fc2e](https://github.com/chr33s/iso/commit/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e).

### 1. Review verdict

The feature can be simpler without removing its proposed capabilities. Keep the first release's local run history, boundary evidence, live following, machine queries, export, retention, and honest coverage. Add finite and live JSONL output through the same reader. Keep agent adapters, structured proxy/egress observations, and remote support in the same later release scope.

The main change is **one audit store, one ordered event collection, and one reader**. Summaries are derived from recorded evidence. Retention needs one bounded checkpoint; it does not need independently updated status files for every run.

| Earlier sketch | Revised design | Why this is simpler |
| --- | --- | --- |
| Journal plus mutable per-run indexes, with historical index semantics | Journal plus one checkpoint at a retention boundary | One publication boundary; no per-event journal/index synchronization or index version history. |
| Separate `events` and `context_events` arrays | One ordered `events` array with explicit subject and a query-derived relationship | One ordering, limit, cursor, and renderer input. |
| Independent scope and nullable identity fields | A tagged subject; related IDs live in the relevant payload | Invalid combinations are prevented by types. |
| Repeated capture-quality concepts | Source availability, known gaps, and retained bounds | Human health labels are derived; outcomes remain separate. |
| Follow and export contracts only partly specified | Text/JSONL following and export use the finite reader | Shared filtering and snapshot rules; no separate streaming service. |
| Redirection of a bounded page presented as export | Distinguish machine pages from a full finite export | A first page cannot masquerade as all available evidence. |
| Missing end record described as an interrupted observation | “No terminal outcome recorded,” unless interruption was actually observed | A missing record does not establish that the launcher died. |

Two tempting cuts are rejected. Removing the invocation ID would merge separate attempts. Removing all retained summary state would lose identity and exposure when old event segments expire.

### 2. Preserved functionality

| Capability | Revised behavior |
| --- | --- |
| Find invocations | Global and instance-filtered run listing, including retained history for deleted instances. |
| Inspect an attempt | Local `iso run`, `iso claude`, and `iso codex`, including preparation failures and disposable cleanup observations. |
| Inspect the environment | Immutable VM identity, known boot identity, selected definition/adapter, and the effective exposure snapshot. |
| Review host actions | Launch/transport observations, boundary policy decisions, shadow verdicts, approvals, stages, direct and partial applies, and cleanup. |
| Preserve attribution | Run-related events, shared VM context, and guest reports remain distinct. |
| Retain history | Stored outside VM directories from the first event; bounded retention and visible missing detail. |
| Follow activity | Human and JSONL following continue beyond transport termination and can show later related operations or boot context. |
| Consume evidence | Versioned finite JSON/JSONL pages, resumable live JSONL, stable pagination, and a full export of one retained snapshot. |
| Understand limitations | Source availability, recording gaps, retention, transport outcome, and cleanup outcome remain explicit. |
| Preserve existing behavior | Legacy audit/config suggestions, serial logs, agent stdout, terminal behavior, passthrough, and exit semantics. |
| Preserve future scope | Agent tool/session/subagent reports, structured network observations, and remote provenance remain planned. |

This is a design-level preservation check, not a claim of tested implementation equivalence.

### 3. User contract

Give every actual managed invocation an `AuditRunID`. Create it after side-effect-free argument validation and before execution preparation. Link an existing disposable cleanup ID when present; do not use that ID as the universal run identity. The current cleanup record only covers local disposable runs. [S2]

Record recognized administrative invocations as administrative. Treat `claude-agents` as an attachment, not a claim to own its background sessions. `--dry-run` creates no audit state. Print the run ID and inspection command to stderr; workload stdout remains unchanged.

#### Proposed commands

```bash
iso audit my-project                         # Existing boundary view
iso audit --runs                             # Recent invocations
iso audit my-project --runs                   # Instance-filtered history
iso audit --run <id>                          # Summary and timeline
iso audit --run <id> --follow                 # Human live view
iso audit --run <id> --output json            # One bounded machine page
iso audit --run <id> --output jsonl           # One bounded page, one object per line
iso audit --run <id> --follow --output jsonl  # Retained history, then live records
iso audit --run <id> --follow --output jsonl --after '<cursor>' # Resume
iso audit --runs --output jsonl              # One bounded page of run summaries
iso audit --run <id> --export ./run-audit.json # Full finite snapshot
```

The new `--export` spelling makes complete export explicit. It shares the reader used by JSON pages. It replaces the earlier misleading suggestion that redirecting one bounded page necessarily exports the full history.

Select one of instance view, run listing, or run detail. The new JSONL mode supports finite run listing/detail and live run detail. Follow and export require run detail. Follow accepts text or JSONL, while `--output json` stays finite. Export is mutually exclusive with follow and either machine stdout format. Keep `--suggest-config` on the existing instance view.

Support `--after` and `--limit` for finite run pages and following. In follow mode, `--limit` bounds each reader page, not the total stream. Without a cursor, follow reads the selected retained history before tailing new records. JSONL without `--follow` emits exactly one bounded page; redirecting it does not implicitly export all pages. Cursor rules are defined in section 7.

A run summary shows the selected agent, environment, effective exposure, observed transport outcome, cleanup observations, and coverage. “Transport exited 0” never means task correctness. A cancellation request never means the guest was confirmed stopped.

#### Define context once

For a selected run, include:

1. Events whose subject is that invocation.
2. Operations explicitly linked to it by the host.
3. Boundary events for its exact known VM/boot through the snapshot boundary, labelled **VM context**.

The third category intentionally covers the whole boot, including activity before or after the invocation. This preserves the earlier example of a later unlinked workspace stage while making its relevance clear. Do not include other runs' invocation events merely because they share the VM. With no trustworthy boot identity, omit that join and show the limitation.

Use this selection rule in text, JSON, JSONL, follow, and export. Instance names and timestamps alone never establish ownership.

### 4. One typed event model

`AuditEvent` is immutable. Existing boundary producers and managed launch code submit typed values to `AuditStore.append`; they do not construct arbitrary JSON envelopes.

| Field | Rule |
| --- | --- |
| `event_id` | Host-generated stable ID for references and repeated query pages. |
| `journal_id`, `sequence` | Ordering and continuation within one journal generation. |
| `recorded_at` | Host recording time. |
| `kind` | Closed event-specific payload discriminator. |
| `producer`, `evidence` | Explicit origin and classification, assigned by a typed constructor. |
| `subject` | Tagged invocation, VM/boot, or workspace-operation identity. |
| `data` | Bounded fields specific to the event; not an arbitrary dictionary. |

Keep producer, evidence, and subject distinct. The same host component can record a request, observe an effect, or receive a guest report. Types enforce valid combinations; consumers still see explicit evidence labels.

A query adds `relationship: invocation | linked_operation | vm_context` to returned entries. This is derived presentation data, not a mutation of the stored event's ownership.

```json
{
  "event_id": "evt_example",
  "journal_id": "journal_example",
  "sequence": 1842,
  "recorded_at": "2026-10-18T09:42:14Z",
  "kind": "launch.transport_ended",
  "producer": "iso",
  "evidence": "host_observation",
  "subject": { "type": "invocation", "audit_run_id": "run_example" },
  "data": { "transport": "ssh", "termination": { "kind": "exited", "status": 0 } }
}
```

The enclosing journal segment/export supplies the `iso.audit/v1` schema. JSONL output embeds this same event model in the separately versioned line envelope defined in section 7. IDs above are illustrative.

Keep the separate event ID: deriving it from the sequence would require proving non-reuse through corruption and recovery for little practical gain. Host IDs deduplicate references to an already stored event. They do not automatically deduplicate repeated ingestion of the same provider report; an adapter needs a source-specific replay key, when available, scoped to its admitted session.

Move cleanup, stage, approval, policy-decision, remote-operation, and reported tool/session IDs into the payloads that actually use them. Do not reserve every future identity on every event.

### 5. Capture through existing boundaries

#### First release

Capture invocation request, preparation failure, workload handoff, observed SSH termination, and linked cleanup. Record safe launch identity and adapter version; exclude arbitrary arguments and environment defaults, including fingerprints of those values.

After the relevant host proof or resolution, record effective guest OS/image identity, workspace mode, egress mode, proxy/providers, policy mode/digest, forwarded variable names or capability presence, and known deadline. Requested settings and effective settings are different observations.

Extend existing typed boundary producers directly. Preserve decision, stage and approval references, counts, shadow-policy semantics, and partial outcomes. Do not scrape legacy JSONL or diagnostic stderr to reconstruct facts. Existing `BoundaryAudit` already supplies the main vocabulary. [S1]

The natural local launch hook is `InteractiveSSH.attach`, with typed context supplied by `RunWorkflow` and the direct agent commands. Avoid instrumenting all `ProcessRunner` calls: that would also collect credential resolution and internal maintenance. [S2][S3]

#### Later sources, using the same model

- **Agent adapters:** optional session, tool, subagent, and reported-completion events through a verified supported interface. Guest claims stay reports; unsupported versions say so. No terminal scraping.
- **Proxy/egress:** structured metadata at actual decision and transport seams. Existing denial diagnostics are lossy and omit allowed requests. Preserve VM/boot attribution and confinement; keep logging outside admission locks. [S5]
- **Remote execution:** link existing host run/operation identities and label origin-host and client-reported evidence. Local instrumentation does not imply remote coverage. [S7]

These remain the same later capabilities as before. Each adds a typed producer; none requires a generic plugin framework, a new audit daemon, or a new network listener.

### 6. One store with one retention checkpoint

Keep JSONL under `<stateRoot>/audit/v1/`, outside instance directories. Current VM deletion removes instance-local logs, and the repository explicitly uses transparent JSON state through `StateStore`/`AtomicFile` under `FileLock`. [S1][S4]

The store contains bounded journal segments and **one checkpoint**. A checkpoint preserves the reducer state through a retired segment boundary `B`: retained run identity, exposure, observed outcomes, and coverage. Keep original event references and observation times in retained summaries. Checkpoint creation is not a new observation.

A query at upper sequence `H` reads:

> checkpoint through B, followed by retained events where B < sequence ≤ H.

No independently mutable per-run status files, historical index versions, live lifecycle joins, or audit-owned execution state machine are needed. Add a disposable performance index only if measurement demonstrates a problem.

#### Safe pruning

1. Under the audit lock, choose a sealed boundary and build the bounded checkpoint from verified evidence.
2. Validate and durably publish the checkpoint atomically.
3. Only then remove covered segments. A crash before deletion leaves redundant segments, which readers ignore through `B`.

Keep run identity/exposure anchors for retained runs when their detailed opening events expire. Long-running histories may have pruned detail without losing their retained baseline. Baselines are subject to the declared retention policy and byte budget; finite storage cannot promise indefinite history. If safe checkpoint publication cannot fit, preserve valid history and explicitly degrade new capture instead of deleting evidence needed to interpret retained runs.

**Keep the provisional defaults:** metadata enabled; up to 7 days and 128 MiB total; 16 KiB maximum encoded event. Include checkpoint replacement headroom in the budget. Specify which whole run summaries expire alongside timeline detail; do not silently retain a listed run with an uninterpretable identity.

This checkpoint is necessary retained state. The simplification is one bounded publication point instead of per-run updates on every event.

#### Failure rules

- Audit failure warns on stderr, preserves workload exit behavior, and never blocks stop, destroy, or cleanup.
- A missing terminal event means no terminal event was recorded. Diagnose disconnection or interruption only from an actual observation.
- Partial or corrupt records produce visible read-health information. Recovery must not silently bridge an uncertain sequence range or reuse cursor identities.
- Retention or generation changes invalidate affected cursors explicitly.
- Read commands inspect audit data only; recovery/maintenance belongs to writers and never repairs VM or policy state.
- Owner-only files/directories, no-follow handling, bounded parsing, and control-character neutralization remain required.
- No prompts, secret values, raw argv, terminal output, request bodies, transcripts, or arbitrary payload hashes enter the default schema.
- The trusted host user can modify local history. No independently verifiable tamper-resistance claim is made.

### 7. One reader for text, JSON, and JSONL

Define one typed `AuditQuery` for instance history, run list, or run detail. `AuditStore.read` produces one bounded page; all renderers use it. This follows the repository's existing “collect once, render many” approach. [S4]

Use a typed result for each selection: run listing returns a `runs` array of derived summaries; run detail returns its summary and one ordered `events` array. Both carry coverage, `as_of`, and `next_cursor`. `--output json` remains one `iso.machine/v1` document. Advertise JSONL's separate `iso.audit.stream/v1` schema and supported finite/follow selections through `capabilities`. The legacy instance view keeps its existing JSONL/text shape and bounded legacy store; adapt it at the reader/renderer edge without changing its retention, output, or suggestion semantics. [S6]

Bind each finite opaque cursor to selection/filters, query/event schema, journal/checkpoint generation, fixed upper sequence `H`, and position. Cursor compatibility is independent of the JSON versus JSONL renderer. Detail uses a journal scan position; listing uses the immutable `(recorded_start_time, audit_run_id)` sort key for runs derived at that same `H`. The limit applies once to the selected collection. Keep the proposed default 100 and maximum 1,000; enforce a serialized-byte bound as well, returning fewer entries when needed. These new page limits do not truncate the legacy instance view.

All historical fields come from the same checkpoint and event prefix through `H`. A newer checkpoint cannot answer an earlier snapshot. A checkpoint publication that retires history conservatively expires older cursors, avoiding historical checkpoint versions.

| Output | Use of the reader |
| --- | --- |
| Text | Render one page and indicate continuation. |
| Finite JSON | Return one page; `next_cursor` means more retained records are available. |
| Finite JSONL | Render one page as state, event/run records, then progress. The progress cursor indicates continuation. |
| Follow, text or JSONL | Fix a fresh `H`, drain that batch, advance the live scan position to `H` even if nothing matched, then repeat. Ctrl-C stops only the viewer. |
| Full export | Drain one fixed `H` into a private temporary file; atomically publish the requested new file only after exhaustion. Refuse overwrite. Expiry or read failure does not publish an apparently complete export. |

Use “snapshot exhausted” to mean all available records in this selected snapshot were read. Never use it to mean every guest action was observed. Redirecting a JSON page exports that page only; destination permissions then belong to the caller.

#### JSONL line protocol

Emit UTF-8 with one compact JSON object followed by LF per record. Escape embedded newlines; do not emit a BOM, blank lines, arrays around the stream, pretty printing, or terminal styling. Flush each complete record promptly, including when stdout is a pipe. Stdout contains protocol records only; human diagnostics use stderr. Workload output is never interleaved.

Every line carries `schema: "iso.audit.stream/v1"` and a `type`. This envelope is a renderer projection over the existing reader, not another stored event format or a stream of `iso.machine/v1` documents.

| Type | Required content and purpose |
| --- | --- |
| `state` | Selection, mode (`page` or `follow`), `as_of`, coverage, and the run-detail summary when applicable. Every successful start/resume begins here, even midway through a snapshot. Emit fresh state before entering a new snapshot. |
| `event` | The full `iso.audit/v1` event plus its query-derived `relationship`. Retain stable IDs, ordering, producer, subject, and evidence classification. |
| `run` | One derived run summary; finite run listing only. Preserve the reader's stable sort order. |
| `progress` | `as_of`, `snapshot_exhausted`, and an opaque `cursor` or null. Emit after every fully written reader page, including an empty page. |
| `error` | A terminal code, safe message, and known relevant gap/retention bounds. Exit nonzero; never convert expiry or failure into successful exhaustion. |

The item limit counts `event`/`run` records only; control records still count toward the serialized-byte budget. Bound every encoded line to 64 KiB including LF and envelope, while keeping the stored event limit at 16 KiB. An oversized state, summary, or event produces `record_too_large`; do not truncate semantic evidence or invent chunk reassembly.

#### Completion and resume

A finite JSONL invocation emits state, up to one page of items, then progress and exits 0. This means that page was written successfully. Its `snapshot_exhausted` flag separately reports whether more selected records remain; `cursor` equals the reader's `next_cursor` and is null only at exhaustion.

Follow drains all pages at its current `H` before advancing to a fresh snapshot. Intermediate progress carries the ordinary fixed-`H` cursor. After exhaustion, it carries a tagged rolling cursor positioned after `H`, bound to the same selection/schema/generation. `--after` accepts either cursor in follow mode; a fixed cursor finishes its original snapshot first. Finite mode rejects rolling cursors. An advanced `H` produces progress even if no events matched. Unchanged idle polls emit nothing; no heartbeat service is needed.

Consumers persist a cursor only after processing the preceding items and a complete LF-terminated progress record. An interrupted page can replay items on reconnect: deduplicate events by `event_id` and run-list rows by `(H, audit_run_id)`. Delivery is at least once while that cursor remains valid. EOF or an unterminated line before progress leaves the page incomplete; resume from the last committed cursor. A follow stream has no final “all activity complete” record and does not stop when the transport exits.

Example tail of a follow batch, after its state record; identifiers and cursor are illustrative:

```jsonl
{"schema":"iso.audit.stream/v1","type":"event","relationship":"invocation","event":{"event_id":"evt_example","journal_id":"journal_example","sequence":1842,"recorded_at":"2026-10-18T09:42:14Z","kind":"launch.transport_ended","producer":"iso","evidence":"host_observation","subject":{"type":"invocation","audit_run_id":"run_example"},"data":{"transport":"ssh","termination":{"kind":"exited","status":0}}}}
{"schema":"iso.audit.stream/v1","type":"progress","as_of":{"journal_id":"journal_example","sequence":1842},"snapshot_exhausted":true,"cursor":"opaque-follow-cursor"}
```

#### Backpressure and discontinuities

Hold at most one bounded reader page awaiting stdout. Release audit locks and close segment handles before waiting on a consumer; never block recording, policy decisions, workload execution, or cleanup. Do not silently drop selected records or accumulate an unbounded queue.

If retention overtakes a cursor or its generation expires, emit `cursor_expired` with known bounds and stop. If a changed association makes older records newly relevant—for example, a previously unknown boot becomes known—emit `reset_required` and require fresh catch-up without `--after`. Do not silently skip this expanded context. Replayed events retain their IDs. Known recording gaps remain visible in state coverage; corruption that prevents trustworthy ordering is a terminal read error.

Emit an error record only at an intact line boundary while stdout is writable. If stdout fails during a record, stop writing; do not append an error to its partial bytes. Broken pipes and interrupts stop only the viewer, use the CLI's normal exit conventions, and cannot guarantee a final protocol record. All ordinary JSONL validation/read failures use the structured error form when possible. Stream records inherit the same privacy and payload bounds as stored/exported audit evidence.

#### Compact coverage

Keep only three coverage dimensions: source status (enabled, disabled, unsupported, unavailable), known recording gaps with available bounds, and retained history bounds. Derive human labels from them. Keep transport and cleanup observations outside coverage.

A reviewer agent can use finite JSON/JSONL, the live JSONL stream, or export and cite event IDs. Generated explanations remain separate from source evidence and inherit its uncertainty.

### 8. Implementation and preservation checks

Implement local capture/store and the shared reader/renderers as reviewable slices, then add the already-planned source extensions. Use existing lifecycle and policy stores as mutation authorities throughout.

Changes center on `BoundaryAudit.swift`, proposed `AuditEvent.swift`/`AuditStore.swift`, `GuestSession.swift`, `RunWorkflow.swift`, agent/read commands, and machine support. Update commands, machine-interface/trust-model documentation, capabilities, and contract fixtures together. [S1][S2][S3][S4][S5][S6]

The essential checks are:

1. Preparation failure, persistent launch, disposable launch, administrative attachment, and dry-run keep distinct behavior.
2. Two runs sharing a VM never acquire each other's invocation events or ownership of shared boundary activity.
3. Deletion/name reuse, a pruned opener, and a long-running history preserve retained identity and visible gaps.
4. Crash before/after checkpoint publication cannot lose the baseline or replay covered events twice.
5. Paging through concurrent appends stays at one `H`; retention expires it explicitly. Follow advances even when no event matches.
6. More than one page exports fully; expiry/corruption cannot produce a falsely complete artifact.
7. Signals, status 255, missing terminal events, cancellation requests, and partial cleanup never become invented success.
8. Secret canaries and hostile report envelopes stay out of stored/exported fields; logging failures preserve workload/cleanup behavior.
9. Existing CLI, output, terminal, policy-suggestion, and boundary contracts remain compatible.
10. JSONL lines parse independently, remain bounded, flush to a pipe, and never mix human diagnostics or workload output. Finite JSON/JSONL select equivalent records at the same snapshot; control records do not consume the item limit.
11. Multi-page catch-up, empty batches, cross-format fixed cursors, rolling resume, and interrupted pages preserve ordering and deduplication. No page is acknowledged before its complete progress record.
12. Slow consumers hold no audit locks; expiry, late context expansion, corruption, partial writes, and broken pipes remain explicit. The viewer cannot block or cancel the workload, and a failed stream never reports successful exhaustion.

Native Swift/macOS gates apply during implementation. This review exercised the design through counterexamples and source inspection; it did not execute those runtime checks.

### Sources

All repository links use the same inspected commit.

- **[S1]** [BoundaryAudit](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/State/BoundaryAudit.swift), [read commands](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoCLI/Commands/ReadCommands.swift), [instance deletion](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/Lifecycle/AppleLifecycle.swift).
- **[S2]** [RunWorkflow](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/Lifecycle/RunWorkflow.swift), [RunSession](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/Lifecycle/RunSession.swift).
- **[S3]** [GuestSession](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/Guest/GuestSession.swift), [agent commands](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoCLI/Commands/AgentCommands.swift).
- **[S4]** [Architecture, including state and rendering invariants](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/docs/ARCHITECTURE.md), [Package.swift](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Package.swift).
- **[S5]** [Proxy startup identity](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/Guest/ProxyStartup.swift), [provider authorization diagnostics](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/iso-proxy/Sources/IsoProxyTransport/ProviderAuthorizer.swift).
- **[S6]** [Machine interface](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/docs/machine-interface.md), [trust model](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/docs/trust-model.md).
- **[S7]** [Remote RunStore](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/HostControl/RunStore.swift), [remote completion handling](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/HostControl/HostRuns.swift).
