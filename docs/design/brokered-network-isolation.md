# Brokered network isolation

**Document ID:** ISO-NET-001  
**Version:** 1.0  
**Date:** 16 October 2026  
**Status:** Implemented as the opt-in `network.transport: "brokered"`; natively qualified on one tuple only, with open items. Sections 1–13 are the specification; [section 14](#14-implementation-status) records what was built and what is qualified.  
**Sequence:** Implement and qualify this specification before Spec 02 (iso-ci).  
**Repository baseline:** `chr33s/iso` at `d27752a7fd1b1731c8dd700e2e9457c119e2fc2e`.  
**Primary users:** Coding agents, interactive shells, workspace tools, sandboxed editors, and users of enrolled remote Macs.

## 1. Decision and intended outcome

Add an opt-in **brokered** transport: Linux guest VMs have no external network interface, while existing SSH-based features operate over VM-bound Virtio-socket streams. Reuse iso's provider and egress brokers through explicitly authorized channels. Retain the existing vmnet transport as an explicit compatibility mode.

This is a standalone iso feature. It requires no CI companion, GitHub App, runner registration, workflow compiler, scheduler, or CI service.

The promised property is:

> Untrusted guest code cannot create a direct IP path to unrelated services on the Mac, sibling VMs, the LAN, or the tailnet. Host interaction and external communication are available only through explicitly authorized, bounded channels enforced outside the guest.

This is **not** a claim that the hypervisor or brokers cannot have vulnerabilities, that guest-produced results are trustworthy, or that an approved remote service cannot be used to receive data. An explicitly authorized local-model endpoint is an intentional exception, not unrestricted host access.

This specification supersedes the implementation ordering and alternative selection in the earlier network-isolation amendments: preserve SSH; change its underlying transport; do not implement a PF/Network Extension subsystem or GitHub-specific functionality in this phase.

## 2. Scope and non-goals

### Included

- NIC-less Linux guests on qualified Apple-silicon Macs, locally and through iso's existing enrolled-host transport.
- Pinned SSH, shell/exec, bounded file transfer, staged workspace returns, agent sessions, and supervised access to sandboxed editors.
- Existing provider-credential isolation and approved public HTTPS CONNECT egress.
- Explicit local-model bridges and loopback-bound development previews.
- Boot/session identity, capability revocation, resource limits, effective-state inspection, compatibility negotiation, and native security qualification.
- Preserving interactive workspaces on communication failures whenever safely possible.

### Excluded

- GitHub Actions semantics or any requirement to install `iso-ci`.
- A general Swift TCP/IP stack, transparent NAT, arbitrary TCP/UDP forwarding, or TLS interception.
- Host-wide PF rules, root firewall helpers, and Network Extension deployment.
- Automatic conversion of existing VMs or silent changes to existing security presets.
- Equivalent support for macOS guests: qualify their distinct runtime/helper path separately.
- Claims of protecting the guest from the trusted host administrator or preventing every possible exfiltration through an approved service.

## 3. Baseline to preserve

The inspected repository separates `iso`, `iso-sandbox`, `iso-proxy`, and `iso-egress`. Its host/session machinery already owns SSH, workspaces, editor confinement, and local/remote lifecycle operations. Reuse those boundaries rather than create a second remote daemon or a new application protocol for each feature.[^n1]

The baseline treats guest root as untrusted, rejects general host shares and arbitrary socket relays, and explicitly accepts host-service reachability through vmnet. Current `egress: none`, `filtered`, `provider-only`, and `offline` settings therefore do not establish the new transport guarantee.[^n2][^n3]

The runtime currently creates a vmnet interface and includes it in container configuration and live state. Removing that dependency requires code and schema changes. Apple documents NIC-less VM configuration and Virtio sockets, while OpenSSH supports a stream supplied by `ProxyCommand`; these are feasibility inputs, not proof that the pinned Containerization integration already implements the design.[^n4][^n5][^n6][^n7]

## 4. Architecture

### 4.1 Local management: retain SSH

```text
iso shell / exec / workspace tools
                  |
          pinned OpenSSH client
                  |
       fixed iso-owned stream connector
                  |
       authorized per-instance stream endpoint
                  |
       runtime-owned Virtio-socket connection
                  |
       guest SSH stream adapter -> guest sshd

Guest VM configuration: no externally connected NIC
```

The stream connector MUST select the destination from trusted runtime/session state. Its interface is a byte stream to one authorized guest SSH service, not a request to connect to an arbitrary host, port, file, or administrative socket.

The guest adapter may forward a fixed guest vsock port to guest-loopback `sshd`. It is not trusted for host-side enforcement: guest root can replace it or the SSH server. Keep host-key pinning and treat every byte returned by the guest as untrusted.

Prefer a host-initiated connection to the fixed guest endpoint. If the pinned runtime requires a different connection direction, N0 must document and qualify equivalent host-side admission. Do not infer authorization from a guest-reported context ID or instance name.

### 4.2 Remote management: replace only the last hop

```text
Client Mac
   | existing authenticated management SSH / optional Tailscale
Enrolled worker Mac
   | existing host service, access session, owned guest relay
VM-bound Virtio-socket stream
   |
Guest SSH service
```

Preserve existing host, owner, instance, boot, generation, operation, and lease semantics. Tailnet visibility does not enroll a worker. Do not introduce a guest Tailscale client, public listener, or separate registry.

### 4.3 Provider and public egress

```text
Guest agent / proxy-aware application
        |
Guest-local endpoint
        |
Static reverse tunnel over the authorized SSH connection
        |
Per-session host-side broker
        +--> iso-proxy: fixed provider operations; host-held credentials
        +--> iso-egress: approved public HTTPS destinations
        +--> explicit local-model bridge, when separately authorized
```

The SSH client owns a finite set of static forwards with fixed destinations. No dynamic reverse proxy, SOCKS endpoint, agent forwarding, or guest-selected host target is permitted. Test the SSH forwarding configuration against a malicious server, not just a cooperative guest.

A guest can ignore or replace its proxy configuration. Doing so MUST NOT create an external uplink. The guest's adapter configuration is convenience, not enforcement.

### 4.4 Editors and previews

Keep any bridge needed by a sandboxed editor outside the editor sandbox. Expose only a supervised loopback connection to the selected guest and retain the editor's separate ephemeral key and limited filesystem/network grants. The editor MUST NOT obtain the general runtime socket or the ability to invoke privileged management commands.

A preview is an operator-authorized host-loopback listener forwarding to a fixed service inside the selected guest. It is not permission for guest-originated host connections. A browser or editor consuming guest-controlled content remains a separate security boundary; do not weaken its existing protections.

## 5. Security requirements

| ID | Mandatory requirement |
|---|---|
| NET-01 | Construct the VM without an external NIC before any guest-authored boot code executes. No temporary bootstrap NIC. |
| NET-02 | Derive the effective transport proof from the actual host-owned VM configuration and channel registry, not a requested mode string or guest report. |
| NET-03 | Bind every access stream to host, owner, instance, boot, generation, purpose, policy digest, session, and expiry. Reuse of a display name grants no authority. |
| NET-04 | Audit all framework/runtime vsock endpoints, including existing guest-agent services. No unexpected listener may become a route to host commands, files, sockets, or another VM. |
| NET-05 | Host commands, executable paths, socket paths, credentials, and network grants come from operator-controlled state. Project files and guest output cannot select them. |
| NET-06 | Keep SSH host-key pinning, bounded control protocols, secret handling, staged-return validation, and editor confinement. Private transport does not replace authentication. |
| NET-07 | Provider and public-egress capabilities are distinct. A model capability cannot become a general network capability. |
| NET-08 | Revocation closes existing authorized streams and prevents new ones. A stale descriptor, boot identity, bearer, or daemon epoch cannot authorize a replacement VM. |
| NET-09 | Broker, adapter, controller, or network failure never causes a NIC attachment or a weaker policy fallback. |
| NET-10 | Limit stream count, request size, buffered bytes, connection rate, output, and lifetime outside the guest. Reserve capacity for stop and cleanup. |
| NET-11 | Report compatibility failures explicitly. Unsupported runtime versions, profiles, and required capabilities cause refusal before workload release. |
| NET-12 | Trusted public-egress policy rejects worker-local and prohibited private destinations; explicit local-service bridges are separately named and visible. |

The trusted computing base includes the Mac OS/hypervisor, iso runtime and host service, selected broker implementations, administrator configuration, and approved worker administrators. A process split alone is not confinement. Document the OS restrictions and privileges of each network-capable companion.

## 6. Runtime and client contracts

Names in this section were proposed contracts; [section 14](#14-implementation-status) gives the names as implemented. Preserve current wire versions for existing behavior. Any incompatible effective-configuration or runtime change requires a new negotiated version; do not make older readers guess.

### 6.1 Immutable network policy

Introduce a typed transport choice:

```text
VMTransport
  vmnet(existing network configuration)
  brokered(BrokeredNetworkPolicy)

BrokeredNetworkPolicy
  schema                  = iso.network/v1
  provider_grants         = approved named provider capabilities
  public_egress_profile   = optional administrator-approved profile + digest
  local_service_grants    = explicit named services; empty by default
  limits                  = stream, traffic, connection, and lifetime budgets
  fallback                = forbidden
```

Resolve grant references on the trusted side into a canonical policy snapshot. Bind that snapshot to the boot. A workflow or guest may request less authority, never more. Grant widening requires explicit operator authorization and a new boot/session policy transition; an in-flight job cannot edit its policy file.

### 6.2 Effective boot proof

Expose these fields through the authenticated host interface:

| Field | Meaning |
|---|---|
| `host_id`, `owner_id`, `instance_id` | Authoritative ownership identities |
| `boot_id`, `generation`, `service_epoch` | Current boot and restart/revocation boundaries |
| `transport` | `brokered` or existing explicit networked mode |
| `external_nic_count` | Must be zero for this contract |
| `network_policy_digest` | Digest of the effective immutable policy |
| `channel_policy_digest` | Digest of approved runtime/SSH stream endpoints |
| `runtime_build`, `runtime_protocol` | Qualified runtime identity |
| `qualification_id` | Matching native qualification record |
| `health`, `lease_expires_at`, `vm_expires_at` | Live readiness and independent hard limits |

Required safety fields must be present and recognized. Separate extensible metadata from security-critical configuration; unknown host-facing configuration fails closed. For brokered guests, IP-address fields are absent or explicitly nullable under a versioned representation. Never insert a fake gateway to satisfy legacy code.

A serialized proof is an observation, not a reusable access credential. Revalidate the current boot at handoff. A qualification record establishes supported builds; it does not replace per-boot verification.

### 6.3 Guest stream operations

The narrow stream seam needs operations equivalent to:

```text
openGuestSSH(qualifiedInstance, boot, session, policyDigest) -> bounded duplex stream
closeGuestStreams(session) -> verified closure result
inspectNetwork(qualifiedInstance) -> current effective boot proof
```

These reuse the host service's authorization, not a new guest-callable administrative API. An implementation can use private descriptors/sockets plus a typed preamble. It MUST validate peer identity, ownership, current lease, and descriptor provenance before handing out a stream.

A generated SSH alias invokes a verified iso connector with validated nonsecret identifiers. Never embed bearers in `ProxyCommand` arguments, let a repository choose an executable, or leak diagnostics onto the SSH byte stream. Support EOF, half-close where required, cancellation, bounded backpressure, and process-group cleanup.

## 7. Broker behavior

### 7.1 Reuse existing controls

The baseline `iso-egress` policy admits exact approved hostnames on port 443. Its public connector resolves afresh, validates address choices, and dials numerically rather than performing a second hostname lookup. Preserve these properties; this phase changes transport, not the meaning of approved network authority.[^n8][^n9]

### 7.2 Required destination checks

For public CONNECT egress:

- Authenticate the job/session capability before attempting an upstream connection.
- Normalize and authorize the hostname and port; reject IP-literal tricks and unsupported encodings.
- Validate all candidate DNS answers, including mixed public/private answers; resolve on the trusted side and connect to the validated numeric address.
- Reject loopback, link-local, private, multicast, special-use, local-interface, and prohibited tailnet destinations in both address families; handle mapped/transition forms conservatively.
- Recheck the connected peer and applicable host-address/policy snapshot. Treat routing/interface changes as a revalidation event.
- Require separate authorization for each new CONNECT target, including a target reached after an application redirect.
- Allow operator-denied public addresses/domains for known NAT hairpins and public aliases of private services. A globally routable address alone is not proof of an external destination.

A blind CONNECT tunnel does not inspect HTTP semantics or prove that an approved server will not relay traffic elsewhere. The contract is destination/capability enforcement, not comprehensive information-flow control. Document this residual risk instead of claiming universal prevention of indirect access.

Broker code accepts hostile input and must remain bounded and confined. Keep provider credentials only in the provider broker, not in the public CONNECT service. Startup secrets travel over protected local channels; no request or credential body goes into diagnostics.

### 7.3 Explicit local services

A local-model grant resolves to a fixed host-side endpoint from administrator configuration. The guest sees only its capability and guest-local endpoint, never a generic host destination selector. Deny unrelated local ports even while this grant is active. Show the grant in effective policy and audit records; enforce service-specific authorization and resource budgets.

### 7.4 Application and Docker compatibility

Guest-local services and Docker networks may operate without an external VM NIC, but external pulls and dependency downloads require configured proxy paths. Configure guest applications, Docker daemon, containers, and builds individually. A container's loopback is not the guest VM's loopback; expose a job-local proxy endpoint on a selected guest-internal bridge where needed.[^n10]

Qualification covers named tool/version combinations. Proxy-incompatible applications fail explicitly. Git-over-SSH, arbitrary UDP, LAN discovery, and unrestricted private endpoints are not included in this HTTPS-focused release.

## 8. Lifecycle and failure semantics

### 8.1 Boot and handoff

1. Validate supported runtime, administrator policy, resources, and immutable image identity.
2. Reserve instance ownership and cleanup capacity before side effects.
3. Construct and inspect the NIC-less VM shape and approved vsock endpoints.
4. Boot; establish pinned guest SSH through the new stream adapter. The guest is untrusted from boot, including before workload launch.
5. Establish only selected brokers and static tunnels; prove confinement, identity, and policy readiness.
6. Release the workload session only after the composite proof succeeds.
7. Revalidate on each new access handoff and supervise existing grants using host-owned deadlines.

### 8.2 Failure policy

| Failure | Required behavior |
|---|---|
| Guest adapter exits or refuses SSH | Session unavailable; no alternate network connection. Preserve workspace disk. |
| Public/provider broker dies | Its authority stops working; close affected streams and mark required sessions unhealthy. Never send the real provider key to the guest as fallback. |
| Host relay/session closes | Revoke that access grant; no resurrection of old descriptors. |
| VM hard deadline expires | Stop independently of guest cooperation. Preserve or delete disk according to the owning workload's declared retention policy. |
| Worker sleeps/reboots | Expired grants stay expired. Reconcile boot/epoch before reconnecting; no automatic trust in an old alias. |
| Policy changes or is revoked | Close affected streams, refuse further access under the old digest, and require explicit reauthorization. |
| Guest helper wedges during stop | Use the runtime-owner termination path; do not rely solely on guest shutdown commands. |
| Runtime/transport unsupported | Refuse before boot or workload release, not a downgraded `vmnet` start. |

The absence of a NIC supplies the direct-network property continuously; periodic health checks do not create it. Capability revocation and stopping have bounded implementation delays, which must be measured and documented. A watcher polling every few seconds is not an instantaneous revocation claim.

Interactive iso defaults to preserving disk state and reporting interruption where possible. A CI caller may later select a finite destructive lifecycle, but this specification does not make disposable CI behavior the default for developer workspaces.

## 9. Configuration, migration, and diagnostics

Illustrative configuration for a **new supported build**:

```jsonc
{
  "network": {
    "transport": "brokered",
    "policy": "approved-development"
  },
  "egress": "filtered"
}
```

`network.transport` is implemented; the named `policy` is not (see [decisions](#decisions-and-deviations-from-the-spec)). In brokered mode, `egress: none` disables general public CONNECT access; separately selected provider/local-service capabilities remain explicit. `egress: filtered` requires an approved broker policy. `egress: open` is invalid with `transport: brokered`; it cannot secretly mean unrestricted networking.

The existing configuration semantics remain unchanged unless the operator explicitly chooses the new transport. Continue to disclose host-service reachability for existing vmnet guests.[^n3]

Initial migration creates a fresh brokered VM from an approved image and transfers workspace data through existing validation/staging. Do not change the topology of a running VM. Moving an old writable disk into the new mode, if implemented later, is a separate explicit conversion with schema, rollback, identity, and boot tests.

Rollback means selecting a supported old build for compatible old state, or explicitly recreating an environment with a clearly disclosed weaker mode. An older binary must refuse state it cannot safely interpret. Never silently attach a NIC because a downgrade cannot read the new transport.

Status and machine output must distinguish:

- Requested profile versus effective transport and policy digest.
- Stopped, running/ready, unhealthy, and unknown/unreachable observations.
- Authorized local-service exceptions versus denied general host access.
- Unsupported capability versus workload failure.
- Session interruption versus data deletion or verified VM termination.

## 10. Implementation work packages — in order

| Package | Main implementation | Completion gate |
|---|---|---|
| **N0 — Feasibility** | Prove NIC-less boot and a VM-bound duplex stream against the pinned Containerization/kernel stack. Audit existing vsock endpoints. | Pinned SSH, one command, bounded file transfer, cancellation, and forced stop work without any bootstrap NIC. Document required upstream changes, if any. |
| **N1 — Types and proof** | Add immutable transport/policy types, effective shape, schema negotiation, and refusal paths. | Tests reject hidden NICs, stale boot identities, unsupported versions, and unknown host-facing configuration. |
| **N2 — SSH transport** | Implement runtime stream endpoint, connector, guest adapter, and access/relay integration. | Shell, exec, SSH pinning, transfer, signal/EOF handling, ownership, and resource limits pass locally. |
| **N3 — Agent and editor parity** | Carry provider tunnels, explicit local-model grants, staged workspace return, preview, and sandboxed-editor bridge. | At least one supported agent and one sandboxed editor pass end to end; all other combinations are explicitly qualified or reported unsupported. |
| **N4 — Approved egress** | Reuse CONNECT policy over static tunnels; wire proxy-aware tools and guest-local Docker. | Named package/image download cases pass; broker bypass, private DNS, and host-target attempts fail. |
| **N5 — Remote and failure parity** | Replace the relay's worker-to-guest hop, preserve leases and recovery, test worker lifecycle and load. | Two physical Macs, lost connections, restarts, sleep/wake, stale sessions, and destructive guest behavior preserve the contract. |
| **N6 — Release and handoff** | Publish operator docs, capability schema, evidence manifest, migration/refusal tests, and stable transport/client seam. | Every release-blocking test below passes on each claimed tuple; completion manifest supplies the Spec 02 prerequisites. |

The first shipping target is Linux ARM64. Qualification records must name the exact OS build, iso/runtime build, kernel/image digests, relevant broker versions, and qualified application combinations. Do not turn a test on one tuple into blanket support for every macOS/runtime release.

No CI implementation is a dependency of N0–N6.

## 11. Release-blocking acceptance tests

Run tests with guest root and deliberately malicious guest services. Keep host-side observations; guest-reported success is not evidence of enforcement.

| Test ID | Test and pass condition |
|---|---|
| **N-T01** | Effective configuration has zero external NICs before boot, after restart, and on every supported restore path. A malicious boot image cannot transmit over a temporary attachment. |
| **N-T02** | Host canaries on gateway/LAN/tailnet/public/IPv6 addresses receive no unauthorized guest traffic. Independent authorized positive controls prove each listener was actually reachable. |
| **N-T03** | Guest route/address changes, raw sockets, spoofing, privileged Docker, and host-network Docker cannot create an external uplink. |
| **N-T04** | Attempts to use arbitrary vsock ports, runtime services, administrative endpoints, or another VM's streams are denied. Include stock framework listeners. |
| **N-T05** | A malicious SSH server cannot turn static forwards or connector inputs into arbitrary host connections or host execution. |
| **N-T06** | Old session bearers, keys, boot IDs, epochs, and descriptors cannot authorize a replacement VM or another owner. |
| **N-T07** | Pinned shell/exec, binary file transfer, staged returns, cancellation, partial writes, and bounded logging work correctly. |
| **N-T08** | Provider agent and approved local-model use work without disclosure of host-held provider secrets. Broker death does not enable direct credentials or an uplink. |
| **N-T09** | Sandboxed editor and preview work without widening editor authority or host listener exposure. Unsafe editor mode is never selected implicitly. |
| **N-T10** | Public CONNECT denies local/private targets, mixed DNS answers, rebinding, alternate IP forms, and known hairpin aliases. Allowed destinations still work. |
| **N-T11** | Docker daemon, selected containers/builds, and chosen package managers use only approved paths; unsupported protocols fail explicitly. |
| **N-T12** | Two-Mac relay, disconnect, reboot, sleep/wake, broker failure, and worker-service restart preserve fencing and no-fallback behavior. |
| **N-T13** | Stream floods, malformed frames, oversized output, and disk pressure remain within host budgets and do not prevent stop/cleanup. |
| **N-T14** | Guest-root refusal to halt cannot extend execution beyond the externally enforced deadline and documented bounded stop grace. |
| **N-T15** | Requested versus effective policy, unknown/unreachable state, exceptions, revocation, and refusal are represented correctly in machine output and audit. |
| **N-T16** | Existing vmnet workflows retain their documented behavior; migration and downgrade cannot silently weaken a brokered guest. |

A skipped native test is `blocked`, not `passed`. A missing listener, unresolvable hostname, or disabled positive control cannot count as an isolation pass.

## 12. Deliverable consumed by Spec 02

N6 publishes **NET-HANDOFF-1**, containing:

1. A supported way for an authenticated local/remote client to request a brokered Linux VM under an administrator-approved policy.
2. The effective boot proof fields from section 6, with live revalidation at access handoff.
3. VM-bound SSH streams, bounded workspace/result transport, revocation, and independent stop/deadline behavior.
4. The exact broker profile schema and the ability to request no provider or local-service grants.
5. Guest-local Docker/proxy compatibility evidence for the selected base image, or explicit limitations to be resolved before CI claims that feature.
6. Capability/version discovery and fail-closed unsupported-profile errors.
7. Native qualification results keyed by build/platform/image tuple, including N-T01–N-T16.
8. Operator installation, upgrade, migration, and recovery documentation.

**Discovery (implemented).** A client asks `host.capabilities` on `iso.host/v1`
(local or remote). `net-handoff-1` is listed only while all of these hold, and
is otherwise absent (fail closed): `network.transport` is `brokered`, the
runtime is qualified and advertises `brokered-transport`, and the
qualification report is `qualified`. The result also carries
`network_handoff.run_policies`: per egress mode (`none`, `filtered`), the
brokered policy a fresh `vm.create`/`run.create` VM boots with — its digest
(the `network_policy_digest` a running boot's `vm.inspect` proof reports),
public egress, provider grants, local services and channel digest. A
`filtered` run VM's every boot starts and proves the worker's `iso-egress`
companion before the start succeeds (otherwise the VM is stopped), so the
advertised `filtered` policy is usable through host control. A fresh
host-control VM has no per-VM proxy override, recorded environment or model
choice, so its grants come from the worker's configuration (`proxy`
upstreams, configured local models); a client that needs no grants checks the
published lists and refuses otherwise. The runtime gate still proves every
boot; the advertised policy is not a substitute for that proof.

The qualification report reads an operator-installed evidence manifest,
`<data_dir>/backends/apple-container-v1/host-control/qualification/net-handoff-1.json`
(schema `iso.qualification/v1`, a regular file owned by the service user and
writable by no one else). It names the tuple — `host_os`, `iso_version`,
`runtime`, `transport`, `image` (`<name>@<image manifest digest>`),
`guest_kernel`, `broker` — and N-T01–N-T16, each of which must be `passed`
(no case may be `not-applicable`: a skipped or unavailable case is blocked).
Status is `missing` (absent, unreadable, malformed or incomplete), `mismatch`
(the host's live `host_os`, `iso_version`, `runtime` or `transport`, or the
named image's current manifest digest, differ), `expired` (`expires_at`
passed) or `qualified`. `guest_kernel` and `broker` are recorded but
operator-attested: the host does not re-derive them per call. `tuple.image` must be
`<image name>@sha256:<64 lowercase hex>`, the image manifest digest. A manifest
whose `expires_at` is more than 365 days after `recorded_at`, or whose
`recorded_at` is more than 300 seconds ahead of the host clock, is invalid
(`missing`), as is any path that is not a regular file (a FIFO is refused
without blocking). The evidence covers that one image only: while
`net-handoff-1` is listed, `network_handoff.qualified_image`
(`{"name": ..., "digest": "sha256:<hex>"}`) names it, and a client binds a VM
to it by sending that name and `image_digest` (bare hex) in `run.create`;
admission refuses a digest the worker image does not have. Other images on the
same host are not covered by this evidence. Record evidence
with `scripts/record-net-handoff-evidence.py --results RESULTS.json`, which
refuses incomplete results and installs the manifest (default 90 days, at most
365). Rebuilding the qualified image, updating iso or the runtime, or changing
the macOS version makes the report `mismatch` until new evidence is recorded.

Spec 02 may add workload-neutral execution receipts or a public client-only package. It MUST NOT bypass this proof, implement its own network stack, or weaken a failed request into a networked VM. CI-specific endpoint profiles and runner conformance belong to Spec 02.

## 13. Risks and decision gates

- **Runtime feasibility:** N0 must prove the pinned guest kernel, Containerization APIs, and framework socket topology support the required stream. If not, record the necessary upstream/internal change and keep the feature blocked; do not insert a hidden NIC.
- **Broker compromise:** Brokers remain host-side attack surfaces. Parser testing, operating-system confinement, restricted privileges, and credential separation are required, not optional consequences of using Swift.
- **Compatibility:** Preserving SSH preserves an application protocol, not every assumption in the current implementation. Editors, tunnels, connection reuse, DNS, and proxy configuration need their own fixtures.
- **Scope expansion:** Do not build general networking, CI, or a plugin ABI to finish the first agent milestone.
- **Future filtering:** PF/Network Extension can be considered in a separate spec when ordinary IP networking is essential. Apple does not treat PF as a supported product API; this is one reason it is not the foundation here.[^n11]

## 14. Implementation status

Implemented from baseline `d27752a`. This section says what was built, how
each mandatory requirement is met, and what has and has not been qualified.
Native results were observed on **one tuple** (see
[Qualification record](#qualification-record)); they are not a support claim
for other macOS, runtime or kernel builds.

### What ships

An opt-in transport, `"network": {"transport": "brokered"}`
([configuration](../configuration.md#network)). A brokered instance's Linux VM
has **no network device**. Every SSH-based feature keeps working because only
SSH's last hop changes: ssh's `ProxyCommand` is the runtime's fixed stream
connector, and the runtime owner opens a Virtio-socket stream to the guest's
SSH adapter for each admitted request. The vmnet transport is unchanged and
remains the default.

```text
iso shell / exec / push / pull / agents / tunnels / editor bridge
        |
pinned OpenSSH client (StrictHostKeyChecking, HostKeyAlias <machine>.iso)
        |  ProxyCommand = iso-sandbox connect --root R <id> --boot B
        |                 --channel-policy C --network-policy N
owner stream socket (0600, per-user 0700 dir, getpeereid)
        |  admit: boot B live, C == runtime policy, N == boot's policy,
        |         purpose "ssh", limits
LinuxContainer.dialVsock(2222)  (host-initiated)
        |
guest iso-ssh-vsock.socket (Accept=yes) -> sshd -i

VM configuration: interfaces = []  -> VZVirtualMachine.networkDevices == 0
```

#### Runtime (`iso-sandbox`)

- `NetworkMode.brokered` (`create --network brokered`): no subnet is
  allocated; the owner builds `LinuxContainer.Configuration.interfaces = []`,
  no DNS, `/etc/hosts` maps the hostname to `127.0.1.1`.
- **NIC-less proof before guest code (NET-01, NET-02).** `LinuxContainer.create()`
  boots the VM into the framework's init only; the guest's `/sbin/init` runs at
  `start()`. Between the two, the owner reads the live
  `VZVirtualMachineInstance.vzVirtualMachine` device inventory on the VM
  queue (`VMDevices`) and stops the VM unbooted unless it has `0` network
  devices and `1` socket device, no console, memory-balloon, USB or graphics
  device, and at most the one virtio-fs device `apple/containerization`
  always attaches, carrying an empty `VZMultipleDirectoryShare` (or no
  share). The same check, with one vmnet network device, runs for vmnet
  sandboxes. The brokered counts are reported in the effective configuration
  (`networkDevices`, `socketDevices`).
- **Fixed channel policy.** `ChannelPolicy.current` (`iso.channels/v1`): one
  endpoint (`ssh` → guest vsock port 2222, host-to-guest), 64 streams, 64
  admissions per 10 s, 4 KiB request line, 10 s setup timeouts, 64 KiB per
  direction. Its sha256 over the sorted-key JSON is reported as
  `channelPolicyDigest`.
- **Stream broker** (`StreamBroker`): a second private Unix socket per brokered
  owner. One JSON request line names a purpose (never a port), the boot id, the
  channel-policy digest, the boot's network-policy digest and an optional
  session label. Admission checks all of them and the limits before dialing the
  guest; refusals never reach the guest. At most 128 connections (twice the
  stream limit) are handled at once, so stalled clients cannot exhaust threads
  before admission applies. Admitted streams are relayed with one
  bounded buffer per direction and EOF forwarded as a write shutdown
  (half-close). `streams list` reports and `streams close [--session S]`
  revokes (a closed session's in-flight and later requests are refused too);
  a halt closes all and refuses new ones. The request line must arrive within
  10 s in total.
- `start --network-policy <64 hex>` records the boot's network-policy digest in
  the record (cleared by a start without it; refused for vmnet sandboxes).
- `connect` is the ProxyCommand: request, reply line (read byte by byte so no
  stream byte is consumed), then stdin/stdout splice; diagnostics on stderr.
- Advertised as the `brokered-transport` feature on protocol 5. Every new
  effective field is present **only** for brokered sandboxes, so vmnet output
  is byte-for-byte unchanged and an older host (strict decoding) refuses a
  brokered report instead of guessing.

#### Guest adapter

`iso setup` images install `iso-ssh-vsock.socket` (`ListenStream=vsock::2222`,
`Accept=yes`, `MaxConnections=64`) and `iso-ssh-vsock@.service` (`sshd -i`,
stdin/stdout on the socket, **stderr to the journal**). The manifest records
`guest_adapters: ["vsock-ssh-v1"]`; committed images inherit it from their
source image. The adapter is convenience, not enforcement (spec 4.1): guest
root can stop it, which makes SSH unavailable and nothing else.

#### Host (`iso`)

- `IsoConfiguration`: `network.transport` (`vmnet` | `brokered`), unknown
  members rejected; `transportConflict` refuses `egress: open` from the file
  or a CLI override. Presets do not select the brokered transport.
- `BrokeredTransport.swift`: the host's own copy of the expected channel policy
  and its digest; `BrokeredNetworkPolicy` (`iso.network/v1`: transport,
  `fallback: forbidden`, public egress profile + allowlist + egress hash,
  provider grants with an effective broker, local services iso tunnels in,
  channel digest) and its canonical digest; `GuestRoute`/`BrokeredRoute`;
  `BrokeredConnector` (route-safe ProxyCommand/argv); `BrokeredView` (status).
- `IsolationGate`: `Expected.transport`/`networkPolicy`; the record must name
  the expected transport; a brokered effective configuration must report
  `transport: brokered`, `0`/`1` devices, no interface or address, exactly
  iso's channel policy and digest, and the boot's network-policy digest. A
  vmnet report carrying any brokered field is refused. `Ready` carries the
  route.
- `NetworkPolicy` record: schema 3 unchanged for vmnet; schema 4 only for
  brokered, holding the transport, the boot's resolved policy and its digest,
  cross-checked against the egress half. Saved before create, and after a
  restart only once the new boot passes the gate. `enforceMode` refuses a
  transport change; `enforce` refuses a configuration that resolves to a
  different brokered policy (`POLICY_CHANGE_REQUIRES_RESTART`).
- `AppleLifecycle`: brokered creates refuse (before any record or VM) an
  `egress: open` conflict, a runtime without the feature, an image without the
  adapter or a macOS image, and a connector path ssh would re-parse. Boots pass
  `--network-policy`; SSH targets come from the gate's route.
- `WorkloadHandoff`/`SessionSupervisor`: brokered handoffs have a live proof,
  so prepared sessions recheck before spawning and `iso`-launched workloads are
  re-proved every 10 s and ended after two consecutive failures (a restart is a
  new route; a changed policy fails `enforce`).
- Remote hosts: `AppleNativeHost.guestEndpoint` returns the connector argv from
  a fresh gate pass for a brokered VM, and `GuestConnector` spawns it in place
  of `/usr/bin/nc <address>`. Worker-side records are scoped to the VM's
  recorded transport. `vm.inspect`/`vm.list` carry the boot's network proof
  (`NetworkProof`, from the same gate pass), shown by `iso host vm inspect`.
- Output: `iso status NAME` text names the transport, digests, egress, brokers
  and local services; `status --output json` adds `network` for brokered
  instances only; `capabilities` adds static `network_transports`
  ([machine interface](../machine-interface.md#status)).

### Requirement mapping

| ID | How it is met | Evidence |
|---|---|---|
| NET-01 | `interfaces = []`; owner checks the live VM's devices after `create`, before the guest's init; no bootstrap NIC exists in the code path. | `brokered` phase N-T01 (also after restart); host gate tests |
| NET-02 | The gate trusts only the owner's live-device reading and iso-computed digests; a mode string alone never passes. | `gateRefusesEveryWeakeningOfTheBrokeredShape`, `hostChannelDigestEqualsTheRuntimesOwn` |
| NET-03 | Streams bind boot id, channel digest, network-policy digest and purpose at the owner; the boot's policy digest covers transport, egress, provider and local-service grants; the remote relay keeps host/owner/instance/boot/generation/session/lease fencing. Display names grant nothing. | N-T06 checks; `admissionChecksBootPolicyPurposeAndSession`; relay tests |
| NET-04 | One fixed host-to-guest endpoint; no host-side listener routes to commands/files/sockets; framework stdio/copy listeners are transient. Guest probes of host CID ports and sibling CIDs. | `brokered` phase N-T04 |
| NET-05 | The connector executable/root are the resolved, ownership-checked runtime; all other arguments are validated identifiers from host state; refused if shell-unsafe. | `brokeredTargetRunsOnlyTheFixedConnector`; fault `brokered-connector-route-safe` |
| NET-06 | Host-key pinning, `BatchMode`, no agent forwarding, staged-return validation and editor confinement are unchanged above the transport. | existing suites; `brokered` phase SSH checks |
| NET-07 | Provider brokers and public CONNECT remain separate processes and tunnels; each is a separate grant in the policy; `egress: open` is invalid. | `networkTransportDecodesAndRefusesOpenEgress` |
| NET-08 | Halt closes and refuses streams; `streams close` revokes; a restart changes the boot id; supervision ends `iso` workloads on a changed route or policy; relay revocation kills the connector. | N-T15/N-T06 checks; `aBrokeredHandoffIsSupervisedAndRefusesAReplacementBoot`; `relayCarriesABrokeredGuestThroughTheConnector` |
| NET-09 | No code path attaches a device; failures leave sessions unavailable. | `brokered` phase NET-09 checks |
| NET-10 | **Partial.** Owner-side stream count, handler count, admission rate, request size and deadline, dial timeout and buffer size; control socket separate from the stream socket. No per-stream byte cap or lifetime beyond the boot's session deadline. | N-T13 checks; `admissionBoundsConcurrencyAndRate`, `handlerSlotsAreBounded`, `aTricklingRequestLineStopsAtTheDeadline` |
| NET-11 | Feature, image adapter, guest OS, egress and path checks refuse before a VM exists; unknown effective fields refuse. | `runtimeCallsCarryTheBrokeredArguments`, `brokeredInstancesNeedAnImageWithTheGuestAdapter` |
| NET-12 | The existing `iso-egress` destination checks are unchanged; local models must be host loopback and are named, visible services. | `aLocalModelOffTheHostLoopbackIsRefused`; existing egress suites |

### Work packages

| Package | Status |
|---|---|
| N0 — Feasibility | **Done on this tuple.** NIC-less boot and a host-initiated VM-bound duplex stream work with the pinned Containerization 0.45.0 and kernel without upstream changes. Required change: none upstream; the guest needs the vsock adapter (shipped in the image recipe). |
| N1 — Types and proof | **Done.** Types, effective shape, feature negotiation, schema-4 record and refusal paths, with unit tests and fault-injection entries. |
| N2 — SSH transport | **Done locally.** Runtime endpoint, connector, guest adapter, gate and SSH target integration; native shell/exec/transfer/EOF/exit-status/forward/limits checks pass. |
| N3 — Agent and editor parity | **Done on this tuple.** Credential-proxy tunnels, agent bootstrap, staged return, previews and the editor transport ride the unchanged SSH path and pass natively on brokered VMs: `tests/integration-proxy-transition.py --brokered` runs both agents through their credential proxies with synthetic credentials, and the `iso` phase checks the managed alias and the sandboxed editor's tunnel. A sandboxed Zed ran end to end (N-T09), and both agents completed live tool use with dedicated keys on a brokered VM (N-T08). |
| N4 — Approved egress | **Done on this tuple.** Filtered CONNECT is reused over its reverse tunnel. Guest sessions carry it as their proxy (curl, pip, npm and other proxy-aware tools); filtered boots also point the Docker daemon, the guest user's Docker client and containers on the default bridge at it, and set git to send proxy credentials up front. `apt` run through `sudo` does not inherit the session proxy and is not wired; images install their packages at build time. |
| N5 — Remote and failure parity | **Done on this tuple.** The relay's last hop is replaced. `tests/integration-remote-host.py --brokered` passes every case through this Mac's host service (`--local`), through this Mac as its own SSH worker (`--loopback`), and against a second Mac over real management SSH (`--remote`): enrollment, the worker VM's brokered shape and the client-side network proof, relay round trip, session revocation, workspace push and staged pull, remote agents with no provider credential in the guest, a management-link cut, a worker-service restart, VM deadlines with an offline client and a wedged guest, host sleep/wake, and (`--remote`) a reboot of the worker Mac. |
| N6 — Release and handoff | **Done on this tuple.** Operator docs, schema, the remote proof (item 2), Docker/proxy evidence with its stated `apt` limitation (item 5) and native results for N-T01–N-T16 (item 7) are in place; see the [qualification record](#qualification-record) and the items that are [not release-blocking](#open-items-before-claiming-net-handoff-1). |

### Acceptance tests

`passed` means observed natively on the tuple below by
`tests/integration-apple-sandbox.sh` (phases `brokered` and `iso`) unless
marked *unit*. A test not run is `blocked`, never `passed`.

| Test | Status | Notes |
|---|---|---|
| N-T01 | passed | Live VM: 0 network / 1 socket devices, no interface or address, before and after restart; restore paths share the boot code but were not separately run. |
| N-T02 | passed | Canaries on 0.0.0.0/:: with host positive controls on 127.0.0.1, the LAN address and ::1; guest probes of loopback, vmnet gateways, 192.168.64.1, 100.100.100.100, 1.1.1.1 and IPv6 targets over TCP, ICMP and DNS all fail and no canary sees a connection. |
| N-T03 | passed | Guest-made dummy devices, addresses and routes create no uplink. On a brokered VM with filtered egress (which lets Docker pull an approved image), a privileged host-network container runs, sees only loopback and the Docker bridge, and after giving the bridge its own address and a default route still reaches nothing; the guest kernel has no dummy or veth support for a new device. |
| N-T04 | passed | No host CID port (1–1024 and service ports) or sibling CID is reachable from guest root; unknown purposes and forged channel digests are refused; the stream socket is owner-only. |
| N-T05 | passed | `tests/brokered_malicious_ssh.py`: a paramiko server stands in for a hostile guest `sshd` behind iso's SSH option set and a ProxyCommand. The granted static reverse forward reaches only its broker; an unrequested forwarded port, server-initiated `direct-tcpip`, agent and X11 channels are refused, and a host canary sees no connection. Run with paramiko 5.0.0 and the system OpenSSH. |
| N-T06 | passed | Stale boot ids, other network-policy digests and the previous boot's connector line are refused; *unit*: a prepared session refuses a replacement boot. |
| N-T07 | passed | Command, 8 MiB binary round trip, stdin EOF/half-close, exit status; `iso` phase covers copy and pull. |
| N-T08 | passed | Synthetic: `tests/integration-proxy-transition.py --brokered` bootstraps Claude Code and Codex on two brokered VMs against the host credential proxies; a scan of every guest file finds no credential; cross-VM capabilities are rejected; killing the proxy ends agent requests with a transport failure and a missing or dying proxy refuses the start. Live, with dedicated keys: `scripts/test-proxy-live.py` passes streaming, disconnect and recovery for `claude-sonnet-5-5` (plus token counting) and `gpt-6-luna`; `--live-agents --brokered` boots a brokered VM whose proxies read the keys through `cmd:` references, and both agents complete a tool call and a final answer through the guest proxy. No key material appears in any log. |
| N-T09 | passed | A loopback preview forward works through the stream; the managed `iso-<name>` alias carries the runtime connector, not an address; the sandboxed editor's transport (a tunnel to guest-loopback `sshd`, then a pinned login through it) works. A sandboxed Zed 1.24.2 (`iso zed --editor-allow internet`) was launched against a brokered `egress: "none"` VM: it logged in with its loopback-restricted session key, uploaded and ran `zed-remote-server`, and its guest-side fetches failed for lack of egress; ending the session removed the editor, its enclave and its guest key. This found and fixed a profile gap (Zed's server upload runs `sftp`/`scp`). VS Code was not run (no Remote-SSH extension here). |
| N-T10 | passed | On a brokered `egress: "filtered"` VM, guest sessions carry the companion as their proxy; the approved host is reached through it, an unapproved host and an IP literal are refused by the companion (curl 56 / 403), and bypassing the proxy has no route or resolver. Mixed DNS, rebinding, alternate IP forms and hairpin aliases are decided in `iso-egress` before any dial, independent of the guest's transport, and keep their package suites (*unit*: `mixedOrLocalAnswersAreNotDialed`, `publicConnectorResolvesEveryRequestAndNeverDialsForbiddenAnswers` for rebinding, `addressPolicyRejectsSpecialPurposeAndTransitionForms`, `addressPolicyAllowsPublicBoundariesAndRejectsEquivalentHostAddresses`); `iso-egress` now dials a fully public answer's addresses in order until one connects. |
| N-T11 | passed | git over HTTPS reaches an approved host and is refused for another; the Docker daemon carries the companion, pulls from an approved registry (`ghcr.io`) and fails for an unapproved one; a container on the default bridge gets the bridge proxy, its CONNECT is admitted for an approved host (200) and refused for another (403), and it has no direct route out. |
| N-T12 | passed | Two Macs (client and an enrolled worker, both macOS 27.0.1 on Apple Silicon, brokered worker): every remote-host case passes, including a 45 s cut of the client's management link (past the 30 s lease: the lapsed grant stays refused, the VM keeps the same brokered boot, a new session works) and a worker-service restart (`launchctl kickstart -k` on the worker: the old grant is refused, the VM keeps its boot); management hello p50 0.65 s. The same cases pass with `--local` and `--loopback`. Host sleep/wake (`--sleep-wake`): across 69 s of sleep the lease lapsed and access was refused after wake; across 904 s with `--sleep-ttl 60` the VM deadline passed during the sleep and the VM was stopped. Worker reboot (`--reboot-worker`, the worker Mac restarted with a brokered VM running and the client's session lost): the old grant is refused, the VM is reported stopped and does not come back on its own, the worker service answers 3.8 s after the Mac returns, and `vm.start` boots a new brokered VM that a new session reaches. The first reboot run found that `vm.start` refused the VM as already running until the periodic sweep committed the stop; start admission and service startup now commit a runtime-observed stop (`aStartAfterTheBootEndedBehindTheServiceIsAdmitted`). Offline-client and wedged-guest deadlines: stop observed at 124.6 s for a 60 s TTL (bound 180 s). |
| N-T13 | passed | A 72-stream flood is refused past the limit and stop completes during it; malformed and oversized requests are refused (*unit*). |
| N-T14 | passed | A guest wedging its own shutdown is stopped by the owner's forced path (measured 63 s: 60 s halt grace plus kill). |
| N-T15 | passed | Machine and text status, boot digest equal to the runtime's, `streams close` revocation; *unit* (`machineStatusAddsNetworkOnlyForBrokeredInstances`): requested vs effective transport, absence for vmnet, `effective: null` when not running. |
| N-T16 | passed | Existing vmnet contracts, fixtures and `iso` phase checks are unchanged and pass; a vmnet configuration refuses a brokered instance and vice versa. The v0.5.0 release binary, pointed at a brokered data root, refuses the configuration (`network: unknown field`) and, with that key removed, refuses to start the instance (`network-policy.json is not a supported network policy record`) while reporting it stopped; the current build then starts the untouched instance brokered. |

#### Measured bounds

- Revocation by `iso-sandbox streams close`: the live session ended in under
  5 s (the phase's bound).
- Revocation by a changed policy or a new boot for an `iso`-launched workload:
  supervision every 10 s, ended after two consecutive failures (≈ 20–30 s).
  A new boot refuses old connector lines immediately; after a configuration
  change new iso handoffs are refused immediately, while the managed alias
  (which presents the boot's original digest) keeps working until restart.
- Stop during a stream flood: 585 ms. Wedged guest shutdown: 63.1 s (60 s halt grace plus the forced kill).

### Qualification record

| Item | Value |
|---|---|
| Host | Apple Silicon (arm64), macOS 27.0.1 (26A434); second Mac for N-T12: Apple Silicon (arm64), macOS 27.0.1, same runtime and kernel |
| Runtime | iso-sandbox 0.1.0, protocol 5, feature `brokered-transport`, Containerization 0.45.0 |
| Kernel | vmlinux-6.18.15-186, sha256 `2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1` |
| Init image | `vminit:0.45.0` `sha256:aa6ab59d0938f7fadb54ac27e80959bdd2f1dafa8050011086d5f8ab1350fd6c` |
| Guest base | `ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3` (test fixture image and `iso setup` image, systemd 255) |
| Channel policy | `iso.channels/v1`, digest `1beae82700a50cad9663c46faaea554ae4a815f5330c82cdcaa412b5c6a59301` |
| Date | 16–19 October 2026 |
| Results | `tests/integration-apple-sandbox.sh` (`setup`, `brokered`, `iso`) on the final code: 173 passed, 0 failed, 1 skipped (the opt-in Touch ID secret-store checks). `tests/integration-remote-host.py --brokered`: every case passed with `--local`, `--loopback` and `--remote` (second Mac), plus `--sleep-wake` (with and without a deadline inside the sleep) and `--reboot-worker`. `tests/integration-proxy-transition.py --brokered`: passed (synthetic); `--live-agents --brokered` and `scripts/test-proxy-live.py`: passed with dedicated keys (`claude-sonnet-5-5`, `gpt-6-luna`). `tests/brokered_malicious_ssh.py`: passed. A sandboxed Zed 1.24.2 ran end to end. The v0.5.0 release binary refuses brokered records. The init filesystem was seeded with `ISO_TEST_INITFS` from an earlier digest-checked pull because ghcr.io refused the download (HTTP/2 stream errors) at the time. Fault injection: every `brokered-*`, `editor-file-transfer-scoped` and `host-start-commits-observed-stop` fault detected. |

### Decisions and deviations from the spec

- **No named policy profiles.** The spec's illustrative `network.policy` name
  is not implemented. The boot's policy is resolved from operator-controlled
  configuration and instance records and bound by digest; adding named
  administrator profiles would be a separate change.
- **Limits live in the channel policy.** `BrokeredNetworkPolicy` has no
  `limits` member; stream limits are the runtime's fixed channel policy, which
  the network policy binds by digest.
- **`sshd -i` per stream** instead of forwarding to guest-loopback `sshd`:
  no TCP hop and no dependency on `sshd` listening; guest `ssh.service` still
  runs for loopback consumers (the sandboxed editor's tunnel targets
  `127.0.0.1:22` inside the guest).
- **The transport is not requested over the host protocol.** A worker's own
  configuration selects the transport for VMs it creates. `vm.inspect` and
  `vm.list` add a closed `network` object to a running brokered VM's
  observation (`transport`, `boot_id`, `external_nic_count`,
  `network_policy_digest`, `channel_policy_digest`) from a fresh gate pass on
  the worker; a VM that fails that pass is reported `unhealthy`, and a client
  refuses a proof with unknown fields, a nonzero device count or another boot.
  The remaining spec 6.2 fields already exist elsewhere on the wire (identities
  and `daemon_epoch` on every response, `generation` and `expires_at` on the
  observation, the runtime build in `hello`, leases on access grants); there is
  no `qualification_id`, since qualification records are documents, not data
  the worker holds. Session labels exist in the runtime (`--session`) but the
  relay revokes by killing the connector instead of labeling streams.
- **Host sleep and clock changes** are covered by the existing owner deadline
  logic; brokered streams add no timer of their own beyond setup timeouts.

### Open items before claiming NET-HANDOFF-1

Found while qualifying: `iso-egress` dialed only the first validated DNS
answer. Inside its Seatbelt jail `getaddrinfo` returned an IPv6 answer first,
and on a Mac with no IPv6 route an approved dual-stack host was refused with
403 on vmnet and brokered VMs alike. It now dials a fully public answer's
addresses in order until one connects
(`publicConnectorDialsValidatedAnswersInOrderUntilOneConnects`); the whole
answer must still be public. Also found: git's default proxy authentication
probes without credentials and gives up on the companion's 403; filtered
boots now set `http.proxyAuthMethod=basic` system-wide.

Not release-blocking for this tuple:

- A VS Code run (N-T09 passed with Zed; VS Code here lacks Remote-SSH).
- `apt` over filtered egress (N4): Ubuntu's sources are plain HTTP and the
  companion admits only CONNECT to port 443, so `apt` after boot needs HTTPS
  sources and an approved mirror. This is a stated limitation under section
  12 item 5; images install their packages at build time.
- Qualification on each further OS/runtime/kernel tuple to be claimed.

### Review changes

The closeout review's design, correctness, security, test and docs findings
were applied:

- `NetworkPolicy` stores only the brokered snapshot; transport, digest and
  schema are derived, schema 3/4 is enforced at decode, and the snapshot's
  schema, transport and fallback are constants checked at decode.
- `Effective`'s brokered fields decode as one required group, the gate's
  expectation is `.vmnet` / `.brokered(networkPolicy:)` (a brokered boot is
  never gated without its digest), the relay's last hop is a typed
  `ConnectorCommand`, runtime `streams` takes `.list` / `.close(session:)`, and
  a brokered record has no `subnetIndex` instead of a 0 sentinel.
- A boot's provider grants are resolved from the environment that boot
  records (`--env` provider secrets), and create-time policy resolution runs
  before any journal or record.
- A burst past the admission rate waits for the window within the setup
  deadline instead of being refused, so short bursts of separate ssh commands
  (bootstrap) are slowed, not failed; the request line has a total deadline;
  a closed session's in-flight dials are refused.
- Host lifecycle tests against the stateful fake runtime cover brokered
  create/restart and digest hand-off, the refusals before any record or VM,
  commit/restore adapter handling and the relay's last-hop selection.

### Residual risks

- The hypervisor, Virtualization.framework vsock device, the runtime owner
  and the brokers remain in the trusted computing base.
- A blind CONNECT to an approved host, a provider API, or a configured local
  model can receive data the guest sends; this is destination enforcement,
  not information-flow control.
- Sessions opened outside `iso` (the managed alias, `unsafe` editors) are not
  supervised; they end at the next stop/restart or `streams close`.

## 15. Sources and evidence status

This document consolidates the earlier design discussion and supplied Markdown artifacts. Repository observations are pinned to the stated baseline; external references are carried forward from that review, not a new compatibility certification. Section 14 records which of the interfaces, configuration, work packages, and tests above are implemented and qualified.

[^n1]: [iso architecture](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/docs/ARCHITECTURE.md).
[^n2]: [iso trust model](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/docs/trust-model.md).
[^n3]: [iso configuration](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/docs/configuration.md).
[^n4]: [iso VM owner and configuration](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/iso-sandbox/Sources/IsoSandboxCore/Owner.swift).
[^n5]: [Apple VM network devices](https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/networkdevices).
[^n6]: [Apple Virtio socket device](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice).
[^n7]: [OpenSSH client configuration, including ProxyCommand and forwarding](https://man.openbsd.org/ssh_config).
[^n8]: [iso public connector](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/iso-egress/Sources/IsoEgressCore/PublicConnector.swift).
[^n9]: [iso egress policy](https://github.com/chr33s/iso/blob/d27752a7fd1b1731c8dd700e2e9457c119e2fc2e/iso-egress/Sources/IsoEgressCore/Policy.swift).
[^n10]: [Docker daemon proxy configuration](https://docs.docker.com/engine/daemon/proxy/) and [container/build proxy configuration](https://docs.docker.com/engine/cli/proxy/).
[^n11]: [Apple TN3165: Packet Filter is not API](https://developer.apple.com/documentation/technotes/tn3165-packet-filter-is-not-api).
