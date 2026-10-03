// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// Writes to the configuration file. Every edit rereads the file under the
/// writer lock (so concurrent edits are not lost), edits the structural form,
/// verifies the result, and replaces the file atomically without widening its
/// mode. A failure at any step leaves the previous file untouched.
package enum ConfigStore {
  /// `iso setup --config-only`: write the commented template (or, for a
  /// strict `.json` path, an empty object) if nothing exists. Returns false
  /// and writes nothing when a file or link is already there.
  @discardableResult
  package static func createTemplate(at path: String, format: ConfigFormat) throws(HostError)
    -> Bool
  {
    var status = stat()
    if lstat(path, &status) == 0 { return false }
    let contents = format == .jsonc ? ConfigTemplate.jsonc : "{}\n"
    do {
      try AtomicFile.createExclusive(Array(contents.utf8), at: path, mode: 0o644)
    } catch  where lstat(path, &status) == 0 {
      return false
    }
    return true
  }

  package static func upsertProxy(
    at path: String, format: ConfigFormat, provider: ProxyProvider, credential: CredentialReference,
    auth: ProxyAuthScheme, environment: ConfigEnvironment
  ) throws {
    let lock = try FileLock.sibling(of: path)
    defer { lock.release() }
    let existing = try ConfigLoader.readSnapshot(path, limit: JSONLimits.configuration.maxBytes)
    let updated = try ConfigEditor.upsertProxy(
      existing: existing, format: format, path: path, provider: provider, credential: credential,
      auth: auth,
      environment: environment)
    // A `cmd:` reference is not itself secret: 0644 as before, never widened.
    try AtomicFile.write(updated, to: path, mode: .atMost(0o644))
  }
}
