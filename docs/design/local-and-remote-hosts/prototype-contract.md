# Prototype contract: iso remote host control (throwaway)

This contract fixes the subset the runnable prototype will exercise. Production implementation remains Swift and is specified separately. The prototype uses Python 3.11+ standard library so its state and transport experiments can run in this workspace and on a prepared Mac. It must always identify its runtime as simulated. No real VM is created by this prototype.

## Scope and questions

Validate target identity separation, durable operation deduplication across response loss and frontend restarts, typed unknown/unreachable outcomes, boot/policy-bound access sessions, host-authoritative modeled TTL and client lease decisions, and bounded versioned messages. Provide a local stdio adapter and an opt-in pinned SSH stdio adapter to run the same simulated worker remotely. Real Apple VM checks are a separate gate and must not be reported as covered.

## Wire subset

Protocol string: `iso.host.prototype/v0`.
One UTF-8 JSON object per line, maximum 64 KiB per request/response; no NaN/Infinity, duplicate keys, or unknown envelope keys.
Request: `{protocol, request_id, method, host_id?, operation_id?, params}`.
Response success: `{protocol, request_id, host_id, ok:true, result}`.
Response error: `{protocol, request_id, host_id, ok:false, error:{code,message}}`.

A hello has no host_id. All other normal methods MUST supply the pinned host_id. Methods: `hello`, `vm.create`, `vm.start`, `vm.inspect`, `vm.stop`, `vm.destroy`, `operation.get`, `session.open`, `session.renew`, `session.close`.
Mutations require operation_id; payload identity excludes request_id and must reject reuse with differing method/target/params.
Instance refs are `{host_id, instance_id}`; every VM action checks both. Owner authorization in production is represented by one fixed prototype namespace and is not a production authorization test.

## Semantics

- vm.create creates a stopped fake VM; same name allowed on different worker roots, same worker rejects duplicates.
- vm.start uses a host duration, new boot_id and incremented generation; repeated same operation_id returns its original outcome without resetting deadline.
- vm.inspect reports current modeled state; transport failures remain explicit errors mapped by client listing to state unknown. They do not create VM records or issue start.
- vm.stop and vm.destroy invalidate access sessions. A destroy leaves an identity tombstone for deduplication; no reused instance identity.
- An access session binds instance_id, boot_id, policy_hash, generation, client_key_fingerprint and lease expiry. Renew requires the same client fingerprint and current boot/policy. Failure invalidates the session; no rebinding to a new boot.
- VM TTL and controller lease use explicit prototype time advancement. This is a MODEL CHECK, not evidence of an independent live timer. Expired records are reconciled when the worker handles the next request.
- Use three default prototype constants: VM TTL 60 seconds, session lease 15 seconds, maximum TTL 86400 seconds. These are experiment constants, not production limits.
- Fault injection is a separate prototype-only CLI option such as --drop-after-commit METHOD; commit normal state and exit without response once, then retry by operation_id.
- Local model state uses explicitly named scratch directories, an owner-only marker and atomic JSON under a per-worker file lock. Normal demo creates temporary roots and deletes them on completion; --keep may preserve them for inspection.

## Expected deliverables

`prototype.py`: worker, client local/SSH transports, scripted demo, interactive commands if practical.
`validate.py`: executable scenario runner with assertions and JSON evidence; validation is the purpose of the prototype.
`README.md`: one command to demo, one to validate, remote simulated-worker instructions, explicit limitations.
Only edit files under `iso-remote-vms-implementation/prototype/`. Do not mutate chr33s/iso or launch actual VMs.

## Scenarios

Required: happy lifecycle; same name two hosts; wrong host rejected; dropped committed create response then retry yields one instance; changed payload with same operation_id rejected; worker frontend restart retains identity and operation; unreachable worker maps to unknown with no mutation; changed boot invalidates session; wrong session key rejected; modeled lease expiration; modeled TTL expiry; duplicate/oversized/malformed protocol inputs rejected; advertised protocol mismatch rejected by client.
Evidence names and implemented commands should be reported to root so the final spec can use exact runnable syntax.

