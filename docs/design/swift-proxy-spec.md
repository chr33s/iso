> **Host scope clarification:** This fork supports macOS 27+ Apple Silicon
> hosts only; guest VMs still run Linux. Earlier requirements to pass Linux/
> Firecracker host gates are superseded. Historical failures remain recorded
> as evidence, not current acceptance blockers. Applicable macOS VM, live
> provider/agent, review, and release-provenance gates remain required.

> **2026-09-27 user decision:** Remove the Rust proxy now and waive the
> observation period. This supersedes the transition selector, dual-binary
> packaging, rollback retention, and pre-deletion sequencing below. Swift is
> the sole proxy implementation. Other unexecuted acceptance/release gates
> remain open and must not be reported as passed. The Rust host CLI is outside
> this proxy-port deletion scope.

# Specification: Swift Port of `iso-proxy`

**Status:** Approved for implementation  
**Scope:** `chr33s/iso`, macOS 27+, Apple Silicon, Swift-only credential proxy; Rust host CLI retained

**Baseline:** `chr33s/iso` at `2e1bf205f7659a06be506b1bbd24a028f9da3773`  
**Guest:** Existing Linux/Ubuntu guest  
**VM backend for acceptance:** `iso-sandbox`; the implementation also supports Lima

**Security sensitivity:** High — credential-bearing boundary

---

## 1. Purpose

This specification defines the replacement of the Rust `iso-proxy` with a
Swift implementation while preserving or strengthening the existing credential
isolation model.

The proxy is a security boundary. It accepts HTTP requests originating from an
untrusted guest VM while holding a real Anthropic or OpenAI credential in host
memory.

The port MUST preserve the central property:

> The guest can exercise a narrowly allowed set of model API operations without
> receiving the reusable upstream credential.

The migration MUST be treated as a behavioral/security replacement, not a
mechanical language translation.

---

## 2. Approved architecture decisions

### D-001 — Separate Swift credential-proxy implementation

**Decision: APPROVED**

The credential proxy is implemented in Swift. The host `iso` CLI remains Rust;
the optional `iso-sandbox` runtime is a separate Swift package. Rewriting the
host CLI is outside this proxy port’s scope.

The proxy remains a **separate executable** from the host CLI and VM runtime.

Required process separation:

```text
iso
  orchestration, configuration, VM lifecycle
        |
        | startup config over pipe
        v
iso-proxy
  real provider credential + hostile HTTP boundary
        |
        | HTTPS
        v
Anthropic / OpenAI
```

The proxy MUST NOT be merged into the `iso` process.

Rationale:

- an HTTP parser/proxy compromise must not automatically gain VM lifecycle
  authority;
- the proxy should have no normal access to workspace contents;
- the proxy should not gain access to unrelated stored credentials;
- Seatbelt confinement remains independently applicable.

---

### D-002 — macOS system trust replaces bundled Mozilla trust roots

**Decision: EXPLICITLY APPROVED**

The Swift proxy SHALL use the **macOS system trust configuration** for
proxy-to-provider TLS verification.

This intentionally replaces the Rust implementation's compiled
`webpki-roots` / Mozilla root set.

The production implementation MUST use a Security.framework-backed trust
evaluation path. A bundled CA bundle SHALL NOT be the production source of
trust.

#### Required TLS behavior

The implementation MUST:

- verify the complete server certificate chain;
- verify the provider hostname;
- reject self-signed certificates unless they are explicitly trusted by macOS;
- reject certificates whose hostname does not match the fixed provider;
- reject expired/not-yet-valid certificates according to macOS trust policy;
- use the fixed provider hostname for SNI/trust evaluation;
- provide no production "accept invalid certificate" option;
- provide no config key that disables TLS verification;
- provide no guest-controlled trust-store input.

#### Explicitly accepted consequence

macOS system trust includes roots trusted by the host operating system,
including roots installed by:

- the local administrator/user where macOS permits it;
- MDM/device-management policy;
- enterprise security tooling.

Therefore, an administrator-installed enterprise TLS interception root MAY be
able to authenticate `api.anthropic.com` or `api.openai.com` to `iso-proxy`.

**This is accepted by design.**

Rationale:

1. `iso` is now a macOS-only product, so host trust policy is an appropriate
   platform source of truth.
2. The host user/administrator and host security policy are already inside the
   trusted host boundary.
3. The untrusted guest cannot modify the host macOS trust store.
4. System trust gains automatic OS security/trust updates and expected
   compatibility with managed enterprise Macs.
5. Maintaining a separate application CA root set would create an independent
   trust-update lifecycle with limited benefit for the stated host threat
   model.

This decision does **not** mean TLS verification may be skipped. It changes
**which roots are trusted**, not whether the provider identity is verified.

#### Certificate pinning

Application-level certificate/SPKI pinning SHALL NOT be introduced in the
initial Swift port.

Reason:

- Anthropic/OpenAI may rotate certificates, intermediates, CDNs, and edge
  infrastructure;
- a pin set creates an additional availability/security update obligation;
- the approved trust authority is macOS system trust.

Pinning may be proposed later as a separate design change.

#### Seatbelt implication

Security.framework trust evaluation may require communication with macOS trust
services such as `trustd`.

If the existing Seatbelt profile must be widened for system trust:

- add only the minimum exact mach service(s) required;
- document each added service;
- add a test proving TLS succeeds under the production profile;
- do not add generic keychain/file-write access;
- treat any additional Seatbelt permission as a security-review item.

---

### D-003 — retain Seatbelt during the language migration

**Decision: APPROVED**

The first production Swift proxy SHALL run under the existing
`sandbox-exec`/Seatbelt confinement model.

The Swift port MUST NOT simultaneously migrate to App Sandbox or another
sandbox technology.

The current intended confinement remains:

```text
deny by default
allow required file reads
deny filesystem writes
deny arbitrary exec
allow exact initial proxy exec
allow loopback bind/inbound
allow outbound TCP :443
allow DNS :53
allow only required name-resolution/trust mach services
```

`sandbox-exec` is deprecated. That debt is accepted for the initial Swift port
because changing both the HTTP implementation and process sandbox at once would
remove a strong source of migration comparability.

Replacing Seatbelt is a separate future project.

---

### D-004 — fixed providers, not arbitrary upstream hosts

**Decision: APPROVED**

The security-critical Swift core SHALL model the provider as a closed enum:

```text
anthropic
openai
```

The guest and normal host config MUST NOT supply an arbitrary upstream hostname.

Provider mapping is compiled policy:

```text
anthropic -> api.anthropic.com:443
openai    -> api.openai.com:443
```

Scheme is always HTTPS.

Port is always 443.

---

### D-005 — HTTP/1.1 only for initial parity

**Decision: APPROVED**

The initial Swift proxy SHALL:

- accept HTTP/1.1 from the guest;
- send HTTP/1.1 upstream;
- not negotiate/use HTTP/2 for provider traffic;
- not support h2c upgrade.

This intentionally matches the existing Rust upstream path closely and avoids
widening the protocol surface during a security migration.

HTTP/2 may be added later with dedicated validation.

---

### D-006 — redirects are prohibited

**Decision: APPROVED**

The upstream HTTP client MUST NOT follow redirects.

A provider redirect MUST be returned to the guest as the provider response; the
proxy MUST NOT issue a second credential-bearing request to the redirect target.

This requirement applies even if the redirect points to another provider-owned
hostname.

---

## 3. Threat model

### 3.1 Trusted

- host macOS kernel;
- host user/administrator;
- host trust-store policy;
- `iso`;
- `iso-sandbox`;
- `iso-proxy` binary as installed/verified;
- fixed proxy configuration generated by `iso`.

### 3.2 Untrusted

- the entire guest VM;
- the coding agent;
- guest HTTP request bytes;
- guest headers;
- guest paths and query strings;
- guest timing/concurrency behavior;
- network responses before TLS identity verification.

### 3.3 Protected asset

The primary protected asset is the reusable upstream provider credential:

- `ANTHROPIC_API_KEY`;
- Claude setup/bearer token;
- `OPENAI_API_KEY`.

The credential MAY exist:

- in `iso` memory while being resolved;
- on the `iso -> iso-proxy` startup pipe;
- in `iso-proxy` memory;
- in an authenticated TLS request to the fixed provider.

The credential MUST NOT intentionally exist:

- in the guest;
- in proxy argv;
- in proxy environment;
- in a proxy config file;
- in persistent proxy state;
- in logs;
- in error output;
- in HTTP responses to the guest.

---

## 4. Process and startup contract

### 4.1 One process per instance/provider

Use one proxy process for each:

```text
(instance, provider)
```

Do not implement a multi-provider route table inside one credential-holding
process.

This limits cross-provider/cross-VM blast radius and preserves simple policy.

### 4.2 Startup configuration transport

`iso` MUST pass startup configuration to `iso-proxy` over an inherited stdin
pipe.

The proxy MUST:

1. read startup JSON to EOF;
2. validate it completely;
3. release/close stdin;
4. establish all security preconditions;
5. only then bind/accept guest traffic.

No startup credential may be passed via argv or a persistent file.

### 4.3 Startup schema

Use a versioned schema.

Example:

```json
{
  "version": 1,
  "listen": "127.0.0.1:8788",
  "provider": "anthropic",
  "capability_token": "<64 lowercase hex characters>",
  "injection": {
    "scheme": "x_api_key",
    "credential": "<secret>"
  }
}
```

Allowed injection schemes:

```text
anthropic:
  x_api_key
  bearer

openai:
  bearer
```

Any incompatible provider/scheme combination MUST fail startup.

Unknown fields SHOULD fail decoding unless there is a documented compatibility
reason to permit them.

### 4.4 Environment scrubbing

Before spawning the proxy, `iso` MUST build an explicit child environment.

The child MUST NOT inherit:

- `ANTHROPIC_*`;
- `OPENAI_*`;
- `GITHUB_*`;
- `GH_*`;
- `SSH_AUTH_SOCK`;
- `DYLD_*`;
- `HTTP_PROXY`;
- `HTTPS_PROXY`;
- `ALL_PROXY`;
- `NO_PROXY`;
- arbitrary caller environment entries.

Permit only variables demonstrated necessary for the Swift runtime / locale /
temporary directory.

Prefer an allowlist such as:

```text
TMPDIR
LANG / LC_* only when required
```

`PATH` SHOULD be omitted because the proxy is forbidden from launching
programs after startup.

### 4.5 Core dumps

The proxy SHOULD set:

```text
RLIMIT_CORE = 0
```

before handling secrets, where supported.

Failure to apply this hardening SHOULD be visible in tests/logging but need not
block production if macOS policy already disables core dumps and the project
records that decision.

---

## 5. Inbound transport

### 5.1 Listener

Initial production listener:

```text
127.0.0.1:<per-instance-provider-port>
```

The config parser MUST reject:

- `0.0.0.0`;
- IPv6 unspecified;
- non-loopback IPv4;
- non-loopback IPv6.

The normal guest reaches this listener only through its per-instance reverse
SSH tunnel.

### 5.2 Future Unix-socket transport

Moving the host-side listener to a Unix-domain socket is desirable but OUT OF
SCOPE for the initial Swift parity port.

It changes:

- SSH forwarding shape;
- Seatbelt permissions;
- socket ownership/cleanup;
- readiness logic.

Treat it as a separate hardening change after Swift parity.

---

## 6. Swift HTTP stack

### 6.1 Inbound

Use SwiftNIO HTTP/1 facilities.

Requirements:

- use a SwiftNIO release containing the 2026 HTTP decoder-limit fix
  (minimum 2.100.0);
- pin the exact vetted dependency version in `Package.resolved`;
- configure parser limits explicitly;
- do not depend on library defaults for hostile-input resource limits.

### 6.2 Outbound

Preferred first implementation:

```text
AsyncHTTPClient + NIOSSL
```

with a dedicated client instance.

Required configuration:

```text
redirects             disabled
HTTP version          HTTP/1 only
TLS verification      full
trust source          macOS system trust
connection count      explicitly bounded
connect timeout       explicitly bounded
environment proxy     disabled/not consulted
```

`HTTPClient.shared` MUST NOT be used.

If true streaming request bodies cannot be implemented without unbounded
buffering, use a direct SwiftNIO/NIOSSL HTTP/1 client instead.

### 6.3 No custom HTTP parser

Do not implement HTTP/1 framing manually on `Network.framework`.

---

## 7. Capability authentication

### 7.1 Token format

Capability tokens SHALL be:

```text
256 random bits
encoded as exactly 64 lowercase hexadecimal characters
```

Startup MUST reject malformed or empty capability tokens.

### 7.2 Presentation channels

Accept capability authentication from:

```text
Authorization: Bearer <token>
x-api-key: <token>
```

All credential-bearing guest headers MUST be stripped before forwarding.

### 7.3 Constant-time verification

Do not use normal Swift `String` equality for capability authentication.

Use a cryptographic constant-time verification primitive from CryptoKit /
Swift Crypto or an equivalently reviewed primitive.

Convert the fixed token representation to bytes before comparison.

### 7.4 Multiple credential headers

Policy:

- duplicate values for the same credential header MUST be rejected;
- if both `Authorization` and `x-api-key` are present, every presented
  capability value MUST decode to the same expected capability;
- conflicting values MUST be rejected.

This prevents parser/header ambiguity while retaining compatibility with clients
that redundantly send both credential forms.

---

## 8. Operation allowlist

Default deny.

### OpenAI

Allowed:

```text
POST /v1/responses
```

### Anthropic

Allowed:

```text
POST /v1/messages
POST /v1/messages/count_tokens
```

Queries MAY be present on these exact paths.

No trailing-slash variants are implicitly accepted.

Examples denied:

```text
GET /v1/responses
POST /v1/responses/
GET /v1/responses/<id>
POST /v1/files
POST /v1/messages/batches
POST /v1/organizations/invites
CONNECT ...
TRACE ...
```

### Request-target handling

Authorization MUST be evaluated on the raw HTTP/1 request target before
Foundation URL canonicalization.

Accept origin-form only:

```text
/path
/path?query
```

Reject:

- absolute-form URLs;
- authority-form;
- asterisk-form;
- malformed request targets.

The upstream scheme/authority MUST be constructed from the fixed provider enum,
never extracted from the guest target.

---

## 9. Header policy

### 9.1 Always remove

Remove before forwarding:

```text
authorization
x-api-key
host
connection
proxy-connection
keep-alive
transfer-encoding
te
trailer
upgrade
proxy-authenticate
proxy-authorization
```

### 9.2 `Connection` nominated headers

If the incoming `Connection` header names additional header fields, those
named fields MUST also be removed.

Example:

```text
Connection: keep-alive, x-internal
```

requires stripping `x-internal`.

### 9.3 Host

Insert exactly:

```text
Host: api.anthropic.com
```

or:

```text
Host: api.openai.com
```

according to the provider.

### 9.4 Provider credential

Inject:

```text
x-api-key: <credential>
```

or:

```text
Authorization: Bearer <credential>
```

according to the validated provider/injection policy.

The injected value MUST be treated as sensitive by any logging/diagnostic
abstraction.

### 9.5 Trailers

Inbound request trailers SHALL be rejected in the initial implementation.

They may be supported later only if a demonstrated client requirement exists.

---

## 10. Request and response streaming

### 10.1 No whole-body aggregation

Normal request and response bodies MUST stream incrementally.

Do not:

- `collect()` the entire request;
- convert the entire request into `Data`;
- buffer the entire upstream response before forwarding.

### 10.2 Backpressure

The inbound/outbound bridge MUST honor backpressure.

An upstream that reads slowly must eventually slow guest reads rather than
allowing an unbounded in-memory queue.

A guest that reads slowly must eventually slow upstream response reads.

### 10.3 Request-body cap

Initial hard cap:

```text
64 MiB per request body
```

If live Claude/Codex validation demonstrates a legitimate larger request, the
constant may be raised in a reviewed change.

The limit MUST NOT be guest-configurable.

Over-limit requests return:

```text
413 Payload Too Large
```

and MUST NOT reach the provider with the real credential.

Request bodies MUST have a known length before upstream forwarding. Reject
`Transfer-Encoding: chunked` with `411 Length Required` before opening an
upstream connection or sending `100 Continue`. Ambiguous framing (including
both Content-Length and Transfer-Encoding) remains `400 Bad Request`.
A request with neither framing header has an empty body and is allowed through
normal authentication and operation checks. Accepted Content-Length bodies are
streamed with backpressure; no whole-request buffering is introduced. Response
streaming, including SSE, is unaffected.

### 10.4 Response-body cap

Do not impose a small total response cap; streamed model responses may be large
or long-lived.

Resource safety is provided through:

- bounded concurrency;
- streaming/backpressure;
- connection limits;
- no unbounded buffering.

---

## 11. Resource limits

Initial constants:

```text
max accepted guest connections       256
max in-flight upstream requests      256
max single HTTP header field         16 KiB
max aggregate HTTP header block      64 KiB
max header count                     128
max request body                     64 MiB
upstream TCP + TLS establishment     30 seconds
initial header read timeout          10 seconds
request-body idle timeout            30 seconds
```

These are compile-time/runtime constants owned by the proxy implementation, not
guest configuration.

### Request permit lifetime

An in-flight request permit MUST remain held until:

```text
entire upstream response body completes
or
the response stream terminates/errors
or
the guest disconnects and upstream work is cancelled
```

Receiving response headers is NOT sufficient to release the permit.

There is no short total timeout on valid streaming responses.

---

## 12. TLS implementation

### 12.1 Fixed identity

For each request:

```text
provider enum
    -> fixed hostname
    -> fixed port 443
    -> SNI = fixed hostname
    -> Security.framework system-trust evaluation
```

Guest data MUST NOT influence these fields.

### 12.2 System trust

As approved in D-002, production verification uses macOS system trust.

The test plan MUST include:

- trusted correct-host certificate succeeds;
- untrusted/self-signed certificate fails unless installed into the relevant
  macOS trust domain for the test;
- wrong-host certificate fails;
- expired certificate fails;
- guest cannot change SNI;
- guest cannot change upstream host;
- guest cannot change port;
- redirect does not trigger a second request.

### 12.3 No client TLS identity

`iso-proxy` does not present a client certificate to providers.

---

## 13. Seatbelt confinement

The Swift binary MUST run under a checked-in deny-default Seatbelt profile.

Required properties:

```text
filesystem writes                denied
arbitrary program exec           denied
initial exec of exact proxy      allowed
required library/config reads    allowed
loopback bind/inbound            allowed
TCP outbound                     only :443 / :53
UDP outbound                     only DNS :53 where required
name resolution                  allowed minimally
macOS trust evaluation           allowed minimally
```

### 13.1 Production self-test

Maintain a `--jail-selftest` equivalent that uses no real credential.

Under the production Seatbelt profile it MUST verify:

- temp-file create is denied;
- `/bin/sh` execution is denied;
- connection to a random disallowed TCP port is denied;
- port 443 is not denied by the sandbox policy;
- DNS succeeds;
- the proxy can bind/accept its intended listener.

### 13.2 Fail closed

If Seatbelt cannot be established, the proxy MUST never begin serving.

`iso` readiness behavior remains:

```text
spawn confined proxy
    |
wait for real HTTP readiness
    |
failure / child exit / timeout
    |
abort VM start
```

No unconfined retry is allowed.

---

## 14. Logging and diagnostics

Production logs MAY include:

- provider name;
- listener port;
- lifecycle state;
- response status class;
- timeout/capacity/error category.

Production logs MUST NOT include:

- capability token;
- provider credential;
- full Authorization value;
- x-api-key value;
- request body;
- response body;
- startup JSON.

Avoid logging query strings unless explicitly demonstrated safe.

The `Secret` type MUST render only as redacted in diagnostics.

---

## 15. Swift package layout

Recommended structure:

```text
Sources/
  IsoProxyCore/
    Provider.swift
    ProxyConfig.swift
    Secret.swift
    Capability.swift
    OperationPolicy.swift
    HeaderPolicy.swift
    RequestTarget.swift
    Limits.swift

  IsoProxy/
    main.swift
    Server.swift
    UpstreamClient.swift
    StreamingBridge.swift
    Signals.swift
    JailSelfTest.swift
```

`IsoProxyCore` MUST not depend on sockets or process APIs.

The security-critical pure policy should therefore be testable without a live
network.

---

## 16. Migration plan

### Phase 0 — harden the Rust reference

Before using Rust as the behavioral oracle, add/confirm:

- loopback-only listener validation;
- explicit child environment allowlist;
- closed provider enum;
- exact token format;
- duplicate/conflicting credential-header handling;
- `Connection`-nominated header stripping;
- origin-form-only request-target policy;
- explicit request body cap;
- explicit HTTP parser/header limits where practical;
- trailer rejection.

Each change gets tests.

The Swift port targets this hardened contract rather than accidental legacy
behavior.

### Phase 1 — pure Swift policy

Implement `IsoProxyCore`.

Required tests:

- config validation;
- provider mapping;
- capability verification;
- exact operation allowlist;
- raw request-target policy;
- header removal/injection;
- conflicting credential headers;
- resource-limit constants.

### Phase 2 — inbound server

Implement SwiftNIO HTTP/1 server with explicit parser limits.

No upstream forwarding yet.

Validate:

- malformed HTTP handling;
- connection cap;
- authorization failures;
- 403 policy failures;
- 413 body-limit failures.

### Phase 3 — outbound TLS/client

Add AsyncHTTPClient/NIOSSL with:

- redirects off;
- HTTP/1 only;
- system trust;
- fixed provider endpoint;
- streaming request/response;
- 30-second connect/TLS timeout.

### Phase 4 — Seatbelt

Run Swift binary under existing profile.

Add only minimum permissions required for system trust.

Pass jail self-test.

### Phase 5 — differential test period (historical)

Ship/build both:

```text
iso-proxy-rs
iso-proxy-swift
```

Default remains Rust.

A host-side development/test selector may choose Swift.

The guest MUST NOT control implementation selection.

### Phase 6 — Swift default

At the user-authorized immediate cutover:

- Swift is the sole proxy implementation;
- package it as `iso-proxy` for compatibility with existing updaters;
- Swift startup failure MUST fail VM startup;
- no fallback implementation or selector remains.

### Phase 7 — remove Rust

The user waived observation and authorized immediate removal on 2026-09-27:

- delete Rust `iso-proxy`;
- remove Tokio/Hyper/Rustls/Landlock proxy dependencies;
- remove transition selector;
- preserve language-neutral proxy contract tests permanently.

---

## 17. Differential security corpus

Both implementations MUST be tested against the same logical contract.

Required adversarial cases include:

### Authentication

- no credential;
- wrong capability;
- malformed bearer;
- empty bearer;
- very long bearer;
- duplicate Authorization;
- duplicate x-api-key;
- Authorization + x-api-key same token;
- Authorization + x-api-key conflicting token.

### Methods/paths

- exact allowed path;
- query on allowed path;
- trailing slash;
- parent/dot segments;
- percent-encoded variants;
- absolute-form URI;
- authority-form;
- `*`;
- GET/DELETE/TRACE/CONNECT;
- cross-provider allowed path.

### Framing/headers

- duplicate Host;
- guest Host pointing elsewhere;
- hop-by-hop fields;
- arbitrary `Connection:` nominated header;
- Transfer-Encoding + Content-Length ambiguity;
- duplicate Content-Length;
- oversized single header;
- oversized total headers;
- too many headers;
- request trailers.

### Streaming/resource behavior

- slow headers;
- slow body;
- body exactly at cap;
- body over cap;
- early guest disconnect;
- early upstream disconnect;
- long SSE response;
- 256 held streaming responses;
- 257th request;
- >256 idle guest sockets.

### TLS

- trusted correct host;
- self-signed;
- wrong hostname;
- expired;
- redirect response;
- DNS failure;
- connect timeout.

---

## 18. Differential comparison rules

For equivalent input, compare:

- local HTTP status;
- whether an upstream request occurred;
- provider selected;
- upstream method;
- exact logical path/query;
- semantic header set;
- absence of guest capability upstream;
- correct injected credential;
- request-body SHA-256;
- response status;
- response headers after hop-by-hop filtering;
- response-body SHA-256;
- connection-close behavior;
- capacity/timeout behavior.

Do not require identical header ordering or implementation-specific error text.

Any semantic difference MUST be:

1. fixed, or
2. documented as an intentional security/compatibility change and reviewed
   before cutover.

---

## 19. Test strategy

### 19.1 Unit tests

Use Swift Testing/XCTest for `IsoProxyCore`.

### 19.2 NIO embedded tests

Use `NIOEmbedded` for deterministic handler tests.

### 19.3 Mutation testing

Use a Swift mutation-testing tool such as Muter on:

```text
Capability.swift
OperationPolicy.swift
HeaderPolicy.swift
RequestTarget.swift
```

Tests MUST kill mutations that turn:

- deny into allow;
- POST into any-method;
- exact path into prefix matching;
- strip into preserve;
- equality into inequality.

### 19.4 Fuzzing

Retain a language-neutral raw HTTP fuzz/adversarial harness.

Swift-native fuzzing may supplement it but MUST NOT be the only malformed-input
gate during migration.

### 19.5 VM integration

On real macOS 27+ hardware:

```text
guest
 -> SSH reverse tunnel
 -> Swift proxy under Seatbelt
 -> controlled upstream harness
```

Assert:

- valid request reaches upstream with injected credential;
- raw credential is absent from guest env;
- raw credential is absent from guest disk;
- capability-less request is rejected;
- streaming works;
- proxy restart/lifecycle cleanup works;
- killing proxy causes a clear agent failure;
- another VM's capability is rejected.

### 19.6 Live-provider smoke tests

After mock integration passes, run controlled tests for:

- Anthropic message streaming;
- Anthropic token counting;
- Claude tool-use round trip;
- OpenAI Responses streaming;
- Codex tool-use round trip;
- cancellation/disconnect.

Do not shadow the same live request through both proxies.

Use dedicated test credentials.

---

## 20. Release and rollback

Package the Swift proxy as `iso-proxy` beside the host CLI in the same
signed/attested macOS artifact and from the same source revision. Preserve
checksum and provenance verification before installation. The Rust rollback
implementation and host selector are removed; startup failure must fail closed.

The user waived the observation period and authorized immediate Rust proxy
removal on 2026-09-27. This supersedes the earlier pre-deletion sequencing.
Unexecuted validation and publication gates still remain required for full goal
completion; removal does not imply they passed.

---

## 21. Acceptance criteria

These remain the full-goal acceptance criteria. The user-authorized immediate
Rust deletion is independent of any unexecuted criteria below. Historical
Rust/Swift comparison and explicit rollback evidence predates deletion.

### Architecture

- [ ] Swift proxy is a separate executable.
- [ ] One process exists per VM/provider.
- [ ] Provider is a closed enum.
- [ ] No arbitrary upstream host config exists.

### Secrets

- [ ] Real credential enters proxy through stdin only.
- [ ] Capability is fixed 256-bit/64-hex format.
- [ ] Capability verification is constant-time.
- [ ] Child environment is explicitly scrubbed.
- [ ] No raw credential in argv.
- [ ] No raw credential in persistent proxy files.
- [ ] No raw credential in logs.
- [ ] No raw credential in guest env/disk.

### HTTP policy

- [ ] HTTP/1.1 only.
- [ ] Redirects disabled.
- [ ] Exact operation allowlist passes.
- [ ] Absolute-form/authority-form/asterisk targets rejected.
- [ ] Guest credential headers stripped.
- [ ] Hop-by-hop fields stripped.
- [ ] `Connection`-nominated fields stripped.
- [ ] Request trailers rejected.
- [ ] Parser limits explicit.
- [ ] Request body capped.
- [ ] Streaming uses backpressure.

### TLS

- [ ] macOS system trust is used.
- [ ] System-trust switch is documented as approved.
- [ ] Correct-host trusted certificate succeeds.
- [ ] Wrong-host certificate fails.
- [ ] Untrusted certificate fails unless intentionally trusted by macOS.
- [ ] Expired certificate fails.
- [ ] Guest cannot control SNI/host/scheme/port.
- [ ] Redirect test proves no credential-bearing follow-up occurs.

### Resource controls

- [ ] Connection cap enforced.
- [ ] In-flight request cap enforced.
- [ ] Request permit held through complete response body.
- [ ] Upstream establishment timeout enforced.
- [ ] Slow/malformed clients cannot grow memory without bound.

### Sandbox

- [ ] Production Seatbelt profile applies to Swift binary.
- [ ] Required trustd/Security permissions are minimal and documented.
- [ ] File-write self-test denied.
- [ ] Exec self-test denied.
- [ ] Disallowed network port denied.
- [ ] DNS/system trust still function.
- [ ] Sandbox failure prevents serving.
- [ ] Proxy readiness failure aborts VM start.

### Validation

- [ ] Shared security corpus passes.
- [ ] Rust/Swift differential suite passes.
- [ ] Mutation tests pass target threshold.
- [ ] Raw malformed-HTTP/fuzz gate passes.
- [ ] Real-hardware VM integration passes.
- [ ] Live Anthropic smoke tests pass.
- [ ] Live OpenAI smoke tests pass.
- [ ] Security review has no unresolved high/critical findings.
- [ ] Explicit rollback to Rust has been exercised.

---

## 22. Non-goals for the initial Swift port

The following are deliberately excluded from the first cutover:

- replacing Seatbelt with App Sandbox;
- moving the host listener to a Unix-domain socket;
- listener-FD passing;
- HTTP/2;
- general-purpose HTTP proxying;
- arbitrary upstream configuration;
- provider certificate pinning;
- GitHub credential proxying;
- sharing one proxy process across VMs/providers.

Each may be considered later as an independent design with its own validation.

---

## 23. Post-parity hardening candidates

After Rust parity and Swift cutover:

1. replace host TCP listener with a `0600` Unix socket carried by SSH remote
   forwarding;
2. optionally pre-bind/pass listener descriptors to remove proxy bind authority;
3. evaluate a supported successor to deprecated `sandbox-exec`;
4. reduce Seatbelt file-read scope if Swift runtime measurements make it
   practical;
5. further restrict query parameters per provider endpoint if required;
6. evaluate per-request byte/accounting telemetry without logging prompt data;
7. evaluate stronger credential-memory handling without claiming perfect
   zeroization.

---

## 24. Security invariants summary

The port is complete only if these statements remain true:

```text
UNTRUSTED GUEST
    cannot choose provider host
    cannot choose TLS scheme
    cannot choose provider port
    cannot access upstream credential
    cannot widen allowed provider operations
    cannot bypass capability authentication
    cannot make proxy bind outside loopback
    cannot make proxy follow a redirect

SWIFT PROXY
    receives credential only over stdin
    keeps credential out of logs/files/argv/env
    runs in a deny-default Seatbelt domain
    verifies provider identity using macOS system trust
    injects credential only after auth + operation policy
    streams bodies with bounded resource usage

HOST
    explicitly trusts macOS trust policy, including admin/MDM-installed roots
    remains the trusted boundary
```

The approved change from compiled Mozilla roots to macOS system trust is a
deliberate platform-trust decision, not a relaxation of TLS verification.
