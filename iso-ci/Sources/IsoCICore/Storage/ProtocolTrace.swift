import Foundation
import Synchronization

/// `iso-ci serve --record-protocol-trace PATH`: an append-only JSONL record
/// of scale-set messages, policy decisions, scheduling and allocation
/// transitions, replayable by the trace tests. Callers pass only the
/// fields they choose; tokens, JIT material, queue URLs and headers are
/// never handed to it. Each line is `{"tick": N, "type": ..., ...}`.
package final class ProtocolTrace: Sendable {
  package static let maxBytes: UInt64 = 64 << 20

  private struct State {
    var fd: Int32
    var tick: Int64 = 0
    var written: UInt64 = 0
    var full = false
  }

  private let state: Mutex<State>
  package let path: String

  package init(path: String) throws(CIError) {
    guard path.hasPrefix("/") else {
      throw CIError.invalid("--record-protocol-trace needs an absolute path")
    }
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw CIError.storage("cannot open the protocol trace at \(path): errno \(errno)")
    }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == getuid()
    else {
      close(fd)
      throw CIError.storage("the protocol trace path is not a regular file owned by this user")
    }
    fchmod(fd, 0o600)
    self.path = path
    state = Mutex(State(fd: fd, written: UInt64(status.st_size)))
  }

  deinit { state.withLock { close($0.fd) } }

  /// Appends one record. Field names `tick` and `type` are reserved.
  package func record(_ type: String, pool: Name? = nil, fields: [String: JSONValue] = [:]) {
    state.withLock { state in
      guard !state.full else { return }
      var members = fields
      members["tick"] = .integer(state.tick)
      members["type"] = .string(type)
      if let pool { members["pool"] = .string(pool.rawValue) }
      let line = JSONValue.object(members).canonical + [0x0A]
      guard state.written + UInt64(line.count) <= Self.maxBytes else {
        state.full = true
        return
      }
      let ok = line.withUnsafeBytes { write(state.fd, $0.baseAddress, $0.count) == $0.count }
      if ok { state.written += UInt64(line.count) }
    }
  }

  package func advance() { state.withLock { $0.tick += 1 } }
}
