import Foundation
import IsoConfiguration
import IsoCore

/// The narrow runtime-client interface (S-01): one concrete Apple backend,
/// with this seam only so tests can script `iso-sandbox` responses.
public protocol RuntimeExecutor: Sendable {
  /// Run the runtime with `arguments`; output is returned whatever the exit
  /// status. A thrown error means the outcome is unknown.
  /// `cancellable` lets Ctrl-C (`Shutdown`) abort the call; only create and
  /// boot are, so cleanup after an interrupt still runs to completion.
  func run(_ arguments: [String], deadline: Duration, outputLimit: Int, cancellable: Bool)
    throws(RuntimeError) -> ProcessRunner.Output

  /// Stream output chunks as they arrive; nil deadline means none.
  func stream(
    _ arguments: [String], deadline: Duration?, cancellable: Bool,
    onOutput: (ProcessRunner.Stream, ArraySlice<UInt8>) throws -> Void
  ) throws -> ProcessRunner.Termination
}

extension RuntimeExecutor {
  /// stdout and stderr appended to `log` (image builds).
  public func runLogged(_ arguments: [String], log: String, deadline: Duration, cancellable: Bool)
    throws
    -> ProcessRunner.Termination
  {
    let fd = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw HostError("Failed to open \(log)") }
    defer { close(fd) }
    return try stream(arguments, deadline: deadline, cancellable: cancellable) { _, bytes in
      _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
  }

  public func stream(
    _ arguments: [String], deadline: Duration?,
    onOutput: (ProcessRunner.Stream, ArraySlice<UInt8>) throws -> Void
  ) throws -> ProcessRunner.Termination {
    try stream(arguments, deadline: deadline, cancellable: false, onOutput: onOutput)
  }

  public func run(_ arguments: [String], deadline: Duration, outputLimit: Int) throws(RuntimeError)
    -> ProcessRunner.Output
  {
    try run(arguments, deadline: deadline, outputLimit: outputLimit, cancellable: false)
  }
}

/// Rust `Duration` `{:?}` for the whole-second and millisecond values iso
/// uses: `10s`, `200ms`.
func rustDuration(_ duration: Duration) -> String {
  let (seconds, attoseconds) = duration.components
  let nanos = attoseconds / 1_000_000_000
  func fraction(_ whole: Int64, _ part: Int64, _ digits: Int, _ unit: String) -> String {
    guard part > 0 else { return "\(whole)\(unit)" }
    var text = String(part)
    text = String(repeating: "0", count: digits - text.count) + text
    while text.hasSuffix("0") { text.removeLast() }
    return "\(whole).\(text)\(unit)"
  }
  if seconds > 0 { return fraction(seconds, nanos, 9, "s") }
  if nanos >= 1_000_000 { return fraction(nanos / 1_000_000, nanos % 1_000_000, 6, "ms") }
  if nanos >= 1_000 { return fraction(nanos / 1_000, nanos % 1_000, 3, "µs") }
  return "\(nanos)ns"
}

/// Runs a resolved `iso-sandbox` through the shared `ProcessRunner`, with
/// stdin at `/dev/null`, a sanitized environment and a fixed `PATH`.
public struct ProcessRuntimeExecutor: RuntimeExecutor {
  /// The only variables a runtime child inherits: enough for the CLI to
  /// find its per-user service and keep its output parseable. Tokens,
  /// `SSH_AUTH_SOCK`, `DYLD_*` and `CONTAINER_*` overrides are dropped.
  public static let inheritedVariables: Set<String> = [
    "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
  ]
  /// A project-local directory on the caller's `PATH` can never shadow a helper.
  public static let childPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  public let binary: String
  let environment: [String: String]
  let runner: ProcessRunner

  public init(
    binary: String, parentEnvironment: [String: String], runner: ProcessRunner = ProcessRunner()
  ) {
    self.binary = binary
    environment = Self.sanitized(parentEnvironment)
    self.runner = runner
  }

  /// The binary's file name, for diagnostics.
  var program: String { (binary as NSString).lastPathComponent }

  public static func sanitized(_ parent: [String: String]) -> [String: String] {
    var out = parent.filter { inheritedVariables.contains($0.key) }
    out["PATH"] = childPath
    return out
  }

  public func run(_ arguments: [String], deadline: Duration, outputLimit: Int, cancellable: Bool)
    throws(RuntimeError) -> ProcessRunner.Output
  {
    let described = program + " " + arguments.joined(separator: " ")
    let output: ProcessRunner.Output
    do {
      var request = ProcessRunner.Request(
        executable: binary, arguments: arguments, environment: environment, deadline: deadline,
        outputLimit: outputLimit, overflow: .drain)
      if cancellable { request.isCancelled = { Shutdown.isRequested } }
      output = try runner.capture(request)
    } catch .cancelled {
      throw .operationUncertain(
        "`\(described)` was cancelled; its effect is unknown and will be reconciled on retry")
    } catch .timedOut {
      throw .operationUncertain(
        "`\(described)` did not finish within \(rustDuration(deadline)); its effect is unknown and will be reconciled on retry"
      )
    } catch .spawn(let code) {
      throw .failed("Failed to run \(binary): \(String(cString: strerror(code)))")
    } catch {
      throw .operationUncertain("`\(described)` failed while reading its output")
    }
    guard !output.truncated else {
      throw .operationUncertain("`\(described)` produced more than \(outputLimit) bytes of output")
    }
    return output
  }

  public func stream(
    _ arguments: [String], deadline: Duration?, cancellable: Bool,
    onOutput: (ProcessRunner.Stream, ArraySlice<UInt8>) throws -> Void
  ) throws -> ProcessRunner.Termination {
    let described = program + " " + arguments.joined(separator: " ")
    var sinkError: (any Error)?
    var request = ProcessRunner.Request(
      executable: binary, arguments: arguments, environment: environment,
      deadline: deadline ?? .zero)
    if cancellable { request.isCancelled = { Shutdown.isRequested } }
    do {
      return try runner.stream(request, deadline: deadline) {
        (stream, bytes) throws(ProcessRunner.Failure) in
        do { try onOutput(stream, bytes) } catch {
          sinkError = error
          throw .io(errno: EPIPE)
        }
      }
    } catch {
      if let sinkError { throw sinkError }
      switch error {
      case .cancelled:
        throw RuntimeError.operationUncertain(
          "`\(described)` was cancelled; its effect is unknown and will be reconciled on retry")
      case .timedOut:
        throw RuntimeError.operationUncertain(
          "`\(described)` did not finish within \(rustDuration(deadline ?? .zero)); its effect is unknown and will be reconciled on retry"
        )
      case .spawn(let code):
        throw RuntimeError.failed("Failed to run \(binary): \(String(cString: strerror(code)))")
      default: throw RuntimeError.failed("Failed to read runtime output")
      }
    }
  }
}

/// Protocol-5 identity captured before a filtered companion starts.
public struct FilteredBoot: Sendable, Equatable {
  public let bootID: String
  public let ownerPID: Int32
  public let livePath: String
}

/// A resolved, qualified-or-not `iso-sandbox`. Qualification failure is
/// kept rather than raised so cleanup of owned resources can still run on
/// an unqualified runtime; anything that boots or hands out a guest calls
/// `requireQualified()` first.
public struct SandboxRuntime: Sendable {
  public static let jsonLimit = 1 << 20
  public static let textLimit = 256 << 10
  public static let containerization = "0.45.0"

  let executor: any RuntimeExecutor
  /// Canonical runtime state root, passed as `--root` on every call.
  public let root: String
  public let settings: AppleContainerConfig
  public let qualification: Result<String, RuntimeError>
  /// Protocol from a successful version probe, otherwise 0.
  public let advertisedProtocol: UInt32

  public init(executor: any RuntimeExecutor, root: String, settings: AppleContainerConfig) {
    self.executor = executor
    self.root = root
    self.settings = settings
    let probed: Result<RuntimeVersion, RuntimeError> = Result { () throws(RuntimeError) in
      let output = try Self.checked(
        executor, ["version"], deadline: settings.probeTimeout.duration, limit: Self.textLimit)
      return try RuntimeProtocol.parseVersion(output)
    }
    switch probed {
    case .success(let version):
      advertisedProtocol = version.protocol
      qualification = Result { () throws(RuntimeError) in try Self.qualify(version) }
    case .failure(let error):
      advertisedProtocol = 0
      qualification = .failure(error)
    }
  }

  /// Resolve the configured or installed runtime for `config`.
  public static func open(_ config: IsoConfig, environment: [String: String], executable: String?)
    throws(RuntimeError) -> SandboxRuntime
  {
    let binary = try BinaryResolver.resolve(
      configured: config.appleContainer.binary?.path,
      defaults: BinaryResolver.defaultRuntimes(home: environment["HOME"], executable: executable),
      tool: .runtime)
    return SandboxRuntime(
      executor: ProcessRuntimeExecutor(binary: binary, parentEnvironment: environment),
      root: BinaryResolver.canonicalPath(config.stateRoot.appending("runtime").path),
      settings: config.appleContainer)
  }

  /// Accept protocol 4 or 5 with the containerization release this host was
  /// validated with. Filtered egress checks protocol 5 separately.
  public static func qualify(_ version: RuntimeVersion) throws(RuntimeError) -> String {
    let identity =
      "\(version.name) \(version.version) (containerization \(version.containerization), protocol \(version.protocol))"
    guard version.name == "iso-sandbox" else {
      throw .unqualified(
        "\(identity) is not iso-sandbox; `apple_container.binary` must point at the runtime built by scripts/build-iso-sandbox.sh"
      )
    }
    guard RuntimeProtocol.compatible.contains(version.protocol),
      version.containerization == containerization
    else {
      throw .unqualified(
        "\(identity) is not a qualified runtime (protocol 4 or \(RuntimeProtocol.version), containerization \(containerization)); rebuild it from this checkout with scripts/build-iso-sandbox.sh"
      )
    }
    return identity
  }

  public func requireQualified() throws(RuntimeError) -> String { try qualification.get() }

  /// `<subcommand...> --root <root> <rest...>`.
  func arguments(_ subcommand: [String], _ rest: [String] = []) -> [String] {
    subcommand + ["--root", root] + rest
  }

  static func checked(
    _ executor: any RuntimeExecutor, _ arguments: [String], deadline: Duration, limit: Int,
    cancellable: Bool = false, program: String = "iso-sandbox"
  )
    throws(RuntimeError) -> [UInt8]
  {
    let output = try executor.run(
      arguments, deadline: deadline, outputLimit: limit, cancellable: cancellable)
    guard output.termination == .exited(0) else {
      let stderr = sanitizeForDisplay(String(decoding: output.stderr, as: UTF8.self))
      throw .failed("`\(program) \(arguments.joined(separator: " "))` failed: \(stderr)")
    }
    guard String(validating: output.stdout, as: UTF8.self) != nil else {
      throw .failed("runtime output is not valid UTF-8")
    }
    return output.stdout
  }

  func probe(_ subcommand: [String], _ rest: [String] = []) throws(RuntimeError) -> [UInt8] {
    try Self.checked(
      executor, arguments(subcommand, rest), deadline: settings.probeTimeout.duration,
      limit: Self.jsonLimit)
  }

  // MARK: Read-only operations

  public func list() throws(RuntimeError) -> [ListedSandbox] {
    try RuntimeProtocol.parseList(probe(["list"]))
  }

  public func inspect(_ name: MachineName) throws(RuntimeError) -> SandboxInspection {
    try RuntimeProtocol.parseInspect(probe(["inspect"], [name.rawValue]), expected: name)
  }

  /// Protocol 5 boot identity. A protocol-4 runtime, or a live state without
  /// `bootId`, fails before filtered egress can start.
  public func requireFilteredBoot(_ name: MachineName) throws(RuntimeError) -> FilteredBoot {
    _ = try requireQualified()
    let inspection = try inspect(name)
    let bootID = inspection.live?.bootId
    guard RuntimeProtocol.filteredBootAllowed(advertised: advertisedProtocol, bootID: bootID),
      let live = inspection.live, let bootID
    else {
      throw .unqualified(
        "filtered egress requires iso-sandbox protocol \(RuntimeProtocol.bootIdentity) and a live boot id for \(name); this runtime is protocol \(advertisedProtocol)"
      )
    }
    return FilteredBoot(
      bootID: bootID, ownerPID: live.pid,
      livePath: "\(root)/sandboxes/\(name.rawValue)/live.json")
  }

  public func images() throws(RuntimeError) -> [RuntimeImage] {
    try RuntimeProtocol.parseImages(probe(["image", "list"]))
  }

  public func disks() throws(RuntimeError) -> [RuntimeDisk] {
    try RuntimeProtocol.parseDisks(probe(["disk", "list"]))
  }

  /// `logs --root R <id> [--follow]`, streamed. Snapshots are bounded by the
  /// boot deadline; following has none.
  public func logs(
    _ name: MachineName, follow: Bool,
    onOutput: (ProcessRunner.Stream, ArraySlice<UInt8>) throws -> Void
  ) throws -> ProcessRunner.Termination {
    try executor.stream(
      arguments(["logs"], [name.rawValue] + (follow ? ["--follow"] : [])),
      deadline: follow ? nil : settings.bootTimeout.duration, onOutput: onOutput)
  }
}

/// Resolves `iso-sandbox` (and the stock `container` builder) to an
/// absolute, host-owned executable. Only the user's configuration and fixed
/// install locations are consulted — never `PATH` or anything a project
/// supplies — so a project cannot choose the runtime.
public enum BinaryResolver {
  public enum Tool: Sendable {
    case runtime
    case builder

    var name: String { self == .runtime ? "iso-sandbox" : "container" }
    var installHint: String {
      switch self {
      case .runtime: "Build it with scripts/build-iso-sandbox.sh, or set `apple_container.binary`."
      case .builder: "Install Apple `container` 1.4.1 or later, or set `apple_container.builder`."
      }
    }
  }

  /// Group ids whose members can already act as root on macOS (`wheel`,
  /// `admin`); Homebrew's prefix is `admin`-group-writable.
  static let rootEquivalentGroups: Set<gid_t> = [0, 80]

  /// Runtime beside the running host first, then fixed install locations.
  public static func defaultRuntimes(home: String?, executable: String?) -> [String] {
    var candidates: [String] = []
    if let executable {
      candidates.append((executable as NSString).deletingLastPathComponent + "/iso-sandbox")
    }
    if let home { candidates.append(home + "/.local/opt/iso-sandbox/bin/iso-sandbox") }
    return candidates + ["/usr/local/bin/iso-sandbox", "/opt/homebrew/bin/iso-sandbox"]
  }

  public static let defaultBuilders = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

  public static func resolve(configured: String?, defaults: [String], tool: Tool)
    throws(RuntimeError) -> String
  {
    var lastError: String?
    for candidate in configured.map({ [$0] }) ?? defaults {
      switch check(candidate) {
      case .success(let resolved): return resolved
      case .failure(let error): lastError = error.message
      }
    }
    let detail = lastError.map { " (\($0))" } ?? ""
    throw .unavailable("no usable `\(tool.name)` found\(detail). \(tool.installHint)")
  }

  static func check(_ path: String, uid: uid_t = getuid()) -> Result<String, HostError> {
    guard path.hasPrefix("/") else { return .failure(HostError("\(path) is not an absolute path")) }
    guard let resolvedPointer = realpath(path, nil) else {
      return .failure(HostError("\(path) does not exist"))
    }
    let resolved = String(cString: resolvedPointer)
    free(resolvedPointer)
    var status = stat()
    guard stat(resolved, &status) == 0 else {
      return .failure(HostError("\(resolved) does not exist"))
    }
    guard (status.st_mode & S_IFMT) == S_IFREG, status.st_mode & 0o111 != 0 else {
      return .failure(HostError("\(resolved) is not an executable file"))
    }
    guard status.st_uid == 0 || status.st_uid == uid else {
      return .failure(HostError("\(resolved) is owned by another user"))
    }
    guard status.st_mode & 0o022 == 0 else {
      return .failure(HostError("\(resolved) is group- or world-writable"))
    }
    // Whoever can rename entries in a directory on the path can swap the
    // binary, so every ancestor must be as trustworthy as the file.
    var directory = (resolved as NSString).deletingLastPathComponent
    while true {
      guard stat(directory, &status) == 0 else {
        return .failure(HostError("Failed to inspect \(directory)"))
      }
      if let why = untrustedDirectory(
        mode: status.st_mode, owner: status.st_uid, group: status.st_gid, me: uid)
      {
        return .failure(HostError("\(resolved) is inside \(directory), which \(why)"))
      }
      if directory == "/" { break }
      directory = (directory as NSString).deletingLastPathComponent
    }
    return .success(resolved)
  }

  /// Why a directory lets someone other than root or `me` replace entries
  /// in it, or nil. A sticky directory only lets users rename their own.
  static func untrustedDirectory(mode: mode_t, owner: uid_t, group: gid_t, me: uid_t) -> String? {
    if owner != 0 && owner != me { return "is owned by another user" }
    if mode & 0o1000 != 0 { return nil }
    if mode & 0o002 != 0 { return "is world-writable" }
    if mode & 0o020 != 0 && !rootEquivalentGroups.contains(group) { return "is group-writable" }
    return nil
  }

  /// `path` with its longest existing ancestor canonicalized, so it reads
  /// the same before and after the missing tail is created (as the runtime
  /// canonicalizes its root).
  public static func canonicalPath(_ path: String) -> String {
    if let real = realpath(path, nil) {
      defer { free(real) }
      return String(cString: real)
    }
    let parent = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    guard !parent.isEmpty, parent != path, !name.isEmpty else { return path }
    let base = canonicalPath(parent)
    return base.hasSuffix("/") ? base + name : base + "/" + name
  }
}
