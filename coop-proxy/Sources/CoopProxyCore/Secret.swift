/// Explicit access prevents accidental string interpolation of credentials.
public struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  private let value: String
  public init(_ value: String) { self.value = value }
  public func expose() -> String { value }
  public var description: String { "<redacted>" }
  public var debugDescription: String { "Secret(<redacted>)" }
}
