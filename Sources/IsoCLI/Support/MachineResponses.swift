import Foundation
import IsoCore
import IsoHost

/// `iso.machine/v1` documents. Within a version, fields are only ever added;
/// a field documented as nullable is always present (`null`, never omitted).
enum MachineAPI {
  static let version = "iso.machine/v1"
}

/// The one document: `result` on success, `error` on failure.
struct MachineEnvelope<Body: Encodable>: Encodable {
  let command: String
  let ok: Bool
  let body: Body

  enum CodingKeys: String, CodingKey {
    case command, ok, result, error
    case apiVersion = "api_version"
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(MachineAPI.version, forKey: .apiVersion)
    try values.encode(command, forKey: .command)
    try values.encode(ok, forKey: .ok)
    try values.encode(body, forKey: ok ? .result : .error)
  }
}

/// A nullable field: synthesized `Encodable` omits a nil optional, the
/// contract requires `null`.
struct Nullable<Wrapped: Encodable>: Encodable {
  let value: Wrapped?
  init(_ value: Wrapped?) { self.value = value }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

// MARK: - Shared objects

/// `InstanceRef`.
struct MachineInstance: Encodable {
  let name: String
  let state: String
  let image: String
  let backend = AppleBackend.name
  /// Additive host fields; present only in all-host listings.
  var remote: Remote?

  struct Remote: Encodable {
    let host: String
    let hostID: String?
    let ownerID: String?
    let instanceID: String?
    let guestOS: String?
    let reachability: String
    let observedAt: UInt64?
    let lastObservedAt: UInt64?
  }

  init(_ instance: Instance, _ state: InstanceState) {
    name = instance.name.rawValue
    self.state = state.rawValue
    image = instance.image.rawValue
  }

  init(local instance: Instance, _ state: InstanceState) {
    self.init(instance, state)
    remote = Remote(
      host: HostAlias.local.rawValue, hostID: nil, ownerID: nil, instanceID: nil, guestOS: nil,
      reachability: "reachable", observedAt: nil, lastObservedAt: nil)
  }

  /// `destroyed` is a host-control state; machine v1 keeps its four states.
  init(_ row: RemoteListingRow) {
    switch row {
    case .observed(let host, let observation):
      name = observation.name.rawValue
      state = observation.state == .destroyed ? "unknown" : observation.state.rawValue
      image = observation.image?.rawValue ?? ""
      remote = Remote(
        host: host.rawValue, hostID: observation.instance.hostID.rawValue,
        ownerID: observation.instance.ownerID.rawValue,
        instanceID: observation.instance.instanceID.rawValue,
        guestOS: observation.instance.guestOS.rawValue, reachability: "reachable",
        observedAt: observation.observedAt.seconds, lastObservedAt: nil)
    case .unreachable(let binding):
      name = binding.name.rawValue
      state = "unknown"
      image = ""
      remote = Remote(
        host: binding.host.rawValue, hostID: binding.hostID.rawValue,
        ownerID: binding.ownerID.rawValue, instanceID: binding.instanceID.rawValue,
        guestOS: binding.guestOS.rawValue, reachability: "unreachable", observedAt: nil,
        lastObservedAt: binding.lastObservedAt)
    }
  }

  enum CodingKeys: String, CodingKey {
    case name, state, image, backend, host, reachability
    case hostID = "host_id"
    case ownerID = "owner_id"
    case instanceID = "instance_id"
    case guestOS = "guest_os"
    case observedAt = "observed_at"
    case lastObservedAt = "last_observed_at"
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(state, forKey: .state)
    try c.encode(image, forKey: .image)
    try c.encode(backend, forKey: .backend)
    guard let remote else { return }
    try c.encode(remote.host, forKey: .host)
    try c.encode(remote.reachability, forKey: .reachability)
    try c.encodeIfPresent(remote.hostID, forKey: .hostID)
    try c.encodeIfPresent(remote.ownerID, forKey: .ownerID)
    try c.encodeIfPresent(remote.instanceID, forKey: .instanceID)
    try c.encodeIfPresent(remote.guestOS, forKey: .guestOS)
    try c.encodeIfPresent(remote.observedAt, forKey: .observedAt)
    try c.encodeIfPresent(remote.lastObservedAt, forKey: .lastObservedAt)
  }
}

/// An instance identified after its state record is gone.
struct MachineRemovedInstance: Encodable, Equatable {
  let name: String
  let image: String

  init(_ instance: Instance) {
    name = instance.name.rawValue
    image = instance.image.rawValue
  }
}

/// `WorkspaceRef`.
struct MachineWorkspace: Encodable {
  let guestPath: String
  let hostPath: Nullable<String>
  let transport: String

  init(_ state: WorkspaceState) {
    guestPath = state.guestPath.rawValue
    switch state.source {
    case .workspace(let path):
      hostPath = Nullable(path)
      transport = "copy"
    case .mount(let path):
      hostPath = Nullable(path)
      transport = "mount"
    case .gitRepo:
      hostPath = Nullable(nil)
      transport = "git-repo"
    }
  }

  enum CodingKeys: String, CodingKey {
    case transport
    case guestPath = "guest_path"
    case hostPath = "host_path"
  }
}

/// `SSHConnectionRef`: the managed alias, never key material.
struct MachineConnection: Encodable {
  let kind = "ssh"
  let hostAlias: String
  let sshConfigPath: String

  init(_ alias: SSHAlias) {
    hostAlias = alias.host
    sshConfigPath = alias.configPath
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case hostAlias = "host_alias"
    case sshConfigPath = "ssh_config_path"
  }
}

struct MachineLifecycle: Encodable {
  let action: String
  init(_ action: LifecycleAction) { self.action = action.rawValue }
}

// MARK: - Command results

struct MachineListResult: Encodable {
  let instances: [MachineInstance]
  /// Hosts an all-host listing could not reach; absent otherwise.
  var hostFailures: [HostFailure]?

  struct HostFailure: Encodable {
    let host: String
    let code: String
    let message: String
  }

  enum CodingKeys: String, CodingKey {
    case instances
    case hostFailures = "host_failures"
  }
}

struct MachineStatusEntry: Encodable {
  let instance: MachineInstance
  let usage: Nullable<StatusOutput.Usage>
  /// The failed readiness proof of an unhealthy instance.
  let reason: Nullable<String>

  init(_ row: Status.Row) {
    instance = MachineInstance(row.instance, row.state)
    usage = Nullable(row.usage.map(StatusOutput.Usage.init))
    reason = Nullable(row.reason)
  }
}

/// `status NAME` is one entry; `status` is `{"instances": [...]}`.
enum MachineStatusResult: Encodable {
  case one(MachineStatusEntry)
  case all([MachineStatusEntry])

  init(_ report: Status.Report) {
    switch report {
    case .one(let row): self = .one(MachineStatusEntry(row))
    case .all(let rows): self = .all(rows.map(MachineStatusEntry.init))
    }
  }

  enum CodingKeys: String, CodingKey { case instances }

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .one(let entry): try entry.encode(to: encoder)
    case .all(let entries):
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(entries, forKey: .instances)
    }
  }
}

struct MachineUpResult: Encodable {
  let lifecycle: MachineLifecycle
  let instance: MachineInstance
  let workspace: Nullable<MachineWorkspace>

  /// `workspace` is the instance's recorded workspace, nil when none is.
  init(_ outcome: UpOutcome, workspace: WorkspaceState?) {
    lifecycle = MachineLifecycle(outcome.action)
    instance = MachineInstance(outcome.instance, .running)
    self.workspace = Nullable(workspace.map(MachineWorkspace.init))
  }
}

/// `start` and `stop`.
struct MachineLifecycleResult: Encodable {
  let lifecycle: MachineLifecycle
  let instance: MachineInstance

  init(_ action: LifecycleAction, _ instance: Instance, state: InstanceState) {
    lifecycle = MachineLifecycle(action)
    self.instance = MachineInstance(instance, state)
  }
}

/// `destroy NAME` carries `instance`; `destroy --all` carries `instances`.
enum MachineDestroyResult: Encodable {
  case one(MachineRemovedInstance)
  case all([MachineRemovedInstance])

  enum CodingKeys: String, CodingKey { case lifecycle, instance, instances }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(MachineLifecycle(.destroyed), forKey: .lifecycle)
    switch self {
    case .one(let instance): try values.encode(instance, forKey: .instance)
    case .all(let instances): try values.encode(instances, forKey: .instances)
    }
  }
}

struct MachineSSHConfigResult: Encodable {
  /// Present for an installed alias; `--clean` names only the instance.
  enum Subject: Encodable {
    case running(MachineInstance)
    case removed(name: String)

    enum CodingKeys: String, CodingKey { case name }

    func encode(to encoder: any Encoder) throws {
      switch self {
      case .running(let instance): try instance.encode(to: encoder)
      case .removed(let name):
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
      }
    }
  }

  let instance: Subject
  let connection: Nullable<MachineConnection>

  init(instance: Subject, connection: MachineConnection?) {
    self.instance = instance
    self.connection = Nullable(connection)
  }
}

/// `code` / `zed`: the lifecycle `up` reports plus the managed alias and the
/// editor launch. Never provider process output, keys or workload state.
struct MachineEditorResult: Encodable {
  struct Editor: Encodable {
    let provider: String
    let launched: Bool
    let launchTarget: String
    let security: String
    let hostCapabilities: [String]
    /// True exactly when `sandboxed`.
    let isolatedProfile: Bool
    let ephemeralSSHIdentity: Bool
    let supervised: Bool

    enum CodingKeys: String, CodingKey {
      case provider, launched, security
      case launchTarget = "launch_target"
      case hostCapabilities = "host_capabilities"
      case isolatedProfile = "isolated_profile"
      case ephemeralSSHIdentity = "ephemeral_ssh_identity"
      case supervised
    }
  }

  let lifecycle: MachineLifecycle
  let instance: MachineInstance
  let workspace: Nullable<MachineWorkspace>
  let connection: MachineConnection
  let editor: Editor
  let warnings: [String]

  init(_ outcome: ProjectEditorWorkflow.Outcome, workspace: WorkspaceState?) {
    lifecycle = MachineLifecycle(outcome.up.action)
    instance = MachineInstance(outcome.up.instance, .running)
    self.workspace = Nullable(workspace.map(MachineWorkspace.init))
    connection = MachineConnection(outcome.alias)
    let sandboxed = outcome.security.security == .sandboxed
    editor = Editor(
      provider: outcome.provider.rawValue, launched: outcome.mode == .launch,
      launchTarget: outcome.launchTarget, security: outcome.security.security.rawValue,
      hostCapabilities: outcome.security.allow.map(\.rawValue), isolatedProfile: sandboxed,
      ephemeralSSHIdentity: sandboxed, supervised: sandboxed)
    warnings = outcome.warnings.map(neutralizeControls)
  }
}

struct MachineCapabilitiesResult: Encodable {
  struct CommandSupport: Encodable {
    let machineOutput = true
    enum CodingKeys: String, CodingKey { case machineOutput = "machine_output" }
  }

  struct EditorProvider: Encodable {
    let id: String
    let displayName: String
    let remoteTransport: String
    enum CodingKeys: String, CodingKey {
      case id
      case displayName = "display_name"
      case remoteTransport = "remote_transport"
    }
  }

  let cliVersion = IsoVersion.string
  let machineAPIVersions = [MachineAPI.version]
  let backend = AppleBackend.name
  let commands = Dictionary(
    uniqueKeysWithValues: MachineCommands.all.map { ($0.machineName, CommandSupport()) })
  /// Compile-time host-control support; reading it touches no host or state.
  let hostControl = HostControlSupport()

  struct HostControlSupport: Encodable {
    let protocols = HostProtocol.supported
    let transports = ["local", "ssh"]
    let remoteGuestOS = ["linux"]
    enum CodingKeys: String, CodingKey {
      case protocols, transports
      case remoteGuestOS = "remote_guest_os"
    }
  }

  let editorProviders = EditorProviderID.allCases.map(\.provider).map {
    EditorProvider(
      id: $0.id.rawValue, displayName: $0.displayName,
      remoteTransport: $0.remoteTransport.rawValue)
  }

  enum CodingKeys: String, CodingKey {
    case backend, commands
    case cliVersion = "cli_version"
    case machineAPIVersions = "machine_api_versions"
    case editorProviders = "editor_providers"
    case hostControl = "host_control"
  }
}
