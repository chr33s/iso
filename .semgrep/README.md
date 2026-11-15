# Semgrep code-style rules

Mechanical checks for conventions in [`docs/code-style.md`](../docs/code-style.md).
`mise run semgrep` runs the rule fixtures (`semgrep --test`) and then scans the
Swift sources of the root, `iso-policy`, `iso-proxy`, `iso-egress` and `iso-ci`
packages; CI runs it in the `Host and runtime` job. The rules are local, and
metrics and the version check are off.

| Rule | Convention | Scope |
| --- | --- | --- |
| `iso.process-launcher` | Child processes start through `ProcessRunner`, not `Process`, `posix_spawn`, `system`, `fork` or `exec*` | all five packages; the launcher files are excluded |
| `iso.host-shell` | No `sh -c` / `bash -c` argv | root, `iso-policy`, `iso-proxy`, `iso-egress` |
| `iso.library-stdout` | Library modules do not write to stdout | root library targets, `iso-policy` |
| `iso.state-write` | Host file writes go through `StateStore` / `AtomicFile` | root, `iso-policy`, `iso-proxy`, `iso-egress` |
| `iso.unexplained-trap` | A `try!` / `as!` has its invariant in a `//` comment on the line above (a validating initializer over one literal is exempt) | all five packages |

Each rule lives in `rules/<name>.yml` with its fixture `rules/<name>.swift`:
`// ruleid:` marks a line the rule must match and `// ok:` one it must not.

**Matching.** The rules use Semgrep's `generic` mode (token patterns with
`//` and `/* */` comments ignored) or regexes (which skip `//` comments only),
not its Swift parser: that parser (Semgrep 1.183.0) reports syntax errors on
typed throws, `unsafe` expressions and `InlineArray` in about 80 of the 335
scanned files, and it missed an `unsafe posix_spawn(...)` call outright.
Generic and regex matching see string literals as code, so a pattern inside a
string can match.

**Exceptions.** An intentional exception carries a comment saying why, then
`// nosemgrep: <rule-id>` on the line directly above the finding. Keep a
path exclude for a file whose whole purpose is the excluded behavior (the
`ProcessRunner` implementation, `AtomicFile`).

`iso-sandbox` is not scanned: the runtime launches helpers with Foundation
`Process` and writes its own state directly.
