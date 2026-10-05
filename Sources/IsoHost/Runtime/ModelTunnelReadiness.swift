import Foundation
import IsoConfiguration
import IsoCore

/// Local-model reverse tunnels compose with the filtered proof. The model
/// server is the user's own and carries no signing identity, so each tunnel
/// this boot started must still be its recorded `ssh` process, recorded for
/// a destination the current model configuration wants (and, with a guest
/// scope, for this pinned target).
enum ModelTunnelReadiness {
  static func require(_ instance: Instance, config: IsoConfig, scope: FilteredReadiness.Scope)
    throws
  {
    let wanted = try LocalEndpoints.tunnels(ModelState.loadOrDefault(instance), config: config)
    for port in ProxyLauncher.recordedModelTunnels(instance).sorted() {
      let recorded = (try? StateStore.readControlFile(ProxyLauncher.modelSpecPath(instance, port)))
        .flatMap { $0.map { String(decoding: $0, as: UTF8.self) } }
      guard let tunnel = wanted[port], let recorded,
        current(recorded, tunnel: tunnel, scope: scope),
        ProxyLauncher.recordedProcessAlive(
          ProxyLauncher.forwardPIDPath(instance, ProxyLauncher.modelTunnelName(port)),
          expect: .ssh)
      else {
        throw HostError(
          "FILTERED_MODEL_TUNNEL_NOT_READY: local model tunnel for guest port \(port) is not running for this boot; restart the instance"
        )
      }
    }
  }

  static func current(_ recorded: String, tunnel: ReverseTunnel, scope: FilteredReadiness.Scope)
    -> Bool
  {
    switch scope {
    case .host:
      recorded.hasSuffix(" \(tunnel.guestPort):\(tunnel.hostAddress):\(tunnel.hostPort)")
    case .guest(let target): recorded == ProxyLauncher.modelTunnelSpec(target, tunnel)
    }
  }
}
