import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost
@testable import IsoHostControl

/// A clock whose monotonic reading advances by `step` on every read once
/// armed: time passing between two checks inside one registry call.
final class SteppingClock: HostClock {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)
  private let baseInstant = ContinuousClock.now
  private let state = Mutex<(offset: Duration, step: Duration)>((.zero, .zero))

  func now() -> Date { base }
  func monotonic() -> ContinuousClock.Instant {
    state.withLock { s in
      let value = baseInstant + s.offset
      s.offset += s.step
      return value
    }
  }
  func set(offset: Duration, step: Duration) { state.withLock { $0 = (offset, step) } }
}

/// The fake runtime, with a real authorized-key set whose removals land late
/// (a slow guest command), as the production hygiene task can.
final class SlowKeyRemovalNative: NativeHost {
  let inner = FakeNativeHost()
  let keys = Mutex<Set<String>>([])
  let removals = Mutex(0)

  func qualification() -> RuntimeQualification { inner.qualification() }
  func observe(_ i: InstanceID, runtime r: MachineName) throws(NativeFailure) -> NativeState {
    try inner.observe(i, runtime: r)
  }
  func create(_ i: InstanceID, runtime r: MachineName, spec: VMSpec, owner: OwnerID)
    throws(NativeFailure)
  { try inner.create(i, runtime: r, spec: spec, owner: owner) }
  func start(_ i: InstanceID, runtime r: MachineName, expiresAt: Date?) throws(NativeFailure) {
    try inner.start(i, runtime: r, expiresAt: expiresAt)
  }
  func stop(_ i: InstanceID, runtime r: MachineName) throws(NativeFailure) {
    try inner.stop(i, runtime: r)
  }
  func delete(_ i: InstanceID, runtime r: MachineName, owner: OwnerID) throws(NativeFailure) {
    try inner.delete(i, runtime: r, owner: owner)
  }
  func guestEndpoint(_ i: InstanceID, runtime r: MachineName) throws(NativeFailure)
    -> GuestEndpoint
  { try inner.guestEndpoint(i, runtime: r) }
  func networkProof(_ i: InstanceID, runtime r: MachineName) throws(NativeFailure)
    -> NetworkProof?
  { try inner.networkProof(i, runtime: r) }
  func imageReady(_ image: ImageName) -> Bool { inner.imageReady(image) }
  func ensureImage(_ request: ImageRequest) throws(NativeFailure) -> String {
    try inner.ensureImage(request)
  }
  func maintain(_ i: InstanceID, runtime r: MachineName, _ change: Maintenance)
    throws(NativeFailure)
  { try inner.maintain(i, runtime: r, change) }
  func filteredPolicy(_ i: InstanceID, runtime r: MachineName) throws(NativeFailure)
    -> FilteredGrantPolicy?
  { try inner.filteredPolicy(i, runtime: r) }
  func guestUser(_ i: InstanceID, runtime r: MachineName) throws(NativeFailure) -> GuestUser {
    try inner.guestUser(i, runtime: r)
  }
  func guestHostKey(_ i: InstanceID, runtime r: MachineName) throws(NativeFailure) -> String {
    try inner.guestHostKey(i, runtime: r)
  }
  func authorizeClientKey(_ i: InstanceID, runtime r: MachineName, key: ClientPublicKey)
    throws(NativeFailure)
  {
    try inner.authorizeClientKey(i, runtime: r, key: key)
    _ = keys.withLock { $0.insert(key.line) }
  }
  func removeClientKey(_ i: InstanceID, runtime r: MachineName, key: ClientPublicKey) {
    Thread.sleep(forTimeInterval: 0.3)
    _ = keys.withLock { $0.remove(key.line) }
    removals.withLock { $0 += 1 }
  }
  func exportResults(_ i: InstanceID, runtime r: MachineName, limit: UInt64)
    throws(NativeFailure) -> [UInt8]
  { try inner.exportResults(i, runtime: r, limit: limit) }
  func networkCapability() -> NetworkCapability { inner.networkCapability() }
  func imageDigest(_ image: ImageName) -> String? { inner.imageDigest(image) }
}

final class RevokedLog: Sendable { let ids = Mutex<[SessionID]>([]) }

@Suite struct HostControlRevocationTests {
  func registry(_ clock: SteppingClock, _ revoked: RevokedLog) -> AccessSessions {
    AccessSessions(
      epoch: .generate(), clock: clock, revoked: { ids in revoked.ids.withLock { $0 += ids } })
  }

  func grant() throws -> (AccessOpenRequest, AccessSessions.Binding) {
    let owner = try OwnerID(String(repeating: "ab", count: 16))
    let instance = QualifiedInstance(
      hostID: .generate(), ownerID: owner, instanceID: .generate(),
      runtimeID: try MachineName.generate(for: owner, randomHex: "0011223344556677"),
      guestOS: .linux)
    let key = try ClientPublicKey(testPublicKey(1))
    let boot = try BootID("boot-1")
    let policy = try SHA256Hex(String(repeating: "a", count: 64))
    let binding = AccessSessions.Binding(
      instance: instance, bootID: boot, policyHash: policy, generation: 2,
      client: try ClientLabel("laptop"), clientKey: key.fingerprint, purpose: .ssh,
      guestHostKey: fakeGuestHostKey, guestUser: try GuestUser("iso"), clientPublicKey: key,
      filteredPolicy: nil)
    let request = AccessOpenRequest(
      instance: instance, expectedEpoch: .generate(), expectedBoot: boot, expectedGeneration: 2,
      policyHash: policy, session: .generate(), client: try ClientLabel("laptop"), clientKey: key,
      purpose: .ssh, bearer: .generate())
    return (request, binding)
  }

  /// A lease that lapses while a renewal, relay admission or replayed open is
  /// being decided is revoked like one a sweep finds: no entry point can mark
  /// a session expired and leave its relay streams open.
  @Test(arguments: ["renew", "admitRelay", "open"])
  func everyExpiryIsRevoked(_ entry: String) throws {
    let clock = SteppingClock()
    let revoked = RevokedLog()
    let sessions = registry(clock, revoked)
    let (template, binding) = try grant()
    let request = AccessOpenRequest(
      instance: template.instance, expectedEpoch: sessions.epoch,
      expectedBoot: template.expectedBoot, expectedGeneration: 2,
      policyHash: template.policyHash, session: template.session, client: template.client,
      clientKey: template.clientKey, purpose: .ssh, bearer: template.bearer)
    _ = try sessions.open(request, binding: binding, vmExpiresAt: nil)
    // The lease ends at +30 s; the entry point is the first to read +35 s.
    clock.set(offset: .seconds(35), step: .zero)
    switch entry {
    case "renew":
      _ = try? sessions.renew(
        session: request.session, bearer: request.bearer, epoch: sessions.epoch,
        boot: request.expectedBoot, policy: request.policyHash)
    case "admitRelay":
      _ = try? sessions.admitRelay(
        session: request.session, bearer: request.bearer, epoch: sessions.epoch)
    default:
      _ = try? sessions.open(request, binding: binding, vmExpiresAt: nil)
    }
    clock.set(offset: .seconds(1_000), step: .zero)
    _ = sessions.sweep()
    #expect(!sessions.isLive(request.session))
    #expect(revoked.ids.withLock { $0 } == [request.session])
  }

  /// A close's key removal that runs after the same client opened a new
  /// session for the instance never removes the key that session uses.
  @Test func lateKeyRemovalKeepsANewerSessionsKey() throws {
    let native = SlowKeyRemovalNative()
    let root = FileManager.default.temporaryDirectory.appending(path: "iso-hc-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let owner = try OwnerID(String(repeating: "ab", count: 16))
    var settings = HostSupervisor.Settings()
    settings.dispatch = .manual
    let supervisor = try HostSupervisor(
      root: root, owner: owner, native: native, clock: ManualClock(), settings: settings)
    func call(_ body: HostRequestBody, operation: HostOperationID? = nil)
      -> Result<JSONValue, HostControlError>
    {
      supervisor.handle(
        HostRequest(
          hostID: supervisor.installation.hostID, ownerID: owner, operationID: operation,
          body: body),
        transport: .ssh
      ).outcome
    }
    let spec = try VMSpec.make(
      name: InstanceName("proj"), image: .default, imageDigest: nil, cpus: 2, memoryMiB: 4096,
      diskGiB: 8, guestOS: .linux, egress: .open)
    let created = try OperationReceipt(wire: call(.vmCreate(spec), operation: .generate()).get())
    supervisor.runPending()
    let instance = try #require(created.instance)
    _ = try call(
      .vmStart(instance, expectedGeneration: 1, ttlSeconds: 3_600, policy: spec.policyHash),
      operation: .generate()
    ).get()
    supervisor.runPending()
    let observation = try VMObservation(wire: call(.vmInspect(instance)).get())
    func request() throws -> AccessOpenRequest {
      AccessOpenRequest(
        instance: instance, expectedEpoch: supervisor.epoch,
        expectedBoot: try #require(observation.bootID), expectedGeneration: observation.generation,
        policyHash: spec.policyHash, session: .generate(), client: try ClientLabel("laptop"),
        clientKey: try ClientPublicKey(testPublicKey(1)), purpose: .ssh, bearer: .generate())
    }
    func close(_ request: AccessOpenRequest) throws {
      _ = try call(
        .accessClose(session: request.session, bearer: request.bearer, epoch: supervisor.epoch)
      ).get()
    }
    let line = try ClientPublicKey(testPublicKey(1)).line
    // Two live sessions share the key: closing one keeps it for the other.
    let first = try request()
    let second = try request()
    _ = try call(.accessOpen(first)).get()
    _ = try call(.accessOpen(second)).get()
    try close(first)
    supervisor.keyQueue(instance.instanceID).sync {}
    #expect(native.removals.withLock { $0 } == 0)
    #expect(native.keys.withLock { $0.contains(line) })
    // The last close's removal lands after the next session's authorization.
    try close(second)
    let third = try request()
    _ = try call(.accessOpen(third)).get()
    let deadline = ContinuousClock.now + .seconds(1)
    while native.removals.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    supervisor.keyQueue(instance.instanceID).sync {}
    #expect(supervisor.sessions.isLive(third.session))
    #expect(native.keys.withLock { $0.contains(line) })
  }
}

@Suite struct HostControlServerLimitTests {
  func serve(_ f: SupervisorFixture, _ limits: LocalHostServer.Limits) throws -> HostControlPaths {
    let paths = HostControlPaths(
      directory: FileManager.default.temporaryDirectory.appending(
        path: "iso-hc-\(UUID().uuidString.prefix(8))"
      ).path)
    let server = LocalHostServer(
      supervisor: f.supervisor, paths: paths,
      diagnostics: Diagnostics(verbosity: 0, sink: { _ in }), limits: limits)
    let listeners = try server.bind()
    Thread.detachNewThread { server.serve(listeners) }
    return paths
  }

  /// Reads until EOF or `timeout`; true when the peer closed.
  func closedByPeer(_ fd: Int32, within timeout: Duration) -> Bool {
    Socket.setReceiveTimeout(fd, timeout)
    var byte: UInt8 = 0
    return read(fd, &byte, 1) == 0
  }

  @Test func theRelayBudgetIsTheRegistryCap() {
    #expect(LocalHostServer.Limits.standard.relay == RelayRegistry.maxStreams)
    #expect(LocalHostServer.Limits.standard.readDeadline == .seconds(10))
  }

  /// Relay connections use their own budget: a full relay socket never stops
  /// control requests (renewal, stop, destroy).
  @Test func aFullRelaySocketLeavesControlAvailable() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    var limits = LocalHostServer.Limits.standard
    limits.relay = 4
    let paths = try serve(f, limits)
    defer { try? FileManager.default.removeItem(atPath: paths.directory) }
    var held: [Int32] = []
    defer { for fd in held { close(fd) } }
    for _ in 0..<limits.relay { held.append(try #require(connectUnix(paths.relay))) }
    Thread.sleep(forTimeInterval: 0.2)
    // The relay socket itself is full...
    let refused = try #require(connectUnix(paths.relay))
    defer { close(refused) }
    #expect(closedByPeer(refused, within: .seconds(2)))
    // ...while control and remote still answer.
    let client = HostControlClient(transport: LocalHostTransport(paths: paths), expected: nil)
    #expect(try client.hello(clientBuild: "t").hostID == f.hostID)
    let remote = try #require(connectUnix(paths.remote))
    defer { close(remote) }
    let hello = HostRequest(
      hostID: nil, ownerID: nil, body: .hello(protocols: [HostProtocol.v1], clientBuild: "t"))
    #expect((try? AtomicFile.writeAll(remote, hello.frame, "test")) != nil)
    #expect(Socket.readLine(remote, limit: HostWire.maxResponseFrame) != nil)
  }

  /// A connection that sends no frame, or a relay no preamble, is closed at the
  /// read deadline instead of holding its slot.
  @Test func idleConnectionsEndAtTheReadDeadline() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    var limits = LocalHostServer.Limits.standard
    limits.readDeadline = .milliseconds(300)
    let paths = try serve(f, limits)
    defer { try? FileManager.default.removeItem(atPath: paths.directory) }
    for path in [paths.control, paths.remote, paths.relay] {
      let fd = try #require(connectUnix(path))
      defer { close(fd) }
      let started = ContinuousClock.now
      #expect(closedByPeer(fd, within: .seconds(3)))
      #expect(ContinuousClock.now - started < .seconds(2))
    }
  }

  /// Chunked reads stop at the newline: the bytes after it (a relay's stream)
  /// stay unread. Over-long lines are refused at the same boundary as before.
  @Test func readLineNeverConsumesPastTheNewline() throws {
    var pair: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { for fd in pair { close(fd) } }
    let sent = Array("first\nsecond\nraw-bytes".utf8)
    #expect((try? AtomicFile.writeAll(pair[0], sent, "test")) != nil)
    #expect(Socket.readLine(pair[1], limit: 64) == Array("first".utf8))
    #expect(Socket.readLine(pair[1], limit: 64) == Array("second".utf8))
    var rest = [UInt8](repeating: 0, count: 64)
    let count = rest.withUnsafeMutableBytes { read(pair[1], $0.baseAddress, $0.count) }
    #expect(Array(rest.prefix(max(0, count))) == Array("raw-bytes".utf8))
    // `limit` bounds the line without its newline: limit - 1 bytes pass.
    #expect((try? AtomicFile.writeAll(pair[0], Array("abc\nabcd\n".utf8), "test")) != nil)
    #expect(Socket.readLine(pair[1], limit: 4) == Array("abc".utf8))
    #expect(Socket.readLine(pair[1], limit: 4) == nil)
    // The refused line's newline is still unread, as with byte reads.
    #expect(Socket.readLine(pair[1], limit: 4) == [])
    // A frame larger than one chunk arrives whole.
    let large = [UInt8](repeating: UInt8(ascii: "x"), count: 200_000)
    let writer = pair[0]
    Thread.detachNewThread { _ = try? AtomicFile.writeAll(writer, large + [0x0A], "test") }
    #expect(Socket.readLine(pair[1], limit: 1 << 20)?.count == large.count)
    // A pipe is read a byte at a time, with the same result.
    var pipeFDs: [Int32] = [-1, -1]
    #expect(pipe(&pipeFDs) == 0)
    defer { for fd in pipeFDs { close(fd) } }
    #expect((try? AtomicFile.writeAll(pipeFDs[1], Array("line\nnext".utf8), "test")) != nil)
    #expect(Socket.readLine(pipeFDs[0], limit: 64) == Array("line".utf8))
    var next = [UInt8](repeating: 0, count: 4)
    #expect(read(pipeFDs[0], &next, 4) == 4)
    #expect(next == Array("next".utf8))
  }
}

@Suite(.serialized) struct HostControlPendingIndexTests {
  /// Periodic passes read the write index, not a listing of the ledger: with
  /// the operations and runs directories unlistable, pending work still runs.
  @Test func pendingWorkRunsWithoutListingTheLedger() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()))
    let run = RunID.generate()
    _ = try f.receipt(
      .runCreate(
        run: run, spec: try f.spec(name: "run", egress: .none), outputLimitBytes: 1 << 20,
        ttlSeconds: 600))
    let directories = [f.supervisor.store.operationsDirectory, f.supervisor.runs.root]
    for directory in directories { #expect(chmod(directory, 0o300) == 0) }
    defer { for directory in directories { chmod(directory, 0o700) } }
    f.supervisor.runPending()
    for directory in directories { chmod(directory, 0o700) }
    #expect(try f.operation(created.operationID).state == .succeeded)
    let state = try RunObservation(wire: f.call(.runInspect(run)).get())
    #expect(state.phase == .running)
  }

  /// Terminal records leave the index after one pass; a later nonterminal
  /// write adds its id back.
  @Test func terminalRecordsLeaveTheIndex() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()))
    #expect(f.supervisor.pendingOperations.snapshot() == [created.operationID])
    f.supervisor.runPending()
    #expect(f.supervisor.nonterminalOperations().isEmpty)
    #expect(f.supervisor.pendingOperations.snapshot().isEmpty)
    // A restarted supervisor seeds the index from its one full scan.
    let instance = try #require(created.instance)
    let start = try f.receipt(
      .vmStart(instance, expectedGeneration: 1, ttlSeconds: 600, policy: f.spec().policyHash))
    let restarted = try f.restarted()
    #expect(restarted.supervisor.pendingOperations.snapshot() == [start.operationID])
  }
}

@Suite struct HostControlBuildCheckTests {
  @Test func helloReportsTheBuildOnlyWhenAsked() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let plain = try f.call(.hello(protocols: [HostProtocol.v1], clientBuild: "t")).get()
    #expect(plain["build"] == nil)
    #expect(try HelloResult(wire: plain).build == nil)
    let asked = try f.call(
      .hello(protocols: [HostProtocol.v1], clientBuild: "t", includeBuild: true)
    ).get()
    #expect(try HelloResult(wire: asked).build == IsoBuild.current.versionString)
    // The question travels only when set, so older services see the frame they know.
    let frame = HostRequest(
      hostID: nil, ownerID: nil, body: .hello(protocols: [HostProtocol.v1], clientBuild: "t")
    ).frame
    #expect(!String(decoding: frame, as: UTF8.self).contains("include_build"))
  }

  @Test func onlyThisExecutablesStaleJobIsRestarted() {
    let ours = "0.11.0 (abc)"
    let exe = "/usr/local/bin/iso"
    #expect(
      HostService.classify(running: ours, ours: ours, jobProgram: exe, executable: exe)
        == .current)
    #expect(
      HostService.classify(running: "0.10.0 (def)", ours: ours, jobProgram: exe, executable: exe)
        == .stale)
    // A service too old to report its build.
    #expect(
      HostService.classify(running: nil, ours: ours, jobProgram: exe, executable: exe) == .stale)
    // Another installation's job is never restarted from here.
    #expect(
      HostService.classify(
        running: "0.10.0 (def)", ours: ours, jobProgram: "/opt/iso/bin/iso", executable: exe)
        == .otherInstallation)
    #expect(
      HostService.classify(running: nil, ours: ours, jobProgram: nil, executable: exe)
        == .otherInstallation)
  }

  @Test func theJobProgramIsReadFromTheServicePlist() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iso-plist-\(UUID())")
      .path
    try StateStore.ensurePrivateDirectory(directory)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let plist = directory + "/service.plist"
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["Label": "x", "ProgramArguments": ["/usr/local/bin/iso", "host-agent"]],
      format: .xml, options: 0)
    try AtomicFile.write(Array(data), to: plist, mode: .atMost(0o600))
    #expect(HostService.jobProgram(plist) == "/usr/local/bin/iso")
    #expect(HostService.jobProgram(directory + "/absent.plist") == nil)
  }
}

@Suite struct HostControlClientDecodeTests {
  @Test func hostAuthoredTextIsSanitizedOnDecode() throws {
    let receipt = OperationReceipt(
      operationID: .generate(), method: .vmStop, state: .failed, disposition: .existing,
      acceptedAt: WireTime(seconds: 1), completedAt: nil, instance: nil, generation: nil,
      bootID: nil, expiresAt: nil, outcome: "\u{1B}]0;owned\u{07}done", cancelRequested: false)
    #expect(try OperationReceipt(wire: receipt.wire).outcome == "?]0;owned?done")
    var run: [String: JSONValue] = [:]
    run["run_id"] = .string(RunID.generate().rawValue)
    run["generation"] = .number(.unsigned(1))
    run["phase"] = .string("destroyed")
    run["recovery_used"] = .bool(false)
    run["disposition"] = .string("\u{1B}[2Jgone")
    #expect(try RunObservation(wire: .object(run)).disposition == "?[2Jgone")
  }
}

/// Answers `artifact.read` from one byte buffer, refusing lengths above
/// `maxLength` the way an older host's decoder does.
final class ArtifactHost: HostTransport {
  let bytes: [UInt8]
  let maxLength: UInt32
  let host = HostID.generate()
  let owner: OwnerID
  let reads = Mutex<[UInt32]>([])

  init(bytes: [UInt8], maxLength: UInt32) throws {
    self.bytes = bytes
    self.maxLength = maxLength
    owner = try OwnerID(String(repeating: "ab", count: 16))
  }

  func exchange(_ frame: [UInt8]) throws(HostControlError) -> [UInt8] {
    let request: HostRequest
    do { request = try HostRequest.decode(frame: Array(frame.dropLast())) } catch {
      throw .invalidRequest("bad frame")
    }
    guard case .artifactRead(let handle, let offset, let length) = request.body else {
      throw .invalidRequest("unexpected method")
    }
    reads.withLock { $0.append(length) }
    let outcome: Result<JSONValue, HostControlError>
    if length > maxLength {
      outcome = .failure(.invalidRequest("params.length must be 1-\(maxLength)"))
    } else {
      let start = Int(min(offset, UInt64(bytes.count)))
      let end = min(start + Int(length), bytes.count)
      var b = WireBuilder()
      b.set("handle", handle)
      b.set("offset", offset)
      b.set("data", Data(bytes[start..<end]).base64EncodedString())
      outcome = .success(b.value)
    }
    return Array(
      HostResponse(
        requestID: request.requestID, hostID: host, ownerID: owner, epoch: .generate(),
        outcome: outcome
      ).frame.dropLast())
  }
}

@Suite struct RemoteRunDownloadTests {
  func download(_ host: ArtifactHost, _ archive: [UInt8]) throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "iso-dl-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: home) }
    let environment = ConfigEnvironment(home: home, variables: ["HOME": home])
    let config = try ConfigLoader.load(
      .defaultsOnly(defaultPath: home + "/.iso/config.jsonc"), environment: environment)
    var wire = WireBuilder()
    wire.set("run_id", RunID.generate())
    wire.set("generation", UInt64(3))
    wire.set("phase", "results_pending")
    wire.set("artifact", ArtifactHandle.generate())
    wire.set("artifact_digest", HostWire.sha256(archive))
    wire.set("recovery_used", false)
    let run = try RunObservation(wire: wire.value)
    let client = HostControlClient(transport: host, expected: (host.host, host.owner))
    let stage = try RemoteRunResults.download(
      client, run: run, config: config, host: host.host, limit: 1 << 20)
    #expect(try StateStore.readControlFile(stage.path) == archive)
  }

  func archive() -> [UInt8] {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let payload = (0..<100_000).map { _ -> UInt8 in
      state = state &* 6_364_136_223_846_793_005 &+ 1
      return UInt8(truncatingIfNeeded: state >> 33)
    }
    return tarArchive([("out.bin", payload)])
  }

  /// Results come back in large chunks, so each remote SSH call carries more.
  @Test func resultsDownloadInLargeChunks() throws {
    let bytes = archive()
    let host = try ArtifactHost(
      bytes: bytes, maxLength: UInt32(HostRequestBody.maxArtifactReadChunk))
    try download(host, bytes)
    #expect(host.reads.withLock { $0 }.count == 2)
  }

  /// A host older than this client refuses the larger chunk; the download
  /// continues at its size.
  @Test func anOlderHostIsReadAtItsChunkSize() throws {
    let bytes = archive()
    let host = try ArtifactHost(bytes: bytes, maxLength: UInt32(HostRequestBody.maxArtifactChunk))
    try download(host, bytes)
    let reads = host.reads.withLock { $0 }
    #expect(reads.first == UInt32(HostRequestBody.maxArtifactReadChunk))
    #expect(reads.dropFirst().allSatisfy { $0 == UInt32(HostRequestBody.maxArtifactChunk) })
  }

  /// The largest read still fits one response frame.
  @Test func theLargestReadFitsAResponseFrame() throws {
    var b = WireBuilder()
    b.set("handle", ArtifactHandle.generate())
    b.set("offset", UInt64(0))
    b.set(
      "data",
      Data([UInt8](repeating: 0xFF, count: HostRequestBody.maxArtifactReadChunk))
        .base64EncodedString())
    let response = HostResponse(
      requestID: .generate(), hostID: .generate(),
      ownerID: try OwnerID(String(repeating: "ab", count: 16)), epoch: .generate(),
      outcome: .success(b.value))
    #expect(response.frame.count < HostWire.maxResponseFrame)
    #expect(throws: Never.self) { try HostResponse.decode(frame: Array(response.frame.dropLast())) }
    let request = try HostRequestBody(
      method: .artifactRead,
      params: HostRequestBody.artifactRead(
        handle: .generate(), offset: 0, length: UInt32(HostRequestBody.maxArtifactReadChunk)
      ).params)
    #expect(request.method == .artifactRead)
    #expect(throws: HostControlError.self) {
      try HostRequestBody(
        method: .artifactRead,
        params: HostRequestBody.artifactRead(
          handle: .generate(), offset: 0, length: UInt32(HostRequestBody.maxArtifactReadChunk) + 1
        ).params)
    }
  }
}
