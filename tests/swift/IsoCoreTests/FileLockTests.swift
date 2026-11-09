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
  let held = flock(probe, LOCK_EX | LOCK_NB)
  let heldError = errno
  #expect(held == -1)
  #expect(heldError == EWOULDBLOCK)

  DispatchQueue.concurrentPerform(iterations: 64) { _ in lock.release() }
  // A child spawned concurrently by another test shares the lock's open file
  // until its exec closes the O_CLOEXEC descriptor, so allow a short wait.
  #expect(acquiresWithin(.seconds(2), probe))

  // Repeated release must not close a descriptor that reused the lock's slot.
  let descriptors = (0..<64).map { _ in open("/dev/null", O_RDONLY | O_CLOEXEC) }
  defer { for fd in descriptors where fd >= 0 { close(fd) } }
  DispatchQueue.concurrentPerform(iterations: 64) { _ in lock.release() }
  for fd in descriptors {
    #expect(fd >= 0)
    #expect(fcntl(fd, F_GETFD) >= 0)
  }
}

private func acquiresWithin(_ timeout: Duration, _ fd: Int32) -> Bool {
  let deadline = ContinuousClock.now + timeout
  while flock(fd, LOCK_EX | LOCK_NB) != 0 {
    guard ContinuousClock.now < deadline else { return false }
    usleep(1_000)
  }
  return true
}
