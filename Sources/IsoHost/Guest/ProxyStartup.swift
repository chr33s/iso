// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

extension ProxyLauncher {
  /// Version 1 for open-network boots; version 2 requires a signed readiness identity.
  static func wireConfig(
    listen: String, capabilityToken: Secret<String>, provider: ProxyProvider,
    auth: ProxyAuthScheme, credential: Secret<String>, readiness: BrokerReadiness.Startup? = nil
  ) -> Secret<[UInt8]> {
    let scheme = auth.wireName
    var document = OrderedJSON.Members([
      ("listen", .string(listen)), ("capability_token", .string(capabilityToken.expose())),
      ("version", .uint(readiness == nil ? 1 : 2)), ("provider", .string(provider.rawValue)),
      (
        "injection",
        .object(
          .init([("scheme", .string(scheme)), ("credential", .string(credential.expose()))]))
      ),
    ])
    if let readiness {
      document["readiness"] = .object(
        .init([
          ("privateKeyHex", .string(readiness.identity.startupKey.expose())),
          ("bootID", .string(readiness.policy.bootID)),
          ("policyHash", .string(readiness.policy.policyHash)),
        ]))
    }
    return Secret(Array(OrderedJSON.object(document).compact.utf8))
  }

}
