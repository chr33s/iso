import Foundation
import IsoConfiguration
import IsoCore

/// Zed's SSH remote development, through the system `ssh`.
package struct ZedEditorProvider: EditorProvider {
  package let id = EditorProviderID.zed
  package let displayName = "Zed"
  package let remoteTransport = EditorRemoteTransport.ssh
  package let installHint = "To install the `zed` CLI: open Zed, Cmd+Shift+P, 'cli: install'"
  package let bundleIdentity = EditorBundleIdentity(
    bundleName: "Zed.app", identifier: "dev.zed.Zed", teamIdentifier: "MQ55VZLNZQ",
    executable: "Contents/MacOS/zed")

  package init() {}

  package func launchTarget(_ target: SSHConnectionTarget) -> String {
    "ssh://\(target.sshHostAlias)\(percentEncodeGuestPath(target.guestPath))"
  }

  /// A sandboxed Zed resolves `zed-remote-server`'s URL from the host, so it
  /// needs `internet` once per Zed version.
  package func warnings(_ target: SSHConnectionTarget, security: EditorConfig) -> [String] {
    switch security.security {
    case .sandboxed where !security.allow.contains(.internet):
      return [
        "The sandboxed Zed has no internet access: if the guest does not already have this Zed version's zed-remote-server, Zed cannot fetch it. Run once with `--editor-allow internet` if Zed cannot connect."
      ]
    case .sandboxed:
      return []
    case .unsafe:
      guard target.egress != .open else { return [] }
      return [
        "Egress is '\(target.egress.rawValue)': the guest may not be able to download zed-remote-server. If Zed cannot connect, add {\"host\": \"\(target.sshHostAlias)\", \"upload_binary_over_ssh\": true} to `ssh_connections` in Zed's settings."
      ]
    }
  }

  package func strategies(_ target: SSHConnectionTarget) -> [EditorLaunchStrategy] {
    let path = percentEncodeGuestPath(target.guestPath)
    return [
      EditorLaunchStrategy(
        name: "zed CLI", executable: "zed", arguments: ["ssh://\(target.sshHostAlias)\(path)"],
        nonzeroExit: .editorFailure),
      EditorLaunchStrategy(
        name: "macOS open zed:// URL", executable: "open",
        arguments: ["zed://ssh/\(target.sshHostAlias)\(path)"], nonzeroExit: .launcherMiss),
    ]
  }

  /// Settings live in `<user-data>/config`. Zed uses ssh's stdio, so the key
  /// needs no forwarding.
  package func prepareSandboxed(_ context: SandboxedEditorContext) throws -> SandboxedEditorPlan {
    let enclave = context.enclave
    let upload = context.capabilities.contains(.internet) && context.target.egress != .open
    let settings: [String: Any] = [
      "disable_ai": true,
      "auto_update": false,
      "telemetry": ["diagnostics": false, "metrics": false],
      "ssh_connections": [
        [
          "host": enclave.alias, "args": ["-F", enclave.sshConfig],
          "upload_binary_over_ssh": upload,
        ] as [String: Any]
      ],
    ]
    try enclave.write(try settingsJSON(settings), to: enclave.data + "/config/settings.json")
    return SandboxedEditorPlan(
      arguments: [
        "--user-data-dir", enclave.data,
        "ssh://\(enclave.alias)\(percentEncodeGuestPath(context.target.guestPath))",
      ],
      keyOptions: [], usesForwardPort: false, terminal: false,
      machServicePrefix: bundleIdentity.identifier + ".")
  }
}
