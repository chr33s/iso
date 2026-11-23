import CryptoKit
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
package struct ManagedBackendLayout: Sendable, Equatable {
  package static let root = "/Library/Application Support/iso-inference/backends"
  package static let launchDaemons = "/Library/LaunchDaemons"

  package let name: ManagedBackendName
  package let prefix: String

  package init(name: ManagedBackendName, prefix: String = "") {
    self.name = name
    self.prefix = prefix
  }

  package var label: String { "com.iso.inference.\(name)" }
  package var directory: String { prefix + Self.root + "/" + name.rawValue }
  package var backendsDirectory: String { prefix + Self.root }
  package var model: String { directory + "/model" }
  package var cache: String { directory + "/cache" }
  package var logs: String { directory + "/logs" }
  package var token: String { directory + "/token" }
  package var launcher: String { directory + "/launcher.py" }
  package var profile: String { directory + "/profile.sb" }
  package var venv: String { directory + "/venv" }
  /// `install`'s standalone CPython, the venv's base.
  package var python: String { directory + "/python" }
  /// `install`'s hash-locked requirements.
  package var lock: String { directory + "/requirements.lock" }
  package var plist: String { prefix + Self.launchDaemons + "/" + label + ".plist" }
}

/// What the privileged step is asked to do. Sent on stdin as JSON (the token
/// never touches argv or disk outside the root-owned token file) and fully
/// re-validated by the root step.
package struct ManagedBackendPlan: Sendable, Equatable {
  package let name: ManagedBackendName
  package let port: UInt16
  package let runtime: ManagedBackendConfig.Runtime
  package let model: ManagedBackendConfig.Model
  package let memoryLimitBytes: Int?
  package let confinement: ManagedBackendConfig.Confinement
  package let token: Secret<String>

  package init(
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

  package init(
    name: ManagedBackendName, backend: InferenceBackendConfig, token: Secret<String>
  ) throws {
    guard let managed = backend.managed else {
      throw HostError("inference backend '\(name)' has no `managed` section")
    }
    self.init(
      name: name, port: backend.port, runtime: managed.runtime, model: managed.model,
      memoryLimitBytes: managed.memoryLimitBytes, confinement: managed.confinement, token: token)
  }

  package var encoded: [UInt8] {
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
    return Array(OutputJSON.object(members).compactRendered().utf8)
  }

  /// Parses and re-validates a plan with the configuration's validators.
  package static func decode(_ bytes: [UInt8]) throws -> ManagedBackendPlan {
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
    case (nil, let version?) where ManagedBackendConfig.lockedMLXLM.contains(version):
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
package struct PythonRuntime: Sendable, Equatable {
  package var launch: String
  package var executable: String
  package var prefix: String
  package var basePrefix: String

  package init(launch: String, executable: String, prefix: String, basePrefix: String) {
    self.launch = launch
    self.executable = executable
    self.prefix = prefix
    self.basePrefix = basePrefix
  }
}

/// The CPython `install` builds its venv from: one python-build-standalone
/// release (CPython 3.12, macOS arm64). The role account downloads it, and
/// root checks the bytes against this size and SHA-256 before anything
/// unpacks or runs them.
package struct PythonArchive: Sendable, Equatable {
  package static let standalone = PythonArchive(
    url:
      "https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.12.16%2B20261110-aarch64-apple-darwin-install_only.tar.gz",
    size: 25_371_130,
    sha256: "e956e60bc9465d577ef8062059aa05cd3a2665b4b8678a2ed24e432368330b8f")

  package var url: String
  package var size: Int
  package var sha256: String
  /// The interpreter in the unpacked tree (the archive's `python/` member,
  /// unpacked without that first component).
  package var interpreter = "bin/python3.12"

  package init(url: String, size: Int, sha256: String) {
    self.url = url
    self.size = size
    self.sha256 = sha256
  }
}

/// System tools the privileged step drives; paths are injectable for tests.
package struct SystemTools: Sendable {
  package var dscl = "/usr/bin/dscl"
  package var launchctl = "/bin/launchctl"
  package var ditto = "/usr/bin/ditto"
  package var sudo = "/usr/bin/sudo"
  package var sandboxExec = "/usr/bin/sandbox-exec"
  package var curl = "/usr/bin/curl"
  package var tar = "/usr/bin/tar"
  /// The archive `install` downloads; tests substitute their own bytes.
  package var pythonArchive = PythonArchive.standalone
  /// The account the root step must run as and trusts, besides root, to own
  /// the interpreter. Tests run the step as themselves against fake tools.
  package var privilegedUID: uid_t = 0
  package var chown: @Sendable (String, uid_t, gid_t) -> Int32 = { path, uid, gid in
    Darwin.lchown(path, uid, gid)
  }
  /// Never follows a final symbolic link.
  package var chmod: @Sendable (String, mode_t) -> Int32 = { path, mode in
    Darwin.fchmodat(AT_FDCWD, path, mode, AT_SYMLINK_NOFOLLOW)
  }

  package init() {}
}

package enum ManagedBackend {
  /// Byte-identical to `Resources/inference-launcher.py`.
  static let launcherSource = EmbeddedInference.launcher
  /// Byte-identical to `Resources/seatbelt-inference-backend.sb`.
  static let profileSource = EmbeddedInference.backendProfile
  /// The hash-locked requirements `install` provisions, one for each
  /// `ManagedBackendConfig.lockedMLXLM` release (`scripts/lock-mlx-lm.py`).
  static let locks = ["0.31.3": EmbeddedInference.mlxLMLock]

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
package struct ManagedBackendProvisioner: Sendable {
  let tools: SystemTools
  let runner: ProcessRunner
  let prefix: String
  let log: @Sendable (String) -> Void

  package init(
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

  package func provision(_ plan: ManagedBackendPlan) throws {
    try requireRoot()
    let layout = ManagedBackendLayout(name: plan.name, prefix: prefix)
    let (uid, gid) = try ensureRoleAccount()
    try makeDirectory(prefix + "/Library/Application Support/iso-inference", 0o755, 0, 0)
    try makeDirectory(layout.backendsDirectory, 0o755, 0, 0)
    try makeDirectory(layout.directory, 0o755, 0, 0)
    try makeDirectory(layout.cache, 0o700, uid, gid)
    // launchd opens the log as root: a root-owned directory and file, so
    // the role account cannot point it elsewhere with a link.
    try makeDirectory(layout.logs, 0o755, 0, 0)
    try write([], to: layout.logs + "/backend.log", 0o600, 0, 0, keepContents: true)
    try write(Array(ManagedBackend.launcherSource.utf8), to: layout.launcher, 0o644, 0, 0)
    try write(Array(ManagedBackend.profileSource.utf8), to: layout.profile, 0o644, 0, 0)
    // `install` and a model fetch run downloaded code as the role account,
    // with network access. No token, old or new, exists while they run, so
    // that code cannot read one and send it out (§20.2).
    guard unlink(layout.token) == 0 || errno == ENOENT else {
      throw HostError.posix("Failed to remove the previous token", layout.token)
    }
    let python = try runtime(plan, layout: layout, uid: uid, gid: gid)
    try installModel(plan, layout: layout, python: python.launch, uid: uid, gid: gid)
    try write(Array(plan.token.expose().utf8), to: layout.token, 0o640, 0, gid)
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
  /// account; `install` builds a root-owned virtualenv on a pinned
  /// standalone CPython instead.
  func runtime(_ plan: ManagedBackendPlan, layout: ManagedBackendLayout, uid: uid_t, gid: gid_t)
    throws -> PythonRuntime
  {
    switch plan.runtime {
    case .python(let path):
      // Root runs the interpreter below, so first the file it would run
      // and its directory must be root-owned; then its prefixes.
      guard let resolved = canonicalPath(path.path) else {
        throw HostError.posix("Failed to resolve", path.path)
      }
      try requireRootOwned(resolved)
      try requireRootOwned((resolved as NSString).deletingLastPathComponent, recursive: false)
      let python = try inspect(path.path)
      for root in Self.outermost([python.executable, python.prefix, python.basePrefix]) {
        try requireRootOwned(root)
      }
      return python
    case .install(let version):
      guard let lock = ManagedBackend.locks[version] else {
        throw HostError("iso ships no hash-locked install for mlx-lm \(version)")
      }
      try installPython(layout, uid: uid, gid: gid)
      try write(Array(lock.utf8), to: layout.lock, 0o644, 0, 0)
      // pip runs as the role account in a staging directory it owns, binary
      // wheels only, installing exactly the lock's files: each must match a
      // hash in it. Root then takes the tree over before anything runs it as
      // root or as the job.
      let staging = layout.directory + "/venv.staging"
      try? FileManager.default.removeItem(atPath: staging)
      try makeDirectory(staging, 0o700, uid, gid)
      log(
        "Installing mlx-lm==\(version) from its lock into \(layout.venv) as \(ManagedBackendConfig.roleAccount) (network)"
      )
      try runAsRole(
        layout,
        [layout.python + "/" + tools.pythonArchive.interpreter, "-I", "-m", "venv", staging])
      try runAsRole(
        layout,
        [
          staging + "/bin/python", "-I", "-m", "pip", "install", "--isolated",
          "--disable-pip-version-check", "--no-input", "--no-cache-dir",
          "--index-url", "https://pypi.org/simple",
          "--only-binary", ":all:",
          "--no-deps",
          "--require-hashes", "-r", layout.lock,
        ], deadline: .seconds(3600))
      try restrict(staging, allowLinks: true)
      try? FileManager.default.removeItem(atPath: layout.venv)
      guard rename(staging, layout.venv) == 0 else {
        throw HostError.posix("Failed to place", layout.venv)
      }
      // Root never runs the venv the role account built: the layout fixes
      // its paths, and its interpreter must be the standalone one.
      let launch = layout.venv + "/bin/python"
      guard let executable = canonicalPath(launch),
        executable == canonicalPath(layout.python + "/" + tools.pythonArchive.interpreter)
      else {
        throw HostError("\(launch) does not resolve to the standalone Python in \(layout.python)")
      }
      try requireRootOwned(layout.python)
      return PythonRuntime(
        launch: launch, executable: executable, prefix: layout.venv, basePrefix: layout.python)
    }
  }

  /// Places the pinned standalone CPython at `layout.python`. The role
  /// account downloads it; root reads the file once and checks those bytes
  /// against the pinned size and SHA-256 before anything unpacks or runs
  /// them, and writes them to a root-owned file that the role account then
  /// unpacks into a staging directory, which root takes over.
  func installPython(_ layout: ManagedBackendLayout, uid: uid_t, gid: gid_t) throws {
    let archive = tools.pythonArchive
    let download = layout.directory + "/python.download"
    let verified = layout.directory + "/python.tar.gz"
    let staging = layout.directory + "/python.staging"
    defer {
      try? FileManager.default.removeItem(atPath: download)
      unlink(verified)
    }
    try? FileManager.default.removeItem(atPath: download)
    try? FileManager.default.removeItem(atPath: staging)
    try makeDirectory(download, 0o700, uid, gid)
    log("Downloading \(archive.url) as \(ManagedBackendConfig.roleAccount) (network)")
    // `--disable` (first) skips a `.curlrc` in the role account's home.
    try runAsRole(
      layout,
      [
        tools.curl, "--disable", "--fail", "--silent", "--show-error", "--location",
        "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
        "--max-filesize", String(archive.size), "--output", download + "/python.tar.gz",
        archive.url,
      ], deadline: .seconds(1800))
    let bytes = try Self.readDownload(download + "/python.tar.gz", size: archive.size)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard digest == archive.sha256 else {
      throw HostError(
        "the downloaded Python archive's SHA-256 is \(digest), not the pinned \(archive.sha256); nothing was unpacked"
      )
    }
    try write(bytes, to: verified, 0o644, 0, 0)
    try makeDirectory(staging, 0o700, uid, gid)
    try runAsRole(
      layout, [tools.tar, "-x", "-z", "-f", verified, "--strip-components", "1", "-C", staging])
    try restrict(staging, allowLinks: true)
    try? FileManager.default.removeItem(atPath: layout.python)
    guard rename(staging, layout.python) == 0 else {
      throw HostError.posix("Failed to place", layout.python)
    }
  }

  /// The role account's download: a regular file with one link (not a link
  /// to a file root can read and the role account cannot) of exactly `size`
  /// bytes, read once.
  static func readDownload(_ path: String, size: Int) throws -> [UInt8] {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw HostError.posix("Failed to open the download", path) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
      throw HostError("the download \(path) is not a regular file with one link")
    }
    guard info.st_size == size else {
      throw HostError("the download \(path) is \(info.st_size) bytes, not the pinned \(size)")
    }
    let bytes = try StateStore.readBounded(
      fd, path: path, limit: size, tooLarge: "the download \(path) grew past \(size) bytes")
    guard bytes.count == size else {
      throw HostError("the download \(path) is \(bytes.count) bytes, not the pinned \(size)")
    }
    return bytes
  }

  /// `argv` as the role account, with a scrubbed environment and its cache
  /// as home: package and model downloads never run as root.
  func runAsRole(
    _ layout: ManagedBackendLayout, _ argv: [String], deadline: Duration = .seconds(600)
  )
    throws
  {
    try runChecked(
      tools.sudo,
      [
        "-u", ManagedBackendConfig.roleAccount, "--", "/usr/bin/env", "-i", "HOME=\(layout.cache)",
        "PATH=/usr/bin:/bin", "HF_HOME=\(layout.cache)/huggingface", "PIP_NO_CACHE_DIR=1",
      ] + argv,
      deadline: deadline)
  }

  /// The resolved executable, `sys.prefix` (a venv's packages) and
  /// `sys.base_prefix` (the standard library), each read-only in the profile.
  func inspect(_ interpreter: String) throws -> PythonRuntime {
    guard let resolved = canonicalPath(interpreter) else {
      throw HostError.posix("Failed to resolve", interpreter)
    }
    let output = try runChecked(
      interpreter,
      ["-I", "-c", "import sys; sys.stdout.write(sys.prefix + '\\n' + sys.base_prefix + '\\n')"])
    let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
    guard lines.count == 2, lines.allSatisfy({ $0.hasPrefix("/") }) else {
      throw HostError("\(interpreter) did not report its prefixes")
    }
    return PythonRuntime(
      launch: interpreter, executable: resolved, prefix: lines[0],
      basePrefix: lines[1])
  }

  /// Every entry under `path` (just `path` without `recursive`) belongs to
  /// root (or the privileged account) and is not group- or world-writable.
  func requireRootOwned(_ path: String, recursive: Bool = true) throws {
    let entries: [(path: String, info: stat)] =
      recursive ? try Self.entries(under: path) : [(path, try Self.lstatEntry(path))]
    for (entry, info) in entries where (info.st_mode & S_IFMT) != S_IFLNK {
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
    return try paths.map { entry in (entry, try lstatEntry(entry)) }
  }

  static func lstatEntry(_ entry: String) throws -> stat {
    var info = stat()
    guard lstat(entry, &info) == 0 else { throw HostError.posix("Failed to inspect", entry) }
    return info
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
      try runAsRole(
        layout, [python, "-I", "-c", script, repository, revision, staging],
        deadline: .seconds(3600))
    }
    try restrict(staging)
    try? FileManager.default.removeItem(atPath: layout.model)
    guard rename(staging, layout.model) == 0 else {
      throw HostError.posix("Failed to place", layout.model)
    }
  }

  /// Root-owned, world-readable, nothing writable by others, no set-id
  /// bits (directories and files with an execute bit `0755`, other files
  /// `0644`); no symlinks in model weights (a Python tree's links are
  /// allowed). The tree
  /// was written by the role account, which may still have a process
  /// running, so nothing here follows a link: ownership is taken first
  /// (`lchown`), which ends the role's ability to change the tree; a second
  /// walk over the now root-owned tree sets modes with `fchmodat(…,
  /// AT_SYMLINK_NOFOLLOW)` and checks ownership, catching entries created
  /// during the first walk.
  func restrict(_ path: String, allowLinks: Bool = false) throws {
    for (entry, _) in try Self.entries(under: path) where tools.chown(entry, 0, 0) != 0 {
      throw HostError.posix("Failed to take ownership of", entry)
    }
    for (entry, info) in try Self.entries(under: path) {
      if (info.st_mode & S_IFMT) == S_IFLNK {
        guard allowLinks else {
          throw HostError("model directories may not contain symbolic links (\(entry))")
        }
        guard tools.chown(entry, 0, 0) == 0 else {
          throw HostError.posix("Failed to take ownership of", entry)
        }
        continue
      }
      let executable = (info.st_mode & S_IFMT) == S_IFDIR || info.st_mode & 0o111 != 0
      guard info.st_uid == 0 || info.st_uid == tools.privilegedUID || tools.chown(entry, 0, 0) == 0,
        tools.chmod(entry, executable ? 0o755 : 0o644) == 0
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
        guard BackendProbe.answersChallenge(port: port, token: token) else {
          throw HostError("the listener on 127.0.0.1:\(port) does not answer the token challenge")
        }
        return
      }
      usleep(500_000)
    }
    throw HostError("the backend did not answer within \(ManagedBackend.healthDeadline)")
  }

  // MARK: Deprovision and restart

  package func deprovision(name: ManagedBackendName) throws {
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

  package func restart(name: ManagedBackendName) throws {
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

  func write(
    _ bytes: [UInt8], to path: String, _ mode: mode_t, _ uid: uid_t, _ gid: gid_t,
    keepContents: Bool = false
  ) throws {
    var info = stat()
    let regular = lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    if !(keepContents && regular) { try AtomicFile.write(bytes, to: path, mode: .atMost(mode)) }
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
  /// The launcher's unauthenticated challenge (`GET /iso/challenge/<nonce>`):
  /// the body must be the hex HMAC-SHA256 of the nonce under the token. A
  /// squatter on the port cannot answer it, and the probe sends no secret.
  static func answersChallenge(port: UInt16, token: Secret<String>) -> Bool {
    let nonce = randomHex(32)
    guard let (status, body) = get(port: port, path: "/iso/challenge/" + nonce), status == 200
    else { return false }
    let expected = HMAC<SHA256>.authenticationCode(
      for: Data(nonce.utf8), using: SymmetricKey(data: Data(token.expose().utf8)))
    let hex = expected.map { String(format: "%02x", $0) }.joined()
    let answer = String(decoding: body, as: UTF8.self).trimmingUnicodeWhitespace()
    return answer.utf8.count == hex.utf8.count
      && zip(answer.utf8, hex.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  /// A bounded `GET` to 127.0.0.1: status and up to 4 KiB of body.
  static func get(port: UInt16, path: String, budget: Int = 10) -> (Int, [UInt8])? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: budget, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { return nil }
    let request = Array(
      "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
    guard request.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == request.count
    else { return nil }
    var response: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1024)
    while response.count < 8 << 10 {
      let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { break }
      response += chunk.prefix(count)
    }
    let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    guard let end = response.indices.first(where: { response[$0...].starts(with: separator) })
    else { return nil }
    let head = String(decoding: response[..<end], as: UTF8.self)
    let parts = head.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
      return nil
    }
    return (status, Array(response[(end + 4)...].prefix(4 << 10)))
  }

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
