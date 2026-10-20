// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy

/// Guest `/workspace`: where a copied, cloned or mounted project lands.
package let guestWorkspace = GuestPath("/workspace")

/// Reproducible build and cache directories that pulls and recursive
/// `workspace.input` path selections skip. No transfer carries `.git`.
let defaultExcludes = ["node_modules/", "target/", "__pycache__/", ".venv/", ".iso/"]
let gitExclude = ".git/"
/// A return never requests Git administration of any object type; the
/// inventory refuses whatever arrives anyway.
let returnGitExclude = ".git"

/// A host directory synced once into the guest (the Apple runtime has no
/// live mounts). `hostPath` is canonical.
package struct Mount: Sendable, Equatable {
  package let hostPath: String
  package let guestPath: GuestPath

  /// `HOST_PATH[:GUEST_PATH]`; the guest path defaults to `/workspace`.
  package static func parse(_ spec: String) throws -> Mount {
    guard let colon = spec.firstIndex(of: ":") else {
      return try Mount(host: spec, guest: guestWorkspace)
    }
    return try Mount(
      host: String(spec[..<colon]),
      guest: GuestPath.absolute(String(spec[spec.index(after: colon)...])))
  }

  package init(host: String, guest: GuestPath) throws {
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
  package var hostIsGitRepo: Bool { FileManager.default.fileExists(atPath: hostPath + "/.git") }
}

/// `realpath(3)`: absolute, symlinks resolved; nil when the path is missing.
package func canonicalPath(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else { return nil }
  defer { free(resolved) }
  return String(validatingCString: resolved)
}

/// Where the workspace came from, persisted in `workspace.json`.
package enum WorkspaceSource: Sendable, Equatable {
  case workspace(hostPath: String)
  /// Cloned inside the guest; only the URL is recorded.
  case gitRepo(url: String)
  case mount(hostPath: String)

  package var hostPath: String? {
    switch self {
    case .workspace(let path), .mount(let path): path
    case .gitRepo: nil
    }
  }
}

/// `<instance>/workspace.json`, in the Rust host's format.
package struct WorkspaceState: Sendable, Equatable {
  /// Always absolute: a relative path in a hand-edited file is rejected at
  /// load time, before it can reach a remote command.
  package let guestPath: GuestPath
  package let source: WorkspaceSource

  package init(guestPath: GuestPath, source: WorkspaceSource) {
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

  package func save(_ instance: Instance, diagnostics: Diagnostics? = nil) throws {
    do {
      try AtomicFile.write(
        Array(String(json.rendered().dropLast()).utf8), to: instance.workspaceStatePath,
        mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write workspace.json", cause: error)
    }
    diagnostics?.debug("Wrote workspace state to \(instance.workspaceStatePath)")
  }

  package static func load(_ instance: Instance) throws -> WorkspaceState? {
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
        "Failed to parse \(path).\nIf this file was written by a pre-#147 iso the on-disk shape changed; delete it and run `iso up` again to regenerate, or `iso destroy <name>` if the instance is no longer needed.",
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
  package static func loadOrWarn(
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
package enum WorkspaceMountRule: Sendable {
  /// `up --copy`: the project occupies `/workspace`.
  case copyProject
  /// `up --git-repo`: the clone occupies `/workspace`.
  case gitRepoClone
  /// The project is itself mounted at `/workspace`, or there is none.
  case projectMountedOrNone
}

/// A mount set with unique guest paths and, per rule, no extra mount on
/// the project's `/workspace`.
package struct ValidatedMounts: Sendable {
  package let mounts: [Mount]

  package init(_ rule: WorkspaceMountRule, _ mounts: [Mount]) throws {
    let collision: String? =
      switch rule {
      case .copyProject:
        "`iso up --copy` already uses /workspace for the project. Give --extra-mount an explicit non-/workspace guest path, or use `iso up --mount` to mount the project itself."
      case .gitRepoClone:
        "`iso up --git-repo` clones into /workspace. Give --extra-mount an explicit non-/workspace guest path."
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
package struct WorkspaceTransfer: Sendable {
  let client: SSHClient
  let diagnostics: Diagnostics

  package init(client: SSHClient, diagnostics: Diagnostics) {
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
  package func tarPipe(
    _ target: SSHTarget, source: String, to guest: GuestPath, excludeGit: Bool,
    excludes: Bool = true
  ) throws {
    diagnostics.log(.info, "Transferring \(source) to guest:\(guest) via tar-pipe")
    var tarArguments = ["cf", "-"] + (excludes ? defaultExcludes.map { "--exclude=\($0)" } : [])
    if excludeGit { tarArguments.append("--exclude=\(gitExclude)") }
    tarArguments += ["-C", source, "."]
    // Stops bsdtar from packing AppleDouble `._*` sidecars for xattrs.
    var tarEnvironment = client.environment
    tarEnvironment["COPYFILE_DISABLE"] = "1"
    let extract = RemoteCommand().literal("tar xf - -C ").arg(guest.rawValue)
    try target.requireHandoff()
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

  /// Receives the guest workspace into an incoming stage tree with the
  /// qualified host tar. `.git` is never requested (the inventory refuses
  /// it anyway); holes stay holes, so a sparse guest file cannot expand on
  /// the host before the budgets run; no owner, ACL, flag or extended
  /// attribute is applied.
  func tarReceive(
    _ target: SSHTarget, guest: GuestPath, into attempt: ReceiveAttempt,
    receivers: InboundReceivers, cancel: (@Sendable () -> Bool)? = nil
  ) throws {
    let excludes = (defaultExcludes + [returnGitExclude]).map { "--exclude=\($0)" } + ["--sparse"]
    let command = RemoteCommand().literal("tar cf - -C ").arg(guest.rawValue)
      .literal(" \(excludes.joined(separator: " ")) .")
    var producer = request(receivers.ssh, target.sshOptions + [target.address, command.rendered])
    producer.isCancelled = cancel
    var consumer = request(
      receivers.tar,
      [
        "xf", "-", "-C", attempt.tree, "--no-same-owner", "--no-acls", "--no-fflags", "--no-xattrs",
        "--no-mac-metadata",
      ], environment: receivers.environment(client.environment))
    consumer.inheritedDescriptors = [attempt.writerDescriptor]
    try target.requireHandoff()
    let output = try runner.pipeline(producer, consumer)
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
    "The guest disk is likely too small for this workspace. Recreate it with a larger disk: `iso up --disk <GiB> ...`."

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

  /// Receives with the qualified host rsync into an incoming stage tree.
  /// Hard links and holes are kept, so a file linked many times or a
  /// sparse file cannot expand on the host before the budgets run; the
  /// stage walk then rejects the hard links. No owner, group or device is
  /// created, and `.git` is never requested.
  func rsyncReceive(
    _ target: SSHTarget, guest: GuestPath, into attempt: ReceiveAttempt,
    receivers: InboundReceivers, cancel: (@Sendable () -> Bool)? = nil
  ) throws {
    let arguments =
      [
        "-rlptzHS", "-e", try target.rsyncSSHCommand(ssh: receivers.ssh),
        "--exclude=\(returnGitExclude)",
        "--filter=:- .gitignore",
      ]
      + defaultExcludes.map { "--exclude=\($0)" }
      + ["\(target.address):\(guest)/", "\(attempt.tree)/"]
    var rsync = request(
      receivers.rsync, arguments, environment: receivers.environment(client.environment))
    rsync.isCancelled = cancel
    rsync.inheritedDescriptors = [attempt.writerDescriptor]
    try target.requireHandoff()
    let termination = try runner.attached(rsync, inheritStdin: false, deadline: nil)
    guard termination.succeeded else { throw HostError("rsync pull failed (\(termination))") }
  }

  func guestHasRsync(_ target: SSHTarget) throws -> Bool {
    try client.succeedsChecked(target, RemoteCommand().literal("which rsync"))
  }

  static func stateOrDefault(_ instance: Instance, directory: String?, command: String) throws
    -> WorkspaceState
  {
    if let state = try WorkspaceState.load(instance) { return state }
    if let directory {
      return WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: directory))
    }
    throw HostError(
      "No workspace.json found and no --dir given.\nEither create/reconnect with `iso up <PATH>` or provide a path: iso \(command) --dir ./my-project"
    )
  }

  static func hostDirectory(_ explicit: String?, _ state: WorkspaceState, command: String) throws
    -> String
  {
    if let explicit { return explicit }
    guard let path = state.source.hostPath else {
      throw HostError(
        "No host_path in workspace.json and no --dir given.\nProvide a directory: iso \(command) --dir ./my-project"
      )
    }
    return path
  }

  /// `iso push`: one selected-content snapshot of the workspace, sent over
  /// the guest copy without deleting anything there.
  package func push(
    _ running: AppleBackend.Running, directory: String?, force: Bool,
    input: WorkspaceInputConfig
  ) throws {
    let state = try Self.stateOrDefault(running.instance, directory: directory, command: "push")
    let source = try Self.hostDirectory(directory, state, command: "push")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw HostError("Source directory \(source) does not exist") }
    if !force { try checkGuestClean(running.target, state.guestPath) }
    diagnostics.log(.info, "Pushing \(source) -> guest:\(state.guestPath)")
    try sendSnapshot(
      running.target, root: source, to: state.guestPath, input: input,
      budget: InputBudget(input.limits), stateDirectory: running.instance.directory + "/inputs",
      audit: running.instance)
    if !force { commitPushedSnapshot(running.target, state.guestPath) }
    diagnostics.log(.info, "Push complete")
  }

  /// Captures one selected-content snapshot of `root` (INPUT-01) and sends
  /// it with tar: never the live directory, never `.git`, and never a
  /// deletion in the guest. Returns what was selected and omitted.
  @discardableResult
  package func sendSnapshot(
    _ target: SSHTarget, root: String, to guest: GuestPath, input: WorkspaceInputConfig,
    budget: InputBudget, stateDirectory: String, wholeRoot: Bool = false,
    audit instance: Instance? = nil
  ) throws -> InputReport {
    let snapshot = try InputSnapshot.capture(
      root: root, input: input, budget: budget, stateDirectory: stateDirectory,
      wholeRoot: wholeRoot)
    defer { snapshot.remove() }
    Self.describe(snapshot.report, root: root, diagnostics: diagnostics)
    if let instance {
      let report = snapshot.report
      BoundaryAudit.record(
        instance,
        .inputSnapshot(
          snapshotID: snapshot.id, selected: report.selected, bytes: report.bytes,
          secretsOmitted: report.secrets.count,
          otherOmitted: report.excluded.count + report.links.count + report.unsupported.count,
          deletedTracked: report.deletedTracked.count), diagnostics: diagnostics)
    }
    try tarPipe(target, source: snapshot.tree, to: guest, excludeGit: true, excludes: false)
    return snapshot.report
  }

  /// Names only, never contents.
  static func describe(_ report: InputReport, root: String, diagnostics: Diagnostics) {
    diagnostics.log(
      .info,
      "Selected \(report.selected) files (\(report.bytes) bytes) from \(neutralizeControls(root)); \(LocalSecretNames.version) omitted \(report.secrets.count)"
    )
    func list(_ paths: [String]) -> String {
      paths.prefix(10).map(neutralizeControls).joined(separator: ", ")
        + (paths.count > 10 ? ", …" : "")
    }
    if !report.secrets.isEmpty {
      diagnostics.warn(
        "Not sent (credential-looking names; allow one with workspace.input.secret_allow): \(list(report.secrets))"
      )
    }
    if !report.links.isEmpty {
      diagnostics.warn("Not sent (links leaving the selection or chained): \(list(report.links))")
    }
    if !report.unsupported.isEmpty {
      diagnostics.warn("Not sent (hard links or special files): \(list(report.unsupported))")
    }
    if !report.deletedTracked.isEmpty {
      diagnostics.warn(
        "\(report.deletedTracked.count) tracked file(s) deleted on the host are not removed from the guest (outbound removal is not supported): \(list(report.deletedTracked))"
      )
    }
  }

  /// After a first copy, a guest-local repository built only from the sent
  /// bytes, so agents can commit; it is not the host's history. Best
  /// effort.
  func initializeGuestRepository(_ target: SSHTarget, _ guest: GuestPath) {
    let command = RemoteCommand().literal("cd ").arg(guest.rawValue).literal(
      " && command -v git >/dev/null 2>&1 && [ ! -e .git ] && git init -q && git add -A && git -c user.name=iso -c user.email=iso@localhost -c commit.gpgsign=false commit -qm 'iso: selected snapshot of the host workspace' && git rev-parse --short HEAD"
    )
    guard let head = client.capture(target, command.rendered)?.trimmingUnicodeWhitespace(),
      !head.isEmpty
    else { return }
    diagnostics.log(
      .info,
      "Guest \(guest) is a new repository (synthetic commit \(sanitizeForDisplay(head))) built from the selected files; it does not carry the host's history"
    )
  }

  /// After a push into a clean guest repository, commits the pushed tracked
  /// changes so the next push's clean check sees only what the guest itself
  /// changed (the guest repository is synthetic and receives no `.git`).
  /// A branch with an upstream is a real clone (`--git-repo`) and is never
  /// committed to. Best effort; untracked guest files are left alone.
  func commitPushedSnapshot(_ target: SSHTarget, _ guest: GuestPath) {
    let command = RemoteCommand().literal("cd ").arg(guest.rawValue).literal(
      " && [ -d .git ] && command -v git >/dev/null 2>&1 && ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && git add -u && { git diff --cached --quiet || git -c user.name=iso -c user.email=iso@localhost -c commit.gpgsign=false commit -qm 'iso: pushed snapshot of the host workspace'; }"
    )
    _ = client.capture(target, command.rendered)
  }

  /// The host directories a return destination must stay disjoint from:
  /// this instance, the backend state root (every instance, remote shadow,
  /// key and lock), and the user's iso configuration directory.
  static func controlRoots(_ instance: Instance) -> [String] {
    var roots = [instance.directory, WorkspacePolicy.stateRoot(of: instance)]
    if let entry = getpwuid(geteuid()), let home = String(validatingCString: entry.pointee.pw_dir) {
      roots.append(home + "/.iso")
    }
    return roots
  }

  /// `iso pull` in direct mode: receive and validate into a stage, then
  /// apply it in the same invocation through the one installer. Without
  /// `force` only a plan of additions applies; otherwise the whole stage
  /// is kept for review and this throws.
  package func pull(
    _ running: AppleBackend.Running, directory: String?, force: Bool, limits: StageLimits,
    configuredPolicy: CompiledPolicy? = nil
  ) throws -> (manifest: StageManifest, applied: [String]) {
    // The host API refuses direct mode under an enforcing workspace
    // policy, whatever route the caller took to get here.
    try WorkspacePolicy.checkDirectPull(
      running.instance, configured: configuredPolicy, diagnostics: diagnostics)
    let manifest = try stage(
      running, directory: directory, limits: limits, configuredPolicy: configuredPolicy)
    let result = try applyStage(
      running.instance, ApplyRequest(stageID: manifest.id, replace: force, direct: true),
      configuredPolicy: configuredPolicy)
    BoundaryAudit.record(running.instance, .pullDirect, diagnostics: diagnostics)
    return result
  }

  /// `iso diff`, `iso pull --review`, `iso pull` in stage mode, and the
  /// first half of a direct pull: receive into a fresh incoming stage
  /// (never the destination), validate it, and select it. A failed receive
  /// leaves the previously selected stage in place.
  package func stage(
    _ running: AppleBackend.Running, directory: String?, limits: StageLimits,
    configuredPolicy: CompiledPolicy? = nil
  ) throws -> StageManifest {
    try stage(
      instance: running.instance, target: running.target, directory: directory, limits: limits,
      configuredPolicy: configuredPolicy)
  }

  func stage(
    instance: Instance, target: SSHTarget, directory: String?, limits: StageLimits,
    configuredPolicy: CompiledPolicy? = nil, receivers: InboundReceivers = .system
  ) throws -> StageManifest {
    let state = try Self.stateOrDefault(instance, directory: directory, command: "pull")
    let requested = try Self.hostDirectory(directory, state, command: "pull")
    let destination = try ReturnDestination.resolve(
      requested, controlRoots: Self.controlRoots(instance))
    let binding = try WorkspacePolicy.bindStage(
      instance, destination: destination.path, explicitDirectory: directory != nil,
      configured: configuredPolicy, diagnostics: diagnostics)
    try receivers.qualify(runner)
    let location = StageLocation(instance)
    let lock = try location.lock()
    defer { lock.release() }
    let attempt = try ReceiveAttempt(location)
    var promoted = false
    defer { if !promoted { attempt.abandon() } }
    let growth = StageGrowthGuard(tree: attempt.tree, limits: limits)
    diagnostics.log(.info, "Staging guest:\(state.guestPath) for \(destination.path)")
    do {
      // openrsync cannot carry an SSH option holding a quote or backslash
      // (for example a key under such a directory): use the tar receive.
      if try guestHasRsync(target), (try? target.rsyncSSHCommand(ssh: receivers.ssh)) != nil {
        try rsyncReceive(
          target, guest: state.guestPath, into: attempt, receivers: receivers,
          cancel: growth.shouldCancel)
      } else {
        diagnostics.log(.info, "Receiving with tar (guest rsync unavailable or unusable here)")
        try tarReceive(
          target, guest: state.guestPath, into: attempt, receivers: receivers,
          cancel: growth.shouldCancel)
      }
    } catch {
      if let breach = growth.breachDescription { throw StageBudgetExceeded(description: breach) }
      throw error
    }
    guard let quiescent = try attempt.awaitQuiescence() else {
      throw ReturnError(
        .busyWriter, stageID: attempt.id,
        "A receiver for stage \(attempt.id) is still running after the transfer ended; the stage was not accepted"
      )
    }
    defer { _ = quiescent }
    try attempt.checkLayout()
    // rsync/tar carry the guest's root mode, which may deny us the tree.
    // A failure surfaces as a clear error when `StageBuilder` opens the tree.
    _ = chmod(attempt.tree, 0o700)
    var builder = StageBuilder(
      tree: attempt.tree, destination: StageDestinationView(destination, try destination.open()),
      limits: limits)
    let manifest = try builder.build(
      id: attempt.id, instance: instance.name.rawValue, policy: binding)
    try location.promote(attempt, manifest: manifest)
    promoted = true
    BoundaryAudit.record(
      instance,
      .pullStage(
        changes: manifest.changes.count, bytes: manifest.stagedBytes,
        applicable: manifest.applicable, stageID: manifest.id,
        sensitive: manifest.sensitivePaths.count, excluded: manifest.excludedCount),
      diagnostics: diagnostics)
    return manifest
  }

  /// One apply attempt of one exact stage (RET-09/11). `replace` is the
  /// overwrite authority for permitted nonsensitive replacements (an
  /// explicit `--apply --stage-id`, or `--force` on a direct pull);
  /// `sensitive` names every execution-sensitive entry being approved.
  package struct ApplyRequest: Sendable {
    package let stageID: String
    package var replace: Bool
    package var sensitive: [String]
    /// A direct pull applying the stage it just made.
    package var direct: Bool

    package init(stageID: String, replace: Bool, sensitive: [String] = [], direct: Bool = false) {
      self.stageID = stageID
      self.replace = replace
      self.sensitive = sensitive
      self.direct = direct
    }
  }

  /// Checks a request's authority against the plan before anything is
  /// written or locked: exact stage, applicability, overwrite authority and
  /// exactly-named sensitive grants. Missing authority holds the whole
  /// stage.
  static func authorize(_ request: ApplyRequest, _ manifest: StageManifest, instance: String) throws
  {
    let review = StageReview(manifest: manifest, tree: "")
    guard manifest.applicable else {
      throw ReturnError(
        .blockedMetadata, stageID: manifest.id,
        "Stage \(manifest.id) cannot be applied:\n"
          + manifest.issues.map { "  - \(neutralizeControls($0))" }.joined(separator: "\n"))
    }
    var granted = Set<String>()
    let sensitive = Set(manifest.sensitivePaths)
    for operand in request.sensitive {
      guard StageManifestValidator.validPath(operand) else {
        throw HostError(
          "--approve-sensitive takes a workspace-relative path; got \(neutralizeControls(operand))")
      }
      guard granted.insert(operand).inserted else {
        throw HostError("--approve-sensitive \(neutralizeControls(operand)) is given twice")
      }
      guard sensitive.contains(operand) else {
        throw HostError(
          "--approve-sensitive \(neutralizeControls(operand)) does not name a withheld entry of stage \(manifest.id); review it with `iso diff`"
        )
      }
    }
    let missing = manifest.sensitivePaths.filter { !granted.contains($0) }
    guard missing.isEmpty else {
      throw ReturnError(
        .missingSensitiveGrant, stageID: manifest.id,
        "Stage \(manifest.id) has execution-sensitive changes that must be named to apply:\n"
          + missing.map { "  \(neutralizeControls($0))" }.joined(separator: "\n")
          + "\nNothing was written. After reviewing them: \(review.applyCommand(instance: instance))"
      )
    }
    if !request.replace, let replaced = manifest.changes.first(where: \.replaces) {
      throw ReturnError(
        .missingOverwriteAuthority, stageID: manifest.id,
        "Stage \(manifest.id) replaces existing files (\(neutralizeControls(replaced.path)) and possibly more); nothing was written. Review it, then: \(review.applyCommand(instance: instance))\(request.direct ? ", or pull again with --force" : "")"
      )
    }
  }

  /// `iso pull --apply --stage-id`, and the second half of a direct pull:
  /// applies exactly the selected stage through the one installer, then
  /// removes it. Under a policy governing `workspace.pull.apply` the
  /// governed path runs instead (`applyGovernedStage`); `confirm` is the
  /// trusted host-terminal confirmation, nil when none is available.
  package func applyStage(
    _ instance: Instance, _ request: ApplyRequest, configuredPolicy: CompiledPolicy? = nil,
    confirm: StageConfirmation? = nil
  ) throws -> (manifest: StageManifest, applied: [String]) {
    do {
      return try applySelected(
        instance, request, configuredPolicy: configuredPolicy, confirm: confirm)
    } catch let refused as ReturnError {
      BoundaryAudit.record(
        instance,
        .pullHeld(stageID: refused.stageID ?? request.stageID, reason: refused.kind.rawValue),
        diagnostics: diagnostics)
      throw refused
    }
  }

  private func applySelected(
    _ instance: Instance, _ request: ApplyRequest, configuredPolicy: CompiledPolicy?,
    confirm: StageConfirmation?
  ) throws -> (manifest: StageManifest, applied: [String]) {
    // One load decides both the path and the epoch it was decided under.
    let active = try ActivePolicy.requireBoundIfRequested(
      instance, configured: configuredPolicy, .workspacePullApply)
    let governing = WorkspacePolicy.governing(active)
    if let (binding, policy) = governing, policy.mode == .enforce {
      return try applyGovernedStage(
        instance, request, binding: binding, policy: policy, confirm: confirm)
    }
    let epoch = active.binding?.policyEpoch
    let location = StageLocation(instance)
    // Selection and manifests are replaced atomically, so this unlocked read
    // only checks authority early; everything is re-read under the locks.
    let peeked = try location.loadSelected()
    try Self.requireSelected(request.stageID, peeked.manifest)
    try Self.authorize(request, peeked.manifest, instance: instance.name.rawValue)
    // Lock order: policy, per-user apply, stage.
    let policyLock = try PolicyBinding.lock(instance)
    defer { policyLock.release() }
    // A boot that started since that load may now govern this apply; an
    // unchanged epoch means an unchanged (immutable) policy.
    guard try ActivePolicy.load(instance).binding?.policyEpoch == epoch else {
      throw PolicyDenied(
        reason: .policyEpochMismatch,
        detail: "'\(instance.name)' started a new boot while preparing the apply; run it again")
    }
    let applyLock = try ReturnApplyLock.acquire()
    defer { applyLock.release() }
    let lock = try location.lock()
    defer { lock.release() }
    let selected = try location.loadSelected()
    guard
      WorkspacePolicy.manifestDigest(selected.manifest)
        == WorkspacePolicy.manifestDigest(peeked.manifest)
    else {
      throw ReturnError(
        .drift, stageID: request.stageID,
        "The stage changed while waiting to apply it; review it again")
    }
    if let (binding, policy) = governing {
      reportShadowApply(instance, manifest: selected.manifest, binding: binding, policy: policy)
    }
    return try install(instance, selected, request, location: location, receipt: nil)
  }

  static func requireSelected(_ stageID: String, _ manifest: StageManifest) throws {
    guard stageID == manifest.id else {
      throw ReturnError(
        .wrongStage, stageID: manifest.id,
        "The selected stage is \(manifest.id), not \(neutralizeControls(stageID)); review it with `iso diff` before applying"
      )
    }
  }

  /// The common final section of every apply, under the locks: complete
  /// preflight (destination identity, every old observation and parent,
  /// gitfiles, every staged byte, receiver quiescence), the durable begin
  /// record that consumes this attempt, then the writes.
  func install(
    _ instance: Instance, _ selected: SelectedStage, _ request: ApplyRequest,
    location: StageLocation, receipt: String?, beforeBegin: () throws -> Void = {}
  ) throws -> (manifest: StageManifest, applied: [String]) {
    let manifest = selected.manifest
    try Self.authorize(request, manifest, instance: instance.name.rawValue)
    if try ApplyAttemptRecord.load(location, stageID: manifest.id) != nil {
      throw ReturnError(
        .consumed, stageID: manifest.id,
        "Stage \(manifest.id) was already applied once (an attempt began)\(Self.describeProgress(ApplyAttemptRecord.progress(location, stageID: manifest.id), manifest)); re-stage with `iso diff` to review what remains"
      )
    }
    let applier = StageApplier(manifest: manifest, tree: selected.stage.tree)
    let verified = try applier.destination.open()
    try applier.preflight(verified)
    try applier.verifyStage()
    guard
      case .quiescent(let hold) = try ReceiveLease.probe(
        selected.stage.leasePath, treeExists: true)
    else {
      throw ReturnError(
        .busyWriter, stageID: manifest.id, "A receiver may still be writing stage \(manifest.id)")
    }
    defer { _ = hold }
    try beforeBegin()
    let record = ApplyAttemptRecord(
      stageID: manifest.id, attemptID: randomHex(8),
      planDigest: WorkspacePolicy.manifestDigest(manifest), destination: manifest.destination,
      binding: manifest.binding, replace: request.replace, sensitive: request.sensitive.sorted(),
      receipt: receipt, beganAt: utcTimestamp())
    let log = try record.begin(location)
    let applied: [String]
    do {
      applied = try applier.apply(verified, log: log)
    } catch var partial as StageApplyError {
      try? log.append("outcome partial")
      partial.stageID = manifest.id
      BoundaryAudit.record(
        instance, .pullApplyPartial(applied: partial.applied.count), diagnostics: diagnostics)
      throw partial
    }
    try? log.append("outcome applied")
    BoundaryAudit.record(instance, .pullApply(applied: applied.count), diagnostics: diagnostics)
    try StageLocation.removeTree(selected.stage.directory)
    try location.clearSelection()
    try ApplyAttemptRecord.remove(location, stageID: manifest.id)
    return (manifest, applied)
  }

  /// What an earlier attempt's log records, classified per change: an
  /// interrupted change (started, not finished) may be partly written and
  /// is named so it can be checked by hand. Nothing is inferred as success.
  static func describeProgress(_ progress: ApplyProgress, _ manifest: StageManifest) -> String {
    let uncertain = progress.started.subtracting(progress.finished).sorted().compactMap {
      manifest.changes.indices.contains($0) ? manifest.changes[$0].path : nil
    }
    var parts = [
      "outcome \(progress.outcome ?? "unknown")",
      "\(progress.finished.count) of \(manifest.changes.count) change(s) finished",
    ]
    if !uncertain.isEmpty {
      parts.append(
        "interrupted, check by hand: \(uncertain.map(sanitizeForDisplay).joined(separator: ", "))")
    }
    if progress.createdRoot { parts.append("it created the destination directory") }
    return " (" + parts.joined(separator: "; ") + ")"
  }

  /// Shadow mode: the hypothetical decision, without prompting, minting or
  /// consuming an approval, or changing the apply.
  /// Applies the same stage-binding checks the enforcing path would, so a
  /// stage enforcement would refuse is never reported as allowed.
  func reportShadowApply(
    _ instance: Instance, manifest: StageManifest, binding: PolicyBinding, policy: CompiledPolicy
  ) {
    let evaluation = ApprovalCheck.evaluate(policy, instance: instance.name.rawValue)
    let staged = manifest.policy
    let attached = (try? WorkspacePolicy.attachedWorkspace(instance)) ?? nil
    let reason: PolicyReason
    if staged == nil || staged?.policyEpoch != binding.policyEpoch
      || staged?.instanceID != binding.instanceID || staged?.policyDigest != policy.digest
    {
      reason = attached == manifest.destination ? .policyEpochMismatch : .unsupportedPath
    } else if attached != manifest.destination
      || WorkspacePolicy.identity(path: manifest.destination) != staged?.destinationIdentity
    {
      reason = .unsupportedPath
    } else {
      switch evaluation.outcome {
      case .denied(let denied): reason = denied
      case .notGoverned: reason = .notGoverned
      case .permitted: reason = evaluation.requiresApproval ? .approvalRequired : .allowed
      }
    }
    let verdict: PolicyVerdict = reason == .allowed ? .allow : .deny
    BoundaryAudit.record(
      instance,
      .policyDecision(
        action: .workspacePullApply, outcome: .decided(verdict, reason),
        decisionID: UUID().uuidString.lowercased(), digest: policy.digest, shadow: true),
      diagnostics: diagnostics)
    diagnostics.log(
      .info,
      "policy shadow: stage \(manifest.id) apply would be \(verdict.rawValue) (\(reason.rawValue))")
  }

  /// `iso pull --discard`: removes the selected stage, a finished incoming
  /// receive and a legacy stage. Never deletes a tree a receiver may still
  /// write. Returns whether anything existed.
  package func discardStage(_ instance: Instance) throws -> Bool {
    let location = StageLocation(instance)
    let lock = try location.lock()
    defer { lock.release() }
    return try location.discard()
  }

  /// One-time copy of each mount into the guest: each explicitly named
  /// mount root is its own whole-root selection, under the operation's
  /// shared budget and the same secret-name and `.git` rules.
  package func syncMountContents(
    _ target: SSHTarget, _ mounts: [Mount], input: WorkspaceInputConfig, budget: InputBudget,
    stateDirectory: String
  ) throws {
    for mount in mounts {
      try client.exec(
        target,
        RemoteCommand().literal("sudo mkdir -p ").arg(mount.guestPath.rawValue)
          .literal(" && sudo chown ").arg("\(target.user):\(target.user)").literal(" ")
          .arg(mount.guestPath.rawValue))
      diagnostics.log(.info, "Syncing \(mount.hostPath) -> guest:\(mount.guestPath)")
      try sendSnapshot(
        target, root: mount.hostPath, to: mount.guestPath, input: input, budget: budget,
        stateDirectory: stateDirectory, wholeRoot: true)
    }
  }

  /// Syncs mounts and records the first as the workspace identity.
  package func syncMounts(
    _ target: SSHTarget, _ instance: Instance, _ mounts: [Mount], input: WorkspaceInputConfig,
    budget: InputBudget
  ) throws {
    try syncMountContents(
      target, mounts, input: input, budget: budget,
      stateDirectory: instance.directory + "/inputs")
    if let first = mounts.first {
      try WorkspaceState(guestPath: first.guestPath, source: .mount(hostPath: first.hostPath))
        .save(instance, diagnostics: diagnostics)
    }
  }

  /// What a guest preflight reported about the workspace a push would
  /// overwrite (PUSH). Only `notRepository` and `clean` permit an ordinary
  /// push. This protects a cooperative guest's work; a hostile guest can
  /// report anything.
  package enum GuestWorkspaceState: Equatable, Sendable {
    case notRepository
    /// Clean; `upstream` is false when no tracking branch is configured,
    /// so its commits may exist nowhere else.
    case clean(upstream: Bool)
    case dirty(String)
    case unknown(String)

    var permitsPush: Bool {
      switch self {
      case .notRepository, .clean: true
      case .dirty, .unknown: false
      }
    }
  }

  /// The preflight script: every Git step's status is checked, a `.git`
  /// file (worktree, submodule) counts as a repository, and a configured
  /// but unresolvable upstream is unknown, not clean. The output ends with
  /// `ISO-END`, so truncated or interrupted output is never clean.
  static func guestStateCommand(_ guest: GuestPath) -> RemoteCommand {
    RemoteCommand().literal("if [ ! -d ").arg(guest.rawValue).literal(
      " ]; then echo ISO-NOT-REPO; echo ISO-END; exit 0; fi; cd "
    ).arg(guest.rawValue).literal(
      #" || exit 3; if [ ! -e .git ]; then echo ISO-NOT-REPO; echo ISO-END; exit 0; fi; "#
        + #"git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo ISO-UNKNOWN repository; echo ISO-END; exit 0; }; "#
        + #"status=$(git status --porcelain --untracked-files=no) || { echo ISO-UNKNOWN status; echo ISO-END; exit 0; }; "#
        + #"if [ -n "$status" ]; then echo ISO-DIRTY; printf '%s\n' "$status"; fi; "#
        + #"if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then "#
        + #"ahead=$(git rev-list --count '@{u}..HEAD') || { echo ISO-UNKNOWN ahead; echo ISO-END; exit 0; }; "#
        + #"if [ "$ahead" -gt 0 ]; then echo "ISO-AHEAD $ahead"; fi; echo ISO-UPSTREAM; "#
        + #"else branch=$(git symbolic-ref -q --short HEAD); "#
        + #"if [ -n "$branch" ] && git config "branch.$branch.merge" >/dev/null 2>&1; then echo ISO-UNKNOWN upstream; "#
        + #"else echo ISO-NO-UPSTREAM; fi; fi; echo ISO-END"#)
  }

  /// Parses the preflight output; anything malformed is unknown.
  static func parseGuestState(_ output: ProcessRunner.Output) -> GuestWorkspaceState {
    guard output.termination.succeeded else {
      return .unknown("the guest check exited with \(output.termination)")
    }
    let text = sanitizeForDisplay(String(decoding: output.stdout, as: UTF8.self))
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while lines.last == "" { lines.removeLast() }
    guard lines.last == "ISO-END", !output.truncated else {
      return text.contains("ISO-DIRTY")
        ? .dirty(text) : .unknown("the guest check's output was incomplete")
    }
    lines.removeLast()
    if lines == ["ISO-NOT-REPO"] { return .notRepository }
    if let unknown = lines.first(where: { $0.hasPrefix("ISO-UNKNOWN") }) {
      return .unknown("git could not determine the \(unknown.dropFirst("ISO-UNKNOWN ".count))")
    }
    var dirty: [String] = []
    var upstream: Bool? = nil
    var inStatus = false
    for line in lines {
      switch line {
      case "ISO-DIRTY": inStatus = true
      case "ISO-UPSTREAM":
        upstream = true
        inStatus = false
      case "ISO-NO-UPSTREAM":
        upstream = false
        inStatus = false
      case _ where line.hasPrefix("ISO-AHEAD "):
        guard let count = Int(line.dropFirst("ISO-AHEAD ".count)), count > 0 else {
          return .unknown("malformed ahead count")
        }
        dirty.append("AHEAD \(count)")
        inStatus = false
      case _ where inStatus: dirty.append(line)
      default: return .unknown("unexpected output from the guest check")
      }
    }
    guard let upstream else { return .unknown("the guest check reported no upstream state") }
    return dirty.isEmpty ? .clean(upstream: upstream) : .dirty(dirty.joined(separator: "\n"))
  }

  func guestState(_ target: SSHTarget, _ guest: GuestPath) throws -> GuestWorkspaceState {
    let output: ProcessRunner.Output
    do {
      try target.requireHandoff()
      output = try runner.capture(
        request(
          try client.ssh(),
          target.sshOptions + [target.address, Self.guestStateCommand(guest).rendered]
        ).with(overflow: .drain))
    } catch let error as GuestHandoffFailure {
      throw error
    } catch {
      return .unknown("ssh failed: \(oneLine(error))")
    }
    return Self.parseGuestState(output)
  }

  /// Blocks a push unless the guest workspace is known safe to overwrite:
  /// not a repository, or clean with nothing unpushed. Failures, malformed
  /// output and a broken upstream block too; `--force` is the explicit
  /// authority to overwrite guest work.
  func checkGuestClean(_ target: SSHTarget, _ guest: GuestPath) throws {
    switch try guestState(target, guest) {
    case .notRepository, .clean: return
    case .dirty(let detail):
      throw HostError(
        "Guest workspace has changes the host does not know about:\n\(detail)\nPull them with `iso pull`, or overwrite with `iso push --force`."
      )
    case .unknown(let why):
      throw HostError(
        "Cannot tell whether the guest workspace has unsaved work (\(why)); refusing to overwrite it. Inspect it with `iso shell`, or overwrite with `iso push --force`."
      )
    }
  }
}
