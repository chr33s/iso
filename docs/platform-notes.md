# Platform notes and gotchas

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

Durable, non-obvious environment facts that repeatedly bite contributors. These
are engineering notes, not user documentation — for user-facing backend setup
see [`backends.md`](backends.md).

## Docker networking in the guest

The Apple runtime boots a full Linux kernel with nftables and `iptable_raw`, so
the image (`ImageBuild.guestConfig` in `Sources/IsoHost/ImageBuild.swift`)
applies no kernel workarounds: Docker runs with its default `iptables-nft`
backend and its raw-table "direct access filtering" rule, and
`/etc/resolv.conf` is left as the base image provides it. The Firecracker-era
workarounds (iptables-legacy, a static `resolv.conf`, masking `fcnet.service`,
and `DOCKER_INSECURE_NO_IPTABLES_RAW=1`) are not part of this fork's image.

## scp tilde expansion (OpenSSH 9+)

Modern scp (OpenSSH 9+) uses SFTP by default, which does **not** expand `~` in
remote paths. `scp file user@host:~/.claude/CLAUDE.md` silently creates a literal
`~` directory instead of writing to the home directory.

Fix: `GuestPath` values use `./` instead of `~/` in remote paths (e.g.
`GuestPath("./.claude")`). SFTP defaults to the user's home directory, so
`./path` is equivalent to `~/path`. This convention is used by
`SSHSession.copy` (`Sources/IsoHost/GuestSession.swift`).

SSH commands (`exec`) are unaffected — the remote shell expands `~` normally.
Only scp's SFTP mode has this issue.

## Diagnostics go to stderr

The isolate binary's diagnostics (`Diagnostics` in `Sources/IsoHost/`:
ERROR/WARN/INFO, plus DEBUG/TRACE with `-v`/`-vv`) go to **stderr**, so stdout
stays clean for machine-readable (`--json`) output and piped consumers.
