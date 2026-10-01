import Foundation
import IsoConfiguration
import IsoCore

/// Mutating `iso-sandbox` calls. Argument vectors, deadlines, output limits
/// and cancellability match the Rust host exactly: only create and boot are
/// cancellable, so stop, delete and cleanup finish even after Ctrl-C.
extension SandboxRuntime {
  public static let pubkeyLimit = 16 << 10

  var probeDeadline: Duration { settings.probeTimeout.duration }
  var operationDeadline: Duration { settings.operationTimeout.duration }
  var createDeadline: Duration { settings.createTimeout.duration }
  var bootDeadline: Duration { settings.bootTimeout.duration }
  var stopDeadline: Duration { settings.stopTimeout.duration }

  func checked(
    _ subcommand: [String], _ rest: [String], deadline: Duration, limit: Int,
    cancellable: Bool = false
  ) throws(RuntimeError) -> [UInt8] {
    try Self.checked(
      executor, arguments(subcommand, rest), deadline: deadline, limit: limit,
      cancellable: cancellable)
  }

  /// Validates the kernel against the runtime's pinned list and prepares
  /// its state root.
  public func initialize(kernel: String) throws(RuntimeError) {
    _ = try checked(
      ["init"], ["--kernel", kernel], deadline: createDeadline, limit: Self.textLimit)
  }

  public enum Source: Sendable {
    case image(String)
    case disk(MachineName)
  }

  public func create(
    _ name: MachineName, source: Source, cpus: UInt32, memoryMiB: UInt64, diskGiB: UInt64,
    owner: OwnerID, egress: EgressMode
  ) throws(RuntimeError) {
    let from: [String] =
      switch source {
      case .image(let reference): ["--image", reference]
      case .disk(let disk): ["--from-disk", disk.rawValue]
      }
    _ = try checked(
      ["create"],
      [name.rawValue] + from + [
        "--cpus", String(cpus), "--memory-mib", String(memoryMiB), "--disk-gib", String(diskGiB),
        "--owner",
        owner.rawValue,
      ] + (egress.requiresHostOnlyNetwork ? ["--network", "host-only"] : []),
      deadline: createDeadline,
      limit: Self.jsonLimit, cancellable: true)
  }

  /// `expiresAt` bounds this boot's session (the owner halts the VM then).
  public func start(_ name: MachineName, expiresAt: Date? = nil) throws(RuntimeError) {
    _ = try checked(
      ["start"],
      [name.rawValue, "--wait-seconds", String(settings.bootTimeout.seconds)]
        + (expiresAt.map { ["--expires-at", String(Int64($0.timeIntervalSince1970))] } ?? []),
      deadline: bootDeadline + .seconds(10), limit: Self.jsonLimit, cancellable: true)
  }

  /// Exit status ignored: callers confirm the state with `inspect`.
  public func stop(_ name: MachineName) throws(RuntimeError) -> ProcessRunner.Output {
    try executor.run(
      arguments(
        ["stop"], [name.rawValue, "--timeout-seconds", String(settings.stopTimeout.seconds)]),
      deadline: stopDeadline + .seconds(120), outputLimit: Self.textLimit, cancellable: false)
  }

  public func delete(_ name: MachineName, owner: OwnerID) throws(RuntimeError) {
    _ = try checked(
      ["delete"], [name.rawValue, "--owner", owner.rawValue], deadline: operationDeadline,
      limit: Self.textLimit)
  }

  public func setResources(
    _ name: MachineName, cpus: UInt32, memoryBytes: UInt64, operation: OperationID,
    expect: OperationID?
  ) throws(RuntimeError) {
    _ = try checked(
      ["set"],
      [
        name.rawValue, "--cpus", String(cpus), "--memory-mib", String(memoryBytes / (1 << 20)),
        "--operation",
        operation.rawValue,
      ] + (expect.map { ["--expect-operation", $0.rawValue] } ?? []),
      deadline: operationDeadline, limit: Self.jsonLimit)
  }

  public func grow(_ name: MachineName, diskGiB: UInt64, operation: OperationID)
    throws(RuntimeError)
  {
    _ = try checked(
      ["grow"], [name.rawValue, "--disk-gib", String(diskGiB), "--operation", operation.rawValue],
      deadline: createDeadline, limit: Self.jsonLimit)
  }

  public func commit(_ name: MachineName, disk: MachineName) throws(RuntimeError) -> RuntimeDisk {
    let output = try checked(
      ["commit"], [name.rawValue, disk.rawValue], deadline: createDeadline, limit: Self.jsonLimit)
    return try RuntimeProtocol.decode(RuntimeDisk.self, output, "commit")
  }

  public func restore(_ name: MachineName, source: Source, operation: OperationID)
    throws(RuntimeError)
  {
    let from: [String] =
      switch source {
      case .disk(let disk): [disk.rawValue]
      case .image(let reference): ["--image", reference]
      }
    _ = try checked(
      ["restore"], [name.rawValue] + from + ["--operation", operation.rawValue],
      deadline: createDeadline,
      limit: Self.jsonLimit)
  }

  /// A fixed command inside the guest over the runtime's own channel; the
  /// caller inspects the exit status.
  public func exec(_ name: MachineName, timeout seconds: UInt32, _ argv: [String], limit: Int)
    throws(RuntimeError)
    -> ProcessRunner.Output
  {
    let seconds = max(1, seconds)
    return try executor.run(
      arguments(["exec"], ["--timeout", String(seconds), name.rawValue, "--"] + argv),
      deadline: .seconds(Int64(seconds) + 30), outputLimit: limit, cancellable: false)
  }

  public func logTail(_ name: MachineName) throws(RuntimeError) -> String {
    let output = try checked(
      ["logs"], [name.rawValue, "-n", "40"], deadline: probeDeadline, limit: Self.jsonLimit)
    return String(decoding: output, as: UTF8.self)
  }

  public func listed(_ name: MachineName) throws(RuntimeError) -> SandboxStatus? {
    try list().first { $0.id == name.rawValue }?.status
  }

  public func exists(_ name: MachineName) throws(RuntimeError) -> Bool { try listed(name) != nil }

  public func importImage(tar: String) throws(RuntimeError) -> [RuntimeImage] {
    try RuntimeProtocol.parseImages(
      checked(
        ["image", "import"], ["--oci-tar", tar], deadline: createDeadline, limit: Self.jsonLimit))
  }

  public func deleteImageBestEffort(_ reference: String, diagnostics: Diagnostics) {
    do {
      _ = try checked(
        ["image", "delete"], [reference], deadline: operationDeadline, limit: Self.textLimit)
    } catch {
      diagnostics.warn("Failed to delete image \(reference): \(error)")
    }
  }

  public func deleteDiskBestEffort(_ disk: String, diagnostics: Diagnostics) {
    do {
      _ = try checked(
        ["disk", "delete"], [disk], deadline: operationDeadline, limit: Self.textLimit)
    } catch {
      diagnostics.warn("Failed to delete committed disk \(disk): \(error)")
    }
  }

  public func reconcileBestEffort(diagnostics: Diagnostics) {
    do {
      _ = try checked(["reconcile"], [], deadline: operationDeadline, limit: Self.jsonLimit)
    } catch {
      diagnostics.warn("Failed to reconcile the sandbox runtime: \(error)")
    }
  }

  public func maintenanceInspect() throws(RuntimeError) -> MaintenanceArtifact? {
    try RuntimeProtocol.parseMaintenance(probe(["maintenance", "inspect"]))
  }

  public func maintenanceInstall(image: String, version: String) throws(RuntimeError)
    -> MaintenanceArtifact?
  {
    try RuntimeProtocol.parseMaintenance(
      checked(
        ["maintenance", "install"], ["--image", image, "--version", version],
        deadline: createDeadline,
        limit: Self.jsonLimit))
  }

  /// The image (or committed disk) a manifest names still exists with the
  /// digest it was verified as.
  public func verifyImage(_ manifest: ImageManifest) throws(RuntimeError) {
    if let disk = manifest.disk {
      guard try disks().contains(where: { $0.name == disk.name.rawValue }) else {
        throw .identityConflict(
          "committed disk \(disk.name) for image \(manifest.imageRef) is missing from the runtime")
      }
      return
    }
    guard let found = try images().first(where: { $0.reference == manifest.imageRef }) else {
      throw .identityConflict(
        "image \(manifest.imageRef) is missing from the runtime; run `iso setup --rebuild`")
    }
    guard found.digest == manifest.digest else {
      throw .identityConflict(
        "image \(manifest.imageRef) now resolves to \(found.digest), but the template was verified as \(manifest.digest); run `iso setup --rebuild`"
      )
    }
  }
}

/// The stock Apple `container` CLI, used only to build images.
public struct ImageBuilder: Sendable {
  let executor: any RuntimeExecutor
  let settings: AppleContainerConfig

  public init(executor: any RuntimeExecutor, settings: AppleContainerConfig) {
    self.executor = executor
    self.settings = settings
  }

  public static func open(_ config: IsoConfig, environment: [String: String]) throws(RuntimeError)
    -> ImageBuilder
  {
    let binary = try BinaryResolver.resolve(
      configured: config.appleContainer.builder?.path, defaults: BinaryResolver.defaultBuilders,
      tool: .builder)
    return ImageBuilder(
      executor: ProcessRuntimeExecutor(binary: binary, parentEnvironment: environment),
      settings: config.appleContainer)
  }

  func checked(_ arguments: [String], deadline: Duration) throws(RuntimeError) -> [UInt8] {
    try SandboxRuntime.checked(
      executor, arguments, deadline: deadline, limit: SandboxRuntime.textLimit, program: "container"
    )
  }

  /// iso never starts or stops the builder's service.
  public func requireService() throws(RuntimeError) {
    do {
      _ = try checked(["system", "status"], deadline: settings.probeTimeout.duration)
    } catch {
      throw .unavailable(
        "the Apple `container` service (used to build images) is not running (\(error)). Start it with `container system start`, then retry."
      )
    }
  }

  /// Build `context` as `reference`, export it, delete the builder's copy,
  /// and import it into the runtime. Returns the imported digest.
  public func buildIntoRuntime(
    reference: String, context: String, log: String, timeout: Duration, runtime: SandboxRuntime
  ) throws -> String {
    let termination = try executor.runLogged(
      [
        "build", "--platform", BuildContext.platform, "--progress", "plain", "-t", reference,
        context,
      ], log: log,
      deadline: timeout, cancellable: true)
    guard termination == .exited(0) else {
      throw HostError("Image build failed. Last lines of \(log):\n\(logTail(log, 4096))")
    }
    let export = try TemporaryDirectory(prefix: "iso-apple-image-")
    defer { export.remove() }
    let tar = export.path + "/image.tar"
    let saved = Result { () throws(RuntimeError) in
      try checked(
        ["image", "save", "--platform", BuildContext.platform, "-o", tar, reference],
        deadline: settings.createTimeout.duration)
    }
    _ = try? checked(["image", "delete", reference], deadline: settings.operationTimeout.duration)
    _ = try saved.get()
    let imported = try runtime.importImage(tar: tar)
    guard let entry = imported.first(where: { $0.reference == reference }) else {
      let references =
        "[" + imported.map { debugQuoted($0.reference) }.joined(separator: ", ") + "]"
      throw RuntimeError.identityConflict(
        "importing \(reference) into the runtime produced \(references)")
    }
    return entry.digest
  }
}

/// The last `max` bytes of a log, sanitized for display.
func logTail(_ path: String, _ max: Int) -> String {
  guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
  defer { try? handle.close() }
  guard let size = try? handle.seekToEnd() else { return "" }
  try? handle.seek(toOffset: size > UInt64(max) ? size - UInt64(max) : 0)
  guard let data = try? handle.readToEnd() else { return "" }
  return sanitizeForDisplay(String(decoding: data, as: UTF8.self))
}
