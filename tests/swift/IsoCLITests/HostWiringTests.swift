import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Synchronization
import Testing

@testable import IsoCLI

/// An in-memory host: answers each request from `reply` and records the
/// methods it was asked for, so a test can prove what was never sent.
private final class ScriptedHost: HostTransport, Sendable {
  let hostID = HostID.generate()
  let ownerID: OwnerID
  private let epoch = DaemonEpoch.generate()
  private let reply: @Sendable (HostRequest) -> JSONValue
  private let seen = Mutex<[String]>([])
  /// While set, every exchange is lost after sending, as an unreachable host.
  let dropReplies = Mutex(false)

  init(owner: OwnerID, reply: @escaping @Sendable (HostRequest) -> JSONValue) {
    ownerID = owner
    self.reply = reply
  }

  var methods: [String] { seen.withLock { $0 } }

  func exchange(_ frame: [UInt8]) throws(HostControlError) -> [UInt8] {
    guard let request = try? HostRequest.decode(frame: frame) else {
      throw .invalidRequest("undecodable test frame")
    }
    seen.withLock { $0.append(request.body.method.rawValue) }
    if dropReplies.withLock({ $0 }) { throw HostControlError(.hostUnreachable, "test: reply lost") }
    return HostResponse(
      requestID: request.requestID, hostID: hostID, ownerID: ownerID, epoch: epoch,
      outcome: .success(reply(request))
    ).frame
  }
}

private struct Fixture {
  let root: String
  let env: HostCommandEnvironment
  let host: ScriptedHost
  let remote: RemoteHost
  let binding: ClientBinding

  init(name: String = "proj", reply: @escaping @Sendable (HostRequest) -> JSONValue) throws {
    root = FileManager.default.temporaryDirectory.appending(path: "iso-wiring-\(UUID())").path
    try FileManager.default.createDirectory(
      atPath: root + "/proj", withIntermediateDirectories: true)
    let config = try ConfigLoader.load(
      .defaultsOnly(defaultPath: root + "/config.jsonc"),
      environment: ConfigEnvironment(home: root, variables: [:]))
    env = HostCommandEnvironment(
      config: config, environment: [:], diagnostics: Diagnostics(verbosity: 0))
    let owner = try OwnerID(String(repeating: "ab", count: 16))
    host = ScriptedHost(owner: owner, reply: reply)
    let alias = try HostAlias("studio")
    remote = RemoteHost(
      enrollment: HostEnrollment(
        alias: alias, sshAlias: alias, agentPath: try AgentPath("/usr/local/bin/iso"),
        hostID: host.hostID, ownerID: owner, enrolledAt: 1),
      client: HostControlClient(transport: host, expected: (host.hostID, owner)))
    binding = ClientBinding(
      host: alias, hostID: host.hostID, ownerID: owner, instanceID: .generate(),
      runtimeID: try MachineName("iso-abababab-0011223344556677"), guestOS: .linux,
      name: try InstanceName(name), policyHash: HostWire.sha256([]), createdBy: .generate(),
      lastState: .running, lastObservedAt: 1)
    try ClientBindingStore(config: config).save(binding)
  }

  func observation(_ state: ObservedState, egress: EgressMode?) -> JSONValue {
    VMObservation(
      instance: binding.instance, name: binding.name, generation: 3, state: state,
      bootID: nil, policyHash: binding.policyHash, expiresAt: nil,
      observedAt: WireTime(seconds: 2), activeOperation: nil, egress: egress
    ).wire
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

/// Observations are answered from a box the test fills after the fixture
/// exists, because they name the fixture's own binding.
private final class Replies: Sendable {
  let inspect = Mutex<JSONValue>(.null)
  let run = Mutex<JSONValue>(.null)
  let receipt = Mutex<JSONValue>(.null)

  func answer(_ request: HostRequest) -> JSONValue {
    switch request.body.method {
    case .vmInspect: inspect.withLock { $0 }
    case .runInspect: run.withLock { $0 }
    default: receipt.withLock { $0 }
    }
  }
}

private func hostUp(_ fixture: Fixture, _ flags: [String]) throws -> HostUp {
  try #require(
    try IsoCommand.parseAsRoot(
      ["host", "up", "studio", fixture.root + "/proj", "--name", "proj"] + flags) as? HostUp)
}

@Test func hostUpRefusesAMismatchedEgressBeforeAnyStartOrPush() throws {
  let replies = Replies()
  let fixture = try Fixture(reply: replies.answer)
  defer { fixture.cleanup() }
  replies.inspect.withLock { $0 = fixture.observation(.running, egress: .open) }
  let mismatch = try hostUp(fixture, ["--egress", "filtered"])
  #expect(throws: HostError.self) { _ = try mismatch.prepare(fixture.env, fixture.remote) }
  // Only the observation went to the host: no start, no session, no push.
  #expect(fixture.host.methods == ["vm.inspect"])

  // The matching value, and no value at all, reuse the VM.
  for flags in [["--egress", "open"], []] {
    let (binding, _) = try hostUp(fixture, flags).prepare(fixture.env, fixture.remote)
    #expect(binding.name.rawValue == "proj")
  }
}

@Test func hostUpRefusesAnUnreportedEgressOnAStoppedVM() throws {
  let replies = Replies()
  let fixture = try Fixture(reply: replies.answer)
  defer { fixture.cleanup() }
  replies.inspect.withLock { $0 = fixture.observation(.stopped, egress: nil) }
  let up = try hostUp(fixture, ["--egress", "none"])
  #expect(throws: HostError.self) { _ = try up.prepare(fixture.env, fixture.remote) }
  #expect(fixture.host.methods == ["vm.inspect"])
}

@Test func hostUpReportsADestroyedVMRatherThanItsEgress() throws {
  let replies = Replies()
  let fixture = try Fixture(reply: replies.answer)
  defer { fixture.cleanup() }
  replies.inspect.withLock { $0 = fixture.observation(.destroyed, egress: nil) }
  let up = try hostUp(fixture, ["--egress", "none"])
  do {
    _ = try up.prepare(fixture.env, fixture.remote)
    Issue.record("a destroyed VM was reused")
  } catch let error as HostError {
    #expect("\(error)".contains("is destroyed"))
  }
}

@Test func aFailedRecoveryFailsRunResultsEvenThoughTheHostAnswered() throws {
  let replies = Replies()
  let fixture = try Fixture(reply: replies.answer)
  defer { fixture.cleanup() }
  let runID = RunID.generate()
  var run = WireBuilder()
  run.set("run_id", runID)
  run.set("generation", UInt64(4))
  run.set("phase", "stopped_disk_pending_export")
  run.set("recovery_used", false)
  replies.run.withLock { $0 = run.value }
  for state in [OperationState.failed, .succeeded] {
    replies.receipt.withLock {
      $0 =
        OperationReceipt(
          operationID: .generate(), method: .runResultsRecover, state: state,
          disposition: .accepted, acceptedAt: WireTime(seconds: 1),
          completedAt: WireTime(seconds: 2), instance: nil, generation: nil, bootID: nil,
          expiresAt: nil, outcome: nil, cancelRequested: false
        ).wire
    }
    let results = try #require(
      try IsoCommand.parseAsRoot(["host", "run-results", "studio", runID.rawValue, "--recover"])
        as? HostRunResults)
    if state == .succeeded {
      try results.perform(fixture.env, fixture.remote)
    } else {
      #expect(throws: ExitCode.failure) { try results.perform(fixture.env, fixture.remote) }
    }
  }
  #expect(fixture.host.methods.filter { $0 == "run.results.recover" }.count == 2)
}

@Test func anUncertainSubmissionKeepsItsIDAndOnlyOffersARealRetryFlag() throws {
  let fixture = try Fixture { _ in .null }
  defer { fixture.cleanup() }
  fixture.host.dropReplies.withLock { $0 = true }
  let stop = HostRequestBody.vmStop(fixture.binding.instance, expectedGeneration: 1)
  let option = try #require(
    try IsoCommand.parseAsRoot([
      "host", "vm", "stop", "studio", "proj", "--operation-id", HostOperationID.generate().rawValue,
    ]) as? HostVMStop)
  let resendable = try option.operation.resolve()
  #expect(resendable.resendable && !SubmittedOperation.fresh().resendable)
  for submitted in [resendable, SubmittedOperation.fresh()] {
    do {
      _ = try submit(
        fixture.remote, stop, operation: submitted, wait: .seconds(1), output: StandardStreams())
      Issue.record("a lost reply was treated as delivered")
    } catch let error as HostError {
      let text = "\(error)"
      #expect(text.contains(submitted.id.rawValue))
      #expect(text.contains("--operation-id") == submitted.resendable)
    }
  }
}
