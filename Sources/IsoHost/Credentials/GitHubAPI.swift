// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// Host tools found on `PATH` (`curl`, `gh`, `git`, `open`, `stty`), run
/// with an explicit environment. Captured runs return stdout of a successful
/// exit, discard stderr, and produce error texts
/// naming the command line without its secret inputs (those go on stdin).
package struct HostTools: Sendable {
  /// Bound host-tool calls so an unresponsive child cannot hang the command.
  package static let deadline: Duration = .seconds(300)

  package let environment: [String: String]
  let runner: ProcessRunner

  package init(environment: [String: String], runner: ProcessRunner = ProcessRunner()) {
    self.environment = environment
    self.runner = runner
  }

  func locate(_ name: String) -> String? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    where !directory.isEmpty {
      let candidate = "\(directory)/\(name)"
      var status = stat()
      if access(candidate, X_OK) == 0, stat(candidate, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG
      {
        return candidate
      }
    }
    return nil
  }

  /// Run `name` and return its output; nil when it is not on `PATH`.
  func run(
    _ name: String, _ arguments: [String], input: [UInt8]? = nil,
    environment override: [String: String]? = nil
  ) throws(ProcessRunner.Failure) -> ProcessRunner.Output? {
    guard let executable = locate(name) else { return nil }
    return try runner.capture(
      .init(
        executable: executable, arguments: arguments, environment: override ?? environment,
        deadline: Self.deadline, input: input))
  }

  /// Rust `Cmd::capture`: stdout of a successful run as UTF-8.
  func capture(_ name: String, _ arguments: [String], input: [UInt8]? = nil) throws -> String {
    let describe = ([name] + arguments).joined(separator: " ")
    let output: ProcessRunner.Output
    do {
      guard let result = try run(name, arguments, input: input) else {
        throw HostError("No such file or directory (os error 2)")
      }
      output = result
    } catch {
      throw ContextError("Failed to execute \(describe)", cause: error)
    }
    guard output.termination.succeeded else {
      throw HostError("\(describe) exited with \(output.termination)")
    }
    guard let text = String(validating: output.stdout, as: UTF8.self) else {
      throw HostError("\(describe) produced non-UTF-8 output")
    }
    return text
  }

  /// `gh auth token`, trimmed; nil when `gh` is missing, fails, or prints
  /// nothing. Used for host-side requests and one-shot clones only.
  package func ghAuthToken() -> Secret<String>? {
    guard let raw = try? capture("gh", ["auth", "token"]) else { return nil }
    let token = raw.trimmingUnicodeWhitespace()
    return token.isEmpty ? nil : Secret(token)
  }

  /// The GitHub slug of `directory`'s `origin` remote. Nil when the
  /// directory is missing, is not a repository, has no origin, or origin is
  /// not on github.com. Git's repository-selecting variables are removed so
  /// a hook context cannot redirect the lookup.
  package func detectWorkspaceRepo(_ directory: String) throws -> RepoSlug? {
    guard FileManager.default.fileExists(atPath: directory) else { return nil }
    var clean = environment
    for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
      clean[name] = nil
    }
    let output: ProcessRunner.Output
    do {
      guard
        let result = try run(
          "git", ["-C", directory, "remote", "get-url", "origin"], environment: clean)
      else { throw HostError("No such file or directory (os error 2)") }
      output = result
    } catch {
      throw ContextError("Failed to invoke git in \(directory)", cause: error)
    }
    guard output.termination.succeeded else { return nil }
    return RepoSlug.parse(url: String(decoding: output.stdout, as: UTF8.self))
  }
}

/// Why `GET /repos/{owner}/{repo}` rejected a PAT. The PAT prompt's
/// recovery advice branches on the case.
package enum GitHubProbeError: Error, Equatable, Sendable, CustomStringConvertible {
  /// 403: typically the organization's fine-grained PAT policy.
  case orgPolicyBlock(RepoSlug)
  /// 404: wrong slug, or the PAT's resource owner does not match.
  case notFound(RepoSlug)
  case unexpected(RepoSlug, status: UInt16)

  package var description: String {
    switch self {
    case .orgPolicyBlock(let repo):
      "GET /repos/\(repo) returned 403. This is often the org's fine-grained PAT policy: ask an org admin to approve fine-grained PATs, or to approve your specific token."
    case .notFound(let repo):
      "GET /repos/\(repo) returned 404. Check the repo slug and that the PAT was generated with the right resource owner."
    case .unexpected(let repo, let status): "GET /repos/\(repo) returned HTTP \(status)"
    }
  }

  /// Map a `GET /repos/{repo}` status; nil for 200.
  package static func classify(_ status: UInt16, repo: RepoSlug) -> GitHubProbeError? {
    switch status {
    case 200: nil
    case 403: .orgPolicyBlock(repo)
    case 404: .notFound(repo)
    default: .unexpected(repo, status: status)
    }
  }
}

/// `api.github.com` over `curl`. A token travels as an `Authorization` header read from stdin
/// (`-H @-`), never on argv.
package struct GitHubAPI: Sendable {
  package static let jsonMedia = "application/vnd.github+json"
  package static let rawMedia = "application/vnd.github.raw+json"

  let tools: HostTools
  let diagnostics: Diagnostics

  package init(tools: HostTools, diagnostics: Diagnostics) {
    self.tools = tools
    self.diagnostics = diagnostics
  }

  /// `GET url`, returning the HTTP status and body. Fails only when curl
  /// does or its output has no status line; HTTP errors are statuses.
  func get(_ url: String, token: Secret<String>?, accept: String = jsonMedia) throws -> (
    UInt16, String
  ) {
    var arguments = ["-sSL", "-H", "Accept: \(accept)"]
    if token != nil { arguments += ["-H", "@-"] }
    arguments += ["-w", "\n%{http_code}", url]
    let input = token.map { Array("Authorization: token \($0.expose())\n".utf8) }
    do {
      return try Self.parseStatusAndBody(tools.capture("curl", arguments, input: input))
    } catch {
      throw ContextError("curl GET \(url) failed", cause: error)
    }
  }

  /// Split curl's `-w "\n%{http_code}"` trailer from the body.
  static func parseStatusAndBody(_ output: String) throws -> (UInt16, String) {
    let body: String
    let trailer: String
    if let newline = output.unicodeScalars.lastIndex(of: "\n") {
      body = String(output.unicodeScalars[..<newline])
      trailer = String(output.unicodeScalars[output.unicodeScalars.index(after: newline)...])
    } else {
      body = ""
      trailer = output.trimmingUnicodeWhitespace()
    }
    let digits = trailer.trimmingUnicodeWhitespace()
    guard let status = UInt16(digits) else {
      throw ContextError(
        "Failed to parse HTTP status from curl output: '\(trailer)'",
        cause: HostError(rustParseIntError(digits)))
    }
    return (status, body)
  }

  package func userLogin(token: Secret<String>) throws -> String {
    let (status, body) = try get("https://api.github.com/user", token: token)
    return try Self.parseUserLogin(status: status, body: body)
  }

  static func parseUserLogin(status: UInt16, body: String) throws -> String {
    guard status == 200 else {
      throw HostError("GET /user returned HTTP \(status) (token may be invalid or revoked)")
    }
    let afterKey = body.components(separatedBy: "\"login\"")
    let quoted = afterKey.count > 1 ? afterKey[1].components(separatedBy: "\"") : []
    guard quoted.count > 1 else {
      throw HostError("Token authentication failed: /user returned unexpected response")
    }
    return quoted[1]
  }

  /// `GET /repos/{repo}` with `token`; throws `GitHubProbeError` on a
  /// non-200 status.
  package func probeRepo(token: Secret<String>, repo: RepoSlug) throws {
    let status: UInt16
    do {
      status = try get("https://api.github.com/repos/\(repo)", token: token).0
    } catch {
      throw ContextError("failed to query GET /repos/\(repo)", cause: error)
    }
    if let failure = GitHubProbeError.classify(status, repo: repo) { throw failure }
  }

  /// Whether an unauthenticated request can read `repo` (it is public).
  /// Anything else, including rate limiting and network failure, counts as
  /// not public, so the wizard errs toward asking for coverage.
  func isPublic(_ repo: RepoSlug) -> Bool {
    do {
      let (status, _) = try get("https://api.github.com/repos/\(repo)", token: nil)
      if status == 200 { return true }
      diagnostics.debug("anonymous probe of \(repo) returned HTTP \(status)")
    } catch {
      diagnostics.debug("anonymous probe of \(repo) failed: \(oneLine(error))")
    }
    return false
  }

  static func gitmodulesURL(_ parent: RepoSlug) -> String {
    "https://api.github.com/repos/\(parent)/contents/.gitmodules"
  }

  /// Discover submodules before the PAT form is shown, with the user's
  /// `gh` token or else anonymously (public parents). Nil when neither
  /// produced an answer; 404 (no `.gitmodules`) is an empty discovery.
  func prefetchSubmodules(_ parent: RepoSlug) -> SubmoduleDiscovery? {
    let url = Self.gitmodulesURL(parent)
    var body: String?
    if let token = tools.ghAuthToken() {
      do {
        switch try get(url, token: token, accept: Self.rawMedia) {
        case (200, let text): body = text
        case (404, _): body = ""
        case (let status, _):
          diagnostics.debug(
            "prefetch with gh token returned HTTP \(status) for \(url) — falling through to anonymous"
          )
        }
      } catch {
        diagnostics.debug("prefetch with gh token failed: \(oneLine(error))")
      }
    }
    if body == nil {
      do {
        switch try get(url, token: nil, accept: Self.rawMedia) {
        case (200, let text): body = text
        case (404, _): body = ""
        case (let status, _):
          diagnostics.debug("anonymous prefetch returned HTTP \(status) for \(url)")
        }
      } catch {
        diagnostics.debug("anonymous prefetch failed: \(oneLine(error))")
      }
    }
    guard let body else { return nil }
    var discovery = SubmoduleDiscovery.classify(
      parent: parent, urls: SubmoduleDiscovery.extractURLs(body), diagnostics: diagnostics)
    _ = discovery.dropPublic(isPublic)
    return discovery
  }

  /// `.gitmodules` of `parent` read with the pasted token. A status other
  /// than 200 yields an empty discovery; the second value is the status to
  /// warn about (not 404, the common "no submodules" case).
  func discoverSubmodules(token: Secret<String>, parent: RepoSlug) throws -> (
    SubmoduleDiscovery, warnStatus: UInt16?
  ) {
    let (status, body) = try get(Self.gitmodulesURL(parent), token: token, accept: Self.rawMedia)
    switch status {
    case 200:
      return (
        SubmoduleDiscovery.classify(
          parent: parent, urls: SubmoduleDiscovery.extractURLs(body), diagnostics: diagnostics),
        nil
      )
    case 404: return (SubmoduleDiscovery(), nil)
    default: return (SubmoduleDiscovery(), status)
    }
  }

  /// The `expected` repos `token` cannot read (403/404). Other non-200
  /// statuses fail.
  func uncovered(token: Secret<String>, expected: [RepoSlug]) throws -> [RepoSlug] {
    var failed: [RepoSlug] = []
    for slug in expected {
      let (status, _) = try get("https://api.github.com/repos/\(slug)", token: token)
      switch status {
      case 200: break
      case 403, 404: failed.append(slug)
      default: throw HostError("GET /repos/\(slug) returned HTTP \(status)")
      }
    }
    return failed
  }
}

/// Rust `ParseIntError` text for a `u16` parse.
func rustParseIntError(_ digits: String) -> String {
  if digits.isEmpty { return "cannot parse integer from empty string" }
  let body = digits.hasPrefix("+") ? digits.dropFirst() : Substring(digits)
  if !body.isEmpty && body.allSatisfy({ $0.isASCII && $0.isNumber }) {
    return "number too large to fit in target type"
  }
  return "invalid digit found in string"
}

// MARK: - Submodules

/// Depth-1 submodules of a parent repository (from `.gitmodules` served by
/// GitHub, so untrusted: URLs are sanitized wherever they are shown),
/// classified for PAT coverage:
/// same resource owner (one PAT can cover them), other owners (one PAT per
/// owner), and URLs not on github.com. Buckets are sorted and deduplicated
/// so the wizard's output is stable.
package struct SubmoduleDiscovery: Equatable, Sendable {
  /// Same owner as the parent; the parent itself excluded.
  package var sameOwner: [RepoSlug] = []
  /// Grouped by owner, owners in byte order.
  package var crossOwner: [(owner: String, repos: [RepoSlug])] = []
  package var nonGitHubURLs: [String] = []

  package init() {}

  package static func == (a: Self, b: Self) -> Bool {
    a.sameOwner == b.sameOwner && a.nonGitHubURLs == b.nonGitHubURLs
      && a.crossOwner.map(\.owner) == b.crossOwner.map(\.owner)
      && a.crossOwner.map(\.repos) == b.crossOwner.map(\.repos)
  }

  package var isEmpty: Bool { sameOwner.isEmpty && crossOwner.isEmpty && nonGitHubURLs.isEmpty }

  /// Remove the repos `isPublic` accepts (they clone without a token) and
  /// return them sorted; owner groups left empty are dropped.
  package mutating func dropPublic(_ isPublic: (RepoSlug) -> Bool) -> [RepoSlug] {
    var dropped: [RepoSlug] = []
    sameOwner = sameOwner.filter { slug in
      if isPublic(slug) {
        dropped.append(slug)
        return false
      }
      return true
    }
    crossOwner = crossOwner.compactMap { group in
      let kept = group.repos.filter { slug in
        if isPublic(slug) {
          dropped.append(slug)
          return false
        }
        return true
      }
      return kept.isEmpty ? nil : (group.owner, kept)
    }
    return dropped.sorted()
  }

  /// `url = …` values of a `.gitmodules` body: comments, blank lines and
  /// section headers skipped, surrounding double quotes stripped.
  package static func extractURLs(_ gitmodules: String) -> [String] {
    var urls: [String] = []
    for raw in rustLines(gitmodules) {
      let line = raw.trimmingUnicodeWhitespace()
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
      guard let equals = line.unicodeScalars.firstIndex(of: "=") else { continue }
      let key = String(line.unicodeScalars[..<equals]).trimmingUnicodeWhitespace()
      guard asciiLowercased(key) == "url" else { continue }
      var value = Substring(
        String(line.unicodeScalars[line.unicodeScalars.index(after: equals)...])
          .trimmingUnicodeWhitespace())
      while value.hasPrefix("\"") { value = value.dropFirst() }
      while value.hasSuffix("\"") { value = value.dropLast() }
      if !value.isEmpty { urls.append(String(value)) }
    }
    return urls
  }

  /// Resolve a submodule URL against its parent: `./x` is below the parent,
  /// each `../` walks up its `owner/repo` path. A walk past the owner (or
  /// deeper than eight levels) is unresolvable.
  static func resolve(_ raw: String, parent: RepoSlug) -> String? {
    if raw.isEmpty { return nil }
    if raw.hasPrefix("./") { return "https://github.com/\(parent)/\(raw.dropFirst(2))" }
    guard raw.hasPrefix("../") else { return raw }
    var up = 0
    var rest = Substring(raw)
    while rest.hasPrefix("../") {
      up += 1
      rest = rest.dropFirst(3)
      if up > 8 { return nil }
    }
    let segments = [parent.owner, parent.repo]
    guard up <= segments.count else { return nil }
    var kept = Array(segments[..<(segments.count - up)])
    if !rest.isEmpty { kept.append(String(rest)) }
    guard !kept.isEmpty else { return nil }
    return "https://github.com/" + kept.joined(separator: "/")
  }

  /// Classify submodule URLs against `parent`. A relative URL that does not
  /// resolve to `github.com/{owner}/{repo}` is dropped, not reported as
  /// non-GitHub.
  package static func classify(parent: RepoSlug, urls: [String], diagnostics: Diagnostics? = nil)
    -> SubmoduleDiscovery
  {
    var same = Set<RepoSlug>()
    var cross: [String: Set<RepoSlug>] = [:]
    var nonGitHub = Set<String>()
    for raw in urls {
      let trimmed = raw.trimmingUnicodeWhitespace()
      if trimmed.isEmpty { continue }
      let relative = trimmed.hasPrefix("./") || trimmed.hasPrefix("../")
      guard let resolved = resolve(trimmed, parent: parent) else {
        diagnostics?.debug("submodule url not resolvable, dropping: \(sanitizeForDisplay(raw))")
        continue
      }
      switch RepoSlug.parse(url: resolved) {
      case let slug? where slug == parent: break
      case let slug? where slug.owner == parent.owner: same.insert(slug)
      case let slug?: cross[slug.owner, default: []].insert(slug)
      case nil where relative:
        diagnostics?.debug(
          "joined relative submodule url doesn't match github.com/{owner}/{repo}, dropping: \(sanitizeForDisplay(resolved)) (from \(sanitizeForDisplay(raw)))"
        )
      case nil: nonGitHub.insert(resolved)
      }
    }
    var discovery = SubmoduleDiscovery()
    discovery.sameOwner = same.sorted()
    discovery.crossOwner = cross.keys.sorted(by: byteOrder).map { ($0, cross[$0]!.sorted()) }
    discovery.nonGitHubURLs = nonGitHub.sorted(by: byteOrder)
    return discovery
  }
}

func byteOrder(_ a: String, _ b: String) -> Bool {
  a.utf8.lexicographicallyPrecedes(b.utf8)
}

func asciiLowercased(_ text: String) -> String {
  String(
    String.UnicodeScalarView(
      text.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
}
