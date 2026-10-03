/// Identifiers shared with the Apple runtime and persisted in host state.
/// Constructors enforce the character, length and ownership rules used
/// when creating and decoding runtime records.

private func isLowerAlnumOrDash(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
}

/// A runtime object name iso generated: `[a-z0-9]([a-z0-9-]*[a-z0-9])?`, at
/// most 48 characters. Never derived from project names, users, or paths.
package struct MachineName: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 48
  package let rawValue: String

  package init(_ name: String) throws(ValidationError) {
    let bytes = Array(name.utf8)
    guard !bytes.isEmpty, bytes.count <= Self.maxLength, bytes.allSatisfy(isLowerAlnumOrDash),
      bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-")
    else { throw ValidationError("invalid runtime object name \(debugQuoted(name))") }
    rawValue = name
  }

  /// `iso-<owner8>-<16 random hex>`.
  package static func generate(for owner: OwnerID, randomHex: String) throws(ValidationError)
    -> MachineName
  {
    try MachineName("iso-\(owner.short)-\(randomHex)")
  }

  /// Whether this name was generated for `owner`. Necessary but never
  /// sufficient for deletion: callers also require matching local metadata.
  package func belongs(to owner: OwnerID) -> Bool {
    rawValue.hasPrefix("iso-\(owner.short)-")
  }

  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// 32 lowercase hex characters identifying one installation's resources.
package struct OwnerID: Hashable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    let bytes = Array(value.utf8)
    let hex = bytes.allSatisfy {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
    }
    guard bytes.count == 32, hex else {
      throw ValidationError("invalid owner id \(debugQuoted(value))")
    }
    rawValue = value
  }

  /// The 8-character prefix embedded in generated names.
  package var short: String { String(rawValue.prefix(8)) }
  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Identifies one runtime mutation (`iso-sandbox --operation`).
package struct OperationID: Hashable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 64, bytes.allSatisfy(isLowerAlnumOrDash) else {
      throw ValidationError("invalid operation id \(debugQuoted(value))")
    }
    rawValue = value
  }

  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The unprivileged uid-1000 guest account: `[a-z_][a-z0-9_-]*`, at most 32
/// characters, never `root`.
package struct GuestUser: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 32
  package static let `default` = try! GuestUser("ubuntu")
  package let rawValue: String

  package init(_ name: String) throws(ValidationError) {
    guard !name.isEmpty else { throw ValidationError("guest user must not be empty") }
    let length = name.utf8.count
    guard length <= Self.maxLength else {
      throw ValidationError("guest user too long (\(length) chars, max \(Self.maxLength))")
    }
    guard name != "root" else {
      throw ValidationError(
        "guest user must not be 'root'; iso requires an unprivileged uid-1000 account")
    }
    for (index, scalar) in name.unicodeScalars.enumerated() {
      let lower = ("a"..."z").contains(scalar)
      if index == 0 {
        guard lower || scalar == "_" else {
          throw ValidationError("guest user must start with [a-z_], got \(quoted(scalar))")
        }
      } else if !(lower || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-") {
        throw ValidationError(
          "guest user contains invalid character \(quoted(scalar)) (allowed: a-z, 0-9, '_', '-')")
      }
    }
    rawValue = name
  }

  package var home: String { "/home/\(rawValue)" }
  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Rust `{:?}` quoting for strings in diagnostics.
package func debugQuoted(_ text: String) -> String {
  "\"" + text.unicodeScalars.map { $0.escaped(asASCII: false) }.joined() + "\""
}

/// Replace control characters (other than newline and tab) and Unicode
/// format characters, so text echoed from the runtime or a guest can neither
/// drive the operator's terminal nor reorder or hide what it shows.
package func sanitizeForDisplay(_ text: String) -> String {
  neutralizeControls(text.trimmingUnicodeWhitespace())
}

/// `sanitizeForDisplay` without the trim: for log and error lines whose
/// layout (indentation) is part of the message.
package func neutralizeControls(_ text: String) -> String {
  var out = String.UnicodeScalarView()
  for scalar in text.unicodeScalars {
    let control = scalar.properties.generalCategory == .control
    let format = scalar.properties.generalCategory == .format
    if (control && scalar != "\n" && scalar != "\t") || format {
      out.append("?")
    } else {
      out.append(scalar)
    }
  }
  return String(out)
}

/// Dotted-quad IPv4 address, parsed like Rust `Ipv4Addr::from_str`: four
/// decimal octets, no leading zeros, no surrounding text.
package struct IPv4Address: Hashable, Sendable, CustomStringConvertible, Codable {
  package let octets: [UInt8]

  package init(_ text: String) throws(ValidationError) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    var octets: [UInt8] = []
    for part in parts {
      let digits = Array(part.utf8)
      guard parts.count == 4, (1...3).contains(digits.count),
        digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
        digits.count == 1 || digits[0] != UInt8(ascii: "0"),
        let value = UInt8(String(part))
      else { throw ValidationError("invalid IPv4 address \(debugQuoted(text))") }
      octets.append(value)
    }
    self.octets = octets
  }

  package var description: String { octets.map(String.init).joined(separator: ".") }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
