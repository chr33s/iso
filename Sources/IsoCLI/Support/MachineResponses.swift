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

  init(_ instance: Instance, _ state: InstanceState) {
    name = instance.name.rawValue
    self.state = state.rawValue
    image = instance.image.rawValue
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
}

struct MachineStatusEntry: Encodable {
  let instance: MachineInstance
  let usage: Nullable<StatusOutput.Usage>

  init(_ row: Status.Row) {
    instance = MachineInstance(row.instance, row.state)
    usage = Nullable(row.usage.map(StatusOutput.Usage.init))
  }
}

/// `status NAME` is one entry; `status` is `{"instances": [...]}`.
enum MachineStatusResult: Encodable {
  case one(MachineStatusEntry)
  case all([MachineStatusEntry])

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

struct MachineCapabilitiesResult: Encodable {
  struct CommandSupport: Encodable {
    let machineOutput = true
    enum CodingKeys: String, CodingKey { case machineOutput = "machine_output" }
  }

  struct EditorProvider: Encodable {
    let id: String
    let displayName: String
    enum CodingKeys: String, CodingKey {
      case id
      case displayName = "display_name"
    }
  }

  let cliVersion = IsoVersion.string
  let machineAPIVersions = [MachineAPI.version]
  let backend = AppleBackend.name
  let commands = Dictionary(
    uniqueKeysWithValues: MachineCommands.all.map { ($0.machineName, CommandSupport()) })
  let editorProviders = EditorKind.allCases.map {
    EditorProvider(id: $0.rawValue, displayName: $0.displayName)
  }

  enum CodingKeys: String, CodingKey {
    case backend, commands
    case cliVersion = "cli_version"
    case machineAPIVersions = "machine_api_versions"
    case editorProviders = "editor_providers"
  }
}
