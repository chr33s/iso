import Foundation
import IsoCore

/// Visual Studio Code over Remote-SSH.
package struct VSCodeEditorProvider: EditorProvider {
  package let id = EditorProviderID.code
  package let displayName = "Visual Studio Code"
  package let remoteTransport = EditorRemoteTransport.ssh
  package let installHint =
    "To install the `code` CLI: open VS Code, Cmd+Shift+P, 'Shell Command: Install'"

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
}
