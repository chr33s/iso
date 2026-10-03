import Darwin
import Foundation
import Synchronization
import Testing

@testable import IsoEgressCore

/// Real relay queues at production scale; injected I/O makes backpressure
/// deterministic without saturating an external server or kernel socket memory.
private final class PressureRelay: Sendable {
  enum Mode { case fill, drain, stop }
  struct State {
    var mode = Mode.fill
    var read = [0, 0]
    var written = [0, 0]
    var polls = 0
  }
  let state = Mutex(State())
  let done = DispatchSemaphore(value: 0)

  func start(_ sockets: [Int32], budget: RelayBudget) {
    Thread {
      Tunnel.pump(
        sockets[0], sockets[1],
        alive: { self.state.withLock { $0.mode != .stop } }, maxReads: nil,
        idle: .seconds(10), queueCap: EgressBudgets.relayQueue, budget: budget,
        read: { fd, bytes, count in
          let direction = fd == sockets[0] ? 0 : 1
          return self.state.withLock { state in
            guard state.mode == .fill else { return 0 }
            // A broken bound must fail, rather than allocate without a ceiling.
            guard state.read[direction] < EgressBudgets.relayQueue * 2 else {
              state.mode = .stop
              return 0
            }
            bytes.initializeMemory(as: UInt8.self, repeating: UInt8(direction + 1), count: count)
            state.read[direction] += count
            return count
          }
        },
        write: { fd, bytes, count in
          let direction = fd == sockets[1] ? 0 : 1
          return self.state.withLock { state in
            guard state.mode == .drain else {
              errno = EAGAIN
              return -1
            }
            // Small writes force queued data through repeated drain iterations.
            let sent = min(count, 4096)
            #expect(
              UnsafeRawBufferPointer(start: bytes, count: sent).allSatisfy {
                $0 == UInt8(direction + 1)
              })
            state.written[direction] += sent
            return sent
          }
        },
        pollEvents: { fds, _ in
          Thread.sleep(forTimeInterval: 0.001)
          self.state.withLock { $0.polls += 1 }
          for index in fds.indices {
            fds[index].revents = fds[index].fd < 0 ? 0 : fds[index].events
          }
          return Int32(fds.filter { $0.revents != 0 }.count)
        })
      self.done.signal()
    }.start()
  }
}

@Test(.serialized, arguments: [1, EgressBudgets.maxTunnels], [false, true])
func productionScaleRelayPressureBoundsBothDirectionsAndRecovers(tunnels: Int, revoke: Bool) throws
{
  let budget = RelayBudget(cap: EgressBudgets.relayAggregate)
  let workers = (0..<tunnels).map { _ in PressureRelay() }
  var descriptors: [Int32] = []
  var started: [PressureRelay] = []
  defer {
    for worker in started { worker.state.withLock { $0.mode = .stop } }
    for worker in started { #expect(worker.done.wait(timeout: .now() + .seconds(3)) == .success) }
    for fd in descriptors { close(fd) }
  }
  for worker in workers {
    var pair: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    descriptors += pair
    worker.start(pair, budget: budget)
    started.append(worker)
  }
  let deadline = Monotonic.now() + 5_000_000_000
  let remaining = EgressBudgets.relayAggregate - tunnels * 2 * EgressBudgets.relayQueue
  while Monotonic.now() < deadline {
    if budget.available == remaining
      && workers.allSatisfy({
        $0.state.withLock { $0.read == [EgressBudgets.relayQueue, EgressBudgets.relayQueue] }
      })
    {
      break
    }
    Thread.sleep(forTimeInterval: 0.005)
  }
  try #require(budget.available == remaining)
  for worker in workers {
    #expect(
      worker.state.withLock { $0.read } == [EgressBudgets.relayQueue, EgressBudgets.relayQueue])
  }
  let reads = workers.map { $0.state.withLock { $0.read } }
  let polls = workers.map { $0.state.withLock { $0.polls } }
  Thread.sleep(forTimeInterval: 0.05)
  // The pump is still executing, but full queues must not request more input.
  #expect(workers.map { $0.state.withLock { $0.read } } == reads)
  #expect(
    zip(workers, polls).allSatisfy { worker, before in worker.state.withLock { $0.polls > before } }
  )
  let spare = budget.reserve(remaining)
  #expect(spare == remaining)
  #expect(budget.reserve(1) == 0)
  budget.release(spare)
  for worker in workers { worker.state.withLock { $0.mode = revoke ? .stop : .drain } }
  for worker in workers {
    try #require(worker.done.wait(timeout: .now() + .seconds(5)) == .success)
    // Leave a signal for the unconditional cleanup join.
    worker.done.signal()
    #expect(
      worker.state.withLock { $0.written }
        == (revoke ? [0, 0] : [EgressBudgets.relayQueue, EgressBudgets.relayQueue]))
  }
  #expect(budget.available == EgressBudgets.relayAggregate)
  let reclaimed = budget.reserve(EgressBudgets.relayAggregate)
  #expect(reclaimed == EgressBudgets.relayAggregate)
  budget.release(reclaimed)
}
