import CoopConfiguration
import CoopCore
import Foundation

/// Guest `/workspace`: where a copied, cloned or mounted project lands.
public let guestWorkspace = GuestPath("/workspace")

/// Transfers skip reproducible build and cache directories. `.git/` stays
/// unless `--exclude-git`: agents in the guest need history and commits
/// that survive a `coop pull`.
let defaultExcludes = ["node_modules/", "target/", "__pycache__/", ".venv/", ".coop/"]
let gitExclude = ".git/"

/// A host directory synced once into the guest (the Apple runtime has no
/// live mounts). `hostPath` is canonical.
public struct Mount: Sendable, Equatable {
  public let hostPath: String
  public let guestPath: GuestPath

  /// `HOST_PATH[:GUEST_PATH]`; the guest path defaults to `/workspace`.
  public static func parse(_ spec: String) throws -> Mount {
    guard let colon = spec.firstIndex(of: ":") else {
      return try Mount(host: spec, guest: guestWorkspace)
    }
    return try Mount(
      host: String(spec[..<colon]),
      guest: GuestPath.absolute(String(spec[spec.index(after: colon)...])))
  }

  public init(host: String, guest: GuestPath) throws {
    guard let canonical = canonicalPath(host) else {
      throw HostError("Mount host path does not exist: \(host)")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw HostError("Mount host path is not a directory: \(canonical)") }
    hostPath = canonical
    guestPath = guest
  }

  /// Contains a `.git` entry (a repository or linked worktree).
  public var hostIsGitRepo: Bool { FileManager.default.fileExists(atPath: hostPath + "/.git") }
}

/// `realpath(3)`: absolute, symlinks resolved; nil when the path is missing.
public func canonicalPath(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else { return nil }
  defer { free(resolved) }
  return String(validatingCString: resolved)
}

/// Where the workspace came from, persisted in `workspace.json`.
public enum WorkspaceSource: Sendable, Equatable {
  case workspace(hostPath: String)
  /// Cloned inside the guest; only the URL is recorded.
  case gitRepo(url: String)
  case mount(hostPath: String)

  public var hostPath: String? {
    switch self {
    case .workspace(let path), .mount(let path): path
    case .gitRepo: nil
    }
  }
}

/// `<instance>/workspace.json`, in the Rust host's format.
public struct WorkspaceState: Sendable, Equatable {
  /// Always absolute: a relative path in a hand-edited file is rejected at
  /// load time, before it can reach a remote command.
  public let guestPath: GuestPath
  public let source: WorkspaceSource

  public init(guestPath: GuestPath, source: WorkspaceSource) {
    self.guestPath = guestPath
    self.source = source
  }

  var json: OutputJSON {
    let source: OutputJSON =
      switch self.source {
      case .workspace(let path):
        .object([("kind", .string("workspace")), ("host_path", .string(path))])
      case .gitRepo(let url): .object([("kind", .string("git_repo")), ("url", .string(url))])
      case .mount(let path): .object([("kind", .string("mount")), ("host_path", .string(path))])
      }
    return .object([("guest_path", .string(guestPath.rawValue)), ("source", source)])
  }

  public func save(_ instance: Instance, diagnostics: Diagnostics? = nil) throws {
    do {
      try AtomicFile.write(
        Array(String(json.rendered().dropLast()).utf8), to: instance.workspaceStatePath,
        mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write workspace.json", cause: error)
    }
    diagnostics?.debug("Wrote workspace state to \(instance.workspaceStatePath)")
  }

  public static func load(_ instance: Instance) throws -> WorkspaceState? {
    let path = instance.workspaceStatePath
    guard let data = FileManager.default.contents(atPath: path) else {
      if FileManager.default.fileExists(atPath: path) {
        throw HostError("Failed to read \(path)")
      }
      return nil
    }
    do {
      return try decode(data)
    } catch {
      throw ContextError(
        "Failed to parse \(path).\nIf this file was written by a pre-#147 coop the on-disk shape changed; delete it and run `coop up` again to regenerate, or `coop destroy <name>` if the instance is no longer needed.",
        cause: error)
    }
  }

  static func decode(_ data: Data) throws -> WorkspaceState {
    struct Raw: Decodable {
      let guestPath: String
      let source: Source
      enum CodingKeys: String, CodingKey {
        case guestPath = "guest_path"
        case source
      }
      struct Source: Decodable {
        let kind: String
        let hostPath: String?
        let url: String?
        enum CodingKeys: String, CodingKey {
          case kind, url
          case hostPath = "host_path"
        }
      }
    }
    let raw = try JSONDecoder().decode(Raw.self, from: data)
    let guestPath = try GuestPath.absolute(raw.guestPath)
    let source: WorkspaceSource
    switch raw.source.kind {
    case "workspace":
      guard let path = raw.source.hostPath else { throw HostError("missing field `host_path`") }
      source = .workspace(hostPath: path)
    case "mount":
      guard let path = raw.source.hostPath else { throw HostError("missing field `host_path`") }
      source = .mount(hostPath: path)
    case "git_repo":
      guard let url = raw.source.url else { throw HostError("missing field `url`") }
      source = .gitRepo(url: url)
    default:
      throw HostError(
        "unknown variant `\(raw.source.kind)`, expected one of `workspace`, `git_repo`, `mount`")
    }
    return WorkspaceState(guestPath: guestPath, source: source)
  }

  /// Nil (after a warning naming what degrades) when the file is unreadable.
  public static func loadOrWarn(
    _ instance: Instance, consequence: String, diagnostics: Diagnostics
  ) -> WorkspaceState? {
    do {
      return try load(instance)
    } catch {
      diagnostics.warn(
        "Could not read workspace state for '\(instance.name)'; \(consequence). \(oneLine(error))"
      )
      return nil
    }
  }
}

/// Which project policy a start-time mount set is checked under.
public enum WorkspaceMountRule: Sendable {
  /// `up --copy`: the project occupies `/workspace`.
  case copyProject
  /// `up --git-repo`: the clone occupies `/workspace`.
  case gitRepoClone
  /// The project is itself mounted at `/workspace`, or there is none.
  case projectMountedOrNone
}

/// A mount set with unique guest paths and, per rule, no extra mount on
/// the project's `/workspace`.
public struct ValidatedMounts: Sendable {
  public let mounts: [Mount]

  public init(_ rule: WorkspaceMountRule, _ mounts: [Mount]) throws {
    let collision: String? =
      switch rule {
      case .copyProject:
        "`coop up --copy` already uses /workspace for the project. Give --extra-mount an explicit non-/workspace guest path, or use `coop up --mount` to mount the project itself."
      case .gitRepoClone:
        "`coop up --git-repo` clones into /workspace. Give --extra-mount an explicit non-/workspace guest path."
      case .projectMountedOrNone: nil
      }
    if let collision, mounts.contains(where: { $0.guestPath == guestWorkspace }) {
      throw HostError(collision)
    }
    var seen: Set<GuestPath> = []
    for mount in mounts where !seen.insert(mount.guestPath).inserted {
      throw HostError("Duplicate mount guest path: \(mount.guestPath)")
    }
    self.mounts = mounts
  }
}

/// Copying projects into and out of the guest over the pinned transport:
/// rsync when the guest has it, a tar pipe otherwise.
public struct WorkspaceTransfer: Sendable {
  let client: SSHClient
  let diagnostics: Diagnostics

  public init(client: SSHClient, diagnostics: Diagnostics) {
    self.client = client
    self.diagnostics = diagnostics
  }

  var runner: ProcessRunner { client.runner }

  func tool(_ name: String) throws -> String {
    guard let path = client.executable(named: name) else {
      throw HostError("Failed to run \(name): not found on PATH")
    }
    return path
  }

  func request(_ executable: String, _ arguments: [String], environment: [String: String]? = nil)
    -> ProcessRunner.Request
  {
    .init(
      executable: executable, arguments: arguments, environment: environment ?? client.environment,
      deadline: SSHClient.captureDeadline, outputLimit: 1 << 20)
  }

  /// `tar cf - | ssh … tar xf - -C <guest>`: no staging copy on either side.
  public func tarPipe(_ target: SSHTarget, source: String, to guest: GuestPath, excludeGit: Bool)
    throws
  {
    diagnostics.log(.info, "Transferring \(source) to guest:\(guest) via tar-pipe")
    var tarArguments = ["cf", "-"] + defaultExcludes.map { "--exclude=\($0)" }
    if excludeGit { tarArguments.append("--exclude=\(gitExclude)") }
    tarArguments += ["-C", source, "."]
    // Stops bsdtar from packing AppleDouble `._*` sidecars for xattrs.
    var tarEnvironment = client.environment
    tarEnvironment["COPYFILE_DISABLE"] = "1"
    let extract = RemoteCommand().literal("tar xf - -C ").arg(guest.rawValue)
    let output = try runner.pipeline(
      request(try tool("tar"), tarArguments, environment: tarEnvironment),
      request(try client.ssh(), target.sshOptions + [target.address, extract.rendered]))
    // The remote side exiting early (disk full, unwritable target) shows up
    // as local tar dying on a closed pipe; the cause is in ssh's stderr.
    if output.producer == .signaled(SIGPIPE) {
      throw ContextError(
        Self.remoteFailure(output.consumerStderr),
        cause: HostError("Failed to write to SSH stdin: Broken pipe (os error 32)"))
    }
    guard output.producer.succeeded else {
      throw HostError(
        "Local tar archive creation failed.\n\(Self.failure("Local tar stderr", output.producerStderr))"
      )
    }
    guard output.consumer.succeeded else {
      throw HostError(
        "tar-pipe transfer to guest failed: \(Self.remoteFailure(output.consumerStderr))")
    }
    diagnostics.log(.info, "Workspace transferred to guest")
  }

  /// `sparse` (staged pulls) archives holes as holes, so a sparse guest
  /// file cannot expand on the host before the stage budgets run.
  func tarPull(
    _ target: SSHTarget, guest: GuestPath, to destination: String, excludeGit: Bool,
    sparse: Bool = false, cancel: (@Sendable () -> Bool)? = nil
  ) throws {
    var excludes = defaultExcludes.map { "--exclude=\($0)" }
    if excludeGit { excludes.append("--exclude=\(gitExclude)") }
    if sparse { excludes.append("--sparse") }
    let command = RemoteCommand().literal("tar cf - -C ").arg(guest.rawValue)
      .literal(" \(excludes.joined(separator: " ")) .")
    var producer = request(
      try client.ssh(), target.sshOptions + [target.address, command.rendered])
    producer.isCancelled = cancel
    let output = try runner.pipeline(
      producer, request(try tool("tar"), ["xf", "-", "-C", destination]))
    if output.producer == .signaled(SIGPIPE) {
      throw ContextError(
        Self.pullFailure(output.producerStderr, output.consumerStderr),
        cause: HostError("Failed to write to tar stdin: Broken pipe (os error 32)"))
    }
    // ssh first: a remote tar dying mid-archive makes local tar report a
    // truncated archive, which would hide the cause.
    guard output.producer.succeeded else {
      throw HostError(
        "tar-pipe pull from guest failed.\n\(Self.pullFailure(output.producerStderr, output.consumerStderr))"
      )
    }
    guard output.consumer.succeeded else {
      throw HostError(
        "tar extraction failed during pull.\n\(Self.failure("Local tar stderr", output.consumerStderr))"
      )
    }
  }

  static let diskHint =
    "The guest disk is likely too small for this workspace. Recreate it with a larger disk: `coop up --disk <GiB> ...`."

  static func failure(_ label: String, _ stderr: [UInt8], diskHint: String? = nil) -> String {
    let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return diskHint.map { "\(label) empty (command exited with no diagnostic). \($0)" }
        ?? "\(label) empty (command exited with no diagnostic)."
    }
    let lower = text.lowercased()
    if let diskHint,
      lower.contains("no space left on device") || lower.contains("disk quota exceeded")
    {
      return "\(label):\n\(text)\n\n\(diskHint)"
    }
    return "\(label):\n\(text)"
  }

  static func remoteFailure(_ stderr: [UInt8]) -> String {
    failure("Remote stderr", stderr, diskHint: diskHint)
  }

  static func pullFailure(_ ssh: [UInt8], _ tar: [UInt8]) -> String {
    let blank = { (bytes: [UInt8]) in
      String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    switch (blank(ssh), blank(tar)) {
    case (true, true): return "No diagnostic output from either side."
    case (false, true): return failure("Remote stderr", ssh)
    case (true, false): return failure("Local tar stderr", tar)
    case (false, false):
      return failure("Remote stderr", ssh) + "\n" + failure("Local tar stderr", tar)
    }
  }

  static func rsyncBaseArguments(_ target: SSHTarget, excludeGit: Bool) -> [String] {
    var arguments = ["-az", "-e", target.rsyncSSHCommand]
    // The `.git/` rule precedes the `.gitignore` merge: rsync's first match
    // wins, so a `.gitignore` listing `.git/` cannot strip git state.
    arguments.append(excludeGit ? "--exclude=\(gitExclude)" : "--filter=+ /.git/***")
    arguments.append("--filter=:- .gitignore")
    return arguments + defaultExcludes.map { "--exclude=\($0)" }
  }

  func rsyncPush(_ target: SSHTarget, source: String, to guest: GuestPath, excludeGit: Bool) throws
  {
    let arguments =
      Self.rsyncBaseArguments(target, excludeGit: excludeGit) + [
        "--delete", "\(source)/", "\(target.address):\(guest)/",
      ]
    guard try runner.attached(request(try tool("rsync"), arguments), inheritStdin: true).succeeded
    else { throw HostError("rsync push failed") }
  }

  /// `preserveLinks` (staged pulls) keeps hard links and holes, so a file
  /// linked many times or a sparse file cannot expand on the host before the
  /// stage budgets run; the stage walk then rejects the hard links.
  func rsyncPull(
    _ target: SSHTarget, guest: GuestPath, to destination: String, excludeGit: Bool,
    preserveLinks: Bool = false, cancel: (@Sendable () -> Bool)? = nil
  ) throws {
    let arguments =
      Self.rsyncBaseArguments(target, excludeGit: excludeGit) + (preserveLinks ? ["-H", "-S"] : [])
      + ["\(target.address):\(guest)/", "\(destination)/"]
    var rsync = request(try tool("rsync"), arguments)
    rsync.isCancelled = cancel
    guard try runner.attached(rsync, inheritStdin: true).succeeded
    else { throw HostError("rsync pull failed") }
  }

  func guestHasRsync(_ target: SSHTarget) -> Bool {
    client.succeeds(target, RemoteCommand().literal("which rsync"))
  }

  static func stateOrDefault(_ instance: Instance, directory: String?, command: String) throws
    -> WorkspaceState
  {
    if let state = try WorkspaceState.load(instance) { return state }
    if let directory {
      return WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: directory))
    }
    throw HostError(
      "No workspace.json found and no --dir given.\nEither create/reconnect with `coop up <PATH>` or provide a path: coop \(command) --dir ./my-project"
    )
  }

  static func hostDirectory(_ explicit: String?, _ state: WorkspaceState, command: String) throws
    -> String
  {
    if let explicit { return explicit }
    guard let path = state.source.hostPath else {
      throw HostError(
        "No host_path in workspace.json and no --dir given.\nProvide a directory: coop \(command) --dir ./my-project"
      )
    }
    return path
  }

  /// `coop push`.
  public func push(
    _ running: AppleBackend.Running, directory: String?, force: Bool, excludeGit: Bool
  )
    throws
  {
    let state = try Self.stateOrDefault(running.instance, directory: directory, command: "push")
    let source = try Self.hostDirectory(directory, state, command: "push")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw HostError("Source directory \(source) does not exist") }
    if !force { try checkGuestClean(running.target, state.guestPath) }
    diagnostics.log(.info, "Pushing \(source) -> guest:\(state.guestPath)")
    if guestHasRsync(running.target) {
      try rsyncPush(running.target, source: source, to: state.guestPath, excludeGit: excludeGit)
    } else {
      diagnostics.log(.info, "rsync not available on guest, using tar-pipe")
      try tarPipe(running.target, source: source, to: guestWorkspace, excludeGit: excludeGit)
    }
    diagnostics.log(.info, "Push complete")
  }

  /// `coop pull`.
  public func pull(
    _ running: AppleBackend.Running, directory: String?, force: Bool, excludeGit: Bool
  )
    throws
  {
    let state = try Self.stateOrDefault(running.instance, directory: directory, command: "pull")
    let destination = try Self.hostDirectory(directory, state, command: "pull")
    if !force && FileManager.default.fileExists(atPath: destination) {
      try checkLocalClean(destination)
    }
    do {
      try FileManager.default.createDirectory(
        atPath: destination, withIntermediateDirectories: true)
    } catch {
      throw ContextError("Failed to create \(destination)", cause: error)
    }
    diagnostics.log(.info, "Pulling guest:\(state.guestPath) -> \(destination)")
    if guestHasRsync(running.target) {
      try rsyncPull(running.target, guest: state.guestPath, to: destination, excludeGit: excludeGit)
    } else {
      diagnostics.log(.info, "rsync not available on guest, using tar-pipe")
      try tarPull(running.target, guest: state.guestPath, to: destination, excludeGit: excludeGit)
    }
    BoundaryAudit.record(running.instance, .pullDirect, diagnostics: diagnostics)
    diagnostics.log(.info, "Pull complete")
  }

  /// `coop diff`, `coop pull --review`, and `coop pull` in stage mode: pull
  /// into a fresh stage (never the destination) and describe it. A budget
  /// overrun or transfer failure discards the stage.
  public func stage(
    _ running: AppleBackend.Running, directory: String?, excludeGit: Bool, limits: StageLimits
  ) throws -> StageManifest {
    try stage(
      instance: running.instance, target: running.target, directory: directory,
      excludeGit: excludeGit, limits: limits)
  }

  func stage(
    instance: Instance, target: SSHTarget, directory: String?, excludeGit: Bool,
    limits: StageLimits
  ) throws -> StageManifest {
    let state = try Self.stateOrDefault(instance, directory: directory, command: "pull")
    let requested = try Self.hostDirectory(directory, state, command: "pull")
    // Absolute before it is stored: `--apply` may run from another directory.
    let absolute =
      requested.hasPrefix("/")
      ? requested : FileManager.default.currentDirectoryPath + "/" + requested
    let destination = canonicalPath(absolute) ?? (absolute as NSString).standardizingPath
    let location = StageLocation(instance)
    let lock = try location.lock()
    defer { lock.release() }
    try location.prepare()
    let growth = StageGrowthGuard(tree: location.tree, limits: limits)
    do {
      diagnostics.log(.info, "Staging guest:\(state.guestPath) for \(destination)")
      do {
        if guestHasRsync(target) {
          try rsyncPull(
            target, guest: state.guestPath, to: location.tree, excludeGit: excludeGit,
            preserveLinks: true, cancel: growth.shouldCancel)
        } else {
          diagnostics.log(.info, "rsync not available on guest, using tar-pipe")
          try tarPull(
            target, guest: state.guestPath, to: location.tree, excludeGit: excludeGit,
            sparse: true, cancel: growth.shouldCancel)
        }
      } catch {
        if let breach = growth.breachDescription { throw StageBudgetExceeded(description: breach) }
        throw error
      }
      // rsync/tar carry the guest's root mode, which may deny us the tree.
      // A failure surfaces as a clear error when `StageBuilder` opens the tree.
      _ = chmod(location.tree, 0o700)
      var builder = StageBuilder(tree: location.tree, destination: destination, limits: limits)
      let manifest = try builder.build(
        id: randomHex(4), instance: instance.name.rawValue, excludeGit: excludeGit)
      try location.saveManifest(manifest)
      BoundaryAudit.record(
        instance,
        .pullStage(
          changes: manifest.changes.count, bytes: manifest.stagedBytes,
          applicable: manifest.applicable), diagnostics: diagnostics)
      return manifest
    } catch {
      try? location.remove()
      throw error
    }
  }

  /// `coop pull --apply`: applies the reviewed stage, then removes it.
  public func applyStage(_ instance: Instance, stageID: String?, force: Bool) throws
    -> (manifest: StageManifest, applied: [String])
  {
    let location = StageLocation(instance)
    let lock = try location.lock()
    defer { lock.release() }
    let manifest = try location.loadManifest()
    if let stageID, stageID != manifest.id {
      throw HostError(
        "The current stage is \(manifest.id), not \(stageID); review it with `coop diff` before applying"
      )
    }
    if !force && FileManager.default.fileExists(atPath: manifest.destination) {
      try checkLocalClean(manifest.destination)
    }
    do {
      try FileManager.default.createDirectory(
        atPath: manifest.destination, withIntermediateDirectories: true)
    } catch {
      throw ContextError("Failed to create \(manifest.destination)", cause: error)
    }
    let applied = try StageApplier(manifest: manifest, tree: location.tree).apply()
    BoundaryAudit.record(instance, .pullApply(applied: applied.count), diagnostics: diagnostics)
    try location.remove()
    return (manifest, applied)
  }

  /// `coop pull --discard`. Returns whether a stage existed.
  public func discardStage(_ instance: Instance) throws -> Bool {
    let location = StageLocation(instance)
    let lock = try location.lock()
    defer { lock.release() }
    guard location.exists else { return false }
    try location.remove()
    return true
  }

  /// One-time copy of each mount into the guest.
  public func syncMountContents(_ target: SSHTarget, _ mounts: [Mount], excludeGit: Bool) throws {
    for mount in mounts {
      try client.exec(
        target,
        RemoteCommand().literal("sudo mkdir -p ").arg(mount.guestPath.rawValue)
          .literal(" && sudo chown ubuntu:ubuntu ").arg(mount.guestPath.rawValue))
      diagnostics.log(.info, "Syncing \(mount.hostPath) -> guest:\(mount.guestPath)")
      if guestHasRsync(target) {
        try rsyncPush(target, source: mount.hostPath, to: mount.guestPath, excludeGit: excludeGit)
      } else {
        diagnostics.log(.info, "rsync not available on guest, using tar-pipe")
        try tarPipe(target, source: mount.hostPath, to: mount.guestPath, excludeGit: excludeGit)
      }
    }
  }

  /// Syncs mounts and records the first as the workspace identity.
  public func syncMounts(
    _ target: SSHTarget, _ instance: Instance, _ mounts: [Mount], excludeGit: Bool
  ) throws {
    try syncMountContents(target, mounts, excludeGit: excludeGit)
    if let first = mounts.first {
      try WorkspaceState(guestPath: first.guestPath, source: .mount(hostPath: first.hostPath))
        .save(instance, diagnostics: diagnostics)
    }
  }

  /// Tracked-file edits and unpushed commits in the guest block a push;
  /// untracked files (usually host-side noise copied in) do not.
  func checkGuestClean(_ target: SSHTarget, _ guest: GuestPath) throws {
    let command = RemoteCommand().literal("if [ -d ").arg(guest.rawValue).literal(
      "/.git ]; then cd "
    )
    .arg(guest.rawValue)
    .literal(
      " && git status --porcelain --untracked-files=no && if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null); if [ \"${ahead:-0}\" -gt 0 ]; then echo \"AHEAD $ahead\"; fi; fi; fi"
    )
    let output: ProcessRunner.Output
    do {
      // Drained, not failed, past the limit: a truncated listing is still
      // non-empty, so it reports the changes rather than an I/O error.
      output = try runner.capture(
        request(try client.ssh(), target.sshOptions + [target.address, command.rendered])
          .with(overflow: .drain))
    } catch {
      throw ContextError("Failed to check guest workspace status", cause: error)
    }
    let stdout = sanitizeForDisplay(String(decoding: output.stdout, as: UTF8.self))
    if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw HostError(
        "Guest workspace has changes the host does not know about:\n\(stdout)\nPull them with `coop pull`, or overwrite with `coop push --force`."
      )
    }
  }

  func checkLocalClean(_ destination: String) throws {
    guard FileManager.default.fileExists(atPath: destination + "/.git") else { return }
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        request(try tool("git"), ["-C", destination, "status", "--porcelain"])
          .with(overflow: .drain))
    } catch {
      throw ContextError("Failed to check local git status", cause: error)
    }
    let stdout = String(decoding: output.stdout, as: UTF8.self)
    if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw HostError(
        "Local directory has uncommitted changes:\n\(stdout)\nUse --force to overwrite")
    }
  }
}
