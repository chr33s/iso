import IsoProxyCore
import Testing

@testable import IsoInferenceCore

private let key = ControlProtocol.InstanceKey(dataRoot: "/Users/me/.iso", name: "dev")

private func registration(_ grants: [ServiceGrant]) -> ControlProtocol.Registration {
  ControlProtocol.Registration(
    instance: key,
    boot: BootIdentity(ownerPID: 42, ownerStart: ProcessStart(seconds: 1, microseconds: 2)),
    nonce: String(repeating: "a", count: 32), limits: .defaults, grants: grants,
    socket: "8e84b04d471a546a.sock", transport: .forward)
}

private func roundTrip(_ request: ControlProtocol.Request) throws -> ControlProtocol.Request {
  let frame = ControlProtocol.frame(ControlProtocol.encode(request))
  let length = try #require(ControlProtocol.frameLength(Array(frame.prefix(4))))
  #expect(length == frame.count - 4)
  return try ControlProtocol.decodeRequest(ControlProtocol.parseFrame(Array(frame.dropFirst(4))))
}

@Test func registrationRoundTripsWithCredential() throws {
  var withSecret = grant(.anthropicMessages)
  withSecret = ServiceGrant(
    alias: withSecret.alias,
    backend: BackendPolicy(
      id: withSecret.backend.id, name: "mlx", maxActive: 1, profile: withSecret.backend.profile,
      credential: Secret("backend-secret")),
    upstreamModel: withSecret.upstreamModel, apis: withSecret.apis, maxContextTokens: 1000,
    defaultOutputTokens: 10, maxOutputTokens: 20, maxInputBytes: 5000)
  guard case .register(let decoded) = try roundTrip(.register(registration([withSecret]))) else {
    Issue.record("wrong operation")
    return
  }
  #expect(decoded.grants == [withSecret])
  #expect(decoded.instance == key)
  #expect(decoded.transport == .forward)
  #expect(decoded.policyDigest == registration([withSecret]).policyDigest)
  // The digest never covers the credential.
  #expect(!registration([withSecret]).policyDigest.isEmpty)
}

@Test func otherOperationsRoundTrip() throws {
  let activation = ControlProtocol.Activation(
    sessionID: "s1", epoch: "e1",
    transport: TransportBinding(pid: 9, start: ProcessStart(seconds: 3, microseconds: 4)),
    deadlineSeconds: 60)
  guard case .activate(let decoded) = try roundTrip(.activate(activation)) else {
    Issue.record("wrong operation")
    return
  }
  #expect(decoded.transport == activation.transport && decoded.deadlineSeconds == 60)
  guard case .revoke(.instance(let revoked)) = try roundTrip(.revoke(.instance(key))) else {
    Issue.record("wrong operation")
    return
  }
  #expect(revoked == key)
  guard case .requalify(let backend) = try roundTrip(.requalify(BackendID(port: 8080))) else {
    Issue.record("wrong operation")
    return
  }
  #expect(backend.port == 8080)
}

@Test func strictDecodingRejectsUnknownAndMismatched() throws {
  let good = ControlProtocol.encode(.shutdown(force: false))
  var unknown = good
  unknown["extra"] = .bool(true)
  // Version 2 (no transport kind) and version 1 (TCP session ports) are
  // refused, as is any other.
  var version = good
  version["version"] = .int(ControlProtocol.version - 1)
  var oldest = good
  oldest["version"] = .int(1)
  var op = good
  op["op"] = .string("exec")
  for message in [unknown, version, oldest, op] {
    #expect(throws: InferenceError.self) { try ControlProtocol.decodeRequest(message) }
  }
  #expect(ControlProtocol.version == 3)
  // A registration names its transport kind, one of the two.
  let registered = ControlProtocol.encode(.register(registration([grant(.openAIChat)])))
  var noKind = registered
  noKind["transport"] = nil
  var otherKind = registered
  otherKind["transport"] = .string("direct")
  var versionTwo = registered
  versionTwo["version"] = .int(2)
  for message in [noKind, otherKind, versionTwo] {
    #expect(throws: InferenceError.self) { try ControlProtocol.decodeRequest(message) }
  }
  _ = try ControlProtocol.decodeRequest(registered)
  #expect(ControlProtocol.frameLength([0x7F, 0, 0, 0]) == nil)

  // A grant whose API needs a different backend protocol is refused.
  let mismatched = grant(.openAIChat, apis: [.anthropicMessages])
  var encoded = ControlProtocol.encode(.register(registration([mismatched])))
  #expect(throws: InferenceError.self) { try ControlProtocol.decodeRequest(encoded) }
  // So is explicit completion evidence, which no adapter implements.
  encoded = ControlProtocol.encode(
    .register(registration([grant(.openAIChat, evidence: .explicit)])))
  #expect(throws: InferenceError.self) { try ControlProtocol.decodeRequest(encoded) }
}

@Test func errorBodiesFollowTheFrontendShape() throws {
  let error = InferenceError(.capacity, "session queue is full")
  let anthropic = try json(String(decoding: error.body(for: .anthropicMessages), as: UTF8.self))
  #expect(anthropic["error"]?["type"]?.string == "rate_limit_error")
  let openAI = try json(String(decoding: error.body(for: .openAIResponses), as: UTF8.self))
  #expect(openAI["error"]?["code"]?.string == "INFERENCE_CAPACITY")
  #expect(InferenceErrorCode.allCases.allSatisfy { (400...599).contains($0.status) })
}

@Test func sessionSocketNamesCannotLeaveTheRelayDirectory() throws {
  for bad in [
    "../x.sock", "/tmp/a.sock", "8E84.sock", "a.sock.sock", ".sock", "8e84b04d471a546a0.sock",
    "8e84",
  ] {
    #expect(!ControlProtocol.Registration.isSocketName(bad), "\(bad)")
  }
  #expect(ControlProtocol.Registration.isSocketName("8e84b04d471a546a.sock"))
  #expect(ControlProtocol.Registration.isSocketName("f.sock"))
  var document = ControlProtocol.encode(.register(registration([grant(.anthropicMessages)])))
  _ = try ControlProtocol.decodeRequest(document)
  document["socket"] = .string("../../escape.sock")
  #expect(throws: InferenceError.self) { try ControlProtocol.decodeRequest(document) }
}

@Test func policyDigestIgnoresOnlyTheCredential() throws {
  func withCredential(_ secret: String?, maxActive: Int = 1) -> ServiceGrant {
    let base = grant(.anthropicMessages)
    return ServiceGrant(
      alias: base.alias,
      backend: BackendPolicy(
        id: base.backend.id, name: base.backend.name, maxActive: maxActive,
        profile: base.backend.profile, credential: secret.map(Secret.init)),
      upstreamModel: base.upstreamModel, apis: base.apis, maxContextTokens: base.maxContextTokens,
      defaultOutputTokens: base.defaultOutputTokens, maxOutputTokens: base.maxOutputTokens,
      maxInputBytes: base.maxInputBytes)
  }
  let first = registration([withCredential("secret-one")]).policyDigest
  #expect(first == registration([withCredential("secret-two")]).policyDigest)
  #expect(first == registration([withCredential(nil)]).policyDigest)
  #expect(first != registration([withCredential("secret-one", maxActive: 2)]).policyDigest)
}

@Test func outputCeilingMustFitTheContextWindow() throws {
  var document = ControlProtocol.encode(.register(registration([grant(.anthropicMessages)])))
  _ = try ControlProtocol.decodeRequest(document)
  guard case .array(var grants)? = document["grants"], case .object(var first) = grants[0] else {
    Issue.record("no grants")
    return
  }
  first["max_context_tokens"] = .int(4_096)
  grants[0] = .object(first)
  document["grants"] = .array(grants)
  #expect(throws: InferenceError.self) { try ControlProtocol.decodeRequest(document) }
}
