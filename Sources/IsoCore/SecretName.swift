/// A secret identifier: `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`. Names are
/// identifiers, never filenames (embedded-secrets spec §11).
package struct SecretName: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 128
  package let rawValue: String

  package init(_ text: String) throws(ValidationError) {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty, bytes.count <= Self.maxLength else {
      throw ValidationError("secret name must be 1-\(Self.maxLength) characters")
    }
    guard Self.alphanumeric(bytes[0]) else {
      throw ValidationError("secret name must start with a letter or digit")
    }
    guard bytes.allSatisfy({ Self.alphanumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D })
    else {
      throw ValidationError("secret name may contain only letters, digits, '.', '_' and '-'")
    }
    rawValue = text
  }

  /// The name a `vault:<name>` reference points at; nil for any other text
  /// and for an invalid name.
  package static func vaultReference(_ text: String) -> SecretName? {
    let prefix = "vault:"
    guard text.hasPrefix(prefix) else { return nil }
    return try? SecretName(String(text.dropFirst(prefix.count)))
  }

  static func alphanumeric(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
  }

  package init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    do {
      try self.init(text)
    } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool {
    a.rawValue.utf8.lexicographicallyPrecedes(b.rawValue.utf8)
  }
}
