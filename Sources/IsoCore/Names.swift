/// Validated identifiers shared by configuration, state and commands. Each is
/// constructed only through its validating initializer, so holders can use the
/// value in paths, argv elements and SSH config without re-checking.

/// Safe-name character class `[a-zA-Z0-9_.-]` shared by image names, repo
/// segments and secret-store names so they cannot drift apart.
public func isSafeNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar {
  case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".": true
  default: false
  }
}

public func validateSafeCharacters(_ name: String, kind: String) throws(ValidationError) {
  if let bad = name.unicodeScalars.first(where: { !isSafeNameCharacter($0) }) {
    throw ValidationError(
      "\(kind) contains invalid character \(quoted(bad)) (allowed: a-z, A-Z, 0-9, '-', '_', '.')")
  }
}

/// Rust-`{:?}`-style quoting so control characters stay visible in errors.
func quoted(_ scalar: Unicode.Scalar) -> String {
  "'\(scalar.escaped(asASCII: false))'"
}

private func isInstanceNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar {
  case "a"..."z", "A"..."Z", "0"..."9", "-", "_": true
  default: false
  }
}

public struct InstanceName: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  public static let maxLength = 64
  public let rawValue: String

  public init(_ name: String) throws(ValidationError) {
    guard !name.isEmpty else { throw ValidationError("Instance name must not be empty") }
    let length = name.utf8.count
    guard length <= Self.maxLength else {
      throw ValidationError("Instance name too long (\(length) chars, max \(Self.maxLength))")
    }
    if let bad = name.unicodeScalars.first(where: { !isInstanceNameCharacter($0) }) {
      var message =
        "Instance name contains invalid character \(quoted(bad)) (allowed: a-z, A-Z, 0-9, '-', '_')"
      if name.unicodeScalars.contains("/") || name.unicodeScalars.first == "~" {
        message +=
          ".\nIf you meant to create or reconnect to a project environment, use `iso up <PATH>`"
      }
      throw ValidationError(message)
    }
    rawValue = name
  }

  public var description: String { rawValue }
  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ImageName: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  public static let maxLength = 64
  public static let `default` = try! ImageName("default")
  public let rawValue: String

  public init(_ name: String) throws(ValidationError) {
    guard !name.isEmpty else { throw ValidationError("Image name is empty") }
    // A leading '.' covers '.' and '..' and keeps dotfiles out of images/.
    guard name.unicodeScalars.first != "." else {
      throw ValidationError("Image name '\(name)' must not start with '.'")
    }
    let length = name.utf8.count
    guard length <= Self.maxLength else {
      throw ValidationError("Image name too long (\(length) chars, max \(Self.maxLength))")
    }
    try validateSafeCharacters(name, kind: "Image name")
    rawValue = name
  }

  public var description: String { rawValue }
  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// POSIX environment variable name `[a-zA-Z_][a-zA-Z0-9_]*`.
public struct EnvVarName: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ name: String) throws(ValidationError) {
    guard let first = name.unicodeScalars.first else {
      throw ValidationError("env var name must not be empty")
    }
    guard first.isASCIILetter || first == "_" else {
      throw ValidationError(
        "env var name '\(name)' must start with a letter or '_' (got \(quoted(first)))")
    }
    for scalar in name.unicodeScalars.dropFirst()
    where !(scalar.isASCIILetter || scalar.isASCIIDigit || scalar == "_") {
      throw ValidationError(
        "env var name '\(name)' contains invalid character \(quoted(scalar)) (allowed: a-z, A-Z, 0-9, '_')"
      )
    }
    rawValue = name
  }

  public var description: String { rawValue }
  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// GitHub `owner/repo` slug: exactly one `/`, non-empty segments, safe class.
public struct RepoSlug: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ slug: String) throws(ValidationError) {
    let scalars = slug.unicodeScalars
    guard let slash = scalars.firstIndex(of: "/") else {
      throw ValidationError("Repo slug must be 'owner/repo', got '\(slug)'")
    }
    let owner = scalars[..<slash]
    let repo = scalars[scalars.index(after: slash)...]
    guard !owner.isEmpty, !repo.isEmpty else {
      throw ValidationError("Repo slug 'owner/repo' must have non-empty owner and repo: '\(slug)'")
    }
    guard !repo.contains("/") else {
      throw ValidationError("Repo slug must contain exactly one '/' separator: '\(slug)'")
    }
    guard owner.allSatisfy(isSafeNameCharacter), repo.allSatisfy(isSafeNameCharacter) else {
      throw ValidationError(
        "Repo slug '\(slug)' contains invalid characters (allowed: a-z, A-Z, 0-9, '-', '_', '.')")
    }
    rawValue = slug
  }

  /// CLI form: surrounding whitespace is trimmed before validation.
  public static func parseCLI(_ argument: String) throws(ValidationError) -> RepoSlug {
    try RepoSlug(argument.trimmingASCIIWhitespace())
  }

  public var owner: String { String(rawValue.split(separator: "/", maxSplits: 1)[0]) }
  public var repo: String { String(rawValue.split(separator: "/", maxSplits: 1)[1]) }
  public var description: String { rawValue }
  public static func < (a: Self, b: Self) -> Bool {
    Array(a.rawValue.utf8).lexicographicallyPrecedes(b.rawValue.utf8)
  }

  private static let urlPrefixes = [
    "https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:",
  ]

  /// Parse `git remote get-url` output or a `--git-repo` argument. Returns nil
  /// for non-GitHub URLs and for paths that are not exactly `owner/repo`.
  public static func parse(url: String) -> RepoSlug? {
    let bytes = Array(url.trimmingUnicodeWhitespace().utf8)
    for prefix in urlPrefixes where bytes.starts(with: prefix.utf8) {
      var path = bytes[prefix.utf8.count...]
      while path.last == UInt8(ascii: "/") { path = path.dropLast() }
      if path.reversed().starts(with: "tig.".utf8) {
        path = path.dropLast(4)
      }
      return try? RepoSlug(String(decoding: path, as: UTF8.self))
    }
    return nil
  }
}

extension Unicode.Scalar {
  var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
  var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

extension String {
  func trimmingASCIIWhitespace() -> String {
    let scalars = unicodeScalars
    guard let start = scalars.firstIndex(where: { !$0.isASCIIWhitespace }) else { return "" }
    let end = scalars.lastIndex(where: { !$0.isASCIIWhitespace })!
    return String(scalars[start...end])
  }

  /// Rust `str::trim`: strips Unicode `White_Space` from both ends.
  public func trimmingUnicodeWhitespace() -> String {
    let scalars = unicodeScalars
    guard let start = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
    let end = scalars.lastIndex(where: { !$0.properties.isWhitespace })!
    return String(scalars[start...end])
  }
}

extension Unicode.Scalar {
  var isASCIIWhitespace: Bool {
    self == " " || self == "\t" || self == "\n" || self == "\r" || self == "\u{0C}"
  }
}
