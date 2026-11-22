import Foundation
import IsoConfiguration
import IsoCore

extension CommandContext {
  /// The inference gateway controller for `config` (this command's,
  /// overrides applied). The boot closure reads the running sandbox's owner,
  /// session deadline and relay socket through the isolation gate. Nil when
  /// the home directory is unknown: the gateway's state lives under it.
  package func inferenceController(
    resolver: CredentialResolver, isoExecutable: String?, config: IsoConfig? = nil
  ) -> InferenceController? {
    guard let home = environment.home else { return nil }
    let config = config ?? self.config
    let backend = self.backend.reconfigured(config)
    return InferenceController(
      config: config, environment: environment.variables, resolver: resolver,
      diagnostics: diagnostics, isoExecutable: isoExecutable,
      proxies: ProxyLauncher(
        environment: environment.variables, resolver: resolver, diagnostics: diagnostics,
        isoExecutable: isoExecutable),
      home: home,
      boot: { instance in
        guard let running = try backend.asRunning(instance) else {
          throw HostError("Instance '\(instance.name)' is not running")
        }
        return InferenceBoot(
          ownerPID: running.ready.ownerPID, deadline: running.ready.sessionDeadline,
          relaySocket: running.ready.inferenceSocket)
      })
  }
}
