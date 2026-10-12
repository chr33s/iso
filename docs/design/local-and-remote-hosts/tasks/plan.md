# Implementation plan: local and remote VM execution

**Specification:** [ISO-HOST-001](../iso-local-and-remote-vms-spec.md)  
**Repository baseline:** [chr33s/iso at 47d17ba2524b145b229abcf42c85f8b5f0071e65](https://github.com/chr33s/iso/commit/47d17ba2524b145b229abcf42c85f8b5f0071e65)  
**Status:** Implementation plan. All production tasks in [todo.md](todo.md) remain unchecked. No production Swift change or real Mac qualification is represented as complete.

## Outcome and scope

Deliver host selection for existing local VMs and Linux guest VMs on trusted remote Apple Silicon Macs. The execution host owns lifecycle truth, accepted operations, native proof, deadlines, and guest-access relays. The client owns its project paths, stages, editor confinement, provider credentials, and session coordinator. Both new local and remote operations pass through the persistent host service after activation.

The first release includes remote setup, lifecycle, shell, Claude/Codex, code/zed, workspace transfer and review, application forwards, and attached disposable runs. Existing local Linux and macOS capabilities remain available. Remote macOS, remote resize/commit/restore, detached agents, new backend implementations, and multi-user hosting remain explicit unsupported capabilities. Capability checks must run before resource work or secret resolution for a new request. The full scope and behavioral contracts are normative in the specification.

## Evidence already available

| Evidence | Observed result | What it permits |
| --- | --- | --- |
| [Q0 model validation](../prototype/evidence.json) | 17 of 17 scenarios passed; 89 assertions; simulated runtime | Use the exercised identity, retry, protocol, and modeled-expiry conclusions to refine production code |
| [Q0 deliberate mutation](../prototype/mutation-evidence.json) | Removing the payload-conflict guard made the matching scenario fail; suite exit 1 | Confidence that this asserted refusal detects its removal |
| [Q0 protocol/assertion trace](../prototype/validation-trace.jsonl) | Captured requests, responses, and assertions | Reproduce and inspect the model's actual evidence |
| [Mac probe on this environment](../mac-validation/probe-evidence-linux.json) | `unsupported_platform`; exit 2 on Linux | Confirms the platform refusal only; no real Mac gate is passed |
| [Native validation runbook](../mac-validation/runbook.md) | Prepared instructions, not executed Mac evidence | A concrete starting point for T01 and subsequent native checks |

Q0 is finished. It is not a production dependency or a substitute for a persistent service, real guest routing, cryptographic verification, runtime isolation, live relay closure, or physical TTL enforcement. Preserve its evidence; do not repeatedly rerun it as a release gate for unrelated Swift changes.

## Decisions to carry into implementation

1. **Prove process ownership early.** A persistent per-user host supervisor accepts work through an authenticated private socket. A fixed SSH frontend is only a transport. Local production acceptance must have the same durable ownership as remote acceptance.
2. **Separate retries from new work.** Authenticate and decode first, then consult the ledger before current runtime qualification, capability, generation, or lifecycle preconditions. A matching historical receipt survives a stopped/destroyed target or changed qualification. A genuinely new request passes current admission checks.
3. **Reserve room to finish and clean up.** Allocate the required finalization, per-boot stop, and destroy metadata capacity before admitting work. Cleanup must remain possible at the ordinary ledger limit, coalescing with an existing operation when appropriate. An already-current cleanup request can return a fresh no-op observation without creating another accepted receipt.
4. **Make grant replay unambiguous.** The client generates a bearer with at least 256 bits of entropy. The worker stores only its verification hash in volatile state. Every access method and relay admission carries the expected daemon epoch. Issued/retired SessionIDs are not evicted within an epoch; at 65,536 issued IDs, refuse new admission while permitting renewal and cleanup.
5. **Own the guest route.** A worker-owned relay fixes the guest endpoint from native proof and can close existing streams. Removing a guest key alone is not revocation. Keep the existing guest pin end to end.
6. **Preserve client secrets and local safety loops.** The client coordinator renews the production 30-second access lease every 10 seconds and owns client brokers/tunnels. The worker keeps its existing one-second/two-second local egress loop. Neither connection failure nor broker loss enables a fallback route.
7. **Collect results while the source can be read.** Normal disposable completion exports bounded results before stopping. Distinguish a committed artifact from `stopped_disk_pending_export`. The latter permits at most one explicitly requested, bounded, restricted recovery boot per RunID with fresh proof and durably reserved child operations. It cannot resume agents, resolve provider secrets, or extend the retention deadline recorded at first verified stop. Reserve one of four run/result-retention slots at run creation and hold it through active, recovery, and pending states until cleanup; default disposable concurrency is therefore four. Expired workload TTL still permits observation, exact cleanup, retained-artifact access, and this separately qualified recovery path.
8. **Preserve all local service methods before activation.** Local resize, image commit, restore, macOS setup, and the existing supported macOS computer-use actions must have complete host-service routes. Remote refusals are deliberate capabilities, not missing dispatch cases.
9. **Hand migration to one owner.** The migration command prepares a handoff and releases its locks before service startup. Only the service completes activation under exclusive ownership. Old writers and pending journals block activation; migration does not stop running VMs automatically.
10. **Keep cancellation narrow.** Cancellation is an idempotent intent on the target operation, admitted only before native side effects start. A late request receives a typed refusal; disconnection is never cancellation.

These decisions incorporate the specification's reviewed operation, access, result-recovery, and migration contracts. New wire methods and record schemas must remain synchronized with that document.

## Delivery order and checkpoints

The default order is the following ten groups of three tasks. Detailed dependencies, acceptance criteria, likely files, and verification are in [todo.md](todo.md). The numbers identify implementation slices, not calendar estimates.

| Phase | Tasks | Working result at checkpoint | Gate |
| --- | --- | --- | --- |
| A — Native footing | T01–T03 | Reproducible Mac fixture; bounded typed hello through a persistent local service | Service ownership prerequisite |
| B — First native mutation | T04–T06 | Pinned remote frontend; durable create; real boot/stop with a worker-owned deadline | First native remote create/start slice |
| C — Recoverable native route | T07–T09 | Lost-reply recovery, tombstones, volatile access, and an owned relay carrying a pinned file round trip | Q1 |
| D — Selected-host inputs | T10–T12 | Explicit configuration realms, enrollment/selection, verified artifact ingestion | Q1 retained; broad UX starts here |
| E — Selected-host lifecycle | T13–T15 | Remote image setup, project coexistence, truthful status and compatible machine output | Lifecycle/user-facing slice |
| F — Supervised sessions | T16–T18 | Unified guest route, persistent client coordinator, and composed broker/egress readiness | Core Q2 policy behavior |
| G — Files and agents | T19–T21 | Remote copy/sync/git workspaces, offline stage review, and interactive agent workflows | Q2 workflow behavior |
| H — Editor and disposable completion | T22–T24 | Confined remote editor, scoped forwards, and normal run result export before stop | Q2 run/editor behavior |
| I — Recovery and local activation | T25–T27 | Restricted result recovery; complete local capabilities; safe service-owned migration | Q3 |
| J — Final lifecycle and release gates | T28–T30 | Safe cancellation, synchronized contracts/docs, fault-sensitive checks, full operational evidence | Q2–Q4 release decision |

### Checkpoint rules

After every group of three tasks:

- Review the focused test/native evidence and require a clean build for the affected package. A blocked prerequisite is recorded as blocked; it is not a pass.
- Inspect failure, retry, cleanup, identity, and process-lifetime behavior for the slice. Deliberately remove or bypass a promised refusal for each new security-relevant assertion and require a detected failure.
- Continue only when the phase's stated result is observed, or record a specific change to the affected scope. Checkpoints are engineering evidence reviews; they do not introduce an extra approval request for already-authorized work.

The **first stop/go decision is at T03**: the host service must actually survive frontend loss and reacquire safe ownership on the intended Mac deployment. The **second is at T06/T07**: native create/start and a lost reply must reconcile without an extra allocation or deadline extension. The **Q1 decision at T09** adds native proof, an enforceable relay, a pinned guest file round trip, and verified cleanup. Broad CLI/workspace/agent work must not be used to postpone these risks.

Do not advertise remote agent/editor support before T18's failure behavior is observed and the corresponding workflow task is complete. Local activation is not eligible until T26 preserves the existing capability set and T27 proves the handoff. Release requires the complete Q2, Q3, and Q4 evidence collected by T30.

## Task sizing and source navigation

The baseline's [architecture](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/ARCHITECTURE.md), [contributor guide](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/AGENTS.md), [code style](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/code-style.md), and [test reference](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/testing.md) remain the implementation conventions. Preserve the concrete Apple backend, native proof types, process/package separation, `ProcessRunner`, `StateStore`/`AtomicFile`, and `FileLock`.

Each task lists no more than five likely files. **E** identifies a file present in the pinned repository tree; **P** identifies a proposed new file. A P file stays marked P in this plan even when a later task extends it. These are implementation boundaries, not permission to hide additional independent work: if a task needs more than five substantive edits or more than three acceptance criteria, split the slice and update its dependencies before proceeding.

The suggested Swift suite names and `tests/integration-remote-host.py` are proposed additions. A listed `swift test --filter ...` command must not be reported as executed before its test exists. Production commands run from a real checkout on qualified macOS, not from this downloadable document package or the source-research snapshot.

## Verification policy

For a focused task, run its named suite and the existing tests that cover the changed boundary. At phase checkpoints, run the relevant package build and regression tests. At the final gate, apply the repository's required checks rather than claiming a complete result from the new suite alone.

Existing host commands include:

```sh
swift build --force-resolved-versions
swift test --force-resolved-versions
swift format lint --strict -r Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints
python3 tests/test-cli-surface.py --swift .build/debug/iso
python3 tests/test-read-contract.py --swift .build/debug/iso
python3 tests/test-lifecycle-contract.py --swift .build/debug/iso
python3 tests/test-data-root-contract.py --swift .build/debug/iso
python3 tests/test-machine-contract.py --swift .build/debug/iso
python3 scripts/swift-host-fault-injection.py
```

Use companion package checks when their code or behavior changes, and at release qualification:

```sh
swift test --package-path iso-proxy --force-resolved-versions
swift test --package-path iso-egress --force-resolved-versions
swift test --package-path iso-sandbox --force-resolved-versions --no-parallel
./tests/run-integration.sh
python3 tests/integration-proxy-transition.py --controlled-upstream
```

The native evidence must identify the source/candidate revisions, binary hashes, macOS/toolchain/runtime versions, exact fixture identities, accepted operations, boot/policy/epoch, expected and observed results, elapsed timing, and cleanup disposition. Cover the specification's final A01–A34 acceptance matrix. Keep diagnostic output bounded and secret-free. Run native tests against dedicated fixtures; an unresolved runtime object must be reconciled by identity rather than hidden by deleting its local metadata.

Q1 additionally measures warm local/remote control p50/p95, repeated SSH setup cost, and network RTT. Q2 measures actual relay closure and native stopped state. The VM TTL qualification bound is the recorded deadline plus 120 seconds; observed native stop time must be reported. Q4 records the real builder/service behavior before GUI login, after logout, through sleep/wake, and after reboot. A declared or missing login stage is not a measured pass.

## Dependencies and parallel work

T01–T09 are intentionally sequential because they establish shared protocol, state, and ownership contracts. T10–T15 then establish the public selection and image/workspace foundations. T16–T18 establish the common live-session path before agents and editors use it.

After those foundations stabilize, separate contributors can work on T19/T20's client stages, T21's agent integration, and T22/T23's editor/forwarding adapters **only after assigning ownership of shared SSH/coordinator files**. T26's local capability routes can proceed in parallel with remote workflow tasks after T15, but must finish before T27 activation. T28 cancellation can be implemented after T07's ledger/reconciliation contract is stable; it must be included in the final failure matrix. T29 documentation can be drafted incrementally, with final synchronization after behavior settles.

Keep operation schema changes, access registry changes, migration activation, and shared transport changes serial unless one contributor owns the shared contract. Never parallelize two writers to the same migration state machine or operation record design.

## Risks and the task that resolves them

| Risk | Consequence | Earliest resolving work |
| --- | --- | --- |
| User service or builder cannot operate in the supported SSH/headless context | Remote deployment assumptions are invalid | T01–T04; full startup matrix T30 |
| Acceptance is still tied to the CLI process group | A lost frontend abandons work | T03–T07 |
| Deduplication follows dynamic preconditions | A valid retry fails after the original effect changes state | T05–T07 |
| Metadata exhaustion prevents safety cleanup | A VM cannot be stopped/destroyed when limits are reached | T05, T24/T25, T30 |
| Stale access.open is re-created after expiry or restart | Old grants regain access | T08/T09 |
| A general jump host leaves streams alive | Claimed lease enforcement is ineffective | T09 and T18 |
| Broker evidence is checked in the wrong process/host realm | Required policy can be misreported as ready | T17/T18 |
| Result collection depends on SSH into a stopped VM | Normal or recovered results become inaccessible | T24/T25 |
| Local methods disappear when switching to the supervisor | Migration regresses existing macOS or maintenance workflows | T26 before T27 |
| The migration command and service deadlock on ownership locks | Activation becomes stuck or permits two writers | T27 |
| A cancellation request arrives after native effects begin | Partial state is mislabeled cancelled | T28 |

## Open implementation questions

No product clarification is required to begin this plan: use the specification's trusted-Mac, remote-Linux, interactive-client-broker defaults. The remaining questions are empirical gates, including actual launchd/builder behavior, routed stream closure, headless prerequisites, and shutdown timing. Resolve them with T01–T09 and T30 evidence. A failed gate may require narrowing a supported deployment assumption; it does not justify silently adding a new platform, credential realm, or weaker isolation mode.

The future implementation must follow the repository's pre-merge security-boundary review rule for network, process, filesystem, and secret changes. That eventual review is separate from producing these documents and does not mark any task as implemented or merged.
