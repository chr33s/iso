# coop: Selective Sandlock-Inspired Hardening

**Status:** Approved (2026-09-28)  
**Target:** `chr33s/coop` Swift fork (`swift` branch), macOS 27+ on Apple Silicon  
**Scope:** Security features worth borrowing from Sandlock without attempting feature parity or changing coop's VM-first trust model  
**Date:** 2026-09-28

---

## 1. Summary

coop should borrow a small set of Sandlock ideas that strengthen **effects crossing the VM boundary**, while preserving coop's existing model:

> The agent may own the guest. Security controls must bound what leaves the guest, what host authority the guest can exercise, and what host state guest-controlled data can mutate.

The proposed feature set is:

1. **Transactional workspace return** — stage, validate, diff, and explicitly apply guest-authored workspace changes, building on the existing `coop pull`.
2. **Host-enforced egress modes** — add `open` and `none`, gated on a feasibility spike (§6.0); `provider-only` is a preset (`none` + required proxy), not a separate network mode. Consider a generic allowlist only later.
3. **Provider proxy policy** — add a `proxy.mode` setting (`auto` / `required` / `off`) on top of the existing per-(VM, provider), per-boot capability tokens, plus the tests that pin those properties.
4. **Boundary resource budgets** — bound session duration, guest disk growth, logs, and workspace export volume at host-controlled boundaries.
5. **Boundary audit / learn mode** — observe security-relevant boundary use and generate a suggested coop configuration or preset.

This proposal intentionally does **not** add Sandlock-style Landlock/seccomp confinement around agents inside the VM, transparent HTTPS MITM, syscall policy callbacks, chroot/proc virtualization, or a general Sandlock-compatible policy language.

---

## 2. Background

### 2.1 coop's current security model

The Swift fork documents the Linux guest VM as the isolation boundary. The guest is deliberately permissive:

- the guest user has passwordless `sudo`;
- Claude/Codex are normally launched with their internal permission/sandbox checks bypassed;
- the entire VM is treated as the blast radius;
- guest-emitted data becomes untrusted once it crosses back to the host.

The trust model specifically identifies workspace pull/sync as the widest guest-to-host channel because guest-controlled paths, file contents, and symlinks are materialized on the host.

The Apple backend additionally constrains the VM/runtime shape:

- no host mounts (`--mount` / `--extra-mount` are one-time copies on this backend);
- no socket relays;
- no published ports (`--forward-port` is an `ssh -L` bound to host loopback);
- no agent forwarding;
- one VM per instance, each on its own vmnet subnet, held by a per-sandbox
  launchd "owner" process;
- effective runtime configuration is verified before use.

Configuration is JSONC (`~/.coop/config.jsonc`); coop state lives under `~/.coop`.
All configuration examples below use JSONC.

### 2.1.1 Current provider proxy (already implemented)

The credential proxy (`docs/credential-proxy.md`, `ProxyLifecycle.swift`) is
**opt-in and off by default**. Without it, coop forwards raw
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` into the
guest over SSH `SendEnv`. When enabled for a provider:

- the credential comes from a `cmd:` reference (Keychain via
  `coop proxy setup`, or user-supplied), with per-VM overrides in
  `<instance>/proxy.json`;
- coop runs **one `coop-proxy` process per (VM, provider)**, confined by
  Seatbelt, bound to host loopback;
- `ProxyLauncher.start` mints a **fresh 32-byte random capability token on
  every start** and delivers the credential over stdin;
- the guest reaches the proxy through a per-instance `ssh -R` reverse tunnel,
  **not** through guest network egress;
- stop/destroy kills the proxy and tunnel and deletes the token file;
- the proxy default-denies all but the documented model operations and uses a
  fixed per-provider upstream.

### 2.1.2 Current host reachability (accepted by design)

`docs/trust-model.md` accepts that guests reach the host via their NAT gateway
and the host's LAN address, including any host service listening on all
interfaces, and records that **vmnet has no per-network filter**; closing that
path "would need a root-owned `pf` anchor on every Mac."

These are the invariants and constraints this proposal starts from.

### 2.2 Relationship to the Embedded Coop Secrets specification

This specification is **not** the normative design for secret storage, secret resolution, `.env` parsing, `{vault:name}` references, or classification of generic versus provider secrets.

Those responsibilities belong to the companion specification:

> **Specification: Embedded Coop Secrets for the Swift 6 Port**

That specification owns:

- Secure Enclave-bound encrypted secret storage;
- passphrase/KDF/AEAD behavior;
- `coop secrets` lifecycle commands;
- `.env` parsing and secret-reference resolution;
- classification of generic secrets versus provider secrets;
- generic-secret injection into the guest;
- delivery of recognized provider-secret plaintext into `coop-proxy`;
- the invariant that recognized provider secrets do not fall back to raw guest forwarding.

This selective-hardening specification owns only the **authority granted after that handoff**, including:

- provider capability identity and lifetime;
- per-boot capability rotation/binding;
- cross-VM and stale-capability rejection;
- `proxy.mode` policy semantics;
- interaction between provider capabilities and network egress modes;
- non-secret boundary audit metadata.

If the two specifications appear to conflict on secret storage, resolution, classification, or whether a recognized provider secret may enter the guest, the Embedded Coop Secrets specification is normative.

Terminology used here is defined there:

- **recognized provider secret** — Embedded Coop Secrets §31.1: a
  `{vault:}` / `vault:` reference bound to a recognized provider variable or
  proxy credential field. Never enters the guest under any mode.
- **legacy provider value** — Embedded Coop Secrets §31.2: a literal,
  `env_forward`, or automatically forwarded host value of a recognized
  variable. Keeps today's behavior unless this specification's
  `proxy.mode = "required"` applies.

### 2.3 Sandlock ideas being borrowed

Sandlock takes a different approach: it confines a Linux process on the host kernel with Landlock, seccomp, network policy, COW filesystem semantics, credential injection, resource limits, profiles, and a `learn` workflow.

The useful ideas for coop are not the host-kernel confinement mechanisms themselves. The useful ideas are:

- **transactionality** — changes can be inspected before commit;
- **explicit authority** — network and credentials are capabilities rather than ambient access;
- **budgets** — resource use is bounded;
- **observability** — policy can be derived from what a workload actually needed;
- **profiles/presets** — safe configurations are easy to select.

---

## 3. Goals

### G1. Preserve the VM-first trust model

No proposed control may depend on the guest cooperating, because the guest is root-capable and untrusted.

### G2. Reduce damage from prompt injection without requiring a VM escape

A malicious or manipulated agent should have fewer ways to:

- exfiltrate guest-readable data;
- consume host resources without bound;
- convert a normal workspace sync into arbitrary host mutation;
- abuse long-lived host credentials.

### G3. Keep security boundaries comprehensible

The security story should remain explainable as:

1. VM isolates execution.
2. Host-side controls constrain cross-boundary effects.
3. Explicit capabilities grant selected host/external authority.

### G4. Fail closed at security boundaries

If validation, enforcement setup, proxy readiness, or policy compilation fails, coop must refuse the affected operation rather than silently widening authority.

### G5. Avoid feature-parity scope

The proposal should deliver a small number of high-value primitives rather than reproduce Sandlock's full policy system.

---

## 4. Non-goals

The following are explicitly out of scope.

### NG1. No Landlock/seccomp sandbox around the coding agent inside the guest

The guest is intentionally permissive and root-capable. Adding a sound inner process sandbox would introduce a second trust model that must account for privileged helpers, system services, sockets, detached processes, and alternate execution paths.

### NG2. No transparent HTTPS interception as a baseline feature

coop should not add a general TLS MITM proxy to enforce arbitrary HTTP method/host/path policies.

Service-specific host capability proxies are preferred where justified.

### NG3. No general dynamic syscall/policy callback engine

coop should not add a Sandlock-compatible or event-driven policy runtime.

### NG4. No guest-enforced security controls

Guest `iptables`, guest routing tables, environment variables, shell wrappers, or agent configuration may improve ergonomics but must not be considered security boundaries.

### NG5. No full policy language

This proposal uses a small, opinionated config surface. A generic policy DSL is not required.

### NG6. No attempt to make the guest partially trusted

Anything in the guest remains attacker-controlled for host-security reasoning.

---

# 5. Feature 1 — Transactional Workspace Return

**Priority:** P0  
**Borrowed concept:** Sandlock COW / dry-run / commit-abort semantics  
**coop adaptation:** Apply transactionality at the guest→host workspace boundary.

## 5.1 Problem

Workspace pull/sync materializes guest-authored data onto the trusted host workspace.

Even with path-traversal protections, direct application has two security/usability weaknesses:

1. an agent can make destructive but syntactically valid changes;
2. users cannot review the complete proposed host mutation before it happens.

The VM disk is already the disposable execution surface. The important transaction boundary is therefore not inside the guest filesystem; it is **when guest output becomes host workspace state**.

## 5.1.1 Existing `coop pull`

`coop pull [NAME] [--dir DIR] [--force]` exists today (`Workspace.swift`,
`docs/workspaces.md`):

- transport is **rsync with `--delete`** when the guest has rsync, otherwise a
  **tar-pipe** over SSH with end-to-end SHA-256 verification;
- before overwriting, it runs `git status --porcelain` on the destination and
  refuses a dirty tree unless `--force` is given.

Both transports write directly into the destination. rsync cannot validate a
tree before mutating it, so staging changes the transport's **target**, not the
transport:

1. pull (rsync or tar-pipe) into a fresh host staging directory, never into the
   destination;
2. validate and build the manifest from the staged tree (§5.5–5.8), computing
   deletions by comparing the staged tree to the destination rather than
   trusting rsync `--delete`;
3. apply from staging to the destination with coop's own apply code (§5.10).

The existing dirty-tree check still runs before apply. `--force` skips only
that check; it MUST NOT skip stage validation or budgets.

## 5.2 Required behavior

coop MUST support a staged pull flow:

```text
guest workspace
    |
    | untrusted transfer
    v
host staging directory
    |
    +-- structural validation
    +-- safety limits
    +-- manifest
    +-- diff / summary
    |
    +-- apply
    `-- discard
```

Guest data MUST NOT be written directly into the target workspace until validation succeeds.

## 5.3 Proposed CLI

Minimum surface:

```bash
coop diff <vm>                 # new command
coop pull <vm> --review        # new flags on the existing command
coop pull <vm> --apply
coop pull <vm> --discard
```

These are new CLI surface: update `docs/commands.md` and the CLI-surface
baselines (`tests/test-swift-host-cli-surface.py`) with them.

An implementation MAY instead expose explicit stage identifiers:

```bash
coop pull <vm> --stage
coop pull <vm> --apply <stage-id>
coop pull <vm> --discard <stage-id>
```

Exact naming is not normative. The security semantics below are normative.

## 5.4 Staging requirements

The staging directory MUST:

- live under the instance directory (e.g. `<instance>/stages/<stage-id>/`),
  outside the target workspace;
- be owned by the current host user;
- not be reachable through any guest mount;
- use restrictive host permissions;
- be unique per staged operation;
- contain a machine-readable manifest before apply is possible.

The staging extractor MUST treat all guest-provided metadata as untrusted.

## 5.5 Accepted object types

Initial implementation SHOULD allow only:

- regular files;
- directories;
- symbolic links, subject to validation.

Initial implementation MUST reject:

- device nodes;
- FIFOs;
- Unix sockets;
- opaque/special filesystem objects not explicitly supported.

Hard links SHOULD be rejected in v1 unless the apply algorithm gives them explicit, well-tested semantics.

## 5.6 Path validation

For every staged entry coop MUST validate that:

- the logical path is relative;
- no path component is `..`;
- no absolute path is accepted;
- no extraction-time symlink can redirect a later write outside staging;
- no apply-time symlink in the destination can redirect a write outside the target workspace;
- deletion targets resolve to entries within the target workspace only.

Validation MUST be descriptor-relative or equivalently race-resistant where practical. A string-prefix check alone is insufficient.

## 5.7 Manifest

Each stage MUST produce a manifest containing at least:

```text
path
operation: add | modify | delete | type-change
object type
old size
new size
content hash where applicable
symlink target where applicable
```

The manifest SHOULD additionally contain:

- total file count;
- total bytes;
- number of deletions;
- number of type changes;
- largest files;
- generated stage identifier;
- source VM identity;
- source boot generation if available;
- timestamp.

## 5.8 Budgets

Before apply, coop MUST enforce configurable limits:

```jsonc
{
  "workspace": {
    "return": {
      "max_files": 50000,
      "max_bytes": "1GiB",
      "max_file_bytes": "256MiB",
      // optional guardrails
      "review_deletes_over": 20,
      "review_type_changes": true
    }
  }
}
```

These are the **only** workspace-export budget settings; Feature 4 (§8)
does not add a second set.

Exceeding a hard maximum MUST abort staging or mark the stage non-applicable.
The tar-pipe and rsync transports SHOULD also be stopped once the staged tree
exceeds `max_bytes`, so an oversized export cannot fill host storage before
validation runs.

## 5.9 Diff

`coop diff` / `--review` SHOULD show:

- added/modified/deleted file counts;
- byte delta;
- type changes;
- symlink changes;
- textual diff for reasonably sized text files;
- binary-file summary;
- conspicuous deletion summary.

Diff generation MUST NOT execute guest content.

External diff tooling MUST NOT be invoked through a shell with guest-controlled arguments.

## 5.10 Apply semantics

Applying a stage MUST:

1. revalidate the destination root;
2. verify the stage manifest has not changed;
3. use temporary files followed by atomic rename for individual regular files where supported;
4. avoid following untrusted destination symlinks;
5. apply deletions only to validated in-workspace paths;
6. remove or mark the stage consumed after successful completion.

The initial version does **not** need whole-tree atomicity.

If apply fails partway through, coop MUST:

- report exactly which operations were applied;
- retain enough stage metadata for diagnosis;
- never silently claim success.

A future version MAY implement stronger transactionality through a temporary worktree/snapshot mechanism.

## 5.11 Optional mode: always-stage

Config:

```jsonc
{
  "workspace": {
    "return": {
      "mode": "direct" // compatibility; or "stage"
    }
  }
}
```

`direct` is today's `coop pull` behavior, unchanged.

A later release SHOULD consider making `stage` the default for interactive use after sufficient compatibility data.

## 5.12 Security acceptance criteria

Tests MUST cover:

- `../` traversal attempts;
- absolute paths;
- nested symlink escape attempts;
- destination symlink races where testable;
- special-file injection;
- hard-link behavior;
- oversized file/tree rejection;
- delete outside workspace attempt;
- filename edge cases;
- stage tampering before apply;
- apply interruption;
- `--force` skips only the dirty-tree check, never validation or budgets;
- both transports (rsync and tar-pipe) land only in staging.

---

# 6. Feature 2 — Host-Enforced Egress Modes

**Priority:** P0/P1  
**Borrowed concept:** Sandlock deny-by-default / allowlisted egress  
**coop adaptation:** A small number of host-enforced network modes.

## 6.1 Problem

A compromised agent does not need a sandbox escape to exfiltrate data. If the guest has general Internet access, prompt injection can often transmit anything readable inside the VM.

Because the guest has root, guest firewall or routing policy is not a security boundary.

## 6.0 Feasibility prerequisite (Phase 0 spike)

**This feature is blocked on a spike.** The trust model records that vmnet
has no per-network filter and that closing guest→host/LAN reachability "would
need a root-owned `pf` anchor on every Mac." No enforcement mechanism is chosen
yet, and the phase plan (§13) depends on which one works.

The spike MUST evaluate, on macOS 27+ Apple Silicon against the pinned
`apple/containerization` runtime:

1. **Runtime/vmnet mode** — whether `coop-sandbox` can attach a sandbox to a
   vmnet mode without external NAT (e.g. host-only) while keeping host→guest
   SSH working. Preferred: no privileged install, enforced by the runtime
   configuration coop already verifies before hand-out.
2. **Root-owned `pf` anchor** bound to each sandbox's `10.231.N.0/24` subnet.
   Requires a privileged install/uninstall step, must follow subnet
   quarantine/re-addressing after unclean exits, and is itself a trust-model
   change (new root-owned host component) that needs sign-off.
3. **Anything else the runtime exposes** (per-interface filters in the owner
   process, etc.).

Spike output, recorded before Phase 3 (`egress = "none"`) starts:

- chosen mechanism and why;
- how coop **proves** the policy is active (§6.6) from outside the guest;
- whether IPv6 and UDP are covered;
- whether guest→host/LAN reachability (§2.1.2) is closed, narrowed, or
  unchanged under `none`;
- privilege requirements and uninstall behavior.

If no mechanism can be enforced and verified without guest cooperation, this
feature is dropped rather than shipped in a weaker form (NG4).

## 6.2 Config surface

Initial config:

```jsonc
{
  "network": {
    "egress": "open" // or "none"
  }
}
```

Semantics:

### `open`

Current-style general guest outbound network access.

### `none`

The guest has no general external egress.

coop's required management path remains available: host→guest SSH and the
`ssh -R` / `ssh -L` tunnels coop provisions (credential proxy, local-model
tunnels, `--forward-port`). These ride the host-initiated SSH connection and
are not guest egress.

### Why there is no `provider-only` network mode

The credential proxy reaches the guest through an `ssh -R` reverse tunnel over
the host→guest SSH connection, not through guest network egress (§2.1.1). At
the network layer, "provider-only" is therefore identical to `none`. The only
difference is whether a provider proxy is required, which is `proxy.mode`'s
job (§7.5).

"Provider-only" is consequently a **preset** (§10.2):
`network.egress = "none"` + `proxy.mode = "required"`. If the selected
agent/provider cannot operate through the proxy under that preset, startup MUST
fail with an actionable error rather than switching to `open`.

## 6.3 Enforcement requirements

Security enforcement MUST be outside the guest.

Acceptable implementation classes include:

- host-owned network topology;
- host firewall rules bound to a coop-owned interface/address;
- host-owned forwarding/proxy architecture;
- runtime-level networking controls.

The implementation MUST NOT rely on:

- guest `iptables`/`nftables`;
- a guest-maintained route;
- agent cooperation;
- a guest-side proxy environment variable as the only control.

## 6.4 Host reachability

The Swift trust model already documents and accepts guest→host reachability
through the NAT gateway and the host's LAN address, including host services
listening on all interfaces (§2.1.2). coop's own listeners bind loopback and
reach a guest only through SSH tunnels, so they do not depend on that path.

`none` MUST explicitly state whether it changes that accepted reachability. The
answer comes from the §6.0 spike.

Default rule:

> A host service is not reachable merely because it exists. It must be a coop-provisioned capability or a documented required management endpoint.

The implementation SHOULD minimize ambient access to arbitrary host/LAN services.

If platform constraints prevent narrowing host reachability safely in the first release, the existing trust-model entry remains the documentation of record, `none` MUST NOT be described as closing it, and it MUST be tested separately from Internet egress.

## 6.5 DNS

`none` SHOULD not provide arbitrary external DNS resolution unless required by the enforcement architecture. The credential proxy resolves its fixed upstream names on the host, so the guest never needs DNS for provider access.

DNS policy MUST NOT be represented as stronger than the underlying enforcement mechanism.

## 6.6 Failure behavior

If coop cannot prove that the selected egress policy is active, VM startup MUST fail.

Policy setup SHOULD be revalidated:

- on VM start;
- after VM restart;
- before returning a usable connection/launcher when inexpensive.

## 6.7 Generic allowlist: deferred

A future mode MAY be added:

```jsonc
{
  "network": {
    "egress": "allowlist",
    "allow": [{ "host": "github.com", "port": 443 }]
  }
}
```

This is not required for the first implementation.

Before adding it, the design MUST address:

- DNS rebinding / hostname-to-IP changes;
- IPv4 and IPv6;
- QUIC/UDP;
- direct-IP access;
- host/LAN reachability;
- runtime network changes;
- policy application races.

The first release SHOULD prefer `none` (and the provider-only preset built on it), whose semantics are easier to explain and verify.

## 6.8 Explicit non-feature: HTTP path ACLs

Method/path-level policies such as:

```text
POST api.example.com/v1/foo
GET docs.example.com/*
```

are not part of this proposal.

If a specific external service justifies operation-level policy, implement a dedicated capability proxy rather than a generic TLS interception layer.

## 6.9 Security acceptance criteria

Tests MUST demonstrate that:

- `none` blocks arbitrary external TCP;
- `none` blocks arbitrary external UDP where applicable;
- provider traffic still works through the capability proxy under `none`;
- host→guest SSH, `--forward-port`, and local-model tunnels still work under `none`;
- the documented guest→host/LAN reachability behaves exactly as §6.4 states;
- policy survives/reapplies across VM restarts;
- failure to install enforcement fails closed;
- IPv6 cannot bypass a policy intended to cover all egress;
- guest root cannot disable the host-side policy.

---

# 7. Feature 3 — Provider Proxy Policy

**Priority:** P1  
**Borrowed concept:** Sandlock credential injection / capability-oriented authority  
**coop adaptation:** Add an explicit `proxy.mode` policy on top of the existing capability proxy, and pin its existing capability properties with tests; do not define a second secret-storage or secret-routing system.

## 7.1 Normative dependency

Secret storage, secret resolution, provider-secret classification, and delivery of provider plaintext into `coop-proxy` are specified by:

> **Specification: Embedded Coop Secrets for the Swift 6 Port**

This section MUST NOT redefine those mechanisms.

In particular:

- a recognized provider secret remains host-side;
- provider plaintext is delivered only to the trusted host-side proxy path;
- a provider secret MUST NOT be reinterpreted as a generic guest secret merely because proxying is disabled or unavailable;
- no automatic fallback may expose a recognized provider credential to the guest.

The purpose of this feature is narrower: define the **guest-facing capability** that authorizes use of an already-configured provider proxy.

## 7.2 Problem

The capability itself is already narrowly scoped (§7.4). What is missing is
**policy**:

- the proxy is opt-in, and when it is off coop forwards legacy provider
  values raw into the guest, with no way to demand otherwise;
- there is no setting that makes "the proxy must be used, or fail" explicit;
- the existing capability properties are true by construction but not pinned
  by named tests, so a refactor could silently regress them.

## 7.3 Capability requirements

These requirements are **already met** by the current implementation and are
restated so tests can pin them. For supported provider proxies:

- the upstream provider credential MUST remain on the host as required by the Embedded Coop Secrets specification;
- the guest receives only a coop capability token plus required proxy endpoint configuration;
- a capability MUST identify one VM instance;
- a capability MUST be limited to one provider;
- the proxy MUST use a fixed upstream selected by coop, never a guest-supplied upstream destination;
- upstream credentials MUST NOT appear in guest environment, argv, files, instance state, or staged workspace content.

## 7.4 Capability lifecycle (existing behavior)

The current design binds the capability structurally rather than through a
shared token table:

| Property | How it holds today |
|---|---|
| Cryptographically random | `ProxyLauncher.start` mints `randomHex(32)` per start |
| Bound to one VM | One `coop-proxy` process per VM; each knows only its own token and is reachable only through that VM's `ssh -R` tunnel |
| Bound to one provider | One process per (VM, provider), fixed upstream per process |
| Bound to one boot | A new token is minted on every start; stop/destroy kills the process and deletes the token file |
| Reuse within a boot | Later sessions of the same running boot read the current token file |

Consequently "a capability from VM A used against VM B", "provider A's token
used for provider B" and "an old-boot token after restart" are rejected
because the other proxy never learned that token (or no longer exists). No
proxy-side VM/provider/generation table is required, and none SHOULD be added
unless the one-process-per-(VM, provider) design changes.

New work in this area is limited to:

- **Optional expiry** — the host MAY pass an `expires_at` in the stdin
  startup document; the proxy then rejects the token after that time. This
  requires a `coop-proxy` protocol version bump.
- **Regression tests** for every row above (§7.9).

A capability may be stored in guest state because it grants only the explicitly intended proxy authority, not the upstream provider credential.

## 7.5 Proxy policy modes

Add one field next to the existing `proxy.anthropic` / `proxy.openai` objects:

```jsonc
{
  "proxy": {
    "mode": "auto", // or "required" | "off"
    "anthropic": { "credential": "cmd:…", "auth": "api_key" }
  }
}
```

The default is `auto`, and `auto` is defined so that **existing configurations
keep their current meaning** (§14.4).

Normative semantics (terms from §2.2):

### `auto` (default, compatible)

- A provider with a configured proxy credential (config default, per-VM
  override, or recognized provider secret) runs through the proxy, as today.
- A **recognized provider secret** never falls back to raw guest forwarding;
  if its proxy cannot start, startup fails.
- **Legacy provider values** for a provider with no proxy are forwarded raw,
  exactly as today, with a warning.

### `required`

- Every provider the selected agents use MUST have a proxy credential and a
  running proxy; otherwise startup fails closed.
- No recognized provider variable reaches the guest by any path: legacy
  literals, `env_forward` entries and automatic host forwards of recognized
  names are refused with an error naming the variable (not its value).
- If the proxy cannot be initialized, confined, or connected safely, startup
  fails closed.

### `off`

- No provider proxy is started.
- A recognized provider secret is **unavailable**: startup fails with an
  error rather than forwarding it, converting it to a generic secret, or
  treating it as a literal.
- Legacy provider values behave as today without a proxy (raw forwarding).
  This is an explicit user choice of the pre-proxy behavior, not an automatic
  downgrade.

If a user intentionally wants a secret to be guest-visible, that must use the
explicit **generic-secret** mechanism defined by the Embedded Coop Secrets
specification.

A future release MAY change the default to `required`; that is a
security-tightening default change and needs release notes and migration
guidance (§14.4).

`proxy.mode` also applies only in remote model mode; `coop model <vm> local`
continues to take precedence and tear the proxy down, as today.

## 7.6 Interaction with network modes

`network.egress` and `proxy.mode` are orthogonal: the proxy path does not use
guest egress (§6.2).

- `egress = "none"` + `proxy.mode = "required"` is the provider-only preset.
- `egress = "none"` + `proxy.mode = "auto"` is valid; a provider without a
  proxy simply has no network path (its legacy value, if forwarded, is
  useless and SHOULD produce a warning).
- `egress = "none"` + `proxy.mode = "off"` is the offline preset; a workflow
  that needs a remote provider SHOULD fail at startup with an actionable error.

No combination may silently widen network egress to compensate for an unavailable provider proxy.

## 7.7 Audit metadata

The proxy MAY emit **boundary metadata** such as:

```text
timestamp
VM identity
boot generation
provider
operation class
HTTP status
request byte count
response byte count
```

It MUST NOT log by default:

- upstream credentials;
- resolved secret values;
- capability tokens;
- request bodies;
- response bodies.

This metadata is not a secret-store authentication/activity log. It records use of a cross-boundary capability after secret resolution.

## 7.8 GitHub credentials

A host-side GitHub capability is attractive but is **not** part of the initial feature.

Git and `gh` have broader protocol/behavioral requirements than the model-provider proxy.

A future GitHub design should be a dedicated project with explicit support boundaries rather than a generic "proxy arbitrary authenticated HTTP" abstraction.

## 7.9 Security acceptance criteria

Tests MUST verify:

- upstream provider credential is absent from guest environment;
- upstream provider credential is absent from guest files and persisted guest state;
- a recognized provider secret never falls back to raw guest forwarding in `auto`, `required`, or `off`;
- `required` refuses legacy literals, `env_forward` entries and automatic forwards of recognized variables;
- `auto` with no proxy configuration forwards legacy values exactly as today (compatibility);
- capability from VM A cannot be used by VM B (pins existing behavior);
- capability from provider A cannot authorize provider B (pins existing behavior);
- old-boot capability is rejected after restart (pins existing behavior);
- expired capability is rejected, when expiry is enabled;
- guest cannot select an arbitrary upstream host;
- `required` fails startup when safe proxy initialization fails;
- `off` makes provider-secret-backed credentials unavailable rather than guest-visible;
- the provider-only preset never widens to general egress when proxy setup fails;
- logs never contain provider secrets or capability tokens.

Add a fault to `scripts/swift-host-fault-injection.py` for the new `required`
refusal path (e.g. dropping the legacy-value check) that a test detects.

---

# 8. Feature 4 — Boundary Resource Budgets

**Priority:** P1/P2  
**Borrowed concept:** Sandlock resource limits  
**coop adaptation:** Enforce budgets on resources visible outside the guest.

## 8.1 Rationale

A compromised guest can intentionally exhaust resources without escaping the VM.

Per-process guest limits are low-value because guest root can often evade or reconfigure them.

Host-controlled VM and transfer budgets remain meaningful.

## 8.2 Proposed budgets

Config MAY support:

```jsonc
{
  "limits": {
    "session_ttl": "8h",
    "max_log_bytes": "256MiB"
  }
}
```

Workspace-export budgets are configured only under `workspace.return` (§5.8).

Existing VM CPU/memory settings remain the primary compute budget. Guest disk
size is already fixed at creation (`--disk`, `vm.template_size_gib`); see §8.6.

## 8.3 Session TTL

When a hard TTL is configured:

- coop MUST track it outside the guest;
- expiry MUST stop the VM/session according to documented semantics;
- guest clock changes MUST NOT affect enforcement.

### Enforcer

`coop` is a short-lived CLI; there is no coop host daemon. The only long-lived
host process per VM is the sandbox **owner**, a launchd job started by
`coop-sandbox start` that holds the VM. TTL enforcement therefore belongs in
the runtime:

- `coop up` / `coop start` passes the deadline (host wall-clock time,
  computed on the host) to `coop-sandbox`, which records it in the sandbox
  record;
- the owner process stops the VM when the deadline passes;
- expiry MUST unload the launchd job (or mark the sandbox expired) so launchd's
  crash-restart does not simply reboot the VM;
- every `coop` command that hands out a connection also checks the deadline
  and refuses an expired instance, so enforcement does not depend solely on the
  owner being alive at the deadline.

Host sleep counts toward the TTL (wall-clock, not monotonic). `coop start` of
an expired instance starts a new TTL window only if the user explicitly
restarts it; document this.

An interactive warning before expiry MAY be provided but is not security-relevant.

## 8.4 Log/output budget

Host-side captured output SHOULD have a maximum retained size. Today this
means the per-sandbox console and owner logs under `~/.coop/runtime/`
(streamed by `coop logs`) and coop's own diagnostics.

On overflow, coop SHOULD:

- continue execution where safe;
- truncate or rotate according to a documented rule;
- surface that truncation occurred.

An attacker must not be able to fill host storage through unbounded stdout/stderr capture.

## 8.5 Workspace-export budgets

Feature 1 limits are the normative enforcement point for guest→host file transfer.

Budget checks MUST happen before applying staged data to the trusted workspace.

## 8.6 Guest disk budget

The guest disk is a fixed-size ext4 image set at creation (`--disk`), which
already bounds guest-visible capacity. What is not bounded is host-side growth
of that image file if it is sparse. If the runtime exposes a reliable
host-controlled bound on that growth, coop SHOULD surface it.

If the underlying runtime does not provide a robust host-side limit, coop MUST NOT emulate one with guest filesystem quotas and claim equivalent security.

## 8.7 Security acceptance criteria

Tests SHOULD cover:

- TTL expiration independent of guest clock;
- bounded log storage under unbounded output;
- workspace export limit failure;
- disk limit behavior where supported;
- clear cleanup behavior after termination.

---

# 9. Feature 5 — Boundary Audit / Learn Mode

**Priority:** P2  
**Borrowed concept:** `sandlock learn`  
**coop adaptation:** Observe cross-boundary authority use, not syscalls.

## 9.1 Goal

Help users discover which coop capabilities a workflow actually uses so they can choose a narrower preset/config without manually understanding every channel.

## 9.2 Proposed CLI

```bash
coop audit <vm>                    # new command
coop audit <vm> --suggest-config
```

`coop audit` does not exist today; it is new CLI surface (update
`docs/commands.md` and the CLI-surface baselines). There is no `coop run`
command; an audit-while-running wrapper is out of scope for this proposal.

## 9.3 Events to record

Audit SHOULD focus on security-relevant boundary events:

### Network

- attempted/allowed outbound destination where observable;
- whether access used general egress or a coop proxy;
- denied attempts where enforcement provides them.

### Credentials

- credential class requested;
- provider proxy used;
- GitHub credential forwarding enabled/disabled;
- arbitrary forwarded environment variable names, but not values.

### Host capabilities

- reverse tunnels created;
- local-model capability used;
- host-side proxy used.

### Workspace return

- staged file count;
- staged byte count;
- add/modify/delete/type-change counts;
- apply/discard result.

### Resources

- session duration;
- peak/allocated VM memory if available;
- log bytes;
- workspace-export bytes.

## 9.4 What must not be recorded

Default audit logs MUST NOT contain:

- credential values;
- resolved secret values;
- capability tokens;
- request/response bodies;
- complete source file contents;
- arbitrary guest environment values.

Boundary audit MUST NOT become a secret-store authentication or access-history subsystem.

The Embedded Coop Secrets design intentionally has no secret-store auth log. Boundary audit records only the use of host/VM capabilities after configuration and secret resolution. It SHOULD record events such as "VM X used the Anthropic proxy" rather than "secret Y was unlocked/read."

## 9.5 Suggested config output

`--suggest-config` MAY emit a JSONC fragment such as:

```jsonc
{
  "network": { "egress": "none" },
  "proxy": { "mode": "required" },
  "workspace": {
    "return": { "mode": "stage", "max_files": 10000, "max_bytes": "200MiB" }
  },
  "limits": { "session_ttl": "4h" }
}
```

The fragment is printed to stdout for the user to merge; `--suggest-config`
MUST NOT edit `~/.coop/config.jsonc` itself.

Suggested config MUST be advisory.

A learning run does **not** prove that an observed set of capabilities is semantically complete for all future runs.

The output SHOULD carry a warning to that effect.

## 9.6 Security acceptance criteria

Tests MUST verify that:

- audit logging never contains known test secrets;
- capability tokens are redacted;
- suggested config is deterministic for a fixed event set;
- unknown/new event types do not silently widen generated permissions.

---

# 10. Security Presets

**Priority:** P2  
**Purpose:** Make the narrow configuration easy to select.

Presets SHOULD compose the primitives above rather than add new enforcement logic.

Suggested presets:

## 10.1 `networked`

Compatibility-oriented.

```text
general egress: yes
provider proxy: auto
workspace return: direct or stage according to global default
```

## 10.2 `provider-only`

Recommended for remote-model coding tasks that do not need package/network access after bootstrapping.

```text
network.egress: none
proxy.mode: required
workspace return: stage
```

## 10.3 `offline`

For local models / fully pre-provisioned environments.

```text
network.egress: none
proxy.mode: off
github: off
workspace return: stage
```

Possible CLI (new flag on `up` / `start`):

```bash
coop up --security networked
coop up --security provider-only
coop up --security offline
```

Preset expansion SHOULD be inspectable. There is no `coop config` command
today; either add `coop config explain --security <preset>` as new surface, or
reuse `coop up --dry-run --json`, which already prints the resolved plan, by
including the expanded security settings in it. Prefer the latter (no new
command).

Presets that need `network.egress = "none"` are available only once Feature 2
ships.

Explicit config values MAY override a preset if the precedence rules are simple and visible.

Security-sensitive overrides SHOULD be shown in startup diagnostics.

---

# 11. Configuration Sketch

This is illustrative, not a frozen schema.

```jsonc
// ~/.coop/config.jsonc (excerpt)
{
  "security": { "preset": "provider-only" },
  "network": { "egress": "none" },
  "proxy": {
    "mode": "required",
    "anthropic": { "credential": "cmd:…", "auth": "api_key" }
  },
  "workspace": {
    "return": {
      "mode": "stage",
      "max_files": 50000,
      "max_bytes": "1GiB",
      "max_file_bytes": "256MiB",
      "review_deletes_over": 20
    }
  },
  "limits": { "session_ttl": "8h", "max_log_bytes": "256MiB" }
}
```

New fields MUST be added in the same change to `CoopConfig` decoding and
validation, `ConfigTemplate`, `config.example.jsonc` and
`docs/configuration.md`.

Design rule:

> Prefer a small set of orthogonal enums and budgets over a general policy grammar.

---

# 12. Trust-Model Changes

The trust model should be updated with these explicit invariants.

## 12.1 Workspace staging invariant

> Guest-authored workspace data is untrusted until staged, structurally validated, and applied through the workspace-return path. Stage creation must never mutate the destination workspace.

## 12.2 Egress invariant

> When `network.egress != "open"`, enforcement is host/runtime-owned. No guest-controlled configuration is sufficient to establish or widen the effective policy.

The existing "Guests can reach host services — accepted by design" entry is
updated to say whether `none` changes it (§6.4).

## 12.3 Provider capability invariant

> Provider-secret storage, resolution, classification, and plaintext handoff to `coop-proxy` are governed by the Embedded Coop Secrets specification. A recognized provider secret never falls back to guest injection. Guest authority is represented only by a capability accepted by exactly one fixed-upstream host proxy process per (VM, provider), minted fresh on every start. Under `proxy.mode = "required"`, no recognized provider variable reaches the guest by any path.

## 12.4 Budget invariant

> Security-relevant limits are measured/enforced by the host/runtime or at a host-controlled transfer boundary, not by guest policy.

## 12.5 Audit invariant

> Audit data is host-owned metadata. It must not become a new channel for secrets or unbounded guest-controlled content.

---

# 13. Implementation Order

## Phase 0 — Egress feasibility spike (can run in parallel with Phase 1)

Deliver the §6.0 findings: mechanism, verification method, IPv6/UDP coverage,
host/LAN reachability outcome, privilege requirements. Phase 3 does not start
until this is recorded and, if it introduces a root-owned component, signed
off as a trust-model change.

## Phase 1 — Transactional workspace return

Deliver:

- staging directory, with the existing rsync / tar-pipe `coop pull`
  transports retargeted into it;
- manifest;
- structural validation;
- file/byte budgets;
- `coop diff` and apply/discard;
- comprehensive malicious-path tests.

Reason: directly hardens the widest documented guest→host channel and requires no networking redesign.

## Phase 2 — Provider proxy policy

Deliver:

- `proxy.mode = auto|required|off` with the compatible `auto` semantics of §7.5;
- integration with the Embedded Coop Secrets provider-secret path;
- regression tests pinning the existing per-(VM, provider), per-boot capability properties;
- optional capability expiry (proxy protocol bump) if wanted.

Reason: small, independent of networking, and a prerequisite for the
provider-only preset.

## Phase 3 — `egress = "none"` (gated on Phase 0)

Deliver:

- host/runtime-enforced external egress denial using the Phase 0 mechanism;
- proof/check that enforcement is active;
- restart behavior;
- IPv4/IPv6 tests;
- provider proxy, local-model tunnels and `--forward-port` verified working under `none`;
- trust-model update for host-local reachability.

Reason: simple semantics and high security value. With Phase 2 done, this
also delivers the provider-only configuration (`none` + `required`).

## Phase 4 — Resource budgets

Deliver:

- session TTL enforced by the sandbox owner (§8.3);
- bounded host logs;
- guest disk growth bound if the runtime provides a strong primitive.

Export budgets ship with Phase 1.

## Phase 5 — Boundary audit + presets

Deliver:

- event schema;
- `coop audit`;
- `--suggest-config`;
- `offline` / `provider-only` / `networked` presets and their `--dry-run --json` expansion.

## Deferred — Generic network allowlist

Only implement after experience with `none` and the provider-only preset demonstrates a clear need.

---

# 14. Cross-Feature Requirements

## 14.1 Fail closed

The following must be startup/operation failures, not warnings:

- selected egress policy cannot be installed or verified;
- `proxy.mode = "required"` cannot initialize safely;
- stage validation fails;
- a hard workspace budget is exceeded before apply;
- runtime security verification fails.

## 14.2 No hidden downgrade

coop MUST NOT silently change:

```text
none -> open
proxy required -> guest credential forwarding
provider_secret -> generic guest secret
stage -> direct
stage validation/budgets skipped by `coop pull --force`
```

A user may explicitly choose a weaker network/workspace mode where the relevant specification permits it, but automatic security downgrade is prohibited. `--force` on `coop pull` keeps its current meaning (skip the destination dirty-tree check) and nothing more.

Provider-secret classification is not a downgradeable mode: intentionally guest-visible credentials must be declared through the generic-secret path defined by the Embedded Coop Secrets specification.

## 14.3 Diagnostics

Startup SHOULD summarize effective security-relevant state, e.g.:

```text
Security:
  VM isolation: verified
  Network egress: none
  Provider credentials: host proxy (required)
  Workspace return: staged
  Session TTL: 8h
```

The summary MUST NOT print secrets or capability tokens.

## 14.4 Compatibility

Where possible, existing config should continue to mean current behavior. Concretely: a config with no `proxy.mode`, `network`, `workspace.return` or `limits` fields behaves exactly as today (`proxy.mode = "auto"` with legacy raw forwarding when no proxy is configured, `egress = "open"`, `workspace.return.mode = "direct"`, no TTL).

Security-tightening defaults may be introduced only with clear release notes and migration behavior.

---

# 15. Testing Strategy

## 15.1 Unit tests

Cover:

- config parsing/precedence;
- manifest generation;
- path validation;
- capability validation;
- budget parsing;
- audit redaction;
- preset expansion.

## 15.2 Integration tests

Use adversarial guest payloads for:

- path traversal;
- symlink traversal;
- special files;
- huge trees;
- arbitrary external network attempts;
- IPv6 bypass;
- direct-IP access;
- proxy misuse;
- stale/cross-VM capabilities;
- log flooding.

## 15.3 Security regression tests

Any bug that crosses a documented boundary MUST receive a regression test.

The trust model should point reviewers to these suites.

## 15.4 Platform qualification

Because the Swift fork supports macOS 27+ / Apple Silicon, network-control acceptance tests MUST run on the actual supported backend rather than relying only on mocks.

---

# 16. Telemetry and Privacy

No product telemetry is required by this proposal.

Local audit records should be:

- opt-in or explicitly invoked;
- stored under coop's state directory;
- permission-restricted;
- bounded in size;
- redactable/deletable by normal file removal.

Do not transmit audit data to a remote service as part of this feature.

---

# 17. Rejected Alternatives

## 17.1 "Run Sandlock inside every coop VM"

Rejected as the baseline design.

Reasons:

- duplicates isolation concepts;
- conflicts with broad/root guest autonomy;
- materially increases policy complexity;
- does not improve the core VM escape boundary;
- risks users confusing inner policy with host isolation.

It may still be useful for individual advanced users inside a guest, but coop should not depend on it.

## 17.2 "Use guest firewall rules for egress"

Rejected as a security boundary because guest root can modify them.

## 17.3 "Mount the host workspace read/write and rely on COW"

Rejected because the Swift Apple backend deliberately has no host mounts. Adding one would materially weaken the current boundary. (The `--mount` / `--extra-mount` flags remain for compatibility but are one-time copies on this backend, not live mounts.)

## 17.4 "Generic TLS MITM proxy"

Rejected for initial scope because certificate injection, TLS edge cases, QUIC, application compatibility, and proxy parsing create substantial attack surface.

## 17.5 "Give every external service a generic credential-forwarding API"

Rejected because credential semantics are service-specific. Prefer narrow explicit capability proxies.

---

# 18. Success Metrics

The project is successful if, without reducing agent autonomy inside the guest:

1. a normal workspace return can be inspected before host mutation;
2. a malicious guest cannot reach arbitrary Internet destinations under `egress = "none"`;
3. no recognized provider variable enters the guest under `proxy.mode = "required"`;
4. runaway guest output and workspace export cannot consume unbounded host storage;
5. users can understand effective cross-boundary authority from one security summary;
6. the implementation does not introduce a second comprehensive sandbox policy engine.

---

# 19. Concise Security Principle

The intended long-term model is:

> **Let the agent own the guest. Make every effect that crosses the guest boundary explicit, bounded, host-enforced, and reviewable.**

That principle should guide future feature review more strongly than Sandlock feature parity.

---

# 20. Source Notes

This proposal was derived from the current project documentation as of 2026-09-28.

Companion normative specification:

- **Specification: Embedded Coop Secrets for the Swift 6 Port** — normative for local secret storage, resolution, generic/provider classification, and plaintext provider handoff into `coop-proxy`.

External/current project sources:

- `chr33s/coop` Swift trust model:  
  https://github.com/chr33s/coop/blob/swift/docs/trust-model.md
- Sandlock repository / feature overview:  
  https://github.com/multikernel/sandlock
- Sandlock `learn` RFC/background:  
  https://github.com/multikernel/sandlock/issues/72

Key observed facts used by this proposal:

- coop's VM is the intended isolation boundary and the guest is deliberately permissive;
- guest filesystem data crossing back to the host is treated as tainted, with workspace pull/sync identified as the widest guest→host channel;
- the Swift Apple backend verifies a runtime shape with no host mounts, socket relays, published ports, or agent forwarding;
- coop already has an opt-in host-side provider proxy (one process per VM and provider, fresh token per start, reached over `ssh -R`) that keeps supported model API keys out of the guest (`docs/credential-proxy.md`, `ProxyLifecycle.swift`);
- vmnet has no per-network filter; guest→host/LAN reachability is accepted by design (`docs/trust-model.md`);
- `coop pull` uses rsync `--delete` or a verified tar-pipe directly into the destination (`docs/workspaces.md`);
- Sandlock exposes COW/dry-run semantics, network controls, credential injection, resource limits, profiles, and a `learn` workflow.

