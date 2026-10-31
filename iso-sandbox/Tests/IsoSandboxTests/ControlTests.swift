import Foundation
import Testing

@testable import IsoSandboxCore

@Suite struct ControlTests {
  func socketPath() -> URL {
    SandboxPaths.controlDirectory.appendingPathComponent("test-\(UUID().uuidString.prefix(8)).sock")
  }

  @Test func roundTripsRequestAndResponse() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serve(at: path) { req in
      switch req.op {
      case .exec:
        ControlResponse(
          ok: true, exitCode: 7, stdout: Data((req.argv ?? []).joined(separator: " ").utf8))
      default: ControlResponse(ok: true)
      }
    }
    #expect(try ControlSocket.call(path, .init(op: .ping)).ok)
    let r = try ControlSocket.call(path, .init(op: .exec, argv: ["echo", "hi"]))
    #expect(r.exitCode == 7)
    #expect(r.stdout == Data("echo hi".utf8))
  }

  @Test func socketIsOwnerOnly() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serve(at: path) { _ in ControlResponse(ok: true) }
    var st = stat()
    #expect(stat(path.path, &st) == 0)
    #expect(st.st_mode & 0o077 == 0)
    #expect(stat(path.deletingLastPathComponent().path, &st) == 0)
    #expect(st.st_mode & 0o077 == 0)
  }

  @Test func missingOwnerIsAnError() {
    #expect(throws: SandboxError.self) { try ControlSocket.call(socketPath(), .init(op: .ping)) }
  }

  @Test func silentOwnerTimesOut() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serve(at: path) { _ in
      try? await Task.sleep(for: .seconds(10))
      return ControlResponse(ok: true)
    }
    let start = Date()
    #expect(throws: SandboxError.self) {
      try ControlSocket.call(path, .init(op: .ping), timeout: 1)
    }
    #expect(Date().timeIntervalSince(start) < 5)
  }

  /// A raw connection to `path` that sends nothing until told to.
  func rawConnect(_ path: URL) throws -> FileHandle {
    let fd = try ControlSocket.connectClient(path, timeout: 10)
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  @Test(.timeLimit(.minutes(1)))
  func aClientThatNeverSendsItsRequestIsCutOffAtTheDeadline() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serveJSON(
      at: path, limits: .init(maxConnections: 4, ioDeadlineSeconds: 1),
      handler: { (_: ControlRequest) in ControlResponse(ok: true) },
      failure: { ControlResponse(ok: false, error: $0) })
    let stalled = try rawConnect(path)
    let start = Date()
    guard case .line(let line) = ControlSocket.readLine(stalled, limit: nil) else {
      Issue.record("no reply to a stalled request")
      return
    }
    #expect(try JSONDecoder().decode(ControlResponse.self, from: line).ok == false)
    #expect(Date().timeIntervalSince(start) < 5)
  }

  @Test(.timeLimit(.minutes(1)))
  func connectionsPastTheCapAreClosedUnreadUntilASlotFrees() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serveJSON(
      at: path, limits: .init(maxConnections: 2, ioDeadlineSeconds: 2),
      handler: { (_: ControlRequest) in ControlResponse(ok: true) },
      failure: { ControlResponse(ok: false, error: $0) })
    let held = [try rawConnect(path), try rawConnect(path)]
    // Let the accept loop claim both slots.
    Thread.sleep(forTimeInterval: 0.3)
    let refused = try rawConnect(path)
    #expect(ControlSocket.readLine(refused, limit: nil) == .closed)
    // The stalled holders time out, and their slots serve requests again.
    for handle in held { _ = ControlSocket.readLine(handle, limit: nil) }
    Thread.sleep(forTimeInterval: 0.3)
    #expect(try ControlSocket.call(path, .init(op: .ping), timeout: 5).ok)
  }

  /// Whether `handle` has a reply or an end of stream waiting.
  func hasInput(_ handle: FileHandle) -> Bool {
    var fds = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
    return poll(&fds, 1, 0) > 0
  }

  /// Each byte arrives well within the receive timeout, so only the
  /// whole-request deadline ends the connection.
  @Test(.timeLimit(.minutes(1)))
  func aClientThatTricklesItsRequestIsCutOffAtTheDeadline() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serveJSON(
      at: path, limits: .init(maxConnections: 4, ioDeadlineSeconds: 1),
      handler: { (_: ControlRequest) in ControlResponse(ok: true) },
      failure: { ControlResponse(ok: false, error: $0) })
    let trickling = try rawConnect(path)
    let start = Date()
    var cutOff = false
    while !cutOff, Date().timeIntervalSince(start) < 10 {
      _ = try? trickling.write(contentsOf: Data(" ".utf8))
      Thread.sleep(forTimeInterval: 0.2)
      cutOff = hasInput(trickling)
    }
    #expect(cutOff)
    #expect(Date().timeIntervalSince(start) < 4)
  }

  /// A client that sends its request and never reads the reply stalls the
  /// owner's write; the send timeout abandons it and frees the slot.
  @Test(.timeLimit(.minutes(1)))
  func aClientThatNeverReadsItsReplyReleasesItsSlot() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serveJSON(
      at: path, limits: .init(maxConnections: 1, ioDeadlineSeconds: 1),
      handler: { (request: ControlRequest) in
        // Far larger than the socket buffers.
        request.op == .exec
          ? ControlResponse(ok: true, stdout: Data(count: 16 << 20)) : ControlResponse(ok: true)
      },
      failure: { ControlResponse(ok: false, error: $0) })
    let stalled = try rawConnect(path)
    try stalled.write(contentsOf: Data("{\"op\":\"exec\"}\n".utf8))
    // Let the owner start the reply and stall on it.
    Thread.sleep(forTimeInterval: 0.5)
    let start = Date()
    var served = false
    while !served, Date().timeIntervalSince(start) < 10 {
      served = (try? ControlSocket.call(path, .init(op: .ping), timeout: 2).ok) ?? false
      if !served { Thread.sleep(forTimeInterval: 0.2) }
    }
    #expect(served)
    #expect(Date().timeIntervalSince(start) < 6)
    withExtendedLifetime(stalled) {}
  }

  @Test func connectionSlotsCountAndRelease() {
    let slots = ConnectionSlots(limit: 2)
    #expect(slots.enter() && slots.enter())
    #expect(!slots.enter())
    slots.leave()
    #expect(slots.inUse == 1)
    #expect(slots.enter())
  }

  @Test func malformedRequestGetsAnErrorReply() throws {
    let path = socketPath()
    defer { unlink(path.path) }
    try ControlSocket.serve(at: path) { _ in ControlResponse(ok: true) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      let b = Array(path.path.utf8)
      raw.copyBytes(from: b)
      raw[b.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(rc == 0)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: Data("not json\n".utf8))
    let reply = try handle.readToEnd() ?? Data()
    let decoded = try JSONDecoder().decode(ControlResponse.self, from: reply.prefix { $0 != 0x0A })
    #expect(decoded.ok == false)
  }
}

@Suite struct ReconcileTests {
  @Test func finishesDeletesAndRemovesUncommittedCreates() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "csb-\(UUID().uuidString)")
    let root = try SandboxRoot(dir.path)
    try root.createDirectories()
    let fm = FileManager.default
    try fm.createDirectory(
      at: root.sandboxes.appendingPathComponent(".deleting-a-1234"),
      withIntermediateDirectories: true)
    try fm.createDirectory(
      at: root.sandboxes.appendingPathComponent("half"), withIntermediateDirectories: true)
    try Data().write(to: root.bases.appendingPathComponent(".tmp-x.ext4"))
    let committed = root.sandbox(try SandboxID("kept"))
    try fm.createDirectory(at: committed.dir, withIntermediateDirectories: true)
    try committed.save(
      SandboxRecord(
        id: try SandboxID("kept"), owner: "o", imageReference: "i", imageDigest: "d", baseDisk: nil,
        environment: [],
        cpus: 1, memoryBytes: 1, diskBytes: 1, subnetIndex: 1, createdAt: Date()))

    let actions = try Sandboxes.reconcile(root: root)
    #expect(actions.contains { $0.action == "finished-delete" })
    #expect(!fm.fileExists(atPath: root.sandboxes.appendingPathComponent(".deleting-a-1234").path))
    #expect(actions.contains { $0.id == "half" && $0.action == "removed-uncommitted-create" })
    #expect(actions.contains { $0.id == "kept" && $0.status == "stopped" && $0.action == "none" })
    #expect(!fm.fileExists(atPath: root.sandboxes.appendingPathComponent("half").path))
    #expect(!fm.fileExists(atPath: root.bases.appendingPathComponent(".tmp-x.ext4").path))
    #expect(fm.fileExists(atPath: committed.record.path))
  }
}

@Suite struct LogTailTests {
  @Test func tailSplitsCRLFConsoleOutput() {
    let data = Data("a\r\nb\r\nc\r\n".utf8)
    #expect(String(decoding: Sandboxes.tailLines(data, 2), as: UTF8.self) == "b\r\nc\r\n")
  }

  @Test func tailOfShortOrEmptyInput() {
    #expect(Sandboxes.tailLines(Data(), 3).isEmpty)
    #expect(String(decoding: Sandboxes.tailLines(Data("only".utf8), 3), as: UTF8.self) == "only\n")
  }
}
