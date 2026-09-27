import NIOConcurrencyHelpers
import NIOCore

/// Admission and ownership share one lock, so shutdown cannot miss work that
/// starts concurrently. Callbacks and cancellation always run outside the lock.
final class UpstreamWork: Sendable {
  enum Failure: Error { case shuttingDown }
  struct Operation: Sendable {
    let cancel: @Sendable () -> Void
    let completion: EventLoopFuture<Void>
  }
  private struct State {
    var closing = false
    var nextID = 0
    var operations: [Int: Operation] = [:]
  }
  private let state = NIOLockedValueBox(State())

  func start<Value>(_ create: () throws -> (Value, Operation)) throws -> Value {
    let (id, value, operation) = try state.withLockedValue { state in
      guard !state.closing else { throw Failure.shuttingDown }
      let (value, operation) = try create()
      let id = state.nextID
      state.nextID += 1
      state.operations[id] = operation
      return (id, value, operation)
    }
    operation.completion.whenComplete { [weak self] _ in
      _ = self?.state.withLockedValue { $0.operations.removeValue(forKey: id) }
    }
    return value
  }

  func shutdown() async {
    let operations = state.withLockedValue { state in
      state.closing = true
      return Array(state.operations.values)
    }
    for operation in operations { operation.cancel() }
    for operation in operations { try? await operation.completion.get() }
  }
}
