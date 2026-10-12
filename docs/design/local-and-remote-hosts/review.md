# Review: ISO-HOST-001 package against `47d17ba`

Reviewed 2026-10-10 on macOS 27 / Apple Silicon (Swift 6.4) against the live
checkout. Scope: specification, plan, tasks, prototype contract and runbook.

## Verdict

The package is internally consistent and safe to implement. Every **E** file
the tasks name exists; no **P** file does. The ordering (ownership and
recovery before UX) is right. The findings below are corrections the
implementation applies; none changes the trust model.

## Findings

| # | Severity | Finding | Resolution in implementation |
| --- | --- | --- | --- |
| 1 | High | `IsoCore.OperationID` already exists as the **runtime** (`iso-sandbox --operation`) identifier. Reusing the name for the client-scoped host operation would conflate two retry domains. | New `HostOperationID` (UUID). The runtime `OperationID` stays the native journal identity underneath (spec 7.3: "existing per-instance journals remain the native layer"). |
| 2 | Medium | Spec 3.3 says "use the existing host user-service pattern". That pattern (`Launchd`) lives in `iso-sandbox`, which the host package must not link (Package.swift header). | A host-side `HostServiceLaunchd` that only builds argv for `ProcessRunner` and writes the plist through `AtomicFile`. |
| 3 | Medium | `FileLock` only blocks. `ServiceOwnershipLock` (spec 7.2, 14.2 step 6) needs a non-blocking attempt so a second daemon fails fast instead of queueing. | Add `FileLock.attempt(path:)` in IsoCore. |
| 4 | Medium | Wire decoding needs duplicate-key, depth and UTF-8 rejection. `ConfigLoader.parse(.json)` + `JSONPreflight` already enforce exactly that. | Reuse them with a wire `JSONLimits` (64 KiB request / 1 MiB response, depth 32) instead of a second parser. |
| 5 | Low | Spec 6.2 example `owner_id: "existing-validated-owner-id"` is not a valid `OwnerID` (32 lowercase hex). The spec already says the values are illustrative. | Fixtures use real-shaped values. |
| 6 | Low | Spec 7.5 "physically allocated metadata" is not defined operationally. | Reservations are fixed-size padded files written at admission; cleanup unlinks its reservation and writes into the freed space, so the ordinary quota never blocks it. |
| 7 | Low | The plan's "two Macs" requirement for T01/T03–T09 cannot be met by a single-host checkout. | `tests/integration-remote-host.py` records `blocked` for every case whose prerequisite (second Mac, qualified runtime) is absent; it never reports a pass it did not observe. |
| 8 | Info | `access.open` takes a client bearer on stdin; `ProcessRunner.Request.input` already covers that. | SSH transport sends frames on stdin only. |

## Native qualification boundary

Unit and in-process supervisor tests cover the state machines (ledger,
reservations, access registry, relay closure over local sockets, artifacts,
runs, cancellation). Migration preview is exercised only manually. Q1–Q4 still require the real two-Mac fixture
from `mac-validation/runbook.md`; nothing here claims those gates passed.

## Implementation review (2026-10-10)

Independent security and correctness reviews of the implementation found, and
the implementation fixed:

- Requests from the SSH frontend arrived on the local control socket and were
  treated as local (remote TTL and local-only refusals bypassed). The service
  now has a separate `remote.sock`; provenance comes from the accepting socket.
- An overflowing pax record length could trap the service on guest-authored
  run results; pax keys other than path/linkpath/times are refused (a `size`
  override would desynchronize validation from extraction); symlinks may not
  climb with `..` or pass through earlier links; member names compare
  case-folded as on APFS; non-tar artifacts are refused.
- Cancelling `run.create` left its child create to run; run children now run
  only from their parent, and cancellation retires both.
- A boot that failed its isolation/pin check could be recorded as running; it
  is now stopped and the start fails. An `unavailable` runtime retries a create
  it never attempted; a crash between instance commit and operation finish no
  longer double-increments the generation.
- Run reconciliation and admission now serialize on the admission lock; failed
  runs get the fixed retention deadline so their slot is reclaimed.
- Access open/renew re-check the instance under the admission lock; closing the
  last session for a key removes it from the guest (hygiene); relay shutdown
  happens under the registry lock; C1 and bidi controls are sanitized.
