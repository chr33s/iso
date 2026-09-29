import Foundation
import IsoCore

// MARK: - Per-project discovery preferences

/// `devcontainer_preferences.json`: explicit opt-outs keyed by canonical
/// project path. A missing entry means "ask/apply normally".
public struct DevcontainerPreferences: Sendable, Equatable {
  /// Project key → ignore flag, in key byte order when saved.
  public private(set) var projects: [String: Bool] = [:]

  public init() {}

  public static func load(_ path: String) throws -> DevcontainerPreferences {
    guard FileManager.default.fileExists(atPath: path) else { return DevcontainerPreferences() }
    let text = try readUTF8File(path)
    struct Entry: Decodable {
      let ignore: Bool
      enum CodingKeys: String, CodingKey { case ignore }
      init(from decoder: any Decoder) throws {
        ignore =
          try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(
            Bool.self, forKey: .ignore) ?? false
      }
    }
    struct File: Decodable {
      let projects: [String: Entry]
      enum CodingKeys: String, CodingKey { case projects }
      init(from decoder: any Decoder) throws {
        projects =
          try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(
            [String: Entry].self, forKey: .projects) ?? [:]
      }
    }
    do {
      let file = try JSONDecoder().decode(File.self, from: Data(text.utf8))
      var preferences = DevcontainerPreferences()
      preferences.projects = file.projects.mapValues(\.ignore)
      return preferences
    } catch {
      throw ContextError("Failed to parse \(path)", cause: error)
    }
  }

  /// An empty set removes the file.
  public func save(_ path: String) throws {
    if projects.isEmpty {
      if FileManager.default.fileExists(atPath: path) {
        guard unlink(path) == 0 else {
          throw ContextError("Failed to remove \(path)", cause: HostError(ioErrorText(errno)))
        }
      }
      return
    }
    let keys = projects.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    let json = OutputJSON.object([
      ("projects", .object(keys.map { ($0, .object([("ignore", .bool(projects[$0]!))])) }))
    ]).rendered()
    do {
      try AtomicFile.write(
        Array(json.dropLast().utf8), to: path, mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write \(path)", cause: error)
    }
  }

  @discardableResult
  public mutating func setIgnored(_ project: String) throws -> String {
    let key = try Self.key(project)
    projects[key] = true
    return key
  }

  public mutating func clear(_ project: String) throws -> Bool {
    projects.removeValue(forKey: try Self.lookupKey(project)) != nil
  }

  public func ignoredProject(_ project: String) throws -> String? {
    let key = try Self.lookupKey(project)
    return projects[key] == true ? key : nil
  }

  /// Opted-out project keys in byte order.
  public var ignoredProjects: [String] {
    projects.filter(\.value).keys.sorted {
      Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
    }
  }

  /// The canonical project path.
  public static func key(_ project: String) throws -> String {
    guard let canonical = canonicalPath(project) else {
      throw ContextError(
        "Failed to resolve project directory \(project) for devcontainer preference",
        cause: HostError(ioErrorText(errno)))
    }
    return canonical
  }

  /// `key`, or for an absolute path that no longer exists, the canonical
  /// form of its longest existing ancestor with the missing tail appended,
  /// so an opt-out stays addressable after the project is deleted.
  public static func lookupKey(_ project: String) throws -> String {
    do { return try key(project) } catch {
      guard project.hasPrefix("/") else { throw error }
      return canonicalizeDeletedProject(project)
    }
  }

  static func canonicalizeDeletedProject(_ project: String) -> String {
    let components = project.split(separator: "/").map(String.init)
    for count in stride(from: components.count, through: 0, by: -1) {
      let ancestor = "/" + components.prefix(count).joined(separator: "/")
      guard let canonical = canonicalPath(ancestor) else { continue }
      let tail = components.dropFirst(count)
      return tail.isEmpty ? canonical : joinPath(canonical, tail.joined(separator: "/"))
    }
    return project
  }
}

// MARK: - Applied file record

/// The devcontainer file applied when an instance was created.
public struct AppliedDevcontainer: Sendable, Equatable, Codable {
  public enum Source: String, Sendable, Equatable, Codable {
    case localFile = "local_file"
    case remoteContents = "remote_contents"
  }

  public let path: String
  /// Lowercase hex SHA-256 of the file text.
  public let contentHash: String
  public var source: Source

  public init(path: String, contentHash: String, source: Source) {
    self.path = path
    self.contentHash = contentHash
    self.source = source
  }

  enum CodingKeys: String, CodingKey {
    case path, source
    case contentHash = "content_hash"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    path = try c.decode(String.self, forKey: .path)
    contentHash = try c.decode(SHA256Hex.self, forKey: .contentHash).rawValue
    source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .localFile
  }

  var json: OutputJSON {
    .object([
      ("path", .string(path)), ("content_hash", .string(contentHash)),
      ("source", .string(source.rawValue)),
    ])
  }

  /// Nil for remote contents or a file that no longer exists.
  func currentHash() throws -> String? {
    guard source == .localFile else { return nil }
    guard let handle = FileHandle(forReadingAtPath: path) else {
      if errno == ENOENT { return nil }
      throw ContextError("Failed to read \(path)", cause: HostError(ioErrorText(errno)))
    }
    defer { try? handle.close() }
    let data = (try? handle.readToEnd()) ?? Data()
    return sha256Hex(Array(data))
  }
}

/// `devcontainer_state.json`, written per instance after start.
public struct DevcontainerState: Sendable, Equatable {
  public let applied: AppliedDevcontainer

  public init(applied: AppliedDevcontainer) { self.applied = applied }

  public func save(_ instance: Instance) throws {
    let json = OutputJSON.object([("applied", applied.json)]).rendered()
    do {
      try AtomicFile.write(
        Array(json.dropLast().utf8), to: instance.devcontainerStatePath,
        mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write devcontainer_state.json", cause: error)
    }
  }

  public static func load(_ instance: Instance) throws -> DevcontainerState? {
    let path = instance.devcontainerStatePath
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let text = try readUTF8File(path)
    struct File: Decodable { let applied: AppliedDevcontainer }
    do {
      return DevcontainerState(
        applied: try JSONDecoder().decode(File.self, from: Data(text.utf8)).applied)
    } catch {
      throw ContextError("Failed to parse devcontainer_state.json", cause: error)
    }
  }

  /// A warning when the applied local file changed or disappeared.
  public func changedWarning(instanceName: String) throws -> String? {
    guard applied.source == .localFile else { return nil }
    guard let current = try applied.currentHash() else {
      return
        "devcontainer.json previously applied to instance '\(instanceName)' is no longer readable at \(applied.path). The existing VM was not changed. Destroy and recreate it to apply creation-time devcontainer changes such as features, hostRequirements, mounts, image/build, or remoteUser."
    }
    if current == applied.contentHash { return nil }
    return
      "devcontainer.json changed since instance '\(instanceName)' was created: \(applied.path). The existing VM was not changed. Destroy and recreate it to apply creation-time devcontainer changes such as features, hostRequirements, mounts, image/build, or remoteUser. Restart-time values from the old file, including containerEnv, forwardPorts, and postStartCommand, are not re-applied automatically."
  }

  /// Rust `warn_if_applied_devcontainer_changed`: failures only warn.
  public static func warnIfChanged(_ instance: Instance, diagnostics: Diagnostics) {
    let state: DevcontainerState
    do {
      guard let loaded = try load(instance) else { return }
      state = loaded
    } catch {
      diagnostics.warn(
        "Could not read devcontainer state for '\(instance.name)'; devcontainer change check skipped. \(oneLine(error))"
      )
      return
    }
    do {
      if let message = try state.changedWarning(instanceName: instance.name.rawValue) {
        diagnostics.warn(message)
      }
    } catch {
      diagnostics.warn(
        "Could not compare devcontainer.json for '\(instance.name)'; devcontainer change check skipped. \(oneLine(error))"
      )
    }
  }
}
