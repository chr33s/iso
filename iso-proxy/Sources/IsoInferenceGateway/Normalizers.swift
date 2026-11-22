import Dispatch
import Foundation
import Synchronization

/// A small pool of threads for request normalization: parsing and validating
/// a body of several MiB takes a fraction of a second, which must not stall
/// an event loop that every session's connections share. The threads have an
/// 8 MiB stack, so the parser's and validator's nesting limits bound their
/// stack use whatever the platform's default for a secondary thread.
/// Jobs are bounded by the connection slots that wait for them.
package final class NormalizerPool: Sendable {
  private struct State {
    var jobs: [@Sendable () -> Void] = []
    var stopped = false
  }
  private let state = Mutex(State())
  private let ready = DispatchSemaphore(value: 0)
  private let threads: Int

  package init(threads: Int) {
    self.threads = threads
    for index in 0..<threads {
      // Each thread keeps the pool until `stop` ends it.
      let thread = Thread { [self] in
        while let job = next() { job() }
      }
      thread.name = "iso-inference-normalizer-\(index)"
      thread.stackSize = 8 << 20
      thread.start()
    }
  }

  private func next() -> (@Sendable () -> Void)? {
    ready.wait()
    return state.withLock { state in state.jobs.isEmpty ? nil : state.jobs.removeFirst() }
  }

  /// Runs `job` on a pool thread; dropped once the pool has stopped.
  package func submit(_ job: @escaping @Sendable () -> Void) {
    let accepted = state.withLock { state -> Bool in
      guard !state.stopped else { return false }
      state.jobs.append(job)
      return true
    }
    if accepted { ready.signal() }
  }

  /// Ends every thread once the queued jobs have run. Idempotent.
  package func stop() {
    let first = state.withLock { state -> Bool in
      defer { state.stopped = true }
      return !state.stopped
    }
    guard first else { return }
    for _ in 0..<threads { ready.signal() }
  }
}
