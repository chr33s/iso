import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost
@testable import IsoHostControl

/// `iso.host/v1` golden fixtures shared with `iso-ci`
/// (`tests/fixtures/host-wire/v1/`). `responses.jsonl` is written by the
/// host's encoders here and decoded by iso-ci's client types;
/// `requests.jsonl` is written by iso-ci's encoder and decoded here. A wire
/// change on either side fails the other side's test until the fixtures are
/// regenerated (`ISO_UPDATE_FIXTURES=1`) and both suites pass again.
@Suite struct HostWireConformanceTests {
  static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../fixtures/host-wire/v1").standardized

  /// `dddddddd-dddd-4ddd-8ddd-dddddddddddd`.
  static func uuid(_ digit: Character) -> String {
    [8, 4, 4, 4, 12].enumerated().map { index, count in
      var group = String(repeating: digit, count: count)
      if index == 2 { group = "4" + group.dropFirst() }
      if index == 3 { group = "8" + group.dropFirst() }
      return group
    }.joined(separator: "-")
  }

  static func digest(_ digit: Character) throws -> SHA256Hex {
    try SHA256Hex(String(repeating: digit, count: 64))
  }

  struct Identity {
    let request = try! RequestID(HostWireConformanceTests.uuid("1"))
    let host = try! HostID(HostWireConformanceTests.uuid("2"))
    let owner = try! OwnerID("0a1b2c3d00112233445566778899aabb")
    let epoch = try! DaemonEpoch(HostWireConformanceTests.uuid("3"))
    let instanceID = try! InstanceID(HostWireConformanceTests.uuid("4"))
    let operation = try! HostOperationID(HostWireConformanceTests.uuid("5"))
    let session = try! SessionID(HostWireConformanceTests.uuid("6"))
    let run = try! RunID(HostWireConformanceTests.uuid("7"))
    let artifact = try! ArtifactHandle(HostWireConformanceTests.uuid("8"))
    let runtime = try! MachineName("iso-0a1b2c3d-00112233445566ff")
    let boot = try! BootID("b7ad1194a3cc79a7720b4f169833bb62")
    let now = WireTime(seconds: 1_800_000_000)

    var instance: QualifiedInstance {
      QualifiedInstance(
        hostID: host, ownerID: owner, instanceID: instanceID, runtimeID: runtime, guestOS: .linux)
    }
  }

  static let liveTuple = [
    "host_os": "27.0.0", "iso_version": "0.6.0", "runtime": "iso-sandbox 0.5.0",
    "transport": "brokered",
  ]
  static let qualifiedImageDigest = "sha256:" + String(repeating: "c", count: 64)

  /// A complete evidence manifest with sorted keys, so its digest is stable.
  static func manifestBytes() throws -> [UInt8] {
    var tuple = liveTuple
    tuple["image"] = "ci-runner@" + qualifiedImageDigest
    tuple["guest_kernel"] = "vmlinux-6.12"
    tuple["broker"] = "iso-egress 0.6.0"
    let document: [String: Any] = [
      "schema": QualificationManifest.schema, "capability": QualificationManifest.capability,
      "recorded_at": 1_799_000_000, "expires_at": 1_802_592_000, "tuple": tuple,
      "tests": Dictionary(
        uniqueKeysWithValues: QualificationManifest.requiredTests.map { ($0, "passed") }),
    ]
    return Array(try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
  }

  static func brokeredNetwork() -> NetworkCapability {
    NetworkCapability(
      transport: .brokered, runtimeBrokered: true,
      runPolicies: [
        .none: BrokeredNetworkPolicy(publicEgress: nil, providerGrants: [], localServices: []),
        .filtered: BrokeredNetworkPolicy(
          publicEgress: .init(
            profile: "filtered", allowedHosts: ["api.github.com", "github.com"],
            policyHash: "sha256:" + String(repeating: "e", count: 64)),
          providerGrants: ["anthropic"],
          localServices: [
            .init(name: "ollama", guestPort: 11_434, hostAddress: "127.0.0.1", hostPort: 11_434)
          ]),
      ], liveTuple: liveTuple)
  }

  /// Every result shape iso-ci decodes, from the host's own encoders.
  static func results() throws -> [(String, Result<JSONValue, HostControlError>)] {
    let id = Identity()
    var cases: [(String, Result<JSONValue, HostControlError>)] = []
    func add(_ name: String, _ value: JSONValue) { cases.append((name, .success(value))) }

    for (name, runtime) in [
      ("hello", RuntimeQualification.qualified("iso-sandbox 0.5.0")),
      ("hello/unqualified", .unqualified("iso-sandbox is not installed")),
    ] {
      add(
        name,
        HelloResult(
          protocolVersion: HostProtocol.v1, hostID: id.host, ownerID: id.owner, epoch: id.epoch,
          runtime: runtime, methods: HostSupervisor.methods(for: .ssh), guestOperations: [.linux]
        ).wire)
    }

    var vmnetTuple = liveTuple
    vmnetTuple["transport"] = "vmnet"
    let vmnet = NetworkCapability(
      transport: .vmnet, runtimeBrokered: false, runPolicies: [:], liveTuple: vmnetTuple)
    add(
      "host.capabilities/vmnet",
      HostCapabilitiesResult(
        network: vmnet,
        qualification: QualificationReport(
          status: .missing, reason: "no NET-HANDOFF-1 evidence manifest is installed",
          manifest: nil, liveTuple: vmnetTuple), maxTTLSeconds: 86_400
      ).wire)
    let manifest = try QualificationManifest(bytes: try manifestBytes(), now: id.now.seconds)
    add(
      "host.capabilities/brokered-qualified",
      HostCapabilitiesResult(
        network: brokeredNetwork(),
        qualification: QualificationReport(
          status: .qualified, reason: nil, manifest: manifest, liveTuple: liveTuple),
        maxTTLSeconds: 86_400
      ).wire)
    add(
      "host.capabilities/brokered-expired",
      HostCapabilitiesResult(
        network: brokeredNetwork(),
        qualification: QualificationReport(
          status: .expired, reason: "the evidence manifest expired", manifest: manifest,
          liveTuple: liveTuple), maxTTLSeconds: nil
      ).wire)

    let name = try InstanceName("ci-run-1")
    let image = try ImageName("ci-runner")
    let policy = try digest("a")
    add(
      "vm.inspect/stopped",
      VMObservation(
        instance: id.instance, name: name, generation: 3, state: .stopped, bootID: nil,
        policyHash: policy, expiresAt: nil, observedAt: id.now, activeOperation: nil,
        image: image, egress: EgressMode.none
      ).wire)
    add(
      "vm.inspect/running-vmnet",
      VMObservation(
        instance: id.instance, name: name, generation: 4, state: .running, bootID: id.boot,
        policyHash: policy, expiresAt: id.now.adding(seconds: 3_600), observedAt: id.now,
        activeOperation: id.operation, image: image, egress: .filtered
      ).wire)
    add(
      "vm.inspect/running-brokered",
      VMObservation(
        instance: id.instance, name: name, generation: 4, state: .running, bootID: id.boot,
        policyHash: policy, expiresAt: id.now.adding(seconds: 3_600), observedAt: id.now,
        activeOperation: nil, image: image, egress: EgressMode.none,
        network: NetworkProof(
          bootID: id.boot, networkPolicy: try digest("b"), channelPolicy: try digest("d"))
      ).wire)
    add(
      "vm.inspect/destroyed",
      VMObservation(
        instance: id.instance, name: name, generation: 6, state: .destroyed, bootID: nil,
        policyHash: nil, expiresAt: nil, observedAt: id.now, activeOperation: nil
      ).wire)

    add(
      "operation.get/accepted",
      OperationReceipt(
        operationID: id.operation, method: .runCreate, state: .accepted, disposition: .accepted,
        acceptedAt: id.now, completedAt: nil, instance: nil, generation: nil, bootID: nil,
        expiresAt: nil, outcome: nil, cancelRequested: false
      ).wire)
    add(
      "operation.get/succeeded",
      OperationReceipt(
        operationID: id.operation, method: .runCreate, state: .succeeded, disposition: .existing,
        acceptedAt: id.now, completedAt: id.now.adding(seconds: 42), instance: id.instance,
        generation: 4, bootID: id.boot, expiresAt: id.now.adding(seconds: 3_600),
        outcome: "run started", cancelRequested: true
      ).wire)

    func grant(vmExpiresAt: WireTime?, filtered: FilteredGrantPolicy?) throws -> AccessGrant {
      AccessGrant(
        session: id.session, epoch: id.epoch, instance: id.instance, bootID: id.boot,
        policyHash: policy, generation: 4, purpose: .ssh, issuedAt: id.now,
        leaseExpiresAt: id.now.adding(seconds: 120), vmExpiresAt: vmExpiresAt,
        guestHostKey: fakeGuestHostKey, guestUser: try GuestUser("runner"),
        filteredPolicy: filtered)
    }
    add("access.open", try grant(vmExpiresAt: nil, filtered: nil).wire)
    add(
      "access.open/filtered",
      try grant(
        vmExpiresAt: id.now.adding(seconds: 3_600),
        filtered: FilteredGrantPolicy(
          bootID: id.boot,
          policyHash: try FilteredPolicyHash("sha256:" + String(repeating: "e", count: 64)))
      ).wire)

    var record = RunStore.Record(
      runID: id.run, createdBy: id.operation, generation: 1, phase: .reserved,
      outputLimit: 1 << 20, ttlSeconds: 600, createOperation: id.operation,
      startOperation: id.operation, recoveryUsed: false)
    add("run.inspect/reserved", RunObservation(record: record).wire)
    record.generation = 9
    record.phase = .resultsPending
    record.instanceID = id.instanceID
    record.runtimeID = id.runtime
    record.artifact = id.artifact
    record.artifactDigest = try digest("f")
    record.retentionDeadline = id.now.seconds + 3_600
    record.liveRetentionUntil = id.now.seconds + 1_800
    record.recoveryUsed = true
    record.disposition = "completed"
    add("run.inspect/retained", RunObservation(record: record).wire)

    cases.append(
      (
        "error/generation-conflict",
        .failure(
          HostControlError(
            .generationConflict, "the instance changed since it was observed",
            details: ["instance_id": id.instanceID.rawValue]))
      ))
    return cases
  }

  static func responseLines() throws -> String {
    let id = Identity()
    return try results().map { name, outcome in
      let frame = HostResponse(
        requestID: id.request, hostID: id.host, ownerID: id.owner, epoch: id.epoch,
        outcome: outcome
      ).frame
      return name + "\t" + String(decoding: frame, as: UTF8.self)
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

  @Test func theHostEncodersProduceTheCommittedResponses() throws {
    let generated = try Self.responseLines()
    let path = Self.directory.appending(path: "responses.jsonl")
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
    // Each committed response is also one the host's own decoder accepts.
    for line in try Self.lines("responses.jsonl") {
      #expect(throws: Never.self, "\(line.name)") { try HostResponse.decode(frame: line.frame) }
    }
  }

  @Test func theHostDecodesEveryClientRequest() throws {
    let lines = try Self.lines("requests.jsonl")
    try #require(!lines.isEmpty)
    var methods: Set<HostMethod> = []
    for line in lines {
      // `<method>` or `<method>/<variant>`.
      let expected = String(line.name.split(separator: "/")[0])
      let request: HostRequest
      do { request = try HostRequest.decode(frame: line.frame) } catch {
        Issue.record("\(line.name): the host refuses the client's frame: \(error)")
        continue
      }
      #expect(request.body.method.rawValue == expected, "\(line.name)")
      methods.insert(request.body.method)
      // Both sides agree on the canonical encoding, so durable-operation
      // digests computed from the typed request match the client's bytes.
      #expect(
        String(decoding: request.frame, as: UTF8.self)
          == String(decoding: line.frame, as: UTF8.self) + "\n", "\(line.name)")
      // The client computes the policy hash the way the host recomputes it.
      if case .runCreate(_, let spec, _, _) = request.body {
        #expect(spec.policyHash == spec.computedPolicyHash, "\(line.name)")
      }
    }
    // Every method the client sends is one this host dispatches on both
    // transports and advertises in `hello`. (The iso-ci suite asserts the
    // file covers every method the client declares.)
    for method in methods.sorted(by: { $0.rawValue < $1.rawValue }) {
      #expect(HostSupervisor.methods(for: .ssh).contains(method), "\(method.rawValue)")
      #expect(HostSupervisor.methods(for: .local).contains(method), "\(method.rawValue)")
    }
    #expect(methods.contains(.hello) && methods.contains(.runCreate))
  }
}
