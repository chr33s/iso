import Darwin

/// Shared request lifecycle; production supplies a control lease and the public
/// connector. Tests can stall work without adding a release policy bypass.
package enum EgressSession {
  package static func handle(
    _ client: Int32, allow: EgressAllowlist, capability: String, admission: Admission,
    lease: ControlLease, readiness: EgressReadiness?
  ) {
    handle(
      client, allow: allow, capability: capability, admission: admission,
      readiness: readiness, alive: lease.alive,
      connect: { PublicConnector.connect($0, admission: admission) })
  }

  static func handle(
    _ client: Int32, allow: EgressAllowlist, capability: String, admission: Admission,
    readiness: EgressReadiness?, alive: () -> Bool, connect: (String) throws -> Int32?
  ) {
    defer { close(client) }
    guard alive() else { return }
    let head = ConnectGate.readHead(client, alive: alive)
    if head.starts(with: Array((EgressReadiness.requestLine + "\r\n").utf8)) {
      let response =
        readiness?.response(head, capability: capability, alive: alive)
        ?? ConnectGate.responseBytes(.unsupported)
      _ = EgressReadiness.write(response, to: client, alive: alive)
      return
    }
    let host: String
    switch ConnectGate.connectTarget(head, allow: allow, capability: capability) {
    case .deny(let denial):
      ConnectGate.writeResponse(client, denial, alive: alive)
      return
    case .connect(let approved): host = approved
    }
    guard admission.tryTunnel() else {
      ConnectGate.writeResponse(client, .unsupported, alive: alive)
      return
    }
    defer { admission.endTunnel() }
    do {
      try Tunnel.open(
        client, host: host, connect: connect,
        alive: alive)
    } catch {
      ConnectGate.writeResponse(client, .unsupported, alive: alive)
    }
  }

}
