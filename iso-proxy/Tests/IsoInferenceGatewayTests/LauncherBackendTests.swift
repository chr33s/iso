import Darwin
import Foundation
import IsoInferenceCore
import IsoInferenceGateway
import IsoProxyCore
import Testing

/// The managed launcher's front end (§20.3): each connection is challenged
/// before the credential or a prompt is sent on it, and each request names
/// its session's prompt-cache partition.
@Suite(.serialized) struct LauncherBackendTests {
  static let token = String(repeating: "ab", count: 32)

  static func launcherGrant(_ port: UInt16) -> ServiceGrant {
    grant(.openAIChat, port: port, credential: token, front: .launcher)
  }

  @Test func theConnectionProvesItselfBeforeTheRequestIsSent() throws {
    let backend = try FakeBackend(.stream(chatEvents), challenge: .answer(token: Self.token))
    let harness = try Harness()
    let session = try harness.session([Self.launcherGrant(backend.port)])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(response.status == 200)
    let challenge = try #require(backend.challengeRequests.first)
    let request = try #require(backend.requests.first)
    #expect(backend.challengeRequests.count == 1 && backend.requests.count == 1)
    #expect(challenge.connection == request.connection, "the proof covers the request's connection")
    #expect(!challenge.head.lowercased().contains("authorization"))
    #expect(!challenge.head.contains(Self.token))
    let head = request.head.lowercased()
    #expect(head.contains("authorization: bearer \(Self.token)"))
    #expect(head.contains("\(LauncherChallenge.partitionHeader): \(session.id)"))
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
    #expect(harness.backend(backend.port)?["front"]?.string == "launcher")
  }

  @Test(arguments: [
    FakeBackend.Challenge.wrong, .unauthorized, .close, .silent,
  ])
  func aListenerThatCannotAnswerNeverSeesTheTokenOrThePrompt(_ answer: FakeBackend.Challenge)
    throws
  {
    let backend = try FakeBackend(.stream(chatEvents), challenge: answer)
    var timing = GatewayTiming()
    timing.backendProof = .milliseconds(300)
    let harness = try Harness(timing: timing)
    let session = try harness.session([Self.launcherGrant(backend.port)])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(response.status == 503)
    #expect(response.body.contains("did not prove"))
    #expect(backend.challengeRequests.count == 1)
    #expect(backend.requests.isEmpty)
    let received = String(decoding: backend.receivedBytes, as: UTF8.self)
    #expect(!received.contains(Self.token), "the token never reaches an unproven listener")
    #expect(!received.contains("hello") && !received.lowercased().contains("authorization"))
    // Nothing was sent, so nothing is outstanding and nothing is quarantined.
    #expect(eventually { harness.backend(backend.port)?["active"]?.number?.int64 == 0 })
    #expect(harness.backend(backend.port)?["quarantine"] == JSON.null)
  }

  @Test func aPlainBackendIsNeitherChallengedNorPartitioned() throws {
    let backend = try FakeBackend(.stream(chatEvents), challenge: .wrong)
    let harness = try Harness()
    let session = try harness.session([
      grant(.openAIChat, port: backend.port, credential: Self.token)
    ])
    let response = RawClient.request(
      socket: session.socket, target: "/v1/chat/completions", token: session.token, body: chatBody)
    #expect(response.status == 200)
    #expect(backend.challengeRequests.isEmpty)
    let head = try #require(backend.requests.first).head.lowercased()
    #expect(!head.contains(LauncherChallenge.partitionHeader))
  }

  @Test func eachSessionNamesItsOwnPartition() throws {
    let backend = try FakeBackend(.stream(chatEvents), challenge: .answer(token: Self.token))
    let harness = try Harness()
    let first = try harness.session([Self.launcherGrant(backend.port)])
    let second = try harness.session([Self.launcherGrant(backend.port)], name: "other")
    for session in [first, second] {
      let response = RawClient.request(
        socket: session.socket, target: "/v1/chat/completions", token: session.token,
        body: chatBody)
      #expect(response.status == 200)
    }
    let partitions = backend.requests.map { request in
      request.head.split(separator: "\r\n").first {
        $0.lowercased().hasPrefix(LauncherChallenge.partitionHeader + ":")
      }.map { String($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
    }
    #expect(partitions == [first.id, second.id])
  }

  @Test func theAnswerMustMatchExactly() {
    let nonce = String(repeating: "5a", count: 32)
    let challenge = LauncherChallenge(token: Secret(Self.token), nonce: nonce)
    let right = LauncherChallenge.answer(token: Self.token, nonce: nonce)
    #expect(challenge.path == "/iso/challenge/" + nonce)
    #expect(challenge.accepts(Array(right.utf8)))
    #expect(!challenge.accepts(Array((right + "\n").utf8)))
    #expect(!challenge.accepts(Array(right.uppercased().utf8)))
    #expect(!challenge.accepts(Array(LauncherChallenge.answer(token: "x", nonce: nonce).utf8)))
    #expect(!challenge.accepts([]))
  }

  @Test func aLauncherGrantNeedsItsCredential() throws {
    let registration = ControlProtocol.Registration(
      instance: .init(dataRoot: "/tmp/x", name: "dev"),
      boot: BootIdentity(ownerPID: 1, ownerStart: ProcessStart(seconds: 1, microseconds: 0)),
      nonce: String(repeating: "0", count: 32),
      limits: .defaults, grants: [grant(.openAIChat, port: 9, front: .launcher)],
      socket: "ab.sock", transport: .owner)
    let frame = ControlProtocol.encode(.register(registration))
    #expect(throws: InferenceError.self) { try ControlProtocol.decodeRequest(frame) }
  }
}
