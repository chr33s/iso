<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Code style

These are isolate's project-specific Swift conventions for the host package
(`Package.swift`, `Sources/`, `tests/swift/`, `fuzz/`) and the companion
packages (`iso-proxy/`, `iso-sandbox/`). The focus is on **using the type
system to eliminate error states**, not on formatting, which `swift format`
owns. The conventions and design lenses in the shared
[`review`](../.agents/skills/review/SKILL.md) workflow enforce these; the
[architecture doc](ARCHITECTURE.md) shows where the patterns already live.

Apply these patterns when they pay for themselves; skip them when a primitive is
genuinely fine. A type system that fights the reader is worse than one that lets
a bug through.

## Toolchain and formatting

- Swift 6 language mode (`swiftLanguageModes: [.v6]`), strict concurrency, the
  pinned Xcode toolchain, macOS 27 deployment target.
- Commit every `Package.resolved`; build and test with
  `--force-resolved-versions` so an unexpected resolution change fails.
  Add a dependency only with a reviewed reason; the host depends only on
  Swift Argument Parser and swift-crypto (`CryptoExtras`, for scrypt).
- `swift format lint --strict` must be clean for every package:

  ```sh
  swift format lint --strict -r Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints
  swift format lint --recursive --strict iso-proxy/Sources iso-proxy/Tests
  ```

- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`/`#require`).
- Keep module boundaries: `IsoCore` has no subprocess or network side
  effects, and its only filesystem mutation is the shared state-write
  primitives (`AtomicFile`, `FileLock`); `IsoConfiguration` has no subprocesses and no TOML or
  configuration-provider dependency; side effects live in `IsoHost`;
  `IsoCLI` stays a thin layer of parsing, dispatch and presentation.

## Lean on the type system before lean on validation

The default move when you see a bug is to add a runtime check. The better move
is usually to change a type so the bug cannot be expressed. Before writing a
check or throwing an error, ask: *can the function signature make this case
unreachable?*

- **Parse, don't validate.** A function that takes a `String` and returns an
  `InstanceName` (or throws) is better than one that takes a validated
  `String` by convention. Convert untrusted input — CLI arguments, configuration,
  runtime and guest output, registry responses — into strong types at the
  boundary and pass the strong type inward. `ConfigDecoding` does this for the
  whole configuration, so `ConfigValidation` only checks environmental facts;
  `RuntimeProtocol` does it for `iso-sandbox` output.
- **Smart constructors.** When an invariant can't be expressed structurally,
  keep the stored property `let` and expose only a validating initializer or
  static factory that throws `ValidationError`. The invariant then holds
  everywhere the type appears (`InstanceName`, `ImageName`, `EnvVarName`,
  `RepoSlug`, `GitRepoURL`, `VmMemory`, `InstanceIndex`, `GuestPath.absolute`).
- **Make illegal states unrepresentable.** Two optionals that are always both
  set or both nil should be one optional tuple or struct. A `Bool` plus a
  payload meaningful only when it is true should be an optional or an enum case
  with an associated value. A `String` holding one of three values should be an
  enum. `DevcontainerInput` (explicit path, disabled, or discover) is one enum, not two
  flags.

## Enums over booleans

A `Bool` parameter reads as `true`/`false` at the call site and invites
transposition. Prefer an enum (`BootMode.firstBoot`, `OverflowPolicy.drain`,
`ConfigFormat.jsonc`) or an argument label that names the choice. A boolean
flag on an options struct that mirrors a CLI flag is fine.

## Lifecycles and liveness

isolate orchestrates VMs through `setup → up/start → shell → stop → destroy`.
Operations are legal only in certain states. When you find yourself writing
`guard isRunning else { throw … }` far from where the state was established,
consider whether the state belongs in a type:

- **State enum with method gating.** An enum for the state and methods that
  switch over it and throw for illegal transitions. Use when call sites are
  few and an explicit error is reasonable (journal states, proxy phases).
- **Proof values.** `AppleBackend.Running` / `AppleBackend.Stopped` have
  initializers that are internal to `IsoHost`; commands get them only from
  `asRunning` / `resolveRunning` / `asStopped`, and operations that need the
  precondition take the proof. Don't reach for this on a type that mostly does
  something else.

Multi-step operations use explicit scoped cleanup (`defer`, journals,
`Shutdown` scopes). Never rely on `deinit` to stop a VM, terminate a process,
release a credential or roll back a step; actors do not replace interprocess
`FileLock`s.

## Newtypes that earn their keep

The win from a wrapper type comes when:

- Two values of the same underlying type are easy to swap at a call site —
  use distinct types or argument labels.
- A primitive carries an invariant (non-empty, a character class, an absolute
  guest path, a non-zero quantity). The initializer is the one place that
  invariant is checked.
- A primitive is a domain concept that shows up in many signatures (instance
  and image names, guest paths, digests, runtime identifiers). The type reads
  as documentation and resists drift.

If a primitive appears in one place and crosses no boundary, leave it alone.

## Error design

- Distinct failure modes → distinct error types or enum cases, so callers can
  branch without string matching (`ProcessRunner.Failure`, `ConfigError`,
  `RuntimeError`). Use **typed throws** (`throws(ValidationError)`,
  `throws(ProcessRunner.Failure)`) where a function has one closed error type
  and callers switch on it; plain `throws` is fine where errors are composed.
- Attach context where an error becomes user-facing (`ContextError`), not at
  every `try`. Generic `HostError` messages are for failures nobody branches on.
- Never use `try?` plus a default to hide a malformed, unreadable or
  wrong-typed value: missing, `null`, and invalid remain distinct.
- No traps on untrusted input: no force unwraps, `try!`, `as!`, unchecked
  integer arithmetic or unchecked indexing on values derived from configuration,
  guest, runtime, registry or network data. Use checked arithmetic
  (`multipliedReportingOverflow`) and bounded parsing. Where a trap is
  genuinely unreachable, a comment must say *why the invariant holds*.
- Error text must not embed secrets, the configuration document, or raw
  Foundation decoding errors. Guest/runtime text reaching the terminal has
  control characters neutralized.

## Processes, files and output

- **One subprocess launcher.** Every child process starts through
  `ProcessRunner` (`capture`, `stream`, `attached`, `pipeline`) with an explicit
  argv and environment, its own process group, deadlines and bounded output.
  Don't use `Process`, `posix_spawn` or `system` elsewhere. Secrets go on stdin
  or into the child's environment, never argv.
- **No shell interpolation.** Guest shell commands are built with
  `RemoteCommand`: `.arg` for every dynamic value, `.literal` only for
  iso-authored fragments. The only intentional host shell is a user-authored
  `cmd:` credential reference in `CredentialResolver`.
- **State writes** go through `StateStore` / `AtomicFile` under the resource's
  `FileLock`: write a temporary sibling, fsync, rename, never widen the mode.
  Control files are read without following symlinks and with a size bound.
- **Output streams.** stdout carries command output and `--json` only;
  diagnostics, prompts and progress go to stderr through `Diagnostics` /
  `OutputStreams`. No `print` in `IsoHost`.
- **Recursive parsers** for untrusted documents cap nesting and run on
  `ParserStack`'s fixed stack.

## Review checklist (in priority order)

Before reviewing, sync to latest remote (`git fetch origin`).

1. **Correctness against the spec.** Does the change do what was asked,
   including edge cases the author may not have surfaced? Run the relevant tests
   and re-read the diff against the request.
2. **Invariants in types vs. checks.** Scan for `Bool` parameters, primitive
   types representing domain concepts, sentinel values (`-1`, `""`, `0` meaning
   "missing"), and nested optionals. Each is a candidate for a stronger type.
   Flag the ones with real payoff.
3. **Error paths.** Every `try` produces an error that surfaces somewhere. Is
   the eventual message specific enough to act on, and free of secrets and raw
   guest text? Are distinct failures distinguishable without string matching?
   Any `try?` that turns a failure into a default?
4. **Traps.** Force unwraps, `try!`, `as!`, `fatalError`, `precondition`,
   overflowing arithmetic, or unchecked subscripts reachable from input.
5. **Processes and cleanup.** New subprocesses go through `ProcessRunner`; every
   spawned process, lock, PID file, temporary directory and credential is
   released on success, failure, timeout and cancellation.
6. **API surface.** New `public` items: do they need to be public across
   modules? Does the module boundary still hold (no side effects in `IsoCore`
   beyond `AtomicFile` / `FileLock`)?
   `Sendable` conformances honest?
7. **Tests cover behavior, not shape.** Edge cases — empty input, boundaries,
   each error case — have a test. Security-relevant behavior has a fault in
   `scripts/swift-host-fault-injection.py` that a test detects.
8. **Diagnostics.** Operations that take time, fail, or alter state log at an
   appropriate level (info for user-visible lifecycle, debug for internals,
   warn/error for problems), on **stderr**.
9. **Integration gates.** Guest-visible or lifecycle changes: run the macOS
   Apple sandbox integration suite (see [`AGENTS.md`](../AGENTS.md) "Before
   committing").

## Authoring checklist

1. **Sketch the types first.** Write the signatures before the body. If they
   don't make the legal call sequences obvious, the types are wrong.
2. **Take the smallest input you need.** Pass the validated value or the
   specific fields, not the whole configuration, when a function needs one field.
3. **Value types by default.** Prefer `struct`/`enum` with `let` properties;
   use a class or actor only for identity or shared mutable state.
4. **One error case per user-meaningful failure.** Five `try`s that produce
   different actionable errors want an enum with five cases.
5. **Resist the "configuration knob" reflex.** A new flag, environment
   variable, or config field is a long-lived commitment. Add it only when a real
   caller needs it, and update `config.example.jsonc`, `ConfigTemplate` and the
   docs in the same change.
6. **Re-read your diff.** Read your own change as the reviewer would before
   pushing, and run `swift format lint --strict`.
