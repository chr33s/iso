import Foundation
import Testing

@testable import IsoCICore

/// `iso.host/v1` golden fixtures shared with the host package
/// (`tests/fixtures/host-wire/v1/` at the repository root).
/// `requests.jsonl` is written by this client's encoder and decoded by the
/// host's `HostRequest.decode`; `responses.jsonl` is written by the host's
/// encoders and decoded here. A wire change on either side fails the other
/// side's test until the fixtures are regenerated (`ISO_UPDATE_FIXTURES=1`)
/// and both suites pass again.
@Suite struct HostWireConformanceTests {
  static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../tests/fixtures/host-wire/v1").standardized

  /// `dddddddd-dddd-4ddd-8ddd-dddddddddddd`.
  static func uuid(_ digit: Character) -> String {
    [8, 4, 4, 4, 12].enumerated().map { index, count in
      var group = String(repeating: digit, count: count)
      if index == 2 { group = "4" + group.dropFirst() }
      if index == 3 { group = "8" + group.dropFirst() }
      return group
    }.joined(separator: "-")
  }

  static func digest(_ digit: Character) throws -> Digest {
    try Digest(String(repeating: digit, count: 64))
  }

  // The same fixed identities the host suite writes into `responses.jsonl`.
  struct Identity {
    let request = try! RequestID(HostWireConformanceTests.uuid("1"))
    let host = try! HostID(HostWireConformanceTests.uuid("2"))
    let owner = try! OwnerID("0a1b2c3d00112233445566778899aabb")
    let epoch = try! DaemonEpoch(HostWireConformanceTests.uuid("3"))
    let instanceID = try! InstanceID(HostWireConformanceTests.uuid("4"))
    let operation = try! HostOperationID(HostWireConformanceTests.uuid("5"))
    let session = try! SessionID(HostWireConformanceTests.uuid("6"))
    let run = try! HostRunID(HostWireConformanceTests.uuid("7"))
    let artifact = try! ArtifactHandle(HostWireConformanceTests.uuid("8"))
    let runtime = "iso-0a1b2c3d-00112233445566ff"
    let boot = try! BootID("b7ad1194a3cc79a7720b4f169833bb62")
    let now: EpochSeconds = 1_800_000_000
    let bearer = String(repeating: "9", count: 64)

    var instance: QualifiedInstance {
      QualifiedInstance(
        hostID: host, ownerID: owner, instanceID: instanceID, runtimeID: runtime, guestOS: "linux")
    }
  }

  /// A syntactically valid ed25519 public key line.
  static let clientKey: String = {
    let blob: [UInt8] =
      [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
      + [UInt8](repeating: 0x43, count: 32)
    return "ssh-ed25519 " + Data(blob).base64EncodedString()
  }()

  /// One request per `HostRequestBody` case, plus the optional-field variants.
  static func requests() throws -> [(String, HostRequestBody)] {
    let id = Identity()
    let policy = try digest("a")
    let pinned = try VMSpec(
      name: "ci-run-1", image: "ci-runner", imageDigest: try digest("c"), cpus: 4,
      memoryMiB: 8_192, diskGiB: 32, egress: .filtered)
    let unpinned = try VMSpec(
      name: "ci-run-2", image: "ci-runner", imageDigest: nil, cpus: 2, memoryMiB: 4_096,
      diskGiB: 16, egress: .none)
    return [
      ("hello", .hello(clientBuild: "iso-ci 0.6.0")),
      ("host.capabilities", .hostCapabilities),
      ("vm.inspect", .vmInspect(id.instance)),
      ("operation.get", .operationGet(id.operation)),
      (
        "access.open",
        .accessOpen(
          AccessOpenRequest(
            instance: id.instance, expectedEpoch: id.epoch, expectedBoot: id.boot,
            expectedGeneration: 4, policyHash: policy, session: id.session, client: "iso-ci",
            clientPublicKey: clientKey, bearer: id.bearer))
      ),
      (
        "access.renew",
        .accessRenew(
          session: id.session, bearer: id.bearer, epoch: id.epoch, boot: id.boot, policy: policy)
      ),
      ("access.close", .accessClose(session: id.session, bearer: id.bearer, epoch: id.epoch)),
      (
        "run.create",
        .runCreate(run: id.run, spec: pinned, outputLimitBytes: 64 << 20, ttlSeconds: 3_600)
      ),
      (
        "run.create/no-image-digest",
        .runCreate(run: id.run, spec: unpinned, outputLimitBytes: 1 << 20, ttlSeconds: 600)
      ),
      ("run.inspect", .runInspect(id.run)),
      ("run.complete", .runComplete(run: id.run, expectedGeneration: 5, exitStatus: 0)),
      (
        "run.complete/nonzero-exit",
        .runComplete(run: id.run, expectedGeneration: 5, exitStatus: 137)
      ),
      (
        "run.complete/no-exit-status",
        .runComplete(run: id.run, expectedGeneration: 5, exitStatus: nil)
      ),
      ("run.retain", .runRetain(run: id.run, expectedGeneration: 5, mode: .live, seconds: 1_800)),
      (
        "run.retain/stopped",
        .runRetain(run: id.run, expectedGeneration: 6, mode: .stopped, seconds: 86_400)
      ),
      ("run.results.discard", .runResultsDiscard(run: id.run, expectedGeneration: 7)),
      ("artifact.read", .artifactRead(handle: id.artifact, offset: 32_768, length: 32_768)),
    ]
  }

  static func requestLines() throws -> String {
    let id = Identity()
    return try requests().map { name, body in
      let request = HostRequest(
        requestID: id.request, hostID: body.method == .hello ? nil : id.host,
        ownerID: body.method == .hello ? nil : id.owner,
        operationID: body.method.isDurableMutation ? id.operation : nil, body: body)
      return name + "\t" + String(decoding: request.frame, as: UTF8.self)
    }.joined()
  }

  static func lines(_ file: String) throws -> [(name: String, frame: [UInt8])] {
    let text = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
    return try text.split(separator: "\n").map { line in
      let parts = line.split(separator: "\t", maxSplits: 1)
      try #require(parts.count == 2, "\(file): a line is not <name>\\t<frame>")
      return (String(parts[0]), Array(parts[1].utf8))
    }
  }

  @Test func theClientEncoderProducesTheCommittedRequests() throws {
    // Every method this client declares has a fixture the host decodes.
    #expect(Set(try Self.requests().map(\.1.method)) == Set(HostMethod.allCases))
    let generated = try Self.requestLines()
    let path = Self.directory.appending(path: "requests.jsonl")
    if ProcessInfo.processInfo.environment["ISO_UPDATE_FIXTURES"] == "1" {
      try FileManager.default.createDirectory(
        at: Self.directory, withIntermediateDirectories: true)
      try Data(generated.utf8).write(to: path)
      return
    }
    let committed = try String(contentsOf: path, encoding: .utf8)
    let expected = committed.split(separator: "\n", omittingEmptySubsequences: false)
    let actual = generated.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(actual.count == expected.count)
    for (want, got) in zip(expected, actual) {
      #expect(got == want, "regenerate with ISO_UPDATE_FIXTURES=1 after a reviewed wire change")
    }
  }

  @Test func theClientDecodesEveryHostResponse() throws {
    let id = Identity()
    let lines = try Self.lines("responses.jsonl")
    var seen: Set<String> = []
    for line in lines {
      let response = try HostResponse.decode(frame: line.frame)
      #expect(response.requestID == id.request, "\(line.name)")
      #expect(response.hostID == id.host, "\(line.name)")
      #expect(response.ownerID == id.owner, "\(line.name)")
      #expect(response.epoch == id.epoch, "\(line.name)")
      let kind = String(line.name.split(separator: "/")[0])
      seen.insert(kind)
      if kind == "error" {
        guard case .failure(let box) = response.outcome else {
          Issue.record("\(line.name): expected an error reply")
          continue
        }
        try Self.check(error: box.error, name: line.name, id: id)
        continue
      }
      let result = try response.outcome.get()
      switch kind {
      case "hello": try Self.check(hello: result, name: line.name, id: id)
      case "host.capabilities": try Self.check(capabilities: result, name: line.name, id: id)
      case "vm.inspect": try Self.check(observation: result, name: line.name, id: id)
      case "operation.get": try Self.check(receipt: result, name: line.name, id: id)
      case "access.open": try Self.check(grant: result, name: line.name, id: id)
      case "run.inspect": try Self.check(run: result, name: line.name, id: id)
      default: Issue.record("\(line.name): no client decoder is checked for this fixture")
      }
    }
    // Every result type this client decodes has at least one host fixture.
    #expect(
      seen == [
        "hello", "host.capabilities", "vm.inspect", "operation.get", "access.open", "run.inspect",
        "error",
      ])
  }

  static func check(error: HostReplyError, name: String, id: Identity) throws {
    #expect(name == "error/generation-conflict")
    #expect(error.code == "GENERATION_CONFLICT")
    #expect(error.retry == "refresh_observation_then_new_operation")
    #expect(error.message == "the instance changed since it was observed")
    #expect(error.details == ["instance_id": id.instanceID.rawValue])
    #expect(error.ciError.code == .conflict)
  }

  static func check(hello value: JSONValue, name: String, id: Identity) throws {
    let hello = try HelloResult(wire: value)
    #expect(hello.hostID == id.host && hello.ownerID == id.owner && hello.epoch == id.epoch)
    // The host advertises every method this client sends.
    #expect(hello.methods.isSuperset(of: HostMethod.allCases.map(\.rawValue)), "\(name)")
    switch name {
    case "hello":
      #expect(hello.runtimeQualified)
      #expect(hello.runtimeDetail == "iso-sandbox 0.5.0")
    case "hello/unqualified":
      #expect(!hello.runtimeQualified)
      #expect(hello.runtimeDetail == "iso-sandbox is not installed")
    default: Issue.record("\(name): unexpected hello fixture")
    }
  }

  static func check(capabilities value: JSONValue, name: String, id: Identity) throws {
    let capabilities = try HostCapabilities(wire: value)
    #expect(capabilities.has(.runRetention1), "\(name)")
    #expect(capabilities.retentionModes == [.live, .stopped], "\(name)")
    #expect(capabilities.maxLiveRetentionSeconds == 14_400, "\(name)")
    #expect(capabilities.maxStoppedRetentionSeconds == 604_800, "\(name)")
    #expect(capabilities.retentionSlots == 4, "\(name)")
    #expect(capabilities.maxOutputBytes == 256 << 20, "\(name)")
    let qualification = try #require(capabilities.qualification, "\(name)")
    switch name {
    case "host.capabilities/vmnet":
      #expect(!capabilities.has(.netHandoff1))
      #expect(capabilities.transport == nil && !capabilities.fallbackForbidden)
      #expect(capabilities.runPolicies.isEmpty)
      #expect(qualification.status == .missing)
      #expect(qualification.reason == "no NET-HANDOFF-1 evidence manifest is installed")
      #expect(qualification.manifestDigest == nil && qualification.expiresAt == nil)
      #expect(qualification.tuple["transport"] == "vmnet" && qualification.tests.isEmpty)
      #expect(capabilities.maxTTLSeconds == 86_400)
    case "host.capabilities/brokered-qualified", "host.capabilities/brokered-expired":
      let qualified = name.hasSuffix("qualified")
      #expect(capabilities.has(.netHandoff1) == qualified, "\(name)")
      #expect(capabilities.transport == "brokered" && capabilities.fallbackForbidden, "\(name)")
      let none = try #require(capabilities.runPolicies[.none], "\(name)")
      #expect(none.isGrantFree && none.publicEgressHosts == nil, "\(name)")
      let filtered = try #require(capabilities.runPolicies[.filtered], "\(name)")
      #expect(filtered.publicEgressHosts == ["api.github.com", "github.com"], "\(name)")
      #expect(filtered.providerGrants == ["anthropic"], "\(name)")
      #expect(filtered.localServices == ["ollama"], "\(name)")
      #expect(filtered.digest != none.digest && filtered.channelPolicy == none.channelPolicy)
      #expect(qualification.status == (qualified ? .qualified : .expired), "\(name)")
      #expect((qualification.reason == nil) == qualified, "\(name)")
      #expect(qualification.manifestDigest != nil, "\(name)")
      #expect(qualification.expiresAt == 1_802_592_000, "\(name)")
      #expect(
        qualification.tuple["image"] == "ci-runner@sha256:" + String(repeating: "c", count: 64),
        "\(name)")
      #expect(qualification.tests.count == 16, "\(name)")
      #expect(qualification.tests.values.allSatisfy { $0 == "passed" }, "\(name)")
      #expect(capabilities.maxTTLSeconds == (qualified ? 86_400 : 0), "\(name)")
    default: Issue.record("\(name): unexpected capabilities fixture")
    }
  }

  static func check(observation value: JSONValue, name: String, id: Identity) throws {
    let observation = try VMObservation(wire: value)
    #expect(observation.instance == id.instance, "\(name)")
    #expect(observation.observedAt == id.now, "\(name)")
    let policy = try digest("a")
    switch name {
    case "vm.inspect/stopped":
      #expect(observation.state == .stopped && observation.generation == 3)
      #expect(observation.bootID == nil && observation.expiresAt == nil)
      #expect(observation.policyHash == policy && observation.image == "ci-runner")
      #expect(observation.egress == EgressMode.none && observation.network == nil)
    case "vm.inspect/running-vmnet":
      #expect(observation.state == .running && observation.generation == 4)
      #expect(observation.bootID == id.boot && observation.expiresAt == id.now + 3_600)
      #expect(observation.egress == .filtered && observation.network == nil)
    case "vm.inspect/running-brokered":
      #expect(observation.state == .running && observation.bootID == id.boot)
      #expect(observation.egress == EgressMode.none)
      #expect(
        observation.network
          == NetworkProof(
            bootID: id.boot, networkPolicy: try digest("b"), channelPolicy: try digest("d")))
    case "vm.inspect/destroyed":
      #expect(observation.state == .destroyed && observation.generation == 6)
      #expect(observation.policyHash == nil && observation.image == nil)
      #expect(observation.egress == nil && observation.network == nil)
    default: Issue.record("\(name): unexpected observation fixture")
    }
  }

  static func check(receipt value: JSONValue, name: String, id: Identity) throws {
    let receipt = try OperationReceipt(wire: value)
    // A receipt is a closed object: a member the client does not know is refused.
    guard case .object(var members) = value else {
      Issue.record("\(name): the receipt is not an object")
      return
    }
    members["unreviewed"] = true
    #expect(throws: CIError.self, "\(name)") { try OperationReceipt(wire: .object(members)) }
    #expect(receipt.operationID == id.operation && receipt.method == "run.create", "\(name)")
    switch name {
    case "operation.get/accepted":
      #expect(receipt.state == .accepted && receipt.disposition == "accepted")
      #expect(receipt.instance == nil && receipt.outcome == nil && receipt.completedAt == nil)
    case "operation.get/succeeded":
      #expect(receipt.state == .succeeded && receipt.disposition == "existing")
      #expect(receipt.instance == id.instance && receipt.outcome == "run started")
      #expect(receipt.completedAt == id.now + 42)
    default: Issue.record("\(name): unexpected receipt fixture")
    }
  }

  static func check(grant value: JSONValue, name: String, id: Identity) throws {
    let grant = try AccessGrant(wire: value)
    #expect(grant.session == id.session && grant.epoch == id.epoch, "\(name)")
    #expect(grant.instance == id.instance && grant.bootID == id.boot, "\(name)")
    #expect(grant.policyHash == (try digest("a")), "\(name)")
    #expect(grant.leaseExpiresAt == id.now + 120, "\(name)")
    #expect(grant.guestHostKey.hasPrefix("ssh-ed25519 ") && grant.guestUser == "runner", "\(name)")
    switch name {
    case "access.open": #expect(grant.vmExpiresAt == nil)
    case "access.open/filtered": #expect(grant.vmExpiresAt == id.now + 3_600)
    default: Issue.record("\(name): unexpected grant fixture")
    }
  }

  static func check(run value: JSONValue, name: String, id: Identity) throws {
    let run = try RunObservation(wire: value)
    #expect(run.runID == id.run, "\(name)")
    switch name {
    case "run.inspect/reserved":
      #expect(
        run
          == RunObservation(
            runID: id.run, generation: 1, phase: .reserved, instanceID: nil, runtimeID: nil,
            artifact: nil, artifactDigest: nil, retentionDeadline: nil, liveRetentionUntil: nil,
            disposition: nil))
    case "run.inspect/retained":
      #expect(
        run
          == RunObservation(
            runID: id.run, generation: 9, phase: .resultsPending, instanceID: id.instanceID,
            runtimeID: id.runtime, artifact: id.artifact, artifactDigest: try digest("f"),
            retentionDeadline: id.now + 3_600, liveRetentionUntil: id.now + 1_800,
            disposition: "completed"))
    default: Issue.record("\(name): unexpected run fixture")
    }
  }
}
