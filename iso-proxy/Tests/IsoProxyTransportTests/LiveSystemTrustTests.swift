import Foundation
import IsoProxyCore
import NIOPosix
import Testing

@testable import IsoProxyTransport

/// Credential-free network gate; ordinary unit tests stay offline.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ISO_PROXY_LIVE_TLS_TEST"] == "1"))
func liveProviderSystemTrust() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let upstream = UpstreamClient(group: group)
  do {
    for provider in Provider.allCases { try await upstream.probeTLS(provider: provider) }
    try await upstream.shutdown()
    try await group.shutdownGracefully()
  } catch {
    try? await upstream.shutdown()
    try? await group.shutdownGracefully()
    throw error
  }
}
