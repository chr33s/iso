// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore
import Foundation

/// `coop update`: fetch release metadata from the one channel, download the
/// platform archive and `SHA256SUMS`, verify the checksum and (with `gh`) the
/// Sigstore attestation, extract into a private temporary directory, then
/// replace the runtime, the proxy and finally this binary. Any failure before
/// a replacement leaves every installed binary untouched.
public struct Updater: Sendable {
  public struct Options: Sendable, Equatable {
    /// Probe the release but do not download or install.
    public var checkOnly = false
    /// Reinstall even if the target is not newer.
    public var force = false
    /// Install this version (with or without a leading `v`).
    public var pinnedVersion: String?
    /// Skip the confirmation prompt.
    public var skipConfirm = false

    public init(
      checkOnly: Bool = false, force: Bool = false, pinnedVersion: String? = nil,
      skipConfirm: Bool = false
    ) {
      self.checkOnly = checkOnly
      self.force = force
      self.pinnedVersion = pinnedVersion
      self.skipConfirm = skipConfirm
    }
  }

  public let environment: [String: String]
  public let home: String?
  public let build: CoopBuild
  /// The running binary (`_NSGetExecutablePath`, as Rust `current_exe`).
  public let currentExecutable: String?
  public let diagnostics: Diagnostics
  let runner: ProcessRunner
  let confirm: @Sendable (String) throws -> Bool
  let now: @Sendable () -> UInt64

  public init(
    environment: [String: String], home: String?, build: CoopBuild = .current,
    currentExecutable: String?, diagnostics: Diagnostics,
    confirm: @escaping @Sendable (String) throws -> Bool = Prompt.confirm,
    runner: ProcessRunner = ProcessRunner(),
    now: @escaping @Sendable () -> UInt64 = UpdateCheck.nowUnix
  ) {
    self.environment = environment
    self.home = home
    self.build = build
    self.currentExecutable = currentExecutable
    self.diagnostics = diagnostics
    self.confirm = confirm
    self.runner = runner
    self.now = now
  }

  var apiBaseOverridden: Bool { environment[UpdateChannel.apiBaseVariable] != nil }
  var apiBase: String { environment[UpdateChannel.apiBaseVariable] ?? UpdateChannel.defaultAPIBase }
  var tools: UpdateTools {
    UpdateTools(environment: environment, runner: runner, diagnostics: diagnostics)
  }

  // MARK: Main flow

  public func run(_ options: Options) throws {
    guard build.kind == .release else {
      throw HostError(
        "This is a dev build (\(build.versionString)); `coop update` only replaces release binaries.\nRe-run install.sh (or build from source) to replace a dev build."
      )
    }
    if apiBaseOverridden {
      diagnostics.warn(
        "\(UpdateChannel.apiBaseVariable) is set — attestation verification is DISABLED. This is a test-only mode; do not use with untrusted URLs."
      )
    }
    let triple = try UpdateChannel.targetTriple()
    let current: SemanticVersion
    do { current = try SemanticVersion(parsing: build.version) } catch {
      throw ContextError("Current version \(build.version) is not valid semver", cause: error)
    }
    let release =
      try options.pinnedVersion.map { try fetchByTag(UpdateChannel.normalizeTag($0)) }
      ?? fetchLatest()
    let target: SemanticVersion
    do { target = try SemanticVersion(parsing: UpdateChannel.stripV(release.tag)) } catch {
      throw ContextError("Release tag \(release.tag) is not valid semver", cause: error)
    }

    let newer = target > current
    if options.checkOnly {
      diagnostics.log(
        .info, newer ? "Update available: \(current) -> \(target)" : "Up to date: coop \(current)")
      return
    }
    if !newer && !options.force && options.pinnedVersion == nil {
      diagnostics.log(.info, "Already on latest: coop \(current)")
      return
    }
    if !options.skipConfirm, try !confirm("Update coop from \(current) to \(target)?") {
      diagnostics.log(.info, "Update cancelled")
      return
    }
    try performUpdate(release, triple: triple)
    diagnostics.log(.info, "coop updated to \(target)")
    UpdateCheck.persist(tag: release.tag, home: home, now: now(), diagnostics: diagnostics)
  }

  func performUpdate(_ release: Release, triple: String) throws {
    let work = try TemporaryDirectory(prefix: ".tmp")
    defer { work.remove() }
    let tarballName = UpdateChannel.assetName(tag: release.tag, triple: triple)
    guard let tarballAsset = release.asset(named: tarballName) else {
      throw HostError(
        "Release \(release.tag) has no asset \(tarballName); this platform may not be supported by that release."
      )
    }
    guard let sumsAsset = release.asset(named: UpdateChannel.checksumAsset) else {
      throw HostError("Release has no SHA256SUMS asset; refusing to install unverified binary")
    }
    let tarball = work.path + "/" + tarballName
    let sums = work.path + "/" + UpdateChannel.checksumAsset

    diagnostics.log(.info, "Downloading \(tarballName)")
    try downloadAsset(
      tag: release.tag, name: tarballName, url: tarballAsset.url, destination: tarball)
    try downloadAsset(
      tag: release.tag, name: UpdateChannel.checksumAsset, url: sumsAsset.url, destination: sums)

    let sumsText: String
    do { sumsText = try readUTF8(sums) } catch {
      throw ContextError("Failed to read \(sums)", cause: error)
    }
    guard let expected = Checksums.parse(sumsText, file: tarballName) else {
      throw HostError("\(tarballName) not listed in SHA256SUMS")
    }
    try Self.verifySHA256(tarball, expected: expected)

    let provenance = resolveProvenance(release, directory: work.path)
    try verifyAttestation(tarball, provenance)

    // `--no-same-owner --no-same-permissions` ignore embedded uid/mode;
    // `-C <tempdir>` plus bsdtar's default refusal of `..` and absolute
    // member paths keep extraction inside the private temporary directory.
    do {
      try tools.run(
        "tar",
        ["-xzf", tarball, "--no-same-owner", "--no-same-permissions", "-C", work.path])
    } catch {
      throw ContextError("Failed to extract release tarball", cause: error)
    }

    let extractDirectory =
      work.path + "/" + UpdateChannel.archiveDirectory(tag: release.tag, triple: triple)
    let extracted = extractDirectory + "/coop"
    guard pathExists(extracted) else {
      throw HostError("Extracted binary not found at \(extracted)")
    }
    // Companions first, from the same verified archive: a missing runtime or
    // proxy, or an unwritable sibling, aborts before `coop` is replaced.
    try SelfReplace.replaceSiblingRuntime(extractDirectory, currentExecutable: currentExecutable)
    try SelfReplace.replaceSiblingProxy(extractDirectory, currentExecutable: currentExecutable)
    guard let currentExecutable else {
      throw HostError("Failed to resolve current executable path")
    }
    try SelfReplace.atomicReplace(extracted, over: currentExecutable, diagnostics: diagnostics)
  }

  static func verifySHA256(_ path: String, expected: SHA256Hex) throws {
    let bytes: [UInt8]
    do { bytes = try readBytes(path) } catch {
      throw ContextError("Failed to read \(path) for checksum", cause: error)
    }
    let actual = Checksums.of(bytes)
    guard actual == expected else {
      throw HostError(
        "SHA-256 mismatch for \(path): expected \(expected.rawValue), got \(actual.rawValue)")
    }
  }

  // MARK: Metadata

  public func fetchLatest() throws -> Release {
    do { return try fetchReleaseMetadata("latest") } catch {
      throw ContextError("Failed to fetch latest release metadata", cause: error)
    }
  }

  func fetchByTag(_ tag: String) throws -> Release {
    do { return try fetchReleaseMetadata("tags/\(tag)") } catch {
      throw ContextError("Failed to fetch release metadata for \(tag)", cause: error)
    }
  }

  /// The latest release tag of another `owner/name` repository (Codex).
  public func latestReleaseTag(repository: String) throws -> String {
    do { return try fetchReleaseMetadata("latest", repository: repository).tag } catch {
      throw ContextError("Failed to fetch latest release metadata for \(repository)", cause: error)
    }
  }

  /// Strategy chosen per call so `GITHUB_TOKEN` / `gh auth` changes apply.
  func fetchReleaseMetadata(_ suffix: String, repository: String = UpdateChannel.repository)
    throws -> Release
  {
    let path = "repos/\(repository)/releases/\(suffix)"
    let body: String
    switch authStrategy() {
    case .gh:
      do {
        body = try tools.capture("gh", ["api", path, "-H", "Accept: application/vnd.github+json"])
      } catch { throw ContextError("gh api \(path) failed", cause: error) }
    case .curlBearer(let token):
      body = try curlCapture("\(apiBase)/\(path)", token: token)
    case .curlBare:
      body = try curlCapture("\(apiBase)/\(path)", token: nil)
    }
    return try Release.parse(body)
  }

  func authStrategy() -> AuthStrategy {
    let overridden = apiBaseOverridden
    let hasGh = !overridden && tools.exists("gh")
    let authed =
      hasGh && tools.statusOK("gh", ["auth", "status", "--hostname", "github.com"])
    return .select(
      apiBaseOverridden: overridden, hasGh: hasGh, ghAuthenticated: authed,
      token: environment["GITHUB_TOKEN"])
  }

  /// The token travels as a header on stdin (`-H @-`), never on argv.
  func curlCapture(_ url: String, token: String?) throws -> String {
    var arguments = ["-fsSL", "-H", "Accept: application/vnd.github+json"]
    if token != nil { arguments += ["-H", "@-"] }
    do {
      return try tools.capture(
        "curl", arguments + [url], input: token.map { Array("Authorization: token \($0)\n".utf8) })
    } catch { throw ContextError("curl GET \(url) failed", cause: error) }
  }

  // MARK: Downloads

  func downloadAsset(tag: String, name: String, url: String, destination: String) throws {
    switch authStrategy() {
    case .gh: try ghReleaseDownload(tag: tag, name: name, destination: destination)
    case .curlBearer(let token): try curlDownload(url, destination: destination, token: token)
    case .curlBare: try curlDownload(url, destination: destination, token: nil)
    }
  }

  func curlDownload(_ url: String, destination: String, token: String?) throws {
    var arguments = ["-fsSL"]
    if token != nil { arguments += ["-H", "@-"] }
    do {
      try tools.run(
        "curl", arguments + [url, "-o", destination],
        input: token.map { Array("Authorization: token \($0)\n".utf8) })
    } catch { throw ContextError("curl download from \(url) failed", cause: error) }
  }

  func ghReleaseDownload(tag: String, name: String, destination: String) throws {
    do {
      try tools.run(
        "gh",
        [
          "release", "download", tag, "--repo", UpdateChannel.repository, "--pattern", name,
          "--output", destination, "--clobber",
        ])
    } catch {
      throw ContextError(
        "gh release download \(tag) --pattern \(name) -> \(destination) failed", cause: error)
    }
  }

  // MARK: Attestation

  /// Never fails the update: bundle problems fall back to the attestations
  /// API (which then must succeed) or, without `gh`, to checksum-only.
  func resolveProvenance(_ release: Release, directory: String) -> Provenance {
    let bundle = UpdateChannel.bundleAsset
    let repository = UpdateChannel.repository
    let asset: Release.Asset
    switch BundleDecision.decide(
      release, apiOverridden: apiBaseOverridden, ghPresent: tools.exists("gh"))
    {
    case .testMode: return .testMode
    case .noGh: return .noGh
    case .noAsset:
      diagnostics.log(
        .info,
        "Release \(release.tag) publishes no \(bundle) — verifying the attestation through the GitHub API, for which `gh` needs a credential authorized for \(repository)."
      )
      return .api(.noAsset)
    case .fetch(let found): asset = found
    }
    let destination = directory + "/" + bundle
    // Deliberately bare curl: the bundle is a public asset, and attaching a
    // credential here is what `--bundle` exists to avoid.
    do { try curlDownload(asset.url, destination: destination, token: nil) } catch {
      diagnostics.warn(
        "Failed to download \(bundle) for release \(release.tag) (\(oneLine(error))) — verifying the attestation through the GitHub API, for which `gh` needs a credential authorized for \(repository)."
      )
      return .api(.downloadFailed)
    }
    var status = stat()
    guard stat(destination, &status) == 0, status.st_size > 0 else {
      diagnostics.warn(
        "\(bundle) for release \(release.tag) is empty — verifying the attestation through the GitHub API, for which `gh` needs a credential authorized for \(repository)."
      )
      return .api(.emptyBundle)
    }
    return .bundle(destination)
  }

  func verifyAttestation(_ tarball: String, _ provenance: Provenance) throws {
    switch provenance {
    case .testMode: return
    case .noGh:
      let repository = UpdateChannel.repository
      let bundle = UpdateChannel.bundleAsset
      diagnostics.log(
        .info,
        "Note: `gh` not installed — skipped cryptographic attestation verification. The download was verified against the published `SHA256SUMS` checksum, which is the same assurance level as most `curl | bash` installers. For end-to-end Sigstore verification, install `gh` (https://cli.github.com) and re-run, or verify manually: `gh attestation verify <tarball> --repo \(repository) --bundle \(bundle)` against the \(bundle) asset from the same release."
      )
      return
    case .api, .bundle: break
    }
    do {
      try tools.run(
        "gh", Provenance.verifyArguments(tarball: tarball, bundle: provenance.bundlePath))
    } catch {
      throw ContextError(
        "Attestation verification failed for \(tarball) — refusing to install\(provenance.apiFallbackHint)",
        cause: error)
    }
  }
}

/// Rust `io::Error` Display: `Permission denied (os error 13)`.
func rustIOError(_ code: Int32) -> String {
  "\(String(cString: strerror(code))) (os error \(code))"
}

/// Rust `Path::exists`: follows symlinks; a dangling link does not exist.
func pathExists(_ path: String) -> Bool {
  var status = stat()
  return stat(path, &status) == 0
}

/// Rust `Path::is_file`: a regular file after following symlinks.
func isRegularFile(_ path: String) -> Bool {
  var status = stat()
  return stat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
}

func readBytes(_ path: String) throws -> [UInt8] {
  let fd = open(path, O_RDONLY | O_CLOEXEC)
  guard fd >= 0 else { throw HostError(rustIOError(errno)) }
  defer { close(fd) }
  var bytes: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 64 << 10)
  while true {
    let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if count < 0 {
      if errno == EINTR { continue }
      throw HostError(rustIOError(errno))
    }
    if count == 0 { return bytes }
    bytes.append(contentsOf: chunk[0..<count])
  }
}

func readUTF8(_ path: String) throws -> String {
  guard let text = String(validating: try readBytes(path), as: UTF8.self) else {
    throw HostError("stream did not contain valid UTF-8")
  }
  return text
}

/// The external tools the updater runs, resolved on `PATH` like the Rust
/// `Command::new`. `run` inherits the terminal (Rust `Cmd::run`); `capture`
/// keeps stdout and discards stderr (Rust `Cmd::capture`).
struct UpdateTools: Sendable {
  let environment: [String: String]
  let runner: ProcessRunner
  let diagnostics: Diagnostics
  /// Metadata calls are bounded; release JSON is far below this.
  static let captureLimit = 16 << 20
  static let captureDeadline: Duration = .seconds(600)
  static let probeDeadline: Duration = .seconds(120)

  func which(_ name: String) -> String? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    where !directory.isEmpty {
      let candidate = "\(directory)/\(name)"
      if access(candidate, X_OK) == 0, isRegularFile(candidate) { return candidate }
    }
    return nil
  }

  func exists(_ name: String) -> Bool { which(name) != nil }

  static func describe(_ program: String, _ arguments: [String]) -> String {
    ([program] + arguments).joined(separator: " ")
  }

  private func resolve(_ program: String, _ describe: String) throws -> String {
    guard let path = which(program) else {
      throw ContextError("Failed to execute \(describe)", cause: HostError(rustIOError(ENOENT)))
    }
    return path
  }

  private func request(_ path: String, _ arguments: [String], input: [UInt8]?, deadline: Duration)
    -> ProcessRunner.Request
  {
    ProcessRunner.Request(
      executable: path, arguments: arguments, environment: environment, deadline: deadline,
      outputLimit: Self.captureLimit, input: input)
  }

  func run(_ program: String, _ arguments: [String], input: [UInt8]? = nil) throws {
    let describe = Self.describe(program, arguments)
    diagnostics.debug("Running: \(describe)")
    let path = try resolve(program, describe)
    let termination: ProcessRunner.Termination
    do {
      termination = try runner.attached(
        request(path, arguments, input: input, deadline: Self.captureDeadline),
        inheritStdin: input == nil)
    } catch {
      throw ContextError("Failed to execute \(describe)", cause: HostError("\(error)"))
    }
    guard termination.succeeded else { throw HostError("\(describe) exited with \(termination)") }
  }

  func capture(_ program: String, _ arguments: [String], input: [UInt8]? = nil) throws -> String {
    let describe = Self.describe(program, arguments)
    diagnostics.debug("Running (capture): \(describe)")
    let path = try resolve(program, describe)
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        request(path, arguments, input: input, deadline: Self.captureDeadline))
    } catch {
      throw ContextError("Failed to execute \(describe)", cause: HostError("\(error)"))
    }
    guard output.termination.succeeded else {
      throw HostError("\(describe) exited with \(output.termination)")
    }
    guard let text = String(validating: output.stdout, as: UTF8.self) else {
      throw HostError("\(describe) produced non-UTF-8 output")
    }
    return text
  }

  func statusOK(_ program: String, _ arguments: [String]) -> Bool {
    diagnostics.debug("Running (status_ok): \(Self.describe(program, arguments))")
    guard let path = which(program),
      let output = try? runner.capture(
        request(path, arguments, input: nil, deadline: Self.probeDeadline))
    else { return false }
    return output.termination.succeeded
  }
}

/// Staged, fsynced, same-directory `rename(2)` replacement of installed
/// binaries (safe over a running binary).
public enum SelfReplace {
  static let obsoleteProxyNames = ["coop-proxy-rs", "coop-proxy-swift"]
  static let proxyName = "coop-proxy"
  static let runtimeName = "coop-sandbox"

  static func join(_ directory: String, _ name: String) -> String {
    directory.isEmpty ? name : directory + "/" + name
  }

  static func parent(_ path: String) -> String? {
    guard !path.isEmpty, path != "/" else { return nil }
    return (path as NSString).deletingLastPathComponent
  }

  static func checkParentWritable(_ directory: String, diagnostics: Diagnostics) throws {
    let probe = join(directory, ".coop-update-probe-\(getpid())")
    let fd = open(probe, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
    guard fd >= 0 else {
      throw HostError(
        "Cannot write to \(directory): \(rustIOError(errno)).\nTry `sudo coop update` if coop is installed in a protected directory."
      )
    }
    close(fd)
    if unlink(probe) != 0 {
      diagnostics.debug("Failed to remove probe file \(probe): \(rustIOError(errno))")
    }
  }

  /// Copy `source` to a staging file beside `target`, chmod 0755, fsync,
  /// then rename it over `target`. The staging file is removed on failure.
  public static func atomicReplace(
    _ source: String, over target: String, diagnostics: Diagnostics = Diagnostics(verbosity: 0)
  ) throws {
    guard let directory = parent(target) else {
      throw HostError("Target executable has no parent directory")
    }
    try checkParentWritable(directory, diagnostics: diagnostics)
    let name = (target as NSString).lastPathComponent
    guard !name.isEmpty, name != "/" else { throw HostError("Target executable has no file name") }
    let staged = join(directory, ".\(name)-update-\(getpid())")
    var published = false
    defer { if !published { unlink(staged) } }
    do { try copyFile(source, to: staged) } catch {
      throw ContextError("Failed to stage update at \(staged)", cause: error)
    }
    guard chmod(staged, 0o755) == 0 else {
      throw ContextError(
        "Failed to chmod staged binary \(staged)", cause: HostError(rustIOError(errno)))
    }
    let fd = open(staged, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      throw ContextError(
        "Failed to reopen staged binary \(staged)", cause: HostError(rustIOError(errno)))
    }
    let synced = fsync(fd) == 0
    let syncError = errno
    close(fd)
    guard synced else {
      throw ContextError(
        "Failed to fsync staged binary \(staged)", cause: HostError(rustIOError(syncError)))
    }
    guard rename(staged, target) == 0 else {
      throw ContextError(
        "Failed to swap \(staged) over \(target)", cause: HostError(rustIOError(errno)))
    }
    published = true
  }

  /// `fs::copy`: follows a symlinked source; the destination is created
  /// fresh and never followed.
  static func copyFile(_ source: String, to destination: String) throws {
    let input = open(source, O_RDONLY | O_CLOEXEC)
    guard input >= 0 else { throw HostError(rustIOError(errno)) }
    defer { close(input) }
    unlink(destination)
    let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard output >= 0 else { throw HostError(rustIOError(errno)) }
    defer { close(output) }
    var chunk = [UInt8](repeating: 0, count: 256 << 10)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw HostError(rustIOError(errno))
      }
      if count == 0 { return }
      var offset = 0
      while offset < count {
        let written = chunk[offset..<count].withUnsafeBytes {
          write(output, $0.baseAddress, $0.count)
        }
        if written < 0 {
          if errno == EINTR { continue }
          throw HostError(rustIOError(errno))
        }
        offset += written
      }
    }
  }

  static func rejectObsoleteProxies(_ extractDirectory: String) throws {
    for obsolete in obsoleteProxyNames where pathExists(extractDirectory + "/" + obsolete) {
      throw HostError("Release contains an obsolete proxy transition artifact")
    }
  }

  static func installDirectory(_ currentExecutable: String?) throws -> String {
    guard let currentExecutable else {
      throw HostError("Failed to resolve current executable path")
    }
    guard let directory = parent(currentExecutable) else {
      throw HostError("Current executable has no parent directory")
    }
    return directory
  }

  /// Apple releases require their qualified runtime and the proxy beside
  /// the host; a missing companion is rejected before anything is replaced.
  public static func replaceSiblingRuntime(_ extractDirectory: String, currentExecutable: String?)
    throws
  {
    try rejectObsoleteProxies(extractDirectory)
    let runtime = extractDirectory + "/" + runtimeName
    guard isRegularFile(runtime) else {
      throw HostError("Release is missing the coop-sandbox runtime")
    }
    guard isRegularFile(extractDirectory + "/" + proxyName) else {
      throw HostError("Release is missing the coop-proxy companion")
    }
    let directory = try installDirectory(currentExecutable)
    try atomicReplace(runtime, over: join(directory, runtimeName))
  }

  /// Replace the proxy sibling from the same verified archive and remove
  /// stale transition names. A no-op for an archive without a proxy.
  public static func replaceSiblingProxy(_ extractDirectory: String, currentExecutable: String?)
    throws
  {
    try rejectObsoleteProxies(extractDirectory)
    let proxy = extractDirectory + "/" + proxyName
    guard !pathExists(proxy) || isRegularFile(proxy) else {
      throw HostError("Proxy artifact is not a regular file")
    }
    guard isRegularFile(proxy) else { return }
    let directory = try installDirectory(currentExecutable)
    try atomicReplace(proxy, over: join(directory, proxyName))
    for stale in obsoleteProxyNames where unlink(join(directory, stale)) != 0 && errno != ENOENT {
      throw ContextError("Failed to remove stale proxy", cause: HostError(rustIOError(errno)))
    }
  }
}
