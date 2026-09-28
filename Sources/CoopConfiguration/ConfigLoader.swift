import Foundation

/// Document syntax, chosen by file extension only (never by sniffing).
public enum ConfigFormat: Sendable, Equatable {
  case jsonc
  case json

  public init(path: String) throws(ConfigError) {
    switch (path as NSString).pathExtension {
    case "jsonc": self = .jsonc
    case "json": self = .json
    case "toml":
      throw .migrationRequired(tomlPath: path, jsoncPath: Self.jsoncSibling(of: path))
    default: throw .unsupportedExtension(path: path)
    }
  }

  static func jsoncSibling(of path: String) -> String {
    (path as NSString).deletingPathExtension + ".jsonc"
  }
}

/// Where a command's configuration comes from (spec section 3.4).
public enum ConfigSelection: Sendable, Equatable {
  /// A file to load; missing files follow `missingFileBehavior`.
  case file(path: String, format: ConfigFormat)
  /// No configuration file exists at the default location.
  case defaultsOnly(defaultPath: String)
}

public enum ConfigLoader {
  public static let defaultFileName = "config.jsonc"
  public static let legacyFileName = "config.toml"

  public static func defaultDirectory(home: String?) -> String {
    HostPath(expanding: "~/.coop", home: home ?? ".").path
  }

  /// Resolve `--config` or the default path. An explicit path is used as-is
  /// (even if missing); the default never falls back across formats.
  public static func select(
    explicitPath: String?, home: String?,
    fileExists: (String) -> Bool = FileManager.default.fileExists
  ) throws(ConfigError) -> ConfigSelection {
    if let explicitPath {
      return .file(path: explicitPath, format: try ConfigFormat(path: explicitPath))
    }
    let directory = defaultDirectory(home: home)
    let jsonc = directory + "/" + defaultFileName
    if fileExists(jsonc) { return .file(path: jsonc, format: .jsonc) }
    let toml = directory + "/" + legacyFileName
    if fileExists(toml) { throw .migrationRequired(tomlPath: toml, jsoncPath: jsonc) }
    return .defaultsOnly(defaultPath: jsonc)
  }

  /// Load and validate the selected configuration. A missing explicit file
  /// yields defaults (baseline behavior); read and parse failures never do.
  public static func load(
    _ selection: ConfigSelection, environment: ConfigEnvironment,
    limits: JSONLimits = .configuration
  ) throws(ConfigError) -> CoopConfig {
    switch selection {
    case .defaultsOnly:
      return try decode(.object([:]), path: "<defaults>", environment: environment)
    case .file(let path, let format):
      guard let bytes = try readSnapshot(path, limit: limits.maxBytes) else {
        return try decode(.object([:]), path: path, environment: environment)
      }
      let value = try parse(bytes, format: format, path: path, limits: limits)
      return try decode(value, path: path, environment: environment)
    }
  }

  /// Steps 2–5 of the pipeline on an in-memory snapshot: UTF-8, comment
  /// scan, structural preflight, Foundation decode into `JSONValue`.
  public static func parse(_ bytes: [UInt8], format: ConfigFormat, path: String, limits: JSONLimits)
    throws(ConfigError) -> JSONValue
  {
    guard bytes.count <= limits.maxBytes else {
      throw .preflight(
        path: path, JSONPreflightError(kind: .tooLarge(limit: limits.maxBytes), location: nil))
    }
    let clean: [UInt8]
    switch format {
    case .jsonc:
      do { clean = try JSONCScanner.strip(bytes, policy: .configuration) } catch {
        throw .scan(path: path, error)
      }
    case .json:
      guard String(validating: bytes, as: UTF8.self) != nil else {
        throw .scan(path: path, JSONCScanError(kind: .invalidUTF8, location: nil))
      }
      clean = bytes
    }
    let preflight: JSONPreflightResult
    do { preflight = try JSONPreflight.check(clean, limits: limits) } catch {
      throw .preflight(path: path, error)
    }
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = false
    decoder.userInfo[FractionalPaths.userInfoKey] = FractionalPaths(preflight.fractionalNumberPaths)
    do {
      return try decoder.decode(JSONValue.self, from: Data(clean))
    } catch {
      // Foundation's message can quote document bytes; report only the fact.
      throw .undecodable(path: path)
    }
  }

  /// Step 6: typed decoding and domain validation of a parsed document.
  public static func decode(_ value: JSONValue, path: String, environment: ConfigEnvironment)
    throws(ConfigError) -> CoopConfig
  {
    do {
      return try ConfigDecoder.decode(value, environment: environment)
    } catch {
      switch error {
      case .rootNotObject: throw .rootNotObject(path: path)
      case .retired(let fields): throw .retiredFields(path: path, fields: fields)
      case .field(let failure):
        throw .invalidField(path: path, field: failure.field, reason: failure.reason)
      }
    }
  }

  /// Reads a regular file, at most `limit + 1` bytes (so an oversized file
  /// is detected without reading all of it); nil when it does not exist.
  public static func readSnapshot(_ path: String, limit: Int) throws(ConfigError) -> [UInt8]? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    if descriptor < 0 {
      let code = errno
      if code == ENOENT { return nil }
      throw .unreadable(path: path, reason: String(cString: strerror(code)))
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw .unreadable(path: path, reason: String(cString: strerror(errno)))
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw .unreadable(path: path, reason: "not a regular file")
    }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while bytes.count <= limit {
      let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw .unreadable(path: path, reason: String(cString: strerror(errno)))
      }
      if count == 0 { break }
      bytes.append(contentsOf: chunk[0..<count])
    }
    return bytes
  }
}
