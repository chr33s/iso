# IsoPolicy v1 — implementation specification

**Status:** Implemented in the `feat/iso-policy` branch; see §19 for where the
implementation made a choice the contract left open.  
**Target:** `chr33s/iso`  
**Repository baseline:** `47d17ba2524b145b229abcf42c85f8b5f0071e65` (`main` inspected on 2026-10-13).  
**Operator documentation:** [`../policy.md`](../policy.md)  
**Supersedes:** The earlier `iso-policy-minimal-spec.md` design sketch.

## 1. Decision

Build a small Swift library, `IsoPolicy`, shared by the host CLI and credential proxy. It provides a default-deny, permit/forbid decision model and exactly two history-dependent controls: a sliding-window request-admission limit and a recent, single-use approval for staged workspace changes.

Do not embed Cedar, Dogwood, a scripting language, a database, or another service. This is an iso-specific design inspired by those projects, not an implementation of either language. Cedar supplies the permit/forbid inspiration; Dogwood supplies the idea of authorization depending on recent events.[^cedar][^dogwood]

**The policy engine can only narrow existing permissions.** An allow decision does not replace VM isolation, capability authentication, operation allowlists, TLS checks, credential-forwarding restrictions, session expiry, or safe filesystem handling.

The words **MUST**, **MUST NOT**, and **SHOULD** define implementation requirements. Everything below is proposed unless explicitly described as an inspected repository fact.

### 1.1 Deliberate changes from the sketch

| Sketch idea | Implementation decision | Reason |
|---|---|---|
| Generic `countBelow(event: ...)` | Count admitted proxy requests, not successful responses | Avoid success-accounting races and ambiguous refunds |
| Temporal conditions on individual permit rules | Independent, mandatory guards | Another permit must not bypass a quota or approval requirement |
| Host-wide event store | Bounded counters inside each proxy; an in-process approval receipt | Avoid a daemon, durable event database, and interprocess history protocol |
| Reusable approval within a time window | One receipt for one exact staged apply attempt | Prevent approval reuse for different content or destinations |
| Root-package `Sources/IsoPolicy` only | A small local `iso-policy/` library package | Reuse the evaluator without linking host orchestration into the proxy |
| `vm.start` in v1 | Deferred | Keep v1 focused on credential use, provider requests, and host-bound file writes |
| Hot policy reload | Immutable policy per VM boot | Avoid live reload races, mixed versions, and quota reset on configuration edits |

These changes are part of the contract, not optional follow-up hardening.

## 2. Repository integration baseline

The inspected root package separates `IsoCore`, `IsoConfiguration`, `IsoSecrets`, `IsoHost`, and `IsoCLI`. The host does not link the separate runtime or credential-proxy packages. Root Swift tests live under `tests/swift`, not a new case-conflicting `Tests/` directory.[^package]

The existing configuration pipeline already handles JSONC scanning, duplicate-key preflight, typed decoding, and validation. Reuse it; do not introduce another JSONC parser. The architecture also identifies `ProxyLifecycle`, `ProxyStartup`, `BoundaryAudit`, and the staged workspace components as host integration points.[^architecture]

| Existing seam | Required addition |
|---|---|
| `Sources/IsoConfiguration/` | Decode the optional policy object with strict unknown-key handling; compile it after existing JSON preflight |
| `Sources/IsoHost/Guest/ProxyStartup.swift` | Versioned, host-origin policy snapshot in the confidential startup handoff |
| Host `ProxyLifecycle` / credential resolution | Enforcing-mode compatibility checks, boot binding, and no restart-with-empty-counters fallback |
| `iso-proxy/Sources/IsoProxyTransport/InboundGate.swift` | Atomic authorization immediately before forwarding an admitted request head |
| `WorkspaceTransfer.applyStage(...)` and `StageApplier` | Exact-stage approval and a host-side enforcement check before mutation |
| `Sources/IsoCLI/Commands/WorkspaceCommands.swift` | Trusted review/confirmation UI; never the sole enforcement point |
| Host state and `BoundaryAudit` | Immutable policy metadata and sanitized policy diagnostics |

`InboundGate` currently checks capability authentication, `OperationPolicy`, header policy, framing, and capacity before forwarding the request head. Insert the new check after those admission checks and before `100 Continue` or `context.fireChannelRead(data)`.[^inbound]

The current startup encoder emits protocol version 1 without readiness and version 2 with readiness. The policy-enabled protocol specified below is a new version, not an existing capability.[^startup]

The repository includes an `iso-egress` filtered-egress companion. This spec neither replaces it nor adds a `network.connect` action. Proxy policy does not govern traffic that bypasses the proxy.[^architecture]

## 3. Scope and threat model

### 3.1 Supported actions

| Action | Resource selectors | Authoritative enforcement point |
|---|---|---|
| `credential.use` | `provider:anthropic`, `provider:openai` | Proxy, for each request using its configured provider credential |
| `proxy.request` | `provider:anthropic`, `provider:openai` | Proxy, before forwarding each admitted HTTP request |
| `workspace.pull.apply` | `workspace:attached` | Host staged-apply workflow, before destination mutation |

`credential.use` means use of the proxy's configured provider credential. It is not authorization for every secret-resolution call, GitHub token, environment variable, or credential available elsewhere on the host. An early host check may avoid resolving a denied provider credential; it does not replace the proxy check.

A provider request checks every applicable governed action in the pair `credential.use` and `proxy.request`. If either denies, the request is not forwarded. The pair consumes at most one admission per applicable rate-limit guard.

`workspace:attached` is a policy selector, not a filesystem path. In v1, governed applies are limited to the instance's recorded attached workspace. A different `--dir` destination is unsupported under enforcing workspace policy and MUST be rejected rather than silently treated as attached.

### 3.2 Identity and trust

The principal is an **instance and VM boot**, not an individual process or named AI agent. All guest processes holding that boot's provider capability share its provider quota. Guest root must not be assumed to preserve distinctions between agents inside the same VM.

Trust the host operator, host-owned configuration/state, the existing process-launch handoff, and the confined proxy's own code. Treat guest requests, headers, workspace contents, claimed session IDs, claimed timestamps, and claimed approvals as untrusted.

The host binds the instance identity, boot identity, policy epoch, provider, and capability when launching the proxy. A guest header MUST NOT select any of those identities. Authentication through the existing capability establishes access to that already-bound proxy; it does not establish a separate guest-supplied principal.

This feature does not defend against a malicious host administrator or malicious code already executing with the host user's authority. A policy digest identifies content; it is not a signature and is not an independent trust root.

### 3.3 Explicit non-goals

No Cedar/Dogwood syntax compatibility, arbitrary expressions, entity graph, generic event queries, monetary/token budgets, distributed quotas, reusable approval tokens, background approval service, per-agent isolation inside one VM, live reload, command inspection inside the guest, or new network firewall.

## 4. Configuration contract

Add an optional top-level `policy` object. Existing configuration without it retains existing behavior.

### 4.1 Example

This is proposed configuration. The example assumes the referenced `vault:anthropic` credential has already been provisioned. The existing example configuration documents `vault:`/`cmd:` credential references, `proxy.mode`, security presets, and staged pulls.[^config]

```json
{
  "security": { "preset": "provider-only" },
  "proxy": {
    "mode": "required",
    "anthropic": {
      "credential": "vault:anthropic",
      "auth": "api_key"
    }
  },
  "workspace": { "pull": { "mode": "stage" } },
  "policy": {
    "version": 1,
    "mode": "enforce",
    "actions": [
      "credential.use",
      "proxy.request",
      "workspace.pull.apply"
    ],
    "rules": [
      {
        "id": "use-anthropic",
        "effect": "permit",
        "action": "credential.use",
        "resources": ["provider:anthropic"]
      },
      {
        "id": "request-anthropic",
        "effect": "permit",
        "action": "proxy.request",
        "resources": ["provider:anthropic"]
      },
      {
        "id": "apply-attached-workspace",
        "effect": "permit",
        "action": "workspace.pull.apply",
        "resources": ["workspace:attached"]
      }
    ],
    "guards": [
      {
        "id": "anthropic-admission-limit",
        "action": "proxy.request",
        "resources": ["provider:anthropic"],
        "require": {
          "rate_limit": { "max_requests": 100, "within_seconds": 60 }
        }
      },
      {
        "id": "review-before-apply",
        "action": "workspace.pull.apply",
        "resources": ["workspace:attached"],
        "require": { "approval_within": { "seconds": 900 } }
      }
    ]
  }
}
```

OpenAI is denied for the governed provider actions because no permit matches it. Do not add a catch-all forbid to express this default: a matching forbid would also override an intended permit.

### 4.2 Fields and matching

| Object | Required fields | Optional fields |
|---|---|---|
| `policy` | `version`, `mode`, `actions`, `rules`, `guards` | None |
| Rule | `id`, `effect`, `action`, `resources` | `instances` |
| Guard | `id`, `action`, `resources`, `require` | `instances` |
| `require.rate_limit` | `max_requests`, `within_seconds` | None |
| `require.approval_within` | `seconds` | None |

`mode` is exactly `off`, `shadow`, or `enforce`. `effect` is exactly `permit` or `forbid`. `require` contains exactly one supported variant, not both.

A selector matches when its action equals the request action, its resource list contains the normalized resource selector, and its optional `instances` list contains the host-derived instance name. Omitted `instances` means all instances to which the snapshot applies. A present empty list is invalid. Instance names are validated using iso's existing name rules; they are convenience selectors, not substitutes for boot identity.

No wildcard, regex, prefix, negation, `when`, `unless`, or implicit string conversion is supported. Unknown actions, unknown resource aliases, mismatched action/resource types, and unknown keys are errors. `null` is not equivalent to absence.

All rule and guard actions MUST appear in `policy.actions`. Empty rules are valid and deny all governed actions. Empty `actions` is allowed only in `off` mode. Even an explicit `off` policy must be structurally valid.

### 4.3 Guard semantics

A rate limit is legal only on `proxy.request`. An approval guard is legal only on `workspace.pull.apply`. All matching guards apply independently of which permit matched. Multiple matching guards are conjunctive: every limit must have capacity, and an approval must satisfy every applicable freshness bound.

One exact-stage approval may satisfy multiple approval guards; it is consumed once for the apply attempt. Quota state is keyed by guard ID, so two distinct rate guards retain distinct windows and capacities.

### 4.4 Validation bounds

| Item | v1 bound |
|---|---|
| Canonically encoded policy | At most 64 KiB, also subject to existing outer configuration limits |
| Rules / guards | At most 128 / 16 |
| Rule or guard ID | Unique across both collections; 1–64 ASCII characters matching `[a-z][a-z0-9._-]*` |
| Instance selectors per entry | At most 64; no duplicates |
| Resources per entry | Only the supported resource set for that action; no duplicates |
| Rate window | Integer 1–3,600 seconds |
| Rate capacity | Integer 1–10,000 admissions |
| Matching rate guards per provider/instance | At most 4 |
| Total allocated timestamp slots per proxy | At most 40,000 |
| Approval freshness | Integer 1–900 seconds |

Reject floats, exponent-form integer literals, booleans masquerading as numbers, overflow, and duplicate keys through the existing parsing/decoding pipeline. The proxy must independently validate its received typed policy and bounds; a host-side compile is not permission to trust an unchecked wire document.

## 5. Policy snapshots and compatibility

### 5.1 Snapshot identity

At a new boot, compile one immutable policy and persist a host-owned boot binding containing:

```text
recordVersion, instanceID, bootID, policyEpoch,
policyDigest, policyMode, governedActions, canonicalPolicy
```

`policyEpoch` is a fresh host-generated UUID for the boot, including when the policy text is unchanged. `policyDigest` is SHA-256 over the normalized policy representation, not over the whole iso configuration and never over credentials.

Normalize by sorting rule/guard entries by ID and sorting set-valued arrays, while preserving all meaningful fields including version, mode, and scope. Encode compact UTF-8 JSON with deterministic key ordering and escaping. Define this encoding as `canonicalizationVersion = 1`; ship exact-byte fixtures shared by host and proxy. Do not claim interoperability with an unspecified general-purpose JSON canonicalization standard.

Host state uses existing owner-only state-file and locking primitives. Add a versioned record rather than placing policy data in guest-visible files. Persist an explicit off binding for new boots without policy so that missing state cannot be mistaken for disabled enforcement.

### 5.2 No live reload

Running boots use their stored snapshot. Editing or removing the configuration does not loosen or tighten that boot. A policy command must show the active digest and identify a differing configured policy as pending the next boot.

A new boot starts a new epoch and new boot-scoped quotas. This is an explicit reset available to the trusted operator, not a cross-boot budget guarantee. An enforcing workspace stage from an earlier epoch must be re-staged before apply.

The latest boot snapshot remains available after the VM stops, allowing its stage to be reviewed and applied while stopped. A subsequent boot supersedes that epoch. A destroyed/recreated instance must not inherit the former instance's stage authorization merely because its display name matches.

### 5.3 Mode behavior

| Situation | Behavior |
|---|---|
| Policy absent or `off` | Existing enforcement and workflows; no temporal mutations |
| `shadow` | Existing outcome wins; report a separate hypothetical policy result |
| `enforce`, governed action | Hard checks AND policy authorization are required |
| `enforce`, ungoverned action | Existing checks remain authoritative; report `not_governed`, not a policy allow |
| Invalid configuration | Validation/operation startup fails; never silently select `off` |
| Lost/corrupt active enforcing snapshot | Governed operations fail closed |
| Existing running instance predating policy bindings | Continue legacy use only without requested enforcement; enabling enforcement requires a new boot |

Shadow evaluation uses separate in-memory simulated quota state. Insert a simulated admission only when the hypothetical batch allows; never count an existing hard-denied request. No shadow result mints or consumes a real approval or changes a real request's disposition. A direct workspace pull lacks the staged approval context and is reported as `shadow_unavailable:not_staged`, not as a fabricated fully evaluated verdict. Shadow diagnostics are observational, not a claim of exact counterfactual workload behavior.

### 5.4 Configuration combinations

When enforcing either provider action, require effective `proxy.mode = required` for the governed provider path. Refuse a raw-key fallback, proxy-off path, or an incompatible provider authentication mode. Do not silently rewrite the requested mode. Known raw-provider forwarding paths must not bypass this check. Arbitrary secrets deliberately placed in guest content are outside the feature's guarantee.

When enforcing workspace apply, require effective `workspace.pull.mode = stage`. Reject incompatible direct-return configuration. The host direct-pull implementation must independently refuse a direct write under such a stored boot policy; checking only CLI argument routing is insufficient. Policy cannot widen a hard restriction established elsewhere.

## 6. Evaluation contract

### 6.1 Decision order

For a trusted request or provider-action batch:

1. Perform existing authentication, normalization, hard restrictions, and resource admission checks.
2. Resolve the immutable policy binding. Reject missing, mismatched, or invalid enforcing state.
3. Evaluate every governed action: any matching forbid denies; otherwise at least one permit must match.
4. Collect **all** guards matching those actions and concrete resources.
5. Atomically validate the guards and consume their required state.
6. Return the decision to the same trusted mediator, which may proceed only with the existing boundary checks still satisfied.

No earlier allow result may be cached across a new request, changed stage, boot, or policy epoch. Rule order is not precedence. A failed action in a batch MUST NOT consume another action's quota or approval.

Unlike Cedar's documented skip-on-error behavior, this custom evaluator denies a governed enforcing request on an evaluation/state error. That divergence is intentional.[^cedar]

### 6.2 Decision representation

Return a typed result, not a Boolean:

```text
verdict: allow | deny | not_governed
reason: allowed | explicit_forbid | no_permit | quota_exceeded |
        approval_required | approval_expired | approval_mismatch |
        approval_consumed | policy_state_unavailable |
        policy_epoch_mismatch | unsupported_path | internal_error
policyDigest, policyEpoch
matchedPermitIDs, matchedForbidIDs, requiredGuardIDs
failedGuardIDs, decisionID
```

Sort diagnostic IDs for stable output. `not_governed` does not authorize anything by itself. Guest-visible responses do not include policy contents, rule IDs, or credential details. Shadow status is an outer diagnostic field, not another way to obtain an enforcing allow.

## 7. Atomic sliding-window admissions

### 7.1 Exact counting rule

For a guard with capacity `L`, window `W`, and trusted current time `t`, count admissions whose timestamps satisfy:

```text
0 <= t - admissionTime < W
```

An admission exactly `W` old is expired. Requests at identical clock ticks still count separately. The check and insertion occur in one critical section.

An admitted request remains charged even if its body never arrives, its transport fails, the client disconnects, or the provider returns an error. There is no success commit, refund, reservation cancellation, or outstanding-request timeout in this rate counter. Existing connection/concurrency leases remain separate.

This is a rate limit on admission at the proxy boundary, not a billing guarantee, response-success quota, byte limit, or exact limit on when an upstream server receives bytes. Subsequent client retries are new requests and new admissions. Do not introduce transparent request replay after admission in v1; any future retry mechanism must define and reauthorize each new attempt explicitly.

### 7.2 Owner and algorithm

One limiter is created per proxy process, shared across all connections/event loops for its bound provider. Do not allocate one limiter per `InboundGate` or TCP connection.

Use a short, bounded synchronous lock around pure state work. This avoids a new async authorization state in the streaming HTTP pipeline. No file access, network access, logging, callbacks, or suspension occurs while holding the lock.

```text
checkAndAdmit(providerBatch):
    lock shared limiter
    read trusted monotonic time
    reject invalid time or binding
    check static permissions for every governed action
    for every matching rate guard:
        evict expired timestamps
        if count >= capacity: record failure
    if any action or guard failed:
        unlock and deny without insertion
    append this admission time once to every matching rate guard
    unlock and allow
```

Use bounded ring buffers/deques; do not repeatedly shift an unbounded array. Expiring old timestamps is housekeeping, not consumption, and may occur on a denied request. All guard checks use the same time sample. Compute `Retry-After`, when provided, as the rounded-up longest wait across failed rate guards.

### 7.3 Time

Production uses a host monotonic clock through a small injected clock adapter. The adapter must specify behavior during host sleep and tests must verify it; prefer elapsed time that includes sleep. Guest timestamps and wall-clock time are never used for quota or approval validity. UTC timestamps are only for diagnostics.

Do not persist process-local clock instants and reload them in another process. Regressing/invalid clock samples or arithmetic overflow deny the governed request. Tests use an integer fake clock with exact boundary values.

### 7.4 Crash and restart contract

V1 avoids durable request history by **forbidding quota-state replacement within an enforcing boot**.

Before launching an enforcing proxy, the host takes the instance lock and durably records a claimed `(bootID, policyEpoch, provider, proxyGenerationID)` launch slot. Claim before spawning; an uncertain interrupted launch stays claimed. Only one proxy generation may own that provider slot in that epoch.

If a proxy dies, the host must not restart it with empty counters, rotate its capability to reset the slot, or fall back to raw forwarding. The governed provider becomes unavailable until the operator starts a new VM boot. An interrupted launch may therefore require a new boot even when no provider request is known to have occurred. This conservative availability cost is intentional.

Missing/corrupt claim state on an already-running enforcing boot is not an unclaimed slot. Fail closed. Do not use PID equality alone to establish process identity. For shadow mode, restarting the simulation is allowed, but emit an explicit simulation-reset diagnostic.

## 8. Recent, single-use staged approvals

### 8.1 Minimal approval model

An approval exists only in the host apply process, after trusted terminal confirmation of the exact stage being reviewed. There is no `iso policy approve` token API, reusable approval file, guest callback, or durable approval database in v1.

An approval receipt binds:

```text
approvalID, instanceID, bootID, policyEpoch, policyDigest,
action = workspace.pull.apply,
workspaceIdentity, destinationDirectoryIdentity,
stageID, manifestDigest,
issuedAtMonotonic, consumed
```

`workspaceIdentity` comes from the host workspace record and destination binding, not just a user-supplied path. `destinationDirectoryIdentity` includes a checked directory handle identity, such as device/inode, held and revalidated by the filesystem adapter.

`manifestDigest` covers the complete authorized mutation plan: stage ID, instance/epoch binding, destination binding, normalized paths, operation types, old-object expectations, new content hashes, file modes, and symlink targets. Use a versioned deterministic manifest encoding. A stage name or top-level directory name alone is insufficient.

The receipt is not a cryptographic proof that a person read every file. It records an explicit trusted-host confirmation, under the host-operator threat model.

### 8.2 Review and apply flow

The current CLI supports `iso pull <name> --review`, `--apply`, and `--stage-id`; reuse that interface.[^workspace-cli]

```bash
iso pull my-vm --review
iso pull my-vm --apply --stage-id STAGE_ID
```

With a matching approval guard, the apply command MUST render the bound stage summary, existing security-sensitive path warnings, and available bounded diffs again before asking for confirmation. The existing review renderer sanitizes guest-controlled display text and bounds text diffs; retain those properties and clearly indicate content omitted from display.[^review]

The implementation sequence is:

1. Load the current instance policy and stage; verify epoch and workspace binding. Verify the staged content against its manifest before treating the rendered material as the approved content.
2. Check static policy and stage applicability before prompting. Render the exact review and request explicit confirmation through the host terminal. Do not accept guest input, environment variables, `--force`, piped `yes`, or machine-output mode as approval.
3. Create the in-memory receipt. Do not hold the instance lifecycle lock while waiting for a person.
4. Acquire the stage/workspace apply lock. Re-read and compare stage ID, manifest digest, current policy epoch, and destination identity. Recheck destination drift and stage content integrity. Changes require a fresh review, not automatic receipt rebinding.
5. Immediately before mutation, check the receipt against every matching approval guard and mark it consumed. The freshness test is `0 <= now - issuedAt < seconds`.
6. Apply through the existing descriptor-relative applier, using the verified destination/stage handles rather than reopening an unchecked path. Record the actual result.

At most one iso return operation may mutate that workspace at a time. After confirmation, acquire locks in this order: instance lifecycle lock, destination-workspace lock, then stage lock. Revalidate the epoch and prepared handles after acquisition. Hold the locks through authorization, apply, and stage-result publication; release in reverse order. Never hold them across the human prompt. Lifecycle changes and stage creation/discard must use compatible ordering. Key the workspace lock by the verified destination directory identity in host-owned lock storage, not by a guest-controlled path. Other iso return paths that mutate the same destination, including legacy direct returns, must honor that workspace lock. Existing external editors remain outside these locks, so per-operation drift checks are still required.

A receipt is consumed before the first possible destination mutation, even if the attempt subsequently fails without a write. It is not restored on error. A second attempt needs a fresh review. Process exit discards the receipt.

### 8.3 Existing filesystem protections remain mandatory

The inspected `StageApplier` already checks destination drift, staged file hashes, and descriptor-relative operations, and reports partial applies through `StageApplyError`. Preserve those checks and partial-failure reporting; policy approval does not make the entire workspace update transactional.[^apply]

Close authorization-to-use gaps by checking the final root identity, not just a path string, and by binding the approval to the actual prepared mutation plan. Denied or expired approval must produce zero destination mutations. A later I/O failure may produce a partial apply, which must remain visible and must not reuse the approval.

For a stopped VM, apply may use the latest retained boot snapshot and a newly issued local receipt. For a newer boot, changed instance identity, or old/missing stage epoch under enforcement, refuse with `policy_epoch_mismatch` and require re-staging. Do not let changing `--config` bypass a stored enforcing snapshot.

## 9. Proxy protocol and enforcement integration

### 9.1 Startup version 3

For policy-enabled provider actions, add a new startup protocol version, **3 at the inspected baseline**, containing an `authorization` block:

```text
schemaVersion = 1
canonicalizationVersion = 1
instanceID, instanceName, bootID, policyEpoch, proxyGenerationID
policyDigest
policy                 // complete normalized policy, no credentials
```

The existing startup channel separately carries the capability and injected credential. The authorization library must never receive the credential. Do not transport policy through argv, guest headers, environment variables, or a guest-writable file.

The proxy independently decodes, validates, compiles, and checks the digest before becoming ready. It instantiates a single provider-bound limiter. Bound the complete v3 startup document to 128 KiB while retaining existing field-specific credential and capability limits; the policy itself remains limited to 64 KiB. Add version-specific reader/preflight tests rather than relaxing older protocols. Unsupported versions, invalid policy, or mismatched binding fail v3 startup before serving requests.

Extend authenticated readiness for v3 so a host nonce challenge binds the protocol version, boot ID, policy epoch, policy digest, provider, and proxy generation. Reuse the existing readiness-signing machinery, but version the signed payload and its verifier together. Keep any existing network-policy hash distinct from `policyDigest`; neither is a substitute for the other. Policy-enabled networked boots need this authorization readiness binding even when they did not previously request network-policy readiness.

The host must verify readiness before exposing the capability/tunnel to the guest. An older proxy that lacks v3 support is incompatible; never downgrade an enforcing launch to v1/v2. Off-mode launches retain the existing protocol. Shadow mode instruments only proxy paths that existing configuration would already launch; it must not start an otherwise disabled proxy to obtain observations. A missing proxy path is reported as `shadow_unavailable:unsupported_path`. For a legacy companion, shadow mode may retain existing startup behavior only while explicitly reporting `shadow_unavailable:protocol_version`; it must not claim that simulation or enforcement activated.

### 9.2 Request path

In `InboundGate`, retain the existing local readiness exception: a valid readiness challenge is not a provider request and does not consume provider quota. It must remain a fixed local response, never an upstream-forwarding shortcut.

For ordinary requests, use the existing authentication and hard operation/header/framing checks, obtain existing capacity admission, then call the shared provider-batch authorizer before `100 Continue` or forwarding the head. Derive the provider from validated startup config, not the URL or a guest-supplied alias.

If authorization denies, release ordinary capacity leases and close/refuse through the existing response path. No credential-bearing request head or body may reach the upstream. If a request fails after authorization, release ordinary transport resources but retain its rate admission.

| Condition | Guest-visible response |
|---|---|
| Existing capability failure | Existing 401 behavior |
| Policy forbid or no permit | 403, empty/sanitized body |
| Rate guard exhausted | 429; optionally coarse `Retry-After` |
| Missing/unusable enforcing state | 503 or connection refusal; never a fallback forward |
| Existing malformed request / hard restriction | Existing status and behavior |

Do not relax `OperationPolicy`, TLS/upstream selection, framing checks, Seatbelt confinement, or transport capacity limits to accommodate policy.

## 10. Swift module and API contract

### 10.1 Package layout

Add a local package whose only product is a small library:

```text
iso-policy/
  Package.swift
  Sources/IsoPolicy/
    PolicyModel.swift
    PolicyCompiler.swift
    PolicyEvaluator.swift
    PolicyDecision.swift
    SlidingWindow.swift
    ApprovalFact.swift
  Tests/IsoPolicyTests/
    CompilerTests.swift
    DecisionTests.swift
    SlidingWindowTests.swift
    ApprovalTests.swift
    Fixtures/
```

Use the repository's Swift language/toolchain baseline. No third-party package dependency is needed for this library. Foundation and platform-provided hashing/clock facilities may be used through narrow adapters. No dependency on `IsoHost`, `IsoSecrets`, NIO, ArgumentParser, subprocesses, or networking is permitted.

The root package uses `.package(path: "iso-policy")`; `iso-proxy/Package.swift` uses `.package(path: "../iso-policy")`. Both depend only on the `IsoPolicy` library product. This adds shared code, not another runtime process. APIs consumed across these Swift packages require deliberately narrow `public` access; existing root cross-target `package` conventions remain unchanged.

Root integration tests belong under `tests/swift/...`. The new standalone package may use its own ordinary `Tests/` directory. Add its test command to CI and ensure source/release builds include the local dependency.

### 10.2 Required interfaces

The following is an interface sketch, not a complete compiling implementation. Concrete identifier wrappers must validate their values and preserve their trust provenance in the adapters.

```swift
public enum PolicyAction: String, Codable, Sendable {
    case credentialUse = "credential.use"
    case proxyRequest = "proxy.request"
    case workspacePullApply = "workspace.pull.apply"
}

public enum PolicyMode: String, Codable, Sendable {
    case off, shadow, enforce
}

public enum PolicyEffect: String, Codable, Sendable {
    case permit, forbid
}

public enum GuardRequirement: Sendable, Equatable {
    case rateLimit(maxRequests: Int, withinSeconds: Int)
    case approvalWithin(seconds: Int)
}

// Pure: parsing adapters construct a document; compilation validates semantics.
public enum PolicyCompiler {
    public static func compile(_ document: PolicyDocument) throws -> CompiledPolicy
}

// Pure: returns static matches and mandatory guards, without state mutation.
public enum PolicyEvaluator {
    public static func evaluateStatic(
        _ requests: [PolicyRequest],
        policy: CompiledPolicy
    ) -> StaticEvaluation
}

// Synchronization belongs to the proxy adapter, shared across all channels.
// This method must check the whole batch and mutate all quota rings atomically.
protocol ProviderPolicyAuthorizing {
    func checkAndAdmit(_ batch: ProviderRequestBatch) -> PolicyDecision
}

// Host-only adapter: called with the apply lock and checked filesystem handles.
// It verifies the exact receipt and consumes it before returning an allow.
protocol WorkspacePolicyAuthorizing {
    func authorizeAndConsume(
        _ prepared: PreparedStageApply,
        approval: inout HostApprovalReceipt?
    ) throws -> PolicyDecision
}
```

`CompiledPolicy`, `PolicyRequest`, `PolicyDocument`, `StaticEvaluation`, and `PolicyDecision` are shared value types. The provider adapter owns synchronization and its injected monotonic clock. The workspace adapter owns the receipt lifecycle, locks, and filesystem identities. Keep credential values out of all these types.

Avoid an async `decide()` API that separately checks capacity and records success later. The mutation-bearing methods are the authorization boundary. Do not expose receipt creation or history injection over a guest-accessible API. Test constructors/fake clocks must not be selectable by production configuration.

## 11. State and audit

There are only three new state categories:

| State | Owner / lifetime | Recovery |
|---|---|---|
| Policy binding and proxy launch claims | Host-owned versioned state; boot lifetime, retained for current staged return | Missing/corrupt enforcing state denies; uncertain claim remains claimed |
| Rate timestamp rings | Proxy memory; one bound proxy generation | Never restored as empty within the same enforcing boot |
| Approval receipt | Host apply process; one attempt | Exit/failure requires new review; never persisted or reconstructed from logs |

A stage records its instance/boot/epoch binding and policy digest alongside its manifest. Stage metadata is authoritative only after bounded parsing, ownership/path checks, and comparison with host policy state. Guest-origin metadata is not accepted as policy state.

Audit is not the decision-state database. Record policy boot binding, mode, selected actions, proxy generation, policy denials, quota denials, approval issuance/consumption, and apply outcomes. Include sanitized IDs, policy digest, decision ID, reason, and diagnostic timestamps. Do not include secrets, capabilities, approval contents, HTTP bodies, arbitrary headers, or raw hostile paths.

Use `BoundaryAudit` for host operations and the existing host-owned proxy diagnostic path for proxy events. Startup stdout must remain dedicated to its protocol. Per-request diagnostics must be bounded and must not block while the quota lock is held. Best-effort audit loss is reported as degraded diagnostics; it must not alter an authorization verdict or reconstruct authorization state. V1 does not promise a durable record of every request.

## 12. CLI behavior

Extend existing `iso validate` to validate policy syntax, semantics, limits, and enforcing-mode configuration combinations. Diagnostics should identify a bounded field path and rule/guard ID without echoing secrets.

Add one read-only command, proposed syntax:

```bash
iso policy show my-vm --json
```

It reports the active mode, epoch, digest, governed actions, proxy generation/claim status, and whether configured policy differs from the active snapshot. It does not read proxy counters, resolve credentials, mint approvals, or imply that a dead proxy is healthy. Reuse the repository's global machine-output conventions when registering the command.

With a matching workspace approval guard, `--force` does not waive policy confirmation. Noninteractive or machine-output apply without a locally obtained receipt returns `approval_required` before writing anything. Existing argument errors remain usage errors; policy/configuration failures use the existing runtime failure convention. No `--ignore-policy`, `--reset-quota`, or exported approval token is provided.

## 13. Failure contract

| Failure | Required effect |
|---|---|
| Unknown/duplicate policy field, invalid identifier, excessive bounds | Reject configuration; do not partially apply |
| Permit and forbid both match | Deny |
| Unconditional permit overlaps a guarded permit | Matching mandatory guards still apply |
| One action in provider batch denies | No forward and no quota insertion |
| Multiple quotas, only one exhausted | Deny and insert into none |
| Concurrent request at capacity | Exactly the available number admit; no check/insert race |
| Invalid/missing proxy readiness binding | No guest handoff |
| Old companion version | Refuse enforcing launch; no downgrade |
| Proxy crash / uncertain launch | No replacement in that epoch; no raw fallback |
| Config removal during running enforcement | Stored snapshot still applies |
| Changed stage, destination, epoch, or manifest | Reject approval; zero writes before authorization |
| Approval expires at boundary | Deny; exact expiry is not still valid |
| Apply fails partway | Report partial result; consumed approval stays consumed |
| Guest claims an approval, timestamp, or another boot identity | Ignore/reject the claim; it cannot become trusted input |
| Audit output fails | Authorization semantics unchanged; report diagnostic degradation |

## 14. Acceptance tests

### 14.1 Compiler and pure evaluator

Provide table-driven fixtures for default deny, permit, forbid precedence, rule-order independence, action/resource type mismatch, omitted versus empty instance filters, duplicate/unknown keys, invalid numeric forms, limit boundaries, canonical digest stability, and the different `off`/`shadow`/`enforce` outcomes.

A key regression fixture adds an unconditional permit after an approval or rate guard. The guard must still constrain the operation. Another fixture selects only one provider action and verifies that unselected actions remain `not_governed`, not implicitly denied or permitted by the engine.

### 14.2 Temporal and concurrency tests

| Test | Expected result |
|---|---|
| Capacity 100, 101 requests at the same fake time | Exactly 100 allow |
| 1,000 concurrent calls at capacity 100 | Exactly 100 allow across all connections |
| 99 admissions, two concurrent calls | Exactly one additional allow |
| Oldest admission at `t - W` | Expired; capacity available |
| Oldest admission at `t - W + 1 tick` | Still charged |
| Upstream failure after admission | Admission retained |
| Header/capability hard denial | No admission |
| Two guards where the second denies | First guard receives no admission |
| Multiple guest callers sharing provider capability | Same limiter |
| Different provider or different VM boot | Separate bound limiter |
| Host wall clock jumps | No change to monotonic-window decisions |
| Monotonic regression / overflow | Enforcing denial |
| Proxy restart in same enforcing epoch | Refused before new service starts |
| Shadow simulation restart | Existing behavior preserved; reset reported |

Approval tests must cover wrong stage, changed file hash/mode/symlink target, wrong destination identity, wrong instance/epoch, missing receipt, exact expiry, consumed receipt, and duplicate apply. Test that a stopped VM's current-epoch stage can receive a new local approval, while a stage from a superseded epoch cannot.

### 14.3 Integration/security tests

Instrument a test upstream and destination filesystem. Assert zero upstream request bytes on policy denial and zero host destination mutations on approval denial. Cover readiness requests, `Expect: 100-continue`, early disconnects, body failures after admission, and existing proxy capacity cleanup.

Exercise `--force`, noninteractive apply, machine-output apply, `--dir`, direct-pull host APIs, alternate command paths, mixed companion versions, configuration removal, duplicate proxy launch attempts, missing state, and a crash between claim persistence and spawn. Cover root-directory replacement and content changes between review and apply. A partial apply must retain existing diagnostic behavior without restoring the receipt.

Run all existing proxy, workspace, configuration, and confinement regressions. Policy-off compatibility is an acceptance gate, not an assumption.

### 14.4 Resource and build gates

Tests must verify the configured memory bounds, no unbounded history growth, and bounded behavior under denial floods. Benchmark static evaluation and check-and-admit separately from transport; record the machine/toolchain, maximum policy size, and contention level rather than claiming an unmeasured performance number.

Suggested test entry points after the package and test targets exist:

```bash
swift test --package-path iso-policy
swift test
swift test --package-path iso-proxy
```

Run on the repository-supported toolchain/platform and retain its existing integration-script invocations. This specification has not executed those Swift suites or compiled the proposed interfaces.

## 15. Implementation sequence

| Change set | Deliverables | Exit criteria |
|---|---|---|
| 1 — Model and compiler | Local package, strict typed schema adapters, canonicalization fixtures, static evaluator | Pure tests pass; no runtime behavior changes |
| 2 — Boot binding and configuration | `policy` decoding, validation, state versioning, claim lifecycle, `policy show`, example/template updates | Invalid combinations refuse; off behavior preserved; no guest-controlled binding inputs |
| 3 — Proxy shadow path | v3 startup/readiness, one shared limiter, bounded diagnostics | No downgrade; real traffic unchanged; hypothetical results and reset status visible |
| 4 — Provider enforcement | Atomic action-batch admission in `InboundGate`, required-proxy checks, no same-boot replacement | Concurrency, no-forward, raw-fallback, and crash tests pass |
| 5 — Workspace enforcement | Bound stage metadata, inline receipt, host-side apply gate, direct-path refusal | No-force-bypass, drift, epoch, expiry, noninteractive, and partial-apply tests pass |
| 6 — Release gate | Full regressions, bounds/benchmarks, protocol docs, operator docs, source/release packaging | All three actions and both guards complete; remaining limitations documented |

Ship the whole v1 contract before documenting the full example as available. Intermediate builds must reject unsupported configured actions/guards, not silently ignore them. Keep the example and generated configuration template synchronized with the repository's existing template test.[^architecture]

## 16. Definition of done

V1 is complete when the shared library is used by both trusted enforcement adapters; every governed operation intersects existing hard checks with policy; all matching guards are mandatory; concurrent provider requests cannot over-admit; guest data cannot mint identity/history/approval; proxy restart cannot reset an enforcing boot's quota; and a workspace receipt authorizes only one exact, current-epoch mutation attempt.

No new daemon, third-party policy runtime, generic event store, or hidden bypass flag is introduced. Documentation clearly states that quotas count admissions, reset at a new VM boot, and trade same-boot proxy recovery for bounded in-memory state. It also states that approvals require inline trusted-host confirmation and do not provide unattended automation in v1.

## 17. Deferred work and expansion boundary

Revisit upstream Cedar or a separately reviewed richer design before adding entity relationships, arbitrary expressions, cross-host policy, durable cross-boot budgets, reusable remote approvals, or general temporal queries. Supporting proxy restarts without quota resets requires a durable admission ledger or another continuously trusted quota owner; it is not a small retry patch.

A future `network.connect` action must be integrated with the actual egress enforcement component and its existing isolation/readiness model. It cannot be implemented by labeling proxy decisions as network policy.

## 18. Sources and verification scope

Repository observations are pinned to the baseline above. Paths designated as new packages, records, protocol fields, commands, or interfaces are proposals. The repository was inspected through GitHub reads; this document is not a completed code audit, implementation, benchmark, or executed test report.

## 19. Implementation notes

These record decisions the contract left open; they are part of the shipped
behavior.

- **Package and API.** `iso-policy/` exports `IsoPolicy` with
  `PolicyDocument.parse` (strict structure over a neutral `PolicyJSON` tree
  each adapter builds from its own parser), `PolicyCompiler.compile`,
  `PolicyCanonical` (encode, digest, and a decode that requires the exact
  canonical bytes), `PolicyEvaluator.evaluateStatic`, `ProviderAdmissions`
  (pure check-and-admit; the proxy holds it in one `Mutex`), and
  `ApprovalCheck.authorizeAndConsume`. A receipt is consumed on any
  authorization attempt, allowed or not.
- **Clock.** `SystemMonotonicClock` reads `CLOCK_MONOTONIC_RAW`, which keeps
  advancing during host sleep and ignores wall-clock changes. The proxy reads
  it inside the quota lock so samples are ordered with admissions.
- **Host state.** `<instance>/policy-instance.json` holds a stable instance
  ID; `<instance>/policy-binding.json` holds the boot binding and its launch
  claims; `<instance>/.policy.lock` is the instance policy lock (first in the
  apply order); workspace locks live in `<state root>/workspace-locks/` (beside `instances/`) keyed
  by `device-inode`. The boot ID is host-generated (32 hex) per boot, distinct
  from the runtime's filtered-egress boot ID.
- **Startup version 3.** The `authorization` block carries the canonical
  policy as a JSON string (`policy`) so the proxy can require exact canonical
  bytes. `readiness` is mandatory and carries the signing key, plus the
  filtered-egress `bootID`/`policyHash` only on filtered boots. The signed
  reply is `iso-broker-readiness-v3\n{nonce}\n{provider}\n{networkBootID}\n{networkPolicyHash}\n{instanceID}\n{policyBootID}\n{policyEpoch}\n{policyDigest}\n{proxyGenerationID}\n`
  (empty strings for absent network fields). A v3 startup requires `shadow`
  or `enforce` and a policy governing a provider action; otherwise the host
  uses version 1 or 2.
- **Mutation-plan digest.** `iso-stage-plan-v1`: newline-separated records
  of the stage ID, instance, destination, `exclude_git`, the stage's policy
  binding, and each change (path, operation, new object, old object) and
  issue, every string length-prefixed. The creation time is excluded.
- **Confirmation.** The person types the stage ID at `/dev/tty`; stdin and
  stderr must be terminals and machine output must be off.
- **Remote hosts.** Client brokers and workspace returns through `iso host`
  have no boot-bound state on the client, so an enforcing provider or
  workspace policy refuses them with `unsupported_path`; shadow reports
  `shadow_unavailable:unsupported_path`.
- **Where a boot is bound.** `AppleBackend.createAndStart` and
  `startExisting` record the binding before booting, so every start path
  (`up`, `start`, `resize --start`, reprovision, the host service) gets a
  new epoch. An instance with a `policy-instance.json` but no binding has
  lost its state and fails closed.
- **Raw keys.** Session preparation consults the running boot's stored
  binding: an enforcing provider policy withholds provider variables as
  `proxy.mode = "required"` does and refuses `codex.auth = "chatgpt"`,
  whatever the current configuration says.
- **Review rendering.** The approval prompt marks every changed file whose
  diff is not shown (binary, not UTF-8, or over 256 KiB).
- **Mid-boot reconfiguration.** `iso model` re-applying agent configuration
  to a running instance restarts its proxies, which an enforcing boot refuses.
- **Verification.** `tests/integration-policy.py` exercises an enforcing
  policy on a real VM without admitting any provider request; the measured
  benchmark is recorded in [`../testing.md`](../testing.md). Live-provider
  acceptance runs with `tests/integration-proxy-transition.py --live-agents
  --enforce-policy`; on 2026-10-13 Claude Code (`claude-haiku-5-5`) and Codex
  (`gpt-5`) completed tool use through version 3 proxies under an enforcing
  policy.

[^package]: [iso root Package.swift, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/Package.swift).
[^architecture]: [iso architecture, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/ARCHITECTURE.md).
[^config]: [iso configuration example, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/config.example.jsonc).
[^inbound]: [Proxy InboundGate.swift, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-proxy/Sources/IsoProxyTransport/InboundGate.swift).
[^startup]: [Host ProxyStartup.swift, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/Sources/IsoHost/Guest/ProxyStartup.swift).
[^apply]: [WorkspaceStageApply.swift, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/Sources/IsoHost/Workspace/WorkspaceStageApply.swift).
[^review]: [WorkspaceStageReview.swift, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/Sources/IsoHost/Workspace/WorkspaceStageReview.swift).
[^workspace-cli]: [WorkspaceCommands.swift, pinned baseline](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/Sources/IsoCLI/Commands/WorkspaceCommands.swift).
[^cedar]: [Cedar authorization semantics](https://docs.cedarpolicy.com/auth/authorization.html), consulted 2026-10-13. Cedar documents default deny, forbid-overrides-permit, and skip-on-error.
[^dogwood]: [Dogwood README](https://github.com/dogwood-policy/dogwood/blob/main/README.md), consulted 2026-10-13. The project describes Cedar-derived temporal authorization and identifies its interpreter as a reference implementation rather than a production enforcement runtime.
