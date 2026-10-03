import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore

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

  struct Startup: Sendable {
    let identity: FilteredReadiness.SigningIdentity
    let policy: FilteredHandoff.BootPolicy

    func persistVerificationKey(_ instance: Instance, provider: ProxyProvider) throws {
      try AtomicFile.write(
        Array(identity.verificationKey.encoded.utf8),
        to: BrokerReadiness.keyPath(instance, provider: provider), mode: .atMost(0o600))
    }
  }

  static func request(nonce: String) -> [UInt8] {
    Array(
      ("GET /__iso/broker-ready HTTP/1.1\r\nHost: localhost\r\nX-Iso-Nonce: \(nonce)\r\nConnection: close\r\n\r\n")
        .utf8)
  }

  private struct Reply: Decodable {
    let version: Int
    let nonce: String
    let provider: String
    let bootID: String
    let policyHash: String
    let signature: String
  }

  static func verifies(
    _ response: [UInt8], nonce: String, provider: ProxyProvider,
    policy: FilteredHandoff.BootPolicy, key: FilteredReadiness.VerificationKey
  ) -> Bool {
    guard response.count <= 1024, let text = String(bytes: response, encoding: .utf8),
      let split = text.range(of: "\r\n\r\n")
    else { return false }
    let headers = text[..<split.lowerBound].components(separatedBy: "\r\n")
    let body = Data(text[split.upperBound...].utf8)
    guard headers.count == 3, headers[0] == "HTTP/1.1 200 OK",
      headers[1].lowercased() == "content-length: \(body.count)",
      headers[2].lowercased() == "connection: close",
      let reply = try? JSONDecoder().decode(Reply.self, from: body),
      reply.version == 1, reply.nonce == nonce, reply.provider == provider.rawValue,
      reply.bootID == policy.bootID, reply.policyHash == policy.policyHash,
      let signature = Data(base64Encoded: reply.signature), signature.count == 64
    else { return false }
    let message =
      "iso-broker-readiness-v1\n\(reply.nonce)\n\(reply.provider)\n\(reply.bootID)\n\(reply.policyHash)\n"
    return key.value.isValidSignature(signature, for: Data(message.utf8))
  }

  @discardableResult
  static func require(
    _ instance: Instance, target: SSHTarget, environment: [String: String],
    provider: ProxyProvider, policy: FilteredHandoff.BootPolicy
  ) throws -> FilteredReadiness.VerificationKey {
    guard
      ProxyLauncher.recordedProcessAlive(
        ProxyLauncher.pidPath(instance, provider.rawValue), expect: .proxy),
      ProxyLauncher.recordedProcessAlive(
        ProxyLauncher.forwardPIDPath(instance, provider.rawValue), expect: .ssh)
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
    let port = provider.port(instance)
    let directNonce = randomHex(16)
    guard
      let response = FilteredReadiness.exchange(port: port, request: request(nonce: directNonce)),
      verifies(response, nonce: directNonce, provider: provider, policy: policy, key: key)
    else {
      throw HostError(
        "FILTERED_BROKER_NOT_READY: authenticated \(provider.rawValue) companion probe failed")
    }
    let guestNonce = randomHex(16)
    let output: ProcessRunner.Output
    do {
      output = try ProcessRunner().capture(
        FilteredReadiness.guestExchangeRequest(
          target, client: SSHClient(environment: environment), port: port,
          request: request(nonce: guestNonce)))
    } catch {
      throw ContextError(
        "FILTERED_BROKER_NOT_READY: \(provider.rawValue) guest-loopback probe did not complete",
        cause: error)
    }
    guard output.termination.succeeded,
      verifies(output.stdout, nonce: guestNonce, provider: provider, policy: policy, key: key)
    else {
      throw HostError(
        "FILTERED_BROKER_NOT_READY: authenticated \(provider.rawValue) guest-loopback probe failed")
    }
    return key
  }

  @discardableResult
  static func requireAll(
    _ instance: Instance, config: IsoConfig, target: SSHTarget,
    environment: [String: String], policy: FilteredHandoff.BootPolicy
  ) throws -> [ProxyProvider: String] {
    var keys: [ProxyProvider: String] = [:]
    for provider in try requiredProviders(instance, config: config) {
      keys[provider] = try require(
        instance, target: target, environment: environment, provider: provider, policy: policy
      ).encoded
    }
    return keys
  }
}
