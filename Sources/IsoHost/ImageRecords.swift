import Foundation
import IsoConfiguration
import IsoCore

/// 64 hex characters (either case, as the Rust `hex` crate accepts).
public struct SHA256Hex: Hashable, Sendable, Codable {
  public let rawValue: String

  public init(_ value: String) throws(ValidationError) {
    let bytes = Array(value.utf8)
    guard bytes.count == 64 else {
      throw ValidationError("expected 64 hex characters, got \(bytes.count)")
    }
    guard bytes.allSatisfy(isASCIIHexDigit) else {
      throw ValidationError("invalid hex in sha256 digest: \(debugQuoted(value))")
    }
    rawValue = value.lowercased()
  }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// `sha256:<64 hex>` OCI content digest.
public struct OCIDigest: Hashable, Sendable, Codable {
  public let hash: SHA256Hex

  public init(_ value: String) throws(ValidationError) {
    guard value.hasPrefix("sha256:") else {
      throw ValidationError("OCI digest must start with 'sha256:': \(debugQuoted(value))")
    }
    hash = try SHA256Hex(String(value.dropFirst(7)))
  }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode("sha256:" + hash.rawValue)
  }
}

public struct InstalledFeature: Sendable, Equatable, Codable {
  public let id: String
  public let reference: String
  public let digest: OCIDigest
  public let installScriptHash: SHA256Hex

  enum CodingKeys: String, CodingKey {
    case id, reference, digest
    case installScriptHash = "install_script_hash"
  }
}

/// `<images>/<name>/template-config.json`: what an image was built with.
public struct TemplateConfig: Sendable, Equatable, Codable {
  public let version: UInt32
  public let created: String
  public let installScriptHash: SHA256Hex
  public let profiles: [String]
  public let extraPackages: [String]
  public let postInstallHash: SHA256Hex?
  public let marketplaces: [String]
  public let plugins: [String]
  public let codexMarketplaces: [String]
  public let codexPlugins: [String]
  public let guestUser: GuestUser
  public let ociFeatures: [InstalledFeature]

  enum CodingKeys: String, CodingKey {
    case version, created, profiles, marketplaces, plugins
    case installScriptHash = "install_script_hash"
    case extraPackages = "extra_packages"
    case postInstallHash = "post_install_hash"
    case codexMarketplaces = "codex_marketplaces"
    case codexPlugins = "codex_plugins"
    case guestUser = "guest_user"
    case ociFeatures = "oci_features"
  }

  init(
    version: UInt32, created: String, installScriptHash: SHA256Hex, profiles: [String],
    extraPackages: [String],
    postInstallHash: SHA256Hex?, marketplaces: [String], plugins: [String],
    codexMarketplaces: [String],
    codexPlugins: [String], guestUser: GuestUser, ociFeatures: [InstalledFeature]
  ) {
    self.version = version
    self.created = created
    self.installScriptHash = installScriptHash
    self.profiles = profiles
    self.extraPackages = extraPackages
    self.postInstallHash = postInstallHash
    self.marketplaces = marketplaces
    self.plugins = plugins
    self.codexMarketplaces = codexMarketplaces
    self.codexPlugins = codexPlugins
    self.guestUser = guestUser
    self.ociFeatures = ociFeatures
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(UInt32.self, forKey: .version)
    created = try c.decode(String.self, forKey: .created)
    installScriptHash = try c.decode(SHA256Hex.self, forKey: .installScriptHash)
    profiles = try c.decode([String].self, forKey: .profiles)
    extraPackages = try c.decode([String].self, forKey: .extraPackages)
    postInstallHash = try c.decodeIfPresent(SHA256Hex.self, forKey: .postInstallHash)
    marketplaces = try c.decodeIfPresent([String].self, forKey: .marketplaces) ?? []
    plugins = try c.decodeIfPresent([String].self, forKey: .plugins) ?? []
    codexMarketplaces = try c.decodeIfPresent([String].self, forKey: .codexMarketplaces) ?? []
    codexPlugins = try c.decodeIfPresent([String].self, forKey: .codexPlugins) ?? []
    guestUser = try c.decodeIfPresent(GuestUser.self, forKey: .guestUser) ?? .default
    ociFeatures = try c.decodeIfPresent([InstalledFeature].self, forKey: .ociFeatures) ?? []
  }
}

/// A named golden image directory under `<state root>/images`.
public struct ImageInfo: Sendable, Equatable {
  public let name: ImageName
  public let directory: String
  /// Nil when `template-config.json` is missing or unreadable.
  public let config: TemplateConfig?
}

public enum ImageStore {
  /// Image directories sorted by name. Entries whose name is not a valid
  /// image name are reported through `skipped` and ignored; an unreadable or
  /// invalid template config yields `config == nil` (baseline behavior).
  public static func list(
    _ config: IsoConfig, skipped: (String, ValidationError) -> Void = { _, _ in }
  ) throws
    -> [ImageInfo]
  {
    let root = config.imagesDirectory.path
    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: root)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    } catch {
      throw HostError("Failed to read images directory")
    }
    var images: [ImageInfo] = []
    for entry in entries {
      var status = stat()
      guard lstat(root + "/" + entry, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
        continue
      }
      let name: ImageName
      do { name = try ImageName(entry) } catch {
        skipped(entry, error)
        continue
      }
      let directory = root + "/" + entry
      let data = FileManager.default.contents(atPath: directory + "/template-config.json")
      let templateConfig = data.flatMap { try? JSONDecoder().decode(TemplateConfig.self, from: $0) }
      images.append(ImageInfo(name: name, directory: directory, config: templateConfig))
    }
    return images.sorted { $0.name.rawValue.utf8.lexicographicallyPrecedes($1.name.rawValue.utf8) }
  }
}

extension TemplateConfig {
  /// Every field written, `null` included, as serde does.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(version, forKey: .version)
    try c.encode(created, forKey: .created)
    try c.encode(installScriptHash, forKey: .installScriptHash)
    try c.encode(profiles, forKey: .profiles)
    try c.encode(extraPackages, forKey: .extraPackages)
    try c.encode(postInstallHash, forKey: .postInstallHash)
    try c.encode(marketplaces, forKey: .marketplaces)
    try c.encode(plugins, forKey: .plugins)
    try c.encode(codexMarketplaces, forKey: .codexMarketplaces)
    try c.encode(codexPlugins, forKey: .codexPlugins)
    try c.encode(guestUser, forKey: .guestUser)
    try c.encode(ociFeatures, forKey: .ociFeatures)
  }

  func withCreated(_ created: String) -> TemplateConfig {
    TemplateConfig(
      version: version, created: created, installScriptHash: installScriptHash, profiles: profiles,
      extraPackages: extraPackages, postInstallHash: postInstallHash, marketplaces: marketplaces,
      plugins: plugins,
      codexMarketplaces: codexMarketplaces, codexPlugins: codexPlugins, guestUser: guestUser,
      ociFeatures: ociFeatures)
  }
}

/// `images/<name>/template-config.json` reads and writes.
public enum TemplateStore {
  static func path(_ config: IsoConfig, _ image: ImageName) -> String {
    config.imagesDirectory.appending(image.rawValue).appending("template-config.json").path
  }

  public static func load(_ config: IsoConfig, _ image: ImageName) throws -> TemplateConfig {
    let path = path(config, image)
    do {
      guard let data = FileManager.default.contents(atPath: path) else {
        throw HostError("Failed to read \(path)")
      }
      do { return try JSONDecoder().decode(TemplateConfig.self, from: data) } catch {
        throw HostError("Failed to parse \(path)")
      }
    } catch {
      throw ContextError("Failed to load template config for source image '\(image)'", cause: error)
    }
  }

  /// Pretty JSON without a trailing newline; a new file is 0644.
  public static func save(
    _ template: TemplateConfig, recreatedAt created: String, config: IsoConfig, image: ImageName
  )
    throws
  {
    let path = path(config, image)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    do {
      try AtomicFile.write(
        Array(try encoder.encode(template.withCreated(created))), to: path,
        mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write \(path)", cause: error)
    }
  }
}
