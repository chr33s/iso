// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopConfiguration
import CoopCore
import Foundation

/// A devcontainer file found in a repository before it is cloned.
public struct GitRepoDevcontainer: Sendable, Equatable {
  /// User-facing source, `github.com/<owner>/<repo>/.devcontainer/devcontainer.json`.
  public let displayPath: String
  public let contents: String
}

/// Best-effort `--git-repo` discovery: GitHub URLs only, one contents-API
/// request, no cache. The token reaches `curl` on stdin, never argv.
public struct GitRepoDevcontainerDiscovery: Sendable {
  /// `curl` bounds the request itself (`--max-time 15`).
  static let deadline: Duration = .seconds(60)

  let environment: [String: String]
  let runner: ProcessRunner
  let diagnostics: Diagnostics?

  public init(
    environment: [String: String], runner: ProcessRunner = ProcessRunner(),
    diagnostics: Diagnostics? = nil
  ) {
    self.environment = environment
    self.runner = runner
    self.diagnostics = diagnostics
  }

  /// Nil for non-GitHub URLs, a missing file, provider errors or rate
  /// limits, so the normal clone path still runs. Only a configured PAT
  /// that fails to resolve is an error.
  public func discover(_ repositoryURL: String, auth: GitHubAuth?) throws -> GitRepoDevcontainer? {
    guard let slug = RepoSlug.parse(url: repositoryURL) else { return nil }
    let url = Self.contentsURL(slug)
    let token = try discoveryToken(auth, slug)
    do {
      let (status, body) = try fetch(url, token: token)
      switch status {
      case 200: return GitRepoDevcontainer(displayPath: Self.displayPath(slug), contents: body)
      case 404: diagnostics?.debug("No remote devcontainer.json found for \(slug)")
      default:
        diagnostics?.debug(
          "GitHub devcontainer discovery for \(slug) returned HTTP \(status); skipping")
      }
    } catch {
      diagnostics?.debug("GitHub devcontainer discovery for \(slug) failed: \(oneLine(error))")
    }
    return nil
  }

  static func contentsURL(_ slug: RepoSlug) -> String {
    "https://api.github.com/repos/\(slug)/contents/\(Devcontainer.defaultRelativePath)"
  }

  static func displayPath(_ slug: RepoSlug) -> String {
    "github.com/\(slug)/\(Devcontainer.defaultRelativePath)"
  }

  func discoveryToken(_ auth: GitHubAuth?, _ slug: RepoSlug) throws -> String? {
    if case .pat(let pat)? = auth, let entry = pat.entries[slug] {
      let token: Secret<String>
      do {
        token = try CredentialResolver(runner: runner, environment: environment).resolve(entry)
      } catch {
        throw ContextError("Failed to resolve token for [github.pat.\"\(slug)\"]", cause: error)
      }
      return Self.normalize(token.expose())
    }
    return Self.selectHostToken(gh: ghAuthToken(), env: environment["GITHUB_TOKEN"])
  }

  static func selectHostToken(gh: String?, env: String?) -> String? {
    gh.flatMap(normalize) ?? env.flatMap(normalize)
  }

  static func normalize(_ token: String) -> String? {
    let trimmed = token.trimmingUnicodeWhitespace()
    return trimmed.isEmpty ? nil : trimmed
  }

  func ghAuthToken() -> String? {
    guard let gh = findExecutable("gh"),
      let output = try? runner.capture(
        .init(
          executable: gh, arguments: ["auth", "token"], environment: environment,
          deadline: Self.deadline)),
      output.termination == .exited(0),
      let text = String(validating: output.stdout, as: UTF8.self)
    else { return nil }
    return Self.normalize(text)
  }

  func fetch(_ url: String, token: String?) throws -> (Int, String) {
    guard let curl = findExecutable("curl") else {
      throw HostError("curl GET \(url) failed")
    }
    var arguments = [
      "-sSL", "--connect-timeout", "5", "--max-time", "15", "-H", "User-Agent: coop", "-H",
      "Accept: application/vnd.github.raw+json", "-w", "\n%{http_code}",
    ]
    var input: [UInt8]?
    if let token {
      arguments += ["-H", "@-"]
      input = Array("Authorization: token \(token)\n".utf8)
    }
    arguments.append(url)
    diagnostics?.debug("Running (capture): curl \(arguments.joined(separator: " "))")
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        .init(
          executable: curl, arguments: arguments, environment: environment,
          deadline: Self.deadline, outputLimit: 16 << 20, input: input))
    } catch {
      throw ContextError("curl GET \(url) failed", cause: HostError("\(error)"))
    }
    guard output.termination == .exited(0) else {
      throw ContextError(
        "curl GET \(url) failed",
        cause: HostError("curl exited with \(exitStatusText(output.termination))"))
    }
    guard let text = String(validating: output.stdout, as: UTF8.self) else {
      throw ContextError(
        "curl GET \(url) failed", cause: HostError("curl produced non-UTF-8 output"))
    }
    return try Self.statusAndBody(text)
  }

  /// `-w "\n%{http_code}"` puts the status on the last line.
  static func statusAndBody(_ output: String) throws -> (Int, String) {
    let body: String
    let statusText: String
    let scalars = output.unicodeScalars
    if let newline = scalars.lastIndex(of: "\n") {
      body = String(scalars[..<newline])
      statusText = String(scalars[scalars.index(after: newline)...])
    } else {
      body = ""
      statusText = output.trimmingUnicodeWhitespace()
    }
    guard let status = parseUnsigned(statusText.trimmingUnicodeWhitespace(), as: UInt16.self)
    else {
      throw HostError("Failed to parse HTTP status from curl output: '\(statusText)'")
    }
    return (Int(status), body)
  }

  func findExecutable(_ name: String) -> String? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    where !directory.isEmpty {
      let candidate = "\(directory)/\(name)"
      if access(candidate, X_OK) == 0 { return candidate }
    }
    return nil
  }
}
