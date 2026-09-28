import Foundation
import Testing

@testable import CoopCore

@Test func gitRepoURLDerivesTheSlugOnceAndPersistsTheBareURL() throws {
  let github = GitRepoURL("https://github.com/trailofbits/coop.git")
  #expect(github.slug == (try RepoSlug("trailofbits/coop")))
  #expect(GitRepoURL("https://gitlab.com/group/project.git").slug == nil)
  let encoded = try JSONEncoder().encode(GitRepoURL("https://github.com/a/b.git"))
  #expect(String(decoding: encoded, as: UTF8.self) == #""https:\/\/github.com\/a\/b.git""#)
  let decoded = try JSONDecoder().decode(
    GitRepoURL.self, from: Data(#""https://github.com/a/b""#.utf8))
  #expect(decoded.slug == (try RepoSlug("a/b")))
  #expect(GitRepoURL("https://github.com/a/b") == GitRepoURL("https://github.com/a/b"))
  #expect(GitRepoURL("https://github.com/a/b") != GitRepoURL("https://github.com/a/c"))
}

@Test func defaultInstanceNamesFollowTheRepoBasename() {
  let cases: [(String, String?)] = [
    ("https://github.com/trailofbits/coop.git", "coop"),
    ("git@example.com:org/my.repo.git", "my-repo"),
    ("https://example.com/org/widget/", "widget"),
    ("git@example.com:org/tools", "tools"),
    ("/srv/git/repo.git", "repo"),
    ("https://example.com/org/.git", nil),
    ("https://example.com/org/---", nil),
  ]
  for (url, expected) in cases {
    #expect(GitRepoURL.defaultInstanceName(url)?.rawValue == expected, "\(url)")
  }
  let long = GitRepoURL.defaultInstanceName(
    "https://example.com/org/\(String(repeating: "a", count: 200)).git")
  #expect(long?.rawValue == String(repeating: "a", count: 60))
}

@Test func githubHTTPSURLsExcludeOtherSchemesHostsAndUserinfo() {
  for url in [
    "https://github.com/owner/repo", "https://github.com/owner/repo.git", "https://github.com/",
  ] {
    #expect(GitRepoURL.isGitHubHTTPS(url), "\(url)")
  }
  for url in [
    "git@github.com:owner/repo.git", "ssh://git@github.com/owner/repo",
    "git://github.com/owner/repo",
    "https://gitlab.com/owner/repo", "https://example.com/github.com/repo",
    "https://api.github.com/repos/x/y", "https://user:pass@github.com/owner/repo",
    "https://token@github.com/owner/repo", "https://github.com",
  ] {
    #expect(!GitRepoURL.isGitHubHTTPS(url), "\(url)")
  }
}

@Test func slugURLParsingRoundTripsThroughNoise() throws {
  let prefixes = [
    "https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:",
  ]
  for prefix in prefixes {
    for suffix in ["", ".git", "/", ".git/"] {
      #expect(
        RepoSlug.parse(url: "\(prefix)own-er/re.po_1\(suffix)") == (try RepoSlug("own-er/re.po_1")))
    }
  }
  #expect(RepoSlug.parse(url: "https://gitlab.com/owner/repo") == nil)
  #expect(RepoSlug.parse(url: "https://github.com/owner/repo/pulls/1") == nil)
  #expect(RepoSlug.parse(url: "https://github.com/owner") == nil)
}
