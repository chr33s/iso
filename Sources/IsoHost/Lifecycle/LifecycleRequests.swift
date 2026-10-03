import IsoConfiguration
import IsoCore
import IsoSecrets

/// Settings applied on either a first boot or a restart.
package struct BootOptions {
  package var noAgents: Bool
  package var noPrompt: Bool
  package var forwardPorts: [PortForward]
  package var configTarget: ConfigTarget
  package var postStartOverride: String?
  package var persistedGuestEnvironment: [EnvVarName: EnvValue]
  /// Generic no-auth runs still require the configured provider proxy.
  package var skipAgentBootstrap: Bool

  package init(
    noAgents: Bool = false, noPrompt: Bool = false, forwardPorts: [PortForward] = [],
    configTarget: ConfigTarget, postStartOverride: String? = nil,
    persistedGuestEnvironment: [EnvVarName: EnvValue] = [:], skipAgentBootstrap: Bool = false
  ) {
    self.noAgents = noAgents
    self.noPrompt = noPrompt
    self.forwardPorts = forwardPorts
    self.configTarget = configTarget
    self.postStartOverride = postStartOverride
    self.persistedGuestEnvironment = persistedGuestEnvironment
    self.skipAgentBootstrap = skipAgentBootstrap
  }
}

/// Inputs that can be applied only while provisioning a fresh guest disk.
package struct CreationRequest {
  package var boot: BootOptions
  package var workspaceDirectory: String?
  package var gitRepo: String?
  package var disk: GiB?
  package var mounts: [Mount] = []
  package var excludeGit = false
  package var appliedDevcontainer: AppliedDevcontainer?

  package init(boot: BootOptions) { self.boot = boot }
}

/// Restart applies boot settings to the guest's existing disk and workspace.
package struct RestartRequest {
  package var boot: BootOptions
  package init(boot: BootOptions) { self.boot = boot }
}
