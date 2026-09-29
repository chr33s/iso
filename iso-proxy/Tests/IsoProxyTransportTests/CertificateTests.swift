import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import IsoProxyTransport

@Test func systemTrustCertificateMatrix() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try generateCertificates(directory)
  let ca = try #require(
    NIOSSLCertificate.fromPEMFile(directory.appendingPathComponent("ca.pem").path).first)
  let key = try NIOSSLPrivateKey(
    file: directory.appendingPathComponent("server.key").path, format: .pem)
  for (name, anchored, accepted) in [
    ("valid", true, true), ("wrong-host", true, false),
    ("expired", true, false), ("future", true, false),
    ("valid", false, false), ("self-signed", false, false), ("self-signed", true, true),
  ] {
    let certificate = try #require(
      NIOSSLCertificate.fromPEMFile(directory.appendingPathComponent(name + ".pem").path).first)
    let chain: [NIOSSLCertificateSource] =
      name == "self-signed"
      ? [.certificate(certificate)] : [.certificate(certificate), .certificate(ca)]
    let tls = try NIOSSLContext(
      configuration: .makeServerConfiguration(
        certificateChain: chain, privateKey: .privateKey(key)))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let requests = NIOLockedValueBox(0)
    var config = UpstreamClient.configuration()
    if anchored {
      // Keep .default: NIOSSL still selects SecTrust, with a per-evaluation
      // anchor. .certificates as trustRoots would switch to BoringSSL instead.
      config.tlsConfiguration?.additionalTrustRoots = [
        .certificates([name == "self-signed" ? certificate : ca])
      ]
    }
    let client = HTTPClient(eventLoopGroup: group, configuration: config)
    do {
      let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
        }.flatMap {
          channel.pipeline.configureHTTPServerPipeline()
        }.flatMap {
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
              CertificateHTTPHandler(requests: requests))
          }
        }
      }.bind(host: "127.0.0.1", port: 0).get()
      let port = try #require(server.localAddress?.port)
      let request = try HTTPClient.Request(
        url: "https://localhost:\(port)/", method: .POST,
        headers: HTTPHeaders([("authorization", "Bearer synthetic-test-secret")]))
      var tlsFailure = false
      do {
        let response = try await client.execute(request: request, deadline: .now() + .seconds(5))
          .get()
        #expect(response.status == .noContent)
        #expect(accepted, "unexpected TLS acceptance: \(name), anchored=\(anchored)")
      } catch is NIOSSLError {
        tlsFailure = true
        #expect(!accepted, "valid anchored certificate failed TLS")
      }
      #expect(tlsFailure == !accepted)
      #expect(
        requests.withLockedValue { $0 } == (accepted ? 1 : 0),
        "invalid TLS must prevent sending the synthetic credential")
      try await server.close().get()
      try await client.shutdown()
      try await group.shutdownGracefully()
    } catch {
      try? await client.shutdown()
      try await group.shutdownGracefully()
      throw error
    }
  }
}

private func generateCertificates(_ directory: URL) throws {
  let generator = try #require(
    Bundle.module.url(
      forResource: "generate-certificates", withExtension: "py", subdirectory: "Fixtures"))
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  process.arguments = [generator.path, directory.path]
  process.environment = [:]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0, "disposable certificate generation failed")
}

private final class CertificateHTTPHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let requests: NIOLockedValueBox<Int>
  init(requests: NIOLockedValueBox<Int>) { self.requests = requests }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head: requests.withLockedValue { $0 += 1 }
    case .end:
      context.write(
        wrapOutboundOut(.head(.init(version: .http1_1, status: .noContent))), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    case .body: break
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
