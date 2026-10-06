import Foundation
import IsoConfiguration
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

/// What a provider may use to prepare a sandboxed session.
package struct SandboxedEditorContext: Sendable {
  package let enclave: EditorEnclave
  package let app: TrustedEditorApp
  package let target: SSHConnectionTarget
  package let capabilities: [EditorHostCapability]
  /// A free loopback port the editor may bind for its own forward.
  package let forwardPort: UInt16
  /// The user's real home; read by iso, never by the editor.
  package let hostHome: String?
}

/// A provider's sandboxed argv and what its transport needs.
package struct SandboxedEditorPlan: Sendable, Equatable {
  package let arguments: [String]
  /// Options re-enabled on the session key after OpenSSH's `restrict`.
  package let keyOptions: [String]
  package let usesForwardPort: Bool
  package let terminal: Bool
  package let machServicePrefix: String
}

/// Adapts an `SSHConnectionTarget` into an external editor launch. Lifecycle,
/// isolation, host-key pinning, the SSH alias and (for a sandboxed session)
/// confinement stay with iso; a provider only chooses argv and editor
/// settings.
package protocol EditorProvider: Sendable {
  var id: EditorProviderID { get }
  var displayName: String { get }
  var remoteTransport: EditorRemoteTransport { get }
  /// How to install the editor's command-line launcher.
  var installHint: String { get }
  /// The signed application a sandboxed session runs.
  var bundleIdentity: EditorBundleIdentity { get }

  /// The address the editor opens, as machine output reports it.
  func launchTarget(_ target: SSHConnectionTarget) -> String
  /// Advisory diagnostics; never a change to iso's VM, egress or SSH config.
  func warnings(_ target: SSHConnectionTarget, security: EditorConfig) -> [String]
  /// `unsafe` launches, tried in order by `EditorLauncher`.
  func strategies(_ target: SSHConnectionTarget) -> [EditorLaunchStrategy]
  /// Writes the session profile into the enclave.
  func prepareSandboxed(_ context: SandboxedEditorContext) throws -> SandboxedEditorPlan
}

extension EditorProvider {
  package func warnings(_ target: SSHConnectionTarget, security: EditorConfig) -> [String] { [] }
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
