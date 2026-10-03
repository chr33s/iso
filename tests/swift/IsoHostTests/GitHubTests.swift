import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

// MARK: - Fixtures

private func slug(_ text: String) -> RepoSlug { try! RepoSlug(text) }

private func config(_ json: String, home: String = "/nohome") throws -> IsoConfig {
  let value = try ConfigLoader.parse(
    Array(json.utf8), format: .jsonc, path: "c", limits: .configuration)
  return try ConfigLoader.decode(
    value, path: "c", environment: ConfigEnvironment(home: home, variables: [:]))
}

private final class Lines: Sendable {
  private let storage = Mutex<[String]>([])
  func append(_ line: String) { storage.withLock { $0.append(line) } }
  var all: [String] { storage.withLock { $0 } }
  var text: String { all.joined() }
}

/// Stub `curl`, `security`, `gh`, `git` and `open` in a private bin
/// directory. Every call appends its argv to `<tool>.argv`; `curl` also
/// records stdin and answers from `responses/<url>` (or `<url>@<token>`).
private final class OneUnlockSecrets: SecretReferenceResolver, @unchecked Sendable {
  var calls: [Set<SecretName>] = []
  let values: [String: String]
  private var cache: [SecretName: Secret<[UInt8]>] = [:]
  init(_ values: [String: String]) { self.values = values }

  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>] {
    let missing = names.subtracting(cache.keys)
    if !missing.isEmpty {
      calls.append(missing)
      var found: [SecretName: Secret<[UInt8]>] = [:]
      for name in missing {
        guard let value = values[name.rawValue] else { throw HostError("not found: \(name)") }
        found[name] = Secret(Array(value.utf8))
      }
      cache.merge(found) { $1 }
    }
    return cache.filter { names.contains($0.key) }
  }
}

private struct Stubs {
  let root: String
  var bin: String { root + "/bin" }

  init() throws {
    root =
      FileManager.default.temporaryDirectory.appending(
        path: "iso-github-\(UUID().uuidString)"
      ).path
    try FileManager.default.createDirectory(
      atPath: root + "/bin/responses", withIntermediateDirectories: true)
    let log = #"printf '%s\n' "$*" >> "$(dirname "$0")/$(basename "$0").argv""#
    try script(
      "curl",
      """
      dir=$(dirname "$0")
      \(log)
      for a; do last=$a; done
      input=""
      case " $* " in *" @- "*) input=$(cat) ;; esac
      printf '%s\\n' "$input" >> "$dir/curl.stdin"
      key=$(printf '%s' "$last" | tr '/:' '__')
      tag=$(printf '%s' "$input" | sed -n 's/^Authorization: token //p')
      if [ -n "$tag" ] && [ -f "$dir/responses/$key@$tag" ]; then cat "$dir/responses/$key@$tag"
      elif [ -f "$dir/responses/$key" ]; then cat "$dir/responses/$key"
      else printf '\\n404'; fi
      """)
    try script(
      "security",
      """
      \(log)
      if [ "$1" = find-generic-password ]; then cat "$(dirname "$0")/keychain-item" 2>/dev/null || exit 44; fi
      exit $(cat "$(dirname "$0")/security.exit" 2>/dev/null || echo 0)
      """)
    try script("gh", "\(log)\ncat \"$(dirname \"$0\")/gh.token\" 2>/dev/null || exit 1")
    try script(
      "git",
      "\(log)\nprintf '%s\\n' \"${GIT_DIR-unset}\" >> \"$(dirname \"$0\")/git.env\"\ncat \"$(dirname \"$0\")/git.origin\" 2>/dev/null || exit 2"
    )
    try script("open", log)
  }

  func script(_ name: String, _ body: String) throws {
    let path = bin + "/" + name
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
  }

  func write(_ text: String, _ name: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: bin + "/" + name))
  }

  /// `body` then curl's `\n<status>` trailer.
  func respond(_ url: String, _ status: Int, _ body: String = "", token: String? = nil) throws {
    let key = url.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    try write("\(body)\n\(status)", "responses/" + key + (token.map { "@" + $0 } ?? ""))
  }

  func calls(_ tool: String) -> [String] {
    guard let text = try? String(contentsOfFile: bin + "/\(tool).argv", encoding: .utf8) else {
      return []
    }
    return rustLines(text)
  }

  func read(_ name: String) -> String {
    (try? String(contentsOfFile: bin + "/" + name, encoding: .utf8)) ?? ""
  }

  var environment: [String: String] { ["PATH": bin + ":/usr/bin:/bin", "HOME": root] }

  func remove() { try? FileManager.default.removeItem(atPath: root) }
}

/// A scripted terminal: queued stdin lines, captured stderr.
private final class ScriptedConsole: Sendable {
  let input: Mutex<[String]>
  let output = Lines()
  let echo = Lines()

  init(_ lines: [String]) { input = Mutex(lines) }

  func console(tty: Bool = true) -> WizardConsole {
    WizardConsole(
      write: { self.output.append($0) },
      readLine: { self.input.withLock { $0.isEmpty ? nil : $0.removeFirst() + "\n" } },
      echoOff: {
        self.echo.append("off")
        return true
      }, echoOn: { self.echo.append("on") }, stdinIsTerminal: { tty })
  }
}

private func host(
  _ stubs: Stubs, console: ScriptedConsole = ScriptedConsole([]), logs: Lines = Lines(),
  tty: Bool = true, extra: [String: String] = [:], cwd: String? = nil,
  secrets: (any SecretReferenceResolver)? = nil
) -> GitHubHost {
  GitHubHost(
    environment: ConfigEnvironment(
      home: stubs.root, variables: stubs.environment.merging(extra) { $1 }),
    diagnostics: Diagnostics(verbosity: 2, sink: { logs.append($0) }),
    security: stubs.bin + "/security", console: console.console(tty: tty),
    workingDirectory: cwd, secrets: secrets)
}

private func instance(_ config: IsoConfig, _ name: String = "projects") throws -> Instance {
  let directory = config.instancesDirectory.appending(name).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  try Data(#"{"name":"\#(name)","index":0}"#.utf8).write(
    to: URL(fileURLWithPath: directory + "/instance.json"))
  return try InstanceStore.resolve(config, name: try InstanceName(name))
}

private func fileMode(_ path: String) -> mode_t {
  var status = stat()
  lstat(path, &status)
  return status.st_mode & 0o777
}

private let userURL = "https://api.github.com/user"
private let parentURL = "https://api.github.com/repos/acme/parent"
private let gitmodulesURL = parentURL + "/contents/.gitmodules"

private let assignmentConfig = #"""
  {"github": {"mode": "pat", "pat": {"org/assigned": {"token": "github_pat_assigned"}, "org/workspace": {"token": "github_pat_default"}}}}
  """#

/// Serialized: these tests spawn many stub processes, and running them all
/// at once would crowd the process-wide descriptor check in HostTests.
@Suite(.serialized) struct GitHubHostTests {

  // MARK: - Secret store (C-04)

  @Test func vaultPATNameIsTheEntryTheVMWillUse() throws {
    let directory = try scratchDirectory("vault-pat")
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let instance = try testInstance(directory + "/instance")
    let config = try testConfig(
      #""github": {"mode": "pat", "pat": {"org/a": {"token": "vault:tok-a"}, "org/b": {"token": "cmd:echo x"}, "org/c": {"token": "vault:tok-c"}}}"#
    )
    func name(_ repo: String?, disabled: Bool = false) throws -> String? {
      try GitHubAssignment.vaultName(
        config, instance: instance, repo: repo.map { try RepoSlug($0) }, githubDisabled: disabled
      )?.rawValue
    }
    #expect(try name("org/a") == "tok-a")
    #expect(try name("org/b") == nil)
    #expect(try name("org/none") == nil)
    #expect(try name(nil) == nil)
    // An assignment wins and never falls back to the workspace repo.
    try GitHubAssignment(repo: RepoSlug("org/c")).save(config, instance)
    #expect(try name("org/a") == "tok-c")
  }

  @Test func keychainReferencesRoundTripThroughTheirCommand() throws {
    let reference = KeychainReference(service: "iso-github-pat", account: "trailofbits-iso")
    #expect(
      reference.description
        == "cmd:security find-generic-password -s iso-github-pat -a trailofbits-iso -w")
    #expect(KeychainReference.parse(reference.description) == reference)
    // `cmd:` with leading space parses the same; other commands are opaque.
    #expect(
      KeychainReference.parse("cmd: security find-generic-password -s s -a a -w")
        == KeychainReference(service: "s", account: "a"))
    for opaque in [
      "cmd:op item get 'foo' --fields password --reveal", "cmd:cat ~/.iso/state/github-pat/x.txt",
      "cmd:secret-tool lookup service iso-github-pat account x", "cmd:echo opaque",
      "github_pat_literal", "cmd:security find-generic-password -s s -a a",
    ] {
      #expect(KeychainReference.parse(opaque) == nil, "\(opaque)")
    }
    let awkward = ["", "-w", "a b", "'", "a'b", "tab\there", "ünï", "--fields", "security"]
    for service in awkward {
      for account in awkward {
        let value = KeychainReference(service: service, account: account)
        #expect(KeychainReference.parse(value.description) == value)
      }
    }
  }

  @Test func shellQuotingIsOneWordAndSplitInvertsIt() {
    #expect(KeychainReference.quote("trailofbits-iso") == "trailofbits-iso")
    #expect(KeychainReference.quote("/tmp/foo.txt") == "/tmp/foo.txt")
    #expect(KeychainReference.quote("a b") == "'a b'")
    #expect(KeychainReference.quote("a'b") == "'a'\\''b'")
    #expect(KeychainReference.quote("") == "''")
    #expect(KeychainReference.split("a '' b") == ["a", "", "b"])
    #expect(KeychainReference.split("'a b' c") == ["a b", "c"])
    #expect(KeychainReference.split(#"'a'\''b'"#) == ["a'b"])
    #expect(KeychainReference.split("'unterminated") == nil)
    for _ in 0..<200 {
      let scalars = (0..<Int.random(in: 0...12)).map { _ in
        Unicode.Scalar(UInt32.random(in: 1...0x2FF)) ?? "x"
      }
      let text = String(String.UnicodeScalarView(scalars))
      #expect(
        KeychainReference.split(KeychainReference.quote(text)) == [text], "\(text.debugDescription)"
      )
    }
  }

  @Test func secretAccountsUseTheSafeClass() throws {
    #expect(SecretAccount(repo: slug("trailofbits/iso")).rawValue == "trailofbits-iso")
    #expect(SecretAccount(repo: slug("trail-of.bits_1/iso")).rawValue == "trail-of.bits_1-iso")
    #expect(throws: ValidationError.self) { try SecretAccount("") }
    for bad in ["a/b", "/a", "a b"] {
      #expect(throws: ValidationError.self) { try SecretAccount(bad) }
    }
  }

  @Test func keychainStoreUsesTheBaselineArgvAndNeverEchoesTheSecret() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let keychain = Keychain(security: stubs.bin + "/security", environment: stubs.environment)
    let reference = try keychain.store(
      service: "iso-github-pat", account: SecretAccount(repo: slug("o/r")),
      secret: Secret("github_pat_SYNTHETIC"))
    #expect(reference == KeychainReference(service: "iso-github-pat", account: "o-r"))
    #expect(
      stubs.calls("security")
        == ["add-generic-password -U -s iso-github-pat -a o-r -w github_pat_SYNTHETIC"])
    try stubs.write("36", "security.exit")
    do {
      _ = try keychain.store(
        service: "iso-github-pat", account: SecretAccount("o-r"),
        secret: Secret("github_pat_SYNTHETIC"))
      Issue.record("expected failure")
    } catch {
      let text = "\(error)"
      #expect(text.contains("Failed to write secret to macOS Keychain"))
      #expect(text.contains("-w <redacted> exited with exit status: 36"))
      #expect(!text.contains("SYNTHETIC"))
    }
    keychain.delete(service: "iso-github-pat", account: try SecretAccount("o-r"))
    #expect(stubs.calls("security").last == "delete-generic-password -s iso-github-pat -a o-r")
  }

  @Test func missingKeychainFailsWithoutFallback() throws {
    let keychain = Keychain(security: "/nonexistent/security", environment: [:])
    #expect(!keychain.isAvailable)
    #expect(throws: HostError.self) { try keychain.requireAvailable() }
  }

  // MARK: - HTTP helpers

  @Test func curlTrailerParsing() throws {
    #expect(try GitHubAPI.parseStatusAndBody("hello\n200") == (200, "hello"))
    #expect(try GitHubAPI.parseStatusAndBody("a\nb\n404") == (404, "a\nb"))
    #expect(try GitHubAPI.parseStatusAndBody("200") == (200, ""))
    #expect(throws: (any Error).self) { try GitHubAPI.parseStatusAndBody("body\nnotastatus") }
    do { _ = try GitHubAPI.parseStatusAndBody("body\nnotastatus") } catch {
      #expect("\(error)".contains("Failed to parse HTTP status from curl output: 'notastatus'"))
      #expect("\(error)".contains("invalid digit found in string"))
    }
  }

  @Test func userLoginParsing() throws {
    #expect(
      try GitHubAPI.parseUserLogin(status: 200, body: #"{"login":"octocat","id":1}"#) == "octocat")
    #expect(throws: HostError("Token authentication failed: /user returned unexpected response")) {
      try GitHubAPI.parseUserLogin(status: 200, body: #"{"id":1}"#)
    }
    #expect(throws: HostError("GET /user returned HTTP 401 (token may be invalid or revoked)")) {
      try GitHubAPI.parseUserLogin(status: 401, body: #"{"login":"octocat"}"#)
    }
  }

  @Test func repoProbeStatusesMapToDistinctFailures() {
    let repo = slug("trailofbits/iso")
    #expect(GitHubProbeError.classify(200, repo: repo) == nil)
    #expect(GitHubProbeError.classify(403, repo: repo) == .orgPolicyBlock(repo))
    #expect(GitHubProbeError.orgPolicyBlock(repo).description.contains("fine-grained PAT policy"))
    #expect(GitHubProbeError.classify(404, repo: repo) == .notFound(repo))
    #expect(GitHubProbeError.notFound(repo).description.contains("Check the repo slug"))
    #expect(GitHubProbeError.classify(500, repo: repo) == .unexpected(repo, status: 500))
    #expect(GitHubProbeError.unexpected(repo, status: 500).description.contains("HTTP 500"))
  }

  @Test func tokensReachCurlOnStdinOnly() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    try stubs.respond("https://api.github.com/user", 200, #"{"login":"octocat"}"#)
    let api = GitHubAPI(
      tools: HostTools(environment: stubs.environment), diagnostics: Diagnostics(verbosity: 0))
    #expect(try api.userLogin(token: Secret("github_pat_SYNTHETIC")) == "octocat")
    #expect(
      stubs.read("curl.argv")
        == "-sSL -H Accept: application/vnd.github+json -H @- -w \n%{http_code} https://api.github.com/user\n"
    )
    #expect(stubs.read("curl.stdin") == "Authorization: token github_pat_SYNTHETIC\n")
    // Anonymous requests carry no Authorization header.
    #expect(!api.isPublic(slug("o/private")))
    #expect(
      stubs.read("curl.argv").hasSuffix(
        "-sSL -H Accept: application/vnd.github+json -w \n%{http_code} https://api.github.com/repos/o/private\n"
      ))
    #expect(!stubs.read("curl.argv").contains("SYNTHETIC"))
  }

  // MARK: - Submodules

  @Test func gitmodulesURLsAreExtracted() {
    let body = """
      # top-level comment
      ; another comment

      [submodule "a"]
          path = vendor/a
          url = https://github.com/owner/a
      [submodule "b"]
          URL = "../b"\r
          url =
      """
    #expect(SubmoduleDiscovery.extractURLs(body) == ["https://github.com/owner/a", "../b"])
  }

  @Test func submodulesAreClassifiedAgainstTheParent() {
    let parent = slug("acme/parent")
    let d = SubmoduleDiscovery.classify(
      parent: parent,
      urls: [
        "https://github.com/acme/lib-b", "https://github.com/acme/lib-a",
        "https://github.com/acme/lib-a.git", "git@github.com:acme/lib-a.git",
        "git@github.com:third-party/foo.git", "https://github.com/other/bar",
        "https://github.com/acme/parent.git", "https://gitlab.com/acme/lib-a",
        "https://internal.example.com/x/y", "../sibling", "../../other/repo", "../../../too-far",
        "./extra/foo", "",
      ])
    #expect(d.sameOwner == [slug("acme/lib-a"), slug("acme/lib-b"), slug("acme/sibling")])
    #expect(d.crossOwner.map(\.owner) == ["other", "third-party"])
    #expect(
      d.crossOwner.map(\.repos) == [
        [slug("other/bar"), slug("other/repo")], [slug("third-party/foo")],
      ])
    #expect(
      d.nonGitHubURLs == ["https://gitlab.com/acme/lib-a", "https://internal.example.com/x/y"])
    #expect(
      SubmoduleDiscovery.classify(parent: parent, urls: ["../../../too-far", "./a/b", ""]).isEmpty)
  }

  @Test func publicSubmodulesAreDroppedFromBothBuckets() {
    var d = SubmoduleDiscovery.classify(
      parent: slug("acme/parent"),
      urls: [
        "https://github.com/acme/private-lib", "https://github.com/acme/public-lib",
        "https://github.com/other/public-thing", "https://github.com/another/keep-private",
      ])
    let dropped = d.dropPublic { $0.repo.hasPrefix("public") }
    #expect(dropped == [slug("acme/public-lib"), slug("other/public-thing")])
    #expect(d.sameOwner == [slug("acme/private-lib")])
    #expect(d.crossOwner.map(\.owner) == ["another"])
    #expect(d.dropPublic { _ in false }.isEmpty)
    #expect(SubmoduleDiscovery().isEmpty)
  }

  @Test func formInstructionsListSubmodulesBeforeThePastePrompt() {
    let parent = slug("acme/parent")
    let plain = GitHubHost.formInstructions(parent, nil)
    #expect(plain.contains("Only select repositories → acme/parent"))
    #expect(plain.contains("  Token name:        iso-acme-parent\n"))
    #expect(!plain.contains("only depth-1"))
    #expect(GitHubHost.formInstructions(parent, SubmoduleDiscovery()) == plain)

    var d = SubmoduleDiscovery()
    d.sameOwner = [slug("acme/lib-a")]
    d.crossOwner = [("other", [slug("other/dep")])]
    d.nonGitHubURLs = ["https://gitlab.com/x/y"]
    let text = GitHubHost.formInstructions(parent, d)
    #expect(text.contains("Only select repositories:\n                       - acme/parent\n"))
    #expect(text.contains("                       - acme/lib-a\n"))
    let paste = text.range(of: "Click \"Generate token\"")!.lowerBound
    #expect(text.range(of: "iso github setup-pat --repo other/dep")!.lowerBound < paste)
    #expect(text.range(of: "https://gitlab.com/x/y")!.lowerBound < paste)
    #expect(text.contains("only depth-1 submodules were checked"))
  }

  // MARK: - Token selection

  @Test func guestTokenFollowsTheConfiguredMode() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let logs = Lines()
    func tokens(_ extra: [String: String] = [:]) -> GitHubTokens {
      GitHubTokens(
        environment: stubs.environment.merging(extra) { $1 },
        diagnostics: Diagnostics(verbosity: 0, sink: { logs.append($0) }))
    }
    let repo = slug("owner/repo")
    #expect(try tokens(["GITHUB_TOKEN": "env-token"]).guestToken(nil, repo: repo) == nil)
    #expect(try tokens(["GITHUB_TOKEN": "env-token"]).guestToken(.off, repo: repo) == nil)
    #expect(
      try tokens(["GITHUB_TOKEN": "env-token"]).guestToken(.auto, repo: nil)?.expose()
        == "env-token")
    try stubs.write("  gh-token\n", "gh.token")
    #expect(try tokens(["GITHUB_TOKEN": ""]).guestToken(.auto, repo: nil)?.expose() == "gh-token")
    #expect(try tokens().guestToken(.env, repo: nil) == nil)
    #expect(logs.text.contains("github: \"env\" requires GITHUB_TOKEN to be set"))

    let pat = try config(
      #"{"github": {"pat": {"owner/repo": {"token": "cmd:printf github_pat_SYNTH"}, "owner/bad": {"token": "cmd:exit 42"}, "owner/classic": {"token": "ghp_classic"}}}}"#
    ).github
    #expect(try tokens().guestToken(pat, repo: nil) == nil)
    #expect(logs.text.contains("requires a resolvable repo"))
    #expect(try tokens().guestToken(pat, repo: slug("owner/none")) == nil)
    #expect(logs.text.contains("github setup-pat --repo owner/none"))
    #expect(try tokens().guestToken(pat, repo: repo)?.expose() == "github_pat_SYNTH")
    #expect(try tokens().guestToken(pat, repo: slug("owner/classic"))?.expose() == "ghp_classic")
    #expect(logs.text.contains("did not start with 'github_pat_'"))
    do {
      _ = try tokens().guestToken(pat, repo: slug("owner/bad"))
      Issue.record("expected failure")
    } catch {
      #expect("\(error)".contains("Failed to resolve token for [github.pat.\"owner/bad\"]"))
    }
    #expect(throws: HostError(missingPATEntryError(repo))) {
      try tokens().patToken(.auto, repo: repo)
    }
    #expect(!logs.text.contains("SYNTH"))
  }

  @Test func hostTokenSelectionPrefersGhAndTrims() {
    #expect(GitHubTokens.selectHostToken(gh: "gh-token", env: "env-token") == "gh-token")
    #expect(GitHubTokens.selectHostToken(gh: nil, env: "env-token") == "env-token")
    #expect(GitHubTokens.selectHostToken(gh: "   \n", env: "env-token") == "env-token")
    #expect(GitHubTokens.selectHostToken(gh: "  gh-token\n", env: nil) == "gh-token")
    #expect(GitHubTokens.selectHostToken(gh: nil, env: "\tenv-token  ") == "env-token")
    #expect(GitHubTokens.selectHostToken(gh: nil, env: nil) == nil)
    #expect(GitHubTokens.selectHostToken(gh: " ", env: "\n") == nil)
  }

  @Test func cloneTokensHonourAssignmentThenPATThenHost() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let tokens = GitHubTokens(
      environment: stubs.environment.merging(["GITHUB_TOKEN": "host-token"]) { $1 },
      diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))
    let url = "https://github.com/owner/repo.git"
    let auth = try config(
      #"{"github": {"pat": {"owner/repo": {"token": "github_pat_default"}, "owner/assigned": {"token": "github_pat_selected"}, "owner/failed": {"token": "cmd:exit 42"}}}}"#
    ).github
    #expect(GitHubTokens.clonePATSlug(auth, url: url) == slug("owner/repo"))
    #expect(GitHubTokens.clonePATSlug(auth, url: "https://gitlab.com/owner/repo") == nil)
    for mode in [nil, GitHubAuth.auto, .env, .off] {
      #expect(GitHubTokens.clonePATSlug(mode, url: url) == nil)
    }
    #expect(try tokens.cloneToken(auth, url: url, assigned: nil)?.expose() == "github_pat_default")
    #expect(
      try tokens.cloneToken(auth, url: url, assigned: slug("owner/assigned"))?.expose()
        == "github_pat_selected")
    #expect(throws: (any Error).self) {
      try tokens.cloneToken(auth, url: url, assigned: slug("owner/missing"))
    }
    #expect(throws: (any Error).self) {
      try tokens.cloneToken(auth, url: url, assigned: slug("owner/failed"))
    }
    #expect(
      try tokens.cloneToken(auth, url: "https://github.com/else/where", assigned: nil)?.expose()
        == "host-token")
  }

  @Test func cloneScriptReadsTheTokenFromStdinAndEscapesTheURL() {
    let script = GitHubGuest.cloneWithTokenScript("https://github.com/owner/repo.git").rendered
    #expect(script.hasPrefix("set -eu\nIFS= read -r GH_TOKEN\nexport GH_TOKEN\n"))
    #expect(
      script.contains(
        "credential.helper='!f() { echo username=x-access-token; echo \"password=$GH_TOKEN\"; }; f'"
      ))
    #expect(script.contains(" clone 'https://github.com/owner/repo.git' /workspace\n"))
    #expect(
      GitHubGuest.cloneWithTokenScript("https://github.com/o'wner/repo").rendered.contains(
        "'https://github.com/o'\\''wner/repo'"))
  }

  // MARK: - VM assignment

  @Test func assignmentsStoreOnlyTheEntryKey() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let cfg = try config(#"{"data_dir": "\#(stubs.root)/data", "# + assignmentConfig.dropFirst())
    let inst = try instance(cfg)
    #expect(try GitHubAssignment.load(inst) == nil)
    #expect(throws: HostError.self) {
      try GitHubAssignment(repo: slug("org/missing")).save(cfg, inst)
    }
    #expect(try GitHubAssignment.load(inst) == nil)
    try GitHubAssignment(repo: slug("org/assigned")).save(cfg, inst)
    let path = inst.directory + "/github_pat.json"
    #expect(
      try canonicalJSON(String(contentsOfFile: path, encoding: .utf8))
        == canonicalJSON(#"{"repo":"org/assigned"}"#))
    #expect(fileMode(path) == 0o600)
    #expect(
      try GitHubAssignment.active(cfg, inst, githubDisabled: false)?.repo == slug("org/assigned"))
    // A rotated entry is used immediately: only the key is stored.
    let tokens = GitHubTokens(
      environment: stubs.environment, diagnostics: Diagnostics(verbosity: 0))
    #expect(
      try tokens.patToken(cfg.github, repo: slug("org/assigned")).expose() == "github_pat_assigned")
    try GitHubAssignment.remove(inst)
    try GitHubAssignment.remove(inst)
    #expect(try GitHubAssignment.load(inst) == nil)
    #expect(cfg.github?.patEntry(slug("org/assigned")) != nil)
  }

  @Test func assignmentsFailClosedExceptWhenGitHubIsDisabled() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let cfg = try config(#"{"data_dir": "\#(stubs.root)/data", "# + assignmentConfig.dropFirst())
    let inst = try instance(cfg)
    let path = inst.directory + "/github_pat.json"
    try GitHubAssignment(repo: slug("org/assigned")).save(cfg, inst)
    let without = cfg.replacingGitHub(try config(#"{"github": "pat"}"#).github)
    #expect(throws: HostError.self) {
      try GitHubAssignment.active(without, inst, githubDisabled: false)
    }
    #expect(
      try GitHubAssignment.active(without.disablingGitHub(), inst, githubDisabled: true) == nil)
    for state in [
      "null", "{}", "{", #"{"repo":"bad"}"#, #"{"repo":"org/assigned","token":"unexpected"}"#,
    ] {
      try Data(state.utf8).write(to: URL(fileURLWithPath: path))
      #expect(try GitHubAssignment.active(cfg, inst, githubDisabled: true) == nil)
      do {
        _ = try GitHubAssignment.active(cfg, inst, githubDisabled: false)
        Issue.record("accepted \(state)")
      } catch {
        #expect("\(error)".contains("Invalid github_pat.json"), "\(state)")
      }
    }
  }

  @Test func assignmentStateIOErrorsAreNotAbsence() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let cfg = try config(#"{"data_dir": "\#(stubs.root)/data", "# + assignmentConfig.dropFirst())
    let inst = try instance(cfg)
    let path = inst.directory + "/github_pat.json"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try GitHubAssignment.load(inst) }
    #expect(throws: (any Error).self) { try GitHubAssignment.remove(inst) }
    #expect(throws: (any Error).self) {
      try GitHubAssignment.active(cfg, inst, githubDisabled: false)
    }
    try FileManager.default.removeItem(atPath: path)
    let target = inst.directory + "/valid-assignment.json"
    try Data(#"{"repo":"org/assigned"}"#.utf8).write(to: URL(fileURLWithPath: target))
    symlink(target, path)
    #expect(throws: (any Error).self) { try GitHubAssignment.load(inst) }
    try GitHubAssignment.remove(inst)
    #expect(FileManager.default.fileExists(atPath: target), "removal unlinks, never the target")
    let file = Instance(
      name: inst.name, index: inst.index, directory: target + "/child", image: inst.image)
    #expect(throws: (any Error).self) { try GitHubAssignment.load(file) }
  }

  @Test func assignmentsRejectEveryManagedOverrideSource() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    for name in ["GITHUB_TOKEN", "GH_TOKEN"] {
      let sources = [
        #""guest_env": {"\#(name)": "not-printed"}"#,
        #""claude": {"env_forward": ["\#(name)"]}"#,
        #""codex": {"env_forward": ["\#(name)"]}"#,
        nil,
      ]
      for source in sources {
        let body = assignmentConfig.dropFirst().dropLast()
        let cfg = try config(
          #"{"data_dir": "\#(stubs.root)/data-\#(name)", "# + body
            + (source.map { ", " + $0 } ?? "") + "}")
        let inst = try instance(cfg)
        try GitHubAssignment(repo: slug("org/assigned")).save(cfg, inst)
        if source == nil {
          try Data(
            #"{"version":2,"entries":{"\#(name)":{"kind":"literal","value":"not-printed"}}}"#.utf8
          ).write(
            to: URL(fileURLWithPath: inst.guestEnvironmentStatePath))
        }
        do {
          _ = try GitHubAssignment.active(cfg, inst, githubDisabled: false)
          Issue.record("accepted \(name) from \(source ?? "guest_env.json")")
        } catch {
          #expect("\(error)".contains(name))
          #expect(!"\(error)".contains("not-printed"))
        }
        try GitHubAssignment.remove(inst)
        #expect(try GitHubAssignment.active(cfg, inst, githubDisabled: false) == nil)
        try? FileManager.default.removeItem(atPath: inst.guestEnvironmentStatePath)
      }
    }
    try GitHubAssignment.rejectOverrides(["GH_TOKEN_OTHER", "OTHER_GITHUB_TOKEN", "NORMAL"])
  }

  // MARK: - Instance repository

  @Test func instanceRepoComesFromWorkspaceState() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let cfg = try config(#"{"data_dir": "\#(stubs.root)/data"}"#)
    let inst = try instance(cfg)
    let logs = Lines()
    let tools = HostTools(environment: stubs.environment.merging(["GIT_DIR": "/elsewhere"]) { $1 })
    let diagnostics = Diagnostics(verbosity: 0, sink: { logs.append($0) })
    #expect(inst.detectRepo(tools: tools, diagnostics: diagnostics) == nil)

    let state = URL(fileURLWithPath: inst.workspaceStatePath)
    try Data(#"{"host_path":"/x","guest_path":"/workspace","source":"mount"}"#.utf8).write(
      to: state)
    #expect(inst.detectRepo(tools: tools, diagnostics: diagnostics) == nil)
    #expect(logs.text.contains("Could not read workspace state for 'projects'"))
    #expect(logs.text.contains("pat-mode tokens will not be forwarded"))
    #expect(logs.text.contains("pre-#147"))

    try Data(
      #"{"guest_path":"/workspace","source":{"kind":"git_repo","url":"https://github.com/a/b.git"}}"#
        .utf8
    ).write(to: state)
    #expect(inst.detectRepo(tools: tools, diagnostics: diagnostics) == slug("a/b"))

    try Data(
      #"{"guest_path":"/workspace","source":{"kind":"workspace","host_path":"\#(stubs.root)"}}"#
        .utf8
    ).write(to: state)
    #expect(inst.detectRepo(tools: tools, diagnostics: diagnostics) == nil)
    try stubs.write("git@github.com:org/repo.git\n", "git.origin")
    #expect(inst.detectRepo(tools: tools, diagnostics: diagnostics) == slug("org/repo"))
    #expect(stubs.calls("git").last == "-C \(stubs.root) remote get-url origin")
    // A hook's GIT_DIR must not redirect the lookup.
    #expect(stubs.read("git.env").hasSuffix("unset\n"))

    try Data(
      #"{"guest_path":"relative","source":{"kind":"git_repo","url":"https://github.com/a/b"}}"#.utf8
    ).write(to: state)
    #expect(inst.detectRepo(tools: tools, diagnostics: diagnostics) == nil)
  }

  // MARK: - Status

  @Test func statusProbeUnlocksTheSecretStoreOnceForVaultEntries() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let cfg = try config(
      #"{"data_dir": "\#(stubs.root)/data", "github": {"mode": "pat", "pat": {"org/a": {"token": "vault:one"}, "org/b": {"token": "vault:two"}}}}"#
    )
    let secrets = OneUnlockSecrets(["one": "github_pat_1", "two": "classic"])
    var view = try host(stubs, secrets: secrets).status(cfg, probe: true, instance: nil)
    #expect(secrets.calls.count == 1)
    #expect(view.entries.map(\.probe) == [.ok, .unexpectedFormat])

    // Without --probe nothing is resolved.
    let quiet = OneUnlockSecrets(["one": "github_pat_1", "two": "classic"])
    view = try host(stubs, secrets: quiet).status(cfg, probe: false, instance: nil)
    #expect(quiet.calls.isEmpty)

    // A failed batch (one name missing) still reports each entry.
    let partial = OneUnlockSecrets(["one": "github_pat_1"])
    view = try host(stubs, secrets: partial).status(cfg, probe: true, instance: nil)
    #expect(view.entries.map(\.probe) == [.ok, .resolveFailed])
  }

  @Test func statusReportsEntriesWithoutTokens() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let cfg = try config(
      #"{"data_dir": "\#(stubs.root)/data", "github": {"mode": "pat", "skip": ["z/skip"], "pat": {"org/entry": {"token": "github_pat_never_print"}, "org/kc": {"token": "cmd:security find-generic-password -s iso-github-pat -a org-kc -w"}}}}"#
    )
    let inst = try instance(cfg)
    let github = host(stubs)
    var view = try github.status(cfg, probe: false, instance: nil)
    #expect(
      view.text()
        == "github mode: pat\nentries (2):\n  org/entry\n    storage: unknown\n  org/kc\n    storage: macOS Keychain\nskip (1):\n  z/skip\n"
    )
    #expect(
      try canonicalJSON(JSONOutput.render(view))
        == canonicalJSON(
          """
          {
            "mode": "pat",
            "entries": [
              {
                "repo": "org/entry",
                "storage": null,
                "probe": null
              },
              {
                "repo": "org/kc",
                "storage": "macos_keychain",
                "probe": null
              }
            ],
            "skip": [
              "z/skip"
            ]
          }

          """))

    try stubs.write("github_pat_SYNTH", "keychain-item")
    view = try github.status(cfg, probe: true, instance: nil)
    #expect(view.entries.map(\.probe) == [.ok, .ok])
    #expect(view.text().contains("    status:  resolves, format ok\n"))

    try GitHubAssignment(repo: slug("org/entry")).save(cfg, inst)
    view = try github.status(cfg, probe: false, instance: inst)
    #expect(view.text().hasPrefix("VM projects: selection Assignment; assigned entry: org/entry\n"))
    let vm = try #require(try jsonObject(JSONOutput.render(view))["vm"] as? [String: String])
    #expect(vm == ["name": "projects", "assigned_entry": "org/entry", "source": "assignment"])
    #expect(try !JSONOutput.render(view).contains("never_print"))

    let off = cfg.replacingGitHub(nil)
    view = try github.status(off, probe: false, instance: inst)
    #expect(view.vm?.source == .missingAssignment)
    #expect(view.text().contains("unassign-pat --vm projects"))
    #expect(view.text().hasSuffix("github mode: off (no PAT entries)\n"))
    try GitHubAssignment.remove(inst)
    #expect(try github.status(off, probe: false, instance: inst).vm?.source == .off)
    for (auth, source) in [
      (GitHubAuth.auto, GitHubStatusView.SelectionSource.auto), (.env, .env),
      (try config(#"{"github": "pat"}"#).github!, .noMatchingEntry),
    ] {
      #expect(
        try github.status(cfg.replacingGitHub(auth), probe: false, instance: inst).vm?.source
          == source)
    }
    #expect(
      GitHubStatusView.SelectionSource.of(cfg, assignment: nil, repo: slug("org/kc")) == .repository
    )
  }

  @Test func statusShapesForEmptyAndSkipOnlyConfigurations() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let github = host(stubs)
    #expect(
      try github.status(config(#"{"github": {"mode": "pat"}}"#), probe: false, instance: nil).text()
        == "github mode: pat (no entries)\n")
    let skipOnly = try github.status(
      config(#"{"github": {"mode": "pat", "skip": ["a/b"]}}"#), probe: false, instance: nil)
    #expect(skipOnly.text() == "github mode: pat\nentries (0):\nskip (1):\n  a/b\n")
    let off = try github.status(config(#"{"github": "off"}"#), probe: false, instance: nil)
    #expect(
      try canonicalJSON(JSONOutput.render(off))
        == canonicalJSON("{\n  \"mode\": \"off\",\n  \"entries\": [],\n  \"skip\": []\n}\n"))
    let probe = try github.status(
      config(#"{"github": {"pat": {"a/b": {"token": "cmd:exit 3"}, "c/d": {"token": "ghp_x"}}}}"#),
      probe: true, instance: nil)
    #expect(probe.entries.map(\.probe) == [.resolveFailed, .unexpectedFormat])
    let entries = try #require(
      try jsonObject(JSONOutput.render(probe))["entries"] as? [[String: Any]])
    #expect(entries.map { $0["probe"] as? String } == ["resolve_failed", "unexpected_format"])
  }

  // MARK: - Wizard

  @Test func setupPATValidatesStoresInTheKeychainAndWritesTheReference() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    try stubs.respond(userURL, 200, #"{"login":"octocat"}"#)
    try stubs.respond(parentURL, 200, "{}")
    let path = stubs.root + "/config.jsonc"
    try Data(#"{"ssh_port": 2222, "github": {"mode": "pat", "skip": ["acme/parent"]}} // c"#.utf8)
      .write(to: URL(fileURLWithPath: path))
    let console = ScriptedConsole(["  github_pat_SYNTHETIC  "])
    let github = host(stubs, console: console)
    let cfg = try config(#"{"github": {"mode": "pat", "skip": ["acme/parent"]}}"#)
    try github.setupPAT(
      cfg, target: ConfigTarget(path: path, format: .jsonc), repo: slug("acme/parent"))

    let written = try ConfigLoader.load(.file(path: path, format: .jsonc), environment: .empty)
    let reference = "cmd:security find-generic-password -s iso-github-pat -a acme-parent -w"
    #expect(written.github?.patEntry(slug("acme/parent"))?.expose() == reference)
    guard case .pat(let pat)? = written.github else { throw HostError("mode") }
    #expect(pat.skip.isEmpty)
    #expect(written.sshPort == 2222)
    #expect(fileMode(path) == 0o644)
    #expect(
      stubs.calls("security")
        == ["add-generic-password -U -s iso-github-pat -a acme-parent -w github_pat_SYNTHETIC"])
    #expect(stubs.calls("open") == ["https://github.com/settings/personal-access-tokens/new"])
    #expect(console.echo.all == ["off", "on"])
    let out = console.output.text
    #expect(
      out.contains(
        "Paste token: \n\nValidating token against api.github.com…\n  ✓ /user\n  ✓ /repos/acme/parent\n"
      ))
    #expect(
      out.contains(
        "\nWrote \(path):\n  github.mode = \"pat\"\n  [github.pat.\"acme/parent\"]\n  token = \"\(reference)\"\n"
      ))
    #expect(
      out.hasSuffix("\nDone. VM startups for https://github.com/acme/parent will use this token.\n")
    )
    #expect(!out.contains("SYNTHETIC"))
    #expect(!stubs.read("curl.argv").contains("SYNTHETIC"))
    // Rotating the same repo produces the same reference: no rewrite.
    var edited = Data("// keep\n".utf8)
    edited.append(try Data(contentsOf: URL(fileURLWithPath: path)))
    try edited.write(to: URL(fileURLWithPath: path))
    try host(stubs, console: ScriptedConsole(["github_pat_ROTATED"])).rotatePAT(
      written, target: ConfigTarget(path: path, format: .jsonc), repo: slug("acme/parent"))
    #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("// keep\n"))
  }

  @Test func setupPATFailsBeforePromptingWithoutAKeychain() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let console = ScriptedConsole(["github_pat_SYNTHETIC"])
    let github = GitHubHost(
      environment: ConfigEnvironment(home: stubs.root, variables: stubs.environment),
      diagnostics: Diagnostics(verbosity: 0, sink: { _ in }), security: stubs.root + "/missing",
      console: console.console(), workingDirectory: nil)
    let path = stubs.root + "/config.jsonc"
    #expect(throws: HostError.self) {
      try github.setupPAT(
        config("{}"), target: ConfigTarget(path: path, format: .jsonc), repo: slug("acme/parent"))
    }
    #expect(!console.output.text.contains("Paste token"))
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(stubs.calls("curl").isEmpty)
  }

  @Test func setupPATRejectsBadTokensAndReportsProbeFailures() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let target = ConfigTarget(path: stubs.root + "/config.jsonc", format: .jsonc)
    #expect(throws: HostError("No token entered")) {
      try host(stubs, console: ScriptedConsole(["   "])).setupPAT(
        config("{}"), target: target, repo: slug("acme/parent"))
    }
    try stubs.respond(userURL, 401)
    #expect(throws: HostError("GET /user returned HTTP 401 (token may be invalid or revoked)")) {
      try host(stubs, console: ScriptedConsole(["github_pat_x"])).setupPAT(
        config("{}"), target: target, repo: slug("acme/parent"))
    }
    try stubs.respond(userURL, 200, #"{"login":"o"}"#)
    try stubs.respond(parentURL, 403)
    let console = ScriptedConsole(["ghp_classic"])
    #expect(throws: GitHubProbeError.orgPolicyBlock(slug("acme/parent"))) {
      try host(stubs, console: console).setupPAT(
        config("{}"), target: target, repo: slug("acme/parent"))
    }
    #expect(console.output.text.contains("warning: token does not start with 'github_pat_'"))
    #expect(stubs.calls("security").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }

  @Test func setupPATDetectsTheRepoFromTheWorkingTree() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let github = host(stubs, cwd: stubs.root)
    #expect(throws: HostError.self) { try github.targetRepo(nil) }
    try stubs.write("https://github.com/acme/parent.git\n", "git.origin")
    #expect(try github.targetRepo(nil) == slug("acme/parent"))
    #expect(try github.targetRepo(slug("x/y")) == slug("x/y"))
  }

  @Test func uncoveredSameOwnerSubmodulesAskForAWidenedToken() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    try stubs.respond(userURL, 200, #"{"login":"o"}"#)
    try stubs.respond(parentURL, 200)
    // No gh token and a rate-limited anonymous prefetch: discovery falls to
    // the pasted token.
    try stubs.respond(gitmodulesURL, 403)
    try stubs.respond(
      gitmodulesURL, 200,
      "[submodule \"a\"]\n url = ../lib\n[submodule \"b\"]\n url = https://github.com/other/dep\n[submodule \"c\"]\n url = https://gitlab.com/x/y",
      token: "github_pat_narrow")
    try stubs.respond("https://api.github.com/repos/acme/lib", 404, token: "github_pat_narrow")
    try stubs.respond("https://api.github.com/repos/acme/lib", 200, token: "github_pat_wide")
    let console = ScriptedConsole(["github_pat_narrow", "github_pat_wide"])
    let path = stubs.root + "/config.jsonc"
    try host(stubs, console: console).setupPAT(
      config("{}"), target: ConfigTarget(path: path, format: .jsonc), repo: slug("acme/parent"))
    let out = console.output.text
    #expect(
      out.contains(
        "\nIgnoring non-GitHub submodule URLs (this token can't cover them):\n  - https://gitlab.com/x/y\n"
      ))
    #expect(
      out.contains(
        "\n1 submodule repo(s) under 'acme' are not covered by this token:\n  - acme/lib\n"))
    #expect(out.contains("\nValidating widened token against api.github.com…\n"))
    #expect(out.contains("  ✓ all same-owner submodule repos covered\n"))
    #expect(out.contains("    iso github setup-pat --repo other/dep\n"))
    #expect(out.contains("only depth-1 submodules were checked"))
    #expect(stubs.calls("security").last?.hasSuffix("-w github_pat_wide") == true)
  }

  @Test func forgetPATDeletesOnlyTheKeychainItemIsoWrote() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let path = stubs.root + "/config.jsonc"
    let text = #"""
      {"github": {"mode": "pat", "pat": {
        "acme/kc": {"token": "cmd:security find-generic-password -s iso-github-pat -a acme-kc -w"},
        "acme/op": {"token": "cmd:op item get 'acme' --fields password --reveal"},
        "acme/file": {"token": "cmd:cat \#(stubs.root)/github-pat/acme-file.txt"}}}}
      """#
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    let secretFile = stubs.root + "/github-pat/acme-file.txt"
    try FileManager.default.createDirectory(
      atPath: stubs.root + "/github-pat", withIntermediateDirectories: true)
    try Data("github_pat_FILE\n".utf8).write(to: URL(fileURLWithPath: secretFile))
    let target = ConfigTarget(path: path, format: .jsonc)
    let logs = Lines()
    let console = ScriptedConsole([])
    let github = host(stubs, console: console, logs: logs)
    var cfg = try ConfigLoader.load(.file(path: path, format: .jsonc), environment: .empty)
    try github.forgetPAT(cfg, target: target, repo: slug("acme/kc"))
    #expect(stubs.calls("security") == ["delete-generic-password -s iso-github-pat -a acme-kc"])
    #expect(console.output.text.hasPrefix("Removed PAT entry for acme/kc.\nnote: the token itself"))
    for repo in ["acme/op", "acme/file"] {
      cfg = try ConfigLoader.load(.file(path: path, format: .jsonc), environment: .empty)
      try github.forgetPAT(cfg, target: target, repo: slug(repo))
    }
    #expect(stubs.calls("security").count == 1)
    #expect(logs.text.contains("Storage backend not recognised"))
    #expect(
      FileManager.default.fileExists(atPath: secretFile), "opaque references are never deleted")
    cfg = try ConfigLoader.load(.file(path: path, format: .jsonc), environment: .empty)
    guard case .pat(let pat)? = cfg.github else { throw HostError("mode") }
    #expect(pat.entries.isEmpty)
    #expect(throws: HostError.self) {
      try github.forgetPAT(cfg, target: target, repo: slug("acme/kc"))
    }
  }

  @Test func rotateNotesAMissingEntry() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let console = ScriptedConsole([])
    #expect(throws: HostError("No token entered")) {
      try host(stubs, console: console).rotatePAT(
        config("{}"), target: ConfigTarget(path: stubs.root + "/c.jsonc", format: .jsonc),
        repo: slug("a/b"))
    }
    #expect(
      console.output.text.hasPrefix(
        "note: no existing PAT entry for 'a/b' — proceeding as if this were a fresh setup.\n"))
  }

  // MARK: - Start-time prompt

  @Test func promptDecisionMatchesTheBaseline() throws {
    let repo = slug("a/b")
    func decide(
      _ json: String, repo: RepoSlug? = slug("a/b"), tty: Bool = true, ci: Bool = false,
      noPrompt: Bool = false
    ) throws -> PATPromptDecision {
      PATPromptDecision.resolve(
        try config(json), repo: repo, isTerminal: tty, isCI: ci, noPrompt: noPrompt)
    }
    #expect(try decide("{}", repo: nil) == .skip)
    #expect(try decide("{}", tty: false) == .skip)
    #expect(try decide("{}", ci: true) == .skip)
    #expect(try decide("{}", noPrompt: true) == .skip)
    #expect(try decide("{}") == .prompt)
    #expect(try decide(#"{"github": "off"}"#) == .prompt)
    #expect(try decide(#"{"github": "pat"}"#) == .prompt)
    #expect(try decide(#"{"github": {"pat": {"a/b": {"token": "cmd:echo x"}}}}"#) == .skip)
    #expect(try decide(#"{"github": {"mode": "pat", "skip": ["a/b"]}}"#) == .skip)
    #expect(try decide(#"{"github": "auto"}"#) == .skip)
    #expect(try decide(#"{"github": "env"}"#) == .skip)
    #expect(try decide(#"{"github": "off", "setup": {"prompt_for_pat": false}}"#) == .skip)
    // `--no-github` disables the prompt as well as forwarding.
    #expect(
      PATPromptDecision.resolve(
        try config(#"{"github": "auto"}"#).disablingGitHub(), repo: repo, isTerminal: true,
        isCI: false, noPrompt: false) == .skip)
  }

  @Test func promptNeverRecordsASkipMarkerAndReloadsGitHubOnly() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let path = stubs.root + "/config.jsonc"
    try Data(#"{"github": "off"}"#.utf8).write(to: URL(fileURLWithPath: path))
    let console = ScriptedConsole(["NEVER"])
    let logs = Lines()
    let cfg = try config(#"{"github": "off"}"#).overridingVM(
      vcpus: 7, memory: nil, templateSize: nil)
    let updated = try host(stubs, console: console, logs: logs).maybePrompt(
      cfg, target: ConfigTarget(path: path, format: .jsonc), repo: slug("a/b"), noPrompt: false)
    #expect(updated.github == (try config(#"{"github": {"skip": ["a/b"]}}"#).github))
    #expect(updated.vm.vcpuCount == 7)
    #expect(
      console.output.text
        == "\nNo GitHub credential is configured for a/b (github = \"off\").\nPushes and private-repo operations from the guest will fail.\n\nSet up a scoped fine-grained PAT now? [y/N/never] "
    )
    #expect(logs.text.contains("recorded skip marker for a/b"))
    // Anything else continues unchanged.
    let declined = try host(stubs, console: ScriptedConsole([""]), logs: logs).maybePrompt(
      cfg, target: ConfigTarget(path: path, format: .jsonc), repo: slug("c/d"), noPrompt: false)
    #expect(declined.github == .off)
    #expect(logs.text.contains("continuing without GitHub auth for c/d"))
  }

  @Test func nonInteractiveStartsGetATipInstead() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    let logs = Lines()
    let console = ScriptedConsole([])
    let cfg = try config("{}")
    let result = try host(stubs, console: console, logs: logs, tty: false).maybePrompt(
      cfg, target: ConfigTarget(path: stubs.root + "/c.jsonc", format: .jsonc), repo: slug("a/b"),
      noPrompt: false)
    #expect(result == cfg)
    #expect(console.output.all.isEmpty)
    #expect(logs.text.contains("tip: run 'iso github setup-pat --repo a/b'"))
  }

  @Test func failedWizardExplainsAndAsksBeforeContinuing() throws {
    let stubs = try Stubs()
    defer { stubs.remove() }
    try stubs.respond(userURL, 200, #"{"login":"o"}"#)
    try stubs.respond(parentURL, 404)
    let target = ConfigTarget(path: stubs.root + "/c.jsonc", format: .jsonc)
    try Data("{}".utf8).write(to: URL(fileURLWithPath: target.path))
    let logs = Lines()
    let yes = ScriptedConsole(["y", "github_pat_x", "yes"])
    let cfg = try config("{}")
    #expect(
      try host(stubs, console: yes, logs: logs).maybePrompt(
        cfg, target: target, repo: slug("acme/parent"), noPrompt: false) == cfg)
    #expect(yes.output.text.contains("'acme/parent' wasn't found with this token."))
    #expect(yes.output.text.hasSuffix("continue without GitHub auth? [y/N] "))
    #expect(logs.text.contains("PAT setup failed (GET /repos/acme/parent returned 404."))
    let no = ScriptedConsole(["y", "github_pat_x", "n"])
    #expect(throws: GitHubProbeError.notFound(slug("acme/parent"))) {
      try host(stubs, console: no).maybePrompt(
        cfg, target: target, repo: slug("acme/parent"), noPrompt: false)
    }
  }
}
