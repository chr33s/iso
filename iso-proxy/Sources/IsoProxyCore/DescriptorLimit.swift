import Darwin

/// The open-file soft limit the proxy needs to hold `Limits.descriptors`.
/// A launchd default of 256 would cap the documented connection and socket
/// limits well below their stated values, so startup raises it or refuses.
package enum DescriptorLimit {
  package enum Failure: Error, Equatable, CustomStringConvertible {
    /// The hard limit is below what the documented limits need.
    case hardLimitTooLow(hard: UInt64, required: UInt64)
    /// The kernel refused to read or raise the soft limit.
    case unavailable(errno: Int32)

    package var description: String {
      switch self {
      case .hardLimitTooLow(let hard, let required):
        "open-file hard limit \(hard) is below the \(required) descriptors the proxy limits need"
      case .unavailable(let code):
        "open-file limit could not be raised (errno \(code))"
      }
    }
  }

  /// The soft limit to set, or nil when `soft` already suffices. Never
  /// lowers the soft limit; never asks for more than `hard`.
  package static func plan(soft: UInt64, hard: UInt64, required: UInt64) throws(Failure)
    -> UInt64?
  {
    guard soft < required else { return nil }
    guard hard >= required else { throw .hardLimitTooLow(hard: hard, required: required) }
    return required
  }

  /// Raises the soft `RLIMIT_NOFILE` to `required`, clamped to the hard limit.
  /// Returns the previous soft limit when it changed.
  @discardableResult
  package static func raise(to required: Int) throws(Failure) -> UInt64? {
    var limit = rlimit()
    // getrlimit and setrlimit only read or write the one rlimit borrowed here.
    guard unsafe getrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw .unavailable(errno: errno) }
    let previous = limit.rlim_cur
    guard
      let soft = try plan(soft: previous, hard: limit.rlim_max, required: UInt64(required))
    else { return nil }
    limit.rlim_cur = soft
    guard unsafe setrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw .unavailable(errno: errno) }
    return previous
  }
}
