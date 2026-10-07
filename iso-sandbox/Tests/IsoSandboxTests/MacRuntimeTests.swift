import Foundation
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

// MARK: - helper link over socketpairs

private let hostKey = "ssh-ed25519 " + Data(repeating: 9, count: 51).base64EncodedString()

private final class FakeStore: MacEnrollmentStore, @unchecked Sendable {
  private let lock = NSLock()
  private var enrolled: Bool
  private var key: HelperKey?
  var failSave = false
  private(set) var mismatches: [String] = []
  private(set) var saved: (HelperKey, String)?

  init(enrolled: Bool, key: HelperKey? = nil) {
    self.enrolled = enrolled
    self.key = key
  }
  var isEnrolled: Bool { lock.withLock { enrolled } }
  var helperKey: HelperKey? { lock.withLock { key } }
  var authorizedKey: String { hostKey }
  var network: HelperNetwork {
    HelperNetwork(address: "10.231.9.2", prefix: 24, gateway: "10.231.9.1", dns: [])
  }
  func saveEnrollment(key: HelperKey, sshHostKey: String) throws {
    if failSave { throw SandboxError("disk full") }
    lock.withLock {
      self.key = key
      enrolled = true
      saved = (key, sshHostKey)
    }
  }
  func markMismatch(_ reason: String) { lock.withLock { mismatches.append(reason) } }
}

/// The guest end of one connection.
private struct GuestEnd {
  let fd: Int32
  var reader: LineReader

  init(fd: Int32) {
    self.fd = fd
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    reader = LineReader(fd: fd)
  }

  mutating func read() -> HelperMessage? {
    guard case .line(let l) = reader.next(), case .success(let m) = HelperMessage.parse(l) else {
      return nil
    }
    return m
  }

  func send(_ m: HelperMessage) {
    let line = m.encodedLine()
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  }

  /// Reads the challenge and answers it.
  mutating func hello(boot: String, enrolled: Bool, key: HelperKey?) -> String? {
    guard let c = read(), c.type == .challenge, let nonce = c.nonce else { return nil }
    var h = HelperMessage(type: .hello)
    h.boot = boot
    h.enrolled = enrolled
    h.mac = key.map { HelperProtocol.mac(key: $0, nonce: nonce, boot: boot) }
    send(h)
    return nonce
  }
}

private func connect(_ link: MacHelperLink) -> GuestEnd? {
  var fds: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
  guard link.accept(fd: fds[0], retaining: nil) else {
    close(fds[1])
    return nil
  }
  return GuestEnd(fd: fds[1])
}

private func waitFor(_ cond: () -> Bool) async -> Bool {
  for _ in 0..<100 {
    if cond() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return cond()
}

@Test func aDisagreeingEnrollmentClaimRejectsTheConnectionAndChangesNothing() async {
  let store = FakeStore(enrolled: true, key: .random())
  let link = MacHelperLink(store: store, log: { _ in })
  guard var guest = connect(link) else {
    Issue.record("socketpair")
    return
  }
  _ = guest.hello(boot: "B", enrolled: false, key: nil)
  #expect(await waitFor { link.pendingCount == 0 })
  #expect(!link.isConnected)
  #expect(store.mismatches.isEmpty)
  #expect(store.isEnrolled)
}

@Test func anAuthenticatedHelloBecomesActiveAndAForgedOneNeverReplacesIt() async {
  let key = HelperKey.random()
  let store = FakeStore(enrolled: true, key: key)
  let link = MacHelperLink(store: store, log: { _ in })
  guard var real = connect(link) else {
    Issue.record("socketpair")
    return
  }
  _ = real.hello(boot: "B1", enrolled: true, key: key)
  #expect(await waitFor { link.isConnected })
  let generation = link.generation
  #expect(link.guestBoot == "B1")
  guard var forged = connect(link) else {
    Issue.record("socketpair")
    return
  }
  _ = forged.hello(boot: "EVIL", enrolled: true, key: .random())
  #expect(await waitFor { link.pendingCount == 0 })
  #expect(link.guestBoot == "B1")
  #expect(link.generation == generation)
  #expect(store.mismatches.isEmpty)
}

@Test func enrollmentPersistsOnlyAProvenKeyAndAFailedSaveDoesNotActivate() async {
  for failSave in [false, true] {
    let store = FakeStore(enrolled: false)
    store.failSave = failSave
    let link = MacHelperLink(store: store, log: { _ in })
    guard var guest = connect(link) else {
      Issue.record("socketpair")
      return
    }
    guard let nonce = guest.hello(boot: "B", enrolled: false, key: nil), let enroll = guest.read(),
      enroll.type == .enroll, let k = enroll.key.flatMap({ HelperKey(hex: $0) })
    else {
      Issue.record("no enroll message")
      return
    }
    #expect(enroll.authorizedKey == hostKey)
    var reply = HelperMessage(type: .enrolled)
    reply.sshHostKey = hostKey + " root@guest"
    reply.mac = HelperProtocol.mac(key: k, nonce: nonce, boot: "B")
    guest.send(reply)
    if failSave {
      #expect(await waitFor { link.pendingCount == 0 })
      #expect(!link.isConnected)
      #expect(store.saved == nil)
    } else {
      #expect(await waitFor { link.isConnected })
      #expect(store.saved?.0 == k)
      #expect(store.saved?.1 == hostKey)
    }
  }
}

@Test func anEnrolledReplyWithoutProofOfTheKeyIsNotSaved() async {
  let store = FakeStore(enrolled: false)
  let link = MacHelperLink(store: store, log: { _ in })
  guard var guest = connect(link) else {
    Issue.record("socketpair")
    return
  }
  guard let nonce = guest.hello(boot: "B", enrolled: false, key: nil), guest.read()?.type == .enroll
  else {
    Issue.record("no enroll message")
    return
  }
  var reply = HelperMessage(type: .enrolled)
  reply.sshHostKey = hostKey
  reply.mac = HelperProtocol.mac(key: .random(), nonce: nonce, boot: "B")
  guest.send(reply)
  #expect(await waitFor { link.pendingCount == 0 })
  #expect(!link.isConnected)
  #expect(store.saved == nil)
}

@Test func pendingConnectionsAreCapped() async {
  let link = MacHelperLink(store: FakeStore(enrolled: true, key: .random()), log: { _ in })
  var held: [GuestEnd] = []
  for _ in 0..<HelperProtocol.maxPending {
    guard let g = connect(link) else {
      Issue.record("refused below the cap")
      return
    }
    held.append(g)
  }
  #expect(connect(link) == nil)
  #expect(link.pendingCount == HelperProtocol.maxPending)
  for g in held { close(g.fd) }
  #expect(await waitFor { link.pendingCount == 0 })
}

@Test func aSupersededConnectionCannotAnswerARequest() async {
  let key = HelperKey.random()
  let link = MacHelperLink(store: FakeStore(enrolled: true, key: key), log: { _ in })
  guard var first = connect(link) else {
    Issue.record("socketpair")
    return
  }
  _ = first.hello(boot: "B", enrolled: true, key: key)
  #expect(await waitFor { link.isConnected })
  #expect(first.read()?.type == .network)
  first.send(HelperMessage(type: .ack))
  guard var second = connect(link) else {
    Issue.record("socketpair")
    return
  }
  _ = second.hello(boot: "B", enrolled: true, key: key)
  #expect(await waitFor { link.generation == 2 })
  #expect(second.read()?.type == .network)
  second.send(HelperMessage(type: .ack))
  // The old connection's late reply must not answer the new request.
  var stale = HelperMessage(type: .statusReply)
  stale.sshHostKey = "ssh-ed25519 " + Data(repeating: 1, count: 51).base64EncodedString()
  first.send(stale)
  let answered = Task.detached { link.status() }
  #expect(second.read()?.type == .status)
  var genuine = HelperMessage(type: .statusReply)
  genuine.sshHostKey = hostKey
  second.send(genuine)
  #expect(await answered.value?.sshHostKey == hostKey)
}

// MARK: - sessions

private let binding = CUBinding(
  bootId: "owner1", vmInstance: "vm1", guestBoot: "g1", helperGeneration: 1, width: 1920,
  height: 1200)

@Test func sessionsAreRefusedOnceTheirBindingBreaksAndStayRefused() throws {
  var t = CUSessions()
  #expect(throws: SandboxError.self) { try t.open(current: nil) }
  let (id, b) = try t.open(current: binding)
  #expect(try t.check(id, current: binding) == b)
  #expect(throws: SandboxError.self) { try t.check("nope", current: binding) }
  var rebooted = binding
  rebooted.guestBoot = "g2"
  do {
    _ = try t.check(id, current: rebooted)
    Issue.record("a changed guest boot must refuse")
  } catch {
    #expect("\(error)".contains("guest boot changed"))
  }
  // Forgotten: refused even if the original binding came back.
  do {
    _ = try t.check(id, current: binding)
    Issue.record("a refused session must stay refused")
  } catch {
    #expect("\(error)" == "unknown session")
  }
}

@Test func actionsMayOnlyBuildOnFramesFromTheirOwnBinding() throws {
  var t = CUSessions()
  let (fid, seq) = t.recordFrame(binding)
  #expect(seq == 1)
  #expect(throws: Never.self) { try t.requireFrame(fid, from: binding) }
  var other = binding
  other.bootId = "owner2"
  #expect(throws: SandboxError.self) { try t.requireFrame(fid, from: other) }
  #expect(throws: SandboxError.self) { try t.requireFrame("owner1-99", from: binding) }
  // Old frames age out.
  for _ in 0..<CUSessions.keptFrames { _ = t.recordFrame(binding) }
  #expect(throws: SandboxError.self) { try t.requireFrame(fid, from: binding) }
}

@Test func heightChangesAlsoBreakABinding() {
  var c = binding
  c.height = 1080
  #expect(binding.mismatch(c) == "geometry changed")
}

@Test func actionBoundsAcceptTheirEdges() throws {
  let v = { (r: CUActionRequest) in try r.validated(width: 100, height: 100) }
  var r = CUActionRequest(kind: "click")
  r.x = 99
  r.y = 99
  r.count = 3
  #expect(try v(r) == .click(CUPoint(x: 99, y: 99), .left, count: 3))
  r = CUActionRequest(kind: "drag")
  r.path = Array(repeating: CUPoint(x: 1, y: 1), count: CUActionRequest.maxPath)
  #expect(throws: Never.self) { try v(r) }
  r.path = [CUPoint(x: 0, y: 0), CUPoint(x: 1, y: 1)]
  #expect(throws: Never.self) { try v(r) }
  r = CUActionRequest(kind: "scroll")
  r.x = 1
  r.y = 1
  r.dy = CUActionRequest.maxScroll
  #expect(throws: Never.self) { try v(r) }
  r.dy = CUActionRequest.maxScroll + 1
  #expect(throws: SandboxError.self) { try v(r) }
  for code in [0, 127] {
    r = CUActionRequest(kind: "key")
    r.keyCode = code
    #expect(throws: Never.self) { try v(r) }
  }
  r = CUActionRequest(kind: "type")
  r.text = String(repeating: "a", count: CUActionRequest.maxText)
  #expect(throws: Never.self) { try v(r) }
}

@Test func handshakeRejectsMalformedHellosAndAMissingHostKey() {
  let nonce = String(repeating: "c", count: 32)
  var h = HelperMessage(type: .enrolled)
  h.boot = "B"
  h.enrolled = true
  #expect(
    Handshake.decide(hostEnrolled: true, hostKey: .random(), hello: h, nonce: nonce)
      == .reject("malformed hello"))
  h = HelperMessage(type: .hello)
  h.boot = "B"
  #expect(
    Handshake.decide(hostEnrolled: true, hostKey: .random(), hello: h, nonce: nonce)
      == .reject("malformed hello"))
  h.enrolled = true
  h.mac = "00"
  #expect(
    Handshake.decide(hostEnrolled: true, hostKey: nil, hello: h, nonce: nonce)
      == .reject("missing mac"))
}

@Test func verifyEnrolledRefusesTheWrongTypeAndAnotherBoot() {
  let k = HelperKey.random()
  let nonce = String(repeating: "d", count: 32)
  var r = HelperMessage(type: .ack)
  r.sshHostKey = hostKey
  r.mac = HelperProtocol.mac(key: k, nonce: nonce, boot: "B")
  #expect(
    Handshake.verifyEnrolled(r, key: k, nonce: nonce, boot: "B") == .failure(.unexpected("ack")))
  r.type = .enrolled
  #expect(Handshake.verifyEnrolled(r, key: k, nonce: nonce, boot: "OTHER") == .failure(.badMAC))
}

@Test func helperKeysAreASCIIHexOnly() {
  #expect(HelperKey(hex: String(repeating: "ａ", count: 64)) == nil)  // full-width
}

@Test func guestTextHasNoControlCharacters() {
  #expect(GuestText.printable("a\nb\u{1b}[2Jc") == "a?b?[2Jc")
}

// MARK: - sandbox lifecycle refusals (no VM needed)

private func tempRoot() throws -> SandboxRoot {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "mac-\(UUID().uuidString)")
  return try SandboxRoot(dir.path)
}

private func fakeTemplate(_ root: SandboxRoot, _ name: String = "t") throws -> SandboxID {
  try root.createMacDirectories()
  let id = try SandboxID(name)
  let t = root.macTemplate(id)
  try FileManager.default.createDirectory(at: t.dir, withIntermediateDirectories: true)
  for f in [t.disk, t.aux, t.hardwareModel] { try Data("x".utf8).write(to: f) }
  let meta = MacTemplate(
    name: id, productVersion: "27.0.1", build: "26A434", ipswSha256: "0", helperSha256: "0",
    diskBytes: 1, minimumCPUs: 2, minimumMemoryBytes: 4 << 30, createdAt: Date())
  try JSONEncoder.pretty.encode(meta).write(to: t.metadata)
  return id
}

@Test func createClonesAPrivateIdentityAndRefusesBadInput() async throws {
  let root = try tempRoot()
  let t = try fakeTemplate(root)
  let id = try SandboxID("m1")
  await #expect(throws: SandboxError.self) {
    try await MacSandboxes.create(
      root: root, id: id, owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30, network: .shared,
      authorizedKey: "ssh-rsa AAAA")
  }
  await #expect(throws: SandboxError.self) {
    try await MacSandboxes.create(
      root: root, id: id, owner: "o", template: t, cpus: 1, memoryBytes: 8 << 30, network: .shared,
      authorizedKey: hostKey)
  }
  let a = try await MacSandboxes.create(
    root: root, id: id, owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30, network: .hostOnly,
    authorizedKey: hostKey)
  let b = try await MacSandboxes.create(
    root: root, id: try SandboxID("m2"), owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30,
    network: .shared, authorizedKey: hostKey)
  #expect(a.enrollment == .pending)
  #expect(a.macAddress != b.macAddress)
  #expect(a.subnetIndex != b.subnetIndex)
  let ma = try Data(contentsOf: root.macSandbox(a.id).machineID)
  let mb = try Data(contentsOf: root.macSandbox(b.id).machineID)
  #expect(ma != mb)
  // One identifier namespace: a second create of the same id is refused.
  await #expect(throws: SandboxError.self) {
    try await MacSandboxes.create(
      root: root, id: id, owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30, network: .shared,
      authorizedKey: hostKey)
  }
  // A Linux sandbox directory with the same id also blocks it.
  try FileManager.default.createDirectory(
    at: root.sandbox(try SandboxID("m3")).dir, withIntermediateDirectories: true)
  await #expect(throws: SandboxError.self) {
    try await MacSandboxes.create(
      root: root, id: try SandboxID("m3"), owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30,
      network: .shared, authorizedKey: hostKey)
  }
}

@Test func createsOfEitherKindSerializeOnOneIdentifierLock() async throws {
  let root = try tempRoot()
  let t = try fakeTemplate(root)
  let id = try SandboxID("m4")
  #expect(root.macSandbox(id).mutationLock == root.sandbox(id).mutationLock)
  // A Linux create holding the id's lock claims the id before releasing it;
  // a macOS create waiting on the lock must then see the claim.
  var held: FileLock? = try FileLock.acquire(root.sandbox(id).mutationLock, .exclusive)
  let mac = Task {
    try await MacSandboxes.create(
      root: root, id: id, owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30, network: .shared,
      authorizedKey: hostKey)
  }
  try await Task.sleep(for: .milliseconds(200))
  #expect(!FileManager.default.fileExists(atPath: root.macSandbox(id).dir.path))
  try FileManager.default.createDirectory(
    at: root.sandbox(id).dir, withIntermediateDirectories: true)
  held = nil
  _ = held
  await #expect(throws: SandboxError.self) { try await mac.value }
  #expect(!FileManager.default.fileExists(atPath: root.macSandbox(id).dir.path))
}

@Test func startAndDeleteRefuseWhatTheyMust() async throws {
  let root = try tempRoot()
  let t = try fakeTemplate(root)
  let id = try SandboxID("m1")
  _ = try await MacSandboxes.create(
    root: root, id: id, owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30, network: .shared,
    authorizedKey: hostKey)
  await #expect(throws: SandboxError.self) {
    try await MacSandboxes.start(
      root: root, id: id, executable: "/usr/bin/false", wait: 1,
      expiresAt: Date().addingTimeInterval(-1))
  }
  let paths = root.macSandbox(id)
  var r = try paths.loadRecord()
  r.enrollment = .identityMismatch
  try paths.save(r)
  do {
    _ = try await MacSandboxes.start(
      root: root, id: id, executable: "/usr/bin/false", wait: 1, expiresAt: nil)
    Issue.record("an identity mismatch must refuse to start")
  } catch {
    #expect("\(error)".contains("identity mismatch"))
  }
  await #expect(throws: SandboxError.self) {
    try await MacSandboxes.delete(root: root, id: id, owner: "someone-else")
  }
  try await MacSandboxes.delete(root: root, id: id, owner: "o")
  #expect(!FileManager.default.fileExists(atPath: paths.dir.path))
  #expect(MacSandboxes.status(paths) == .stopped)
}

@Test func templateDeleteRefusesATemplateASandboxStillUses() async throws {
  let root = try tempRoot()
  let t = try fakeTemplate(root)
  let id = try SandboxID("m5")
  _ = try await MacSandboxes.create(
    root: root, id: id, owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30, network: .shared,
    authorizedKey: hostKey)
  #expect(throws: SandboxError.self) { try MacTemplates.delete(root: root, name: t) }
  #expect(FileManager.default.fileExists(atPath: root.macTemplate(t).dir.path))
  try await MacSandboxes.delete(root: root, id: id, owner: "o")
  try MacTemplates.delete(root: root, name: t)
  #expect(!FileManager.default.fileExists(atPath: root.macTemplate(t).dir.path))
  #expect(throws: (any Error).self) { try MacTemplates.delete(root: root, name: t) }
}

@Test func provisioningRunsAsRootBeforeHostKeysAreRemoved() throws {
  let plain = MacTemplates.guestSetupScript()
  #expect(!plain.contains("iso-provision.sh </dev/null"))
  let script = MacTemplates.guestSetupScript(provision: true)
  let run = try #require(script.range(of: "/bin/bash /Users/iso/iso-provision.sh </dev/null"))
  let keys = try #require(script.range(of: "rm -f /etc/ssh/ssh_host_*"))
  let cleanup = try #require(script.range(of: "/Users/iso/iso-provision.sh\n"))
  #expect(run.lowerBound < cleanup.lowerBound && cleanup.lowerBound < keys.lowerBound)
  #expect(script.hasPrefix("#!/bin/sh\nset -eu\n"))
}

@Test func anOwnerWaitsForThePreviousVMToReleaseItsImages() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "mac-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let image = dir.appendingPathComponent("aux.img")
  try Data("x".utf8).write(to: image)
  let held = open(image.path, O_RDONLY)
  #expect(flock(held, LOCK_EX) == 0)
  #expect(throws: SandboxError.self) { try MacOwner.awaitImagesReleased([image], timeout: 0.6) }
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { close(held) }
  let start = Date()
  try MacOwner.awaitImagesReleased([image], timeout: 10)
  #expect(Date().timeIntervalSince(start) >= 0.4)
}

@Test func aPendingHostReEnrollsAGuestThatKeptAnInterruptedKey() async {
  let store = FakeStore(enrolled: false)
  let link = MacHelperLink(store: store, log: { _ in })
  guard var guest = connect(link) else {
    Issue.record("socketpair")
    return
  }
  guard let nonce = guest.hello(boot: "B", enrolled: true, key: .random()),
    let enroll = guest.read(),
    enroll.type == .enroll, let k = enroll.key.flatMap({ HelperKey(hex: $0) })
  else {
    Issue.record("a pending host must send enroll")
    return
  }
  var reply = HelperMessage(type: .enrolled)
  reply.sshHostKey = hostKey
  reply.mac = HelperProtocol.mac(key: k, nonce: nonce, boot: "B")
  guest.send(reply)
  #expect(await waitFor { link.isConnected })
  #expect(store.saved?.0 == k)
}

@Test func aTemplateDeleteWaitsForACreateCloningIt() async throws {
  let root = try tempRoot()
  let t = try fakeTemplate(root)
  // A create in progress holds the template shared.
  var creating: FileLock? = try FileLock.acquire(root.macTemplateLock(t), .shared)
  let delete = Task.detached { try MacTemplates.delete(root: root, name: t) }
  try await Task.sleep(for: .milliseconds(300))
  #expect(FileManager.default.fileExists(atPath: root.macTemplate(t).dir.path))
  creating = nil
  _ = creating
  try await delete.value
  #expect(!FileManager.default.fileExists(atPath: root.macTemplate(t).dir.path))
}

// MARK: - the owner's record store and pin check, for real

/// A real record store for a created sandbox, enrolled with `hostKey`, and
/// a link with an authenticated, network-acked guest connection.
private func enrolledOwner(_ root: SandboxRoot, _ id: SandboxID) async throws -> (
  MacSandboxPaths, MacRecordStore, MacHelperLink, GuestEnd
)? {
  let t = try fakeTemplate(root)
  let record = try await MacSandboxes.create(
    root: root, id: id, owner: "o", template: t, cpus: 4, memoryBytes: 8 << 30, network: .shared,
    authorizedKey: hostKey)
  let paths = root.macSandbox(id)
  let store = MacRecordStore(
    paths: paths, record: record,
    network: HelperNetwork(address: "10.231.9.2", prefix: 24, gateway: "10.231.9.1", dns: []))
  let key = HelperKey.random()
  try store.saveEnrollment(key: key, sshHostKey: hostKey)
  let link = MacHelperLink(store: store, log: { _ in })
  guard var guest = connect(link) else { return nil }
  _ = guest.hello(boot: "B", enrolled: true, key: key)
  guard await waitFor({ link.isConnected }), guest.read()?.type == .network else { return nil }
  guest.send(HelperMessage(type: .ack))
  return (paths, store, link, guest)
}

private func answerStatus(_ guest: inout GuestEnd, with key: String) -> Bool {
  guard guest.read()?.type == .status else { return false }
  var reply = HelperMessage(type: .statusReply)
  reply.sshHostKey = key
  guest.send(reply)
  return true
}

@Test func theSamePinnedKeyWithAGuestCommentStaysEnrolled() async throws {
  let root = try tempRoot()
  guard let (paths, store, link, connected) = try await enrolledOwner(root, try SandboxID("m7"))
  else {
    Issue.record("no enrolled owner")
    return
  }
  var guest = connected
  let verified = Task { await MacOwner.verifyPin(link: link, store: store) }
  #expect(answerStatus(&guest, with: hostKey + " root@guest"))
  #expect(await verified.value)
  #expect(try paths.loadRecord().enrollment == .enrolled)
  // An enrolled record is never enrolled again, and its pin is unchanged.
  #expect(throws: SandboxError.self) {
    try store.saveEnrollment(key: .random(), sshHostKey: "ssh-ed25519 AAAA")
  }
  #expect(paths.loadPinnedHostKey() == hostKey)
}

@Test func anAuthenticatedDifferentHostKeyIsPersistedAsAMismatch() async throws {
  let root = try tempRoot()
  guard let (paths, store, link, connected) = try await enrolledOwner(root, try SandboxID("m8"))
  else {
    Issue.record("no enrolled owner")
    return
  }
  var guest = connected
  let other = "ssh-ed25519 " + Data(repeating: 7, count: 51).base64EncodedString()
  let verified = Task { await MacOwner.verifyPin(link: link, store: store) }
  #expect(answerStatus(&guest, with: other))
  #expect(await verified.value == false)
  #expect(store.current.enrollment == .identityMismatch)
  #expect(try paths.loadRecord().enrollment == .identityMismatch)
}

@Test func aLateReplyNumberedForAnEarlierRequestDoesNotAnswerTheNext() async {
  let key = HelperKey.random()
  let link = MacHelperLink(store: FakeStore(enrolled: true, key: key), log: { _ in })
  guard var guest = connect(link) else {
    Issue.record("socketpair")
    return
  }
  _ = guest.hello(boot: "B", enrolled: true, key: key)
  #expect(await waitFor { link.isConnected })
  guard let network = guest.read(), network.type == .network, let first = network.id else {
    Issue.record("numbered network request")
    return
  }
  var ack = HelperMessage(type: .ack)
  ack.id = first
  guest.send(ack)
  let answered = Task.detached { link.status() }
  guard let status = guest.read(), status.type == .status, let second = status.id else {
    Issue.record("numbered status request")
    return
  }
  #expect(second != first)
  // A reply for the earlier request (late, after its timeout) is ignored.
  var stale = HelperMessage(type: .statusReply)
  stale.id = first
  stale.sshHostKey = "ssh-ed25519 " + Data(repeating: 1, count: 51).base64EncodedString()
  guest.send(stale)
  var genuine = HelperMessage(type: .statusReply)
  genuine.id = second
  genuine.sshHostKey = hostKey
  guest.send(genuine)
  #expect(await answered.value?.sshHostKey == hostKey)
}

@Test func aTemplateBuildWithoutTheHelperFailsBeforeReadingTheRestoreImage() async throws {
  let root = try tempRoot()
  let missing = URL(fileURLWithPath: "/nonexistent/iso-macos-helper")
  let ipsw = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).ipsw")
  do {
    _ = try await MacTemplates.build(
      root: root, name: try SandboxID("t1"), ipsw: ipsw, helper: missing, executable: "/x",
      cpus: 4, memoryBytes: 8 << 30, diskBytes: 64 << 30)
    Issue.record("built without a helper")
  } catch {
    #expect("\(error)".contains("iso-macos-helper not found"))
  }
  #expect(MacTemplates.list(root: root).isEmpty)
}
