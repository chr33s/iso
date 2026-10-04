// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets

/// The project selection and creation options `iso up`, `iso code` and
/// `iso zed` share. Each builds the same `UpRequest`, so every command keeps
/// `iso up`'s affinity, reuse, restart and devcontainer semantics.
struct ProjectArguments: ParsableArguments {
  @Argument(help: "Project directory (default: current directory)") var dir: String?
  @Option(
    help: "Instance name to use when creating the project environment", transform: parseInstanceName
  )
  var name: InstanceName?
  @Flag(help: "Create a separate named instance even when DIR already has one")
  var newInstance = false
  @Flag(help: "Copy/sync DIR into the guest as /workspace (default)") var copy = false
  @Flag(help: "Mount DIR at /workspace instead of using --copy") var mount = false
  @Option(
    help:
      "Additional host directory to mount into the guest (`HOST_PATH[:GUEST_PATH]`, repeatable)",
    transform: parseMountSpec)
  var extraMount: [Mount] = []
  @Option(
    help: "Clone a git repository into /workspace instead of copying a local project directory")
  var gitRepo: String?
  @Option(help: "Number of vCPUs (overrides config when creating a new instance)") var vcpus: UInt8?
  @Option(
    help: "Memory in MiB (overrides config when creating a new instance)", transform: parseMemory)
  var mem: VmMemory?
  @Option(
    help: "Instance disk size in GiB (only used when creating a new instance)", transform: parseGiB)
  var disk: GiB?
  @Flag(
    name: .customLong("no-agents"),
    help: "Skip injecting Claude Code and Codex credentials/config into the VM")
  var noAgents = false
  @Flag(help: "Use github = \"off\" for this invocation and skip the GitHub PAT prompt")
  var noGithub = false
  @Option(
    help: "Named image to use when creating a new instance (default: \"default\")",
    transform: parseImageName)
  var image: ImageName?
  @Option(help: "Build or reuse a profile-derived image when creating a new instance")
  var profile: [String] = []
  @Flag(help: "Skip `.git/` when copying/syncing local directories") var excludeGit = false
  @Flag(
    help:
      "Suppress the interactive prompt to set up a scoped GitHub PAT when one is missing for the resolved repo"
  )
  var noPrompt = false
  @Option(
    help: "Forward a guest port to the host (`GUEST[:HOST]`, repeatable)",
    transform: parsePortForward)
  var forwardPort: [PortForward] = []
  @Option(
    help: ArgumentHelp(
      "Shell command to run inside the guest after boot (overrides `post_start` from the config). Failure is logged but does not fail the start",
      valueName: "CMD"))
  var postStart: String?
  @Option(
    name: .customLong("env"),
    help: ArgumentHelp(
      "Env var to set in the guest (`KEY=VALUE`, repeatable). A whole value `{vault:NAME}` is resolved from `iso secrets` for each session. Overrides `--env-file`, `guest_env` entries from config and any forwarded values with the same name",
      valueName: "KEY=VALUE"),
    transform: parseGuestEnvironment)
  var guestEnvironment: [(EnvVarName, EnvValue)] = []
  @Option(
    help: ArgumentHelp(
      "A `.env` file of guest env vars (`KEY=value`, `{vault:NAME}` references). Parsed strictly; never run by a shell",
      valueName: "PATH"))
  var envFile: String?
  @Option(
    help: ArgumentHelp(
      "Explicit path to a `devcontainer.json` to use (skips discovery)", valueName: "PATH"))
  var devcontainer: String?
  @Flag(help: "Ignore any discovered `devcontainer.json` (escape hatch for CI)")
  var noDevcontainer = false
  @OptionGroup var egressOptions: EgressOptions

  func validate() throws {
    if newInstance && name == nil {
      throw UsageError("the following required arguments were not provided:\n  --name <NAME>")
    }
    if copy && mount { throw UsageError("the argument '--copy' cannot be used with '--mount'") }
    if gitRepo != nil && (dir != nil || copy || mount) {
      throw UsageError(
        "the argument '--git-repo <GIT_REPO>' cannot be used with '[DIR]', '--copy' or '--mount'")
    }
    if devcontainer != nil && noDevcontainer {
      throw UsageError(
        "the argument '--devcontainer <PATH>' cannot be used with '--no-devcontainer'")
    }
  }

  var profiles: [String] { profile.flatMap { $0.split(separator: ",").map(String.init) } }

  /// Sorted, deduplicated profile list and the image named after it.
  static func profileTarget(_ profiles: [String]) throws -> (profiles: [String], image: ImageName)?
  {
    guard !profiles.isEmpty else { return nil }
    let names = Array(Set(profiles)).sorted {
      Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
    }
    do {
      return (names, try ImageName(names.joined(separator: "-")))
    } catch {
      throw ContextError(
        "Cannot derive an image name from profile list: \(names.joined(separator: ", "))",
        cause: error)
    }
  }

  /// The configuration snapshot with this invocation's egress override.
  func loadContext(_ global: GlobalOptions) throws -> CommandContext {
    let context = try CommandContext.load(global) {
      try applyEgressOverride($0, mode: egressOptions.egress, hosts: egressOptions.allowHost)
    }
    for warning in try context.config.validated() { context.diagnostics.warn(warning) }
    return context
  }

  /// `command` names the invoking subcommand in messages.
  func workflow(_ context: CommandContext, global: GlobalOptions, command: String) throws
    -> UpWorkflow
  {
    let target = try Self.profileTarget(profiles)
    if target != nil, let image {
      throw HostError(
        "`iso \(command) --profile` derives the image name from the sorted profile list; use `iso setup --image \(image) --profile ...` and then `iso \(command) --image \(image)` for an explicit named image."
      )
    }
    return UpWorkflow(
      request: request(
        configTarget: try global.configTarget(context.environment), command: command),
      lifecycle: ProjectLifecycle(context, noGitHub: noGithub), target: target)
  }

  func request(configTarget: ConfigTarget, command: String) -> UpRequest {
    var request = UpRequest(configTarget: configTarget)
    request.command = command
    request.egressRequested = egressOptions.egress != nil || !egressOptions.allowHost.isEmpty
    request.dir = dir
    request.gitRepo = gitRepo
    request.name = name
    request.image = image
    request.newInstance = newInstance
    request.vcpus = vcpus
    request.mem = mem
    request.disk = disk
    request.postStart = postStart
    request.guestEnvironment = guestEnvironment
    request.envFile = envFile
    request.forwardPort = forwardPort
    request.extraMount = extraMount
    request.excludeGit = excludeGit
    request.noAgents = noAgents
    request.noGithub = noGithub
    request.noPrompt = noPrompt
    request.transport = mount ? .mount : .copy
    request.devcontainerInput = .fromFlags(path: devcontainer, noDevcontainer: noDevcontainer)
    return request
  }
}
