import Foundation
import IsoCore

/// A host failure whose class a caller branches on, such as the machine
/// interface's stable error codes. `description` is the human message,
/// unchanged from the untyped error it replaces.
package struct HostFailure: Error, Equatable, Sendable, CustomStringConvertible {
  package enum Reason: Equatable, Sendable {
    /// No instance matches the selection (or none exist).
    case instanceNotFound
    /// More than one instance matches; `resolution` names the argument of
    /// the failing command that picks one, nil when none does.
    case ambiguousInstance(candidates: [InstanceName], resolution: String?)
    case instanceAlreadyRunning(InstanceName)
    /// Nil when no single instance is named (none of several is running).
    case instanceNotRunning(InstanceName?)
    /// The existing instance cannot honor the requested creation options.
    case instanceIncompatible(InstanceName)
    /// The project or repository is already associated with another instance.
    case projectAlreadyAssociated(InstanceName)
    /// Continuing needs a decision the command may not make on its own.
    case interactionRequired(Interaction)
  }

  package enum Interaction: Equatable, Sendable {
    /// A discovered `devcontainer.json` needs an explicit apply or ignore.
    case devcontainer(path: String, acceptedFlags: [String])
    /// The secret store needs a passphrase, and no terminal may be used.
    case passphrase(descriptorVariable: String)
    /// Starting would offer the GitHub PAT setup for `repo`.
    case githubPAT(repo: String, acceptedFlags: [String])
  }

  package let reason: Reason
  package let message: String

  package init(_ reason: Reason, _ message: String) {
    self.reason = reason
    self.message = message
  }

  package var description: String { message }
}
