---
name: mutation-check
description: Run the Swift host fault-injection check (scripts/swift-host-fault-injection.py) for changed security-relevant isolate behavior and keep its fault list synchronized. Use when security-relevant host logic changes, before refactors of it, or when asked to verify that tests bite.
---

# Mutation Check (fault injection)

Fault injection replaces mutation testing for the Swift host. Read the
[fault-injection section of `docs/testing.md`](../../../docs/testing.md#fault-injection)
first.

1. Inspect the diff before running. A change that adds or alters
   security-relevant host behavior — untrusted or user-edited input parsing,
   credential handling, argv/environment construction, path/symlink checks,
   host-key pinning, ownership/lock/atomic-write checks, process cleanup,
   update verification — needs a `FAULTS` entry in
   `scripts/swift-host-fault-injection.py` in the same PR: an id, the
   production file, the exact original text, a replacement that removes the
   behavior, and the `swift test` filter that must catch it.
2. When the diff edits code an existing fault targets, update that entry's
   original text; a missing anchor fails the run.
3. Run the affected faults, redirecting output to a file (do not pipe a long
   run through `head` or `grep`):
   `python3 scripts/swift-host-fault-injection.py --only <id>`, or the whole
   list when many are touched. The script runs a clean control first and
   counts a fault as detected only when a test runs and fails.
4. Triage survivors: add or sharpen a discriminating test for a real gap,
   choose a fault that actually removes the behavior when the replacement was
   equivalent, and delete dead code. A fault that only breaks compilation
   proves nothing; rewrite it.
5. Report faults added/changed/run, detected vs. survived, every survivor's
   disposition, and whether the fault list changed.

Code that only shells out, runs SSH, or talks to external services is not a
fault-injection target by itself; identify the unit/integration blind spot
explicitly and test extracted pure decision logic directly. For
`iso-proxy/` policy code use its Muter sweep and
`scripts/test-swift-proxy-mutations.py` instead.
