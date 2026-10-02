import Darwin
import Foundation
import Testing

@testable import IsoEgressCore

private func relayPair() throws -> [Int32] {
  var pair: [Int32] = [-1, -1]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  return pair
}

@Test(arguments: [Int32(EPIPE), Int32(ECONNRESET), Int32(0)])
func relayHardWriteErrorTerminatesInsteadOfDroppingAndContinuing(error: Int32) throws {
  let client = try relayPair()
  defer { for fd in client { close(fd) } }
  let upstream = try relayPair()
  defer { for fd in upstream { close(fd) } }
  let payload: [UInt8] = [1, 2, 3, 4]
  try #require(payload.withUnsafeBytes { send(client[0], $0.baseAddress, $0.count, 0) } == 4)
  let budget = RelayBudget(cap: 8)
  var probes = 0
  var writes = 0
  Tunnel.pump(
    client[1], upstream[1],
    alive: {
      probes += 1
      return probes <= 5
    }, maxReads: nil,
    idle: .seconds(1), queueCap: 4, budget: budget,
    read: { recv($0, $1, $2, MSG_DONTWAIT) },
    write: { _, _, _ in
      writes += 1
      errno = error
      return error == 0 ? 0 : -1
    })
  #expect(writes == 1)
  #expect(probes < 5)
  #expect(budget.available == budget.cap)
}

@Test(arguments: [Int32(EAGAIN), Int32(EINTR)])
func relayEOFDrainsQueuedBytesThroughBackpressureAndPartialWrites(error: Int32) throws {
  let client = try relayPair()
  defer { for fd in client { close(fd) } }
  let upstream = try relayPair()
  defer { for fd in upstream { close(fd) } }
  var noSignal: Int32 = 1
  try #require(
    setsockopt(
      upstream[1], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0)
  let payload = Array("queued".utf8)
  try #require(
    payload.withUnsafeBytes { send(client[0], $0.baseAddress, $0.count, 0) } == payload.count)
  try #require(shutdown(client[0], SHUT_WR) == 0)
  try #require(shutdown(upstream[0], SHUT_WR) == 0)
  let budget = RelayBudget(cap: 16)
  var probes = 0
  var writes = 0
  var delivered: [UInt8] = []
  Tunnel.pump(
    client[1], upstream[1],
    alive: {
      probes += 1
      return probes <= 50
    }, maxReads: nil,
    idle: .seconds(1), queueCap: 16, budget: budget,
    read: { recv($0, $1, $2, MSG_DONTWAIT) },
    write: { _, pointer, count in
      writes += 1
      if writes <= 2 {
        errno = error
        return -1
      }
      let sent = send(upstream[1], pointer, min(count, 1), 0)
      if sent > 0 { delivered.append(pointer.load(as: UInt8.self)) }
      return sent
    })
  #expect(delivered == payload)
  #expect(writes == payload.count + 2)
  #expect(try relayReadThroughEOF(upstream[0]) == payload)
  #expect(probes < 50)
  #expect(budget.available == budget.cap)
}

@Test func relayInterruptedReadPreservesTheDirectionAndItsReservation() throws {
  let client = try relayPair()
  defer { for fd in client { close(fd) } }
  let upstream = try relayPair()
  defer { for fd in upstream { close(fd) } }
  var payload: UInt8 = 42
  try #require(send(client[0], &payload, 1, 0) == 1)
  try #require(shutdown(client[0], SHUT_WR) == 0)
  try #require(shutdown(upstream[0], SHUT_WR) == 0)
  let budget = RelayBudget(cap: 4)
  var probes = 0
  var interrupted = false
  var delivered: [UInt8] = []
  Tunnel.pump(
    client[1], upstream[1],
    alive: {
      probes += 1
      return probes <= 10
    }, maxReads: nil,
    idle: .seconds(1), queueCap: 4, budget: budget,
    read: { fd, pointer, count in
      if fd == client[1] && !interrupted {
        interrupted = true
        errno = EINTR
        return -1
      }
      return recv(fd, pointer, count, MSG_DONTWAIT)
    },
    write: { _, pointer, count in
      delivered.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: count))
      return count
    })
  #expect(interrupted)
  #expect(delivered == [payload])
  #expect(probes < 10)
  #expect(budget.available == budget.cap)
}

private final class RelayWorker: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  let done = DispatchSemaphore(value: 0)
  let budget = RelayBudget(cap: 16)

  init(left: Int32, right: Int32) {
    Thread {
      Tunnel.relay(
        left, right, alive: self.alive, idle: .seconds(1), queueCap: 4, budget: self.budget)
      self.done.signal()
    }.start()
  }

  private func alive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  func stop() {
    lock.lock()
    active = false
    lock.unlock()
  }
}

private func relayReadThroughEOF(_ fd: Int32) throws -> [UInt8] {
  let flags = fcntl(fd, F_GETFL)
  try #require(flags >= 0)
  try #require(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
  defer { _ = fcntl(fd, F_SETFL, flags) }
  let deadline = Monotonic.now() + 2_000_000_000
  var result: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 64)
  while Monotonic.now() < deadline {
    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let waited = poll(&ready, 1, 20)
    if waited < 0 && errno == EINTR { continue }
    try #require(waited >= 0)
    if waited == 0 { continue }
    let count = recv(fd, &buffer, buffer.count, 0)
    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
    try #require(count >= 0)
    if count == 0 { return result }
    result.append(contentsOf: buffer.prefix(count))
    try #require(result.count <= 1024)
  }
  Issue.record("relay peer did not reach EOF within two seconds")
  return result
}

@Test(arguments: [false, true])
func relayHalfCloseDrainsAndStillAllowsTheOppositeResponse(reverse: Bool) throws {
  let a = try relayPair()
  defer { for fd in a { close(fd) } }
  let b = try relayPair()
  defer { for fd in b { close(fd) } }
  let source = reverse ? b : a
  let destination = reverse ? a : b
  let flags = [fcntl(a[1], F_GETFL), fcntl(b[1], F_GETFL)]
  let worker = RelayWorker(left: a[1], right: b[1])
  var joined = false
  defer {
    worker.stop()
    if !joined { #expect(worker.done.wait(timeout: .now() + .seconds(2)) == .success) }
  }
  let request = Array("bytes-before-half-close".utf8)
  try #require(
    request.withUnsafeBytes { send(source[0], $0.baseAddress, $0.count, 0) } == request.count)
  try #require(shutdown(source[0], SHUT_WR) == 0)
  #expect(try relayReadThroughEOF(destination[0]) == request)
  let response = Array("response-after-source-eof".utf8)
  try #require(
    response.withUnsafeBytes { send(destination[0], $0.baseAddress, $0.count, 0) } == response.count
  )
  try #require(shutdown(destination[0], SHUT_WR) == 0)
  #expect(try relayReadThroughEOF(source[0]) == response)
  joined = worker.done.wait(timeout: .now() + .seconds(2)) == .success
  #expect(joined)
  #expect(worker.budget.available == worker.budget.cap)
  #expect([fcntl(a[1], F_GETFL), fcntl(b[1], F_GETFL)] == flags)
  for fd in [a[1], b[1]] {
    var noSignal: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    #expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &size) == 0)
    #expect(noSignal == 1)
  }
}

@Test func relayPausedHangupWaitsInsteadOfSpinning() throws {
  var client = try relayPair()
  defer { for fd in client where fd >= 0 { close(fd) } }
  let upstream = try relayPair()
  defer { for fd in upstream { close(fd) } }
  var smallBuffer: Int32 = 1024
  try #require(
    setsockopt(
      upstream[1], SOL_SOCKET, SO_SNDBUF, &smallBuffer,
      socklen_t(MemoryLayout<Int32>.size)) == 0)
  let flags = fcntl(upstream[1], F_GETFL)
  try #require(flags >= 0)
  try #require(fcntl(upstream[1], F_SETFL, flags | O_NONBLOCK) == 0)
  let filler = [UInt8](repeating: 0, count: 1024)
  var filled = false
  for _ in 0..<1024 {
    let count = filler.withUnsafeBytes { send(upstream[1], $0.baseAddress, $0.count, MSG_DONTWAIT) }
    if count < 0 {
      try #require(errno == EAGAIN || errno == EWOULDBLOCK)
      filled = true
      break
    }
  }
  try #require(filled)
  let payload: [UInt8] = [1, 2, 3, 4]
  try #require(payload.withUnsafeBytes { send(client[0], $0.baseAddress, $0.count, 0) } == 4)
  close(client[0])
  client[0] = -1
  let budget = RelayBudget(cap: 4)
  var probes = 0
  var reads = 0
  Tunnel.pump(
    client[1], upstream[1],
    alive: {
      probes += 1
      return probes <= 100
    }, maxReads: nil,
    idle: .milliseconds(40), queueCap: 4, budget: budget,
    read: { fd, pointer, count in
      let got = recv(fd, pointer, count, MSG_DONTWAIT)
      if got > 0 { reads += got }
      return got
    }, write: { send($0, $1, $2, MSG_DONTWAIT) },
    pollEvents: { fds, milliseconds in
      // Inject poll's unconditional HUP contract. This macOS socketpair does
      // not consistently report HUP without read interest; it is not evidence
      // that every supported socket will suppress it under backpressure.
      let result = poll(&fds, 2, fds[0].fd >= 0 ? 0 : milliseconds)
      if result >= 0 && fds[0].fd >= 0 {
        fds[0].revents |= Int16(POLLHUP)
        return max(result, 1)
      }
      return result
    })
  #expect(reads == 4)
  #expect(probes <= 4)
  #expect(budget.available == budget.cap)
}

@Test func relayIdleAndRevocationReleaseQueuedBudget() throws {
  for revoked in [false, true] {
    let client = try relayPair()
    defer { for fd in client { close(fd) } }
    let upstream = try relayPair()
    defer { for fd in upstream { close(fd) } }
    var payload: UInt8 = 42
    try #require(send(client[0], &payload, 1, 0) == 1)
    let budget = RelayBudget(cap: 4)
    var probes = 0
    var reads = 0
    var blocked = false
    Tunnel.pump(
      client[1], upstream[1],
      alive: {
        probes += 1
        return !revoked || probes <= 2
      },
      maxReads: nil, idle: .milliseconds(20), queueCap: 4, budget: budget,
      read: { fd, pointer, count in
        let got = recv(fd, pointer, count, MSG_DONTWAIT)
        if got > 0 { reads += got }
        return got
      },
      write: { _, _, _ in
        blocked = true
        errno = EAGAIN
        return -1
      })
    #expect(reads == 1)
    #expect(blocked)
    #expect(budget.available == budget.cap)
  }
}
