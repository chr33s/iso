import Darwin
import Foundation

/// Relays an already-approved CONNECT. The connector is called with the
/// hostname only, after the request head has been consumed, so proxy
/// authentication is not written upstream.
package enum Tunnel {
  package static func open(
    _ client: Int32, host: String, connect: (String) throws -> Int32?, alive: () -> Bool = { true }
  ) rethrows {
    guard alive() else { return }
    guard let upstream = try connect(host) else {
      ConnectGate.writeResponse(client, .addressNotPublic, alive: alive)
      return
    }
    defer { close(upstream) }
    guard ConnectGate.writeResponse(client, nil, alive: alive) else { return }
    relay(client, upstream, alive: alive)
  }

  /// Copies bytes until both directions drain after EOF, a hard error occurs,
  /// `alive` is false, or `maxReads` reads have completed. Half-closes are
  /// forwarded only after their queued bytes; backpressure stops reads.
  package static func relay(
    _ left: Int32, _ right: Int32, alive: () -> Bool = { true }, maxReads: Int? = nil,
    idle: Duration = EgressBudgets.idleTunnel, queueCap: Int = EgressBudgets.relayQueue,
    budget: RelayBudget = .shared
  ) {
    let savedLeft = fcntl(left, F_GETFL)
    let savedRight = fcntl(right, F_GETFL)
    guard savedLeft >= 0, savedRight >= 0 else { return }
    defer {
      _ = fcntl(left, F_SETFL, savedLeft)
      _ = fcntl(right, F_SETFL, savedRight)
    }
    var noSignal: Int32 = 1
    guard fcntl(left, F_SETFL, savedLeft | O_NONBLOCK) == 0,
      fcntl(right, F_SETFL, savedRight | O_NONBLOCK) == 0,
      setsockopt(left, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0,
      setsockopt(right, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else { return }
    pump(
      left, right, alive: alive, maxReads: maxReads, idle: idle, queueCap: queueCap, budget: budget,
      read: { fd, pointer, count in recv(fd, pointer, count, 0) },
      write: { fd, pointer, count in send(fd, pointer, count, 0) })
  }

  private enum Phase { case reading, draining, finished }
  private struct Direction {
    var queue: [UInt8] = []
    var phase: Phase = .reading
  }
  private enum Transfer {
    case progress(Int)
    case blocked, end, failed
  }

  static func pump(
    _ left: Int32, _ right: Int32, alive: () -> Bool, maxReads: Int?, idle: Duration, queueCap: Int,
    budget: RelayBudget, read: (Int32, UnsafeMutableRawPointer, Int) -> Int,
    write: (Int32, UnsafeRawPointer, Int) -> Int,
    pollEvents: (inout [pollfd], Int32) -> Int32 = { poll(&$0, 2, $1) }
  ) {
    // Index names the source socket; each queue writes to the other socket.
    let sockets = [left, right]
    var directions = [Direction(), Direction()]
    var held = 0
    defer { budget.release(held) }
    var reads = 0
    var last = Monotonic.now()
    let idleLimit = Monotonic.nanoseconds(idle)
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while alive() {
      if let maxReads, reads >= maxReads { return }
      let now = Monotonic.now()
      if !Monotonic.within(last, now: now, limit: idleLimit) { return }
      var fds = sockets.map { pollfd(fd: $0, events: 0, revents: 0) }
      for index in 0..<2 {
        if directions[index].phase == .reading,
          RelayRoom(
            pending: directions[index].queue.count, perDirection: queueCap,
            aggregateAvailable: budget.available
          ).allowed > 0
        {
          fds[index].events |= Int16(POLLIN)
        }
        if !directions[index].queue.isEmpty { fds[1 - index].events |= Int16(POLLOUT) }
      }
      // poll reports HUP even with no requested events. Ignore paused sockets
      // so a closed source under backpressure cannot turn the wait into a spin.
      for index in 0..<2 where fds[index].events == 0 { fds[index].fd = -1 }
      let remain = idleLimit &- (now &- last)
      let wait = Int32(max(1, min(remain / 1_000_000, 200)))
      if pollEvents(&fds, wait) < 0 {
        if errno == EINTR { continue }
        return
      }
      if fds.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) { return }
      for index in 0..<2 where !directions[index].queue.isEmpty {
        guard fds[1 - index].revents & Int16(POLLOUT | POLLHUP) != 0 else { continue }
        switch flush(&directions[index].queue, to: sockets[1 - index], write: write, budget: budget)
        {
        case .progress(let count):
          held -= count
          last = Monotonic.now()
        case .blocked: break
        case .end, .failed: return
        }
      }
      for index in 0..<2 where directions[index].phase == .reading {
        guard fds[index].revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
        let room = RelayRoom(
          pending: directions[index].queue.count, perDirection: queueCap,
          aggregateAvailable: budget.available
        ).allowed
        guard room > 0 else { continue }
        switch take(
          sockets[index], into: &directions[index].queue, room: room, buffer: &buffer, read: read,
          budget: budget)
        {
        case .progress(let count):
          reads += 1
          last = Monotonic.now()
          held += count
        case .blocked: break
        case .end: directions[index].phase = .draining
        case .failed: return
        }
      }
      for index in 0..<2
      where directions[index].phase == .draining && directions[index].queue.isEmpty {
        if shutdown(sockets[1 - index], SHUT_WR) < 0 {
          if errno == EINTR { continue }
          return
        }
        directions[index].phase = .finished
      }
      if directions.allSatisfy({ $0.phase == .finished }) { return }
    }
  }

  private static func flush(
    _ queue: inout [UInt8], to fd: Int32, write: (Int32, UnsafeRawPointer, Int) -> Int,
    budget: RelayBudget
  ) -> Transfer {
    var error: Int32 = 0
    let count = queue.withUnsafeBytes { raw -> Int in
      guard let base = raw.baseAddress else { return 0 }
      let wrote = write(fd, base, queue.count)
      error = errno
      return wrote
    }
    if count < 0 {
      if error == EAGAIN || error == EWOULDBLOCK || error == EINTR { return .blocked }
      return .failed
    }
    guard count > 0 else { return .failed }
    queue.removeFirst(count)
    budget.release(count)
    return .progress(count)
  }

  private static func take(
    _ fd: Int32, into queue: inout [UInt8], room: Int, buffer: inout [UInt8],
    read: (Int32, UnsafeMutableRawPointer, Int) -> Int, budget: RelayBudget
  ) -> Transfer {
    let reserved = budget.reserve(min(room, buffer.count))
    if reserved == 0 { return .blocked }
    var error: Int32 = 0
    let count = buffer.withUnsafeMutableBytes { raw -> Int in
      guard let base = raw.baseAddress else { return -1 }
      let got = read(fd, base, reserved)
      error = errno
      return got
    }
    if count < 0 {
      budget.release(reserved)
      if error == EAGAIN || error == EWOULDBLOCK || error == EINTR { return .blocked }
      return .failed
    }
    if count == 0 {
      budget.release(reserved)
      return .end
    }
    budget.release(reserved - count)
    queue.append(contentsOf: buffer.prefix(count))
    return .progress(count)
  }
}
