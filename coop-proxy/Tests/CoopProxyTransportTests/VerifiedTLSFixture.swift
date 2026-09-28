import Foundation
import NIOSSL

@testable import CoopProxyTransport

/// A per-evaluation trust anchor; never modifies the host trust store.
func verifiedTLSFixture() throws -> (server: NIOSSLContext, client: TLSConfiguration) {
  let fixtures = try generateForwardingFixtures()
  defer { try? FileManager.default.removeItem(at: fixtures) }
  let ca = try NIOSSLCertificate.fromDERFile(fixtures.appendingPathComponent("forward_ca.der").path)
  let leaf = try NIOSSLCertificate.fromDERFile(
    fixtures.appendingPathComponent("forward_leaf.der").path)
  let key = try NIOSSLPrivateKey(
    file: fixtures.appendingPathComponent("forward_leaf.pkcs8.der").path, format: .der)
  let server = try NIOSSLContext(
    configuration: .makeServerConfiguration(
      certificateChain: [.certificate(leaf), .certificate(ca)], privateKey: .privateKey(key)))
  var client = UpstreamClient.tlsConfiguration()
  client.additionalTrustRoots = [.certificates([ca])]
  return (server, client)
}
