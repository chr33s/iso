import IsoProxyCore

/// The link between the broker and one session worker (§5.1): the control
/// protocol's length-prefixed JSON frames, over the broker's owner-only
/// worker socket. A link serves only the session its `hello` authenticated:
/// no message names a session, so a worker can affect no other.
package enum WorkerProtocol {
  package static let version: Int64 = 1

  /// Worker to broker.
  package enum Up: Sendable, Equatable {
    /// The session and the one-time key the host gave the worker.
    case hello(session: String, key: String)
    /// The session socket is bound.
    case ready
    /// One rate token from the session's bucket (before normalization).
    case permit(id: UInt64)
    /// Admission of normalized work under an earlier permit.
    case admit(id: UInt64, permit: UInt64, backend: BackendID, outputTokens: Int)
    case withdraw(id: UInt64, ticket: UInt64)
    /// Completion evidence: the slot is released.
    case finish(ticket: UInt64, outputTokens: Int?)
    /// No completion evidence: the slot stays held, the backend quarantined.
    case uncertain(ticket: UInt64)
    /// Reported usage broke the backend's qualification.
    case qualificationFailure(backend: BackendID)
    /// An audit record of one of the worker's own events.
    case audit(event: String, fields: JSONObject)
    case rejected(code: InferenceErrorCode)
    /// The answer to `Down.activate`.
    case activated(id: UInt64, error: InferenceError?)
    /// The worker revoked its session itself (its transport exited).
    case revoked(reason: String)
  }

  /// Broker to worker.
  package enum Down: Sendable {
    case config(Config)
    case permitted(id: UInt64, permit: UInt64)
    case admitted(id: UInt64, ticket: UInt64, queued: Bool)
    case refused(id: UInt64, error: InferenceError)
    case withdrawn(id: UInt64, value: Bool)
    case dispatch(ticket: UInt64)
    case cancel(ticket: UInt64, reason: CancelReason)
    case activate(id: UInt64, transport: TransportBinding, deadlineSeconds: Int64?)
    case revoke(reason: String)
  }

  /// What a worker serves: its registration (grants with their backend
  /// credentials), session identity and capability, and its share of the
  /// broker's request-buffer budget.
  package struct Config: Sendable {
    package let sessionID: String
    package let epoch: String
    package let registration: ControlProtocol.Registration
    package let capability: Secret
    package let requestBufferBytes: Int

    package init(
      sessionID: String, epoch: String, registration: ControlProtocol.Registration,
      capability: Secret, requestBufferBytes: Int
    ) {
      self.sessionID = sessionID
      self.epoch = epoch
      self.registration = registration
      self.capability = capability
      self.requestBufferBytes = requestBufferBytes
    }
  }

  /// The worker events the broker records, and the fields each may carry:
  /// numbers, booleans and short identifiers only, so a worker cannot put
  /// guest text in the log. The broker adds the session itself.
  package static let auditEvents: [String: Set<String>] = [
    "limit_clamped": ["alias", "output_tokens"],
    "request_completed": [
      "alias", "api", "request_bytes", "response_bytes", "input_tokens", "output_tokens",
      "cancelled", "milliseconds",
    ],
    "backend_quarantined": ["backend", "reason", "detail"],
    "transport_exited": ["pid"],
    "request_rejected": ["alias", "code", "api"],
  ]

  // MARK: Encoding

  package static func encode(_ message: Up) -> JSONObject {
    var out = JSONObject(["version": .int(version)])
    switch message {
    case .hello(let session, let key):
      out["op"] = .string("hello")
      out["session"] = .string(session)
      out["key"] = .string(key)
    case .ready: out["op"] = .string("ready")
    case .permit(let id):
      out["op"] = .string("permit")
      out["id"] = .int(Int64(bitPattern: id))
    case .admit(let id, let permit, let backend, let outputTokens):
      out["op"] = .string("admit")
      out["id"] = .int(Int64(bitPattern: id))
      out["permit"] = .int(Int64(bitPattern: permit))
      out["backend"] = .int(Int64(backend.port))
      out["output_tokens"] = .int(Int64(outputTokens))
    case .withdraw(let id, let ticket):
      out["op"] = .string("withdraw")
      out["id"] = .int(Int64(bitPattern: id))
      out["ticket"] = .int(Int64(bitPattern: ticket))
    case .finish(let ticket, let outputTokens):
      out["op"] = .string("finish")
      out["ticket"] = .int(Int64(bitPattern: ticket))
      if let outputTokens { out["output_tokens"] = .int(Int64(outputTokens)) }
    case .uncertain(let ticket):
      out["op"] = .string("uncertain")
      out["ticket"] = .int(Int64(bitPattern: ticket))
    case .qualificationFailure(let backend):
      out["op"] = .string("qualification_failure")
      out["backend"] = .int(Int64(backend.port))
    case .audit(let event, let fields):
      out["op"] = .string("audit")
      out["event"] = .string(event)
      out["fields"] = .object(fields)
    case .rejected(let code):
      out["op"] = .string("rejected")
      out["code"] = .string(code.rawValue)
    case .activated(let id, let error):
      out["op"] = .string("activated")
      out["id"] = .int(Int64(bitPattern: id))
      if let error {
        out["code"] = .string(error.code.rawValue)
        out["message"] = .string(error.message)
      }
    case .revoked(let reason):
      out["op"] = .string("revoked")
      out["reason"] = .string(reason)
    }
    return out
  }

  package static func encode(_ message: Down) -> JSONObject {
    var out = JSONObject(["version": .int(version)])
    switch message {
    case .config(let config):
      out["op"] = .string("config")
      out["session_id"] = .string(config.sessionID)
      out["epoch"] = .string(config.epoch)
      out["registration"] = .object(ControlProtocol.encode(.register(config.registration)))
      out["capability"] = .string(config.capability.expose())
      out["request_buffer_bytes"] = .int(Int64(config.requestBufferBytes))
    case .permitted(let id, let permit):
      out["op"] = .string("permitted")
      out["id"] = .int(Int64(bitPattern: id))
      out["permit"] = .int(Int64(bitPattern: permit))
    case .admitted(let id, let ticket, let queued):
      out["op"] = .string("admitted")
      out["id"] = .int(Int64(bitPattern: id))
      out["ticket"] = .int(Int64(bitPattern: ticket))
      out["queued"] = .bool(queued)
    case .refused(let id, let error):
      out["op"] = .string("refused")
      out["id"] = .int(Int64(bitPattern: id))
      out["code"] = .string(error.code.rawValue)
      out["message"] = .string(error.message)
    case .withdrawn(let id, let value):
      out["op"] = .string("withdrawn")
      out["id"] = .int(Int64(bitPattern: id))
      out["value"] = .bool(value)
    case .dispatch(let ticket):
      out["op"] = .string("dispatch")
      out["ticket"] = .int(Int64(bitPattern: ticket))
    case .cancel(let ticket, let reason):
      out["op"] = .string("cancel")
      out["ticket"] = .int(Int64(bitPattern: ticket))
      out["reason"] = .string(Self.name(reason))
    case .activate(let id, let transport, let deadline):
      out["op"] = .string("activate")
      out["id"] = .int(Int64(bitPattern: id))
      out["transport"] = .object(
        JSONObject([
          "pid": .int(Int64(transport.pid)), "version": .int(Int64(transport.version)),
        ]))
      if let deadline { out["deadline_seconds"] = .int(deadline) }
    case .revoke(let reason):
      out["op"] = .string("revoke")
      out["reason"] = .string(reason)
    }
    return out
  }

  static func name(_ reason: CancelReason) -> String {
    switch reason {
    case .sessionRevoked: "session-revoked"
    case .backendQuarantined: "backend-quarantined"
    case .shutdown: "shutdown"
    }
  }

  // MARK: Decoding

  /// A worker's message, as the broker reads it: strict members, bounded
  /// values, and audit fields only from ``auditEvents``.
  package static func decodeUp(_ object: JSONObject) throws(InferenceError) -> Up {
    let r = Reader(object, path: "")
    guard try r.int("version") == version else {
      throw InferenceError(.protocolUnsupported, "unsupported worker protocol version")
    }
    switch try r.string("op", maxBytes: 32) {
    case "hello":
      try r.only(["version", "op", "session", "key"])
      let session = try r.string("session", maxBytes: 64)
      let key = try r.string("key", maxBytes: 64)
      guard isHex(session, count: 32), isHex(key, count: 64) else {
        throw InferenceError(.requestInvalid, "malformed hello")
      }
      return .hello(session: session, key: key)
    case "ready":
      try r.only(["version", "op"])
      return .ready
    case "permit":
      try r.only(["version", "op", "id"])
      return .permit(id: try id(r, "id"))
    case "admit":
      try r.only(["version", "op", "id", "permit", "backend", "output_tokens"])
      return .admit(
        id: try id(r, "id"), permit: try id(r, "permit"),
        backend: BackendID(port: try r.port("backend")),
        outputTokens: try r.bounded("output_tokens", 0...SessionLimits.generatedTokensPerMinute))
    case "withdraw":
      try r.only(["version", "op", "id", "ticket"])
      return .withdraw(id: try id(r, "id"), ticket: try id(r, "ticket"))
    case "finish":
      try r.only(["version", "op", "ticket", "output_tokens"])
      let tokens = try r.optionalInt("output_tokens")
      if let tokens, !(0...Int64(Usage.maxTokens)).contains(tokens) {
        throw InferenceError(.requestInvalid, "'output_tokens' is out of range")
      }
      return .finish(ticket: try id(r, "ticket"), outputTokens: tokens.map { Int($0) })
    case "uncertain":
      try r.only(["version", "op", "ticket"])
      return .uncertain(ticket: try id(r, "ticket"))
    case "qualification_failure":
      try r.only(["version", "op", "backend"])
      return .qualificationFailure(backend: BackendID(port: try r.port("backend")))
    case "audit":
      try r.only(["version", "op", "event", "fields"])
      let event = try r.string("event", maxBytes: 64)
      guard let allowed = auditEvents[event] else {
        throw InferenceError(.requestInvalid, "unknown audit event")
      }
      let fields = try r.object("fields")
      try fields.only(allowed)
      for member in fields.object.members {
        switch member.value {
        case .number, .bool, .null: continue
        case .string(let text) where text.utf8.count <= 64 && isIdentifier(text): continue
        default: throw InferenceError(.requestInvalid, "audit field '\(member.key)' is not allowed")
        }
      }
      return .audit(event: event, fields: fields.object)
    case "rejected":
      try r.only(["version", "op", "code"])
      return .rejected(code: try r.enumeration("code", InferenceErrorCode.self))
    case "activated":
      try r.only(["version", "op", "id", "code", "message"])
      let id = try id(r, "id")
      guard let raw = try r.optionalString("code", maxBytes: 64) else {
        return .activated(id: id, error: nil)
      }
      guard let code = InferenceErrorCode(rawValue: raw) else {
        throw InferenceError(.requestInvalid, "unknown error code")
      }
      return .activated(
        id: id,
        error: InferenceError(code, try r.optionalString("message", maxBytes: 512) ?? ""))
    case "revoked":
      try r.only(["version", "op", "reason"])
      let reason = try r.string("reason", maxBytes: 64)
      guard isIdentifier(reason) else { throw InferenceError(.requestInvalid, "malformed reason") }
      return .revoked(reason: reason)
    default:
      throw InferenceError(.requestInvalid, "unknown worker operation")
    }
  }

  /// The broker's message, as a worker reads it.
  package static func decodeDown(_ object: JSONObject) throws(InferenceError) -> Down {
    let r = Reader(object, path: "")
    guard try r.int("version") == version else {
      throw InferenceError(.protocolUnsupported, "unsupported worker protocol version")
    }
    switch try r.string("op", maxBytes: 32) {
    case "config":
      try r.only([
        "version", "op", "session_id", "epoch", "registration", "capability",
        "request_buffer_bytes",
      ])
      guard
        case .register(let registration) = try ControlProtocol.decodeRequest(
          try r.object("registration").object)
      else { throw InferenceError(.requestInvalid, "config needs a registration") }
      return .config(
        Config(
          sessionID: try r.string("session_id", maxBytes: 64),
          epoch: try r.string("epoch", maxBytes: 64),
          registration: registration, capability: Secret(try r.string("capability", maxBytes: 128)),
          requestBufferBytes: try r.bounded(
            "request_buffer_bytes", 0...SessionLimits.requestBufferBytesPerSession)))
    case "permitted":
      try r.only(["version", "op", "id", "permit"])
      return .permitted(id: try id(r, "id"), permit: try id(r, "permit"))
    case "admitted":
      try r.only(["version", "op", "id", "ticket", "queued"])
      return .admitted(
        id: try id(r, "id"), ticket: try id(r, "ticket"), queued: try r.bool("queued"))
    case "refused":
      try r.only(["version", "op", "id", "code", "message"])
      return .refused(
        id: try id(r, "id"),
        error: InferenceError(
          try r.enumeration("code", InferenceErrorCode.self), try r.string("message", maxBytes: 512)
        ))
    case "withdrawn":
      try r.only(["version", "op", "id", "value"])
      return .withdrawn(id: try id(r, "id"), value: try r.bool("value"))
    case "dispatch":
      try r.only(["version", "op", "ticket"])
      return .dispatch(ticket: try id(r, "ticket"))
    case "cancel":
      try r.only(["version", "op", "ticket", "reason"])
      let reason: CancelReason =
        switch try r.string("reason", maxBytes: 32) {
        case "session-revoked": .sessionRevoked
        case "backend-quarantined": .backendQuarantined
        case "shutdown": .shutdown
        default: throw InferenceError(.requestInvalid, "unknown cancel reason")
        }
      return .cancel(ticket: try id(r, "ticket"), reason: reason)
    case "activate":
      try r.only(["version", "op", "id", "transport", "deadline_seconds"])
      let transport = try r.object("transport")
      try transport.only(["pid", "version"])
      return .activate(
        id: try id(r, "id"),
        transport: TransportBinding(
          pid: try transport.pid("pid"),
          version: UInt32(try transport.bounded("version", 1...Int(UInt32.max)))),
        deadlineSeconds: try r.optionalInt("deadline_seconds"))
    case "revoke":
      try r.only(["version", "op", "reason"])
      return .revoke(reason: try r.string("reason", maxBytes: 64))
    default:
      throw InferenceError(.requestInvalid, "unknown broker operation")
    }
  }

  static func id(_ r: Reader, _ key: String) throws(InferenceError) -> UInt64 {
    let value = try r.int(key)
    guard value >= 0 else { throw InferenceError(.requestInvalid, "'\(key)' is out of range") }
    return UInt64(value)
  }

  static func isHex(_ text: String, count: Int) -> Bool {
    text.utf8.count == count && text.utf8.allSatisfy(ControlProtocol.isLowerHex)
  }

  /// `[A-Za-z0-9._:-]+`: identifiers, codes and reasons, never free text.
  static func isIdentifier(_ text: String) -> Bool {
    !text.isEmpty
      && text.utf8.allSatisfy { byte in
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
          || (0x61...0x7A).contains(byte) || [0x2E, 0x5F, 0x3A, 0x2D].contains(byte)
      }
  }
}
