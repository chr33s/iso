import Foundation
import Testing

@testable import IsoCICore

/// The production path with the real executable: the supervisor runs the
/// confinement self-test, launches the confined child, and the child binds
/// one socket per allocation. Opt-in: set ISO_CI_E2E_BINARY to the built
/// iso-ci executable (`mise run check-ci` does).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ISO_CI_E2E_BINARY"] != nil))
struct DataPlaneConfinedTests {
  static var executable: String {
    let raw = ProcessInfo.processInfo.environment["ISO_CI_E2E_BINARY"] ?? ""
    return (try? FileManager.default.destinationOfSymbolicLink(atPath: raw)).map { _ in
      URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    } ?? raw
  }

  @Test func confinedChildServesOnlyRegisteredAllocations() async throws {
    let root = "/tmp/iso-ci-e2e-" + randomHex(bytes: 4)
    try PrivateFiles.ensureDirectory(root + "/rt")
    defer { PrivateFiles.removeTree(root) }
    try PrivateFiles.write(Array("private\n".utf8), to: root + "/probe")
    let store = try ObjectStore(
      database: try Database(path: ":memory:"), objects: root + "/objects",
      staging: root + "/staging")
    let broker = DataPlaneBroker(store: store, childStaging: root + "/child", scripts: DPScripts())
    let supervisor = try await DataPlaneSupervisor.launch(
      paths: .init(
        executable: Self.executable, socket: root + "/rt/dp.sock", staging: root + "/child",
        probe: root + "/probe"),
      broker: broker)
    defer { supervisor.shutdown() }
    #expect(supervisor.isRunning)

    let (plan, job) = DPHarness.plan()
    let allocation = AllocationID.generate()
    let config = try await broker.register(
      DataPlaneRegistration(
        allocation: allocation, attempt: .generate(), run: .generate(), authority: .validation,
        plan: plan, job: job,
        contexts: JobMessageBuilder.Contexts(
          repository: "octo/demo", sha: String(repeating: "a", count: 40), ref: "refs/heads/main",
          runID: 7),
        secrets: [:], snapshot: nil, actions: [], dependencyAttempts: [],
        cacheScope: DPHarness.scope(), limits: DPHarness.limits, guestPort: 41_000,
        expiresAt: EpochSeconds(Date().timeIntervalSince1970) + 900, runnerName: "iso-ci-e2e"))
    var status = stat()
    #expect(lstat(config.hostSocket, &status) == 0 && (status.st_mode & S_IFMT) == S_IFSOCK)

    // An unauthenticated request to the allocation's own socket is refused.
    let reply = try #require(
      Self.get(config.hostSocket, "/_iso/snapshot/" + String(repeating: "0", count: 64)))
    #expect(reply.hasPrefix("HTTP/1.1 401") || reply.hasPrefix("HTTP/1.1 403"))

    await broker.unregister(allocation)
    var deadline = 50
    while access(config.hostSocket, F_OK) == 0 && deadline > 0 {
      try await Task.sleep(for: .milliseconds(100))
      deadline -= 1
    }
    #expect(access(config.hostSocket, F_OK) != 0)
  }

  static func get(_ path: String, _ target: String) -> String? {
    guard let fd = connectUnix(path) else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard
      writeAll(
        fd,
        Array("GET \(target) HTTP/1.1\r\nHost: iso-ci.localhost\r\nConnection: close\r\n\r\n".utf8))
    else { return nil }
    var out: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count <= 0 { break }
      out += buffer[0..<count]
    }
    return String(decoding: out, as: UTF8.self)
  }
}
