import Darwin
import IsoInferenceCore
import Synchronization

/// Owner-only, size-bounded audit records (§13). Each record is one JSON
/// line built from host-assigned identifiers, fixed codes and counts; no
/// prompt, completion, tool argument, capability, credential, header or
/// guest-chosen path is ever written.
///
/// Rejections are aggregated per session and code: the first one is written
/// at once, later ones in the same 10-second window are only counted, and
/// the count is written when the window ends (`flush`, from the gateway's
/// ticker) or with the next rejection after it. A session therefore writes
/// at most two rejection records per code per window, however many requests
/// it sends.
package final class AuditLog: Sendable {
  package static let maxBytes = 4 << 20
  static let window: Duration = .seconds(10)

  struct Key: Hashable {
    let session: String
    let code: InferenceErrorCode
  }

  struct Window {
    let since: ContinuousClock.Instant
    var held = 0
  }

  struct State {
    /// Kept open between records; reopened after rotation.
    var fd: Int32 = -1
    var bytes = 0
    var rejections: [Key: Window] = [:]
  }

  private let path: String
  private let state = Mutex(State())
  private let now: @Sendable () -> ContinuousClock.Instant

  package init(
    path: String,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.path = path
    self.now = now
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

  /// A record whose fields a session worker sent, already limited to its
  /// event's allowed members (``WorkerProtocol/auditEvents``).
  package func record(_ event: String, object fields: JSONObject) {
    var object = JSONObject([
      "time": .int(Int64(time(nil))), "event": .string(event),
    ])
    for member in fields.members { object[member.key] = member.value }
    append(JSON.object(object).serialized + [0x0A])
  }

  /// One rejected request.
  package func rejected(session: String, code: InferenceErrorCode) {
    let key = Key(session: session, code: code)
    let instant = now()
    let count: Int? = state.withLock { state in
      guard let open = state.rejections[key] else {
        state.rejections[key] = Window(since: instant)
        return 1
      }
      guard instant - open.since >= Self.window else {
        state.rejections[key]?.held += 1
        return nil
      }
      // The window has ended: this rejection is written with those it held.
      state.rejections[key] = Window(since: instant)
      return open.held + 1
    }
    if let count { rejection(key, count: count) }
  }

  /// Writes the held count of every window that has ended and forgets those
  /// windows.
  package func flush() {
    let instant = now()
    let due = state.withLock { state -> [(Key, Int)] in
      let ended = state.rejections.filter { instant - $0.value.since >= Self.window }
      for key in ended.keys { state.rejections[key] = nil }
      return ended.filter { $0.value.held > 0 }.map { ($0.key, $0.value.held) }
    }
    for (key, count) in due.sorted(by: {
      ($0.0.session, $0.0.code.rawValue) < ($1.0.session, $1.0.code.rawValue)
    }) {
      rejection(key, count: count)
    }
  }

  private func rejection(_ key: Key, count: Int) {
    record(
      "request_rejected",
      [
        "session": .string(key.session), "code": .string(key.code.rawValue),
        "count": .int(Int64(count)),
      ])
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
