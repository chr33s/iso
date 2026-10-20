# iso-ci — Implementation Specification

**Document ID:** ISO-CI  
**Date:** 19 October 2026  
**Status:** Implementation contract, implemented in `iso-ci/` ([Implementation status](#implementation-status)). Status and evidence live in the [qualification record](iso-ci-qualification.md); release qualification of a signed, tagged build has not been recorded.  
**Product:** A separately installable Swift companion to iso, initially maintained in the iso repository.  
**Target execution:** Qualified Linux ARM64 guests on local or explicitly enrolled Apple-silicon Macs.

## 1. Product contract and scope

Build `iso-ci` as a Swift-native companion that supplies isolated GitHub Actions execution without taking ownership of iso's VM runtime or host service.

| Mode | Job authority | Behavior |
|---|---|---|
| **GitHub-connected** | GitHub | Supply fresh, single-use official runners. GitHub owns workflow orchestration, job assignment, checks, and normal Actions caches and artifacts. |
| **Local preflight** | iso-ci | Compile a declared workflow subset, deliver jobs to the official runner through local compatibility services, test an immutable working-tree snapshot, and provide inspection, patching, retention, and fresh replay. |

Both modes require the brokered execution foundation defined in section 2. Use one clean VM per job attempt and a guest-local Docker daemon for qualified job containers, services, and container actions. Local preflight has no runner-registration or GitHub App requirement. Optional repository fetching and workflow secrets require explicit authorization.

Support repository and organization onboarding, bounded ready capacity, multi-host placement, operational logs and results, immutable trust-scoped local caches, draining and offboarding, public-trigger qualification, and separation of validation from privileged release authority.

Ordinary pinned SSH over Tailscale may connect enrolled management hosts. Tailscale is not required for a local pool, and job VMs do not join the tailnet. Never discover arbitrary tailnet nodes and authorize them as workers automatically. Never register, reuse, or modify a developer VM as CI capacity.

### Scope boundaries

The execution target is Linux ARM64. macOS/Xcode and Windows executors, implicit architecture translation, cloud backends, Docker-free Actions hooks, and a dynamic plugin system are outside scope.

Local preflight supports only its published compatibility manifest. Arbitrary workflow parity, unqualified reusable workflows or dynamic matrices, transparent failed-step continuation, and genuine GitHub-issued OIDC or environment-approval authority are outside scope. Fresh whole-job replay is included.

Privileged release execution stays disabled unless its admission and credential controls are qualified. Demand-based scale-to-zero, webhooks, and runner scale sets are not required for the ready-pool implementation. No exactly-once external side effects or transparent migration of an active job is promised.

The companion is complete only when both execution modes, the included fleet operations, and the applicable acceptance tests are delivered. A connected-runner milestone alone is not completion of local preflight.

## 2. Brokered execution prerequisite

CI execution depends on a qualified iso network and execution foundation. This section states the complete handoff required by the companion; it does not assign network implementation to CI.

The host must advertise the supported **`NET-HANDOFF-1`** capability and supply all of the following:

| Required capability | Admission and execution requirement |
|---|---|
| **No external network interface (NIC)** | Effective VM configuration has no externally connected network interface from first boot, including bootstrap, restart, and any permitted restore path. Guest-local Docker interfaces do not provide an external uplink. |
| **VM-bound management** | Local and remote access uses authenticated SSH streams over a VM-bound private transport. Stream identity is bound to host, owner, VM, boot, policy, and current access authorization. |
| **Current isolation proof** | The host validates the effective configuration and broker readiness at access handoff and enforces revalidation and revocation. A cached onboarding check is insufficient. |
| **Approved communications** | Public egress and any local-service channel are explicit, administrator-approved capabilities. CI can request a profile with no provider, developer-local-service, or private-network grants. |
| **Independent limits** | Host-owned leases, hard deadlines, resource admission, and a stop path remain effective when the controller disconnects or guest root refuses to cooperate. |
| **Safe transport and results** | Workspace transfer, diagnostics, archives, and results are bounded and validated. No guest-supplied path becomes arbitrary host filesystem access. |
| **Negotiated client access** | Capability discovery and the supported host-client subset expose clean allocation, current observations, access, cancellation, results, and verified release. Unsupported requests fail explicitly. |
| **Qualification evidence** | An evidence manifest identifies the exact host OS, iso/runtime, guest kernel, image, broker, transport, and relevant tool combinations that passed the required tests. |

The evidence must cover NIC-less boot, host-service and guest-to-guest isolation, hostile guest-root behavior, bounded private-channel access, stale-identity rejection, broker destination enforcement, stream/output abuse, forced stop, and the claimed local/remote failure paths. It must include the qualified guest-Docker/proxy combinations used by the selected runner profile. Evidence for the supported network foundation must be complete before CI is admitted.

CI consumes the host's authenticated admission handle and qualification references. It does not independently implement network proof signing, packet filtering, private-transport enforcement, or physical VM state. Store the evidence references with each allocation, and test the runner/Docker/API composition introduced by CI.

**Fail closed:** missing capability, expired proof, incompatible profile, unavailable required broker, or unqualified worker prevents allocation or use. During execution, loss of enforcement invokes host revocation and the configured CI stop policy. There is no fallback to vmnet, an external NIC, unrestricted host access, or developer credentials, regardless of repository visibility.

Network qualification is a prerequisite, not a CI work item. Compiler and client unit tests may run against fixtures before that prerequisite is available; fixture success does not qualify real CI execution.

## 3. Implementation architecture

Use one companion package, one executable, and one durable controller per operator data root. A later optional `iso ci` command may delegate to the explicitly installed companion. Use an executable target plus one library target, organized into `Execution`, `GitHub`, `Preflight`, and `Storage` folders. These are code boundaries, not mandatory packages or independent services. Base iso must not require the companion or GitHub credentials.

The CLI talks to the controller through a private, same-user control channel. `serve` may run in the foreground or through an explicitly installed user service. The controller, rather than an attached terminal, holds active workload leases. Do not add a worker daemon, VM runtime, host registry, generic plugin system, or distributed scheduler.

```text
CLI ── private operator control ── Controller
                                   ├── GitHub pool reconciler
                                   ├── Preflight graph/session manager
                                   └── Thin iso client
                                             │
                                  Existing iso host service
                                             │
                               Brokered iso VM + SSH
                                             │
                                 Official runner + Docker
```

Only local preflight needs a guest-facing Actions API. Serve its runner, action-delivery, cache, artifact, and log routes through one scoped data-plane endpoint rather than separate services. Keep route-specific protocols and authorization intact. When the controller holds App/host credentials, run this endpoint in a confined child invocation of the same executable with only its scoped input/staging paths and bounded message channel. This is not another daemon or plugin boundary. A separate process without OS confinement or credential restrictions does not establish this separation.

The guest-facing endpoint cannot call arbitrary host operations, open controller administration routes, or request credentials. Controller-side validation remains required even for messages from that child.

The single preflight endpoint combines protocol routes; it does not grant access to every active run. Authorize each request by its allocation and explicitly shared immutable objects. The confined child receives no inherited App keys, host-management credentials, arbitrary filesystem access, or administrative file descriptors. Its controller channel accepts only bounded, validated data-plane messages. Failure to establish the required confinement prevents preflight service admission.

## 4. Supported iso client contract

Formalize the minimum client-supported subset of iso's host protocol and the brokered handoff in section 2. Use the host protocol's own version negotiation for incompatible extensions. Do not add a parallel execution service or wire protocol that merely renames host operations, and do not send unsupported fields to strict decoders.

| Client need | Reuse or narrowly extend |
|---|---|
| Discovery/admission | Host identities, approved image/policy references, qualification and budget capabilities |
| Acquire clean VM | Existing durable run creation with a pre-persisted operation identity |
| Access/bootstrap/execute | Existing access leases, VM-bound SSH streams and bounded transport |
| Observe/cancel | Host observations, operation receipts, cancellation and stop |
| Results/retention/release | Existing staging, digest-bound results, expiry and verified cleanup; explicit retention extension where needed |

These operations already have foundations in the baseline host code; they are not all proven external APIs today.[^host]

The host service owns effective configuration checks, live boot proof, hard deadlines, physical admission, and cleanup. CI requires and correlates an authenticated, current admitted handle and its qualified policy; it does not reimplement NIC inspection, subnet rules, proof signing, or physical lifecycle state. Store the immutable proof/provenance reference plus observations, not a second authoritative resource record. No cached setup check substitutes for the host's live handoff validation.

**Required integration work:** supported external client access; controller-held sessions; creation without a developer workspace; bounded logs/results; opt-in live retention and narrowed grants. The baseline `iso host run` is attached and pushes its selected directory, so invoking it unchanged is not the complete adapter.[^run]

Retention must be host-owned. If current `run.complete` always exports/stops, add a workload-neutral, versioned finalize/retention capability rather than circumventing the host lifecycle. Live and stopped-state retention are required capabilities and must pass their release gates. Preserve remote-operation restrictions; do not use locally available image mutation APIs to bypass them.

## 5. State ownership and host placement

Use one transactional controller database with bounded event cursors and a filesystem object store. This database correlates work; the host ledger continues to own actual resources. One controller ownership lock prevents concurrent writers for a data root.

Persist three logical record families; storage tables may normalize these records as needed:

| Record | Minimum purpose |
|---|---|
| Profile/pool | Approved image/network/compatibility references, eligible enrolled hosts, scope, capacity and lifetime policy |
| Allocation | One owned environment request, host operation/VM/boot references, runner registration when applicable, immutable input provenance, desired disposition and observed outcomes |
| Preflight run/job | Workflow graph, matrix identity, dependency outputs, snapshot and attempt links; absent from connected scheduling |

A ready GitHub runner has an **allocation**, not yet a known GitHub job. Bind its assigned repository/run/attempt/job identity later using GitHub observations. Guest log hints are not authoritative. Preflight job attempts reference allocations explicitly.

Keep host/owner/instance identity, boot/generation, operation IDs, lease observations and deadline in the referenced allocation record. Store immutable image, actual runner version, network policy, qualification, platform, source/workflow/action digests and resource limits. Keep execution result, result-export result, VM/storage cleanup, and registration cleanup independent. UI phases are derived from those observations, not a second VM state machine. Unknown is not failed, stopped, or reusable.

Placement is a deterministic filter-and-select operation across enrolled hosts: require qualification, profile, authority and budgets; prefer existing approved image/cache locality where observable; then use stable fair ordering. The host atomically admits resources. Provisional/uncertain allocations count until resolved. No cross-host consensus, work stealing, migration, cache replication service, or connected-job DAG is required.

For connected allocations, record GitHub scope and assigned job provenance only when available; an idle allocation has no fabricated job identity. For preflight, preserve the base commit and selected working-tree snapshot separately. Store no secret values in these records or event payloads.

## 6. Runner images and execution profiles

A `RunnerProfile` is a versioned descriptor referencing an approved immutable image, qualified brokered network profile, resource/lifetime bounds and a compatibility manifest. It bundles configuration; it does not merge their authorities or hide provenance. Pools supply GitHub scope/labels or preflight input, not replacement policy.

Images contain the official Linux ARM64 runner, essential tools, the SSH adapter and qualified guest-local Docker/proxy setup. Never bake in runner registration, project state, mutable job caches, developer environments, App material, or provider credentials. Pin expected versions and record actual versions; reject/drain unexpected ones under the update policy.

Use iso's qualified brokers for all egress enforcement. CI contributes a reviewed GitHub/package endpoint profile and compatibility tests. Resolve GitHub's wildcard/CNAME requirements explicitly against the broker schema; do not auto-allow guest-requested hosts. Configure runner, Docker daemon, containers/builds and supported tools separately.[^proxy][^docker]

Local preflight additionally requests one exact service endpoint, with per-allocation credentials and object/method limits. No generic controller-port grant. Cross-job artifacts and caches are available only through explicit authorized immutable references, never through another job's delivery/control namespace.

CI profiles default to no provider, developer-local-service, or private-network grants. A preflight endpoint is a separately scoped capability, not access to controller administration. No fallback to a NIC, arbitrary private destinations, provider keys, developer tokens, or unqualified images is allowed. Unsupported combinations fail explicitly.

A compatibility descriptor is mode-specific: connected execution qualifies the runner image, tools, Docker integration, and communication paths; it does not apply the local workflow compiler's syntax restrictions to GitHub jobs. Preflight additionally qualifies the local compiler, action versions, and runner-compatible protocol surface. Neither mode claims software-image parity with every GitHub-hosted runner.

## 7. GitHub-connected pools

GitHub owns its workflow graph, eligible-job queue, actual assignment, checks and standard cache/artifact semantics. The companion manages ready **capacity**, not another GitHub scheduler. Registration does not bind a runner to a chosen job.[^jit]

Each reconciliation pass:

1. Refresh owned host operations, leases, registrations and relevant GitHub job observations; resolve previous uncertainty before adding work.
2. Process stop/expiry/revocation/retention/cleanup and persist each intended external operation before sending it.
3. Compute the idle deficit and available resource budgets. Starting allocations reserve future idle slots; retained and uncertain resources still consume their applicable budgets.
4. Create only the admitted deficit, after fair placement; verify brokered readiness; obtain JIT material; launch the runner and verify scope, labels and connection.

Default to one ready runner when capacity permits, within an explicit live-VM cap. Zero desired idle without a demand source means a paused/non-replenishing pool, not working scale-to-zero. Webhooks, scale sets and demand-based zero-idle operation are outside the ready-pool implementation.

Allocate the VM and prove its profile **before** releasing bootstrap material. Persist the chosen runner name, controller identity and allocation correlation before the JIT request. JIT creation is not assumed idempotent: if its response is lost, reconcile the exact owned registration in the correct scope before retrying. If ownership cannot be resolved, retain an explicit registration-uncertain state and require supervised resolution instead of guessing. Do not delete runners based only on a shared name prefix. Keep App keys and installation-management tokens out of worker request payloads and guests (a controller may physically share the local Mac); JIT material is guest-visible and excluded from host argv, templates and logs.

GitHub job/run APIs may be polled for correlation and status with bounded backoff/pagination, not for local scheduling. Preserve a GitHub result link and bounded operational diagnostics; do not mirror all GitHub logs or artifacts to implement the UI. Job metadata APIs expose runner identifiers useful for correlation.[^jobs]

Retire idle runners early enough to leave the configured job allowance before the VM hard deadline. Assignment/removal races can still happen: report interrupted work honestly and never extend a hard deadline indefinitely. Once an assigned runner ends, never feed another job into that VM. Forward bounded diagnostics during execution where possible; post-exit export alone cannot guarantee logs survive a crash. GitHub deregistration never substitutes for iso cleanup.[^runners]

A successful official-runner process exit is not necessarily a successful workflow job. Keep runner-process health and GitHub's job conclusion distinct. Observe the actual conclusion through GitHub; leave it unknown while the authoritative API cannot confirm it. Replacing capacity is not authorization to replay an uncertain side-effecting job.

## 8. Onboarding, operation, and offboarding

`iso-ci setup` is an idempotent frontend to the same profile/pool store used by explicit CLI configuration. It does not create a second setup engine.

| Step | Required result |
|---|---|
| Select host/profile | Existing local/enrolled host; qualified brokered handoff from section 2; clean image, budgets, proxy compatibility and cleanup verified |
| Connect App | Create via manifest or connect an operator-owned App; complete installation separately; validate callback state and installation scope |
| Approve authority | Explain GitHub permissions, eligible repositories/groups, workflow-policy limitations and deliberate job capabilities |
| Enable service | Explicit foreground/service choice; protected credential access works unattended or pool stays inactive |
| Smoke test | Generate workflow for review, never commit/push automatically; two runs use different clean VMs/registrations |
| Validate availability | Expose sleep, restart, login/unlock, OS permission and secure-store limitations |

Repository JIT management needs Administration write; organization management needs Self-hosted runners write. Request Actions read for selected observation APIs, not Actions write merely for provisioning. Keep App setup, installation and token refresh in one credential component; no PAT/`gh` fallback. Support App creation through the manifest flow.[^app][^jit][^jobs]

Workflows opt in with `runs-on: [self-hosted, linux, ARM64, iso-ci]`, with an explicit group where applicable. Actual labels must be verified. Existing developer VMs and unrelated host settings remain untouched except operator-approved CI-only configuration/service writes.

Adding hosts uses iso enrollment; it is not a new onboarding protocol. Disable/pause stops replenishment. Drain waits for assigned work; explicit abort stops it. Handle assignment/removal races. Offboarding removes only owned registrations/resources, verifies or records pending cleanup, and removes CI-only credentials when requested. It must not remove iso enrollment, unrelated VMs, other controllers' runners, or unrelated App installations.

### Smoke workflow

Generate this workflow for operator review. The labels must match the actual pool registration; organization workflows may select their approved runner group as well.

```yaml
name: ISO runner smoke
on:
  workflow_dispatch:
permissions: {}
jobs:
  smoke:
    runs-on: [self-hosted, linux, ARM64, iso-ci]
    timeout-minutes: 5
    steps:
      - name: Identify the runner
        env:
          CI_RUNNER_NAME: ${{ runner.name }}
        run: |
          uname -a
          printf 'runner=%s\n' "$CI_RUNNER_NAME"
```

Onboarding verifies execution and replacement: two consecutive invocations must use different clean VM and runner identities. Workflow generation is not permission to commit, push, or alter unrelated workflows.

## 9. Local Actions preflight

Preflight does not require runner registration or an installed GitHub App. Fetch credentials and mapped workflow secrets are optional and explicitly authorized; do not read all shell variables or imply GitHub can return stored Actions secret values.

Compile YAML and the declared expressions into an immutable workflow plan. Preserve `on` as a workflow key. Validate syntax, selected action metadata and statically decidable compatibility before allocation. Data-dependent failures are reported at the first responsible boundary; do not promise to statically analyze arbitrary shell programs.

| Included certified subset | Required semantics |
|---|---|
| Shell/environment/working directory | Exit status, timeout, command and environment handling |
| Approved JavaScript and composite actions | Selected runtimes, nested inputs/outputs and post-actions |
| `needs`, static matrices, conditions and outputs | Dependency ordering, skip/failure behavior, output propagation and declared expression subset |
| Checkout/dirty tree | Approved single-workspace checkout plus explicit snapshot overlay |
| Job containers, service containers and container actions | Official runner with guest-local Docker, qualified under this profile |
| Caches, artifacts, logs and results | Qualified action/runner protocol versions and authorized objects |

Publish one compatibility manifest binding runner/image, syntax, approved action/runtime versions, endpoint profile and protocol fixtures. Unsupported reusable/dynamic/context features are rejected explicitly. Platform mapping is operator-approved and recorded; ARM64 preflight is not silently equivalent to hosted x86/macOS. Genuine GitHub OIDC and approval authority are not forged.

The local server implements only the protocol surface exercised by this manifest: job delivery/completion, action resolution, timeline/logs and selected cache/artifact wire protocols. It is not a general GitHub emulator. A single store/server implementation does not mean one generic protocol can replace distinct Actions APIs. Differential/fixture testing is required; any reuse of external implementation/fixtures requires recorded provenance and license review.

### Source snapshots and checkout

Use iso's bounded workspace transport and safe extraction. Capture an immutable selected tree with visible inclusion/exclusion rules; exclude local credential files by default; include requested uncommitted/untracked content, deletions, executable modes and permitted links. Detect concurrent source changes during capture and retry boundedly or fail. Record base commit, snapshot, workflow, resolved actions and patch revision independently.

For an approved checkout step, insert a visible synthetic overlay immediately afterward and before subsequent user steps. It applies and verifies the selected snapshot, including deletions. Without checkout, materialize before the first user step. Unsupported multi-checkout, submodule or LFS layouts fail compatibility admission.

**Guarantee:** the selected input is materialized at that boundary. Later user commands may change their own workspace; predicting every reset/clean script is neither required nor claimed. A snapshot digest identifies supplied input, not tamper-proof attestation of everything hostile code executed. Never publish a dirty-tree success as proof that the unchanged base commit passed.

### Debug, patch, retry

Provide `run`, `logs --follow`, `inspect`, `debug`, `patch --from-working-tree`, `retry --from-start` and `abort`. Debug is scoped iso access; patch uses validated transfer and records a new snapshot/revision. Prevent patch/run races by requiring a retained, non-running attempt before altering its workspace.

Retry means a new whole-job attempt in a clean VM. Bind dependency outputs/artifacts to their original run/input provenance; do not mix changed inputs into a previously green workflow and present it as one clean run. Re-run affected dependency closure when needed or report explicitly mixed-input diagnostic provenance. Failed-step continuation is unsupported.

Connected mode destroys its VM by default. Live failure retention is explicit, finite, host-owned and budgeted. Distinguish it from stopped-disk retention. Revoke delegations supported by the immutable profile to reduce retained authority, or stop the VM; do not mutate a fixed boot policy in place or silently widen it on restart. Do not reacquire privileged secrets for debug. Existing secrets may remain in retained guest state; never describe network revocation as secret erasure. A replay of a connected job is a separate local result and cannot rewrite a GitHub check.

When replay needs upstream job outputs or artifacts, treat their provenance as an explicit input. A fresh snapshot must not silently reuse incompatible dependency results. If connected-job source, secrets, or dependencies cannot be reconstructed within the preflight manifest and current authorization, report that limitation instead of presenting the replay as equivalent to the GitHub run.

## 10. Storage, authorization, and result handling

### Object storage and authorized sharing

Preflight uses one immutable object store for snapshots, cache payloads, artifacts and log segments, with separate metadata/authorization for each kind. Reuse iso staging/validation; do not expose host paths. Cache matching retains declared Actions key/version/restore-key behavior within repository/authority/platform/compatibility scope. Preserve private writable dependency trees, atomic publication, output budgets and explicit promotion. Digest knowledge alone never authorizes a read.

Partition local cache namespaces by repository/owner, authority class, OS/architecture, approved image/toolchain, and dependency lock or input digest, in addition to the declared Actions key/version/restore-key semantics. Any broader compatibility fingerprint requires its own qualification. Shared immutable objects may be granted across authorized jobs; another attempt's private job/control objects may not. No new distributed cache service is required: remote runners use their scoped endpoint; image/local object locality is a placement preference, not a correctness requirement.

Connected Actions continue using GitHub cache/artifact services. Local export of diagnostics and optional operator-requested results does not transparently redirect those protocols.

### GitHub authority and host-side grants

Every guest remains hostile. A pool's `validation` label only describes intended policy and iso-side grants; it cannot reduce GitHub-issued `GITHUB_TOKEN` permissions or strip workflow secrets. Validate actual repository/group/workflow/environment restrictions and expose which guarantees are verified, operator-attested or unavailable. Fail admission when required controls cannot be established. Labels and watching one approved queued job are not security enforcement.[^security]

Separate unprivileged validation and privileged release inputs, resource grants, caches and credential release. Privileged capacity remains disabled unless every eligible job satisfies enforceable admission. Public/fork execution is a qualified target, never granted by repository privacy or name. Workflow changes and artifacts cannot request host configuration, provider keys, broader network access or privileged credentials.

## 11. Failure handling and reconciliation

| Condition | Required behavior |
|---|---|
| Host mutation reply lost | Retry/inspect the same durable identity; do not duplicate or assume cleanup |
| JIT response/registration cleanup uncertain | Reconcile owned registration separately; do not blindly repeat create |
| Controller/CLI loss | Controller-owned sessions survive CLI departure; controller loss follows iso lease/deadline behavior |
| Worker unreachable | Mark unknown; quarantine unresolved budgets/resources; no invented deletion success |
| GitHub unavailable/revoked | Pause affected admission, bound retries, preserve local limits, handle revocation under explicit stop policy |
| Broker/proof failure | Invoke host brokered-access revocation and CI stop behavior; never attach a NIC |
| Cancellation/expiry | Externally stop, stage permitted diagnostics, request verified cleanup |
| Disk/output/flood abuse | Enforce host budgets and preserve cleanup capacity |
| Job outcome unknown | No automatic side-effecting replay; require explicit authorization |

Guarantee bounded admission/revocation behavior and independent host deadlines while that host runs. Do not promise successful remote disk deletion by a finite deadline when a worker or API is unavailable. Keep cleanup debt visible until verified. Separately account for compute, storage/retention, and registration limits; conservatively reserve unresolved physical capacity.

Stopping public admission or revoking a grant does not erase secrets already delivered to guest memory, files, logs, or retained disks. Never include such material in an automatically promoted image or cache. Log masking is defense in depth, not a guarantee against deliberate exfiltration to an authorized destination.

## 12. Operator interface and configuration

All `iso-ci` commands and configuration below define the intended interface, not commands implemented by the referenced iso baseline. Command handlers use the same controller, records, and authorization as the setup wizard. No command may bypass the host-client contract or current qualification.

### Commands

| Command | Contract |
|---|---|
| `iso-ci setup` | Idempotent host/profile selection, App create/connect/install, pool authorization, and smoke-test preparation. |
| `iso-ci serve` | Run the controller in the foreground. `--install` explicitly installs/enables the supported user service. |
| `iso-ci status` | Report pool capacity, current allocations, qualification, availability, and unresolved cleanup. |
| `iso-ci pool pause <pool>` | Stop replenishment without implicitly killing assigned work. |
| `iso-ci pool drain <pool>` | Stop replenishment and retire idle capacity; let assigned work finish within its existing bounds. |
| `iso-ci pool remove <pool>` | Offboard only owned CI resources and report pending cleanup; credential removal is explicit. |
| `iso-ci run <workflow> --host <host> --platform linux/arm64` | Submit a local preflight run with explicit placement/platform. Configured eligible-host selection may be used when no host is fixed. |
| `iso-ci logs <run-or-allocation> --follow` | Stream bounded local events/diagnostics; connected jobs include their GitHub result/log reference rather than a complete local mirror. |
| `iso-ci inspect <allocation>` | Show input provenance, host references, job correlation, and independent execution/export/cleanup outcomes. |
| `iso-ci debug <allocation>` | Open explicitly authorized iso access to a retained environment without acquiring new privileged credentials. |
| `iso-ci patch <allocation> --from-working-tree` | Transfer a new validated snapshot into a retained, non-running preflight environment and record its revision. |
| `iso-ci retry <allocation> --from-start` | Create a fresh whole-job preflight attempt. Connected-job replay is a separate local result. |
| `iso-ci abort <run-or-allocation>` | Request cancellation and externally enforced stop; retain honest result/cleanup status. |

Mutations return stable operation/allocation identifiers. Machine-readable commands must expose typed status/error codes and bounded cursor-based events without parsing human text. Workload streams remain distinct from control responses. A disconnected CLI does not implicitly revoke controller-held leases; abort is an explicit operation.

### Configuration shape

Configuration is administrator-controlled. Repository-local workflow content may request an authorized pool or profile; it cannot define host executables, secrets, network destinations, privileged grants, or resource ceilings. The example uses symbolic references which setup resolves to approved immutable descriptors.

```yaml
schema: iso-ci/v1

profiles:
  linux-validation:
    platform: linux/arm64
    image: approved-linux-arm64-runner
    network_policy: approved-ci-public-egress
    compatibility: approved-connected-linux
    authority: validation
    limits: operator-approved-ci-limits

  linux-preflight:
    platform: linux/arm64
    image: approved-linux-arm64-runner
    network_policy: approved-preflight-egress-and-service
    compatibility: approved-local-actions
    authority: validation
    limits: operator-approved-ci-limits

pools:
  validation:
    profile: linux-validation
    hosts: [local]
    github:
      installation: selected-installation
      scope:
        repository: OWNER/REPOSITORY
      labels: [self-hosted, linux, ARM64, iso-ci]
    max_live_vms: 2
    desired_idle_vms: 1
    retention_on_failure: disabled

preflight:
  profile: linux-preflight
  hosts: [local]
  architecture_mapping: explicit
  retry: fresh-job
```

For organization pools, select organization scope and an explicitly authorized runner group instead of repository scope. Resolve and validate scope exclusivity, group access, actual labels, approved digests, installation identity, and capability compatibility before activating a pool.

The limits descriptor must contain finite CPU/memory/disk allocation, boot/idle/job allowances, a host-enforced hard deadline, bounded stop/export grace, output/traffic limits, and finite retention. Persist chosen values rather than relying on undocumented defaults. Capacity is checked across the operator's pools and preflight work, then admitted by the worker under its own limits. Starting, retained, exporting, and uncertain allocations continue to consume their relevant budgets.

Credentials live in the protected credential store, not this configuration. The example capacity values are illustrative, not performance claims. Explicit operator approval is required for service installation, grant changes, or credential removal. Invalid or partial configuration leaves the affected pool inactive.

## 13. Implementation sequence and qualification

The brokered execution prerequisite in section 2 must be implemented and qualified before real CI execution. The companion consumes that capability and does not absorb its networking work.

| Milestone | Work | Completion gate |
|---|---|---|
| **S0 — Host client and execution harness** | Supported client subset, controller ownership, allocation records, clean environment creation, bounded streams/results, cancellation, uncertainty, and host-owned retention. | A fresh brokered VM runs one command without developer state; live and stopped retention, result staging, forced stop, and verified destruction work through the supported client. |
| **S1 — Connected pools and onboarding** | App create/connect/install, protected credentials, profiles, ready-pool reconciliation, official runner/Docker integration, diagnostics, and cleanup. | Two real jobs use distinct clean VMs and registrations; repository and organization scope behavior, routing, startup/assignment/removal races, and the declared container/action cases pass. |
| **S2 — Local preflight** | Workflow compiler, scoped local APIs, snapshots/checkout overlay, caches/artifacts, debug, patch, retention, and fresh replay. | Every included manifest feature has runner-level fixtures; dirty-tree provenance, authorized sharing, and replay outcomes are correct. |
| **S3 — Fleet, security, and release** | Fair multi-host placement, aggregate budgets, drain/offboard, updates, public-trigger and privilege qualification, failure suite, and operator documents. | Two-worker concurrency and failure cases pass; support claims match qualification evidence; unverifiable privileged modes remain disabled. |

Run security and failure tests during each milestone. The complete companion requires S0–S3 and all applicable acceptance gates; a shipping subset must be labeled by its actual supported capabilities.

Reuse valid network-foundation evidence with exact dependency references. Add composition tests for the runner, root-capable guest Docker, bootstrap path, and every new guest-facing endpoint. Runtime, kernel, broker, transport, or channel changes invalidate affected evidence and require reruns. Runner-only changes require the applicable CI compatibility/security suites, not unrelated test implementations.

Qualify image and runner updates as an operational requirement. Pinning must not leave connected runners outside GitHub's applicable update policy. Drain/refuse unsupported images, record actual runner versions, and rerun affected endpoint/action fixtures.[^runners]

## 14. Acceptance tests

The following release-blocking tests apply to each claimed worker/profile combination. Native tests must record host-side observations and valid positive controls; skipped or unavailable cases are blocked, not passed.

| ID | Required evidence |
|---|---|
| C-T01 | Require the qualified handoff and current host admission; refuse unsupported profiles with no NIC fallback. |
| C-T02 | Never alter development VMs/credentials or unrelated settings; only explicit CI-only configuration/service writes are allowed. |
| C-T03 | Correct GitHub scope/OS/architecture/labels; consecutive jobs use different clean VM and runner identities. |
| C-T04 | No App private keys, installation-management tokens, host-management private keys, or tailnet enrollment credentials enter guests, images, or logs. Authorized job credentials and JIT exposure are distinguished and documented. |
| C-T05 | Runner, checkout, declared JS/composite actions, Docker job/service/action cases, approved pulls, logs and artifacts work. |
| C-T06 | Inherit valid base isolation evidence and prove no runner/Docker/new API path reaches unauthorized host, VM, LAN or tailnet targets. |
| C-T07 | Faults, cancellation, expiry and revocation produce bounded control responses, host-enforced deadlines and honest cleanup debt until verification. |
| C-T08 | Same-operation retry cannot duplicate resources; uncertain host/JIT results do not release capacity or duplicate side effects. |
| C-T09 | Reject statically unsupported semantics before allocation; make data-dependent errors and platform mapping explicit. |
| C-T10 | Dirty tree, deletions and modes are correct at the post-checkout boundary; input provenance is never falsely represented as clean-commit attestation. |
| C-T11 | Local APIs deny cross-attempt private/control access; only explicitly granted immutable cache/artifact sharing succeeds. |
| C-T12 | Poisoning, incomplete cache publication, traversal/links, oversized output and automatic privileged artifact consumption are blocked. |
| C-T13 | Live/stopped retention is finite, budgeted and scoped; patch/replay preserves provenance and never rewrites GitHub checks. |
| C-T14 | Two workers, concurrency, disruptions, restarts, placement and drain/assignment races preserve capacity and ownership. |
| C-T15 | Unprivileged sources cannot acquire privilege through labels/config/artifacts/caches; verify GitHub-side as well as iso-side controls; disable unverifiable privileged modes. |
| C-T16 | Trigger/flood/disk/timeout abuse cannot bypass external budgets or starve cleanup. |
| C-T17 | Offboarding touches only owned CI resources; accurately expose service, secure-store, permission and availability constraints. |
| C-T18 | Qualify runner/image/endpoint updates, preserve evidence dependency tracking, and drain/refuse unsupported versions. |

Include explicit regression tests for an unassigned warm allocation, lost JIT response, GitHub secret delivery despite a `validation` label, allowed shared cache versus denied private object, source mutation after overlay, unavailable-worker cleanup debt, and retained guest secrets. These cases must be represented by explicit fixtures, not inferred from unrelated success-path tests.

## 15. Release deliverables

Ship one companion package containing the controller/CLI executable and its internal library, plus the bounded preflight child mode. Base iso must still build, install, and operate without the companion or GitHub authorization.

```text
iso/
  Sources/                     # host service and supported client integration
  iso-sandbox/                 # VM lifecycle and qualified private transport
  iso-proxy/                   # provider broker; not inherited by CI jobs
  iso-egress/                  # shared qualified egress enforcement
  iso-ci/
    Package.swift
    Sources/
      IsoCICore/
        Execution/
        GitHub/
        Preflight/
        Storage/
      IsoCI/                   # CLI, controller and confined child entrypoints
    Tests/
  docs/design/
    iso-ci-specification.md
    iso-ci-qualification.md
```

Publish the supported host/runtime/kernel/image/runner/endpoint combinations, preflight compatibility manifest, qualification dependencies and results, onboarding/offboarding instructions, operational limits, network and credential grants, provenance model, and failure/recovery behavior.

A release must distinguish supported features, blocked qualification, and deliberately unsupported capabilities. Public/fork execution and privileged release availability are separate support claims backed by their own applicable controls and tests. Repository privacy is not a substitute for those controls.

Record provenance and assess licensing before copying or deriving external workflow, protocol, or fixture implementations. A Swift rewrite or package boundary does not by itself settle reuse rights.

Release sign-off requires the execution prerequisites, complete included functionality, bounded failure behavior, independent outcome reporting, update process, and applicable acceptance tests. This document records requirements. Implementation status and test evidence live in the [qualification record](iso-ci-qualification.md); no recorded case is a release sign-off.

## 16. Implementation references

Repository references identify the code baseline used for the integration design, `d27752a7fd1b1731c8dd700e2e9457c119e2fc2e`. They do not assert that any new CI capability exists in that baseline. External API and tool requirements must be checked against the versions selected for implementation and qualification.

[^host]: [iso host-control protocol](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoHost/HostControl/HostProtocol.swift).
[^run]: [iso disposable-run and remote workflow commands](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/Sources/IsoCLI/Commands/HostWorkflowCommands.swift).
[^jit]: [GitHub self-hosted runner REST API, including JIT configuration](https://docs.github.com/en/rest/actions/self-hosted-runners).
[^jobs]: [GitHub workflow jobs API](https://docs.github.com/en/rest/actions/workflow-jobs).
[^runners]: [GitHub self-hosted runner reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).
[^proxy]: [GitHub runner proxy configuration](https://docs.github.com/en/actions/how-tos/manage-runners/use-proxy-servers).
[^docker]: [Docker daemon proxy configuration](https://docs.docker.com/engine/daemon/proxy/) and [Docker container/build proxy configuration](https://docs.docker.com/engine/cli/proxy/).
[^app]: [GitHub App manifest flow](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest).
[^security]: [GitHub compromised runners](https://docs.github.com/en/actions/concepts/security/compromised-runners), [runner group access](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access), and [secure use](https://docs.github.com/en/actions/reference/security/secure-use).

## Implementation status

The tree implements this contract in `iso-ci/`. Local preflight, a
GitHub-connected repository pool, an organization pool and a two-worker pool
have run end to end against real GitHub and the official runner on qualified
brokered Macs. The evidence, the defects it exposed and the review hardening
are in the [qualification record](iso-ci-qualification.md). Release
qualification of a signed, tagged build has not been recorded, and no case is
a release sign-off.

### Where each part lives

| Spec section | Implementation |
|---|---|
| 2 Brokered prerequisite | Host: `host.capabilities` advertises `net-handoff-1` only for a brokered host whose evidence manifest (`scripts/record-net-handoff-evidence.py`) matches the live tuple with N-T01–N-T16 passed and unexpired; it reports the grant set of the brokered policy a fresh run VM boots with. Companion: `AllocationDriver.admission` refuses without the capability, current qualification, a grant-free run policy, the reviewed endpoint profile, or the profile's limits; `provision` compares the boot's live proof with the admitted policy digest, and every guest session revalidates it. There is no vmnet, NIC or developer-credential fallback. |
| 3 Architecture | `iso-ci/`: one library (`IsoCICore` with `Execution`, `GitHub`, `Preflight`, `Storage`) and one executable (CLI, controller, `_dataplane` child). Private control socket (same-user, 0700/0600). The data plane runs in a confined child (`sandbox-exec`, empty environment, only stdio inherited, staging-only filesystem, no network but its Unix socket); a failed self-test refuses preflight. |
| 4 Client contract | Thin client over `iso.host/v1` through `iso host-agent client --host ALIAS --stdio [--relay]` (remote-v1 restrictions also apply locally). `run.retain` (host-owned live/stopped retention) is the workload-neutral finalize extension. |
| 5 State | One SQLite controller database with an ownership lock, allocation/intent/pool/host/approval/App/installation/preflight records, a bounded cursor event log, and a content-addressed object store with per-subject grants. Host mutations use identities persisted before sending; lost replies resolve the same identity. Execution, export, VM cleanup and registration outcomes are independent; unknown is never treated as failed or reusable. Placement is deterministic filter-and-select with budgets that count uncertain and cleanup-debt allocations. |
| 6 Profiles and images | `iso-ci/v1` descriptors (image, network policy, compatibility, limits) with digests and operator approvals; `iso-ci/images/ci-runner.profile.jsonc` pins actions/runner v2.338.0 by SHA-256. |
| 7 Connected pools | `ConnectedPoolReconciler` (refresh → lifecycle → deficit → create), JIT material only via the VM's SSH stdin, exact-owned registration reconciliation and an operator-resolved uncertain state, GitHub-observed job binding, idle retirement before the hard deadline, single-job VMs. |
| 8 Onboarding | `iso-ci setup` (hosts, config, approvals, App manifest flow or existing App, installation verification, service, smoke workflow, availability limits); `pool pause/drain/resume/remove/resolve`. |
| 9 Preflight | Strict YAML subset, expression subset, `local-actions/v1` manifest, compiler with full static diagnostics, job graph, deterministic selected-content snapshots (`iso-ci.snapshot/v2`, no base-commit bundle or history) with credential-file excludes, synthetic checkout/overlay steps, `run`/`debug`/`patch`/`retry`/`abort`, approved action archives (`iso-ci actions import`). |
| 10 Storage and authority | Scoped caches (first writer wins, invisible until verified), run-scoped artifacts gated by dependency provenance and authority class, signed URLs, per-allocation budgets; GitHub-side guarantees reported as verified / operator-attested / unavailable; privileged pools stay inactive. |
| 12 Interface | All commands in the table, plus `pool resume`, `pool resolve`, `actions import/list`; `--json` with typed codes. |

### Decisions taken while implementing

- The preflight data plane uses the official runner's run-service ("V2")
  protocol, cache v1 REST and artifact v2 twirp with Azure block uploads,
  derived by reading MIT-licensed sources (`iso-ci/PROVENANCE.md`).
- The guest reaches the preflight endpoint only through an `ssh -R` forward
  from guest loopback to the controller's Unix socket inside that VM's own
  session; no host TCP listener is opened.
- Failed preflight jobs are retained live (finite, host-owned) for debug and
  patch; connected pools follow `retention_on_failure` (default disabled).
- `concurrency:` is accepted with a warning that it is ignored.

### Known gaps

- Release qualification of a signed, tagged build has not been recorded.
- Custom runner groups with workflow restrictions need a paid GitHub plan;
  that path is covered by fixtures only.
- Live console feeds, `DeleteArtifact`/`MigrateArtifact` and controller-side
  `hashFiles()` are not implemented.
- A connected job's GitHub conclusion is no longer tracked once its
  allocation settles after an abort.
- The guest bootstrap's Docker proxy configuration assumes systemd and sudo
  in the image.

Operator constraints are in the [operator guide](../ci.md): storing the App
key again after a rebuild ([onboarding](../ci.md#onboarding)), `no_proxy` for
service containers ([configuration](../ci.md#configuration)), the network
policy and user that preflight container images need
([local preflight](../ci.md#local-preflight)), and the refusal of public, fork
and privileged execution ([credentials and trust](../ci.md#credentials-and-trust)).
