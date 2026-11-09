import Foundation
import Testing

@testable import IsoSandboxCore

/// The lease iso-ci counts toward a Mac's shared ceilings: written once,
/// held under an exclusive lock for the owner's lifetime.
@Suite struct VMLeaseTests {
  @Test func leaseIsWrittenAndHeldUntilClosed() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("iso-lease-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fd = try #require(
      VMLease.hold(
        sandbox: "iso-a", guestOS: "macos", cpus: 4, memoryBytes: 8 << 30, directory: directory))
    let path = directory.appendingPathComponent("iso-a.json").path
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        as? [String: Any])
    #expect(json["schema"] as? String == VMLease.schema)
    #expect(json["guest_os"] as? String == "macos")
    #expect(json["cpus"] as? Int == 4 && json["memory_mib"] as? Int == 8_192)
    // Another description cannot take the lock (a reader's probe sees it held),
    // and a second owner for the same sandbox gets no lease.
    let probe = open(path, O_RDONLY)
    defer { close(probe) }
    #expect(flock(probe, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK)
    #expect(
      VMLease.hold(
        sandbox: "iso-a", guestOS: "macos", cpus: 4, memoryBytes: 8 << 30, directory: directory)
        == nil)
    close(fd)
    #expect(flock(probe, LOCK_SH | LOCK_NB) == 0)
    var status = stat()
    #expect(stat(path, &status) == 0 && status.st_mode & 0o077 == 0)
  }
}

/// container 1.7 saves `local/x` as `docker.io/local/x`; import treats only
/// such registry-qualified aliases as the same name.
@Suite struct ImageReferenceNormalizationTests {
  @Test func aliasesNormalizeToTheSameName() {
    #expect(Disks.normalizedReference("local/iso-1:2") == "docker.io/local/iso-1:2")
    #expect(Disks.normalizedReference("docker.io/local/iso-1:2") == "docker.io/local/iso-1:2")
    #expect(Disks.normalizedReference("ubuntu:24.04") == "docker.io/library/ubuntu:24.04")
    #expect(Disks.normalizedReference("ghcr.io/o/i:1") == "ghcr.io/o/i:1")
    #expect(Disks.normalizedReference("localhost/i:1") == "localhost/i:1")
    #expect(Disks.normalizedReference("registry:5000/i:1") == "registry:5000/i:1")
    #expect(Disks.normalizedReference("local/a:1") != Disks.normalizedReference("local/b:1"))
    #expect(
      Disks.normalizedReference("local/a:1") != Disks.normalizedReference("ghcr.io/local/a:1"))
  }
}
