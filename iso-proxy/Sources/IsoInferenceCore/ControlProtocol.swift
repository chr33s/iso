import CryptoKit
import IsoProxyCore

/// The host-only control protocol (§7): length-prefixed JSON frames over an
/// owner-only Unix-domain socket. Unknown versions, operations and members
/// are rejected; duplicate keys fail the parser.
public enum ControlProtocol {
  /// 2: sessions are Unix sockets named by the registration (`socket`), not
  /// TCP ports (§22).
  public static let version: Int64 = 2
  public static let maxFrameBytes = 256 << 10

  public enum Request: Sendable {
    case register(Registration)
    case activate(Activation)
    case revoke(Revocation)
    case inspect(instance: InstanceKey?)
    case requalify(BackendID)
    case shutdown(force: Bool)
  }

  public struct InstanceKey: Sendable, Hashable {
    public let dataRoot: String
    public let name: String
    public init(dataRoot: String, name: String) {
      self.dataRoot = dataRoot
      self.name = name
    }
  }

  public struct Registration: Sendable {
    public let instance: InstanceKey
    public let boot: BootIdentity
    public let nonce: String
    public let limits: GlobalLimits
    public let grants: [ServiceGrant]
    /// The session socket's file name in the gateway's relay directory: the
    /// host end of the instance's vsock relay (§22).
    public let socket: String

    public init(
      instance: InstanceKey, boot: BootIdentity, nonce: String, limits: GlobalLimits,
      grants: [ServiceGrant], socket: String
    ) {
      self.instance = instance
      self.boot = boot
      self.nonce = nonce
      self.limits = limits
      self.grants = grants
      self.socket = socket
    }

    /// 1–16 lowercase hex digits and `.sock`: the runtime's hash name. It
    /// can never name a path outside the relay directory.
    public static func isSocketName(_ name: String) -> Bool {
      guard name.hasSuffix(".sock") else { return false }
      let stem = name.utf8.dropLast(5)
      return (1...16).contains(stem.count) && stem.allSatisfy(isLowerHex)
    }

    /// Digest of the authorization-relevant policy (credentials excluded).
    public var policyDigest: String {
      var canonical = grants.sorted { $0.alias < $1.alias }.map { grant in
        JSON.object(ControlProtocol.encode(grant, includeCredential: false))
      }
      canonical.append(.object(ControlProtocol.encode(limits)))
      let bytes = JSON.array(canonical).serialized
      return hex(Array(SHA256.hash(data: bytes)))
    }
  }

  public struct Activation: Sendable {
    public let sessionID: String
    public let epoch: String
    public let transport: TransportBinding
    /// Seconds until the host session deadline; nil when the VM has none.
    public let deadlineSeconds: Int64?

    public init(
      sessionID: String, epoch: String, transport: TransportBinding, deadlineSeconds: Int64?
    ) {
      self.sessionID = sessionID
      self.epoch = epoch
      self.transport = transport
      self.deadlineSeconds = deadlineSeconds
    }
  }

  public enum Revocation: Sendable {
    case session(String)
    case instance(InstanceKey)
  }

  // MARK: Framing

  public static func frame(_ value: JSONObject) -> [UInt8] {
    let body = JSON.object(value).serialized
    let length = UInt32(body.count)
    return [
      UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF),
      UInt8(length & 0xFF),
    ] + body
  }

  public static func frameLength(_ header: [UInt8]) -> Int? {
    guard header.count == 4 else { return nil }
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    return length <= maxFrameBytes ? length : nil
  }

  public static func parseFrame(_ body: [UInt8]) throws(InferenceError) -> JSONObject {
    do {
      guard
        case .object(let object) = try JSONParser.parse(
          body, limits: .init(maxBytes: maxFrameBytes, maxDepth: 16))
      else { throw InferenceError(.requestInvalid, "control message must be an object") }
      return object
    } catch let error as InferenceError {
      throw error
    } catch {
      throw InferenceError(.requestInvalid, "control message is not valid JSON")
    }
  }

  // MARK: Requests

  public static func encode(_ request: Request) -> JSONObject {
    var out = JSONObject(["version": .int(version)])
    switch request {
    case .register(let registration):
      out["op"] = .string("register_session")
      out["instance"] = .object(encode(registration.instance))
      out["boot"] = .object(
        JSONObject([
          "owner_pid": .int(Int64(registration.boot.ownerPID)),
          "owner_start": .string(registration.boot.ownerStart.description),
        ]))
      out["nonce"] = .string(registration.nonce)
      out["socket"] = .string(registration.socket)
      out["global_limits"] = .object(encode(registration.limits))
      out["grants"] = .array(
        registration.grants.map { .object(encode($0, includeCredential: true)) })
    case .activate(let activation):
      out["op"] = .string("activate_session")
      out["session_id"] = .string(activation.sessionID)
      out["epoch"] = .string(activation.epoch)
      out["transport"] = .object(
        JSONObject([
          "pid": .int(Int64(activation.transport.pid)),
          "start": .string(activation.transport.start.description),
        ]))
      if let deadline = activation.deadlineSeconds { out["deadline_seconds"] = .int(deadline) }
    case .revoke(.session(let id)):
      out["op"] = .string("revoke_session")
      out["session_id"] = .string(id)
    case .revoke(.instance(let key)):
      out["op"] = .string("revoke_session")
      out["instance"] = .object(encode(key))
    case .inspect(let key):
      out["op"] = .string("inspect")
      if let key { out["instance"] = .object(encode(key)) }
    case .requalify(let backend):
      out["op"] = .string("requalify_backend")
      out["port"] = .int(Int64(backend.port))
    case .shutdown(let force):
      out["op"] = .string("shutdown")
      out["force"] = .bool(force)
    }
    return out
  }

  public static func decodeRequest(_ object: JSONObject) throws(InferenceError) -> Request {
    let r = Reader(object, path: "")
    guard try r.int("version") == version else {
      throw InferenceError(.protocolUnsupported, "unsupported control protocol version")
    }
    switch try r.string("op", maxBytes: 64) {
    case "register_session":
      try r.only([
        "version", "op", "instance", "boot", "nonce", "socket", "global_limits", "grants",
      ])
      let socket = try r.string("socket", maxBytes: 32)
      guard Registration.isSocketName(socket) else {
        throw InferenceError(.requestInvalid, "socket must be 1-16 lowercase hex digits and .sock")
      }
      let boot = try r.object("boot")
      try boot.only(["owner_pid", "owner_start"])
      let nonce = try r.string("nonce", maxBytes: 64)
      guard nonce.utf8.count == 32, nonce.utf8.allSatisfy(isLowerHex) else {
        throw InferenceError(.requestInvalid, "nonce must be 32 lowercase hex digits")
      }
      let grants = try r.array("grants").enumerated().map {
        (index, value) throws(InferenceError) in
        try decodeGrant(Reader.of(value, path: "grants[\(index)]"))
      }
      guard !grants.isEmpty, grants.count <= 16 else {
        throw InferenceError(.requestInvalid, "a session needs 1...16 grants")
      }
      guard Set(grants.map(\.alias)).count == grants.count else {
        throw InferenceError(.requestInvalid, "duplicate grant alias")
      }
      return .register(
        Registration(
          instance: try decodeInstance(r.object("instance")),
          boot: BootIdentity(
            ownerPID: try boot.pid("owner_pid"), ownerStart: try boot.start("owner_start")),
          nonce: nonce, limits: try decodeLimits(r.object("global_limits")), grants: grants,
          socket: socket))
    case "activate_session":
      try r.only(["version", "op", "session_id", "epoch", "transport", "deadline_seconds"])
      let transport = try r.object("transport")
      try transport.only(["pid", "start"])
      let deadline = try r.optionalInt("deadline_seconds")
      if let deadline, deadline < 1 {
        throw InferenceError(.requestInvalid, "deadline_seconds must be positive")
      }
      return .activate(
        Activation(
          sessionID: try r.string("session_id", maxBytes: 64),
          epoch: try r.string("epoch", maxBytes: 64),
          transport: TransportBinding(
            pid: try transport.pid("pid"), start: try transport.start("start")),
          deadlineSeconds: deadline))
    case "revoke_session":
      if r.object["session_id"] != nil {
        try r.only(["version", "op", "session_id"])
        return .revoke(.session(try r.string("session_id", maxBytes: 64)))
      }
      try r.only(["version", "op", "instance"])
      return .revoke(.instance(try decodeInstance(r.object("instance"))))
    case "inspect":
      try r.only(["version", "op", "instance"])
      return .inspect(
        instance: try r.object["instance"].map { _ throws(InferenceError) in
          try decodeInstance(r.object("instance"))
        })
    case "requalify_backend":
      try r.only(["version", "op", "port"])
      return .requalify(BackendID(port: try r.port("port")))
    case "shutdown":
      try r.only(["version", "op", "force"])
      return .shutdown(force: try r.bool("force"))
    default:
      throw InferenceError(.requestInvalid, "unknown control operation")
    }
  }

  // MARK: Pieces

  static func encode(_ key: InstanceKey) -> JSONObject {
    JSONObject(["data_root": .string(key.dataRoot), "name": .string(key.name)])
  }

  static func decodeInstance(_ r: Reader) throws(InferenceError) -> InstanceKey {
    try r.only(["data_root", "name"])
    return InstanceKey(
      dataRoot: try r.string("data_root", maxBytes: 4096), name: try r.string("name", maxBytes: 256)
    )
  }

  static func encode(_ limits: GlobalLimits) -> JSONObject {
    JSONObject([
      "max_active_requests": .int(Int64(limits.maxActiveRequests)),
      "max_queued_requests": .int(Int64(limits.maxQueuedRequests)),
      "max_request_buffer_bytes": .int(Int64(limits.maxRequestBufferBytes)),
    ])
  }

  static func decodeLimits(_ r: Reader) throws(InferenceError) -> GlobalLimits {
    try r.only(["max_active_requests", "max_queued_requests", "max_request_buffer_bytes"])
    return GlobalLimits(
      maxActiveRequests: try r.bounded("max_active_requests", 1...64),
      maxQueuedRequests: try r.bounded("max_queued_requests", 0...1024),
      maxRequestBufferBytes: try r.bounded("max_request_buffer_bytes", (1 << 20)...(1 << 30)))
  }

  static func encode(_ grant: ServiceGrant, includeCredential: Bool) -> JSONObject {
    let profile = grant.backend.profile
    var backend = JSONObject([
      "port": .int(Int64(grant.backend.id.port)), "name": .string(grant.backend.name),
      "max_active": .int(Int64(grant.backend.maxActive)),
      "profile": .object(
        JSONObject([
          "name": .string(profile.name), "protocol": .string(profile.backendProtocol.rawValue),
          "completion_evidence": .string(profile.evidence.rawValue),
          "stream_close_drain_ms": .int(Int64(profile.streamCloseDrainMilliseconds)),
          "context_overflow": .string(profile.contextOverflow.rawValue),
          "overhead_per_request_bytes": .int(Int64(profile.overheadPerRequestBytes)),
          "overhead_per_message_bytes": .int(Int64(profile.overheadPerMessageBytes)),
          "max_input_bytes": .int(Int64(profile.maxInputBytes)),
          "max_request_body_bytes": .int(Int64(profile.maxRequestBodyBytes)),
          "token_counter": .string(profile.tokenCounter.rawValue),
        ])),
    ])
    if includeCredential, let credential = grant.backend.credential {
      backend["credential"] = .string(credential.expose())
    }
    var out = JSONObject([
      "alias": .string(grant.alias), "upstream_model": .string(grant.upstreamModel),
      "apis": .array(grant.apis.map(\.rawValue).sorted().map(JSON.string)),
      "max_context_tokens": .int(Int64(grant.maxContextTokens)),
      "default_output_tokens": .int(Int64(grant.defaultOutputTokens)),
      "max_output_tokens": .int(Int64(grant.maxOutputTokens)),
      "backend": .object(backend),
    ])
    if let bytes = grant.maxInputBytes { out["max_input_bytes"] = .int(Int64(bytes)) }
    return out
  }

  static func decodeGrant(_ r: Reader) throws(InferenceError) -> ServiceGrant {
    try r.only([
      "alias", "upstream_model", "apis", "max_context_tokens", "default_output_tokens",
      "max_output_tokens", "max_input_bytes", "backend",
    ])
    let b = try r.object("backend")
    try b.only(["port", "name", "max_active", "profile", "credential"])
    let p = try b.object("profile")
    try p.only([
      "name", "protocol", "completion_evidence", "stream_close_drain_ms", "context_overflow",
      "overhead_per_request_bytes", "overhead_per_message_bytes", "max_input_bytes",
      "max_request_body_bytes", "token_counter",
    ])
    let profile = QualificationProfile(
      name: try p.string("name", maxBytes: 128),
      backendProtocol: try p.enumeration("protocol", BackendProtocol.self),
      evidence: try p.enumeration("completion_evidence", CompletionEvidence.self),
      streamCloseDrainMilliseconds: try p.bounded("stream_close_drain_ms", 0...60_000),
      contextOverflow: try p.enumeration("context_overflow", ContextOverflow.self),
      overheadPerRequestBytes: try p.bounded("overhead_per_request_bytes", 0...(1 << 20)),
      overheadPerMessageBytes: try p.bounded("overhead_per_message_bytes", 0...(1 << 16)),
      maxInputBytes: try p.bounded("max_input_bytes", 1...(64 << 20)),
      maxRequestBodyBytes: try p.bounded("max_request_body_bytes", 1024...(64 << 20)),
      tokenCounter: try p.enumeration("token_counter", TokenCounter.self))
    if profile.evidence == .explicit {
      throw InferenceError(
        .protocolUnsupported, "completion evidence 'explicit' has no qualified adapter")
    }
    let alias = try r.string("alias", maxBytes: 128)
    guard !alias.isEmpty, alias == displayName(alias) else {
      throw InferenceError(.requestInvalid, "alias must use [A-Za-z0-9._-]")
    }
    let apis = try r.array("apis").map { value throws(InferenceError) -> FrontendAPI in
      guard case .string(let raw) = value, let api = FrontendAPI(rawValue: raw) else {
        throw InferenceError(.requestInvalid, "unknown frontend API")
      }
      return api
    }
    guard !apis.isEmpty else { throw InferenceError(.requestInvalid, "a grant needs an API") }
    for api in apis where api.backendProtocol.map({ $0 != profile.backendProtocol }) ?? false {
      throw InferenceError(
        .protocolUnsupported,
        "\(api.rawValue) needs a \(api.backendProtocol!.rawValue) backend; '\(alias)' is \(profile.backendProtocol.rawValue)"
      )
    }
    if apis.contains(.anthropicCountTokens), profile.tokenCounter != .backend {
      throw InferenceError(
        .protocolUnsupported, "anthropic-count-tokens needs a qualified exact token counter")
    }
    let maxOutput = try r.bounded("max_output_tokens", 1...SessionLimits.generatedTokensPerMinute)
    let defaultOutput = try r.bounded("default_output_tokens", 1...maxOutput)
    let credential = try b.optionalString("credential", maxBytes: 4096).map(Secret.init)
    return ServiceGrant(
      alias: alias,
      backend: BackendPolicy(
        id: BackendID(port: try b.port("port")), name: try b.string("name", maxBytes: 128),
        maxActive: try b.bounded("max_active", 1...64), profile: profile, credential: credential),
      upstreamModel: try r.string("upstream_model", maxBytes: 1024), apis: Set(apis),
      maxContextTokens: try r.bounded("max_context_tokens", 1...10_000_000),
      defaultOutputTokens: defaultOutput, maxOutputTokens: maxOutput,
      maxInputBytes: try r.optionalInt("max_input_bytes").map { value throws(InferenceError) in
        guard (1...(64 << 20)).contains(value) else {
          throw InferenceError(.requestInvalid, "max_input_bytes is out of range")
        }
        return Int(value)
      })
  }

  public static func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      out.append(digits[Int(byte >> 4)])
      out.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func isLowerHex(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
  }

  // MARK: Responses

  public static func success(_ fields: JSONObject = JSONObject()) -> JSONObject {
    var out = JSONObject(["version": .int(version), "ok": .bool(true)])
    for member in fields.members { out[member.key] = member.value }
    return out
  }

  public static func failure(_ error: InferenceError) -> JSONObject {
    JSONObject([
      "version": .int(version), "ok": .bool(false), "code": .string(error.code.rawValue),
      "message": .string(error.message),
    ])
  }

  /// A response frame: its fields on success, the gateway's error otherwise.
  public static func decodeResponse(_ object: JSONObject) throws(InferenceError) -> JSONObject {
    guard object["version"]?.number?.int64 == version else {
      throw InferenceError(.protocolUnsupported, "unsupported control protocol version")
    }
    guard object["ok"]?.bool == true else {
      let code = object["code"]?.string.flatMap(InferenceErrorCode.init(rawValue:))
      throw InferenceError(
        code ?? .backendUnavailable, object["message"]?.string ?? "gateway refused the request")
    }
    return object
  }
}

/// Strict member access for control messages.
struct Reader {
  let object: JSONObject
  let path: String

  init(_ object: JSONObject, path: String) {
    self.object = object
    self.path = path
  }

  static func of(_ value: JSON, path: String) throws(InferenceError) -> Reader {
    guard case .object(let object) = value else {
      throw InferenceError(.requestInvalid, "'\(path)' must be an object")
    }
    return Reader(object, path: path)
  }

  func name(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

  func only(_ keys: Set<String>) throws(InferenceError) {
    if let extra = object.keys.first(where: { !keys.contains($0) }) {
      throw InferenceError(.requestInvalid, "unknown member '\(displayName(name(extra)))'")
    }
  }

  func value(_ key: String) throws(InferenceError) -> JSON {
    guard let value = object[key] else {
      throw InferenceError(.requestInvalid, "'\(name(key))' is required")
    }
    return value
  }

  func object(_ key: String) throws(InferenceError) -> Reader {
    try Reader.of(value(key), path: name(key))
  }

  func array(_ key: String) throws(InferenceError) -> [JSON] {
    guard case .array(let array) = try value(key), array.count <= 64 else {
      throw InferenceError(.requestInvalid, "'\(name(key))' must be an array")
    }
    return array
  }

  func string(_ key: String, maxBytes: Int) throws(InferenceError) -> String {
    guard case .string(let text) = try value(key), text.utf8.count <= maxBytes else {
      throw InferenceError(.requestInvalid, "'\(name(key))' must be a string")
    }
    return text
  }

  func optionalString(_ key: String, maxBytes: Int) throws(InferenceError) -> String? {
    guard object[key] != nil else { return nil }
    return try string(key, maxBytes: maxBytes)
  }

  func bool(_ key: String) throws(InferenceError) -> Bool {
    guard case .bool(let flag) = try value(key) else {
      throw InferenceError(.requestInvalid, "'\(name(key))' must be a boolean")
    }
    return flag
  }

  func int(_ key: String) throws(InferenceError) -> Int64 {
    guard case .number(let number) = try value(key), let int = number.int64 else {
      throw InferenceError(.requestInvalid, "'\(name(key))' must be an integer")
    }
    return int
  }

  func optionalInt(_ key: String) throws(InferenceError) -> Int64? {
    guard object[key] != nil else { return nil }
    return try int(key)
  }

  func bounded(_ key: String, _ range: ClosedRange<Int>) throws(InferenceError) -> Int {
    let value = try int(key)
    guard value >= Int64(range.lowerBound), value <= Int64(range.upperBound) else {
      throw InferenceError(.requestInvalid, "'\(name(key))' is out of range")
    }
    return Int(value)
  }

  func port(_ key: String) throws(InferenceError) -> UInt16 {
    UInt16(try bounded(key, 1024...65535))
  }

  func pid(_ key: String) throws(InferenceError) -> Int32 {
    Int32(try bounded(key, 1...Int(Int32.max)))
  }

  func start(_ key: String) throws(InferenceError) -> ProcessStart {
    let text = try string(key, maxBytes: 64)
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let seconds = UInt64(parts[0]), let micros = UInt64(parts[1]),
      micros < 1_000_000
    else { throw InferenceError(.requestInvalid, "'\(name(key))' must be SECONDS.MICROSECONDS") }
    return ProcessStart(seconds: seconds, microseconds: micros)
  }

  func enumeration<T: RawRepresentable<String>>(_ key: String, _: T.Type) throws(InferenceError)
    -> T
  {
    guard let value = T(rawValue: try string(key, maxBytes: 64)) else {
      throw InferenceError(.requestInvalid, "'\(name(key))' has an unknown value")
    }
    return value
  }
}
