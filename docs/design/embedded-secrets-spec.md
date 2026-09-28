# Specification: Embedded Coop Secrets for the Swift 6 Port

**Status:** Approved implementation specification (2026-09-28)  
**Target:** `chr33s/coop` Swift 6 rewrite, macOS 27+, Apple Silicon  
**Primary goal:** provide local encrypted secret storage and `--env-file` resolution directly inside Coop, with no external `vault` executable or service  
**Password KDF:** scrypt only  
**Hardware factor:** Secure Enclave, directly integrated into Swift  
**Recovery model:** **No recovery path by design**

---

## 1. Executive decision

The Swift 6 Coop port SHALL include a small, local, single-user secret store derived from the useful local-security ideas in `chr33s/vault`, but it SHALL **not** port Vault's distributed replica format or general vault product.

The embedded implementation exists only to support:

1. storing local secrets required by Coop;
2. resolving secret references from `--env-file` / `--env`;
3. supplying known model-provider credentials directly to `coop-proxy` without exposing those credentials to the guest;
4. supplying explicitly requested generic secrets to the guest environment;
5. basic local secret management (`init`, `set`, `rm`, `list`).

The implementation is intentionally:

- single-host;
- single-user;
- local-only;
- no-sync;
- no-sharing;
- no-relay;
- no-CRDT;
- no-auth-log;
- no-device enrollment;
- no-recovery escrow;
- no-recovery key;
- no-cross-device recovery;
- no-rotation DAG;
- no asymmetric identity/signature scheme;
- no external Vault runtime.

The local secret store SHALL require both:

```text
user passphrase
+
this Mac's Secure Enclave key
```

to decrypt.

Loss of the Secure Enclave key SHALL make the store permanently unrecoverable.

That consequence is **explicitly accepted by design**.

## 1.1 Baseline: what coop already has

This specification extends the current `swift` branch; it does not replace it.
Relevant existing pieces:

| Existing piece | Where | Role today |
|---|---|---|
| `Secret<Value>` redacted wrapper | `Sources/CoopCore/Units.swift` | Redacted description/debug rendering for secret values |
| `AtomicFile` | `Sources/CoopHost/AtomicFile.swift` | Temp-file + rename writes with bounded mode |
| `FileLock` | `Sources/CoopHost/FileLock.swift` | Advisory state locks |
| `SecretStore` (enum) | `Sources/CoopHost/SecretStore.swift` | macOS Keychain service names for `coop proxy setup` and `coop github setup-pat` |
| `cmd:` references | `CredentialResolver.swift` | Structured credential fields (`proxy.<provider>.credential`, per-VM `proxy.json` overrides, `github.pat`, `claude.api_key`) run a host command on use |
| `coop-proxy` stdin startup document (protocol v1) | `ProxyLifecycle.swift` | Provider credential reaches the proxy on stdin; the proxy child has an empty environment |
| `GuestEnvState` | `<instance>/guest_env.json` | Start-time `--env` / devcontainer `containerEnv` literals, overlaid on every later session |
| `env_forward`, automatic `ANTHROPIC_API_KEY` / `GITHUB_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` forwarding | `GuestSession.swift` | Raw values over SSH `SendEnv` when the proxy is off for that provider |

Configuration is JSONC (`~/.coop/config.jsonc`); coop state lives under the data
root `~/.coop`. Examples in this document use those formats.

---

# 2. Security model

## 2.1 Trusted

Trusted:

- macOS kernel;
- the logged-in host user;
- this Mac's Secure Enclave;
- Coop's signed binaries;
- Coop's host-side state directory;
- Swift Crypto / CryptoKit implementation;
- macOS filesystem permissions;
- `coop-proxy` as specified separately.

## 2.2 Untrusted

Untrusted:

- the entire guest VM;
- coding agents in the guest;
- project files copied from the guest;
- `.env` contents supplied by a project;
- command-line inputs;
- malformed or tampered Coop secret-store files.

## 2.3 Protected assets

Protected assets:

- secret values stored in Coop's encrypted local store;
- secret-store passphrase;
- model-provider credentials resolved for `coop-proxy`.

The encrypted store protects primarily against:

- offline disk theft;
- backup exposure;
- accidental plaintext persistence;
- passphrase-only offline brute-force attacks when the attacker does not possess the original device's usable Secure Enclave key.

It does **not** protect against:

- a compromised live host account;
- a process debugger attached with sufficient host privileges;
- malware running as the trusted host user while the user authorizes Secure Enclave access;
- a malicious or compromised macOS kernel;
- secrets already injected into a running guest environment;
- provider credentials already loaded into a running `coop-proxy`.

---

# 3. Explicit non-recovery decision

## D-001 — No recovery path

**Decision: APPROVED**

The Coop secret store SHALL NOT implement:

- a recovery key;
- cloud escrow;
- password-only fallback;
- device-to-device recovery;
- exported master key;
- backup unlock secret;
- alternate wrapping key.

The store is cryptographically bound to the Secure Enclave key created on the Mac where `coop secrets init` is performed.

If that key becomes unavailable, the encrypted secret store is unrecoverable.

### Events that can permanently destroy access

Examples include:

- Mac hardware replacement;
- motherboard / Secure Enclave failure;
- erasing or reinstalling the Mac in a way that destroys the key material;
- loss/corruption/deletion of the Secure Enclave opaque key representation;
- deleting the Coop Secure Enclave key state;
- restoring only `store.v1.json` from backup without the original usable enclave key state.

### Accepted operational consequence

A backup of:

```text
store.v1.json
```

alone is **not sufficient** to recover secrets on another Mac.

This is intentional.

The design prioritizes:

```text
strong device binding
over
recoverability
```

### Required documentation

`coop secrets init` MUST display a clear warning before creating the store:

```text
This secret store is bound to this Mac's Secure Enclave.

There is no recovery key or password-only fallback.
If this Mac, its Secure Enclave key, or Coop's enclave key state is lost,
the stored secrets cannot be recovered.

Keep independent copies of important credentials with their original providers.
```

Initialization requires an explicit confirmation.

For non-interactive creation, a future automation path MUST require an explicit acknowledgment flag such as:

```text
--accept-no-recovery
```

There is no default silent acceptance.

---

# 4. What is ported from Vault conceptually

Port only the following ideas/behaviors.

## 4.1 Keep

- memory-hard password derivation;
- random per-store salt;
- HKDF key separation;
- AES-256-GCM authenticated encryption;
- Secure Enclave device binding;
- user-presence authorization;
- owner-only state directories/files;
- atomic writes;
- secret-aware diagnostic types;
- strict dotenv parsing;
- whole-value secret references;
- fail-closed unresolved secret handling;
- provider credentials kept out of the guest when Coop knows the protocol.

## 4.2 Do not port

No Vault code is reused. Vault's sync, sharing, enrollment, recovery, auth log,
CRDT/rotation machinery, its own proxy, and non-macOS keystores are all out of
scope (see §56).

The Secure Enclave logic is implemented directly in Swift inside Coop.

---

# 5. Compatibility decision

## D-002 — existing Vault databases are not runtime-compatible

**Decision: APPROVED**

The embedded Coop secret store SHALL use a new compact format and SHALL NOT directly read existing `chr33s/vault` SQLite replicas.

Rationale:

Preserving Vault format compatibility would require substantial portions of:

- auth-log replay;
- rotation validation;
- X25519 grants;
- Ed25519 signatures;
- CRDT materialization;
- SQLite state;
- migration code.

That would defeat the "only code required by Coop" objective.

A one-time migration/import tool MAY be implemented separately if required. It is not part of this specification.

## D-003 — Relationship to the Keychain and `cmd:` references

**Decision: APPROVED 2026-09-28**

The enclave store is an **additional built-in reference source**, not a
replacement for existing credential sources.

1. `cmd:` references remain valid everywhere they are accepted today, with
   unchanged semantics.
2. The macOS Keychain remains the store written by `coop proxy setup` and
   `coop github setup-pat` in v1. Those commands are not changed by this
   specification.
3. Structured credential fields that accept `cmd:` today
   (`proxy.<provider>.credential`, per-VM `proxy.json` overrides, `github.pat`,
   `claude.api_key`) additionally accept `vault:<secret-name>`, resolved by
   `CredentialResolver` through `CoopSecrets`. A literal value remains rejected
   wherever it is rejected today.
4. `.env` files and `--env` values use the whole-value `{vault:<secret-name>}`
   form (§27).
5. All `vault:` / `{vault:}` references needed by one command are resolved in
   a single unlock (§33), regardless of which field they came from.
6. Moving existing Keychain items into the enclave store is out of scope; a
   later `coop secrets import --from-keychain` MAY be specified separately.

Provider-credential precedence per (instance, provider) becomes:

```text
.env / --env provider-secret declaration (§31)
  > per-VM proxy.json override
  > config proxy.<provider> default
  > off
```

A provider-secret declaration therefore also enables the proxy for that
provider on that instance.

---

# 6. Swift package architecture

Module layout follows the existing package (`CoopCLI` → `CoopHost` →
`CoopConfiguration` / `CoopCore`). Add one library target:

```text
Sources/
  CoopSecrets/                 # depends on CoopCore only
    SecretName.swift
    KDF.swift
    SecureEnclaveFactor.swift
    StoreFormat.swift
    EnclaveStore.swift         # the store actor (§44)
    EnvFile.swift              # .env parser (§26)
    SecretReference.swift      # {vault:name} / vault:name
    SecretResolver.swift

  CoopCLI/
    SecretsCommands.swift      # coop secrets init|set|rm|list|status

  CoopHost/
    CredentialResolver.swift   # + vault: references
    GuestEnvState.swift        # + typed declarations (§28)
    ProxyLifecycle.swift       # unchanged wire protocol; new credential source
```

Naming: the store type is `EnclaveStore`. The existing `SecretStore` enum
(Keychain service names) keeps its name.

Reuse, do not duplicate:

- `Secret<Value>` (`CoopCore/Units.swift`) is the redacted value type (§36).
- `AtomicFile` and `FileLock` are the write/lock primitives (§23). Because
  `CoopSecrets` must not depend on `CoopHost`, move both into `CoopCore` in a
  **separate preceding refactor PR** with no behavior change.

`coop-proxy/` (separate package) needs **no change**: its stdin startup
document already carries the credential (§34).

`CoopSecrets` SHOULD be usable from:

- the main Coop CLI;
- proxy-start orchestration;
- unit tests.

`CoopSecrets` MUST NOT depend on VM/runtime code.

---

# 7. Dependencies

The host package's only third-party dependency today is
`swift-argument-parser`. This specification adds **one** package, only for
scrypt:

```text
apple/swift-crypto 5.0.0 (exact)  →  product CryptoExtras  (KDF.Scrypt)
```

**Decision (2026-09-28):** use swift-crypto's scrypt rather than an in-house
implementation. On Darwin, `CryptoExtras` builds BoringSSL and depends on
`swift-asn1`; that supply-chain cost is accepted in exchange for a vetted,
optimized KDF (a slower hand-written scrypt would force a lower work factor
than attackers' tuned implementations).

Everything else comes from system frameworks already imported by `CoopHost`:

```text
CryptoKit:
  HKDF<SHA256>
  AES.GCM
  P256.KeyAgreement (software ephemeral key)
  SecureEnclave.P256.KeyAgreement.PrivateKey
LocalAuthentication
Security
Foundation
```

Requirements:

- Depend only on `CryptoExtras`; do not use swift-crypto's `Crypto` product in
  place of CryptoKit.
- Pin with `exact:` in `Package.swift` and commit `Package.resolved`
  (including the transitive `swift-asn1` pin).
- Record the pin in the closeout review as a supply-chain change.

No Argon2, SQLite, or third-party dotenv package is included.

---

# 8. Secret-store location

The store lives under coop's data root (`DataRoot`, default `~/.coop`),
alongside all other coop state:

```text
~/.coop/
  secrets/
    store.v1.json
    device.sekey
    store-duk.sealed
    store.lock
```

Permissions:

```text
~/.coop/          0700
secrets/          0700
store.v1.json     0600
device.sekey      0600
store-duk.sealed  0600
store.lock        0600
```

The implementation MUST verify all secret-state files are:

- regular files;
- owned by the current user;
- not group/world writable.

Unsafe ownership or permissions cause a fail-closed error.

---

# 9. Secure Enclave design

## 9.1 Purpose

Secure Enclave provides a device-bound second factor for unlocking the secret store.

The passphrase alone MUST NOT be sufficient.

## 9.2 Device key

Create one Secure Enclave P-256 key-agreement private key for Coop secrets.

Use access control equivalent to:

```text
kSecAttrAccessibleWhenUnlockedThisDeviceOnly
.privateKeyUsage
.userPresence
```

The private key is non-exportable.

Persist CryptoKit's opaque `dataRepresentation` as:

```text
device.sekey
```

The representation is not the private key itself and is only usable with the originating Secure Enclave.

## 9.3 Device Unlock Key

At initialization:

```text
DUK = CSPRNG(32 bytes)
```

The DUK is random and independent of the user passphrase.

Seal the DUK to the Secure Enclave public key.

Persist:

```text
store-duk.sealed
```

## 9.4 DUK sealing format

Use:

```text
ephemeral P-256 key agreement
ECDH
HKDF-SHA256
AES-256-GCM
```

Conceptually:

```text
ephemeralPrivate = random P-256 key
shared = ECDH(ephemeralPrivate, enclavePublic)
wrapKey = HKDF-SHA256(
    shared,
    salt = ephemeralPublicBytes,
    info = "coop/secrets/enclave-duk/v1"
)
sealedDUK = AES-GCM(wrapKey, DUK)
```

Store:

```text
ephemeralPublic || nonce || ciphertext || tag
```

The exact encoding MUST be versioned and test-vector locked.

## 9.5 Unseal

To unlock:

1. construct `LAContext`;
2. set a user-facing reason such as:
   ```text
   Unlock Coop secrets
   ```
3. load the existing Secure Enclave private key;
4. perform ECDH using the stored ephemeral public key;
5. user presence is required by the private-key operation;
6. derive wrapping key;
7. AES-GCM decrypt the DUK.

Never create a new Secure Enclave key during an unlock attempt.

If the stored key is missing/unreadable:

```text
fatal: Coop secrets Secure Enclave key is unavailable; this store cannot be recovered
```

Do not silently regenerate.

## 9.6 Code-signing prerequisite

Development and default release archives ship an ad-hoc-signed `coop`; only
the `--sign` release-candidate stage produces a Developer ID signature.

Before implementation proceeds past a prototype, verify on macOS 27+ Apple
Silicon that Secure Enclave key creation, `dataRepresentation` reload, and
user-presence-gated key agreement all work from:

1. a `swift build` debug binary;
2. an unsigned/ad-hoc `scripts/build-release.py` archive;
3. a `--sign` release-candidate archive.

Also verify that a key created by one of these builds remains usable after
upgrading to the next (the key must not be bound to a code-signing identity
that changes between releases). If any case fails, record the constraint and
the supported build types here before continuing; a store that becomes
unreadable on `coop update` is a release blocker, not an accepted loss event.

**Spike result (2026-09-28, macOS 27, Apple Silicon):** a
`SecureEnclave.P256.KeyAgreement` key (`.privateKeyUsage`, optionally
`.userPresence`, `WhenUnlockedThisDeviceOnly`) created by an ad-hoc-signed
`swiftc` binary was reloaded from `dataRepresentation` and used for ECDH by a
second ad-hoc binary with a different cdhash and by a Developer ID-signed,
hardened-runtime binary. No keychain entitlement was needed. With
`.userPresence`, every use showed a Touch ID prompt. The key is not bound to
the signing identity, so `coop update` does not strand it. The cancel path is
still unverified and stays in the §48 hardware tests.

## 9.7 Corrupted key representation

The same spike found that `SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation:)`
**traps the process** (a `try!` inside CryptoKit, `CryptoKitError.invalidParameter`)
when `device.sekey` is corrupted, instead of throwing. coop MUST therefore not
hand unverified bytes to that initializer:

- `device.sekey` is stored in a small versioned envelope containing the
  representation and its SHA-256;
- the envelope, length bounds, and digest are checked before calling CryptoKit;
- a mismatch fails with the permanent `enclaveKeyUnavailable` error (§35).

This guards against accidental corruption (disk, partial restore). A same-user
attacker who can rewrite the file can also recompute the digest; that attacker
is out of scope (§2.3).

---

# 10. Store format

Use one whole-store encrypted envelope.

Example outer JSON:

```json
{
  "format": "coop-secrets",
  "version": 1,
  "kdf": {
    "algorithm": "scrypt",
    "salt": "<base64>",
    "N": 131072,
    "r": 8,
    "p": 1
  },
  "cipher": {
    "algorithm": "aes-256-gcm",
    "nonce": "<base64>",
    "ciphertext": "<base64>",
    "tag": "<base64>"
  }
}
```

The outer structure contains no secret names or values.

Encrypted plaintext:

```json
{
  "version": 1,
  "entries": {
    "anthropic": {
      "value": "<base64 bytes>",
      "created_at": "2026-09-27T00:00:00Z",
      "updated_at": "2026-09-27T00:00:00Z"
    }
  }
}
```

Secret names are encrypted along with values.

---

# 11. Secret names

Valid name grammar:

```text
[A-Za-z0-9][A-Za-z0-9._-]{0,127}
```

Maximum length:

```text
128 bytes ASCII
```

Reject:

- `/`;
- path traversal forms;
- whitespace;
- control characters;
- leading punctuation other than alphanumeric;
- Unicode in v1.

Secret names are identifiers, not filenames.

---

# 12. Secret values

Internally, values are bytes (`Data`).

Maximum:

```text
1 MiB
```

## Environment use

Resolved value MUST:

- be valid UTF-8;
- contain no NUL byte.

## Provider use

Resolved value MUST satisfy `coop-proxy` header-value validation.

Do not silently transform invalid bytes.

---

# 13. scrypt KDF

## 13.1 Algorithm

Only:

```text
scrypt
```

No Argon2id compatibility is implemented.

## 13.2 Default parameters

```text
N = 2^17 = 131072
r = 8
p = 1
outputByteCount = 32
salt = 16 random bytes
```

Benchmark before release on supported Apple Silicon hardware.

Do not reduce below this default without explicit security review.

## 13.3 Parameter validation

Reader accepts only bounded metadata:

```text
N is power-of-two
2^15 <= N <= 2^20
r == 8
p == 1
salt length 16..64 bytes
```

Reject unreasonable values before invoking scrypt.

---

# 14. Final store-key derivation

The secret store requires both:

```text
passphrase factor
+
Secure Enclave DUK
```

Derive:

```text
passwordKey = scrypt(passphrase, salt, N, r, p, 32)
```

Then:

```text
storeKey = HKDF-SHA256(
    inputKeyMaterial = passwordKey,
    salt = DUK,
    info = "coop/secrets/store-key/v1",
    output = 32
)
```

The DUK acts as an independent high-entropy device factor.

Neither:

```text
passwordKey
```

nor:

```text
DUK
```

alone is sufficient to decrypt the store.

---

# 15. AEAD

Use:

```text
AES-256-GCM
```

Each store rewrite gets a fresh random 12-byte nonce.

Authenticated additional data MUST bind:

```text
format
version
KDF algorithm
KDF parameters
KDF salt
```

Recommended canonical AAD:

```text
coop-secrets:v1:scrypt:<N>:<r>:<p>:<base64-salt>
```

No locale-dependent formatting.

---

# 16. Passphrase acquisition

## 16.1 Interactive default

Prompt securely through `/dev/tty`:

- no echo;
- not argv;
- not environment;
- not logs.

## 16.2 Automation

If required:

```text
COOP_SECRETS_PASSPHRASE_FD=<fd>
```

or equivalent internal fd-based input.

Do not support plaintext:

```text
--passphrase value
COOP_SECRETS_PASSPHRASE=value
```

in production.

`COOP_SECRETS_PASSPHRASE_FD` names a file descriptor, not a secret, but it is
new secret-input surface. It MUST be documented in `docs/trust-model.md`
alongside the existing "never on argv" rules (§55.1), and coop MUST:

- read the passphrase from that descriptor once and close it;
- refuse the descriptor if it refers to a regular file that is group- or
  world-readable;
- never forward the variable to guest-bound `ssh`/`scp`/`rsync`, runtime, or
  `coop-proxy` child processes.

---

# 17. Unlock sequence

Every store unlock:

```text
1. validate file ownership/permissions
2. parse and validate bounded outer format
3. prompt for passphrase
4. derive passwordKey with scrypt
5. load existing Secure Enclave key
6. request user presence
7. unseal DUK
8. HKDF(passwordKey, DUK) -> storeKey
9. AES-GCM authenticate/decrypt store
10. best-effort clear temporary factor buffers
```

If any step fails:

```text
unable to unlock Coop secrets store
```

except for the explicit unrecoverable-key case, which should state that the enclave key is unavailable and recovery is impossible.

---

# 18. Secret store lifecycle commands

Add:

```bash
coop secrets init
coop secrets set <name>
coop secrets rm <name>
coop secrets list
```

Optional:

```bash
coop secrets status
```

Do not include a default plaintext `get` command.

---

# 19. `coop secrets init`

Behavior:

1. refuse if store exists;
2. display the non-recovery warning;
3. require explicit confirmation;
4. prompt passphrase twice;
5. create random scrypt salt;
6. create Secure Enclave key;
7. create random 32-byte DUK;
8. seal DUK to enclave key;
9. derive store key from passphrase + DUK;
10. create empty AES-GCM encrypted store;
11. atomically persist all files with owner-only permissions;
12. verify a complete unlock before reporting success.

If verification fails, initialization fails and incomplete state is removed where safe.

---

# 20. `coop secrets set`

Example:

```bash
coop secrets set anthropic
```

Default input:

- secure terminal prompt.

Automation:

```bash
printf '%s' "$TOKEN" | coop secrets set anthropic --stdin
```

The secret never appears on argv.

Flow:

1. obtain exclusive store lock;
2. unlock once;
3. decrypt store;
4. set/replace entry;
5. fresh AEAD nonce;
6. atomic rewrite;
7. release lock.

---

# 21. `coop secrets rm`

```bash
coop secrets rm anthropic
```

- exclusive lock;
- unlock;
- delete;
- rewrite with fresh AEAD nonce.

Removal prevents future resolution.

It cannot erase a secret already loaded into an active proxy or guest process.

---

# 22. `coop secrets list`

Unlocks and prints names/metadata only.

Example:

```text
anthropic
database-password
openai
```

Never print values.

---

# 23. Concurrency and atomic writes

Use:

```text
store.lock
```

Mutation commands require exclusive lock.

Reads may use shared lock.

Write sequence:

```text
serialize new encrypted envelope
write temp file in same directory
chmod 0600
fsync temp where practical
atomic rename
fsync directory where practical
release lock
```

Never mutate the active store file in place.

---

# 24. Store limits

```text
encrypted store file: 16 MiB
entries:              4096
secret name:          128 bytes
secret value:         1 MiB
```

Fail closed beyond limits.

---

# 25. `--env-file`

Add:

```bash
coop up --env-file .env
coop start <instance> --env-file .env
```

Existing:

```bash
--env KEY=VALUE
```

remains supported.

v1 accepts one env file.

---

# 26. `.env` grammar

Supported:

```dotenv
KEY=value
KEY="value with spaces"
KEY='value with spaces'
export KEY=value
# comment
KEY=value # trailing comment
```

Keys:

```text
[A-Za-z_][A-Za-z0-9_]*
```

Do not:

- invoke a shell;
- execute `$()`;
- execute backticks;
- expand `$VAR`;
- support arbitrary interpolation;
- support multiline values.

Comment rule:

- a line whose first non-whitespace character is `#` is a comment;
- in an **unquoted** value, `#` starts a comment only when preceded by at
  least one space or tab; the value is the text before that whitespace, with
  trailing whitespace trimmed;
- a `#` not preceded by whitespace is part of the value
  (`URL=https://example.com/#frag` keeps `#frag`);
- inside single or double quotes, `#` is always literal; after the closing
  quote, only optional whitespace and an optional `# comment` may follow.

Malformed declarations fail loudly.

---

# 27. Secret reference syntax

Canonical syntax:

```dotenv
SECRET={vault:secret}
```

Grammar:

```text
{vault:<secret-name>}
```

Examples:

```dotenv
DATABASE_PASSWORD={vault:database-password}
ANTHROPIC_API_KEY={vault:anthropic}
OPENAI_API_KEY={vault:openai}
```

## Whole-value only

Allowed:

```dotenv
TOKEN={vault:token}
```

Rejected:

```dotenv
URL=postgres://user:{vault:password}@host/db
TOKEN=prefix-{vault:secret}
```

No interpolation engine in v1.

---

# 28. Environment declaration persistence

Persist typed declarations, never resolved secrets.

### Migration from the current `guest_env.json`

Today `<instance>/guest_env.json` is unversioned and holds only literal string
values (`GuestEnvState`). Treat that shape as **version 1**:

- readers accept both version 1 (no `version` field, string values) and
  version 2 (below);
- a version-1 file is upgraded to version 2 in memory, every entry becoming
  `kind: "literal"`;
- coop writes version 2 only when the instance has at least one non-literal
  declaration, so instances that never use references stay readable by older
  coop binaries;
- an older binary that meets a version-2 file MUST fail with a clear
  "written by a newer coop" error rather than misreading it (add this check to
  the last release before this feature ships, or document that downgrading an
  instance that used references is unsupported).

Version 2 example:

```json
{
  "version": 2,
  "entries": {
    "NOT_SECRET": {
      "kind": "literal",
      "value": "not-secret"
    },
    "SECRET": {
      "kind": "secret",
      "name": "secret"
    },
    "ANTHROPIC_API_KEY": {
      "kind": "provider_secret",
      "provider": "anthropic",
      "injection": "x_api_key",
      "name": "anthropic"
    }
  }
}
```

Resolved plaintext MUST NOT be written to Coop instance state.

---

# 29. Precedence

Insert `--env-file` into the existing documented order without changing the
relative order of existing sources:

```text
config guest_env
  <
forwarded values (env_forward, automatic forwards)
  <
devcontainer containerEnv
  <
--env-file
  <
CLI --env
```

Explicit CLI `--env` wins, as documented today ("Overrides `guest_env` config
entries and any forwarded values with the same name"). If the current code
orders any existing pair differently from this diagram, the code's order is
authoritative and this diagram must be corrected rather than the behavior.

Provider-secret declarations (§31) do not take part in guest-env precedence:
they never produce a guest variable.

---

# 30. Generic guest secrets

Example:

```dotenv
DATABASE_PASSWORD={vault:database-password}
```

Flow:

```text
Coop secret store
   |
   v
Coop
   |
   v
guest environment
```

The plaintext is intentionally visible in the guest.

Documentation MUST say so explicitly.

Secure Enclave protects the value at rest on the host; it does not keep generic environment secrets hidden from the guest after injection.

---

# 31. Provider proxy secrets

Recognized variables and mappings:

```text
ANTHROPIC_API_KEY        -> anthropic / x_api_key
ANTHROPIC_AUTH_TOKEN     -> anthropic / bearer
CLAUDE_CODE_OAUTH_TOKEN  -> anthropic / bearer   (a `claude setup-token` value)
OPENAI_API_KEY           -> openai / bearer
```

`ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` map to the same
(provider, scheme); declaring both for one instance is an error.

## 31.1 Definition: recognized provider secret

This definition is normative for this specification and for the Selective
Hardening specification.

A **recognized provider secret** is a declaration whose variable name is in the
table above **and** whose value is a `{vault:<name>}` reference, from either
`--env-file` or `--env`. Equivalently, a structured proxy credential field set
to `vault:<name>` (D-003).

A recognized provider secret:

- is persisted only as a `provider_secret` declaration (§28);
- is delivered only to `coop-proxy` (§34);
- NEVER becomes a guest environment variable, under any proxy mode, and is
  never reinterpreted as a generic secret or literal;
- fails startup if the proxy for its provider cannot start (§35).

## 31.2 Legacy provider values

A **legacy provider value** is any other source of a recognized variable name:
a literal in `.env` / `--env` / `guest_env`, an `env_forward` entry, or the
automatic host-environment forward of `ANTHROPIC_API_KEY` /
`CLAUDE_CODE_OAUTH_TOKEN`.

Legacy values keep today's behavior so existing configurations do not change
meaning:

- if a proxy is active for that provider, the value is suppressed (not
  forwarded) with a warning — unchanged;
- if no proxy is active for that provider, the value is forwarded raw over
  `SendEnv` as today, and coop SHOULD print a one-line warning pointing at
  `coop secrets` / `coop proxy setup`.

Tightening legacy values (refusing raw forwarding) is governed by the Selective
Hardening specification's `proxy.mode = "required"` and by a future
default change with release notes; it is not done implicitly here.

---

# 32. Provider literal safety

If a proxy is active for a provider:

```dotenv
ANTHROPIC_API_KEY=plaintext
```

MUST NOT result in raw guest forwarding (§31.2).

Retain the existing suppression/warning behavior.

---

# 33. Resolution timing

## Start/restart

If references exist:

1. prompt once for passphrase;
2. prompt once for Secure Enclave user presence;
3. unlock store once;
4. batch resolve all required entries;
5. configure generic guest env and provider proxy;
6. release decrypted store object as soon as practical.

## Later `exec` / shell / agent commands

## D-004 — Per-session unlock for generic secrets

**Decision: APPROVED 2026-09-28 (deliberate UX cost)**

`GuestEnvState` overlays the start-time environment onto **every** later
session of an instance (`coop shell`, `coop exec`, agent launches). Because
only references are persisted, any session of an instance with generic
`{vault:}` declarations must resolve them again, which requires:

```text
passphrase + Secure Enclave user presence
```

on every such invocation.

Provider secrets do **not** cause this: the running `coop-proxy` already holds
the credential for the VM's lifetime, and later sessions need only the
capability token.

This cost is accepted in v1. No long-lived secret daemon or unlocked cache is
introduced.

Alternatives considered and deferred:

- **Write resolved generic secrets into the guest once at start** (owner-only
  file in the guest, sourced by sessions). Generic secrets are guest-visible by
  design, so this does not weaken the guest boundary and removes repeat
  prompts, but it adds guest-disk persistence and changes the session overlay
  mechanism. Revisit if v1 prompting proves unworkable.
- **Host-side unlocked cache with a timeout.** Rejected: reintroduces a
  plaintext-holding daemon.

---

# 34. `coop-proxy` integration

Provider flow:

```text
CoopSecrets
    |
    | plaintext exists in trusted Coop host process
    v
coop launcher (ProxyLauncher.start)
    |
    | stdin startup document, protocol v1 (existing)
    v
coop-proxy
    |
    | HTTPS
    v
Anthropic / OpenAI
```

This path already exists: `ProxyLauncher.start` resolves the credential, sends
it in the stdin startup document only after confirming the proxy is the port's
sole listener, and the proxy child runs with an empty environment. The only
change is a new credential source feeding `resolver.resolve`; the wire protocol
and `coop-proxy` package are unchanged.

The provider credential MUST NOT appear:

- in proxy argv;
- in proxy environment;
- in guest state;
- in guest env;
- in logs.

---

# 35. Failure semantics

## Missing generic secret

Fail command:

```text
unable to resolve required secret 'database-password'
```

Do not substitute empty string.

## Missing provider secret

Fail proxy/VM/agent startup.

No fallback to raw forwarding.

## Secure Enclave key missing

Fail with a distinct permanent error:

```text
Coop secrets cannot be unlocked because the Secure Enclave key for this store
is unavailable.

This store has no recovery path.
Restore the original device/key state or recreate the secret store.
```

Do not create a new key.

---

# 36. Logging and secret types

Use the existing `Secret<Value>` wrapper (`CoopCore/Units.swift`) for resolved
values — `Secret<[UInt8]>` for store values, `Secret<String>` once validated for
environment/header use. Do not add a parallel `SecretValue` type.

`Secret<Value>` already provides, and MUST continue to provide:

- debug rendering = `<redacted>`;
- no public plaintext `description`;
- no automatic Codable plaintext serialization;
- explicit accessors (`expose()`).

Passphrases use the same wrapper (`Secret<[UInt8]>`) so the redaction rules
apply uniformly.

Allowed:

```text
resolved secret reference for DATABASE_PASSWORD
configured Anthropic proxy from stored secret
```

Never log resolved values.

---

# 37. Memory hygiene

Best-effort:

- keep passphrase and DUK in mutable buffers;
- clear temporary buffers after derivation;
- release decrypted dictionary after use;
- use `RLIMIT_CORE=0` for secret-bearing Coop/proxy processes where practical;
- never create plaintext temp files.

No claim of guaranteed memory zeroization.

---

# 38. No recovery files

The implementation MUST NOT create or expose:

```text
recovery.key
master.key
exported DUK
unencrypted backup key
password-only fallback wrapper
```

No hidden fallback may be added for convenience.

Any future recovery mechanism requires a new design decision and migration format version.

---

# 39. No secret sync

No:

```text
relay
Cloudflare
Tailscale
peer sync
iCloud sync
```

The store is local to this Mac.

Encrypted filesystem backups are permitted, but are only useful when the original Secure Enclave key state remains usable.

---

# 40. No multi-user sharing

No:

```text
users
roles
admins
devices
invites
grants
recovery escrow
```

One local macOS account owns the store.

---

# 41. No CRDT / operation log

Secret mutation rewrites the encrypted dictionary.

No:

```text
HLC
MV registers
tombstones
signed operations
```

---

# 42. Crypto surface

The v1 embedded store requires:

```text
CSPRNG
scrypt
HKDF-SHA256
AES-256-GCM
P-256 ECDH for Secure Enclave DUK sealing
```

No:

```text
X25519
Ed25519
certificates
PKI
```

---

# 43. Legacy migration

Existing Vault compatibility is not part of production Coop.

If migration is needed, provide a one-time external path such as:

```bash
vault export-coop-secrets | coop secrets import --stdin
```

No plaintext intermediate file.

Do not add legacy Vault database parsing to production Coop.

---

# 44. Suggested Swift APIs

```swift
public enum NoRecoveryAcknowledgement: Sendable { case accepted }

public actor EnclaveStore {
    func initialize(
        passphrase: Secret<[UInt8]>,
        acknowledgement: NoRecoveryAcknowledgement
    ) async throws(EnclaveStoreError)

    func set(
        _ name: SecretName,
        value: Secret<[UInt8]>,
        passphrase: Secret<[UInt8]>
    ) async throws(EnclaveStoreError)

    func remove(
        _ name: SecretName,
        passphrase: Secret<[UInt8]>
    ) async throws(EnclaveStoreError)

    func list(
        passphrase: Secret<[UInt8]>
    ) async throws(EnclaveStoreError) -> [SecretMetadata]

    func resolve(
        _ names: Set<SecretName>,
        passphrase: Secret<[UInt8]>
    ) async throws(EnclaveStoreError) -> [SecretName: Secret<[UInt8]>]
}
```

`EnclaveStoreError` is a closed enum (typed throws, per `docs/code-style.md`)
with a distinct `enclaveKeyUnavailable` case for the permanent-loss error
(§35). The no-recovery acknowledgement is a type, not a `Bool`.

Secure Enclave user-presence interaction occurs internally during unlock.

Batch resolution ensures one:

```text
scrypt derivation
+
Secure Enclave authorization
```

per invocation rather than per secret.

---

# 45. Approximate implementation size

Estimated production Swift:

| Component | Estimated LOC |
|---|---:|
| Secret/redacted value types | 80–140 |
| scrypt + HKDF + AES-GCM | 100–180 |
| Secure Enclave factor | 140–220 |
| Store envelope + validation | 120–180 |
| Atomic file / permissions / lock | 100–180 |
| Store CRUD | 180–280 |
| dotenv parser | 80–130 |
| `{vault:name}` parser | 40–70 |
| env resolution / provider routing | 150–250 |
| CLI `secrets` commands | 180–280 |
| lifecycle integration | 150–300 |
| **Total** | **~1,320–2,210 LOC** |

Tests:

```text
~1,500–2,400 LOC
```

---

# 46. Test vectors

Maintain deterministic vectors for:

## scrypt

```text
password
salt
N/r/p
expected 32-byte output
```

## HKDF store key

Fixed:

```text
passwordKey
DUK
info
```

-> expected `storeKey`.

## DUK sealing

Use a software P-256 test key for deterministic tests of the seal format.

Real Secure Enclave tests run on hardware separately.

## AES-GCM store envelope

Fixed key/nonce/plaintext/AAD fixture.

---

# 47. Unit tests

Test:

- secret-name grammar;
- store format bounds;
- invalid KDF params;
- malformed base64;
- wrong passphrase;
- wrong DUK;
- corrupt ciphertext;
- corrupt DUK blob;
- missing enclave key;
- fresh rewrite produces new nonce;
- set/replace/remove/list;
- concurrency lock.

---

# 48. Secure Enclave hardware tests

On Apple Silicon:

1. initialize store;
2. confirm user-presence prompt;
3. unlock succeeds;
4. cancel prompt -> unlock fails;
5. copy encrypted store without enclave state -> cannot unlock;
6. replace `device.sekey` -> cannot unlock;
7. delete `device.sekey` -> permanent unrecoverable error;
8. ensure unlock does not mint a replacement key.

The test must explicitly validate the no-recovery property.

---

# 49. `.env` parser tests

Support and test:

```dotenv
A=x
B="x y"
C='x # y'
export D=z
E=x # comment
```

Reject malformed keys.

Shell syntax is never executed.

---

# 50. Secret-reference tests

Valid:

```dotenv
SECRET={vault:secret}
```

Reject:

```dotenv
SECRET={vault:}
SECRET={vault:../../x}
SECRET=prefix-{vault:secret}
SECRET={vault:secret}-suffix
```

---

# 51. Provider-routing tests

Given:

```dotenv
ANTHROPIC_API_KEY={vault:anthropic}
```

assert:

- raw key absent from guest env;
- raw key absent from guest disk;
- proxy receives value;
- guest receives only proxy capability/config.

Likewise:

```dotenv
ANTHROPIC_AUTH_TOKEN={vault:anthropic-setup}
OPENAI_API_KEY={vault:openai}
```

---

# 52. Persistence tests

Use canary values and scan:

```text
instance state
logs
workspace metadata
proxy state
guest disk
```

Provider credentials must never appear.

Generic environment secrets may appear in the guest by design but must not appear in host persisted declaration state.

---

# 53. End-to-end real-hardware test

On macOS 27+ Apple Silicon:

1. `coop secrets init`;
2. accept the no-recovery warning;
3. set:
   ```text
   generic
   anthropic
   openai
   ```
4. create:
   ```dotenv
   GENERIC={vault:generic}
   ANTHROPIC_API_KEY={vault:anthropic}
   OPENAI_API_KEY={vault:openai}
   ```
5. run:
   ```bash
   coop up --env-file .env
   ```
6. assert:
   - passphrase + Secure Enclave authorization required;
   - `GENERIC` is visible in guest;
   - Anthropic/OpenAI keys are not;
   - proxy can use provider credentials;
   - state persists only references;
   - restart requires successful secret-store unlock;
   - user-presence cancellation fails closed.

---

# 54. Destructive-loss test

This is a required acceptance test because non-recovery is a deliberate product property.

Test:

1. initialize store;
2. add known secret;
3. verify unlock;
4. securely copy encrypted store for test;
5. delete/replace Secure Enclave key state;
6. attempt unlock;
7. verify:
   ```text
   unlock fails permanently
   no fallback is offered
   no new key is minted
   no password-only path exists
   ```

Documentation and CLI error text must match this behavior.

---

# 55. Security review checklist

Before release:

- [ ] no-recovery decision documented prominently;
- [ ] init requires explicit acknowledgment;
- [ ] unlock never regenerates enclave key;
- [ ] DUK is random 256-bit;
- [ ] DUK only persisted encrypted;
- [ ] Secure Enclave key requires user presence;
- [ ] `WhenUnlockedThisDeviceOnly` semantics used;
- [ ] scrypt bounds reviewed;
- [ ] passphrase never argv/env/logged;
- [ ] permissions fail closed;
- [ ] atomic rewrite crash-tested;
- [ ] tampered store fails authentication;
- [ ] resolved values never persisted in Coop state;
- [ ] provider credentials never enter guest;
- [ ] generic secrets clearly documented as guest-visible;
- [ ] env parser never executes shell;
- [ ] unresolved refs fail closed;
- [ ] proxy fallback cannot expose provider credential;
- [ ] core-dump posture reviewed;
- [ ] destructive-loss/non-recovery test passes;
- [ ] Secure Enclave works on every supported build type and survives `coop update` (§9.6);
- [ ] `guest_env.json` v1 → v2 migration and downgrade behavior tested (§28).

## 55.1 Cross-file updates

Keep these in sync in the same PR series (per `AGENTS.md`):

- `docs/trust-model.md`: the enclave store as a new host secret source;
  `COOP_SECRETS_PASSPHRASE_FD` under "Never on argv"; recognized provider
  secrets (§31.1) never enter the guest; generic `{vault:}` secrets are
  guest-visible.
- `docs/configuration.md`, `config.example.jsonc`, `ConfigTemplate`: `vault:`
  on structured credential fields.
- `docs/commands.md`, CLI surface baselines: `coop secrets …`, `--env-file`.
- `docs/credential-proxy.md`: the new credential source and precedence (D-003).
- `scripts/swift-host-fault-injection.py`: faults that (a) forward a
  recognized provider secret into guest env, (b) persist a resolved value in
  `guest_env.json`, (c) mint a new enclave key on unlock — each detected by a
  test.

---

# 56. Non-goals

Not in v1:

- existing `chr33s/vault` database compatibility;
- Argon2id;
- PBKDF2;
- recovery key;
- password-only fallback;
- Secure Enclave migration to another Mac;
- Keychain fallback;
- secret synchronization;
- sharing;
- device enrollment;
- recovery escrow;
- secret version history;
- CRDT;
- per-secret ACLs;
- networked secret service;
- generic HTTP secret injection;
- arbitrary template interpolation;
- automatic provider-secret rotation.

---

# 57. User-facing examples

## Initialize

```bash
coop secrets init
```

Required warning:

```text
WARNING: Coop secrets are bound to this Mac's Secure Enclave.

There is no recovery key and no password-only fallback.

If this Mac or the Secure Enclave key is lost, these secrets cannot be
recovered, even if you know the passphrase or have a copy of the encrypted
store.

Keep independent copies of critical credentials with their original provider.

Continue? [y/N]
```

## Add secrets

```bash
coop secrets set anthropic
coop secrets set database-password
```

## Manifest

```dotenv
# Visible in guest:
DATABASE_PASSWORD={vault:database-password}

# Literal:
NODE_ENV=development

# Host-only through coop-proxy:
ANTHROPIC_API_KEY={vault:anthropic}
OPENAI_API_KEY={vault:openai}
```

## Start

```bash
coop up --env-file .env
```

---

# 58. Final architecture

```text
                        macOS HOST

               passphrase
                   |
                 scrypt
                   |
             passwordKey
                   |
                   +----------------+
                                    |
Secure Enclave                      |
  P-256 private key                 |
       |                            |
       | user presence              |
       v                            |
   unseal DUK ----------------------+
              |
              v
       HKDF(passwordKey, DUK)
              |
           storeKey
              |
         AES-256-GCM
              |
  ~/.coop/secrets/store.v1.json
              |
              v
         CoopSecrets
          /       \
 generic env     provider credential
      |                  |
      v                  v
   guest env         coop-proxy
                          |
                          v
                   Anthropic/OpenAI
```

Recovery path:

```text
none
```

If the Secure Enclave key is lost:

```text
store is permanently unreadable
```

This is intentional.

---

# 59. Acceptance definition

The embedded secrets feature is complete when Coop can:

```text
initialize a scrypt + Secure-Enclave-bound secret store
set/remove/list secrets
parse --env-file
resolve {vault:name}
persist only references
inject generic secrets into guest sessions
route provider secrets into coop-proxy
operate without any external vault executable/service
fail permanently when the original Secure Enclave key is lost
```

with the production cryptographic surface limited to:

```text
CSPRNG
scrypt
HKDF-SHA256
AES-256-GCM
P-256 ECDH via Secure Enclave
```

and with **no recovery mechanism by design**.
