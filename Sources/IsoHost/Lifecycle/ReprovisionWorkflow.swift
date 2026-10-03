import Foundation
import IsoConfiguration
import IsoCore

/// Wipe the guest and bring the instance back with the settings iso
/// persisted: name, index, image, disk size, workspace association, port
/// forwards and guest variables. Everything that can fail cheaply runs
/// before the disk is replaced; after it, every error says how to finish.
package struct ReprovisionWorkflow {
  package let lifecycle: ProjectLifecycle
  package let name: InstanceName?
  package let image: ImageName?
  package let noAgents: Bool
  package let noPrompt: Bool
  package let configTarget: ConfigTarget

  package init(
    lifecycle: ProjectLifecycle, name: InstanceName?, image: ImageName?,
    noAgents: Bool, noPrompt: Bool, configTarget: ConfigTarget
  ) {
    self.lifecycle = lifecycle
    self.name = name
    self.image = image
    self.noAgents = noAgents
    self.noPrompt = noPrompt
    self.configTarget = configTarget
  }

  package var context: CommandContext { lifecycle.context }

  package func run(confirm: (InstanceName, ImageName, WorkspaceState?) throws -> Bool) throws {
    let instance = try InstanceStore.resolve(lifecycle.config, name: name)
    let image = self.image ?? instance.image
    guard lifecycle.backend.imageIsBuilt(image) else {
      throw HostError("No image '\(image)' found. Run `iso images` to list available images.")
    }
    let workspace = try WorkspaceState.load(instance)
    let savedForwards = try PortForwards.load(instance) ?? []
    let savedEnvironment = try GuestEnvState.tryLoad(instance)?.entries ?? [:]
    let applied = try DevcontainerState.load(instance)?.applied
    try Self.checkWorkspaceSource(instance.name, workspace)
    DevcontainerState.warnIfChanged(instance, diagnostics: lifecycle.diagnostics)
    var options = CreationRequest(
      boot: BootOptions(
        noAgents: noAgents, noPrompt: noPrompt, configTarget: configTarget,
        persistedGuestEnvironment: savedEnvironment))
    options.appliedDevcontainer = applied
    switch workspace?.source {
    case .workspace(let path)?: options.workspaceDirectory = path
    case .gitRepo(let url)?: options.gitRepo = url
    case .mount(let path)?:
      // Revalidated: this path comes from a state file, not the CLI.
      options.mounts = [try Mount(host: path, guest: workspace!.guestPath)]
    case nil: break
    }
    if try !confirm(instance.name, image, workspace) {
      throw HostError(
        "Aborted — instance '\(instance.name)' left untouched.\nPass -y to reprovision without the prompt (required when stdin is not a TTY)."
      )
    }
    // Saved references must resolve before the disk is replaced.
    _ = try GuestEnvState.providerSecrets(savedEnvironment)
    let repo = lifecycle.tokens.instanceRepo(instance)
    try lifecycle.preflightReferences(savedEnvironment, instance: instance, repo: repo)
    try lifecycle.maybePromptForPAT(instance, repo: repo, options.boot)
    let shutdown = Shutdown.install()
    defer { shutdown.restore() }
    try lifecycle.stop(instance)
    // After the teardown: the instance's own forwarder held these ports.
    let forwardSet = PortForward.merge(config: lifecycle.config.forwardPorts, cli: savedForwards)
    do { try PortForwards.checkCollisions(forwardSet) } catch {
      throw ContextError(
        "Instance '\(instance.name)' is stopped and was not reprovisioned. Free the host port or drop the conflicting `forward_ports` entry from the config, then re-run `iso restore \(instance.name) --reprovision` — or `iso start \(instance.name)` to bring it back as it was.",
        cause: error)
    }
    let backend = lifecycle.backend
    let stopped = try backend.asStopped(instance)
    // An image disk is template-sized; re-grow to what the instance had.
    let previousDisk = try backend.currentDiskGiB(stopped)
    try Shutdown.check()
    try backend.restoreDisk(stopped, image: image)
    let partial = Self.partialMessage(instance.name, image, previousDisk)
    do {
      let restored = try instance.withImage(image)
      let current = try backend.currentDiskGiB(try backend.asStopped(restored))
      if previousDisk > current {
        try backend.resizeDisk(try backend.asStopped(restored), toGiB: previousDisk)
      }
      try Shutdown.check()
      lifecycle.foldGuestEnvironment(savedEnvironment)
      try lifecycle.backend.startExisting(restored)
      try lifecycle.provisionFirstBoot(restored, options, repo: repo, forwardSet: forwardSet)
    } catch {
      throw ContextError(partial, cause: error)
    }
    lifecycle.diagnostics.log(.info, "Instance '\(instance.name)' reprovisioned")
  }

  /// A recorded workspace that could not be re-synced is refused while the
  /// guest is still intact.
  package static func checkWorkspaceSource(_ name: InstanceName, _ state: WorkspaceState?) throws {
    guard let path = state?.source.hostPath else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw HostError(
        "Instance '\(name)' records workspace \(path), which is not a directory.\nPut it back at that path, or `iso destroy \(name)` and `iso up` from the new location — reprovisioning now would leave the guest with no workspace to sync back.\nNothing re-points an existing instance's recorded workspace: `iso up` matches on the canonical path and would create a second instance, and `iso push --dir` does not persist the new source."
      )
    }
  }

  package static func partialMessage(_ name: InstanceName, _ image: ImageName, _ disk: UInt64)
    -> String
  {
    "Instance '\(name)' was reset but not fully provisioned. Re-run `iso restore \(name) --image \(image) --reprovision` to finish.\nIts disk was \(disk) GiB before the reset. Nothing persists that, and a re-run measures the replaced (template-sized) disk, so check `iso status \(name)` and run `iso resize \(name) --size \(disk)` if the re-grow did not complete."
  }

}
