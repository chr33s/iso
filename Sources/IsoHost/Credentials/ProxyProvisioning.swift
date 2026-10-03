// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// `iso proxy setup` provisioning (C-04): the credential goes only to the
/// macOS Keychain, under the existing service/account names, and the
/// configuration or per-VM override records the `cmd:` reference that
/// reads it back. There is no fallback store.
package enum ProxyProvisioning {
  package static let securityTool = "/usr/bin/security"

  /// OpenAI keys are always Bearer; Anthropic uses `x-api-key` for an API
  /// key and Bearer for a `setup-token`.
  package static func auth(for provider: ProxyProvider, apiKey: Bool) -> ProxyAuthScheme {
    provider == .anthropic && apiKey ? .apiKey : .bearer
  }

  /// A per-VM override appends `-<vm>` so it never collides with the
  /// default entry.
  package static func service(for provider: ProxyProvider, vm: InstanceName?) -> String {
    vm.map { "\(provider.keychainService)-\($0)" } ?? provider.keychainService
  }

  /// The Rust `shell_quote`: bare when every character is safe.
  static func shellQuote(_ text: String) -> String {
    let safe =
      !text.isEmpty
      && text.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || "-_./:=".unicodeScalars.contains($0)
      }
    return safe ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  package static func reference(service: String, account: String) -> CredentialReference {
    CredentialReference(
      "cmd:security find-generic-password -s \(shellQuote(service)) -a \(shellQuote(account)) -w")!
  }

  /// `security add-generic-password -U`. The CLI takes the secret only on
  /// argv (a documented exception); nothing else sees it and it is never
  /// logged. Fails when the Keychain is unavailable or refuses the write.
  package static func storeInKeychain(
    service: String, account: String, secret: Secret<String>, environment: [String: String],
    runner: ProcessRunner = ProcessRunner(), tool: String = securityTool
  ) throws -> CredentialReference {
    guard access(tool, X_OK) == 0 else {
      throw HostError(
        "macOS Keychain is unavailable (\(tool) not found); `iso proxy setup` stores credentials only in the Keychain. Alternatively write a `cmd:` reference to a command that prints the credential into proxy.<provider>.credential"
      )
    }
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        .init(
          executable: tool,
          arguments: [
            "add-generic-password", "-U", "-s", service, "-a", account, "-w", secret.expose(),
          ], environment: environment, deadline: .seconds(120), outputLimit: 64 << 10,
          overflow: .drain))
    } catch {
      throw ContextError(
        "Failed to write secret to macOS Keychain", cause: HostError("security could not run"))
    }
    guard output.termination.succeeded else {
      throw ContextError(
        "Failed to write secret to macOS Keychain",
        cause: HostError("security add-generic-password exited with \(output.termination)"))
    }
    return reference(service: service, account: account)
  }
}
