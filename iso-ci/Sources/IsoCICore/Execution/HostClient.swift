import Foundation

/// Exchanges one `iso.host/v1` frame for one reply frame.
package protocol HostTransport: Sendable {
  /// `frame` includes its newline. Throws `.hostUnreachable` when no reply
  /// arrived; the client decides whether a mutation became uncertain.
  func exchange(_ frame: [UInt8]) throws(CIError) -> [UInt8]
}

/// The supported external client access path: the explicitly installed
/// `iso` executable's `host-agent client --host <alias> --stdio` bridge.
/// For `local` it reaches the local host service as a remote-v1 caller (so
/// local-only maintenance stays refused); for an enrolled host it uses iso's
/// pinned management SSH. Request bytes travel on stdin only.
package struct IsoBridgeTransport: HostTransport {
  package let iso: String
  /// The operator-chosen iso configuration (`iso --config`), when iso-ci
  /// uses a dedicated iso data root instead of `~/.iso`.
  package let isoConfig: String?
  package let alias: Name
  package let timeout: Duration
  package let environment: [String: String]

  package init(
    iso: String, isoConfig: String? = nil, alias: Name, timeout: Duration = .seconds(90),
    environment: [String: String] = Subprocess.hostConnectionEnvironment()
  ) {
    self.iso = iso
    self.isoConfig = isoConfig
    self.alias = alias
    self.timeout = timeout
    self.environment = environment
  }

  package var arguments: [String] {
    Self.clientArguments(isoConfig: isoConfig, host: alias.rawValue, relay: false)
  }

  /// `host-agent client` argv; the frame or preamble travels on stdin only.
  package static func clientArguments(isoConfig: String?, host: String, relay: Bool) -> [String] {
    ["host-agent", "client"] + (isoConfig.map { ["--config", $0] } ?? []) + ["--host", host]
      + (relay ? ["--relay"] : []) + ["--stdio"]
  }

  package func exchange(_ frame: [UInt8]) throws(CIError) -> [UInt8] {
    let output: Subprocess.Output
    do {
      output = try Subprocess.run(
        .init(
          executable: iso, arguments: arguments, environment: environment, input: frame,
          timeout: timeout, outputLimit: (1 << 20) + 2))
    } catch {
      throw CIError(.hostUnreachable, "cannot start the iso client bridge for \(alias)")
    }
    guard !output.timedOut else {
      throw CIError(.hostUnreachable, "host \(alias) did not reply in time")
    }
    guard let newline = output.stdout.firstIndex(of: 0x0A) else {
      let detail = String(decoding: output.stderr.suffix(256), as: UTF8.self)
      throw CIError(.hostUnreachable, "host \(alias) did not reply: \(detail)")
    }
    return Array(output.stdout[..<newline])
  }
}

/// Typed `iso.host/v1` calls with response validation: request correlation,
/// pinned host/owner identity, and lost-reply handling for durable
/// mutations (`OPERATION_UNCERTAIN`: resolve the same identity).
package struct HostClient: Sendable {
  package let alias: Name
  package let transport: any HostTransport
  /// The pinned identity; nil only during first contact.
  package let expected: (host: HostID, owner: OwnerID)?

  package init(alias: Name, transport: any HostTransport, expected: (host: HostID, owner: OwnerID)?)
  {
    self.alias = alias
    self.transport = transport
    self.expected = expected
  }

  package func hello() throws(CIError) -> (HelloResult, DaemonEpoch) {
    let request = HostRequest(
      hostID: nil, ownerID: nil, body: .hello(clientBuild: IsoCIVersion.clientBuild))
    let (value, epoch) = try send(request)
    let hello = try HelloResult(wire: value)
    if let expected {
      guard hello.hostID == expected.host, hello.ownerID == expected.owner else {
        throw CIError(.hostIdentityChanged, "host \(alias) identity changed since it was enabled")
      }
    }
    return (hello, epoch)
  }

  package func capabilities() throws(CIError) -> HostCapabilities {
    try HostCapabilities(wire: try call(.hostCapabilities))
  }

  package func call(_ body: HostRequestBody, operation: HostOperationID? = nil) throws(CIError)
    -> JSONValue
  {
    guard let expected else { throw CIError.invalid("host \(alias) identity is not pinned yet") }
    guard body.method.isDurableMutation == (operation != nil) else {
      throw CIError.invalid("durable mutations need an operation id; others must not carry one")
    }
    return try send(
      HostRequest(
        hostID: expected.host, ownerID: expected.owner, operationID: operation, body: body)
    ).0
  }

  private func send(_ request: HostRequest) throws(CIError) -> (JSONValue, DaemonEpoch) {
    let reply: [UInt8]
    do { reply = try transport.exchange(request.frame) } catch {
      if request.body.method.isDurableMutation, let operation = request.operationID {
        throw CIError(
          .operationUncertain,
          "no reply after sending \(request.body.method.rawValue); resolve the same operation",
          details: ["operation_id": operation.rawValue, "cause": error.code.rawValue])
      }
      throw error
    }
    let response = try HostResponse.decode(frame: reply)
    guard response.requestID == request.requestID else {
      throw CIError.invalid("host reply does not match the request")
    }
    if let expected {
      guard response.hostID == expected.host, response.ownerID == expected.owner else {
        throw CIError(.hostIdentityChanged, "host \(alias) identity changed")
      }
    }
    switch response.outcome {
    case .success(let value): return (value, response.epoch)
    case .failure(let box): throw box.error.ciError
    }
  }

  // MARK: Typed helpers

  package func inspectRun(_ run: HostRunID) throws(CIError) -> RunObservation {
    try RunObservation(wire: try call(.runInspect(run)))
  }

  package func inspectVM(_ instance: QualifiedInstance) throws(CIError) -> VMObservation {
    try VMObservation(wire: try call(.vmInspect(instance)))
  }

  package func operation(_ id: HostOperationID) throws(CIError) -> OperationReceipt {
    try OperationReceipt(wire: try call(.operationGet(id)))
  }

  package func submit(_ body: HostRequestBody, operation: HostOperationID) throws(CIError)
    -> OperationReceipt
  {
    try OperationReceipt(wire: try call(body, operation: operation))
  }

  /// Polls `operation.get` until terminal or the deadline; never re-sends.
  package func wait(
    _ id: HostOperationID, timeout: Duration, interval: Duration = .milliseconds(500)
  )
    throws(CIError) -> OperationReceipt
  {
    let deadline = ContinuousClock.now + timeout
    while true {
      let receipt = try operation(id)
      if receipt.state.isTerminal || ContinuousClock.now >= deadline { return receipt }
      Thread.sleep(
        forTimeInterval: Double(interval.components.seconds) + Double(
          interval.components.attoseconds) / 1e18)
    }
  }

  /// Reads a committed host artifact until a short chunk, bounded by
  /// `limit`, and verifies it against the digest the host recorded.
  package func readArtifact(_ handle: ArtifactHandle, digest: Digest, limit: UInt64) throws(CIError)
    -> [UInt8]
  {
    var out: [UInt8] = []
    var offset: UInt64 = 0
    let chunkSize = HostRequestBody.maxArtifactChunk
    while true {
      let chunk = try call(.artifactRead(handle: handle, offset: offset, length: chunkSize))
      guard let data = chunk["data"]?.stringValue, let bytes = Data(base64Encoded: data),
        bytes.count <= Int(chunkSize)
      else { throw CIError.invalid("malformed artifact chunk") }
      out += bytes
      offset += UInt64(bytes.count)
      guard offset <= limit else {
        throw CIError(.budgetExceeded, "host artifact exceeds the export limit")
      }
      if bytes.count < Int(chunkSize) { break }
    }
    guard Digest(hashing: out) == digest else {
      throw CIError.invalid("host artifact does not match its recorded digest")
    }
    return out
  }
}
