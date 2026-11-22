import Darwin
import IsoInferenceCore
import Synchronization

/// The secret-free outstanding-work journal (§9.2): one small file per
/// backend that is non-zero while dispatched requests lack completion
/// evidence. It is written, and synced, before the first outstanding request
/// goes upstream, so a gateway that crashes mid-generation restarts with that
/// backend quarantined. Only the zero/non-zero transitions touch the disk: a
/// lost return to zero can only over-quarantine. File names are derived from
/// the backend port only.
package final class Journal: Sendable {
  private let directory: String
  private let counts = Mutex<[BackendID: Int]>([:])

  package init(directory: String) throws {
    self.directory = directory
    // The C path is borrowed for the call only.
    if unsafe mkdir(directory, 0o700) != 0 && errno != EEXIST {
      throw GatewayError.io("cannot create the journal directory")
    }
  }

  /// Backends a previous process left with unresolved work.
  package func unresolved() -> [BackendID] {
    guard let entries = try? listDirectory(directory) else { return [] }
    return entries.compactMap { name -> BackendID? in
      guard name.hasSuffix(".count"), let port = UInt16(name.dropLast(6)), port >= 1024,
        let text = readSmallFile(directory + "/" + name), let count = Int(text), count > 0
      else { return nil }
      return BackendID(port: port)
    }.sorted()
  }

  package func dispatched(_ backend: BackendID) throws {
    try update(backend) { $0 + 1 }
  }

  package func settled(_ backend: BackendID) {
    try? update(backend) { max($0 - 1, 0) }
  }

  /// After host requalification: the backend starts clean.
  package func clear(_ backend: BackendID) {
    counts.withLock { $0[backend] = 0 }
    unsafe unlink(path(backend))
  }

  private func update(_ backend: BackendID, _ change: (Int) -> Int) throws {
    try counts.withLock { counts in
      let old = counts[backend] ?? 0
      let value = change(old)
      counts[backend] = value
      guard (old == 0) != (value == 0) else { return }
      try writeAtomically(Array(String(value).utf8), to: path(backend), durable: value > 0)
    }
  }

  private func path(_ backend: BackendID) -> String { "\(directory)/\(backend.port).count" }
}

package enum GatewayError: Error, Sendable, Equatable {
  case io(String)
  case startup(String)
}

/// Write-then-rename, owner-only; `durable` syncs before the rename.
func writeAtomically(_ bytes: [UInt8], to path: String, durable: Bool = true) throws {
  let temporary = path + ".tmp"
  // The C paths below are borrowed for each call only.
  let fd = unsafe open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
  guard fd >= 0 else { throw GatewayError.io("cannot write \(path)") }
  defer { close(fd) }
  var offset = 0
  while offset < bytes.count {
    // write reads at most count bytes of the borrowed tail.
    let written = bytes[offset...].withUnsafeBytes { unsafe write(fd, $0.baseAddress, $0.count) }
    guard written > 0 else { throw GatewayError.io("cannot write \(path)") }
    offset += written
  }
  guard !durable || fsync(fd) == 0, unsafe rename(temporary, path) == 0 else {
    throw GatewayError.io("cannot write \(path)")
  }
}

func readSmallFile(_ path: String, limit: Int = 4096) -> String? {
  // The C path is borrowed for the call only.
  let fd = unsafe open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var buffer = [UInt8](repeating: 0, count: limit)
  // read writes at most `limit` bytes into the buffer of that size.
  let count = unsafe read(fd, &buffer, limit)
  guard count >= 0 else { return nil }
  return String(decoding: buffer.prefix(count), as: UTF8.self)
}

func listDirectory(_ path: String) throws -> [String] {
  // The directory stream is used only on this thread and closed on return;
  // each entry is read before the next readdir call invalidates it.
  guard let handle = unsafe opendir(path) else { throw GatewayError.io("cannot list \(path)") }
  defer { unsafe closedir(handle) }
  var names: [String] = []
  while let entry = unsafe readdir(handle) {
    let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { raw in
      unsafe String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    if name != "." && name != ".." { names.append(name) }
  }
  return names
}
