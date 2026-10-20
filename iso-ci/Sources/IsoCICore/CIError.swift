import Foundation

/// The one error type crossing iso-ci boundaries. `code` is stable and
/// machine-readable (spec section 12: typed status/error codes); `message`
/// is bounded human text that never quotes secret or guest-supplied bytes.
package struct CIError: Error, Sendable, Equatable, CustomStringConvertible {
  package enum Code: String, Sendable, CaseIterable, Codable {
    case invalidRequest = "INVALID_REQUEST"
    case invalidConfiguration = "INVALID_CONFIGURATION"
    case unsupported = "UNSUPPORTED"
    /// A required host capability (for example NET-HANDOFF-1) is absent.
    case capabilityMissing = "CAPABILITY_MISSING"
    /// Qualification evidence is missing, stale or does not cover the tuple.
    case qualificationMissing = "QUALIFICATION_MISSING"
    case admissionRefused = "ADMISSION_REFUSED"
    case hostUnreachable = "HOST_UNREACHABLE"
    case hostIdentityChanged = "HOST_IDENTITY_CHANGED"
    case hostRefused = "HOST_REFUSED"
    /// A mutation was sent and no reply arrived: resolve the same identity.
    case operationUncertain = "OPERATION_UNCERTAIN"
    case notFound = "NOT_FOUND"
    case conflict = "CONFLICT"
    case budgetExceeded = "BUDGET_EXCEEDED"
    case unauthorized = "UNAUTHORIZED"
    case githubUnavailable = "GITHUB_UNAVAILABLE"
    case githubRefused = "GITHUB_REFUSED"
    case registrationUncertain = "REGISTRATION_UNCERTAIN"
    case compatibilityRejected = "COMPATIBILITY_REJECTED"
    case confinementUnavailable = "CONFINEMENT_UNAVAILABLE"
    case storage = "STORAGE"
    case controllerUnavailable = "CONTROLLER_UNAVAILABLE"
    case controllerBusy = "CONTROLLER_BUSY"
    case guestFailed = "GUEST_FAILED"
    case timeout = "TIMEOUT"
    case internalError = "INTERNAL"
  }

  package static let maxMessageBytes = 1_024

  package let code: Code
  package let message: String
  package let details: [String: String]

  package init(_ code: Code, _ message: String, details: [String: String] = [:]) {
    self.code = code
    self.message = Self.bounded(message)
    self.details = details.mapValues(Self.bounded)
  }

  package var description: String { "\(code.rawValue): \(message)" }

  package static func invalid(_ message: String) -> CIError { CIError(.invalidRequest, message) }
  package static func config(_ message: String) -> CIError {
    CIError(.invalidConfiguration, message)
  }
  package static func unsupported(_ message: String) -> CIError { CIError(.unsupported, message) }
  package static func storage(_ message: String) -> CIError { CIError(.storage, message) }

  /// Strips control characters and caps length so a diagnostic can never
  /// carry terminal escapes or an unbounded guest payload.
  package static func bounded(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      if scalar.value < 0x20 || scalar.value == 0x7F || (0x80..<0xA0).contains(scalar.value) {
        out.unicodeScalars.append(scalar == "\n" || scalar == "\t" ? " " : "?")
      } else {
        out.unicodeScalars.append(scalar)
      }
      if out.utf8.count >= maxMessageBytes { return out + "…" }
    }
    return out
  }

  package var json: JSONValue {
    var members: [String: JSONValue] = [
      "code": .string(code.rawValue), "message": .string(message),
    ]
    if !details.isEmpty { members["details"] = .object(details.mapValues { .string($0) }) }
    return .object(members)
  }

  package init(json value: JSONValue) throws(CIError) {
    var reader = try ObjectReader(value, field: "error")
    guard let code = Code(rawValue: try reader.string("code")) else {
      throw CIError.invalid("unknown error code")
    }
    let message = try reader.string("message")
    var details: [String: String] = [:]
    if let raw = reader.optional("details") {
      guard case .object(let members) = raw else { throw CIError.invalid("error.details") }
      for (key, value) in members {
        guard case .string(let text) = value else { throw CIError.invalid("error.details") }
        details[key] = text
      }
    }
    try reader.finish()
    self.init(code, message, details: details)
  }
}

/// Converts any thrown error into a `CIError`, keeping typed ones intact.
package func ciError(_ error: any Error, _ code: CIError.Code = .internalError) -> CIError {
  (error as? CIError) ?? CIError(code, "\(error)")
}
