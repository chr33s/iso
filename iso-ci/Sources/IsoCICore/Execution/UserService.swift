import Foundation

/// The explicitly installed per-user launchd service for the controller.
/// Installation is a CI-only write the operator asked for; nothing else in
/// launchd or iso's own service is touched.
package enum UserService {
  package static func label(_ root: DataRoot) -> String {
    "dev.iso.ci." + Digest(hashing: root.path).short
  }

  package static func plistPath(_ root: DataRoot) -> String {
    NSHomeDirectory() + "/Library/LaunchAgents/" + label(root) + ".plist"
  }

  /// The constraints an operator must know before relying on the service.
  package static let limitations = [
    "runs only while this user is logged in; logout, restart and sleep stop it",
    "the GitHub App key in the login keychain is readable only while the keychain is unlocked, and only by the iso-ci executable you allowed (allow it again after an update)",
    "a stopped controller lets the host stop VMs after their lease grace; hard deadlines still apply",
    "macOS may require Full Disk Access or Local Network approval for the iso executable it calls",
  ]

  package static func apply(install: Bool, root: DataRoot, executable: String, iso: String?)
    throws(CIError) -> JSONValue
  {
    let label = label(root)
    let path = plistPath(root)
    guard let launchctl = Subprocess.which("launchctl") else {
      throw CIError(.unsupported, "launchctl is not available")
    }
    let domain = "gui/\(getuid())"
    // Remove any previous instance first; absence is not an error.
    _ = try? Subprocess.run(
      .init(
        executable: launchctl, arguments: ["bootout", "\(domain)/\(label)"], timeout: .seconds(30)))
    if !install {
      PrivateFiles.remove(path)
      return ["label": .string(label), "installed": false]
    }
    var arguments = [executable, "serve", "--root", root.path]
    if let iso { arguments += ["--iso", iso] }
    try root.prepare()
    let document: [String: Any] = [
      "Label": label,
      "ProgramArguments": arguments,
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "ThrottleInterval": 10,
      "ProcessType": "Background",
      "StandardOutPath": root.logs + "/controller.log",
      "StandardErrorPath": root.logs + "/controller.log",
      "EnvironmentVariables": [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
      ],
    ]
    let data: Data
    do {
      data = try PropertyListSerialization.data(
        fromPropertyList: document, format: .xml, options: 0)
    } catch {
      throw CIError(.internalError, "cannot encode the service definition")
    }
    let directory = (path as NSString).deletingLastPathComponent
    if access(directory, F_OK) != 0 {
      guard mkdir(directory, 0o755) == 0 || errno == EEXIST else {
        throw CIError.storage("cannot create \(directory)")
      }
    }
    try PrivateFiles.write(Array(data), to: path, mode: 0o600)
    let output = try Subprocess.run(
      .init(executable: launchctl, arguments: ["bootstrap", domain, path], timeout: .seconds(30)))
    guard output.succeeded else {
      throw CIError(
        .internalError,
        "launchctl bootstrap failed: \(String(decoding: output.stderr.suffix(200), as: UTF8.self))")
    }
    return [
      "label": .string(label), "installed": true, "plist": .string(path),
      "limitations": .array(limitations.map { .string($0) }),
    ]
  }
}
