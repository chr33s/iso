import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#endif

/// Reads newline-terminated lines from a file descriptor with a hard cap.
package struct LineReader {
  /// The helper protocol's line cap (`HelperProtocol.maxLine`).
  package static let defaultLimit = 64 * 1024
  let fd: Int32
  let limit: Int
  var buffer: [UInt8] = []
  /// Bytes of `buffer` already known to hold no newline.
  var scanned = 0
  package init(fd: Int32, limit: Int = LineReader.defaultLimit) {
    self.fd = fd
    self.limit = limit
  }

  package enum Next: Equatable {
    case line([UInt8])
    case closed
    case tooLong
    case deadline
  }

  /// The next line. With `deadline`, a wall-clock bound across reads: a
  /// per-read timeout alone would let a peer trickle bytes indefinitely.
  package mutating func next(deadline: Date? = nil) -> Next {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      // Only new bytes are searched: a multi-megabyte line stays linear.
      if let nl = buffer[scanned...].firstIndex(of: 0x0A) {
        let line = Array(buffer[..<nl])
        buffer.removeSubrange(...nl)
        scanned = 0
        return .line(line)
      }
      scanned = buffer.count
      if buffer.count > limit { return .tooLong }
      if let deadline, Date() >= deadline { return .deadline }
      let n = read(fd, &chunk, chunk.count)
      if n < 0, errno == EINTR { continue }
      if n <= 0 { return .closed }
      buffer.append(contentsOf: chunk[0..<n])
    }
  }
}
