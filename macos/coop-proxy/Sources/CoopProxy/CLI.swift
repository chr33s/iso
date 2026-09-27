import CoopProxyCore
import CoopProxyTransport
import Darwin
import Foundation
import NIOCore
import NIOPosix

@main
struct ProxyMain {
  static func main() async {
    do {
      try Jail.disableCoreDumps()
      try Jail.requireConfinement()
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.isEmpty || arguments == ["--jail-selftest"] else {
        throw Startup.invalidArguments
      }
      let signals = Signals()
      if arguments == ["--jail-selftest"] {
        try await selftest()
        return
      }
      let config = try readConfig()
      let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
      let upstream = UpstreamClient(group: group)
      let connections = ConnectionRegistry()
      do {
        let server = try await Server.bind(
          config: config, group: group, upstream: upstream, registry: connections
        ).get()
        log("coop-proxy ready")
        for await _ in signals.stream { break }
        try await server.close().get()
        await connections.closeAll()
        try await upstream.shutdown()
        try await group.shutdownGracefully()
      } catch {
        await connections.closeAll()
        try? await upstream.shutdown()
        try? await group.shutdownGracefully()
        throw Startup.runtime
      }
    } catch let failure as Jail.Failure {
      log("coop-proxy confinement failure: \(failure)")
      exit(1)
    } catch {
      // Never render error payloads: decoders, HTTP clients and system APIs may
      // embed paths, request targets, or credential-bearing startup values.
      log("coop-proxy startup or runtime failure")
      exit(1)
    }
  }

  enum Startup: Error { case invalidArguments, oversizedConfig, runtime }

  private static func readConfig() throws -> ProxyConfig {
    let input = FileHandle.standardInput
    defer { try? input.close() }
    var data = Data()
    while let chunk = try input.read(upToCount: min(4096, Limits.startupBytes + 1 - data.count)),
      !chunk.isEmpty
    {
      data.append(chunk)
      guard data.count <= Limits.startupBytes else { throw Startup.oversizedConfig }
    }
    return try ProxyConfig(json: data)
  }

  private static func selftest() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = UpstreamClient(group: group)
    do {
      log("coop-proxy self-test: probing Anthropic TLS")
      try await upstream.probeTLS(provider: .anthropic)
      log("coop-proxy self-test: probing OpenAI TLS")
      try await upstream.probeTLS(provider: .openai)
      try await upstream.shutdown()
      try await group.shutdownGracefully()
      log("coop-proxy jail self-test: write/exec/egress denied; DNS/system TLS passed")
    } catch {
      log("coop-proxy self-test failure category: \(String(describing: type(of: error)))")
      if let io = error as? IOError { log("coop-proxy self-test errno: \(io.errnoCode)") }
      try? await upstream.shutdown()
      try? await group.shutdownGracefully()
      throw Startup.runtime
    }
  }

  private static func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
