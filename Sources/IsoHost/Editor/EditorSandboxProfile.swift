import IsoConfiguration

/// What one sandboxed editor session may reach beyond the shared baseline.
package struct EditorSandboxPolicy: Sendable, Equatable {
  /// Loopback port of iso's SSH tunnel to the guest's sshd.
  package let tunnelPort: UInt16
  /// The editor's own loopback forward (VS Code); nil for ssh stdio.
  package let forwardPort: UInt16?
  /// The provider runs ssh through a local pty and `/bin/sh` (Remote-SSH).
  package let terminal: Bool
  /// Prefix of the Mach service names the editor registers for itself.
  package let machServicePrefix: String
  package let capabilities: [EditorHostCapability]

  package init(
    tunnelPort: UInt16, forwardPort: UInt16?, terminal: Bool, machServicePrefix: String,
    capabilities: [EditorHostCapability]
  ) {
    self.tunnelPort = tunnelPort
    self.forwardPort = forwardPort
    self.terminal = terminal
    self.machServicePrefix = machServicePrefix
    self.capabilities = capabilities
  }

  /// Paths reach the profile only as `(param ...)` values, never as text.
  package static func parameters(app: String, session: String, prefix: String) -> [String] {
    ["-D", "APP=\(app)", "-D", "SESSION=\(session)", "-D", "MACH_PREFIX=\(prefix)"]
  }

  /// Deny-by-default SBPL. The Mach allowlist omits the pasteboard,
  /// LaunchServices' database (app/URL launching), Apple Events, the keychain
  /// and TCC. Derived on macOS 27 with VS Code 1.140 and Zed 1.22.
  package var profile: String {
    var rules = [Self.baseline]
    rules.append(
      #"(allow mach-register mach-lookup (global-name-prefix (param "MACH_PREFIX")) (global-name-prefix (string-append (param "SESSION") "/")))"#
    )
    rules.append(#"(allow network-outbound (remote ip "localhost:\#(tunnelPort)"))"#)
    if let forwardPort {
      rules.append(
        #"(allow network-bind network-inbound network-outbound (local ip "localhost:\#(forwardPort)") (remote ip "localhost:\#(forwardPort)"))"#
      )
    }
    if terminal { rules.append(Self.terminalRules) }
    for capability in capabilities {
      switch capability {
      case .clipboard:
        rules.append(#"(allow mach-lookup (global-name "com.apple.pasteboard.1"))"#)
      case .internet:
        rules.append(Self.internetRules)
      }
    }
    return rules.joined(separator: "\n") + "\n"
  }

  static let baseline = #"""
    (version 1)
    (deny default)
    (allow process-fork)
    (allow process-exec* (subpath (param "APP")))
    (allow process-exec* file-read* (literal "/usr/bin/ssh"))
    (allow file-read*
      (subpath (param "APP"))
      (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/Library/Fonts")
      (subpath "/private/etc") (subpath "/private/var/db/timezone") (literal "/")
      (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom")
      (literal "/dev/dtracehelper") (literal "/dev/autofs_nowait"))
    (allow file-write-data (literal "/dev/null") (literal "/dev/dtracehelper"))
    (allow file-read-metadata)
    (allow file* (subpath (param "SESSION")))
    (allow sysctl-read)
    (allow system-info (info-type "vfs.disk-space"))
    (allow process-info* (target self))
    (allow signal (target same-sandbox))
    (allow ipc-posix-shm)
    (allow iokit-open)
    (allow system-socket)
    (allow network-bind network-inbound (local unix-socket (subpath (param "SESSION"))))
    (allow network-outbound (remote unix-socket (subpath (param "SESSION"))))
    (allow user-preference-read
      (preference-domain "kCFPreferencesAnyApplication" "com.apple.universalaccess"
        "com.apple.accessibility" "com.apple.hitoolbox" "com.apple.coregraphics" "pbs"))
    (allow mach-lookup
      (global-name "com.apple.CARenderServer")
      (global-name "com.apple.CoreServices.coreservicesd")
      (global-name "com.apple.FSEvents")
      (global-name "com.apple.MTLCompilerService")
      (global-name "com.apple.MenuBarAgent.systemservices")
      (global-name "com.apple.SystemConfiguration.DNSConfiguration")
      (global-name "com.apple.SystemConfiguration.configd")
      (global-name "com.apple.ViewBridgeAuxiliary")
      (global-name "com.apple.bsd.dirhelper")
      (global-name "com.apple.coreservices.launchservicesd")
      (global-name "com.apple.diagnosticd")
      (global-name "com.apple.distributed_notifications@Uv3")
      (global-name "com.apple.dock.fullscreen")
      (global-name "com.apple.dock.server")
      (global-name "com.apple.hiservices-xpcservice")
      (global-name "com.apple.logd")
      (global-name "com.apple.logd.events")
      (global-name "com.apple.system.notification_center")
      (global-name "com.apple.system.opendirectoryd.libinfo")
      (global-name "com.apple.system.opendirectoryd.membership")
      (global-name "com.apple.touchbarserver.mig")
      (global-name "com.apple.window_proxies")
      (global-name "com.apple.windowmanager.server")
      (global-name "com.apple.windowserver.active"))
    """#

  /// Remote-SSH runs ssh via `/bin/sh -c` on a pty. Only ptys the editor
  /// allocated are reachable, not the user's terminals.
  static let terminalRules = #"""
    (allow process-exec* file-read* (literal "/bin/sh") (literal "/bin/bash") (literal "/private/var/select/sh"))
    (allow pseudo-tty)
    (allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
    (allow file-read* file-write* file-ioctl
      (require-all (regex #"^/dev/ttys[0-9]+$") (extension "com.apple.sandbox.pty")))
    """#

  /// `internet`: HTTPS anywhere, name resolution and TLS trust evaluation.
  static let internetRules = #"""
    (allow network-outbound (remote tcp "*:443"))
    (allow network-outbound (literal "/private/var/run/mDNSResponder"))
    (allow mach-lookup (global-name "com.apple.mDNSResponder") (global-name "com.apple.trustd.agent"))
    """#
}
