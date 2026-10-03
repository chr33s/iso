/// A rejected value at a validating boundary. Messages name the offending
/// field or character class; callers that handle secret-bearing input must not
/// construct one from the secret itself.
package struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
  package let message: String

  package init(_ message: String) { self.message = message }

  package var description: String { message }
}
