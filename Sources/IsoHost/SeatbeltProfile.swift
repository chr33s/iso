/// The Seatbelt profile that confines `iso-proxy` (applied with
/// `sandbox-exec -p`), byte-identical to `seatbelt-proxy.sb` beside it, which the
/// integration suite also passes to `iso-proxy --jail-selftest`. Denies
/// file writes and program execution (except the initial exec of
/// `PROXY_BIN`) and allows egress only to ports 443 and 53.
enum SeatbeltProfile {
  static let proxy = #"""
    ;; Seatbelt (SBPL) profile confining the host-side iso-proxy on macOS
    ;; (issue #411, slice 3). Applied by the launcher via `sandbox-exec -p`
    ;; (see Sources/IsoHost/ProxyLifecycle.swift) and asserted by the integration suite via
    ;; `sandbox-exec -f Sources/IsoHost/seatbelt-proxy.sb iso-proxy --jail-selftest`.
    ;;
    ;; Deny everything by default, then allow only what the proxy legitimately
    ;; needs: read files (the dynamic linker, resolver config), resolve names,
    ;; bind its loopback listener, accept the reverse-tunnel connection, and
    ;; connect out only to :443 (upstream HTTPS) and :53 (DNS). No filesystem
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

    ;; Reads stay open (dyld, dylib cache, /etc/resolv.conf, /etc/hosts). Writes
    ;; are denied by the default deny; the proxy only writes to its inherited
    ;; stderr log, which is an already-open descriptor and is unaffected.
    (allow file-read*)

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
    (allow network-outbound (remote tcp "*:443"))
    (allow network-outbound (remote tcp "*:53"))
    (allow network-outbound (remote udp "*:53"))
    ;; Local UNIX sockets used during name resolution. This is the broadest allow
    ;; in the profile (any local UNIX socket, not a specific path). macOS resolves
    ;; names via mach (allowed above), so this may be unnecessary or scopeable to a
    ;; specific path (e.g. path-literal "/var/run/mDNSResponder") — a candidate to
    ;; tighten once validated on a Mac. Kept for now so name resolution cannot
    ;; break.
    (allow network-outbound (remote unix-socket))

    """#

  /// Confines `iso-inference`; byte-identical to `seatbelt-inference.sb`
  /// beside it. Writes only under `STATE_DIR`, reads only system files, the
  /// binary and `STATE_DIR`, no program execution except the initial exec of
  /// `INFERENCE_BIN`, and outbound connections only to the backend ports
  /// `inference(backendPorts:)` renders in place of the marker.
  static let inferenceTemplate = #"""
    ;; Seatbelt (SBPL) profile confining the host-side iso-inference gateway on
    ;; macOS (docs/design/secure-local-inference-spec.md §10). Applied by the
    ;; launcher via `sandbox-exec -p` (Sources/IsoHost/InferenceLifecycle.swift)
    ;; and asserted by `iso-inference --jail-selftest`, which refuses to start
    ;; unless file writes outside STATE_DIR and RELAY_DIR, TCP listeners, program
    ;; execution and non-loopback egress are denied.
    ;;
    ;; This is a separate profile from seatbelt-proxy.sb: the cloud proxy's
    ;; allowance (ports 443 and 53 on any host) is not widened, and this profile
    ;; allows no non-loopback egress at all.
    (version 1)
    (deny default)

    ;; sandbox-exec execve-replaces itself with the gateway binary; that one exec
    ;; must be allowed. No other program can be executed.
    (allow process-exec* (literal (param "INFERENCE_BIN")))

    ;; Reads: system libraries and data, the gateway binary and its state
    ;; directory. Metadata stays readable for path resolution; the root
    ;; directory itself is read by the runtime at startup. Guest strings never
    ;; become paths.
    (allow file-read-metadata)
    (allow file-read*
      (literal "/")
      (subpath "/System")
      (subpath "/usr/lib")
      (subpath "/usr/share")
      (subpath "/private/var/db/timezone")
      (literal "/dev/null")
      (literal "/dev/random")
      (literal "/dev/urandom")
      (literal (param "INFERENCE_BIN"))
      (subpath (param "STATE_DIR"))
      (subpath (param "RELAY_DIR")))

    (allow sysctl-read)
    (allow system-socket)
    (allow process-info* (target self))
    ;; The instance's sandbox owner process, which carries the vsock relay:
    ;; identity (proc_pidinfo) at activation and its exit notification
    ;; (§12.3, §22). Read-only process metadata.
    (allow process-info-pidinfo)
    (allow mach-lookup (global-name "com.apple.system.logger"))

    ;; Writes only under the owner-only state directory: the control socket,
    ;; startup lock, outstanding-work journal and audit log.
    (allow file-write* (subpath (param "STATE_DIR")))
    (allow network-bind (local unix-socket (subpath (param "STATE_DIR"))))
    (allow network-inbound (local unix-socket (subpath (param "STATE_DIR"))))

    ;; Session sockets: one Unix socket per instance in the owner-only relay
    ;; directory, which the sandbox runtime relays into that instance's guest
    ;; over vsock (§22). No TCP listener. Outbound: only the configured backend
    ;; ports, one rule per port, rendered by the launcher in place of the marker
    ;; below.
    (allow file-write* (subpath (param "RELAY_DIR")))
    (allow network-bind (local unix-socket (subpath (param "RELAY_DIR"))))
    (allow network-inbound (local unix-socket (subpath (param "RELAY_DIR"))))
    ;; @BACKEND_PORTS@

    """#

  static let backendPortsMarker = ";; @BACKEND_PORTS@"

  /// The profile for one gateway launch. Each port gets one outbound rule;
  /// with no ports the gateway can reach no backend.
  static func inference(backendPorts: [UInt16]) -> String {
    let rules = backendPorts.sorted().map {
      "(allow network-outbound (remote ip \"localhost:\($0)\"))"
    }
    return inferenceTemplate.replacingOccurrences(
      of: backendPortsMarker,
      with: rules.isEmpty ? ";; no backend ports" : rules.joined(separator: "\n"))
  }
}
