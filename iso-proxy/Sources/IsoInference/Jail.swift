import Darwin
import Foundation
import IsoProxyCore

/// Probes that the gateway runs under its Seatbelt profile before it binds
/// anything or reads a registration (§10). A denial must be a permission
/// error, not a missing path or an unreachable network.
enum Jail {
  enum Failure: Error, CustomStringConvertible {
    case coreLimit, fileWriteAllowed, stateWriteDenied, tcpListenAllowed, execAllowed
    case egressAllowed, unlistedPortAllowed, homeReadAllowed, processInfoAllowed

    var description: String {
      switch self {
      case .coreLimit: "cannot disable core dumps"
      case .fileWriteAllowed:
        "writes outside the state directory (or the session socket) are allowed"
      case .stateWriteDenied: "writes inside the state directory are denied"
      case .tcpListenAllowed: "listening on TCP is allowed"
      case .execAllowed: "program execution is allowed"
      case .egressAllowed: "non-loopback network egress is allowed"
      case .unlistedPortAllowed: "a loopback connection the profile should deny is allowed"
      case .homeReadAllowed: "reading the home directory is allowed"
      case .processInfoAllowed: "reading another process's information is allowed"
      }
    }
  }

  static func disableCoreDumps() throws {
    guard JailProbes.disableCoreDumps() else { throw Failure.coreLimit }
  }

  /// The broker's confinement (§5.1): it writes only its state directory
  /// (not the relay directory, where workers bind), listens on no TCP port,
  /// executes nothing, opens no network connection at all (workers reach the
  /// backends), reads nothing in the home directory and no other process's
  /// information.
  static func requireConfinement(
    stateDirectory: String, relayDirectory: String, backendPorts: Set<UInt16>
  ) throws {
    let outside = "/private/tmp/iso-inference-jail-" + UUID().uuidString
    guard JailProbes.isDenial(JailProbes.createError(outside)) else {
      throw Failure.fileWriteAllowed
    }
    let inside = stateDirectory + "/.jail-probe-" + UUID().uuidString
    guard JailProbes.createError(inside) == 0 else { throw Failure.stateWriteDenied }
    let relayed = relayDirectory + "/.jail-probe-" + UUID().uuidString
    guard JailProbes.isDenial(JailProbes.createError(relayed)) else {
      throw Failure.fileWriteAllowed
    }
    guard JailProbes.isDenial(JailProbes.listenError("127.0.0.1")) else {
      throw Failure.tcpListenAllowed
    }
    guard JailProbes.isDenial(JailProbes.spawnError()) else { throw Failure.execAllowed }
    // TEST-NET-1 is never routed: an allowed connect fails later, a denied
    // one fails immediately with EPERM.
    guard denied("192.0.2.1", port: 443) else { throw Failure.egressAllowed }
    // No loopback port either, a backend's included.
    for port in [UInt16(1)] + backendPorts.sorted() {
      guard denied("127.0.0.1", port: port) else { throw Failure.unlistedPortAllowed }
    }
    guard JailProbes.isDenial(JailProbes.homeReadError()) else { throw Failure.homeReadAllowed }
    guard !JailProbes.readsOtherProcesses() else { throw Failure.processInfoAllowed }
  }

  /// A session worker's confinement (§5.1): it may write only its own
  /// session socket, listens on no TCP port, executes nothing, reaches no
  /// address beyond loopback and no other loopback port than its backends',
  /// reads nothing in the home directory and no other process's information.
  static func requireWorkerConfinement(socketPath: String) throws {
    guard JailProbes.isDenial(JailProbes.createError(socketPath + ".jail-probe")) else {
      throw Failure.fileWriteAllowed
    }
    guard JailProbes.isDenial(JailProbes.listenError("127.0.0.1")) else {
      throw Failure.tcpListenAllowed
    }
    guard JailProbes.isDenial(JailProbes.spawnError()) else { throw Failure.execAllowed }
    guard denied("192.0.2.1", port: 443) else { throw Failure.egressAllowed }
    // Backends listen on unprivileged ports, so port 1 is never one.
    guard denied("127.0.0.1", port: 1) else { throw Failure.unlistedPortAllowed }
    guard JailProbes.isDenial(JailProbes.homeReadError()) else { throw Failure.homeReadAllowed }
    guard !JailProbes.readsOtherProcesses() else { throw Failure.processInfoAllowed }
  }

  private static func denied(_ host: String, port: UInt16) -> Bool {
    JailProbes.isDenial(JailProbes.connectError(host, port: port))
  }
}
