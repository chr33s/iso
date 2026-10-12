# Host-control prototype

**Runnable experiment; every VM operation is simulated.** This is a throwaway Python implementation of the control and state subset in [the prototype contract](../prototype-contract.md). The production implementation remains Swift and must satisfy the implementation specification's native integration gates.

The normal demo and validation run two or more **local subprocess workers** with different state roots. The worker named `remote-model` is another local process. Neither command launches a VM, connects to another computer, touches `iso` state, or resolves credentials.

## Run it

Requirements: Python **3.11 or later**, a POSIX system with `fcntl`, and a writable current directory. The experiment was executed with Python 3.12.14 on Linux x86_64. macOS execution remains to be checked. No third-party Python package is needed.

From the extracted `iso-remote-vms-implementation` directory, run the demonstration:

```sh
python3 prototype/prototype.py demo
```

Run all validation scenarios and write fresh evidence:

```sh
python3 prototype/validate.py --output prototype/evidence.json --trace prototype/validation-trace.jsonl
```

The validation exits **0** only when every scenario passes. A failing scenario is included in the JSON and makes the process exit **1**. The JSON records the actual Python/OS environment, execution time, assertion counts, observations, and limitations. The JSONL trace contains each scenario, protocol request/response, and assertion; identifiers and fingerprints are generated or fake experiment values.

Both commands create temporary `PROTOTYPE-*` directories under the current directory and remove them at completion. Add `--keep` to either command to retain the explicitly simulated state for inspection. Manually initialized worker roots remain until you remove them.

## What the prototype validates

| Scenario | Question answered within this model |
| --- | --- |
| `happy_lifecycle` | Can a modeled instance be created, started, leased, stopped, and destroyed through the same control boundary? |
| `same_name_two_hosts` | Do equal names and equal modeled guest addresses remain distinct under host-qualified references? |
| `wrong_host_rejected` | Do the envelope host and the reference host both have to match the receiving worker? |
| `lost_committed_create_reply` | After the worker commits and exits without replying, does retry find the original instance and operation receipt? |
| `operation_payload_conflict` | Does an operation ID reject a changed method, target, or payload? |
| `frontend_restart_persists_identity` | Does a new frontend retain host identity and the committed operation outcome? |
| `unreachable_maps_to_unknown` | Does a failed inspection become unknown without issuing create/start or creating a state directory? |
| `changed_boot_invalidates_session` | Does replacement of a modeled boot invalidate the old session? |
| `wrong_session_key_rejected` | Is renewal refused and the modeled session invalidated when its fingerprint changes? |
| `modeled_lease_expiration` | Does the next request reconcile an expired access lease while the modeled VM can remain running? |
| `modeled_ttl_expiration` | Does the next request stop the modeled VM at its deadline, with no extension on duplicate start? |
| `delayed_create_retry_after_destroy` | Does a late retry return its historical receipt without recreating a destroyed identity? |
| `strict_worker_protocol_inputs` | Are duplicate keys, malformed/oversized frames, unknown envelope keys, incompatible protocols, and non-finite numbers rejected? |
| `strict_client_protocol_responses` | Does the client reject malformed/unbound/incompatible responses before adopting host identity? |
| `concurrent_operation_retry` | Do two simultaneous local frontends with one operation ID commit one modeled instance? |
| `changed_policy_invalidates_session` | Does a policy-binding mismatch refuse renewal? The policy change is a test-only local state fixture. |
| `ssh_argument_construction_only` | Does the opt-in adapter construct fixed-command, pinned-host SSH arguments? SSH itself is not executed. |

The supplied [evidence.json](evidence.json) and [validation-trace.jsonl](validation-trace.jsonl) are outputs from the executed run, not hand-authored expected results. Re-running the validation replaces those two outputs. UUIDs and measured durations will differ between runs.

A separate deliberate falsification check removed the operation payload-conflict guard in an isolated temporary copy. The mutated suite exited **1** and `operation_payload_conflict` failed with `Expected failure OPERATION_CONFLICT`; the other 16 scenarios passed. [mutation-evidence.json](mutation-evidence.json) records the change and confirms that the delivered source remained byte-identical. This establishes that the asserted refusal is exercised; it is not comprehensive mutation coverage.

## Model and implementation choices

Each worker stores one private `state.json`, a `PROTOTYPE_ONLY` marker, and a `worker.lock` within an owner-only `PROTOTYPE-*` directory. A per-worker `fcntl` lock serializes transactions. JSON state is written to a temporary private file, fsynced, atomically replaced, and followed by a directory fsync. The instance change and operation receipt are part of the **same JSON transaction**. Existing directories cannot be initialized accidentally; inspection never creates a missing root.

The model starts at time zero. The default VM TTL is **60 model seconds**, the access lease is **15 model seconds**, and the maximum requested TTL is **86,400 model seconds**. These are experiment constants. Advancing model time only changes the clock field; expiration is reconciled when the worker next handles a valid request. It is deliberately possible to inspect the raw file immediately after an advance and still see `running`.

Each local request launches a new stdio worker process, demonstrating that identity and operation receipts are in worker state rather than frontend memory. There is no persistent daemon. `--drop-after-commit vm.create` tells one frontend to exit with code 70 after a successful state commit and before emitting its response. The validation observes that exit code, then recovers through the same operation ID.

Operation identity is the SHA-256 of canonical JSON containing the method, host ID, and params. Object-key order does not matter; request IDs and operation IDs do not participate in the payload hash. **Retry with the same parameter content**, including the same choice to omit or include defaults. A changed payload with the same operation ID is refused. The experiment retains all receipts and tombstones and rejects new work at small fixed storage limits rather than evicting retry evidence: 128 instance records, 256 session records, and 1,024 operation receipts per worker.

**A receipt describes a past operation, not current liveness.** Replaying a create after destroy returns the original create snapshot, while a fresh `vm.inspect` returns `destroyed`. Replaying a successful start after modeled TTL expiration returns the original deadline and running snapshot without restarting anything. Reconcile the operation first and inspect the target afterward when current status matters.

## Wire subset

The protocol is `iso.host.prototype/v0`. Each direction uses one UTF-8 JSON object followed by a newline; a frame including its delimiter may be at most **65,536 bytes**. Requests and responses reject duplicate JSON keys, non-finite numbers, and unknown envelope keys. The subprocess client applies both output-size bounds and a transport deadline.

```json
{
  "protocol": "iso.host.prototype/v0",
  "request_id": "request-1",
  "host_id": "copied-worker-host-id",
  "operation_id": "create-1",
  "method": "vm.create",
  "params": {"name": "example"}
}
```

`hello` omits `host_id` and `operation_id`. All other methods require the pinned `host_id`. The VM reference is `{ "host_id": "...", "instance_id": "..." }`. All mutations, including the prototype's fake session operations, require an `operation_id`.

| Method | Params |
| --- | --- |
| `hello` | `{}` |
| `vm.create` | `{name, policy_hash?}` |
| `vm.start` | `{ref, ttl_seconds?}` |
| `vm.inspect`, `vm.stop`, `vm.destroy` | `{ref}` |
| `operation.get` | `{operation_id}` |
| `session.open` | `{ref, client_key_fingerprint}` |
| `session.renew`, `session.close` | `{ref, session_id, client_key_fingerprint}` |

The worker uses a fixed `prototype-owner` namespace. There is no production owner-authorization check. Fingerprints are inert labels; no private keys, provider credentials, real guest host keys, or real routes are sent through this protocol.

## Explore an individual local worker

These commands initialize and retain a private simulated worker, then create an instance:

```sh
python3 prototype/prototype.py init --root ./PROTOTYPE-manual
python3 prototype/prototype.py call --root ./PROTOTYPE-manual hello
python3 prototype/prototype.py call --root ./PROTOTYPE-manual --operation-id example-create vm.create --params '{"name":"example"}'
```

Copy the actual `host_id` and `instance_id` from that output into the following reference:

```sh
python3 prototype/prototype.py call --root ./PROTOTYPE-manual --operation-id example-start vm.start --params '{"ref":{"host_id":"COPY-HOST-ID","instance_id":"COPY-INSTANCE-ID"},"ttl_seconds":60}'
python3 prototype/prototype.py advance --root ./PROTOTYPE-manual --seconds 60
python3 prototype/prototype.py call --root ./PROTOTYPE-manual vm.inspect --params '{"ref":{"host_id":"COPY-HOST-ID","instance_id":"COPY-INSTANCE-ID"}}'
```

`advance` is a **local prototype-only fixture command**, never a remotely callable production method. Model time is not wall-clock time.

## Optional SSH experiment on a prepared host

This path runs the **same simulated worker** on a second computer. It was **not executed** as part of the included evidence. It does not create real VMs and cannot establish real guest networking, isolation, or deadline enforcement.

On a trusted POSIX worker with Python 3.11+, install a copy of `prototype.py` at `.local/lib/iso-host-prototype/prototype.py` relative to the SSH account's home directory. Create the parent state directory `.local/state/iso-host-prototype`, then run this command from that home directory:

```sh
python3 .local/lib/iso-host-prototype/prototype.py init --root .local/state/iso-host-prototype/PROTOTYPE-worker
```

Record the resulting installation `host_id`. On the client, use a trusted SSH config alias and an existing dedicated `known_hosts` file containing an independently verified management-host key:

```sh
python3 prototype/prototype.py call --ssh-alias prepared-mac --known-hosts /absolute/path/verified_known_hosts hello
```

Compare the reported installation identity with the worker's initialization output. Supply that identity for subsequent actions:

```sh
python3 prototype/prototype.py call --ssh-alias prepared-mac --known-hosts /absolute/path/verified_known_hosts --expected-host-id COPY-VERIFIED-HOST-ID --operation-id remote-example-create vm.create --params '{"name":"example"}'
```

The adapter uses the fixed remote command:

```sh
python3 .local/lib/iso-host-prototype/prototype.py worker --root .local/state/iso-host-prototype/PROTOTYPE-worker
```

Structured params travel over stdin. The adapter requires strict management-host-key checking, disables automatic host-key updates, disables agent forwarding and other forwards, and disables shared control sockets. It never installs the worker, modifies `known_hosts`, obtains credentials, or inserts request data into a remote command. Its SSH alias and client SSH configuration are trusted setup inputs. The supplied fixture checks argument construction only; actual OpenSSH behavior and connection failure modes still need an execution test on the intended deployment.

## Explicit limits before production implementation

Passing these scenarios supports the **control/state design within the model**. It does not complete the product's acceptance gates:

- No actual Apple VM, runtime image, disk, guest SSH, vmnet route, native isolation check, broker, editor, workspace transfer, or headless Mac is exercised.
- No actual local-to-remote SSH connection or cryptographic management/guest key verification is exercised. The SSH adapter is provided for an opt-in next experiment.
- There is no persistent supervisor, independent TTL timer, worker-owned relay, live connection revocation, guest process termination, daemon-epoch invalidation, or wall-clock lease enforcement. Fake-clock expiration is a model check.
- Session results contain only modeled public binding data. Their durable receipts **are not the approved production grant design**: production secret grants must remain volatile, bound to the supervisor epoch, and protected against replay. A reused modeled receipt cannot be treated as fresh access.
- VM generation increases are observed, but expected-generation compare-and-swap preconditions are not implemented. The concurrency test covers same-operation deduplication under a file lock, not production stale-write prevention.
- State mutations have no external effects beyond one JSON file. Crash recovery between a journal commit and a real runtime side effect, partially completed runtime work, cancellation, power loss, filesystem faults, and every production operation remain untested.
- The fixed owner namespace is not multi-user authorization, enrollment, quota management, or a security boundary against the trusted worker administrator.

The next evidence gate is a Mac-to-Mac native slice using the actual host service, Apple runtime, worker-owned supervisor and relay, pinned guest access, real workspace round trip, disconnect/reconnect, and real deadline/lease enforcement. See the implementation specification for pass/fail criteria.
