import CryptoKit
import Foundation
import IsoCore
import Synchronization

/// Kinds of host-owned artifacts. Each fixes its size bound and whether its
/// content must pass `ArchiveValidator` before publication.
package enum ArtifactKind: String, Sendable, Codable, CaseIterable {
  /// An OCI/tar image archive for `image.ensure`.
  case imageArchive = "image_archive"
  /// A bounded build context tarball.
  case buildContext = "build_context"
  /// Results captured from a disposable run; produced by the worker.
  case runResult = "run_result"

  package var maxBytes: UInt64 {
    switch self {
    case .imageArchive: 32 << 30
    case .buildContext: 1 << 30
    case .runResult: 4 << 30
    }
  }

  /// Clients upload these; `runResult` is only produced by the worker.
  package var isClientUpload: Bool { self != .runResult }
}

/// Bounded, owner-bound staging for artifacts (spec 11.4). Handles are random
/// ids under an owner-only directory; nothing here exposes a general path API.
package final class ArtifactStore: Sendable {
  package static let uploadTTL: UInt64 = 3_600
  package static let maxPending = 64

  package enum State: String, Codable, Sendable {
    case uploading
    case committed
  }

  package struct Record: Codable, Sendable, Equatable {
    package var schema = 1
    package let handle: ArtifactHandle
    package let owner: OwnerID
    package let kind: ArtifactKind
    package let size: UInt64
    package let digest: SHA256Hex
    package let createdAt: UInt64
    package var expiresAt: UInt64
    package var state: State
    package var written: UInt64
    /// An accepted operation or run owning this artifact; exempt from expiry.
    package var retainedBy: String?
  }

  private let root: String
  private let clock: any HostClock
  private let lock = Mutex<Void>(())

  package init(root: String, clock: any HostClock) throws(HostError) {
    self.root = root
    self.clock = clock
    try StateStore.ensurePrivateDirectory(root)
  }

  private func directory(_ handle: ArtifactHandle) -> String { root + "/" + handle.rawValue }
  private func metaPath(_ handle: ArtifactHandle) -> String { directory(handle) + "/meta.json" }
  package func dataPath(_ handle: ArtifactHandle) -> String { directory(handle) + "/data" }

  private var now: UInt64 { WireTime(clock.now()).seconds }

  package func begin(owner: OwnerID, kind: ArtifactKind, size: UInt64, digest: SHA256Hex)
    throws(HostControlError) -> Record
  {
    guard kind.isClientUpload else { throw .invalidRequest("artifact kind is not uploadable") }
    return try create(owner: owner, kind: kind, size: size, digest: digest)
  }

  /// Worker-side creation (run results); the caller writes then commits.
  package func create(owner: OwnerID, kind: ArtifactKind, size: UInt64, digest: SHA256Hex)
    throws(HostControlError) -> Record
  {
    guard size <= kind.maxBytes else {
      throw HostControlError(.limitExceeded, "artifact exceeds the \(kind.rawValue) size limit")
    }
    return try withLock { () throws(HostControlError) -> Record in
      sweepLocked()
      guard pendingCountLocked() < Self.maxPending else {
        throw HostControlError(.limitExceeded, "too many staged artifacts")
      }
      let handle = ArtifactHandle.generate()
      let record = Record(
        handle: handle, owner: owner, kind: kind, size: size, digest: digest, createdAt: now,
        expiresAt: now + Self.uploadTTL, state: .uploading, written: 0, retainedBy: nil)
      do {
        try StateStore.ensurePrivateDirectory(directory(handle))
        try AtomicFile.createExclusive([], at: dataPath(handle), mode: 0o600)
        try StateStore.writeControlFile(record, to: metaPath(handle))
      } catch {
        throw HostControlError(.limitExceeded, "artifact staging is unavailable")
      }
      return record
    }
  }

  /// Sequential append; `offset` must equal the bytes already written.
  package func write(owner: OwnerID, handle: ArtifactHandle, offset: UInt64, bytes: [UInt8])
    throws(HostControlError) -> Record
  {
    try withLock { () throws(HostControlError) -> Record in
      var record = try loadOwnedLocked(owner, handle)
      guard record.state == .uploading else {
        throw .invalidRequest("artifact is already committed")
      }
      guard offset == record.written else {
        throw .invalidRequest("artifact write offset \(offset) expected \(record.written)")
      }
      let (end, overflow) = offset.addingReportingOverflow(UInt64(bytes.count))
      guard !overflow, end <= record.size else {
        throw HostControlError(.limitExceeded, "artifact write exceeds its declared size")
      }
      let fd = open(dataPath(handle), O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw HostControlError(.resultsUnavailable, "artifact data is missing") }
      defer { close(fd) }
      do { try AtomicFile.writeAll(fd, bytes, "artifact") } catch {
        throw HostControlError(.limitExceeded, "artifact write failed")
      }
      record.written = end
      try saveLocked(record)
      return record
    }
  }

  /// Verifies size, digest and (for archives) member policy, then publishes.
  package func commit(owner: OwnerID, handle: ArtifactHandle) throws(HostControlError) -> Record {
    try withLock { () throws(HostControlError) -> Record in
      var record = try loadOwnedLocked(owner, handle)
      if record.state == .committed { return record }
      guard record.written == record.size else {
        throw .invalidRequest("artifact is incomplete (\(record.written) of \(record.size) bytes)")
      }
      let fd = open(dataPath(handle), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw HostControlError(.resultsUnavailable, "artifact data is missing") }
      defer { close(fd) }
      fsync(fd)
      var hasher = SHA256()
      var total: UInt64 = 0
      var chunk = [UInt8](repeating: 0, count: 64 << 10)
      while true {
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
          if errno == EINTR { continue }
          throw HostControlError(.resultsUnavailable, "artifact data is unreadable")
        }
        if count == 0 { break }
        total += UInt64(count)
        hasher.update(data: chunk[0..<count])
      }
      guard total == record.size, SHA256Hex(digest: hasher.finalize()) == record.digest else {
        discardLocked(handle)
        throw .invalidRequest("artifact digest or size does not match; upload discarded")
      }
      // Every kind is a tar archive; anything else (including compressed
      // archives the validator cannot see into) is refused.
      do throws(HostControlError) {
        _ = try ArchiveValidator.validate(path: dataPath(handle))
      } catch {
        discardLocked(handle)
        throw error
      }
      record.state = .committed
      try saveLocked(record)
      return record
    }
  }

  package func read(owner: OwnerID, handle: ArtifactHandle, offset: UInt64, length: UInt32)
    throws(HostControlError) -> [UInt8]
  {
    let record = try withLock { () throws(HostControlError) -> Record in
      try loadOwnedLocked(owner, handle)
    }
    guard record.state == .committed else { throw .invalidRequest("artifact is not committed") }
    guard offset <= record.size else { throw .invalidRequest("artifact read offset out of range") }
    let fd = open(dataPath(handle), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw HostControlError(.resultsUnavailable, "artifact data is missing") }
    defer { close(fd) }
    let want = Int(min(UInt64(length), record.size - offset))
    var buffer = [UInt8](repeating: 0, count: want)
    var filled = 0
    while filled < want {
      let count = buffer[filled...].withUnsafeMutableBytes {
        pread(fd, $0.baseAddress, $0.count, off_t(offset) + off_t(filled))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw HostControlError(.resultsUnavailable, "artifact data is unreadable")
      }
      if count == 0 { break }
      filled += count
    }
    return Array(buffer.prefix(filled))
  }

  package func record(owner: OwnerID, handle: ArtifactHandle) throws(HostControlError) -> Record {
    try withLock { () throws(HostControlError) -> Record in try loadOwnedLocked(owner, handle) }
  }

  /// Binds an artifact to an accepted operation or run; the binder alone may release it.
  package func retain(owner: OwnerID, handle: ArtifactHandle, by holder: String)
    throws(HostControlError)
  {
    try withLock { () throws(HostControlError) in
      var record = try loadOwnedLocked(owner, handle)
      if let current = record.retainedBy, current != holder {
        throw HostControlError(.instanceBusy, "artifact is owned by another operation")
      }
      record.retainedBy = holder
      try saveLocked(record)
    }
  }

  /// Deletes an artifact only for its retaining holder.
  package func release(owner: OwnerID, handle: ArtifactHandle, by holder: String)
    throws(HostControlError)
  {
    try withLock { () throws(HostControlError) in
      let record = try loadOwnedLocked(owner, handle)
      guard record.retainedBy == holder else {
        throw HostControlError(.instanceBusy, "artifact is owned by another operation")
      }
      discardLocked(handle)
    }
  }

  /// Removes unretained artifacts past their expiry.
  package func sweep() {
    whileLocked { sweepLocked() }
  }

  // MARK: - Locked helpers

  private func withLock<T: Sendable>(_ body: () throws(HostControlError) -> T)
    throws(HostControlError) -> T
  {
    try lock.withLock { (_) throws(HostControlError) -> T in try body() }
  }

  private func whileLocked(_ body: () -> Void) {
    lock.withLock { _ in body() }
  }

  private func handles() -> [ArtifactHandle] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    return names.compactMap { try? ArtifactHandle($0) }
  }

  private func pendingCountLocked() -> Int {
    handles().count
  }

  private func sweepLocked() {
    let current = now
    for handle in handles() {
      guard let bytes = try? StateStore.readControlFile(metaPath(handle)),
        let record = try? JSONDecoder().decode(Record.self, from: Data(bytes))
      else {
        // A directory without readable metadata is an interrupted begin.
        discardLocked(handle)
        continue
      }
      if record.retainedBy == nil && record.expiresAt <= current { discardLocked(handle) }
    }
  }

  private func loadOwnedLocked(_ owner: OwnerID, _ handle: ArtifactHandle) throws(HostControlError)
    -> Record
  {
    let bytes: [UInt8]?
    do { bytes = try StateStore.readControlFile(metaPath(handle)) } catch {
      throw HostControlError(.resultsUnavailable, "artifact metadata is unreadable")
    }
    guard let bytes, let record = try? JSONDecoder().decode(Record.self, from: Data(bytes)),
      record.handle == handle
    else { throw HostControlError(.resultsUnavailable, "unknown artifact handle") }
    // An unowned handle is indistinguishable from an unknown one.
    guard record.owner == owner else {
      throw HostControlError(.resultsUnavailable, "unknown artifact handle")
    }
    if record.retainedBy == nil && record.expiresAt <= now {
      discardLocked(handle)
      throw HostControlError(.resultsUnavailable, "artifact expired")
    }
    return record
  }

  private func saveLocked(_ record: Record) throws(HostControlError) {
    do { try StateStore.writeControlFile(record, to: metaPath(record.handle)) } catch {
      throw HostControlError(.limitExceeded, "artifact metadata write failed")
    }
  }

  private func discardLocked(_ handle: ArtifactHandle) {
    unlink(dataPath(handle))
    unlink(metaPath(handle))
    rmdir(directory(handle))
  }

}
