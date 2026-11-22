// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// Writes to the configuration file. Every edit rereads it under the writer lock
/// (no lost concurrent edits), edits the structural form, verifies the result and
/// replaces the file atomically without widening its mode; any failure leaves the
/// previous file untouched.
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
      try AtomicFile.createExclusive(Array(contents.utf8), at: path, mode: 0o600)
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
    // Owner-only: the file may also hold a literal `api_key`.
    try AtomicFile.write(updated, to: path, mode: .atMost(0o600))
  }

  /// `iso inference init`: apply the hardened defaults under the lock.
  /// Returns the keys it changed; nothing is written when none changed.
  package static func applyDefaults(
    at path: String, format: ConfigFormat, settings: [([String], JSONValue)], force: Bool,
    environment: ConfigEnvironment
  ) throws -> [String] {
    let lock = try FileLock.sibling(of: path)
    defer { lock.release() }
    let existing = try ConfigLoader.readSnapshot(path, limit: JSONLimits.configuration.maxBytes)
    let (updated, changed) = try ConfigEditor.applyDefaults(
      existing: existing, format: format, path: path, settings: settings, force: force,
      environment: environment)
    // Owner-only, as for `upsertProxy`: the file may hold a literal `api_key`.
    if !changed.isEmpty { try AtomicFile.write(updated, to: path, mode: .atMost(0o600)) }
    return changed
  }
}
