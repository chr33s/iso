// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

/// The Seatbelt profile that confines `iso-proxy` (applied with
/// `sandbox-exec -p`), byte-identical to `Resources/seatbelt-proxy.sb`, which the
/// integration suite also passes to `iso-proxy --jail-selftest`. Denies
/// file writes, program execution (except the initial exec of `PROXY_BIN`)
/// and reads outside system paths, and allows egress only to non-loopback
/// port 443 and to DNS.
enum SeatbeltProfile {
  static let proxy = #"""
    ;; Derived from trailofbits/coop.
    ;; Modified by chr33s: ported/adapted for the Swift implementation.
    ;; SPDX-License-Identifier: Apache-2.0

    ;; Seatbelt (SBPL) profile confining the host-side iso-proxy on macOS
    ;; (issue #411, slice 3). Applied by the launcher via `sandbox-exec -p`
    ;; (see Sources/IsoHost/Guest/ProxyLifecycle.swift) and asserted by the integration suite via
    ;; `sandbox-exec -f Sources/IsoHost/Guest/Resources/seatbelt-proxy.sb iso-proxy --jail-selftest`.
    ;;
    ;; Deny everything by default, then allow only what the proxy legitimately
    ;; needs: read system files (the dynamic linker, frameworks), resolve names,
    ;; bind its loopback listener, accept the reverse-tunnel connection, and
    ;; connect out only to non-loopback :443 (upstream HTTPS) and :53 (DNS). No filesystem
    ;; writes; the only exec permitted is sandbox-exec's initial replace-exec of
    ;; the proxy binary itself (see PROXY_BIN below) — a compromised proxy still
    ;; cannot exec any other program. No other egress. The sandbox is inherited by
    ;; children and cannot be relaxed from inside.
    ;;
    ;; `sandbox-exec`/SBPL is officially deprecated but still functional and widely
    ;; relied on; Apple has shipped no CLI successor. See docs/trust-model.md.
    (version 1)
    (deny default)

    ;; sandbox-exec applies this profile to itself and then execve-replaces itself
    ;; with the proxy binary. That initial exec is governed by this profile, so it
    ;; must be permitted or the proxy can never start. Scope it to this exact
    ;; binary — its absolute path is passed as the PROXY_BIN parameter via
    ;; `sandbox-exec -D` — so a compromised proxy still cannot exec a shell or any
    ;; other program (every other path stays denied by `(deny default)`), and the
    ;; proxy never execs again after this.
    (allow process-exec* (literal (param "PROXY_BIN")))

    ;; Reads are limited to what dyld, Foundation, Security.framework trust
    ;; evaluation and the resolver load: system libraries and data, the proxy
    ;; binary itself, and a few devices. Home directories, iso state and other
    ;; user files stay unreadable. Writes are denied by the default deny; the
    ;; proxy only writes to its inherited stderr log, which is an already-open
    ;; descriptor and is unaffected.
    (allow file-read*
      (literal (param "PROXY_BIN"))
      (literal "/")
      (subpath "/System")
      (subpath "/usr/lib")
      (subpath "/usr/share")
      (subpath "/Library/Preferences")
      (subpath "/private/var/db/dyld")
      (subpath "/private/var/db/timezone")
      (subpath "/private/etc")
      (literal "/dev/null")
      (literal "/dev/random")
      (literal "/dev/urandom")
      (literal "/dev/dtracehelper"))
    ;; The /etc and /var symlinks are traversed to reach /private/etc and the
    ;; mDNSResponder socket; name resolution fails without the /var lookup.
    (allow file-read-metadata (literal "/etc") (literal "/var"))

    ;; Baseline a networked binary needs to start under (deny default).
    (allow sysctl-read)
    (allow system-socket)
    (allow process-info* (target self))
    (allow mach-lookup
      (global-name "com.apple.mDNSResponder")
      (global-name "com.apple.system.opendirectoryd.libinfo")
      (global-name "com.apple.system.logger"))

    ;; NIOSSL .default trust on macOS uses Security.framework/SecTrust. Its
    ;; per-user trust evaluation service is required to verify provider identities.
    ;; Verified with credential-free TLS to both providers on macOS 27: removing
    ;; this exact permission fails TLS; com.apple.trustd alone does not suffice.
    ;; No keychain API service or filesystem write permission is added.
    (allow mach-lookup (global-name "com.apple.trustd.agent"))

    ;; Bind only the loopback listener and accept the host's reverse-tunnel
    ;; connection to it.
    (allow network-bind (local ip "localhost:*"))
    (allow network-inbound (local ip "localhost:*"))

    ;; Egress allowlist: connect out only to the upstream HTTPS port and DNS.
    ;; This is port-scoped, not host-scoped — the two upstreams' identity is
    ;; enforced at the TLS layer in the proxy, and the guest cannot retarget them.
    ;; Both ports are for the network only: the deny after them keeps every
    ;; loopback IP service, on any port, out of reach. It must follow the
    ;; allows because a later matching rule overrides an earlier one.
    (allow network-outbound (remote tcp "*:443"))
    (allow network-outbound (remote tcp "*:53"))
    (allow network-outbound (remote udp "*:53"))
    (deny network-outbound (remote ip "localhost:*"))
    ;; The system resolver's socket; name resolution fails without it (verified
    ;; on macOS 27). No other local UNIX socket is reachable.
    (allow network-outbound (path-literal "/private/var/run/mDNSResponder"))

    """#

  /// Blind CONNECT companion. No TLS trust evaluation and no credential files.
  /// Byte-identical to `Resources/seatbelt-egress.sb`; the reads, loopback
  /// deny and resolver socket match the proxy profile above.
  static let egress = #"""
    (version 1)
    (deny default)
    (allow process-exec* (literal (param "EGRESS_BIN")))
    (allow file-read*
      (literal (param "EGRESS_BIN"))
      (literal "/")
      (subpath "/System")
      (subpath "/usr/lib")
      (subpath "/usr/share")
      (subpath "/Library/Preferences")
      (subpath "/private/var/db/dyld")
      (subpath "/private/var/db/timezone")
      (subpath "/private/etc")
      (literal "/dev/null")
      (literal "/dev/random")
      (literal "/dev/urandom")
      (literal "/dev/dtracehelper"))
    (allow file-read-metadata (literal "/etc") (literal "/var"))
    (allow sysctl-read)
    (allow system-socket)
    (allow process-info* (target self))
    (allow mach-lookup
      (global-name "com.apple.mDNSResponder")
      (global-name "com.apple.system.opendirectoryd.libinfo")
      (global-name "com.apple.system.logger"))
    (allow network-bind (local ip "localhost:*"))
    (allow network-inbound (local ip "localhost:*"))
    (allow network-outbound (remote tcp "*:443"))
    (allow network-outbound (remote tcp "*:53"))
    (allow network-outbound (remote udp "*:53"))
    (deny network-outbound (remote ip "localhost:*"))
    (allow network-outbound (path-literal "/private/var/run/mDNSResponder"))
    """# + "\n"
}

extension SeatbeltProfile {
  /// Confines the host `bsdtar` that unpacks a guest-authored workspace
  /// stream (`WorkspaceTransfer.tarReceive`). Whatever the stream makes it
  /// do, the receiver writes only beneath `TREE` (the receive attempt's
  /// tree), reads only system files, executes nothing but `RECEIVER` itself
  /// and opens no network connection. The inherited writer-lease descriptor
  /// is already open and needs no permission.
  static let tarReceiver = #"""
    (version 1)
    (deny default)
    (allow process-exec* (literal (param "RECEIVER")))
    (allow file-read*
      (literal (param "RECEIVER"))
      (literal "/")
      (subpath "/System")
      (subpath "/usr/lib")
      (subpath "/usr/share")
      (subpath "/Library/Preferences")
      (subpath "/private/var/db/dyld")
      (subpath "/private/var/db/timezone")
      (subpath "/private/etc")
      (literal "/dev/null")
      (literal "/dev/random")
      (literal "/dev/urandom")
      (literal "/dev/dtracehelper"))
    (allow file-read-metadata (literal "/etc") (literal "/var") (literal "/tmp"))
    (allow file-read* file-write* (subpath (param "TREE")))
    (allow sysctl-read)
    (allow process-info* (target self))
    (allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))
    """# + "\n"
}

enum EgressPorts {
  static let base: UInt16 = 10788
  static func port(_ instance: Instance) -> UInt16 { base &+ instance.index.value }
  static func capabilityPath(_ instance: Instance) -> String {
    instance.directory + "/egress-capability"
  }
}
