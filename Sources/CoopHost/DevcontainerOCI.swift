// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore
import CryptoKit
import Foundation

/// A devcontainer Feature published under `ghcr.io/devcontainers/features/*`,
/// resolved at setup time. Registry responses and archives are untrusted:
/// they reach processes only as argv elements or files, never a shell.
public struct FeatureRequest: Sendable, Equatable {
  public let rawID: String
  public let reference: OCIReference
  /// Option values rendered as strings, ordered by key bytes.
  public let options: [(key: String, value: String)]

  public static func == (a: Self, b: Self) -> Bool {
    a.rawID == b.rawID && a.reference == b.reference
      && a.options.map(\.key) == b.options.map(\.key)
      && a.options.map(\.value) == b.options.map(\.value)
  }

  static let registryHost = "ghcr.io"
  static let supportedPrefix = "devcontainers/features/"
  static let shapeMessage = "expected ghcr.io/devcontainers/features/<name>[:tag|@digest]"

  /// Nil when the id is not a supported registry reference.
  public static func parse(rawID: String, options: DevcontainerJSON) throws -> FeatureRequest? {
    guard let reference = try parseReference(rawID) else { return nil }
    return FeatureRequest(rawID: rawID, reference: reference, options: try parseOptions(options))
  }

  static func parseReference(_ rawID: String) throws -> OCIReference? {
    var rest = Substring(rawID)
    if rest.hasPrefix("oci://") {
      rest = rest.dropFirst(6)
    } else if rest.hasPrefix("https://") {
      rest = rest.dropFirst(8)
    }
    guard rest.hasPrefix("ghcr.io/") else { return nil }
    rest = rest.dropFirst(8)
    guard rest.hasPrefix(supportedPrefix) else { return nil }
    rest = rest.dropFirst(supportedPrefix.count)
    let name: Substring
    let reference: OCIReference.Ref
    if let at = rest.firstIndex(of: "@") {
      name = rest[..<at]
      do {
        reference = .digest(try OCIDigest(String(rest[rest.index(after: at)...])))
      } catch {
        throw ContextError("invalid feature digest in \(debugQuoted(rawID))", cause: error)
      }
    } else if let colon = rest.lastIndex(of: ":") {
      let tag = rest[rest.index(after: colon)...]
      guard !tag.isEmpty else { throw HostError(shapeMessage) }
      name = rest[..<colon]
      reference = .tag(String(tag))
    } else {
      name = rest
      reference = .tag("latest")
    }
    guard !name.isEmpty else { throw HostError(shapeMessage) }
    guard name.unicodeScalars.allSatisfy(isFeatureNameCharacter) else {
      throw HostError("feature name contains unsupported characters")
    }
    return OCIReference(
      host: registryHost, repository: supportedPrefix + name, reference: reference)
  }

  static func parseOptions(_ raw: DevcontainerJSON) throws -> [(key: String, value: String)] {
    guard case .object(let members) = raw.value else {
      throw HostError("expected feature options object")
    }
    var out: [(key: String, value: String)] = []
    for (key, value) in mergedMembers(members) {
      guard key.unicodeScalars.allSatisfy(isFeatureNameCharacter) else {
        throw HostError("feature option \(debugQuoted(key)) contains unsupported characters")
      }
      let rendered: String
      switch value.value {
      case .bool, .unsigned, .negative, .float: rendered = value.rendered
      case .string(let text): rendered = text
      case .null: rendered = ""
      default:
        throw HostError(
          "feature option \(debugQuoted(key)) must be a string, number, boolean, or null")
      }
      out.append((key, rendered))
    }
    return sortedMembers(out)
  }
}

private func isFeatureNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
  scalar.isASCII
    && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
      || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_" || scalar == ".")
}

public struct OCIReference: Sendable, Equatable {
  /// A mutable `:tag` or an immutable `@sha256:` digest.
  public enum Ref: Sendable, Equatable, CustomStringConvertible {
    case tag(String)
    case digest(OCIDigest)

    public var description: String {
      switch self {
      case .tag(let tag): tag
      case .digest(let digest): "sha256:" + digest.hash.rawValue
      }
    }
  }

  public let host: String
  public let repository: String
  public let reference: Ref

  public var canonical: String { "\(host)/\(repository)/\(reference)" }
}

public struct ResolvedFeature: Sendable, Equatable {
  public let installed: InstalledFeature
  public let installScript: String
  public let archive: [UInt8]
  public let options: [(key: String, value: String)]

  public static func == (a: Self, b: Self) -> Bool {
    a.installed == b.installed && a.installScript == b.installScript && a.archive == b.archive
      && a.options.map(\.key) == b.options.map(\.key)
      && a.options.map(\.value) == b.options.map(\.value)
  }

  /// Provisioning-script fragment that unpacks the archive embedded as
  /// base64 and runs its `install.sh` with the options exported.
  public var installSnippet: String {
    var out = "\necho '  [guest] Installing devcontainer Feature "
    out += shellSingleQuote(installed.reference) + "'\n"
    out += "(\n"
    out += "feature_dir=$(mktemp -d)\n"
    out += "trap 'rm -rf \"$feature_dir\"' EXIT\n"
    out += "archive=\"$feature_dir/feature.tgz\"\n"
    let delimiter = "COOP_FEATURE_ARCHIVE_\(installed.installScriptHash.rawValue.prefix(16))"
    out += "base64 -d > \"$archive\" <<'\(delimiter)'\n"
    out += Data(archive).base64EncodedString() + "\n"
    out += delimiter + "\n"
    out += "tar -xzf \"$archive\" -C \"$feature_dir\"\n"
    out += "chmod +x \"$feature_dir/install.sh\"\n"
    out += "export _REMOTE_USER=\"$GUEST_USER\"\n"
    out += "export _REMOTE_USER_HOME=\"/home/$GUEST_USER\"\n"
    for (key, value) in options {
      out += "export \(optionEnvironmentName(key))=\(shellSingleQuote(value))\n"
    }
    out += "cd \"$feature_dir\"\n"
    out += "./install.sh\n"
    out += ")\n"
    return out
  }
}

func optionEnvironmentName(_ key: String) -> String {
  String(
    key.map { character -> Character in
      guard character.isASCII, character.isLetter || character.isNumber else { return "_" }
      return Character(character.uppercased())
    })
}

func shellSingleQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Registry resolution

/// Resolves Feature requests against GHCR with `curl` and unpacks layers
/// with `tar`, both found on `PATH` as the baseline did. URLs and argv
/// match the baseline exactly; nothing here uses a shell.
public struct FeatureResolver: Sendable {
  static let manifestAccept =
    "application/vnd.oci.image.manifest.v1+json,application/vnd.oci.artifact.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
  /// The baseline set no deadline; this only bounds a hung transfer.
  static let deadline: Duration = .seconds(1800)

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

  /// One result per request, in order.
  public func resolve(_ requests: [FeatureRequest]) -> [Result<ResolvedFeature, any Error>] {
    requests.map { request in Result { try resolve(request) } }
  }

  func resolve(_ request: FeatureRequest) throws -> ResolvedFeature {
    let token = try fetchToken(request.reference)
    let (manifest, digest) = try fetchManifest(request.reference, token: token)
    let metadata = manifest.metadata
    let blob = try manifest.featureBlob()
    let directory: TemporaryDirectory
    do { directory = try TemporaryDirectory(prefix: "coop-feature-") } catch {
      throw ContextError("Failed to create feature extraction directory", cause: error)
    }
    defer { directory.remove() }
    let blobPath = directory.path + "/feature.tgz"
    try downloadBlob(request.reference, digest: blob.digest, token: token, output: blobPath)
    return try resolvedFeature(
      request, manifestDigest: digest, metadata: metadata, blobPath: blobPath)
  }

  func resolvedFeature(
    _ request: FeatureRequest, manifestDigest: String, metadata: OCIManifest.FeatureMetadata?,
    blobPath: String
  ) throws -> ResolvedFeature {
    let id = metadata?.id ?? metadata?.name ?? request.rawID
    let archive = try Self.readBounded(blobPath, limit: Self.layerLimit, what: "feature layer")
    let directory: TemporaryDirectory
    do { directory = try TemporaryDirectory(prefix: "coop-feature-check-") } catch {
      throw ContextError("Failed to create feature validation directory", cause: error)
    }
    defer { directory.remove() }
    let extracted = directory.path + "/feature"
    guard mkdir(extracted, 0o700) == 0 else {
      throw ContextError(
        "Failed to create feature extraction target", cause: HostError(ioErrorText(errno)))
    }
    do {
      try run("tar", ["-xzf", blobPath, "-C", extracted])
    } catch {
      throw ContextError("Failed to extract devcontainer feature layer", cause: error)
    }
    let installPath = extracted + "/install.sh"
    guard FileManager.default.fileExists(atPath: extracted + "/devcontainer-feature.json") else {
      throw HostError("feature layer does not contain devcontainer-feature.json")
    }
    // Layer content is untrusted: a symlinked or special `install.sh` could
    // read a host file or never end.
    guard
      let script = String(
        validating: try Self.readBounded(
          installPath, limit: Self.installScriptLimit, what: "feature install.sh"),
        as: UTF8.self)
    else { throw HostError("feature install.sh is not valid UTF-8") }
    guard !script.trimmingUnicodeWhitespace().isEmpty else {
      throw HostError("feature install.sh is empty")
    }
    let digest: OCIDigest
    do { digest = try OCIDigest(manifestDigest) } catch {
      throw ContextError(
        "registry returned unexpected manifest digest \(debugQuoted(manifestDigest))",
        cause: error)
    }
    let hash = try SHA256Hex(
      SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined())
    return ResolvedFeature(
      installed: InstalledFeature(
        id: id, reference: request.rawID, digest: digest, installScriptHash: hash),
      installScript: script, archive: Array(archive), options: request.options)
  }

  func fetchToken(_ reference: OCIReference) throws -> String {
    let url =
      "https://\(FeatureRequest.registryHost)/token?scope=repository:\(reference.repository):pull&service=\(FeatureRequest.registryHost)"
    let body: String
    do { body = try capture("curl", ["-fsSL", url]) } catch {
      throw ContextError("Failed to fetch GHCR registry token", cause: error)
    }
    struct TokenResponse: Decodable { let token: String }
    do {
      return try JSONDecoder().decode(TokenResponse.self, from: Data(body.utf8)).token
    } catch {
      throw ContextError("Failed to parse token JSON", cause: error)
    }
  }

  func fetchManifest(_ reference: OCIReference, token: String) throws -> (OCIManifest, String) {
    let url =
      "https://\(FeatureRequest.registryHost)/v2/\(reference.repository)/manifests/\(reference.reference)"
    let directory: TemporaryDirectory
    do { directory = try TemporaryDirectory(prefix: "coop-manifest-") } catch {
      throw ContextError("Failed to create manifest download directory", cause: error)
    }
    defer { directory.remove() }
    let headersPath = directory.path + "/headers"
    let bodyPath = directory.path + "/manifest.json"
    do {
      try run(
        "curl",
        [
          "-fsSL", "-D", headersPath, "-o", bodyPath, "-H", "Accept: \(Self.manifestAccept)",
          "-H", "Authorization: Bearer \(token)", url,
        ], redacted: [7, 8])
    } catch {
      throw ContextError(
        "Failed to fetch feature manifest for \(reference.canonical)", cause: error)
    }
    let headers = try readUTF8File(headersPath)
    let body = try Self.readBounded(bodyPath, limit: Self.manifestLimit, what: "feature manifest")
    // The manifest is identified by the digest of its bytes: a `@sha256:`
    // pin must match it, and so must any digest the registry claims.
    let computed = "sha256:" + sha256Hex(body)
    if case .digest(let pin) = reference.reference, "sha256:" + pin.hash.rawValue != computed {
      throw HostError(
        "feature manifest for \(reference.canonical) does not match its pinned digest (got \(computed))"
      )
    }
    if let claimed = Self.contentDigest(headers), claimed != computed {
      throw HostError(
        "registry digest \(debugQuoted(sanitizeForDisplay(claimed))) for \(reference.canonical) does not match the manifest received (\(computed))"
      )
    }
    let manifest: OCIManifest
    do { manifest = try JSONDecoder().decode(OCIManifest.self, from: Data(body)) } catch {
      throw ContextError("Failed to parse OCI manifest", cause: error)
    }
    return (manifest, computed)
  }

  func downloadBlob(_ reference: OCIReference, digest: String, token: String, output: String)
    throws
  {
    // Validated before it becomes part of a URL, and checked after download.
    let expected: OCIDigest
    do { expected = try OCIDigest(digest) } catch {
      throw ContextError(
        "registry returned an invalid layer digest \(debugQuoted(sanitizeForDisplay(digest)))",
        cause: error)
    }
    let url =
      "https://\(FeatureRequest.registryHost)/v2/\(reference.repository)/blobs/sha256:\(expected.hash.rawValue)"
    do {
      try run(
        "curl", ["-fsSL", "-H", "Authorization: Bearer \(token)", url, "-o", output],
        redacted: [1, 2])
    } catch {
      throw ContextError("Failed to download feature layer \(digest)", cause: error)
    }
    let bytes = try Self.readBounded(output, limit: Self.layerLimit, what: "feature layer")
    guard sha256Hex(bytes) == expected.hash.rawValue else {
      unlink(output)
      throw HostError("feature layer \(digest) does not match its digest; refusing to use it")
    }
  }

  static let manifestLimit = 1 << 20
  static let layerLimit = 64 << 20
  static let installScriptLimit = 1 << 20

  /// A regular file (never followed through a symlink, never a FIFO or
  /// device) of at most `limit` bytes.
  static func readBounded(_ path: String, limit: Int, what: String) throws -> [UInt8] {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      throw ContextError("Failed to read \(what) \(path)", cause: HostError(ioErrorText(errno)))
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw HostError("\(what) \(path) is not a regular file")
    }
    guard status.st_size <= limit else {
      throw HostError("\(what) \(path) is larger than \(limit) bytes")
    }
    var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        throw ContextError("Failed to read \(what) \(path)", cause: HostError(ioErrorText(errno)))
      }
      if count == 0 { break }
      offset += count
    }
    return Array(bytes[..<offset])
  }

  /// The last `Docker-Content-Digest` header, if any.
  static func contentDigest(_ headers: String) -> String? {
    for line in rustLines(headers).reversed() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      if line[..<colon].lowercased() == "docker-content-digest" {
        return String(line[line.index(after: colon)...]).trimmingUnicodeWhitespace()
      }
    }
    return nil
  }

  // MARK: Processes

  func executable(_ name: String) throws -> String {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    where !directory.isEmpty {
      let candidate = "\(directory)/\(name)"
      if access(candidate, X_OK) == 0 { return candidate }
    }
    throw HostError("\(name): No such file or directory (os error 2)")
  }

  static func describe(_ name: String, _ arguments: [String], redacted: Set<Int>) -> String {
    ([name]
      + arguments.enumerated().map { redacted.contains($0.offset) ? "<redacted>" : $0.element })
      .joined(separator: " ")
  }

  /// Rust `Cmd::run`: stdout and stderr stay the caller's.
  func run(_ name: String, _ arguments: [String], redacted: Set<Int> = []) throws {
    let description = Self.describe(name, arguments, redacted: redacted)
    diagnostics?.debug("Running: \(description)")
    let path: String
    do { path = try executable(name) } catch {
      throw ContextError("Failed to execute \(description)", cause: error)
    }
    let termination: ProcessRunner.Termination
    do {
      termination = try runner.attached(
        .init(
          executable: path, arguments: arguments, environment: environment,
          deadline: Self.deadline), inheritStdin: false)
    } catch {
      throw ContextError("Failed to execute \(description)", cause: HostError("\(error)"))
    }
    guard termination == .exited(0) else {
      throw HostError("\(description) exited with \(exitStatusText(termination))")
    }
  }

  /// Rust `Cmd::capture`: stdout returned, stderr discarded.
  func capture(_ name: String, _ arguments: [String]) throws -> String {
    let description = Self.describe(name, arguments, redacted: [])
    diagnostics?.debug("Running (capture): \(description)")
    let path: String
    do { path = try executable(name) } catch {
      throw ContextError("Failed to execute \(description)", cause: error)
    }
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        .init(
          executable: path, arguments: arguments, environment: environment,
          deadline: Self.deadline, outputLimit: 64 << 20))
    } catch {
      throw ContextError("Failed to execute \(description)", cause: HostError("\(error)"))
    }
    guard output.termination == .exited(0) else {
      throw HostError("\(description) exited with \(exitStatusText(output.termination))")
    }
    guard let text = String(validating: output.stdout, as: UTF8.self) else {
      throw HostError("\(description) produced non-UTF-8 output")
    }
    return text
  }
}

/// Rust `ExitStatus` display.
func exitStatusText(_ termination: ProcessRunner.Termination) -> String {
  switch termination {
  case .exited(let code): "exit status: \(code)"
  case .signaled(let signal): "signal: \(signal) (\(signalName(signal)))"
  }
}

/// The OCI manifest fields coop reads; unknown fields are ignored.
struct OCIManifest: Decodable {
  struct Descriptor: Decodable {
    let digest: String
    let annotations: [String: String]

    enum CodingKeys: String, CodingKey { case digest, annotations }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      digest = try c.decode(String.self, forKey: .digest)
      annotations = try c.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:]
    }
  }

  struct FeatureMetadata: Decodable {
    let id: String?
    let name: String?
  }

  let config: Descriptor?
  let layers: [Descriptor]
  let annotations: [String: String]

  enum CodingKeys: String, CodingKey { case config, layers, annotations }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    config = try c.decodeIfPresent(Descriptor.self, forKey: .config)
    layers = try c.decodeIfPresent([Descriptor].self, forKey: .layers) ?? []
    annotations = try c.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:]
  }

  func digest() throws -> String {
    if let digest = annotations["org.opencontainers.image.digest"]
      ?? annotations["dev.containers.digest"]
    {
      return digest
    }
    if let config { return config.digest }
    throw HostError("OCI manifest has no digest-bearing config descriptor")
  }

  /// The layer titled `*.tgz`/`*.gz`, else the first layer.
  func featureBlob() throws -> Descriptor {
    let titled = layers.first { layer in
      guard let title = layer.annotations["org.opencontainers.image.title"] else { return false }
      let fileName = title.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
      guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return false }
      let ext = fileName[fileName.index(after: dot)...].lowercased()
      return ext == "tgz" || ext == "gz"
    }
    guard let blob = titled ?? layers.first else {
      throw HostError("OCI manifest has no downloadable feature layer")
    }
    return blob
  }

  var metadata: FeatureMetadata? {
    annotations["dev.containers.metadata"].flatMap {
      try? JSONDecoder().decode(FeatureMetadata.self, from: Data($0.utf8))
    }
  }
}
