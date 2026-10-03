import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Foundation

package struct ImageSummary: Codable, Sendable {
  package var reference: String
  package var digest: String
}

package struct DiskSummary: Codable, Sendable {
  package var name: String
  package var logicalBytes: UInt64
  package var allocatedBytes: UInt64
}

/// OCI images, unpacked base disks, and committed disks.
package enum Disks {
  /// Load an OCI archive (as written by `container image save`) into the
  /// private image store.
  package static func importImage(root: SandboxRoot, ociTar: URL) async throws -> [ImageSummary] {
    let layout = root.root.appendingPathComponent(".oci-layout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: layout) }
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xf", ociTar.path, "-C", layout.path]
    tar.environment = ["PATH": "/usr/bin:/bin"]
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else {
      throw SandboxError("tar failed to unpack \(ociTar.path)")
    }
    let store = try ImageStore(path: root.imageStore)
    return try await store.load(from: layout).map {
      ImageSummary(reference: $0.reference, digest: $0.digest)
    }
  }

  package static func listImages(root: SandboxRoot) async throws -> [ImageSummary] {
    let store = try ImageStore(path: root.imageStore)
    return try await store.list().map { ImageSummary(reference: $0.reference, digest: $0.digest) }
      .sorted { $0.reference < $1.reference }
  }

  /// Remove `reference` and every cached base disk unpacked from it.
  package static func deleteImage(root: SandboxRoot, reference: String) async throws {
    let store = try ImageStore(path: root.imageStore)
    let image = try await store.get(reference: reference)
    let prefix = image.digest.replacingOccurrences(of: "sha256:", with: "") + "-"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: root.bases.path)) ?? []
    where name.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: root.bases.appendingPathComponent(name))
    }
    try await store.delete(reference: reference, performCleanup: true)
  }

  static func baseName(digest: String, bytes: UInt64) -> String {
    "\(digest.replacingOccurrences(of: "sha256:", with: ""))-\(bytes).ext4"
  }

  /// An unpacked, journaled ext4 of `image` at `bytes` capacity, created once
  /// and cloned per sandbox (unpacking costs ~0.7 s; a clone is instant).
  package static func base(root: SandboxRoot, image: Containerization.Image, bytes: UInt64)
    async throws -> URL
  {
    let url = root.bases.appendingPathComponent(baseName(digest: image.digest, bytes: bytes))
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let tmp = root.bases.appendingPathComponent(".tmp-\(UUID().uuidString).ext4")
    defer { try? FileManager.default.removeItem(at: tmp) }
    _ = try await EXT4Unpacker(capacityInBytes: bytes, journal: .init(defaultMode: .ordered))
      .unpack(image, for: .current, at: tmp)
    // A concurrent create may have won the race; either copy is identical.
    if rename(tmp.path, url.path) != 0, !FileManager.default.fileExists(atPath: url.path) {
      throw SandboxError("rename base: errno \(errno)")
    }
    return url
  }

  package static let initImagePrefix = "ghcr.io/apple/containerization/vminit"

  package static func listDisks(root: SandboxRoot) -> [DiskSummary] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.disks.path)) ?? []
    return names.filter { $0.hasSuffix(".ext4") && !$0.hasPrefix(".") }.sorted().map { name in
      let (logical, allocated) = sizes(root.disks.appendingPathComponent(name))
      return DiskSummary(
        name: String(name.dropLast(5)), logicalBytes: logical, allocatedBytes: allocated)
    }
  }

  package static func sizes(_ url: URL) -> (logical: UInt64, allocated: UInt64) {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return (0, 0) }
    return (UInt64(st.st_size), UInt64(st.st_blocks) * 512)
  }
}
