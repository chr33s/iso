import Containerization
import Foundation
import Synchronization
import Testing

@testable import IsoSandboxCore

/// The brokered transport's owner side: admission against the boot, the
/// policy digests and the limits, the stream table, and the byte relay.
@Suite struct BrokeredTests {
  static let boot = "b7ad1194a3cc79a7720b4f169833bb62"
  static let policy = String(repeating: "a", count: 64)

  func request(
    purpose: String = "ssh", boot: String = boot, channel: String = ChannelPolicy.current.digest,
    network: String? = policy, session: String? = nil
  ) -> StreamRequest {
    StreamRequest(
      purpose: purpose, bootId: boot, channelPolicy: channel, networkPolicy: network,
      session: session)
  }

  func broker(
    policy: ChannelPolicy = .current,
    dial: @escaping @Sendable (UInt32) async throws -> FileHandle = { _ in
      throw SandboxError("no guest")
    }
  ) -> StreamBroker {
    StreamBroker(bootID: Self.boot, networkPolicy: Self.policy, policy: policy, dial: dial)
  }

  @Test func channelPolicyDigestIsPinned() {
    // The host recomputes this digest from its own copy of the policy
    // (BrokeredChannel in Sources/IsoHost); both sides pin the same value.
    #expect(
      ChannelPolicy.current.digest
        == "1beae82700a50cad9663c46faaea554ae4a815f5330c82cdcaa412b5c6a59301")
    #expect(ChannelPolicy.current.endpoints.map(\.guestPort) == [2222])
  }

  @Test func admissionChecksBootPolicyPurposeAndSession() {
    let b = broker()
    #expect(throws: Never.self) { try b.admit(request()).get() }
    b.release()
    let refusals: [(StreamRequest, StreamBroker.Refusal)] = [
      (request(boot: "other"), .bootChanged),
      (request(channel: String(repeating: "0", count: 64)), .channelPolicyChanged),
      (request(network: nil), .networkPolicyChanged),
      (request(network: String(repeating: "b", count: 64)), .networkPolicyChanged),
      (request(purpose: "agent"), .unknownPurpose),
      (request(purpose: "2222"), .unknownPurpose),
      (request(session: "a b"), .badSession),
      (request(session: String(repeating: "s", count: 65)), .badSession),
    ]
    for (req, wanted) in refusals {
      #expect(b.admit(req).failure == wanted)
    }
  }

  @Test func admissionBoundsConcurrencyAndRate() {
    var tight = ChannelPolicy.current
    tight.maxStreams = 2
    tight.maxOpensPerWindow = 3
    let b = broker(policy: tight)
    let digest = tight.digest
    let now = ContinuousClock.now
    #expect(b.admit(request(channel: digest), now: now).failure == nil)
    #expect(b.admit(request(channel: digest), now: now).failure == nil)
    #expect(b.admit(request(channel: digest), now: now).failure == .tooManyStreams)
    b.release()
    #expect(b.admit(request(channel: digest), now: now).failure == nil)
    b.release()
    b.release()
    // Three admissions in this window already: the fourth waits for it to pass.
    #expect(b.admit(request(channel: digest), now: now).failure == .rateLimited)
    #expect(
      b.admit(request(channel: digest), now: now + .seconds(tight.windowSeconds)).failure == nil)
  }

  @Test func shutdownRefusesNewStreams() {
    let b = broker()
    b.shutdownAll()
    #expect(b.admit(request()).failure == .stopping)
  }

  @Test func handlerSlotsAreBounded() {
    let b = broker()
    for _ in 0..<b.maxHandlers { #expect(b.enterHandler()) }
    #expect(!b.enterHandler())
    b.leaveHandler()
    #expect(b.enterHandler())
  }

  @Test func registrationAfterShutdownIsRefused() throws {
    let b = broker()
    _ = try b.admit(request()).get()
    b.shutdownAll()
    #expect(b.register(client: -1, guest: -1, purpose: "ssh", session: nil) == nil)
    #expect(b.open.isEmpty)
  }

  @Test func aFailedGuestDialReturnsItsSlot() throws {
    var single = ChannelPolicy.current
    single.maxStreams = 1
    let b = StreamBroker(bootID: Self.boot, networkPolicy: Self.policy, policy: single) { _ in
      throw SandboxError("no guest adapter")
    }
    let path = SandboxPaths.controlDirectory.appendingPathComponent(
      "test-\(UUID().uuidString.prefix(8)).streams.sock")
    try b.serve(at: path)
    defer { unlink(path.path) }
    // With one slot, a leaked reservation would refuse the second request
    // as "too many open streams" instead of reaching the dial again.
    for _ in 0..<2 {
      let (fd, reply) = try open(path, request(channel: single.digest))
      close(fd)
      #expect(
        reply == StreamReply(ok: false, error: "the guest ssh endpoint did not accept a connection")
      )
    }
  }

  @Test func theBrokeredMachineHasNoInterfaceOrResolver() throws {
    var record = SandboxRecord(
      id: try SandboxID("b"), owner: "o", imageReference: "i", imageDigest: "d", baseDisk: nil,
      environment: [], cpus: 1, memoryBytes: 1 << 30, diskBytes: 1 << 30, subnetIndex: nil,
      createdAt: Date(), network: .brokered)
    record.networkPolicy = Self.policy
    let config = Owner.machineConfiguration(
      record: record, interface: nil, bootLog: .file(path: URL(fileURLWithPath: "/dev/null")))
    #expect(config.interfaces.isEmpty)
    #expect(config.dns == nil)
    #expect(config.hosts?.entries.contains { $0.ipAddress == "127.0.1.1" } == true)
    #expect(config.sockets.isEmpty)
    let rootfs = Mount.block(format: "ext4", source: "/r", destination: "/", options: [])
    let effective = Owner.effectiveConfig(
      record: record, config: config, rootfs: rootfs, devices: VMDevices(network: 0, socket: 1))
    #expect(effective.interfaces.isEmpty)
    #expect(effective.transport == "brokered")
    #expect(effective.networkDevices == 0 && effective.socketDevices == 1)
    #expect(effective.channelPolicyDigest == ChannelPolicy.current.digest)
    #expect(effective.networkPolicy == Self.policy)
    // A vmnet sandbox reports none of the brokered fields.
    record.network = .shared
    let vmnet = Owner.effectiveConfig(record: record, config: config, rootfs: rootfs, devices: nil)
    #expect(vmnet.transport == nil && vmnet.networkDevices == nil && vmnet.channelPolicy == nil)
    let encoded = String(decoding: try JSONEncoder.wire.encode(vmnet), as: UTF8.self)
    #expect(!encoded.contains("transport") && !encoded.contains("channelPolicy"))
  }

  /// A served broker whose "guest" is one end of a socket pair; the test
  /// holds the other end.
  func served() throws -> (StreamBroker, URL, Guests) {
    let guests = Guests()
    let b = broker { _ in
      var pair: [Int32] = [0, 0]
      guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SandboxError("pair") }
      guests.withLock { $0.append(pair[1]) }
      return FileHandle(fileDescriptor: pair[0], closeOnDealloc: false)
    }
    let path = SandboxPaths.controlDirectory.appendingPathComponent(
      "test-\(UUID().uuidString.prefix(8)).streams.sock")
    try b.serve(at: path)
    return (b, path, guests)
  }

  func open(_ path: URL, _ req: StreamRequest) throws -> (Int32, StreamReply) {
    let fd = try ControlSocket.connectClient(path, timeout: 5)
    var line = try JSONEncoder.wire.encode(req)
    line.append(0x0A)
    #expect(Splice.writeAll(fd, Array(line)))
    let reply = try #require(Splice.readLine(fd, limit: 4096))
    return (fd, try JSONDecoder().decode(StreamReply.self, from: Data(reply)))
  }

  @Test func anAdmittedStreamCarriesBytesBothWaysAndHalfCloses() throws {
    let (b, path, guests) = try served()
    defer { unlink(path.path) }
    let (client, reply) = try open(path, request(session: "s1"))
    defer { close(client) }
    #expect(reply == StreamReply(ok: true, error: nil))
    let guest = try #require(guests.withLock { $0.first })
    defer { close(guest) }
    ControlSocket.setReceiveTimeout(guest, 5)
    // Bytes the guest sends at once (an SSH banner) follow the reply line
    // without being consumed by it.
    #expect(Splice.writeAll(guest, Array("SSH-2.0-guest\n".utf8)))
    #expect(Splice.readLine(client, limit: 64) == Array("SSH-2.0-guest".utf8))
    #expect(Splice.writeAll(client, Array("ping".utf8)))
    var buffer = [UInt8](repeating: 0, count: 4)
    #expect(read(guest, &buffer, 4) == 4 && buffer == Array("ping".utf8))
    #expect(b.open.map(\.session) == ["s1"])
    // The client's half-close reaches the guest; the guest can still reply.
    shutdown(client, SHUT_WR)
    #expect(read(guest, &buffer, 4) == 0)
    #expect(Splice.writeAll(guest, Array("pong".utf8)))
    #expect(read(client, &buffer, 4) == 4 && buffer == Array("pong".utf8))
  }

  @Test func refusedRequestsNeverDialTheGuest() throws {
    let (_, path, guests) = try served()
    defer { unlink(path.path) }
    for req in [request(boot: "stale"), request(network: nil), request(purpose: "agent")] {
      let (client, reply) = try open(path, req)
      close(client)
      #expect(!reply.ok)
    }
    #expect(guests.withLock { $0.isEmpty })
  }

  @Test func closingASessionShutsOnlyItsStreams() throws {
    let (b, path, guests) = try served()
    defer { unlink(path.path) }
    let (one, _) = try open(path, request(session: "one"))
    let (two, _) = try open(path, request(session: "two"))
    defer {
      close(one)
      close(two)
      for fd in guests.withLock({ $0 }) { close(fd) }
    }
    #expect(b.close(session: "one").map(\.session) == ["one"])
    ControlSocket.setReceiveTimeout(one, 5)
    var byte: UInt8 = 0
    #expect(read(one, &byte, 1) == 0)
    // The other session's stream still works.
    let guestTwo = try #require(guests.withLock { $0.last })
    #expect(Splice.writeAll(guestTwo, [0x2A]))
    ControlSocket.setReceiveTimeout(two, 5)
    #expect(read(two, &byte, 1) == 1 && byte == 0x2A)
    b.shutdownAll()
    #expect(read(two, &byte, 1) == 0)
  }

  @Test func aBurstPastTheRateWaitsInsteadOfFailing() throws {
    var slow = ChannelPolicy.current
    slow.maxOpensPerWindow = 1
    slow.windowSeconds = 1
    let b = broker(policy: slow)
    _ = try b.admit(request(channel: slow.digest)).get()
    b.release()
    // The second request in the same window waits for it to pass.
    let started = ContinuousClock.now
    let endpoint = b.admitWaiting(
      request(channel: slow.digest), until: .now + .seconds(5), conn: -1)
    #expect(endpoint?.purpose == "ssh")
    #expect(ContinuousClock.now - started >= .milliseconds(900))
    b.release()
    // The window is full again; past the deadline the request is refused
    // (the reply goes to an invalid descriptor).
    #expect(b.admitWaiting(request(channel: slow.digest), until: .now, conn: -1) == nil)
  }

  @Test func aClosedSessionAdmitsNothingMore() throws {
    let b = broker()
    _ = try b.admit(request(session: "s")).get()
    #expect(b.close(session: "s").isEmpty)
    // Its still-dialing stream is refused at registration, and new ones at admission.
    #expect(b.register(client: -1, guest: -1, purpose: "ssh", session: "s") == nil)
    #expect(b.admit(request(session: "s")).failure == .stopping)
    #expect(b.admit(request(session: "t")).failure == nil)
  }

  @Test func aTricklingRequestLineStopsAtTheDeadline() throws {
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      close(pair[0])
      close(pair[1])
    }
    // One byte every 50 ms for 2 s, never a newline, then EOF: each read
    // succeeds well inside any per-read timeout, so only the total deadline
    // can end the line early. Without it the read lasts until the EOF.
    let writer = pair[0]
    Thread.detachNewThread {
      for _ in 0..<40 {
        _ = Splice.writeAll(writer, [UInt8(ascii: "x")])
        Thread.sleep(forTimeInterval: 0.05)
      }
      shutdown(writer, SHUT_WR)
    }
    ControlSocket.setReceiveTimeout(pair[1], 5)
    let started = ContinuousClock.now
    #expect(Splice.readLine(pair[1], limit: 64, deadline: .now + .milliseconds(300)) == nil)
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  @Test func oversizedOrMalformedRequestsAreRefused() throws {
    let (_, path, guests) = try served()
    defer { unlink(path.path) }
    for line in [
      Array(repeating: UInt8(ascii: "x"), count: ChannelPolicy.current.requestBytes + 1),
      Array("{not json}".utf8),
    ] {
      let fd = try ControlSocket.connectClient(path, timeout: 5)
      defer { close(fd) }
      _ = Splice.writeAll(fd, line + [0x0A])
      let reply = try #require(Splice.readLine(fd, limit: 4096))
      #expect(try JSONDecoder().decode(StreamReply.self, from: Data(reply)).ok == false)
    }
    #expect(guests.withLock { $0.isEmpty })
  }

  @Test func readLineStopsAtTheNewline() throws {
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      close(pair[0])
      close(pair[1])
    }
    #expect(Splice.writeAll(pair[0], Array("line\nrest".utf8)))
    #expect(Splice.readLine(pair[1], limit: 16) == Array("line".utf8))
    var rest = [UInt8](repeating: 0, count: 4)
    #expect(read(pair[1], &rest, 4) == 4 && rest == Array("rest".utf8))
  }

  @Test func sessionLabelsAreShortAndPlain() {
    #expect(validStreamLabel("0b4f6c1e-7f5a-4e0a-9b8c-3d2e1f0a9b8c"))
    for bad in ["", "a b", "a/b", "a;b", String(repeating: "x", count: 65), "é"] {
      #expect(!validStreamLabel(bad))
    }
  }

  @Test func brokeredRecordsHoldNoSubnet() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "csb-\(UUID().uuidString)")
    let root = try SandboxRoot(dir.path)
    try root.createDirectories()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = try SandboxID("b")
    let paths = root.sandbox(id)
    try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
    try paths.save(
      SandboxRecord(
        id: id, owner: "o", imageReference: "i", imageDigest: "d", baseDisk: nil, environment: [],
        cpus: 1, memoryBytes: 1, diskBytes: 1, subnetIndex: nil, createdAt: Date(),
        network: .brokered))
    #expect(try SubnetAllocator(root: root).usedIndices(excluding: try SandboxID("x")).isEmpty)
    #expect(try paths.loadRecord().subnetIndex == nil)
    let encoded = String(decoding: try Data(contentsOf: paths.record), as: UTF8.self)
    #expect(!encoded.contains("subnetIndex"))
    #expect(!NetworkMode.brokered.usesSubnet)
    // A record written by this runtime round-trips its mode and boot policy.
    var record = try paths.loadRecord()
    record.networkPolicy = Self.policy
    try paths.save(record)
    #expect(try paths.loadRecord().network == .brokered)
    #expect(try paths.loadRecord().networkPolicy == Self.policy)
  }

  @Test func networkPolicyDigestsAreValidated() {
    #expect(Sandboxes.isPolicyDigest(Self.policy))
    for bad in ["", "A" + String(repeating: "a", count: 63), String(repeating: "a", count: 63)] {
      #expect(!Sandboxes.isPolicyDigest(bad))
    }
  }
}

/// The test's ends of the guest socket pairs the broker dialed.
final class Guests: Sendable {
  private let fds = Mutex<[Int32]>([])
  func withLock<T>(_ body: (inout [Int32]) -> T) -> T { fds.withLock { body(&$0) } }
}

extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
