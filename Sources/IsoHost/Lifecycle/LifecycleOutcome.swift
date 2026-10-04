import Foundation
import IsoCore

/// What a lifecycle command did, as its workflow observed it.
package enum LifecycleAction: String, Sendable {
  case created
  case started
  case reused
  case stopped
  case destroyed
  case unchanged
}

/// `iso up`: the instance it settled on and how it got there.
package struct UpOutcome: Sendable {
  package let action: LifecycleAction
  package let instance: Instance

  package init(action: LifecycleAction, instance: Instance) {
    self.action = action
    self.instance = instance
  }
}

/// The managed `iso-<name>` alias, never its key material.
package struct SSHAlias: Sendable, Equatable {
  package let host: String
  package let configPath: String

  package init(host: String, configPath: String) {
    self.host = host
    self.configPath = configPath
  }
}
