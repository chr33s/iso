import AsyncHTTPClient
import NIOCore

/// One socket-read batch may arrive before upstream establishment completes.
/// The caller stops reads until that batch has drained. Every body write is
/// awaited before issuing the next write or requesting more guest input.
final class UploadStream {
  enum Failure: Error { case cancelled, excessBufferedInput }
  private let eventLoop: EventLoop
  private let completion: EventLoopPromise<Void>
  private var writer: HTTPClient.Body.StreamWriter?
  private var pending: [ByteBuffer] = []
  private var pendingBytes = 0
  private var writing = false
  private var ended = false
  private var completed = false
  var readyForMore: (() -> Void)?

  init(eventLoop: EventLoop) {
    self.eventLoop = eventLoop
    completion = eventLoop.makePromise(of: Void.self)
  }

  func body(length: Int?) -> HTTPClient.Body {
    let bound = NIOLoopBound(self, eventLoop: eventLoop)
    return .stream(length: length) { writer in
      bound.eventLoop.flatSubmit {
        bound.value.attach(writer)
      }
    }
  }

  func attach(_ writer: HTTPClient.Body.StreamWriter) -> EventLoopFuture<Void> {
    self.writer = writer
    pump()
    return completion.futureResult
  }

  var canRead: Bool { writer != nil && !writing && pending.isEmpty && !ended && !completed }

  func receive(_ buffer: ByteBuffer) throws {
    guard !completed else { return }
    // Empty frames make no progress and must not grow the queue's metadata.
    guard buffer.readableBytes > 0 else { return }
    // Server's receive allocation is 16 KiB and maxMessagesPerRead is 1.
    // This extra bound fails closed if a future caller bypasses that contract.
    guard buffer.readableBytes <= 64 * 1024 - pendingBytes else {
      throw Failure.excessBufferedInput
    }
    pending.append(buffer)
    pendingBytes += buffer.readableBytes
    pump()
  }

  func end() {
    ended = true
    pump()
  }

  func cancel() {
    guard !completed else { return }
    completed = true
    pending.removeAll()
    pendingBytes = 0
    readyForMore = nil
    completion.fail(Failure.cancelled)
  }

  private func pump() {
    guard !writing, !completed, let writer else { return }
    guard !pending.isEmpty else {
      if ended {
        completed = true
        readyForMore = nil
        completion.succeed(())
      } else {
        readyForMore?()
      }
      return
    }
    let buffer = pending.removeFirst()
    pendingBytes -= buffer.readableBytes
    writing = true
    let bound = NIOLoopBound(self, eventLoop: eventLoop)
    writer.write(.byteBuffer(buffer)).hop(to: eventLoop).whenComplete { result in
      let stream = bound.value
      stream.writing = false
      switch result {
      case .success: stream.pump()
      case .failure: stream.cancel()
      }
    }
  }
}
