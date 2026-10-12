import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

extension SupervisorFixture {
  func openRequest(
    _ instance: QualifiedInstance, _ observation: VMObservation, session: SessionID = .generate(),
    bearer: AccessBearer = .generate(), key: String = "11", epoch: DaemonEpoch? = nil
  ) throws -> AccessOpenRequest {
    AccessOpenRequest(
      instance: instance, expectedEpoch: epoch ?? supervisor.epoch,
      expectedBoot: try #require(observation.bootID), expectedGeneration: observation.generation,
      policyHash: try #require(observation.policyHash), session: session,
      client: try ClientLabel("laptop"),
      clientKey: try ClientPublicKey(testPublicKey(key == "11" ? 1 : 2)),
      purpose: .ssh, bearer: bearer)
  }

  func open(_ request: AccessOpenRequest) -> Result<JSONValue, HostControlError> {
    call(.accessOpen(request))
  }
}

@Suite struct HostControlAccessTests {
  @Test func openIsIdempotentForTheSameBearerOnly() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let request = try f.openRequest(instance, observation)
    let first = try AccessGrant(wire: f.open(request).get())
    // Lost reply: same session and bearer get the same live metadata back.
    let again = try AccessGrant(wire: f.open(request).get())
    #expect(again.session == first.session)
    #expect(again.issuedAt == first.issuedAt)
    let other = try f.openRequest(instance, observation, session: request.session)
    #expect(failure(f.open(other)) == .sessionIdentityChanged)
  }

  @Test func epochAndBootAreBound() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let stale = try f.openRequest(instance, observation, epoch: .generate())
    #expect(failure(f.open(stale)) == .sessionExpired)
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    // Restart: a new epoch rejects the old session and its delayed open (A11/A27).
    let restarted = try f.restarted()
    #expect(failure(restarted.call(.accessOpen(request))) == .sessionExpired)
    #expect(
      failure(
        restarted.call(
          .accessRenew(
            session: request.session, bearer: request.bearer, epoch: f.supervisor.epoch,
            boot: request.expectedBoot, policy: request.policyHash))) == .sessionExpired)
    // A new boot invalidates a grant for the old one (A03).
    _ = try f.receipt(.vmStop(instance, expectedGeneration: observation.generation))
    f.supervisor.runPending()
    _ = try f.receipt(
      .vmStart(
        instance, expectedGeneration: observation.generation + 1, ttlSeconds: 600,
        policy: request.policyHash))
    f.supervisor.runPending()
    let reopened = try f.openRequest(instance, observation)
    #expect(failure(f.open(reopened)) != nil)
  }

  @Test func leaseExpiresAndCannotBeRevivedOrReused() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    f.clock.advance(.seconds(20))
    let renewed = try AccessGrant(
      wire: f.call(
        .accessRenew(
          session: request.session, bearer: request.bearer, epoch: f.supervisor.epoch,
          boot: request.expectedBoot, policy: request.policyHash)
      ).get())
    #expect(renewed.leaseExpiresAt.seconds == WireTime(f.clock.now()).seconds + 30)
    f.clock.advance(.seconds(31))
    #expect(f.supervisor.sessions.sweep() == [request.session])
    let renew = HostRequestBody.accessRenew(
      session: request.session, bearer: request.bearer, epoch: f.supervisor.epoch,
      boot: request.expectedBoot, policy: request.policyHash)
    #expect(failure(f.call(renew)) == .sessionExpired)
    #expect(failure(f.open(request)) == .sessionExpired)
  }

  @Test func closeIsIdempotentAndRequiresTheBearer() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    let wrong = HostRequestBody.accessClose(
      session: request.session, bearer: .generate(), epoch: f.supervisor.epoch)
    #expect(failure(f.call(wrong)) == .sessionExpired)
    #expect(f.supervisor.sessions.isLive(request.session))
    let close = HostRequestBody.accessClose(
      session: request.session, bearer: request.bearer, epoch: f.supervisor.epoch)
    _ = try f.call(close).get()
    _ = try f.call(close).get()
    #expect(failure(f.open(request)) == .sessionExpired)
  }

  @Test func issuedIDsAreNeverEvictedAtTheCap() throws {
    var settings = HostSupervisor.Settings()
    settings.access = .init(leaseSeconds: 30, maxLive: 64, maxIssued: 3)
    let f = try SupervisorFixture(settings: settings)
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    var requests: [AccessOpenRequest] = []
    for _ in 0..<3 {
      let request = try f.openRequest(instance, observation)
      _ = try f.open(request).get()
      requests.append(request)
    }
    let close = HostRequestBody.accessClose(
      session: requests[0].session, bearer: requests[0].bearer, epoch: f.supervisor.epoch)
    _ = try f.call(close).get()
    #expect(failure(f.open(try f.openRequest(instance, observation))) == .limitExceeded)
    // Renewal and close remain available at the cap.
    let renew = HostRequestBody.accessRenew(
      session: requests[1].session, bearer: requests[1].bearer, epoch: f.supervisor.epoch,
      boot: requests[1].expectedBoot, policy: requests[1].policyHash)
    _ = try f.call(renew).get()
    #expect(failure(f.open(requests[0])) == .sessionExpired)
  }

  @Test func oneControllingClientPerBoot() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    _ = try f.open(try f.openRequest(instance, observation, key: "11")).get()
    _ = try f.open(try f.openRequest(instance, observation, key: "11")).get()
    #expect(failure(f.open(try f.openRequest(instance, observation, key: "22"))) == .sessionInUse)
  }

  @Test func leaseNeverOutlivesTheVM() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    f.clock.advance(.seconds(3_590))
    let grant = try AccessGrant(wire: f.open(try f.openRequest(instance, observation)).get())
    #expect(grant.leaseExpiresAt == grant.vmExpiresAt)
    f.clock.advance(.seconds(11))
    #expect(failure(f.open(try f.openRequest(instance, observation))) == .sessionExpired)
  }

  @Test func bearerIsNeverPersisted() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    let enumerator = FileManager.default.enumerator(atPath: f.root)
    while let path = enumerator?.nextObject() as? String {
      guard let data = FileManager.default.contents(atPath: f.root + "/" + path) else { continue }
      #expect(!String(decoding: data, as: UTF8.self).contains(request.bearer.rawValue))
    }
  }

  @Test func stopRevokesLiveSessions() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    _ = try f.receipt(.vmStop(instance, expectedGeneration: observation.generation))
    f.supervisor.runPending()
    #expect(!f.supervisor.sessions.isLive(request.session))
  }
}

/// A loopback TCP echo server standing in for the guest's SSH port.
final class EchoServer: @unchecked Sendable {
  let fd: Int32
  let port: UInt16

  init() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    fd = listener
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
    }
    listen(listener, 8)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    port = UInt16(bigEndian: address.sin_port)
    Thread.detachNewThread {
      while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        Thread.detachNewThread {
          var buffer = [UInt8](repeating: 0, count: 4_096)
          while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            _ = write(client, buffer, count)
          }
          close(client)
        }
      }
    }
  }

  func stop() { close(fd) }
}

@Suite struct HostControlRelayTests {
  func relay(_ f: SupervisorFixture, _ preamble: [UInt8]) -> (Int32, [UInt8]?) {
    var pair: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
    let server = pair[1]
    Thread.detachNewThread { f.supervisor.serveRelay(client: server) }
    _ = preamble.withUnsafeBytes { write(pair[0], $0.baseAddress, $0.count) }
    return (pair[0], Socket.readLine(pair[0], limit: 4_096))
  }

  @Test func relayCarriesBytesAndRevocationClosesTheStream() throws {
    let echo = try EchoServer()
    defer { echo.stop() }
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    f.native.set {
      $0.endpoint = GuestEndpoint(address: try! IPv4Address("127.0.0.1"), port: echo.port)
    }
    let (instance, observation) = try f.running()
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    let (client, status) = relay(
      f,
      RelayPreamble(session: request.session, bearer: request.bearer, epoch: f.supervisor.epoch)
        .frame)
    defer { close(client) }
    #expect(status.map { String(decoding: $0, as: UTF8.self) } == #"{"ok":true}"#)
    _ = write(client, "ping", 4)
    var buffer = [UInt8](repeating: 0, count: 4)
    #expect(read(client, &buffer, 4) == 4)
    #expect(buffer == Array("ping".utf8))
    #expect(f.supervisor.relays.count(request.session) == 1)
    // Lease expiry closes the existing stream within the budget (A12).
    f.clock.advance(.seconds(31))
    let started = ContinuousClock.now
    f.supervisor.sessions.sweep()
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    #expect(read(client, &buffer, 4) == 0)
    #expect(ContinuousClock.now - started < .seconds(2))
  }

  @Test func relayRefusesWrongBearerAndEpoch() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    for preamble in [
      RelayPreamble(session: request.session, bearer: .generate(), epoch: f.supervisor.epoch),
      RelayPreamble(session: request.session, bearer: request.bearer, epoch: .generate()),
    ] {
      let (client, status) = relay(f, preamble.frame)
      close(client)
      let line = try #require(status)
      #expect(String(decoding: line, as: UTF8.self).contains("SESSION_EXPIRED"))
    }
    #expect(f.native.calls("endpoint") == 0)
  }
}

@Suite struct RemoteBrokerReadinessTests {
  @Test func filteredGrantsCarryTheWorkersProvenBootPolicy() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running(egress: .filtered)
    #expect(observation.egress == .filtered)
    let grant = try AccessGrant(wire: f.open(try f.openRequest(instance, observation)).get())
    #expect(grant.filteredPolicy?.bootID == observation.bootID)
    // An open VM's grant carries none.
    let (other, otherObservation) = try f.running(name: "plain")
    let plain = try AccessGrant(wire: f.open(try f.openRequest(other, otherObservation)).get())
    #expect(plain.filteredPolicy == nil)
  }

  @Test func lostWorkerEgressProofRefusesAndRevokes() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running(egress: .filtered)
    f.native.inject("filtered", .failed("companion gone"))
    #expect(failure(f.open(try f.openRequest(instance, observation))) == .sessionExpired)
    let request = try f.openRequest(instance, observation)
    _ = try f.open(request).get()
    f.native.inject("filtered", .failed("companion gone"))
    let renew = HostRequestBody.accessRenew(
      session: request.session, bearer: request.bearer, epoch: f.supervisor.epoch,
      boot: request.expectedBoot, policy: request.policyHash)
    #expect(failure(f.call(renew)) == .sessionExpired)
    // No fallback: the session is closed, not degraded.
    #expect(!f.supervisor.sessions.isLive(request.session))
  }
}
