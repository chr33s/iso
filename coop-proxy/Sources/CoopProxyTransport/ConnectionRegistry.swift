import NIOConcurrencyHelpers
import NIOCore

/// Tracks children so shutdown cancels streams before shutting down the client.
/// The closing flag covers accepts racing with listener shutdown.
public final class ConnectionRegistry: Sendable {
  private struct State {
    var closing = false
    var channels: [ObjectIdentifier: Channel] = [:]
  }
  private let state = NIOLockedValueBox(State())
  public init() {}

  func add(_ channel: Channel) {
    let id = ObjectIdentifier(channel)
    let accepted = state.withLockedValue { state in
      guard !state.closing else { return false }
      state.channels[id] = channel
      return true
    }
    guard accepted else {
      channel.close(promise: nil)
      return
    }
    channel.closeFuture.whenComplete { [weak self] _ in
      _ = self?.state.withLockedValue { $0.channels.removeValue(forKey: id) }
    }
  }

  public func closeAll() async {
    let channels = state.withLockedValue { state in
      state.closing = true
      let channels = Array(state.channels.values)
      state.channels.removeAll()
      return channels
    }
    for channel in channels { try? await channel.close().get() }
  }
}
