import Darwin
import Foundation
import IsoInferenceCore
import IsoInferenceGateway
import Synchronization
import Testing

/// Short deadlines, so timeout paths run in a test.
private func quick(_ adjust: (inout GatewayTiming) -> Void = { _ in }) -> GatewayTiming {
  var timing = GatewayTiming()
  timing.headerRead = .milliseconds(400)
  timing.bodyRead = .milliseconds(800)
  timing.close = .milliseconds(500)
  adjust(&timing)
  return timing
}

extension GatewayTests {
  // MARK: Connection lifetime

  /// Every connection's handler is freed once its socket closes and its
  /// work settles, whatever path it took.
  @Test func handlersAreFreedAfterEveryKindOfConnection() throws {
    let backend = try FakeBackend(.stream(chatEvents, pauseMilliseconds: 20))
    let harness = try Harness()
    let session = try harness.session([discoveryGrant(backend.port)])
    for _ in 0..<5 {
      _ = RawClient.request(
        socket: session.socket, target: "/v1/chat/completions", token: nil, body: chatBody)
      _ = RawClient.request(
        socket: session.socket, method: "GET", target: "/v1/models", token: session.token, body: "")
      close(RawClient.connect(session.socket))
    }
    for _ in 0..<3 {
      #expect(
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: session.token,
          body: chatBody
        ).status == 200)
      close(RawClient.open(session.socket, token: session.token))
    }
    #expect(eventually { backend.completed == backend.requests.count })
    #expect(eventually { harness.gateway.liveHandlers.load(ordering: .relaxed) == 0 })
  }

  /// Discovery and request-then-close return both connection slots.
  @Test func connectionSlotsReturnOnEveryPath() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([discoveryGrant(backend.port)])
    let own = try #require(harness.gatewaySession(session.id)).connections
    let shared = harness.gateway.sharedConnections
    for _ in 0..<20 {
      #expect(
        RawClient.request(
          socket: session.socket, method: "GET", target: "/v1/models", token: session.token,
          body: ""
        ).status == 200)
      close(RawClient.open(session.socket, token: session.token))
    }
    #expect(eventually { own.available == own.capacity && shared.available == shared.capacity })
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
    // Still usable: the session never ran out of slots.
    #expect(
      RawClient.request(
        socket: session.socket, target: "/v1/chat/completions", token: session.token,
        body: chatBody
      ).status == 200)
  }

  /// A client that stops reading cannot keep its socket, or its slots.
  @Test func aClientThatStopsReadingIsClosed() throws {
    let big = String(repeating: "x", count: 4_096)
    let events =
      (0..<2_000).map { _ in
        #"data: {"id":"c","model":"real/model","choices":[{"index":0,"delta":{"content":"\#(big)"}}]}"#
      } + chatEvents
    let backend = try FakeBackend(.stream(events))
    let harness = try Harness(timing: quick { $0.generation = .seconds(1) })
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let own = try #require(harness.gatewaySession(session.id)).connections
    let fd = RawClient.open(session.socket, token: session.token)
    defer { close(fd) }
    #expect(eventually { backend.requests.count == 1 })
    #expect(own.available == own.capacity - 1)
    // Never read: the generation deadline ends the response, and the close
    // deadline ends the socket although its buffers are full.
    #expect(eventually(10) { own.available == own.capacity })
  }

  // MARK: Budgets

  /// One session's requests cannot hold the buffers another session needs.
  @Test func oneSessionCannotTakeTheWholeBufferBudget() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness(timing: quick { $0.bodyRead = .seconds(5) })
    let greedy = try harness.session([grant(.openAIChat, port: backend.port)], name: "a")
    let other = try harness.session([grant(.openAIChat, port: backend.port)], name: "b")
    // Sixteen 4 MiB bodies would be the whole 64 MiB shared budget.
    let held = (0..<16).map { _ in
      RawClient.open(greedy.socket, token: greedy.token, body: "", contentLength: 4 << 20)
    }
    defer { for fd in held { close(fd) } }
    #expect(eventually { harness.gateway.buffers.free == (64 << 20) - (16 << 20) })
    #expect(
      RawClient.request(
        socket: other.socket, target: "/v1/chat/completions", token: other.token, body: chatBody
      ).status == 200)
    let statuses = held.map { RawClient.readAll($0).status }
    #expect(statuses.filter { $0 == 429 }.count == 12)
    #expect(eventually { harness.gateway.buffers.free == 64 << 20 })
  }

  /// A body that fails normalization still costs a rate token.
  @Test func failedNormalizationsCountTowardTheRateLimit() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let statuses = (0..<(SessionLimits.requestBurst + 1)).map { _ in
      RawClient.request(
        socket: session.socket, target: "/v1/chat/completions", token: session.token,
        body: #"{"model":"local-coder","messages":[],"surprise":1}"#
      ).status
    }
    #expect(statuses.dropLast().allSatisfy { $0 == 422 })
    #expect(statuses.last == 429)
    #expect(backend.requests.isEmpty)
  }

  // MARK: Audit

  @Test func rejectionsAreAggregatedPerWindow() throws {
    let clock = TestClock()
    let path = NSTemporaryDirectory() + "iso-audit-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    let audit = AuditLog(path: path) { clock.now }
    func lines() throws -> [JSONObject] {
      try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
        try #require(
          try JSONParser.parse(Array($0.utf8), limits: .init(maxBytes: 1 << 16, maxDepth: 4)).object
        )
      }
    }
    for _ in 0..<50 { audit.rejected(session: "s", code: .authInvalid) }
    audit.flush()
    // The first is written at once; the rest wait for the window's end.
    #expect(try lines().map { $0["count"]?.number?.int64 } == [1])
    clock.advance(.seconds(10))
    audit.flush()
    #expect(try lines().map { $0["count"]?.number?.int64 } == [1, 49])
    // Without a flush, the next rejection after the window carries the count.
    audit.rejected(session: "s", code: .authInvalid)
    audit.rejected(session: "s", code: .authInvalid)
    clock.advance(.seconds(10))
    audit.rejected(session: "s", code: .authInvalid)
    #expect(try lines().map { $0["count"]?.number?.int64 } == [1, 49, 1, 2])
  }

  @Test func eachRejectionIsAuditedOnce() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    for _ in 0..<3 {
      #expect(
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: nil, body: chatBody
        ).status == 401)
    }
    let counted = try harness.auditRecords().filter {
      $0["event"]?.string == "request_rejected" && $0["code"]?.string == "INFERENCE_AUTH_INVALID"
    }.compactMap { $0["count"]?.number?.int64 }
    #expect(counted.reduce(0, +) == 3)
  }

  // MARK: HTTP framing and limits

  @Test func discoveryListsOnlyTheSessionsAliases() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([discoveryGrant(backend.port)])
    let listed = RawClient.request(
      socket: session.socket, method: "GET", target: "/v1/models", token: session.token, body: "")
    #expect(listed.status == 200)
    let body = try JSONParser.parse(
      Array(listed.body.utf8), limits: .init(maxBytes: 1 << 16, maxDepth: 8))
    #expect(body["data"]?.array?.compactMap { $0["id"]?.string } == ["local-coder"])
    #expect(!listed.body.contains("real/model"))
    #expect(
      RawClient.request(
        socket: session.socket, method: "GET", target: "/v1/models", token: nil, body: ""
      ).status == 401)
    let plain = try harness.session([grant(.openAIChat, port: backend.port)], name: "plain")
    #expect(
      RawClient.request(
        socket: plain.socket, method: "GET", target: "/v1/models", token: plain.token, body: ""
      ).status == 403)
    #expect(backend.requests.isEmpty)
  }

  @Test func slowHeadersAndBodiesTimeOut() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness(timing: quick())
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let partialHead = RawClient.connect(session.socket)
    RawClient.sendAll(partialHead, Array("POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\n".utf8))
    #expect(RawClient.status(partialHead) == 408)
    let partialBody = RawClient.open(
      session.socket, token: session.token, body: "{", contentLength: 100)
    #expect(RawClient.status(partialBody) == 408)
    #expect(backend.requests.isEmpty)
  }

  @Test func oversizedHeadersAndOldVersionsAreRefused() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let oversized = RawClient.open(
      session.socket, token: session.token,
      extraHeaders: [("x-stainless-padding", String(repeating: "a", count: 40 << 10))])
    #expect(RawClient.status(oversized) == 431)
    let old = RawClient.connect(session.socket)
    RawClient.sendAll(old, Array("GET /v1/models HTTP/1.0\r\nhost: x\r\n\r\n".utf8))
    #expect(RawClient.status(old) == 505)
    #expect(backend.requests.isEmpty)
  }

  @Test func connectionCapsCloseExcessConnections() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness(sharedConnections: SessionLimits.connections + 2)
    let first = try harness.session([grant(.openAIChat, port: backend.port)], name: "a")
    let second = try harness.session([grant(.openAIChat, port: backend.port)], name: "b")
    let idle = (0..<SessionLimits.connections).map { _ in RawClient.connect(first.socket) }
    defer { for fd in idle { close(fd) } }
    let own = try #require(harness.gatewaySession(first.id)).connections
    #expect(eventually { own.available == 0 })
    // Over the session's 16: closed unread.
    #expect(RawClient.status(RawClient.open(first.socket, token: first.token)) == 0)
    // Two shared slots are left for the other session, then none.
    let others = (0..<2).map { _ in RawClient.connect(second.socket) }
    defer { for fd in others { close(fd) } }
    #expect(eventually { harness.gateway.sharedConnections.available == 0 })
    #expect(RawClient.status(RawClient.open(second.socket, token: second.token)) == 0)
    #expect(backend.requests.isEmpty)
  }

  /// A session socket holds its 16 accepted connections plus its listen
  /// backlog. A forward session's backlog keeps that within 32 (§22.9), so
  /// the guest cannot make the host `ssh` or the gateway hold more for one
  /// forward; the vmnet relay's keeps room for the 32 it relays (R2).
  @Test(arguments: [TransportKind.forward, .owner])
  func sessionSocketsBoundTheirAcceptedAndPendingConnections(_ kind: TransportKind) throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)], transport: kind)
    let idle = (0..<SessionLimits.connections).map { _ in RawClient.connect(session.socket) }
    defer { for fd in idle { close(fd) } }
    let own = try #require(harness.gatewaySession(session.id)).connections
    #expect(eventually { own.available == 0 })
    // Hold every event loop, so nothing more is accepted: what still
    // connects waits in the listen backlog, and the next dial is refused.
    let release = DispatchSemaphore(value: 0)
    var loops = 0
    for loop in harness.group.makeIterator() {
      loops += 1
      loop.execute { release.wait() }
    }
    var pending: [Int32] = []
    defer { for fd in pending { close(fd) } }
    while pending.count <= 64, let fd = RawClient.connectNow(session.socket) { pending.append(fd) }
    for _ in 0..<loops { release.signal() }
    let held = SessionLimits.connections + pending.count
    switch kind {
    case .forward:
      #expect(held == SessionLimits.forwardedConnections, "\(pending.count) pending")
      #expect(SessionListener.backlog(.forward) == 16)
    case .owner:
      #expect(pending.count == SessionLimits.relayedConnections, "\(pending.count) pending")
    }
    #expect(backend.requests.isEmpty)
  }

  @Test func repeatedAuthenticationFailuresCloseNewConnections() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    for _ in 0..<SessionLimits.authFailuresPerMinute {
      _ = RawClient.request(
        socket: session.socket, target: "/v1/chat/completions",
        token: String(repeating: "b", count: 64), body: chatBody)
    }
    // Even the right token is not read now.
    #expect(RawClient.status(RawClient.open(session.socket, token: session.token)) == 0)
    #expect(backend.requests.isEmpty)
  }

  @Test func continueIsSentOnlyAfterAuthentication() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let expect = [("expect", "100-continue")]
    let refused = RawClient.open(session.socket, token: nil, body: "", extraHeaders: expect)
    #expect(RawClient.readHead(refused).hasPrefix("HTTP/1.1 401"))
    close(refused)
    let accepted = RawClient.open(
      session.socket, token: session.token, body: "", contentLength: chatBody.utf8.count,
      extraHeaders: expect)
    defer { close(accepted) }
    #expect(RawClient.readHead(accepted).hasPrefix("HTTP/1.1 100"))
    RawClient.sendAll(accepted, Array(chatBody.utf8))
    #expect(RawClient.readAll(accepted).status == 200)
  }

  @Test func pipelinedRequestsCloseTheConnection() throws {
    let backend = try FakeBackend(.stream(chatEvents, pauseMilliseconds: 100))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let one =
      "POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\nauthorization: Bearer \(session.token)\r\ncontent-type: application/json\r\ncontent-length: \(chatBody.utf8.count)\r\n\r\n\(chatBody)"
    let fd = RawClient.connect(session.socket)
    RawClient.sendAll(fd, Array((one + one).utf8))
    let response = RawClient.readAll(fd)
    close(fd)
    #expect(!response.body.contains("data: [DONE]"))
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
    #expect(backend.requests.count <= 1)
  }

  // MARK: Completion evidence

  /// Stream-close evidence: a disconnect closes the upstream stream, and the
  /// slot is released only after the qualified drain interval.
  @Test func streamCloseReleasesAfterTheDrainInterval() throws {
    let backend = try FakeBackend(.streamThenHang([chatEvents[0]]))
    let harness = try Harness()
    let session = try harness.session(
      [grant(.openAIChat, port: backend.port, evidence: .streamClose)])
    let fd = RawClient.open(session.socket, token: session.token)
    #expect(eventually { backend.requests.count == 1 })
    usleep(100_000)
    close(fd)
    #expect(eventually { backend.closedWhileHanging == 1 })
    // The grant's profile drains for 100 ms; well inside it the slot is held.
    #expect(harness.backend(backend.port)?["active"]?.number?.int64 == 1)
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
    #expect(harness.backend(backend.port)?["quarantine"] == JSON.null)
  }

  /// A completed stream must report input usage, or the input bound cannot
  /// be checked: the backend is quarantined as a qualification failure.
  @Test func aCompletedStreamWithoutUsageQuarantines() throws {
    let backend = try FakeBackend(.stream(Array(chatEvents[0...1]) + ["data: [DONE]"]))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    #expect(
      RawClient.request(
        socket: session.socket, target: "/v1/chat/completions", token: session.token,
        body: chatBody
      ).status == 200)
    #expect(
      eventually {
        harness.backend(backend.port)?["quarantine"]?.string == "qualification-failure"
      })
  }

  // MARK: Control plane

  @Test func acceptFailuresDoNotEndTheControlPlane() throws {
    #expect(ControlServer.classify(EMFILE) == .backOff)
    #expect(ControlServer.classify(ENFILE) == .backOff)
    #expect(ControlServer.classify(ECONNABORTED) == .backOff)
    #expect(ControlServer.classify(EINTR) == .retry)
    #expect(ControlServer.classify(EBADF) == .fatal)
    let harness = try Harness()
    let failures = Mutex(3)
    let path = "/tmp/ic-" + String(UUID().uuidString.prefix(8)) + ".sock"
    let server = try ControlServer(path: path, gateway: harness.gateway) { listener in
      if failures.withLock({ count in
        defer { count -= 1 }
        return count > 0
      }) {
        return (-1, EMFILE)
      }
      let fd = Darwin.accept(listener, nil, nil)
      return (fd, fd < 0 ? errno : 0)
    }
    let thread = Thread { server.run() }
    thread.start()
    defer { server.stop() }
    let fd = RawClient.connect(path)
    defer { close(fd) }
    RawClient.sendAll(fd, ControlProtocol.frame(ControlProtocol.encode(.inspect(instance: nil))))
    var header = [UInt8](repeating: 0, count: 4)
    #expect(recv(fd, &header, 4, MSG_WAITALL) == 4)
    #expect(ControlProtocol.frameLength(header) != nil)
  }

  @Test func anotherInstancesSocketNameIsRefused() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let first = try harness.session([grant(.openAIChat, port: backend.port)], name: "a")
    let (_, owner) = try harness.spawnTransport()
    #expect(throws: InferenceError.self) {
      try harness.gateway.register(
        ControlProtocol.Registration(
          instance: .init(dataRoot: harness.directory, name: "b"),
          boot: BootIdentity(ownerPID: owner.pid, ownerStart: owner.start),
          nonce: String(repeating: "1", count: 32), limits: .defaults,
          grants: [grant(.openAIChat, port: backend.port)], socket: Harness.socketName("a"),
          transport: .owner))
    }
    // The first session's listener still answers.
    #expect(
      RawClient.request(
        socket: first.socket, target: "/v1/chat/completions", token: first.token, body: chatBody
      ).status == 200)
  }

  @Test func revocationRemovesOnlyItsOwnSocketFile() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let first = try harness.session([grant(.openAIChat, port: backend.port)], name: "a")
    #expect(FileManager.default.fileExists(atPath: first.socket))
    harness.gateway.revoke(.session(first.id))
    #expect(!FileManager.default.fileExists(atPath: first.socket))

    // A file that replaced the session's socket is left alone.
    let second = try harness.session([grant(.openAIChat, port: backend.port)], name: "b")
    try FileManager.default.removeItem(atPath: second.socket)
    try Data().write(to: URL(fileURLWithPath: second.socket))
    harness.gateway.revoke(.session(second.id))
    #expect(FileManager.default.fileExists(atPath: second.socket))
  }

  @Test func staleSessionSocketsAreRemovedAtStartup() throws {
    let harness = try Harness()
    let stale = harness.relayDirectory + "/" + Harness.socketName("old")
    let fd = RawClient.listen(stale)
    close(fd)
    let other = harness.relayDirectory + "/notes.txt"
    try Data().write(to: URL(fileURLWithPath: other))
    harness.gateway.removeStaleSessionSockets()
    #expect(!FileManager.default.fileExists(atPath: stale))
    #expect(FileManager.default.fileExists(atPath: other))
  }

  /// A registration refused on one grant adopts none of its backends.
  @Test func backendAdoptionIsAllOrNothing() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    _ = try harness.session([grant(.openAIChat, port: backend.port)], name: "a")
    let fresh = grant(.openAIChat, port: 18_999, alias: "fresh")
    let conflicting = grant(.openAIChat, port: backend.port, evidence: .streamClose)
    #expect(throws: InferenceError.self) {
      _ = try harness.session([fresh, conflicting], name: "b")
    }
    #expect(harness.backend(18_999) == nil)
  }
}

extension RawClient {
  /// A bound and listening Unix socket at `path`.
  static func listen(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      let bytes = Array(path.utf8)
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    Darwin.listen(fd, 1)
    return fd
  }
}
