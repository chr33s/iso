import Foundation
import IsoConfiguration
import IsoCore

/// Host-side image facts. Runtime cache allocation is not probed here; the
/// early inspection increment reports that as unavailable rather than guessing.
public struct ImageInspection: Sendable, Equatable {
  public let name: ImageName
  public let source: String
  public let recipeHash: String
  public let profiles: [String]
  public let guestUser: String
  public let created: String
  public let digest: String
  public let baseImage: String
  public let instanceReferences: [String]
  public let runtimeCache: String

  public var lines: [String] {
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

  public var json: OutputJSON {
    .object([
      ("name", .string(name.rawValue)),
      ("source", .string(source)),
      ("recipe_hash", .string(recipeHash)),
      ("profiles", .array(profiles.map(OutputJSON.string))),
      ("guest_user", .string(guestUser)),
      ("created", .string(created)),
      ("digest", .string(digest)),
      ("base_image", .string(baseImage)),
      ("instance_references", .array(instanceReferences.map(OutputJSON.string))),
      ("runtime_cache", .string(runtimeCache)),
    ])
  }
}

public struct CacheStatus: Sendable, Equatable {
  public let manifests: [String]
  public let instanceDisks: Int
  public let unpackedDisks: String
  public let note: String

  public var lines: [String] {
    [
      "Image manifests: \(manifests.isEmpty ? "none" : manifests.joined(separator: ", "))",
      "Instance records: \(instanceDisks)",
      "Unpacked runtime disks: \(unpackedDisks)",
      note,
    ]
  }

  public var json: OutputJSON {
    .object([
      ("manifests", .array(manifests.map(OutputJSON.string))),
      ("instance_records", .int(Int64(instanceDisks))),
      ("unpacked_runtime_disks", .string(unpackedDisks)),
      ("note", .string(note)),
    ])
  }
}

public enum ImageInspectionReport {
  public static func inspect(_ config: IsoConfig, _ name: ImageName) throws -> ImageInspection {
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

  public static func cacheStatus(_ config: IsoConfig) throws -> CacheStatus {
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
