import Darwin
import Foundation
import IsoConfiguration
import IsoCore

// The iso-provisioned, launchd-managed MLX backend
// (docs/design/secure-local-inference-spec.md §20.2–20.4). The user-side
// command generates a token and a plan; the one privileged step
// (`iso inference provision-system`, run through `sudo`) creates the role
// account, the root-owned backend directory, the confined LaunchDaemon, and
// verifies it serves only authenticated requests. Every tool runs with an
// argv, never a shell string.

/// Where a managed backend lives. `prefix` relocates every path for tests.
public struct ManagedBackendLayout: Sendable, Equatable {
  public static let root = "/Library/Application Support/iso-inference/backends"
  public static let launchDaemons = "/Library/LaunchDaemons"

  public let name: ManagedBackendName
  public let prefix: String

  public init(name: ManagedBackendName, prefix: String = "") {
    self.name = name
    self.prefix = prefix
  }

  public var label: String { "com.iso.inference.\(name)" }
  public var directory: String { prefix + Self.root + "/" + name.rawValue }
  public var backendsDirectory: String { prefix + Self.root }
  public var model: String { directory + "/model" }
  public var cache: String { directory + "/cache" }
  public var logs: String { directory + "/logs" }
  public var token: String { directory + "/token" }
  public var launcher: String { directory + "/launcher.py" }
  public var profile: String { directory + "/profile.sb" }
  public var venv: String { directory + "/venv" }
  public var plist: String { prefix + Self.launchDaemons + "/" + label + ".plist" }
}

/// What the privileged step is asked to do. Sent on stdin as JSON (the token
/// never touches argv or disk outside the root-owned token file) and fully
/// re-validated by the root step.
public struct ManagedBackendPlan: Sendable, Equatable {
  public let name: ManagedBackendName
  public let port: UInt16
  public let runtime: ManagedBackendConfig.Runtime
  public let model: ManagedBackendConfig.Model
  public let memoryLimitBytes: Int?
  public let confinement: ManagedBackendConfig.Confinement
  public let token: Secret<String>

  public init(
    name: ManagedBackendName, port: UInt16, runtime: ManagedBackendConfig.Runtime,
    model: ManagedBackendConfig.Model, memoryLimitBytes: Int?,
    confinement: ManagedBackendConfig.Confinement, token: Secret<String>
  ) {
    self.name = name
    self.port = port
    self.runtime = runtime
    self.model = model
    self.memoryLimitBytes = memoryLimitBytes
    self.confinement = confinement
    self.token = token
  }

  public init(
    name: ManagedBackendName, backend: InferenceBackendConfig, token: Secret<String>
  ) throws {
    guard let managed = backend.managed else {
      throw HostError("inference backend '\(name)' has no `managed` section")
    }
    self.init(
      name: name, port: backend.port, runtime: managed.runtime, model: managed.model,
      memoryLimitBytes: managed.memoryLimitBytes, confinement: managed.confinement, token: token)
  }

  public var encoded: [UInt8] {
    var members: [(String, OutputJSON)] = [
      ("version", .uint(1)), ("name", .string(name.rawValue)), ("port", .uint(UInt64(port))),
      ("confinement", .string(confinement.rawValue)), ("token", .string(token.expose())),
    ]
    switch runtime {
    case .python(let path): members.append(("python", .string(path.path)))
    case .install(let version): members.append(("install", .string(version)))
    }
    switch model {
    case .directory(let path): members.append(("model_directory", .string(path.path)))
    case .fetch(let repository, let revision):
      members.append(("model_repo", .string(repository)))
      members.append(("model_revision", .string(revision)))
    }
    if let limit = memoryLimitBytes { members.append(("memory_limit", .uint(UInt64(limit)))) }
    return Array(OutputJSON.object(members).rendered().utf8)
  }

  /// Parses and re-validates a plan with the configuration's validators.
  public static func decode(_ bytes: [UInt8]) throws -> ManagedBackendPlan {
    guard bytes.count <= 64 << 10,
      case .object(let m) = try ConfigLoader.parse(
        bytes, format: .json, path: "plan", limits: .configuration)
    else { throw HostError("the provisioning plan is malformed") }
    let allowed: Set<String> = [
      "version", "name", "port", "confinement", "token", "python", "install", "model_directory",
      "model_repo", "model_revision", "memory_limit",
    ]
    guard m.keys.allSatisfy(allowed.contains),
      m["version"] == .number(.unsigned(1))
        || m["version"] == .number(.integer(1))
    else { throw HostError("the provisioning plan has unknown members or version") }
    func string(_ key: String) -> String? { if case .string(let v)? = m[key] { v } else { nil } }
    func integer(_ key: String) -> Int64? { m[key].flatMap(InferenceController.integer) }
    guard let name = string("name").flatMap({ try? ManagedBackendName($0) }),
      let port = integer("port").flatMap(UInt16.init(exactly:)), port >= 1024,
      let confinement = string("confinement").flatMap(ManagedBackendConfig.Confinement.init),
      let token = string("token"), ManagedBackendConfig.isHex(token, count: 64)
    else {
      throw HostError("the provisioning plan has an invalid name, port, confinement or token")
    }
    let runtime: ManagedBackendConfig.Runtime
    switch (string("python"), string("install")) {
    case (let path?, nil) where path.hasPrefix("/"): runtime = .python(HostPath(absolute: path))
    case (nil, let version?) where ManagedBackendConfig.isQualifiedVersion(version):
      runtime = .install(version: version)
    default: throw HostError("the provisioning plan needs exactly one valid python or install")
    }
    let model: ManagedBackendConfig.Model
    switch (string("model_directory"), string("model_repo"), string("model_revision")) {
    case (let directory?, nil, nil) where directory.hasPrefix("/"):
      model = .directory(HostPath(absolute: directory))
    case (nil, let repository?, let revision?)
    where ManagedBackendConfig.isRepository(repository) && ManagedBackendConfig.isHex(revision):
      model = .fetch(repository: repository, revision: revision)
    default: throw HostError("the provisioning plan needs one valid model source")
    }
    let limit = integer("memory_limit").map { Int($0) }
    if let limit, !ManagedBackendConfig.memoryLimitRange.contains(limit) {
      throw HostError("the provisioning plan's memory limit is out of range")
    }
    return ManagedBackendPlan(
      name: name, port: port, runtime: runtime, model: model, memoryLimitBytes: limit,
      confinement: confinement, token: Secret(token))
  }
}

/// The interpreter a managed job runs: the path it is launched by, the
/// executable that resolves to (what Seatbelt matches on exec) and its prefixes.
public struct PythonRuntime: Sendable, Equatable {
  public var launch: String
  public var executable: String
  public var prefix: String
  public var basePrefix: String

  public init(launch: String, executable: String, prefix: String, basePrefix: String) {
    self.launch = launch
    self.executable = executable
    self.prefix = prefix
    self.basePrefix = basePrefix
  }
}

/// System tools the privileged step drives; paths are injectable for tests.
public struct SystemTools: Sendable {
  public var dscl = "/usr/bin/dscl"
  public var launchctl = "/bin/launchctl"
  public var ditto = "/usr/bin/ditto"
  public var sudo = "/usr/bin/sudo"
  public var sandboxExec = "/usr/bin/sandbox-exec"
  public var systemPython = "/usr/bin/python3"
  /// The account the root step must run as and trusts, besides root, to own
  /// the interpreter. Tests run the step as themselves against fake tools.
  public var privilegedUID: uid_t = 0
  public var chown: @Sendable (String, uid_t, gid_t) -> Int32 = { path, uid, gid in
    Darwin.lchown(path, uid, gid)
  }

  public init() {}
}

public enum ManagedBackend {
  /// Byte-identical to `inference-launcher.py` beside this file.
  static let launcherSource = EmbeddedManagedBackend.launcher
  /// Byte-identical to `seatbelt-inference-backend.sb` beside this file.
  static let profileSource = EmbeddedManagedBackend.profile

  static let healthDeadline: Duration = .seconds(300)

  /// The job's arguments: `sandbox-exec` with the backend profile (unless
  /// confinement is off), then the interpreter, the launcher and its options.
  static func programArguments(
    _ plan: ManagedBackendPlan, layout: ManagedBackendLayout, python: PythonRuntime,
    tools: SystemTools
  ) -> [String] {
    var launcher = [
      python.launch, "-I", layout.launcher, "--model", layout.model, "--port", String(plan.port),
      "--token-file", layout.token,
    ]
    if let limit = plan.memoryLimitBytes { launcher += ["--memory-limit", String(limit)] }
    guard plan.confinement == .seatbelt else { return launcher }
    return [
      tools.sandboxExec, "-D", "PYTHON=\(python.launch)", "-D",
      "PYTHON_EXECUTABLE=\(python.executable)", "-D", "PYTHON_PREFIX=\(python.prefix)", "-D",
      "PYTHON_BASE_PREFIX=\(python.basePrefix)",
      "-D", "BACKEND_DIR=\(layout.directory)", "-D", "CACHE_DIR=\(layout.cache)",
      "-D", "LOG_DIR=\(layout.logs)", "-D", "PORT=\(plan.port)", "-f", layout.profile,
    ] + launcher
  }

  /// The LaunchDaemon: role account, background priority, offline Hugging
  /// Face, restart on exit, logs in the role-owned log directory.
  static func plist(
    _ plan: ManagedBackendPlan, layout: ManagedBackendLayout, arguments: [String]
  ) throws -> [UInt8] {
    let document: [String: Any] = [
      "Label": layout.label,
      "UserName": ManagedBackendConfig.roleAccount,
      "GroupName": ManagedBackendConfig.roleAccount,
      "ProgramArguments": arguments,
      "RunAtLoad": true,
      "KeepAlive": true,
      "ThrottleInterval": 10,
      "ProcessType": "Background",
      "Nice": 5,
      "LowPriorityIO": true,
      "WorkingDirectory": layout.cache,
      "Umask": 0o077,
      "EnvironmentVariables": [
        "HOME": layout.cache, "HF_HOME": layout.cache + "/huggingface", "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1", "PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin",
      ],
      "StandardOutPath": layout.logs + "/backend.log",
      "StandardErrorPath": layout.logs + "/backend.log",
    ]
    return Array(
      try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0))
  }
}

/// The privileged step (`iso inference provision-system`): root only.
public struct ManagedBackendProvisioner: Sendable {
  let tools: SystemTools
  let runner: ProcessRunner
  let prefix: String
  let log: @Sendable (String) -> Void

  public init(
    tools: SystemTools = SystemTools(), runner: ProcessRunner = ProcessRunner(),
    prefix: String = "",
    log: @escaping @Sendable (String) -> Void
  ) {
    self.tools = tools
    self.runner = runner
    self.prefix = prefix
    self.log = log
  }

  func requireRoot() throws {
    if geteuid() != tools.privilegedUID {
      throw HostError("provision-system must run as root (it is invoked through sudo)")
    }
  }

  // MARK: Provision

  public func provision(_ plan: ManagedBackendPlan) throws {
    try requireRoot()
    let layout = ManagedBackendLayout(name: plan.name, prefix: prefix)
    let (uid, gid) = try ensureRoleAccount()
    try makeDirectory(prefix + "/Library/Application Support/iso-inference", 0o755, 0, 0)
    try makeDirectory(layout.backendsDirectory, 0o755, 0, 0)
    try makeDirectory(layout.directory, 0o755, 0, 0)
    try makeDirectory(layout.cache, 0o700, uid, gid)
    try makeDirectory(layout.logs, 0o700, uid, gid)
    try write(Array(plan.token.expose().utf8), to: layout.token, 0o640, 0, gid)
    try write(Array(ManagedBackend.launcherSource.utf8), to: layout.launcher, 0o644, 0, 0)
    try write(Array(ManagedBackend.profileSource.utf8), to: layout.profile, 0o644, 0, 0)
    let python = try runtime(plan, layout: layout)
    try installModel(plan, layout: layout, python: python.launch, uid: uid, gid: gid)
    let arguments = ManagedBackend.programArguments(
      plan, layout: layout, python: python, tools: tools)
    try write(
      try ManagedBackend.plist(plan, layout: layout, arguments: arguments), to: layout.plist,
      0o644, 0, 0)
    bootout(layout)
    try runChecked(tools.launchctl, ["bootstrap", "system", layout.plist])
    log("Loaded \(layout.label); waiting for the backend to answer on 127.0.0.1:\(plan.port)")
    do {
      try awaitHealthy(port: plan.port, token: plan.token)
    } catch {
      bootout(layout)
      throw ContextError(
        "The managed backend did not become healthy; its log is \(layout.logs)/backend.log (confinement: \(plan.confinement.rawValue))",
        cause: error)
    }
    log("Backend '\(plan.name)' is serving authenticated requests only")
  }

  /// The role account `_isoinference`, created hidden with no shell and no
  /// home when missing; a UID and GID in 400–499.
  func ensureRoleAccount() throws -> (uid_t, gid_t) {
    let account = ManagedBackendConfig.roleAccount
    if let existing = try recordNumber("/Users/\(account)", "UniqueID"),
      let group = try recordNumber("/Users/\(account)", "PrimaryGroupID")
    {
      return (uid_t(existing), gid_t(group))
    }
    let usedUIDs = try listNumbers("/Users", "UniqueID")
    let usedGIDs = try listNumbers("/Groups", "PrimaryGroupID")
    guard let id = (400...499).first(where: { !usedUIDs.contains($0) && !usedGIDs.contains($0) })
    else { throw HostError("no free system UID/GID in 400–499 for \(account)") }
    let records = [
      (
        "/Groups/\(account)",
        [("PrimaryGroupID", String(id)), ("RealName", "iso inference backend"), ("Password", "*")]
      ),
      (
        "/Users/\(account)",
        [
          ("UniqueID", String(id)), ("PrimaryGroupID", String(id)),
          ("UserShell", "/usr/bin/false"), ("NFSHomeDirectory", "/var/empty"),
          ("RealName", "iso inference backend"), ("Password", "*"), ("IsHidden", "1"),
        ]
      ),
    ]
    for (record, attributes) in records {
      for (key, value) in attributes {
        try runChecked(tools.dscl, [".", "-create", record, key, value])
      }
    }
    log("Created the hidden role account \(account) (UID \(id))")
    return (uid_t(id), gid_t(id))
  }

  func recordNumber(_ record: String, _ key: String) throws -> Int? {
    let output = try run(tools.dscl, [".", "-read", record, key])
    guard output.termination.succeeded else { return nil }
    let text = String(decoding: output.stdout, as: UTF8.self)
    return text.split(whereSeparator: \.isWhitespace).last.flatMap { Int($0) }
  }

  func listNumbers(_ path: String, _ key: String) throws -> Set<Int> {
    let output = try run(tools.dscl, [".", "-list", path, key])
    guard output.termination.succeeded else {
      throw HostError("dscl could not list \(path)")
    }
    return Set(
      String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").compactMap {
        $0.split(whereSeparator: \.isWhitespace).last.flatMap { Int($0) }
      })
  }

  /// The interpreter the job runs. A configured interpreter must be
  /// root-owned and unwritable by others, since the job runs it as the role
  /// account; `install` builds a root-owned virtualenv instead.
  func runtime(_ plan: ManagedBackendPlan, layout: ManagedBackendLayout) throws -> PythonRuntime {
    switch plan.runtime {
    case .python(let path):
      let python = try inspect(path.path)
      for root in Self.outermost([python.executable, python.prefix, python.basePrefix]) {
        try requireRootOwned(root)
      }
      return python
    case .install(let version):
      if !FileManager.default.fileExists(atPath: layout.venv + "/bin/python") {
        try runChecked(tools.systemPython, ["-m", "venv", layout.venv])
      }
      log("Installing mlx-lm==\(version) into \(layout.venv) (network)")
      try runChecked(
        layout.venv + "/bin/python",
        [
          "-m", "pip", "install", "--disable-pip-version-check", "--no-input", "mlx-lm==\(version)",
        ],
        deadline: .seconds(3600))
      try restrict(layout.venv, allowLinks: true)
      let python = try inspect(layout.venv + "/bin/python")
      try requireRootOwned(python.basePrefix)
      return python
    }
  }

  /// The resolved executable, `sys.prefix` (a venv's packages) and
  /// `sys.base_prefix` (the standard library), each read-only in the profile.
  func inspect(_ interpreter: String) throws -> PythonRuntime {
    guard let resolved = canonicalPath(interpreter) else {
      throw HostError.posix("Failed to resolve", interpreter)
    }
    let output = try runChecked(
      interpreter, ["-I", "-c", "import sys; print(sys.prefix); print(sys.base_prefix)"])
    let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
    guard lines.count == 2, lines.allSatisfy({ $0.hasPrefix("/") }) else {
      throw HostError("\(interpreter) did not report its prefixes")
    }
    return PythonRuntime(
      launch: interpreter, executable: resolved, prefix: lines[0],
      basePrefix: lines[1])
  }

  /// Every entry under `path` belongs to root (or the privileged account)
  /// and is not group- or world-writable.
  func requireRootOwned(_ path: String) throws {
    for (entry, info) in try Self.entries(under: path) where (info.st_mode & S_IFMT) != S_IFLNK {
      guard info.st_uid == 0 || info.st_uid == tools.privilegedUID, info.st_mode & 0o022 == 0
      else {
        throw HostError(
          "\(entry) is writable by a non-root account; the managed backend needs a root-owned Python (use `install` instead)"
        )
      }
    }
  }

  /// `path` and everything below it, with their `lstat`.
  static func entries(under path: String) throws -> [(path: String, info: stat)] {
    var paths = [path]
    if let walker = FileManager.default.enumerator(atPath: path) {
      while let next = walker.nextObject() as? String { paths.append(path + "/" + next) }
    }
    return try paths.map { entry in
      var info = stat()
      guard lstat(entry, &info) == 0 else { throw HostError.posix("Failed to inspect", entry) }
      return (entry, info)
    }
  }

  /// The paths not inside another of them, so each tree is walked once.
  static func outermost(_ paths: [String]) -> [String] {
    let unique = Array(Set(paths))
    return unique.filter { path in
      !unique.contains { other in other != path && path.hasPrefix(other + "/") }
    }.sorted()
  }

  /// Weights are root-owned and read-only to the role account.
  func installModel(
    _ plan: ManagedBackendPlan, layout: ManagedBackendLayout, python: String, uid: uid_t, gid: gid_t
  ) throws {
    let staging = layout.directory + "/model.staging"
    try? FileManager.default.removeItem(atPath: staging)
    switch plan.model {
    case .directory(let source):
      try runChecked(tools.ditto, [source.path, staging])
    case .fetch(let repository, let revision):
      try makeDirectory(staging, 0o700, uid, gid)
      log("Fetching \(repository)@\(revision) as \(ManagedBackendConfig.roleAccount) (network)")
      let script =
        "import sys; from huggingface_hub import snapshot_download; snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])"
      try runChecked(
        tools.sudo,
        [
          "-u", ManagedBackendConfig.roleAccount, "--", "/usr/bin/env", "-i",
          "HOME=\(layout.cache)",
          "HF_HOME=\(layout.cache)/huggingface", python, "-I", "-c", script, repository, revision,
          staging,
        ], deadline: .seconds(3600))
    }
    try restrict(staging)
    try? FileManager.default.removeItem(atPath: layout.model)
    guard rename(staging, layout.model) == 0 else {
      throw HostError.posix("Failed to place", layout.model)
    }
  }

  /// Root-owned, world-readable, nothing writable by others; no symlinks
  /// in model weights (a venv's interpreter links are allowed).
  func restrict(_ path: String, allowLinks: Bool = false) throws {
    for (entry, info) in try Self.entries(under: path) {
      if (info.st_mode & S_IFMT) == S_IFLNK {
        guard allowLinks else {
          throw HostError("model directories may not contain symbolic links (\(entry))")
        }
        _ = tools.chown(entry, 0, 0)
        continue
      }
      let directory = (info.st_mode & S_IFMT) == S_IFDIR
      guard tools.chown(entry, 0, 0) == 0, chmod(entry, directory ? 0o755 : 0o644) == 0
      else { throw HostError.posix("Failed to restrict", entry) }
    }
  }

  func awaitHealthy(port: UInt16, token: Secret<String>) throws {
    let deadline = ContinuousClock.now + ManagedBackend.healthDeadline
    while ContinuousClock.now < deadline {
      if let status = BackendProbe.status(port: port, token: token), status == 200 {
        guard BackendProbe.status(port: port, token: nil) == 401 else {
          throw HostError("the backend answers without its token")
        }
        return
      }
      usleep(500_000)
    }
    throw HostError("the backend did not answer within \(ManagedBackend.healthDeadline)")
  }

  // MARK: Deprovision and restart

  public func deprovision(name: ManagedBackendName) throws {
    try requireRoot()
    let layout = ManagedBackendLayout(name: name, prefix: prefix)
    bootout(layout)
    unlink(layout.plist)
    try? FileManager.default.removeItem(atPath: layout.directory)
    let remaining =
      (try? FileManager.default.contentsOfDirectory(atPath: layout.backendsDirectory))
      ?? []
    if remaining.isEmpty {
      let account = ManagedBackendConfig.roleAccount
      _ = try? run(tools.dscl, [".", "-delete", "/Users/\(account)"])
      _ = try? run(tools.dscl, [".", "-delete", "/Groups/\(account)"])
      log("Removed the role account \(account)")
    }
    log("Removed managed backend '\(name)'")
  }

  public func restart(name: ManagedBackendName) throws {
    try requireRoot()
    try runChecked(
      tools.launchctl, ["kickstart", "-k", "system/\(ManagedBackendLayout(name: name).label)"])
  }

  // MARK: Helpers

  func bootout(_ layout: ManagedBackendLayout) {
    _ = try? run(tools.launchctl, ["bootout", "system/\(layout.label)"])
  }

  func makeDirectory(_ path: String, _ mode: mode_t, _ uid: uid_t, _ gid: gid_t) throws {
    if mkdir(path, mode) != 0 && errno != EEXIST { throw HostError.posix("Failed to create", path) }
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
      throw HostError("\(path) is not a directory")
    }
    guard chmod(path, mode) == 0, tools.chown(path, uid, gid) == 0 else {
      throw HostError.posix("Failed to secure", path)
    }
  }

  func write(_ bytes: [UInt8], to path: String, _ mode: mode_t, _ uid: uid_t, _ gid: gid_t) throws {
    try AtomicFile.write(bytes, to: path, mode: .atMost(mode))
    guard chmod(path, mode) == 0, tools.chown(path, uid, gid) == 0 else {
      throw HostError.posix("Failed to own", path)
    }
  }

  @discardableResult
  func runChecked(_ executable: String, _ arguments: [String], deadline: Duration = .seconds(120))
    throws -> [UInt8]
  {
    let output = try run(executable, arguments, deadline: deadline)
    guard output.termination.succeeded else {
      let detail = String(decoding: output.stderr.prefix(2048), as: UTF8.self)
        .trimmingUnicodeWhitespace()
      throw HostError(
        "\((executable as NSString).lastPathComponent) \(arguments.first ?? "") failed (\(output.termination))\(detail.isEmpty ? "" : ": " + detail)"
      )
    }
    return output.stdout
  }

  func run(_ executable: String, _ arguments: [String], deadline: Duration = .seconds(120)) throws
    -> ProcessRunner.Output
  {
    try runner.capture(
      .init(
        executable: executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], deadline: deadline,
        outputLimit: 4 << 20, overflow: .drain))
  }
}

/// Minimal HTTP probes of a backend on 127.0.0.1.
enum BackendProbe {
  /// The status of `GET /v1/models`, with or without the bearer token; nil
  /// when nothing answers within 10 seconds.
  static func status(port: UInt16, token: Secret<String>?) -> Int? {
    guard
      let line = ProxyLauncher.httpStatusLine(
        port: port, path: "/v1/models",
        headers: token.map { ["Authorization: Bearer \($0.expose())"] } ?? [],
        budget: .seconds(10))
    else { return nil }
    let parts = String(decoding: line, as: UTF8.self).split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/1.") else { return nil }
    return Int(parts[1])
  }
}
