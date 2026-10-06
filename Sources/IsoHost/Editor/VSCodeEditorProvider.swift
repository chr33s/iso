import Foundation
import IsoConfiguration
import IsoCore

/// Visual Studio Code over Remote-SSH.
package struct VSCodeEditorProvider: EditorProvider {
  package let id = EditorProviderID.code
  package let displayName = "Visual Studio Code"
  package let remoteTransport = EditorRemoteTransport.ssh
  package let installHint =
    "To install the `code` CLI: open VS Code, Cmd+Shift+P, 'Shell Command: Install'"
  package let bundleIdentity = EditorBundleIdentity(
    bundleName: "Visual Studio Code.app", identifier: "com.microsoft.VSCode",
    teamIdentifier: "UBF8T346G9", executable: "Contents/MacOS/Code")

  static let remoteSSHExtension = "ms-vscode-remote.remote-ssh"

  package init() {}

  package func launchTarget(_ target: SSHConnectionTarget) -> String {
    "vscode-remote://ssh-remote+\(target.sshHostAlias)\(percentEncodeGuestPath(target.guestPath))"
  }

  /// The fallback is a `vscode://` URL rather than `open -a … --args`: macOS
  /// passes `--args` only to a newly launched app, so a running VS Code
  /// would come to the front, `open` would exit 0 and no remote would open.
  package func strategies(_ target: SSHConnectionTarget) -> [EditorLaunchStrategy] {
    let alias = "ssh-remote+\(target.sshHostAlias)"
    return [
      EditorLaunchStrategy(
        name: "code CLI", executable: "code",
        arguments: ["--remote", alias, target.guestPath.rawValue], nonzeroExit: .editorFailure),
      EditorLaunchStrategy(
        name: "macOS open vscode:// URL", executable: "open",
        arguments: ["vscode://vscode-remote/\(alias)\(percentEncodeGuestPath(target.guestPath))"],
        nonzeroExit: .launcherMiss),
    ]
  }

  package func warnings(_ target: SSHConnectionTarget, security: EditorConfig) -> [String] {
    guard target.egress != .open else { return [] }
    if security.security == .sandboxed, !security.allow.contains(.internet) {
      return [
        "Egress is '\(target.egress.rawValue)': the guest may not be able to download VS Code Server, and the sandboxed editor has no internet access. If VS Code cannot connect, run once with `--editor-allow internet`."
      ]
    }
    return []
  }

  /// A separate `--user-data-dir` keeps it from joining a running VS Code.
  /// Chromium's sandbox cannot nest inside Seatbelt, hence
  /// `--disable-chromium-sandbox`.
  package func prepareSandboxed(_ context: SandboxedEditorContext) throws -> SandboxedEditorPlan {
    let enclave = context.enclave
    let source = try Self.remoteSSHSource(home: context.hostHome)
    let destination = enclave.extensions + "/" + (source as NSString).lastPathComponent
    do {
      try FileManager.default.copyItem(atPath: source, toPath: destination)
    } catch {
      throw ContextError("Failed to copy the Remote - SSH extension from \(source)", cause: error)
    }
    let internet = context.capabilities.contains(.internet)
    var settings: [String: Any] = [
      "chat.disableAIFeatures": true,
      "telemetry.telemetryLevel": "off",
      "update.mode": "none",
      "extensions.autoUpdate": false,
      "extensions.autoCheckUpdates": false,
      "workbench.enableExperiments": false,
      // Remote-SSH's terminal needs trust before connecting: a mandatory click.
      "security.workspace.trust.enabled": false,
      "remote.SSH.configFile": enclave.sshConfig,
      "remote.SSH.path": "/usr/bin/ssh",
      "remote.SSH.remotePlatform": [enclave.alias: "linux"],
      "remote.SSH.defaultExtensions": [String](),
      "remote.SSH.enableRemoteCommand": false,
      "remote.SSH.enableDynamicForwarding": false,
      "remote.SSH.useLocalServer": false,
      "remote.SSH.showLoginTerminal": false,
      "remote.SSH.preferredLocalPortRange": "\(context.forwardPort)-\(context.forwardPort)",
    ]
    if internet, context.target.egress != .open {
      settings["remote.SSH.localServerDownload"] = "always"
    }
    try enclave.write(try settingsJSON(settings), to: enclave.data + "/User/settings.json")
    return SandboxedEditorPlan(
      arguments: [
        "--user-data-dir", enclave.data, "--extensions-dir", enclave.extensions, "--new-window",
        "--disable-chromium-sandbox", "--force-disable-user-env",
        "--remote", "ssh-remote+\(enclave.alias)", context.target.guestPath.rawValue,
      ],
      keyOptions: [
        "port-forwarding", "permitopen=\"localhost:*\"", "permitopen=\"127.0.0.1:*\"",
      ],
      usesForwardPort: true, terminal: true,
      machServicePrefix: bundleIdentity.identifier + ".MachPortRendezvousServer.")
  }

  /// The newest user-owned Remote-SSH in the user's VS Code extensions.
  static func remoteSSHSource(home: String?) throws -> String {
    let root = (home ?? NSHomeDirectory()) + "/.vscode/extensions"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    let prefix = remoteSSHExtension + "-"
    let candidates = names.compactMap { name -> (version: [Int], path: String)? in
      guard name.hasPrefix(prefix) else { return nil }
      let version = name.dropFirst(prefix.count).split(separator: ".").map { Int($0) }
      guard !version.isEmpty, version.allSatisfy({ $0 != nil }) else { return nil }
      let path = root + "/" + name
      var status = stat()
      guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
        status.st_uid == getuid()
      else { return nil }
      return (version.map { $0! }, path)
    }
    guard let newest = candidates.max(by: { $0.version.lexicographicallyPrecedes($1.version) })
    else {
      throw HostFailure(
        .editorLaunchFailed(.code),
        "The sandboxed VS Code needs the Remote - SSH extension (\(remoteSSHExtension)), and none is installed in \(root). Install it in VS Code; iso copies it into each isolated session."
      )
    }
    return newest.path
  }
}
