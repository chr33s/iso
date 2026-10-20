import Foundation
import Testing

@testable import IsoCICore

/// The endpoint over a real Unix socket (NIO), the controller/child frame
/// channel over pipes, and fail-closed confinement admission.
@Suite struct DataPlaneProcessTests {
  static func shortSocketPath() -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let base = String(
      decoding: buffer.prefix(max(length - 1, 0)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return base + "dp-" + randomHex(bytes: 4) + ".sock"
  }

  /// A minimal HTTP/1.1 client over a Unix socket; returns (status, headers, body) per request.
  final class UnixHTTPClient {
    let fd: Int32
    var pending: [UInt8] = []

    init(path: String) throws {
      fd = socket(AF_UNIX, SOCK_STREAM, 0)
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
      }
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard result == 0 else { throw CIError(.hostUnreachable, "connect failed") }
      var timeout = timeval(tv_sec: 10, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(fd) }

    func send(
      _ method: String, _ target: String, headers: [String: String] = [:], body: [UInt8] = []
    ) {
      var text =
        "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n"
      for (name, value) in headers { text += "\(name): \(value)\r\n" }
      text += "\r\n"
      let bytes = Array(text.utf8) + body
      _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    func fill() -> Bool {
      var buffer = [UInt8](repeating: 0, count: 65_536)
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      guard count > 0 else { return false }
      pending += buffer[0..<count]
      return true
    }

    func receive() -> (Int, [String: String], [UInt8])? {
      while pending.firstRange(of: Array("\r\n\r\n".utf8)) == nil {
        guard fill() else { return nil }
      }
      let end = pending.firstRange(of: Array("\r\n\r\n".utf8))!
      let head = String(decoding: pending[..<end.lowerBound], as: UTF8.self)
      pending.removeSubrange(..<end.upperBound)
      let lines = head.components(separatedBy: "\r\n")
      let status = Int(lines[0].split(separator: " ")[1]) ?? 0
      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
          headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
      }
      let length = Int(headers["content-length"] ?? "0") ?? 0
      while pending.count < length { guard fill() else { return nil } }
      let body = Array(pending[..<length])
      pending.removeSubrange(..<length)
      return (status, headers, body)
    }
  }

  @Test func servesTheRunnerFlowOverAUnixSocketWithKeepAlive() async throws {
    let harness = try await DPHarness()
    let snapshot = try harness.store.importBytes(
      Array(repeating: 0x5A, count: 300_000), kind: .snapshot)
    let (allocation, _, runner) = try await harness.register(snapshot: snapshot)
    let path = Self.shortSocketPath()
    let server = try await DataPlaneHTTPServer.start(
      socketPath: path, service: harness.service, allocation: allocation)
    defer { unlink(path) }
    var status = stat()
    #expect(stat(path, &status) == 0 && status.st_mode & 0o077 == 0)
    let client = try UnixHTTPClient(path: path)
    // Unauthorized and malformed requests are refused without echoing input.
    client.send("POST", "/_apis/oauth2/token", body: Array("grant_type=nope".utf8))
    let refused = try #require(client.receive())
    #expect(refused.0 == 401)
    // Same connection (keep-alive): sign in and stream the granted snapshot.
    let assertion = DPHarness.assertion(
      key: runner.key, clientID: runner.clientID, audience: runner.audience,
      now: Int64(harness.clock.now()))
    let form =
      "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)"
    client.send(
      "POST", "/_apis/oauth2/token", headers: ["Content-Type": "application/x-www-form-urlencoded"],
      body: Array(form.utf8))
    let token = try #require(client.receive())
    #expect(token.0 == 200)
    client.send(
      "GET", "/_iso/snapshot/\(snapshot.rawValue)",
      headers: ["Authorization": "Bearer \(runner.config.isoToken)"])
    let download = try #require(client.receive())
    #expect(download.0 == 200)
    #expect(download.2.count == 300_000)
    #expect(Digest(hashing: download.2) == snapshot)
    // The exported clone is gone once served.
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(atPath: harness.childStaging + "/out")) ?? []
    #expect(leftovers.isEmpty)
    // An oversized JSON body is refused before it is buffered, and the
    // connection is closed.
    let raw = Array(
      "POST /run/renewjob HTTP/1.1\r\nHost: x\r\nContent-Length: 5000000\r\n\r\n".utf8)
    _ = raw.withUnsafeBytes { write(client.fd, $0.baseAddress, $0.count) }
    let tooLarge = client.receive()
    #expect(tooLarge?.0 == 413)
    await server.close()
  }

  @Test func childChannelCarriesValidatedCallsToTheBroker() async throws {
    let harness = try await DPHarness()
    let snapshot = try harness.store.importBytes(Array("snap".utf8), kind: .snapshot)
    let (allocation, _, _) = try await harness.register(snapshot: snapshot)
    var toController: [Int32] = [0, 0]
    var toChild: [Int32] = [0, 0]
    #expect(pipe(&toController) == 0 && pipe(&toChild) == 0)
    // Child side: writes requests to the controller, reads replies.
    let childChannel = DataPlaneChannel(input: toChild[0], output: toController[1])
    let pending = DataPlanePendingCalls()
    childChannel.startReading(
      onFrame: { frame in if case .reply(let id, let result) = frame { pending.resolve(id, result) }
      },
      onClose: { error in pending.close(error ?? CIError(.controllerUnavailable, "closed")) })
    // Controller side: answers requests through the broker.
    let controllerChannel = DataPlaneChannel(input: toController[0], output: toChild[1])
    let broker = harness.broker
    controllerChannel.startReading(
      onFrame: { frame in
        guard case .request(let id, let allocation, let call) = frame else { return }
        Task {
          let result: Result<JSONValue, CIError>
          do throws(CIError) { result = .success(try await broker.call(allocation, call)) } catch {
            result = .failure(error)
          }
          try? controllerChannel.send(.reply(id: id, result: result))
        }
      }, onClose: { _ in })
    let backend = ChannelBackend(channel: childChannel, pending: pending)
    let opened = try await backend.call(allocation, .openSnapshot(snapshot))
    #expect(opened["file"]?.stringValue.map(DataPlaneWire.isFileName) == true)
    if let name = opened["file"]?.stringValue {
      PrivateFiles.remove(harness.childStaging + "/out/" + name)
    }
    // Authorization still happens on the controller side.
    await #expect(throws: CIError.self) {
      try await backend.call(allocation, .openSnapshot(Digest(hashing: "someone else's")))
    }
    // A malformed frame from the peer closes the channel; pending calls fail.
    let garbage = Array("{\"v\":\"iso-ci.dataplane/v1\",\"type\":\"reply\",\"id\":\"x\"}\n".utf8)
    _ = garbage.withUnsafeBytes { write(toChild[1], $0.baseAddress, $0.count) }
    try await Task.sleep(for: .milliseconds(100))
    await #expect(throws: CIError.self) {
      try await backend.call(allocation, .openSnapshot(snapshot))
    }
    for fd in toController + toChild { close(fd) }
  }

  @Test func confinementSelfTestFailureRefusesAdmission() async throws {
    let harness = try await DPHarness()
    let paths = DataPlaneSupervisor.Paths(
      executable: "/usr/bin/false", socket: Self.shortSocketPath(), staging: harness.root + "/jail",
      probe: harness.root + "/probe")
    do {
      _ = try await DataPlaneSupervisor.launch(paths: paths, broker: harness.broker)
      Issue.record("an unconfined endpoint was admitted")
    } catch {
      #expect(error.code == .confinementUnavailable)
    }
    // Without a running endpoint, registration fails closed too.
    let fresh = DataPlaneBroker(
      store: harness.store, childStaging: harness.root + "/c2", scripts: DPScripts())
    let (plan, job) = DPHarness.plan()
    let registration = DataPlaneRegistration(
      allocation: .generate(), attempt: .generate(), run: .generate(), authority: .validation,
      plan: plan, job: job,
      contexts: .init(repository: "o/r", sha: "s", ref: "refs/heads/main", runID: 1), secrets: [:],
      snapshot: nil,
      actions: [], dependencyAttempts: [], cacheScope: DPHarness.scope(), limits: DPHarness.limits,
      guestPort: 1,
      expiresAt: harness.clock.now() + 60, runnerName: "r")
    await #expect(throws: CIError.self) { try await fresh.register(registration) }
  }

  @Test func sandboxArgumentsCarryTheProfileAndResolvedPaths() {
    let paths = DataPlaneSupervisor.Paths(
      executable: "/opt/iso-ci/iso-ci", socket: "/var/folders/x/T/iso-ci-1/dp.sock",
      staging: "/var/folders/x/T/s",
      probe: "/p")
    let arguments = DataPlaneSupervisor.sandboxArguments(paths, ["_dataplane"])
    #expect(arguments.first == "/usr/bin/sandbox-exec")
    #expect(arguments[1] == "-p")
    #expect(arguments[2] == DataPlaneSeatbelt.profile)
    #expect(arguments.contains("EXE=/opt/iso-ci/iso-ci"))
    #expect(arguments.last == "_dataplane")
    // The profile denies by default and grants no outbound network.
    #expect(DataPlaneSeatbelt.profile.contains("(deny default)"))
    #expect(!DataPlaneSeatbelt.profile.contains("network-outbound"))
    #expect(!DataPlaneSeatbelt.profile.contains("(allow default)"))
    // No links: the controller and guest forwards are never redirected.
    #expect(DataPlaneSeatbelt.profile.contains("(deny file-write-create (vnode-type SYMLINK))"))
    #expect(DataPlaneSeatbelt.profile.contains("(deny file-link)"))
    // Sockets are only bindable in the per-allocation socket directory.
    #expect(arguments.contains { $0.hasPrefix("SOCKETS=") && $0.hasSuffix("/iso-ci-1/dp") })
    #expect(paths.socketDirectory == "/var/folders/x/T/iso-ci-1/dp")
  }
}
