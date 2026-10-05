import Foundation
import IsoCore

/// The compiled-in editor providers. Not a plugin ABI: a new editor is a
/// case here, a top-level command and tests. The raw value is the stable id
/// machine output carries and the command name; case order is `iso editor`'s
/// auto-detection order.
package enum EditorProviderID: String, CaseIterable, Sendable {
  case code
  case zed

  package var provider: any EditorProvider {
    switch self {
    case .code: VSCodeEditorProvider()
    case .zed: ZedEditorProvider()
    }
  }
}

/// How an editor reaches the guest.
package enum EditorRemoteTransport: String, Sendable {
  case ssh
}

/// Whether a project editor command starts the editor.
package enum EditorLaunchMode: Sendable, Equatable {
  case launch
  /// Prepare the instance and alias only (`--no-launch`).
  case prepareOnly
}

/// How a strategy's nonzero exit is read.
package enum NonzeroExitPolicy: Sendable, Equatable {
  /// The editor itself started and declined: only the same provider's
  /// remaining strategies may still run.
  case editorFailure
  /// The launcher could not find the editor; the next strategy runs.
  case launcherMiss
}

/// One way to start an editor: an executable looked up on `PATH` and its
/// literal argv. Never run through a shell.
package struct EditorLaunchStrategy: Sendable, Equatable {
  package let name: String
  package let executable: String
  package let arguments: [String]
  package let nonzeroExit: NonzeroExitPolicy

  package init(
    name: String, executable: String, arguments: [String], nonzeroExit: NonzeroExitPolicy
  ) {
    self.name = name
    self.executable = executable
    self.arguments = arguments
    self.nonzeroExit = nonzeroExit
  }
}

/// Adapts an `SSHConnectionTarget` into an external editor launch. Lifecycle,
/// isolation, host-key pinning and the SSH alias stay with iso; a provider
/// only chooses argv for the managed alias.
package protocol EditorProvider: Sendable {
  var id: EditorProviderID { get }
  var displayName: String { get }
  var remoteTransport: EditorRemoteTransport { get }
  /// How to install the editor's command-line launcher.
  var installHint: String { get }

  /// The address the editor opens, as machine output reports it.
  func launchTarget(_ target: SSHConnectionTarget) -> String
  /// Advisory diagnostics; never a change to iso's VM, egress or SSH config.
  func warnings(_ target: SSHConnectionTarget) -> [String]
  /// Tried in order by `EditorLauncher`.
  func strategies(_ target: SSHConnectionTarget) -> [EditorLaunchStrategy]
}

extension EditorProvider {
  package func warnings(_ target: SSHConnectionTarget) -> [String] { [] }
}

private let urlReservedBytes = Set(" \"#%<>?`{}".utf8)

/// Guest paths reach editors inside a URL: escape what would end or reshape
/// it (`#` would truncate the path as a fragment) and `%` itself.
package func percentEncodeGuestPath(_ path: GuestPath) -> String {
  var out = ""
  for byte in path.rawValue.utf8 {
    if byte < 0x20 || byte >= 0x7F || urlReservedBytes.contains(byte) {
      out += String(format: "%%%02X", byte)
    } else {
      out.unicodeScalars.append(Unicode.Scalar(byte))
    }
  }
  return out
}
