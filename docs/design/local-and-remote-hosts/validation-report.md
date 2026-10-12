# Validation report: iso local and remote VM design

**Date:** 2026-10-09  
**Production specification:** [ISO-HOST-001](iso-local-and-remote-vms-spec.md)  
**Source baseline:** [`chr33s/iso` at `47d17ba2524b145b229abcf42c85f8b5f0071e65`](https://github.com/chr33s/iso/commit/47d17ba2524b145b229abcf42c85f8b5f0071e65)

## Result

**The portable control/state prototype passed all 17 scenarios and 89 assertions.** A deliberate mutation also demonstrated that the suite detects removal of the operation-payload conflict guard. These results support the modeled identity, retry, observation, and session-state decisions in the specification.

**Native Mac-to-Mac VM qualification remains unrun.** The delivered environment is Linux x86_64. The read-only Mac probe returned `unsupported_platform` with exit code 2, as expected. No real Apple VM, remote SSH connection, broker, guest route, or editor was exercised. Production Swift changes are implementation tasks, not part of the runnable Python model.

## 1. Captured evidence

| Evidence | Observation |
| --- | --- |
| [Prototype evidence](prototype/evidence.json) | `passed: true`; 17/17 scenarios; 89 assertions; 4.007557 seconds |
| [Protocol/scenario trace](prototype/validation-trace.jsonl) | Actual requests, responses, assertions, and scenario boundaries from that run |
| [Demo output](prototype/demo-output.txt) | Local and remote-model labels, distinct simulated host identities, lifecycle and replay observations |
| [Mutation evidence](prototype/mutation-evidence.json) | Broken temporary copy exited 1; expected scenario failed; final source unchanged |
| [Mac probe evidence](mac-validation/probe-evidence-linux.json) | Linux x86_64; `unsupported_platform`; no native runtime or network experiment |

The validation evidence was generated at **2026-10-09 03:25:12 UTC** using **Python 3.12.14 on Linux x86_64**. UUIDs, fingerprints, addresses, and operation names in the trace are generated or synthetic experiment values. The measured duration describes this small simulator run; it is not a VM boot or remote-control performance measurement.

### Reproduce the portable experiment

From the extracted package root, with Python 3.11+ on POSIX:

```sh
python3 prototype/prototype.py demo
python3 prototype/validate.py --output prototype/evidence.json --trace prototype/validation-trace.jsonl
```

The validation exits 0 only when every scenario passes. A scenario failure is written to the evidence JSON and produces exit 1. The default worker roots are temporary and explicitly marked as prototype data. See [the prototype README](prototype/README.md) for retained manual state and the opt-in SSH adapter.

## 2. Scenario results

All conclusions in this table are limited to the model. An acceptance-case reference identifies the production requirement that the experiment informs; it does not mark that production acceptance case as fully passed.

| Scenario | Assertions | Observed result | Production relationship |
| --- | ---: | --- | --- |
| `happy_lifecycle` | 7 | Create, start, access, stop, and destroy complete through the modeled control boundary | Basic lifecycle shape |
| `same_name_two_hosts` | 4 | Two workers retain distinct host-qualified identities despite equal instance names and modeled guest address | Partial A01 |
| `wrong_host_rejected` | 3 | Wrong envelope/reference host is refused; the target remains running | Identity part of A02/R19 |
| `lost_committed_create_reply` | 5 | Frontend exits 70 after durable JSON commit and before reply; retry leaves exactly one instance | Model form of A04 |
| `operation_payload_conflict` | 3 | Changed params or changed method/target under an existing operation ID conflict | Model form of A06 |
| `frontend_restart_persists_identity` | 7 | New subprocess frontends retain the same worker identity and operation result | Persistence premise of A10; no persistent supervisor tested |
| `unreachable_maps_to_unknown` | 4 | Only inspect is attempted; unavailable worker yields unknown/unreachable and retains last-observed metadata | Model form of A08 |
| `changed_boot_invalidates_session` | 3 | A changed modeled boot refuses the old session | State binding part of A03 |
| `wrong_session_key_rejected` | 3 | A changed fake key fingerprint refuses renewal | State binding only; no cryptography |
| `modeled_lease_expiration` | 4 | After advancing model time 15 seconds, the next request observes expired access | Lease-state premise of A12; no stream closure |
| `modeled_ttl_expiration` | 5 | After advancing model time 10 seconds, the next request observes stop; duplicate start retains the original deadline | Deadline-state premise of A15; no host timer |
| `delayed_create_retry_after_destroy` | 4 | Old create returns its historical stopped snapshot; fresh inspect returns destroyed; no resurrection | Model form of A07 |
| `strict_worker_protocol_inputs` | 12 | Malformed UTF-8/JSON, duplicate keys, oversized/missing-newline frames, unknown envelope fields, protocol mismatch, and nonfinite values are rejected | Prototype subset of A19 |
| `strict_client_protocol_responses` | 13 | Invalid version, request identity, shape, size, duplicate keys, and changed application host identity are rejected | Client validation subset of A19/A02 |
| `concurrent_operation_retry` | 2 | Two simultaneous local frontends with the same operation ID commit one instance under a file lock | Deduplication only; expected-generation CAS untested |
| `changed_policy_invalidates_session` | 2 | A test-only changed policy fixture refuses renewal | Policy-binding premise of A03 |
| `ssh_argument_construction_only` | 8 | Fixed-command/pinning-related SSH arguments are constructed as expected | Argument construction only; SSH not executed |
| **Total** | **89** | **17 scenarios passed** | **Q0 model evidence** |

The lost-response experiment is the central useful result: the client does not need to invent a new allocation identity merely because it missed the reply. The worker can recover a committed result using the original operation ID. The historical-receipt experiment separately demonstrates why the client must inspect current state after recovering a receipt: a successful past create does not imply the VM still exists.

Those results depend on the simulator committing the instance mutation and operation receipt in **one atomic JSON transaction**. A real VM allocation is an external side effect and cannot share that transaction. Production correctness therefore additionally requires reserved runtime identities, an accepted-intent ledger, native observation, and reconciliation at every external-effect boundary.

## 3. Deliberate falsification check

In an isolated temporary copy, the following required guard was replaced with a no-op:

```python
require(old["payload_hash"] == identity, "OPERATION_CONFLICT",
        "Operation ID reused with different payload")
```

The modified suite exited **1**. `operation_payload_conflict` failed with **`AssertionError: Expected failure OPERATION_CONFLICT`**; the other 16 scenarios passed. The temporary copy was removed. The delivered `prototype.py` was unchanged, with SHA-256:

```text
cea13063cd71930e442e734ddfe1e6afe18c918e9f9dd83d14f42ee7f470b145
```

This demonstrates that the suite actually exercises this refusal. It is one targeted falsification check, not comprehensive mutation testing or proof that every defect would be detected. The [machine-readable record](prototype/mutation-evidence.json) preserves the exact change and outcome.

## 4. Production differences that matter

| Area | Delivered model | Required production behavior |
| --- | --- | --- |
| Runtime effect | Mutations to one JSON file | Real AppleBackend lifecycle with native ownership/isolation proof and crash reconciliation |
| Process lifetime | A new local worker subprocess per request | HostSupervisor survives frontend loss and owns accepted work |
| Identity | Host/instance UUIDs; fixed prototype owner namespace | Validated host/owner/instance/runtime identities, authorization, generation, boot and epoch |
| Access | Durable receipts containing fake public fingerprints | Client-generated secret bearer, hash-only volatile worker registry, explicit expected epoch, bounded non-evicting session history |
| Time | Explicit model-clock advancement; expiry reconciled on the next valid request | Independent native VM deadline enforcement and worker-owned live access timers |
| Revocation | Modeled session state changes | Existing relay streams, tunnels and dependent access actually close |
| Concurrency | File lock plus same-operation deduplication | Lifecycle serialization, expected-generation checks, safety preemption, reserved cleanup capacity |
| SSH | Adapter argument construction | Actual management-host pinning, end-to-end guest pinning, bounded connection behavior and relay transport |
| Files and credentials | Synthetic state only | Hostile workspace/artifact handling, client-owned stages, broker confinement and worker egress proof |
| Compatibility | Independent scratch state | Existing local data/CLI behavior, complete local service adapters, migration fencing and recovery |

The model uses `iso.host.prototype/v0`; production uses `iso.host/v1`. The model's 15-second access lease and 60-second default TTL are experiment values. The production proposal uses a 30-second access lease, 10-second renewal interval, and an 8-hour default remote VM TTL, subject to native qualification. A modeled lease expiration cannot establish a real-time shutdown guarantee.

## 5. Specification review and resulting decisions

The implementation contract was reviewed against the repository architecture and the delivered prototype. The following issues were resolved **in the specification**; their production verification remains part of the task plan.

| Issue | Specified resolution | Acceptance case |
| --- | --- | --- |
| A server storing only a bearer hash cannot resend a lost random token | Client generates and retains the bearer before open; worker retries return nonsecret matching metadata | A27 |
| Old access opens could revive after supervisor restart or history eviction | Every access method supplies the expected epoch; retain all issued IDs within a capped epoch | A11/A27 |
| Current runtime/input checks could hide an old accepted receipt | Authenticate and structurally decode first; deduplicate before dynamic admission preconditions | A28 |
| A full ordinary ledger could prevent cleanup | Reserve finalization/stop/destroy storage during admission; coalesce cleanup and avoid unbounded no-op receipts | A29 |
| Stopped disks are not automatically downloadable results | Export before normal stop; distinguish unexported disks; allow one bounded restricted recovery boot | A18/A30/A34 |
| Activated local features could bypass the service writer | Route existing local commit/restore/resize/macOS capabilities through local-only service methods | A31 |
| Migration could deadlock on a lifetime lock or serve half-activated state | Distinct locks, durable prepared handoff, activation-only supervisor, then committed active state | A32 |
| Cancellation had undefined timing/resource semantics | Atomic intent update wins only before an external effect; late requests receive a typed refusal | A33 |

These changes make the implementation plan concrete without implying that the Python model implements the expanded production protocol.

## 6. Remaining qualification gates

| Gate | Status in this delivery | Evidence still required |
| --- | --- | --- |
| Q0 — portable model | **Passed within stated scope** | None for the delivered 17 scenarios; keep it as a small reference experiment |
| Q1 — native remote slice | **Not run** | Two qualified Macs; persistent service; fixed pinned SSH; real create/start; native proof; owned relay; file round trip; verified stop/destroy |
| Q2 — failure and policy | **Not run** | Native effect-boundary response loss, epochs/bearers, live stream closure, broker/egress failure, offline-client TTL, hostile guest stop, quota cleanup, result recovery |
| Q3 — local compatibility | **Not run** | Existing Swift/CLI suites, complete local capability adapters, legacy state fixtures, stopped-boundary activation and crash recovery |
| Q4 — operational qualification | **Not run** | Cold and warm image setup, SSH-only account, locked GUI, logout, sleep/wake, worker reboot, real resource/log limits |

The [Mac probe result](mac-validation/probe-evidence-linux.json) is an expected refusal on an unsupported platform, not a passed native gate. The [runbook](mac-validation/runbook.md) provides exact existing-baseline experiments and clearly marks candidate experiments that require implementation first.

The first production slice should settle whether the selected Mac user-service/runtime arrangement can durably own accepted work and revoke an established guest route. Broader remote agents, editor integration, and migration follow that evidence. The [plan](tasks/plan.md) and [task list](tasks/todo.md) order this work and keep production completion unchecked.
