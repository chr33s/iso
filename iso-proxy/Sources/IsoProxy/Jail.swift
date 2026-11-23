// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoProxyCore

/// These probes run before reading stdin, while no provider secret is present.
/// Denial must specifically be a permission error, not a missing path or socket.
enum Jail {
  enum Failure: Error {
    case coreLimit, fileWriteAllowed, execAllowed, egressAllowed, loopbackHTTPSAllowed
    case loopbackDNSAllowed, httpsDenied, homeReadAllowed, processInfoAllowed
  }

  static func disableCoreDumps() throws {
    guard JailProbes.disableCoreDumps() else { throw Failure.coreLimit }
  }

  static func requireConfinement() throws {
    let path = "/private/tmp/iso-proxy-jail-" + UUID().uuidString
    guard JailProbes.isDenial(JailProbes.createError(path)) else { throw Failure.fileWriteAllowed }

    guard JailProbes.isDenial(JailProbes.spawnError()) else { throw Failure.execAllowed }

    let blockedPort = UInt16.random(in: 49152...65535)
    guard denied("127.0.0.1", port: blockedPort) else { throw Failure.egressAllowed }
    // Ports 443 and 53 are open to the network only; loopback services stay out of reach.
    guard denied("127.0.0.1", port: 443) else { throw Failure.loopbackHTTPSAllowed }
    guard denied("127.0.0.1", port: 53) else { throw Failure.loopbackDNSAllowed }
    // A TEST-NET-1 address: the non-blocking connect is only started, never completed.
    guard !denied("192.0.2.1", port: 443) else { throw Failure.httpsDenied }

    guard JailProbes.isDenial(JailProbes.homeReadError()) else { throw Failure.homeReadAllowed }
    guard !JailProbes.readsOtherProcesses() else { throw Failure.processInfoAllowed }
  }

  private static func denied(_ host: String, port: UInt16) -> Bool {
    JailProbes.isDenial(JailProbes.connectError(host, port: port))
  }
}
