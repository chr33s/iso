import Darwin
import Testing

@testable import IsoEgressCore

@Test func stalledDialUsesItsDeadlineAndRestoresSocketFlags() throws {
  let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  try #require(socket >= 0)
  defer { close(socket) }
  let flags = fcntl(socket, F_GETFL)
  var address = sockaddr()
  var starts = 0
  var waits = 0
  let began = Monotonic.now()
  let connected = withUnsafePointer(to: &address) { address in
    Dial.connect(
      socket, address: address, length: socklen_t(MemoryLayout<sockaddr>.size),
      timeout: .milliseconds(80),
      start: { fd, _, _ in
        starts += 1
        #expect(fd == socket)
        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK != 0)
        errno = EINPROGRESS
        return -1
      },
      wait: { probe, count, timeout in
        waits += 1
        #expect(probe?.pointee.fd == socket)
        #expect(probe?.pointee.events == Int16(POLLOUT))
        #expect(count == 1)
        #expect(timeout == 80)
        // Real bounded kernel wait; no external route can shortcut this timeout.
        return poll(nil, 0, min(max(timeout, 1), 1000))
      })
  }
  let elapsed = Monotonic.now() - began
  #expect(!connected)
  #expect(starts == 1 && waits == 1)
  #expect(elapsed >= 60_000_000 && elapsed < 2_000_000_000)
  #expect(fcntl(socket, F_GETFL) == flags)

  // Check the production timeout reaches the wait unchanged without sleeping
  // ten seconds, and that interrupted waits refuse instead of claiming success.
  let interrupted = withUnsafePointer(to: &address) { address in
    Dial.connect(
      socket, address: address, length: 0, timeout: EgressBudgets.connect,
      start: { _, _, _ in
        errno = EINPROGRESS
        return -1
      },
      wait: { _, _, timeout in
        #expect(timeout == 10_000)
        errno = EINTR
        return -1
      })
  }
  #expect(!interrupted)
  #expect(fcntl(socket, F_GETFL) == flags)
}
