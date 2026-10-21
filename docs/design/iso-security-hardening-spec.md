# iso security hardening: final implementation specification

**Status:** Final design specification v1.0, implemented. Outbound removal is scoped to tracked files deleted on the host, applied by a permitted push.  
**Date:** 20 October 2026  
**Target:** `chr33s/iso`, macOS 27+ on Apple Silicon; supported Linux and macOS guests, local and enrolled remote execution hosts.  
**Purpose:** Combine the coop comparison, critical boundary review, and supplied secure-defaults design into one implementation contract with explicit limits, compatibility decisions, and release gates.  
**Revision:** Final critical review of the integrated host-boundary and secure-defaults specification, 20 October 2026. Incorporates `iso-secure-defaults-main-2026-10-20.md`; the source attachment is unchanged. New syntax described below is an implementation requirement, not a claim that it exists in the pinned source.

## 1. Decision and scope

Adopt the two immediate invariants: guest environment names must not configure host processes, and workspace return must neither execute host Git nor install protected Git administration entries. Reuse iso's existing SSH, native stage/review/apply, policy, and supervision machinery. Do not replace the VM architecture, remove devcontainers, introduce a new guest RPC, or build a synchronization engine as prerequisites.

The critical review adds receive-writer lifetime, control-state/destination separation, complete preflight, accurate partial outcomes, terminal environment precedence, safe teardown and supported Git-layout protection. The secure-defaults integration adds explicit input/credential selection, stage-bound grants for known execution-sensitive paths, qualified brokered defaults, policy provenance, required-provider readiness, restart/deadline enforcement, migration and reuse of existing audit/CI boundaries. Updater binding, conservative allocation, guest push checks and hook ordering remain independent follow-ups.

This document supersedes the recommended implementation behavior in the earlier downloadable `iso-host-boundary-hardening-plan.md` and consolidates the current recommendations from the supplied secure-defaults document. Its historical vmnet/pf text and older rebase notes are not additional requirements. It does not claim approval to merge or that the repository already implements the requirements. **MUST** identifies an acceptance requirement for the relevant deliverable. Priorities are implementation priorities, not CVSS severity ratings.

### 1.1 Pinned evidence

| Item | Revision and interpretation |
|---|---|
| Reviewed iso source | [`58fb04089503925070c74630f80edef28b19d9f2`](https://github.com/chr33s/iso/commit/58fb04089503925070c74630f80edef28b19d9f2), checked during the 20 October integration. This final pass is pinned to that revision. |
| Recorded upstream fork point | [`6ac6c2c5e739aadae3f6735f4f3348f2f2671d30`](https://github.com/trailofbits/coop/commit/6ac6c2c5e739aadae3f6735f4f3348f2f2671d30), explicitly recorded in [iso provenance][I-PROVENANCE]. |
| Latest coop main observed during integration | [`9e94b9ee830a10e006e39a7e97e47fc53d103415`](https://github.com/trailofbits/coop/commit/9e94b9ee830a10e006e39a7e97e47fc53d103415). This prepares v0.9.0 through version/changelog changes; it is not evidence that a release has been published. |
| Coop runtime evidence | Immutable source links at `86b2876bdab7f03f414650365d14a1e5f0bb4221`. Subsequent `7c46174` changes release preflight and `9e94b9e` changes versions/notes; the cited runtime behavior is unchanged. |

Evidence is a read-only source and history review. No new end-to-end exploit reproduction, supported-macOS execution, implementation tests, or full audit was performed for this specification. Source-confirmed behavior, inferred consequences, and proposed controls are distinguished below.

### 1.2 Existing documents that need explicit amendments

The repository's older [selective-hardening specification][I-OLD-SPEC] contains historical and normative statements that conflict with the new return contract. Change those clauses when implementing, rather than leaving two contradictory specifications:

| Existing clause | Required amendment |
|---|---|
| §5.1.1 and related acceptance/rollout text retain host Git cleanliness checks | Replace with the no-host-Git rule and explicit overwrite authorization in §5 of this document. |
| §5.11 preserves direct destination writes | Retain the `direct` spelling, but route automatic application through the mandatory validated stage. |
| Early text suggests pull deletions | Preserve the later §5.11.1 decision: return does not delete host files. |
| §5.11.1 says monitoring happens only after transfer | Document the existing transfer-time monitor and its sampling/overshoot limits accurately. |
| Unique-per-operation staging versus one-slot implementation | Specify unique incoming receives with one selected completed stage, as in RET-03. |
| Generic transactional language | State per-file atomic replacement where available and explicit partial outcomes; do not promise whole-workspace atomicity. |

Preserve the existing VM-first trust model, provider-secret classification, optional approval policies, editor enclave, host-key pinning, and boot/policy supervision. This specification grants no new guest network, credential, or host execution capabilities. [Architecture and contributor constraints][I-AGENTS].

### 1.3 Secure-defaults integration and conflict resolutions

The supplied `iso-secure-defaults-main-2026-10-20.md` is design input, not execution evidence. Its 20 October rebase notes take precedence over historical vmnet/pf prose. Both documents use the same iso revision; the main branch was checked again during integration. Older inherited line anchors were not treated as proof without checking the relevant source.

| Supplied material | Integrated contract / decision |
|---|---|
| Latest rebase, executive decision, defaults and onboarding (§§1–2, 9) | DEF-01: change transport and policy defaults independently; qualify Linux brokered first; explicit vmnet for incompatible/macOS workflows. |
| Threat model (§3) | §3: preserve guest root/autonomy, broker limits, explicit guest-held login credentials and existing structural controls. |
| Older “safer today” fragment and pf proposal (§§4, 7.1) | Superseded by the complete brokered target; retain vmnet reachability only as a compatibility limitation. |
| Host-owned grants (§5) | POL-01: frozen effective authority, origins, trusted-config traversal and no secret resolution during reports. |
| Input manifest/history (§6.1) | INPUT-01: immutable selected snapshot, qualified inert discovery or explicit paths; no implicit history or deletion inference. |
| Agent imports / clone auth (§§6.2–6.3) | IMPORT-01 and AUTH-01; also cover separate preferences/TOML reads and devcontainer discovery authentication. |
| Broker readiness / restart / TTL (§§7.2–7.4) | READY-01 and LIFE-01; preserve existing runtime/TTL controls and compose required proofs. |
| Return approval (§8) | RET-09/11: exact stage ID, mandatory sensitive-path grants and safe explicit direct mode. The prior interactive no-ID exception is removed. |
| Migration (§10) | MIG-01: read-only classification, saved-grant reconciliation and fresh-image/data-only migration without destroying the source VM. |
| New audit and iso-ci surfaces | AUD-01 and CI-01: extend existing contracts; history exclusion covers the CI base bundle, not only its overlay. |
| Sequence and acceptance (§§11–12) | §§11–12 below: preserve independently releasable repairs and gate the eventual default switch. |

Integration deliberately rejects subset application as a prerequisite for sensitive-path grants: the first implementation keeps the whole stage and makes no writes while any required named grant is missing. This avoids adding a second partial-approval/remainder state machine to RET-08.

### 1.4 Final design decisions

| Decision | Final disposition |
|---|---|
| Immediate repairs | Environment separation and structural validated return may release independently once their own gates pass. Neither waits for the shipped-default switch. |
| Execution-sensitive return paths | Exact, content-bound approval is mandatory for the secure-default profile; missing approval holds the whole stage with zero destination mutations. |
| Initial return support | Qualified APFS worktrees and export directories, including supported standard gitfiles. Refuse `.git` symlinks and ambiguous/custom in-destination administration targets. |
| Apply authorization | One apply attempt, one exact stage, and a durable begin/consumed record before writes. No reusable approval inbox or subset application. |
| Initial outbound support | Immutable selected data. Qualified inert tracked-path discovery is optional convenience; explicit bounded path selection is a supported fallback. No new history-transfer capability. |
| Lifetime | Default 8h; preserve finite remote and CI contracts. Explicit unlimited is local-only. New admission stops at expiry, with fixed active-revocation and shutdown targets in LIFE-01. |
| Network target | Qualified Linux brokered profile. Explicit vmnet/macOS compatibility is reported with its actual limitations. |
| Release order | Default switch comes last for the advertised workflow set. CI selected-content redesign has its own companion gate; shared regressions still gate changes that affect CI. |
| Deferred mechanisms | Receiver sandbox, hard storage quota, history transfer, whole-workspace rollback, and synchronization baseline remain separate work. |

## 2. Critical review findings

| ID | Finding and evidence | Required disposition |
|---|---|---|
| F-01 | `EnvForward.overlay` inserts original guest names into the host SSH environment; four production launch paths use it. [Evidence][I-ENV] [Remote path][I-REMOTE-LAUNCH] | P0: atomic alias preparation across all four paths. Remove original-name forwarding, not just the overlay. |
| F-02 | A wholesale coop SSH-option transplant would disable iso's guest pinning or break its explicit connector and remote-management authentication. [Evidence][I-SSH] [Management][I-MANAGEMENT] | Preserve separate guest, connector, management, editor, and cleanup authorities. Broader launcher isolation is a separate deliverable. |
| F-03 | PTY attach currently normalizes TERM after overlay. Restoring aliases later would silently reverse that precedence. [Evidence][I-ENV] | Decide effective PTY TERM before encoding and preserve current behavior. |
| F-04 | Direct pull and both apply branches may run host Git; review warnings do not forbid `.git` installation. [Evidence][I-WORKSPACE] [Policy][I-WORKSPACE-POLICY] [Review][I-REVIEW] | P0: no host Git and one protected-path installer across all return modes. |
| F-05 | Ordinary apply can reopen an unchecked destination path; no general return/control-root disjointness check was found. [Evidence][I-APPLY] [Workspace][I-WORKSPACE] | P0: one verified destination handle and rejection of overlapping managed control roots. |
| F-06 | A stage slot is removed before replacement receive; locks close on exec. This creates a source-level lifetime risk if parent death leaves a receiver alive; no production exploit was reproduced. [Evidence][I-STAGE] [Locks][I-LOCK] [Signals][I-CHILDREN] | P0: unique incoming directories plus a writer-lifetime proof; no reuse, promotion, or cleanup while writers may remain. |
| F-07 | Pipeline cancellation is polled while stderr descriptors remain open, then it waits indefinitely. Early closure exposes a control-flow gap; guest-triggerability on the production macOS tuple was not demonstrated. [Evidence][I-PROCESS] | P0: monitor until every writer terminates, independent of stream EOF. |
| F-08 | Ordinary apply does not perform the governed path's complete stage verification before the first mutation. [Evidence][I-APPLY] [Governed path][I-WORKSPACE-POLICY] | P0: complete preflight in every mode, plus per-write revalidation. |
| F-09 | File/symlink-to-directory apply unlinks the old object before mkdir; a failed operation can therefore mutate a path absent from `applied`. [Evidence][I-APPLY] | Refuse destructive file/symlink-to-directory transitions in this release. Report actual effects and uncertainty. |
| F-10 | Existing symlink checks omit the final target component; a link may end at another preserved host symlink. [Evidence][I-STAGE] | Validate the complete target against the planned final tree and existing destination. |
| F-11 | `.git` spelling filters cannot cover arbitrary bare/custom Git layouts, and normalization alone is not a filesystem-equivalence proof. [Current filter limitation][C-WORKSPACE] | Define supported layouts and volumes; protect standard gitfiles without invoking Git; refuse ambiguous cases. Narrow the security claim. |
| F-12 | Rsync-only was previously presented as necessary. It reduces parser variants but does not itself establish containment or stop metadata interpretation. | Preserve qualified transports for the focused fix. Disable any unqualified inbound transport; treat wholesale tar removal as a separate compatibility decision. |
| F-13 | The 500 ms allocated-space monitor is not a hard quota and can overshoot; a host-owned stage is not process confinement. [Evidence][I-STAGE] | Preserve monitoring, fix lifetime gaps, fail on inspection errors, and state resource/parser limits accurately. |
| F-14 | Production updater source overrides and unconstrained asset URL fields remain, while signed checksums, revocations, and downgrade protection already exist. [Evidence][I-UPDATE] [Release model][I-UPDATE-RELEASE] | P1: bind source/asset authority while preserving the mandatory signature chain. Do not claim an arbitrary unsigned-install bypass. |
| F-15 | Allocation uses a listing that skips corrupt instances, then creates an existing directory permissively. [Evidence][I-STATE] | P1: strict reservation scan and exclusive creation; unreadable possible allocations are not free slots. |
| F-16 | Guest cleanliness checks miss gitfiles, suppress some Git failures, and do not inspect SSH termination. Push can then proceed with deletion semantics. [Evidence][I-WORKSPACE] | P1: fail-closed guest preflight. This protects guest work; an adversarial guest can still lie about itself. |
| F-17 | First-boot `bootstrapAndPostStart` runs before workspace copying/cloning and mount synchronization. [Evidence][I-PROJECT] | P1: split bootstrap from the post-start hook and place the hook after successful provisioning. |
| F-18 | Preset, transport, nested limits and import defaults are independent; changing only the preset leaves vmnet/unlimited/import behavior. [Decoder][I-CONFIG-DECODING] [Types][I-CONFIG-TYPES] | Default gate: DEF-01 consistency and explicit null/unlimited semantics. |
| F-19 | Initial archive, push filters and CI snapshots do not implement one selected-content contract. [Workspace][I-WORKSPACE] [CI snapshot][I-CI-SNAPSHOT] | Default gate: INPUT-01 freezes the complete payload and separates history/removal intent. |
| F-20 | Imports follow source links; additional agent settings reads bypass a single staged-copy view. [Staging][I-BOOTSTRAP-STAGING] [Codex][I-BOOTSTRAP-CODEX] [Claude][I-BOOTSTRAP-CLAUDE] | Default gate: disable implicit imports and use one confined snapshot for every import read. |
| F-21 | Clone and devcontainer discovery can select ambient gh/environment tokens independently of off-mode forwarding. Only clone exposes its token to the guest. [Clone][I-GITHUB-TOKENS] [Discovery][I-DEVCONTAINER-GIT] | Default gate: one explicit source-auth decision; no ambient fallback. |
| F-22 | Known execution-sensitive paths are warnings rather than withheld mutations; separate apply permits no stage ID. [Review][I-REVIEW] [CLI][I-WORKSPACE-CLI] | RET-09/11: exact stage and named content-bound grants; missing grant leaves the whole stage unapplied. |
| F-23 | Provider preflight can resolve unused configured secrets, while readiness accepts either provider rather than the selected adapter's provider. [Lifecycle][I-PROJECT] [Bootstrap][I-BOOTSTRAP] | Default gate: derive required authority before resolution and prove the selected capabilities. |
| F-24 | Restart lacks fresh startup's outer post-boot cleanup handler. [Lifecycle][I-PROJECT] [Backend][I-APPLE-LIFECYCLE] | Default gate: coordinated rollback, disk preservation and unresolved-cleanup fencing. |
| F-25 | CI's filtered overlay still embeds a HEAD bundle; excluded tracked files/history can remain in the complete input. Source construction was reviewed; no exploit reproduction was run. [Snapshot][I-CI-SNAPSHOT] [Checkout][I-CI-OVERLAY] | CI gate: selected data only, without the original base bundle. Refuse unsupported history-dependent local jobs; do not claim overlay exclusions sanitize history. |
| F-26 | Host config loading checks regular-file shape but not the proposed owner/mode/ancestry policy. [Loader][I-CONFIG-LOADER] | Default gate: deliberate trust checks with supported trusted-dotfile symlinks; no repository autodiscovery. |

## 3. Threat model and claim boundaries

### 3.1 Trusted authority

The host user, installed iso binaries, deliberately selected and validated host configuration, enrolled execution host, and host-selected destination are trusted authorities within their stated roles. The guest is root-capable and untrusted. Project/devcontainer input is workload data unless explicitly promoted to a documented host capability. SSH peers, transfer payloads, returned filenames/metadata, and release metadata are untrusted input at their respective boundaries.

Protect the host's process configuration, credentials, Git administration entries, iso control state, local edits, stage/approval identities, and lifecycle allocations. Do not claim protection against arbitrary malicious code already running with the user's full host authority, VM/kernel escape, or intentional execution of returned source. Preserve guest root/passwordless sudo and autonomous agent execution; guest prompts do not enforce host confidentiality. Approved model calls can reveal selected project data and incur charges. Provider brokering and an eight-hour lifetime are neither information-flow control nor spending caps. Explicit guest account login remains guest-held credential authority, including refresh credentials stored in a guest keyring.

### 3.2 Claims permitted after qualification

- **Environment separation:** requested guest names cannot alter host process control variables; reconstruction occurs only after the data reaches the guest.
- **Managed transport isolation:** only after §6 passes, managed SSH ignores ambient authority except the explicitly documented management/editor roles.
- **Structural validated return:** after D2/D3a/D4 and R1–R9 pass, iso never runs host Git during return and installs only a validated mutation plan under the supported-layout, protected-administration and destination-authority rules. This claim does not imply that known execution-sensitive source files are withheld.
- **Sensitive-path withholding:** only after D3b/RET-11/R10 pass, the named classifier also withholds its covered changes without exact stage/content authorization. This is required for the secure-default profile and is not a complete detector of later host execution.
- **Secure defaults:** only after the additional §8 gates pass, new supported workflows begin with explicit data/credential disclosure, qualified brokered transport, staged return and bounded boot authority. A preset label alone is not evidence of effective isolation.
- **Receiver confinement:** may be claimed only after the chosen production receiver is actually confined and tested; staging-directory permissions alone do not establish it.
- **Resource bounds:** manifest limits are hard acceptance limits; sampled transfer cancellation is not an absolute host-disk quota.

The guest wrapper is not a trusted host-security component: a malicious guest can ignore it, change its own environment, or fabricate results. Host security comes from alias encoding and host launch policy. Secret-safe diagnostics refer to iso-generated commands, wrappers, errors and audit records; a workload given a secret can intentionally print it.

## 4. P0: guest environment separation

### ENV-01 — One atomic preparation operation

Replace the original-name overlay and `SSHSession` original-name `SendEnv` construction together. A private preparation operation MUST produce the remote wrapper, exact alias forwarding options, and alias values as one coherent result. Leaving old `SendEnv=HOME` or similar options behind can forward the trusted host's value even after the guest overlay is removed.

Use existing `EnvVarName`, `Secret`, `RemoteCommand`, `ProcessRunner` and session types. Add the smallest internal value/helper needed; do not create a generic public process framework or allow callers to reconstruct a host environment from `GuestEnvironment`.

Illustrative internal contract, not a required public API name:

```swift
func prepareGuestCommand(
  session: SSHSession,
  command: RemoteCommand,
  terminal: GuestTerminalIntent
) throws -> PreparedGuestCommand
```

`PreparedGuestCommand` owns the matched wrapper/options/environment. Its construction is private to the host transport code; callers choose guest intent, not transport variable names. Existing execution supervision and stdin remain separate inputs to the runner.

### ENV-02 — Validation and limits

- Names MUST use the existing ASCII POSIX-style name type. Values MUST reject NUL before process/C-string conversion.
- Initial internal limits are 64 entries, 8 KiB UTF-8 bytes per value, 64 KiB total name/value bytes, and 64 KiB generated wrapper. These are policy limits, not assumed OpenSSH limits. Qualify them on the supported Apple SSH and both guest OS families; a tuple that cannot support the advertised contract is unsupported until the contract is deliberately amended.
- Retain an additional host argv/environment-size check. Limits include empty-valued entries and all encoded name/value bytes where applicable. Change the constants only through a documented compatibility amendment; never truncate.
- Fail before spawning on an invalid or oversized environment. Report the validated name or limit category without its value.

### ENV-03 — Transport and reconstruction

- Generate `ISO_SSH_ENV_<index>` names; values appear only under these names in the host SSH child environment. Preserve necessary trusted host values from an independent host snapshot even when the guest requests a name such as HOME or PATH.
- Clear preexisting transport-alias entries from that snapshot. Iso-generated forwarding options MUST name only the newly generated exact aliases and deliberately required terminal behavior. Excluding forwarding added by ambient SSH configuration is part of SSH-01.
- Capture all aliases before exporting any original name, allowing legitimate alias-name collisions. Reconstruction state, including the saved login shell and values still to be exported, MUST survive collisions with every requested guest name; positional parameters or another collision-proof construction may be used. Do not reserve a new user prefix merely to avoid correct reconstruction.
- Preserve intentionally empty values. Missing aliases and failed assignments abort before workload execution without raw-name fallback.
- Unset aliases and export original names using validated identifiers and quoted values; no `eval`, secret-bearing argv, persistent decoder file, or stdin preamble.
- Preserve the guest login shell before restoring guest SHELL. Host ProxyCommand shell selection remains host-controlled.
- Provider-secret classification/withholding MUST happen before alias preparation and remain unchanged.

### ENV-04 — Call sites and terminal semantics

Migrate both `SSHClient.exec(session, ...)` overloads, `InteractiveSSH.attach`, and the remote agent launcher in `ClientBindings`. Preserve exact binary stdin, EOF, terminal restoration, resize, interrupt handling, escape behavior, exit status, readiness and running-session supervision.

For the existing `InteractiveSSH.attach` PTY path, preserve its precedence: iso's normalized host-derived terminal type wins over a requested guest TERM. Compute that effective guest environment before encoding aliases. Non-PTY sessions retain the requested guest TERM behavior. The separate remote agent launcher does not currently perform this normalization; preserve its behavior explicitly instead of silently imposing local-attach precedence. Its present producer supplies only the Codex capability variable, so migration is completeness/future-proofing, not evidence that arbitrary guest SHELL currently reaches it. Audit names may remain original guest names; aliases and values must not appear as accidental diagnostics.

Existing images using `AcceptEnv *` can support the protocol without a new helper. A missing alias is a compatibility error, not permission to revert. Test Linux and macOS guest shell behavior; do not infer it from Linux-only shell fixtures. [Current environment behavior][I-ENV]; [coop reference implementation][C-ENV].

### ENV-05 — Focused release criterion

The alias repair may ship before the broader §6 refactor once every environment-bearing path and its regression matrix passes. Its release note MUST claim environment-name separation, not complete ambient SSH isolation. No remaining original-name overlay or forwarding call site is acceptable.

## 5. P0 structural return and secure-default path authorization

### RET-01 — No host Git and one final installer

Remove `checkLocalClean` and every return-path invocation from direct pull, ordinary apply and governed apply. Diff/review, recovery and migration MUST NOT invoke host Git, libgit2, external diff/textconv, pagers or editors to inspect guest-influenced destinations. Keep bounded native Swift rendering.

All local/remote returns, including `direct`, stage, review, apply, force, shadow-policy and governed-policy paths, MUST use the same validated mutation plan and final installer. Receiver processes never write the destination. Review/approval authorizes a particular plan; it cannot weaken path, metadata, budget or drift rules.

### RET-02 — Destination authority and separation

Before receiving, replacing an old stage, or creating destination content:

- Resolve and validate the selected destination through race-resistant parent traversal. Reject a root inside protected Git administration.
- Require disjointness from managed control roots, incoming/completed stages, remote shadow state, keys/approval state and the relevant runtime stores. Neither ancestor nor descendant overlap is allowed. Compare validated filesystem identities/ancestry, not raw string prefixes. `--force` cannot override this.
- Existing destinations are bound by directory identity. A nonexistent destination MUST remain absent during receive, review and authorization. Bind an existing validated parent, a validated final component and expected absence. The first implementation requires the parent to exist; it does not create additional ancestors implicitly.
- After complete preflight and authorization, exclusive parent-relative creation of a new destination is the first recorded destination mutation. Immediately verify and record its directory identity. A later failure reports that creation as an actual effect even if no returned file was installed.
- The common installer MUST receive a verified directory handle, obtained from the existing root or that authorized safe-create operation; remove its optional unchecked pathname fallback. Use descriptor-relative, no-follow ancestor traversal for preflight, review reads and writes, rechecking expected entry identities/contents at mutation boundaries.
- Review bytes MUST match the manifest's content observations/hashes. If a read observes changed bytes or ancestry, mark the view stale and require a new validated review; a final-component `O_NOFOLLOW` alone is insufficient.
- Serialize cooperating iso applies to overlapping destinations, including nested workspaces and distinct instance/data roots. Exact-root locks alone do not cover parent/child overlap. A shared per-user apply lock is an acceptable simple first implementation; document its concurrency cost. Recheck destination expectations after copying/hashing the temporary output and immediately before replacement. This minimizes drift windows but is not an atomic compare-and-swap against arbitrary host editors.

These restrictions intentionally refuse broad destinations such as a home directory containing iso state. The error should identify the overlap category and direct the user to a disjoint workspace/export directory without exposing secret-bearing contents.

### RET-03 — Stage lifecycle and writer ownership

Retain one **selected completed stage** per instance for CLI compatibility. Receive each new attempt into a fresh owner-private, unpredictable incoming directory with a distinct ID. Keep host manifests, active pointers, approvals and lifecycle records outside the receiver's writable tree.

The lifecycle is `receiving → quiescent → validated → selected → applying → applied/partial`. A failed receive does not replace the prior selected stage. Only a fully validated, quiescent receive may atomically replace the selected-stage pointer.

- Coordination MUST remain valid for the complete lifetime of every local writer, including after the initiating CLI is killed. A parent-only close-on-exec lock is insufficient.
- Use an explicitly inherited receive lease or a separately supervised lifetime owner; qualify the actual subprocess behavior. Do not globally disable close-on-exec or assume arbitrary tools retain unspecified descriptors.
- Poll cancellation and growth until all writers terminate, independently of stdout/stderr EOF. Combine applicable producer/consumer cancellation conditions rather than selecting only the first non-nil callback.
- On cancellation, terminate and reap owned writers with bounded escalation. Normal completion includes verifying every participating process's termination status.
- After uncertain parent death, never validate, reuse, promote or delete a tree until writer quiescence is established. Do not kill a bare recorded PID that may have been reused.
- Keep an internal first-release bound of one selected completed stage plus one incoming attempt per instance. Refuse additional receives when an incoming tree cannot safely be reclaimed; do not add a new user-facing retention configuration merely for this fix.
- New quarantine, manifest, lease and pointer storage MUST use verified private roots, no-follow parent-relative operations, exclusive creation where applicable, and owner/type/identity checks. Directories default to 0700 and files to 0600; account for effective ACL access, sensitive hardlinks and lock-file replacement. Reuse or extend the dedicated control-state primitives without changing intentional user-configuration symlink behavior globally.

This is a prerequisite for reliable stage validation, not an optional process-sandbox feature. [Current stage slot][I-STAGE]; [pipeline and spawn behavior][I-PROCESS]; [signal cleanup][I-CHILDREN].

### RET-04 — Transport qualification, not transport mythology

The focused fix does not mandate rsync-only transfer. Preserve current rsync and tar compatibility **only for production paths that pass the receiver tests below**. Both must target unique quarantine and feed the same independent inventory/installer. A failed or partially completed transfer cannot fall back to a legacy direct-write path.

Before enabling an inbound transport, bind its qualification to the protected absolute host receiver path, executable family/version, arguments, environment, helper paths and supported host OS. Launch that exact qualified receiver with a deliberately constructed host environment; do not search PATH, inherit tool-control overrides, or substitute another implementation. This P0 requirement covers both tar and rsync independently of D5. A materially changed receiver or launch context requires qualification or refusal; supporting only documented system-tool paths is sufficient. [Current tool selection][I-WORKSPACE].

Qualify absolute/parent paths, symlink and hardlink ordering, duplicate names, relevant extended metadata, sparse files, early stderr closure, cancellation and resource exhaustion on the supported macOS tool tuple. Hostile cases MUST leave sentinels outside the receive tree unchanged, checked before post-receive inventory and again after cancellation/reaping. A rejected manifest does not compensate for an earlier out-of-tree receiver write. Guest-side excludes and guest tool-version claims are not security evidence. If a receiver cannot pass, disable inbound use on that tuple with an actionable error; do not weaken validation. Removing tar entirely is then a justified simplification/compatibility decision.

The acceptance claim concerns validated handling of hostile protocol inputs with the selected tools. Unknown memory-safety flaws in an unconstrained receiver remain outside it. Receiver process confinement is the separate §10 follow-up.

### RET-05 — Protected paths, layouts and links

The mandatory reserved-entry rule covers `.git` at every path component and object type: directory, gitfile and symlink, nested repositories and supported case/filesystem aliases. Preserve existing host entries; do not install, remove, traverse or replace them through guest operations. Sender filtering is optional optimization; inventory and final apply independently enforce the rule.

**Supported layouts:** ordinary worktrees, standard linked worktrees/submodules, and plain export directories. Do not claim complete administration-data protection for arbitrary bare repositories or custom GIT_DIR layouts selected through external configuration.

For existing gitfiles, use a bounded native read of the supported `gitdir:` representation, with no Git invocation or config discovery. Standard targets outside the returned tree, or beneath an already protected `.git` subtree, remain untouched. An unresolved, ambiguous, unsupported, or custom in-destination administration target makes that destination inapplicable in this release. Do not interpret arbitrary Git configuration or introduce an exception inventory to widen support. Revalidate the relevant gitfile observations before apply. Refuse destinations containing an existing `.git` symlink; target-following support requires separate qualification. Protecting only the link pathname would be insufficient.

Validate names against the supported destination volume semantics. Initial qualification covers case-sensitive and case-insensitive APFS, canonical-equivalent spellings, Git-relevant aliases and stage/destination differences. Refuse detectable ambiguous names/collisions or unsupported volume behavior. NFC plus lowercasing alone is not the acceptance proof. A case-folding staging filesystem may collapse raw guest names before post-receive inventory. Complete source-name fidelity therefore requires a qualified raw-name/receiver mechanism or a staging representation that preserves distinctions; without it, claim only validation of the materialized tree and do not claim every original collision was detected.

Symlink validation MUST examine **every** target component, including the final component, against the planned final tree and preserved destination. Reject external escape, paths into protected administration/control state, symlink chains and unresolved ambiguity. An otherwise permitted dangling target must remain lexically within the supported worktree and have safe resolved ancestors. Existing host symlinks cannot become a write route.

Use host-owned accepted entries, not guest `.gitignore` or filter files, as installation authority. Inventory omissions never imply deletions. All returned source/configuration remains untrusted for later host use. The structural return release retains conspicuous-path warnings. The secure-default profile additionally requires RET-11 withholding for known execution-sensitive paths such as `.envrc` and editor tasks unless the exact staged content receives a named-path grant; this classifier is intentionally incomplete.

### RET-06 — Object and metadata policy

Allow regular files, directories and validated symlinks. Reject incoming hardlinks and special objects unless a future explicit contract supports them. Detect duplicate/colliding accepted paths before installing anything.

The native installer copies file bytes and explicitly permitted mode bits only; it must not propagate guest owner/group IDs, setuid/setgid/sticky privileges, ACLs, extended attributes, resource forks or filesystem flags as implicit authority. Preserve documented executable-bit behavior. Timestamps, if retained, are informational metadata and must not affect validation or authority.

Structural issues make the entire mutation plan inapplicable. Known protected metadata may be excluded with a bounded review summary; ambiguous namespaces or an attempted alias into protected state must fail the plan. Excluding return data does not delete it from the guest.

### RET-07 — Manifest version and complete preflight

Introduce manifest schema version 2. Required authority fields include stage ID, return-policy version, instance/source binding, destination identity or safe-create binding, accepted path/object inventory, expected old objects, new hashes/targets/modes, limits, and the existing optional policy binding. A baseline generation is absent in the first implementation. Internal return-policy version 1 represents the structural contract with conspicuous-path warnings; version 2 additionally requires RET-11 named grants. These are compatibility identifiers, not user-selectable bypass modes. The secure-default profile accepts only version 2; an older selected stage must be revalidated under that policy with a new ID/digest.

On load, validate schema version, bounded lengths/counts, unique paths, canonical order, reserved names, object types and all cross-field invariants. Codable decoding and an empty `issues` array are not proof of validity. Only a validated manifest type may reach apply.

Before the first destination mutation, every mode MUST verify the entire accepted stage against the manifest, all old destination observations and parent paths, destination identity, policy epoch/receipt where applicable, and receiver quiescence. Recheck source bytes and destination expectations immediately before each write as well. The active stage cannot change under the operation lock.

Include authority fields, conflict-authorization requirements, path classifications, required named-grant scopes and dispositions in the immutable manifest/plan digest using unambiguous serialization. Collect overwrite/named-path authority and any required policy receipt for one apply attempt in the same invocation, bound to that digest and its destination observations. Approval must not change the reviewed plan. Do not introduce reusable preissued or persisted approval authority; the durable attempt record in RET-08 records consumption and effects, not a grant available for replay. A pre-upgrade receipt does not authorize the new plan. No new signature scheme is required: the manifest remains trusted host state under the existing private-state and approval model.

### RET-08 — Apply, partial failure and recovery

Retain atomic regular-file/symlink replacement where supported, including regular-file-to-symlink and symlink-to-regular-file changes. Refuse directory-to-file/symlink and file/symlink-to-directory transitions in this release. Report an unsupported transition during review, before any writes. Do not add a backup/rollback mechanism as an alternative prerequisite.

After final locked preflight and authorization, persist a host-owned apply-attempt begin record bound to the plan digest, destination observations and exact authorized scopes **before the first destination mutation**, including safe-create. Validate/consume any required policy receipt in that same critical section. Beginning an attempt consumes its authorization. Failure to persist begin means zero destination writes. A crash, failure or lost outcome never makes that authorization reusable; recovery may classify effects but cannot resume writes automatically.

For accepted operations, persist sufficient progress intent/outcome to recover conservatively. Report completed writes, the failed operation, whether that operation changed anything, and any uncertain state. Never report “no changes” merely because no operation reached the final success append. Keep the stage after partial failure; retry requires reconciliation and a new validated plan/approval for remaining work. Do not automatically replay a consumed approval.

Crash recovery compares expected old/new observations and recorded progress without running Git. Ambiguous state is unresolved, not success. No automatic deletion is introduced.

### RET-09 — CLI compatibility and overwrite authority

Retain current command names and `workspace.pull.mode` values:

| Invocation | Required behavior after the applicable deliverable |
|---|---|
| `iso diff VM` / `iso pull VM --review` | Receive, validate and show the selected plan; no destination writes. |
| `mode: stage` | Same stage-only behavior. |
| Explicit `mode: direct` | Automatically receive/validate, then apply only within documented overwrite authority and the active return policy; never direct receiver writes. Under the secure-default policy, RET-11 grants are also mandatory. DEF-01 makes stage the new default after qualification. |
| Explicit direct without sufficient replacement authority | Apply only when the entire plan is authorized and all structural, drift and applicable policy/grant checks pass. Otherwise retain the entire stage without writes. A plan consisting solely of authorized additions/noops may apply. |
| `iso pull VM --force` | Supplies authority for otherwise permitted nonsensitive replacements in that direct apply attempt, including permitted file/symlink transitions. It does not change stage mode into direct application or save future overwrite authority. It grants neither RET-11 sensitive paths nor any bypass of validation, protected paths, limits, drift or required policy approval. |
| `iso pull VM --apply --stage-id ID` | Authorizes the exact displayed plan's permitted nonsensitive additions, directory changes and replacements, including supported file/symlink transitions. Applies only after all required sensitive-path grants and drift/policy checks pass. |
| `--apply` without a stage ID | Refuse in interactive and noninteractive use; show the selected ID and exact command needed. Do not infer latest or substitute a generic confirmation. An explicitly selected direct operation binds its newly produced ID internally. |
| `--exclude-git` on return | Deprecated compatible no-op; inbound protection is unconditional. INPUT-01 also excludes raw administration by default outbound; legacy false/default does not become a history grant. |
| `--discard` | Discard only a quiescent stage. Never delete a tree with an unproven live writer. |

Keep remote/offline apply on the same hard gate. Removing the former interactive no-ID shortcut is an intentional compatibility change from the prior specification. Do not silently downgrade optional policy support for remote workflows. Internal typed outcomes and human diagnostics MUST distinguish unsupported layout, blocked metadata, drift, missing overwrite/named authorization, busy writer, transport failure and partial/uncertain apply; include the relevant stage ID and actionable remedy without secret values. Failed application returns a nonzero exit status, including a direct attempt held for missing authority.

The current `pull` and `diff` commands are outside the JSON machine interface. This release retains that scope and its `UNSUPPORTED_MACHINE_OUTPUT` response; it does not introduce new machine commands or an undocumented wire format as a prerequisite. Update CLI help and existing surface/error fixtures, and use typed internal outcomes in tests. A later machine-command feature must specify its complete result/error contract. [Workspace CLI][I-WORKSPACE-CLI]; [machine interface][I-MACHINE].

### RET-10 — Migration and limits

Old manifests cannot be applied directly. Retain their bytes, revalidate under the new policy, and produce a new stage ID/digest; if this is impossible, require a fresh receive without destroying the sole retained copy. Update all `StageLocation.exists` consumers, disposable-instance cleanup, destroy, discard and remote-shadow cleanup for the selected-pointer/incoming layout and writer-lifetime rules. Migration must not run Git, delete host/guest administration data, erase commits or rewrite shared worktree pointers.

Unknown synchronization history is not proof of compromise. A hash baseline does not establish that old Git metadata is trusted. For suspected previous metadata contamination, preserve the old workspace/VM and use a fresh independently trusted repository plus reviewed worktree return.

Keep the existing stage limits and transfer-time monitor. Receive storage accounting includes data later excluded from the accepted manifest, including protected Git metadata. Validate both logical content sizes and actual storage observations as appropriate; inspection failure must not become “within budget.” Continue polling after stderr EOF and during child shutdown. State that monitoring can overshoot and cannot guarantee the host volume never fills. A hard per-operation storage quota requires a separately qualified mechanism.

### RET-11 — Withhold known execution-sensitive changes

Turn the current conspicuous-path warnings into host-owned, versioned authorization rules. Initially cover .husky at any component, .envrc leaf entries and .vscode/tasks.json, including nested forms, each permitted object type and qualified case/filesystem aliases. Classify permitted symlink targets under the same supported final-tree rules; fail ambiguous aliases. The classifier does not trace every script dependency: an existing host tool can execute an ordinarily named source file, and approved source remains untrusted. [Current warnings][I-REVIEW].

A sensitive change requires a named-path grant bound to the exact stage/plan digest, destination identity or safe-create binding, old observation, proposed content or link target, mode and classification-policy version. General stage approval, `--force`, direct mode, a preset or a persistent pathname preference does not imply approval of unseen sensitive content. Git administration remains prohibited; it cannot be authorized through this mechanism.

The first implementation MUST retain the entire stage and perform **zero destination mutations** if any required named grant is missing. Show ordinary and withheld changes together, then allow one concrete approval to include all named grants and required policy approval. No repetitive confirmation is needed for the same unchanged plan. An explicit direct operation encountering an ungranted sensitive change stops with the stage available for review.

Introduce the new repeatable option `--approve-sensitive PATH`, usable only with `--apply --stage-id ID`:

```text
iso pull VM --apply --stage-id ID --approve-sensitive .envrc --approve-sensitive .vscode/tasks.json
```

Each operand is one exact displayed sensitive entry in the immutable selected plan. Operands are literal normalized workspace-relative paths, with no glob or directory-prefix authority. A directory operand approves only that entry, never unseen descendants; review lists every additional required entry. Reject absolute/escaping, duplicate, unknown, nonsensitive or unstaged operands before mutation. The host binds the selected paths to their hashes/targets, modes and old observations; callers cannot supply replacement content or a grant digest. Interactive review may compose this same concrete invocation, and noninteractive callers supply it explicitly. There is no blanket approve-all option or persistent pathname wildcard in this release.

Named arguments do not satisfy a governed policy's separate trusted-terminal/receipt requirement. Collect that required confirmation and the selected named paths in one apply attempt, then follow RET-08 consumption ordering. Local and client-side remote/offline apply use the same typed request: exact stage ID plus exact sensitive-path set. Do not add an execution-host approval protocol where application already occurs on the client.

Do not introduce subset application, residual-stage rewriting or repeated approval consumption in this release. Changed stage content, destination observations or policy invalidates the attempt; retry after actual partial failure follows RET-08 and requires fresh authorization.

## 6. P1: explicit managed host transport policy

### SSH-01 — Complete launch context

Introduce a small shared managed-transport policy using existing types. Default to protected absolute system SSH/SCP paths and explicitly resolved rsync. Do not add a new tool-override feature solely for coop parity. If an existing or separately justified exact-path override remains, require owner/type/writability/ancestor/symlink validation, including applicable ACLs. A user-owned override is an explicit host trust choice, not OS provenance. No silent fallback after invalid configuration.

Construct environment and cwd deliberately. Fix the host shell used for ProxyCommand; retain only documented host context required by the connector. Disable ambient SSH configuration with `-F none` or an explicit private generated configuration. Preserve pinned guest known-host files and `StrictHostKeyChecking=yes`.

Pin SCP's nested SSH executable and serialize rsync `-e` for its own grammar. Keep shell quoting, SSH option/path parsing, percent expansion and rsync tokenization separate. Do not expand supported connector-path syntax as part of this repair.

### SSH-02 — Role-specific authority

| Role | Allowed authority |
|---|---|
| Guest command/probe | Explicit guest pin/key/route, neutral environment aliases where needed; no ambient agent, X11, local commands, implicit forwards or alternate auth. |
| Brokered/remote guest route | Exactly one validated iso connector/relay, preserving the route's existing machine/session/epoch and applicable boot/channel/network-policy bindings. Never emit `ProxyCommand=none` before a second desired value. |
| Proxy/port/editor tunnel | Same host policy with only its explicit loopback/reverse forwards; do not clear required explicit forwards. |
| Enrolled-host management | Trusted enrollment config and any required trusted host agent; never guest environment or inherited aliases. Do not blindly apply guest no-config/no-agent rules. |
| Editor inner SSH | Generated enclave config and session-only credentials; no host VM key or management agent imported into the enclave. |
| Cleanup/control | Only the owned control socket/process identity. It may terminate an existing session after guest authorization is lost, but cannot establish a new guest connection. |

### SSH-03 — Coverage and revocation

Cover direct exec, capture/probes, both environment execs, interactive/remote agents, SCP, rsync, proxy/local-model/egress tunnels, port forwards, editor outer tunnels, readiness masters and `-O` cleanup.

Do not make cleanup depend on a fresh workload readiness proof: revocation is a reason to tear down the old session. Validate the owned control path/process identity and restrict cleanup to teardown. Test that stale/replaced control records cannot target unrelated processes and that a missing socket does not create a replacement connection.

A generic launcher refactor is not a prerequisite for ENV's focused repair, but the complete managed-transport claim requires every listed family to migrate. [Upstream launch policy][C-SSH]; [iso readiness and cleanup][I-SSH].

## 7. P1: additional recommended upstream adaptations

### UPD — Bind updater metadata and asset authority

Production builds MUST reject `ISO_UPDATE_API_BASE_URL` before any update network I/O, including background checks. Replace fixture routing with an injected/test-build-only source capability unavailable to the production entry point. Keep development and release behavior explicit.

Validate canonical release tags and every selected initial asset URL against `chr33s/iso`, the exact tag and expected filename. An explicitly requested/pinned version MUST match the returned canonical tag; valid assets for a different release do not satisfy the request. Reject conflicting duplicate assets, encoded path ambiguity, userinfo, nonstandard ports, query/fragment ambiguity and lookalike hosts. Constrain requests/redirects to HTTPS. Allow legitimate GitHub release-CDN redirects, including their signed queries, while stripping authorization on origin changes; do not require every final CDN URL to be on github.com. Tokens may go only to intended authenticated GitHub endpoints. Apply equivalent rules to curl and gh paths, archive, checksum, signature and attestation assets; keep gh optional.

Preserve mandatory compiled-key Ed25519 verification of SHA256SUMS, archive checksum verification, revocation checks, explicit downgrade authorization, and exact workflow/tag provenance checks where available. The existing override chooses bare curl, so do not claim the override itself sends GITHUB_TOKEN. The normal bearer-download path makes metadata-provided asset authority relevant before signature verification. Also correct diagnostics that describe the signed-checksum fallback as checksum-only assurance. [Current updater][I-UPDATE]; [release model][I-UPDATE-RELEASE]; [signatures][I-SIGNATURE].

### ALLOC — Reserve existing and corrupt instance state

Keep user-facing listing tolerant, but allocation MUST use a strict reservation scan under the namespace lock. Existing entries occupy their names regardless of metadata readability or object type. If an existing possible allocation's index cannot be safely determined, refuse allocation rather than infer that index is free; an independently authoritative reservation record is an acceptable alternative.

Create the selected directory exclusively relative to a verified parent. EEXIST is a collision, never permission to reuse/overwrite. Persist initial state privately and retain enough identity to clean up only a directory created by this attempt. Do not auto-delete corrupt instances. Test explicit/derived names, corrupt records, unknown indices, symlinks, case collisions and concurrent creators. [Current allocator][I-STATE].

### PUSH — Fail closed before overwriting guest work

Model guest preflight as explicit outcomes: not a repository, clean with verified upstream state, clean with no configured upstream, dirty/ahead, and unable to determine. Support standard `.git` files/worktrees as well as directories. Inspect SSH termination and Git command exit statuses; malformed/truncated protocol output and errors are not clean. Do not suppress a failed ahead-of-upstream calculation into zero. A genuinely absent tracking upstream is a legitimate state distinct from a failed ref probe: preserve current compatibility by allowing an otherwise verified-clean working tree, without claiming its commits are backed up elsewhere. A configured but unavailable/broken upstream produces unknown and blocks ordinary push.

Only a known-safe result permits ordinary push; explicit `push --force` may authorize overwriting guest work under existing product semantics, while transport readiness and source validation still apply. This is data-loss protection for a cooperative guest, not a way to trust a hostile guest's report. Never move these checks back onto the host. [Current push guard][I-WORKSPACE].

### HOOK — Run post-start after successful provisioning

Separate bootstrap/readiness and credential setup from the post-start hook. Complete workspace copy/clone and additional one-time mount synchronization before invoking the hook. Check cancellation after each boundary; do not run the hook after failed or incomplete provisioning. Preserve readiness, proxy and secret requirements. Invoke the hook once per successful provisioning/boot attempt, preventing duplicate calls introduced by the bootstrap/hook split. Preserve existing restart behavior and ordinary post-start failure-as-warning semantics; do not turn this ordering fix into mandatory resumable creation hooks. An interrupted hook can require an idempotent retry; exactly-once execution across a crash is not promised. Cover copy, clone, mount-only, no-agent and reprovision paths. [Current ordering][I-PROJECT].

## 8. Secure defaults and explicit capability grants

These requirements integrate the supplied secure-defaults design into the boundary repairs. “P0/default gate” means required before the secure-default profile is released or advertised; it does not delay independently complete ENV or structural-return repairs. The shipped default changes last. Existing explicit compatibility workflows remain available under their own accurately reported policy.

### POL-01 — Resolve authority once, before side effects

Resolve each new mutable setting in this order: baseline, explicitly selected preset, trusted host configuration, then explicit command input. Later explicit values override earlier defaults. Recorded creation-time transport/egress and current host admission limits are constraints, not lower-precedence defaults; reject incompatible requests. Preserve each field's origin, scope, persistence and expiry. Freeze approved input bytes and identities rather than rereading mutable project content after approval.

Saved grants are not a final override layer. Reuse only authority whose origin, persistence, expiry and current policy still permit that scope. Recompute configuration-derived grants from their current authorizing entries; removal or explicit disabling withdraws them. Existing deliberately instance-persistent command grants may survive restart only under their documented scope. New command grants default to the request or boot unless that feature explicitly specifies instance persistence. Legacy entries without adequate provenance require a concrete reauthorization/migration choice; assigning them fresh IDs is not authorization.

Extend existing grant/receipt metadata with schema version, stable opaque ID, capability and exact scope, origin kind and source binding, persistence (`request`, `boot`, or `instance`), applicable instance/boot binding, expiry or explicit permitted local-unlimited value, and revocation generation. Bind the authorizing source to its relevant entry/scope, not unrelated changes elsewhere in a configuration file. Unknown security-critical values fail closed. Do not create a second general grant service.

Introduce the proposed trusted-host setting `security.revoked_grant_ids`, an array of exact opaque IDs shown by the policy report. Validate host/owner and applicable instance scope. Durably record applicable revocation tombstones in existing private policy state before activating a policy or handing off workload authority. A tombstone suppresses reuse and automatic replacement from the unchanged authorizing source. Deleting the setting or an array entry does not restore authority; subsequent explicit authorization through the relevant capability flow creates a new ID. Unknown/foreign IDs cannot revoke unrelated grants and must produce a targeted validation error. Reports show pending/effective revocations without writing them. For a live boot, use a supported revocation transition; if the capability cannot be revoked safely in place, require stop/reconciliation before reauthorization. Mere editing of a file does not claim instantaneous live revocation.

Project files, devcontainers, agent definitions, workflow YAML and guest output can request workload settings or suggest resources. They MUST NOT authorize host commands, secret reads, paths, network destinations, tool executables or capability widening. An existing explicit trusted-host grant is sufficient authorization for its documented scope; do not introduce a redundant generic confirmation boolean or repeated prompts.

Reuse the existing resolved boot/session policy, policy receipts and host-control admission. Extend their metadata where necessary. HostCapabilities advertises supported, qualified host features; it is not already a general user-grant database. Do not create a second privilege system or make iso-ci a dependency of base iso. [Agent launch plan][I-LAUNCH-PLAN]; [host capabilities][I-CAPABILITIES].

Effective-policy and migration reports MUST show requested versus effective transport, egress, provider mode, return mode, imports, named host services, saved environment/forwards, deadline and explicit relaxations. Credential references may be named. Reports may use existing read-only runtime or enrolled-host management queries, but must not resolve workload/provider secrets, execute credential commands, contact providers, start or mutate VMs, change policy/grants, or mutate audit state. Unavailable live evidence is reported as unknown; reporting must not establish a new workload access grant merely to fill a field.

For security-bearing host configuration, validate ownership, write permissions, effective ACLs and path ancestry. The selected file must be a regular file owned by the effective user or root; neither it nor its resolved ancestry may be writable by an untrusted principal through mode bits or ACLs. Verify this through the actual opened path/identities, not a separate race-prone pathname check. Continue supporting deliberate trusted dotfile symlinks when their resolved target/ancestors satisfy the trust policy; do not globally prohibit symlinks or chmod a foreign target as repair. Read a bounded verified snapshot. Never automatically discover repository-local host configuration. [Current configuration loader][I-CONFIG-LOADER].

### DEF-01 — One qualified baseline, including transport

The target for **new, qualified Linux instances** is:

| Setting | Target default | Explicit relaxation |
|---|---|---|
| Network transport | brokered | vmnet compatibility, separately selected and reported |
| Security preset / egress | provider-only / none | Approved filtered destinations; open egress requires explicit vmnet |
| Provider credentials | required broker for the selected remote provider | Deliberate guest-held credentials or account login under a separate grant |
| Workspace return | stage | Explicit direct application through the same validator and path-grant rules |
| Claude/Codex host imports | disabled | Named files or a confined explicitly selected directory |
| GitHub | off, including ambient clone credentials | Explicit repository-scoped source authority |
| Editor | sandboxed, no extra allowances | Independent editor grants |
| Session TTL | 8h per boot | Explicit finite override within the host/product limit; local-only unlimited under the new contract below |

A target configuration, using existing finite-TTL syntax, is:

```json
{
  "network": { "transport": "brokered" },
  "security": { "preset": "provider-only" },
  "egress": "none",
  "proxy": { "mode": "required" },
  "github": "off",
  "claude": { "config_dir": false },
  "codex": { "config_dir": false },
  "workspace": { "pull": { "mode": "stage" } },
  "editor": { "security": "sandboxed", "allow": [] },
  "limits": { "session_ttl": "8h" }
}
```

This is the proposed default contract, not a complete provider configuration or a claim that the default has changed. Preserve configured provider credential references when merging; a remote-provider workflow without its required broker fails with a targeted setup instruction. Do not silently replace a guest account-authentication selection with API-key authentication. Local-model and agent-free workflows require only their selected capabilities.

Current decoding defaults independently to networked and vmnet; provider-only does not choose a transport. Change the outer defaults and nested partial-object paths together, plus programmatic constructors, setup templates, examples and fixtures. An explicit networked preset alone must not silently choose vmnet: its open egress conflicts with brokered until the operator explicitly selects vmnet. Display its open-egress, automatic-credential and direct-return relaxations. A single egress override must leave required proxy, staged return, disabled imports and editor confinement intact. [Decoder][I-CONFIG-DECODING]; [configuration types][I-CONFIG-TYPES].

Missing implicit configuration, an empty object, a commented default template and supported partial objects MUST resolve the same baseline. Preserve errors for a missing explicitly selected file, a file removed after selection, zero-byte/invalid JSON and a non-object root. Omitted nested transport, proxy, pull, agent and limits fields cannot restore legacy defaults. Treat explicit null for the newly defaulted security-bearing scalar fields and session TTL as invalid; use false to disable agent imports. Document this deliberate migration rule rather than allowing null to mean unlimited or automatic import.

Introduce a typed finite/unlimited **local** lifetime. Omission means 8h. Preserve the current finite local range of 1m–720h and numeric-seconds/duration syntax. The proposed new spelling `"session_ttl": "unlimited"` requires explicit trusted-host configuration/command authority and visible provenance, and is available only for ordinary local instances; it is **not existing syntax**. Zero/negative/out-of-range/invalid values fail, and unlimited is never inferred from absent/corrupt state.

Enrolled remote boots remain finite, retain their existing 8h default and 24h maximum (or a stricter host limit), and reject unlimited. The configured remote default retains its 1m–24h range; preserve the existing host-protocol admission of positive TTL seconds within its maximum rather than inventing a new protocol minimum. Iso-ci retains its finite pool/job ceilings and any stricter host limit. Effective expiry is the earliest applicable job, boot, access-session or capability deadline; one layer never extends another. A locally accepted long/unlimited setting must not be silently truncated or carried into an incompatible remote request. [Local duration bounds][I-UNITS]; [remote configuration][I-EXECUTION-CONFIG]; [remote admission][I-HOST-SUPERVISOR].

Brokered support currently excludes macOS guests and has tuple-specific qualification. An unsupported guest/runtime must fail with an explicit compatibility choice, never fall back to vmnet. Preserve macOS guest support through deliberately selected vmnet; do not claim it has the brokered profile's isolation. Remote execution must negotiate the enrolled worker's effective policy and qualification; changing the client's defaults alone does not change the worker. Reuse each existing admission contract: this spec does not impose the CI-specific evidence-file mechanism on every ordinary local command, but every advertised supported tuple still needs native release qualification. [Brokered status][I-BROKERED-DESIGN]; [macOS runtime][I-MAC-OWNER].

### INPUT-01 — A single explicit outbound snapshot contract

P0/default gate: create a host-owned, immutable transfer snapshot from one validated input manifest. Reuse that selection for first copy, push, fallback transport and additional directory imports; neither tar recursion nor rsync's interpretation of project ignore files may broaden it.

For supported Git working trees, select tracked working-tree bytes, including local modifications, plus specifically selected untracked inclusions. For non-Git or unsupported layouts, require explicit path selection under the same bounds; never silently fall back to archiving the whole directory. A qualified explicit-selection implementation is sufficient for the first release; building a new index reader is not a prerequisite.

The new trusted-host `workspace.input` v1 configuration has this shape; omitted members use the shown defaults:

```json
{
  "workspace": {
    "input": {
      "mode": "tracked",
      "paths": [],
      "exclude": [],
      "secret_allow": [],
      "limits": {
        "max_entries": 100000,
        "max_file_bytes": 1073741824,
        "max_total_bytes": 4294967296
      }
    }
  }
}
```

`mode` is `tracked` or `paths`. `paths` is a list of `{ "path": "relative/name", "recursive": false }` selectors; a directory subtree requires `recursive: true`. In tracked mode it adds named untracked selections; in paths mode the list must be nonempty. The root comes from the existing explicit workspace/root selection, and each extra root has its own selection. Selectors are literal normalized root-relative names: no implicit globs, ignore-file expansion, absolute paths, NUL or `..` traversal. `.` is permitted only as an explicit recursive whole-root choice. Expand recursive selections into the frozen inventory before transfer; a selector never authorizes following a source symlink.

`exclude` contains literal relative entries/subtrees to omit. `secret_allow` contains exact selected file or link paths whose default local-secret exclusion is deliberately waived; it does not select otherwise unselected data or override an explicit exclusion, raw Git-administration prohibition or structural restriction. Reject duplicate, unselected or conflicting exceptions. Parent directories needed to represent an allowed file confer no authority over siblings. Imports use the same typed selector and snapshot implementation for their separately approved root; they do not inherit authority merely from the workspace setting.

Adopt the existing CI exclusion names as versioned classifier `local-secret-names/1`, applied even to tracked files:

```text
.env  .env.*  *.pem  *.key  *.p12  *.pfx  *.keystore
id_rsa*  id_dsa*  id_ecdsa*  id_ed25519*
.netrc  _netrc  .npmrc  .pypirc  .git-credentials
.aws/  .ssh/  .gnupg/  .docker/config.json  .kube/config
credentials.json
```

For this fixed table, `*` matches within one component; single-component names match at any depth, trailing `/` excludes the named directory and descendants at any depth, and the two multi-component file names match that exact component sequence at the root or nested. Apply qualified filesystem-equivalence rules so aliases cannot avoid the same exclusion. Custom selectors remain literal; this table does not introduce user-controlled pattern semantics. Named exceptions require explicit host authority. The classifier is a convenience and is not content scanning or proof that selected source contains no secrets. [Existing exclusion names and starting budgets][I-CI-SNAPSHOT].

The initial shared input ceilings are 100,000 inventory entries, 1 GiB per regular file and 4 GiB aggregate logical file bytes, counted across all roots in one operation as well as per root. Directories and links count as entries. Trusted configuration may lower these positive integer limits; raising the v1 ceilings requires a documented compatibility/qualification amendment. No unlimited spelling is accepted. These outbound limits are independent of RET's existing inbound stage budgets. Copy/hash attempts are bounded to three captures; a changing tree then fails. Snapshot accounting must include temporary storage, fail on inspection errors and distinguish acceptance limits from any unenforced host-volume quota.

Tracked-path discovery MUST be a separately qualified inert/read-only operation. Do not run Git against the original project merely to recover convenience: an older return may have contaminated its metadata. A bounded isolated index-inventory mechanism is acceptable only if it cannot load repository-selected configuration, hooks, helpers, filters, fsmonitor, pagers or credential commands. Unsupported index/worktree/submodule forms use explicit paths. Do not make a new full Git implementation a prerequisite.

Bind selection/classifier version, root identity, relative paths, source identities, lengths, hashes, types and limits into the snapshot. Copy/hash the actual selected bytes into private immutable state before transport. Permit regular files, directories and ordinary symlinks preserved as link objects without dereferencing. Validate every link-target component against the selected tree and the same confinement/protected-path rules as RET-05; refuse escapes, chains and ambiguous targets. V1 refuses multiply linked regular files, special objects and unresolved races. Extra roots require independent host selection and aggregate accounting. Display selected files and omissions without secret contents.

Raw `.git` entries of **every object type** are excluded at every depth and cannot be reenabled by input exceptions. This is distinct from the permitted ordinary symlinks above. V1 transfers selected data only, without original repository history or a base bundle. Create any required guest-local metadata from those bytes and report any resulting synthetic commit separately from original-source provenance; do not claim they are the same commit. Base iso and local CI refuse requests that require original-history transfer until a separately specified capability ships. Existing history-bearing local snapshots must be recaptured, not relabeled sanitized. An old `excludeGit: false` or omitted legacy value is not a history grant.

Preserve tracked deletions as explicit **outbound** selection/removal intent only. Distinguish a deliberately omitted secret from a tracked file actually deleted by the user. Missing/excluded entries are not permission to delete guest-only files or guest Git metadata. If scoped outbound removal is not implemented initially, report that limitation rather than silently mirror-deleting. Do not combine the new manifest with unrestricted rsync --delete; any supported removal must be individually represented and pass guest-overwrite policy. Inbound RET no-delete semantics remain unchanged. [Current initial-copy/push paths][I-WORKSPACE].

### IMPORT-01 — Disable automatic agent-home imports

Change both omitted-agent and omitted-config_dir defaults to disabled while continuing to generate iso-owned guest settings. Existing explicit imports require a named, host-approved root, bounded file/byte counts, safe traversal and an immutable selected snapshot. Prefer named settings to recursive agent-home copying. Reject escaping/cyclic symlinks and special files; an allowlisted filename does not make its followed target safe.

This applies to first start, restart, reprovision and remote staging, including separate Codex config.toml and Claude preferences reads. They must read the approved snapshot rather than reopen the original host path. Preserve existing withholding of Codex auth.json under required/proxied/no-egress policy; a directory import grant does not override credential policy. [Codex import][I-BOOTSTRAP-CODEX]; [Claude import][I-BOOTSTRAP-CLAUDE]. Disabling future copying does not remove previously copied credentials or config from a retained guest disk; report that distinction during migration. [Current defaults][I-CONFIG-DECODING]; [import staging][I-BOOTSTRAP-STAGING].

### AUTH-01 — No ambient source credentials

GitHub off MUST also prohibit opportunistic clone/discovery authentication from host gh, GITHUB_TOKEN, saved overlays or unrelated credential helpers. The current cloneToken path can obtain a token independently of ordinary forwarding mode, and the guest helper exposes it during clone; transient exposure is still guest authority. [Current token selection and guest helper][I-GITHUB-TOKENS]. Devcontainer repository discovery has a separate ambient-token fallback; route it through the same source-authentication decision. That path uses the token on the host for GitHub discovery, so do not misdescribe it as guest exposure. [Discovery authentication][I-DEVCONTAINER-GIT].

Public retrieval defaults to anonymous access to the explicitly selected source. Because brokered none cannot reach GitHub directly, implement authorized host retrieval into INPUT's snapshot, or require a local snapshot until supported; never relax guest egress just to clone. Private retrieval requires an explicit repository-scoped host fetch or a narrowly scoped broker; grant repository/ref and any submodule/LFS/additional-host retrieval deliberately. A named PAT entry or token prefix is not proof of its server-side repository scope. A .gitmodules URL or action dependency is a request, not authority to expand that scope.

Host fetching must use a controlled tool/config/environment and quarantine, disable repository-selected execution and avoid automatic checkout or recursive submodule access before selection. Do not forward authorization across unapproved origins. Missing scope/authentication is a useful refusal, never a reason to discover broader ambient credentials. A genuine requirement for a token inside the guest is a separate visible grant with the narrowest practical scope and lifetime. Guest account login remains explicitly guest-held credential authority; a keyring does not make it host-only.

### NET-01 — Qualify the existing brokered topology

P0/default gate: use the implemented NIC-less Linux runtime and fixed authorized SSH/Virtio-socket path. Do not implement a new pf or Network Extension subsystem for this profile. The attachment's older vmnet host-firewall discussion is historical; none/filtered on vmnet must still not be advertised as isolating unrelated Mac services.

Validate actual host-owned device and channel state before workload release: no external NIC, no temporary bootstrap NIC and no weaker fallback after broker, adapter, lease, qualification or owner failure. Retain host-key pinning and all current boot/channel/network-policy/session bindings. Preserve static fixed forwards and the editor's separate credentials. Qualify hostile SSH-server behavior and every reachable runtime/vsock endpoint, not just cooperative guest traffic.

Public egress remains independent of model access and local services. Default to exact approved HTTPS destinations; any already supported wildcard profile requires explicit operator scope and must not be synthesized from workload hints. Preserve trusted DNS/address validation, numeric dialing, private/host/tailnet and hairpin protections, bounded streams and separate grants for redirected/new targets. A local-model bridge names one fixed host endpoint; it is not an arbitrary guest-to-host socket capability.

Verify guest-root IPv4/IPv6, route/spoofing, sibling-VM, host/LAN and host-service probes, with host-side positive controls, and approved providers/local services/filtered destinations. Repeat relevant tests across restart, sleep/wake, service failure, revocation and remote reconnect. Existing one-tuple results are useful evidence but do not qualify a new build/platform automatically. Retain documented stream/lifetime/resource limitations; no universal exfiltration or spending guarantee follows. [Brokered design and qualification][I-BROKERED-DESIGN]; [transport implementation][I-BROKERED-TRANSPORT].

### READY-01 — Prove the capabilities actually required

Reuse the existing boot, owner, policy, signing-identity and session machinery. Derive the selected provider and required-secret set from the compiled agent adapter, chosen model and explicit grants before resolving credentials. Resolve only needed provider/vault references and explicit guest-secret grants; an unused configured provider must not prompt or fail an agent-free/local-model workload. Deliberately selected multiprovider provisioning can require multiple providers, but their mere presence in configuration is not evidence they are needed. Do not weaken provider-key withholding. For each guest handoff, prove the components required by its resolved policy, including required provider brokers in none mode. Do not accept “some provider exists” when the selected agent requires a different provider. An agent-free shell or local-model workflow needs no unused remote-provider broker; none mode needs no unused public-egress companion.

Apply the applicable proof to creation/restart, running-instance reuse, agent/shell/exec, guest updates/hooks, transfers and editor handoff. Skipping installation does not skip runtime isolation or required-capability readiness. A cached record or guest-authored answer cannot replace current host proof, and a prepared environment cannot silently adopt a changed identity. Revoke host-held streams/grants on loss; killing one SSH process alone does not account for other guest processes.

Read-only policy reporting, native offline stage apply and teardown use their own authorities. They must not require a live guest proof merely to inspect or revoke old authority; preserve SSH-02/03 cleanup behavior. [Bootstrap requirements][I-BOOTSTRAP]; [brokered session verification][I-BROKERED-TRANSPORT].

### LIFE-01 — Restart rollback and deadline enforcement

Add coordinated rollback around post-boot restart provisioning/readiness failure: revoke resources created for the failed attempt, stop the VM with bounded escalation and preserve its disk/work. If cleanup cannot be confirmed, retain an unhealthy/unknown state and refuse new workload handoffs until reconciled. Keep owned-resource identities so cleanup cannot kill an unrelated replacement. Ordinary hook exit failure retains HOOK warning semantics; readiness/security failure aborts. [Current lifecycle][I-PROJECT]; [backend start/stop][I-APPLE-LIFECYCLE].

An 8h boot deadline is an **authority cutoff**. Every admission point MUST deny new authority at expiry. While the host is running, revoke existing network/broker/session grants within 30 seconds of expiry; permit at most a further 30 seconds for disk-preserving shutdown and escalation. By that second bound, report confirmed stop or an explicitly unresolved, fenced state; never report a successful stop without evidence. If authority revocation itself cannot be established, close the owned transport/service path and refuse reuse until reconciled. These are new qualification targets, not guarantees demonstrated by the current polling loop. A tuple that cannot enforce the authority bound is not qualified for this profile. [Existing owner polling and halt path][I-LINUX-OWNER].

Reconnect, CLI death, owner respawn and host sleep must not extend the deadline. Evaluate expiry before restoring authority after wake; tests measure the running-host bound separately from suspension and must prove expired work is not readmitted. Wall-clock rollback cannot mint extra authority within the same boot. An explicit new start under a newly validated policy creates a new boot/session; failure or missing records does not.

Keep persistent up workflows and retained disks; this change does not make all execution disposable. Document the grace and uncertain-stop states, test a guest refusing shutdown, and preserve explicit unlimited compatibility only for ordinary local instances. Enrolled remote boots and iso-ci remain finite under DEF-01. [Existing TTL contract][I-TRUST]; [deadline construction][I-APPLE-LIFECYCLE].

### AUD-01 — Extend the existing audit contract

Record effective policy and grant provenance, explicit relaxations, refusals, readiness/revocation decisions, snapshot/stage identities and deadline outcomes through the existing typed boundary/run events. Extend existing schemas/renderers deliberately; do not invent a parallel capability log or record free-form secret-bearing diagnostics.

Retain metadata-only redaction, bounded append/read/export/retention and visible gap semantics. Do not record secret values, provider bodies, prompts, raw argv, terminal data or hashes of any of those excluded categories. Use opaque identifiers and approved policy/manifest identifiers where appropriate. Current history is host-editable, and network/remote coverage is not complete; do not describe it as tamper-resistant or comprehensive.

Audit recording failure remains separate from the policy engine: it must not make an otherwise forbidden action allowable, nor prevent stop/cleanup. Preserve the existing warning/gap behavior rather than making observability success a new security dependency. Dry-run creates no audit state. Suggested narrowing configuration is advisory and grants nothing. [Audit contract][I-AUDIT].

### CI-01 — Apply the same boundaries to iso-ci

Keep iso-ci a separate optional companion. Its job VMs require qualified brokered hosts and finite limits; no vmnet fallback or developer-VM reuse. Workflows/actions can request capabilities within approved pool policy, never authorize new destinations, host executables, host paths or secret sources, or increase resource ceilings. Approved jobs may select guest executables and consume their explicitly mapped guest-secret grants. Do not relax global iso defaults to make a CI workflow pass.

Apply INPUT/IMPORT/AUTH and RET-equivalent object/path rules to local snapshots, checkout, action downloads, caches, artifacts and selected output. Current local preflight embeds a `base.bundle` from HEAD even when credential-looking paths are excluded from the overlay. V1 selected-content mode MUST omit that original bundle and all original history; overlay exclusion alone is insufficient. Introduce `iso-ci.snapshot/v2` for the selected-content snapshot/checkout contract; old readers must refuse it rather than interpret it as the history-bearing v1 format. Recapture legacy snapshots. A synthetic repository identifies its own commit honestly and may separately record original-source provenance. Qualify checkout/action behavior on selected bytes and refuse history-dependent local jobs with an unsupported-capability error. No successful local history-grant mode is required or offered in this release. Connected CI retains its separately authorized repository/ref retrieval contract and must state that disclosure scope; it is not covered by a claim that no repository history reaches any CI guest. [Snapshot construction][I-CI-SNAPSHOT]; [guest checkout][I-CI-OVERLAY]. Map each surface's actual authority separately: connected jobs may intentionally receive bounded runner/job tokens; GitHub App private keys and installation access tokens MUST remain host/controller-side, and ambient developer credentials must not enter job guests by default. Do not claim that every CI token can stay host-side.

An artifact stored as inert data is not automatically authorized for installation into a host workspace. Extraction/import that mutates a host destination must pass the validated installer and sensitive-path rules; CI approval is not implicit host execution approval. Isolate cache namespaces and validate contents on use; action-declared URLs and archive paths cannot enlarge host authority.

Reuse host.capabilities/net-handoff-1 evidence and existing job admission/cleanup. Preserve existing grant-free CI run-policy restrictions and exact image/policy matching; do not silently enable ordinary interactive provider/local-service grants for job boots. Test cancellation, timeout, reconnect, stale worker/service epochs, artifact interruption and failure cleanup with finite leases/deadlines. Preserve documented qualification limitations: existing source/tests or local evidence do not prove a signed tagged release passed. [CI behavior][I-CI]; [CI qualification][I-CI-QUALIFICATION]; [host capabilities][I-CAPABILITIES].

### DEV-01 — Preview discovery; give narrow remedies

For discovered devcontainers, parse/translate into a frozen preview before asking for acceptance. Display requested workspace/import/network/credential/command effects and their grant provenance. Discovery grants nothing; explicit selection is useful workload authorization but does not override host policy. Preserve refusal of unattended implicit discovery unless a host policy explicitly supplies the concrete needed authority.

Keep prepared-image provider-only work and explicit filtered development as distinct supported workflows. Errors identify the missing provider, approved host, selected file, compatible transport or grant. Do not suggest the broad networked preset or disabling the proxy as the first remedy. Preserve current project mount limits and persistent workflows. [Current discovery][I-DEVCONTAINER-RESOLVE].

### MIG-01 — Preserve work while changing defaults

Produce a read-only report of requested policy, recorded transport/egress, live boot proof, saved environment/forwards, imports, deadline and source of each relaxation. Distinguish incompatible policy, unavailable evidence and corrupt/missing records. Do not resolve secrets or modify a VM to generate it.

Omitted fields adopt the new baseline when the gated default change ships. Deliberate trusted-host settings remain explicit relaxed choices. Where older generated values cannot be distinguished from deliberate choices, require a concrete migration selection; do not silently widen, erase or reinterpret them. The commented setup template does not itself materialize old explicit grants.

Keep existing transport and creation-time egress immutable. No implicit disk reuse or secret carry-over when moving vmnet to brokered. A stopped compatible instance may receive a separately validated allowed-host policy through its supported transition; a crashed owner must be fenced/stopped before mutation. Missing policy is not permission to adopt a VM.

To preserve an old instance's work, offer a narrowly scoped migration receive using the full RET gate, review selected output, and create a fresh VM from a trusted prepared image. Never auto-destroy the source VM. An explicit decision to retain its old authority is valid and must be reported as relaxed. Committing its disk or deleting known auth files does not prove credential scrubbing.

Reconcile persisted guest environment and forwards as well as current config under POL-01's origin, precedence and durable-revocation rules. Removed configuration-derived fields must not resurrect saved grants; deliberately persistent command authority remains visible rather than being silently merged back in. Unknown-origin legacy entries require explicit reauthorization. Deauthorizing a host capability does not prove previously disclosed bytes were erased from the guest. Handle exposed credentials according to actual exposure. Old binaries/clients must reject unknown security-critical policy; no downgrade path may reinterpret brokered state as vmnet. [Recorded network policy][I-NETWORK-POLICY]; [restart inputs][I-PROJECT]; [trust and committed images][I-TRUST].

## 9. Existing protections to preserve and verify

Do not turn every upstream change into a claim of a missing iso fix:

- Guest host-key pinning and disabled guest SSH agent use already exist. Keep them.
- Brokered runtime/device verification, host deadlines and refusal of expired owner/session state already exist. Compose and qualify complete authority cutoff; do not describe TTL or all none-mode runtime proof as missing.
- Audit history and qualified, grant-free CI admission already exist. Extend their coverage without replacing their established redaction, credential, image/policy or cleanup-debt rules.
- Runtime disk mutations already use stopped-state/operation-lock checks; verify failure and race cases before changing that machinery.
- Iso's sandboxed editor and maintenance VM are stronger architectural measures than coop's new warnings for those specific host boundaries.
- Mandatory signed checksums, revocations and downgrade protection already exist; origin/asset binding adds another control.
- Private state permissions and descriptor primitives already exist in parts of iso. Enforce RET-03 for new boundary control files now. A broader P1 audit/migration of runtime, instance, approval and credential ancestry/ACL/lock handling is a separate scoped follow-up; preserve intentional user-configuration behavior. Do not transplant Linux sudo/rootfs code or claim all storage is currently hardened to coop's exact model.
- Existing stage budgets, native diffs, per-write hashes, policy receipts and no-delete semantics remain part of the design. Correct stale design documentation instead of reimplementing them.

The detailed upstream disposition matrix in §13 records which remaining coop changes are optional or backend-specific. Section 8 contains iso-specific secure-default requirements, not newly attributed upstream changes.

## 10. Deferred work and rejected alternatives

| Item | Decision and reason |
|---|---|
| Host-owned three-way synchronization baseline | Defer. It is a convenience/data-integrity feature, not needed to remove host Git. Existing stage-old hashes remain drift observations, not sync history. |
| Git history transfer in either direction | Deferred separate capability. V1 selected-content base iso/local CI refuses history-dependent requests and sends no original base bundle. Preserve existing work/commits. Connected CI's existing explicitly authorized source retrieval remains a separately stated disclosure scope. A future bundle remains untrusted parser input. |
| Structured guest-exec RPC | Defer until justified by product needs. It adds protocol/PTY/compatibility scope and does not eliminate SSH for transfers/editors. |
| Receiver process sandbox | Valuable follow-up. Separate parser authority from transport credentials, confine writes to quarantine, and test production confinement. Do not label ordinary private staging a sandbox. |
| Hard receive disk quota | Separate mechanism/qualification. Polling and cancellation do not establish one. |
| Whole-workspace atomic commit/rollback | Out of scope. Use complete preflight, per-operation safety and honest partial recovery. |
| Removing devcontainers | Optional product decision. Enforce workload-to-host boundaries without requiring feature removal. |
| Copying coop's no-host-key-check or blanket no-ProxyCommand flags | Reject; conflicts with iso's identity and brokered transport model. |
| Sanitizing arbitrary Git repositories/configuration | Reject as the return architecture. Support a narrow worktree contract and keep Git interpretation separate. |

If a later baseline is implemented, capture the exact successfully exported immutable host snapshot in private host state. Use common baseline B, current host H and validated guest G: equal H/G is a no-op; G=B preserves a host edit; H=B permits a guest update; divergent edits conflict. Keep B for host-only edits until actually exported, advance only known-completed paths after partial apply, and never infer deletion from an omitted guest file.

## 11. Implementation sequence and repository map

Keep each PR a coherent change, separating preparatory refactors from behavior where required by repo conventions. Deliverables may span small sequential PRs; one row does not mean one large patch. The two immediate workstreams can run in parallel: D1 for environment separation, and D2/D3a/D4 for structural validated return. D3b's sensitive-path approval is separately deliverable and mandatory for the secure-default profile. The shipped-default switch is last; neither immediate repair waits for it.

D8 and D9 remain independently deliverable. They gate advertised workflows that use the affected push or post-start paths, not unrelated repairs. D16 gates the new CI selected-content profile or changed CI snapshot behavior; it does not make the optional companion's redesign a prerequisite for every base-iso release. Existing CI regression/admission gates still apply whenever shared changes affect it.

| Deliverable | Scope | Main files / test areas | Dependency |
|---|---|---|---|
| D1: environment repair | ENV-01–05 | `Guest/GuestSession.swift`, remote `HostControl/ClientBindings.swift`, existing env/name types; SSH/host-control tests | Independent of workspace work |
| D2: receive lifecycle | RET-02–04, RET-10 monitoring | `WorkspaceStage.swift`, `Workspace.swift`, `ProcessRunner.swift`, `ChildGroups.swift`, explicit lock/lease support; process/stage tests | Before claiming validated return |
| D3a: structural return and installer | RET-01, RET-05–08; retain existing conspicuous-path warnings | `WorkspaceStage.swift`, `WorkspaceStageApply.swift`, `WorkspaceStageReview.swift`, `Policy/WorkspacePolicy.swift`; stage/policy tests | D2 lifecycle contract |
| D3b: sensitive-path approval | RET-11 and return-policy version 2 | Same native plan/installer; exact-path CLI option and single-attempt policy approval | D3a/D4; required for D18, independent of the narrow structural-return release |
| D4: return compatibility/migration | RET-09–10 | Local/client-side remote CLI, help/error/surface fixtures, docs and stage migration; no new JSON return command | D2/D3a |
| D5: managed SSH context | SSH-01–03 | `Guest/SSH.swift`, guest sessions, transports/forwards/editor/control callers; readiness/brokered/editor tests | Builds on D1; separate claim |
| D6: updater binding | UPD | `Update.swift`, `UpdateRelease.swift`, `UpdateCheck.swift`, updater tests and fixture routing | Independent |
| D7: allocation reservation | ALLOC | `State/StateStore.swift`, lifecycle/state tests | Independent |
| D8: guest push guard | PUSH | `Workspace.swift`, `WorkspaceTests.swift`, guest integration | Independent; retains guest Git only |
| D9: hook ordering | HOOK | `Lifecycle/ProjectLifecycle.swift`, bootstrap/hook APIs, lifecycle tests | Readiness and provisioning contracts |
| D10: effective policy and trusted configuration | POL-01; precedence, grant origins/revocation and baseline infrastructure without switching defaults | `Sources/IsoConfiguration/`, `Guest/AgentLaunchPlan.swift`, `HostControl/HostCapabilities.swift`, existing policy/state/reporting | Foundation for default-gate work; preserve existing feature/admission roles |
| D11: selected outbound snapshots | INPUT-01; v1 selector/exclusion/limits contract and immutable selected-data payload | `Workspace/Workspace.swift`, lifecycle/import callers, remote `HostControl/ClientBindings.swift`; host filesystem/transfer tests | D10; D8 before advertising the affected ordinary push workflow |
| D12: confined explicit imports | IMPORT-01 | `Sources/IsoConfiguration/ConfigDecoding.swift`, `Guest/BootstrapStaging.swift`, `Guest/BootstrapCodex.swift`, `Guest/BootstrapClaude.swift` | D10/D11 snapshot contract |
| D13: scoped source authentication | AUTH-01 | `Credentials/GitHubTokens.swift`, `Devcontainer/DevcontainerGitRepo.swift`, clone/source-fetch callers | D10/D11; anonymous or explicitly scoped retrieval |
| D14: required capability and lifecycle enforcement | NET-01, READY-01, LIFE-01 | Existing isolation/egress/brokered/session code, `Guest/Bootstrap.swift`, project/runtime/host-control lifecycle and companion tests | Separate network qualification, needed-provider resolution and restart/deadline PRs; D5 and applicable D9 integration |
| D15: audit provenance | AUD-01 | `State/Audit*.swift`, `Sources/IsoCLI/Commands/AuditCommand.swift`, audit/machine contracts | D10/D14; authorization state remains independent |
| D16: CI boundary coverage | CI-01, INPUT/AUTH/RET adaptations | `iso-ci/Sources/IsoCICore/Preflight/`, execution/admission/artifact/cache/credential paths; existing CI suites | D10–D14 and applicable RET controls; separate companion qualification |
| D17: migration and discovery | MIG-01, DEV-01 | `Runtime/NetworkPolicy.swift`, lifecycle/saved-state, `Devcontainer/DevcontainerResolve.swift`, local/remote CLI and docs | Accurate D10 reports; D11–D14 and RET preservation rules |
| D18: switch and qualify shipped defaults | DEF-01 and complete supported-profile release gates | Configuration defaults/constructors/template/example, onboarding/reference docs, fixtures and native release evidence | D1/D2/D3a/D3b/D4/D5 and D10–D15/D17; D8/D9 for affected advertised workflows; D16 for the new/changed CI profile. Never switch first. |

Paths in this table are relative to `Sources/IsoHost` unless prefixed with `Sources/`, `tests/`, `iso-sandbox/` or `iso-ci/`. Host tests belong in existing `tests/swift/IsoHostTests` suites; configuration changes also use `tests/swift/IsoConfigurationTests`, and runtime/CI changes use their existing package suites. Add focused fixtures rather than a parallel test framework. Update `docs/trust-model.md`, `docs/workspaces.md`, relevant local/remote command docs, configuration examples/templates, CLI baselines, existing machine baselines where an already supported machine surface changes, and the contradictory clauses of the older design document.

Host subprocesses continue through `ProcessRunner`, control-state writes through the existing private/atomic state primitives, and diagnostics through existing stderr/machine-output contracts; companion packages keep their established equivalent seams. Keep guest parsing/validation in appropriate existing module boundaries. [Code style][I-STYLE]; [testing contract][I-TESTING].

## 12. Acceptance evidence and release gates

### 12.1 Required behavior matrix

| Test ID | Positive and adversarial cases | Required observation |
|---|---|---|
| E1 | Guest SHELL/PATH/HOME/loader/SSH names, trusted host values with the same names, original SendEnv regression | Only aliases carry requested guest values on the host. No iso-generated original-name SendEnv remains; alias preparation does not select trusted host values merely because names match. |
| E2 | Empty/Unicode/quotes/newlines, alias and reconstruction-state/saved-shell collisions, NUL, limits, missing aliases, failed assignments | Exact supported round-trip; wrapper state survives guest names; bounded fail-closed errors without host-generated value disclosure. |
| E3 | Both exec overloads, PTY/non-PTY, remote launch, binary stdin/EOF, TERM override, signals and exit status | Existing IO/supervision semantics preserved; local-attach normalization and separate remote-launch TERM behavior explicit. |
| S1 | Ambient SSH config/PATH/agent/local-command/provider settings versus each managed role | No unintended host authority; intended guest pins, management authentication and explicit connectors still work. |
| S2 | Lost boot/lease, missing/replaced control socket, cleanup after revocation | Existing owned sessions terminate without a new unauthorized connection or unrelated-process kill. |
| R1 | Host Git marker fixtures in old destination and incoming metadata; every apply mode and migration | No host Git, repository-configured helper, external diff/textconv, pager or editor. Qualified transfer receivers remain governed by RET-04. Positive control confirms the fixture was meaningful. |
| R2 | Guest ignores filters; root/nested gitfiles, directories, existing .git symlinks, filesystem aliases and recognized unsupported layouts | Protected host entries unchanged; unsupported gitfile/symlink forms fail clearly. Arbitrary bare/custom configurations remain outside the guarantee. |
| R3 | Hostile receiver paths/order/metadata, all link components, hardlinks/special files, duplicate/colliding names, PATH/tool-control substitution | Actual qualified protected receiver/context is launched; outside-tree sentinels stay unchanged before inventory and after reaping. Structural failure refuses the whole plan; safe ordinary files succeed. |
| R4 | Destination/control-root overlap, absent root during review/missing authorization, creation race, missing parent, renamed root/parent, nested concurrent applies | No unauthorized root/ancestor creation. Safe-create happens only after preflight/authorization and is recorded as a mutation; verified handles and overlap serialization hold across data roots. |
| R5 | Parent SIGKILL/TERM, lingering writer, retry, discard, old stage plus failed receive | No active-tree reuse/deletion/promotion; old selected stage survives failed replacement; retained state stays bounded. |
| R6 | Receiver closes stderr then writes or stalls; both cancellation callbacks; inspection failure | Polling/cancellation continues until writer termination; failure never becomes an accepted stage. |
| R7 | Late-file tamper before apply, review-byte/ancestor changes, manifest tamper/version, policy/epoch change, edit during temporary-file copy | Complete preflight fails before the first write; stale review is refused; destination drift is rechecked immediately before replacement. |
| R8 | Failure before durable begin, crash after begin before first write, root creation, temporary write/rename/type change, crash after mutation before outcome | Failed begin yields zero writes; attempt authorization cannot replay. Accurate completed/failed/uncertain effects and fresh reconciliation/approval; unsupported destructive transitions refuse before writes. |
| R9 | Legacy/schema/policy versions, force in stage/direct modes, missing/wrong stage ID in interactive/noninteractive CLI, remote/offline apply, unsupported JSON output | Separate apply requires exact ID; direct binds its own stage; force does not persist future authority. JSON return commands remain unsupported. No bypass, lost retained work or implied worker approval protocol. |
| R10 | .husky/.envrc/editor tasks, nested/aliased/link paths, force/direct, changed bytes, duplicate/unknown/prefix operands, policy requiring trusted confirmation | Exact-path attempt grants only; missing any grant leaves the entire stage and absent root unchanged. Named arguments do not satisfy separate policy confirmation; structural/no-Git rules remain nonwaivable. |
| U1 | Production source override, wrong requested tag, bad/duplicate asset metadata, hostile redirects, legitimate CDN redirects, normal gh/curl paths | Rejected before unauthorized network/credential use; no binary replacement on verification failure. |
| U2 | Valid signed release, bad signature/hash, revoked digest, downgrade, unavailable gh | Existing signature/revocation/downgrade guarantees preserved and accurately described. |
| A1 | Corrupt/unknown allocation, existing file/symlink/directory, concurrent/case-colliding creators | No reused identity/index or overwritten instance metadata; readable unrelated listing remains usable. |
| P1 | Guest Git/SSH failure, gitfile/worktree, dirty/ahead, no configured upstream versus broken configured upstream, malformed/truncated output, explicit force | Unknown blocks ordinary push; explicit guest-overwrite authorization is distinct from host safety checks. |
| H1 | Copy/clone/mount-only/no-agent/reprovision, failure and cancellation before hook | Hook sees completed workspace/prerequisites, with one invocation per successful attempt; warning/restart behavior preserved, no exactly-once crash claim. |

Run volume/receiver/SSH behavior on the supported macOS toolchain and both guest families where applicable. Synthetic child tools are useful for launch inspection and fault injection, but cannot replace actual Apple SSH, rsync/tar, APFS and VM qualification. Use synthetic credentials; no live-provider test is needed merely to prove alias handling.

### 12.2 Secure-defaults and capability acceptance

| Test ID | Positive and adversarial cases | Required observation |
|---|---|---|
| SD1 | Missing implicit config, {}, partial network/proxy/pull/agent/limits, strict JSON/JSONC; missing explicit config, empty file, invalid/null values | One intended baseline; malformed/explicitly missing input fails; no null-to-unlimited or nested legacy fallback. |
| SD2 | Filtered/open override, networked preset, explicit vmnet, conflicting combinations, macOS image, incompatible worker | Independent grants preserve other defaults; brokered/open and unsupported tuples refuse; no silent worker or transport change. |
| CAP1 | Project/agent/workflow requests, trusted config symlinks, writable ancestry, mutable approved input, dry-run and migration reports | Only trusted authority grants host capabilities; approved bytes frozen; read-only management queries may establish live evidence, but reports perform no credential resolution/provider calls or VM/policy/grant/audit mutation; unavailable evidence remains unknown. |
| CAP2 | Baseline/preset/config/command conflicts, immutable constraints, removed config, persistent command grant, unknown legacy origin, revocation/restart/crash/ID reissue | Deterministic precedence; immutable limits cannot be overridden. Removed source grants withdraw; applicable tombstones persist before handoff, survive config removal and prevent automatic replacement from unchanged input. |
| IN1 | Modified/staged-added/ignored tracked file, deletion, every classifier pattern at root/nested/aliased paths, exact exception, explicit excludes, tracked/paths mode and recursive subtree | Deterministic v1 selection across initial/push/fallback/import; exceptions neither select extra bytes nor override structural rules. No original history, implicit reconstruction or broad guest deletion. |
| IN2 | Contaminated Git metadata, unsupported index/layout, source races, safe/escaping/chained links, hardlinks/special objects, extra roots, per-file/aggregate budget excess | No repository-selected execution or escape; immutable bounded captures, aggregate accounting and explicit paths/refusal. Qualified tracked discovery is optional; no whole-tree fallback. |
| IM1 | All default/null import paths, explicit import, linked/copied preferences and TOML, source replacement, oversized tree | No default host-home import; every explicit read uses the same confined snapshot; managed guest settings and auth withholding preserved. |
| GH1 | Logged-in gh, ambient token, GitHub off/--no-github, public clone/discovery, required broker/no egress | Anonymous or explicit approved host retrieval; no ambient credential use, guest token or network relaxation. |
| GH2 | Private repo, assigned grant/URL mismatch, failed lookup, submodule/LFS/additional origin | Missing scope refuses; no broader fallback; credentials only reach approved destinations/guest grants. |
| BN1 | Live NIC/channel proof, unsupported Linux image/runtime, macOS guest, remote worker mismatch, missing/expired applicable qualification | Brokered admitted only on its qualified contract; no bootstrap NIC, fake proof or vmnet fallback. |
| BN2 | Guest-root host/LAN/sibling IPv4/IPv6 probes, spoofing/routes, hostile SSH server, approved public/local endpoints, wildcard scope | Unapproved routes/channels fail with positive controls; explicit grants remain bounded and functional. |
| BR1 | Wrong/missing provider, configured but unused locked vault, no-auth/local-model workload, explicit multiprovider provisioning, stale identity | Needed-secret set resolves only approved authority; correct required brokers proved; skip-install cannot bypass isolation. |
| LC1 | Failure after boot, secret resolution, each broker/tunnel/forward/readiness/state step; cleanup failure | No successful handoff; owned partial authority revoked, existing disk preserved, unresolved cleanup blocks adoption. |
| TT1 | Expiry on idle/active streams, local/remote/CI ranges and unlimited, sleep/wake, reconnect, retry, owner respawn, clock changes, slow unlock, wedged shutdown | Earliest applicable deadline wins; no expired admission or renewal. Running-host active revocation within 30s, then at most 30s to stop/escalate or report fenced uncertainty. Remote/CI never accept unlimited. |
| AU1 | Grant/denial/revocation metadata, follow/export/suggestions, secret sentinels, capture failure, missing terminal event | Existing typed redaction/gaps retained; no hashes of excluded content categories or inferred stop; audit failure grants no authority and never blocks teardown. |
| CI1 | Tracked .env sentinel, secret only in prior commit/base bundle, old snapshot reader, checkout reconstruction, history-dependent local job, connected source retrieval | Selected-content payload has no original history or bundle; legacy snapshots recapture; synthetic identity is distinct. Local history requests refuse; connected retrieval discloses its separately authorized scope. |
| CI2 | Action/archive substitution, cross-attempt token/cache/object use, interrupted artifacts, controller reconnect, stale host/image/policy, unconfirmed cleanup | Existing admission/token boundaries retained; no fallback, privilege widening or deletion success inferred; debt remains accounted. |
| DC1 | Implicit discovery, explicit selection, noninteractive use, translated effects, changed devcontainer after review | Frozen preview precedes acceptance; guest setup approval does not confer host capabilities. |
| MG1 | Old implicit-open VM, explicit relaxed config, ambiguous generated defaults, corrupt policy, unknown-origin saved env/forwards, revoked grants, fresh-image migration | Concrete reauthorization without silent adoption/erasure; exact transport stays pinned; revoked/removed source authority does not revive; original VM/work retained and secret carry-over not claimed absent. |

### 12.3 Commands and artifacts

These are existing repository commands to run during implementation, not commands executed for this document:

```bash
swift build --force-resolved-versions
swift test --force-resolved-versions
swift format lint --strict -r Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints
python3 tests/test-cli-surface.py --swift .build/debug/iso
python3 tests/test-machine-contract.py --swift .build/debug/iso
python3 tests/test-lifecycle-contract.py --swift .build/debug/iso
python3 tests/test-audit-contract.py --swift .build/debug/iso
python3 scripts/swift-host-fault-injection.py
./tests/run-integration.sh --only iso
```

Run the relevant companion-package tests when their code changes. For the added CI work, run `swift test --package-path iso-ci --force-resolved-versions`; also run the existing brokered, remote-host, proxy-transition and malicious-SSH native suites with their documented setup and tuple recording. No live-provider credential is needed just to prove selection/redaction, though existing release gates may require separate authorized live evidence. Add the new cases to the actual integration suites and verify those cases executed; a skipped suite is not a pass. Broaden to full integration when changing shared process/transport lifecycle. Updater fixture routing must be migrated without enabling a production bypass; existing install/update integration fixtures should continue exercising the real verification chain.

For each deliverable retain: revision/tool tuple, test IDs and results, negative-test positive controls, injected fault caught, supported/unsupported paths, and explicit unrun gates. Mutations should include reintroducing raw-name forwarding, a host-Git call, bypassing final protected-path validation, removing destination identity checks, ending polling on stderr EOF, and treating corrupt allocation as absent. Tests that still pass under the corresponding fault do not establish the claimed property.

### 12.4 Completion criteria

- D1 can release with the narrow ENV claim after E1–E3 pass on all environment-bearing paths.
- The structural validated-return claim requires D2/D3a/D4 and R1–R9 together, including actual protected receiver launch contexts and supported volume paths. It may release before D3b, retaining warnings and the limitation that returned source remains untrusted. Documented refusal is acceptable for unsupported paths; silent fallback is not.
- Sensitive-path withholding requires D3b/RET-11/R10 and the concrete exact-path caller contract. It is mandatory for the secure-default profile and never a prerequisite for the narrow structural-return repair.
- The broader managed SSH claim requires D5 and S1–S2 across every role.
- D6–D9 each require their own targeted positive/failure/compatibility evidence before release.
- D18 switches shipped defaults only after D1/D2/D3a/D3b/D4/D5, D10–D15/D17, and the applicable secure-default matrix pass for the advertised workflow set. D8/D9 additionally gate affected advertised push/post-start workflows; list any unsupported workflows explicitly. New defaults must not silently remove a previously promised path.
- D16/CI1/CI2 and existing CI admission/credential/cleanup gates qualify the new CI selected-content mode or changed snapshot behavior. Base iso remains independent of that companion redesign; shared/default changes still must pass existing affected CI regression/admission gates. Qualification of one tuple or mode does not establish every local/remote/macOS-guest workflow.
- No release note may call the receiver sandboxed, the disk budget absolute, the whole apply atomic, returned source trusted, audit tamper-resistant, or vmnet none equivalent to brokered without separate evidence for that claim.

## 13. Disposition of upstream changes since the fork

This groups substantive upstream changes after the recorded fork point through the pinned current main. Merge commits, follow-up tests, build repairs and release-note repetitions are grouped with their logical change. “Verify existing” means inspect/test the existing control, not that this review ran the release gate. Dates and revisions are fixed to §1.1; this is not a continuously updated inventory.

| Upstream change / primary commit | Disposition for iso |
|---|---|
| Guest environment aliases and guest-side restoration ([45813fb](https://github.com/trailofbits/coop/commit/45813fb2f156f303d35a56187be80ce0a44ae691)) | P0 — D1 / ENV. Adapt the invariant across all four iso paths; preserve stdin, terminal and secret-classification behavior. |
| Managed OpenSSH execution context ([b4557e4](https://github.com/trailofbits/coop/commit/b4557e43cf25fd3d8a8d88168bacf4ba76b2decf)) | P1 — D5 / SSH. Preserve iso's pinned peers, connector policy, management authentication and teardown authority. It is separate from the focused alias repair. |
| Disable host agent use for guest transports ([0f1c4ef](https://github.com/trailofbits/coop/commit/0f1c4ef72ecfe90863406d1096c35060ade28535)) | Verify existing control. Retain both no forwarding and no agent authentication, including nested transports. |
| Remove host Git during pull ([d1b51dd](https://github.com/trailofbits/coop/commit/d1b51dd293dfbecc55c07f943004d31521b965ad)) | P0 — D3a. Remove direct, ordinary and governed return callers; combine with protected-path installation and explicit overwrite authority. |
| Interruption-safe pull staging ([467b8bd](https://github.com/trailofbits/coop/commit/467b8bdf536fe3179ed96c34cdaacec1b3015271)) | P0 — D2. Qualify receiver lifetime through parent death; a stage lock alone is insufficient. |
| Private storage permissions and pinned operations ([7053df2](https://github.com/trailofbits/coop/commit/7053df244350d27db682fcb49ed68bcdfbe9b3aa)) | P0 for new RET control state; scoped P1 audit for broader existing storage. Reuse existing private/atomic primitives; no Linux privilege-helper transplant. |
| Privileged writes into guest rootfs ([bb5b7bb](https://github.com/trailofbits/coop/commit/bb5b7bb1b61f017abc139d8f89a8d151a94ec252)) | Backend-specific. Preserve iso's maintenance VM separation and verify analogous boundaries. |
| Lima mount escaping and structured YAML serialization ([3a1027e](https://github.com/trailofbits/coop/commit/3a1027ef8d0a0eede284654d9a25cc0d1cd831ef)) | No Lima YAML port. Preserve typed serialization and hostile path/script-character coverage; this group also includes f6263f5 and the serde-saphyr replacement 0cabc7c. |
| Trusted Linux network-tool resolution ([18630db](https://github.com/trailofbits/coop/commit/18630db304c7b9bb20e83da030c4bc9db866a37e)) | Backend-specific implementation. Audit explicit host context for actual analogous iso helpers; do not add Linux ip/iptables/bridge machinery. |
| Exact release attestation workflow and tag ([0c6974b](https://github.com/trailofbits/coop/commit/0c6974b260cbaea41e80e29a0ef64dba73a5bd7b)) | Verify existing provenance checks; preserve mandatory signed checksums and optional gh behavior. |
| Production release origin and asset identity ([c9fa586](https://github.com/trailofbits/coop/commit/c9fa586b382b1246dd347a254bb86ecdb8f900d1)) | P1 — D6 / UPD. Bind repository, requested tag and assets before authenticated downloads, including signature assets and legitimate CDN handling. |
| Remove devcontainer support ([daac1e2](https://github.com/trailofbits/coop/commit/daac1e26b816a66d43043f9ea02af9a386c8a728)) | Optional product scope. These fixes do not require removal; retain explicit host-capability boundaries for project input. |
| Rsync-only workspace transfer ([970f972](https://github.com/trailofbits/coop/commit/970f9727485781c391600be83703fe8ca8d34d26)) | Conditional simplification, not the metadata fix. RET-04 requires qualification or disabling each inbound transport. Outbound tar removal is an independent compatibility decision. |
| Host-editor risk warnings ([89d0838](https://github.com/trailofbits/coop/commit/89d08386c61f254ccc0a74900bb221cb58d09656)) | Preserve iso's stronger default editor enclave; warn accurately for explicitly granted or unconfined paths. |
| Propagate unknown lifecycle/liveness state ([4083f02](https://github.com/trailofbits/coop/commit/4083f02b6ec501f2c16f9b38925b566784985791)) | Verify existing conservative owner-lock/runtime behavior on both guest families. This group includes Firecracker failure reporting in 247dedd; do not infer a missing iso control from try? alone. |
| Serialize stopped-state probes and disk mutations ([257320e](https://github.com/trailofbits/coop/commit/257320eb3e30ea77a37e347e573d614891f10092)) | Verify existing under-lock rechecks and runtime mutation guards. Do not add redundant locking without a concrete race. |
| Reserve corrupt instance directories ([ec69b8e](https://github.com/trailofbits/coop/commit/ec69b8efdffe0332189c169e94894e9697ed4a99)) | P1 — D7 / ALLOC. Strict reservations and exclusive directory creation; lenient status listing remains separate. |
| Reject unknown workspace cleanliness ([7c6cf87](https://github.com/trailofbits/coop/commit/7c6cf8741173a561c4e13fb87c9243ce4657db7f)) | P1 — D8 / PUSH for the guest-side protection. Remove host-side Git checks under D3a instead of hardening their invocation. |
| Bounded shutdown and TAP cleanup ([27cb115](https://github.com/trailofbits/coop/commit/27cb115cced908e5bfc442315375bec14e896925)) | Firecracker-specific code; verify bounded stop and confirmation in iso's runtime. Includes TAP cleanup f327c06. |
| Filesystem repair status and same-size resize retry ([788487c](https://github.com/trailofbits/coop/commit/788487c229b40645ab4a7d25028121c4d9c0e586)) | Backend-specific recovery. Preserve iso's maintenance/transaction invariants and uncertain-outcome reporting; includes accepted corrected e2fsck results in 62638ed. |
| Post-start ordering and cancellation ([d603c4d](https://github.com/trailofbits/coop/commit/d603c4d9355b6fd6c17b906f62f2250b17806469)) | P1 — D9 / HOOK. Finish workspace/mount provisioning before hook invocation; preserve warning and restart semantics. |
| Reject unsupported Lima setup options ([3b82026](https://github.com/trailofbits/coop/commit/3b8202613a0eca7034a7d3cf27a099857b9202be)) | No Lima flags to port. Preserve explicit unsupported-operation rejection for iso guest OS/backend/mode combinations. |
| Codex workspace access-token proxy mode ([b075d7c](https://github.com/trailofbits/coop/commit/b075d7cbb138c7e2855497b1a4261f1cee19b53e)) | Optional feature. If adopted, require fixed endpoint/operation authority, token entitlements and guest credential suppression; no prerequisite for this repair. |
| Explicit guest_files mappings ([f7efdc2](https://github.com/trailofbits/coop/commit/f7efdc2d126ed05f12e36cd4770e241ba2a57e87)) | Optional feature. Existing agent-specific copying is not full parity. New general mappings require explicit host-disclosure authority and validated endpoints. |
| Resumable creation hooks ([a5e2d8f](https://github.com/trailofbits/coop/commit/a5e2d8f7ca40f0b2bbb6f5e941e8c62673dab6a7)) | Optional feature. Do not add a captured-recipe/progress state machine to fix ordinary post-start ordering. |
| Grok support, config and version checks ([2c8dd1a](https://github.com/trailofbits/coop/commit/2c8dd1a27415cb01af7e929c53b90c6dc021807a)) | Optional agent support. Includes unreadable-config handling and version probes; any new agent must reuse common launch and secret policy. |
| Codex native Code Mode host pairing ([39c253e](https://github.com/trailofbits/coop/commit/39c253e8bf10614e3941b4cc6d6135b6507187c5)) | Optional compatibility follow-up if supported CLI versions require it. Pair/test artifact versions; this is not itself host isolation. |
| 1Password API Credential category ([e906b93](https://github.com/trailofbits/coop/commit/e906b9378b758fc6b7c3f4c8912c599569c18582)) | No current built-in parity requirement. Iso's Keychain/vault and user command integrations differ. |
| Nix packaging and lifecycle integration ([1901cfc](https://github.com/trailofbits/coop/commit/1901cfca0257ff9a4ea208f7b9d87fbd4ca6ba8c)) | Optional packaging. A Rust/Lima recipe is not an iso security fix. |
| Lifecycle-aware/live completions and macOS Bash fix ([064f388](https://github.com/trailofbits/coop/commit/064f3883c0c11ca63be1ff3008758360de244ff7)) | Optional CLI work; includes caead1e and b225ccc. Iso has a different command implementation. |
| Full proxy release preflight ([5648414](https://github.com/trailofbits/coop/commit/564841415113ed3b3202156d08449e0541022c50)) | Preserve/verify iso's documented release gates and add these boundary regressions. Existing documentation is not proof that a particular release passed. |
| Cross-platform, mutation, disk-pin and umask testing ([86b2876](https://github.com/trailofbits/coop/commit/86b2876bdab7f03f414650365d14a1e5f0bb4221)) | Adopt relevant test methods and supported-platform evidence. Includes bd24c7c, d0d890a, 7ff190d and 888009a; Linux-in-Docker mechanics are not a direct port. |
| MUSL ioctl and cross-linker checks ([7c46174](https://github.com/trailofbits/coop/commit/7c4617414eea5a6e02d9b504b971d14f81e33f72)) | Rust/Linux build-specific. No newly missing iso runtime control. |
| Dependency and CI-action maintenance ([0d89154](https://github.com/trailofbits/coop/commit/0d89154922757708504f36449f57a4d56cf2f7ac)) | Review iso's actual dependencies/advisories. Do not copy Cargo.lock or call every bump a security fix; rustls 0.23.45 was already in the fork baseline. |
| Review host execution and later file interpretation ([ec8b941](https://github.com/trailofbits/coop/commit/ec8b941379792f0318e7218855e191d46def0ee3)) | Apply now as review criteria, together with 9b1b145. Trace complete authority paths; documentation is not mitigation. |
| Host filesystem-repair warning and Lima diagnostics ([cef3ed3](https://github.com/trailofbits/coop/commit/cef3ed3f0db906b0799dcd29d7d07b1d5a0a1bd5)) | Preserve maintenance VM separation. Adopt relevant diagnostic clarity, without importing Lima troubleshooting. |
| v0.9.0 preparation and earlier release metadata ([9e94b9e](https://github.com/trailofbits/coop/commit/9e94b9ee830a10e006e39a7e97e47fc53d103415)) | Version/changelog changes, not a new runtime fix or evidence that v0.9.0 is published. |

The P0 return recommendations go beyond a literal coop port: descriptor-bound destinations, protected control roots, accurate partial outcomes and a qualified supported-layout contract are iso-specific obligations created by its existing stage/policy design. Preserve the editor enclave and maintenance VM rather than reducing those controls to upstream warnings. [Iso trust model][I-TRUST]; [private atomic writes][I-ATOMIC]; [release validation][I-RELEASE].

## 14. Review and sign-off

Implemented on branch `security-hardening` (base `58fb040`). The maintainer
reviewed and approved the stop-and-confirm items on 2026-10-21:

1. New receive subprocesses (`/usr/bin/bsdtar`, `/usr/bin/rsync` openrsync)
   run on guest-sent data, from the protected system tools, with an inherited
   lease and validated layout (RET-03/04).
2. The return installer writes host paths derived from guest data, through
   descriptor-relative, no-follow traversal and the destination binding
   (RET-05–08).
3. The `iso update` chain changed and is stricter: canonical tag, exact
   asset URLs, HTTPS only, fixtures compile-gated (UPD-01).
4. Forwarded guest environment values travel as `ISO_SSH_ENV_<n>` aliases
   (ENV-01–04).
5. New audit events: `pull_held`, `input_snapshot`, `handoff_fence` (AUD-01).
6. Secure defaults: brokered transport, the provider-only preset and an 8h
   session TTL (DEF-01).

Evidence on the final tree:

- Host package tests, companion packages (iso-policy, iso-proxy, iso-egress,
  iso-ci, iso-sandbox), the six host contract scripts and
  `swift format lint --strict` pass; the fault-injection suite detects every
  fault (522).
- S1: the full Apple VM suite (every phase) and the host-control suite, both
  `--local` and `--remote` against a second Mac, pass with a hostile
  `Include` at the top of the operator's `~/.ssh/config` (ProxyCommand and
  LocalCommand writing markers, agent and X11 forwarding, `SendEnv *`, a
  RemoteForward, `StrictHostKeyChecking no`); no marker was written. The
  enrolled-host management hop keeps its trusted configuration by design and
  was excluded from the hostile block. `ManagedSSHRoleTests` resolves every
  role's real arguments with `ssh -G` under the same kind of file. Under the
  same hostile file, sandboxed `iso zed` and `iso code` sessions against a
  real VM each brought up the editor's server in the guest through the
  editor's own SSH (session key, session config, iso's loopback tunnel);
  quitting the editor ended the session and left no session key authorized.
  (VS Code needed Remote-SSH 0.128's scp probe allowed when it uploads a
  host-downloaded server; see the editor sandbox.)
- S2: the VM suite revokes an `--env` grant by ID (absent from the next
  session before any restart), replaces and then removes a port-forward
  control socket (each stop succeeds promptly, starts no new ssh for the
  control path and never signals an unrelated process); the host-control
  suite covers relay session revocation, a lost management link, a
  worker-service restart fencing earlier grants, and TTL expiry with an
  offline client and a wedged guest.

## Source references

[I-PROVENANCE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/PROVENANCE.md
[I-AGENTS]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/AGENTS.md
[I-OLD-SPEC]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/design/selective-hardening-spec.md
[I-STYLE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/code-style.md
[I-TESTING]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/testing.md
[I-ENV]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Guest/GuestSession.swift
[I-REMOTE-LAUNCH]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/HostControl/ClientBindings.swift#L687-L697
[I-SSH]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Guest/SSH.swift
[I-MANAGEMENT]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/HostControl/SSHHostControl.swift
[I-WORKSPACE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Workspace/Workspace.swift
[I-STAGE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Workspace/WorkspaceStage.swift
[I-APPLY]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Workspace/WorkspaceStageApply.swift
[I-REVIEW]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Workspace/WorkspaceStageReview.swift
[I-WORKSPACE-POLICY]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Policy/WorkspacePolicy.swift
[I-PROCESS]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Processes/ProcessRunner.swift
[I-CHILDREN]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Processes/ChildGroups.swift
[I-LOCK]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoCore/FileLock.swift
[I-STATE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/State/StateStore.swift
[I-UPDATE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Update/Update.swift
[I-UPDATE-RELEASE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Update/UpdateRelease.swift
[I-SIGNATURE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Update/ReleaseSignature.swift
[I-PROJECT]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Lifecycle/ProjectLifecycle.swift
[C-ENV]: https://github.com/trailofbits/coop/blob/86b2876bdab7f03f414650365d14a1e5f0bb4221/src/backend.rs#L48-L146
[C-SSH]: https://github.com/trailofbits/coop/blob/86b2876bdab7f03f414650365d14a1e5f0bb4221/src/openssh.rs
[C-WORKSPACE]: https://github.com/trailofbits/coop/blob/86b2876bdab7f03f414650365d14a1e5f0bb4221/src/workspace.rs

[I-TRUST]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/trust-model.md
[I-ATOMIC]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoCore/AtomicFile.swift
[I-RELEASE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/release-validation.md

[I-CONFIG-DECODING]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoConfiguration/ConfigDecoding.swift
[I-CONFIG-TYPES]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoConfiguration/IsoConfig.swift
[I-CONFIG-LOADER]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoConfiguration/ConfigLoader.swift
[I-LAUNCH-PLAN]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Guest/AgentLaunchPlan.swift
[I-CAPABILITIES]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/HostControl/HostCapabilities.swift
[I-BROKERED-DESIGN]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/design/brokered-network-isolation.md
[I-BROKERED-TRANSPORT]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Runtime/BrokeredTransport.swift
[I-MAC-OWNER]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/iso-sandbox/Sources/IsoSandboxCore/MacOS/MacOwner.swift
[I-BOOTSTRAP]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Guest/Bootstrap.swift
[I-BOOTSTRAP-STAGING]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Guest/BootstrapStaging.swift
[I-BOOTSTRAP-CODEX]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Guest/BootstrapCodex.swift
[I-BOOTSTRAP-CLAUDE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Guest/BootstrapClaude.swift
[I-GITHUB-TOKENS]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Credentials/GitHubTokens.swift
[I-DEVCONTAINER-GIT]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Devcontainer/DevcontainerGitRepo.swift
[I-DEVCONTAINER-RESOLVE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Devcontainer/DevcontainerResolve.swift
[I-APPLE-LIFECYCLE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Lifecycle/AppleLifecycle.swift
[I-AUDIT]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/audit.md
[I-CI]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/ci.md
[I-CI-QUALIFICATION]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/design/iso-ci-qualification.md
[I-CI-SNAPSHOT]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/iso-ci/Sources/IsoCICore/Preflight/Snapshot.swift
[I-CI-OVERLAY]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/iso-ci/Sources/IsoCICore/Preflight/Overlay.swift
[I-NETWORK-POLICY]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/Runtime/NetworkPolicy.swift
[I-WORKSPACE-CLI]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoCLI/Commands/WorkspaceCommands.swift
[I-MACHINE]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/docs/machine-interface.md
[I-UNITS]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoCore/Units.swift
[I-EXECUTION-CONFIG]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoConfiguration/ExecutionHostConfig.swift
[I-HOST-SUPERVISOR]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/Sources/IsoHost/HostControl/HostSupervisor.swift
[I-LINUX-OWNER]: https://github.com/chr33s/iso/blob/58fb04089503925070c74630f80edef28b19d9f2/iso-sandbox/Sources/IsoSandboxCore/Owner.swift
