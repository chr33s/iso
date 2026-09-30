import Darwin
import Foundation
import IsoProxyCore

/// Probes that the gateway runs under its Seatbelt profile before it binds
/// anything or reads a registration (§10). A denial must be a permission
/// error, not a missing path or an unreachable network.
enum Jail {
  enum Failure: Error, CustomStringConvertible {
    case coreLimit, fileWriteAllowed, stateWriteDenied, execAllowed, egressAllowed,
      unlistedPortAllowed, loopbackDenied

    var description: String {
      switch self {
      case .coreLimit: "cannot disable core dumps"
      case .fileWriteAllowed: "writes outside the state directory are allowed"
      case .stateWriteDenied: "writes inside the state directory are denied"
      case .execAllowed: "program execution is allowed"
      case .egressAllowed: "non-loopback network egress is allowed"
      case .unlistedPortAllowed: "a loopback port outside the backend list is allowed"
      case .loopbackDenied: "loopback connections are denied"
      }
    }
  }

  static func disableCoreDumps() throws {
    guard JailProbes.disableCoreDumps() else { throw Failure.coreLimit }
  }

  static func requireConfinement(stateDirectory: String, backendPorts: Set<UInt16>) throws {
    let outside = "/private/tmp/iso-inference-jail-" + UUID().uuidString
    guard JailProbes.isDenial(JailProbes.createError(outside)) else {
      throw Failure.fileWriteAllowed
    }
    let inside = stateDirectory + "/.jail-probe"
    let probe = open(inside, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
    guard probe >= 0 else { throw Failure.stateWriteDenied }
    close(probe)
    unlink(inside)

    guard JailProbes.isDenial(JailProbes.spawnError()) else { throw Failure.execAllowed }

    // TEST-NET-1 is never routed: an allowed connect fails later, a denied
    // one fails immediately with EPERM.
    let egress = JailProbes.connectError(address: "192.0.2.1", port: 443)
    guard JailProbes.isDenial(egress) else { throw Failure.egressAllowed }
    // Only the listed backend ports are reachable on loopback.
    let unlisted = (1024...UInt16.max).first { !backendPorts.contains($0) } ?? 1024
    let other = JailProbes.connectError(address: "127.0.0.1", port: unlisted)
    guard JailProbes.isDenial(other) else { throw Failure.unlistedPortAllowed }
    let listed = JailProbes.connectError(address: "127.0.0.1", port: backendPorts.min() ?? unlisted)
    guard !JailProbes.isDenial(listed) else { throw Failure.loopbackDenied }
  }
}
