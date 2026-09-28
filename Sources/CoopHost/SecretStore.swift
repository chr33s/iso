// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore
import Foundation

/// Host secret provisioning (C-04): the macOS Keychain is the one built-in
/// store. A stored secret is referenced from the configuration by a `cmd:`
/// string that `CredentialResolver` runs on use, so coop never reads it back
/// itself and no plaintext reaches the configuration file. Any other `cmd:`
/// reference (1Password, Vault, a file) is the user's own and stays opaque:
/// coop neither creates nor deletes what it points at. There is no fallback
/// store; when the Keychain is unavailable, provisioning fails.
public enum SecretStore {
  /// Service name for GitHub PATs; the account is the repo slug with `-`.
  public static let githubPATService = "coop-github-pat"
  /// Provider proxy credentials. A per-VM override appends `-<vm>`.
  public static let anthropicService = "coop-anthropic"
  public static let openAIService = "coop-openai"
  /// Human label for `github status`; `keychainToken` is its JSON form.
  public static let keychainLabel = "macOS Keychain"
  public static let keychainToken = "macos_keychain"
}

/// Keychain account name: the safe-name class only, so it is usable as a
/// lookup key and round-trips through the `cmd:` reference.
public struct SecretAccount: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  /// `owner/repo` becomes `owner-repo`.
  public init(repo: RepoSlug) {
    rawValue = repo.rawValue.replacingOccurrences(of: "/", with: "-")
  }

  public init(_ name: String) throws(ValidationError) {
    guard !name.isEmpty else { throw ValidationError("Account name is empty") }
    try validateSafeCharacters(name, kind: "Account name")
    rawValue = name
  }

  public var description: String { rawValue }
}

/// The `cmd:` reference coop writes for a Keychain item. `description` and
/// `parse` are exact inverses, so the stored string and the item it names
/// cannot diverge.
public struct KeychainReference: Equatable, Sendable, CustomStringConvertible {
  public let service: String
  public let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  public var description: String {
    "cmd:security find-generic-password -s \(Self.quote(service)) -a \(Self.quote(account)) -w"
  }

  /// The Keychain item a stored reference reads, or nil for any command not
  /// in exactly the form coop writes (such references are opaque).
  public static func parse(_ command: String) -> KeychainReference? {
    var body = Substring(command)
    if body.hasPrefix("cmd:") {
      body = body.dropFirst(4).drop { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }
    }
    guard let words = split(String(body)), words.count == 7,
      words[0] == "security", words[1] == "find-generic-password", words[2] == "-s",
      words[4] == "-a", words[6] == "-w"
    else { return nil }
    return KeychainReference(service: words[3], account: words[5])
  }

  /// POSIX quoting that `split` inverts: plain words pass through, anything
  /// else (including the empty string) is single-quoted.
  static func quote(_ value: String) -> String {
    let plain = value.unicodeScalars.allSatisfy { scalar in
      switch scalar {
      case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".", "/", ":", "=": true
      default: false
      }
    }
    if !value.isEmpty && plain { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Shell words for the constructs `quote` emits (single quotes and
  /// backslash escapes); nil on an unterminated quote.
  static func split(_ text: String) -> [String]? {
    var words: [String] = []
    var current = String.UnicodeScalarView()
    var inWord = false
    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case " ", "\t":
        if inWord {
          words.append(String(current))
          current = String.UnicodeScalarView()
          inWord = false
        }
      case "'":
        inWord = true
        var closed = false
        while let quoted = scalars.next() {
          if quoted == "'" {
            closed = true
            break
          }
          current.append(quoted)
        }
        guard closed else { return nil }
      case "\\":
        inWord = true
        if let next = scalars.next() { current.append(next) }
      default:
        inWord = true
        current.append(scalar)
      }
    }
    if inWord { words.append(String(current)) }
    return words
  }
}

/// `/usr/bin/security`, the Keychain's command-line interface.
public struct Keychain: Sendable {
  public static let defaultSecurity = "/usr/bin/security"

  let security: String
  let runner: ProcessRunner
  let environment: [String: String]

  public init(
    security: String = Keychain.defaultSecurity, environment: [String: String],
    runner: ProcessRunner = ProcessRunner()
  ) {
    self.security = security
    self.environment = environment
    self.runner = runner
  }

  public var isAvailable: Bool { FileManager.default.fileExists(atPath: security) }

  /// Fails explicitly when the Keychain cannot be used; there is no other
  /// built-in store to fall back to (C-04).
  public func requireAvailable() throws {
    guard isAvailable else {
      throw HostError(
        "macOS Keychain is unavailable (\(security) not found). coop stores secrets only in the Keychain; store the secret yourself and write a `cmd:` reference that prints it."
      )
    }
  }

  /// Create or replace the item and return its reference.
  ///
  /// `security` has no stdin form for a generic password: `-w` takes it on
  /// argv, where local process listings can briefly see it (the baseline's
  /// accepted cost). It never appears in coop's own messages.
  public func store(service: String, account: SecretAccount, secret: Secret<String>) throws
    -> KeychainReference
  {
    let visible = ["add-generic-password", "-U", "-s", service, "-a", account.rawValue, "-w"]
    let describe = (["security"] + visible + ["<redacted>"]).joined(separator: " ")
    let termination: ProcessRunner.Termination
    do {
      termination = try runner.attached(
        .init(
          executable: security, arguments: visible + [secret.expose()], environment: environment,
          deadline: .seconds(300)),
        inheritStdin: false)
    } catch {
      throw ContextError(
        "Failed to write secret to macOS Keychain",
        cause: ContextError("Failed to execute \(describe)", cause: error))
    }
    guard termination.succeeded else {
      throw ContextError(
        "Failed to write secret to macOS Keychain",
        cause: HostError("\(describe) exited with \(termination)"))
    }
    return KeychainReference(service: service, account: account.rawValue)
  }

  /// Remove the item; best-effort, a missing item is not an error.
  public func delete(service: String, account: SecretAccount) {
    _ = try? runner.capture(
      .init(
        executable: security,
        arguments: ["delete-generic-password", "-s", service, "-a", account.rawValue],
        environment: environment, deadline: .seconds(60), overflow: .drain))
  }
}
