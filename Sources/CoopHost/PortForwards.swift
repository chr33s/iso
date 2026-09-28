// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopConfiguration
import CoopCore
import Foundation

/// Host-to-guest TCP forwards for a VM's lifetime: one backgrounded
/// `ssh -L` session parked under `<instance>/forwards.sock`, so teardown
/// (`ssh -O exit`) never touches the user's own SSH sessions.
public struct PortForwards: Sendable {
  let client: SSHClient
  let diagnostics: Diagnostics

  public init(client: SSHClient, diagnostics: Diagnostics) {
    self.client = client
    self.diagnostics = diagnostics
  }

  /// `<instance>/forwards.json`; an empty set removes the file.
  public static func save(_ forwards: [PortForward], _ instance: Instance, diagnostics: Diagnostics)
    throws
  {
    let path = instance.forwardsStatePath
    guard !forwards.isEmpty else {
      if FileManager.default.fileExists(atPath: path) {
        do {
          try FileManager.default.removeItem(atPath: path)
        } catch {
          diagnostics.debug("Failed to remove empty forwards state \(path) (non-fatal): \(error)")
        }
      }
      return
    }
    let json = OutputJSON.object([
      (
        "forwards",
        .array(
          forwards.map { forward in
            var members: [(String, OutputJSON)] = [
              ("guest", .uint(UInt64(forward.guest))), ("host", .uint(UInt64(forward.host))),
            ]
            if let label = forward.label { members.append(("label", .string(label))) }
            return .object(members)
          })
      )
    ])
    do {
      try AtomicFile.write(
        Array(String(json.rendered().dropLast()).utf8), to: path,
        mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write forwards.json", cause: error)
    }
    diagnostics.debug("Wrote forwards state to \(path)")
  }

  public static func load(_ instance: Instance) throws -> [PortForward]? {
    let path = instance.forwardsStatePath
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = FileManager.default.contents(atPath: path) else {
      throw HostError("Failed to read \(path)")
    }
    struct Raw: Decodable {
      struct Entry: Decodable {
        let guest: UInt16
        let host: UInt16?
        let label: String?
      }
      let forwards: [Entry]?
    }
    do {
      let raw = try JSONDecoder().decode(Raw.self, from: data)
      return try (raw.forwards ?? []).map {
        try PortForward(guest: $0.guest, host: $0.host, label: $0.label)
      }
    } catch {
      throw ContextError("Failed to parse forwards.json", cause: error)
    }
  }

  static func suggestion(_ host: UInt16) -> UInt16 { host == .max ? host - 1 : host + 1 }

  /// Fails on the first duplicate or busy host port, before any VM cost.
  public static func checkCollisions(_ forwards: [PortForward]) throws {
    var seen: Set<UInt16> = []
    for forward in forwards {
      guard seen.insert(forward.host).inserted else {
        throw HostError(
          "Duplicate host port \(forward.host) in forward set — only one guest port can bind a given host port.\nPick distinct hosts, e.g. `--forward-port G:\(suggestion(forward.host))`."
        )
      }
      if let failure = probe(forward.host) {
        throw HostError(
          failure == EADDRINUSE
            ? "Host port \(forward.host) is already in use — cannot forward guest port \(forward.guest).\nPick another host port, e.g. `--forward-port \(forward.guest):\(suggestion(forward.host))`."
            : "Failed to probe host port \(forward.host): \(String(cString: strerror(failure))) (os error \(failure)).\nPick another host port, e.g. `--forward-port \(forward.guest):\(suggestion(forward.host))`."
        )
      }
    }
  }

  /// Binds `127.0.0.1:port` and releases it; the errno on failure.
  static func probe(_ port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    // As Rust's TcpListener::bind: a port whose old connections sit in
    // TIME_WAIT after a stop is free for ssh's own `-L` bind.
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0 ? nil : errno
  }

  static func controlPath(_ instance: Instance) -> String { instance.directory + "/forwards.sock" }

  /// Starts the forwarder; a no-op for an empty set. Any leftover master
  /// from a crashed run is closed first so it cannot hold the ports.
  public func spawn(_ instance: Instance, _ target: SSHTarget, _ forwards: [PortForward]) throws {
    guard !forwards.isEmpty else { return }
    teardown(instance, target)
    let control = Self.controlPath(instance)
    var arguments =
      target.sshOptions + [
        "-f", "-N", "-T", "-o", "ControlMaster=yes", "-o", "ControlPath=\(control)", "-o",
        "ControlPersist=yes", "-o", "ExitOnForwardFailure=yes",
      ]
    let specs = forwards.map { "127.0.0.1:\($0.host):127.0.0.1:\($0.guest)" }
    for spec in specs { arguments += ["-L", spec] }
    arguments.append(target.address)
    diagnostics.log(.info, "Establishing SSH port forwards: \(specs.joined(separator: ", "))")
    let output: ProcessRunner.Output
    do {
      // `-f` backgrounds the master after authentication; the launching
      // ssh exits and the master keeps no pipe of ours open.
      output = try client.runner.capture(
        client.request(try client.ssh(), arguments).with(overflow: .drain))
    } catch {
      throw ContextError("Failed to launch ssh -L for port forwards", cause: error)
    }
    guard output.termination.succeeded else {
      throw HostError(
        "ssh -L for port forwards exited with status: \(output.termination).\nForwards attempted: \(specs.joined(separator: ", "))\nstderr: \(String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }

  /// Best effort; safe when no forwards were started.
  public func teardown(_ instance: Instance, _ target: SSHTarget) {
    let control = Self.controlPath(instance)
    guard FileManager.default.fileExists(atPath: control) else { return }
    diagnostics.debug("Tearing down SSH port forwards via control socket \(control)")
    if let ssh = client.sshExecutable(),
      let output = try? client.runner.capture(
        client.request(ssh, ["-O", "exit", "-o", "ControlPath=\(control)", target.address]))
    {
      diagnostics.debug(
        output.termination.succeeded
          ? "SSH forwarder closed cleanly"
          : "ssh -O exit returned \(output.termination) (non-fatal)")
    }
    if FileManager.default.fileExists(atPath: control) {
      do {
        try FileManager.default.removeItem(atPath: control)
      } catch {
        diagnostics.debug(
          "Failed to remove forward control socket \(control) (non-fatal): \(error)")
      }
    }
  }
}
