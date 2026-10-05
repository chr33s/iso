import IsoCore

/// What a listing reports for one instance.
package enum InstanceHealth: Sendable {
  case stopped
  case running
  /// The sandbox is running but its live readiness proof failed.
  case unhealthy(InstanceUnhealthy)
}

/// A running filtered sandbox whose live readiness proof (boot, policy,
/// owner, companion, broker or tunnel) failed. Commands that need it fail
/// with this error; status and listings report the instance unhealthy.
package struct InstanceUnhealthy: Error, Sendable, CustomStringConvertible {
  package let instance: InstanceName
  let error: ContextError

  package init(_ instance: InstanceName, cause: any Error) {
    self.instance = instance
    error = AppleBackend.unreachable(instance, cause: cause)
  }

  package var cause: any Error { error.cause }
  package var description: String { error.description }
  package var alternate: String { error.alternate }

  /// The failed proof on one line, without the instance preamble.
  package var reason: String {
    cause.contextError?.alternate ?? "\(cause)"
  }
}

extension Error {
  /// The context chain of a `ContextError`, or of an unhealthy instance,
  /// which renders as one.
  package var contextError: ContextError? {
    (self as? ContextError) ?? (self as? InstanceUnhealthy)?.error
  }
}

/// Marks a failure of the filtered readiness proof itself.
struct ReadinessFailure: Error {
  let cause: any Error

  static func wrapping<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch { throw ReadinessFailure(cause: error) }
  }
}
