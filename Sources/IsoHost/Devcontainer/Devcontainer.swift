// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// Lifecycle stage a translation feeds. Setup and start read disjoint keys;
/// the stage keeps "applied for another command" distinct from
/// "unsupported".
package enum DevcontainerStage: Sendable, Equatable {
  case setup
  case start
}

/// CLI/config state the translator needs for "CLI > devcontainer.json >
/// defaults" precedence.
package struct DevcontainerTranslatorInputs: Sendable {
  package var cliVcpus: UInt8?
  package var cliMemory: VmMemory?
  package var cliDisk: GiB?
  package var cliPostStart: String?
  package var cliGuestEnvKeys: [EnvVarName]
  package var cliForwardPorts: [PortForward]
  package var cliMounts: [Mount]
  package var cliProfiles: [String]
  /// `setup --guest-user`; makes `remoteUser` overridden (setup only).
  package var cliGuestUser: GuestUser?
  /// The image's persisted guest user (start only). A different
  /// `remoteUser` skips `containerEnv`.
  package var persistedGuestUser: GuestUser?
  /// `--workspace` or `--git-repo` was given, which excludes devcontainer
  /// `mounts` (start only).
  package var cliWorkspaceOrGitRepo: Bool

  package init(
    cliVcpus: UInt8? = nil, cliMemory: VmMemory? = nil, cliDisk: GiB? = nil,
    cliPostStart: String? = nil, cliGuestEnvKeys: [EnvVarName] = [],
    cliForwardPorts: [PortForward] = [], cliMounts: [Mount] = [], cliProfiles: [String] = [],
    cliGuestUser: GuestUser? = nil, persistedGuestUser: GuestUser? = nil,
    cliWorkspaceOrGitRepo: Bool = false
  ) {
    self.cliVcpus = cliVcpus
    self.cliMemory = cliMemory
    self.cliDisk = cliDisk
    self.cliPostStart = cliPostStart
    self.cliGuestEnvKeys = cliGuestEnvKeys
    self.cliForwardPorts = cliForwardPorts
    self.cliMounts = cliMounts
    self.cliProfiles = cliProfiles
    self.cliGuestUser = cliGuestUser
    self.persistedGuestUser = persistedGuestUser
    self.cliWorkspaceOrGitRepo = cliWorkspaceOrGitRepo
  }
}

/// Values to fold into configuration and start/setup options, plus the
/// report. The translator never mutates its inputs.
package struct DevcontainerTranslation: Sendable {
  package var applied: AppliedDevcontainer?
  package var vcpus: UInt8?
  package var memory: MiB?
  package var disk: GiB?
  package var postStart: String?
  /// Byte order of name (Rust `BTreeMap`).
  package var guestEnvironment: [(name: EnvVarName, value: String)] = []
  package var forwardPorts: [PortForward] = []
  package var mounts: [Mount] = []
  package var ociFeatureRequests: [FeatureRequest] = []
  package var ociFeatures: [ResolvedFeature] = []
  package var profiles: [String] = []
  /// `remoteUser` when no `--guest-user` overrode it (setup only).
  package var guestUser: GuestUser?
  package var report = DevcontainerReport()

  package init() {}
}

package enum Devcontainer {
  /// Where discovery looks inside a workspace or mount root.
  package static let defaultRelativePath = ".devcontainer/devcontainer.json"

  /// Rust `IsoConfig::devcontainer_preferences_path`.
  package static func preferencesPath(_ config: IsoConfig) -> String {
    config.stateRoot.appending("devcontainer_preferences.json").path
  }

  /// Rust `backend::persisted_guest_user`: the image's recorded guest user,
  /// or the default when its template record is missing or unreadable.
  package static func persistedGuestUser(_ config: IsoConfig, image: ImageName) -> GuestUser {
    (try? TemplateStore.load(config, image))?.guestUser ?? .default
  }

  // MARK: Translation

  package static func translate(
    _ file: ParsedDevcontainer, inputs: DevcontainerTranslatorInputs, stage: DevcontainerStage
  ) -> DevcontainerTranslation {
    var t = DevcontainerTranslation()
    t.applied = AppliedDevcontainer(
      path: file.path, contentHash: file.contentHash, source: .localFile)
    t.report.sourcePath = file.path
    let raw = file.raw

    if let requirements = raw.hostRequirements {
      translateHostRequirements(requirements, inputs, stage, &t)
    }

    if let command = raw.postStartCommand {
      let key = "postStartCommand"
      if stage == .setup {
        t.report.push(key, .applied, .devcontainer, command.rendered, "applied at start time")
      } else if let text = postStartText(command) {
        if let cli = inputs.cliPostStart {
          t.report.push(
            key, .overridden, .cli, cli,
            "CLI --post-start overrides devcontainer value \(debugQuoted(text))")
        } else {
          t.postStart = text
          t.report.push(key, .applied, .devcontainer, text)
        }
      } else {
        t.report.push(
          key, .invalid, .devcontainer, command.rendered,
          "expected string or [string,...]; array form joined with ' && '")
      }
    }

    if let environment = raw.containerEnv {
      if stage == .start && remoteUserMismatch(raw, inputs) {
        t.report.push(
          "containerEnv", .unsupported, .devcontainer, "\(environment.count) entries",
          "skipped because devcontainer.json's `remoteUser` does not match the image")
      } else {
        translateContainerEnv(environment, inputs, stage, &t)
      }
    }

    if let ports = raw.forwardPorts { translateForwardPorts(ports, inputs, stage, &t) }
    if let features = raw.features { translateFeatures(features, inputs, stage, &t) }
    if let mounts = raw.mounts { translateMounts(mounts, inputs, stage, &t) }
    if let user = raw.remoteUser { translateRemoteUser(user, inputs, stage, &t) }

    if let image = raw.image {
      t.report.push(
        "image", .unsupported, .devcontainer, image.rendered,
        "iso builds its own rootfs; base images are ignored")
    }
    if let build = raw.build {
      t.report.push(
        "build", .unsupported, .devcontainer, build.rendered,
        "iso builds its own rootfs; Dockerfile/build is ignored")
    }
    if let compose = raw.dockerComposeFile {
      t.report.push(
        "dockerComposeFile", .unsupported, .devcontainer, compose.rendered,
        "iso has no compose support")
    }
    if raw.customizations != nil {
      t.report.push(
        "customizations", .unsupported, .devcontainer, "<...>",
        "editor-specific; not relevant to iso")
    }
    if let name = raw.name {
      t.report.push(
        "name", .unsupported, .devcontainer, name,
        "informational only; iso names instances via --name or auto-generates")
    }
    for (key, value) in raw.extras {
      t.report.push(
        key, .unsupported, .devcontainer, value.rendered, "unrecognised devcontainer.json key")
    }
    return t
  }

  static func translateHostRequirements(
    _ requirements: RawHostRequirements, _ inputs: DevcontainerTranslatorInputs,
    _ stage: DevcontainerStage, _ t: inout DevcontainerTranslation
  ) {
    if let cpus = requirements.cpus {
      let key = "hostRequirements.cpus"
      if let count = UInt8(exactly: cpus), count > 0 {
        if let cli = inputs.cliVcpus {
          t.report.push(
            key, .overridden, .cli, String(cli),
            "CLI --vcpus overrides devcontainer.json value \(count)")
        } else {
          t.vcpus = count
          t.report.push(key, .applied, .devcontainer, String(count))
        }
      } else {
        t.report.push(
          key, .invalid, .devcontainer, String(cpus), "expected positive integer that fits in u8")
      }
    }
    if let memory = requirements.memory {
      let key = "hostRequirements.memory"
      let mib = memory.mib
      if let cli = inputs.cliMemory {
        t.report.push(
          key, .overridden, .cli, "\(cli) MiB",
          "CLI --mem overrides devcontainer.json value \(mib) MiB")
      } else {
        t.memory = mib
        t.report.push(key, .applied, .devcontainer, "\(mib) MiB")
      }
    }
    if let storage = requirements.storage {
      let key = "hostRequirements.storage"
      let gib = storage.gib
      if stage == .setup {
        t.report.push(
          key, .unsupported, .devcontainer, "\(gib) GiB",
          "instance disk size is applied at `iso start` time, not during setup")
      } else if let cli = inputs.cliDisk {
        t.report.push(
          key, .overridden, .cli, "\(cli) GiB",
          "CLI --disk overrides devcontainer.json value \(gib) GiB")
      } else {
        t.disk = gib
        t.report.push(key, .applied, .devcontainer, "\(gib) GiB")
      }
    }
    for (key, value) in requirements.extras {
      t.report.push(
        "hostRequirements.\(key)", .unsupported, .devcontainer, value.rendered,
        "unrecognised hostRequirements key")
    }
  }

  static func translateRemoteUser(
    _ user: String, _ inputs: DevcontainerTranslatorInputs, _ stage: DevcontainerStage,
    _ t: inout DevcontainerTranslation
  ) {
    let key = "remoteUser"
    let parsed: GuestUser
    do { parsed = try GuestUser(user) } catch {
      t.report.push(key, .invalid, .devcontainer, user, error.message)
      return
    }
    switch stage {
    case .setup:
      if let cli = inputs.cliGuestUser {
        t.report.push(
          key, .overridden, .cli, cli.rawValue,
          "CLI --guest-user overrides devcontainer.json value \(parsed)")
      } else {
        t.guestUser = parsed
        t.report.push(
          key, .applied, .devcontainer, parsed.rawValue, "baked into the image at setup time")
      }
    case .start:
      if let persisted = inputs.persistedGuestUser {
        if persisted == parsed {
          t.report.push(
            key, .applied, .devcontainer, parsed.rawValue,
            "matches the image's persisted guest user")
        } else {
          t.report.push(
            key, .unsupported, .devcontainer, parsed.rawValue,
            "image was set up with `\(persisted)`; `iso destroy && iso setup --guest-user \(parsed)` to switch (containerEnv skipped to avoid pointing at /home/\(parsed))"
          )
        }
      } else if parsed == .default {
        t.report.push(
          key, .applied, .devcontainer, parsed.rawValue, "matches the default guest user")
      } else {
        t.report.push(
          key, .unsupported, .devcontainer, parsed.rawValue,
          "image was set up with the default `\(GuestUser.default)`; `iso destroy && iso setup --guest-user \(parsed)` to switch"
        )
      }
    }
  }

  /// At start, true when a valid `remoteUser` differs from the image's user.
  static func remoteUserMismatch(_ raw: RawDevcontainer, _ inputs: DevcontainerTranslatorInputs)
    -> Bool
  {
    guard let user = raw.remoteUser, let parsed = try? GuestUser(user) else { return false }
    return (inputs.persistedGuestUser ?? .default) != parsed
  }

  static func translateContainerEnv(
    _ environment: [(key: String, value: String)], _ inputs: DevcontainerTranslatorInputs,
    _ stage: DevcontainerStage, _ t: inout DevcontainerTranslation
  ) {
    let key = "containerEnv"
    guard !environment.isEmpty else { return }
    if stage == .setup {
      t.report.push(
        key, .applied, .devcontainer, "\(environment.count) entries", "applied at start time")
      return
    }
    let cliKeys = Set(inputs.cliGuestEnvKeys.map(\.rawValue))
    var overridden: [String] = []
    var applied: [String] = []
    var invalid: [String] = []
    for (name, value) in environment {
      guard let variable = try? EnvVarName(name) else {
        invalid.append(name)
        continue
      }
      if cliKeys.contains(name) {
        overridden.append(name)
      } else {
        t.guestEnvironment.append((variable, value))
        applied.append(name)
      }
    }
    if !applied.isEmpty {
      t.report.push(
        key, .applied, .devcontainer, "\(applied.count) entries", applied.joined(separator: ","))
    }
    if !overridden.isEmpty {
      t.report.push(
        key, .overridden, .cli, "\(overridden.count) entries",
        "CLI --env overrides: \(overridden.joined(separator: ","))")
    }
    if !invalid.isEmpty {
      t.report.push(
        key, .invalid, .devcontainer, "\(invalid.count) entries",
        "invalid env var names (must match [a-zA-Z_][a-zA-Z0-9_]*): \(invalid.joined(separator: ","))"
      )
    }
  }

  static func translateForwardPorts(
    _ ports: [DevcontainerJSON], _ inputs: DevcontainerTranslatorInputs,
    _ stage: DevcontainerStage, _ t: inout DevcontainerTranslation
  ) {
    let key = "forwardPorts"
    guard !ports.isEmpty else { return }
    if stage == .setup {
      t.report.push(key, .applied, .devcontainer, "\(ports.count) entries", "applied at start time")
      return
    }
    let cliGuestPorts = Set(inputs.cliForwardPorts.map(\.guest))
    var applied: [String] = []
    var overridden: [String] = []
    for entry in ports {
      do {
        let forward = try parseForwardPortEntry(entry)
        if cliGuestPorts.contains(forward.guest) {
          overridden.append(String(forward.guest))
        } else {
          applied.append(
            forward.guest == forward.host
              ? String(forward.guest) : "\(forward.guest):\(forward.host)")
          t.forwardPorts.append(forward)
        }
      } catch {
        t.report.push(key, .invalid, .devcontainer, entry.rendered, topMessage(error))
      }
    }
    if !applied.isEmpty {
      t.report.push(key, .applied, .devcontainer, applied.joined(separator: ","))
    }
    if !overridden.isEmpty {
      t.report.push(
        key, .overridden, .cli, overridden.joined(separator: ","),
        "CLI --forward-port overrides for guest port(s): \(overridden.joined(separator: ","))")
    }
  }

  static func translateFeatures(
    _ features: [(key: String, value: DevcontainerJSON)], _ inputs: DevcontainerTranslatorInputs,
    _ stage: DevcontainerStage, _ t: inout DevcontainerTranslation
  ) {
    let cliProfiles = Set(inputs.cliProfiles)
    let perStart =
      "features are baked into the template at `iso setup` time, not selected per-start"
    for (rawID, options) in features {
      let key = "features.\(rawID)"
      if let name = profileForFeature(rawID) {
        if stage == .start {
          t.report.push(key, .unsupported, .devcontainer, name, perStart)
        } else if cliProfiles.contains(name) {
          t.report.push(
            key, .overridden, .cli, name, "CLI --profile already includes this profile")
        } else {
          t.profiles.append(name)
          t.report.push(
            key, .applied, .devcontainer, name, "mapped to built-in profile '\(name)'")
        }
        continue
      }
      if stage == .start {
        t.report.push(key, .unsupported, .devcontainer, rawID, perStart)
        continue
      }
      do {
        if let request = try FeatureRequest.parse(rawID: rawID, options: options) {
          t.ociFeatureRequests.append(request)
        } else {
          t.report.push(
            key, .unsupported, .devcontainer, rawID,
            "no built-in profile match and only ghcr.io/devcontainers/features/* OCI features are supported"
          )
        }
      } catch {
        t.report.push(key, .invalid, .devcontainer, options.rendered, topMessage(error))
      }
    }
  }

  static func translateMounts(
    _ mounts: [DevcontainerJSON], _ inputs: DevcontainerTranslatorInputs,
    _ stage: DevcontainerStage, _ t: inout DevcontainerTranslation
  ) {
    let key = "mounts"
    guard !mounts.isEmpty else { return }
    if stage == .setup {
      t.report.push(
        key, .applied, .devcontainer, "\(mounts.count) entries", "applied at start time")
      return
    }
    if !inputs.cliMounts.isEmpty {
      t.report.push(
        key, .overridden, .cli, "\(inputs.cliMounts.count) CLI --mount entries",
        "CLI --mount conflicts with --workspace and replaces devcontainer mounts")
      return
    }
    if inputs.cliWorkspaceOrGitRepo {
      t.report.push(
        key, .unsupported, .devcontainer, "\(mounts.count) entries",
        "iso --mount is mutually exclusive with --workspace/--git-repo in v1; drop those flags to use devcontainer mounts"
      )
      return
    }
    var applied: [String] = []
    for entry in mounts {
      do {
        let mount = try parseMountEntry(entry)
        applied.append("\(mount.hostPath)->\(mount.guestPath)")
        t.mounts.append(mount)
      } catch {
        t.report.push(key, .invalid, .devcontainer, entry.rendered, topMessage(error))
      }
    }
    if !applied.isEmpty {
      t.report.push(key, .applied, .devcontainer, applied.joined(separator: ", "))
    }
  }

  // MARK: Helpers

  static func postStartText(_ value: DevcontainerJSON) -> String? {
    switch value.value {
    case .string(let text): return text
    case .array(let items):
      let strings = items.compactMap(\.string)
      return strings.count == items.count ? strings.joined(separator: " && ") : nil
    default: return nil
    }
  }

  static func parseForwardPortEntry(_ value: DevcontainerJSON) throws -> PortForward {
    switch value.value {
    case .unsigned(let number):
      guard let port = UInt16(exactly: number) else {
        throw HostError("port \(number) out of range 1..=65535")
      }
      return try PortForward.parse(String(port))
    case .negative, .float: throw HostError("port must be a positive integer")
    case .string(let spec): return try PortForward.parse(spec)
    default: throw HostError("expected port number or 'GUEST[:HOST]' string")
    }
  }

  static func parseMountEntry(_ value: DevcontainerJSON) throws -> Mount {
    switch value.value {
    case .string(let spec): return try parseMountString(spec)
    case .object(let members):
      let fields = mergedMembers(members)
      func field(_ name: String) -> String? { fields.last { $0.key == name }?.value.string }
      guard let type = field("type") else { throw HostError("mount object requires 'type'") }
      guard type == "bind" else {
        throw HostError("unsupported mount type '\(type)' (iso supports 'bind' only in v1)")
      }
      guard let source = field("source") else {
        throw HostError("mount object requires 'source'")
      }
      guard let target = field("target") else {
        throw HostError("mount object requires 'target'")
      }
      let guest = try GuestPath.absolute(target)
      return try Mount(host: source, guest: guest)
    default: throw HostError("expected mount string or object")
    }
  }

  /// Native `HOST[:GUEST]` or Docker's `type=bind,source=...,target=...`.
  static func parseMountString(_ spec: String) throws -> Mount {
    guard spec.contains("=") else { return try Mount.parse(spec) }
    var type: String?
    var source: String?
    var target: String?
    for rawPart in spec.split(separator: ",", omittingEmptySubsequences: false) {
      let part = String(rawPart).trimmingUnicodeWhitespace()
      if part.isEmpty { continue }
      let name: String
      let value: String?
      if let equals = part.firstIndex(of: "=") {
        name = String(part[..<equals]).trimmingUnicodeWhitespace()
        value = String(part[part.index(after: equals)...]).trimmingUnicodeWhitespace()
      } else {
        name = part
        value = nil
      }
      switch name {
      case "type": type = value
      case "source", "src": source = value
      case "target", "dst", "destination": target = value
      case "readonly", "ro", "consistency", "bind-propagation": break
      default: throw HostError("unsupported mount field '\(name)'")
      }
    }
    let kind = type ?? "bind"
    guard kind == "bind" else {
      throw HostError("unsupported mount type '\(kind)' (iso supports 'bind' only in v1)")
    }
    guard let source else { throw HostError("mount string missing source=...") }
    guard let target else { throw HostError("mount string missing target=...") }
    let guest = try GuestPath.absolute(target)
    return try Mount(host: source, guest: guest)
  }

  static let featureProfileIDs: Set<String> = ["python", "node", "c", "fuzz", "rust", "go"]

  /// A built-in profile for a bare (`rust`) or registry
  /// (`ghcr.io/devcontainers/features/rust:1`) feature id.
  static func profileForFeature(_ rawID: String) -> String? {
    let last =
      rawID.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)
      ?? rawID
    let id =
      last.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init)
      ?? last
    guard featureProfileIDs.contains(id), Profiles.builtin.contains(where: { $0.name == id })
    else { return nil }
    return id
  }

  // MARK: Discovery

  package enum DiscoveryOrigin: Sendable, Equatable {
    case workspace
    case mount
  }

  package struct Discovered: Sendable, Equatable {
    package let path: String
    package let origin: DiscoveryOrigin
  }

  /// Present `.devcontainer/devcontainer.json` files: workspace first, then
  /// each mount root in order.
  package static func discover(workspace: String?, mounts: [Mount]) -> [Discovered] {
    var found: [Discovered] = []
    if let workspace {
      let candidate = joinPath(workspace, defaultRelativePath)
      if isFile(candidate) { found.append(Discovered(path: candidate, origin: .workspace)) }
    }
    for mount in mounts {
      let candidate = joinPath(mount.hostPath, defaultRelativePath)
      if isFile(candidate) { found.append(Discovered(path: candidate, origin: .mount)) }
    }
    return found
  }

  /// Workspace wins over mounts; among mounts the first wins. The losers
  /// are returned so a dry run lists every file seen.
  package static func pickWinner(_ found: [Discovered]) -> (Discovered, [String])? {
    let mounts = found.filter { $0.origin == .mount }
    if let workspace = found.last(where: { $0.origin == .workspace }) {
      return (workspace, mounts.map(\.path))
    }
    guard let first = mounts.first else { return nil }
    return (first, mounts.dropFirst().map(\.path))
  }

  // MARK: Application

  /// Fold a translation into configuration. A `hostRequirements.memory`
  /// below the guest floor is rejected: the file is external input.
  package static func applyToConfig(_ config: IsoConfig, _ t: DevcontainerTranslation) throws
    -> IsoConfig
  {
    var memory: VmMemory?
    if let mib = t.memory {
      do { memory = try VmMemory(mib) } catch {
        throw ContextError(
          "devcontainer.json hostRequirements.memory is below the guest-memory floor",
          cause: error)
      }
    }
    return config.applyingDevcontainer(
      vcpus: t.vcpus, memory: memory, postStart: t.postStart,
      guestEnvironment: t.guestEnvironment)
  }

  /// The CLI disk wins; otherwise the translation's.
  package static func effectiveDisk(cli: GiB?, _ t: DevcontainerTranslation) -> GiB? {
    cli ?? t.disk
  }

  /// Translation forwards merged over config forwards; a later guest port
  /// wins in place.
  package static func mergeIntoForwardPorts(config: [PortForward], translation: [PortForward])
    -> [PortForward]
  {
    PortForward.merge(config: config, cli: translation)
  }
}

/// Rust `Path::join` for a relative component.
func joinPath(_ base: String, _ component: String) -> String {
  if base.isEmpty { return component }
  return base.hasSuffix("/") ? base + component : base + "/" + component
}

/// Rust `Path::is_file`: follows symlinks.
func isFile(_ path: String) -> Bool {
  var status = stat()
  return stat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
}
