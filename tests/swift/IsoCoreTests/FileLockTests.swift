import Dispatch
import Foundation
import IsoCore
import Testing

@Test func concurrentFileLockReleaseUnlocksWithoutClosingOtherDescriptors() throws {
  let path = FileManager.default.temporaryDirectory.appending(path: "iso-lock-\(UUID())").path
  defer { unlink(path) }
  let lock = try FileLock(path: path)
  defer { lock.release() }
  let probe = open(path, O_WRONLY | O_CLOEXEC)
  #expect(probe >= 0)
  defer { close(probe) }
  #expect(flock(probe, LOCK_EX | LOCK_NB) == -1)
  #expect(errno == EWOULDBLOCK)

  DispatchQueue.concurrentPerform(iterations: 64) { _ in lock.release() }
  #expect(flock(probe, LOCK_EX | LOCK_NB) == 0)

  // Repeated release must not close a descriptor that reused the lock's slot.
  let descriptors = (0..<64).map { _ in open("/dev/null", O_RDONLY | O_CLOEXEC) }
  defer { for fd in descriptors where fd >= 0 { close(fd) } }
  DispatchQueue.concurrentPerform(iterations: 64) { _ in lock.release() }
  for fd in descriptors {
    #expect(fd >= 0)
    #expect(fcntl(fd, F_GETFD) >= 0)
  }
}
