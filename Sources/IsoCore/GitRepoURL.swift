/// A clone URL given to `iso up --git-repo`, with the `owner/repo` slug
/// derived once at construction. The slug is nil for clone URLs that are not
/// GitHub `owner/repo` URLs; such repositories still clone, they just carry
/// no slug for PAT routing. Persisted as the bare URL string.
public struct GitRepoURL: Hashable, Sendable, CustomStringConvertible, Codable {
  public let url: String
  public let slug: RepoSlug?

  public init(_ url: String) {
    self.url = url
    slug = RepoSlug.parse(url: url)
  }

  public var description: String { url }

  /// Equality is by URL; the slug is derived from it.
  public static func == (a: Self, b: Self) -> Bool { a.url == b.url }
  public func hash(into hasher: inout Hasher) { hasher.combine(url) }

  public init(from decoder: any Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(url)
  }

  /// `https://github.com/...` with no userinfo: a URL whose credentials the
  /// caller did not supply, so a host token may be offered for the clone.
  public static func isGitHubHTTPS(_ url: String) -> Bool {
    guard url.hasPrefix("https://") else { return false }
    let rest = url.dropFirst("https://".count)
    guard let slash = rest.firstIndex(of: "/") else { return false }
    return rest[..<slash] == "github.com"
  }

  /// Default instance name for a clone: the slug's repo segment, otherwise
  /// the URL's last path segment without `.git`, mapped to the instance-name
  /// class, trimmed of `-`, and capped at 60 characters.
  public static func defaultInstanceName(_ url: String) -> InstanceName? {
    var base: Substring
    if let slug = RepoSlug.parse(url: url) {
      base = Substring(slug.repo)
    } else {
      var trimmed = Substring(url)
      while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
      base = trimmed.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
      base = base.split(separator: ":", omittingEmptySubsequences: false).last ?? ""
      while base.hasSuffix(".git") { base = base.dropLast(4) }
    }
    let mapped = String(
      String.UnicodeScalarView(
        base.unicodeScalars.map { scalar -> Unicode.Scalar in
          switch scalar {
          case "a"..."z", "A"..."Z", "0"..."9", "-", "_": scalar
          default: "-"
          }
        }))
    let sanitized = mapped.drop { $0 == "-" }.reversed().drop { $0 == "-" }.reversed()
    guard !sanitized.isEmpty else { return nil }
    return try? InstanceName(String(sanitized.prefix(60)))
  }
}
