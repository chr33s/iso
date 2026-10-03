import Foundation

/// Supervision of sandbox owners by launchd.
///
/// The VM lives inside its owner process, so each running sandbox is one
/// launchd job loaded from a plist in the sandbox directory (never in
/// `~/Library/LaunchAgents`, so nothing starts at login). The job requests
/// relaunch after abnormal exits; the owner exits 0 on a clean halt and on its
/// own startup errors, so neither requests a relaunch.
package enum Launchd {
  static let launchctl = "/bin/launchctl"

  /// The background user domain keeps supervising VMs while the GUI is locked.
  package static func domain() -> String {
    "user/\(getuid())"
  }

  package static func plist(label: String, executable: String, arguments: [String], log: URL)
    -> [String: Any]
  {
    [
      "Label": label,
      "ProgramArguments": [executable] + arguments,
      "RunAtLoad": true,
      // Without this session type, bootstrap into the user domain is rejected.
      "LimitLoadToSessionType": "Background",
      "KeepAlive": ["SuccessfulExit": false],
      "ThrottleInterval": 10,
      // The owner halts systemd on SIGTERM; give it time before SIGKILL.
      "ExitTimeOut": 90,
      "ProcessType": "Interactive",
      "StandardOutPath": log.path,
      "StandardErrorPath": log.path,
      // Nothing from the caller's environment reaches the runtime.
      "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()],
    ]
  }

  package static func write(_ plist: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
    chmod(url.path, 0o600)
  }

  package static func isLoaded(_ label: String, domain: String) -> Bool {
    run([launchctl, "print", "\(domain)/\(label)"]).status == 0
  }

  package static func bootstrap(plist url: URL, domain: String, label: String) throws {
    try bootstrap(plist: url, domain: domain, label: label, request: run)
  }

  static func bootstrap(
    plist url: URL, domain: String, label: String,
    request: ([String]) -> (status: Int32, output: String)
  ) throws {
    let loaded = request([launchctl, "bootstrap", domain, url.path])
    guard loaded.status == 0 else {
      throw SandboxError("launchctl bootstrap failed (\(loaded.status)): \(loaded.output)")
    }
    let target = "\(domain)/\(label)"
    // RunAtLoad may remain a speculative spawn. Demand startup, but never
    // use -k: an owner that already started must keep its VM and boot identity.
    let started = request([launchctl, "kickstart", target])
    guard started.status == 0 else {
      let unloaded = request([launchctl, "bootout", target])
      var message = "launchctl kickstart failed (\(started.status)): \(started.output)"
      if unloaded.status != 0 {
        message += "; launchctl bootout also failed (\(unloaded.status)): \(unloaded.output)"
      }
      throw SandboxError(message)
    }
  }

  /// Unload the owner job from its background user domain.
  package static func bootout(_ label: String) {
    let domain = domain()
    if isLoaded(label, domain: domain) {
      _ = run([launchctl, "bootout", "\(domain)/\(label)"])
    }
  }

  static func run(_ argv: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.environment = ["PATH": "/usr/bin:/bin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
      try p.run()
    } catch {
      return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data.prefix(4096), as: UTF8.self))
  }
}
