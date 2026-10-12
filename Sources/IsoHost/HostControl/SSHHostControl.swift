import Foundation
import IsoConfiguration
import IsoCore

/// The fixed internal entrypoints an SSH frontend may invoke.
package enum HostAgentEntrypoint: String, Sendable {
  case serve
  case relay

  /// The remote command: the enrolled path plus fixed arguments only.
  package func remoteCommand(_ agent: AgentPath) -> String {
    RemoteCommand().arg(agent.rawValue).literal(" host-agent \(rawValue) --stdio").rendered
  }
}

/// SSH arguments shared by control and relay connections to an execution
/// host: pinned host key, no agent/X11/port forwarding, bounded liveness.
package func managementSSHArguments(
  alias: HostAlias, agent: AgentPath, _ entry: HostAgentEntrypoint
)
  -> [String]
{
  [
    "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
    "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
    "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
    "--", alias.rawValue, entry.remoteCommand(agent),
  ]
}

/// One request per SSH connection to the fixed `serve` frontend. The frame
/// travels on stdin through `ProcessRunner`; nothing from it reaches argv.
package struct SSHHostTransport: HostTransport {
  let alias: HostAlias
  let agent: AgentPath
  let ssh: String
  let environment: [String: String]
  let runner: ProcessRunner

  package init(
    alias: HostAlias, agent: AgentPath, ssh: String, environment: [String: String],
    runner: ProcessRunner = ProcessRunner()
  ) {
    self.alias = alias
    self.agent = agent
    self.ssh = ssh
    self.environment = SSHClient.transportEnvironment(environment)
    self.runner = runner
  }

  package var arguments: [String] { managementSSHArguments(alias: alias, agent: agent, .serve) }

  package func exchange(_ frame: [UInt8]) throws(HostControlError) -> [UInt8] {
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        .init(
          executable: ssh, arguments: arguments, environment: environment, deadline: .seconds(60),
          outputLimit: HostWire.maxResponseFrame + 1, input: frame))
    } catch {
      throw HostControlError(.hostUnreachable, "ssh to \(alias) failed (\(error))")
    }
    if output.termination == .exited(255) {
      throw Self.classify(output.stderr, alias: alias)
    }
    guard let newline = output.stdout.firstIndex(of: UInt8(ascii: "\n")) else {
      let diagnostic = HostControlError.sanitize(
        String(decoding: output.stderr.suffix(256), as: UTF8.self))
      throw HostControlError(
        .hostUnreachable, "the host agent on \(alias) did not reply: \(diagnostic)")
    }
    return Array(output.stdout[..<newline])
  }

  /// ssh's own failures: a changed management host key is distinct from an
  /// unreachable host and from a changed application identity.
  static func classify(_ stderr: [UInt8], alias: HostAlias) -> HostControlError {
    let text = String(decoding: stderr.suffix(4_096), as: UTF8.self)
    if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
      || text.contains("Host key verification failed")
    {
      return HostControlError(
        .hostIdentityChanged,
        "the SSH host key of \(alias) does not match its pin; verify the host before re-enrolling",
        retry: .explicitIdentityResolution, details: ["layer": "management"])
    }
    return HostControlError(.hostUnreachable, "could not connect to \(alias)")
  }
}

/// Client-side enrollment record of one execution host (spec 13.1). Holds
/// identities and the trusted entrypoint, never grants or credentials.
package struct HostEnrollment: Codable, Sendable, Equatable {
  package var schema = 1
  package let alias: HostAlias
  package let sshAlias: HostAlias
  package let agentPath: AgentPath
  package let hostID: HostID
  package let ownerID: OwnerID
  package let enrolledAt: UInt64
  package var disabled: Bool

  package init(
    alias: HostAlias, sshAlias: HostAlias, agentPath: AgentPath, hostID: HostID, ownerID: OwnerID,
    enrolledAt: UInt64, disabled: Bool = false
  ) {
    self.alias = alias
    self.sshAlias = sshAlias
    self.agentPath = agentPath
    self.hostID = hostID
    self.ownerID = ownerID
    self.enrolledAt = enrolledAt
    self.disabled = disabled
  }
}

/// Enrolled hosts under `<state root>/hosts`, one file per alias.
package struct HostRegistry: Sendable {
  let directory: String

  package init(config: IsoConfig) {
    directory = config.stateRoot.appending("hosts").path
  }

  package init(directory: String) { self.directory = directory }

  func path(_ alias: HostAlias) -> String { directory + "/" + alias.rawValue + ".json" }

  package func load(_ alias: HostAlias) throws(HostError) -> HostEnrollment? {
    guard let bytes = try StateStore.readControlFile(path(alias)) else { return nil }
    let record = try StateStore.decode(HostEnrollment.self, bytes, path: path(alias))
    guard record.alias == alias, record.schema == 1 else {
      throw HostError("\(path(alias)) does not describe host \(alias)")
    }
    return record
  }

  package func list() throws(HostError) -> [HostEnrollment] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    var records: [HostEnrollment] = []
    for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
      guard let alias = try? HostAlias(String(name.dropLast(5))), let record = try load(alias)
      else { continue }
      records.append(record)
    }
    return records
  }

  /// Saves a new enrollment. A second alias for the same installation is
  /// allowed (one identity); re-enrolling an alias under a different
  /// identity requires removing it first.
  package func save(_ record: HostEnrollment, replacing: Bool = false) throws(HostError) {
    try StateStore.ensurePrivateDirectory(directory)
    if let existing = try load(record.alias), !replacing {
      guard existing.hostID == record.hostID, existing.ownerID == record.ownerID else {
        throw HostError(
          "host '\(record.alias)' is enrolled as a different installation; remove it before enrolling a replacement"
        )
      }
    }
    try StateStore.writeControlFile(record, to: path(record.alias))
  }

  package func remove(_ alias: HostAlias) throws(HostError) {
    try StateStore.removeIfPresent(path(alias))
  }
}
