import Foundation
import IsoConfiguration
import IsoCore

/// What an editor provider may know about a verified running instance: the
/// managed `iso-<name>` alias and the guest path to open. It carries no key
/// material, resolved secret or runtime handle, and it is never a substitute
/// for a `WorkloadSession`.
package struct SSHConnectionTarget: Sendable, Equatable {
  package let instance: InstanceName
  package let guestPath: GuestPath
  package let egress: EgressMode

  /// Internal: outside `IsoHost`, a target comes only from a running proof.
  init(instance: InstanceName, guestPath: GuestPath, egress: EgressMode) {
    self.instance = instance
    self.guestPath = guestPath
    self.egress = egress
  }

  package init(_ running: AppleBackend.Running, guestPath: GuestPath, egress: EgressMode) {
    self.init(instance: running.instance.name, guestPath: guestPath, egress: egress)
  }

  package var sshHostAlias: String { SSHConfigBlocks.host(for: instance) }
}
