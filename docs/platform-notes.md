<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Platform notes and gotchas

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

Durable, non-obvious environment facts that repeatedly bite contributors. These
are engineering notes, not user documentation — for user-facing backend setup
see [`backends.md`](backends.md).

## Docker networking in the guest

The Apple runtime boots a full Linux kernel with nftables and `iptable_raw`, so
the image (`ImageBuild.guestConfig` in `Sources/IsoHost/Guest/ImageBuild.swift`)
applies no kernel workarounds: Docker runs with its default `iptables-nft`
backend and its raw-table "direct access filtering" rule, and
`/etc/resolv.conf` is left as the base image provides it. The Firecracker-era
workarounds (iptables-legacy, a static `resolv.conf`, masking `fcnet.service`,
and `DOCKER_INSECURE_NO_IPTABLES_RAW=1`) are not part of this fork's image.

## scp tilde expansion

Since OpenSSH 9.0, scp uses SFTP by default. In that mode `~` in a remote path
is expanded only through the `expand-path@openssh.com` extension, which needs
OpenSSH 8.7 or later on both ends; against an older server,
`scp file user@host:~/.claude/CLAUDE.md` creates a literal `~` directory.

Convention: `GuestPath` values given to scp use `./` instead of `~/` (e.g.
`GuestPath("./.claude")`). SFTP starts in the user's home directory, so
`./path` is equivalent to `~/path` with any server. `SSHClient.copy`
(`Sources/IsoHost/Guest/GuestSession.swift`) passes the path to scp unchanged.

One caller does not follow the convention: local marketplace staging
(`stageMarketplaceSource` in `Sources/IsoHost/Guest/Bootstrap.swift`) copies to
`~/.iso/marketplaces/<tool>/<name>`, relying on the guest's OpenSSH to expand
`~`, and passes the same `~` path, single-quoted, to `claude plugin marketplace
add` and `codex plugin marketplace add`.

SSH commands (`exec`) are unaffected: the remote shell expands an unquoted `~`.

## Diagnostics go to stderr

The isolate binary's diagnostics (`Diagnostics` in `Sources/IsoHost/`:
ERROR/WARN/INFO, plus DEBUG/TRACE with `-v`/`-vv`) go to **stderr**, so stdout
stays clean for machine-readable (`--json`) output and piped consumers.
