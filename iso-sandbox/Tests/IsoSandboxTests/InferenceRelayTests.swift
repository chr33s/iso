import Containerization
import ContainerizationExtras
import Foundation
import Synchronization
import Testing

@testable import IsoSandboxCore

/// The one socket relay a record can switch on (secure-local-inference §22): the record field,
/// the derived host socket, the owner's machine configuration and report, and the owner's relay
/// between guest connections and the gateway's socket.
@Suite struct InferenceRelayTests {
  static func record(relay: Bool = false, network: NetworkMode = .shared) throws -> SandboxRecord {
    var r = SandboxRecord(
      id: try SandboxID("a"), owner: "o", imageReference: "i", imageDigest: "d", baseDisk: nil,
      environment: [], cpus: 1, memoryBytes: 1 << 30, diskBytes: 1 << 30,
      subnetIndex: network.usesSubnet ? 1 : nil, createdAt: Date(timeIntervalSince1970: 0),
      network: network)
    try r.setInferenceRelay(relay)
    return r
  }

  static func paths() throws -> SandboxPaths {
    try SandboxRoot(FileManager.default.temporaryDirectory.path + "/csb-relay").sandbox(
      try SandboxID("a"))
  }

  static func interface() throws -> NATInterface {
    NATInterface(
      ipv4Address: try CIDRv4("10.231.1.2/24"), ipv4Gateway: try IPv4Address("10.231.1.1"))
  }

  static let bootLog = BootLog.file(path: URL(fileURLWithPath: "/dev/null"))

  // MARK: record

  @Test func theRecordSwitchesTheRelayOnAndCarriesNoPath() throws {
    let off = try Self.record()
    #expect(!off.relaysInference)
    let plain = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder.pretty.encode(off)) as? [String: Any])
    #expect(plain["inferenceRelay"] == nil)
    let on = try Self.record(relay: true)
    let text = String(decoding: try JSONEncoder.pretty.encode(on), as: UTF8.self)
    #expect(text.contains("\"inferenceRelay\" : true"))
    #expect(try JSONDecoder.iso.decode(SandboxRecord.self, from: Data(text.utf8)).relaysInference)
    // The record can only switch the relay on; it names no host or guest path.
    #expect(!text.contains(".sock"))
    // `false` reads as absent and is written as absent.
    let explicitOff = text.replacingOccurrences(
      of: "\"inferenceRelay\" : true", with: "\"inferenceRelay\" : false")
    let decoded = try JSONDecoder.iso.decode(SandboxRecord.self, from: Data(explicitOff.utf8))
    #expect(!decoded.relaysInference && decoded.inferenceRelay == nil)
  }

  /// A brokered owner opens no host listener that routes to a socket (NET-04), so neither the
  /// record nor `start` can give it the relay.
  @Test func aBrokeredSandboxCannotHaveTheRelay() throws {
    #expect(throws: SandboxError.self) { try Self.record(relay: true, network: .brokered) }
    var brokered = try Self.record(network: .brokered)
    try brokered.setInferenceRelay(false)
    let text = String(decoding: try JSONEncoder.pretty.encode(brokered), as: UTF8.self)
    let forged = text.replacingOccurrences(
      of: "\"imageDigest\"", with: "\"inferenceRelay\" : true,\n  \"imageDigest\"")
    #expect(forged != text)
    #expect(throws: DecodingError.self) {
      try JSONDecoder.iso.decode(SandboxRecord.self, from: Data(forged.utf8))
    }
    #expect(throws: SandboxError.self) {
      try Sandboxes.bootRecord(brokered, expiresAt: nil, networkPolicy: nil, inferenceRelay: true)
    }
  }

  /// `start --inference-relay on|off` switches the relay from this boot on; omitted keeps it.
  @Test func startSwitchesOrKeepsTheRecordedRelay() throws {
    let off = try Self.record()
    let on = try Self.record(relay: true)
    func boot(_ record: SandboxRecord, _ relay: Bool?) throws -> SandboxRecord? {
      try Sandboxes.bootRecord(record, expiresAt: nil, networkPolicy: nil, inferenceRelay: relay)
    }
    #expect(try boot(off, true)?.inferenceRelay == true)
    #expect(try boot(on, false).map { $0.inferenceRelay == nil } == true)
    #expect(try boot(on, nil) == nil)
    #expect(try boot(off, nil) == nil)
    #expect(try boot(on, true) == nil)
    #expect(try boot(off, false) == nil)
    // The session window still applies to each boot alone, beside a kept relay.
    let deadline = Date(timeIntervalSince1970: 1_000)
    let windowed = try #require(
      try Sandboxes.bootRecord(on, expiresAt: deadline, networkPolicy: nil, inferenceRelay: nil))
    #expect(windowed.expiresAt == deadline && windowed.relaysInference)
    #expect(throws: SandboxError.self) {
      try Sandboxes.bootRecord(
        on, expiresAt: nil, networkPolicy: String(repeating: "a", count: 64), inferenceRelay: nil)
    }
  }

  // MARK: paths

  @Test func theHostSocketIsDerivedInsideThePrivateDirectory() throws {
    let socket = try Self.paths().inferenceSocket
    #expect(socket.deletingLastPathComponent().path == InferenceRelay.hostDirectory.path)
    #expect(
      InferenceRelay.hostDirectory.deletingLastPathComponent() == SandboxPaths.controlDirectory)
    #expect(socket.lastPathComponent.hasSuffix(".sock"))
    let name = socket.lastPathComponent.dropLast(5)
    #expect(!name.isEmpty && name.count <= 16 && name.allSatisfy(\.isHexDigit))
    // It must fit sun_path.
    #expect(socket.path.utf8.count < 104)
  }

  // MARK: machine configuration and report

  @Test func theOwnerConfiguresAndReportsExactlyTheInferenceRelay() throws {
    let paths = try Self.paths()
    let rootfs = Mount.block(format: "ext4", source: "/r", destination: "/", options: [])
    let devices = VMDevices(network: [.vmnet], socket: 1)

    let offRecord = try Self.record()
    let off = Owner.machineConfiguration(
      record: offRecord, interface: try Self.interface(), bootLog: Self.bootLog,
      relay: InferenceRelay.Endpoint.of(offRecord, at: paths))
    #expect(off.sockets.isEmpty)
    #expect(off.mounts.count == LinuxContainer.defaultMounts().count)
    let offReport = Owner.effectiveConfig(
      record: offRecord, config: off, rootfs: rootfs, devices: devices)
    #expect(offReport.socketRelays == 0 && offReport.inferenceRelay == nil)
    #expect(
      !String(decoding: try JSONEncoder.wire.encode(offReport), as: UTF8.self)
        .contains("inferenceRelay"))

    let onRecord = try Self.record(relay: true)
    let relay = try #require(InferenceRelay.Endpoint.of(onRecord, at: paths))
    #expect(relay.host == paths.inferenceSocket)
    let on = Owner.machineConfiguration(
      record: onRecord, interface: try Self.interface(), bootLog: Self.bootLog, relay: relay)
    // The owner relays the socket itself: the framework is given no relay of its own.
    #expect(on.sockets.isEmpty)
    let guestEnd = try #require(on.mounts.last)
    #expect(on.mounts.count == LinuxContainer.defaultMounts().count + 1)
    #expect(guestEnd.type == "bind" && guestEnd.options == ["bind"])
    #expect(guestEnd.source == "/run/iso-inference/gateway.sock")
    #expect(guestEnd.destination == "/var/lib/iso-inference/gateway.sock")
    let report = Owner.effectiveConfig(
      record: onRecord, config: on, rootfs: rootfs, devices: devices, relay: relay)
    #expect(report.socketRelays == 1)
    #expect(
      report.inferenceRelay
        == .init(
          host: paths.inferenceSocket.path, guest: "/var/lib/iso-inference/gateway.sock",
          maxConnections: 32))
    // The guest end is the relay, not a mount: the mounts are the kernel pseudo-filesystems.
    #expect(report.mounts.map(\.destination) == offReport.mounts.map(\.destination))
    let json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder.wire.encode(report)) as? [String: Any])
    let reported = try #require(json["inferenceRelay"] as? [String: Any])
    #expect(Set(reported.keys) == ["host", "guest", "maxConnections"])

    // A relay whose guest end the configuration lacks is not reported as one.
    let missing = Owner.effectiveConfig(
      record: onRecord, config: off, rootfs: rootfs, devices: devices, relay: relay)
    #expect(missing.socketRelays == 0 && missing.inferenceRelay == nil)
  }

  // MARK: the relay

  @Test func aConnectionAtTheCapIsClosedBeforeTheGatewayIsDialed() throws {
    let gateway = try FakeGateway(serve: .hold)
    defer { gateway.stop() }
    let server = gateway.server()
    defer { server.shutdownAll() }
    var guests: [Int32] = []
    defer { for fd in guests { close(fd) } }
    for _ in 0..<InferenceRelay.maxConnections {
      let (ours, theirs) = try pair()
      #expect(server.accept(ours))
      guests.append(theirs)
    }
    #expect(try eventually { gateway.accepted == InferenceRelay.maxConnections })
    let (ours, theirs) = try pair()
    defer { close(theirs) }
    #expect(!server.accept(ours))
    #expect(readsEOF(theirs))
    Thread.sleep(forTimeInterval: 0.2)
    #expect(gateway.accepted == InferenceRelay.maxConnections)
    #expect(server.active == InferenceRelay.maxConnections)
  }

  /// A guest can hold every slot with idle connections; the gateway closing one frees its slot
  /// at once, without the guest doing anything.
  @Test func aClosedGatewayConnectionFreesItsSlotWhileTheGuestIsIdle() throws {
    let gateway = try FakeGateway(serve: .hold)
    defer { gateway.stop() }
    let server = gateway.server()
    defer { server.shutdownAll() }
    var guests: [Int32] = []
    defer { for fd in guests { close(fd) } }
    for _ in 0..<InferenceRelay.maxConnections {
      let (ours, theirs) = try pair()
      #expect(server.accept(ours))
      guests.append(theirs)
    }
    #expect(try eventually { gateway.accepted == InferenceRelay.maxConnections })
    gateway.closeOne()
    #expect(try eventually { server.active == InferenceRelay.maxConnections - 1 })
    let (ours, theirs) = try pair()
    guests.append(theirs)
    #expect(server.accept(ours))
    #expect(try eventually { gateway.accepted == InferenceRelay.maxConnections + 1 })
  }

  /// The gateway answers, then closes while the guest is behind and still sending: every byte
  /// it sent reaches the guest before the guest sees EOF (no truncated stream).
  @Test func everyByteTheGatewaySentReachesAGuestThatIsBehind() throws {
    let body = (0..<(192 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let gateway = try FakeGateway(serve: .answer(body))
    defer { gateway.stop() }
    let server = gateway.server()
    defer { server.shutdownAll() }
    let (ours, guest) = try pair()
    defer { close(guest) }
    var one: Int32 = 1
    setsockopt(guest, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #expect(server.accept(ours))
    #expect(Splice.writeAll(guest, Array("request\n".utf8)))
    #expect(try eventually { gateway.answered == 1 })
    // The gateway has written everything and closed; the guest has read nothing and sends more.
    #expect(Splice.writeAll(guest, Array("pipelined\n".utf8)))
    Thread.sleep(forTimeInterval: 0.2)
    #expect(readAll(guest) == body)
    #expect(try eventually { server.active == 0 })
  }

  /// The guest's EOF reaches the gateway as EOF, and the gateway can still answer.
  @Test func theGuestsHalfCloseReachesTheGatewayWhichStillAnswers() throws {
    let gateway = try FakeGateway(serve: .echoAfterEOF)
    defer { gateway.stop() }
    let server = gateway.server()
    defer { server.shutdownAll() }
    let (ours, guest) = try pair()
    defer { close(guest) }
    #expect(server.accept(ours))
    #expect(Splice.writeAll(guest, Array("ping".utf8)))
    shutdown(guest, SHUT_WR)
    #expect(readAll(guest) == Array("ping".utf8))
  }

  /// A guest that stops reading while the gateway sends loses the connection after the stall.
  @Test func aGuestThatStopsReadingLosesItsConnection() throws {
    let gateway = try FakeGateway(serve: .flood)
    defer { gateway.stop() }
    let server = gateway.server(stallSeconds: 1)
    defer { server.shutdownAll() }
    let (ours, guest) = try pair()
    defer { close(guest) }
    #expect(server.accept(ours))
    #expect(try eventually { gateway.accepted == 1 })
    #expect(server.active == 1)
    #expect(try eventually(timeout: .seconds(10)) { server.active == 0 })
  }

  /// R1: with no gateway socket a guest connection is closed, and the next one is relayed once
  /// the socket is back.
  @Test func aMissingGatewayClosesOnlyThatConnection() throws {
    let dir = FakeGateway.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("g.sock")
    try ControlSocket.prepareDirectory(for: path)
    let server = InferenceRelayServer(
      endpoint: .init(host: path), expiresAt: nil, log: { _ in })
    defer { server.shutdownAll() }
    let (missing, peer) = try pair()
    defer { close(peer) }
    #expect(server.accept(missing))
    #expect(readsEOF(peer))
    #expect(try eventually { server.active == 0 })

    let gateway = try FakeGateway(in: dir, name: "g.sock", serve: .hold)
    defer { gateway.stop() }
    let (ours, theirs) = try pair()
    defer { close(theirs) }
    #expect(server.accept(ours))
    #expect(try eventually { gateway.accepted == 1 })
  }

  /// No relayed connection outlives a halt or the boot's deadline, and none is accepted after.
  @Test func aHaltClosesRelayedConnectionsAndRefusesNewOnes() async throws {
    let gateway = try FakeGateway(serve: .hold)
    defer { gateway.stop() }
    let server = gateway.server()
    let (ours, guest) = try pair()
    defer { close(guest) }
    #expect(server.accept(ours))
    #expect(try eventually { gateway.accepted == 1 })
    let lifecycle = Lifecycle(
      container: Inert(), relay: server, haltGrace: .seconds(30), killGrace: .seconds(30),
      forceExit: {})
    await lifecycle.requestHalt()
    #expect(readsEOF(guest))
    #expect(try eventually { server.active == 0 })
    let (late, theirs) = try pair()
    defer { close(theirs) }
    #expect(!server.accept(late))
    #expect(readsEOF(theirs))
    await lifecycle.markStopped()

    let expired = InferenceRelayServer(
      endpoint: .init(host: gateway.path), expiresAt: Date().addingTimeInterval(-1),
      log: { _ in })
    let (tooLate, peer) = try pair()
    defer { close(peer) }
    #expect(!expired.accept(tooLate))
    #expect(readsEOF(peer))
    #expect(gateway.accepted == 1)
  }
}

// MARK: - helpers

/// A connected socket pair: the relay's end and the guest's.
private func pair() throws -> (Int32, Int32) {
  var fds: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SandboxError("socketpair") }
  return (fds[0], fds[1])
}

/// Whether `fd` reads EOF within five seconds (rather than data, an error or a timeout).
private func readsEOF(_ fd: Int32) -> Bool {
  ControlSocket.setReceiveTimeout(fd, 5)
  var byte: UInt8 = 0
  return read(fd, &byte, 1) == 0
}

/// Everything `fd` delivers until EOF, or until a read waits five seconds.
private func readAll(_ fd: Int32) -> [UInt8] {
  ControlSocket.setReceiveTimeout(fd, 5)
  var out: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { return out }
    out += buffer[0..<count]
  }
}

private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.01)
  }
  return condition()
}

/// A machine whose guest agent takes every signal and does nothing.
private struct Inert: HaltableContainer {
  func kill(_ signal: Signal) async throws {}
}

/// A stand-in for the gateway's per-sandbox socket, in a private directory of its own.
private final class FakeGateway: Sendable {
  enum Behaviour: Sendable {
    /// Keep each connection open, unread, until `closeOne` or `stop`.
    case hold
    /// Read one line, write `body` and close.
    case answer([UInt8])
    /// Echo what arrives once the peer's EOF arrives, then close.
    case echoAfterEOF
    /// Write until a write fails.
    case flood
  }

  struct Counts: Sendable {
    var accepted = 0
    var answered = 0
    var held: [Int32] = []
  }

  let path: URL
  private let ownsDirectory: Bool
  private let listener: Int32
  private let counts = Mutex(Counts())

  /// A fresh private directory beside the real relay directory (short enough for sun_path).
  static func directory() -> URL {
    SandboxPaths.controlDirectory.appendingPathComponent(
      "relay-test-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
  }

  convenience init(serve: Behaviour) throws {
    try self.init(in: Self.directory(), name: "g.sock", serve: serve, ownsDirectory: true)
  }

  init(in dir: URL, name: String, serve: Behaviour, ownsDirectory: Bool = false) throws {
    path = dir.appendingPathComponent(name)
    self.ownsDirectory = ownsDirectory
    try ControlSocket.prepareDirectory(for: path)
    unlink(path.path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(fd, 128) == 0 else {
      close(fd)
      throw SandboxError("fake gateway: bind/listen errno \(errno)")
    }
    listener = fd
    Thread.detachNewThread { [self] in
      while true {
        let conn = accept(fd, nil, nil)
        if conn < 0 {
          if errno == EINTR || errno == ECONNABORTED { continue }
          return
        }
        var one: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        counts.withLock { $0.accepted += 1 }
        Thread.detachNewThread { [self] in handle(conn, serve) }
      }
    }
  }

  private func handle(_ conn: Int32, _ behaviour: Behaviour) {
    switch behaviour {
    case .hold:
      counts.withLock { $0.held.append(conn) }
    case .answer(let body):
      // Room for the whole answer, so this side can finish and close while the guest is behind.
      var size = Int32(body.count * 2)
      setsockopt(conn, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      _ = Splice.readLine(conn, limit: 64)
      _ = Splice.writeAll(conn, body)
      close(conn)
      counts.withLock { $0.answered += 1 }
    case .echoAfterEOF:
      var received: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(conn, $0.baseAddress, $0.count) }
        guard count > 0 else { break }
        received += buffer[0..<count]
      }
      _ = Splice.writeAll(conn, received)
      close(conn)
    case .flood:
      let chunk = [UInt8](repeating: 0x2A, count: 64 << 10)
      while Splice.writeAll(conn, chunk) {}
      close(conn)
    }
  }

  var accepted: Int { counts.withLock { $0.accepted } }
  var answered: Int { counts.withLock { $0.answered } }

  /// Closes one held connection, as a gateway ending an idle session does.
  func closeOne() {
    counts.withLock { counts in
      if let fd = counts.held.popLast() { close(fd) }
    }
  }

  func server(stallSeconds: Int = InferenceRelay.stallSeconds) -> InferenceRelayServer {
    InferenceRelayServer(
      endpoint: .init(host: path), expiresAt: nil, stallSeconds: stallSeconds, log: { _ in })
  }

  func stop() {
    shutdown(listener, SHUT_RDWR)
    close(listener)
    counts.withLock { counts in
      for fd in counts.held { close(fd) }
      counts.held.removeAll()
    }
    unlink(path.path)
    if ownsDirectory { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
  }
}
