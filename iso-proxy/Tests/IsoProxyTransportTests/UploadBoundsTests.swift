import AsyncHTTPClient
import NIOCore
import NIOEmbedded
import Testing

@testable import IsoProxyTransport

private final class UploadObservations {
  var writes: [Int] = []
  var outcomes: [Bool] = []
  var reads = 0
  var acknowledgments: [EventLoopPromise<Void>] = []
}

@Test func cancellationDropsQueuedUploadDespiteLateWriteCompletion() throws {
  let loop = EmbeddedEventLoop()
  let upload = UploadStream(eventLoop: loop)
  let observed = NIOLoopBound(UploadObservations(), eventLoop: loop)
  let stalled = loop.makePromise(of: Void.self)
  upload.readyForMore = { observed.value.reads += 1 }
  let completion = upload.attach(
    HTTPClient.Body.StreamWriter { data in
      if case .byteBuffer(let buffer) = data { observed.value.writes.append(buffer.readableBytes) }
      return stalled.futureResult
    })
  completion.whenComplete { result in
    switch result {
    case .success: observed.value.outcomes.append(true)
    case .failure: observed.value.outcomes.append(false)
    }
  }
  let chunk = ByteBuffer(repeating: 0x5a, count: 16 * 1024)
  try upload.receive(chunk)
  for _ in 0..<4 { try upload.receive(chunk) }
  #expect(throws: UploadStream.Failure.self) { try upload.receive(ByteBuffer(string: "x")) }
  #expect(observed.value.writes == [16 * 1024])
  #expect(!upload.canRead)
  let readsBeforeCancel = observed.value.reads
  upload.cancel()
  loop.run()
  #expect(observed.value.outcomes == [false])
  stalled.succeed(())
  loop.run()
  upload.end()
  upload.cancel()
  try upload.receive(chunk)
  loop.run()
  #expect(observed.value.writes == [16 * 1024])
  #expect(observed.value.reads == readsBeforeCancel)
  #expect(observed.value.outcomes == [false])
  #expect(!upload.canRead)
}

@Test func uploadBeforeWriterIsBoundedAndIgnoresEmptyFrames() throws {
  let loop = EmbeddedEventLoop()
  let upload = UploadStream(eventLoop: loop)
  let observed = NIOLoopBound(UploadObservations(), eventLoop: loop)
  for _ in 0..<1000 { try upload.receive(ByteBuffer()) }
  let chunk = ByteBuffer(repeating: 0x41, count: 16 * 1024)
  for _ in 0..<4 { try upload.receive(chunk) }
  #expect(throws: UploadStream.Failure.self) { try upload.receive(ByteBuffer(string: "x")) }
  #expect(!upload.canRead)
  upload.end()
  let completion = upload.attach(
    HTTPClient.Body.StreamWriter { data in
      if case .byteBuffer(let buffer) = data { observed.value.writes.append(buffer.readableBytes) }
      let acknowledgment = loop.makePromise(of: Void.self)
      observed.value.acknowledgments.append(acknowledgment)
      return acknowledgment.futureResult
    })
  completion.whenComplete { result in
    switch result {
    case .success: observed.value.outcomes.append(true)
    case .failure: observed.value.outcomes.append(false)
    }
  }
  for _ in 0..<1004 {
    if !observed.value.acknowledgments.isEmpty {
      observed.value.acknowledgments.removeFirst().succeed(())
      loop.run()
    }
  }
  #expect(observed.value.writes == Array(repeating: 16 * 1024, count: 4))
  #expect(observed.value.outcomes == [true])
  #expect(!upload.canRead)
}
