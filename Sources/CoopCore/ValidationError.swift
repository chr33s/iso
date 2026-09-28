/// A rejected value at a validating boundary. Messages name the offending
/// field or character class; callers that handle secret-bearing input must not
/// construct one from the secret itself.
public struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
  public let message: String

  public init(_ message: String) { self.message = message }

  public var description: String { message }
}
