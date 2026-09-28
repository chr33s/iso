// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore
import Foundation

/// The one release channel `coop update` installs from. Every metadata
/// request, download and attestation check names this repository; nothing
/// here is configurable except the test-only API base override.
public enum UpdateChannel {
  public static let repository = "chr33s/coop"
  public static let defaultAPIBase = "https://api.github.com"
  /// Release asset holding the Sigstore provenance bundle.
  public static let bundleAsset = "attestations.jsonl"
  public static let checksumAsset = "SHA256SUMS"
  /// Test-only: point metadata and downloads at a local fixture. Setting it
  /// disables attestation verification (and says so on stderr).
  public static let apiBaseVariable = "COOP_UPDATE_API_BASE_URL"

  /// The prebuilt target this host installs.
  public static func targetTriple() throws(HostError) -> String {
    #if os(macOS) && arch(arm64)
      return "aarch64-apple-darwin"
    #else
      #if arch(x86_64)
        let arch = "x86_64"
      #else
        let arch = "unknown"
      #endif
      throw HostError("No prebuilt coop binary for macos-\(arch); build from source.")
    #endif
  }

  /// Release workflow naming: `coop-<tag>-<triple>.tar.gz`.
  public static func assetName(tag: String, triple: String) -> String {
    "coop-\(tag)-\(triple).tar.gz"
  }

  /// The directory the archive unpacks to: `coop-<tag>-<triple>/`.
  public static func archiveDirectory(tag: String, triple: String) -> String {
    "coop-\(tag)-\(triple)"
  }

  /// A user-supplied version as a `v`-prefixed semver tag. Only semver is
  /// admitted: the tag is interpolated into the API URL path, so this is the
  /// boundary that keeps `--version` from traversing to another repository.
  public static func normalizeTag(_ input: String) throws -> String {
    let trimmed = input.trimmingUnicodeWhitespace()
    let body = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    do { _ = try SemanticVersion(parsing: body) } catch {
      throw ContextError(
        "--version \(debugQuoted(trimmed)) is not a valid semver tag", cause: error)
    }
    return "v" + body
  }

  static func stripV(_ tag: String) -> String {
    tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
  }
}

/// The subset of GitHub's release JSON the updater reads.
public struct Release: Sendable, Equatable, Decodable {
  public let tag: String
  public let assets: [Asset]

  public struct Asset: Sendable, Equatable, Decodable {
    public let name: String
    public let url: String

    public init(name: String, url: String) {
      self.name = name
      self.url = url
    }

    enum CodingKeys: String, CodingKey {
      case name
      case url = "browser_download_url"
    }
  }

  enum CodingKeys: String, CodingKey {
    case tag = "tag_name"
    case assets
  }

  public init(tag: String, assets: [Asset]) {
    self.tag = tag
    self.assets = assets
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tag = try container.decode(String.self, forKey: .tag)
    // `#[serde(default)]`: absent means empty; an explicit null is an error.
    assets = container.contains(.assets) ? try container.decode([Asset].self, forKey: .assets) : []
  }

  public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }

  public static func parse(_ text: String) throws -> Release {
    do { return try JSONDecoder().decode(Release.self, from: Data(text.utf8)) } catch {
      throw ContextError("Failed to parse GitHub release JSON", cause: HostError("\(error)"))
    }
  }
}

public enum Checksums {
  /// The digest for `file` in a `sha256sum`-style listing. Accepts
  /// `<hash>  <file>` and `<hash> *<file>`, skips blank and `#` lines; the
  /// first well-formed entry wins and malformed digests are skipped. A
  /// non-blank line without whitespace ends the search (baseline).
  public static func parse(_ content: String, file: String) -> SHA256Hex? {
    for raw in rustLines(content) {
      let line = raw.trimmingUnicodeWhitespace().unicodeScalars
      if line.isEmpty || line.first == "#" { continue }
      guard let split = line.firstIndex(where: isASCIIWhitespace) else { return nil }
      let hash = String(String.UnicodeScalarView(line[..<split]))
      let rest = line[line.index(after: split)...]
        .drop { $0.properties.isWhitespace }
        .drop { $0 == "*" }
      if String(String.UnicodeScalarView(rest)) == file, let parsed = try? SHA256Hex(hash) {
        return parsed
      }
    }
    return nil
  }

  public static func of(_ bytes: [UInt8]) -> SHA256Hex {
    try! SHA256Hex(sha256Hex(bytes))
  }
}

/// Rust `char::is_ascii_whitespace`.
func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
  scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == "\r"
}

/// How release metadata and assets are fetched.
enum AuthStrategy: Equatable {
  /// The `gh` CLI, already authenticated to github.com.
  case gh
  /// curl with `GITHUB_TOKEN` as a bearer token, passed on stdin.
  case curlBearer(String)
  /// curl without credentials.
  case curlBare

  /// The API override forces bare curl: the local fixture speaks neither gh
  /// nor tokens.
  static func select(apiBaseOverridden: Bool, hasGh: Bool, ghAuthenticated: Bool, token: String?)
    -> AuthStrategy
  {
    if apiBaseOverridden { return .curlBare }
    if hasGh && ghAuthenticated { return .gh }
    if let token, !token.isEmpty { return .curlBearer(token) }
    return .curlBare
  }
}

/// Whether the release's provenance bundle can be used; decided before IO.
enum BundleDecision: Equatable {
  /// The API override is set; verification is skipped.
  case testMode
  /// `gh` is absent; nothing can verify an attestation.
  case noGh
  /// The release publishes no bundle asset.
  case noAsset
  /// Download the bundle from this asset.
  case fetch(Release.Asset)

  static func decide(_ release: Release, apiOverridden: Bool, ghPresent: Bool) -> BundleDecision {
    if apiOverridden { return .testMode }
    if !ghPresent { return .noGh }
    return release.asset(named: UpdateChannel.bundleAsset).map(BundleDecision.fetch) ?? .noAsset
  }
}

/// Why verification fell back to the attestations API.
enum APIReason: Equatable {
  case noAsset
  case downloadFailed
  /// `gh` before 2.56.0 reports success on an empty bundle, so an empty file
  /// never reaches `--bundle`.
  case emptyBundle
}

/// What the attestation is verified against.
enum Provenance: Equatable {
  case testMode
  case noGh
  case api(APIReason)
  case bundle(String)

  var bundlePath: String? {
    if case .bundle(let path) = self { return path }
    return nil
  }

  /// Names the API fallback in a verification failure; empty otherwise.
  var apiFallbackHint: String {
    let cause: String
    switch self {
    case .api(.noAsset): cause = "the release publishes no \(UpdateChannel.bundleAsset)"
    case .api(.downloadFailed): cause = "\(UpdateChannel.bundleAsset) could not be downloaded"
    case .api(.emptyBundle): cause = "the published \(UpdateChannel.bundleAsset) is empty"
    case .testMode, .noGh, .bundle: return ""
    }
    return
      " (verified through the GitHub API because \(cause); an HTTP 403 here means your GitHub credential has no SSO session for \(UpdateChannel.repository))"
  }

  /// `gh attestation verify` argv; the repository is always pinned.
  static func verifyArguments(tarball: String, bundle: String?) -> [String] {
    var arguments = ["attestation", "verify", tarball, "--repo", UpdateChannel.repository]
    if let bundle { arguments += ["--bundle", bundle] }
    return arguments
  }
}
