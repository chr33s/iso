import Foundation
import IsoCore

/// The runtime commands for one guest OS's sandboxes. Linux sandboxes and
/// macOS guests live in separate runtime namespaces (`iso-sandbox …` and
/// `iso-sandbox macos …`); everything that differs between them, apart from
/// the isolation gate itself, is here.
package struct SandboxNamespace: Sendable {
  let runtime: SandboxRuntime
  package let kind: GuestOS

  /// For macOS, from `macos list`: `macos inspect` also asks the guest
  /// helper, which a plain status check must not wait for.
  package func status(_ name: MachineName) throws(RuntimeError) -> SandboxStatus {
    switch kind {
    case .linux: return try runtime.inspect(name).status
    case .macos:
      guard let status = try runtime.macListed(name) else {
        throw .identityConflict("sandbox \(name) is not in the runtime")
      }
      return status
    }
  }

  /// `list`, not `inspect`: Linux `inspect` refuses an unreadable staged update.
  package func listed(_ name: MachineName) throws(RuntimeError) -> SandboxStatus? {
    switch kind {
    case .linux: try runtime.listed(name)
    case .macos: try runtime.macListed(name)
    }
  }

  /// The live boot of a running sandbox, from one inspection.
  package func live(_ name: MachineName) throws(RuntimeError) -> (bootID: String, pid: Int32)? {
    switch kind {
    case .linux: try runtime.inspect(name).live.map { ($0.bootId, $0.pid) }
    case .macos: try runtime.macInspect(name).live.map { ($0.bootId, $0.pid) }
    }
  }

  /// The runtime's state directory for one sandbox.
  package func directory(_ name: MachineName) -> String {
    Self.directory(root: runtime.root, name, kind)
  }

  /// The runtime's layout (`iso-sandbox`'s `SandboxRoot`), in one place.
  package static func directory(root: String, _ name: MachineName, _ kind: GuestOS) -> String {
    let base = root.hasSuffix("/") ? String(root.dropLast()) : root
    return switch kind {
    case .linux: "\(base)/sandboxes/\(name.rawValue)"
    case .macos: "\(base)/macos/sandboxes/\(name.rawValue)"
    }
  }

  /// Stop, then confirm with an inspection rather than the exit status.
  package func stopAndConfirm(_ name: MachineName) throws {
    let output =
      switch kind {
      case .linux: try runtime.stop(name)
      case .macos: try runtime.macStop(name)
      }
    let now = try status(name)
    guard now == .stopped else {
      throw RuntimeError.operationUncertain(
        "sandbox \(name) did not confirm it stopped (now \(now.rawValue); \(sanitizeForDisplay(String(decoding: output.stderr, as: UTF8.self)))); leaving it untouched"
      )
    }
  }

  /// Delete, then confirm it is gone from the listing.
  package func delete(_ name: MachineName, owner: OwnerID) throws {
    switch kind {
    case .linux: try runtime.delete(name, owner: owner)
    case .macos: try runtime.macDelete(name, owner: owner)
    }
    guard try listed(name) == nil else {
      throw RuntimeError.operationUncertain("sandbox \(name) still exists after delete")
    }
  }

  package func reconcileBestEffort(diagnostics: Diagnostics) {
    switch kind {
    case .linux: runtime.reconcileBestEffort(diagnostics: diagnostics)
    case .macos: runtime.macReconcileBestEffort(diagnostics: diagnostics)
    }
  }
}

extension SandboxRuntime {
  package func namespace(_ kind: GuestOS) -> SandboxNamespace {
    SandboxNamespace(runtime: self, kind: kind)
  }
}
