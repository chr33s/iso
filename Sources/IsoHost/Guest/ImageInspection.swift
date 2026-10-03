import Foundation
import IsoConfiguration
import IsoCore

/// Host-side image facts. Runtime cache allocation is not probed here; the
/// early inspection increment reports that as unavailable rather than guessing.
package struct ImageInspection: Sendable, Equatable, Encodable {
  package let name: ImageName
  package let source: String
  package let recipeHash: String
  package let profiles: [String]
  package let guestUser: String
  package let created: String
  package let digest: String
  package let baseImage: String
  package let instanceReferences: [String]
  package let runtimeCache: String

  package var lines: [String] {
    [
      "Image: \(name)",
      "Source: \(source)",
      "Recipe: \(recipeHash)",
      "Profiles: \(profiles.isEmpty ? "none" : profiles.joined(separator: ", "))",
      "Guest user: \(guestUser)",
      "Created: \(created)",
      "Digest: \(digest)",
      "Base: \(baseImage)",
      "Instance references: \(instanceReferences.isEmpty ? "none" : instanceReferences.joined(separator: ", "))",
      "Runtime cache: \(runtimeCache)",
    ]
  }

  enum CodingKeys: String, CodingKey {
    case name, source, profiles, created, digest
    case recipeHash = "recipe_hash"
    case guestUser = "guest_user"
    case baseImage = "base_image"
    case instanceReferences = "instance_references"
    case runtimeCache = "runtime_cache"
  }

}

package struct CacheStatus: Sendable, Equatable, Encodable {
  package let manifests: [String]
  package let instanceDisks: Int
  package let unpackedDisks: String
  package let note: String

  package var lines: [String] {
    [
      "Image manifests: \(manifests.isEmpty ? "none" : manifests.joined(separator: ", "))",
      "Instance records: \(instanceDisks)",
      "Unpacked runtime disks: \(unpackedDisks)",
      note,
    ]
  }

  enum CodingKeys: String, CodingKey {
    case manifests, note
    case instanceDisks = "instance_records"
    case unpackedDisks = "unpacked_runtime_disks"
  }

}

package enum ImageInspectionReport {
  package static func inspect(_ config: IsoConfig, _ name: ImageName) throws -> ImageInspection {
    let images = try ImageStore.list(config)
    guard let image = images.first(where: { $0.name == name }) else {
      throw HostError("No image '\(name)' found.\nRun `iso setup --image \(name)` first.")
    }
    let manifest = try? ImageManifest.loadIfPresent(config, name)
    let instances = (try? InstanceStore.list(config)) ?? []
    let references = instances.filter { $0.image == name }.map(\.name.rawValue)
    let source: String
    let recipe: String
    if let template = image.config {
      source = "recipe-built"
      recipe = template.installScriptHash.rawValue
    } else if manifest?.disk != nil {
      source = "manual snapshot"
      recipe = "unknown (not recipe-reproducible)"
    } else {
      source = "unknown"
      recipe = "unknown"
    }
    return ImageInspection(
      name: name, source: source, recipeHash: recipe, profiles: image.config?.profiles ?? [],
      guestUser: image.config?.guestUser.rawValue ?? manifest?.guestUser.rawValue ?? "unknown",
      created: image.config?.created ?? manifest?.created ?? "unknown",
      digest: manifest?.digest ?? "unknown",
      baseImage: manifest?.baseImage ?? "unknown", instanceReferences: references,
      runtimeCache: "unavailable (not probed)")
  }

  package static func cacheStatus(_ config: IsoConfig) throws -> CacheStatus {
    let images = try ImageStore.list(config)
    let instances = (try? InstanceStore.list(config)) ?? []
    return CacheStatus(
      manifests: images.map(\.name.rawValue), instanceDisks: instances.count,
      unpackedDisks: "unavailable",
      note:
        "Runtime cache allocation is not measured. Shared APFS clones are not summed as exclusive space. Prune is not available."
    )
  }
}
