---
name: integration
description: Run and interpret coop's macOS 27+ VM integration suite for the Apple runtime. Use when asked for integration testing or when guest-visible/lifecycle work needs its pre-merge gate.
---

# Integration

The runner is `./tests/run-integration.sh`, which invokes the Apple runtime
suite on macOS 27+ Apple Silicon. Supported options are `--only PHASES` and
`--keep`. The `container` builder and signed `coop-sandbox` runtime are required.
Run it for host lifecycle, guest-visible, runtime, or isolation changes.

Linux guests remain
in scope; Linux/Firecracker host failures are not release blockers. Run the suite with output
redirected to a file, narrate progress during the long run, inspect the complete
output, and report pass/fail per phase. Do not declare success unless the runner
exits zero. Quote the failing phase, clean up the output file, and state any
backend that was not run.
