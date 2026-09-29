import Foundation
import IsoCore
import IsoHost

/// A secret store that behaves like the CLI's: only names not yet cached
/// cost an unlock (one recorded call), and a missing name fails the batch.
final class CountingSecrets: SecretReferenceResolver, @unchecked Sendable {
  var calls: [Set<SecretName>] = []
  let values: [String: String]
  private var cache: [SecretName: Secret<[UInt8]>] = [:]
  init(_ values: [String: String]) { self.values = values }

  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>] {
    let missing = names.subtracting(cache.keys)
    if !missing.isEmpty {
      calls.append(missing)
      var found: [SecretName: Secret<[UInt8]>] = [:]
      for name in missing {
        guard let value = values[name.rawValue] else { throw HostError("not found: \(name)") }
        found[name] = Secret(Array(value.utf8))
      }
      cache.merge(found) { $1 }
    }
    return cache.filter { names.contains($0.key) }
  }
}
