import Foundation
import IsoProxyCore

/// These probes run before reading stdin, while no provider secret is present.
/// Denial must specifically be a permission error, not a missing path or socket.
enum Jail {
  enum Failure: Error { case coreLimit, fileWriteAllowed, execAllowed, egressAllowed, httpsDenied }

  static func disableCoreDumps() throws {
    guard JailProbes.disableCoreDumps() else { throw Failure.coreLimit }
  }

  static func requireConfinement() throws {
    let write = JailProbes.createError("/private/tmp/iso-proxy-jail-" + UUID().uuidString)
    guard JailProbes.isDenial(write) else { throw Failure.fileWriteAllowed }
    guard JailProbes.isDenial(JailProbes.spawnError()) else { throw Failure.execAllowed }
    let blockedPort = UInt16.random(in: 49152...65535)
    let other = JailProbes.connectError(address: "127.0.0.1", port: blockedPort)
    guard JailProbes.isDenial(other) else { throw Failure.egressAllowed }
    let https = JailProbes.connectError(address: "127.0.0.1", port: 443)
    guard !JailProbes.isDenial(https) else { throw Failure.httpsDenied }
  }
}
