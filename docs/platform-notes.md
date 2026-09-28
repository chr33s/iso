# Platform notes and gotchas

> **Host support:** This fork supports macOS 27+ on Apple Silicon only. Linux
> guests remain supported.

Durable, non-obvious environment facts that repeatedly bite contributors. These
are engineering notes, not user documentation — for user-facing backend setup
see [`backends.md`](backends.md).

## Inherited guest image workarounds

`scripts/guest/guest-config.sh` (baked into the golden image) still applies
three workarounds that originated with the minimal Firecracker CI kernel and
base image. They are retained so one image script serves every guest kernel:

1. **iptables-legacy.** A kernel without nftables support makes Docker's
   default `iptables-nft` backend fail with "Protocol not supported". Fix:
   `update-alternatives --set iptables /usr/sbin/iptables-legacy`.
2. **Static `resolv.conf`.** A rootfs whose `/etc/resolv.conf` links to
   systemd-resolved's stub (`127.0.0.53`) without `systemd-resolved` installed
   fails DNS silently. Fix: replace the symlink with a static file.
3. **`fcnet.service` masked.** An inherited base image may enable
   `fcnet.service`, which assigns a MAC-derived `/30` address alongside coop's
   systemd-networkd configuration. Provisioning disables and masks it.

## Docker networking in the guest

A kernel without the `iptable_raw` module (`CONFIG_IP_NF_RAW` not set, as in
the inherited Firecracker CI kernel) breaks Docker 28+, which uses the raw
table for "direct access filtering" — a PREROUTING DROP rule that prevents direct routing to published container ports,
ensuring traffic goes through Docker's port-mapping rules.

Without the raw table, Docker refuses to start bridge networking. The fix uses
Docker 28.0.2's `DOCKER_INSECURE_NO_IPTABLES_RAW=1` env var (moby/moby#49621),
set via a systemd drop-in at `/etc/systemd/system/docker.service.d/no-raw.conf`.
This tells Docker to skip raw-table rules while keeping full bridge networking:
NAT, port mapping (`-p`), container-to-container communication, and embedded DNS
all work normally.

The "insecure" label refers to the fact that without raw-table rules, other
hosts on the local network could route directly to published container ports
even if they're bound to loopback. This is irrelevant here — the guest's only
network neighbor is the host, and the VM itself is the isolation
boundary. See [`trust-model.md`](trust-model.md#documented-accepted-trade-offs).

## scp tilde expansion (OpenSSH 9+)

Modern scp (OpenSSH 9+) uses SFTP by default, which does **not** expand `~` in
remote paths. `scp file user@host:~/.claude/CLAUDE.md` silently creates a literal
`~` directory instead of writing to the home directory.

Fix: `GuestPath` values use `./` instead of `~/` in remote paths (e.g.
`GuestPath("./.claude")`). SFTP defaults to the user's home directory, so
`./path` is equivalent to `~/path`. This convention is used by
`SSHSession.copy` (`Sources/CoopHost/GuestSession.swift`).

SSH commands (`exec`) are unaffected — the remote shell expands `~` normally.
Only scp's SFTP mode has this issue.

## Diagnostics go to stderr

The coop binary's diagnostics (`Diagnostics` in `Sources/CoopHost/`:
ERROR/WARN/INFO, plus DEBUG/TRACE with `-v`/`-vv`) go to **stderr**, so stdout
stays clean for machine-readable (`--json`) output and piped consumers.
