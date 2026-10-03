import Foundation
import IsoCore

/// How a defined agent expects its guest terminal to be allocated.
package enum AgentTerminalMode: String, Sendable, Equatable, CaseIterable {
  case auto
  case required
  case never
}

/// Image or profile set a definition requests. It selects existing image
/// machinery; it does not embed an install language.
package enum AgentEnvironmentSelection: Sendable, Equatable {
  case image(ImageName)
  case profiles([String])
}

package struct GuestEnvironmentDefault: Sendable, Equatable {
  package let name: EnvVarName
  package let value: String

  package init(name: EnvVarName, value: String) {
    self.name = name
    self.value = value
  }
}

package struct AgentLaunchSpec: Sendable, Equatable {
  package let argv: [String]
  package let workingDirectory: GuestPath
  package let terminal: AgentTerminalMode
  package let environment: [GuestEnvironmentDefault]

  package init(
    argv: [String], workingDirectory: GuestPath, terminal: AgentTerminalMode,
    environment: [GuestEnvironmentDefault]
  ) {
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.terminal = terminal
    self.environment = environment
  }
}

/// A validated agent definition. Built-ins and installed files use this same
/// model. It requests a reviewed adapter and may suggest hosts; it cannot
/// grant network, credentials, mounts, or host commands.
package struct AgentDefinition: Sendable, Equatable {
  package static let schemaVersion = 1
  package static let maxArgvEntries = 128
  package static let maxArgvEntryBytes = 4 * 1024
  package static let maxArgvBytes = 64 * 1024
  package static let maxProfiles = 64
  package static let maxHints = 256
  package static let maxWorkingDirectoryBytes = 4 * 1024
  package static let maxDisplayScalars = 128
  package static let fileBytes = 256 * 1024

  package let id: AgentDefinitionID
  package let displayName: String
  package let environment: AgentEnvironmentSelection?
  package let launch: AgentLaunchSpec
  package let authAdapter: AgentAdapterID
  package let networkHints: [ExactHostname]

  package init(
    id: AgentDefinitionID, displayName: String, environment: AgentEnvironmentSelection?,
    launch: AgentLaunchSpec, authAdapter: AgentAdapterID, networkHints: [ExactHostname]
  ) {
    self.id = id
    self.displayName = displayName
    self.environment = environment
    self.launch = launch
    self.authAdapter = authAdapter
    self.networkHints = networkHints
  }
}

package struct AgentDefinitionError: Error, Equatable, Sendable, CustomStringConvertible {
  package let message: String
  package init(_ message: String) { self.message = message }
  package var description: String { message }
}

extension JSONLimits {
  /// Parser budgets for one agent-definition file. These are limits, not
  /// measured performance.
  package static let agentDefinition = JSONLimits(
    maxBytes: AgentDefinition.fileBytes, maxDepth: 16, maxKeys: 512, maxArrayElements: 256,
    maxNumberLength: 32, maxStringBytes: AgentDefinition.maxArgvEntryBytes)
}

package enum AgentDefinitionDecoder {
  /// Parse one definition document. `format` selects comment stripping;
  /// unknown fields, duplicate keys, and the budgets above are rejected.
  package static func decode(_ bytes: [UInt8], path: String, format: ConfigFormat) throws
    -> AgentDefinition
  {
    let value: JSONValue
    do {
      value = try ConfigLoader.parse(bytes, format: format, path: path, limits: .agentDefinition)
    } catch {
      throw AgentDefinitionError("\(path): \(error)")
    }
    do {
      return try decode(value)
    } catch let error as FieldError {
      throw AgentDefinitionError("\(path): \(error.field): \(error.reason)")
    } catch let error as AgentDefinitionError {
      throw AgentDefinitionError("\(path): \(error.message)")
    }
  }

  package static func decode(_ value: JSONValue) throws -> AgentDefinition {
    let reader = try ObjectReader(value, at: [])
    try reader.rejectUnknown(allowing: [
      "schema_version", "id", "display_name", "environment", "launch", "auth_adapter",
      "network_hints",
    ])
    let version = try reader.required("schema_version") { value, path throws(FieldError) in
      try Parse.unsigned(value, path, as: UInt32.self)
    }
    guard version == UInt32(AgentDefinition.schemaVersion) else {
      throw AgentDefinitionError(
        "schema_version \(version) is not supported (expected \(AgentDefinition.schemaVersion))")
    }
    let id = try reader.required("id") { value, path throws(FieldError) in
      let raw = try Parse.string(value, path)
      return try Parse.domain(path) { () throws(ValidationError) in try AgentDefinitionID(raw) }
    }
    let displayName = try reader.required("display_name") { value, path throws(FieldError) in
      try validateDisplayName(Parse.string(value, path), path)
    }
    let environment = try reader.optional("environment", decodeEnvironment)
    let launch = try reader.required("launch", decodeLaunch)
    let adapter = try reader.required("auth_adapter") { value, path throws(FieldError) in
      let raw = try Parse.string(value, path)
      return try Parse.domain(path) { () throws(ValidationError) in try AgentAdapterID(raw) }
    }
    let hints = try reader.optional("network_hints", decodeHints) ?? []
    return AgentDefinition(
      id: id, displayName: displayName, environment: environment, launch: launch,
      authAdapter: adapter, networkHints: hints)
  }

  /// Canonical document used for the definition hash and the installed copy.
  /// Field order is part of the hash.
  package static func canonical(_ definition: AgentDefinition) -> OutputJSON {
    var members: [(String, OutputJSON)] = [
      ("schema_version", .int(Int64(AgentDefinition.schemaVersion))),
      ("id", .string(definition.id.rawValue)),
      ("display_name", .string(definition.displayName)),
    ]
    switch definition.environment {
    case nil: members.append(("environment", .null))
    case .image(let image):
      members.append(("environment", .object([("image", .string(image.rawValue))])))
    case .profiles(let profiles):
      members.append(
        (
          "environment",
          .object([("profiles", .array(profiles.map(OutputJSON.string)))]),
        ))
    }
    let defaults = definition.launch.environment.map {
      ($0.name.rawValue, OutputJSON.string($0.value))
    }
    members.append(
      (
        "launch",
        .object([
          ("argv", .array(definition.launch.argv.map(OutputJSON.string))),
          ("working_directory", .string(definition.launch.workingDirectory.rawValue)),
          ("terminal", .string(definition.launch.terminal.rawValue)),
          ("environment", defaults.isEmpty ? .null : .object(defaults)),
        ]),
      ))
    members.append(("auth_adapter", .string(definition.authAdapter.rawValue)))
    members.append(
      (
        "network_hints",
        .object([
          ("suggested_hosts", .array(definition.networkHints.map { .string($0.rawValue) }))
        ]),
      ))
    return .object(members)
  }

  package static func canonicalBytes(_ definition: AgentDefinition) -> [UInt8] {
    Array(canonical(definition).compactRendered().utf8)
  }
}

private func decodeEnvironment(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
  -> AgentEnvironmentSelection
{
  let reader = try ObjectReader(value, at: path)
  try reader.rejectUnknown(allowing: ["image", "profiles"])
  let image = try reader.optional("image") { value, path throws(FieldError) in
    let raw = try Parse.string(value, path)
    return try Parse.domain(path) { () throws(ValidationError) in try ImageName(raw) }
  }
  let profiles = try reader.optional("profiles") { value, path throws(FieldError) in
    try Parse.array(value, path) { item, itemPath throws(FieldError) in
      let name = try Parse.string(item, itemPath)
      guard !name.isEmpty, name.utf8.count <= 64 else {
        throw FieldError(itemPath, "profile name must be 1...64 bytes")
      }
      guard name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0 != "/" })
      else { throw FieldError(itemPath, "profile name contains a control character or '/'") }
      return name
    }
  }
  switch (image, profiles) {
  case (let image?, nil): return .image(image)
  case (nil, let profiles?):
    guard !profiles.isEmpty else {
      throw FieldError(path + [.key("profiles")], "must not be empty")
    }
    guard profiles.count <= AgentDefinition.maxProfiles else {
      throw FieldError(
        path + [.key("profiles")], "more than \(AgentDefinition.maxProfiles) entries")
    }
    if let duplicate = profiles.first(where: { name in profiles.filter { $0 == name }.count > 1 }) {
      throw FieldError(path + [.key("profiles")], "duplicate profile '\(duplicate)'")
    }
    return .profiles(profiles)
  case (nil, nil):
    throw FieldError(path, "expected image or profiles")
  case (.some, .some):
    throw FieldError(path, "image and profiles are mutually exclusive")
  }
}

private func decodeLaunch(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
  -> AgentLaunchSpec
{
  let reader = try ObjectReader(value, at: path)
  try reader.rejectUnknown(allowing: ["argv", "working_directory", "terminal", "environment"])
  let argv = try reader.required("argv") { value, path throws(FieldError) in
    try Parse.array(value, path) { item, itemPath throws(FieldError) in
      try Parse.string(item, itemPath)
    }
  }
  try validateArgv(argv, path + [.key("argv")])
  let directory = try reader.defaulted("working_directory", "/workspace") {
    value, path throws(FieldError) in
    try validateWorkingDirectory(Parse.string(value, path), path)
  }
  let terminal = try reader.defaulted("terminal", AgentTerminalMode.auto) {
    value, path throws(FieldError) in
    try Parse.stringEnum(value, path, AgentTerminalMode.allCases)
  }
  let environment = try reader.optional("environment", decodeEnvironmentDefaults) ?? []
  return AgentLaunchSpec(
    argv: argv, workingDirectory: GuestPath(directory), terminal: terminal, environment: environment
  )
}

private func decodeEnvironmentDefaults(_ value: JSONValue, _ path: [JSONPathComponent])
  throws(FieldError) -> [GuestEnvironmentDefault]
{
  guard case .object(let members) = value else {
    throw FieldError(path, "expected an object, found \(value.typeName)")
  }
  guard members.count <= AgentEnvironmentAllowlist.maxEntries else {
    throw FieldError(path, "more than \(AgentEnvironmentAllowlist.maxEntries) entries")
  }
  var defaults: [GuestEnvironmentDefault] = []
  for key in members.keys.sorted() {
    guard AgentEnvironmentAllowlist.names.contains(key) else {
      throw FieldError(path + [.key(key)], "not in the non-sensitive environment allowlist")
    }
    let raw = try Parse.string(members[key]!, path + [.key(key)])
    guard raw.utf8.count <= AgentEnvironmentAllowlist.maxValueBytes else {
      throw FieldError(
        path + [.key(key)], "value longer than \(AgentEnvironmentAllowlist.maxValueBytes) bytes")
    }
    guard !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
      throw FieldError(path + [.key(key)], "value contains a control character")
    }
    defaults.append(
      GuestEnvironmentDefault(
        name: try Parse.domain(path + [.key(key)]) { () throws(ValidationError) in
          try EnvVarName(key)
        },
        value: raw))
  }
  return defaults
}

private func decodeHints(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
  -> [ExactHostname]
{
  let reader = try ObjectReader(value, at: path)
  try reader.rejectUnknown(allowing: ["suggested_hosts"])
  let hosts: [ExactHostname] = try reader.defaulted(
    "suggested_hosts", [ExactHostname]()
  ) { value, path throws(FieldError) in
    try Parse.array(value, path) { item, itemPath throws(FieldError) in
      let raw = try Parse.string(item, itemPath)
      return try Parse.domain(itemPath) { () throws(ValidationError) in try ExactHostname(raw) }
    }
  }
  guard hosts.count <= AgentDefinition.maxHints else {
    throw FieldError(
      path + [.key("suggested_hosts")], "more than \(AgentDefinition.maxHints) entries")
  }
  var seen: Set<String> = []
  var ordered: [ExactHostname] = []
  for host in hosts where seen.insert(host.rawValue).inserted { ordered.append(host) }
  return ordered.sorted { $0.rawValue < $1.rawValue }
}

private func validateDisplayName(_ name: String, _ path: [JSONPathComponent]) throws(FieldError)
  -> String
{
  let scalars = Array(name.unicodeScalars)
  guard (1...AgentDefinition.maxDisplayScalars).contains(scalars.count) else {
    throw FieldError(
      path, "display name must be 1...\(AgentDefinition.maxDisplayScalars) Unicode scalars")
  }
  for scalar in scalars
  where scalar.value == 0 || scalar.properties.generalCategory == .control
    || scalar.properties.generalCategory == .format
  {
    throw FieldError(path, "display name contains a control or format character")
  }
  return name
}

private func validateArgv(_ argv: [String], _ path: [JSONPathComponent]) throws(FieldError) {
  guard !argv.isEmpty else { throw FieldError(path, "must not be empty") }
  guard argv.count <= AgentDefinition.maxArgvEntries else {
    throw FieldError(path, "more than \(AgentDefinition.maxArgvEntries) entries")
  }
  var total = 0
  for (index, entry) in argv.enumerated() {
    guard !entry.isEmpty else { throw FieldError(path + [.index(index)], "must not be empty") }
    guard entry.utf8.count <= AgentDefinition.maxArgvEntryBytes else {
      throw FieldError(
        path + [.index(index)], "longer than \(AgentDefinition.maxArgvEntryBytes) bytes")
    }
    guard
      !entry.unicodeScalars.contains(where: {
        $0.value == 0 || $0.properties.generalCategory == .control
      })
    else { throw FieldError(path + [.index(index)], "contains a control character") }
    total += entry.utf8.count
  }
  guard total <= AgentDefinition.maxArgvBytes else {
    throw FieldError(path, "aggregate argv exceeds \(AgentDefinition.maxArgvBytes) bytes")
  }
}

private func validateWorkingDirectory(_ raw: String, _ path: [JSONPathComponent]) throws(FieldError)
  -> String
{
  guard raw.utf8.count <= AgentDefinition.maxWorkingDirectoryBytes else {
    throw FieldError(path, "longer than \(AgentDefinition.maxWorkingDirectoryBytes) bytes")
  }
  guard raw.hasPrefix("/") else { throw FieldError(path, "must be an absolute guest path") }
  guard !raw.contains("~"), !raw.contains("$"), !raw.contains("\u{0}") else {
    throw FieldError(path, "must not contain '~', '$', or NUL")
  }
  for scalar in raw.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
    throw FieldError(path, "contains a control character")
  }
  let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  guard parts.first == "" else { throw FieldError(path, "must be an absolute guest path") }
  for part in parts.dropFirst() {
    guard part != ".", part != ".." else {
      throw FieldError(path, "must not contain '.' or '..'")
    }
  }
  let normalized = "/" + parts.dropFirst().filter { !$0.isEmpty }.joined(separator: "/")
  guard normalized != "/" || raw == "/" else {
    throw FieldError(path, "must be an absolute guest path")
  }
  return normalized.isEmpty ? "/" : normalized
}
