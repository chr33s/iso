import IsoConfiguration
import IsoCore
import IsoSecrets

package struct BootOptions {
  package var noAgents: Bool
  package var noPrompt: Bool
  package var forwardPorts: [PortForward]
  package var configTarget: ConfigTarget
  package var postStartOverride: String?
  package var persistedGuestEnvironment: [EnvVarName: EnvValue]
  /// Generic no-auth runs still require the configured provider proxy.
  package var skipAgentBootstrap: Bool
  /// Grant scopes given by this command (POL-01). Nil: every entry and forward of a
  /// first start. A reprovision passes only what the config grants, so saved entries
  /// keep their provenance and a revoked one is not re-granted.
  package var freshGrantScopes: Set<String>? = nil

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

package struct RestartRequest {
  package var boot: BootOptions
  package init(boot: BootOptions) { self.boot = boot }
}
