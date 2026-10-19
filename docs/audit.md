# Audit history (`iso.audit/v1`)

`iso audit` answers two questions from host-recorded evidence: what crossed an
instance's boundary (the instance view, unchanged), and what each managed
invocation did (run history). Everything is metadata: names, modes, counts,
identities and times. Prompts, secret values, argv, terminal output, request
bodies, transcripts and hashes of any of them are never recorded.

```bash
iso audit my-project                          # boundary events of one instance
iso audit my-project --suggest-config         # advisory narrowing fragment
iso audit --runs                              # recent invocations, newest first
iso audit my-project --runs                   # filtered by recorded instance name
iso audit --run <id>                          # summary and timeline
iso audit --run <id> --follow                 # human live view
iso audit --run <id> --output json            # one bounded iso.machine/v1 page
iso audit --run <id> --output jsonl           # one bounded page as stream lines
iso audit --run <id> --follow --output jsonl  # retained history, then live records
iso audit --run <id> --follow --output jsonl --after '<cursor>'   # resume
iso audit --runs --output jsonl               # one page of run summaries
iso audit --run <id> --export ./run-audit.json  # the full retained snapshot
```

Choose one view: the instance view (the default), `--runs`, or `--run ID`.
`--follow` and `--export` need `--run`. `--follow` accepts text or
`--output jsonl`; `--output json` is always one finite page. `--export` cannot
be combined with `--follow`, `--output`, `--after` or `--limit`.
`--suggest-config` belongs to the instance view, which is text only and reads
`<instance>/audit.jsonl` (1 MiB bound).

## Runs

Every actual `iso run`, `iso claude`, `iso codex` and `iso claude-agents`
invocation gets an **audit run ID** (`run_` and 32 hex) after argument
validation and before any preparation. The command prints it on stderr:

```
Audit run run_…; inspect with `iso audit --run run_…`
```

Workload stdout is unchanged. `--dry-run` creates no audit state.
`claude-agents` is recorded as an `administrative` attachment; iso does not
claim the background sessions it shows. `iso shell` and `iso exec` are not
runs.

A run records, as separate typed events:

| Kind | What it says |
|---|---|
| `invocation.requested` | command, role (`managed`/`administrative`), lifecycle (`persistent`, `disposable`, `existing`, `attachment`), the agent id and instance name as given, iso's own `--ask`, iso version |
| `invocation.preparation_failed` | the stage (`resolve`, `prepare`, `start`, `connect`) where the invocation failed before its handoff; never the error text |
| `invocation.environment` | after the running proof: instance, stable VM id and boot id (when known), image, guest OS, workspace mode, the boot's recorded egress and transport, policy mode and digest, proxied providers, the resolved agent definition and adapter version, the disposable session id; `requested` holds this invocation's configured egress, `proxy.mode` and session TTL; `unreadable` names host records that exist but could not be read, whose fields are then unknown rather than absent |
| `launch.handoff` | at `InteractiveSSH.attach`: transport, PTY, the names of variables forwarded into the session (never values; adapter defaults are excluded) |
| `launch.transport_ended` | the observed transport status: `exited N` or `signaled N` |
| `launch.transport_failed` | `revalidation_failed`: the isolation recheck refused the handoff and no transport started; `session_error`: the launch or its supervision failed without an exit status |
| `cleanup.observed` | a disposable run's cleanup: `destroyed`, `deferred`, `destroy_failed`, `start_failed` |

`transport exited 0` is the transport's status, never a verdict on the task.
A run with no terminal event shows **no terminal outcome recorded**; iso does
not infer that the launcher died. A cancellation request is not a confirmed
guest stop.

### What a run's timeline includes

For `--run ID`, in text, JSON, JSONL, follow and export alike:

1. events whose subject is that invocation (`relationship: invocation`);
2. host operations explicitly linked to it: `iso run-cleanup` of its
   disposable session (`linked_operation`);
3. boundary events of its exact known VM and boot, across the whole boot,
   including activity before or after the invocation (`vm_context`).

Another run's invocation events never join, even on the same VM. Instance
names and times never establish ownership. Without a known boot identity (an
instance booted before boot bindings existed), the VM context is omitted and
`coverage.vm_context` is `unavailable`.

## Event model

Each stored event is immutable:

```json
{"event_id":"evt_…","journal_id":"journal_…","sequence":1842,"recorded_at":"2026-10-18T09:42:14Z",
 "kind":"launch.transport_ended","producer":"iso","evidence":"host_observation",
 "subject":{"type":"invocation","audit_run_id":"run_…"},
 "data":{"transport":"ssh","termination":{"kind":"exited","status":0,"signal":null}}}
```

- `kind` is a closed set (above, plus `boundary.*` for the instance view's
  vocabulary and `store.recording_gap`).
- `evidence` is `host_request`, `host_observation`, `host_decision` or
  `store_record`; producer, evidence and subject are fixed by the producer's
  typed record, not chosen per event.
- `subject` is `invocation` (`audit_run_id`), `vm` (`vm_id`, `boot_id` or
  `null`), `operation` (`run_cleanup`, `session_id`) or `journal`.
- `event_id` is stable across pages and reads. Deduplicate by it.

Boundary events (`boundary.boot`, `boundary.pull_stage`,
`boundary.policy_decision`, ...) carry the same fields as the instance view,
plus `instance_name`, and are attributed to the VM's stable identity
(`policy-instance.json`) and its current host boot binding.

## Storage and retention

The store is `<data_dir>/backends/apple-container-v1/audit/v1/`, outside
instance directories, so history survives `iso destroy` and name reuse. It
holds owner-only bounded JSONL segments (`seg-<first sequence>.jsonl`, 4 MiB),
`journal.json`, one `checkpoint.json`, `capture-degraded.json` while capture is
refused, and the `.lock` / `.capture-degraded.lock` files. Writers append under
the store lock and wait at most two seconds for it; a record they cannot place
is counted as refused. Readers take no lock. Files are opened without following symlinks and parsed
with size bounds.

Retention keeps up to **7 days and 128 MiB** (checkpoint headroom included);
one event is at most 16 KiB. To retire the oldest sealed segments, the writer
builds a checkpoint of every run summary through their boundary `B` (identity,
exposure, observed outcomes, with the original event references and times),
publishes it atomically, and only then deletes them. A crash in between
leaves redundant segments that readers skip. A run whose last event is older
than 7 days expires as a whole with its detail and is counted in
`coverage.retained.expired_runs`; a run kept by the size budget alone keeps its
summary (`opener_retained: false`). A run with any event still retained is
never expired. At most 4096 run summaries and 64 gaps are kept in the
checkpoint; past that the oldest runs expire (counted) and the oldest gaps are
dropped. If a checkpoint cannot be published, valid history is kept and new
capture is refused (degraded) instead.

Failure rules:

- A recording failure warns on stderr and never changes the workload, its exit
  status, `stop`, `destroy` or cleanup.
- A refused capture is visible: `coverage.sources` reports `unavailable` while
  it lasts, and a `store.recording_gap` (`capture_degraded`, with the count and
  start) is recorded when capture resumes.
- A torn record is never written after: the writer starts a new segment, skips
  the torn record's sequence and records a `torn_record` gap. Unparseable
  records (including one whose `data` does not match its `kind`) and sequence
  discontinuities appear in `coverage.gaps`. A sequence
  that goes backwards is a terminal read error.
- `iso audit` reads only; it never repairs audit, VM or policy state.
- The host user can edit local history. No tamper-resistance is claimed.

## Reading

One typed reader serves every rendering. A page fixes a snapshot upper bound
`H`: the checkpoint through `B`, then retained events with `B < sequence ≤ H`.
Pages carry `as_of` (`journal_id`, `sequence` = `H`), `coverage` and a cursor.

- `--limit` (default 100, at most 1000) bounds the items of one page; a page
  also stays within 1 MiB of serialized items and returns fewer when needed.
  In follow mode it bounds each reader page, not the stream.
- Run detail is ordered by sequence. The run listing is ordered newest first by
  `(started_at, audit_run_id)` at the page's `H`.
- A cursor is bound to the selection, the schemas, the journal, the checkpoint
  `B`, `H` and the position, and is independent of JSON versus JSONL. A newer
  checkpoint, or a replaced journal, expires it (`cursor_expired`).

`coverage` has three dimensions: `sources` (`launch` and `boundary` are
`enabled` or `unavailable`; `agent_reports`, `network` and `remote` are
`unsupported` in this release), `gaps` (with sequence or time bounds), and
`retained` (journal, `checkpoint_through`, oldest and newest retained
sequences, expired runs, the retention policy). Transport and cleanup outcomes
are reported in the run summary, not in coverage.

### `--output json`

One `iso.machine/v1` document (see [machine-interface.md](machine-interface.md)):
`{selection, as_of, coverage, run, events, next_cursor}` for `--run`, and
`{selection, as_of, coverage, runs, next_cursor}` for `--runs`. `next_cursor`
is `null` exactly when the selected snapshot is exhausted. Redirecting a page
exports that page only; use `--export` for everything.

### `--output jsonl` (`iso.audit.stream/v1`)

UTF-8, one compact JSON object and LF per record, no BOM, blank lines or
styling, each record written whole and promptly (also to a pipe). stdout holds
protocol records only; diagnostics go to stderr, and `--quiet` discards them.
Every line has `schema: "iso.audit.stream/v1"` and a `type`:

| `type` | Content |
|---|---|
| `state` | `selection`, `mode` (`page` or `follow`), `as_of`, `coverage`, and `run` for run detail. Every start or resume begins with one, and a follower emits a fresh one before each new snapshot |
| `event` | `relationship` and the full stored `event` |
| `run` | one run summary (listing only), in listing order |
| `progress` | `as_of`, `snapshot_exhausted`, `cursor` (opaque or `null`), after every fully written page, including an empty one |
| `error` | `code`, `message`, `bounds` (or `null`); terminal, the exit status is nonzero |

Error codes: `invalid_argument`, `invalid_cursor`, `run_not_found`,
`cursor_expired` (with `bounds`), `reset_required`, `record_too_large`,
`unavailable`, `failed`. Every line is at most 64 KiB; an oversized record is
`record_too_large`, never truncated. Item limits count `event` and `run`
records only.

A finite invocation writes `state`, at most one page of items, then
`progress`, and exits 0. `snapshot_exhausted` says whether more remains;
`cursor` is the page's `next_cursor`, `null` only at exhaustion. It never
drains further pages on its own.

`--follow` drains every page at its `H`, then polls. A snapshot whose `H`
advanced emits `state`, its matching events (possibly none) and `progress`;
an unchanged poll emits nothing. Intermediate `progress` carries the fixed
cursor of the current snapshot; after exhaustion it carries a rolling cursor
positioned after `H`. `--after` accepts either in follow mode (a fixed cursor
finishes its snapshot first); finite mode rejects a rolling cursor. The stream
has no final "all activity complete" record and does not stop when the
transport exits; Ctrl-C stops only the viewer.

Persist a cursor only after processing the preceding items and a complete,
LF-terminated `progress` record. An interrupted page can replay items on
reconnect: deduplicate events by `event_id` and listing rows by
`(as_of.sequence, audit_run_id)`. Delivery is at least once while the cursor is
valid.

When a run gains a VM or session association whose earlier records a
follower has not seen (for example its boot became known), nothing is skipped
silently. A running follower re-reads under a fresh `state` and writes the
newly relevant events it has not written yet, so they can appear after events
with higher sequences. A follower resumed with `--after` whose cursor predates
the association fails with `reset_required`; read again without `--after`. The writer holds at most one page awaiting stdout and no audit lock
while it waits. A write failure (a broken pipe) stops the stream without an
error record.

### Text

`--runs` prints a table and `--run` a summary and timeline; both name the
continuation command when a page is not the last. `--follow` uses the same
live reader as JSONL: it prints the summary, then each newly selected event
once, including VM context that becomes known later. `--after` starts after
a cursor and, as in JSONL, fails with `reset_required` when the cursor
predates a new association.

### `--export PATH`

Drains one fixed snapshot of `--run` into a private temporary file beside
`PATH` and links it into place only after exhaustion. It refuses an existing
`PATH`, and an expired snapshot or read failure leaves no file. The file is
`{schema: "iso.audit/v1", selection, as_of, coverage, run,
snapshot_exhausted: true, events: [...]}` with mode 0600.

"Snapshot exhausted" means every retained record of the selected snapshot was
read, never that every guest action was observed. Summaries and anything
generated from them inherit the evidence's limits.

## Not in this release

Agent tool, session and subagent reports through a supported adapter
interface; structured proxy and egress decision metadata; and remote-host
provenance use the same model and appear as `unsupported` sources until they
are added.

The design review and the evidence for each essential check are in
[design/iso-audit.md](design/iso-audit.md).
