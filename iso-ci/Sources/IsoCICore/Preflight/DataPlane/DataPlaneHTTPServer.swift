import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// HTTP/1.1 for the scoped endpoint over Unix domain sockets — one socket per
/// allocation, reached only through that allocation's VM-bound SSH reverse
/// forward. There is no TCP listener. Requests on an allocation's socket are
/// bound to it, so one guest cannot use (or exhaust) another's socket.
/// Bounded everywhere: connections per socket, a deadline for the request
/// head and for the whole request, buffered header bytes, body size per
/// route, idle time; the service bounds the rest.
package final class DataPlaneHTTPServer: Sendable {
  package struct Limits: Sendable {
    package var maxHeaderBytes = 64 << 10
    package var maxJSONBody = 1 << 20
    /// Cache chunks (toolkit default 32 MiB) and blob blocks.
    package var maxUploadBody = 33 << 20
    /// Connections per allocation socket.
    package var maxConnections = 16
    package var idleTimeout: TimeAmount = .seconds(120)
    /// The request line and headers must arrive within this time.
    package var headerTimeout: TimeAmount = .seconds(10)
    /// The whole request (head and body) must arrive within this time.
    package var requestTimeout: TimeAmount = .seconds(300)

    package init() {}
  }

  private let channel: any Channel
  private let ownedGroup: MultiThreadedEventLoopGroup?
  package let socketPath: String

  private init(channel: any Channel, ownedGroup: MultiThreadedEventLoopGroup?, socketPath: String) {
    self.channel = channel
    self.ownedGroup = ownedGroup
    self.socketPath = socketPath
  }

  /// Binds `socketPath` (replacing a stale socket file) with mode 0600.
  /// `allocation` binds every request on it; nil only in tests.
  package static func start(
    socketPath: String, service: DataPlaneService, allocation: AllocationID?,
    group shared: MultiThreadedEventLoopGroup? = nil, limits: Limits = Limits()
  )
    async throws(CIError) -> DataPlaneHTTPServer
  {
    let owned = shared == nil ? MultiThreadedEventLoopGroup(numberOfThreads: 2) : nil
    let group: MultiThreadedEventLoopGroup = shared ?? owned!
    let connections = ConnectionCounter()
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(.backlog, value: 64)
      .childChannelInitializer { channel in
        let admitted = connections.count.withLock { count -> Bool in
          guard count < limits.maxConnections else { return false }
          count += 1
          return true
        }
        guard admitted else { return channel.close() }
        channel.closeFuture.whenComplete { _ in connections.count.withLock { $0 -= 1 } }
        return channel.eventLoop.makeCompletedFuture {
          let sync = channel.pipeline.syncOperations
          try sync.addHandler(
            ByteToMessageHandler(
              HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes),
              maximumBufferSize: limits.maxHeaderBytes))
          try sync.addHandler(HTTPResponseEncoder())
          try sync.addHandler(HTTPServerPipelineHandler())
          try sync.addHandler(IdleStateHandler(allTimeout: limits.idleTimeout))
          try sync.addHandler(
            DataPlaneHTTPHandler(service: service, allocation: allocation, limits: limits))
        }
      }
    do {
      let channel = try await bootstrap.bind(
        unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true
      ).get()
      chmod(socketPath, 0o600)
      return DataPlaneHTTPServer(channel: channel, ownedGroup: owned, socketPath: socketPath)
    } catch {
      try? await owned?.shutdownGracefully()
      throw CIError(.storage, "cannot bind the preflight endpoint socket")
    }
  }

  package var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

  package func close() async {
    try? await channel.close()
    unlink(socketPath)
    try? await ownedGroup?.shutdownGracefully()
  }
}

/// Aggregates one request (bounded per route), hands it to the service, and
/// writes the response (streaming file bodies with sendfile).
final class DataPlaneHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let service: DataPlaneService
  private let allocation: AllocationID?
  private let limits: DataPlaneHTTPServer.Limits
  private var head: HTTPRequestHead?
  private var body: [UInt8] = []
  private var limit = 0
  private var refused = false
  private var deadline: Scheduled<Void>?

  init(service: DataPlaneService, allocation: AllocationID?, limits: DataPlaneHTTPServer.Limits) {
    self.service = service
    self.allocation = allocation
    self.limits = limits
  }

  /// Closes the connection unless `deadline` is cancelled first.
  private func arm(_ context: ChannelHandlerContext, _ timeout: TimeAmount) {
    deadline?.cancel()
    let channel = context.channel
    deadline = context.eventLoop.scheduleTask(in: timeout) { channel.close(promise: nil) }
  }

  func handlerAdded(context: ChannelHandlerContext) {
    arm(context, limits.headerTimeout)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    deadline?.cancel()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      arm(context, limits.requestTimeout)
      self.head = head
      body = []
      refused = false
      let upload =
        (head.method == .PATCH && head.uri.hasPrefix("/cache/"))
        || (head.method == .PUT && head.uri.hasPrefix("/isoci/"))
      limit = upload ? limits.maxUploadBody : limits.maxJSONBody
      if let declared = head.headers.first(name: "content-length").flatMap(Int.init),
        declared > limit
      {
        refuse(context, 413)
      }
    case .body(var buffer):
      guard !refused else { return }
      if body.count + buffer.readableBytes > limit {
        refuse(context, 413)
        return
      }
      body += buffer.readBytes(length: buffer.readableBytes) ?? []
    case .end:
      guard !refused, let head else { return }
      // The response may take a long poll; the next request gets a fresh
      // header deadline once this one is answered.
      deadline?.cancel()
      deadline = nil
      self.head = nil
      var headers: [String: String] = [:]
      for (name, value) in head.headers { headers[name] = value }
      var request = DataPlaneRequest(
        method: head.method.rawValue, target: head.uri, headers: headers, body: body)
      request.boundAllocation = allocation
      let bound = request
      body = []
      let keepAlive = head.isKeepAlive
      let version = head.version
      let promise = context.eventLoop.makePromise(of: DataPlaneResponse.self)
      let service = self.service
      promise.completeWithTask { await service.handle(bound) }
      let loop = NIOLoopBound((context, self), eventLoop: context.eventLoop)
      promise.futureResult.whenSuccess { response in
        let (context, handler) = loop.value
        Self.write(response, context: context, version: version, keepAlive: keepAlive)
        if keepAlive { handler.arm(context, handler.limits.headerTimeout) }
      }
    }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is IdleStateHandler.IdleStateEvent {
      context.close(promise: nil)
    } else {
      context.fireUserInboundEventTriggered(event)
    }
  }

  private func refuse(_ context: ChannelHandlerContext, _ status: Int) {
    refused = true
    body = []
    let version = head?.version ?? .http1_1
    head = nil
    Self.write(
      .error(status, "request body too large"), context: context, version: version, keepAlive: false
    )
  }

  static func write(
    _ response: DataPlaneResponse, context: ChannelHandlerContext, version: HTTPVersion,
    keepAlive: Bool
  ) {
    var headers = HTTPHeaders()
    for (name, value) in response.headers { headers.add(name: name, value: value) }
    var fileHandle: NIOFileHandle?
    var region: FileRegion?
    var bytes: [UInt8] = []
    var status = response.status
    switch response.body {
    case .bytes(let data): bytes = data
    case .file(let path, let offset, let length):
      let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      // The exported clone is private to this response.
      unlink(path)
      if fd >= 0 {
        let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fd)
        fileHandle = handle
        region = FileRegion(
          fileHandle: handle, readerIndex: Int(offset), endIndex: Int(offset + length))
      } else {
        status = 404
        bytes = DataPlaneResponse.error(404, "not found").bodyBytes
        headers = HTTPHeaders([("Content-Type", "application/json")])
      }
    }
    let length = region.map { $0.readableBytes } ?? bytes.count
    headers.replaceOrAdd(name: "Content-Length", value: String(length))
    headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
    let head = HTTPResponseHead(
      version: version, status: HTTPResponseStatus(statusCode: status), headers: headers)
    context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
    if let region {
      context.write(NIOAny(HTTPServerResponsePart.body(.fileRegion(region))), promise: nil)
    } else if !bytes.isEmpty {
      var buffer = context.channel.allocator.buffer(capacity: bytes.count)
      buffer.writeBytes(bytes)
      context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
    }
    let done = context.eventLoop.makePromise(of: Void.self)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: done)
    let channel = context.channel
    let opened = fileHandle
    done.futureResult.whenComplete { _ in
      try? opened?.close()
      if !keepAlive { channel.close(promise: nil) }
    }
  }
}

final class ConnectionCounter: Sendable {
  let count = Mutex(0)
}
