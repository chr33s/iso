import Darwin
import IsoInferenceCore
import Synchronization

/// Owner-only, size-bounded audit records (§13). Each record is one JSON
/// line built from host-assigned identifiers, fixed codes and counts; no
/// prompt, completion, tool argument, capability, credential, header or
/// guest-chosen path is ever written. Repeated rejections of one code in
/// one session are aggregated into a single record per window.
package final class AuditLog: Sendable {
  package static let maxBytes = 4 << 20
  static let aggregationSeconds: Int64 = 10

  struct State {
    /// Kept open between records; reopened after rotation.
    var fd: Int32 = -1
    var bytes = 0
    var rejections: [String: (count: Int, since: ContinuousClock.Instant)] = [:]
  }

  private let path: String
  private let state = Mutex(State())
  private let clock = ContinuousClock()

  package init(path: String) {
    self.path = path
    var info = stat()
    // stat writes only the one record borrowed here; the C path is borrowed too.
    if unsafe stat(path, &info) == 0 { state.withLock { $0.bytes = Int(info.st_size) } }
  }

  deinit {
    state.withLock { state in if state.fd >= 0 { close(state.fd) } }
  }

  package func record(_ event: String, _ fields: KeyValuePairs<String, JSON> = [:]) {
    var object = JSONObject([
      "time": .int(Int64(time(nil))), "event": .string(event),
    ])
    for (key, value) in fields { object[key] = value }
    append(JSON.object(object).serialized + [0x0A])
  }

  /// A rejected request: aggregated per (session, code).
  package func rejected(session: String, code: InferenceErrorCode) {
    let key = session + "|" + code.rawValue
    let now = clock.now
    let flush: Int? = state.withLock { state in
      var entry = state.rejections[key] ?? (0, now)
      entry.count += 1
      if entry.count == 1 || now - entry.since >= .seconds(Self.aggregationSeconds) {
        state.rejections[key] = (0, now)
        return entry.count
      }
      state.rejections[key] = entry
      return nil
    }
    if let count = flush {
      record(
        "request_rejected",
        ["session": .string(session), "code": .string(code.rawValue), "count": .int(Int64(count))])
    }
  }

  private func append(_ line: [UInt8]) {
    state.withLock { state in
      if state.bytes + line.count > Self.maxBytes {
        // The C paths are borrowed for the call only.
        unsafe rename(path, path + ".1")
        if state.fd >= 0 { close(state.fd) }
        state.fd = -1
        state.bytes = 0
      }
      if state.fd < 0 {
        // The C path is borrowed for the call only.
        state.fd = unsafe open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard state.fd >= 0 else { return }
      let fd = state.fd
      // write reads at most count bytes of the borrowed line buffer.
      let written = line.withUnsafeBytes { unsafe write(fd, $0.baseAddress, $0.count) }
      if written > 0 { state.bytes += written }
    }
  }
}
