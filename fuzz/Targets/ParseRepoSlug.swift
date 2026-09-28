import CoopCore

/// `RepoSlug.parse(url:)` on arbitrary input: `git remote get-url` output and
/// `--git-repo` arguments cross a trust boundary.
public enum ParseRepoSlugHarness {
  public static func run(_ bytes: [UInt8]) {
    let text = String(decoding: bytes, as: UTF8.self)
    guard let slug = RepoSlug.parse(url: text) else { return }
    // A parsed slug is itself valid and survives a canonical round trip.
    require((try? RepoSlug(slug.rawValue)) == slug, "parsed slug revalidates")
    require(slug.owner + "/" + slug.repo == slug.rawValue, "owner/repo split")
    // One `.git` suffix is stripped by design, so `y.git` re-parses as `y`.
    require(
      RepoSlug.parse(url: "git@github.com:" + slug.rawValue + ".git") == slug, "ssh round trip")
    if !slug.rawValue.hasSuffix(".git") {
      require(
        RepoSlug.parse(url: "https://github.com/" + slug.rawValue + "/") == slug, "https round trip"
      )
    }
  }
}
