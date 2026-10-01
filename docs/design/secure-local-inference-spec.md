# Secure Host MLX Inference for iso

**Status:** Implementation specification  
**Version:** 0.6.0  
**Date:** October 1, 2026  
**Repository:** `chr33s/iso`  
**Design baseline:** commit `1784c5648f65d8d7bc1c901635cc33f11f80382e`  
**Repository path:** `docs/design/secure-local-inference-spec.md`

**Changes in 0.2.0:** client-derived limits and output-limit clamping; explicit per-adapter field disposition; native-protocol backends before translating adapters; conservative byte-bound admission instead of mandatory gateway tokenization; streamed upstream completion evidence; transport-bound session liveness replacing the guardian and lease renewal; fixed per-user gateway location; reuse of `iso-proxy` transport libraries.

**Changes in 0.3.0 (implementation):** corrections from recorded client fixtures (Claude Code 2.1.285, Codex CLI 0.159.2): an allowed `beta=true` query on Anthropic Messages; browser-origin detection by `Origin` only; hosted-tool declarations dropped rather than rejected; `system` role inside Anthropic `messages`. The output clamp no longer subtracts the input bound (§8.4). Qualification profiles live in `inference.qualification_profiles` (§11.1). Two host-only control operations, `requalify_backend` and `shutdown`, are added (§7), and the gateway exits when idle (§5.1). Backend checks run as a preflight before any VM work (§12.2). A manual revocation withholds inference only; shells and commands keep working (§12.4). Stream translators relay only the protocol's own event types and rewrite every model field (§8.5; found by fuzzing).

**Changes in 0.4.0:** host-side hardening (§20): a dedicated backend account, and an iso-provisioned, launchd-managed MLX backend. That backend requires bearer authentication, runs under its own Seatbelt profile and a GPU memory limit, and is restarted by the host. The gateway's Seatbelt profile allows only the configured backend ports and narrowed reads. `iso inference init` writes a hardened configuration, and `doctor` audits host listeners reachable from guests. Model fetching is an opt-in step pinned to a commit.

**Changes in 0.5.0 (design):** engine-neutral backends (§21). An owner manifest describes any loopback inference engine: its argv template, pinned artifacts, protocols and confinement capabilities. iso supplies the generic launcher, an auth front for engines without authentication, multi-protocol backends and per-profile deadlines. `iso inference qualify` measures qualification profiles instead of the owner entering them. The design is motivated by running ds4 on real hardware (§21.2).

**Changes in 0.6.0:** vsock session transport (§22), implemented with the relay fixes vendored. A spike on real hardware showed that containerization 0.45.0 can relay a host Unix socket into the guest over vsock, fast and bound to the VM. It also showed that the relay dies permanently after one failed host connect, and that a guest can exhaust the owner process's descriptors. §22 sets the relay requirements, the runtime and `IsolationGate` changes, and a systemd guest bridge. SSH stays until the relay is fixed.

> This specification is implemented through §20, and §22; §21 is a design. §19 records which acceptance tests have evidence and which claims remain open. It does not claim a qualified real MLX deployment: qualification profiles are owner decisions, and §17 lists what they must establish. Source review is not a substitute for the hardware and adversarial tests defined here.

## 1. Decision and security objective

Expose host-side MLX inference through a **host-enforced inference gateway**, using iso's existing pinned reverse-SSH transport to reach the guest. Keep the gateway and MLX backend on host loopback. Do not expose the raw MLX port, model-management APIs, host directories, or runtime control sockets to the guest.

The guest receives a capability to request a bounded set of inference operations against approved model aliases. It does not receive authority to select host destinations, load arbitrary models or adapters, retrieve host files, run host tools, or obtain backend credentials.

Use SSH for the first implementation. A dedicated vsock inference channel may be considered separately; it is not required for this design and must not reuse the privileged runtime control channel.

**The gateway enforces an API boundary, not complete host isolation.** An already-running MLX process remains part of the trusted computing base. Request deadlines do not prove that GPU computation stopped. This specification distinguishes mandatory gateway guarantees from separately qualified backend guarantees.

Normative **MUST**, **MUST NOT**, and **SHOULD** indicate requirements, prohibitions, and recommended behavior. Numerical defaults are proposed starting values, not measured performance claims.

## 2. Verified baseline and gaps

The design builds on the following inspected behavior:

| Existing behavior | Consequence for this feature |
|---|---|
| `LocalEndpoints.plan()` maps host IPv4-loopback model endpoints to per-instance SSH reverse forwards. Non-loopback endpoints pass through unchanged. | Reuse the transport, but introduce a distinct guarded-service endpoint type that cannot pass through an arbitrary URL. |
| `ProxyLauncher.syncModelTunnels()` manages forwards and waits for the forwarding acknowledgment. | Reuse lifecycle mechanics and host-key pinning; a forwarding acknowledgment is not proof of backend identity or API readiness. |
| Local model mode takes precedence over the cloud credential proxy. | `proxy.mode: "required"` is not a local-inference policy layer. Add a separate setting. |
| Codex local configuration uses `wire_api = "responses"`; Claude local configuration targets the Anthropic protocol. | Stock Chat Completions support alone is insufficient for these clients. |
| Local-model `auth_token` is passed verbatim; an omitted token receives a placeholder. | This does not create authentication or per-VM capabilities. |
| `egress: "none"` preserves SSH tunnels but does not block services on reachable host addresses. | The feature must not claim to firewall the Mac or guarantee that inference is the guest's only network capability. |
| The guest has root-equivalent authority, and runtime policy excludes host mounts, socket relays, and published ports. | Do not rely on guest policy or relax the runtime isolation gate to implement inference. |
| `iso-proxy` already binds host loopback, verifies a per-instance capability token in constant time, default-denies routes, bounds connections and requests, runs under Seatbelt, and is released a credential only after the host confirms it is the port's sole listener. PIDs are signalled only while they still name `iso-proxy` or `ssh`. | Reuse these transport and verification components as libraries. Do not reuse the cloud proxy's upstream policy, Seatbelt profile, or process. |
| Reverse forwards use `ExitOnForwardFailure=yes` and `ServerAliveInterval=30`/`ServerAliveCountMax=3`. | A forward process exits when its guest session dies; its lifetime is usable liveness evidence (§12.3). |
| `limits.session_ttl` is enforced by the sandbox owner using the host clock, including host sleep. | The gateway receives the same deadline; it does not invent a separate TTL. |

These behaviors are documented in the pinned [model routing implementation][repo-model], [tunnel lifecycle implementation][repo-lifecycle], [configuration reference][repo-config], [credential proxy guide][repo-proxy], and [trust model][repo-trust].

The previously inspected `mlx_lm/server.py` snapshot has Git blob SHA `9462d6e57822df160adc260d9414838179b71907`. It exposes Completions/Chat Completions POST routes, reads model/draft-model/adapter and generation options from request bodies, and warns that its security checks are basic. Its generation-length CLI option is a request default, not an enforced gateway ceiling. No request-cancellation or job-status API was identified in that snapshot; qualification must confirm this (§9.2). This is a source-snapshot observation, not a claim about every MLX serving product or future release. See [MLX server source][mlx-server] and the [snapshot blob][mlx-blob].

Other MLX-based host servers may natively serve the Responses or Anthropic Messages protocols. The design treats "which protocol a backend speaks" as a property of its qualification profile, not of MLX.

### 2.1 Client traffic constraints

The target agent clients shape the defaults:

- Agent requests carry large system prompts and tool schemas; a single Claude Code or Codex turn can exceed 16k tokens before any user content.
- Clients request output limits (`max_tokens`, `max_output_tokens`) well above what a local model profile may allow, and they do not retry with a smaller value after a 4xx.
- Clients issue concurrent requests (subagents, title/summary calls, and small-fast-model calls; iso pins every Claude tier to the local model) and cancel in-flight requests routinely on user interrupt.
- Requests carry client-specific fields (for example prompt-cache hints, thinking/reasoning controls, and request metadata) that change between client releases.

Limits and schemas that ignore these constraints fail every real request. They are therefore fixed from recorded client fixtures (§8.5), not chosen in isolation.

## 3. Scope

### 3.1 First implementation

The first implementation MUST provide:

- A separate host gateway executable, VM/session-scoped listeners and capabilities, fixed backend routing, structured request validation, and bounded admission.
- Attachment to an already-running, explicitly configured IPv4-loopback MLX backend.
- Same-protocol adapters (the frontend protocol equals the backend protocol): a stateless Chat Completions frontend, and Responses or Anthropic Messages frontends for backends qualified to serve those protocols natively.
- Translating adapters (for example Responses→Chat Completions) only as a later, independently qualified addition.
- Fail-closed integration with agent bootstrap, local-mode selection, VM lifetime, and credential suppression.
- Per-session and shared gateway budgets, cancellation handling, backend quarantine, and secret-free operational audit events.
- Automated policy tests and real Apple-hardware isolation, compatibility, and lifecycle tests.

A release may initially expose Chat Completions only. It MUST reject Codex or Claude configurations whose required adapter is unavailable rather than claim those integrations work. Agent support is reached soonest through a backend that natively serves the client's protocol; a translating adapter is not a prerequisite for the first agent release.

### 3.2 Not in scope

The first implementation does not provide a generic proxy, LAN inference service, GPU passthrough, host tool execution, model downloads, model installation, arbitrary model switching, file APIs, persistent conversations, multimodal URL fetching, or guest access to model caches.

It does not modify vmnet policy, add a `pf` firewall, expose host vsock, remove all host-service reachability, or enforce resource limits on unrelated host applications or other macOS users. Fully managed MLX process launch and mandatory backend OS confinement are a later extension, not implied by attaching to an existing process.

## 4. Threat model

### 4.1 Trust and assets

Trust the host user, owner-controlled configuration, iso's host controller, gateway, selected adapter implementation, and vetted model assets. Treat the VM, every process inside it, all request bytes, and all guest-authored configuration as untrusted.

Protect host credentials and files, backend selection, gateway control state, other VM sessions, and host availability to the extent the gateway can enforce it. Prompts necessarily cross from guest to host inference; this design does not hide them from the host user or backend.

Assume an attacker can read guest tokens, become guest root, modify agent settings, send malformed HTTP, hold connections open, replay requests, kill guest SSH services, and consume its entire authorized allowance.

### 4.2 Boundaries and accepted limitations

| Threat | Required response or limitation |
|---|---|
| Guest changes `Host`, model name, path, or URL to reach another host service. | Reject or normalize before dispatch; only a host-selected backend can be contacted. |
| Guest invokes backend download, adapter-loading, file, or administrative behavior. | Deny routes and request fields; construct a fresh allowlisted upstream request. |
| Guest steals its own capability. | Expected. The capability grants authority to the entire VM, not an individual agent process. |
| VM A uses its token on VM B's gateway listener. | Reject; listener identity and session capability must both match. |
| Guest requests excessive work or disconnects to evade accounting. | Reserve budgets before dispatch; retain outstanding work until confirmed complete or quarantined. |
| Backend has a memory-safety or parser vulnerability. | Gateway reduces exposure, but backend confinement and patching remain necessary defense in depth. |
| Another host process with the same user identity is malicious. | Outside this security boundary. Loopback and owner-only files are not isolation from the trusted host user. |
| Guest relays its authorized endpoint to another party. | Possible where another communication path exists. Per-VM authorization cannot prove which process originated a prompt or prevent delegation. |

## 5. Architecture

```text
UNTRUSTED LINUX VM                        MAC HOST

Agent / authorized HTTP client
        |
        v
127.0.0.1:<guest-port>
        |
        +--------- pinned SSH -R ------> 127.0.0.1:<session-port>
                                          iso-inference
                                          - listener -> session binding
                                          - capability authentication
                                          - API/model policy
                                          - shared scheduler and budgets
                                          - protocol adapter
                                                   |
                                                   v
                                          127.0.0.1:<backend-port>
                                          existing MLX process
                                                   |
                                                   v
                                               Metal / GPU

HOST-ONLY CONTROL PLANE
iso controller
        |
        +--> owner-only Unix-domain control socket --> iso-inference
             register / activate / revoke / inspect
                                                   |
             iso-inference watches the session's    |
             ssh -R process (kqueue) and deadline <-+
```

### 5.1 Process model

Introduce a companion executable, provisionally `iso-inference`, separate from the `iso` CLI, VM owner, and cloud `iso-proxy`. It is built from the same package as `iso-proxy` and reuses its transport and verification libraries (`IsoProxyTransport`, and the capability-token and route-allowlist pieces of `IsoProxyCore`): loopback listening, constant-time token comparison, connection and request bounds, and HTTP framing. It does not reuse the cloud proxy's upstream policy, TLS trust configuration, Seatbelt profile, or process. Security-relevant HTTP parsing therefore has one implementation and one fuzz corpus.

Run one gateway service per host user, with an independent loopback listener for each VM boot session. A single service maintains shared admission accounting across its sessions and backend aliases. Other users and software remain outside those budgets.

Unlike `iso-proxy` (one process per VM and provider), the gateway is a per-user singleton because the resource it schedules, the host GPU and its attached backend, is shared across VMs. Per-VM processes would each see only their own load and could not enforce a shared backend concurrency limit without an external ledger, which would reintroduce the singleton.

The gateway's control socket and outstanding-work journal live at a fixed per-user location independent of `data_dir`, provisionally `~/Library/Application Support/iso/inference/` (directory `0700`). Every `data_dir` root attaches to the service at that location, so multiple roots cannot create independent global budgets. An owner-only lock file in the same directory serializes service startup. A gateway with no sessions and no outstanding work for 10 minutes exits; the next registration starts it again.

This shared process is a deliberate tradeoff: it gives one authoritative scheduler, but a gateway compromise can affect all of its registered sessions. Neither shared-process memory isolation nor shared-backend prompt-cache/timing side-channel isolation is claimed. Workloads requiring separate confidentiality domains should use separately isolated backends and cache policies; that does not remove the host gateway from their trusted computing base.

The gateway MUST NOT hold cloud provider keys, SSH private keys, or runtime control credentials. It may hold a narrowly scoped local-backend credential when the host explicitly configures one.

Use a versioned, owner-only Unix-domain socket for control. The gateway MUST check peer UID, use a `0700` parent directory and `0600` socket, and never relay the socket into a guest. Guest HTTP routes MUST NOT invoke control operations. Conflicting binaries or control-protocol versions fail instead of launching a second incompatible service.

### 5.2 Session identity and listeners

A session is identified by host-derived instance identity, VM boot generation, gateway epoch, and a fresh session identifier. Do not identify it by a guest-provided header, guest IP, model name, or bearer token alone.

Bind a session listener to `127.0.0.1:0` and retain the bound socket before reporting its allocated port. Never probe a free port, close it, and assume ownership later. Do not use address/port reuse to share a listener with another process.

The SSH destination is fixed to that listener. A request arriving on session B's listener is evaluated exclusively against B's authorization state, even if it presents session A's otherwise valid token. Do not multiplex all VM authority solely by bearer token on one shared guest-facing port.

The controller chooses a free, unprivileged guest port and establishes the reverse forward using iso's pinned SSH options. No dynamic SOCKS forwarding, host agent forwarding, broad bind address, or guest-selected destination is permitted. Protect the SSH control path with an owner-only directory.

## 6. Security invariants

| ID | Invariant |
|---|---|
| INV-01 | Every guest inference request traverses the registered session listener and its policy pipeline. No raw-backend tunnel is created for a guarded service. |
| INV-02 | Guest bytes cannot choose a backend address, port, URL, credential, executable, model path, or adapter path. |
| INV-03 | Authentication is bound to the receiving listener, VM boot generation, gateway epoch, a live bound transport process, and the host session deadline. |
| INV-04 | Capability material never appears in argv, diagnostics, audit records, URLs, repository files, or world-readable state. |
| INV-05 | Frontend and upstream method/path/body schemas are closed allowlists. Unknown behavior is rejected rather than transparently forwarded. |
| INV-06 | No function call produced by a model is executed on the host. Tool names, schemas, arguments, and results remain untrusted data. |
| INV-07 | Request and queue admission is atomic across sessions. Disconnecting does not free capacity for still-running backend work. |
| INV-08 | No failure causes fallback to a raw model endpoint, a cloud provider, or legacy credential forwarding. |
| INV-09 | Revocation prevents new dispatch and initiates cancellation of queued and active requests. Exit of the session's bound transport process, or passing its deadline, revokes the session without controller involvement. |
| INV-10 | Control sockets, model assets, host credentials, and runtime sockets remain unavailable to the guest through this feature. |
| INV-11 | Existing runtime isolation checks remain intact. A gateway transport is not implemented by enabling arbitrary socket relays or published ports. |
| INV-12 | Status distinguishes enforced gateway limits, qualified backend behavior, and unverified assumptions. |

## 7. Capability and control-plane contract

Generate at least 256 bits of randomness for every new session capability using the operating system's cryptographic random source. Use an opaque bearer token and constant-time comparison. A shared placeholder such as `iso-local` is invalid for guarded services.

Authorization state MUST include the session identity, listener identity, approved model aliases, permitted frontend APIs, resource budgets, the host session deadline, the bound transport process identity, and configuration-policy digest. A token cannot widen that state.

Send registration policy over the host control socket. Deliver guest capability material through existing protected bootstrap/stdin or SSH environment paths, never command arguments. If later Codex sessions require host-side token persistence, use an atomic `0600` file in an owner-only instance directory. A gateway restart MUST invalidate persisted old tokens; their presence on disk does not restore authorization.

The proposed control protocol exposes only the following operations:

| Operation | Semantics |
|---|---|
| `register_session` | Validate host policy; allocate an inactive listener and fresh capability; return session and epoch identifiers. |
| `activate_session` | Enable inference only after the controller confirms the expected tunnel and guest configuration were established. Binds the session to the reverse-forward process (PID plus process start time) and the host session deadline; see §12.3. |
| `revoke_session` | Atomically disable admission, drop queued work, request cancellation, and close the session listener. Idempotent. |
| `inspect` | Return redacted status, limits, adapter/backend qualification, and outstanding-work state. |
| `requalify_backend` | Clear a backend's quarantine and outstanding-work journal after the host operator has drained or restarted it (`iso inference requalify`). Refused while the gateway itself still has active work on that backend. |
| `shutdown` | Stop the gateway (`iso inference stop`). Refused while sessions are active unless forced, in which case every session is revoked first. |

Control messages MUST be length-bounded and reject unknown versions, duplicate keys, and unknown operation fields. Capability secrets are returned only to the authenticated control client that performs registration.

## 8. Request pipeline and protocol policy

### 8.1 Processing order

For each request:

1. Enforce connection, header, and read-time budgets; identify the listener's session.
2. Verify that the session is active and the capability is valid before accepting an expensive body.
3. Validate the exact method/path and HTTP framing; reserve bounded body-buffer capacity.
4. Parse a size- and depth-bounded JSON object with duplicate-key rejection.
5. Validate a frontend-specific schema (§8.3.1) and translate it into a typed inference request.
6. Resolve the approved alias to its fixed backend/model mapping; compute the input bound (§8.4.1).
7. Atomically reserve session, backend, and shared capacity; enqueue or reject.
8. Construct a new upstream request from approved fields and fixed configuration. Request a streamed upstream response whenever the backend profile supports it, regardless of whether the client requested streaming (§9.2).
9. Stream bounded output with backpressure, deadlines, and cancellation support; aggregate for non-streaming clients.
10. Settle accounting only when backend work is confirmed complete; otherwise quarantine as specified below.

Do not forward raw guest headers, raw JSON bodies, or arbitrary unknown properties to the backend.

### 8.2 HTTP rules

Accept origin-form paths only. Reject absolute-form targets, `CONNECT`, protocol upgrades, encoded path separators, ambiguous normalization, duplicate authorization headers, and ambiguous `Content-Length`/`Transfer-Encoding` combinations. Query strings are rejected unless the adapter's field table names the exact query; the only one in 0.3.0 is `beta=true` on `POST /v1/messages`, which Claude Code sends on every request. The query is never forwarded.

For the initial implementation, require a valid bounded `Content-Length` for POST bodies, reject chunked uploads, and reject compressed request bodies. Authenticate and validate declared limits before responding to `Expect: 100-continue`. Streaming responses remain supported. Client qualification (§8.5) MUST record the request framing and `Content-Encoding` each qualified client version actually sends; a client that requires chunked or compressed uploads is unqualified until a bounded decoder is specified and fuzzed, not silently accepted.

Rebuild outbound `Host` and authentication headers. Remove guest `Authorization`, `Proxy-Authorization`, forwarding headers, cookies, and hop-by-hop headers rather than passing them upstream. Do not follow redirects. Do not inherit proxy-related environment variables or consult automatic system proxy discovery for backend requests.

The gateway is not a browser service: do not advertise permissive CORS, and reject browser-origin requests (any request carrying an `Origin` header) unless a separately reviewed policy explicitly permits them. CORS is not an authentication mechanism. The Anthropic SDK header `anthropic-dangerous-direct-browser-access` is sent by the Claude Code CLI itself and is not evidence of a browser; it is dropped like other client headers.

### 8.3 Frontend routes

Expose only the subset granted to a session and implemented by a qualified adapter:

| Frontend | Allowed routes | Contract |
|---|---|---|
| OpenAI Chat Completions | `POST /v1/chat/completions` | Stateless text conversation, approved function-tool data, bounded generation, optional SSE. |
| OpenAI Responses | `POST /v1/responses` | Stateless input, streaming events, approved function calls and results; force `store: false`. |
| Anthropic Messages | `POST /v1/messages` | Text messages, system content, approved tool definitions/results, bounded generation, optional SSE. |
| Anthropic token counting | `POST /v1/messages/count_tokens` | Enable only with a separately qualified exact counter (§8.4.1); do not invent counts. |
| Discovery | `GET /v1/models` | Optional authenticated synthetic response containing only authorized public aliases. Disabled unless a client fixture requires it. |

All other routes are denied. Health and management operations use the host control socket, not guest HTTP. An application needing another endpoint requires an explicit policy and qualification update.

For Responses, reject persistent conversation identifiers, `previous_response_id`, uploaded-file references, remote prompt references, background jobs, hosted-tool calls or outputs in `input`, and remote-resource fetching. A hosted-tool *declaration* in `tools` (for example `web_search`, which Codex declares by default) is dropped: removing it cannot widen authority, and the local model never sees it. For every protocol, reject image/audio/file/URL inputs in the text-only first release. Tool results are text/data, never host file access.

#### 8.3.1 Field disposition

Each adapter version carries a closed, versioned field table covering request bodies (at every nesting level that accepts objects) and request headers. Every field has exactly one disposition:

| Disposition | Meaning | Examples |
|---|---|---|
| `forward` | Validated against its schema and bounds, then copied into the constructed upstream request. | Messages, system content, function-tool definitions, bounded sampling parameters. |
| `rewrite` | Replaced with a host-derived value. | `model` (alias → upstream ID), output limit (§8.4), `stream` (§8.1 step 8), Responses `store: false`. |
| `drop` | Accepted, shape-checked, bounded in size, and not forwarded. Used for fields with no local meaning whose removal cannot widen authority. | Prompt-cache hints, request metadata, client beta/feature headers, thinking or reasoning controls the backend profile does not support. |
| `reject` | Request fails with `403` or `422` before backend dispatch. | Fields listed in §8.3 and §8.4, and every field absent from the table. |

Unknown fields are rejected, so the table must cover every field a qualified client version sends. The table is derived from recorded fixtures of each qualified client version (§8.5); a client update that introduces a new field requires a table update and requalification. `drop` is never inferred: a field is dropped only when the table names it. Dropped fields remain untrusted and still count toward body and depth limits.

### 8.4 Model and generation policy

A guest-visible alias such as `local-coder` maps to one fixed backend and upstream model identifier. The gateway MUST substitute that mapping into its constructed request. Unknown aliases are rejected before backend dispatch.

Reject guest-selected `draft_model`, adapter names or paths, tokenizer selection, chat templates, template execution options, remote-code settings, download options, and local filesystem paths. Host-owned backend configuration may preselect such features, but they are not guest request parameters.

Bound temperature, sampling options, stop sequences, tool counts, and schema sizes through a versioned schema; reject out-of-range values for those fields. Force a single generated candidate in the initial release.

Output length is handled differently because agent clients request limits above any local profile and do not retry smaller (§2.1). Normalize frontend generation-limit fields to one internal `max_output_tokens`:

- Absent: use the service's `default_output_tokens`.
- Present and within the service ceiling: use it.
- Present and above the ceiling: clamp to `max_output_tokens` and send that value upstream. Record the clamp as a `limit_clamped` audit event. The input bound (§8.4.1) is not subtracted: it overestimates tokens, so subtracting it would shrink the output allowance of requests that fit the context window. Context-window fit is the backend's responsibility (§8.4.1).
- Non-positive, non-integer, or conflicting (two frontend fields disagreeing): reject with `400`.

Always set the upstream output limit explicitly; never rely on an upstream default. When generation stops at the clamped limit, report the protocol's length-limit stop reason (for example `max_tokens` or `length`), never a normal completion.

#### 8.4.1 Input bound

The gateway MUST NOT require an in-process model tokenizer or chat-template engine for admission. Executing a model's chat template in the gateway would add a template interpreter and tokenizer implementation to its trusted computing base.

Instead, compute a conservative input bound: the UTF-8 byte length of all text-bearing fields forwarded upstream (including tool schemas), plus a per-message and per-request overhead taken from the qualification profile. For byte-level BPE tokenizers, and byte-fallback tokenizers, each token covers at least one byte, so this bounds the token count from above; qualification MUST confirm that property and the overhead constants for each model profile. Tokenizers without that property are unqualified for byte-bound admission.

- Admission, the shared memory budget, and rate accounting use the bound; `max_input_bytes` caps it.
- Because the bound overestimates, it is not used to reject a request for exceeding the model's context window. Context-window enforcement is delegated to the backend, whose over-length behavior (reject vs. silent truncation) MUST be recorded in the backend profile. A backend that silently truncates is qualified only with that limitation shown in status.
- Backend-reported usage reconciles token accounting after completion; usage that exceeds the bound is a qualification failure and quarantines the backend.
- `count_tokens` is exposed only when a separately qualified exact counter exists (the backend's own count endpoint or a qualified out-of-process tokenizer). The byte bound is never returned as an exact count.

### 8.5 API adapters and qualification

Adapters come in two kinds:

- **Same-protocol:** the frontend and backend speak the same protocol. The adapter validates, applies the field table, and constructs a fresh upstream request; responses and stream events are parsed, bounded, and re-serialized, not piped through. This is the first-release path for every protocol.
- **Translating:** the frontend protocol differs from the backend's (for example Responses→Chat Completions). It MUST implement semantics, not merely rename an HTTP path. It is a later addition and is qualified independently.

Qualification of either kind must cover event ordering, terminal events, usage, tool-call identifiers, incremental arguments, multiple tool results, error translation, disconnects, and full multi-turn client exchanges.

Qualify an explicit tuple of client version, gateway adapter version (including its field table), backend version and protocol, model assets, input-bound overhead constants, and enabled features. Store the manifest in host-controlled state. Qualification fixtures are recorded real client traffic for that client version and also fix the limit defaults (§9.1). Backend self-reported HTTP features alone are not sufficient evidence.

If an adapter or model profile cannot support the configured client and model, bootstrap fails with `INFERENCE_PROTOCOL_UNSUPPORTED` or `INFERENCE_MODEL_UNQUALIFIED`. No automatic fallback to Chat Completions, approximate token counts presented as exact, or cloud behavior is allowed.

## 9. Resource limits, scheduling, and cancellation

### 9.1 Proposed defaults

These values require validation on supported hardware and representative coding workloads. Rows marked *fixture-derived* have no fixed default: the qualification profile sets them from the largest request observed in the recorded fixtures of each qualified client version, plus headroom, and bootstrap refuses a service whose limits are below its qualified client's fixture requirement. Host configuration may tighten other limits; increases require schema bounds and explicit configuration.

| Budget | Proposed default | Enforcement |
|---|---:|---|
| Connections | 16 per session; 128 shared | Count accepted idle and active sockets. |
| HTTP headers | 32 KiB total; 64 fields | Reject before body buffering. |
| Request body | 4 MiB, or fixture-derived if larger | Reserve memory before reading; stop at the limit. |
| JSON nesting | 32 levels | Enforce during parsing. |
| Gateway request-buffer budget | 64 MiB shared | Includes queued normalized payloads; parser expansion also requires a bounded memory design. |
| Input bound (`max_input_bytes`) | Fixture-derived | Byte bound of §8.4.1, including tool schemas. Context-window fit is enforced by the backend. |
| Output tokens | 4,096 default; 8,192 configurable ceiling | Clamp larger requests (§8.4); reserve the effective allowance before dispatch and enforce it in the upstream request. |
| Active generation | 1 per backend; 2 shared | One authoritative scheduler across all listeners. No per-session active cap below the backend cap. |
| Queued generation | 8 per session; 32 shared | Covers concurrent agent requests (§2.1); reject excess work; no hidden unbounded queue. |
| Request rate | 30 accepted requests/minute/session; burst 8 | Token bucket, including repeated short requests. |
| Generated-token allowance | 32,768 tokens per rolling minute/session | Reserve the effective maximum; reconcile after verified completion. |
| Queue wait | 300 seconds | Expire before dispatch. At least one full generation deadline, so a request queued behind one maximal generation is not rejected. |
| Header/body read | 5 / 15 seconds | Deadlines do not reset indefinitely on trickled bytes. |
| Time to first output / total generation | 120 / 300 seconds | Measured from dispatch, not enqueue. Independent of SSE heartbeats. |
| Response bytes | 16 MiB per request | Bound serialized output and initiate cancellation on overflow. |
| Cancellation grace | 5 seconds | Quarantine when backend termination cannot be confirmed (§9.2). |

Streaming clients waiting in the queue receive protocol-appropriate keep-alive (SSE comment lines, or the protocol's ping event) so that client idle timeouts do not fire; keep-alive does not extend the queue deadline. Non-streaming clients whose own timeout is shorter than the queue deadline are a documented qualification limitation.

Effective limits are the minimum of the session policy, model profile, backend profile, and shared available budget.

Scheduling SHOULD be fair across sessions, with bounded FIFO order inside a session. Normalize backend identities so multiple public aliases or configuration entries cannot bypass one backend's concurrency limit. Apply separate inexpensive rejection limits to unauthorized traffic so authentication failures cannot allocate unbounded work.

### 9.2 Attached-backend contract

Attachment to a pre-existing server enforces what the gateway sends and admits. It does **not** confer ownership of that server or permission to kill it. In particular, closing the upstream HTTP connection does not by itself prove that generation stopped.

Each qualified backend profile declares one completion-evidence class, backed by tests rather than server metadata:

| Class | Evidence of completion | On client cancellation |
|---|---|---|
| `explicit` | A backend cancellation or job-status API confirms the request stopped. | Call the API; release on confirmation. |
| `stream-close` | Qualification demonstrated that closing the upstream streaming connection stops generation, and that the backend's per-request work ends when the stream ends. | Close the upstream stream, then release after the qualified drain interval. |
| `drain` | Only the upstream stream's own terminal event or end-of-stream shows the work ended. | Stop relaying to the client but keep reading and discarding upstream output until its terminal event, within the remaining generation deadline and the effective output-token allowance. Release on terminal event. |
| `none` | No reliable evidence. | Quarantine on any cancellation. |

Because the gateway requests streamed upstream responses (§8.1 step 8), a backend that streams with a reliable terminal event qualifies for at least `drain`. User interrupts then cost at most the remaining bounded generation, not a quarantine. The attached stock `mlx_lm.server` snapshot is expected to be `drain` or `stream-close`; which one is an open qualification item (§17).

On cancellation, disconnect, timeout, or response overflow:

- Cancel queued work without dispatch.
- Apply the backend's completion-evidence procedure and close the client response when necessary.
- Retain the active-work reservation until that procedure yields completion evidence.
- If evidence does not arrive within the grace period (for `explicit` and `stream-close`) or the remaining generation deadline (for `drain`), mark that backend `quarantined` and refuse new dispatch to it.

Never release capacity simply because a client disappeared. Never kill an attached process that may serve other host clients. Clearing quarantine requires reliable completion evidence or an explicit host-side drain/restart and requalification step. Time passing alone is insufficient.

Persist a secret-free dirty/outstanding-work marker before dispatch. After a gateway crash, any backend with unresolved work starts quarantined. Do not reset counters by restarting the gateway while old backend jobs may still run. A conservative false-positive quarantine is preferable to over-admission.

### 9.3 What resource isolation can be claimed

The first release may claim bounded gateway memory, bounded admitted concurrency, request limits, and admission cessation after uncertainty. It MUST NOT claim a hard GPU-time or total-host-memory cap for an unmanaged MLX process.

A future owned-backend mode may add process supervision, an independently enforced kill deadline, constrained memory/cache configuration, and restart recovery. Such claims require tests demonstrating actual cessation of work, not just an HTTP error or disappearance of output.

## 10. Backend isolation and qualification

For initial attachment, accept only an explicit `http://127.0.0.1:<unprivileged-port>` base URL with no user information, path, query, or fragment. Fixed API paths come from the adapter. Reject DNS names, wildcard addresses, IPv6, LAN addresses, and arbitrary schemes in the first version; support may be expanded only with reviewed transport policy.

Before attachment, the controller MUST establish that the selected backend has no listener for the same service on wildcard or reachable non-loopback interfaces. A backend reachable directly from the guest defeats the gateway policy. The check runs without elevated privileges: attempt TCP connections to the backend port on every non-loopback host address the guest can reach (each vmnet host address and each configured interface address); any accepted connection fails attachment with `INFERENCE_BACKEND_UNSAFE_BIND`. Inspection is a startup guard, not proof that another trusted host process cannot expose it later; `iso inference doctor` repeats it.

The gateway's own session listeners are verified the same way `iso-proxy` verifies its listener: the controller confirms the gateway is the port's sole listener before the reverse forward is established.

Require vetted, preloaded model assets. No request may trigger arbitrary asset retrieval. A local-backend credential, when required, must be resolved by the host and delivered over the host control channel; never reuse a guest capability as backend authorization.

The gateway process MUST run with a minimal environment, no shell execution, no general filesystem write authority, narrowly scoped network authority for approved loopback destinations, and only the process-inspection authority needed to watch bound transport processes (§12.3). Operational output and the secret-free outstanding-work journal may use pre-opened, narrowly authorized descriptors. Journal locations and identifiers come only from the host controller; guest strings must not become filesystem paths. Read permissions must be minimized and their residual scope documented.

Do not widen the existing cloud proxy Seatbelt profile: it serves a different upstream policy. Its current documented outbound allowance is for ports 443 and 53, not arbitrary local inference ports. A new gateway profile must be implemented and tested independently. See the [trust model][repo-trust].

For the attached MLX process, report separately whether filesystem restrictions, outbound-network restrictions, cache limits, prompt logging controls, and cancellation behavior have been verified. A loopback bind does not establish any of those properties. A recommended deployment uses a dedicated host account or tested confinement profile, read-only vetted assets, minimal writable cache directories, and no access to host credential stores or unrelated home-directory contents.

Qualification status must name limitations explicitly. The feature must not label an attached backend “fully sandboxed” solely because the frontend is guarded.

## 11. Proposed configuration

### 11.1 New schema

Add top-level `inference` configuration. `mode` is `off` by default for backward compatibility; `required` selects the guarded path. There is no `auto` mode that can fall back to a raw endpoint after an error.

Qualification profiles are owner-controlled configuration under `inference.qualification_profiles.<name>`. A profile records the backend protocol it was qualified for, its completion-evidence class, its context-overflow behavior, its input-bound overhead constants, and its fixture-derived limits. A backend names exactly one profile, and its `protocol` must equal the profile's.

Extend each agent's `local_model` to a closed union:

```jsonc
// Existing legacy form. Not accepted for an agent under inference.mode = required.
{
  "host_url": "http://127.0.0.1:8080/v1/",
  "model": "existing-model"
}
```

```jsonc
// Proposed guarded form. Service and policy resolve only on the host.
{
  "service": "local-coder"
}
```

The guarded form MUST reject `host_url`, `auth_token`, and additional model-routing fields. The gateway generates the guest URL and token at boot. Persist the service selection, not the generated endpoint or raw capability, in model selection state.

### 11.2 Example: guarded local Codex

**This example is proposed configuration, not valid configuration for the inspected baseline.** It assumes an MLX-based host server that natively serves the Responses protocol and a qualified same-protocol adapter and model profile. The stock `mlx_lm.server` snapshot serves Chat Completions only and does not satisfy that requirement; using it for Codex would need a qualified translating adapter.

```jsonc
{
  "security": {
    "preset": "offline"
  },
  "github": "off",
  "limits": {
    "session_ttl": "8h"
  },
  "inference": {
    "mode": "required",
    "global_limits": {
      "max_active_requests": 2,
      "max_queued_requests": 32,
      "max_request_buffer_bytes": 67108864
    },
    "backends": {
      "mlx-main": {
        "base_url": "http://127.0.0.1:8080",
        "protocol": "openai-responses",
        "qualification_profile": "mlx-coder-reviewed-v1",
        "max_active_requests": 1
      }
    },
    "services": {
      "local-coder": {
        "backend": "mlx-main",
        "upstream_model": "HOST_CONFIGURED_PRELOADED_MODEL_ID",
        "frontend_apis": ["openai-responses"],
        "max_context_tokens": 131072,
        "default_output_tokens": 4096,
        "max_output_tokens": 8192
      }
    }
  },
  "codex": {
    "config_dir": false,
    "local_model": {
      "service": "local-coder"
    }
  }
}
```

The qualification profile is an owner-controlled descriptor of the reviewed backend and its protocol, adapter and field table, model assets, input-bound overhead constants, completion-evidence class (§9.2), context-window over-length behavior, fixture-derived limits (`max_input_bytes`, request body), and tested capabilities. Fixture-derived limits come from the profile, so they are absent from the service; a service may tighten but not loosen them. Its name is illustrative; no such profile is assumed to exist today. Replacing the placeholder model ID and qualifying the deployment are required setup steps.

To use Claude, select a service granting `anthropic-messages` and, if required by the qualified client, `anthropic-count-tokens`. To expose generic Chat Completions, explicitly grant `openai-chat`; do not enable all protocols by default.

### 11.3 Validation and compatibility rules

`iso validate` MUST reject unknown inference fields, conflicting endpoint forms, missing services/backends, invalid limits, unqualified protocols, and a guarded service reference while inference mode is off.

Under `required`, every agent launched through iso must have an authorized guarded service. An unconfigured agent fails locally; it must not retain the existing possibility of silently using a cloud endpoint. Suppress managed cloud-provider credential forwarding and cloud-auth file staging on this path, independently of `proxy.mode`. Reject conflicting provider-credential declarations in `env_forward`, `guest_env`, `--env`, environment files, and persisted environment overrides; do not merely remove the automatically discovered key.

Existing raw local endpoints continue to function only when guarded inference is off, with documentation that they provide transport rather than inference policy. Upgrading configuration is explicit; do not silently reinterpret legacy authentication tokens as gateway capabilities.

The `offline` preset remains recommended, but its existing override behavior remains unchanged. Status must show the effective egress policy. Open-egress sessions cannot claim protection against general exfiltration, and even no-egress sessions retain the existing host-service exposure. Changing an existing instance's egress mode still requires recreation under the baseline contract. See the [configuration reference][repo-config].

## 12. CLI, bootstrap, and session lifecycle

### 12.1 Proposed command surface

Retain `iso model NAME local` and status behavior, extending them to show guarded services. Add:

```text
iso up --model-mode local
iso start NAME --model-mode local
iso inference status [NAME] [--json]
iso inference doctor [--json]
iso inference revoke NAME
```

The `--model-mode` options and `iso inference` command group are new proposals. Resolve requested model mode before offline/provider-auth preflight, so a fresh offline instance can select local inference before agent bootstrap. Do not require an initial cloud-authenticated boot.

For application-only use, add a proposed explicit host command:

```text
iso inference attach NAME --service local-coder --api openai-chat
```

This persists a host-side service grant for that instance. It validates the service's approved frontend APIs and does not accept a guest URL, backend address, model path, or token. Bootstrap and subsequent sessions provide `ISO_INFERENCE_BASE_URL`, `ISO_INFERENCE_MODEL`, and `ISO_INFERENCE_TOKEN` through protected guest-environment delivery. Revoke removes active authority; an explicit attach or host restart decision is required to re-enable a manually revoked grant.

`status` and `doctor` MUST report service alias, session generation, mode, frontend protocol, backend qualification, effective limits (including any clamps applied), egress mode, bound transport process and deadline, completion-evidence class, and quarantine state without secrets. Use names such as `gateway_enforced` and `backend_cancellation_verified`, not an undifferentiated `secure: true`.

### 12.2 Startup transaction

```text
unregistered -> registered/inactive -> tunnel-ready -> active
                                                failure -> revoked
active -> draining/revoked
active -> backend-quarantined (no new backend dispatch)
```

The controller MUST:

1. Resolve trusted host configuration and selected service before credential staging.
2. Verify VM identity, boot generation, host-key pin, and the existing isolation gate.
3. Validate backend binding and qualification; start or connect to the matching gateway service.
4. Register an inactive session and receive the already-bound listener and fresh capability.
5. Confirm the gateway is the listener port's sole listener, then establish a fresh fixed reverse-SSH forward for this session (a guarded forward is never kept across sessions the way raw model tunnels are). Verify the registration nonce, gateway epoch, and ownership of the retained listener over the host control protocol; a generic HTTP response or guest-reported readiness is not sufficient.
6. Write managed guest configuration and remove stale managed local/cloud authentication material from prior modes.
7. Activate authorization, passing the forward process identity and the host session deadline (§12.3), and only then launch the client.

Steps 1 and 3 also run as a preflight before `up`/`start` boot the VM: the gateway binary must exist, and every requested backend must accept on 127.0.0.1 and on no non-loopback host address. A bad backend therefore costs no boot.

Any failure revokes the partial session, closes the tunnel, removes newly staged capability state, and returns an error. Do not publish an unusable endpoint and allow the client to select another provider.

Cleanup cannot erase secrets an earlier compromised guest already copied. For strict migration from a previously credential-bearing VM, recommend a fresh instance. The feature controls iso-managed delivery; it does not claim to scrub arbitrary user-provided files or intentionally supplied secrets.

### 12.3 Session liveness and expiry

The CLI may exit while the VM remains running, so session liveness must not depend on the controller. No separate guardian process and no lease-renewal protocol are introduced. The gateway itself binds each active session to two host-side facts supplied at activation:

- **Transport process.** The session's reverse-forward `ssh` process, identified by PID plus process start time, and confirmed to name `ssh` and to be owned by the same user. The gateway watches it with a kqueue `EVFILT_PROC`/`NOTE_EXIT` filter registered at activation, after re-checking the identity; if the process has already exited or its identity does not match, activation fails. When the process exits, the gateway revokes the session. The forward's `ExitOnForwardFailure` and `ServerAlive*` options (§2) bound how long a forward outlives a dead guest session, so VM stop, crash, or network loss revoke the session within that bound.
- **Session deadline.** The host session deadline from `limits.session_ttl`, as enforced by the sandbox owner. The gateway measures it with a monotonic clock that counts host sleep, so wall-clock rollback cannot extend it.

Guest output never extends either. A transient forward failure revokes the session; the next `iso start`, `iso shell`, or agent launch registers a fresh session with a fresh capability rather than reviving the old one. Deliberate stop and revoke operations act immediately through the control socket.

A restarted gateway issues a new epoch, starts with no active sessions, and does not reactivate old capabilities automatically. Old forwards then point at a closed port; the controller closes them on next contact before registering a replacement.

### 12.4 Teardown and mode changes

On explicit stop, destroy, mode change, or revoke: disable gateway admission first, remove queued work, initiate active cancellation, then tear down SSH forwarding and remove capability files. Teardown is idempotent.

Switching local services creates a fresh policy/session capability and revokes the old one. `iso inference revoke` withholds inference from the instance until the VM restarts or a grant is attached. Shells and commands keep working, and agents reach no model. A revoked service must not reappear merely because `iso shell` or an agent launcher reconnects. Runtime failure and TTL expiry trigger equivalent revocation through the gateway's transport-process watch and deadline check (§12.3); the controller removes remaining host-side state on next contact.

## 13. Error and audit contract

Return sanitized JSON errors before streaming begins. After streaming begins, use the qualified protocol's terminal error behavior and cancel upstream work; do not pretend a truncated generation completed successfully.

| HTTP status | Condition |
|---|---|
| `400` | Invalid framing, malformed JSON, invalid schema, or conflicting parameters. |
| `401` | Missing/invalid capability or inactive/expired session, without revealing token details. |
| `403` | Valid session but forbidden operation, alias, or feature. |
| `411` | Missing required body length or unsupported chunked upload. |
| `413` | Request byte limit exceeded. |
| `422` | Valid request exceeds model/token constraints or requires unsupported semantics. |
| `429` | Rate, token allowance, concurrency, queue, or shared capacity exhausted. |
| `502` | Invalid upstream response or upstream redirect. |
| `503` | Backend unavailable/quarantined or service not ready. |
| `504` | Queue, first-output, or generation deadline exceeded. |

Use stable internal error codes including `INFERENCE_AUTH_INVALID`, `INFERENCE_POLICY_DENIED`, `INFERENCE_PROTOCOL_UNSUPPORTED`, `INFERENCE_BACKEND_UNSAFE_BIND`, `INFERENCE_BACKEND_QUARANTINED`, `INFERENCE_BACKEND_UNSAFE_OWNER`, `INFERENCE_MODEL_UNQUALIFIED`, `INFERENCE_SESSION_REVOKED`, and, with §21, `INFERENCE_ENGINE_INVALID` and `INFERENCE_ENGINE_MISMATCH`.

Extend host audit events with registration, activation, revocation, denied operations, limit rejections, output-limit clamps, transport-process revocations, qualification changes, and quarantine. Record host-assigned instance/session/request IDs, authorized aliases, normalized operation codes, byte/token counts, durations, and reason codes. Do not record prompts, completions, tool arguments, capability values, backend credentials, raw attacker paths, or arbitrary headers.

Logs MUST be bounded, owner-only, and resistant to log injection. Handle repeated rejections with aggregation. Backend logging is a separate qualification check: the inspected MLX snapshot can log request bodies on some errors or at debug level, so gateway redaction alone does not establish end-to-end prompt privacy. See [MLX server source][mlx-server].

## 14. Repository integration map

Existing paths below refer to the inspected baseline. New names are proposed and may change without changing the security contract.

| Area | Work |
|---|---|
| `Sources/IsoConfiguration/ConfigDecoding.swift` and configuration model types | Add inference schema, closed endpoint union, limit validation, and error redaction. |
| `Sources/IsoConfiguration/ConfigTemplate.swift`, `config.example.jsonc` | Document guarded service configuration without implying legacy URL routes receive policy protection. |
| `Sources/IsoHost/ModelState.swift` | Persist service references; generate frontend-specific guest configuration; avoid legacy URL planning for guarded services. |
| `Sources/IsoHost/ProxyLifecycle.swift` | Reuse fixed reverse-forward mechanics, not the cloud upstream policy; prevent duplicate raw-model tunnels. |
| Proposed `Sources/IsoHost/InferenceLifecycle.swift` | Registration, sole-listener and readiness verification, capability provisioning, transaction rollback, and handing the forward process identity to the gateway. |
| `Sources/IsoHost/Bootstrap.swift`, guest-session integration | Resolve local mode early, suppress cloud credentials, remove stale managed state, enforce required-mode launches. |
| `Sources/IsoCLI/AgentCommands.swift` and new inference commands | Status, model selection, application grants, revoke, doctor, and mode preflight. |
| `iso-proxy/` package | Extract the reusable transport, framing, capability, and route-allowlist code into libraries shared with the new executable; the cloud proxy's behavior and tests are unchanged. |
| Proposed `iso-inference` executable (in the `iso-proxy` package) | Field tables, typed adapters, input bound, shared scheduler, completion-evidence handling, control protocol, transport-process watch, session listeners, and audit events. |
| New gateway confinement profile | Minimized host rights; no changes to the existing cloud proxy profile's authority. |
| Runtime owner / isolation gate | No new guest-visible mounts, relays, or ports. |
| Host, gateway, and hardware test suites | Unit, parser fuzz, lifecycle fault injection, backend qualification, and root-guest boundary tests. |
| Documentation and release scripts | Package the adjacent companion binary; document security guarantees, limits, new commands, and qualification evidence. |

Keep cloud proxy regression tests unchanged and passing. Do not convert `iso-proxy` into an arbitrary-upstream proxy to avoid adding a new executable.

## 15. Acceptance tests

All negative tests MUST assert both the client result and whether a controlled backend received a request. Invalid traffic must not be counted as “blocked” merely because the client failed after the backend already acted. Run security tests from a root-controlled guest where applicable.

| ID | Test | Acceptance criterion |
|---|---|---|
| AT-01 | Listener exposure | Gateway and selected MLX service have no reachable LAN/wildcard listener. Raw backend access from the guest fails. |
| AT-02 | VM-scoped authority | A token fails on B's listener; root within A can use A's allowed inference capability, as intended. |
| AT-03 | Token lifecycle | Missing, wrong, expired, revoked, previous-boot, and previous-gateway-epoch tokens fail before backend dispatch. |
| AT-04 | Host-key and tunnel integrity | Wrong SSH host key, occupied guest port, failed forwarding acknowledgment, and unexpected gateway identity abort bootstrap. |
| AT-05 | Fixed upstream | Absolute URLs, `CONNECT`, crafted `Host`/forwarding headers, redirects, and proxy environment variables cannot select a different destination. |
| AT-06 | Route denylist by default | Admin, download, file, model-load, health, and undeclared API routes never reach the backend. |
| AT-07 | Structured body policy | Alternate models, adapters, draft models, remote URLs, file paths, remote-code/template controls, and duplicate JSON keys are rejected. |
| AT-08 | HTTP parser robustness | Conflicting lengths, CL/TE ambiguity, compressed uploads, chunked bodies, malformed paths, oversized headers, and slow reads fail safely. |
| AT-09 | Token and memory limits | Boundaries at the exact configured limits are tested; concurrent bodies and queued requests cannot exceed shared memory admission. Over-ceiling output requests are clamped and report a length stop reason; backend-reported usage never exceeds the input bound. |
| AT-10 | Shared scheduling | Simultaneous VMs, aliases, and data roots obey one shared ledger; fairness and bounded queues hold under load. |
| AT-11 | Disconnect/cancellation | Disconnect storms do not free outstanding-work slots. Each completion-evidence class behaves as §9.2 specifies: a `drain` backend releases capacity only at its terminal event and is not quarantined by an ordinary interrupt; missing evidence quarantines the backend. |
| AT-12 | Unmanaged backend safety | A hung or uncancellable attached server is never killed automatically; further gateway dispatch stops and status names the limitation. |
| AT-13 | Crash accounting | Gateway crash during generation leaves the backend quarantined on restart until unresolved work is accounted for. |
| AT-14 | Revocation and VM lifetime | Explicit stop/revoke blocks new dispatch immediately; killing the forward process revokes the session; VM stop or crash revokes it within the SSH keepalive bound; activation with a mismatched process identity fails; host TTL cannot be extended by guest or host wall-clock changes. |
| AT-15 | Fail-closed behavior | Missing binary, policy, adapter, model profile, confinement, credential resolution, or backend readiness never causes cloud/raw fallback. |
| AT-16 | Credential and log hygiene | Host canary secrets never appear in guest state, child argv/environment, diagnostics, or logs; synthetic prompt/tool sentinels do not enter gateway logs. |
| AT-17 | Client compatibility | Qualified Codex/Claude versions complete streamed multi-turn tool-use exchanges through their actual required protocol, using the default limits, including concurrent requests and a user interrupt mid-generation. Every field and header those clients send has a field-table entry. Chat-only support is not accepted as evidence. |
| AT-18 | Tool non-execution | Model-generated shell/tool requests are returned as data; host command/file/network canaries remain untouched. |
| AT-19 | Guest isolation regressions | Existing mount, socket relay, peer-network, host-key, and runtime isolation gates still pass on Apple hardware. |
| AT-20 | Host-service limitation | Tests distinguish the new protected inference path from pre-existing reachable host services; reports do not falsely claim total host isolation. |
| AT-21 | Migration and stale state | Legacy raw tunnels cannot coexist with a guarded grant; old managed auth/configuration cannot restore cloud fallback after conversion. |
| AT-22 | Fuzz and stress | HTTP framing, bounded JSON, protocol transforms, SSE parsing, and control messages survive fuzzing; valid concurrent streams remain bounded under hostile traffic. |

Measure gateway-added latency and throughput against direct loopback inference using the same model, prompt, generation length, and concurrency. Publish results and hardware/software versions; this document does not set an unmeasured performance guarantee. Track first-token latency, steady-state streaming, gateway CPU/memory, queue wait, and cancellation-to-backend-stop time separately.

## 16. Delivery sequence and release gates

| Phase | Deliverable | Gate |
|---|---|---|
| 1. Policy core | Configuration types, session authorization, request schemas, model mapping, and shared accounting. | Unit tests and parser fuzzing; denied-request backend canaries remain untouched. |
| 2. Host transport | Shared `iso-proxy` transport libraries, per-session listeners, fixed SSH forwards, control socket, capabilities, transport-process watch, and fail-closed bootstrap. | Root-guest transport, identity, revocation, and lifecycle fault tests. |
| 3. MLX attachment | Same-protocol Chat Completions adapter, input-bound model profile, backend qualification with completion-evidence class, cancellation/quarantine, and crash ledger. | Real attached MLX tests; explicit documentation of unverified backend isolation. |
| 4. Agent adapters | Same-protocol Responses and Anthropic Messages adapters with client field tables, each independently enabled, for backends that serve those protocols natively. Translating adapters follow as separately gated work. | Actual qualified client tool-use fixtures and streaming/error tests under default limits. |
| 5. Distribution | Companion packaging, confinement evidence, migration documentation, and diagnostics. | Hardware isolation regression suite and reviewed security evidence. |

Do not announce secure Codex or Claude local inference before that client's adapter gate passes. Do not announce hard compute isolation before an owned or otherwise externally constrained backend demonstrates it.

## 17. Alternatives and deferred decisions

**Direct SSH tunnel to raw MLX:** Retain as a documented legacy transport option. It does not provide this policy boundary and is rejected under guarded required mode.

**Dedicated vsock service:** Designed in §22 as a relay into a host Unix socket. It is blocked on the relay defects recorded there. Reconsider only as a separate data-plane transport after the HTTP policy and lifecycle are stable. It would need new runtime qualification and isolation-gate treatment, and must not expose the existing privileged control channel. The current contract deliberately excludes host socket relay exposure. See the [trust model][repo-trust].

**VM-network listener plus host firewall:** Deferred. It adds host-network policy and deployment requirements without replacing request authorization. Authentication and API policy would still be required.

**Managed MLX backend:** Specified and implemented in §20. §21 generalizes it to any engine through manifests.

**Outstanding qualification decisions:** Select the first supported backend/model/client version tuples, including an MLX-based server that natively serves Responses or Anthropic Messages; record the client fixtures that set fixture-derived limits and field tables; determine the completion-evidence class of stock `mlx_lm.server` (whether closing its stream stops generation, and whether its stream has a reliable terminal event); confirm the input-bound property and overhead constants for each model tokenizer; confirm the gateway's Seatbelt profile permits the kqueue process watch; and measure the filesystem/network restrictions compatible with their Metal runtime. These are release prerequisites for the corresponding claims, not reasons to weaken the default-deny policy.

## 18. Definition of done

The feature is complete for a declared supported protocol when a root-controlled VM can use its authorized local model through the guarded endpoint, all security invariants and applicable acceptance tests pass, and failures cannot broaden access or reveal host credentials.

The release evidence MUST identify exact revisions and hardware, distinguish gateway enforcement from backend qualification, document host-service reachability and unmanaged-compute limitations, and include an operational revocation/recovery procedure. Implementation claims are limited to the combinations actually tested.

## 19. Implementation status

Where each part is implemented:

- Gateway: `iso-proxy/Sources/IsoInferenceCore` (policy), `IsoInferenceGateway` (NIO transport, control socket, liveness) and the `iso-inference` executable.
- Controller: `Sources/IsoHost/InferenceLifecycle.swift` and `BootstrapInference.swift`.
- Configuration: `Sources/IsoConfiguration/Inference*.swift`.

Evidence was gathered on macOS 27, Apple Silicon, Swift 6.4. "Scripted backend" means `tests/fixtures/inference-backend.py`, or the in-process fake in `IsoInferenceGatewayTests`. The acceptance tests below ran against scripted backends. The managed-backend measurements after the table used a real MLX server.

| ID | Status | Evidence |
|---|---|---|
| AT-01 | Enforced | Controller preflight and `iso inference doctor` probe every non-loopback host address (`InferenceTests.backendBindingChecks`). The VM phase shows the backend is unreachable directly from the guest. Session listeners bind `127.0.0.1:0` only. |
| AT-02 | Enforced | `GatewayTests.deniedRequestsNeverReachTheBackend`: session B's token fails on session A's listener. |
| AT-03 | Enforced | Missing, wrong, inactive, revoked and stale-epoch tokens fail before the backend sees anything (`GatewayTests`, the process test). A new boot gets a new session. |
| AT-04 | Enforced | Pinned SSH options, the forwarding acknowledgment, the sole-listener check, the registration nonce, and the transport identity (`activationChecksTheTransportIdentity`, the process test's non-`ssh` refusal). |
| AT-05, AT-06 | Enforced | Exact routes and queries (`routesAndQueries`). Absolute-form targets, other routes and queries are refused (`deniedRequestsNeverReachTheBackend`). The upstream is a fixed port with no proxy, redirect or decompression. |
| AT-07 | Enforced | Field tables (`hostSelectedAndUnknownFieldsAreRejected`, `responsesRejectsStatefulAndHostedFeatures`), duplicate keys (`rejectsHostileDocuments`); gateway mutants killed. |
| AT-08, AT-22 | Enforced | Strict parser and header table tests. libFuzzer targets `InferenceRequest`, `InferenceStream` and `InferenceControl` ran 5-minute campaigns each. Fuzzing found two relay defects in the stream translators, fixed in 0.3.0; their inputs are kept as regression seeds. |
| AT-09 | Enforced | Output clamp, input bound and byte budget (`outputLimitNormalization`, `inputBoundIsEnforced`, `byteBudgetAndSlots`). |
| AT-10 | Enforced (single root) | Scheduler fairness, queue bounds and the shared active limit (`SchedulerTests`, `secondRequestQueuesBehindTheBackendLimit`). All data roots share one gateway through the fixed per-user state directory. No test runs two data roots at once. |
| AT-11, AT-12 | Enforced | `clientDisconnectDrainsBeforeReleasingTheSlot` and `noEvidenceBackendIsQuarantinedOnCancellation`; the "drain releases on disconnect" mutant is killed. No code path kills a backend. |
| AT-13 | Enforced | `crashJournalQuarantinesAtStartup`. |
| AT-14 | Enforced | Transport exit, session deadline and host revoke (`GatewayTests`, the process test); the VM phase adds forward kill and `iso inference revoke`. |
| AT-15 | Enforced | Preflight refuses a missing binary, an unreachable backend or an unsafe bind before boot. Configuration refuses unqualified protocols. No fallback path exists. Host faults are detected (`swift-host-fault-injection.py`, `inference-*`). |
| AT-16 | Enforced | Provider variables are withheld and refused under `required` (`requiredModeWithholdsEveryProviderCredential`, VM canary). Audit and errors carry no prompt, backend body or capability (`backendErrorsAreSanitized`, the process test). |
| AT-17 | Scripted backend only | The recorded Claude Code 2.1.285 and Codex CLI 0.159.2 requests pass the field tables (`NormalizerTests`). In the VM phase (`./tests/run-integration.sh --only inference`), the guest's own Claude Code and Codex each complete a turn through the gateway against scripted backends (36/36 checks, re-run after the host-hardening changes). Not evidence of tool use against a real model. |
| AT-18 | By construction | The gateway never executes tool calls; tool definitions and results are forwarded as data only. No dedicated canary test. |
| AT-19 | Not re-run | The existing isolation phases are unchanged by this feature and were not re-run with it. |
| AT-20 | Documented | Status reports `backend_isolation_verified: false`. The configuration reference and trust model state that `egress: "none"` still reaches host services. |
| AT-21 | Enforced | No raw tunnel under `required` (`requiredModeNeedsNoProviderProxyAndStartsNone`). Managed Codex `auth.json` is removed; legacy endpoint forms are refused. |

**mlx-lm 0.31.3 qualification** (mlx 0.32.3, `mlx-community/Qwen2.5-0.5B-Instruct-4bit` at `a5339a4`, launched by `launcher.py` under `seatbelt-inference-backend.sb` as the invoking user, since the role account needs the `sudo` step):

- Metal generation succeeds under the profile. Removing any one of `AGXDeviceUserClient`, `IOSurfaceRootUserClient`, `com.apple.MTLCompilerService` or `sysctl-read` makes generation or startup fail. The other GPU rules in the draft profile were unnecessary and were removed.
- Inside the profile, outbound loopback and internet connections, binds to other ports and the wildcard address, writes outside `cache/` and `logs/`, reads of the home directory, and process execution are all denied.
- Without the token the server answers 401; with it, 200.
- Completion evidence is `stream-close`. The gateway always streams upstream (§8.1 step 8). Closing that stream stopped all server CPU activity within 500 ms in three trials. Prefill cannot be interrupted: a stream closed during prefill of a 30,000-token prompt kept the server busy until prefill ended (1.6 s on this model), then stopped. A closed non-streamed request keeps generating to its limit, so non-streamed upstream requests have no evidence. `init` writes `stream_close_drain_ms: 10000`. Raise it to the model's prefill time for `max_input_bytes` on larger models.
- Context overflow is `accept`. A 45,034-token prompt to a 32,768-token model returned 200 with `prompt_tokens: 45034`: it was neither rejected nor truncated. Only the gateway's input bound limits prompt size. `context_overflow` gained the value `accept` for this.

Open before claiming a qualified deployment (§17): the same measurements run by `provision` as the role account. Also open: input-overhead constants for each model tokenizer, tool-use exchanges against a real model, and a concurrent multi-data-root run.

## 20. Host hardening and the managed backend

The attached backend of §9.2 and §10 remains supported. This section adds controls that shrink its trusted computing base. Each control is optional, verified on every start, and reported separately in status. None of them weakens §6.

### 20.1 Dedicated backend account (`run_as`)

`inference.backends.<name>.run_as` names a macOS account. Before registration the controller verifies all of the following:

1. The account exists, and its UID is not the invoking user's.
2. No process of the invoking user listens on the backend port (`lsof` lists only the caller's own processes). A listener that accepts connections but belongs to nobody the caller can see belongs to another account.
3. For a managed backend (§20.2), the launchd job `system/com.iso.inference.<name>` reports a running PID owned by `run_as`.

Failure is `INFERENCE_BACKEND_UNSAFE_OWNER`, before any VM work. A backend running as the invoking user can read that user's keys, Keychain and iso state; `run_as` removes that exposure. Loopback is still shared across accounts, which is why §20.3 authenticates the backend.

### 20.2 Managed backend (`iso inference provision`)

`inference.backends.<name>.managed` describes a backend iso provisions and owns:

| Field | Meaning |
|---|---|
| `server` | `"mlx-lm"`: the only supported server. |
| `python` | Absolute path to an interpreter that imports `mlx_lm`. Mutually exclusive with `install`. |
| `install` | Opt-in: a pinned `mlx-lm` version installed into a root-owned virtual environment during provisioning. This is network access. |
| `model` | An absolute local directory copied in at provisioning, or `{ "repo": ..., "revision": "<40-hex commit>" }` to fetch (opt-in network access, pinned to a commit). |
| `memory_limit` | GPU and wired memory ceiling passed to MLX. |
| `confinement` | `"seatbelt"` (default) or `"none"`. |

A managed backend implies `run_as: "_isoinference"`. Its credential is implicit (§20.3), so it takes no `credential` field.

Provisioning is the only privileged step. `iso inference provision <name>` runs as the user: it validates the configuration, generates the backend token and stores it in the login Keychain (service `iso-inference-backend`, account `<name>`). It then runs `sudo <iso> inference provision-system` with a plan on stdin. The root step, using argv only, never a shell:

1. Creates the hidden role account `_isoinference`, a UID in 400–499 with shell `/usr/bin/false` and home `/var/empty`, if it is missing.
2. Creates `/Library/Application Support/iso-inference/backends/<name>/`, owned by root and `0755`. Inside it: `model/` (root-owned, read-only to the role), `cache/` and `logs/` (owned by the role, `0700`), `token` (`root:_isoinference`, `0640`), `launcher.py` and `profile.sb` (root, `0644`), and `venv/` when `install` is used (root-owned).
3. Copies or fetches the model into `model/`. A fetch runs as the role account, offline apart from the pinned download.
4. Writes `/Library/LaunchDaemons/com.iso.inference.<name>.plist`, then bootstraps it. The job runs with `UserName` `_isoinference`, `KeepAlive`, `ProcessType Background`, a positive `Nice`, `LowPriorityIO`, and the environment `HF_HUB_OFFLINE=1`, `HOME=<cache>`. With confinement it runs `sandbox-exec -f profile.sb`. The job binds `127.0.0.1:<port>` only.

`iso inference deprovision <name>` reverses these steps (`sudo`). It removes the role account when no managed backend remains. `iso inference restart-backend <name>` runs `sudo launchctl kickstart -k`, and `iso inference requalify <name> --restart` combines that with requalification. A managed backend is killable by iso, so a quarantine after a hung generation can be cleared with evidence: the job was restarted.

### 20.3 Backend authentication

The launcher (`launcher.py`, from iso) starts `mlx_lm.server` with a handler that requires `Authorization: Bearer <token>`, compared in constant time. It rejects any `Origin` header and serves no CORS. It sets `mx.set_memory_limit` and clamps `mx.set_wired_limit` to `memory_limit`. It passes no adapter, draft-model or remote-code option. The gateway sends the Keychain token as the backend credential. Other local processes, other accounts and any path that reaches loopback therefore cannot use the backend without the gateway. The launcher is pinned to the `mlx-lm` versions it was qualified with (currently 0.31.x). Any other version refuses to start.

### 20.4 Backend confinement

`profile.sb` (deny default) allows:

- reads of the system libraries, the interpreter's `sys.prefix` and `sys.base_prefix`, the backend directory (`model/`, `launcher.py`, `token`) and `cache/`;
- writes to `cache/` and `logs/` only;
- network bind and inbound on `localhost:<port>`, and no outbound connections;
- Metal: the `AGXDeviceUserClient` and `IOSurfaceRootUserClient` IOKit user clients and the `com.apple.MTLCompilerService` mach service, each shown necessary by qualification (§19);
- execution of the interpreter only, by its configured path or the path it resolves to (a venv's `python` is a symbolic link).

A configured `python` must be root-owned and not group- or world-writable, down to its executable, `sys.prefix` and `sys.base_prefix`. Otherwise the invoking user could change code that the role account runs. `install` builds a root-owned virtual environment instead.

Provisioning qualifies the profile: the job must answer an authenticated health request within a deadline. A crash-looping job fails provisioning, with no fallback to `"none"`. Status reports `backend_confined` from the kernel (`sandbox_check` on the job's PID), not from configuration.

### 20.5 Gateway confinement per port

The gateway profile is generated at launch. It allows outbound connections only to `localhost:<p>` for each backend port in the configuration, and reads only of the system libraries, the binary and `STATE_DIR`. The gateway refuses a registration naming any other port (`INFERENCE_BACKEND_UNAVAILABLE`). The controller then restarts an idle gateway with the union of ports, or asks the user to stop an active one. The jail self-test also requires a denied loopback port.

### 20.6 Hardened defaults (`iso inference init`)

`iso inference init (--python P | --install V) (--model DIR | --model-repo R --model-revision C) [--backend N] [--port P] [--memory-limit B]` writes a configuration with the following, then prints what it changed:

- `inference.mode = "required"` and `security.preset = "offline"` (so `egress: "none"`);
- `limits.session_ttl = "8h"`;
- the `mlx-lm-0.31` qualification profile with the §19 values;
- a managed backend with confinement on and `max_active_requests: 1`;
- a `local-chat` service (`openai-chat`, 32768-token context, 2048 default and 4096 maximum output tokens). mlx-lm serves Chat Completions only, so Claude Code and Codex need a backend that speaks their own protocol.

Existing values are never overwritten silently: a conflicting key fails with a list of the conflicts unless `--force` is given.

### 20.7 Host listener audit

`iso inference doctor` lists the invoking user's TCP listeners bound to wildcard or non-loopback addresses (`lsof -iTCP -sTCP:LISTEN`), because guests can reach them regardless of `egress`. It warns, and names `sudo lsof` for other accounts' listeners, which an unprivileged process cannot see (`netstat` does not list TCP sockets on macOS 27). It changes no binding and installs no firewall rule.

### 20.8 Status

`status` and `doctor` add these fields:

- `backend_run_as_verified`
- `backend_authenticated` (an unauthenticated probe is refused)
- `backend_confined` (kernel-reported)
- `backend_managed`
- `gateway_egress_ports`

`backend_isolation_verified` is true only when run-as, authentication and confinement are all verified.

### 20.9 Tests

- Unit tests: plan and plist generation, profile rendering, launcher argument and authentication behavior (a fake `mlx_lm` module), owner verification with fake tools, the `netstat` parser, and per-port gateway enforcement.
- The root step runs against fake `dscl`, `launchctl` and `chown` tools under a prefix, so it is testable without privilege.
- The process test checks that a loopback port absent from the list is denied to the gateway.
- Qualification with real MLX (a small model under the backend profile) is recorded in §19 when run on hardware.

## 21. Engine-neutral backends

**Status: design, not implemented.** §20 hard-codes one engine: the managed backend is an mlx-lm server, with an mlx-lm launcher, an mlx-lm Seatbelt profile and hand-entered qualification values. This section generalizes the managed path. An inference engine becomes data: an owner-supplied manifest. iso keeps every security-relevant mechanism, and qualification becomes something iso measures rather than something the owner types. Adding an engine then needs no iso change, except for the cases listed in §21.13.

### 21.1 Goals and non-goals

Goals:

- run any loopback HTTP engine that natively serves one or more of the supported protocols (§8.1), including ds4, mlx-lm and llama.cpp-style servers, managed or attached, with the §20 hardening;
- let one engine process serve several protocols, so Claude Code and Codex can share one loaded model;
- derive the qualification profile (§10, §17) from measurements tied to the exact engine, executable and model.

Non-goals:

- translating between protocols. This remains deferred (§17).
- executable plugins, owner-written Seatbelt rules, or engine code running inside iso or the gateway;
- downloading engines. Artifacts are local files pinned by hash (§21.3). Downloads stay a separate stop-and-confirm decision.

### 21.2 Evidence from a second engine

ds4 ([antirez/ds4][ds4], commit `8db1d1d`), was run on macOS 27 on an Apple M-series machine with 128 GiB of memory. The model was `DeepSeek-V4-Flash-IQ2XXS…-0731.gguf` (86.7 GB, 81.6 GiB resident), with `--ctx 32768`. The recorded Claude Code and Codex requests were replayed through the real confined gateway:

| Finding | Consequence for this design |
|---|---|
| It serves `/v1/messages`, `/v1/responses`, `/v1/chat/completions` and `/v1/completions`, with structured tool calls on Messages (`tool_use`) and Responses (`function_call`). It has no `count_tokens`. | Claude Code and Codex work through the gateway unchanged: 200, and well-formed event sequences for 4 of the 5 recorded requests. |
| The gateway refuses a second profile on the same port (`INFERENCE_MODEL_UNQUALIFIED`), and a profile has one protocol. | One engine process cannot serve Claude and Codex at once. Two processes do not fit in memory. §21.8 fixes this. |
| It has no authentication. A browser-style `text/plain` POST carrying an `Origin` header is served even without `--cors`. | Any local process, or any web page, can drive generation. §21.6 fixes this. |
| The 25k-token recorded Claude request hit the fixed 120 s first-output deadline (504). Prefill runs at about 360 tokens/s. | Deadlines must be per profile, and measured (§21.10). |
| After a close, generation stops within a few tokens, whether streamed or not. During prefill it stops at the end of the current chunk (4096 tokens, about 12 s). | `stream-close` evidence, with a drain window that covers one prefill chunk. The harness measures this (§21.9). |
| An over-long prompt gets an immediate 400 `context_length_exceeded`. | `context_overflow: reject`, which the harness detects. |
| `--trace FILE` writes prompts and outputs. The disk KV cache stores prompt text. `--host` widens the bind. | The manifest forbids these flags (§21.4). Cache writes stay in the role-owned `cache/` directory. |

### 21.3 Engine manifest

Engines are declared under `inference.engines.<name>` in the configuration. They are part of the one validated snapshot each command loads. iso ships built-in manifests (the first is `mlx-lm-0.31`, which replaces the hard-coded §20 path). An owner manifest may not reuse a built-in name.

```jsonc
"inference": {
  "engines": {
    "ds4": {
      "protocols": ["anthropic-messages", "openai-responses", "openai-chat"],
      "executable": { "path": "/opt/ds4/ds4-server", "sha256": "…64 hex…" },
      "files": [{ "path": "/opt/ds4/metal", "sha256": "…tree digest…" }],
      "model": { "file": "/models/DeepSeek-V4-Flash.gguf", "sha256": "…", "placement": "copy" },
      "params": { "ctx": { "type": "integer", "min": 1024, "max": 1048576, "default": 32768 } },
      "launch": ["{executable}", "-m", "{model}", "--ctx", "{ctx}",
                 "--host", "127.0.0.1", "--port", "{engine_port}", "--kv-disk-dir", "{cache_dir}"],
      "forbid_args": ["--cors", "--trace"],
      "health": { "path": "/v1/models", "status": 200 },
      "auth": "none",
      "model_ids": ["deepseek-v4-flash"],
      "capabilities": ["metal", "write-cache"],
      "memory": { "resident_gib": 82 }
    }
  },
  "backends": {
    "ds4-main": {
      "base_url": "http://127.0.0.1:18180",
      "engine": "ds4",
      "managed": { "params": { "ctx": 65536 } }
    }
  }
}
```

| Field | Meaning |
|---|---|
| `protocols` | The protocols (§8.1) the engine serves natively. Every protocol a backend exposes must be qualified (§21.9). |
| `executable` | An absolute path and SHA-256. Managed provisioning copies it into the root-owned backend directory, and the job runs only that copy. |
| `interpreter` | Instead of `executable`, for script engines: `{ "python": PATH }` or `{ "install": [pip requirement lines with --hash] }`, launched with the `interpreter` capability (§21.7). |
| `files` | Support files or directories the engine reads at run time, pinned by digest and copied the same way. |
| `model` | `file` or `directory`, with a digest. `placement` is `copy` (the default) or `adopt`, which renames the source into the root-owned tree when it is on the same volume. That avoids a second copy of a model of 100 GB or more, and hands the file to root. |
| `params` | Typed, bounded parameters that the backend's `managed.params` may set. They are the only owner values that reach argv. |
| `launch` | An argv template. Elements are literals or whole placeholders (§21.4). |
| `forbid_args` | Literal arguments that may not appear in the rendered argv, whatever their source. |
| `health` | A GET path and expected status, used for readiness. It is sent with the token when `auth` is native. |
| `auth` | `native`: the engine enforces a bearer token read from the argument that `{token_file}` supplies. `none`: iso's auth front is required (§21.6). |
| `model_ids` | The upstream model ids a service may name. |
| `capabilities` | Confinement grants from iso's vocabulary (§21.7). |
| `memory` | Declared resident size. Provisioning refuses a host without enough memory left over, and status reports it. |

The existing `managed` form of §20.2 (`server: "mlx-lm"`, `python`/`install`, `model`) remains accepted. It is an alias for `engine: "mlx-lm-0.31"`.

### 21.4 Manifest trust rules

A manifest is owner-trusted host configuration, but iso treats it as data and enforces these rules:

- **argv.** Each `launch` element is either a literal or exactly one placeholder. There is no substitution inside strings, no shell and no environment expansion. The placeholders that iso sets are `{executable}`, `{interpreter}`, `{launcher}`, `{model}`, `{engine_port}`, `{cache_dir}`, `{log_dir}` and `{token_file}`. Declared `params` are the only others. Their values are checked against their type and bounds, and must not start with `-`.
- **Forbidden arguments.** The rendered argv must not contain any `forbid_args` element. iso adds a built-in deny list for bind and CORS flags that it knows for its built-in engines.
- **Binding.** The engine binds `127.0.0.1:{engine_port}`, a port iso allocates. The §10 bind checks and the §20.1 owner checks apply to that port.
- **Environment.** The job gets a fixed environment: `HOME` and `TMPDIR` under `cache/`, a minimal `PATH`, and offline flags for known model hubs. Manifests cannot add variables.
- **Artifacts.** The executable, files and model are verified against their digests when provisioned. Copies are root-owned and read-only to the role account. At every launch, iso re-checks the size, inode and modification time. `iso inference verify <backend>` re-hashes everything in full.
- **Identity.** A manifest's identity is the SHA-256 of its canonical JSON form. A qualification record (§21.9) is bound to it.

### 21.5 Generic launcher

§20.2 provisioning applies unchanged: the role account, the root-owned backend directory, the Keychain token, the LaunchDaemon and the single `sudo` step that takes a stdin plan. The engine-specific parts come from the manifest:

- **ProgramArguments.** `sandbox-exec` runs the profile composed from `capabilities` (§21.7), then the rendered `launch` argv.
- **Readiness.** `health` must answer within `health_deadline`, 300 s by default and adjustable per manifest up to 1800 s for large models. With `auth: none`, readiness is checked on the engine port and then through the front.
- **The plan.** The stdin plan carries the manifest, its digest, the resolved `params`, the allocated ports and the artifact digests. The root step re-validates all of it with the same decoder the configuration uses. It never reads the user's configuration.

### 21.6 Auth front

An engine with `auth: "none"` is served through `iso-inference front`, a mode of the `iso-inference` binary that reuses its HTTP transport. It runs as the role account in a second LaunchDaemon, under its own profile. Inbound is allowed on the backend's public port, outbound on the engine port only. It has no filesystem writes except its log. For each request, the front:

- requires `Authorization: Bearer <token>` (from `token`, compared in constant time);
- refuses any `Origin` header, `OPTIONS`, and any `POST` whose content type is not `application/json`, which closes the browser simple-request path;
- forwards method, path and body unchanged to `127.0.0.1:{engine_port}`, and streams the response back without buffering it;
- enforces header and body bounds, not policy. Policy stays in the gateway.

**Residual risk:** another local process can still find and connect to the engine port directly, because macOS loopback has no per-user isolation. Status therefore distinguishes `backend_authenticated: native | front | none`. `front` counts as authenticated for `backend_isolation_verified` only when the owner sets `accept_front_auth: true` on the backend. Otherwise doctor warns. Engines that add native authentication, or a Unix-socket listener (§21.13), close this gap.

### 21.7 Confinement capabilities

The backend profile is composed from a fixed base and named capabilities. Each capability is an SBPL fragment that ships with iso and is qualified on hardware:

| Capability | Grants | Qualified by |
|---|---|---|
| (base, always) | Reads of system libraries, the executable and `files` copies, the model, and the backend directory. Bind and inbound on `{engine_port}` only. No outbound network. Execution of the executable only. `sysctl-read`. `process-info` on itself. | §19, mlx-lm |
| `metal` | The `AGXDeviceUserClient` and `IOSurfaceRootUserClient` user clients, and `com.apple.MTLCompilerService`. | §19, mlx-lm 0.31.3 |
| `interpreter` | Reads of the interpreter's `sys.prefix` and `sys.base_prefix`, and execution of its resolved executable. | §19 |
| `write-cache` | Writes to `cache/` (disk KV caches, compiled kernels). | Per engine, by the harness |
| `write-logs` | Writes to `logs/`. Always granted. | — |

A manifest naming an unknown capability is refused (`INFERENCE_ENGINE_INVALID`). The harness (§21.9) runs the engine under exactly this profile. An engine that needs more than the vocabulary allows needs a new capability, which is an iso change (§21.13).

### 21.8 Multi-protocol backends

- **Profiles.** A qualification profile's `protocol` becomes `protocols`, an array. The old single `protocol` key is still accepted as a one-element array.
- **Backends.** A backend's `protocol` likewise becomes `protocols`. It must equal the profile's set, and must be a subset of the engine's `protocols`.
- **Gateway identity.** A backend is still identified by its port. Registration conflicts only when the profile's full content differs, so services with different APIs on the same port share the backend's concurrency limit and quarantine state.
- **Services.** Each API in `frontend_apis` must be served natively by the backend. Adapters remain same-protocol only (§8.1).
- **Wire format.** The control protocol grant carries `profile.protocols`, and the gateway selects the adapter per request from the granted API.

### 21.9 Qualification harness (`iso inference qualify <backend>`)

The harness runs on the host as the user. It starts a private, confined gateway with an ephemeral state directory, pointed at the backend exactly as a session would use it, and measures the following:

| Probe | Method | Derives |
|---|---|---|
| Protocols | Replays each recorded client fixture set for every declared protocol through the gateway, then a tool-call round trip (a declared tool, then its result). A pass needs a 2xx response, a well-formed event sequence, and a structured tool call. | Which `protocols` are qualified. |
| Stop after close | With the backend limited to one active request, it closes a streamed request during decode, a non-streamed request during decode, and a streamed request during prefill of the largest allowed input. It then sends a one-token probe and measures that probe's time to first byte against an idle baseline. | `completion_evidence`: `stream-close` when every close stops within the bound, otherwise `drain`, otherwise `none`. `stream_close_drain_ms` is the worst stop latency times 1.5. |
| Overflow | Sends a prompt larger than the declared context. | `context_overflow`: `reject` for a 4xx context error, `truncate` for 2xx with `prompt_tokens` at or below the context, `accept` for 2xx with `prompt_tokens` above it. |
| Input bound | Compares `usage` input tokens with the byte bound over the fixtures and synthetic prompts. | `input_overhead` constants, and whether the byte bound holds (§9). |
| Latency | Time to first output at the largest allowed input, and decode rate. | `first_output_seconds` (twice the measurement, rounded up) and `generation_seconds` (§21.10). |
| Logging | Scans `logs/` for canary prompt text after the run. | Whether the engine logs prompts (reported, not enforced). |

The harness writes a qualification record: `qualification.json`, in the backend directory for managed backends (written through the root step), or `<state>/qualifications/<backend>.json` (`0600`) for attached ones. It contains:

- the manifest digest, executable and model digests, resolved `params`, iso version, fixture-set versions and host hardware;
- each derived value, with the raw measurements behind it;
- the time of the run.

**Use and invalidation:**

- A backend without `qualification_profile` uses the record's profile.
- A record is stale when any digest, the iso version's fixture set, or the `params` differ. A stale or missing record makes the backend `INFERENCE_MODEL_UNQUALIFIED` at session start, with the reason.
- A hand-written `qualification_profile` still overrides the record, and status marks it `owner_asserted`.

### 21.10 Per-profile deadlines

`SessionLimits.firstOutputSeconds` (120) and `generationSeconds` (300) become profile fields `first_output_seconds` (1–3600) and `generation_seconds` (1–86400). Their defaults are unchanged. The gateway arms each request's timers from its grant's profile. A running gateway still only tightens shared global limits (§11). Deadlines are per backend, so they never loosen another backend's.

### 21.11 CLI, status and errors

- `iso inference engines [--json]`: the declared and built-in engines, with digests, protocols and capabilities.
- `iso inference qualify <backend> [--protocol P]... [--fixtures DIR]`: runs §21.9 and prints the derived profile and the record path.
- `iso inference verify <backend>`: re-hashes the artifacts against the manifest and the record.
- `iso inference init --engine NAME`: writes a backend and services for any engine, one service per protocol, with the hardened defaults of §20.6.
- `provision`, `deprovision` and `restart-backend` work for any managed engine. `provision` refuses to finish until `qualify` has passed, unless `--skip-qualify` is given (for example when qualification will be run later on other hardware).

Status adds `backend_engine`, `engine_digest`, `backend_authenticated` (`native | front | none`), and `qualification` (`current | stale | missing | owner_asserted`, with `measured_at`).

New stable error codes:

- `INFERENCE_ENGINE_INVALID`: a manifest failed decoding, template or capability rules.
- `INFERENCE_ENGINE_MISMATCH`: an artifact digest or launch check failed.

A stale qualification reuses `INFERENCE_MODEL_UNQUALIFIED`.

### 21.12 Trust-model changes

- The engine stays inside the trusted computing base for the prompts it receives, as in §20.
- A manifest is owner configuration, with the same trust as the rest of `config.jsonc`. It can choose which program runs as the role account, but cannot widen that account's confinement beyond the shipped vocabulary.
- The harness sends synthetic prompts and recorded fixture bodies only. It never sends guest data.
- The front is a new listener: loopback only, on a configured backend port, and bearer-authenticated. It falls under the stop-and-confirm rule for new network listeners, and is listed in `docs/trust-model.md`.

### 21.13 What still requires an iso change

- **A new confinement capability,** for example CUDA or ROCm on a future host platform, a new Metal service, or network access for engines that shard across machines.
- **A new client protocol,** or a translating adapter (§17).
- **A new listener transport:** Unix-domain-socket engines, which would remove the front's residual risk. This needs a gateway upstream type and a placeholder for the socket path.
- **New fixture sets** when a supported client version changes its requests (§8.5).

### 21.14 Acceptance tests

| ID | Requirement |
|---|---|
| AT-23 | A manifest with a string-interpolated placeholder, an unknown placeholder, a parameter value starting with `-`, a forbidden argument or an unknown capability is refused. So is a rendered argv containing a literal from the deny list. |
| AT-24 | A changed executable, file or model digest blocks launch with `INFERENCE_ENGINE_MISMATCH`, and makes the qualification record stale. |
| AT-25 | One engine port serves `anthropic-messages` and `openai-responses` services in concurrent sessions, sharing the backend's limit and quarantine. |
| AT-26 | With `auth: none`, the engine is reachable only through the front for clients that obey the protocol. The front refuses a missing or wrong token, `Origin`, `OPTIONS` and non-JSON POSTs. Status reports `front`. |
| AT-27 | The harness derives the ds4 and mlx-lm values recorded in §19 and §21.2 (completion evidence, overflow class, a drain window covering prefill) against the real engines, and against scripted engines with known behavior. |
| AT-28 | A stale or missing record fails session start with `INFERENCE_MODEL_UNQUALIFIED`. A record for another host or iso version is stale. |
| AT-29 | Per-profile deadlines: a backend with `first_output_seconds: 600` serves a 25k-token Claude Code request that fails at the default 120 s. |

### 21.15 Delivery sequence

Each step is its own change, with refactors before behavior:

1. **Multi-protocol profiles and per-profile deadlines** (§21.8, §21.10). This covers configuration, the control protocol and the gateway. It already lets an attached ds4 serve Claude and Codex at once.
2. **The manifest decoder, the capability vocabulary and the generic launcher.** `managed.server: "mlx-lm"` is re-expressed as the built-in `mlx-lm-0.31` manifest, with no behavior change.
3. **The auth front.**
4. **The qualification harness and records,** then removing the need for hand-written profiles.
5. **ds4 as the first owner manifest:** documentation example and hardware evidence in §19.

[ds4]: https://github.com/antirez/ds4

## 22. vsock session transport

**Status: implemented, with the relay fixes vendored (§22.3).** Before this section, the guest reached its gateway session through a pinned `ssh -R` forward to a per-session listener on host loopback (§5, §12). The forward is replaced by a vsock relay into a per-instance host Unix socket, and the SSH forward path for inference is removed. The trust-model change in §22.6 was approved. This branch does not merge to `main` until upstream releases the vendored fixes.

### 22.1 Why

| | `ssh -R` (current) | vsock → host Unix socket |
|---|---|---|
| Host exposure | One TCP listener on loopback per session. Any local process can connect; only the capability stops it. | No host TCP. A `0600` socket in a `0700` per-user directory, reachable only through the instance VM's vsock device. |
| Session identity | Built by iso: sole-listener check, `ssh` PID and start time, kqueue watch, forward identity. | Given by the VM: a connection can only come from that instance. The capability remains as defense in depth. |
| Revocation and lifecycle | Kill the forward, and handle stale forwards, `sshd` restarts and a guest killing its end. | The relay lives and dies with the VM. Revocation is capability-only. |
| Dependencies | Guest `sshd`, host `ssh`, pinned host keys. | The guest agent's relay, plus a guest-side bridge (§22.4). |

### 22.2 Spike

This was run on October 1, 2026, on macOS 27, Apple Silicon. iso-sandbox protocol 4 was built on containerization 0.45.0 and runs VMs with `VZVirtualMachineManager` and `LinuxContainer` (the guest agent is vminitd from the pinned `vminit` image). A throwaway build set `LinuxContainer.Configuration.sockets` to one `.into` relay, pairing a host Unix socket with a guest path. It used the integration test image, a private runtime root and a host HTTP server on the Unix socket.

| Check | Result |
|---|---|
| Guest root reaches the host server through the relay | ✅ A request round trip works. |
| Guest socket path | ❌ When placed under `/run`, it is hidden: the relay mounts it at container start, and systemd then mounts a fresh tmpfs over `/run`. A path outside `/run` (`/var/lib/iso-inference/gateway.sock`) works. |
| Guest socket permissions | Created as `0000 root:root`. A non-root guest user is refused. The relay's `permissions` option needs `SystemPackage`, which iso-sandbox does not import yet. The bridge below makes this moot. |
| Throughput | 20,000 SSE events in about 28 ms. An 8 MiB request body in 23 ms. 100 sequential requests in 262 ms, including `curl` start-up. |
| Guest TCP bridge | ✅ A systemd socket unit on `127.0.0.1:10788` with `systemd-socket-proxyd` (present in the guest image) reaches the relay for root and non-root users, and streams. `socat` is absent from iso's guest image. |
| Host socket briefly absent | ❌ One guest connection while the host socket was missing (as when the gateway is not running) **permanently killed the relay** for the VM's lifetime. Later connections were reset, even though the host server answered directly. |
| 400 concurrent guest connections | ❌ The owner process went from 35 to 383 open descriptors, above its soft limit of 256, and stayed at 381 after every client exited. The relay died again. The owner's control channel (`exec`, `stop`) still answered. |
| Public API | `LinuxContainer` exposes `dialVsock` (host to guest) but not a host-side `listen`. iso-sandbox therefore cannot run its own relay without a containerization change. |

### 22.3 Relay defects that block adoption

In containerization 0.45.0, `UnixSocketRelay.setupHostVsockListener` runs one accept loop. `handleGuestVsockConn` creates and connects the host socket outside its `do/catch`, so a failed connect ends the loop, and with it the relay. The host socket is created with `closeOnDeinit: false`, and the error path closes neither side, so descriptors leak. Nothing limits concurrent connections. A guest can therefore disable the relay permanently, and exhaust the descriptors of the process that owns the VM.

Adoption requires a relay that satisfies:

- **R1.** A failed host connect closes that guest connection only. The listener keeps accepting.
- **R2.** A cap on concurrent relayed connections per VM (32). Excess connections are closed immediately.
- **R3.** Both descriptors are closed on every exit path. The owner's descriptor count returns to baseline after load.
- **R4.** Bytes only: no parsing and no buffering beyond a fixed chunk, with back-pressure between the two sides.
- **R5.** The relay ends with the VM, and runs in no other process.

It can be satisfied in either of two ways:

- **Upstream fix (preferred):** a containerization change for R1–R3, contributed and pinned when released.
- **iso-owned relay:** containerization exposes the VM's host-side `listen(port)` (or the instance) from `LinuxContainer`, and iso-sandbox implements R1–R5 itself.

**Status of the fix.** Upstream `main` at `f24df2a` (September 30, 2026) already contains R1 and R3. Per-connection errors are caught and the loop continues, and failed setups close both sides. R2 is still missing. A patch adding `UnixSocketConfiguration.maxConnections` was drafted against that commit ("Limit concurrent connections in UnixSocketRelay"). It comes with unit tests for both directions, which fail with the limit disabled, and was checked on hardware: iso-sandbox built on the patched checkout with `maxConnections: 32`.

- With the host socket absent, guest connections failed immediately, and the relay recovered when the socket returned (R1).
- With 400 concurrent guest connections, the owner peaked at 99 descriptors and returned to its baseline of 35 (R2, R3).
- The relay and the owner's control channel kept working.

**Vendored.** `iso-sandbox/Vendor/containerization` is 0.45.0 plus the host-side relay change from `8b8cd7e` and this patch (`iso-sandbox/Vendor/patches/`), with tests trimmed to `UnixSocketRelayTests`. The guest agent stays the pinned `vminit:0.45.0` image, since both fixes are host-only. `VENDORED.md` records the provenance, and the removal step: point at the upstream release that contains both fixes, bump the `vminit` pin, and re-run the VM suite.

### 22.4 Design

**Runtime (iso-sandbox, protocol 5)**

- **Record.** `SandboxRecord.inferenceRelay`, a boolean, defaults to false. It is set by `create --inference-relay`, and by `start --inference-relay on|off` for each boot. `start` records it under the runtime's mutation guard after clearing a crashed owner's state. The record holds no path.
- **Host path.** The runtime derives it the way it derives the owner's control socket: `<per-user temp>/iso-sbx/inference/<hash of the sandbox directory>.sock`. The owner creates `iso-sbx/inference` as a `0700` directory owned by the user, and verifies it like the control-socket directory. The guest path is the constant `/var/lib/iso-inference/gateway.sock`, placed outside systemd's `/run` tmpfs (§22.2).
- **Relay.** The owner configures exactly one `.into` relay, with `maxConnections: 32`.
- **Reporting.** `inspect` reports it as `inferenceRelay: {host, guest, maxConnections}`, alongside `socketRelays`.

**Gateway**

- `iso-inference` is launched with `--relay-dir <per-user temp>/iso-sbx/inference`, and its Seatbelt profile allows creating, binding and accepting Unix sockets under that directory only (`RELAY_DIR`).
- A registration names its socket (`socket`: 1–16 lowercase hex characters, the runtime's hash, plus `.sock`). The gateway binds `RELAY_DIR/<socket>` (`0600`), replacing any stale file. One session per instance means one socket per instance.
- Session listeners on TCP are removed. The capability remains required on every request.
- Activation binds the session to the instance's sandbox owner process. The PID and start time come from the registration's boot identity, and the command must be `iso-sandbox`. The owner's exit revokes the session through the existing kqueue watch.

**Host (iso)**

- `InferenceBoot` carries the relay host path read from `inspect`.
- The controller refuses a path whose directory is not `<per-user temp>/iso-sbx/inference`, or whose name is not a 1–16 hex digit hash. It registers with that name and activates with the owner identity. No forward is created, and no loopback listener check is needed.
- The session state records the owner's PID and start time. The per-command session memo and `current()` check that process instead of a forward.
- iso creates the sandbox with the relay when `inference.mode == "required"`, and passes `start --inference-relay on|off` when the mode has changed since. Unchanged starts keep their exact runtime arguments.
- `IsolationGate` accepts zero relays, or exactly the inference relay with the derived host path, the constant guest path and a cap of 32. The relay is accepted only when the configuration requires inference. A running boot whose relay does not match the configuration (the mode changed while it ran) is refused with a restart hint.
- The bridge is installed when a session is created. If the install fails, the session is revoked, so the next command registers again and retries the install.
- The control protocol is version 2: registrations name a `socket` instead of receiving a port.

**Guest (bootstrap)**

- iso installs `iso-inference.socket` (`ListenStream=127.0.0.1:10788`) and `iso-inference.service` (`systemd-socket-proxyd /var/lib/iso-inference/gateway.sock`). It enables the socket on each agent bootstrap.
- The guest port is fixed at 10788 for every instance, since each VM has one. Agents use `http://127.0.0.1:10788` as before.

**Removed**

- For inference: the `ssh -R` forward, its PID file and memo identity, the sole-listener check, per-index guest ports, and TCP session listeners.
- SSH remains for shells, agent bootstrap and the legacy raw tunnels of `mode: off`.

### 22.5 Security properties

- No inference listener exists on host TCP. Local processes need write access to the user's `0700` state directory, which is owner-only.
- The guest cannot choose the host path. The runtime pins it to the per-user inference directory and verifies it, and iso's `IsolationGate` verifies it again.
- Guest-driven load is bounded by R2 in the owner process, and by the gateway's per-session connection limit (§9).
- The capability remains required. A bug in the relay path cannot hand one instance's session to another, because each instance has its own socket.

### 22.6 Trust-model and `IsolationGate` changes (require sign-off)

- The runtime contract changes from "no field for a socket relay" to "at most one socket relay, into the fixed guest path, from the instance's own inference socket".
- `IsolationGate.Ready` requires either zero relays, or exactly that one: guest path equal to the constant, host path equal to the path iso computed for the instance.
- `docs/trust-model.md` records the relay as a host exposure that is bounded (R1–R5) and authenticated (the capability).
- The VM isolation suite is re-run with the relay present. The runtime's protocol version is bumped, and iso requires the new version before enabling the transport.

### 22.7 Acceptance tests

| ID | Requirement |
|---|---|
| AT-30 | A guest reaches its session through the bridge. No host TCP listener exists for inference sessions (`lsof -iTCP` shows none owned by the gateway). |
| AT-31 | With the gateway stopped, a guest connection fails. After the gateway restarts, the next connection succeeds (R1). |
| AT-32 | 400 concurrent guest connections: at most 32 are relayed. The owner's descriptor count returns to within 5 of baseline afterwards. The relay and the owner's control channel keep working (R2, R3). |
| AT-33 | A record whose relay host path lies outside the instance's inference directory, is a symlink, or names another instance's socket is refused by the runtime and by `IsolationGate`. |
| AT-34 | Instance A cannot reach instance B's session through the relay, even with B's capability, because each instance has its own socket. |
| AT-35 | Stopping the VM revokes the session, bound to the owner process. SSH remains usable for shells, and no `ssh -R` is created for inference. |

### 22.8 Delivery

1. The relay fix (§22.3), upstream or through an exposed `listen`. Then pin the containerization release.
2. iso-sandbox: the record field, validation, the owner relay, `inspect`, and a protocol bump.
3. iso: Unix-socket session listeners in the gateway, the controller's transport identity bound to the owner process, the guest bridge units, `IsolationGate`, the trust-model update, and the integration phase.
4. Remove the `ssh -R` inference path.

Steps 1 (vendored), 2, 3 and 4 are implemented on this branch. The branch merges once the upstream release lands.

## Source references

Repository references are pinned to the design-baseline commit. The MLX branch link is mutable; the blob reference identifies the source snapshot used in the preceding assessment. Revalidate relevant behavior when adopting a newer dependency or repository revision.

- [Model routing and local endpoint planning][repo-model]
- [Proxy and reverse-tunnel lifecycle][repo-lifecycle]
- [Configuration reference, local models, egress, and presets][repo-config]
- [Credential proxy behavior and limitations][repo-proxy]
- [Repository trust model and runtime isolation contract][repo-trust]
- [Agent model-mode commands][repo-agent]
- [MLX server source][mlx-server] and [reviewed snapshot blob][mlx-blob]

[repo-model]: https://github.com/chr33s/iso/blob/1784c5648f65d8d7bc1c901635cc33f11f80382e/Sources/IsoHost/ModelState.swift
[repo-lifecycle]: https://github.com/chr33s/iso/blob/1784c5648f65d8d7bc1c901635cc33f11f80382e/Sources/IsoHost/ProxyLifecycle.swift
[repo-config]: https://github.com/chr33s/iso/blob/1784c5648f65d8d7bc1c901635cc33f11f80382e/docs/configuration.md
[repo-proxy]: https://github.com/chr33s/iso/blob/1784c5648f65d8d7bc1c901635cc33f11f80382e/docs/credential-proxy.md
[repo-trust]: https://github.com/chr33s/iso/blob/1784c5648f65d8d7bc1c901635cc33f11f80382e/docs/trust-model.md
[repo-agent]: https://github.com/chr33s/iso/blob/1784c5648f65d8d7bc1c901635cc33f11f80382e/Sources/IsoCLI/AgentCommands.swift
[mlx-server]: https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/server.py
[mlx-blob]: https://api.github.com/repos/ml-explore/mlx-lm/git/blobs/9462d6e57822df160adc260d9414838179b71907
