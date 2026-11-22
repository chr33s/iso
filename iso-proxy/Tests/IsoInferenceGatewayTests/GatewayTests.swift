import Darwin
import Foundation
import IsoInferenceCore
import IsoInferenceGateway
import Testing

@Suite(.serialized) struct GatewayTests {
  @Test func streamedChatIsRebuiltUpstreamAndRelayedWithAlias() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody,
      extraHeaders: [("x-stainless-lang", "js"), ("cookie", "a=b")])
    #expect(response.status == 200)
    #expect(response.head.lowercased().contains("text/event-stream"))
    #expect(response.body.contains(#""model":"local-coder""#))
    #expect(!response.body.contains("real/model"))
    #expect(response.body.hasSuffix("data: [DONE]\n\n"))
    let upstream = try #require(backend.requests.first)
    let head = upstream.head.lowercased()
    #expect(head.hasPrefix("post /v1/chat/completions http/1.1"))
    #expect(!head.contains("authorization"), "guest capability never reaches the backend")
    #expect(!head.contains("cookie") && !head.contains("x-stainless"))
    let body = try #require(upstream.json)
    #expect(body["model"]?.string == "real/model")
    #expect(body["max_tokens"]?.number?.int64 == 256)
    #expect(body["stream_options"]?["include_usage"]?.bool == true)
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
  }

  @Test func nonStreamingClientGetsAnAggregatedResponse() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token,
      body: #"{"model":"local-coder","messages":[{"role":"user","content":"hello"}]}"#)
    #expect(response.status == 200)
    let body = try JSONParser.parse(
      Array(response.body.utf8), limits: .init(maxBytes: 1 << 20, maxDepth: 16))
    #expect(body["object"]?.string == "chat.completion")
    #expect(body["choices"]?.array?.first?["message"]?["content"]?.string == "hi")
    // The backend was still asked to stream (§8.1 step 8).
    #expect(backend.requests.first?.json?["stream"]?.bool == true)
  }

  @Test func deniedRequestsNeverReachTheBackend() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let other = try harness.session([grant(.openAIChat, port: backend.port)], name: "other")
    let cases: [(RawResponse, Int)] = [
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: nil, body: chatBody), 401
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions",
          token: String(repeating: "a", count: 64), body: chatBody), 401
      ),
      // Session B's token on session A's listener.
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: other.token, body: chatBody
        ),
        401
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/models/pull", token: session.token, body: "{}"), 403
      ),
      (
        RawClient.request(
          socket: session.socket, target: "http://127.0.0.1:1/v1/chat/completions",
          token: session.token, body: chatBody), 403
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions?x=1", token: session.token,
          body: chatBody), 403
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/responses", token: session.token, body: chatBody),
        403
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: session.token,
          body: chatBody, extraHeaders: [("origin", "https://evil.example")]), 403
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: session.token,
          body: chatBody,
          extraHeaders: [("transfer-encoding", "chunked")], contentLength: false), 411
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: session.token,
          body: #"{"model":"local-coder","messages":[],"draft_model":"x"}"#), 403
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: session.token,
          body: #"{"model":"other-model","messages":[]}"#), 403
      ),
      (
        RawClient.request(
          socket: session.socket, target: "/v1/chat/completions", token: session.token,
          body: #"{"model":"local-coder","model":"x","messages":[]}"#), 400
      ),
    ]
    for (index, (response, status)) in cases.enumerated() {
      #expect(response.status == status, "case \(index)")
    }
    #expect(backend.requests.isEmpty)
  }

  @Test func inactiveAndRevokedSessionsAreRejected() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let inactive = try harness.session([grant(.openAIChat, port: backend.port)], activate: false)
    #expect(
      RawClient.request(
        socket: inactive.socket, target: "/v1/chat/completions", token: inactive.token,
        body: chatBody
      ).status == 401)
    let session = try harness.session([grant(.openAIChat, port: backend.port)], name: "b")
    harness.gateway.revoke(.session(session.id))
    // The listener is closed: nothing answers, and the backend saw nothing.
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(response.status == 0 || response.status == 401)
    #expect(backend.requests.isEmpty)
  }

  @Test func transportExitRevokesTheSession() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    session.transport.terminate()
    #expect(
      eventually {
        harness.gateway.inspect(nil)["sessions"]?.array?.isEmpty == true
      })
  }

  @Test func activationChecksTheTransportIdentity() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    let registered = try harness.gateway.register(
      ControlProtocol.Registration(
        instance: .init(dataRoot: harness.directory, name: "x"),
        boot: BootIdentity(ownerPID: 1, ownerStart: ProcessStart(seconds: 1, microseconds: 0)),
        nonce: String(repeating: "0", count: 32), limits: .defaults,
        grants: [grant(.openAIChat, port: backend.port)], socket: Harness.socketName("x")))
    let (_, binding) = try harness.spawnTransport()
    let wrongStart = TransportBinding(
      pid: binding.pid, start: ProcessStart(seconds: binding.start.seconds + 1, microseconds: 0))
    #expect(throws: InferenceError.self) {
      try harness.gateway.activate(
        .init(
          sessionID: registered.sessionID, epoch: harness.gateway.epoch, transport: wrongStart,
          deadlineSeconds: nil))
    }
    #expect(throws: InferenceError.self) {
      try harness.gateway.activate(
        .init(
          sessionID: registered.sessionID, epoch: "stale-epoch", transport: binding,
          deadlineSeconds: nil))
    }
  }

  @Test func sessionDeadlineRevokes() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness()
    harness.gateway.startTicker(interval: .milliseconds(100))
    let session = try harness.session(
      [grant(.openAIChat, port: backend.port)], deadlineSeconds: 1)
    #expect(
      RawClient.request(
        socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody
      ).status == 200)
    #expect(eventually(5) { harness.gateway.inspect(nil)["sessions"]?.array?.isEmpty == true })
  }

  @Test func clientDisconnectDrainsBeforeReleasingTheSlot() throws {
    let backend = try FakeBackend(.stream(chatEvents, pauseMilliseconds: 500))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let fd = RawClient.connect(session.socket)
    RawClient.sendAll(
      fd,
      Array(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\nauthorization: Bearer \(session.token)\r\ncontent-type: application/json\r\ncontent-length: \(chatBody.utf8.count)\r\n\r\n\(chatBody)"
          .utf8))
    #expect(eventually { backend.requests.count == 1 })
    close(fd)
    // Well after the disconnect is processed, and before the backend has
    // finished, the slot is still held: a disconnect is not evidence.
    usleep(400_000)
    #expect(backend.completed == 0)
    #expect(harness.backend(backend.port)?["active"]?.number?.int64 == 1)
    #expect(eventually { backend.completed == 1 })
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
    #expect(harness.backend(backend.port)?["quarantine"] == JSON.null)
  }

  @Test func noEvidenceBackendIsQuarantinedOnCancellation() throws {
    let backend = try FakeBackend(.streamThenHang([chatEvents[0]]))
    let harness = try Harness()
    let session = try harness.session(
      [grant(.openAIChat, port: backend.port, evidence: CompletionEvidence.none)])
    let fd = RawClient.connect(session.socket)
    RawClient.sendAll(
      fd,
      Array(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\nauthorization: Bearer \(session.token)\r\ncontent-type: application/json\r\ncontent-length: \(chatBody.utf8.count)\r\n\r\n\(chatBody)"
          .utf8))
    #expect(eventually { backend.requests.count == 1 })
    close(fd)
    #expect(
      eventually {
        harness.backend(backend.port)?["quarantine"]?.string == "uncertain-cancellation"
      })
    let refused = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(refused.status == 503)
    #expect(backend.requests.count == 1)
    // Host requalification clears it; the abandoned slot is released.
    try harness.gateway.requalify(BackendID(port: backend.port))
    #expect(harness.backend(backend.port)?["active"]?.number?.int64 == 0)
  }

  @Test func journalRecordsOutstandingWorkAcrossRestarts() throws {
    let directory = NSTemporaryDirectory() + "iso-journal-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let backend = BackendID(port: 18080)
    let journal = try Journal(directory: directory)
    try journal.dispatched(backend)
    try journal.dispatched(backend)
    journal.settled(backend)
    // Still outstanding: a restart now would quarantine the backend.
    #expect(try Journal(directory: directory).unresolved() == [backend])
    journal.settled(backend)
    #expect(try Journal(directory: directory).unresolved().isEmpty)
  }

  @Test func crashJournalQuarantinesAtStartup() throws {
    let backend = try FakeBackend(.stream(chatEvents))
    let harness = try Harness(journalSeed: [backend.port: 1])
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(response.status == 503)
    #expect(response.body.contains("INFERENCE_BACKEND_QUARANTINED"))
    #expect(backend.requests.isEmpty)
    try harness.gateway.requalify(BackendID(port: backend.port))
    #expect(
      RawClient.request(
        socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody
      ).status == 200)
  }

  @Test func secondRequestQueuesBehindTheBackendLimit() throws {
    let backend = try FakeBackend(.stream(chatEvents, pauseMilliseconds: 200))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let results = Results()
    let threads = (0..<2).map { _ in
      Thread {
        results.add(
          RawClient.request(
            socket: session.socket, target: "/v1/chat/completions", token: session.token,
            body: chatBody
          ).status)
      }
    }
    for thread in threads { thread.start() }
    #expect(eventually { harness.backend(backend.port)?["queued"]?.number?.int64 == 1 })
    #expect(eventually(15) { results.all.count == 2 })
    #expect(results.all == [200, 200])
    #expect(backend.requests.count == 2)
  }

  @Test func backendErrorsAreSanitized() throws {
    let backend = try FakeBackend(
      .json(status: 400, body: #"{"error":"prompt is: SECRET-PROMPT-TEXT"}"#))
    let harness = try Harness()
    let session = try harness.session([grant(.openAIChat, port: backend.port)])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(response.status == 422)
    #expect(!response.body.contains("SECRET-PROMPT-TEXT"))
    let audit = try String(contentsOfFile: harness.directory + "/audit.log", encoding: .utf8)
    #expect(!audit.contains("SECRET-PROMPT-TEXT") && !audit.contains(session.token))
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
  }

  @Test func registrationsOutsideTheLaunchPortsAreRefused() throws {
    let harness = try Harness(backendPorts: [18080])
    #expect(throws: InferenceError.self) {
      _ = try harness.session([grant(.openAIChat, port: 18081)], name: "outside")
    }
    #expect(
      harness.gateway.inspect(nil)["gateway"]?["gateway_egress_ports"] == .array([.int(18080)]))
  }

  @Test func unreachableBackendFailsWithoutQuarantine() throws {
    let harness = try Harness()
    let session = try harness.session(
      [grant(.openAIChat, port: 1, evidence: CompletionEvidence.none)])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(response.status == 503)
    #expect(harness.backend(1)?["quarantine"] == JSON.null)
  }
}

final class Results: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int] = []
  func add(_ value: Int) { lock.withLock { values.append(value) } }
  var all: [Int] { lock.withLock { values } }
}
