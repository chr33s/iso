<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Credential-injecting proxy (`proxy`)

Status: **Anthropic (Claude Code) and OpenAI (Codex); macOS 27+ only.** Opt-in; off by default. Design:
[`design/issue-411-injecting-proxy.md`](design/issue-411-injecting-proxy.md).

## What it does

Without proxy mode, isolate forwards the raw `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`
into the guest as SSH `SendEnv` variables — a prompt-injected or rogue agent can
read them from its own environment and, with egress open, exfiltrate them.

With proxy mode, the raw credential **never enters the guest**. isolate runs a
small host-side reverse proxy (`iso-proxy`) — one process per (VM, provider) —
for the lifetime of the VM:

- The proxy binds host loopback and is exposed into the guest by a per-instance
  `ssh -R` reverse tunnel; the guest is pointed at `http://127.0.0.1:<port>` and
  holds only a **per-instance capability token**.
  - **Claude Code:** `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` in the
    managed `~/.claude/settings.json`.
  - **Codex:** a `[model_providers.iso_local]` block in `~/.codex/config.toml`
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

When agent bootstrap runs with an OpenAI proxy, isolate also removes any existing
`~/.codex/auth.json` left by a previous direct-auth boot. If removal fails,
proxy bootstrap aborts and tears down the proxy. `--no-agents` skips this
cleanup along with the rest of agent bootstrap.

For Codex account or workspace access without API billing, use
`"codex": { "auth": "chatgpt" }` instead of `proxy.openai`. That mode stores Codex
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
endpoint, it fails locally with `403` until isolate adds and reviews that route.
Claude Code may issue `HEAD /api/hello` and `GET /v1/models?limit=1000` for
warmup or discovery; proxy mode intentionally refuses both because its normal
message and token-count operations do not require gateway discovery. Codex's
proxy provider is named `iso credential proxy`, not `OpenAI`, so Codex does
not currently enable its OpenAI-specific `POST /v1/responses/compact` behavior.
If either client changes this behavior, add the route only with an explicit
policy, test, and documentation update.

## Request body framing

The Swift proxy admits bodies with a declared `Content-Length` of at
most 64 MiB and stream them with backpressure. Larger declared bodies receive
`413 Payload Too Large`. Chunked requests receive `411 Length Required` before
any upstream connection or `100 Continue`; clients must send a known length.
Ambiguous framing receives `400 Bad Request`. With neither Content-Length nor
Transfer-Encoding, HTTP/1.1 defines an empty request body. Response streaming
and SSE have no corresponding total-size cap.

## Enabling it

The easiest path is `iso proxy setup`: it takes a pasted credential, stores it
in the macOS Keychain (service `coop-anthropic` or `coop-openai`), and writes
the `proxy.<provider>` object for you with a `cmd:` reference — so the
credential is never plaintext in the config. The Keychain is the only built-in
store; if it is unavailable, setup fails rather than falling back.

- **Anthropic (default):** `iso proxy setup` takes a Claude `setup-token`
  (subscription) or an API key with `--api-key`. To generate a token first, run
  `claude setup-token` on the host (needs a Claude subscription; the token is
  inference-scoped, ~1 year).
- **OpenAI (Codex):** `iso proxy setup --openai` takes an OpenAI API key
  (always injected as `Authorization: Bearer`).

Or configure it by hand:

```jsonc
{
  "proxy": {
    "anthropic": {
      "credential": "cmd:op read op://Private/Anthropic/credential",
      "auth": "api_key"  // api_key → x-api-key (default); bearer → a Claude setup-token
    },
    "openai": {
      "credential": "cmd:op read op://Private/OpenAI/credential",
      "auth": "bearer"   // OpenAI keys inject as Authorization: Bearer
    }
  }
}
```

The `credential` must be a `cmd:` reference or a `vault:<name>` reference to a
[`iso secrets`](commands.md#secrets) entry; a literal value is rejected, and
the error names the field without printing its contents.

An instance can also take its provider credential from the secret store at
`up`/`start`: `--env ANTHROPIC_API_KEY={vault:anthropic}` (or the same line in
an `--env-file`) routes that secret to this VM's proxy and never into the
guest. Resolution per provider is then **provider secret → per-VM override →
default → off**. The command runs on
the **host** at VM start, just in time, and isolate never creates or deletes what
a hand-written reference points at. For Claude subscription billing without
exposure, run `claude setup-token` on the host, stash the printed one-year
token, reference it via `cmd:`, and set `"auth": "bearer"`.

## `proxy.mode`

`"auto"` (the default) keeps the behavior above: a provider with an upstream
is proxied and none of its credential variables (`ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, or `OPENAI_API_KEY`) is
forwarded; a provider without one is forwarded raw, with a warning.
`"required"` withholds every provider's variables, refuses explicit
`env_forward`/`guest_env`/`--env` declarations of them, and fails `up`/`start`
for a remote-mode VM without any provider proxy. `"off"` starts no proxy. See
[configuration](configuration.md#proxymode).

## Per-VM credential overrides

The `proxy.<provider>` objects are the **defaults** for every VM. A single VM
can use a different credential — for per-project billing, scope, or revocation —
with `iso proxy setup --openai --vm <name>` (or `--anthropic --vm <name>`). The
override is stored in that instance's state (`<inst.dir>/proxy.json`), not in a
growing config object, and its Keychain item is namespaced separately
(`coop-openai-<vm>`). A per-VM override must also be a `cmd:` reference; an
older literal override is rejected until you re-run `iso proxy setup --vm`.

Resolution per provider is **override → default → off**: the per-VM override
wins, else the config default, else the proxy is off for that provider. This is
purely host-side credential selection — the proxy binary and the per-VM
capability token are unchanged, so there is no new attack surface.

`iso proxy status` shows the defaults and every VM's overrides; `iso proxy
status --vm <name>` shows one VM's effective resolution. Credentials are shown
as their `cmd:` reference (a command, not the secret).

Proxy mode applies only in **remote** model mode. `iso model <vm> local` takes
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
verification against macOS system trust, a required capability token, and
resource limits. Each proxy allows at most 256 accepted guest TCP connections
and 256 concurrent requests; excess connections are closed immediately, so
idle sockets cannot bypass the request limit. The listener binds only host
loopback and is reverse-tunnelled
to exactly one guest — never a non-loopback interface, never the LAN. The host
starts the proxy only on a free port and sends the credential only after
confirming that the proxy is the port's sole listener; proxy and tunnel PIDs
are signalled only while they still name `iso-proxy` or `ssh`.

It is **jailed** by `sandbox-exec` using the checked-in Seatbelt profile, which
denies filesystem writes and program execution and limits outbound connections
to ports 443 and 53. Startup fails closed if these denials cannot be established.
The network rules are port-scoped; TLS verifies the fixed provider identity.
See [trust model](trust-model.md) for the accepted limitations.

## Platform support

The Swift proxy requires **macOS 27+** and the Apple sandbox backend. Linux
hosts are outside this fork’s support scope. GitHub
credentials are not supported by this proxy.

## Swift implementation

The sole implementation lives in `iso-proxy`. It uses macOS system trust
through Security.framework, including administrator/MDM-installed roots.
Hostname and full-chain verification are mandatory; the guest cannot disable
them or supply trust roots.

The proxy bounds the request target to 16 KiB and count its bytes
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
swift build --package-path iso-proxy
python3 scripts/test-swift-proxy-process.py
```

The gate also exercises stdin configuration, actual HTTP bind/accept, secret-free
argv/diagnostics, and shutdown with an open guest socket. `--skip-tls` runs only
the offline portions and cannot establish TLS readiness. Controlled certificate rejection tests are also available in the Swift test
suite. Remaining VM/live-agent and release validation is tracked in
[implementation evidence](design/swift-proxy-progress.md). Unexecuted gates
there remain open.

### Local builds and distribution

On Apple Silicon macOS 27+, the one release build entrypoint builds the host,
the Swift proxy, and the runtime together:

```sh
python3 scripts/build-release.py                  # unsigned development archive
python3 scripts/build-release.py --release --test # optimized, with every package's tests
```

The SwiftPM product is named `iso-proxy-swift`; the archive installs it under
the stable `iso-proxy` name understood by existing updaters. The archive
`iso-<tag|revision>-aarch64-apple-darwin.tar.gz` holds `iso`, `iso-proxy`,
the ad-hoc signed `iso-sandbox`, LICENSE and BUILD.json (source revision and
binary digests), with a `SHA256SUMS` beside it. Local checksums do not
establish release provenance. Signing and notarization are a separate,
explicit `--sign` stage used by the **Release candidate** workflow, which
requires a clean exact revision, verifies binary signatures, and attests its
candidate archive.

The `chr33s/iso` release workflow requires tagged commits from `swift` and
packages the host, Swift proxy, and signed runtime together on macOS. Only
macOS 27+ Apple Silicon hosts are supported. Installer and updater provenance
checks pin `chr33s/iso`. Archives must include both companions; missing
companions or obsolete `iso-proxy-rs`/`iso-proxy-swift` transition artifacts
are rejected before replacement. Verification precedes installation; companion
replacements precede the host replacement. Hosted candidate and release
verification remain pending.

The host resolves only the adjacent `iso-proxy` executable. There is no
implementation selector or fallback. Missing binaries, confinement failures,
and failed readiness abort proxy startup. The child receives an empty
environment; credentials enter over stdin.
