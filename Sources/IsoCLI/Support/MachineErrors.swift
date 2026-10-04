import ArgumentParser
import Foundation
import IsoCore
import IsoHost

/// Stable `iso.machine/v1` error codes. Consumers branch on these, never on
/// the message; the set is open-ended, so an unknown code is unsupported
/// rather than fatal.
enum MachineErrorCode: String, Encodable, Sendable {
  case invalidArgument = "INVALID_ARGUMENT"
  case unsupportedMachineOutput = "UNSUPPORTED_MACHINE_OUTPUT"

  case instanceNotFound = "INSTANCE_NOT_FOUND"
  case ambiguousInstance = "AMBIGUOUS_INSTANCE"
  case instanceAlreadyRunning = "INSTANCE_ALREADY_RUNNING"
  case instanceNotRunning = "INSTANCE_NOT_RUNNING"
  case instanceIncompatible = "INSTANCE_INCOMPATIBLE"
  case projectAlreadyAssociated = "PROJECT_ALREADY_ASSOCIATED"

  case interactionRequired = "INTERACTION_REQUIRED"

  // The Apple runtime's existing diagnostic classes (docs/backends.md).
  case appleRuntimeUnavailable = "APPLE_RUNTIME_UNAVAILABLE"
  case appleRuntimeUnqualified = "APPLE_RUNTIME_UNQUALIFIED"
  case appleNetworkIsolation = "APPLE_NETWORK_ISOLATION"
  case appleHostExposure = "APPLE_HOST_EXPOSURE"
  case appleIdentityConflict = "APPLE_IDENTITY_CONFLICT"
  case appleHostKeyChanged = "APPLE_HOST_KEY_CHANGED"
  case appleBootTimeout = "APPLE_BOOT_TIMEOUT"
  case appleSessionExpired = "APPLE_SESSION_EXPIRED"
  case appleOperationUncertain = "APPLE_OPERATION_UNCERTAIN"

  case operationInterrupted = "OPERATION_INTERRUPTED"
  case operationFailed = "OPERATION_FAILED"

  /// Re-running can succeed: after the decision or selection the details
  /// name, or once an in-flight runtime state settles.
  var retryable: Bool {
    switch self {
    case .interactionRequired, .ambiguousInstance, .appleOperationUncertain,
      .appleBootTimeout, .operationInterrupted:
      true
    default: false
    }
  }
}

/// Structured context for an error code; every string is display-sanitized.
enum MachineErrorDetails: Encodable, Equatable, Sendable {
  case devcontainer(path: String, acceptedFlags: [String])
  case passphrase(descriptorVariable: String)
  case githubPAT(repo: String, acceptedFlags: [String])
  case ambiguous(instances: [String], resolution: String?)
  case instance(name: String)
  /// `destroy --all` failed after removing `destroyed`; the cause's own
  /// details, if any, sit beside it.
  indirect case partialDestroy(destroyed: [MachineRemovedInstance], cause: MachineErrorDetails?)

  enum CodingKeys: String, CodingKey {
    case kind, path, instances, resolution, name, repo, destroyed
    case acceptedFlags = "accepted_flags"
    case descriptorVariable = "descriptor_variable"
  }

  func encode(to encoder: any Encoder) throws {
    if case .partialDestroy(let destroyed, let cause) = self {
      try cause?.encode(to: encoder)
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(destroyed, forKey: .destroyed)
      return
    }
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .partialDestroy: break
    case .devcontainer(let path, let flags):
      try values.encode("devcontainer", forKey: .kind)
      try values.encode(path, forKey: .path)
      try values.encode(flags, forKey: .acceptedFlags)
    case .passphrase(let variable):
      try values.encode("passphrase", forKey: .kind)
      try values.encode(variable, forKey: .descriptorVariable)
    case .githubPAT(let repo, let flags):
      try values.encode("github-pat", forKey: .kind)
      try values.encode(repo, forKey: .repo)
      try values.encode(flags, forKey: .acceptedFlags)
    case .ambiguous(let instances, let resolution):
      try values.encode(instances, forKey: .instances)
      try values.encode(resolution, forKey: .resolution)
    case .instance(let name):
      try values.encode(name, forKey: .name)
    }
  }
}

/// One failure as the error document carries it.
struct MachineFailure: Encodable, Sendable {
  /// Messages are bounded: an error chain can carry runtime or guest text.
  static let messageLimit = 4096

  let code: MachineErrorCode
  let message: String
  let details: MachineErrorDetails?

  init(code: MachineErrorCode, message: String, details: MachineErrorDetails?) {
    self.code = code
    self.message = Self.bounded(neutralizeControls(message))
    self.details = details
  }

  /// The most precise typed class along the error's context chain, outermost
  /// first; untyped failures are `OPERATION_FAILED`.
  init(_ error: any Error) {
    if let partial = error as? PartialDestroy {
      let cause = MachineFailure(partial.cause)
      self.init(
        code: cause.code, message: cause.message,
        details: .partialDestroy(destroyed: partial.destroyed, cause: cause.details))
      return
    }
    let message = oneLine(error)
    if Shutdown.isRequested {
      self.init(code: .operationInterrupted, message: message, details: nil)
      return
    }
    var next: (any Error)? = error
    while let current = next {
      if let (code, details) = Self.classify(current) {
        self.init(code: code, message: message, details: details)
        return
      }
      next = (current as? ContextError)?.cause
    }
    self.init(code: .operationFailed, message: message, details: nil)
  }

  static func classify(_ error: any Error) -> (MachineErrorCode, MachineErrorDetails?)? {
    switch error {
    case is ArgumentParser.ValidationError, is IsoCore.ValidationError:
      return (.invalidArgument, nil)
    case let failure as HostFailure:
      return classify(failure.reason)
    case let runtime as RuntimeError:
      return classify(runtime).map { ($0, nil) }
    default:
      return nil
    }
  }

  static func classify(_ reason: HostFailure.Reason) -> (MachineErrorCode, MachineErrorDetails?) {
    switch reason {
    case .instanceNotFound: (.instanceNotFound, nil)
    case .ambiguousInstance(let candidates, let resolution):
      (
        .ambiguousInstance,
        .ambiguous(instances: candidates.map(\.rawValue), resolution: resolution)
      )
    case .instanceAlreadyRunning(let name):
      (.instanceAlreadyRunning, .instance(name: name.rawValue))
    case .instanceNotRunning(let name):
      (.instanceNotRunning, name.map { .instance(name: $0.rawValue) })
    case .instanceIncompatible(let name): (.instanceIncompatible, .instance(name: name.rawValue))
    case .projectAlreadyAssociated(let name):
      (.projectAlreadyAssociated, .instance(name: name.rawValue))
    case .interactionRequired(.devcontainer(let path, let flags)):
      (
        .interactionRequired,
        .devcontainer(
          path: neutralizeControls(path), acceptedFlags: flags.map(neutralizeControls))
      )
    case .interactionRequired(.githubPAT(let repo, let flags)):
      (.interactionRequired, .githubPAT(repo: neutralizeControls(repo), acceptedFlags: flags))
    case .interactionRequired(.passphrase(let variable)):
      (.interactionRequired, .passphrase(descriptorVariable: variable))
    }
  }

  /// `.failed` carries no diagnostic class.
  static func classify(_ error: RuntimeError) -> MachineErrorCode? {
    switch error {
    case .unavailable: .appleRuntimeUnavailable
    case .unqualified: .appleRuntimeUnqualified
    case .networkIsolation: .appleNetworkIsolation
    case .hostExposure: .appleHostExposure
    case .identityConflict: .appleIdentityConflict
    case .hostKeyChanged: .appleHostKeyChanged
    case .bootTimeout: .appleBootTimeout
    case .sessionExpired: .appleSessionExpired
    case .operationUncertain: .appleOperationUncertain
    case .failed: nil
    }
  }

  static func bounded(_ text: String) -> String {
    guard text.utf8.count > messageLimit else { return text }
    var out = ""
    for character in text {
      guard out.utf8.count + character.utf8.count <= messageLimit - 3 else { break }
      out.append(character)
    }
    return out + "..."
  }

  enum CodingKeys: String, CodingKey { case code, message, retryable, details }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(code, forKey: .code)
    try values.encode(message, forKey: .message)
    try values.encode(code.retryable, forKey: .retryable)
    try values.encode(details, forKey: .details)
  }
}

/// `destroy --all` stopped at `cause` after removing `destroyed`. Text mode
/// shows only the cause, as before.
struct PartialDestroy: Error, CustomStringConvertible {
  let destroyed: [MachineRemovedInstance]
  let cause: any Error

  var description: String { "\(cause)" }
}
