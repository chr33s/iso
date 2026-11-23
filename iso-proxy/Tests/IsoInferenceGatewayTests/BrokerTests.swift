import Darwin
import Foundation
import IsoInferenceCore
import IsoInferenceGateway
import IsoProxyCore
import NIOPosix
import Synchronization
import Testing

/// A broker with its worker socket, and workers in this process: the
/// links are real Unix sockets, framed and decoded as between processes.
final class BrokerHarness: @unchecked Sendable {
  let directory: String
  let relayDirectory: String
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let gateway: Gateway
  let server: WorkerServer
  var workerSocket: String { directory + "/workers.sock" }

  init() throws {
    signal(SIGPIPE, SIG_IGN)
    // Short, so socket paths fit sun_path.
    directory = "/tmp/ib-" + String(UUID().uuidString.prefix(8))
    relayDirectory = "/tmp/ir-" + String(UUID().uuidString.prefix(8))
    for path in [directory, relayDirectory] {
      try FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    gateway = Gateway(
      group: group, journal: try Journal(directory: directory + "/journal"),
      audit: AuditLog(path: directory + "/audit.log"), relayDirectory: relayDirectory,
      workers: WorkerRegistry(attachTimeout: .seconds(5)), onExit: {})
    server = try WorkerServer(path: directory + "/workers.sock", gateway: gateway)
    let server = server
    Thread { server.run() }.start()
  }

  deinit {
    try? gateway.prepareShutdown(force: true)
    server.stop()
    gateway.stop()
    try? group.syncShutdownGracefully()
    try? FileManager.default.removeItem(atPath: directory)
    try? FileManager.default.removeItem(atPath: relayDirectory)
  }

  func register(_ grants: [ServiceGrant], name: String = "dev") throws -> Gateway.Registered {
    try gateway.register(
      ControlProtocol.Registration(
        instance: .init(dataRoot: directory, name: name),
        boot: BootIdentity(ownerPID: getpid(), ownerStart: try TestProcess.start(getpid())),
        nonce: String(repeating: "0", count: 32), limits: .defaults, grants: grants,
        socket: Harness.socketName(name), transport: .owner))
  }

  /// A worker for `registered`, serving on its own thread until its link ends.
  func worker(_ registered: Gateway.Registered) throws -> (SessionWorker, Flag) {
    let worker = try SessionWorker.start(
      broker: workerSocket, socketPath: relayDirectory + "/" + registered.socket,
      sessionID: registered.sessionID, key: try #require(registered.workerKey).expose(),
      group: group)
    let ended = Flag()
    Thread {
      worker.run()
      ended.set()
    }.start()
    return (worker, ended)
  }

  /// Activated bound to this test process, whose requests the worker serves.
  func activate(_ registered: Gateway.Registered) throws {
    try gateway.activate(
      ControlProtocol.Activation(
        sessionID: registered.sessionID, epoch: gateway.epoch,
        transport: try TestProcess.binding(getpid()), deadlineSeconds: nil))
  }

  func socket(_ registered: Gateway.Registered) -> String {
    relayDirectory + "/" + registered.socket
  }

  func session(_ id: String) -> JSONObject? {
    gateway.inspect(nil)["sessions"]?.array?.compactMap(\.object).first {
      $0["session_id"]?.string == id
    }
  }

  func backend(_ port: UInt16) -> JSONObject? {
    gateway.inspect(nil)["backends"]?.array?.compactMap(\.object).first {
      $0["backend"]?.string == "127.0.0.1:\(port)"
    }
  }
}

/// A worker link spoken by hand: what a compromised worker can send.
final class RawWorker {
  let fd: Int32

  init(_ socket: String) throws {
    fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      let bytes = Array(socket.utf8)
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(connected == 0)
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  }

  deinit { close(fd) }

  func send(_ message: WorkerProtocol.Up) { sendRaw(WorkerProtocol.encode(message)) }

  func sendRaw(_ object: JSONObject) {
    let frame = ControlProtocol.frame(object)
    _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
  }

  /// The next broker message, or nil when the link closed.
  func next() -> WorkerProtocol.Down? {
    var header = [UInt8](repeating: 0, count: 4)
    guard recv(fd, &header, 4, MSG_WAITALL) == 4,
      let length = ControlProtocol.frameLength(header)
    else { return nil }
    var body = [UInt8](repeating: 0, count: length)
    guard length == 0 || recv(fd, &body, length, MSG_WAITALL) == length else { return nil }
    return try? WorkerProtocol.decodeDown(ControlProtocol.parseFrame(body))
  }

  /// Messages until one that `match` accepts (events may come first).
  func until(_ match: (WorkerProtocol.Down) -> Bool) -> WorkerProtocol.Down? {
    while let message = next() {
      if match(message) { return message }
    }
    return nil
  }

  /// hello, the configuration, ready.
  func attach(_ registered: Gateway.Registered) -> Bool {
    send(.hello(session: registered.sessionID, key: registered.workerKey?.expose() ?? ""))
    guard case .config? = next() else { return false }
    send(.ready)
    return true
  }

  /// A permit and admission for `backend`; the ticket.
  func admit(_ backend: UInt16) -> UInt64? {
    send(.permit(id: 1))
    guard
      case .permitted(_, let permit)? = until({ if case .permitted = $0 { true } else { false } })
    else { return nil }
    send(.admit(id: 2, permit: permit, backend: BackendID(port: backend), outputTokens: 16))
    guard
      case .admitted(_, let ticket, _)? = until({ if case .admitted = $0 { true } else { false } })
    else { return nil }
    return ticket
  }
}

@Suite(.serialized) struct BrokerTests {
  /// The broker binds no session socket; the session's worker serves it,
  /// and the broker reports it ready by PID. Revocation ends the worker.
  @Test func aWorkerServesItsSessionForTheBroker() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try BrokerHarness()
    let registered = try harness.register([grant(.openAIChat, port: backend.port)])
    #expect(registered.workerKey?.expose().count == 64)
    #expect(!FileManager.default.fileExists(atPath: harness.socket(registered)))
    let (_, ended) = try harness.worker(registered)
    try harness.activate(registered)
    let response = RawClient.request(
      socket: harness.socket(registered), target: "/v1/chat/completions",
      token: registered.capability.expose(), body: chatBody)
    #expect(response.status == 200)
    #expect(backend.requests.count == 1)
    let listed = try #require(harness.session(registered.sessionID))
    #expect(listed["worker"]?.string == "ready")
    #expect(listed["worker_pid"]?.number?.int64 == Int64(getpid()))
    #expect(listed["state"]?.string == "active")
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
    harness.gateway.revoke(.session(registered.sessionID))
    #expect(eventually { ended.isSet })
    #expect(!FileManager.default.fileExists(atPath: harness.socket(registered)))
  }

  /// Two workers share the broker's scheduler: a backend that takes one
  /// generation at a time never runs two, whichever sessions ask.
  @Test func workersShareTheBrokersBackendLimit() throws {
    let backend = try FakeBackend(.stream(chatEvents, pauseMilliseconds: 150))
    let harness = try BrokerHarness()
    var sessions: [Gateway.Registered] = []
    for name in ["a", "b"] {
      let registered = try harness.register([grant(.openAIChat, port: backend.port)], name: name)
      _ = try harness.worker(registered)
      try harness.activate(registered)
      sessions.append(registered)
    }
    let statuses = Mutex<[Int]>([])
    let threads = sessions.map { registered in
      Thread {
        let status = RawClient.request(
          socket: harness.socket(registered), target: "/v1/chat/completions",
          token: registered.capability.expose(), body: chatBody
        ).status
        statuses.withLock { $0.append(status) }
      }
    }
    for thread in threads { thread.start() }
    #expect(eventually(30) { statuses.withLock { $0.count } == 2 })
    #expect(statuses.withLock { $0 } == [200, 200])
    #expect(backend.peakConcurrency == 1)
  }

  /// A worker settles only tickets the broker issued to it: another
  /// session's worker cannot release them.
  @Test func aWorkerSettlesOnlyItsOwnTickets() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try BrokerHarness()
    let first = try harness.register([grant(.openAIChat, port: backend.port)], name: "a")
    let second = try harness.register([grant(.openAIChat, port: backend.port)], name: "b")
    let a = try RawWorker(harness.workerSocket)
    let b = try RawWorker(harness.workerSocket)
    #expect(a.attach(first) && b.attach(second))
    let ticket = try #require(a.admit(backend.port))
    // The backend takes one at a time: A's second request queues.
    let queued = try #require(a.admit(backend.port))
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 1 })
    #expect(harness.backend(backend.port)?["queued"]?.number?.int64 == 1)
    b.send(.finish(ticket: ticket, outputTokens: 0))
    b.send(.withdraw(id: 9, ticket: queued))
    guard case .withdrawn(_, let withdrawn)? = b.next() else {
      Issue.record("no answer")
      return
    }
    #expect(!withdrawn)
    #expect(harness.backend(backend.port)?["active"]?.number?.int64 == 1)
    #expect(harness.backend(backend.port)?["queued"]?.number?.int64 == 1)
    a.send(.finish(ticket: ticket, outputTokens: 0))
    #expect(eventually { harness.backend(backend.port)?["queued"]?.number?.int64 == 0 })
  }

  /// A worker is admitted only to the backends its own session's grants
  /// name, whatever other sessions registered.
  @Test func aWorkerIsAdmittedOnlyToItsGrantsBackends() throws {
    let mine = try FakeBackend(.stream(chatEvents))
    let theirs = try FakeBackend(.stream(chatEvents))
    let harness = try BrokerHarness()
    _ = try harness.register([grant(.openAIChat, port: theirs.port)], name: "other")
    let registered = try harness.register([grant(.openAIChat, port: mine.port)])
    let worker = try RawWorker(harness.workerSocket)
    #expect(worker.attach(registered))
    worker.send(.permit(id: 1))
    guard case .permitted(_, let permit)? = worker.next() else {
      Issue.record("no permit")
      return
    }
    worker.send(
      .admit(id: 2, permit: permit, backend: BackendID(port: theirs.port), outputTokens: 1))
    guard case .refused(_, let error)? = worker.next() else {
      Issue.record("admitted to another session's backend")
      return
    }
    #expect(error.code == .policyDenied)
  }

  /// A worker that goes away while holding work leaves no evidence that the
  /// backend stopped: the backend is quarantined and the session ends.
  @Test func aWorkerThatExitsWithWorkQuarantinesTheBackend() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try BrokerHarness()
    let registered = try harness.register([grant(.openAIChat, port: backend.port)])
    var worker: RawWorker? = try RawWorker(harness.workerSocket)
    #expect(worker?.attach(registered) == true)
    _ = try #require(worker?.admit(backend.port))
    worker = nil
    #expect(
      eventually {
        harness.backend(backend.port)?["quarantine"]?.string == "uncertain-cancellation"
      })
    #expect(eventually { harness.session(registered.sessionID) == nil })
  }

  /// Only the expected worker attaches: the key must match, once.
  @Test func theBrokerAttachesOnlyTheKeyedWorkerOnce() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try BrokerHarness()
    let registered = try harness.register([grant(.openAIChat, port: backend.port)])
    let wrong = try RawWorker(harness.workerSocket)
    wrong.send(.hello(session: registered.sessionID, key: String(repeating: "0", count: 64)))
    #expect(wrong.next() == nil, "a wrong key gets no configuration")
    let right = try RawWorker(harness.workerSocket)
    #expect(right.attach(registered))
    let again = try RawWorker(harness.workerSocket)
    again.send(
      .hello(session: registered.sessionID, key: try #require(registered.workerKey).expose()))
    #expect(again.next() == nil, "the key works once")
  }

  /// A worker's audit records carry only identifiers: free text, unknown
  /// events or members, or a backend outside its grants end the link and
  /// with it the session.
  @Test func aWorkerThatBreaksTheProtocolLosesItsSession() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try BrokerHarness()
    let messages: [JSONObject] = [
      WorkerProtocol.encode(
        .audit(event: "request_completed", fields: JSONObject(["alias": .string("hi there")]))),
      WorkerProtocol.encode(.audit(event: "session_registered", fields: JSONObject())),
      WorkerProtocol.encode(
        .audit(event: "limit_clamped", fields: JSONObject(["prompt": .string("x")]))),
      WorkerProtocol.encode(.qualificationFailure(backend: BackendID(port: 1))),
    ]
    for (index, message) in messages.enumerated() {
      let registered = try harness.register(
        [grant(.openAIChat, port: backend.port)], name: "s\(index)")
      let worker = try RawWorker(harness.workerSocket)
      #expect(worker.attach(registered))
      worker.sendRaw(message)
      #expect(worker.next() == nil, "case \(index)")
      #expect(eventually { harness.session(registered.sessionID) == nil }, "case \(index)")
    }
  }

  /// The worker binds the session to its transport; the broker records the
  /// activation only once the worker answers.
  @Test func activationWaitsForTheWorker() throws {
    let harness = try BrokerHarness()
    let registered = try harness.register([grant(.openAIChat, port: 9)])
    let started = ContinuousClock.now
    #expect(throws: InferenceError.self) { try harness.activate(registered) }
    #expect(ContinuousClock.now - started >= .seconds(4), "it waited for a worker")
    #expect(harness.session(registered.sessionID)?["state"]?.string == "inactive")
  }
}

final class Flag: Sendable {
  private let value = Mutex(false)
  func set() { value.withLock { $0 = true } }
  var isSet: Bool { value.withLock { $0 } }
}
