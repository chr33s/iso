import Foundation
import IsoCore

/// The exact reverse-tunnel `ssh` master a readiness proof relies on: its
/// PID, the unique control path it was started with (inside a fresh random
/// directory, so no other process carries it) and its guest destination. A
/// live PID that is any other process, including another `ssh`, is not this
/// tunnel.
struct TunnelIdentity: Codable, Equatable {
  let schemaVersion: UInt32
  let pid: Int32
  let controlPath: String
  let address: String

  init(pid: Int32, controlPath: String, address: String) {
    schemaVersion = 1
    self.pid = pid
    self.controlPath = controlPath
    self.address = address
  }

  static func path(_ instance: Instance, _ name: String) -> String {
    instance.directory + "/proxy-\(name)-fwd.identity.json"
  }

  func save(_ instance: Instance, name: String) throws {
    try StateStore.writeControlFile(self, to: Self.path(instance, name))
  }

  static func load(_ instance: Instance, _ name: String) -> TunnelIdentity? {
    let path = path(instance, name)
    guard let bytes = try? StateStore.readControlFile(path) ?? nil,
      let identity = try? StateStore.decode(TunnelIdentity.self, bytes, path: path),
      identity.schemaVersion == 1, identity.pid > 0
    else { return nil }
    return identity
  }

  /// `ps` names this master: `ssh` started with exactly this control path
  /// and destination.
  func matches(commandLine: String) -> Bool {
    let words = commandLine.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    guard let first = words.first, (first as NSString).lastPathComponent == "ssh" else {
      return false
    }
    let arguments = words.dropFirst()
    return arguments.contains(address)
      && zip(arguments, arguments.dropFirst()).contains { $0 == "-S" && $1 == controlPath }
  }

  /// The recorded tunnel is alive and still the master this boot started,
  /// for `address` when given. The PID file must name the same process.
  static func verify(_ instance: Instance, _ name: String, address: String?) -> Bool {
    guard let identity = load(instance, name),
      let bytes = try? StateStore.readControlFile(ProxyLauncher.forwardPIDPath(instance, name))
        ?? nil,
      Int32(String(decoding: bytes, as: UTF8.self).trimmingUnicodeWhitespace()) == identity.pid,
      address.map({ $0 == identity.address }) ?? true,
      let command = ProxyLauncher.commandLine(identity.pid)
    else { return false }
    return identity.matches(commandLine: command)
  }
}
