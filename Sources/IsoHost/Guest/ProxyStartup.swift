// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy

extension ProxyLauncher {
  /// Version 1 for open-network boots; version 2 requires a signed readiness
  /// identity; version 3 adds the policy `authorization` block, which always
  /// requires signed readiness. Off-mode launches keep version 1 or 2.
  static func wireConfig(
    listen: String, capabilityToken: Secret<String>, provider: ProxyProvider,
    auth: ProxyAuthScheme, credential: Secret<String>, readiness: BrokerReadiness.Startup? = nil
  ) -> Secret<[UInt8]> {
    let scheme = auth.wireName
    let version: UInt64 = readiness?.authorization != nil ? 3 : (readiness == nil ? 1 : 2)
    var document = OrderedJSON.Members([
      ("listen", .string(listen)), ("capability_token", .string(capabilityToken.expose())),
      ("version", .uint(version)), ("provider", .string(provider.rawValue)),
      (
        "injection",
        .object(
          .init([("scheme", .string(scheme)), ("credential", .string(credential.expose()))]))
      ),
    ])
    if let readiness {
      var block = OrderedJSON.Members([
        ("privateKeyHex", .string(readiness.identity.startupKey.expose()))
      ])
      if let policy = readiness.policy {
        block["bootID"] = .string(policy.bootID)
        block["policyHash"] = .string(policy.policyHash)
      }
      document["readiness"] = .object(block)
    }
    if let authorization = readiness?.authorization {
      // Host-origin identity and the normalized policy; no credential.
      document["authorization"] = .object(
        .init([
          ("schemaVersion", .uint(1)),
          ("canonicalizationVersion", .uint(UInt64(PolicySchema.canonicalizationVersion))),
          ("instanceID", .string(authorization.instanceID)),
          ("instanceName", .string(authorization.instanceName)),
          ("bootID", .string(authorization.bootID)),
          ("policyEpoch", .string(authorization.policyEpoch)),
          ("proxyGenerationID", .string(authorization.proxyGenerationID)),
          ("policyDigest", .string(authorization.policyDigest)),
          ("policy", .string(authorization.canonicalPolicy)),
        ]))
    }
    return Secret(Array(OrderedJSON.object(document).compact.utf8))
  }
}
