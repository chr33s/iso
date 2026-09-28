---
name: integration
description: Run and interpret coop's macOS 27+ VM integration suite for the Apple runtime. Use when asked for integration testing or when guest-visible/lifecycle work needs its pre-merge gate.
---

# Integration

The runner is `./tests/run-integration.sh`, which invokes the Apple runtime
suite (`tests/integration-apple-sandbox.sh`) on macOS 27+ Apple Silicon.
Supported options are `--only PHASE[,PHASE...]` and `--keep`; phases are
`setup disks machine isolation exposure identity persistence resources growth
snapshots recovery concurrency coop`. It needs Xcode 27, `jq`, and stock Apple
`container` with its service running; it builds `coop-sandbox` and `coop`
itself. Run it for host lifecycle, guest-visible, runtime, or isolation
changes. For credential-proxy changes also run
`python3 tests/integration-proxy-transition.py`
(add `--controlled-upstream` for the TLS streaming gate; it may prompt for
sudo to reserve port 443).
`--live-agents` with `--claude-model`/`--codex-model` runs the in-guest agent
tool-use check against real providers. It is billed: run it only when the
user asks, with the models they approved and their dedicated `coop-live-*`
Keychain credentials, never as part of a routine integration run.

Linux guests remain in scope; Linux hosts are not supported. Run the suite
with output redirected to a file, narrate progress during the long run,
inspect the complete output, and report pass/fail per phase. Do not declare
success unless the runner exits zero. Quote the failing phase, clean up the
output file, and state any gate that was not run.
