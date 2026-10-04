import Foundation
import IsoCore

/// Zed's SSH remote development, through the system `ssh` and the managed
/// alias.
package struct ZedEditorProvider: EditorProvider {
  package let id = EditorProviderID.zed
  package let displayName = "Zed"
  package let remoteTransport = EditorRemoteTransport.ssh
  package let installHint = "To install the `zed` CLI: open Zed, Cmd+Shift+P, 'cli: install'"

  package init() {}

  package func launchTarget(_ target: SSHConnectionTarget) -> String {
    "ssh://\(target.sshHostAlias)\(percentEncodeGuestPath(target.guestPath))"
  }

  /// Zed fetches `zed-remote-server` from inside the guest; restricted egress
  /// may block it. iso neither widens egress nor edits Zed's settings.
  package func warnings(_ target: SSHConnectionTarget) -> [String] {
    guard target.egress != .open else { return [] }
    return [
      "Egress is '\(target.egress.rawValue)': the guest may not be able to download zed-remote-server. If Zed cannot connect, add {\"host\": \"\(target.sshHostAlias)\", \"upload_binary_over_ssh\": true} to `ssh_connections` in Zed's settings."
    ]
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
}
