import IsoProxyCore
import NIOCore
import NIOPosix

/// Socket listener shared by the production bridge and controlled test harness.
/// The executable must establish confinement before calling bind.
package enum Server {
  package static func bind(
    config: ProxyConfig, group: MultiThreadedEventLoopGroup,
    upstream: UpstreamClient, registry: ConnectionRegistry = ConnectionRegistry()
  ) -> EventLoopFuture<Channel> {
    bind(config: config, group: group, registry: registry) { channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config, upstream: upstream))
        }
      }
    }
  }

  package static func bind(
    config: ProxyConfig, group: EventLoopGroup, registry: ConnectionRegistry = ConnectionRegistry(),
    application: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
  ) -> EventLoopFuture<Channel> {
    let connections = Capacity(Limits.connections)
    let requests = Capacity(Limits.requests)
    return ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: Int32(Limits.connections))
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
      .childChannelOption(
        ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1024)
      )
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelInitializer { channel in
        registry.add(channel)
        do {
          try InboundPipeline.configure(
            channel: channel, config: config,
            connections: connections, requests: requests)
          return application(channel)
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .bind(host: config.listen.host, port: config.listen.port)
  }
}
