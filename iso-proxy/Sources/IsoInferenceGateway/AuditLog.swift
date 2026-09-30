import Darwin
import IsoInferenceCore
import Synchronization

/// Owner-only, size-bounded audit records (§13). Each record is one JSON
/// line built from host-assigned identifiers, fixed codes and counts; no
/// prompt, completion, tool argument, capability, credential, header or
/// guest-chosen path is ever written. Repeated rejections of one code in
/// one session are aggregated into a single record per window.
public final class AuditLog: Sendable {
  public static let maxBytes = 4 << 20
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

  public init(path: String) {
    self.path = path
    var info = stat()
    if stat(path, &info) == 0 { state.withLock { $0.bytes = Int(info.st_size) } }
  }

  deinit {
    state.withLock { state in if state.fd >= 0 { close(state.fd) } }
  }

  public func record(_ event: String, _ fields: KeyValuePairs<String, JSON> = [:]) {
    var object = JSONObject([
      "time": .int(Int64(time(nil))), "event": .string(event),
    ])
    for (key, value) in fields { object[key] = value }
    append(JSON.object(object).serialized + [0x0A])
  }

  /// A rejected request: aggregated per (session, code).
  public func rejected(session: String, code: InferenceErrorCode) {
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
        rename(path, path + ".1")
        if state.fd >= 0 { close(state.fd) }
        state.fd = -1
        state.bytes = 0
      }
      if state.fd < 0 {
        state.fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard state.fd >= 0 else { return }
      let fd = state.fd
      let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if written > 0 { state.bytes += written }
    }
  }
}
