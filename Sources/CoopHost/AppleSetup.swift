import CoopConfiguration
import CoopCore
import CryptoKit
import Foundation

public struct SetupOptions: Sendable {
  public var rebuild: Bool
  public var profiles: [ProfileDefinition]
  public var image: ImageName
  public var guestUser: GuestUser
  /// Overrides `apple_container.build_timeout_seconds` for this run.
  public var builderTimeout: Duration?
  /// devcontainer Features resolved from the registry, installed in order.
  public var ociFeatures: [ResolvedFeature]

  public init(
    rebuild: Bool, profiles: [ProfileDefinition], image: ImageName, guestUser: GuestUser,
    builderTimeout: Duration?, ociFeatures: [ResolvedFeature] = []
  ) {
    self.rebuild = rebuild
    self.profiles = profiles
    self.image = image
    self.guestUser = guestUser
    self.builderTimeout = builderTimeout
    self.ociFeatures = ociFeatures
  }
}

/// `template-config.json` as the Apple backend writes it.
struct TemplateRecord: Encodable {
  let version: UInt32
  let created: String
  let installScriptHash: String
  let profiles: [String]
  let guestUser: GuestUser
  let ociFeatures: [InstalledFeature]

  func encode(to encoder: any Encoder) throws {
    enum Keys: String, CodingKey {
      case version, created, profiles, marketplaces, plugins
      case installScriptHash = "install_script_hash"
      case extraPackages = "extra_packages"
      case postInstallHash = "post_install_hash"
      case codexMarketplaces = "codex_marketplaces"
      case codexPlugins = "codex_plugins"
      case guestUser = "guest_user"
      case ociFeatures = "oci_features"
    }
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(version, forKey: .version)
    try c.encode(created, forKey: .created)
    try c.encode(installScriptHash, forKey: .installScriptHash)
    try c.encode(profiles, forKey: .profiles)
    try c.encode([String](), forKey: .extraPackages)
    try c.encodeNil(forKey: .postInstallHash)
    try c.encode([String](), forKey: .marketplaces)
    try c.encode([String](), forKey: .plugins)
    try c.encode([String](), forKey: .codexMarketplaces)
    try c.encode([String](), forKey: .codexPlugins)
    try c.encode(guestUser, forKey: .guestUser)
    try c.encode(ociFeatures, forKey: .ociFeatures)
  }
}

extension AppleBackend {
  /// Oldest macOS release whose vmnet networks the runtime supports.
  static let minimumMacOSMajor = 26

  func checkPlatform() throws {
    #if !arch(arm64)
      throw RuntimeError.unavailable("the Apple sandbox backend requires an Apple Silicon Mac")
    #endif
    let version = ProcessInfo.processInfo.operatingSystemVersion
    guard version.majorVersion >= Self.minimumMacOSMajor else {
      throw RuntimeError.unavailable(
        "the Apple sandbox backend requires macOS \(Self.minimumMacOSMajor) or later (found \(version.majorVersion).\(version.minorVersion).\(version.patchVersion))"
      )
    }
  }

  /// `<state root>/vm_key`: the coop VM-access key, generated once.
  func ensureSSHKey() throws {
    let key = config.sshKeyPath.path
    guard !FileManager.default.fileExists(atPath: key) else { return }
    let output = try ProcessRunner().capture(
      .init(
        executable: "/usr/bin/ssh-keygen",
        arguments: ["-t", "ed25519", "-N", "", "-q", "-C", "coop-apple", "-f", key],
        environment: environment, deadline: .seconds(60)))
    guard output.termination == .exited(0) else {
      throw ContextError(
        "Failed to generate the VM access key",
        cause: HostError(
          "/usr/bin/ssh-keygen -t ed25519 -N  -q -C coop-apple -f \(key) exited with \(output.termination)"
        ))
    }
  }

  func initializeRuntime(_ runtime: SandboxRuntime) throws {
    guard
      let kernel = config.appleContainer.kernel?.path
        ?? environment["HOME"].map({
          $0 + "/Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
        })
    else { throw HostError("no kernel path: set `apple_container.kernel`") }
    do {
      try StateStore.ensurePrivateDirectory(runtime.root)
      try runtime.initialize(kernel: kernel)
    } catch {
      throw RuntimeError.unavailable(
        "failed to initialize the sandbox runtime with kernel \(kernel): \(oneLine(error)). The kernel is installed by Apple `container` (`container system start`), or set `apple_container.kernel` to a validated kernel."
      )
    }
  }

  func buildTimeout(_ options: SetupOptions) -> Duration {
    options.builderTimeout ?? config.appleContainer.buildTimeout.duration
  }

  /// The disk maintenance image the runtime boots (networkless) to grow and
  /// commit disks. Reinstalled only when its recipe version changes.
  func ensureMaintenance(_ runtime: SandboxRuntime, owner: Owner, options: SetupOptions) throws {
    if try runtime.maintenanceInspect()?.version == BuildContext.maintenanceVersion { return }
    let builder = try ImageBuilder.open(config, environment: environment)
    try builder.requireService()
    let reference = BuildContext.maintenanceRef(owner: owner.id, buildID: randomHex(4))
    let context = try BuildContext.maintenanceContext()
    defer { context.remove() }
    let log = config.stateRoot.appending("maintenance-build.log").path
    try AtomicFile.write([], to: log, mode: .atMost(0o600))
    diagnostics.log(.info, "Building the disk maintenance image \(reference) (log: \(log))")
    let installed = Result { () throws -> MaintenanceArtifact? in
      _ = try builder.buildIntoRuntime(
        reference: reference, context: context.path, log: log, timeout: buildTimeout(options),
        runtime: runtime)
      return try runtime.maintenanceInstall(
        image: reference, version: BuildContext.maintenanceVersion)
    }
    runtime.deleteImageBestEffort(reference, diagnostics: diagnostics)
    let artifact = try installed.get()
    guard let artifact, artifact.version == BuildContext.maintenanceVersion,
      artifact.reference == reference
    else {
      throw RuntimeError.unqualified(
        "installing maintenance image \(reference) reported \(String(describing: artifact))")
    }
  }

  /// Prepare the runtime and build the named image, unless an up-to-date
  /// image with the same inputs is already verified.
  public func setup(_ options: SetupOptions) throws {
    _ = try config.validated()
    try checkPlatform()
    let runtime = try runtime()
    let identity = try runtime.requireQualified()
    diagnostics.log(.info, "Sandbox runtime: \(identity)")
    let owner = try Owner.loadOrInit(config)
    try ensureSSHKey()
    try initializeRuntime(runtime)
    try ensureMaintenance(runtime, owner: owner, options: options)

    let publicKeyPath = config.sshKeyPath.path + ".pub"
    guard let publicKeyData = FileManager.default.contents(atPath: publicKeyPath) else {
      throw HostError("Failed to read \(publicKeyPath)")
    }
    let publicKey = String(decoding: publicKeyData, as: UTF8.self).trimmingUnicodeWhitespace()
    let fingerprint: String
    do { fingerprint = try HostPublicKey(parsing: publicKey).fingerprint } catch {
      throw HostError(
        "VM access key \(publicKeyPath) \(error.description.replacingOccurrences(of: "APPLE_HOST_KEY_CHANGED: guest host public key ", with: "")); delete it and rerun `coop setup` to regenerate it"
      )
    }
    let context = BuildContext.render(
      publicKey: publicKey, profiles: options.profiles, guestUser: options.guestUser,
      ociFeatures: options.ociFeatures)
    let manifestID = context.manifestID(
      guestUser: options.guestUser, publicKeyFingerprint: fingerprint)
    let previous = ImageManifest.loadLenient(config, options.image, diagnostics: diagnostics)
    if !options.rebuild, let previous, previous.manifestID == manifestID,
      (try? runtime.verifyImage(previous)) != nil
    {
      diagnostics.log(.info, "Image '\(options.image)' is up to date (\(previous.imageRef))")
      return
    }
    let builder = try ImageBuilder.open(config, environment: environment)
    try builder.requireService()
    let reference = BuildContext.imageRef(
      owner: owner.id, manifestID: manifestID, buildID: randomHex(4))
    let imageDirectory = config.imagesDirectory.appending(options.image.rawValue).path
    try StateStore.ensurePrivateDirectory(imageDirectory)
    let log = imageDirectory + "/build.log"
    try AtomicFile.write([], to: log, mode: .atMost(0o600))
    let materialized = try context.materialize()
    defer { materialized.remove() }
    diagnostics.log(.info, "Building image '\(options.image)' as \(reference) (log: \(log))")
    let digest: String
    do {
      digest = try builder.buildIntoRuntime(
        reference: reference, context: materialized.path, log: log, timeout: buildTimeout(options),
        runtime: runtime)
      try verifyImageInSandbox(
        runtime, owner: owner, reference: reference, guestUser: options.guestUser)
    } catch {
      runtime.deleteImageBestEffort(reference, diagnostics: diagnostics)
      throw error
    }
    let created = utcTimestamp()
    try ImageManifest(
      schemaVersion: StateSchema.version, backend: StateSchema.backend, imageRef: reference,
      digest: digest, disk: nil,
      manifestID: manifestID, baseImage: BuildContext.baseImage, platform: BuildContext.platform,
      guestUser: options.guestUser, created: created
    ).save(config, options.image)
    try saveTemplateRecord(options, manifestID: manifestID, created: created)
    if let previous { releaseManifest(runtime, owner: owner, manifest: previous, except: nil) }
    diagnostics.log(.info, "Setup complete. Run `coop up` in a project directory to launch a VM.")
  }

  func saveTemplateRecord(_ options: SetupOptions, manifestID: String, created: String) throws {
    let hash = sha256Hex(Array(manifestID.utf8))
    let record = TemplateRecord(
      version: 2, created: created, installScriptHash: hash, profiles: options.profiles.map(\.name),
      guestUser: options.guestUser, ociFeatures: options.ociFeatures.map(\.installed))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let path = config.imagesDirectory.appending(options.image.rawValue).appending(
      "template-config.json"
    ).path
    do {
      try AtomicFile.write(
        Array(try encoder.encode(record)), to: path, mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write \(path)", cause: error)
    }
  }

  /// Boot the new image once in a disposable sandbox and check its tools,
  /// guest user and services. The sandbox is always removed; its host key
  /// is never pinned.
  func verifyImageInSandbox(
    _ runtime: SandboxRuntime, owner: Owner, reference: String, guestUser: GuestUser
  ) throws {
    let machine = try MachineName.generate(for: owner.id, randomHex: randomHex(8))
    diagnostics.log(.info, "Verifying image in disposable sandbox \(machine)")
    let expected = IsolationGate.Expected(
      sandbox: machine, owner: owner.id, runtimeRoot: runtime.root,
      resources: Resources(cpus: 2, memoryBytes: 2048 << 20))
    let result = Result { () throws in
      try runtime.create(
        machine, source: .image(reference), cpus: 2, memoryMiB: 2048,
        diskGiB: UInt64(config.vm.templateSize.value),
        owner: owner.id)
      try IsolationGate.verifyRecord(try runtime.inspect(machine), expected)
      let deadline = ContinuousClock.now + runtime.settings.bootTimeout.duration
      _ = try bootValidated(runtime, expected, until: deadline)
      try checkImageContents(runtime, machine, guestUser: guestUser)
    }
    do {
      if try runtime.exists(machine) {
        if try runtime.inspect(machine).status != .stopped { try stopAndConfirm(runtime, machine) }
        try deleteSandbox(runtime, machine, owner: owner.id)
      }
    } catch {
      diagnostics.warn("Failed to clean up verification sandbox \(machine): \(oneLine(error))")
    }
    try result.get()
  }

  func checkImageContents(_ runtime: SandboxRuntime, _ machine: MachineName, guestUser: GuestUser)
    throws
  {
    let required = [
      "/usr/bin/docker", "/usr/bin/gh", "\(guestUser.home)/.local/bin/claude",
      "/usr/local/bin/codex",
      "/usr/local/bin/codex-account", "/usr/bin/dbus-run-session", "/usr/bin/gnome-keyring-daemon",
      "/usr/bin/secret-tool",
    ]
    let probe = try runtime.exec(
      machine, timeout: 60,
      ["/bin/sh", "-c", #"for p; do test -x "$p" || printf '%s\n' "$p"; done"#, "sh"] + required,
      limit: SandboxRuntime.textLimit)
    guard probe.termination == .exited(0) else {
      throw HostError(
        "guest check failed: \(sanitizeForDisplay(String(decoding: probe.stderr, as: UTF8.self)))")
    }
    FileHandle.standardError.write(Data("  Verifying installed binaries...\n".utf8))
    let missing = rustLines(String(decoding: probe.stdout, as: UTF8.self)).filter { !$0.isEmpty }
    if !missing.isEmpty {
      throw HostError(
        "Golden image is missing required binaries: \(missing.joined(separator: ", "))\nThe image build completed but these tools were not installed correctly."
      )
    }
    let uid = try runtime.exec(
      machine, timeout: 10, ["/usr/bin/id", "-u", guestUser.rawValue],
      limit: SandboxRuntime.textLimit)
    guard String(decoding: uid.stdout, as: UTF8.self).trimmingUnicodeWhitespace() == "1000" else {
      throw HostError("Image verification failed: guest user \(guestUser) is not uid 1000")
    }
    let deadline = ContinuousClock.now + runtime.settings.bootTimeout.duration
    while true {
      let active = try runtime.exec(
        machine, timeout: 60, ["/usr/bin/systemctl", "is-active", "--quiet", "ssh", "docker"],
        limit: SandboxRuntime.textLimit)
      if active.termination == .exited(0) { return }
      if ContinuousClock.now >= deadline {
        let states = try runtime.exec(
          machine, timeout: 10, ["/usr/bin/systemctl", "is-active", "ssh", "docker"],
          limit: SandboxRuntime.textLimit)
        let text = sanitizeForDisplay(String(decoding: states.stdout, as: UTF8.self))
          .replacingOccurrences(
            of: "\n", with: ", ")
        throw HostError(
          "Image verification failed: services ssh, docker not active in time (\(text))")
      }
      sleep(.seconds(1))
    }
  }
}

/// Lowercase hex SHA-256.
func sha256Hex(_ bytes: [UInt8]) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
