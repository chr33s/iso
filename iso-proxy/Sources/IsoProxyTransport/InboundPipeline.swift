import IsoProxyCore
import NIOCore
import NIOHTTP1

public enum InboundPipeline {
  /// Must be called on the channel's event loop. No pipelining assistance is
  /// installed: the gate bounds one active request per guest connection.
  public static func configure(
    channel: Channel, config: ProxyConfig,
    connections: Capacity, requests: Capacity
  ) throws {
    var limits = NIOHTTPDecoderLimitConfiguration()
    limits.maxHeaderFieldSize = Limits.headerFieldBytes
    limits.maxHeaderListSize = Limits.headerBlockBytes
    limits.maxHeaderFieldCount = Limits.headerCount
    let wireBudget = HeaderWireBudget()
    try channel.pipeline.syncOperations.addHandlers([
      wireBudget,
      HTTPResponseEncoder(),
      ByteToMessageHandler(
        HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes, limitConfiguration: limits)),
      InboundGate(
        config: config, connections: connections, requests: requests, wireBudget: wireBudget),
    ])
  }
}
