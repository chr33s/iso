import Foundation
import IsoCore
import Testing

@testable import IsoConfiguration

private let ab = try! RepoSlug("a/b")

private func document(_ edit: GitHubConfigEdit?) throws -> JSONValue {
  let edit = try #require(edit)
  return try ConfigLoader.parse(edit.bytes, format: .json, path: "c", limits: .configuration)
}

private func pat(_ edit: GitHubConfigEdit?) throws -> PATConfig {
  let value = try document(edit)
  guard
    case .pat(let pat)? = try ConfigLoader.decode(value, path: "c", environment: fixtureHome)
      .github
  else {
    Issue.record("not PAT mode")
    return PATConfig(entries: [:], skip: [])
  }
  return pat
}

private func upsert(_ text: String?, _ repo: RepoSlug = ab, token: String = "cmd:echo x") throws
  -> GitHubConfigEdit?
{
  try ConfigEditor.upsertPAT(
    existing: text.map { Array($0.utf8) }, format: .jsonc, path: "c", repo: repo, token: token,
    environment: fixtureHome)
}

private func skip(_ text: String?, _ repo: RepoSlug = ab) throws -> GitHubConfigEdit? {
  try ConfigEditor.addSkipMarker(
    existing: text.map { Array($0.utf8) }, format: .jsonc, path: "c", repo: repo,
    environment: fixtureHome)
}

@Test func patUpsertCreatesAMissingDocument() throws {
  let edit = try upsert(nil, token: "cmd:cat ./t.txt")
  #expect(try pat(edit).entries[ab]?.expose() == "cmd:cat ./t.txt")
  #expect(try document(edit)["github"]?["mode"] == .string("pat"))
  #expect(edit?.holdsLiteralToken == false)
}

@Test func patUpsertPreservesOtherKeysAndUpgradesStringModes() throws {
  let edit = try upsert(#"{"ssh_port": 2222, "vm": {"vcpu_count": 4}, "github": "off"}"#)
  let value = try document(edit)
  #expect(value["ssh_port"] == .number(.integer(2222)))
  #expect(value["vm"]?["vcpu_count"] == .number(.integer(4)))
  #expect(try pat(edit).entries.keys.contains(ab))
  // Unmodeled members of `github` survive.
  let future = try upsert(#"{"github": {"mode": "pat", "pat": {}, "future": 1}}"#)
  #expect(try document(future)["github"]?["future"] == .number(.integer(1)))
  #expect(throws: ConfigError.self) {
    try upsert(#"{"github": {"mode": "pat", "pat": "garbage"}}"#)
  }
}

@Test func unchangedPATUpsertDoesNotRewrite() throws {
  let original = """
    // user comment
    {"github": {"mode": "pat", "pat": {"a/b": {"token": "cmd:echo x"}}}}
    """
  #expect(try upsert(original) == nil)
  #expect(try upsert(original, token: "cmd:echo y") != nil)
}

@Test func patUpsertClearsTheSkipMarkerForItsRepo() throws {
  let edit = try upsert(#"{"github": {"mode": "pat", "skip": ["a/b", "c/d"]}}"#)
  #expect(try pat(edit).skip == [try RepoSlug("c/d")])
  // Start at off, record skip, then set up: marker gone, entry present.
  let skipped = try skip(#"{"github": "off"}"#)
  let text = String(decoding: try #require(skipped).bytes, as: UTF8.self)
  let final = try pat(try upsert(text))
  #expect(final.skip.isEmpty)
  #expect(final.entries[ab] != nil)
}

@Test func patRemovalDropsOnlyTheNamedEntry() throws {
  let text =
    #"{"github": {"mode": "pat", "pat": {"a/b": {"token": "cmd:x"}, "c/d": {"token": "cmd:y"}}}}"#
  let edit = try ConfigEditor.removePAT(
    existing: Array(text.utf8), format: .jsonc, path: "c", repo: ab, environment: fixtureHome)
  let remaining = try pat(edit)
  #expect(remaining.entries[ab] == nil)
  #expect(remaining.entries[try RepoSlug("c/d")] != nil)
  // Nothing to remove: no rewrite, and no `github` member invented.
  #expect(
    try ConfigEditor.removePAT(
      existing: Array(#"{"ssh_port": 22}"#.utf8), format: .jsonc, path: "c", repo: ab,
      environment: fixtureHome) == nil)
}

@Test func skipMarkersAreIdempotentAndForcePATMode() throws {
  let once = try skip(nil)
  #expect(try pat(once).skip == [ab])
  let text = String(decoding: try #require(once).bytes, as: UTF8.self)
  #expect(try skip(text) == nil)
  // `off` would drop the list on reload; the marker must survive.
  #expect(try pat(try skip(#"{"github": "off"}"#)).skip == [ab])
  // A malformed `skip` fails validation, so the file is not edited at all.
  #expect(throws: ConfigError.self) { try skip(#"{"github": {"mode": "pat", "skip": "garbage"}}"#) }
}

@Test func literalTokensAreDetectedForTheFileMode() throws {
  #expect(try upsert(nil, token: "github_pat_literal")?.holdsLiteralToken == true)
  #expect(
    try upsert(#"{"github": {"pat": {"c/d": {"token": "github_pat_other"}}}}"#)?
      .holdsLiteralToken == true)
  #expect(ConfigEditor.holdsLiteralToken(.object(["ssh_port": .number(.integer(22))])) == false)
}

@Test func invalidDocumentsAreNotEdited() {
  #expect(throws: ConfigError.self) { try upsert(#"{"vm": {"vcpu_count": 2.0}}"#) }
  #expect(throws: ConfigError.self) { try upsert("[1]") }
}

@Test func githubReplacementKeepsOtherSettings() throws {
  let config = try ConfigLoader.load(
    bytes: #"{"ssh_port": 2200, "github": "auto"}"#, environment: fixtureHome)
  let replaced = config.replacingGitHub(.env)
  #expect(replaced.github == .env)
  #expect(replaced.sshPort == 2200)
  let disabled = config.disablingGitHub()
  #expect(disabled.github == .off)
  #expect(!disabled.setup.promptForPAT)
  #expect(disabled.sshPort == 2200)
}
