// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopConfiguration
import CoopCore
import CoopSecrets
import Foundation

/// Resolves stored-secret references (`{vault:}` / `vault:`). The CLI's
/// implementation unlocks the secret store at most once per command.
public protocol SecretReferenceResolver: Sendable {
  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>]
}

/// Just-in-time resolution of secret-bearing configuration values. A value
/// beginning `cmd:` is a trusted, user-authored host command run through
/// `/bin/sh -c`; its trimmed stdout is the secret. A value `vault:<name>` is
/// read from the local secret store. Other values pass through unchanged.
/// Only callers whose operation needs the secret invoke this; configuration
/// loading never does.
public struct CredentialResolver: Sendable {
  public static let timeout: Duration = .seconds(10)

  /// The store the CLI installs for this process; the default for every
  /// resolver built without an explicit one.
  nonisolated(unsafe) public static var processSecrets: (any SecretReferenceResolver)?

  let runner: ProcessRunner
  let environment: [String: String]
  let secrets: (any SecretReferenceResolver)?

  public init(
    runner: ProcessRunner = ProcessRunner(), environment: [String: String],
    secrets: (any SecretReferenceResolver)? = CredentialResolver.processSecrets
  ) {
    self.runner = runner
    self.environment = environment
    self.secrets = secrets
  }

  /// A `vault:<name>` value, as UTF-8 text without NUL. Errors never echo
  /// the text: a mistyped or pasted value may be the secret itself.
  func resolveStored(_ text: String) throws(HostError) -> Secret<String> {
    let name: SecretName
    do {
      name = try SecretName(text)
    } catch {
      throw HostError(
        "a `vault:` credential reference has an invalid secret name (letters, digits, '.', '_', '-')"
      )
    }
    guard let secrets else {
      throw HostError(
        "a `vault:` credential needs the coop secret store, which this command cannot unlock")
    }
    let bytes: [UInt8]
    do {
      guard let value = try secrets.resolve([name])[name] else {
        throw HostError("a `vault:` credential reference names a secret that is not in the store")
      }
      bytes = value.expose()
    } catch let error as HostError {
      throw error
    } catch {
      throw HostError("unable to resolve a `vault:` credential: \(error)")
    }
    guard !bytes.contains(0), let text = String(validating: bytes, as: UTF8.self) else {
      throw HostError("a `vault:` credential is not valid UTF-8 text without NUL")
    }
    return Secret(text)
  }

  /// Resolves every `vault:` value in `values` in one unlock, so the later
  /// per-value resolutions are cache hits. A no-op without a store or names.
  /// One missing name fails the whole batch.
  public func prefetchStored(_ values: [Secret<String>]) throws(HostError) {
    let names = Set(values.compactMap { SecretName.vaultReference($0.expose()) })
    guard !names.isEmpty, let secrets else { return }
    do { _ = try secrets.resolve(names) } catch let error as HostError {
      throw error
    } catch {
      throw HostError("unable to resolve a `vault:` credential: \(error)")
    }
  }

  /// Resolution for credentials that may come from the secret store:
  /// provider proxy credentials and GitHub PATs.
  public func resolveAllowingStored(_ value: Secret<String>) throws(HostError) -> Secret<String> {
    let raw = value.expose()
    if raw.hasPrefix("vault:") { return try resolveStored(String(raw.dropFirst(6))) }
    return try resolve(value)
  }

  /// `cmd:` or literal. A `vault:` value is refused here: these fields
  /// (agent `api_key`, MCP headers) are placed in the guest, and a stored
  /// provider credential must never be (embedded-secrets §31.1).
  public func resolve(_ value: Secret<String>) throws(HostError) -> Secret<String> {
    let raw = value.expose()
    if raw.hasPrefix("vault:") {
      throw HostError(
        "`vault:` references are supported for proxy.<provider>.credential and github.pat tokens only; this value would be placed in the guest"
      )
    }
    guard raw.hasPrefix("cmd:") else { return value }
    let command = String(raw.dropFirst(4)).trimmingUnicodeWhitespace()
    guard !command.isEmpty else { throw HostError("Empty command after 'cmd:' prefix") }
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        .init(
          executable: "/bin/sh", arguments: ["-c", command], environment: environment,
          deadline: Self.timeout, outputLimit: 1 << 20))
    } catch .timedOut {
      throw HostError(
        "Secret command timed out after 10s: \(command)\nEnsure the command runs non-interactively."
      )
    } catch .spawn {
      throw HostError("Failed to spawn secret command: \(command)")
    } catch .outputLimitExceeded {
      throw HostError("Secret command produced more than 1 MiB of output: \(command)")
    } catch {
      throw HostError("Failed to read output: \(command)")
    }
    guard output.termination == .exited(0) else {
      let code =
        switch output.termination {
        case .exited(let status): String(status)
        case .signaled: "signal"
        }
      let stderr = String(decoding: output.stderr.prefix(4096), as: UTF8.self)
      throw HostError("Secret command failed (exit \(code)): \(command)\nstderr: \(stderr)")
    }
    guard let stdout = String(validating: output.stdout, as: UTF8.self) else {
      throw HostError("Secret command output is not valid UTF-8")
    }
    let resolved = stdout.trimmingUnicodeWhitespace()
    guard !resolved.isEmpty else {
      throw HostError(
        "Secret command produced empty output: \(command)\nThe command succeeded but stdout was empty after trimming."
      )
    }
    return Secret(resolved)
  }

  public func resolve(_ reference: CredentialReference) throws(HostError) -> Secret<String> {
    try resolveAllowingStored(reference.command)
  }
}
