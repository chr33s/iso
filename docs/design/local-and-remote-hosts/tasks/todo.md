# Implementation tasks: ISO-HOST-001

**Baseline:** [47d17ba2524b145b229abcf42c85f8b5f0071e65](https://github.com/chr33s/iso/commit/47d17ba2524b145b229abcf42c85f8b5f0071e65)  
**Normative behavior:** [Implementation specification](../iso-local-and-remote-vms-spec.md)  
**Sequence and release policy:** [plan.md](plan.md)

All production tasks below are **not implemented**. Q0's delivered model has already passed 17 scenarios/89 assertions and its deliberate payload-conflict mutation check. The Linux Mac-probe result is unsupported, not Mac qualification. No calendar estimates are assigned.

**File legend:** **E** = present in the pinned repository tree. **P** = proposed new file, including a proposed file introduced by an earlier task. Each task has at most five likely files and three acceptance criteria. Named new Swift suites and the remote integration runner are proposed until implemented. Run Swift/native verification on a qualified Mac checkout.

## Phase A — Native footing

### T01 — Establish a reproducible native qualification fixture

Prepare the evidence-producing native test entrypoint and an isolated Mac fixture using the supplied runbook. Keep the exact baseline distinguishable from candidate changes.

**Dependencies:** None. **Scope:** Small, 2 files.

**Likely files:**

- **P** `tests/integration-remote-host.py`
- **P** `docs/design/local-and-remote-hosts-spec.md`

**Acceptance criteria:**

- [ ] The fixture records both Mac identities, OS/toolchain/runtime/builder versions, source/binary hashes, and explicit pass/fail/blocked evidence with no secrets.
- [ ] Baseline image setup, native ownership/proof, pinned guest sentinel access, and exact fixture cleanup run using the existing commands before candidate results are accepted.
- [ ] An unsupported host, missing tool, unavailable builder, or unexecuted case fails/blocks the gate rather than passing it.

**Verification:** Execute the read-only probe and baseline stages in [the runbook](../mac-validation/runbook.md) on the two prepared Macs. Deliberately remove one prerequisite from a controlled fixture and require a blocked/failed result. Do not count the delivered Linux probe as this task's verification.

### T02 — Define validated identities and bounded control messages

Implement the typed host-control contract and closed v1 wire decoder, initially proving hello and request admission without allocating a VM.

**Dependencies:** T01. **Scope:** Medium, 4 files.

**Likely files:**

- **P** `Sources/IsoCore/HostIdentity.swift`
- **P** `Sources/IsoHost/HostControl/HostControl.swift`
- **P** `Sources/IsoHost/HostControl/HostProtocol.swift`
- **P** `tests/swift/IsoHostTests/HostControlProtocolTests.swift`

**Acceptance criteria:**

- [ ] Host/owner/instance/runtime/operation/session/epoch identities and typed error/retry classifications have validated constructors and deterministic canonical request encoding.
- [ ] The decoder enforces the specification's request/response bounds and depth, rejecting duplicate keys, non-finite values, invalid UTF-8, unknown closed fields, and incompatible versions before dispatch.
- [ ] Response correlation and host/owner identity are checked before using data; hello exposes explicit supported methods without implying native readiness.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlProtocolTests`; mutate one field/size/correlation guard and require the relevant assertion to fail. Keep the public machine protocol separate from this internal wire protocol.

### T03 — Run hello through a persistent local host service

Introduce the per-user supervisor and local socket transport. Wire the fixed internal command entrypoints without moving existing local installations into the new service yet.

**Dependencies:** T02. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `Sources/IsoHost/HostControl/LocalHostControl.swift`
- **P** `Sources/IsoCLI/Commands/HostAgentCommands.swift`
- **E** `Sources/IsoCLI/IsoCommand.swift`
- **P** `tests/integration-remote-host.py`

**Acceptance criteria:**

- [ ] A host-managed user service exclusively owns a private, peer-user-checked socket with a bounded socket path and stable installation identity.
- [ ] Killing the hello frontend or its process group leaves the service available; a service restart yields a new daemon epoch and preserves installation identity.
- [ ] Fresh dedicated roots work through the service while legacy local roots remain on their compatibility path; no activation or VM stop happens implicitly.

**Verification:** Native fixture: start the service, perform hello from two separate local frontends, terminate one frontend/group, reconnect, then restart the service and inspect identity/epoch. Record real process ownership and resource cleanup.

### Checkpoint A — Persistent service prerequisite

- [ ] T01–T03 have observed evidence, a clean host build, and no unaccounted fixture service/process.
- [ ] Service ownership works in the intended SSH-user context; a missing headless prerequisite is explicitly blocked.

## Phase B — First native mutation

### T04 — Reach the persistent service through pinned SSH

Add the fixed remote control frontend and client transport before adding broad host configuration UX.

**Dependencies:** T03. **Scope:** Medium, 4 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/SSHHostControl.swift`
- **P** `Sources/IsoCLI/Commands/HostAgentCommands.swift`
- **P** `tests/swift/IsoHostTests/HostControlSSHTests.swift`
- **P** `tests/integration-remote-host.py`

**Acceptance criteria:**

- [ ] A verified management host/account reaches only a validated installed entrypoint plus fixed arguments; request data travels on stdin, through `ProcessRunner`.
- [ ] Wrong management pin, application host/owner identity, protocol, or runtime qualification is distinguished and cannot silently re-enroll the target.
- [ ] Disconnect/reconnect leaves the supervisor alive and returns bounded typed failure; no agent forwarding, raw secret argument, or automatic host fallback is introduced.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlSSHTests`, plus real Mac-to-Mac hello, deliberate management-pin failure, application-identity mismatch, and frontend termination in the native fixture.

### T05 — Accept one durable native create with cleanup capacity reserved

Implement the production operation ledger and allocation reservation, then use it for the smallest native create path against the prepared image.

**Dependencies:** T04. **Scope:** Medium, 4 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/OperationStore.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **E** `Sources/IsoHost/Lifecycle/AppleLifecycle.swift`
- **P** `tests/swift/IsoHostTests/HostControlLedgerTests.swift`

**Acceptance criteria:**

- [ ] Authentication/static decoding precedes locked ledger lookup; matching retries return/reconcile existing work before current capability/runtime/generation/state checks, and conflicting payloads have zero extra effects.
- [ ] Stable instance/runtime IDs, canonical request identity, and accepted intent are fsynced before native allocation; allocation and native proof stay on the execution host.
- [ ] Admission physically reserves metadata needed for finalization, per-boot stop, and destroy; ordinary capacity exhaustion refuses new work while exact cleanup/reconciliation remains possible through reserved/coalesced records or a fresh no-op observation.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlLedgerTests`; run one real accepted create from the remote client and compare reserved/native identities. Fault the dedup guard and exhaust ordinary ledger capacity; require both conflict detection and successful exact cleanup.

### T06 — Boot and stop the native fixture with its original deadline

Extend the accepted-operation path to native start, inspection, and stop while retaining the runtime owner's independent TTL behavior.

**Dependencies:** T05. **Scope:** Medium, 4 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `Sources/IsoHost/HostControl/OperationStore.swift`
- **E** `Sources/IsoHost/Lifecycle/AppleLifecycle.swift`
- **P** `tests/swift/IsoHostTests/HostControlLifecycleTests.swift`

**Acceptance criteria:**

- [ ] New start validates generation and policy, records the worker-computed finite remote deadline before boot, and returns a historical receipt with separate fresh observation.
- [ ] Running/stopped/unhealthy/unreachable remain distinct; a transport failure cannot trigger start or establish stopped state.
- [ ] Stop verifies native stopped state without guest cooperation; local no-TTL behavior and specified remote limits are preserved. Expiry denies workload access without blocking observation, receipts, exact cleanup, retained-artifact actions, or the separately qualified result-recovery path.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlLifecycleTests`; native remote create/start/inspect/stop with the client frontend disconnected during the boot lifetime. Record runtime-owner identity and actual TTL stop timing against the deadline +120-second bound.

### Checkpoint B — Real remote lifecycle slice

- [ ] T04–T06 work on the actual two-Mac fixture through the persistent supervisor, with native proof and exact cleanup.
- [ ] Record control RTT/setup overhead, accepted IDs, boot/deadline, and stopped evidence; no simulator result substitutes for this gate.

## Phase C — Recoverable native route

### T07 — Reconcile lost native replies without reallocating

Complete crash/lost-reply reconciliation around the native lifecycle journal, including destroy and retained tombstones.

**Dependencies:** T06. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/OperationStore.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **E** `Sources/IsoHost/Lifecycle/AppleLifecycle.swift`
- **P** `tests/swift/IsoHostTests/HostControlRecoveryTests.swift`
- **P** `tests/integration-remote-host.py`

**Acceptance criteria:**

- [ ] Disconnect/crash after acceptance and between native substeps reconciles the exact reserved runtime object; uncertainty never becomes an invented terminal result.
- [ ] Duplicate create/start survives changed generation, lifecycle state, and qualification; it creates no replacement identity and never extends the original deadline.
- [ ] Destroy verifies native absence and retains identity/receipt evidence; delayed create replay returns history while fresh inspection confirms the tombstone.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlRecoveryTests`; native dropped-reply and frontend-death cases for create/start/stop/destroy, followed by same-ID retries and authoritative runtime inventory. Deliberately bypass dedup/reconciliation guards and require failures.

### T08 — Issue volatile access bound to client bearer and daemon epoch

Implement live access admission independently from durable mutation receipts, including safe reply-loss recovery and bounded SessionID retirement.

**Dependencies:** T07. **Scope:** Medium, 4 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/AccessSessions.swift`
- **P** `Sources/IsoHost/HostControl/HostProtocol.swift`
- **P** `Sources/IsoHost/Guest/ClientSessionCoordinator.swift`
- **P** `tests/swift/IsoHostTests/HostControlAccessTests.swift`

**Acceptance criteria:**

- [ ] The client generates at least 256 bits of bearer entropy and retains it in an owner-only ephemeral descriptor; the worker retains only a verification hash and public binding data, never a replayable durable grant.
- [ ] Open/renew/close and relay admission require expected daemon epoch and matching host/owner/instance/boot/policy/key/purpose; lost open reply can recover only the same still-live grant with the original client bearer.
- [ ] Expired/closed SessionIDs are never evicted and reused within an epoch; at 65,536 issued IDs, new admission fails while renewal/revocation remains available, and stale-epoch delayed open cannot create a replacement session.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlAccessTests`; test delayed open after expiry, close, registry saturation, and epoch restart, plus wrong bearer/key/boot/policy and storage/log scans using synthetic secrets.

### T09 — Carry a pinned guest stream through the owned relay

Build the revocable byte relay and close Q1 with a real native-proof-to-guest file round trip before broad workflow integration.

**Dependencies:** T08. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/GuestRelay.swift`
- **P** `Sources/IsoHost/HostControl/AccessSessions.swift`
- **P** `Sources/IsoCLI/Commands/HostAgentCommands.swift`
- **P** `tests/swift/IsoHostTests/HostControlRelayTests.swift`
- **P** `tests/integration-remote-host.py`

**Acceptance criteria:**

- [ ] The authenticated relay preamble selects an existing live grant; the endpoint comes from current native proof, while client guest SSH verifies its distinct pinned guest key end to end.
- [ ] Expiry/revocation closes existing streams within the qualified two-second observation budget; queue/session/installation limits apply without disabling cleanup, and removing a guest key alone is demonstrated insufficient.
- [ ] The real remote native fixture completes a sentinel copy/pull through the relay, then stop/destroy verifies owned runtime cleanup; no workload credential is needed for this bootstrap qualification.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlRelayTests`; actual stalled/active streams, wrong destination attempts, client/daemon loss, backpressure, key-removal control, and relay-close observation in the Mac fixture. Measure warm p50/p95 and SSH setup overhead/RTT.

### Checkpoint C — Q1 decision

- [ ] T07–T09 establish native lost-reply recovery, fresh proof, end-to-end guest pinning, owned relay closure, file round trip, and exact cleanup.
- [ ] A failure in persistent ownership or enforceable routing stops broader remote UX work until the deployment/design is corrected; remote agent readiness is still unavailable.

## Phase D — Selected-host inputs

### T10 — Decode host configuration in explicit client and worker realms

Add global execution settings and immutable execution snapshots while preserving the implicit local default.

**Dependencies:** T09. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoConfiguration/IsoConfig.swift`
- **E** `Sources/IsoConfiguration/ConfigDecoding.swift`
- **E** `Sources/IsoConfiguration/ConfigTemplate.swift`
- **P** `Sources/IsoConfiguration/ExecutionHostConfig.swift`
- **P** `tests/swift/IsoConfigurationTests/ExecutionHostConfigTests.swift`

**Acceptance criteria:**

- [ ] Existing configuration decodes to local; local cannot be redirected; host aliases and installed absolute entrypoint paths use validated types.
- [ ] Only global trusted configuration chooses hosts; project data cannot select a worker, a local secret, or an executable.
- [ ] Canonical worker execution snapshots include policy/resources/image/TTL but exclude client paths, command/vault references, grant bearers, and resolved credentials.

**Verification:** Proposed `swift test --force-resolved-versions --filter ExecutionHostConfigTests`, plus existing configuration fixtures and duplicate/limit preflight tests. Inject synthetic sensitive fields and require secret-free errors.

### T11 — Enroll a host and resolve immutable placement

Add the public host registry and resolve a selected host once per command, keeping identity separate from alias/config names.

**Dependencies:** T10. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoCLI/Commands/HostCommands.swift`
- **E** `Sources/IsoCLI/IsoCommand.swift`
- **E** `Sources/IsoHost/Support/CommandContext.swift`
- **P** `Sources/IsoHost/HostControl/HostRegistry.swift`
- **P** `tests/swift/IsoHostTests/HostSelectionTests.swift`

**Acceptance criteria:**

- [ ] Registration verifies management/application identities before saving enrollment, transferring no project/credential data; aliases for one installation resolve to one identity.
- [ ] Persisted instance placement wins over default changes; explicit mismatches and cross-host ambiguity return qualified errors/candidates with no fallback.
- [ ] Disabled hosts block new work but retain references for observation/cleanup, and selected-host cleanup never acquires implicit all-host scope.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostSelectionTests`; native enroll/inspect with changed identity and two aliases, plus defaults/disabled-host/name-ambiguity fixtures.

### T12 — Stage and verify owned image artifacts

Introduce the bounded artifact path used by image inputs and later result exports, without exposing a generic worker filesystem API.

**Dependencies:** T11. **Scope:** Medium, 4 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/ArtifactStore.swift`
- **P** `Sources/IsoHost/HostControl/HostProtocol.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `tests/swift/IsoHostTests/HostControlArtifactTests.swift`

**Acceptance criteria:**

- [ ] Handles bind owner, kind, size, digest, and expiry; bounded streaming and digest verification precede publication.
- [ ] Archive traversal, absolute members, unsafe links, duplicate/conflicting members, wrong kinds, excess size, and unowned handles are refused without writes outside staging.
- [ ] Incomplete unowned uploads expire after one hour; accepted operations retain their inputs, and cleanup cannot delete another operation's artifact.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlArtifactTests` with hostile archives, interrupted uploads, digest mismatch, wrong owner, and retention/admission limits.

### Checkpoint D — Explicit placement and input ownership

- [ ] T10–T12 preserve local defaults, verified enrollment, immutable target selection, and confined worker inputs.
- [ ] A configuration or malformed artifact cannot redirect execution or cause secret resolution; relevant configuration/host suites pass.

## Phase E — Selected-host lifecycle

### T13 — Build and resolve images on the selected worker

Connect setup/image preparation to host-owned artifact inputs and durable image operations.

**Dependencies:** T12. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Lifecycle/AppleSetup.swift`
- **E** `Sources/IsoHost/Runtime/RuntimeOperations.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `Sources/IsoHost/HostControl/OperationStore.swift`
- **P** `tests/swift/IsoHostTests/HostControlImageTests.swift`

**Acceptance criteria:**

- [ ] `image.ensure`/selected-host setup resolve worker binaries/storage and explicit staged input, with host/architecture/digest/manifest-scoped image identity.
- [ ] Accepted builds survive frontend loss, reconcile publication by digest/manifest, and retain existing build/verification deadlines independently of the control timeout.
- [ ] A copied client image record or client path cannot satisfy remote image existence; unsupported guest/image operations refuse before allocation.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlImageTests`; native worker image build/import/verification boot, lost frontend during build, and restart/reconcile with no duplicate published identity.

### T14 — Create or reuse one project on each selected host

Route project lifecycle through the resolved host client while keeping local workspace association outside worker lifecycle records.

**Dependencies:** T13. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Lifecycle/ProjectLifecycle.swift`
- **E** `Sources/IsoHost/Lifecycle/UpWorkflow.swift`
- **E** `Sources/IsoHost/Support/CommandContext.swift`
- **P** `Sources/IsoHost/HostControl/ClientBindings.swift`
- **P** `tests/swift/IsoHostTests/RemoteProjectWorkflowTests.swift`

**Acceptance criteria:**

- [ ] Project affinity includes host identity, permitting the same directory/repository and display name on local and remote hosts without cross-target reuse.
- [ ] Existing refs stay bound through default changes, retry, stop, destroy, and returned files; workers never receive client destination authority.
- [ ] Reuse/start decisions consume typed observations and compatibility checks; unreachable state cannot initiate recreation or restart.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteProjectWorkflowTests`; native local-plus-remote project coexistence with equal names and guest IPs, changed defaults, unreachable worker, and selected deletion.

### T15 — Expose truthful status and compatible machine output

Complete bounded read/status/log output and pure global capabilities for the new host boundary.

**Dependencies:** T14. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoCLI/Commands/ReadCommands.swift`
- **E** `Sources/IsoCLI/Commands/CapabilitiesCommand.swift`
- **E** `Sources/IsoCLI/Support/MachineResponses.swift`
- **E** `Sources/IsoCLI/Support/MachineErrors.swift`
- **P** `tests/swift/IsoCLITests/RemoteMachineTests.swift`

**Acceptance criteria:**

- [ ] Machine v1 keeps existing field meanings/types and backend identity; host/owner/instance/reachability metadata and typed errors are additive.
- [ ] All-host listing is bounded and reports per-host partial failures; unknown retains last observation metadata, and operation receipts are explicitly historical.
- [ ] Global `iso capabilities` reads no config/state/secrets and starts no service/network connection; explicit host inspection performs live qualification and bounded diagnostics never expose grants or credentials.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteMachineTests`; existing CLI/read/machine contract scripts, plus a fixture that fails on any capability-side effect and a partial-outage all-host listing.

### Checkpoint E — Selected-host lifecycle UX

- [ ] T13–T15 support worker image setup and same-project coexistence with correct status/retry identity and machine compatibility.
- [ ] Remote agent/editor capabilities remain refused until their readiness/session tasks complete; no intermediate release implies those gates passed.

## Phase F — Supervised sessions

### T16 — Derive every guest transport from one access descriptor

Make guest SSH routing a shared typed input rather than an optional jump-host flag added to individual commands.

**Dependencies:** T15. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Guest/SSH.swift`
- **E** `Sources/IsoHost/Guest/SSHConfig.swift`
- **E** `Sources/IsoHost/Guest/GuestSession.swift`
- **E** `Sources/IsoHost/Editor/SSHConnectionTarget.swift`
- **P** `tests/swift/IsoHostTests/RemoteGuestRouteTests.swift`

**Acceptance criteria:**

- [ ] SSH, SCP, rsync, tar, probes, reverse tunnels, and editor transport construction all consume the same verified route/pin identity.
- [ ] Alias/control-socket/key/connection equality includes host/instance/boot/session as appropriate; equal display names and private IPs cannot collide.
- [ ] Relay bearer data comes from a private descriptor and stdin preamble, not argv/config literals; management identity and guest pin remain separate.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteGuestRouteTests`; inspect every transport command and run representative real SSH/SCP/rsync/tar fallback through the Mac relay fixture with deliberate pin/identity mismatch.

### T17 — Keep client session ownership alive after CLI exit

Turn the initial client grant holder into the per-instance coordinator that owns renewals, process groups, ports, and private session material.

**Dependencies:** T16. **Scope:** Medium, 4 files.

**Likely files:**

- **P** `Sources/IsoHost/Guest/ClientSessionCoordinator.swift`
- **E** `Sources/IsoHost/Lifecycle/UpWorkflow.swift`
- **E** `Sources/IsoHost/Guest/TunnelIdentity.swift`
- **P** `tests/swift/IsoHostTests/ClientSessionCoordinatorTests.swift`

**Acceptance criteria:**

- [ ] A coordinator outlives normal CLI exit, renews every 10 seconds against a 30-second live lease, and is reused only for matching host/instance/boot/policy.
- [ ] One controlling client owns a boot; a second cannot silently replace it, while multiple local commands can share its valid coordinator.
- [ ] Stop, destroy, epoch change, dependency failure, and client loss clean local private files/process groups/ports; remote uncertainty stays explicit while local credential/tunnel cleanup completes.

**Verification:** Proposed `swift test --force-resolved-versions --filter ClientSessionCoordinatorTests`; real CLI exit/reuse, competing coordinator, abrupt coordinator death, sleep longer than lease, daemon restart, and orphan-resource inspection.

### T18 — Compose client broker and worker egress readiness

Enable the client-broker security path only after both execution realms and the actual guest path contribute verified readiness.

**Dependencies:** T17. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Guest/ProxyLifecycle.swift`
- **E** `Sources/IsoHost/Runtime/BrokerReadiness.swift`
- **E** `Sources/IsoHost/Runtime/EgressLease.swift`
- **P** `Sources/IsoHost/Guest/ClientSessionCoordinator.swift`
- **P** `tests/swift/IsoHostTests/RemoteBrokerReadinessTests.swift`

**Acceptance criteria:**

- [ ] Provider credentials resolve only on the client into the confined broker; worker disk/config/image/wire records receive no raw provider value.
- [ ] Fresh signed guest-path broker evidence composes with worker-native owner/boot/policy/egress proof; no remote PID is treated as evidence of a client process.
- [ ] Broker, tunnel, coordinator, or local egress failure refuses new handoffs and revokes dependent streams without fallback; the worker's one-second/two-second local egress timing remains local.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteBrokerReadinessTests`; controlled upstream/broker fixtures and real Mac tunnel/egress failure. Require actual relay closure and negative provider/direct-egress attempts, plus synthetic-secret scans of prohibited surfaces.

### Checkpoint F — Core Q2 session policy

- [ ] T16–T18 prove a common route, bounded coordinator ownership, fresh composite readiness, and observed failure revocation.
- [ ] No agent/editor workload can pass readiness on a stale boot/epoch or missing broker; measured lease/relay behavior is recorded.

## Phase G — Files and agents

### T19 — Transfer client workspaces through the selected guest route

Preserve copy, one-time mount sync, and guest Git-clone semantics while making each source realm explicit.

**Dependencies:** T18. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Workspace/Workspace.swift`
- **E** `Sources/IsoHost/Workspace/ProjectDirectory.swift`
- **E** `Sources/IsoHost/Guest/GuestSession.swift`
- **P** `Sources/IsoHost/HostControl/ClientBindings.swift`
- **P** `tests/swift/IsoHostTests/RemoteWorkspaceTransferTests.swift`

**Acceptance criteria:**

- [ ] Client source directories and exclusions remain client-owned; copy/mount synchronization and guest Git sources retain existing behavior through the verified route.
- [ ] Host/instance-qualified bindings distinguish the same project on several hosts and cannot be replaced by worker-returned paths.
- [ ] Interrupted or hostile transfers remain bounded, do not escape client/guest destinations, and never activate automatic bidirectional synchronization.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteWorkspaceTransferTests`, existing workspace tests, and actual copy/rsync/tar fallback/Git fixture cases through the remote route, including an interrupted transfer.

### T20 — Review completed stages safely while the worker is offline

Extend staged-return identity without tying completed client data to worker VM lifetime.

**Dependencies:** T19. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Workspace/WorkspaceStage.swift`
- **E** `Sources/IsoHost/Workspace/WorkspaceStageApply.swift`
- **E** `Sources/IsoHost/Workspace/WorkspaceStageReview.swift`
- **P** `Sources/IsoHost/HostControl/ClientBindings.swift`
- **P** `tests/swift/IsoHostTests/RemoteWorkspaceStageTests.swift`

**Acceptance criteria:**

- [ ] A stage binds client workspace, full instance identity, observed boot/policy, manifests, and completion independently of display-name or VM lifetime.
- [ ] Completion is fsynced only after all content/manifest checks; hostile paths, partial downloads, and destination drift cannot cause an automatic apply.
- [ ] A completed stage remains reviewable/applicable offline after remote destroy, and a replacement VM/name cannot reassign or erase it.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteWorkspaceStageTests`, existing stage suites, and a real staged download followed by worker disconnection/destroy plus local destination drift.

### T21 — Launch interactive agents through the verified remote session

Route Claude/Codex preparation and launch through the established project and composite-readiness path.

**Dependencies:** T20. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoCLI/Commands/AgentCommands.swift`
- **E** `Sources/IsoHost/Guest/AgentLaunchPlan.swift`
- **E** `Sources/IsoHost/Guest/GuestSession.swift`
- **E** `Sources/IsoHost/Guest/Bootstrap.swift`
- **P** `tests/swift/IsoHostTests/RemoteAgentTests.swift`

**Acceptance criteria:**

- [ ] Supported interactive agents use the selected qualified project/session and preserve existing explicit guest credential policies and lazy client secret resolution.
- [ ] Boot/policy/epoch/broker loss invalidates prepared agent handoff and prevents new workload launch; reconnect requires fresh observation and session.
- [ ] Detached operation and unsupported remote guest/maintenance capabilities refuse before image work, allocation, or secret resolution.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteAgentTests`; controlled-upstream remote agent setup/tool-use fixtures and session loss. Use live-provider credentials only under the repository's separately authorized live-test procedure.

### Checkpoint G — Workspace and interactive workflows

- [ ] T19–T21 preserve transfer/stage safety and demonstrate remote interactive agent behavior under qualified policy.
- [ ] Completed stages survive remote failure; all supported transfer fallbacks use the same identity; detach remains unsupported.

## Phase H — Editor and disposable completion

### T22 — Preserve editor confinement through the remote route

Adapt the existing code/zed editor path to the coordinator-owned outer tunnel without exposing management credentials or a general agent socket.

**Dependencies:** T21. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Editor/SandboxedEditorSession.swift`
- **E** `Sources/IsoHost/Editor/SSHConnectionTarget.swift`
- **E** `Sources/IsoHost/Editor/EditorLauncher.swift`
- **E** `Sources/IsoHost/Editor/ProjectEditorWorkflow.swift`
- **P** `tests/swift/IsoHostTests/RemoteEditorTests.swift`

**Acceptance criteria:**

- [ ] The editor receives a loopback endpoint and its own guest session key; the outer transport remains outside the enclave.
- [ ] No management identity, grant bearer, master guest key, or general agent socket becomes available inside the editor enclave.
- [ ] Proof/relay loss terminates the supervised editor process tree and cleans the enclave; a stale session cannot reconnect silently.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteEditorTests`, existing editor sandbox/launcher tests, and native code/zed connection plus relay-loss/process-tree cleanup observations.

### T23 — Scope forwards and local-model tunnels to the live coordinator

Finish application-port and client-local model routing with host-qualified identity and explicit local intent.

**Dependencies:** T22. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Guest/PortForwards.swift`
- **E** `Sources/IsoHost/Guest/ProxyLifecycle.swift`
- **E** `Sources/IsoHost/Guest/SSHConfig.swift`
- **P** `Sources/IsoHost/Guest/ClientSessionCoordinator.swift`
- **P** `tests/swift/IsoHostTests/RemoteForwardTests.swift`

**Acceptance criteria:**

- [ ] Application listeners bind client loopback by default; ports/sockets/process identity distinguish host/instance/session instead of relying on a host-local instance index.
- [ ] Requested forward specs persist only as client intent; active resources require the matching live coordinator and explicit client-versus-worker endpoint realm.
- [ ] Session expiry/revocation and stop/destroy close existing forwards, while admission-limit failure leaves other sessions and cleanup functional.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteForwardTests`; two-host equal-name/IP forwarding, client-local model endpoint, lease loss, collision, and saturation cases on the native fixture.

### T24 — Own disposable runs and export normal results before stop

Create a worker-owned RunID and recovery record before allocation, then implement the successful attached-run completion path.

**Dependencies:** T23. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `Sources/IsoHost/Lifecycle/RunSession.swift`
- **E** `Sources/IsoHost/Lifecycle/RunWorkflow.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `Sources/IsoHost/HostControl/HostRunStore.swift`
- **P** `tests/swift/IsoHostTests/RemoteRunOwnershipTests.swift`

**Acceptance criteria:**

- [ ] Run admission reserves exact create/instance identity, cleanup ownership/capacity, storage budget, and one of four result-retention slots before VM creation; hold that slot across active/recovery/pending states until cleanup, limiting default disposable concurrency to four.
- [ ] Normal completion collects bounded results into an owned artifact before stopping, then records `results_pending` only for a complete artifact plus verified stop; preempted/failed export records `stopped_disk_pending_export` without relying on a client exit handler.
- [ ] Acknowledgment binds RunID, digest, completed client StageID, and transfer completion; only then may exact destroy occur, and worker deletion never removes the completed client stage.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteRunOwnershipTests`; native short attached run with output, client loss during export/acknowledgment, same-ID recovery, and ordinary ledger-capacity exhaustion during finalization.

### Checkpoint H — Complete normal editor/run path

- [ ] T22–T24 preserve local confinement/forward ownership and demonstrate normal disposable output collection before native stop.
- [ ] Result acknowledgment is content/identity-bound and cleanup still succeeds at ordinary capacity limits; no detached job promise is made.

## Phase I — Recovery and local activation

### T25 — Recover stopped-run results within fixed retention

Handle lease-loss and already-stopped result sources with restricted recovery, bounded retention, and exact resource cleanup.

**Dependencies:** T24. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/HostRunStore.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `Sources/IsoHost/HostControl/ArtifactStore.swift`
- **E** `Sources/IsoHost/Lifecycle/RunSession.swift`
- **P** `tests/swift/IsoHostTests/RemoteRunRecoveryTests.swift`

**Acceptance criteria:**

- [ ] Controller loss triggers worker-owned stop and accurately distinguishes `results_pending` from `stopped_disk_pending_export`; the next client discovers the existing RunID rather than creating a replacement run.
- [ ] Each RunID permits at most one explicitly requested bounded, restricted recovery boot, with allowance consumption, child operation IDs, deadline, and fresh proof persisted before start; retry cannot buy another boot, resume agents, resolve provider secrets, or relax egress.
- [ ] One-hour retention from first verified stop never moves; active/recovering/pending runs keep their pre-reserved slots until verified cleanup, so simultaneous completions cannot overflow retention capacity. Acknowledgment/discard/expiry preserve completed client stages, and expiry stops any recovery boot.

**Verification:** Proposed `swift test --force-resolved-versions --filter RemoteRunRecoveryTests`; native client disappearance, stopped-source recovery, recovery failure/TTL, partial download, expiry while recovering, and full-ledger/pending-result limits. Record any unavailable output rather than declaring it recovered.

### T26 — Preserve the full local capability set through the service

Complete the local-only host-service routes before migration can switch a legacy installation to the supervisor.

**Dependencies:** T15; T12's artifact channel. May proceed alongside T19–T25 once shared files have an owner. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/HostControl.swift`
- **P** `Sources/IsoHost/HostControl/HostProtocol.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `Sources/IsoHost/HostControl/LocalNativeCapabilities.swift`
- **P** `tests/swift/IsoHostTests/HostControlLocalCapabilitiesTests.swift`

**Acceptance criteria:**

- [ ] Local resize, image commit, restore, existing macOS image/setup/lifecycle, and the baseline's supported macOS computer-use read/input actions have complete typed service dispatch using native implementations.
- [ ] Native checks, bounded artifact/frame handling, exact identity, and operation reconciliation retain existing local behavior; no command bypasses the supervisor merely because it was deferred remotely.
- [ ] Remote versions of these deferred capabilities return typed refusal before images/resources/secrets are touched, and capability advertisements match actual dispatch coverage.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlLocalCapabilitiesTests`, existing lifecycle/Mac gate suites, and baseline local maintenance/macOS qualification cases through the new service. Treat every missing dispatch as an activation blocker.

### T27 — Activate legacy local state through a prepared service handoff

Implement the stopped-boundary metadata migration with a single activation owner and explicit rollback state.

**Dependencies:** T26 and T07. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/HostMigration.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **E** `Sources/IsoHost/State/StateStore.swift`
- **P** `Sources/IsoCLI/Commands/HostCommands.swift`
- **P** `tests/swift/IsoHostTests/HostControlMigrationTests.swift`

**Acceptance criteria:**

- [ ] Preview preserves old records/runtime paths and allows legacy inspection/exact cleanup; running VMs, pending native journals, unknown mutation state, or old writers defer/refuse activation without stopping VMs.
- [ ] The command creates the specified prepared handoff under ordered locks, releases its ownership before startup, and only the new service reacquires exclusive ownership to finish validation/fencing/activation; no CLI/service lock cycle or second writer is possible.
- [ ] Crash at each prepare/activate boundary has a recorded recovery/rollback disposition; new mutations remain blocked until activation commits, and post-activation downgrade is not an automatic metadata rewind.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlMigrationTests`, existing data-root tests, and native running/stopped legacy fixtures with an old writer, pending journal, activation crash, and service-start failure. Re-run preserved local capabilities after activation.

### Checkpoint I — Q3 and bounded run recovery

- [ ] T25–T27 demonstrate recoverable/discardable stopped results, preserved complete local capability dispatch, and service-owned activation without automatic VM interruption.
- [ ] Legacy writer fencing, ordered lock handoff, rollback boundaries, local macOS behavior, and completed-stage survival have explicit evidence.

## Phase J — Final lifecycle and release gates

### T28 — Cancel only before native effects begin

Add the narrow cancellation contract without inventing an independent cancellation ledger that can race the target operation.

**Dependencies:** T07. May be implemented earlier after ledger/recovery stabilizes. **Scope:** Medium, 5 files.

**Likely files:**

- **P** `Sources/IsoHost/HostControl/OperationStore.swift`
- **P** `Sources/IsoHost/HostControl/HostSupervisor.swift`
- **P** `Sources/IsoHost/HostControl/HostProtocol.swift`
- **P** `tests/swift/IsoHostTests/HostControlCancellationTests.swift`
- **E** `scripts/swift-host-fault-injection.py`

**Acceptance criteria:**

- [ ] Cancellation records an idempotent intent on the target operation under its lock and is accepted only while native side effects have not started.
- [ ] Repeated/lost-reply cancellation returns the same target disposition; a late request is refused without relabeling running, uncertain, or completed effects as cancelled.
- [ ] Frontend disconnect remains unrelated to cancellation, and cancellation/admission races preserve reserved cleanup capacity and known resource disposition.

**Verification:** Proposed `swift test --force-resolved-versions --filter HostControlCancellationTests`; force both sides of the first-effect boundary, retry cancellation after reply loss/restart, and disable the safe-point guard in a controlled mutation to require failure.

### T29 — Synchronize public examples, machine meaning, and trust documentation

Publish the implemented behavior and its explicit limits in the repository's existing system of record.

**Dependencies:** T25, T27, T28, with T21–T23 complete. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `config.example.jsonc`
- **E** `docs/ARCHITECTURE.md`
- **E** `docs/trust-model.md`
- **E** `docs/machine-interface.md`
- **E** `docs/testing.md`

**Acceptance criteria:**

- [ ] Examples/defaults match the implemented config template, supported commands, capability refusals, TTL/lease/retention values, and migration states.
- [ ] Trust documentation explains client secret ownership, worker enforcement, hash-only grants/epoch retirement, actual relay revocation, historical receipts, safe cancellation, and restricted result recovery.
- [ ] Test documentation separates Q0 evidence from Q1–Q4 native requirements and names actual available test commands; machine v1 compatibility and pure capabilities remain explicit.

**Verification:** Run existing config/CLI/read/lifecycle/data-root/machine contract scripts against the candidate binary and search all edited contract representations for stale command names or conflicting limits. Documentation changes require consistency review, not redundant implementation-mirroring tests.

### T30 — Wire the release gates and record complete native qualification

Connect the focused tests and real-Mac matrix to the repository's gates, then record the actual release evidence and remaining unsupported capabilities.

**Dependencies:** T01–T29. **Scope:** Medium, 5 files.

**Likely files:**

- **E** `.github/workflows/ci.yml`
- **E** `mise.toml`
- **P** `tests/integration-remote-host.py`
- **E** `scripts/swift-host-fault-injection.py`
- **E** `docs/release-validation.md`

**Acceptance criteria:**

- [ ] Required CI/package/contract gates are actually present and run; every new security-relevant refusal has a detected fault/mutation, with source/tool hashes and unresolved outcomes recorded.
- [ ] Q2–Q4 native cases cover relay/broker failure, offline-client TTL with hostile guest, ledger/session/result limits, retry/cancellation/migration races, legacy local Linux/macOS compatibility, and SSH-only/builder/logout/sleep/reboot behavior.
- [ ] The release record reports observed timings, p50/p95/RTT, exact cleanup, passed/failed/not-run cases, and unsupported features; any missing mandatory gate blocks the corresponding release claim and is sent back to its owning task.

**Verification:** Run the applicable existing commands in [plan.md](plan.md), the implemented remote integration runner, the full A01–A34 acceptance matrix in the specification, and the repository's final review workflow on the candidate revision. A green simulator or skipped native case cannot satisfy this task.

### Checkpoint J — Release decision

- [ ] T28–T30 complete; all Q1–Q4 mandatory evidence is present and consistent with actual support.
- [ ] No unresolved owned VM, orphan relay/coordinator, stale migration, unsupported capability advertised as ready, or untested safety claim remains.
- [ ] Apply the repository's required pre-merge security review to the concrete implementation and evidence; this checklist does not claim a merge or deployment was performed.
