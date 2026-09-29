import AsyncHTTPClient
import IsoProxyCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// One dedicated client per proxy process. Call shutdown before stopping the
/// externally owned event loop group. No caller environment is consulted.
public final class UpstreamClient: Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let work = UpstreamWork()
  private let resolutions = Capacity(Limits.requests)
  private let resolutionFactory: BoundedResolver.Factory
  private let socketCapacity: Capacity

  public convenience init(group: MultiThreadedEventLoopGroup) {
    self.init(group: group, resolutionFactory: { NIORandomizedDNSResolver(loop: $0) })
  }

  // Internal resolver seam for deterministic cancellation/admission tests.
  init(
    group: MultiThreadedEventLoopGroup, socketCapacity: Capacity = Capacity(Limits.connections),
    resolutionFactory: @escaping BoundedResolver.Factory
  ) {
    self.socketCapacity = socketCapacity
    self.resolutionFactory = resolutionFactory
    self.group = group
  }

  func execute(request: HTTPClient.Request, relay: ResponseRelay, eventLoop: EventLoop)
    -> OwnedHTTPRequest
  {
    do {
      return try work.start {
        let task = OwnedHTTPRequest(
          request: request, relay: relay, eventLoop: eventLoop,
          resolver: BoundedResolver(
            eventLoop: eventLoop, capacity: resolutions, factory: resolutionFactory),
          socketCapacity: socketCapacity)
        return (task, .init(cancel: { task.cancel() }, completion: task.futureResult))
      }
    } catch {
      return OwnedHTTPRequest(rejected: error, relay: relay, eventLoop: eventLoop)
    }
  }

  static func tlsConfiguration() -> TLSConfiguration {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .fullVerification
    // NIOSSL 2.36.1 SSLContext selects Security.framework for .default on
    // Darwin. Supplying .certificates or .file would bypass that path.
    tls.trustRoots = .default
    tls.additionalTrustRoots = []
    tls.applicationProtocols = ["http/1.1"]
    return tls
  }

  static func configuration() -> HTTPClient.Configuration {
    var config = HTTPClient.Configuration(
      tlsConfiguration: tlsConfiguration(), redirectConfiguration: .disallow,
      timeout: .init(connect: .seconds(30), read: nil), proxy: nil,
      decompression: .disabled)
    config.httpVersion = .http1Only
    config.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = Limits.requests
    config.connectionPool.retryConnectionEstablishment = false
    config.connectionPool.preWarmedHTTP1ConnectionCount = 0
    config.maximumUsesPerConnection = 1
    return config
  }

  static func request(head: HTTPRequestHead, config: ProxyConfig, body: HTTPClient.Body) throws
    -> HTTPClient.Request
  {
    let target = try RequestTarget(head.uri)
    guard
      OperationPolicy.allows(
        method: head.method.rawValue, target: target, provider: config.provider)
    else { throw PolicyError.invalidTarget }
    let headers = try HeaderPolicy.request(
      head.headers.map { Header($0.name, $0.value) },
      provider: config.provider, injection: config.injection)
    return try HTTPClient.Request(
      url: "https://" + config.provider.hostname + target.raw,
      method: head.method, headers: HTTPHeaders(headers.map { ($0.name, $0.value) }), body: body)
  }

  /// Credential-free DNS/TLS probe through the forwarding transport. It sends
  /// no HTTP request and never receives or injects a provider credential.
  public func probeTLS(provider: Provider) async throws {
    let loop = group.next()
    let (connection, completed) = try await loop.submit { [self] in
      try work.start {
        let connection = try CancellableTLSConnection(
          host: provider.hostname, port: provider.port, serverHostname: provider.hostname,
          configuration: Self.tlsConfiguration(), eventLoop: loop,
          resolver: BoundedResolver(
            eventLoop: loop, capacity: resolutions, factory: resolutionFactory),
          socketCapacity: socketCapacity)
        let completed = loop.makePromise(of: Void.self)
        return (
          (connection, completed),
          UpstreamWork.Operation(
            cancel: { connection.cancel() }, completion: completed.futureResult)
        )
      }
    }.get()
    defer {
      connection.cancel()
      completed.succeed(())
    }
    let channel = try await withTaskCancellationHandler {
      try await connection.established.get()
    } onCancel: {
      connection.cancel()
    }
    connection.cancel()
    try await channel.closeFuture.get()
  }

  public func shutdown() async throws { await work.shutdown() }
}
