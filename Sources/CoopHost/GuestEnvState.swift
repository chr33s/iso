import CoopConfiguration
import CoopCore
import Foundation

/// `<instance>/guest_env.json`: the start-time `--env` (and devcontainer
/// `containerEnv`) entries, overlaid on every later session of the
/// instance. The configuration's own `guest_env` is re-read each time and
/// is not stored here. An empty snapshot is not written.
public struct GuestEnvState: Sendable, Equatable {
  public var entries: [EnvVarName: String] = [:]

  public init(entries: [EnvVarName: String] = [:]) { self.entries = entries }

  /// Byte order of name (Rust `BTreeMap`).
  public var sortedEntries: [(EnvVarName, String)] {
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
    var state = GuestEnvState()
    switch members["entries"] {
    case nil: break
    case .object(let entries)?:
      for (name, value) in entries {
        guard case .string(let text) = value else {
          throw HostError("invalid type for guest_env entry '\(name)'")
        }
        state.entries[try EnvVarName(name)] = text
      }
    default: throw HostError("invalid type for `entries`")
    }
    return state
  }

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
    let json = OutputJSON.object([
      ("entries", .object(sortedEntries.map { ($0.0.rawValue, OutputJSON.string($0.1)) }))
    ])
    do {
      try AtomicFile.write(
        Array(json.rendered().dropLast().utf8), to: path, mode: .atMost(0o600))
    } catch {
      throw ContextError("Failed to write guest_env.json", cause: error)
    }
    diagnostics?.debug("Wrote guest_env state to \(path)")
  }

  /// Devcontainer entries overlaid by CLI entries (CLI wins).
  public static func merge(devcontainer: [EnvVarName: String], cli: [EnvVarName: String])
    -> [EnvVarName: String]
  {
    devcontainer.merging(cli) { _, cli in cli }
  }

  /// `--env KEY=VALUE`; the value may be empty or contain `=`.
  public static func parseCLIArgument(_ entry: String) throws -> (EnvVarName, String) {
    guard let equals = entry.firstIndex(of: "=") else {
      throw HostError("--env expects KEY=VALUE, got '\(entry)' (missing '=')")
    }
    do {
      return (
        try EnvVarName(String(entry[..<equals])), String(entry[entry.index(after: equals)...])
      )
    } catch {
      throw ContextError("--env KEY is invalid (got '\(entry)')", cause: error)
    }
  }
}
