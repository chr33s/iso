# iso: local and remote VM implementation package

**An implementation specification, an ordered task plan, and a runnable control/state prototype for `chr33s/iso`.** The initial remote target is a trusted Apple Silicon Mac running Linux guest VMs. Existing local Linux and macOS capabilities remain part of the production compatibility requirement.

Source baseline: [`47d17ba2524b145b229abcf42c85f8b5f0071e65`](https://github.com/chr33s/iso/commit/47d17ba2524b145b229abcf42c85f8b5f0071e65). Prepared 2026-10-09. The files in this package do not modify the upstream repository.

## Start here

| File | Purpose |
| --- | --- |
| [Implementation specification](iso-local-and-remote-vms-spec.md) | Scope, architecture, protocol, operation/recovery semantics, access grants, credentials, workspaces, migration, and release gates |
| [Implementation plan](tasks/plan.md) | Ordered delivery sequence, dependencies, checkpoints, and risks |
| [Implementation tasks](tasks/todo.md) | Focused tasks with acceptance criteria, verification, and likely source files |
| [Validation report](validation-report.md) | Actual prototype results, the deliberate broken-code check, and the remaining native qualification gates |
| [Prototype README](prototype/README.md) | Runnable demo, validation, manual exploration, and optional prepared-host SSH experiment |
| [Prototype contract](prototype-contract.md) | The deliberately smaller `iso.host.prototype/v0` experiment |
| [Mac validation runbook](mac-validation/runbook.md) | Existing baseline experiments and the future native Mac-to-Mac host-service gate |

The implementation specification is the production contract. The prototype contract explains what this experiment models; it must not replace the production access, durability, isolation, or migration requirements.

## Run the prototype

Requirements: Python 3.11+ on a POSIX system with `fcntl`, plus a writable current directory. There are no third-party Python dependencies. From this extracted directory:

```sh
python3 prototype/prototype.py demo
python3 prototype/validate.py --output prototype/evidence.json --trace prototype/validation-trace.jsonl
```

The default demo uses separate **local subprocess workers**, including one labeled `remote-model`. It does not connect to another computer or create a VM. Temporary state is isolated in marked `PROTOTYPE-*` roots and removed on completion unless `--keep` is supplied.

The recorded validation run passed **17 scenarios and 89 assertions** in 4.01 seconds on Linux x86_64/Python 3.12.14. The captured outputs are [evidence.json](prototype/evidence.json), [validation-trace.jsonl](prototype/validation-trace.jsonl), and [demo-output.txt](prototype/demo-output.txt). Re-running the suite produces new identifiers and timings.

An isolated mutation check removed the operation-payload conflict guard. The suite then exited 1 and caught the expected scenario; the delivered source was unchanged. See [mutation-evidence.json](prototype/mutation-evidence.json).

## Validate native behavior on Macs

The [runbook](mac-validation/runbook.md) distinguishes commands that exist at the source baseline from candidate commands that must be implemented. It includes dedicated fixtures, management and guest identity checks, real lifecycle experiments, frontend loss, lease revocation, independent TTL enforcement, headless operation, and exact cleanup.

The accompanying probe is read-only:

```sh
python3 mac-validation/probe.py --stage preparation
```

It checks platform/developer-tool observations only. On the delivery environment it correctly returned `unsupported_platform` with exit code 2; see [probe-evidence-linux.json](mac-validation/probe-evidence-linux.json). It cannot qualify the Apple runtime, a VM, SSH, a broker, or isolation even when its platform check passes.

## Implementation decisions

- Named execution hosts route operations to one host-owned service around the existing concrete AppleBackend.
- Durable operation identities, reservations, receipts, and tombstones make uncertain retries explicit.
- Client-owned workspaces, editors, and credentials remain separate from worker-owned VM lifecycle and enforcement.
- Short-lived access grants bind the host, instance, boot, policy, client key, and supervisor epoch; an owned relay can close existing streams.
- Disposable runs export before normal stop and use an explicit bounded recovery path when only a stopped disk remains.
- Local activation uses a stopped boundary, old-writer fencing, and a prepared-state handoff; no migration side effect stops an existing VM.

Remote Linux/cloud backends, remote macOS/computer use, worker-held credentials/detached agents, and remote resize/commit/restore are outside the first release. They require explicit later capability and qualification work.

## Evidence boundary

The portable model supports decisions about identity, retry, receipt history, unknown observations, and modeled session expiry. It does not validate real Apple VM effects, crash recovery around an external runtime call, actual SSH pinning, native isolation, production bearer/epoch security, live relay closure, broker readiness, host timers, or local migration. The implementation plan puts a small real Mac-to-Mac slice before broad product integration.

`SHA256SUMS` records the packaged file contents before distribution. It detects accidental changes relative to this package; it is not a signature or a claim of provenance from GitHub.
