import IsoInferenceCore
import IsoProxyCore
import Testing

private func roundTrip(_ message: WorkerProtocol.Up) throws -> WorkerProtocol.Up {
  let frame = ControlProtocol.frame(WorkerProtocol.encode(message))
  return try WorkerProtocol.decodeUp(ControlProtocol.parseFrame(Array(frame.dropFirst(4))))
}

@Test func workerMessagesRoundTrip() throws {
  let messages: [WorkerProtocol.Up] = [
    .hello(session: String(repeating: "a", count: 32), key: String(repeating: "b", count: 64)),
    .ready, .permit(id: 3),
    .admit(id: 4, permit: 5, backend: BackendID(port: 8080), outputTokens: 9),
    .withdraw(id: 6, ticket: 7), .finish(ticket: 8, outputTokens: 10),
    .finish(ticket: 8, outputTokens: nil),
    .uncertain(ticket: 11), .qualificationFailure(backend: BackendID(port: 8081)),
    .audit(event: "limit_clamped", fields: JSONObject(["alias": .string("local-coder")])),
    .rejected(code: .policyDenied), .activated(id: 12, error: nil),
    .activated(id: 13, error: InferenceError(.policyDenied, "no")),
    .revoked(reason: "transport-exited"),
  ]
  for message in messages { #expect(try roundTrip(message) == message, "\(message)") }
}

/// The broker reads a worker's messages strictly: a worker is only as
/// trusted as the VM whose requests it parses.
@Test func theBrokerDecodesWorkerMessagesStrictly() throws {
  let good = WorkerProtocol.encode(.permit(id: 1))
  var extra = good
  extra["session"] = .string("other")
  var version = good
  version["version"] = .int(WorkerProtocol.version + 1)
  var op = good
  op["op"] = .string("exec")
  var negative = good
  negative["id"] = .int(-1)
  let bad: [JSONObject] = [
    extra, version, op, negative,
    WorkerProtocol.encode(.hello(session: "short", key: String(repeating: "b", count: 64))),
    WorkerProtocol.encode(
      .hello(session: String(repeating: "a", count: 32), key: String(repeating: "B", count: 64))),
    WorkerProtocol.encode(.audit(event: "session_registered", fields: JSONObject())),
    WorkerProtocol.encode(
      .audit(event: "limit_clamped", fields: JSONObject(["session": .string("x")]))),
    WorkerProtocol.encode(
      .audit(event: "limit_clamped", fields: JSONObject(["alias": .string("a b")]))),
    WorkerProtocol.encode(
      .audit(event: "limit_clamped", fields: JSONObject(["alias": .array([])]))),
    WorkerProtocol.encode(
      .audit(
        event: "limit_clamped",
        fields: JSONObject(["alias": .string(String(repeating: "a", count: 65))]))),
    WorkerProtocol.encode(.revoked(reason: "free text")),
    WorkerProtocol.encode(.finish(ticket: 1, outputTokens: Usage.maxTokens + 1)),
    WorkerProtocol.encode(
      .admit(
        id: 1, permit: 1, backend: BackendID(port: 8080),
        outputTokens: SessionLimits.generatedTokensPerMinute + 1)),
  ]
  for (index, message) in bad.enumerated() {
    #expect(throws: InferenceError.self, "case \(index)") {
      try WorkerProtocol.decodeUp(message)
    }
  }
  _ = try WorkerProtocol.decodeUp(good)
}

/// A worker's configuration carries its registration, credentials
/// included, and nothing it can widen.
@Test func aWorkerConfigurationRoundTrips() throws {
  let grant = ServiceGrant(
    alias: "local-coder",
    backend: BackendPolicy(
      id: BackendID(port: 8080), name: "b", maxActive: 1,
      profile: QualificationProfile(
        name: "p", backendProtocol: .openAIChat, evidence: .drain, streamCloseDrainMilliseconds: 0,
        contextOverflow: .reject, overheadPerRequestBytes: 0, overheadPerMessageBytes: 0,
        maxInputBytes: 1024, maxRequestBodyBytes: 2048, tokenCounter: .none),
      credential: Secret("token"), front: .launcher),
    upstreamModel: "m", apis: [.openAIChat], maxContextTokens: 10, defaultOutputTokens: 1,
    maxOutputTokens: 2, maxInputBytes: nil)
  let registration = ControlProtocol.Registration(
    instance: .init(dataRoot: "/d", name: "n"),
    boot: BootIdentity(ownerPID: 1, ownerStart: ProcessStart(seconds: 1, microseconds: 0)),
    nonce: String(repeating: "0", count: 32), limits: .defaults, grants: [grant],
    socket: "ab.sock", transport: .owner)
  let config = WorkerProtocol.Config(
    sessionID: String(repeating: "c", count: 32), epoch: "e", registration: registration,
    capability: Secret(String(repeating: "d", count: 64)), requestBufferBytes: 1 << 20)
  let frame = ControlProtocol.frame(WorkerProtocol.encode(.config(config)))
  guard
    case .config(let decoded) = try WorkerProtocol.decodeDown(
      ControlProtocol.parseFrame(Array(frame.dropFirst(4))))
  else {
    Issue.record("not a configuration")
    return
  }
  #expect(decoded.sessionID == config.sessionID && decoded.requestBufferBytes == 1 << 20)
  #expect(decoded.registration.grants.first?.backend.credential?.expose() == "token")
  #expect(decoded.registration.grants.first?.backend.front == .launcher)
  var oversized = WorkerProtocol.encode(.config(config))
  oversized["request_buffer_bytes"] = .int(Int64(SessionLimits.requestBufferBytesPerSession + 1))
  #expect(throws: InferenceError.self) { try WorkerProtocol.decodeDown(oversized) }
}
