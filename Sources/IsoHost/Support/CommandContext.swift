import IsoConfiguration
import IsoCore

/// Immutable services and configuration for one host command.
package struct CommandContext {
  package let environment: ConfigEnvironment
  package let config: IsoConfig
  package let backend: AppleBackend
  package let output: any OutputStreams
  package let diagnostics: Diagnostics
  package let ssh: SSHClient

  package init(
    environment: ConfigEnvironment, config: IsoConfig, backend: AppleBackend,
    output: any OutputStreams, diagnostics: Diagnostics, ssh: SSHClient
  ) {
    self.environment = environment
    self.config = config
    self.backend = backend
    self.output = output
    self.diagnostics = diagnostics
    self.ssh = ssh
  }

  package func listInstances() throws -> [Instance] {
    try InstanceStore.list(config) { path, error in
      diagnostics.warn(
        "Skipping corrupted instance dir \(path) (\(error)). Remove it manually or run `destroy --all`."
      )
    }
  }
}

/// Command output streams, supplied by the CLI or a recording test sink.
package protocol OutputStreams {
  func out(_ line: String)
  func write(_ text: String)
  func error(_ line: String)
}
