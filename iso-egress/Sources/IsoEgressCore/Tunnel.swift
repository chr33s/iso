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
  /// A direction stops reading when its queue or the shared budget is full.
  public static func relay(
    _ left: Int32, _ right: Int32, alive: () -> Bool = { true }, maxReads: Int? = nil,
    idle: Duration = EgressBudgets.idleTunnel, queueCap: Int = EgressBudgets.relayQueue,
    budget: RelayBudget = .shared
  ) {
    let savedLeft = fcntl(left, F_GETFL)
    let savedRight = fcntl(right, F_GETFL)
    if savedLeft >= 0 { _ = fcntl(left, F_SETFL, savedLeft | O_NONBLOCK) }
    if savedRight >= 0 { _ = fcntl(right, F_SETFL, savedRight | O_NONBLOCK) }
    defer {
      if savedLeft >= 0 { _ = fcntl(left, F_SETFL, savedLeft) }
      if savedRight >= 0 { _ = fcntl(right, F_SETFL, savedRight) }
    }
    pump(
      left, right, alive: alive, maxReads: maxReads, idle: idle, queueCap: queueCap, budget: budget,
      read: { fd, pointer, count in recv(fd, pointer, count, 0) },
      write: { fd, pointer, count in send(fd, pointer, count, 0) })
  }

  static func pump(
    _ left: Int32, _ right: Int32, alive: () -> Bool, maxReads: Int?, idle: Duration, queueCap: Int,
    budget: RelayBudget, read: (Int32, UnsafeMutableRawPointer, Int) -> Int,
    write: (Int32, UnsafeRawPointer, Int) -> Int
  ) {
    var toRight: [UInt8] = []
    var toLeft: [UInt8] = []
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
      let rightRoom = RelayRoom(
        pending: toRight.count, perDirection: queueCap, aggregateAvailable: budget.available
      ).allowed
      let leftRoom = RelayRoom(
        pending: toLeft.count, perDirection: queueCap, aggregateAvailable: budget.available
      ).allowed
      var fds = [
        pollfd(fd: left, events: rightRoom > 0 ? Int16(POLLIN) : 0, revents: 0),
        pollfd(fd: right, events: leftRoom > 0 ? Int16(POLLIN) : 0, revents: 0),
      ]
      if !toRight.isEmpty { fds[1].events |= Int16(POLLOUT) }
      if !toLeft.isEmpty { fds[0].events |= Int16(POLLOUT) }
      let remain = idleLimit &- (now &- last)
      let wait = Int32(max(1, min(remain / 1_000_000, 200)))
      if poll(&fds, 2, wait) < 0, errno != EINTR { return }
      if !toRight.isEmpty {
        held -= flush(&toRight, to: right, write: write, budget: budget)
      }
      if !toLeft.isEmpty {
        held -= flush(&toLeft, to: left, write: write, budget: budget)
      }
      if rightRoom > 0,
        let taken = take(
          left, into: &toRight, room: rightRoom, buffer: &buffer, read: read, budget: budget)
      {
        if taken < 0 { return }
        if taken > 0 {
          reads += 1
          last = Monotonic.now()
          held += taken
        }
      }
      if leftRoom > 0,
        let taken = take(
          right, into: &toLeft, room: leftRoom, buffer: &buffer, read: read, budget: budget)
      {
        if taken < 0 { return }
        if taken > 0 {
          reads += 1
          last = Monotonic.now()
          held += taken
        }
      }
    }
  }

  /// Bytes removed from the queue. A hard write error empties it so the caller stops.
  private static func flush(
    _ queue: inout [UInt8], to fd: Int32, write: (Int32, UnsafeRawPointer, Int) -> Int,
    budget: RelayBudget
  ) -> Int {
    var error: Int32 = 0
    let count = queue.withUnsafeBytes { raw -> Int in
      guard let base = raw.baseAddress else { return 0 }
      let wrote = write(fd, base, queue.count)
      error = errno
      return wrote
    }
    if count < 0 {
      if error == EAGAIN || error == EWOULDBLOCK { return 0 }
      let dropped = queue.count
      queue.removeAll()
      budget.release(dropped)
      return dropped
    }
    if count == 0 { return 0 }
    queue.removeFirst(count)
    budget.release(count)
    return count
  }

  /// `nil` when this side was not readable. Negative on a hard read error or EOF.
  private static func take(
    _ fd: Int32, into queue: inout [UInt8], room: Int, buffer: inout [UInt8],
    read: (Int32, UnsafeMutableRawPointer, Int) -> Int, budget: RelayBudget
  ) -> Int? {
    let reserved = budget.reserve(min(room, buffer.count))
    if reserved == 0 { return 0 }
    var error: Int32 = 0
    let count = buffer.withUnsafeMutableBytes { raw -> Int in
      guard let base = raw.baseAddress else { return -1 }
      let got = read(fd, base, reserved)
      error = errno
      return got
    }
    if count < 0 {
      budget.release(reserved)
      if error == EAGAIN || error == EWOULDBLOCK { return 0 }
      return -1
    }
    if count == 0 {
      budget.release(reserved)
      return -1
    }
    budget.release(reserved - count)
    queue.append(contentsOf: buffer.prefix(count))
    return count
  }
}
