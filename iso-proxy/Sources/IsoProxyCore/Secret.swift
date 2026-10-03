/// Explicit access prevents accidental string interpolation of credentials.
package struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  private let value: String
  package init(_ value: String) { self.value = value }
  package func expose() -> String { value }
  package var description: String { "<redacted>" }
  package var debugDescription: String { "Secret(<redacted>)" }
}
