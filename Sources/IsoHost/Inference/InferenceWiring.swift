import Foundation
import IsoConfiguration
import IsoCore

extension CommandContext {
  /// The inference gateway controller for `config` (this command's,
  /// overrides applied). The boot closure reads the running sandbox's owner,
  /// session deadline and carrier through the isolation gate. Nil when the
  /// home directory is unknown: the gateway's state lives under it.
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
        return try backend.inferenceBoot(running)
      })
  }
}

extension AppleBackend {
  /// A gate-approved boot's inference facts. vmnet: the relay the gate
  /// verified. brokered: the session socket iso derives for the sandbox (the
  /// same name the runtime would give a relay, in the same private
  /// directory), and whether the network policy the gate matched to this
  /// boot carries the inference grant (brokered spec 7.3).
  package func inferenceBoot(_ running: Running) throws -> InferenceBoot {
    let carrier: InferenceCarrier
    switch running.ready.route {
    case .vmnet: carrier = .relay(socket: running.ready.inferenceSocket)
    case .brokered:
      carrier = .forward(
        socket: IsolationGate.inferenceSocket(
          runtimeRoot: try runtime().root, sandbox: running.ready.sandbox),
        granted: try brokeredView(running)?.policy.grantsInference ?? false)
    }
    return InferenceBoot(
      ownerPID: running.ready.ownerPID, deadline: running.ready.sessionDeadline, carrier: carrier)
  }
}
