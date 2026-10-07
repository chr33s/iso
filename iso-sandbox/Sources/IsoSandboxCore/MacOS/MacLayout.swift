import Foundation
import IsoMacProtocol

/// Fixed display geometry for every macOS guest (Gate F): framebuffer pixels,
/// guest backing scale 1, no reconfiguration for the life of the VM.
package enum MacDisplay {
  package static let width = 1920
  package static let height = 1200
  package static let pixelsPerInch = 80
}

extension SandboxRoot {
  package var macos: URL { root.appendingPathComponent("macos", isDirectory: true) }
  package var macTemplates: URL { macos.appendingPathComponent("templates", isDirectory: true) }
  package var macSandboxes: URL { macos.appendingPathComponent("sandboxes", isDirectory: true) }

  package func macTemplate(_ name: SandboxID) -> MacTemplatePaths {
    MacTemplatePaths(dir: macTemplates.appendingPathComponent(name.rawValue, isDirectory: true))
  }

  /// Held shared by a create while it clones the template and commits its
  /// record, exclusively by a template delete.
  package func macTemplateLock(_ name: SandboxID) -> URL {
    locks.appendingPathComponent("macos-template-\(name.rawValue).lock")
  }

  package func macSandbox(_ id: SandboxID) -> MacSandboxPaths {
    MacSandboxPaths(
      id: id, dir: macSandboxes.appendingPathComponent(id.rawValue, isDirectory: true),
      locks: locks)
  }

  package func createMacDirectories() throws {
    try createDirectories()
    for dir in [macos, macTemplates, macSandboxes] {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try Self.makePrivate(dir)
    }
  }

  /// Every committed macOS sandbox record; unreadable ones are errors, so
  /// subnet allocation fails closed.
  package func allMacRecords() throws -> [MacSandboxRecord] {
    guard FileManager.default.fileExists(atPath: macSandboxes.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: macSandboxes.path).sorted()
      .compactMap { name in
        guard let id = try? SandboxID(name) else { return nil }
        let paths = macSandbox(id)
        guard FileManager.default.fileExists(atPath: paths.record.path) else { return nil }
        return try paths.loadRecord()
      }
  }
}

package struct MacTemplatePaths: Sendable {
  package let dir: URL
  package var metadata: URL { dir.appendingPathComponent("template.json") }
  package var disk: URL { dir.appendingPathComponent("disk.img") }
  package var aux: URL { dir.appendingPathComponent("aux.img") }
  package var hardwareModel: URL { dir.appendingPathComponent("hardware-model.bin") }

  package func load() throws -> MacTemplate {
    try JSONDecoder.iso.decode(MacTemplate.self, from: Data(contentsOf: metadata))
  }
}

/// A published macOS template: installed, provisioned, helper installed, no
/// SSH host keys, password authentication off. Immutable once published.
package struct MacTemplate: Codable, Sendable {
  package var name: SandboxID
  package var productVersion: String
  package var build: String
  package var ipswSha256: String
  package var helperSha256: String
  /// The operator's provisioning script, when the build ran one.
  package var provisionSha256: String?
  package var diskBytes: UInt64
  package var minimumCPUs: Int
  package var minimumMemoryBytes: UInt64
  package var createdAt: Date
}

package struct MacSandboxPaths: Sendable {
  package let id: SandboxID
  package let dir: URL
  let locks: URL
  package var record: URL { dir.appendingPathComponent("record.json") }
  package var live: URL { dir.appendingPathComponent("live.json") }
  package var disk: URL { dir.appendingPathComponent("disk.img") }
  package var aux: URL { dir.appendingPathComponent("aux.img") }
  package var machineID: URL { dir.appendingPathComponent("machine-id.bin") }
  /// The per-clone helper key, written at enrollment.
  package var helperKey: URL { dir.appendingPathComponent("helper.key") }
  /// The guest's SSH host key, pinned at enrollment.
  package var sshHostKey: URL { dir.appendingPathComponent("ssh_host_ed25519.pub") }
  package var ownerLog: URL { dir.appendingPathComponent("owner.log") }
  package var lock: URL { dir.appendingPathComponent("owner.lock") }
  package var launchdPlist: URL { dir.appendingPathComponent("launchd.plist") }
  package var ownerFailed: URL { dir.appendingPathComponent("owner.failed") }
  /// The same file as a Linux sandbox's mutation guard: one identifier
  /// namespace, so creates of either kind serialize on it.
  package var mutationLock: URL { locks.appendingPathComponent("sandbox-\(id.rawValue).lock") }

  /// Same short per-user directory as Linux sandboxes; a distinct hash input.
  package var control: URL {
    SandboxPaths.controlDirectory.appendingPathComponent(
      "m\(SandboxPaths.stableHash(dir.path)).sock")
  }
  package var launchdLabel: String { "dev.iso.sandbox.macos.\(SandboxPaths.stableHash(dir.path))" }

  package func loadRecord() throws -> MacSandboxRecord {
    try JSONDecoder.iso.decode(MacSandboxRecord.self, from: Data(contentsOf: record))
  }

  package func save(_ record: MacSandboxRecord) throws {
    try JSONEncoder.pretty.encode(record).write(to: self.record, options: .atomic)
  }

  package func loadLive() -> MacLiveState? {
    guard let data = try? Data(contentsOf: live) else { return nil }
    return try? JSONDecoder.iso.decode(MacLiveState.self, from: data)
  }

  package func loadPinnedHostKey() -> String? {
    (try? String(contentsOf: sshHostKey, encoding: .utf8)).map {
      SSHPublicKey.canonical($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

/// How far a clone's first-boot enrollment has got.
package enum MacEnrollment: String, Codable, Sendable {
  /// Fresh clone: the next boot enrolls the helper.
  case pending
  case enrolled
  /// The guest reported, over the authenticated channel, an SSH host key
  /// that differs from the pin; the sandbox is unusable until it is recreated.
  case identityMismatch = "identity_mismatch"
}

package struct MacSandboxRecord: Codable, Sendable {
  package var id: SandboxID
  package var owner: String
  package var template: SandboxID
  package var templateBuild: String
  package var cpus: Int
  package var memoryBytes: UInt64
  package var macAddress: String
  package var subnetIndex: Int
  package var network: NetworkMode
  package var enrollment: MacEnrollment
  /// The host user's SSH public key authorized for the guest `iso` user at
  /// enrollment.
  package var authorizedKey: String
  package var createdAt: Date
  package var expiresAt: Date?

  package var subnet: String { SandboxRecord.subnet(subnetIndex) }
  /// The guest's static address: `.2` of its subnet, as for Linux sandboxes.
  package var guestAddress: String { "10.231.\(subnetIndex).2" }
  package var gateway: String { "10.231.\(subnetIndex).1" }
}

/// Written by the macOS owner while its VM runs; removed on stop.
package struct MacLiveState: Codable, Sendable {
  package var pid: Int32
  package var startedAt: Date
  /// Random per owner process: host-anchored, so sessions bound to it die
  /// with the owner.
  package var bootId: String
  package var ipv4: String
}
