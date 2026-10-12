import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// Worker-owned byte relays to verified guest SSH endpoints (spec 9.1).
/// Each stream belongs to one access session; revoking the session shuts
/// down its sockets, which ends the stream regardless of guest behavior.
/// The client's SSH still verifies the pinned guest host key end to end.
package final class RelayRegistry: Sendable {
  package static let maxStreamsPerSession = 16
  package static let maxStreams = 256
  /// Per-direction user-space buffer; well under the 1 MiB queue bound.
  static let chunk = 64 << 10

  struct Stream: Sendable {
    let client: Int32
    /// The connector process carrying the guest side; killed on revocation.
    let connector: pid_t
  }

  struct State: Sendable {
    var streams: [SessionID: [UInt64: Stream]] = [:]
    var next: UInt64 = 0
    var total = 0
  }

  private let state = Mutex(State())

  package init() {}

  /// Registers a stream, or nil when a session or installation limit is reached.
  func register(_ session: SessionID, client: Int32, connector: pid_t) -> UInt64? {
    state.withLock { state in
      guard state.total < Self.maxStreams,
        (state.streams[session]?.count ?? 0) < Self.maxStreamsPerSession
      else { return nil }
      state.next += 1
      state.streams[session, default: [:]][state.next] = Stream(
        client: client, connector: connector)
      state.total += 1
      return state.next
    }
  }

  func unregister(_ session: SessionID, _ id: UInt64) {
    state.withLock { state in
      if state.streams[session]?.removeValue(forKey: id) != nil { state.total -= 1 }
      if state.streams[session]?.isEmpty == true { state.streams[session] = nil }
    }
  }

  /// Shuts down every stream of `sessions`; the splice threads then close.
  package func close(sessions: [SessionID]) {
    // Shut down under the lock: a stream unregisters (under the same lock)
    // before its descriptors close, so a number here is never reused yet.
    state.withLock { state in
      let streams = sessions.flatMap { state.streams[$0]?.values.map { $0 } ?? [] }
      for stream in streams {
        shutdown(stream.client, SHUT_RDWR)
        // Still unreaped while registered, so the group id cannot be reused.
        kill(-stream.connector, SIGKILL)
      }
    }
  }

  package func closeAll() {
    let all = state.withLock { state in Array(state.streams.keys) }
    close(sessions: all)
  }

  package func count(_ session: SessionID) -> Int {
    state.withLock { $0.streams[session]?.count ?? 0 }
  }

  package var total: Int { state.withLock { $0.total } }
}

/// The relay preamble: one bounded JSON line selecting a live grant.
package struct RelayPreamble: Sendable, Equatable {
  package static let maxBytes = 4_096
  package let session: SessionID
  package let bearer: AccessBearer
  package let epoch: DaemonEpoch

  package init(session: SessionID, bearer: AccessBearer, epoch: DaemonEpoch) {
    self.session = session
    self.bearer = bearer
    self.epoch = epoch
  }

  package var frame: [UInt8] {
    var b = WireBuilder()
    b.set("protocol", HostProtocol.v1)
    b.set("session_id", session)
    b.set("bearer", bearer.rawValue)
    b.set("expected_epoch", epoch)
    return HostWire.frame(b.value)
  }

  package init(frame: [UInt8]) throws(HostControlError) {
    let limits = JSONLimits(
      maxBytes: Self.maxBytes, maxDepth: 2, maxKeys: 8, maxArrayElements: 0, maxNumberLength: 1,
      maxStringBytes: 256)
    var r = try WireObject(try HostWire.parse(frame, limits: limits), field: "")
    guard try r.string("protocol") == HostProtocol.v1 else {
      throw HostControlError(.hostProtocolIncompatible, "unsupported relay protocol")
    }
    session = try r.parsed("session_id", SessionID.init)
    bearer = try r.parsed("bearer", AccessBearer.init)
    epoch = try r.parsed("expected_epoch", DaemonEpoch.init)
    try r.finish()
  }
}

extension HostSupervisor {
  /// Serves one relay connection on the daemon's relay socket: preamble,
  /// admission against a live grant, status line, then raw bytes to the
  /// guest endpoint chosen from current native proof. Closes `client`.
  package func serveRelay(client: Int32) {
    defer { close(client) }
    func status(_ error: HostControlError?) -> Bool {
      var b = WireBuilder()
      if let error { b.set("error", error.wire) } else { b.set("ok", true) }
      return (try? AtomicFile.writeAll(client, HostWire.frame(b.value), "relay")) != nil
    }
    guard let line = Socket.readLine(client, limit: RelayPreamble.maxBytes) else { return }
    let guest: ProcessRunner.PipedChild
    let session: SessionID
    do throws(HostControlError) {
      let preamble = try RelayPreamble(frame: line)
      let binding = try sessions.admitRelay(
        session: preamble.session, bearer: preamble.bearer, epoch: preamble.epoch)
      let endpoint = try relayEndpoint(binding)
      guest = try GuestConnector.open(endpoint)
      session = preamble.session
    } catch {
      _ = status(error)
      return
    }
    // Reaped only after unregistering, so revocation never signals a reused pid.
    defer { guest.terminate() }
    guard let id = relays.register(session, client: client, connector: guest.pid) else {
      _ = status(HostControlError(.limitExceeded, "too many relay streams"))
      return
    }
    defer { relays.unregister(session, id) }
    // The grant may have been revoked between admission and registration.
    guard sessions.isLive(session), status(nil) else { return }
    Socket.splice(client, child: guest)
  }
}

/// Opens the guest side of a relay through `/usr/bin/nc`. A platform binary
/// is used deliberately: macOS Local Network privacy refuses connections to
/// the VM's network from a non-Apple binary running as a background job
/// (no prompt can be shown), while Apple binaries are exempt. The endpoint
/// still comes only from native proof; nc gets it as fixed argv.
package enum GuestConnector {
  static let nc = "/usr/bin/nc"

  package static func open(_ endpoint: GuestEndpoint) throws(HostControlError)
    -> ProcessRunner.PipedChild
  {
    let address = endpoint.address.description
    let port = String(endpoint.port)
    // Probe first so an unreachable guest is a typed refusal, not a silent EOF.
    let probe = try? ProcessRunner().capture(
      .init(
        executable: nc, arguments: ["-z", "-G", "10", address, port], environment: [:],
        deadline: .seconds(15), outputLimit: 4_096, overflow: .drain))
    guard probe?.termination == .exited(0) else {
      throw HostControlError(.hostUnreachable, "the guest endpoint did not accept a connection")
    }
    do {
      return try ProcessRunner().piped(
        .init(
          executable: nc, arguments: ["-G", "10", address, port], environment: [:],
          deadline: .seconds(0)))
    } catch {
      throw HostControlError(.hostUnreachable, "the guest connector could not start")
    }
  }
}

/// Small blocking-socket helpers shared by the control and relay servers.
package enum Socket {
  /// Reads one `\n`-terminated line (without it), at most `limit` bytes.
  /// Nil on EOF, error or an oversized line.
  package static func readLine(_ fd: Int32, limit: Int) -> [UInt8]? {
    var line: [UInt8] = []
    var byte: UInt8 = 0
    while true {
      let count = read(fd, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count == 1 else { return nil }
      if byte == UInt8(ascii: "\n") { return line }
      line.append(byte)
      guard line.count < limit else { return nil }
    }
  }

  /// Copies both directions until each side reaches EOF or fails.
  package static func splice(_ a: Int32, _ b: Int32) {
    let done = DispatchGroup()
    for (from, to) in [(a, b), (b, a)] {
      done.enter()
      Thread.detachNewThread {
        copy(from: from, to: to)
        shutdown(to, SHUT_WR)
        done.leave()
      }
    }
    done.wait()
  }

  /// Copies a socket to a child's stdin and the child's stdout back, until
  /// either side ends.
  static func splice(_ socket: Int32, child: ProcessRunner.PipedChild) {
    let done = DispatchGroup()
    done.enter()
    Thread.detachNewThread {
      copy(from: socket, to: child.input)
      // EOF to the child; the pipe itself is closed when the child is reaped.
      kill(-child.pid, SIGTERM)
      done.leave()
    }
    copy(from: child.output, to: socket)
    shutdown(socket, SHUT_RDWR)
    done.wait()
  }

  static func copy(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: RelayRegistry.chunk)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return }
      guard (try? AtomicFile.writeAll(destination, Array(buffer[0..<count]), "relay")) != nil else {
        return
      }
    }
  }

}
