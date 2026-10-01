# Sandboxy-inspired features for Coop

**Status:** Draft proposal, version 0.2  
**Date:** 2026-10-01  
**Target:** `chr33s/coop`, `swift` branch  
**Suggested repository path:** `docs/design/sandboxy-inspired-features-spec.md`  
**Coop baseline:** `7cacce6fd92df07a690b8b6774c437e9376cd14e`  
**Sandboxy reference:** `apple/containerization` at `f24df2ac817df66fe149a80103251dec987c32dc`, `examples/sandboxy/`

This document proposes changes; it does not describe shipped features or certify their security. Existing behavior is identified explicitly and linked to the inspected source. All new commands, configuration fields, state records, budgets, and acceptance criteria below are proposed. No implementation or runtime tests were performed for this specification.

**Revision 0.2:** Promote declarative agent definitions to the second delivery increment, before filtered egress. Use one launch-definition model for built-ins and user-installed agents; allow compatible, reviewed compiled adapters rather than restricting every custom definition to unauthenticated execution. Specify guest working directories, bounded non-sensitive environment defaults, adapter compatibility, independent network authorization, and incremental migration of existing launchers. Image installation and credential policy remain separate. Feature IDs are stable identifiers, not delivery priorities.

## 1. Decision summary

Borrow Sandboxy's low-friction workflow and selected networking ideas, not its host-sharing model. Preserve Coop's separate guest workspace, provider credential broker, isolation gate, and single Apple runtime.

| ID | Feature | Recommendation | Scope of the actual addition |
|---|---|---|---|
| F1 | Destination-filtered egress | Implement after a dedicated security qualification gate | A separate, credential-free CONNECT proxy over a host-only VM network. Compose with, never replace, `coop-proxy`. |
| F2 | One-command agent sessions | Implement early | `coop run` combines existing project resolution, image preparation, startup, and agent launch. Add explicitly disposable runs without changing existing commands. |
| F3 | Declarative agent definitions and reviewed adapters | Implement immediately after the F2/F5 foundation, before F1 | One launch model for built-in and host-installed definitions; image/profile selection, guest launch metadata, and compatible compiled adapter selection. Definitions request capabilities but cannot grant them. |
| F4 | Environment inspection and customization | Extend existing image machinery | Explain cache reuse/staleness, safely prune unreferenced caches, and provide an optional clone-edit-publish workflow. Do not build another cache system. |
| F5 | Effective-policy startup summary | Implement with F2 | Show what this running instance actually permits, what persists, and how to return changes. Include phase timings and a side-effect-free preview. |

**First delivery:** F2's persistent workflow and F5, with built-in Claude/Codex represented through the shared definition model. **Second delivery: F3's installed definitions and reviewed-adapter dispatch.** F3 is an architectural extension point, not a cosmetic convenience or a feature contingent on filtered egress. Deliver it before F1 and before optional cache editing; add disposable cleanup as a separately tested increment. F1 remains a distinct security capability requiring its own qualification and must not ship on the strength of unit tests alone.

The organizing separation is: **images/profiles determine installed software; definitions determine launch requirements; compiled adapters implement client configuration and credential use; host security policy grants authority; workspace policy governs file transfers.** A definition is useful because it joins these existing pieces without replacing any of their trust boundaries.

## 2. Baseline and non-goals

### 2.1 What already exists

Sandboxy already offers per-agent JSON definitions, cached environments, an interactive cache editor, named sessions, `--rm`, live virtio-fs workspaces, and a hostname-filtering forward proxy. Its proxy can tunnel HTTPS and forward plain HTTP; its built-in agent definitions can forward provider variables and mount host configuration directories. These are inspiration, not a compatibility contract.[^S1][^S2][^S3]

Coop already has the following facilities; implementations MUST extend them rather than duplicate them:

| Existing capability | Consequence for this proposal |
|---|---|
| `coop up` resolves project affinity and reuses a running or stopped instance | `run` is an orchestration entry point, not a new instance manager.[^C1] |
| Profile-derived image preparation, recipe-hash staleness checks, and APFS-cloned instance disks | F4 adds visibility and controlled customization, not basic caching or copy-on-write support.[^C2] |
| `commit` and `restore` for stopped instances | Image editing reuses these transaction paths.[^C2] |
| No runtime host mounts, SSH-agent forwarding, socket relays, or published ports; an effective-configuration isolation gate | These invariants remain mandatory. Existing SSH tunnels are a host orchestration mechanism, not a relaxation of runtime exposure checks.[^C3][^C5] |
| A provider-specific, credential-injecting proxy exposed by reverse SSH tunnels | General development traffic belongs in a different process.[^C4][^C9] |
| `open`/`none` egress, security presets, provider proxy modes, staged pulls, and a session TTL | New features compose with these policies. Existing defaults do not change.[^C6] |
| Explicit workspace copying, `push`, `pull`, and staged review/apply | `run` does not introduce a live mount or automatically apply guest output.[^C7] |
| Dedicated Claude/Codex command and bootstrap paths, with separate configuration sections | F3 factors common launch metadata and dispatch while retaining the existing security-sensitive implementations behind reviewed adapters.[^C6][^C8][^C11] |

### 2.2 Non-goals

The proposal MUST NOT introduce live host filesystem sharing, host SSH-agent forwarding, a host Docker socket, guest-controlled host commands, TLS interception, automatic trust of repository-local agent definitions, or an unrestricted-network fallback. It MUST NOT replace the Apple backend, introduce a backend selection abstraction, or change the fork's supported-host policy.[^C3][^C8]

The first version also excludes wildcard host rules, general plain-HTTP forwarding, arbitrary CONNECT ports, a remote agent-definition marketplace, unreviewed third-party credential adapters, and automatic publishing of an edited cache.

There is no claim of complete exfiltration prevention. An approved destination can receive sensitive data, and a permitted model operation can still misuse the authority available through the provider broker. Existing host-only networking also leaves some host services reachable; this proposal does not close that separate boundary.[^C4][^C6]

## 3. Requirements common to all features

**INV-01 — Preserve the guest boundary.** Keep `IsolationGate` mandatory before user or agent hand-off. Never add a bypass flag. Runtime mounts, socket relays, published ports, and SSH-agent forwarding remain disallowed.

**INV-02 — Preserve credential semantics.** Existing `proxy.mode` behavior remains authoritative. In particular, `required` MUST continue to reject raw recognized provider credentials through every newly added entry point. `filtered` egress alone MUST NOT be advertised as credential protection.

**INV-03 — Host-owned policy.** Agent code and guest output cannot grant new network destinations, approve a definition, change a saved image recipe, or trigger a host-side credential command. Repository configuration may provide suggestions only through an explicit review path.

**INV-04 — No implicit destructive action.** Reuse of an instance MUST NOT cause a push, restore, recreation, image replacement, or workspace pull. Removing a newly created disposable instance requires explicit `--rm` intent and a matching ownership record.

**INV-05 — Reuse current implementation boundaries.** Configuration parsing belongs in `CoopConfiguration`; validated values in `CoopCore`; side effects in `CoopHost`; argument parsing in `CoopCLI`. Runtime ownership stays in `coop-sandbox`. Host processes use `ProcessRunner`, guest commands use `RemoteCommand`, and state writes use existing locks and atomic-file primitives.[^C8]

**INV-06 — Honest reporting.** Distinguish desired policy, recorded boot policy, verified runtime configuration, and live companion health. Never label an instance protected solely because a configuration file requests protection.

**INV-07 — Defaults stay compatible.** Existing `up`, `start`, `claude`, `codex`, image commands, `networked`, `provider-only`, and `offline` retain their meanings. New policy is opt-in; explicit configuration still overrides preset defaults.

## 4. F1 — Destination-filtered egress

### 4.1 Purpose and security contract

Allow a development tool in an otherwise host-only VM to connect to specifically approved public destinations, without granting general NAT access or handing provider keys to a general-purpose proxy.

The bounded contract is: **no direct Internet route through Coop's configured VM network, plus a controlled host-mediated TCP tunnel to approved hostnames on port 443.** CONNECT is a blind tunnel after establishment; this is not HTTP method/path filtering, read-only package access, payload inspection, or proof of the protocol inside the tunnel.[^N1]

This feature does not claim that the guest cannot reach host services or use a separately exposed host relay. Display that residual risk in the startup report and document it in the trust model.

### 4.2 Configuration and policy resolution

Add `EgressMode.filtered` and a top-level `egress_filter` object:

```jsonc
{
  "security": { "preset": "provider-only" },
  "egress": "filtered",
  "egress_filter": {
    "allowed_hosts": [
      "github.com",
      "registry.npmjs.org",
      "pypi.org",
      "files.pythonhosted.org"
    ]
  }
}
```

This example deliberately overrides only the preset's egress default; required provider proxying and staged pulls remain selected. A provider credential must still be provisioned through Coop's existing supported mechanism. The host list is illustrative, not a promise that every package manager, redirect, or project will work with it.

| Setting | Runtime network | General egress companion |
|---|---|---|
| `open` | Existing shared/NAT network | Not started |
| `none` | Existing host-only network | Not started |
| `filtered` | Existing host-only network | Started with the resolved allowlist |

**NET-01.** An empty list means no general-proxy destinations. No built-in agent, profile, or package manager receives a hidden allowlist.

**NET-02.** `egress_filter` is valid only with `egress: filtered`. Reject unknown fields, invalid types, duplicate JSON keys, more than 256 entries, and unsupported schema values. Canonically identical host entries are deduplicated and sorted.

**NET-03.** Add repeatable `--allow-host HOST` and `--egress open|none|filtered` to `up`, `start`, and `run`. `--allow-host` requires an explicitly effective `filtered` mode; it MUST NOT change `none` to `filtered` automatically. Existing instances cannot change their creation-time egress mode through this flag.

**NET-04.** Effective hosts for a new boot are the configured list plus explicit CLI additions. Agent-definition suggestions are never merged automatically. CLI additions apply to that boot only and do not edit the configuration. Record their origin in the boot policy and audit log.

**NET-05.** Freeze the resolved policy for the lifetime of a boot. A running instance is not silently reconfigured when a config file changes or `run` supplies different hosts. Refuse launch with `POLICY_CHANGE_REQUIRES_RESTART`, showing the policy difference without credentials. A stopped instance may start with a new allowlist, subject to validation and its fixed egress mode.

**NET-06.** Compute the policy hash from a versioned canonical representation of mode, canonical host set, protocol/port restrictions, and compiled limit profile. Exclude timestamps, ports allocated for local transport, and capability values. Store both the semantic policy hash and diagnostic field origins.

### 4.3 Process and transport architecture

Add a separate package and executable, **`coop-egress`**, with no provider-key injection code and no provider credential store access. This adds a fourth distributed executable; that packaging cost is intentional. Do not broaden the request handling or destination selection of credential-bearing `coop-proxy`.

```text
Guest development tool
  -> guest loopback CONNECT endpoint
  -> dedicated ssh -R tunnel
  -> host-loopback coop-egress
  -> validated public address for an approved hostname:443

Guest supported coding agent
  -> existing guest-loopback provider endpoint
  -> existing provider ssh -R tunnel
  -> existing coop-proxy
  -> fixed provider, using the host-held credential
```

**NET-07.** Run one egress companion per VM boot, with a separately allocated loopback listener and reverse tunnel. Bind neither listener to a LAN or vmnet gateway address. Do not reuse a provider's capability or listener port.

**NET-08.** Generate a random 256-bit capability for each VM boot. Use standard proxy authentication, with a fixed username and this capability as the Basic-auth password, for client compatibility. Authenticate before destination resolution or connection. Reject duplicate or malformed authentication headers; comparisons use a constant-time primitive. Capabilities are local grants, not provider credentials.

**NET-09.** Supply companion startup configuration and capabilities over stdin, never argv. Start with a minimal environment that excludes provider secrets and inherited proxy configuration. Persist a capability only where later host invocations need it, in a dedicated owner-only file, not ordinary diagnostic JSON. Invalidate and remove it at boot teardown.

**NET-10.** Deliver managed upper- and lowercase proxy environment variables to guest sessions through the existing controlled environment path. Managed `NO_PROXY` covers loopback provider and local-model endpoints. Do not inherit arbitrary host proxy variables or allow user config to override these managed values on a filtered boot. Plain-HTTP clients routed here receive an explicit unsupported-operation error; there is no NAT fallback.

Guest code can read and use its local capability. This is expected. Coop-generated diagnostics and audit events MUST redact proxy userinfo; arbitrary guest stdout cannot be guaranteed to avoid echoing a guest-visible capability.

**NET-11.** Confine `coop-egress` separately: deny host file writes, subprocess execution, and unrelated outbound ports. Permit only the minimum runtime/system reads and name-resolution facilities demonstrated necessary by confined-process tests. Confinement failure aborts startup. Port-scoped confinement is defense in depth; application policy performs hostname and resolved-address enforcement.

**NET-12.** Share only reviewed, credential-independent primitives where this reduces duplication. The host must not link a networking companion merely to parse its protocol. Do not copy Sandboxy's proxy wholesale and treat it as qualified production code.

### 4.4 Destination and wire policy

**NET-13.** Version 1 accepts exact ASCII DNS names only. Lowercase for comparison; normalize one terminal dot; validate DNS-label structure and total length. Reject wildcards, IP literals, numeric-address aliases, single-label names, URI schemes, paths, userinfo, control characters, empty labels, and percent-encoded host syntax. Non-ASCII input is rejected; reviewed ASCII A-labels can be entered explicitly. A rule for `example.com` does not match `a.example.com` or `example.com.attacker.test`.

**NET-14.** Accept HTTP/1.1 CONNECT with an explicit destination port of 443 only. Reject absent/invalid ports, inconsistent authority metadata, unsupported methods, nonzero request bodies, ambiguous framing, and any `Transfer-Encoding`. A successful CONNECT response has neither `Content-Length` nor `Transfer-Encoding`, and the byte relay must not insert HTTP framing into the tunnel.[^N1]

**NET-15.** Resolve on the host only after authentication and hostname approval. Before connecting, check every returned address. Deny the request if any answer is non-public or belongs to a host interface. Check IPv4 and IPv6, including mapped-address forms; reject unsupported transition/translation forms rather than interpreting them optimistically. Pin a versioned, tested address-policy table based on the IANA special-purpose registries, with additional explicit denial of multicast and this Mac's addresses.[^N2][^N3]

**NET-16.** Connect directly to a validated numeric address from that resolution; do not let a later hostname-based connect resolve it again. Check the connected peer. Re-resolve and revalidate for each new connection. No guest-supplied resolver, proxy chaining, or host-network bypass override is supported in version 1.

**NET-17.** Authenticate each new connection independently. Strip proxy authentication before starting the raw upstream relay. A hostname approval authorizes a destination, not a certificate, HTTP Host header, tenant, repository, or endpoint. Shared hosting, server-side relays, and data sent to approved services remain limitations; TLS validation inside the tunnel remains the client's responsibility.

**NET-18.** Denials report bounded reason codes, such as `HOST_NOT_ALLOWED`, `PORT_NOT_ALLOWED`, `ADDRESS_NOT_PUBLIC`, and `AUTH_REQUIRED`. Diagnostic text is escaped and size-limited. Do not log request headers, bodies, full proxy URLs, or arbitrary queried hostnames from unauthenticated traffic.

### 4.5 Proposed limits and lifecycle

These are implementation budgets to qualify, not measured performance claims:

| Resource | Initial bound per companion |
|---|---|
| Accepted client sockets, including unauthenticated sockets | 128 |
| Established upstream tunnels | 64 |
| Concurrent DNS resolutions | 16 |
| CONNECT metadata | 16 KiB aggregate; 64 headers; 1 KiB target |
| Request-head / DNS / connection deadline | 5 / 5 / 10 seconds |
| Idle established tunnel | 300 seconds |
| Application relay queues | 256 KiB per direction per tunnel; 32 MiB aggregate |

Admission, DNS work, pending connects, and relay queues must all be bounded. Stop reading under backpressure; reject new work when no budget exists. These application budgets do not claim to bound all kernel socket memory or installation-wide usage across many VMs.

**NET-19.** Startup order is: validate policy; boot host-only VM; pass runtime isolation gate and pin SSH identity; establish companions/tunnels; validate their boot-bound readiness; then release the selected session. Do not start project hooks or an agent through an earlier path. Existing intentional package/image preparation is governed separately below.

**NET-20.** Introduce a composite host-side session readiness proof covering `IsolationGate.Ready`, VM boot identity, policy hash, and required companion/tunnel readiness. Every guest hand-off re-establishes the relevant proof; the runtime gate alone cannot verify a user-space proxy. A health change must make status unhealthy, not claim that a cached readiness check is still live.

**NET-21.** If proxy or tunnel startup fails, no filtered session launches. If it fails after launch, affected traffic fails, new hand-offs are refused until recovery, and no shared network or direct connection is substituted. The VM may remain running for diagnosis. A live check is not a guarantee that a process cannot fail immediately afterward.

**NET-22.** Stop, destroy, TTL expiry, and owner replacement close egress tunnels, terminate the matching companion, revoke the capability, and record teardown. Persistent mode requires host supervision independent of the short-lived `coop run` process; reuse the project's launchd ownership style. Supervisor loss must not leave indefinitely usable orphan grants: the companion must terminate on loss of its boot-owner liveness channel. Validate PID identity before signalling any recorded process.

**NET-23.** VM network creation remains `shared` or `host-only`; do not add a second NIC. Refactor the host's existing `.none` comparisons into an explicit host-only requirement used by both `none` and `filtered`. The runtime networking protocol need not change merely for this mapping. Any additional boot-identity/supervision protocol change must be versioned and advertised explicitly, not smuggled into the existing contract.

### 4.6 Preparation versus workload networking

Coop already prepares images separately from workload execution.[^C2] A filtered run MUST NOT silently rebuild an image with open networking after printing a filtered-workload summary.

A new `run` path may reuse verified existing images without prompting. When a build or first-boot install requires broader network access, show a separate preparation stage, its network mode, and the fact that no workspace or provider credential will be supplied to that build. Require interactive approval or explicit `--prepare` authorization. Noninteractive runs fail before the build without that authorization. Existing explicit `coop setup` semantics remain unchanged.

Do not temporarily switch a workload VM to open networking for plugins, updates, or package installation. Under `none`, required uncached network installs fail with remediation. Under `filtered`, they use approved hosts or fail. F1 does not promise compatibility with tools that ignore proxy variables, guest Docker daemons without proxy configuration, plain-HTTP mirrors, or git-over-SSH.

## 5. F2 — One-command agent sessions

### 5.1 Command surface

```text
coop run <agent> [--workspace DIR] [--name NAME]
         [--image NAME | --profile LIST]
         [--egress open|none|filtered] [--allow-host HOST ...]
         [--prepare] [--rm] [--ask] [--dry-run] [--json]
         [-- AGENT_ARGS...]
```

The first increment dispatches the existing Claude and Codex adapters through the shared definition model. The immediately following F3 increment accepts installed custom definitions on the same path; it does not depend on F1. Relevant existing resource, environment, GitHub opt-out, and devcontainer opt-out options may be exposed through shared option groups; they retain existing validation. Do not duplicate their implementations. The `filtered` and `--allow-host` options are available only after F1 is qualified, not merely because a definition has network hints.

```sh
# Ensure the current project's environment, then launch its agent.
coop run claude

# Launch in a named project instance without silently pushing host edits.
coop run codex --name payments

# An explicitly new throwaway VM; guest changes will not be pulled automatically.
coop run claude --rm --workspace ./scratch

# Add a host for a new filtered boot. This never changes an existing VM's mode.
coop run claude --egress filtered --allow-host registry.npmjs.org

# Inspect the prospective launch without starting anything.
coop run codex --workspace ./service --dry-run --json
```

### 5.2 Resolution and persistent behavior

**RUN-01.** Without `--name`, reuse `up`'s canonical project-affinity resolution for `--workspace` or the current directory. Do not select an unrelated VM just because it is the only VM in the installation. Multiple matching persistent instances require an explicit name.

**RUN-02.** An existing explicit name selects that VM and its recorded workspace. A supplied `--workspace` must match its recorded association; the current working directory is not silently substituted. A nonexistent explicit name creates an instance for the requested/default workspace.

**RUN-03.** For a matching running instance, verify live policy and launch without a build, push, restart, or bootstrap replay. For a stopped instance, follow the existing startup path and readiness checks. For a new instance, follow the existing image/preparation and creation paths, with the separate preparation authorization described in F1.

**RUN-04.** Reject creation-time requirements incompatible with an existing instance. Do not ignore a requested image/profile, recreate the VM, or silently change its resources. Explain the mismatch and the explicit recreate workflow.

**RUN-05.** A normal run retains the instance and leaves it running after the agent exits, subject to the existing TTL and explicit stop/destroy commands. It does not automatically copy guest output to the host. Print the instance name, persistence state, and the applicable `coop diff` / `coop pull` guidance. Documentation must explain that keeping a VM also keeps its writable disk and any authority still available during that boot.

**RUN-06.** Resolve the selected agent to a typed launch plan, then delegate client-specific launch, permission flags, credential handling, and terminal behavior to its reviewed adapter. Initially these wrap the existing Claude/Codex implementations. `--ask` preserves their existing meanings; a custom definition can use it only when its selected adapter advertises support, otherwise fail before boot or launch rather than ignoring it. Arguments after `--` are forwarded as arguments, without host-shell interpretation. Legacy `coop claude` and `coop codex` retain their command-line behavior. See F3 for the generic launch contract.

### 5.3 Disposable behavior

**RUN-07.** `--rm` always creates a new disposable instance. It never attaches cleanup to an existing VM. A supplied name must be unused. Generated names must be collision-resistant and valid under existing name rules. Mark disposable instances as ineligible for ordinary project-affinity reuse so a simultaneous `coop up` cannot adopt one.

**RUN-08.** Write a host-owned session record before creation with a session ID, intended name, owner ID, creation operation ID, and cleanup intent. Record the resulting sandbox identity and boot identity after verification. Cleanup requires matching identities, not a name or PID alone.

**RUN-09.** After a normal agent exit, stop the VM, tear down companions and tunnels, and destroy only the instance owned by that disposable session. No implicit pull, review, commit, or image publication occurs. The pre-launch summary explicitly states that guest changes are discarded.

**RUN-10.** On catchable interruption, forward the signal through existing child-process handling and perform bounded cleanup. On an uncatchable host crash, shutdown, or uncertain operation, do not claim cleanup completed. Add `coop run-cleanup --dry-run` and `coop run-cleanup --session ID` to reconcile abandoned run records using existing lifecycle journals. Never delete a still-active session or an object whose ownership cannot be proven.

**RUN-11.** Reject or suspend destruction if a pending staged pull exists, another host operation holds the relevant lock, or state is ambiguous. Stop where safe, retain the instance, and report the reason. Unapplied stages are currently stored under the instance directory, so blindly deleting it would destroy the review artifact.[^C7] Exporting review artifacts independently of an instance is deferred.

**RUN-12.** For this first version, an agent exit is not proof that all work in the guest was successful or saved. Nonzero exit still follows explicit `--rm` cleanup. Do not auto-persist failures under an undocumented heuristic.

**RUN-13.** Preserve a known nonzero agent exit status. If the agent succeeds but cleanup fails, return an infrastructure failure. If no trustworthy agent status is available because transport failed, report it as unknown and return an infrastructure failure. Store agent outcome and cleanup outcome separately. Usage/configuration errors follow the existing CLI exit convention; no new ambiguous success code is introduced.

### 5.4 Preview and machine output

`--dry-run` is side-effect-free: no VM, image build, network request, credential resolution, config creation, update check, or execution of a `cmd:` reference. Resolve from local metadata only; mark unavailable facts unresolved. A missing image can be reported as requiring preparation without performing it. A preview is not a live readiness proof.

`--json` is accepted only with `--dry-run` in version 1. During actual runs, stdout/stdin belong to the agent; Coop's reports go to stderr. Structured final state is available through recorded session information and the existing status/audit surfaces, rather than mixing control JSON with agent output.

## 6. F3 — Declarative agent definitions and reviewed adapters

### 6.1 Decision and architecture

**Implement this early, before destination-filtered egress.** Borrow Sandboxy's ability to add an agent by describing its launch, without making its definition a document that grants access to host resources. Sandboxy's broader schema also includes installation commands, mounts, and forwarded variables; those responsibilities stay with Coop's existing subsystems.[^S3][^C2][^C6][^C7]

Coop currently has dedicated Claude/Codex command, configuration, and bootstrap paths.[^C6][^C8][^C11] The proposal introduces a shared `AgentDefinition` and launch planner so adding launch variants or compatible tools does not require a new top-level command and another copy of session orchestration. It does **not** require rewriting the provider broker or immediately replacing the existing bootstrap implementations.

| Responsibility | Owning subsystem | What a definition can do |
|---|---|---|
| Which software is installed | Existing golden images, profiles, image preparation | Select an image or profile set; never embed a new installation language |
| How the guest program starts | Validated `AgentDefinition` and shared launch planner | Declare guest argv, working directory, terminal needs, and bounded non-sensitive defaults |
| How a supported client is configured | Reviewed compiled configuration adapter | Select an already supported adapter contract, not specify arbitrary config-file writes |
| How provider authentication is supplied | Reviewed compiled credential adapter plus existing `coop-proxy` policy | Request a compatible binding; never select a secret value, host credential command, or injection destination |
| Which network authority is granted | Effective host security configuration and explicit CLI authorization | Describe destination hints; never turn them into an allowlist automatically |
| Which files cross the VM boundary | Existing workspace copy/push/pull/stage policy | Use the existing guest workspace; never request live host mounts or automatic return of changes |

The compiled adapter registry associates a client's configuration behavior with its credential behavior. Keep the existing schema's single `auth_adapter` selector for that reviewed binding rather than adding independent, potentially inconsistent provider/configuration switches. A provider name alone is insufficient to establish how a particular client uses a base URL, bearer capability, or API operation.

Built-in and installed definitions use the **same validated model and launch path**. Built-ins remain shipped, immutable descriptors referring to the existing reviewed implementations. Installed definitions are host-owned data, not executable host plugins.

### 6.2 Definition schema

A custom tool already installed in a prepared image can be described as follows. `repo-helper` is an illustrative tool, not a claim of a newly supported product:

```jsonc
{
  "schema_version": 1,
  "id": "repo-helper",
  "display_name": "Repository helper",
  "environment": { "image": "helper-tools" },
  "launch": {
    "argv": ["repo-helper"],
    "working_directory": "/workspace",
    "terminal": "auto",
    "environment": { "NO_COLOR": "1" }
  },
  "auth_adapter": "none",
  "network_hints": {
    "suggested_hosts": ["registry.npmjs.org"]
  }
}
```

For profile-derived preparation, replace the top-level `environment` with, for example, `{"profiles": ["node", "repo-helper-tools"]}`. The custom profile must already be defined through Coop's existing host configuration and actually install the tool. Selecting `node` or `python` alone does not imply that an agent has been installed. A definition neither contains install commands nor causes an unapproved preparation step.

A second example demonstrates that custom definitions are **not restricted to `auth_adapter: none`**. This launch variant requests the already reviewed Claude adapter while leaving credential selection entirely in host configuration:

```jsonc
{
  "schema_version": 1,
  "id": "claude-review",
  "display_name": "Claude review session",
  "launch": {
    "argv": ["claude"],
    "working_directory": "/workspace",
    "terminal": "auto"
  },
  "auth_adapter": "claude"
}
```

The adapter recognizes the logical `claude` executable and resolves the guest-user-specific binary through the existing launcher. This file does not select an API key, authorize a provider, or enable a proxy. `coop run claude-review --ask` delegates permission behavior to the existing Claude adapter. Adapter compatibility must be validated; selecting `claude` for an unrelated executable is an error, not a generic credential forwarding mechanism.

| Field | Contract |
|---|---|
| `schema_version` | Required integer, exactly `1` for this draft's first implementation |
| `id` | Required validated agent ID matching the installed filename; 1–64 lowercase ASCII letters, digits, or hyphens, starting with a letter; no path separators |
| `display_name` | Required bounded display text; never used for identity or command dispatch |
| `environment.image` / `environment.profiles` | Optional mutually exclusive environment selectors; profiles reference existing built-in or host-configured recipes |
| `launch.argv` | Required nonempty argument array; executable first, followed by definition defaults; caller passthrough arguments append without host-shell evaluation |
| `launch.working_directory` | Optional normalized absolute guest path, default `/workspace`; no host mapping, `..`, tilde expansion, or variable expansion |
| `launch.terminal` | `auto` (default), `required`, or `never`, subject to the selected adapter's supported transport modes |
| `launch.environment` | Optional literal, non-sensitive guest defaults from the compiled allowlist described below; not host environment forwarding |
| `auth_adapter` | Required ID of a compiled reviewed binding, including `none`; unknown or incompatible IDs are rejected |
| `network_hints.suggested_hosts` | Optional exact-host suggestions, individually validated; they confer no permission |

Unknown fields are rejected. In particular, `baseImage`, `installCommands`, `mounts`, raw credential fields, and arbitrary provider/configuration templates are not accepted as a Sandboxy compatibility mode. Migration is a conscious translation into profiles, launch metadata, and host policy.

### 6.3 Catalog, installation, and trust

```text
coop agent list
coop agent inspect <id> [--json]
coop agent add <file> [--replace] [--yes]
coop run <id> [RUN_OPTIONS] [-- ARGS...]
```

```sh
# Validate, review, and install a host-owned definition copy.
coop agent add ./repo-helper.jsonc
coop agent inspect repo-helper --json

# Uses the same environment and session machinery as a built-in agent.
coop run repo-helper -- --help

# A custom launch variant can select an existing reviewed adapter.
coop agent add ./claude-review.jsonc
coop run claude-review --ask
```

**AGT-01.** Represent built-in and installed agents using the same `AgentDefinition` type. Reserve the built-in `claude` and `codex` definition IDs; files cannot shadow them. Separately reserve every compiled adapter ID so files cannot replace an implementation. A custom definition may refer to a compatible adapter without owning it. Preserve `coop agent update` and all legacy agent commands; definition installation is not a package update.

**AGT-02.** Store each validated custom copy as `<data_dir>/agents/<id>.json` in the installation's private agent catalog. `agent add` shows the canonical source path, ID, full escaped launch metadata, environment requirements, requested adapter, and network hints before confirmation. `--yes` explicitly authorizes installation in automation; replacement additionally requires `--replace`. Validation, review, and writing use the same file snapshot, so changing the input after review cannot change what is installed. Install atomically under a catalog lock. No repository-local discovery, source-file reference, URL fetch, marketplace, or automatic inheritance is supported. An explicitly supplied repository file may be copied only through this same trust action.

**AGT-03.** Read bounded regular files without following symlinks; verify expected ownership and private-directory rules. Reuse JSONC parsing/preflight with a 256 KiB file cap, maximum nesting depth 16, duplicate-key detection, strict unknown-field rejection, at most 128 argv entries, at most 4 KiB per entry and 64 KiB aggregate argv, at most 64 profile entries, and at most 256 hostname hints. Working directories are bounded to 4 KiB; display names to 128 Unicode scalars. Reject NUL in executable arguments and invalid/control-bearing path or display fields. These are proposed parser budgets, not measured performance. Same-user malicious host processes remain outside this trust boundary.

`agent list` distinguishes built-in, installed, invalid, and unsupported definitions. An invalid file is reported and cannot be used; it is never silently replaced with a different definition. `inspect` reports source, hash, schema, environment requirements, adapter contract, non-sensitive defaults, and hints. Catalog operations perform no guest execution, credential resolution, package installation, update check, or network request.

### 6.4 Reviewed credential and configuration adapters

**AGT-04.** Custom definitions MAY select compatible **compiled, reviewed adapter bindings**. The initial registry contains `none` and wrappers around the existing `claude` and `codex` implementations. Registry ownership is independent of whether a definition is built-in or user-installed. Do not retain a blanket rule that every custom definition must use `none`.

Each registry entry declares its accepted logical executable/client contract, supported terminal and permission options, configuration adapter, provider binding (or no provider), managed configuration/environment names, supported authentication modes, and compatibility-test evidence. Client-specific path resolution and configuration generation remain code. The registry must not load Swift code, dynamic libraries, scripts, arbitrary file templates, or command hooks from a definition.

The `claude` and `codex` entries preserve their existing supported authentication behavior subject to host policy. A definition cannot enable a direct-auth mode that the configuration disallows. For a brokered binding, the configuration adapter supplies only Coop's local endpoint/capability to the guest; the credential adapter resolves the already host-authorized provider through the existing broker lifecycle. No definition chooses a Keychain item, vault name, `cmd:` command, bearer value, or raw-key destination.

A new client/provider pair—such as a future Pi or Aider integration—needs a reviewed registry entry and compatibility tests before it is advertised. Their names here identify possible extensions, not verified support. If a candidate client requires operations outside the broker's current allowlist, it is unsupported until a separate operation-policy change is reviewed; installing JSON cannot widen the broker. Reuse an existing compiled contract where it fits rather than creating another provider transport.

**AGT-05.** Effective host policy remains authoritative on every launch path. `proxy.mode: required` retains all recognized raw-provider-variable guards. A missing authorized provider, unsupported auth mode, or incompatible client/adapter binding fails explicitly before guest hand-off, without raw-credential fallback. `auth_adapter: none` means this launch requests no managed credential/configuration binding; it does not disable required-proxy validation or silently select local-model mode. Local-model selection remains an explicit existing host configuration operation.

A fresh generic no-auth launch must not invoke unrelated Claude/Codex bootstrap solely because those binaries happen to be installed in the image. Explicit user-provided configuration/variables still pass through the existing policy checks. Conversely, a reused VM or snapshot may already hold credentials, config, provider capabilities, or tunnels from earlier authorized work. The VM, not the definition, remains the isolation unit: `none` is **not** a promise that its program cannot use another program's guest-visible authority. Display known ambient authority and unknown disk history honestly; stronger separation requires a fresh appropriately provisioned VM, not a different definition ID.

**AGT-06.** Definitions cannot grant host mounts, SSH-agent forwarding, socket access, automatic config-directory copying, environment forwarding, raw credentials, host command execution, provider endpoint overrides, or relaxed egress. They cannot contain credential lookup/resolution fields, custom injection templates, security-preset switches, or installation commands. `auth_adapter` is a request to use a supported binding under existing host authorization, not a grant to read host secrets.

Arbitrary guest argv remains arbitrary guest code. Rejecting unsupported fields does not prove that an operator did not paste a secret into an argument or that a guest program cannot misuse existing access. Do not advertise automatic secret detection, executable attestation, or a new per-agent security boundary. Managed configuration and known conflicting client flags must be rejected by the selected adapter; that launch-time validation does not constrain a compromised guest's later code.

### 6.5 Launch, environment, and network resolution

**AGT-07.** Network hints are requested/explanatory metadata only. `inspect`, preview, and startup reporting show **suggested**, **explicitly approved**, and **not approved/not evaluated** destinations separately. Before F1 ships, hints can be displayed without enabling any filtering behavior. After F1, only effective host configuration and explicit `--allow-host` additions grant destinations; installing or launching a definition never merges hints into that set. A hint does not change `none` to `filtered`, start a companion, or waive a preparation approval. Use the exact-host rules of NET-13; wildcard hints are not accepted in version 1. Hints are not mandatory dependencies and do not themselves block a launch; actual denied connections fail normally.

**AGT-08.** Build all guest argv through existing safe command construction. For a generic adapter, execute the declared guest program; for a reviewed client adapter, validate its logical command then let that adapter resolve the actual guest binary and permitted defaults. A working directory changes only the guest process's directory; a missing directory fails without creating a host path or transferring files. `auto` uses a PTY only when both the host input and output are terminals, `required` rejects missing terminal input/output, and `never` uses non-PTY execution. If the selected adapter does not yet support a requested mode, return an explicit compatibility error rather than replacing its transport. Preserve terminal restoration, resize, signals, passthrough argv, and exit status through existing transport code.

**AGT-09.** Resolve environment selection in this order: explicit CLI image/profile, definition image/profile, existing configuration defaults. Treat a profile selection as one set; do not append definition profiles to an explicit CLI selection. Reuse existing profile normalization, derived-image naming, staleness checks, and preparation authorization. Unknown profiles, conflicting selectors, incompatible existing-instance requirements, or an absent executable produce actionable failures, not an implicit install or VM recreation. An image requirement is not a promise of executable/version availability; only actually checked facts may be reported as verified.

**AGT-10.** Freeze and hash the validated definition used for each launch. Record its source/hash, adapter ID/contract version, selected environment recipe identity, and whether defaults were overridden. Keep definition identity separate from image recipe identity: display, argv, working-directory, terminal, auth-binding, and runtime-environment changes do not invalidate an unchanged installation recipe. A profile or image-selection change can require different preparation. Matching image metadata does not establish the currently installed agent version or undo runtime package updates.

**AGT-11.** A compiled adapter descriptor is the only place that can associate a client configuration contract with a provider-auth contract. Compatibility checks cover the selected executable, requested options, config ownership, auth mode, and required provider operations. `auth_adapter: openai` is not implicitly accepted merely because OpenAI is a known provider; there must be an exact registered client-compatible binding. Adapter implementations can reuse existing providers without opening additional broker operations. Failed compatibility checks occur before resolving credential commands or starting a new VM whenever local facts suffice.

**AGT-12.** `launch.environment` supplies bounded literal **guest** defaults only. The initial compiled allowlist is `TERM`, `COLORTERM`, and `NO_COLOR`; allow at most these three entries with values no longer than 128 UTF-8 bytes and no control characters. Expansion of this list requires review. Reject all other names, including provider credential/base-URL variables, proxy variables, executable-search or code-loader variables, and SSH connection/agent variables. There is no host lookup, `${...}` substitution, `cmd:` execution, or vault resolution in this object.

For permitted ordinary variables, explicit host-authorized CLI/session values override host configuration, which overrides definition defaults; preserve existing precedence among CLI and configuration sources. Values owned by a credential/configuration adapter, the transport, or filtered networking are reserved and cannot be overridden through this new surface. Materialize defaults through `GuestSession`'s controlled environment path, never by appending `KEY=value` text to a host shell command. Passthrough arguments are not recorded in ordinary audit logs, because users may supply sensitive values themselves.

**AGT-13.** Resolve both built-in and installed definitions into an immutable `AgentLaunchPlan` before side effects. It contains definition identity, selected environment, guest argv/directory/terminal, non-sensitive defaults, requested adapter binding, effective host policy, separate network hints, and unresolved compatibility/preparation checks. It contains no resolved credentials or capability values. A prospective plan is not permission to launch: the existing runtime and applicable companion readiness checks still gate hand-off.

For an already running VM, validate that the selected adapter's existing bootstrap requirements can be satisfied without changing boot-scoped policy or replaying provisioning. Otherwise refuse with restart/recreation guidance. Merely changing the definition file must not restart a VM, resolve another provider credential, copy config, install software, push a workspace, or mutate a live network grant. Ordinary new launch arguments or directory choices can take effect on the next compatible launch; they do not rewrite a running session.

**AGT-14.** Catalog replacement affects future launches only. Keep the current launch's validated snapshot in memory; never re-read a definition halfway through execution or cleanup. Persist only the bounded provenance/outcome needed for status and audit, with no capability, resolved credential, or caller passthrough argv. Use a distinct launch identity for concurrent invocations rather than overwriting a single mutable `last-agent` field. Inspection of legacy launches may report definition metadata as unavailable. A failed catalog write preserves the previous installed definition.

**AGT-15.** Report unsupported capabilities explicitly: unknown adapter, unsupported terminal/permission option, incompatible auth mode, missing image/profile, required preparation, unavailable guest executable, or boot-policy mismatch. Errors must name the relevant requirement without printing secrets. Do not claim file-only support for an authenticated client until its actual configuration and operation requirements have been exercised against a reviewed binding. Failures never choose a different agent, disable filtering, or forward a raw key as a convenience fallback.

### 6.6 Incremental migration and release scope

1. **Common model, existing implementations.** Introduce `AgentDefinition`, `AgentLaunchPlan`, and the reviewed registry. Add immutable descriptors for Claude/Codex. Wrap existing launch/config/auth functions; leave the broker's routes and credential handling intact. F2's initial `run` uses these descriptors.
2. **Installed files.** Add local catalog list/inspect/add and generic no-auth launch behavior. Permit compatible custom variants to select the shipped reviewed adapters. Keep legacy `coop claude`, `coop codex`, agent updates, and existing configuration sections working through shared services rather than recursively invoking commands.
3. **Additional authenticated clients.** Qualify and register client-specific bindings incrementally. No new top-level command, provider credential store, automatic network grant, or duplicate image builder is required merely to add one. A definition cannot substitute for missing client compatibility work.

The second delivery increment is complete only when installed definitions, a controlled generic tool, and custom variants using both shipped adapters pass T13, T17, and T18. Additional authenticated clients are not prerequisites for that increment and are not advertised speculatively. No F1 companion, runtime protocol-5 boot ID, wildcard-host support, or four-executable release is required for F3. Security-related validation of the existing broker is still required for adapter-backed launches.

## 7. F4 — Environment inspection, cache management, and editing

### 7.1 Extend, do not replace, the image cache

Sandboxy's warm-start experience is useful, but Coop already clones cached image disks and detects recipe changes. It also records that downloaded agent versions are not currently part of its staleness hash.[^C2] This feature makes the distinctions visible and adds controlled editing.

```text
coop images inspect <name> [--json]
coop images cache status [--json]
coop images cache prune [--dry-run] [--yes]
coop images edit <base> --as <new-name> [--network none|filtered|open]
                 [--allow-host HOST ...]
```

Existing `coop images` listing and `--delete` behavior remain compatible. Subcommands must coexist with that surface rather than replacing it silently.

**ENV-01.** `inspect` reports source type (recipe-built or manual snapshot), resolved base/image digest, recipe hash, profiles/features, guest user, creation time, runtime/kernel compatibility identity, known installed agent versions, and cache/instance references. Unknown legacy fields are displayed as unknown, not guessed.

**ENV-02.** Report why an environment is reusable or stale: missing artifact, changed recipe, profile/feature change, schema incompatibility, or incompatible runtime preparation. Do not equate a matching recipe hash with current upstream packages or a bit-for-bit reproducible rebuild.

**ENV-03.** Extend existing recipe identity to include any new environment-affecting inputs: descriptor-selected recipe, resolved base and feature digests, build-script content, guest architecture/user, and a versioned preparation format. Capture installed tool versions when available. A script that downloads an unpinned latest version remains a mutable input; explicit rebuild resolves it again. Version reporting alone does not repair reproducibility.

**ENV-04.** Cache creation and image publication keep the existing fresh-artifact, verify, then publish transaction model. Concurrent equivalent builds serialize or converge on a verified result. Failed or interrupted preparation leaves the prior published image intact. Session changes never write back into a shared template implicitly.

**ENV-05.** Cache status distinguishes image manifests, reusable unpacked disks, and instance disks. Report logical size and measured allocation where available, marking shared APFS allocation as non-exclusive. Do not add per-clone sizes and present the sum as space that deletion will recover.

**ENV-06.** Pruning is limited to unreferenced, rebuildable cache artifacts. Protect artifacts referenced by named images, instance records, in-flight transactions, edit sessions, or an active owner. Recheck reachability under the existing lock discipline immediately before deletion. `--dry-run` prints candidates; mutation requires confirmation or `--yes`. Never delete user instances, named images, credentials, kernel policy, host-key pins, or pending workspace stages as a side effect of cache pruning.


Cache inspection and deletion must cross the runtime's supported CLI, not inspect or unlink private runtime files from `CoopHost`. Add versioned `cache inspect` and `cache prune` runtime operations when the existing image/disk commands cannot provide the required information. Inspection returns opaque artifact IDs and a generation token. Prune takes that token plus the host-protected image set over stdin, rejects a stale generation, and recomputes runtime reachability under its own locks. The host holds the relevant image/instance publication locks while supplying its protected set; all concurrent create/build/edit paths must participate in the same documented lock order. If a complete protected set cannot be established, prune refuses. The early inspection increment may report unavailable cache details; safe prune ships only after these operations and concurrency tests exist.

### 7.2 Optional clone-edit-publish workflow

This is a later convenience increment over `commit`, not permission to edit the canonical cache in place.

**ENV-07.** `images edit BASE --as NEW` clones a verified base into an isolated maintenance/edit instance. Reject an existing output name in version 1. Do not open a project VM or allow ordinary project-affinity reuse of this instance.

**ENV-08.** The edit VM receives no project workspace, host config copies, provider credential/capability, GitHub token, inherited `--env`, local-model tunnel, port forward, project hook, or agent bootstrap. Its default network is `none`; `filtered` requires an approved host list and F1, and `open` requires explicit selection plus a visible preparation-network warning. This network choice is independent of normal workload presets.

**ENV-09.** After the shell exits, show the proposed output name and require an explicit save/discard decision. Do not automatically publish on terminal disconnect or a failed shell launch. On save, stop the edit instance and use the existing commit/maintenance transaction to strip machine identity and publish a new image. Never overwrite BASE.

**ENV-10.** Mark the resulting image as a manual snapshot with its parent identity and creation metadata. It is not recipe-reproducible; encourage moving durable changes into a profile. Known absence of automatic credential injection is not proof that an operator or installed program did not put a secret on the disk. Do not promise general secret scrubbing.

**ENV-11.** Preserve a failed edit or publication under an explicitly recoverable edit-session record, without exposing it through project-affinity lookup. Cleanup follows ownership checks equivalent to disposable runs. Record edit preparation, publication, discard, and failure in the host audit trail.

## 8. F5 — Effective-policy startup summary and timings

### 8.1 Human-facing summary

Before handing the terminal to an agent, print a compact, escaped summary to stderr. Example after successful verification:

```text
Instance: service-fix                    Agent: Claude Code
Environment: node-python                Recipe: 0b7d… (reused)
Workspace: host copy -> /workspace       Live host mounts: none
Provider: Anthropic via host broker      Raw provider forwarding: none
Network: filtered, host-only VM          Approved destinations: 4, port 443
Host services: may remain reachable     Return policy: staged
Lifecycle: persistent                   TTL: 8h remaining
```

The example is a proposed format, not captured output. Print observed values, not fixed reassurance. Under legacy raw forwarding, print a warning naming the affected provider/variable names without their values. Under open egress, say `open`, not `sandboxed network`.

**UX-01.** Show instance identity, selected agent, built-in/installed definition provenance and hash, selected reviewed adapter, image provenance/cache state, guest working directory/terminal mode, workspace transport, raw-credential forwarding status, broker health, egress policy/hash, approved destinations, host-service limitation, return policy, lifecycle, and TTL. Keep requested network hints separate from grants. Selecting `auth_adapter: none` must not conceal authority already present in a reused VM. `--rm` must visibly say that guest changes will be discarded.

**UX-02.** `status` separates recorded effective boot policy from current config when they differ. On an already running instance, the launch summary reflects the former. Do not report file-level or network isolation properties the runtime/companion checks did not establish.

**UX-03.** Summaries never print secret values, capabilities, authenticated proxy URLs, or raw credential commands. Treat agent definitions, paths, hostnames, and guest/runtime messages as potentially malicious terminal input; escape controls and bound lengths. Long lists show a bounded preview and direct the user to a structured inspection command.

**UX-04.** Preview JSON is versioned and contains: action (`create`, `restart`, `attach`, or `blocked`), instance match, definition ID/source/hash, adapter ID/contract version, resolved environment identity and selection origin, guest working directory/terminal mode, preparation requirement, desired policy, last-recorded policy if any, explicitly approved hosts, separate definition network hints, unresolved compatibility/readiness checks, and cleanup intent. Report only the names/origins of session environment inputs, not arbitrary values. It contains no capabilities, resolved credentials, or caller passthrough argv. Preview is distinguishable from verified runtime status.

**UX-05.** Record monotonic durations for resolution, preparation, disk creation/clone, VM boot, SSH readiness, companion readiness, workspace transfer, bootstrap, and agent hand-off. Identify reused/skipped phases explicitly. Keep timing events separate from untrusted agent stdout.

**UX-06.** Do not promise Sandboxy's reported sub-second warm start for Coop. Establish a baseline on supported hardware and separately measure wrapper overhead, full startup, and workspace-copy time. For a warm attach, the acceptance target is no image/build/network mutation and no extra external service request; timing thresholds must be set from that measured baseline, not invented here.

**UX-07.** After a persistent run, show a single actionable workspace-return command. After a disposable run, show the independently recorded cleanup outcome. Do not imply that an exited agent means a VM was destroyed or that a destroyed VM's unexported changes can be recovered.

## 9. Integration, state, and compatibility

### 9.1 Implementation map

Paths marked **new** are proposed files/packages, not existing implementation.

| Area | Reuse / extend | Proposed addition |
|---|---|---|
| Validated policy values | `Sources/CoopCore/` | **New:** `EgressPolicy.swift`, `AgentDefinitionID.swift`, `AgentAdapterID.swift`, `AgentLaunchID.swift`, `RunSessionID.swift` |
| Configuration | `CoopConfig.swift`, `ConfigDecoding.swift`, `ConfigValidation.swift`, JSONC preflight | **New:** `AgentDefinition.swift`, `AgentDefinitionDecoding.swift`, and typed egress-filter decoding; existing preset resolution remains authoritative |
| Agent catalog and launch planning | Existing configuration loading, state reads/writes, guest command types | **New:** `AgentCatalog.swift`, `AgentLaunchPlan.swift`, `AgentDefinitionCommands.swift`; immutable shipped descriptors and atomically installed host copies use the same model |
| Reviewed client adapters | `AgentCommands.swift`, `BootstrapClaude.swift`, `BootstrapCodex.swift`, `GuestSession.swift`, `ProxyLifecycle.swift` | **New:** `AgentAdapterRegistry.swift`; typed wrappers around existing config/auth/launch paths; no JSON-defined credential destinations or host plugins |
| Session orchestration | `UpCommands.swift`, `AgentCommands.swift`, `AppleLifecycle.swift`, `GuestSession.swift` | **New:** `RunCommands.swift`, `RunSession.swift`, `SessionReadiness.swift`; factor shared operations rather than invoking the CLI recursively |
| Egress lifecycle | `ProxyLifecycle.swift`, `ProcessRunner.swift`, `SSH.swift`, `SeatbeltProfile.swift` patterns | **New:** `EgressLifecycle.swift`, `EgressSupervisor.swift`, a separate confinement profile; provider policy is not generalized |
| Network companion | Existing dependency pinning/build conventions | **New:** `coop-egress/` package with policy, transport, executable, and test targets |
| Runtime verification | `IsolationGate.swift`, `RuntimeProtocol.swift`, `SandboxRuntime.swift` | Explicit `requiresHostOnlyNetwork` mapping and boot identity support |
| Runtime boot identity | `coop-sandbox/Sources/CoopSandboxCore/Owner.swift` and control/inspection types | Protocol 5: add host-generated `live.boot_id`, renewed for each actual boot/owner replacement |
| Images | `ImageBuild.swift`, `ImageRecords.swift`, runtime disk commit/maintenance paths | Inspection, cache reachability/pruning, isolated edit-session orchestration |
| State and audit | `StateStore.swift`, `BoundaryAudit.swift`, existing journals | Feature-bearing record schema, boot network policy, run/edit session records, redacted per-launch definition/adapter provenance, bounded egress events |
| Presentation | Existing diagnostics, read/status commands | **New:** `SessionSummary.swift`, versioned preview output, monotonic phase measurements |
| Distribution | `scripts/build-release.py`, installer, updater, release preflight/workflows | F3 retains the three-executable layout; F1 adds signing, attestation, verification, and installation of `coop-egress` |

### 9.2 Record ownership and authority

Proposed records under `<data_dir>/backends/apple-container-v1`:

| Record | Contents | Authority / lifetime |
|---|---|---|
| `instances/<name>/network-policy.json` | Mode, approved hosts, limit-profile version, field origins, policy hash, boot ID | Immutable effective policy for one boot; no capability |
| `instances/<name>/egress.json` | Companion identity, tunnel identity, local endpoint, expected boot/policy, observed health | Operational state only; reverify process identity before use |
| `instances/<name>/egress-capability` | Local proxy capability | Dedicated 0600 secret file; revoke/remove on teardown |
| `run-sessions/<session-id>.json` | Owner, workspace association, creation operation, instance/sandbox identity, lifecycle intent, outcome | Survives instance deletion; authoritative cleanup intent |
| `edit-sessions/<session-id>.json` | Parent image, output name, temporary sandbox identity, edit/publish phase | Protected against cache pruning until resolved |
| `agent-launches/<launch-id>.json` | Definition ID/source/hash, adapter contract version, environment recipe identity, instance association, timing/outcome | Descriptive launch history only; no cleanup authorization, resolved credentials, capabilities, or caller passthrough argv |

All directories are private and all records use existing no-follow, bounded reads and atomic writes. File names use validated IDs. Lock acquisition follows the existing documented order. No new code edits runtime-owned records directly. The definition catalog lives separately at `<data_dir>/agents/<id>.json`; its schema version is independent of runtime/instance record versions. Per-launch history is descriptive, not a source of network, credential, or cleanup authority; cap and rotate completed history without deleting unresolved run/edit ownership records.

Run lifecycle states are `planned -> creating -> ready -> running -> finalizing -> completed`; failures enter `retained` or `cleanup_pending`. Record a mutating operation's intent before calling the runtime and reconcile uncertain results before a new mutation. A missing or corrupt record is not permission to destroy a matching name.

Keep redacted completed run summaries and audit outcomes outside deleted instance directories. Extend audit lookup with `--session ID`. Set a bounded retention policy for completed summaries; unresolved cleanup records and pending review data are never aged out automatically. Egress event collection is host-owned, capped and rotated; aggregate denial counts rather than writing an unbounded event for every hostile connection.

### 9.3 Boot-bound egress supervision

Protocol 5 adds a random, host-generated `live.boot_id` to runtime inspection. A restored disk does not restore this identity. New-host readers may operate legacy protocol-4 runtimes for existing compatible commands, but filtered egress requires protocol 5; missing capability fails before launch.

A per-VM host supervisor runs independently of the invoking terminal. It checks the same runtime owner and boot ID at least once per second, and renews a short companion lease only after successful confirmation. The companion receives renewals through a private inherited control pipe, never through guest HTTP. It gets no runtime control socket or permission to execute runtime commands.

The companion closes grants and sockets after two seconds without a valid renewal, on control-pipe EOF, on shutdown, or at the recorded absolute session deadline, whichever applies first. The supervisor closes the pipe immediately when it observes a changed owner/boot, an expired session, or explicit teardown. Use monotonic time for lease intervals and the existing host-clock deadline for TTL. These intervals define the bounded stale-grant window and must be exercised by process tests; they are not a claim of instantaneous revocation.

### 9.4 State migration and downgrade behavior

The baseline host checks explicit state schema versions and currently uses version 2 for instance records, journals, and image manifests.[^C10] Do not hide security-relevant changes in optional fields that an older host can ignore.

Introduce schema version 3 for records requiring filtered-egress enforcement, disposable/edit ownership, or other new security semantics. New readers explicitly dispatch supported version-2 and version-3 formats. Upgrade related feature-bearing records transactionally before the feature is enabled; preserve unmodified legacy records when no new semantics are needed. Add required-feature names within version 3 for precise diagnostics, not as a replacement for version checking.

Installing definition files or recording descriptive launch provenance alone does not require converting every existing instance to version 3. F3 does not persist a new per-agent isolation policy and does not depend on runtime protocol 5. If an implementation introduces durable credential/boot restrictions beyond existing semantics, those are security-relevant feature-bearing state and must use the explicit versioned migration rather than descriptive launch history.

A baseline host must refuse feature-bearing version-3 records. Verify this against the actual baseline executable. Do not offer a lossy downgrade that turns `filtered` into `open` or adopts a disposable instance as persistent. Supported rollback requires stopping affected instances with a compatible tool and explicitly recreating them under older semantics. Unknown schema, mode, runtime protocol, or capability values fail closed.

### 9.5 Distribution and operational compatibility

The early F2/F3/F5 increments retain the existing three-executable archive; shipped agent descriptors are compiled or bundled inside the signed host product, not downloaded during launch. Only the F1 increment expands the release archive to `coop`, `coop-sandbox`, `coop-proxy`, and `coop-egress`. Resolve companions adjacent to the host executable using the existing distribution model. Verify archive identity, signatures/checksums/attestation policy, companion versions, and required capabilities before replacement. Test upgrades from the current three-executable archive layout, interrupted replacements, and mixed-version failure diagnostics.

A missing `coop-egress` blocks `filtered` boots with a repair instruction; it does not affect compatible existing `open` or `none` paths or trigger fallback. Release preflight must reject an incomplete new archive even though a developer may run non-filtered commands without that companion. No F1 release claim is made until this four-binary transition passes; independently qualified earlier increments are not blocked by it.

## 10. Acceptance and evidence matrix

Every gate begins **not executed**. Passing evidence must name the tested commit, companion hashes, macOS/toolchain, command, and result. A documentation review or successful build alone does not close a runtime gate.

| Gate | Required evidence / pass condition |
|---|---|
| T01 Configuration compatibility | Existing fixtures retain their behavior. Preset precedence, explicit mode overrides, empty host sets, duplicate keys, size limits, and unknown values have deterministic tests. |
| T02 Hostname/authority policy | Exact-match, case, terminal-dot, invalid-label, wildcard, IP-literal, numeric-alias, Unicode, percent-encoding, host/port mismatch, and suffix-confusion cases. All unapproved forms fail before resolution. |
| T03 Resolved-address policy | Private, loopback, link-local, multicast, special-purpose, mapped IPv6, host-interface addresses, mixed public/private answers, DNS rebinding, and connect-time re-resolution. No forbidden address reaches the production connector. |
| T04 CONNECT wire correctness | Fragmented/coalesced input, duplicate headers, authentication failures, framing ambiguity, unsupported methods/ports, and success-response framing. A successful tunnel is byte-transparent; proxy authentication never appears upstream. |
| T05 Resource exhaustion | Idle unauthenticated sockets, slow heads, stalled DNS/connect, saturated slots, repeated denials, slow readers/writers, and disconnects during each phase. Buffers/work remain bounded and normal service recovers after pressure ends. |
| T06 Confined companion | Actual signed release-profile process can bind, resolve and connect to approved test destinations; filesystem writes, child execution, unrelated ports, inherited proxy use, and secret-bearing startup argv are rejected/absent. |
| T07 Real-VM network boundary | On supported hardware, filtered VM has the expected single host-only interface, no configured direct Internet path, and no newly exposed host mounts/relays. Approved HTTPS tooling works; unapproved destinations and direct attempts fail. Separately measure and report host-service reachability rather than concealing it. |
| T08 Broker composition | Claude and Codex use their existing broker routes under filtered egress. With synthetic provider credentials, guest environment/files and egress process startup/state contain no raw key. Required-mode forwarding guards remain effective on `run`. Existing broker endpoint-policy tests still pass. |
| T09 Capability isolation/revocation | VM A cannot authenticate to VM B's companion. Previous-boot tokens fail. Stop/destroy/TTL, killed owner, changed boot ID, supervisor death, and missed renewals close grants within the specified lease behavior; no fallback path appears. |
| T10 Persistent `run` parity | Create/restart/attach outcomes agree with existing project rules. A warm attach does not push, rebuild, replay hooks, or mutate creation settings. Multiple matching projects fail explicitly; named selection does not substitute the caller's directory. |
| T11 Disposable ownership | Existing-name refusal; no project-affinity adoption; crash at every journal boundary; stale/reused PIDs; pending review stages; concurrent mutations; partial cleanup. Only proven session-owned objects are deleted. Reconciliation is idempotent. |
| T12 Terminal and exit handling | Claude/Codex interactive runs, redirected input, required/non-PTY generic modes, resize, SIGINT/SIGTERM/SIGHUP, transport failure, nonzero agent exit, and cleanup failure. Host terminal is restored and agent/cleanup outcomes remain distinguishable. |
| T13 Definition trust | Unknown/duplicate keys, all schema budgets, symlinks, foreign ownership, reserved definition/adapter IDs, unsupported fields, host hooks, secret/forwarding declarations, and launch-injection strings. Explicit add uses the reviewed snapshot; replacement is atomic and cannot affect active launches. Repo-local files are never auto-discovered, auto-executed, or auto-approved. Literal defaults accept only the compiled non-sensitive variable allowlist; network hints grant nothing. |
| T14 Environment safety | Recipe changes trigger the existing rebuild path. Unchanged recipes reuse artifacts. Concurrent builds, failed publication, referenced-cache pruning, edit crash, and save/discard protect the original image and user instances. |
| T15 Output/preview | Preview makes no subprocess/network/credential/config-write/update-check call. Agent stdout is not polluted. Fixtures cover control-character escaping, long fields, redaction, unknown facts, raw-forwarding warnings, and desired/effective-policy drift. |
| T16 Migration/distribution | Version-2 fixtures read without changing old behavior. Baseline host rejects version-3 feature records. Early F3 catalog/launch tests pass with the three-binary layout and compatible protocol-4 runtime, without enabling F1. Separately qualify protocol-4 filtered refusal and the F1 three-to-four binary upgrade, signatures/provenance, interruption, and clean-machine install/run/update/uninstall. |
| T17 Reviewed adapter dispatch | Built-in definitions and installed Claude/Codex variants dispatch the same reviewed implementations with the intended permission and terminal semantics. Controlled real-VM broker tests use synthetic provider credentials; configured proxy and required modes keep raw keys out of guest data and launch history. Test `auto`/`required`/`off`, missing authorization, incompatible auth/config modes, unknown adapters, and conflicting managed settings; no silent fallback or route widening. New client/provider bindings need their own pinned-client integration evidence. |
| T18 Definition resolution and independence | A controlled generic tool exercises argv, passthrough, guest directory, literal-default precedence, and terminal modes. CLI environment selection replaces rather than unions definition selectors. Changed launch metadata leaves image recipe reuse intact; changed profiles use existing preparation checks. Missing requirements cause no unapproved installation/build, implicit push, or recreation; explicitly authorized preparation still uses the existing image path. Definition snapshots/history survive concurrent catalog replacement. Preview remains side-effect-free; F3 works without `coop-egress` or F1, hints remain informational, and `none` does not conceal existing guest authority. |

Use injected resolvers/connectors for exhaustive policy tests and separate test executables for controlled transport fixtures. A test bypass allowing local/private destinations must not be reachable through release configuration, environment variables, or CLI flags. Real release-process refusal tests must execute the production policy.

## 11. Delivery sequence

Feature IDs are stable reference labels; **F3 ships before F1**. Agent definitions do not wait for the general egress proxy or optional image editing.

| Increment | Deliverable | Prerequisites / release gate |
|---|---|---|
| 1 | F5 preview/summary and F2 persistent `run`; F3's common definition/launch-plan types and immutable built-in descriptors | Existing Claude/Codex implementations remain behind registry wrappers; T01, T10, T12, T15 and built-in dispatch regression coverage |
| 2 | F3 host-installed definitions, catalog commands, generic launch behavior, and compatible selection of shipped reviewed adapters | T13, T17, T18 and applicable T10/T12/T15; early-layout compatibility portion of T16; no F1 or fourth binary required |
| 3 | F2 explicit disposable runs and cleanup reconciliation | Version-3 ownership records; T11 plus interruption and state-migration coverage |
| 4 | F4 image inspection/cache diagnostics | Existing image recipes/transactions; T14 inspection fixtures; no new networking |
| 5 | F1 pure policy, companion, supervisor, runtime boot ID, configuration, and four-binary packaging | T01–T09 and F1 portions of T16; re-run adapter composition under filtered egress; independent security review of the actual candidate |
| 6 | F4 safe prune and optional clone-edit-publish | Reachability/ownership qualification; T14; filtered editor networking also requires F1 |

After increment 2, additional reviewed client/provider adapters can ship independently when their own T17 compatibility evidence is complete. Do not require a new top-level command or a new credential broker for each client. Do not treat an installed definition as evidence that an unqualified authenticated client is supported.

Each increment must work without unfinished later features. Before F1, `network_hints` is inspectable metadata, not an active network grant, and no filtered-mode flag is advertised. Keep legacy default behavior stable throughout the sequence. Use small reviewable changes separating parsing/model, shared orchestration, reviewed adapter dispatch, process transport, lifecycle/state, user interface, and distribution. Tests listed for an early increment close only the portions exercised at that increment; later network/distribution cases remain open.

## 12. Tradeoffs and deferred work

**Separate egress executable.** Adds packaging, process supervision, and tests, but avoids turning the credential-bearing proxy into a guest-selected destination relay. Combining those responsibilities is rejected for this version.

**Exact hosts and port 443 only.** Less convenient than Sandboxy's wildcards/plain HTTP, but the initial authority is explicit and testable. Wildcard rules need separately specified apex/subdomain semantics and shared-service risk review. Plain HTTP needs its own request-target/Host/framing/connection-reuse policy; it is not a small switch on CONNECT.

**Explicit preparation.** A cold one-command run may require one approval or `--prepare`. This is intentional: filtered workload policy must not conceal a broader network-enabled build. Moving more plugin installation into reproducible images is a possible later improvement, not a prerequisite for falsely claiming offline compatibility.

**Agent definitions are a first-class extension point, not a host plugin framework.** The shared model removes duplicated launch orchestration and supports useful custom variants immediately. Keep installation in profiles, host authority in policy, and client configuration/auth in reviewed compiled bindings. Custom files may select those bindings; they are not permanently limited to no-auth tools. This deliberately stops short of claiming that a provider label or a Pi/Aider launch recipe alone proves compatibility with the broker's allowed operations.

**Early adapter migration stays incremental.** Claude/Codex wrappers preserve existing code paths and command behavior while metadata moves into one model. Do not turn this into a wholesale rewrite of security-sensitive bootstrap code or removal of existing configuration sections. Such a rewrite is a prerequisite for neither F3 nor F1. New authenticated clients require a small reviewed compatibility addition, not arbitrary JSON instructions for secret delivery.

**Literal environment defaults are deliberately narrow.** Display/terminal preferences are useful in definitions. Loader variables, provider URLs, raw secrets, arbitrary host forwarding, and shell expansion belong nowhere in this new data surface. Broader supported ordinary variables may be added through review; installation requirements remain image/profile concerns.

**Manual image edits.** Convenient for exploration, but not reproducible and not guaranteed secret-free. Save a new image; do not silently modify a shared template or replace recipe provenance.

**Host-service isolation remains separate.** Closing guest access to Mac services, host DNS relays, and other host-provided escape routes requires a distinct network-boundary design and real-VM validation. Do not describe F1 as closing that gap.

**No live mounts or automatic output application.** Their convenience is not worth changing the central filesystem boundary in this proposal. Independent review-artifact export for disposable sessions can be designed later; the first release never deletes an unapplied stage merely to satisfy `--rm`.

## Sources

Repository links are pinned to the inspected revisions. They support the baseline and borrowing rationale, not an assertion that the proposed features already exist.

[^S1]: Apple Containerization, [Sandboxy README](https://github.com/apple/containerization/blob/f24df2ac817df66fe149a80103251dec987c32dc/examples/sandboxy/README.md): session workflow, caching, editing, mounts, network filtering, and persistence.
[^S2]: Apple Containerization, [HostProxy.swift](https://github.com/apple/containerization/blob/f24df2ac817df66fe149a80103251dec987c32dc/examples/sandboxy/Sources/sandboxy/HostProxy.swift): hostname matching and CONNECT/plain-HTTP implementation.
[^S3]: Apple Containerization, [AgentDefinition.swift](https://github.com/apple/containerization/blob/f24df2ac817df66fe149a80103251dec987c32dc/examples/sandboxy/Sources/sandboxy/AgentDefinition.swift): agent definitions, built-ins, credential-variable forwarding, and mounts.
[^C1]: Coop, [Command reference](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/docs/commands.md): current `up`, `start`, setup, agent, and image command behavior.
[^C2]: Coop, [Images and profiles](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/docs/images-and-profiles.md): existing golden images, derived-image reuse, recipe hashes, cloning, commit/restore, and version limitations.
[^C3]: Coop, [IsolationGate.swift](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/Sources/CoopHost/IsolationGate.swift): enforced host exposure, init, network, and per-hand-off checks.
[^C4]: Coop, [Credential proxy](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/docs/credential-proxy.md): fixed provider transport, operation policy, credential non-exposure, and limitations. The detailed `proxy.mode` section is used for default semantics rather than the document's older introductory opt-in wording.
[^C5]: Coop, [Runtime README](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/coop-sandbox/README.md): process ownership, protocol 4, host-only/shared network modes, disk transactions, and launchd behavior. Its introductory opt-in-backend wording is not used to infer current backend selection.
[^C6]: Coop, [CoopConfig.swift](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/Sources/CoopConfiguration/CoopConfig.swift): egress modes, required/auto/off credential policy, preset precedence, TTL, and workspace pull defaults.
[^C7]: Coop, [Workspace sync](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/docs/workspaces.md): project copying, explicit return paths, stage placement, validation, and application behavior.
[^C8]: Coop, [Architecture](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/docs/ARCHITECTURE.md): current package/process boundaries, one concrete backend, subprocess and state invariants.
[^C9]: Coop, [ProxyLifecycle.swift](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/Sources/CoopHost/ProxyLifecycle.swift): current loopback listeners, reverse tunnels, capability persistence, and startup handling.
[^C10]: Coop, [StateStore.swift](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/Sources/CoopHost/StateStore.swift): private atomic records and strict schema-version checks.
[^C11]: Coop, [AgentCommands.swift](https://github.com/chr33s/coop/blob/7cacce6fd92df07a690b8b6774c437e9376cd14e/Sources/CoopCLI/AgentCommands.swift): existing Claude/Codex command wrappers, passthrough handling, permission options, and shared bootstrap/session wiring.
[^N1]: IETF, [RFC 9110, section 9.3.6 — CONNECT](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6): tunnel semantics, explicit port, proxy authentication, target restrictions, and successful-response framing.
[^N2]: IANA, [IPv4 special-purpose address registry](https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml), consulted 2026-10-01. An implementation must pin and test its address classification rather than fetch policy dynamically at runtime.
[^N3]: IANA, [IPv6 special-purpose address registry](https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml), consulted 2026-10-01. Transition forms and host-local addresses require additional explicit handling in this proposal.
