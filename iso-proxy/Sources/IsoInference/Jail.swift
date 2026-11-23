import Darwin
import Foundation
import IsoProxyCore

/// Probes that the gateway runs under its Seatbelt profile before it binds
/// anything or reads a registration (§10). A denial must be a permission
/// error, not a missing path or an unreachable network.
enum Jail {
  enum Failure: Error, CustomStringConvertible {
    case coreLimit, fileWriteAllowed, stateWriteDenied, tcpListenAllowed, execAllowed
    case egressAllowed, unlistedPortAllowed, loopbackDenied, homeReadAllowed
    case processInfoAllowed

    var description: String {
      switch self {
      case .coreLimit: "cannot disable core dumps"
      case .fileWriteAllowed: "writes outside the state and relay directories are allowed"
      case .stateWriteDenied: "writes inside the state or relay directory are denied"
      case .tcpListenAllowed: "listening on TCP is allowed"
      case .execAllowed: "program execution is allowed"
      case .egressAllowed: "non-loopback network egress is allowed"
      case .unlistedPortAllowed: "a loopback port outside the backend list is allowed"
      case .loopbackDenied: "loopback connections to a backend port are denied"
      case .homeReadAllowed: "reading the home directory is allowed"
      case .processInfoAllowed: "reading another process's information is allowed"
      }
    }
  }

  static func disableCoreDumps() throws {
    guard JailProbes.disableCoreDumps() else { throw Failure.coreLimit }
  }

  static func requireConfinement(
    stateDirectory: String, relayDirectory: String, backendPorts: Set<UInt16>
  ) throws {
    let outside = "/private/tmp/iso-inference-jail-" + UUID().uuidString
    guard JailProbes.isDenial(JailProbes.createError(outside)) else {
      throw Failure.fileWriteAllowed
    }
    for directory in [stateDirectory, relayDirectory] {
      let inside = directory + "/.jail-probe-" + UUID().uuidString
      guard JailProbes.createError(inside) == 0 else { throw Failure.stateWriteDenied }
    }
    // Sessions are Unix sockets reached through the vsock relay (§22).
    guard JailProbes.isDenial(JailProbes.listenError("127.0.0.1")) else {
      throw Failure.tcpListenAllowed
    }
    guard JailProbes.isDenial(JailProbes.spawnError()) else { throw Failure.execAllowed }

    // TEST-NET-1 is never routed: an allowed connect fails later, a denied
    // one fails immediately with EPERM.
    guard denied("192.0.2.1", port: 443) else { throw Failure.egressAllowed }
    // Only the listed backend ports are reachable on loopback.
    let unlisted = (1024...UInt16.max).first { !backendPorts.contains($0) } ?? 1024
    guard denied("127.0.0.1", port: unlisted) else { throw Failure.unlistedPortAllowed }
    guard !denied("127.0.0.1", port: backendPorts.min() ?? unlisted) else {
      throw Failure.loopbackDenied
    }
    guard JailProbes.isDenial(JailProbes.homeReadError()) else { throw Failure.homeReadAllowed }
    // launchd's path is readable to any unconfined process of this user.
    guard executablePath(1) == nil else { throw Failure.processInfoAllowed }
  }

  /// `proc_pidpath`; nil when it fails.
  static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    // proc_pidpath writes at most `buffer.count` bytes into the buffer borrowed here.
    let length = buffer.withUnsafeMutableBytes { raw in
      unsafe proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
    }
    return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
  }

  private static func denied(_ host: String, port: UInt16) -> Bool {
    JailProbes.isDenial(JailProbes.connectError(host, port: port))
  }
}
