import Foundation
import IsoCore

/// `inference` decoding (secure-local-inference spec §11.3). Every object is
/// closed: unknown members are rejected, as are conflicting endpoint forms,
/// dangling references and limits outside their bounds.
extension ConfigDecoder {
  static let inferenceKeys: Set<String> = [
    "mode", "global_limits", "qualification_profiles", "backends", "services",
  ]

  static func inference(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> InferenceConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: inferenceKeys)
    let mode = try r.defaulted("mode", .off) { v, p throws(FieldError) in
      try Parse.stringEnum(v, p, InferenceMode.allCases)
    }
    let limits = try r.defaulted("global_limits", .defaults, globalLimits)
    let profiles: [String: QualificationProfileConfig] = try r.defaulted(
      "qualification_profiles", [:]
    ) { v, p throws(FieldError) -> [String: QualificationProfileConfig] in
      let raw = try Parse.map(v, p, profile)
      var out: [String: QualificationProfileConfig] = [:]
      for (name, value) in raw {
        try checkName(name, p + [.key(name)])
        out[name] = QualificationProfileConfig(
          name: name, backendProtocol: value.backendProtocol,
          completionEvidence: value.completionEvidence,
          streamCloseDrainMilliseconds: value.streamCloseDrainMilliseconds,
          contextOverflow: value.contextOverflow,
          overheadPerRequestBytes: value.overheadPerRequestBytes,
          overheadPerMessageBytes: value.overheadPerMessageBytes,
          maxInputBytes: value.maxInputBytes, maxRequestBodyBytes: value.maxRequestBodyBytes,
          tokenCounter: value.tokenCounter)
      }
      return out
    }
    let backends: [String: InferenceBackendConfig] = try r.defaulted("backends", [:]) {
      v, p throws(FieldError) in try Parse.map(v, p, backend)
    }
    for (name, backend) in backends {
      let at = r.child("backends") + [.key(name)]
      try checkName(name, at)
      if backend.managed != nil {
        _ = try Parse.domain(at) { () throws(ValidationError) in try ManagedBackendName(name) }
      }
      guard let profile = profiles[backend.profile] else {
        throw FieldError(
          at + [.key("qualification_profile")],
          "unknown qualification profile '\(backend.profile)'")
      }
      guard profile.backendProtocol == backend.backendProtocol else {
        throw FieldError(
          at + [.key("protocol")],
          "backend protocol \(backend.backendProtocol.rawValue) differs from profile '\(backend.profile)' (\(profile.backendProtocol.rawValue))"
        )
      }
    }
    let services = try r.defaulted("services", [:]) {
      v, p throws(FieldError) -> [InferenceServiceName: InferenceServiceConfig] in
      let raw = try Parse.map(v, p, service)
      var out: [InferenceServiceName: InferenceServiceConfig] = [:]
      for (key, value) in raw {
        let at = p + [.key(key)]
        let name = try Parse.domain(at) { () throws(ValidationError) in
          try InferenceServiceName(key)
        }
        guard let backend = backends[value.backend] else {
          throw FieldError(at + [.key("backend")], "unknown backend '\(value.backend)'")
        }
        let profile = profiles[backend.profile]!
        for api in value.frontendAPIs {
          if let needed = api.backendProtocol, needed != backend.backendProtocol {
            throw FieldError(
              at + [.key("frontend_apis")],
              "INFERENCE_PROTOCOL_UNSUPPORTED: \(api.rawValue) needs a \(needed.rawValue) backend; '\(value.backend)' is \(backend.backendProtocol.rawValue) and no translating adapter is qualified"
            )
          }
          if api == .anthropicCountTokens, profile.tokenCounter != .backend {
            throw FieldError(
              at + [.key("frontend_apis")],
              "anthropic-count-tokens needs a qualified exact token counter (token_counter: \"backend\")"
            )
          }
        }
        out[name] = value
      }
      return out
    }
    return InferenceConfig(
      mode: mode, globalLimits: limits, profiles: profiles, backends: backends, services: services)
  }

  static func globalLimits(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> InferenceGlobalLimits
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: [
      "max_active_requests", "max_queued_requests", "max_request_buffer_bytes",
    ])
    let d = InferenceGlobalLimits.defaults
    return InferenceGlobalLimits(
      maxActiveRequests: try r.defaulted(
        "max_active_requests", d.maxActiveRequests, bounded(1...64)),
      maxQueuedRequests: try r.defaulted(
        "max_queued_requests", d.maxQueuedRequests, bounded(0...1024)),
      maxRequestBufferBytes: try r.defaulted(
        "max_request_buffer_bytes", d.maxRequestBufferBytes, byteBounded((1 << 20)...(1 << 30))))
  }

  static func profile(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> QualificationProfileConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: [
      "protocol", "completion_evidence", "stream_close_drain_ms", "context_overflow",
      "input_overhead", "max_input_bytes", "max_request_body_bytes", "token_counter",
    ])
    let overhead = try r.required("input_overhead") { v, p throws(FieldError) in
      let o = try ObjectReader(v, at: p)
      try o.rejectUnknown(allowing: ["per_request_bytes", "per_message_bytes"])
      return (
        try o.required("per_request_bytes", bounded(0...(1 << 20))),
        try o.required("per_message_bytes", bounded(0...(1 << 16)))
      )
    }
    return QualificationProfileConfig(
      name: "",
      backendProtocol: try r.required("protocol") { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, InferenceProtocol.allCases)
      },
      completionEvidence: try r.required("completion_evidence") { v, p throws(FieldError) in
        if case .string("explicit") = v {
          throw FieldError(
            p, "completion evidence 'explicit' has no qualified adapter in this release")
        }
        return try Parse.stringEnum(v, p, CompletionEvidenceMode.allCases)
      },
      streamCloseDrainMilliseconds: try r.defaulted(
        "stream_close_drain_ms", 500, bounded(0...60_000)),
      contextOverflow: try r.required("context_overflow") { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, ContextOverflowMode.allCases)
      },
      overheadPerRequestBytes: overhead.0, overheadPerMessageBytes: overhead.1,
      maxInputBytes: try r.required("max_input_bytes", byteBounded(1...(64 << 20))),
      maxRequestBodyBytes: try r.defaulted(
        "max_request_body_bytes", 4 << 20, byteBounded(1024...(64 << 20))),
      tokenCounter: try r.defaulted("token_counter", .none) { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, TokenCounterMode.allCases)
      })
  }

  static func backend(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> InferenceBackendConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: [
      "base_url", "protocol", "qualification_profile", "max_active_requests", "credential",
      "run_as", "managed",
    ])
    let url = try r.required("base_url", Parse.string)
    guard let port = loopbackPort(url) else {
      throw FieldError(
        r.child("base_url"),
        "must be http://127.0.0.1:<port> with a port in 1024...65535 and no path, query or credentials; DNS names, wildcard, IPv6 and LAN addresses are not accepted"
      )
    }
    let managed = try r.optional("managed", managedBackend)
    let runAs = try r.optional("run_as") { v, p throws(FieldError) in
      let name = try Parse.string(v, p)
      guard isAccountName(name) else {
        throw FieldError(p, "must be a macOS account name ([a-z_][a-z0-9_-]{0,31})")
      }
      return name
    }
    let credential = try r.optional("credential") { v, p throws(FieldError) in
      let raw = try Parse.secret(v, p)
      guard let reference = CredentialReference(raw.expose()) else {
        throw FieldError(
          p, "literal credentials are not accepted; use a `cmd:` or `vault:<name>` reference")
      }
      return reference
    }
    let operation: InferenceBackendConfig.Operation
    if let managed {
      if r.members["credential"] != nil {
        throw FieldError(
          r.child("credential"),
          "a managed backend's credential is provisioned into the Keychain; remove this field")
      }
      if let runAs, runAs != ManagedBackendConfig.roleAccount {
        throw FieldError(
          r.child("run_as"), "a managed backend runs as \(ManagedBackendConfig.roleAccount)")
      }
      operation = .managed(managed)
    } else {
      operation = .external(credential: credential, runAs: runAs)
    }
    return InferenceBackendConfig(
      port: port,
      backendProtocol: try r.required("protocol") { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, InferenceProtocol.allCases)
      },
      profile: try r.required("qualification_profile", Parse.string),
      maxActiveRequests: try r.defaulted("max_active_requests", 1, bounded(1...64)),
      operation: operation)
  }

  static func managedBackend(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> ManagedBackendConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: [
      "server", "python", "install", "model", "memory_limit", "confinement",
    ])
    _ = try r.required("server") { v, p throws(FieldError) in
      guard case .string("mlx-lm") = v else { throw FieldError(p, "only \"mlx-lm\" is supported") }
    }
    let python = try r.optional("python") { v, p throws(FieldError) in
      let raw = try Parse.string(v, p)
      guard raw.hasPrefix("/") else { throw FieldError(p, "must be an absolute path") }
      return HostPath(absolute: raw)
    }
    let install = try r.optional("install") { v, p throws(FieldError) in
      let version = try Parse.string(v, p)
      guard ManagedBackendConfig.isQualifiedVersion(version) else {
        throw FieldError(
          p,
          "must be an mlx-lm \(ManagedBackendConfig.qualifiedMLXLM)x version the launcher is qualified for"
        )
      }
      return version
    }
    let runtime: ManagedBackendConfig.Runtime
    switch (python, install) {
    case (let path?, nil): runtime = .python(path)
    case (nil, let version?): runtime = .install(version: version)
    default: throw FieldError(path, "set exactly one of `python` or `install`")
    }
    let model = try r.required("model") { v, p throws(FieldError) -> ManagedBackendConfig.Model in
      if case .string(let raw) = v {
        guard raw.hasPrefix("/") else { throw FieldError(p, "must be an absolute directory") }
        return .directory(HostPath(absolute: raw))
      }
      let m = try ObjectReader(v, at: p)
      try m.rejectUnknown(allowing: ["repo", "revision"])
      let repo = try m.required("repo", Parse.string)
      let revision = try m.required("revision", Parse.string)
      guard ManagedBackendConfig.isRepository(repo) else {
        throw FieldError(m.child("repo"), "must be OWNER/NAME")
      }
      guard ManagedBackendConfig.isHex(revision) else {
        throw FieldError(m.child("revision"), "must be a 40-hex commit")
      }
      return .fetch(repository: repo, revision: revision)
    }
    return ManagedBackendConfig(
      runtime: runtime, model: model,
      memoryLimitBytes: try r.optional(
        "memory_limit", byteBounded(ManagedBackendConfig.memoryLimitRange)),
      confinement: try r.defaulted("confinement", .seatbelt) { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, ManagedBackendConfig.Confinement.allCases)
      })
  }

  static func isAccountName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard (1...32).contains(bytes.count),
      bytes[0] == UInt8(ascii: "_") || (0x61...0x7A).contains(bytes[0])
    else { return false }
    return bytes.allSatisfy {
      (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) || $0 == UInt8(ascii: "_")
        || $0 == UInt8(ascii: "-")
    }
  }

  static func service(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> InferenceServiceConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: [
      "backend", "upstream_model", "frontend_apis", "max_context_tokens",
      "default_output_tokens", "max_output_tokens", "max_input_bytes",
    ])
    let apis = try r.required("frontend_apis") { v, p throws(FieldError) in
      try Parse.array(v, p) { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, InferenceAPI.allCases)
      }
    }
    guard !apis.isEmpty, Set(apis).count == apis.count else {
      throw FieldError(r.child("frontend_apis"), "must list each granted API once")
    }
    let maxOutput = try r.defaulted("max_output_tokens", 8_192, bounded(1...32_768))
    let defaultOutput = try r.defaulted(
      "default_output_tokens", min(4_096, maxOutput), bounded(1...32_768))
    guard defaultOutput <= maxOutput else {
      throw FieldError(r.child("default_output_tokens"), "must not exceed max_output_tokens")
    }
    let model = try r.required("upstream_model", Parse.string)
    guard !model.isEmpty, model.utf8.count <= 1024 else {
      throw FieldError(r.child("upstream_model"), "must be 1...1024 bytes")
    }
    return InferenceServiceConfig(
      backend: try r.required("backend", Parse.string), upstreamModel: model, frontendAPIs: apis,
      maxContextTokens: try r.required("max_context_tokens", bounded(1...10_000_000)),
      defaultOutputTokens: defaultOutput, maxOutputTokens: maxOutput,
      maxInputBytes: try r.optional("max_input_bytes", byteBounded(1...(64 << 20))))
  }

  /// A guarded `local_model` needs `inference.mode = "required"`, a known
  /// service and the agent's protocol; under `required` the legacy form is
  /// refused (§11.3).
  static func checkLocalSelection(
    _ agent: AgentConfig, agent name: String, needs api: InferenceAPI, _ inference: InferenceConfig,
    _ r: ObjectReader
  ) throws(FieldError) {
    let path = r.child(name) + [.key("local_model")]
    switch agent.localSelection {
    case .service(let service)?:
      guard inference.mode == .required else {
        throw FieldError(
          path + [.key("service")],
          "a guarded inference service needs inference.mode = \"required\"")
      }
      guard let resolved = inference.services[service] else {
        throw FieldError(path + [.key("service")], "unknown inference service '\(service)'")
      }
      guard resolved.frontendAPIs.contains(api) else {
        throw FieldError(
          path + [.key("service")],
          "INFERENCE_PROTOCOL_UNSUPPORTED: \(name) needs a service granting \(api.rawValue); '\(service)' grants \(resolved.frontendAPIs.map(\.rawValue).joined(separator: ", "))"
        )
      }
    case .endpoint?:
      guard inference.mode == .off else {
        throw FieldError(
          path,
          "inference.mode = \"required\" refuses a raw local_model endpoint; use { \"service\": NAME }"
        )
      }
    case nil: break
    }
  }

  static func loopbackPort(_ text: String) -> UInt16? {
    let prefix = "http://127.0.0.1:"
    guard text.hasPrefix(prefix) else { return nil }
    var rest = Substring(text.dropFirst(prefix.count))
    if rest.hasSuffix("/") { rest = rest.dropLast() }
    guard !rest.isEmpty, rest.utf8.count <= 5, rest.utf8.allSatisfy({ (48...57).contains($0) }),
      rest.first != "0", let port = UInt16(rest), port >= 1024
    else { return nil }
    return port
  }

  static func checkName(_ name: String, _ path: [JSONPathComponent]) throws(FieldError) {
    _ = try Parse.domain(path) { () throws(ValidationError) in try InferenceServiceName(name) }
  }

  static func bounded(_ range: ClosedRange<Int>) -> (JSONValue, [JSONPathComponent])
    throws(FieldError) -> Int
  {
    { v, p throws(FieldError) in
      let value = try Parse.unsigned(v, p, as: UInt64.self)
      guard value >= UInt64(range.lowerBound), value <= UInt64(range.upperBound) else {
        throw FieldError(p, "must be in \(range.lowerBound)...\(range.upperBound)")
      }
      return Int(value)
    }
  }

  /// A byte count (integer or `"4MiB"`) within `range`.
  static func byteBounded(_ range: ClosedRange<Int>) -> (JSONValue, [JSONPathComponent])
    throws(FieldError) -> Int
  {
    { v, p throws(FieldError) in
      let bytes = try Parse.byteCount(v, p).bytes
      guard bytes >= UInt64(range.lowerBound), bytes <= UInt64(range.upperBound) else {
        throw FieldError(p, "must be in \(range.lowerBound)...\(range.upperBound) bytes")
      }
      return Int(bytes)
    }
  }
}
