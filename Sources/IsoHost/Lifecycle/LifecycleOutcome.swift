import Foundation
import IsoCore

package enum LifecycleAction: String, Sendable {
  case created
  case started
  case reused
  case stopped
  case destroyed
  case unchanged
}

package struct UpOutcome: Sendable {
  package let action: LifecycleAction
  package let instance: Instance

  package init(action: LifecycleAction, instance: Instance) {
    self.action = action
    self.instance = instance
  }
}

package struct SSHAlias: Sendable, Equatable {
  package let host: String
  package let configPath: String

  package init(host: String, configPath: String) {
    self.host = host
    self.configPath = configPath
  }
}
