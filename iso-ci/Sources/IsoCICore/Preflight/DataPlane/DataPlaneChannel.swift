import Foundation
import Synchronization

/// JSON-Lines framing over a pair of file descriptors, bounded by
/// `DataPlaneWire.maxFrameBytes`. Writes are serialized; reads run on a
/// dedicated thread and deliver decoded frames in order.
package final class DataPlaneChannel: Sendable {
  private let input: Int32
  private let output: Int32
  private let writeLock = Mutex(())

  package init(input: Int32, output: Int32) {
    self.input = input
    self.output = output
  }

  package func send(_ frame: DataPlaneFrame) throws(CIError) {
    let bytes = frame.frame
    guard bytes.count <= DataPlaneWire.maxFrameBytes + 1 else {
      throw CIError(.budgetExceeded, "data-plane frame too large")
    }
    let ok = writeLock.withLock { _ -> Bool in
      var offset = 0
      while offset < bytes.count {
        let count = bytes.withUnsafeBytes {
          write(output, $0.baseAddress! + offset, $0.count - offset)
        }
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += count
      }
      return true
    }
    guard ok else { throw CIError(.controllerUnavailable, "the data-plane channel is closed") }
  }

  /// Reads frames until end of input or an invalid frame (which closes the
  /// channel: a peer that sends malformed frames is not trusted further).
  /// `onFrame` runs on the reader thread; `onClose` runs once at the end.
  package func startReading(
    onFrame: @escaping @Sendable (DataPlaneFrame) -> Void,
    onClose: @escaping @Sendable (CIError?) -> Void
  ) {
    let input = self.input
    Thread.detachNewThread {
      var pending: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 64 << 10)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
        if count < 0 {
          if errno == EINTR { continue }
          onClose(CIError(.controllerUnavailable, "data-plane channel read failed"))
          return
        }
        if count == 0 {
          onClose(nil)
          return
        }
        pending += buffer[0..<count]
        while let newline = pending.firstIndex(of: 0x0A) {
          let line = Array(pending[..<newline])
          pending.removeSubrange(...newline)
          do throws(CIError) { onFrame(try DataPlaneFrame.decode(line)) } catch {
            onClose(CIError(.invalidRequest, "invalid data-plane frame: \(error.message)"))
            return
          }
        }
        if pending.count > DataPlaneWire.maxFrameBytes {
          onClose(CIError(.budgetExceeded, "data-plane frame too large"))
          return
        }
      }
    }
  }
}

/// Outstanding request/reply correlation with a bounded number in flight.
package final class DataPlanePendingCalls: Sendable {
  private struct State {
    var next: Int64 = 1
    var waiting: [Int64: CheckedContinuation<Result<JSONValue, CIError>, Never>] = [:]
    var closed: CIError?
  }

  package static let maxInFlight = 256
  private let state = Mutex(State())

  package init() {}

  /// Registers a waiter and sends via `send`; resolves with the reply.
  package func call(_ send: (Int64) throws(CIError) -> Void) async throws(CIError) -> JSONValue {
    let id: Int64
    do {
      id = try state.withLock { (state) throws(CIError) -> Int64 in
        if let closed = state.closed { throw closed }
        guard state.waiting.count < Self.maxInFlight else {
          throw CIError(.controllerBusy, "too many data-plane calls in flight")
        }
        defer { state.next += 1 }
        return state.next
      }
    }
    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<JSONValue, CIError>, Never>) in
      let closed = state.withLock { state -> CIError? in
        if let closed = state.closed { return closed }
        state.waiting[id] = continuation
        return nil
      }
      if let closed {
        continuation.resume(returning: .failure(closed))
        return
      }
      do throws(CIError) { try send(id) } catch {
        if let waiter = state.withLock({ $0.waiting.removeValue(forKey: id) }) {
          waiter.resume(returning: .failure(error))
        }
      }
    }
    return try result.get()
  }

  package func resolve(_ id: Int64, _ result: Result<JSONValue, CIError>) {
    state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(returning: result)
  }

  package func close(_ error: CIError) {
    let waiters = state.withLock {
      state -> [CheckedContinuation<Result<JSONValue, CIError>, Never>] in
      state.closed = error
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    for waiter in waiters { waiter.resume(returning: .failure(error)) }
  }
}
