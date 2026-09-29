import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets

/// `<instance>/guest_env.json`: the start-time `--env` (and devcontainer
/// `containerEnv`) entries, overlaid on every later session of the
/// instance. The configuration's own `guest_env` is re-read each time and
/// is not stored here. An empty snapshot is not written.
///
/// Version 1 (no `version` member) holds literal strings. Version 2 holds
/// typed entries, `{"kind": "literal", "value": …}` or `{"kind": "secret",
/// "name": …}`, and is written only when a secret reference is present, so
/// literal-only instances stay readable by older iso. A resolved secret
/// value is never written here.
public struct GuestEnvState: Sendable, Equatable {
  public var entries: [EnvVarName: EnvValue] = [:]

  public init(entries: [EnvVarName: EnvValue] = [:]) { self.entries = entries }

  /// A `{vault:}` reference on a recognized provider variable: routed to
  /// that provider's `iso-proxy`, never into the guest environment
  /// (embedded-secrets spec §31.1).
  public struct ProviderSecret: Sendable, Equatable {
    public let provider: ProxyProvider
    public let auth: ProxyAuthScheme
    public let variable: EnvVarName
    public let name: SecretName
  }

  static func providerRoute(_ variable: String) -> (ProxyProvider, ProxyAuthScheme)? {
    ProxyProvider.route(forVariable: variable)
  }

  /// A stored secret is either a provider credential (routed to iso-proxy)
  /// or a guest-visible value, never both: a generic reference naming a
  /// secret that a proxy credential or provider secret also reads would put
  /// that credential in the guest.
  public static func checkCredentialSeparation(
    _ entries: [EnvVarName: EnvValue], proxyCredentialNames: Set<SecretName>
  ) throws {
    let routed = try providerSecrets(entries)
    let routedVariables = Set(routed.values.map(\.variable))
    let credentials = proxyCredentialNames.union(routed.values.map(\.name))
    for (variable, value) in entries.sorted(by: { $0.key < $1.key }) {
      guard let name = value.reference, !routedVariables.contains(variable),
        credentials.contains(name)
      else { continue }
      throw HostError(
        "\(variable)={vault:\(name)} would put a provider credential in the guest: '\(name)' is also a credential-proxy secret"
      )
    }
  }

  /// Provider secrets by provider; two declarations for one provider are
  /// an error.
  public static func providerSecrets(_ entries: [EnvVarName: EnvValue]) throws
    -> [ProxyProvider: ProviderSecret]
  {
    var out: [ProxyProvider: ProviderSecret] = [:]
    for (variable, value) in entries.sorted(by: { $0.key < $1.key }) {
      guard let name = value.reference, let (provider, auth) = providerRoute(variable.rawValue)
      else { continue }
      if let existing = out[provider] {
        throw HostError(
          "\(existing.variable) and \(variable) both name a stored \(provider.rawValue) credential; keep one"
        )
      }
      out[provider] = ProviderSecret(provider: provider, auth: auth, variable: variable, name: name)
    }
    return out
  }

  public func providerSecrets() throws -> [ProxyProvider: ProviderSecret] {
    try Self.providerSecrets(entries)
  }

  public init(literals: [EnvVarName: String]) {
    entries = literals.mapValues { .literal($0) }
  }

  /// Byte order of name (Rust `BTreeMap`).
  public var sortedEntries: [(EnvVarName, EnvValue)] {
    entries.keys.sorted {
      Array($0.rawValue.utf8).lexicographicallyPrecedes(Array($1.rawValue.utf8))
    }
    .map { ($0, entries[$0]!) }
  }

  public static func tryLoad(_ instance: Instance) throws -> GuestEnvState? {
    let path = instance.guestEnvironmentStatePath
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    do {
      return try decode(bytes)
    } catch {
      throw ContextError("Failed to parse guest_env.json", cause: error)
    }
  }

  static func decode(_ bytes: [UInt8]) throws -> GuestEnvState {
    let value = try ConfigLoader.parse(
      bytes, format: .json, path: "guest_env.json", limits: .configuration)
    guard case .object(let members) = value else {
      throw HostError("invalid type: expected struct GuestEnvState")
    }
    let version: Int
    switch members["version"] {
    case nil: version = 1
    case .number(.integer(2))?, .number(.unsigned(2))?: version = 2
    default: throw HostError("guest_env.json was written by a newer iso (unsupported version)")
    }
    var state = GuestEnvState()
    switch members["entries"] {
    case nil: break
    case .object(let entries)?:
      for (name, value) in entries {
        let key = try EnvVarName(name)
        switch (version, value) {
        case (1, .string(let text)):
          state.entries[key] = .literal(text)
        case (2, .object(let fields)):
          state.entries[key] = try typedEntry(fields, name: name)
        default: throw HostError("invalid type for guest_env entry '\(name)'")
        }
      }
    default: throw HostError("invalid type for `entries`")
    }
    return state
  }

  static func typedEntry(_ fields: [String: JSONValue], name: String) throws -> EnvValue {
    switch (fields["kind"], fields["value"], fields["name"]) {
    case (.string("literal")?, .string(let text)?, nil): return .literal(text)
    case (.string("secret")?, nil, .string(let secret)?): return .secret(try SecretName(secret))
    case (.string("provider_secret")?, nil, .string(let secret)?):
      guard let (provider, auth) = providerRoute(name),
        fields["provider"] == .string(provider.rawValue),
        fields["injection"] == .string(auth.wireName)
      else { throw HostError("invalid provider_secret entry '\(name)'") }
      return .secret(try SecretName(secret))
    default: throw HostError("invalid guest_env entry '\(name)'")
    }
  }

  var hasReferences: Bool { entries.values.contains { $0.reference != nil } }

  /// An empty snapshot removes the file. Values can be secrets (`--env`,
  /// `containerEnv`), so the file is owner-only (the Rust host wrote 0644).
  public func save(_ instance: Instance, diagnostics: Diagnostics? = nil) throws {
    let path = instance.guestEnvironmentStatePath
    if entries.isEmpty {
      if unlink(path) != 0 && errno != ENOENT {
        diagnostics?.debug(
          "Failed to remove empty guest_env state \(path) (non-fatal): \(String(cString: strerror(errno)))"
        )
      }
      return
    }
    let json: OutputJSON
    if hasReferences {
      json = .object([
        ("version", .uint(2)),
        (
          "entries",
          .object(
            sortedEntries.map { name, value in
              switch value {
              case .literal(let text):
                (name.rawValue, .object([("kind", .string("literal")), ("value", .string(text))]))
              case .secret(let secret):
                if let (provider, auth) = Self.providerRoute(name.rawValue) {
                  (
                    name.rawValue,
                    .object([
                      ("kind", .string("provider_secret")),
                      ("provider", .string(provider.rawValue)),
                      ("injection", .string(auth.wireName)),
                      ("name", .string(secret.rawValue)),
                    ])
                  )
                } else {
                  (
                    name.rawValue,
                    .object([("kind", .string("secret")), ("name", .string(secret.rawValue))])
                  )
                }
              }
            })
        ),
      ])
    } else {
      json = .object([
        (
          "entries",
          .object(
            sortedEntries.map { name, value in
              guard case .literal(let text) = value else { preconditionFailure() }
              return (name.rawValue, .string(text))
            })
        )
      ])
    }
    do {
      try AtomicFile.write(
        Array(json.rendered().dropLast().utf8), to: path, mode: .atMost(0o600))
    } catch {
      throw ContextError("Failed to write guest_env.json", cause: error)
    }
    diagnostics?.debug("Wrote guest_env state to \(path)")
  }

  /// Devcontainer entries overlaid by CLI entries (CLI wins).
  /// Precedence, lowest first: devcontainer `containerEnv`, `--env-file`,
  /// `--env`.
  public static func merge(
    devcontainer: [EnvVarName: EnvValue], envFile: [EnvVarName: EnvValue] = [:],
    cli: [EnvVarName: EnvValue]
  ) -> [EnvVarName: EnvValue] {
    devcontainer.merging(envFile) { _, file in file }.merging(cli) { _, cli in cli }
  }

  /// `--env KEY=VALUE`; the value may be empty or contain `=`, and may be a
  /// whole-value `{vault:<name>}` reference.
  public static func parseCLIArgument(_ entry: String) throws -> (EnvVarName, EnvValue) {
    guard let equals = entry.firstIndex(of: "=") else {
      throw HostError("--env expects KEY=VALUE, got '\(entry)' (missing '=')")
    }
    let name: EnvVarName
    do {
      name = try EnvVarName(String(entry[..<equals]))
    } catch {
      throw ContextError("--env KEY is invalid (got '\(entry)')", cause: error)
    }
    do {
      return (name, try EnvValue.parse(String(entry[entry.index(after: equals)...])))
    } catch {
      throw HostError("--env \(name): \(error.message)")
    }
  }

  /// `--env-file PATH`: a regular file of at most 1 MiB, parsed strictly.
  public static func readEnvFile(_ path: String) throws -> [EnvVarName: EnvValue] {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw HostError.posix("Failed to open --env-file", path) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw HostError("--env-file \(path) is not a regular file")
    }
    guard info.st_size <= EnvFile.maxBytes else {
      throw HostError("--env-file \(path) is larger than 1 MiB")
    }
    let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
    guard let text = String(validating: data, as: UTF8.self) else {
      throw HostError("--env-file \(path) is not UTF-8")
    }
    do {
      return Dictionary(try EnvFile.parse(text), uniquingKeysWith: { $1 })
    } catch {
      throw HostError("--env-file \(path): \(error.message)")
    }
  }
}
