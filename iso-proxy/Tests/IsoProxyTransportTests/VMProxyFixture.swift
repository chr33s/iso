import Darwin
import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import XCTest

@testable import IsoProxyTransport

/// Opt-in process fixture for the real-VM gate. Never linked into the product.
/// Exercises the shared HTTP bridge with loopback routing and a fixture CA.
final class VMProxyFixture: XCTestCase {
  func testServe() async throws {
    guard let caPath = ProcessInfo.processInfo.environment["ISO_VM_FIXTURE_CA"] else {
      throw XCTSkip("requires the controlled VM integration harness")
    }
    var core = rlimit(rlim_cur: 0, rlim_max: 0)
    XCTAssertEqual(setrlimit(RLIMIT_CORE, &core), 0)
    let probe = "/private/tmp/iso-vm-fixture-" + UUID().uuidString
    let fd = Darwin.open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd >= 0 {
      Darwin.close(fd)
      Darwin.unlink(probe)
      XCTFail("fixture must run under the production profile")
      return
    }
    XCTAssertTrue(errno == EPERM || errno == EACCES)
    let input = FileHandle.standardInput
    let bytes = try XCTUnwrap(try input.read(upToCount: Limits.startupBytes + 1))
    XCTAssertLessThanOrEqual(bytes.count, Limits.startupBytes)
    XCTAssertTrue(try input.readToEnd()?.isEmpty ?? true)
    try input.close()
    let config = try ProxyConfig(json: bytes)
    let ca = try NIOSSLCertificate.fromDERFile(caPath)
    var tls = UpstreamClient.tlsConfiguration()
    tls.additionalTrustRoots = [.certificates([ca])]
    let fixtureTLS = tls
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let registry = ConnectionRegistry()
    let loop = group.next()
    let completed = loop.makePromise(of: Void.self)
    let finished = NIOLockedValueBox(false)
    let finish: @Sendable (Result<Void, Error>) -> Void = { result in
      let first = finished.withLockedValue { value in
        if value { return false }
        value = true
        return true
      }
      if first { completed.completeWith(result) }
    }
    let deadline = loop.scheduleTask(in: .seconds(90)) {
      finish(.failure(FixtureError.timeout))
    }
    let server = try await Server.bind(config: config, group: group, registry: registry) {
      channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config) { request, relay, eventLoop in
              let task = OwnedHTTPRequest(
                request: request, relay: relay, eventLoop: eventLoop,
                tlsConfiguration: fixtureTLS, connectHost: "127.0.0.1")
              task.futureResult.whenFailure { error in
                // This synthetic-credential fixture runs only under the test harness.
                // Report transport failures before the guest's 502 triggers cleanup.
                FileHandle.standardError.write(Data("VM_PROXY_UPSTREAM_FAILED: \(error)\n".utf8))
              }
              task.futureResult.flatMap { channel.closeFuture }.whenComplete(finish)
              return task
            })
        }
      }
    }.get()
    FileHandle.standardOutput.write(Data("VM_PROXY_READY\n".utf8))
    do {
      try await completed.futureResult.get()
      deadline.cancel()
      try await server.close().get()
      await registry.closeAll()
      try await group.shutdownGracefully()
    } catch {
      deadline.cancel()
      try? await server.close().get()
      await registry.closeAll()
      try? await group.shutdownGracefully()
      throw error
    }
  }

  private enum FixtureError: Error { case timeout }
}
