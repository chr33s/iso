import IsoConfiguration
import IsoCore

/// The closed host-control error contract (spec section 6.4). Callers branch
/// on `code` and `retry`, never on message text.
package struct HostControlError: Error, Equatable, Sendable, CustomStringConvertible {
  package enum Code: String, Sendable, CaseIterable {
    case hostUnreachable = "HOST_UNREACHABLE"
    case hostIdentityChanged = "HOST_IDENTITY_CHANGED"
    case hostProtocolIncompatible = "HOST_PROTOCOL_INCOMPATIBLE"
    case hostRuntimeUnqualified = "HOST_RUNTIME_UNQUALIFIED"
    case ownerMismatch = "OWNER_MISMATCH"
    case instanceNotFound = "INSTANCE_NOT_FOUND"
    case instanceDestroyed = "INSTANCE_DESTROYED"
    case instanceAlreadyRunning = "INSTANCE_ALREADY_RUNNING"
    case instanceIncompatible = "INSTANCE_INCOMPATIBLE"
    case instanceBusy = "INSTANCE_BUSY"
    case generationConflict = "GENERATION_CONFLICT"
    case operationIDConflict = "OPERATION_ID_CONFLICT"
    case operationUncertain = "OPERATION_UNCERTAIN"
    case operationNotFound = "OPERATION_NOT_FOUND"
    case cancelTooLate = "CANCEL_TOO_LATE"
    case sessionInUse = "SESSION_IN_USE"
    case sessionExpired = "SESSION_EXPIRED"
    case sessionIdentityChanged = "SESSION_IDENTITY_CHANGED"
    case guestKeyChanged = "GUEST_KEY_CHANGED"
    case resultsUnavailable = "RESULTS_UNAVAILABLE"
    case unsupportedCapability = "UNSUPPORTED_CAPABILITY"
    case migrationRequired = "MIGRATION_REQUIRED"
    case limitExceeded = "LIMIT_EXCEEDED"
    case invalidRequest = "INVALID_REQUEST"

    /// The retry guidance a client follows when the server sends none.
    package var defaultRetry: Retry {
      switch self {
      case .hostUnreachable: .safeReadRetry
      case .operationUncertain: .retrySameOperationID
      case .instanceBusy, .generationConflict, .instanceAlreadyRunning, .sessionExpired,
        .sessionIdentityChanged, .limitExceeded, .cancelTooLate:
        .refreshObservationThenNewOperation
      case .hostIdentityChanged, .ownerMismatch, .operationIDConflict, .guestKeyChanged,
        .instanceDestroyed, .instanceNotFound, .sessionInUse, .migrationRequired,
        .operationNotFound, .resultsUnavailable:
        .explicitIdentityResolution
      case .hostProtocolIncompatible, .hostRuntimeUnqualified, .instanceIncompatible,
        .unsupportedCapability, .invalidRequest:
        .unsupported
      }
    }
  }

  package enum Retry: String, Sendable, CaseIterable {
    case safeReadRetry = "safe_read_retry"
    case retrySameOperationID = "retry_same_operation_id"
    case refreshObservationThenNewOperation = "refresh_observation_then_new_operation"
    case explicitIdentityResolution = "explicit_identity_resolution"
    case unsupported
  }

  package static let maxMessageBytes = 512
  package static let maxDetails = 16

  package let code: Code
  package let message: String
  package let retry: Retry
  /// Bounded nonsecret identifiers (operation, instance, session ids).
  package let details: [String: String]

  package init(
    _ code: Code, _ message: String, retry: Retry? = nil, details: [String: String] = [:]
  ) {
    self.code = code
    self.message = Self.sanitize(message)
    self.retry = retry ?? code.defaultRetry
    var bounded: [String: String] = [:]
    for key in details.keys.sorted().prefix(Self.maxDetails) {
      bounded[Self.sanitize(key, limit: 64)] = Self.sanitize(details[key] ?? "", limit: 128)
    }
    self.details = bounded
  }

  package static func invalidRequest(_ message: String) -> HostControlError {
    HostControlError(.invalidRequest, message)
  }

  package static func unsupported(_ capability: String) -> HostControlError {
    HostControlError(.unsupportedCapability, "\(capability) is not supported on this host")
  }

  package var description: String { "\(code.rawValue): \(message)" }

  /// Control characters neutralized and length bounded; never embeds frame bytes.
  package static func sanitize(_ text: String, limit: Int = maxMessageBytes) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      let piece =
        isDisplayControl(scalar) ? "?" : String(Character(scalar))
      guard out.utf8.count + piece.utf8.count <= limit else { break }
      out += piece
    }
    return out
  }

  package var wire: JSONValue {
    var builder = WireBuilder()
    builder.set("code", code.rawValue)
    builder.set("message", message)
    builder.set("retry", retry.rawValue)
    builder.set("details", .object(details.mapValues { .string($0) }))
    return builder.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var reader = try WireObject(value, field: "error")
    let code = try reader.string("code")
    let retry = try reader.string("retry")
    guard let decodedCode = Code(rawValue: code), let decodedRetry = Retry(rawValue: retry) else {
      throw .invalidRequest("unknown error code or retry class")
    }
    let message = try reader.string("message")
    var details: [String: String] = [:]
    if let raw = reader.raw("details") {
      guard case .object(let members) = raw, members.count <= Self.maxDetails else {
        throw .invalidRequest("error.details must be a bounded object")
      }
      for (key, value) in members {
        details[key] = try WireObject.string(value, field: "error.details")
      }
    }
    try reader.finish()
    self.init(decodedCode, message, retry: decodedRetry, details: details)
  }
}

/// C0/C1 controls, DEL, and bidirectional overrides/isolates: never shown raw.
func isDisplayControl(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 0..<0x20, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
  default: false
  }
}
