// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoCore

/// Host secret provisioning (C-04): the macOS Keychain is the one built-in
/// store, referenced from config by a `cmd:` string that `CredentialResolver`
/// runs on use, so no plaintext reaches the config and iso never reads it back.
/// Other `cmd:` references are the user's own and stay opaque. No fallback
/// store: provisioning fails when the Keychain is unavailable.
package enum SecretStore {
  package static let githubPATService = "iso-github-pat"
  /// Human label for `github status`; `keychainToken` is its JSON form.
  package static let keychainLabel = "macOS Keychain"
  package static let keychainToken = "macos_keychain"
}

/// Keychain account name: the safe-name class or a repository slug, so it
/// is usable as a lookup key and round-trips through the `cmd:` reference.
package struct SecretAccount: Hashable, Sendable, CustomStringConvertible {
  package let rawValue: String

  /// The `owner/repo` slug itself. Owners and repositories may both contain
  /// `-`, so joining them with `-` would map two repositories to one item.
  package init(repo: RepoSlug) {
    rawValue = repo.rawValue
  }

  package init(_ name: String) throws(ValidationError) {
    guard !name.isEmpty else { throw ValidationError("Account name is empty") }
    try validateSafeCharacters(name, kind: "Account name")
    rawValue = name
  }

  package var description: String { rawValue }
}

/// The `cmd:` reference iso writes for a Keychain item. `description` and
/// `parse` are exact inverses, so the stored string and the item it names
/// cannot diverge.
package struct KeychainReference: Equatable, Sendable, CustomStringConvertible {
  package let service: String
  package let account: String

  package init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  package var description: String {
    "cmd:security find-generic-password -s \(shellWord(service)) -a \(shellWord(account)) -w"
  }

  /// The Keychain item a stored reference reads, or nil for any command not
  /// in exactly the form iso writes (such references are opaque).
  package static func parse(_ command: String) -> KeychainReference? {
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

  /// Shell words for the constructs `shellWord` emits (single quotes and
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

package struct Keychain: Sendable {
  package static let defaultSecurity = "/usr/bin/security"

  let security: String
  let runner: ProcessRunner
  let environment: [String: String]

  package init(
    security: String = Keychain.defaultSecurity, environment: [String: String],
    runner: ProcessRunner = ProcessRunner()
  ) {
    self.security = security
    self.environment = environment
    self.runner = runner
  }

  package var isAvailable: Bool { FileManager.default.fileExists(atPath: security) }

  /// Fails explicitly when the Keychain cannot be used; there is no other
  /// built-in store to fall back to (C-04).
  package func requireAvailable() throws {
    guard isAvailable else {
      throw HostError(
        "macOS Keychain is unavailable (\(security) not found). iso stores secrets only in the Keychain; store the secret yourself and write a `cmd:` reference that prints it."
      )
    }
  }

  /// Create or replace the item and return its reference. `-w` puts the secret
  /// on argv, briefly visible to local process listings (the documented exception
  /// in docs/trust-model.md; same for `ProxyProvisioning.storeInKeychain`).
  package func store(service: String, account: SecretAccount, secret: Secret<String>) throws
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
        inheritStdin: false, deadline: nil)
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

  /// Remove the item a reference names; best-effort, a missing item is not
  /// an error.
  package func delete(_ item: KeychainReference) {
    _ = try? runner.capture(
      .init(
        executable: security,
        arguments: ["delete-generic-password", "-s", item.service, "-a", item.account],
        environment: environment, deadline: .seconds(60), overflow: .drain))
  }
}
