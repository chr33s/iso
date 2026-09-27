# Credential-injecting proxy (`[proxy]`)

Status: **v1 — Anthropic (Claude Code) and OpenAI (Codex); Firecracker and
Lima.** Opt-in; off by default. Design:
[`design/issue-411-injecting-proxy.md`](design/issue-411-injecting-proxy.md).

## What it does

Without proxy mode, coop forwards the raw `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`
into the guest as SSH `SendEnv` variables — a prompt-injected or rogue agent can
read them from its own environment and, with egress open, exfiltrate them.

With proxy mode, the raw credential **never enters the guest**. coop runs a
small host-side reverse proxy (`coop-proxy`) — one process per (VM, provider) —
for the lifetime of the VM:

- The proxy binds host loopback and is exposed into the guest by a per-instance
  `ssh -R` reverse tunnel; the guest is pointed at `http://127.0.0.1:<port>` and
  holds only a **per-instance capability token**.
  - **Claude Code:** `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` in the
    managed `~/.claude/settings.json`.
  - **Codex:** a `[model_providers.coop_local]` block in `~/.codex/config.toml`
    (`base_url` at the proxy, `wire_api = "responses"`) with the capability
    token supplied as the provider's bearer `env_key`. Proxy mode pins no model
    — Codex keeps its own, only its egress is redirected.
- The proxy verifies that token (constant-time), strips it, injects the real
  credential (`x-api-key`, or `Authorization: Bearer`), and streams the request
  to the pinned upstream (`api.anthropic.com` / `api.openai.com`) over TLS.
- The raw `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` is no longer forwarded, and in
  proxy mode Codex's `~/.codex/auth.json` is **not** staged onto the guest disk
  (it holds a refreshable subscription token — the exact at-rest exposure #411
  closes). Codex subscription is therefore out of scope in proxy mode; use an
  OpenAI API key.

When agent bootstrap runs with an OpenAI proxy, coop also removes any existing
`~/.codex/auth.json` left by a previous direct-auth boot. If removal fails,
proxy bootstrap aborts and tears down the proxy. `--no-agents` skips this
cleanup along with the rest of agent bootstrap.

For Codex account or workspace access without API billing, use
`[codex] auth = "chatgpt"` instead of `[proxy.openai]`. That mode stores Codex
credentials in the guest Linux keyring and is rejected when an OpenAI proxy is
also active.

The capability token is worthless off the host — it only authorizes the local
proxy, which holds the real key itself — so exfiltrating it gains a compromised
guest nothing.

## Operation policy

After authenticating the capability token, the proxy default-denies operations
before connecting upstream. The only allowed method/path pairs are:

| Provider | Allowed operation |
| --- | --- |
| OpenAI | `POST /v1/responses` |
| Anthropic | `POST /v1/messages` |
| Anthropic | `POST /v1/messages/count_tokens` |

All other methods and paths receive a local `403`. Unknown providers are
rejected at startup.
This limits a compromised guest to the model calls its configured coding agent
needs, and prevents it from using the injected key for account, model, admin,
or arbitrary retrieval APIs. Widening this list requires security review and
tests for the new agent operation.

The request bodies are intentionally opaque and streamed. In particular, an
allowed `POST /v1/responses` can still reference OpenAI objects by ID (such as
existing conversations, responses, prompts, or files) when the injected key is
authorized for them. The allowlist is defense in depth against broad API use,
not object-level tenant isolation.

The policy is intentionally closed: if a future agent version needs another
endpoint, it fails locally with `403` until coop adds and reviews that route.
Claude Code may issue `HEAD /api/hello` and `GET /v1/models?limit=1000` for
warmup or discovery; proxy mode intentionally refuses both because its normal
message and token-count operations do not require gateway discovery. Codex's
proxy provider is named `coop credential proxy`, not `OpenAI`, so Codex does
not currently enable its OpenAI-specific `POST /v1/responses/compact` behavior.
If either client changes this behavior, add the route only with an explicit
policy, test, and documentation update.

## Request body framing

Both proxy implementations admit bodies with a declared `Content-Length` of at
most 64 MiB and stream them with backpressure. Larger declared bodies receive
`413 Payload Too Large`. Chunked requests receive `411 Length Required` before
any upstream connection or `100 Continue`; clients must send a known length.
Ambiguous framing receives `400 Bad Request`. With neither Content-Length nor
Transfer-Encoding, HTTP/1.1 defines an empty request body. Response streaming
and SSE have no corresponding total-size cap.

## Enabling it

The easiest path is `coop proxy setup`: it takes a pasted credential, stores it
in a secret backend of your choice (macOS Keychain / Linux secret-service /
1Password / a 0600 file), and writes the `[proxy.<provider>]` block for you with
a `cmd:` reference — so the credential is never plaintext in the config.

- **Anthropic (default):** `coop proxy setup` takes a Claude `setup-token`
  (subscription) or an API key with `--api-key`. To generate a token first, run
  `claude setup-token` on the host (needs a Claude subscription; the token is
  inference-scoped, ~1 year).
- **OpenAI (Codex):** `coop proxy setup --openai` takes an OpenAI API key
  (always injected as `Authorization: Bearer`).

Or configure it by hand:

```toml
[proxy.anthropic]
credential = "cmd:op read op://Private/Anthropic/credential"  # or a plain key
auth = "api_key"   # api_key → x-api-key (default); bearer → a Claude setup-token

[proxy.openai]
credential = "cmd:op read op://Private/OpenAI/credential"
auth = "bearer"    # OpenAI keys inject as Authorization: Bearer
```

The `credential` uses the same `cmd:` resolution as every other coop secret and
is resolved on the **host** at VM start. For Claude subscription billing without
exposure, run `claude setup-token` on the host, stash the printed one-year
token, reference it via `cmd:`, and set `auth = "bearer"`.

## Per-VM credential overrides

The `[proxy.<provider>]` blocks are the **defaults** for every VM. A single VM
can use a different credential — for per-project billing, scope, or revocation —
with `coop proxy setup --openai --vm <name>` (or `--anthropic --vm <name>`). The
override is stored in that instance's state (`<inst.dir>/proxy.json`), not in a
growing config table, and its secret is namespaced separately (`coop-openai-<vm>`).

Resolution per provider is **override → default → off**: the per-VM override
wins, else the config default, else the proxy is off for that provider. This is
purely host-side credential selection — the proxy binary and the per-VM
capability token are unchanged, so there is no new attack surface.

`coop proxy status` shows the defaults and every VM's overrides; `coop proxy
status --vm <name>` shows one VM's effective resolution. Credentials are shown
as their `cmd:` reference (a command, not the secret); a hand-written literal is
redacted.

Proxy mode applies only in **remote** model mode. `coop model <vm> local` takes
precedence (the VM routes at your local model server and the proxy is torn
down). If credential resolution fails at start, the VM **fails closed** — it
does not come up on a path where the agent silently has no or the wrong key.

## What it does and does not guarantee

It stops a rogue agent from **reading a usable key** from its environment or
disk. It does **not**:

- Stop **use** of the credential while the agent runs — the agent still makes
  model calls through the proxy (that is the point). Non-exposure limits
  exfiltration of the raw key, not use during the session.
- Provide **egress** control — a token-less agent with open egress can still
  reach arbitrary hosts (issue #2). The proxy composes with, but does not
  replace, "no route out except the proxy."
- Provide **scope** enforcement — the injected key keeps its full account scope
  (issue #73). Non-exposure and scope are orthogonal.

The proxy itself is new attack surface, mitigated by a fixed per-route upstream
(the guest controls only the path, never the host — closing SSRF), TLS
verification against a pinned root set, a required capability token, and
resource limits. Each proxy allows at most 256 accepted guest TCP connections
and 256 concurrent requests; excess connections are closed immediately, so
idle sockets cannot bypass the request limit. The listener binds only host
loopback and is reverse-tunnelled
to exactly one guest — never a non-loopback interface, never the LAN.

It is also **jailed** to bound the blast radius of a proxy exploit. On Linux,
Landlock denies filesystem writes and program execution as a required floor;
additional filesystem restrictions apply where the kernel supports them. TCP
egress is limited to `:443` and `:53` on kernels ≥6.7. On kernels 5.13–6.6,
the proxy can start with that TCP restriction absent. On macOS, `sandbox-exec`
applies a Seatbelt profile that denies filesystem writes and program execution
and limits egress to those ports.

Startup fails closed if the required filesystem/exec floor cannot be applied.
The network rules are port-scoped, not host-scoped, and Landlock does not
restrict UDP. See [`trust-model.md`](trust-model.md) for the full threat model
and accepted limitations.

## Platform support

**Firecracker (Linux) and Lima (macOS).** The proxy binds `127.0.0.1` on the
host and is exposed into the guest with a per-instance `ssh -R` reverse tunnel,
so it works identically on both backends (each already keeps an SSH channel to
its guest). The host-side proxy process is jailed on both — Landlock on Linux
(enabled on the host; kernel ≥5.13, with TCP scoping from ≥6.7), Seatbelt via
`sandbox-exec` on macOS. GitHub credentials are not supported.


## Swift port development

The macOS 27+ Swift implementation is under development in
`macos/coop-proxy`; coop defaults to the Rust implementation. The approved
Swift trust policy uses macOS system trust through Security.framework, including
administrator/MDM-installed roots. This intentionally replaces the Rust proxy's
bundled Mozilla roots. Hostname and full-chain verification remain mandatory;
there is no guest or startup option to disable them or supply trust roots.

Both implementations bound the request target to 16 KiB and count its bytes
with header names and values toward a 64 KiB aggregate metadata limit. Each
header's name and value together may occupy at most 16 KiB, with at most 128
headers. Separators are excluded from these byte counts. This matches
SwiftNIO's aggregate accounting and is stricter than counting headers alone.
The complete wire request head is additionally capped at 82,496 bytes, including
optional whitespace and separators. Body bytes do not consume that allowance.

The Swift executable refuses startup unless file writes, shell execution, and
a randomly selected disallowed TCP port are denied. Seatbelt permits outbound
TCP on ports 443 and 53; application policy fixes the provider hostname and TLS
verifies its identity. The production Seatbelt profile adds only
`com.apple.trustd.agent` lookup for system trust evaluation; it adds no keychain
service or filesystem write allowance. The credential-free process gate proves
TLS to both providers under that profile and fails when this permission is
removed:

```sh
swift build --package-path macos/coop-proxy
python3 scripts/test-swift-proxy-process.py
```

The gate also exercises stdin configuration, actual HTTP bind/accept, secret-free
argv/diagnostics, and shutdown with an open guest socket. `--skip-tls` runs only
the offline portions and cannot establish TLS readiness. Controlled certificate rejection tests are also available in the Swift test
suite. Full differential/VM/live-agent validation, cutover, and the observation period
remain required; see [implementation evidence](design/swift-proxy-progress.md).

### Local transition builds

On Apple Silicon macOS 27+, build the host with the Apple sandbox backend and
both proxy implementations:

```sh
python3 scripts/build-proxy-transition.py
```

The script places `coop`, `coop-proxy-rs`, and `coop-proxy-swift` in Cargo's debug
output directory. Pass `--release` for release builds. This is a development
build workflow; release packaging and installation have not switched.

To create a local bundle of those three executables:

```sh
python3 scripts/build-proxy-transition.py --archive /tmp/coop-proxy-transition.tar.gz
```

The archive includes `LICENSE`, per-binary `SHA256SUMS`, and `BUILD.json` with
the backend, minimum macOS version, Rust default, source revision, and dirty-tree
status. These checksums detect corruption; this local bundle has no release
attestation. Add `--include-runtime` to bundle the ad-hoc signed `coop-sandbox`
runtime too; otherwise that runtime must be installed/configured separately.
The manual **Proxy transition candidate** workflow prepares a release-mode
four-executable archive, requiring a clean checkout of the triggering revision
before and after building. It verifies each Mach-O signature and adds a GitHub
provenance attestation and archive checksum. It uploads a candidate artifact;
it does not publish a release or change the default. The workflow has not yet
been run on GitHub. Ad-hoc binary signatures are not Developer ID signing or
notarization; the separate attestation supplies build provenance when verified.
Published releases still use the Lima build. The installer and self-updater can
consume a verified release archive containing both `coop-proxy-rs` and
`coop-proxy-swift`; a partial pair is rejected before replacement. Installing a
legacy archive containing `coop-proxy` removes stale transition names so the host
cannot select an older Rust sibling. Older archives without any proxy preserve
existing companions. Artifact checksum and attestation verification still happen
before these installation steps. The local transition archive above is not an
official installer/update artifact, and self-update still refuses Apple-backend
builds until a matching release channel exists.

Set `COOP_PROXY_IMPLEMENTATION=swift` in the **host** environment when launching
that `coop` build to test Swift. Set it to `rust`, or leave it unset, to use Rust.
The selector accepts only these two values and is unavailable for Swift on other
backend/platform builds. It is not a guest configuration field and the proxy
child receives an empty environment. A missing Swift binary or failed Swift
startup fails the launch; there is no automatic fallback. Rust resolves
`coop-proxy-rs` first and accepts the legacy `coop-proxy` name for compatibility
with existing installations. Binary paths are always relative to the host
`coop` executable, never supplied by the selector.
