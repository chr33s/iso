import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

/// `host.capabilities`: NET-HANDOFF-1 is advertised only with a brokered
/// transport, a brokered runtime and current evidence for this tuple.
@Suite struct HostControlCapabilityTests {
  static let imageDigest = "sha256:" + String(repeating: "c", count: 64)
  static let liveTuple = [
    "host_os": "27.0.0", "iso_version": "0.6.0", "runtime": "fake-runtime 1",
    "transport": "brokered",
  ]

  func brokered(_ f: SupervisorFixture, runtime: Bool = true) {
    f.native.set {
      $0.capability = NetworkCapability(
        transport: .brokered, runtimeBrokered: runtime,
        runPolicies: [
          .none: BrokeredNetworkPolicy(publicEgress: nil, providerGrants: [], localServices: [])
        ], liveTuple: Self.liveTuple)
      $0.imageDigests = [.default: Self.imageDigest]
    }
  }

  func manifest(
    tuple: [String: String] = [:], tests: [String: String] = [:], expires: UInt64? = nil,
    recorded: UInt64 = 1_799_000_000, extra: [String: Any] = [:]
  ) -> [String: Any] {
    var fullTuple = Self.liveTuple.merging(
      [
        "image": "default@" + Self.imageDigest, "guest_kernel": "vmlinux-6.12",
        "broker": "iso-egress 0.6.0",
      ],
      uniquingKeysWith: { a, _ in a })
    fullTuple.merge(tuple) { _, b in b }
    var results = Dictionary(
      uniqueKeysWithValues: QualificationManifest.requiredTests.map { ($0, "passed") })
    results.merge(tests) { _, b in b }
    var document: [String: Any] = [
      "schema": "iso.qualification/v1", "capability": "NET-HANDOFF-1", "recorded_at": recorded,
      "expires_at": expires ?? 1_802_592_000, "tuple": fullTuple, "tests": results,
    ]
    document.merge(extra) { _, b in b }
    return document
  }

  func install(_ f: SupervisorFixture, _ document: [String: Any], mode: mode_t = 0o600) throws {
    let path = QualificationManifest.path(root: f.supervisor.store.root)
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: document).write(to: URL(fileURLWithPath: path))
    chmod(path, mode)
  }

  func capabilities(_ f: SupervisorFixture, transport: HostTransportKind = .ssh) throws
    -> JSONValue
  {
    try f.call(.hostCapabilities, transport: transport).get()
  }

  func names(_ value: JSONValue) -> [String] {
    guard case .array(let items)? = value["capabilities"] else { return [] }
    return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
  }

  func status(_ value: JSONValue) -> String? {
    if case .string(let s)? = value["qualification"]?["status"] { s } else { nil }
  }

  @Test func aVmnetHostAdvertisesRetentionButNoHandoff() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let value = try capabilities(f)
    #expect(names(value) == ["run-retention-1"])
    #expect(value["network_handoff"] == nil)
    #expect(status(value) == "missing")
    #expect(value["limits"]?["max_ttl_seconds"] == .number(.unsigned(24 * 3_600)))
    // Local requests have no host maximum TTL.
    #expect(try capabilities(f, transport: .local)["limits"]?["max_ttl_seconds"] == nil)
    // The method is dispatched over both transports.
    #expect(HostSupervisor.methods(for: .ssh).contains(.hostCapabilities))
    #expect(HostSupervisor.methods(for: .local).contains(.hostCapabilities))
  }

  @Test func currentEvidenceForThisTupleAdvertisesTheHandoff() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    brokered(f)
    try install(f, manifest())
    let value = try capabilities(f)
    #expect(names(value) == ["net-handoff-1", "run-retention-1"])
    #expect(status(value) == "qualified")
    let policy = try #require(value["network_handoff"]?["run_policies"]?["none"])
    let expected = BrokeredNetworkPolicy(publicEgress: nil, providerGrants: [], localServices: [])
    #expect(policy["digest"] == .string(expected.digest.rawValue))
    #expect(policy["provider_grants"] == .array([]))
    #expect(policy["public_egress"] == .null)
    #expect(value["network_handoff"]?["fallback"] == .string("forbidden"))
    #expect(value["qualification"]?["manifest_digest"] != nil)
  }

  @Test func everyMissingConditionFailsClosed() throws {
    let cases: [(String, (SupervisorFixture) throws -> Void, String)] = [
      ("no manifest", { _ in }, "missing"),
      ("a failed test", { try install($0, manifest(tests: ["N-T05": "failed"])) }, "missing"),
      (
        "a not-applicable test", { try install($0, manifest(tests: ["N-T09": "not-applicable"])) },
        "missing"
      ),
      ("an unknown field", { try install($0, manifest(extra: ["note": "x"])) }, "missing"),
      (
        "another iso version", { try install($0, manifest(tuple: ["iso_version": "0.5.0"])) },
        "mismatch"
      ),
      ("a vmnet tuple", { try install($0, manifest(tuple: ["transport": "vmnet"])) }, "mismatch"),
      (
        "a rebuilt image",
        {
          try install(
            $0, manifest(tuple: ["image": "default@sha256:" + String(repeating: "d", count: 64)]))
        },
        "mismatch"
      ),
      ("expired evidence", { try install($0, manifest(expires: 1_799_500_000)) }, "expired"),
      ("a group-writable manifest", { try install($0, manifest(), mode: 0o620) }, "missing"),
      (
        "a lifetime over 365 days",
        {
          try install($0, manifest(expires: 1_799_000_000 + 400 * 86_400, recorded: 1_799_000_000))
        },
        "missing"
      ),
      (
        "evidence recorded in the future",
        { try install($0, manifest(recorded: 1_800_001_000)) }, "missing"
      ),
      (
        "an image without a sha256 digest",
        {
          try install(
            $0, manifest(tuple: ["image": "default@" + String(repeating: "c", count: 64)]))
        },
        "missing"
      ),
    ]
    for (label, setup, expected) in cases {
      let f = try SupervisorFixture()
      defer { f.cleanup() }
      brokered(f)
      try setup(f)
      let value = try capabilities(f)
      #expect(!names(value).contains("net-handoff-1"), "\(label)")
      #expect(status(value) == expected, "\(label)")
    }
  }

  @Test func aRuntimeWithoutTheBrokeredFeatureIsNotAHandoff() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    brokered(f, runtime: false)
    try install(f, manifest())
    let value = try capabilities(f)
    #expect(status(value) == "qualified")
    #expect(!names(value).contains("net-handoff-1"))
  }

  @Test func theQualifiedImageIsNamedOnlyWhileTheHandoffIsAdvertised() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    brokered(f)
    try install(f, manifest())
    let image = try #require(try capabilities(f)["network_handoff"]?["qualified_image"])
    #expect(image["name"] == .string("default"))
    #expect(image["digest"] == .string(Self.imageDigest))
    // Valid evidence, but no handoff (the runtime lacks the brokered feature).
    brokered(f, runtime: false)
    #expect(try capabilities(f)["network_handoff"]?["qualified_image"] == nil)
  }

  @Test func aFIFOAtTheManifestPathIsRefusedWithoutBlocking() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    brokered(f)
    let path = QualificationManifest.path(root: f.supervisor.store.root)
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    #expect(mkfifo(path, 0o600) == 0)
    let value = try capabilities(f)
    #expect(status(value) == "missing")
    #expect(!names(value).contains("net-handoff-1"))
  }

  @Test func aRequestedImageDigestMustBeTheWorkerImage() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    f.native.set { $0.imageDigests = [.default: Self.imageDigest] }
    func spec(_ hex: Character) throws -> VMSpec {
      try VMSpec.make(
        name: InstanceName("bound"), image: .default,
        imageDigest: try SHA256Hex(String(repeating: hex, count: 64)), cpus: 2, memoryMiB: 4096,
        diskGiB: 8, guestOS: .linux, egress: .none)
    }
    #expect(
      failure(
        f.call(
          .runCreate(
            run: .generate(), spec: try spec("d"), outputLimitBytes: 1 << 20, ttlSeconds: 600),
          operation: .generate())) == .instanceIncompatible)
    #expect(
      failure(f.call(.vmCreate(try spec("d")), operation: .generate())) == .instanceIncompatible)
    let accepted = try f.receipt(
      .runCreate(run: .generate(), spec: try spec("c"), outputLimitBytes: 1 << 20, ttlSeconds: 600))
    #expect(accepted.disposition == .accepted)
  }

  @Test func paramsMustBeEmpty() throws {
    func decode(_ params: String) -> HostControlError.Code? {
      let frame =
        #"{"protocol":"iso.host/v1","request_id":"\#(RequestID.generate())","host_id":"\#(HostID.generate())","owner_id":"\#(String(repeating: "ab", count: 16))","method":"host.capabilities","params":\#(params)}"#
      do {
        _ = try HostRequest.decode(frame: Array(frame.utf8))
        return nil
      } catch {
        switch error {
        case .correlated(_, let failure), .uncorrelated(let failure): return failure.code
        }
      }
    }
    #expect(decode("{}") == nil)
    #expect(decode(#"{"verbose":true}"#) == .invalidRequest)
    #expect(decode("[]") == .invalidRequest)
  }
}
