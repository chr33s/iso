import Foundation
import IsoConfiguration
import IsoCore

extension AppleBackend {
  static let macBuildCPUs: UInt32 = 4
  static let macBuildMemoryMiB: UInt64 = 8192
  static let macDefaultDiskGiB: UInt64 = 64
  static let macCoreAISuffix = "-coreai"

  /// `iso setup --guest macos`: install macOS from the operator's restore image into
  /// a runtime template provisioned by ``MacProvision``, recorded as image
  /// `options.image`. The build uses its own vmnet network; no project content or
  /// host credential is given to it.
  func setupMac(_ options: SetupOptions, ipsw: String, runtime: SandboxRuntime, owner: Owner)
    throws
  {
    try runtime.requireMacGuests()
    guard options.profiles.isEmpty, options.ociFeatures.isEmpty else {
      throw HostError(
        "profiles and devcontainer Features install Linux packages; they are not supported for macOS guests"
      )
    }
    guard options.guestUser == .default || options.guestUser == MacProvision.guestUser else {
      throw HostError("macOS guests always use the guest user '\(MacProvision.guestUser)'")
    }
    let restore = URL(fileURLWithPath: ipsw).standardizedFileURL.path
    var status = stat()
    guard stat(restore, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw HostError("macOS restore image \(restore) is not a regular file")
    }
    let script = MacProvision.script()
    let provisionSHA = sha256Hex(Array(script.utf8))
    let previous = ImageManifest.loadLenient(config, options.image, diagnostics: diagnostics)
    if let previous, previous.guestOS != .macos, !options.rebuild {
      throw HostError(
        "Image '\(options.image)' is a Linux image; choose another name with --image, or replace it with --rebuild"
      )
    }
    // The restore image (many GiB) is hashed only when everything cheaper
    // says the image is current.
    if !options.rebuild, let previous, previous.guestOS == .macos,
      previous.manifestID
        == ImageManifest.macManifestID(provisionSHA256: provisionSHA, coreAI: options.macOSCoreAI),
      (try? runtime.verifyImage(previous)) != nil,
      previous.baseImage.hasSuffix("ipsw-sha256:\(try sha256Hex(fileAt: restore))")
    {
      diagnostics.log(.info, "macOS image '\(options.image)' is up to date (\(previous.imageRef))")
      return
    }
    if options.refuseRebuild {
      throw HostError(
        "\(SetupOptions.preparationRequiredPrefix): image '\(options.image)' needs preparation. Re-run with --prepare."
      )
    }
    try StateStore.ensurePrivateDirectory(runtime.root)
    let imageDirectory = config.imagesDirectory.appending(options.image.rawValue).path
    try StateStore.ensurePrivateDirectory(imageDirectory)
    let scriptPath = imageDirectory + "/macos-provision.sh"
    try AtomicFile.write(Array(script.utf8), to: scriptPath, mode: .atMost(0o600))
    // A Core AI template's name carries the runtime's `-coreai` suffix.
    let name = try MachineName(
      MachineName.generate(for: owner.id, randomHex: randomHex(8)).rawValue
        + (options.macOSCoreAI ? Self.macCoreAISuffix : ""))
    let disk = UInt64(config.vm.templateSize.value)
    diagnostics.log(
      .info,
      "Installing macOS from \(restore) into \(options.macOSCoreAI ? "Core AI " : "")template \(name); this takes a while"
    )
    let template = try runtime.macBuildTemplate(
      name, ipsw: restore, provision: scriptPath,
      cpus: max(Self.macBuildCPUs, UInt32(config.vm.vcpuCount)),
      memoryMiB: max(Self.macBuildMemoryMiB, UInt64(config.vm.memory.mib.value)),
      diskGiB: max(Self.macDefaultDiskGiB, disk), coreAI: options.macOSCoreAI,
      deadline: options.builderTimeout ?? .seconds(3 * 3600)
    ) { diagnostics.log(.info, $0) }
    guard template.provisionSha256 == provisionSHA else {
      try? runtime.macDeleteTemplate(name)
      throw RuntimeError.identityConflict(
        "template \(name) recorded a different provisioning script than iso supplied")
    }
    guard template.hasCoreAIFeatureFlag == options.macOSCoreAI else {
      try? runtime.macDeleteTemplate(name)
      throw RuntimeError.identityConflict(
        "template \(name) \(template.hasCoreAIFeatureFlag ? "has" : "lacks") the Core AI feature flag; iso asked for \(options.macOSCoreAI ? "it" : "a plain template")"
      )
    }
    let created = utcTimestamp()
    try ImageManifest(
      schemaVersion: StateSchema.version, backend: StateSchema.backend, imageRef: name.rawValue,
      digest: ImageManifest.macDigest(template), disk: nil,
      manifestID: ImageManifest.macManifestID(template),
      baseImage:
        "macOS \(template.productVersion) (\(template.build)) ipsw-sha256:\(template.ipswSha256)",
      platform: ImageManifest.macPlatform, guestUser: MacProvision.guestUser, created: created
    ).save(config, options.image)
    if let previous { releaseManifest(runtime, owner: owner, manifest: previous, except: nil) }
    diagnostics.log(
      .info,
      "Setup complete: image '\(options.image)' is macOS \(template.productVersion) (\(template.build)). Run `iso up --image \(options.image)` in a project directory."
    )
  }
}
