# Authorization policy

`policy` is an optional, default-deny layer over three operations. It can only
narrow what iso already allows: it never replaces VM isolation, the proxy
capability, operation allowlists, TLS checks, credential-forwarding limits,
session expiry, or the staged-return filesystem checks. The engineering
contract is [`design/iso-policy.md`](design/iso-policy.md).

| Action | Resources | Enforced by |
|---|---|---|
| `credential.use` | `provider:anthropic`, `provider:openai` | the credential proxy, per request |
| `proxy.request` | `provider:anthropic`, `provider:openai` | the credential proxy, per request |
| `workspace.pull.apply` | `workspace:attached` | the host, at `iso pull --apply` |

## Configuring

```jsonc
{
  "security": { "preset": "provider-only" },
  "proxy": { "mode": "required", "anthropic": { "credential": "vault:anthropic", "auth": "api_key" } },
  "workspace": { "pull": { "mode": "stage" } },
  "policy": {
    "version": 1,
    "mode": "enforce",                 // "off", "shadow" or "enforce"
    "actions": ["credential.use", "proxy.request", "workspace.pull.apply"],
    "rules": [
      { "id": "use-anthropic", "effect": "permit", "action": "credential.use", "resources": ["provider:anthropic"] },
      { "id": "request-anthropic", "effect": "permit", "action": "proxy.request", "resources": ["provider:anthropic"] },
      { "id": "apply-attached-workspace", "effect": "permit", "action": "workspace.pull.apply", "resources": ["workspace:attached"] }
    ],
    "guards": [
      { "id": "anthropic-admission-limit", "action": "proxy.request", "resources": ["provider:anthropic"],
        "require": { "rate_limit": { "max_requests": 100, "within_seconds": 60 } } },
      { "id": "review-before-apply", "action": "workspace.pull.apply", "resources": ["workspace:attached"],
        "require": { "approval_within": { "seconds": 900 } } }
    ]
  }
}
```

- Only actions listed in `actions` are governed; anything else keeps its
  existing behavior and is reported as `not_governed`.
- A governed action needs a matching `permit` and no matching `forbid`. Rule
  order does not matter. Nothing matching means deny, so OpenAI above is
  denied without a catch-all `forbid` (which would also override permits).
- Every guard matching an action applies, whichever permit matched. Several
  rate guards must all have capacity; several approval guards must all be
  fresh.
- `instances` (optional, never empty) limits an entry to named instances.
  There are no wildcards, prefixes, expressions or `when` clauses. Unknown
  keys, `null`, fractional or exponent numbers, and duplicate keys are errors.

Bounds: 128 rules, 16 guards, IDs of 1–64 characters matching
`[a-z][a-z0-9._-]*` and unique across both lists, at most 64 instances per
entry, `max_requests` 1–10,000, `within_seconds` 1–3,600, `approval_within`
1–900 seconds, at most 4 rate guards per provider and instance, and 64 KiB of
canonical policy. `iso validate` checks all of it.

Enforcing `credential.use` or `proxy.request` requires `proxy.mode =
"required"` and is incompatible with `codex.auth = "chatgpt"`. Enforcing
`workspace.pull.apply` requires `workspace.pull.mode = "stage"`. iso refuses
the configuration rather than changing those settings for you.

## Modes

- `off`: the policy is validated, nothing is governed.
- `shadow`: existing behavior wins. The proxy logs hypothetical denials to
  `proxy-<provider>.log`, and staged applies record a hypothetical decision in
  the boundary audit. Nothing is prompted, minted, consumed or blocked.
- `enforce`: governed operations need both the existing checks and the policy.

## One policy per boot

The policy is fixed when a VM boots: `iso up` and `iso start` record an
immutable snapshot with a fresh epoch, digest and boot ID. Editing or
removing `policy` affects the next boot only; `iso policy show NAME [--json]`
shows the active snapshot and whether the configured one is pending.

A running instance that booted before policies existed has no snapshot.
Asking it for enforcement fails until it is restarted.

## Provider quotas

A rate guard counts requests **admitted** by the proxy in a sliding window
(an admission exactly `within_seconds` old has expired). An admitted request
stays counted even if its upload stalls, the client disconnects or the
provider fails. A denied request is never forwarded and never counted.

| Result | Guest sees |
|---|---|
| no permit, or a forbid | `403` |
| quota exhausted | `429` with `Retry-After` |
| policy state unusable | `503`; never a fallback forward |

Quotas live only in the proxy's memory and reset at each new boot; they are
not a billing limit or a cross-boot budget. Because restarting the proxy would
reset them, an enforcing boot never relaunches its proxy: if it dies, or
`iso model` re-applies agent configuration to a running instance, provider
access stays unavailable until the next `iso stop` / `iso start`. All guest
processes share their VM's quota.

## Approving a staged apply

With an `approval_within` guard, `iso pull NAME --apply` re-renders the exact
stage (summary, sensitive-path warnings, bounded text diffs) on the host
terminal and asks you to type the stage ID. Only that answer, typed at the
controlling terminal, approves it. `--force` (which still skips only the git
cleanliness check), piped input, environment variables and `--output json`
cannot approve; without a terminal the command fails with `approval_required`
and writes nothing.

The approval covers one attempt at one exact stage: its content hashes,
modes, link targets, the destination directory's identity and this boot's
epoch. It is used up before the first write, even if the apply then fails
partway (the partial result is reported, and a retry needs a new review). A
stage built in an earlier boot, a re-staged or modified stage, or a replaced
destination directory all need a fresh `iso pull --review`. A stopped VM's
latest stage can still be approved and applied.

Under enforcement only the instance's recorded workspace can be staged
(`--dir` naming another directory is refused), it must already exist, and
direct pulls are refused. Remote-host (`iso host`) client brokers and
workspace returns cannot be governed by an enforcing policy.

## Limits

- Quotas count requests **admitted** by the proxy, not successful responses,
  tokens or spend; they are not a billing limit.
- Quotas live in proxy memory and reset at every new VM boot; there is no
  cross-boot or cross-host budget.
- Enforcing boots trade proxy recovery for that bounded state: a dead or
  re-applied proxy is not relaunched until the next boot.
- Approvals need an inline confirmation at the host terminal for each apply;
  there is no approval token, background approver or unattended automation.
- The principal is the instance and boot. Agents inside one VM share its
  quota; the policy cannot tell them apart.
- Only traffic through the credential proxy is governed; this is not a
  network firewall (see `egress` for that).
- Remote-host (`iso host`) brokers and returns cannot be enforced.
- The policy digest identifies content; it is not a signature, and nothing
  here defends against the host administrator.

## Audit

The boundary audit (`iso audit NAME`) records `policy_boot`,
`policy_proxy_claim`, `policy_decision`, `approval_issued`,
`approval_consumed` and `pull_apply_partial` events with IDs, reasons and the
policy digest, never request content, secrets or approval contents. The
audit is diagnostic, not decision state, and losing it never changes a
decision.
