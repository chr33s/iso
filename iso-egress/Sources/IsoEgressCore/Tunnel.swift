import Darwin
import Foundation

/// Relays an already-approved CONNECT. The connector is called with the
/// hostname only, after the request head has been consumed, so proxy
/// authentication is not written upstream.
public enum Tunnel {
  public static func open(
    _ client: Int32, host: String, connect: (String) throws -> Int32?, alive: () -> Bool = { true }
  ) rethrows {
    guard let upstream = try connect(host) else {
      ConnectGate.writeResponse(client, .addressNotPublic)
      return
    }
    defer { close(upstream) }
    ConnectGate.writeResponse(client, nil)
    relay(client, upstream, alive: alive)
  }

  /// Copies bytes in both directions until one side closes, `alive` is false,
  /// or `maxReads` reads have completed. Nothing is inserted between the bytes.
  public static func relay(
    _ left: Int32, _ right: Int32, alive: () -> Bool = { true }, maxReads: Int? = nil
  ) {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    var fds = [
      pollfd(fd: left, events: Int16(POLLIN), revents: 0),
      pollfd(fd: right, events: Int16(POLLIN), revents: 0),
    ]
    var reads = 0
    while alive() {
      if let maxReads, reads >= maxReads { return }
      if poll(&fds, 2, 200) <= 0 { continue }
      for index in 0..<2 where fds[index].revents & Int16(POLLIN) != 0 {
        let count = recv(fds[index].fd, &buffer, buffer.count, 0)
        if count <= 0 { return }
        let peer = fds[1 - index].fd
        var sent = 0
        while sent < count {
          let n = buffer.withUnsafeBytes { send(peer, $0.baseAddress! + sent, count - sent, 0) }
          if n <= 0 { return }
          sent += n
        }
        reads += 1
      }
    }
  }
}
