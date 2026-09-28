import Darwin
import Dispatch

final class Signals {
  let stream: AsyncStream<Void>
  private let sources: [DispatchSourceSignal]

  init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.stream = stream
    sources = [SIGINT, SIGTERM].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        continuation.yield(())
        continuation.finish()
      }
      source.resume()
      return source
    }
  }
  deinit {
    for source in sources { source.cancel() }
  }
}
