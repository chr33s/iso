import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy

/// Required remote brokers compose with the filtered transport proof. Local
/// models and off mode do not authorize or require a provider broker.
enum BrokerReadiness {
  static func requiredProviders(_ instance: Instance, config: IsoConfig) throws -> [ProxyProvider] {
    guard try ModelState.loadOrDefault(instance).mode == .remote else { return [] }
    return try ProxyProvider.allCases.filter {
      try ProxyState.effectiveUpstream(instance, $0, config: config.proxy) != nil
    }
  }

  static func keyPath(_ instance: Instance, provider: ProxyProvider) -> String {
    instance.directory + "/proxy-\(provider.rawValue)-readiness-public-key"
  }

  /// A version 2 proxy carries only `policy` (the network boot policy); a
  /// version 3 proxy always carries `authorization` and, for a filtered
  /// boot, `policy` too.
  struct Startup: Sendable {
    let identity: FilteredReadiness.SigningIdentity
    let policy: FilteredHandoff.BootPolicy?
    var authorization: ProxyAuthorizationStartup? = nil

    func persistVerificationKey(_ instance: Instance, provider: ProxyProvider) throws {
      try AtomicFile.write(
        Array(identity.verificationKey.encoded.utf8),
        to: BrokerReadiness.keyPath(instance, provider: provider), mode: .atMost(0o600))
    }
  }

  /// The broker answers only a holder of its guest capability. The guest
  /// already holds it, so the guest-loopback probe discloses nothing new.
  /// A proxy an older iso started asks for none, and refuses a probe that
  /// carries one; see ``capabilities(_:provider:)``.
  static func request(nonce: String, capability: Secret<String>?) -> [UInt8] {
    let authorization = capability.map { "Authorization: Bearer \($0.expose())\r\n" } ?? ""
    return Array(
      ("GET /__iso/broker-ready HTTP/1.1\r\nHost: localhost\r\nX-Iso-Nonce: \(nonce)\r\nConnection: close\r\n\(authorization)\r\n")
        .utf8)
  }

  static func capability(_ instance: Instance, provider: ProxyProvider) -> Secret<String>? {
    ProxyLauncher.capabilityToken(instance, provider: provider)
  }

  /// The probes to try, in order: with the persisted capability, then
  /// without one, for a proxy an older iso started (which persisted no
  /// Anthropic token, and rejects any probe that carries a capability). A
  /// current proxy refuses the bare probe, so readiness still fails
  /// closed; every reply is verified against the persisted key either way.
  static func capabilities(_ instance: Instance, provider: ProxyProvider) -> [Secret<String>?] {
    capability(instance, provider: provider).map { [$0, nil] } ?? [nil]
  }

  private struct Reply: Decodable {
    let version: Int
    let nonce: String
    let provider: String
    let bootID: String
    let policyHash: String
    let signature: String
    // Version 3 only.
    let instanceID: String?
    let policyBootID: String?
    let policyEpoch: String?
    let policyDigest: String?
    let proxyGenerationID: String?
  }

  /// The signed text of a version 3 reply. Absent network fields are empty.
  static func messageV3(
    nonce: String, provider: String, bootID: String, policyHash: String, instanceID: String,
    policyBootID: String, policyEpoch: String, policyDigest: String, proxyGenerationID: String
  ) -> String {
    "iso-broker-readiness-v3\n\(nonce)\n\(provider)\n\(bootID)\n\(policyHash)\n\(instanceID)\n\(policyBootID)\n\(policyEpoch)\n\(policyDigest)\n\(proxyGenerationID)\n"
  }

  /// A legacy reply must match `policy`; with `authorization`, only a
  /// version 3 reply binding that boot, epoch, digest and proxy generation
  /// verifies. The two identities never substitute for each other.
  static func verifies(
    _ response: [UInt8], nonce: String, provider: ProxyProvider,
    policy: FilteredHandoff.BootPolicy?, authorization: ProxyAuthorizationStartup? = nil,
    key: FilteredReadiness.VerificationKey
  ) -> Bool {
    guard policy != nil || authorization != nil,
      response.count <= 1024,
      let text = String(bytes: response, encoding: .utf8),
      let split = text.range(of: "\r\n\r\n")
    else { return false }
    let headers = text[..<split.lowerBound].components(separatedBy: "\r\n")
    let body = Data(text[split.upperBound...].utf8)
    guard headers.count == 3, headers[0] == "HTTP/1.1 200 OK",
      headers[1].lowercased() == "content-length: \(body.count)",
      headers[2].lowercased() == "connection: close",
      let reply = try? JSONDecoder().decode(Reply.self, from: body),
      reply.nonce == nonce, reply.provider == provider.rawValue,
      reply.bootID == (policy?.bootID ?? ""), reply.policyHash == (policy?.policyHash ?? ""),
      let signature = Data(base64Encoded: reply.signature), signature.count == 64
    else { return false }
    let message: String
    if let authorization {
      guard reply.version == 3, reply.instanceID == authorization.instanceID,
        reply.policyBootID == authorization.bootID,
        reply.policyEpoch == authorization.policyEpoch,
        reply.policyDigest == authorization.policyDigest,
        reply.proxyGenerationID == authorization.proxyGenerationID
      else { return false }
      message = messageV3(
        nonce: reply.nonce, provider: reply.provider, bootID: reply.bootID,
        policyHash: reply.policyHash, instanceID: authorization.instanceID,
        policyBootID: authorization.bootID, policyEpoch: authorization.policyEpoch,
        policyDigest: authorization.policyDigest,
        proxyGenerationID: authorization.proxyGenerationID)
    } else {
      guard reply.version == 1, reply.instanceID == nil, reply.policyEpoch == nil else {
        return false
      }
      message =
        "iso-broker-readiness-v1\n\(reply.nonce)\n\(reply.provider)\n\(reply.bootID)\n\(reply.policyHash)\n"
    }
    return key.value.isValidSignature(signature, for: Data(message.utf8))
  }

  /// Processes, identity and the signed reply on host loopback only; never
  /// connects to the guest.
  @discardableResult
  static func requireDirect(
    _ instance: Instance, provider: ProxyProvider, policy: FilteredHandoff.BootPolicy?,
    tunnelAddress: String?
  ) throws -> FilteredReadiness.VerificationKey {
    // A policy-bound proxy must prove the stored binding; corrupt state fails.
    try requireDirect(
      instance, provider: provider, policy: policy, tunnelAddress: tunnelAddress,
      authorization: try ProxyAuthorizationStartup.expected(instance, provider: provider)
    ).key
  }

  /// The verification key, and the capability the companion answered the
  /// direct probe for (nil: it answered the bare probe), which the guest
  /// probe then uses.
  private static func requireDirect(
    _ instance: Instance, provider: ProxyProvider, policy: FilteredHandoff.BootPolicy?,
    tunnelAddress: String?, authorization: ProxyAuthorizationStartup?
  ) throws -> (key: FilteredReadiness.VerificationKey, capability: Secret<String>?) {
    guard
      ProxyLauncher.recordedProcessAlive(
        ProxyLauncher.pidPath(instance, provider.rawValue), expect: .proxy),
      TunnelIdentity.verify(instance, provider.rawValue, address: tunnelAddress)
    else {
      throw HostError(
        "FILTERED_BROKER_NOT_READY: \(provider.rawValue) process or tunnel is not running; restart the instance"
      )
    }
    let key: FilteredReadiness.VerificationKey
    do {
      key = try FilteredReadiness.readVerificationKey(at: keyPath(instance, provider: provider))
    } catch {
      throw ContextError(
        "FILTERED_BROKER_NOT_READY: \(provider.rawValue) readiness identity unavailable",
        cause: error)
    }
    guard
      let answered = directProbe(
        instance, provider: provider, policy: policy, authorization: authorization, key: key)
    else {
      // A current proxy refuses the bare probe: with no token on disk it
      // can never pass, and only a restart writes one.
      let hint =
        capability(instance, provider: provider) == nil
        ? "; its capability is unavailable, so restart the instance" : ""
      throw HostError(
        "FILTERED_BROKER_NOT_READY: authenticated \(provider.rawValue) companion probe failed\(hint)"
      )
    }
    return (key, answered)
  }

  /// The capability the companion answered a verified direct probe for
  /// (`.some(nil)`: it answered the bare probe), or nil when none did.
  static func directProbe(
    _ instance: Instance, provider: ProxyProvider, policy: FilteredHandoff.BootPolicy?,
    authorization: ProxyAuthorizationStartup?, key: FilteredReadiness.VerificationKey
  ) -> Secret<String>?? {
    for capability in capabilities(instance, provider: provider) {
      let nonce = randomHex(16)
      if let response = FilteredReadiness.exchange(
        port: provider.port(instance), request: request(nonce: nonce, capability: capability)),
        verifies(
          response, nonce: nonce, provider: provider, policy: policy,
          authorization: authorization, key: key)
      {
        return .some(capability)
      }
    }
    return nil
  }

  @discardableResult
  static func require(
    _ instance: Instance, target: SSHTarget, environment: [String: String],
    provider: ProxyProvider, policy: FilteredHandoff.BootPolicy?
  ) throws -> FilteredReadiness.VerificationKey {
    // One load of the expected identity serves both probes.
    let authorization = try ProxyAuthorizationStartup.expected(instance, provider: provider)
    // The guest probe uses what the direct probe was answered for.
    let (key, capability) = try requireDirect(
      instance, provider: provider, policy: policy, tunnelAddress: target.address,
      authorization: authorization)
    let port = provider.port(instance)
    let guestNonce = randomHex(16)
    let output: ProcessRunner.Output
    do {
      output = try ProcessRunner().capture(
        FilteredReadiness.guestExchangeRequest(
          target, client: SSHClient(environment: environment), port: port,
          request: request(nonce: guestNonce, capability: capability)))
    } catch {
      throw ContextError(
        "FILTERED_BROKER_NOT_READY: \(provider.rawValue) guest-loopback probe did not complete",
        cause: error)
    }
    guard output.termination.succeeded,
      verifies(
        output.stdout, nonce: guestNonce, provider: provider, policy: policy,
        authorization: authorization, key: key)
    else {
      throw HostError(
        "FILTERED_BROKER_NOT_READY: authenticated \(provider.rawValue) guest-loopback probe failed")
    }
    return key
  }

  /// Every required broker, through guest loopback too for `.guest`.
  @discardableResult
  static func requireAll(
    _ instance: Instance, config: IsoConfig, scope: FilteredReadiness.Scope,
    environment: [String: String], policy: FilteredHandoff.BootPolicy
  ) throws -> [ProxyProvider: String] {
    var keys: [ProxyProvider: String] = [:]
    for provider in try requiredProviders(instance, config: config) {
      keys[provider] =
        switch scope {
        case .host:
          try requireDirect(instance, provider: provider, policy: policy, tunnelAddress: nil)
            .encoded
        case .guest(let target):
          try require(
            instance, target: target, environment: environment, provider: provider,
            policy: policy
          ).encoded
        }
    }
    return keys
  }
}
