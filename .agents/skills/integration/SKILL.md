---
name: integration
description: Run and interpret coop's macOS 27+ VM integration suites for Lima and the Apple runtime. Use when asked for integration testing or when guest-visible/lifecycle work needs its pre-merge gate.
---

# Integration

The runner is `./tests/run-integration.sh`. Empty arguments run locally on
macOS/Lima. The inherited `--remote user@host` Firecracker path is outside
this fork’s supported-host and acceptance scope.
Other supported arguments include `--full`, `--profile LIST`, and `--name NAME`.

The opt-in Apple sandbox runtime (`apple-container` build) has its own
real-hardware suite, `./tests/integration-apple-sandbox.sh` (macOS 27+ Apple Silicon, stock
`container` for image builds; `--only PHASES`). Run it for changes to
`coop-sandbox`, its `containerization` pin, or the isolation gate.

Confirm the requested platform and prerequisites. Run each applicable macOS backend separately;
never describe one backend as proving another. Linux guests remain
in scope; Linux/Firecracker host failures are not release blockers. Run the suite with output
redirected to a file, narrate progress during the long run, inspect the complete
output, and report pass/fail per phase. Do not declare success unless the runner
exits zero. Quote the failing phase, clean up the output file, and state any
backend that was not run.
