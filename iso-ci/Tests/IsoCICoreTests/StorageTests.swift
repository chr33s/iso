import Foundation
import Testing

@testable import IsoCICore

@Suite struct ConfigurationTests {
  @Test func templateParsesAndResolves() throws {
    let config = try TestConfig.configuration()
    #expect(config.pools["validation"]?.scope == .repository(try RepositoryName("octo/demo")))
    #expect(config.preflight?.platformMap["ubuntu-latest"] == "linux/arm64")
    #expect(config.poolDigest("validation") != nil)
    #expect(config.descriptors(of: "linux-validation").count == 5)
  }

  @Test(arguments: [
    ("open egress", "egress: filtered", "egress: open"),
    (
      "x86 platform",
      "platform: linux/arm64\n    image: approved-linux-arm64-runner\n    network_policy: approved-ci-public-egress",
      "platform: linux/amd64\n    image: approved-linux-arm64-runner\n    network_policy: approved-ci-public-egress"
    ),
    ("wildcard host", "- github.com", "- '*.github.com'"),
    (
      "missing pool label", "labels: [self-hosted, linux, ARM64, iso-ci]",
      "labels: [self-hosted, linux, ARM64]"
    ),
    ("idle above max", "desired_idle_vms: 1", "desired_idle_vms: 5"),
    ("infinite deadline", "hard_deadline_seconds: 28800", "hard_deadline_seconds: 0"),
    ("unknown key", "retry: fresh-job", "retry: fresh-job\n  continue_failed_steps: true"),
    ("step continuation", "retry: fresh-job", "retry: failed-step"),
    ("unknown profile", "profile: linux-validation", "profile: nope"),
  ])
  func refusesInvalidConfiguration(_ testCase: (String, String, String)) throws {
    let (_, from, to) = testCase
    #expect(TestConfig.yaml.contains(from))
    let edited = TestConfig.yaml.replacingOccurrences(of: from, with: to)
    #expect(throws: CIError.self) { _ = try CIConfiguration.parse(edited) }
  }

  @Test func descriptorDigestsChangeWithContent() throws {
    var config = try TestConfig.configuration()
    let before = config.poolDigest("validation")
    config.limits["operator-approved-ci-limits"]?.cpus = 2
    #expect(config.poolDigest("validation") != before)
  }
}

@Suite struct ControllerStoreTests {
  @Test func eventsAreBoundedAndCursorOrdered() throws {
    let store = try ControllerStore.inMemory(clock: FixedClock(value: 10))
    for index in 0..<5 { try store.event("run:x", "kind", "message \(index)\u{1b}[31m") }
    try store.event("run:y", "kind", "other")
    let page = try store.events(after: 0, subject: "run:x", limit: 3)
    #expect(page.count == 3)
    #expect(page.allSatisfy { !$0.message.contains("\u{1b}") })
    let rest = try store.events(after: page.last!.sequence, subject: "run:x")
    #expect(rest.count == 2)
  }

  @Test func allocationsRoundTripAndSettle() throws {
    let store = try ControllerStore.inMemory()
    var record = AllocationRecord(
      id: .generate(), kind: .preflight, controller: try store.controllerID(), host: "local",
      hostRun: .generate(), operations: HostOperations(create: .generate()),
      provenance: InputProvenance(
        profileDigest: Digest(hashing: "p"), imageReference: "ci-runner", imageDigest: nil,
        expectedRunnerVersion: nil, networkPolicyDigest: nil, qualificationDigest: nil,
        qualificationTuple: [:], compatibilityDigest: nil, limitsDigest: nil,
        platform: "linux/arm64"),
      reservation: .zero, createdAt: 1, hardDeadline: 100)
    try store.insert(record)
    #expect(try store.openAllocations().count == 1)
    record.vmCleanup = .verified
    try store.save(record)
    #expect(try store.openAllocations().isEmpty)
    #expect(try store.allocation(record.id)?.phase == "settled")
  }

  @Test func controllerIdentityIsStable() throws {
    let store = try ControllerStore.inMemory()
    #expect(try store.controllerID() == (try store.controllerID()))
  }
}

@Suite struct ObjectStoreTests {
  static func store() throws -> ObjectStore {
    let directory = scratchDirectory("objects")
    return try ObjectStore(
      database: try Database(path: ":memory:"), objects: directory + "/objects",
      staging: directory + "/staging")
  }

  @Test func uploadsPublishAtomicallyAndNeedGrants() throws {
    let objects = try Self.store()
    let upload = try objects.beginUpload(kind: .artifact, subject: "attempt:a", limit: 64)
    try objects.write(upload, offset: 0, bytes: Array("hello".utf8))
    let (digest, size) = try objects.commit(upload)
    #expect(size == 5)
    #expect(digest == Digest(hashing: "hello"))
    // Knowing the digest is not authorization.
    #expect(throws: CIError.self) {
      _ = try objects.authorizedPath(subject: "attempt:b", kind: .artifact, digest: digest)
    }
    try objects.grant(subject: "attempt:b", kind: .artifact, digest: digest)
    #expect(
      try objects.authorizedPath(subject: "attempt:b", kind: .artifact, digest: digest).hasSuffix(
        digest.rawValue))
  }

  @Test func oversizedAndMismatchedUploadsAreRefused() throws {
    let objects = try Self.store()
    let upload = try objects.beginUpload(kind: .cache, subject: "a", limit: 4)
    #expect(throws: CIError.self) {
      try objects.write(upload, offset: 0, bytes: Array("12345".utf8))
    }
    let other = try objects.beginUpload(kind: .cache, subject: "a", limit: 16)
    try objects.write(other, offset: 0, bytes: Array("abc".utf8))
    #expect(throws: CIError.self) {
      try objects.commit(other, expectedDigest: Digest(hashing: "abd"))
    }
    #expect(try !objects.exists(kind: .cache, digest: Digest(hashing: "abc")))
  }

  @Test func cacheSemanticsWithinOneScope() throws {
    let objects = try Self.store()
    let scope = ObjectStore.CacheScope(
      repository: "octo/demo", authority: "validation", platform: "linux/arm64", imageDigest: "i",
      toolchain: "t", inputDigest: "lock", confinedToRun: nil)
    let other = ObjectStore.CacheScope(
      repository: "octo/other", authority: "validation", platform: "linux/arm64", imageDigest: "i",
      toolchain: "t", inputDigest: "lock", confinedToRun: nil)
    let reserved = try #require(
      try objects.cacheReserve(
        scope: scope, key: "deps-Linux-abc", version: "v1", subject: "a1", limit: 64))
    // A second writer for the same key/version is refused while reserved.
    #expect(
      try objects.cacheReserve(
        scope: scope, key: "deps-Linux-abc", version: "v1", subject: "a2", limit: 64) == nil)
    // Incomplete publication is invisible.
    #expect(try objects.cacheLookup(scope: scope, keys: ["deps-Linux-abc"], version: "v1") == nil)
    try objects.write(reserved.upload, offset: 0, bytes: Array("payload".utf8))
    #expect(throws: CIError.self) {
      _ = try objects.cacheCommit(reservation: reserved.reservation, subject: "a2", expectedSize: 7)
    }
    _ = try objects.cacheCommit(reservation: reserved.reservation, subject: "a1", expectedSize: 7)
    #expect(
      try objects.cacheLookup(scope: scope, keys: ["deps-Linux-abc"], version: "v1")?.key
        == "deps-Linux-abc")
    #expect(try objects.cacheLookup(scope: scope, keys: ["deps-Linux-abc"], version: "v2") == nil)
    #expect(
      try objects.cacheLookup(scope: scope, keys: ["nomatch", "deps-Linux-"], version: "v1") != nil)
    #expect(try objects.cacheLookup(scope: scope, keys: ["deps-linux-"], version: "v1") == nil)
    #expect(try objects.cacheLookup(scope: scope, keys: ["x", "DEPS-"], version: "v1") == nil)
    #expect(try objects.cacheLookup(scope: other, keys: ["deps-Linux-abc"], version: "v1") == nil)
    // First writer wins: no overwrite of a published entry.
    #expect(
      try objects.cacheReserve(
        scope: scope, key: "deps-Linux-abc", version: "v1", subject: "a3", limit: 64) == nil)
  }

  @Test func artifactNamesAndRunScoping() throws {
    let objects = try Self.store()
    for name in ["../x", "a/b", "", "c:d", "x\u{0}"] {
      #expect(throws: CIError.self) {
        _ = try objects.artifactCreate(
          run: "r", attempt: "a", name: name, authority: "validation", limit: 8)
      }
    }
    let created = try objects.artifactCreate(
      run: "r1", attempt: "a1", name: "out", authority: "validation", limit: 8)
    try objects.write(created.upload, offset: 0, bytes: [1, 2, 3])
    #expect(throws: CIError.self) {
      _ = try objects.artifactFinalize(
        id: created.entry.id, attempt: "a2", expectedSize: 3, expectedDigest: nil)
    }
    let final = try objects.artifactFinalize(
      id: created.entry.id, attempt: "a1", expectedSize: 3, expectedDigest: nil)
    #expect(final.finalized)
    #expect(try objects.artifacts(run: "r1").count == 1)
    #expect(try objects.artifacts(run: "r2").isEmpty)
  }
}

@Suite struct ControlChannelTests {
  @Test func roundTripOverAPrivateSocket() throws {
    let directory = "/tmp/iso-ci-t-" + randomHex(bytes: 4)
    let path = directory + "/c.sock"
    let server = ControlServer(path: path) { request in
      request.method == "echo" ? .success(request.params) : .failure(CIError(.unsupported, "nope"))
    }
    try server.start()
    defer {
      server.stop()
      PrivateFiles.removeTree(directory)
    }
    let client = ControlClient(path: path, timeout: 5)
    #expect(try client.call("echo", ["x": 1]) == ["x": 1])
    #expect(throws: CIError.self) { _ = try client.call("other") }
    var status = stat()
    #expect(lstat(path, &status) == 0 && status.st_mode & 0o077 == 0)
  }

  @Test func requestDecodingIsStrict() {
    for frame in [
      #"{"api":"iso-ci.control/v2","request_id":"00000000-0000-4000-8000-000000000000","method":"x","params":{}}"#,
      #"{"api":"iso-ci.control/v1","request_id":"nope","method":"x","params":{}}"#,
      #"{"api":"iso-ci.control/v1","request_id":"00000000-0000-4000-8000-000000000000","method":"x y","params":{}}"#,
      #"{"api":"iso-ci.control/v1","request_id":"00000000-0000-4000-8000-000000000000","method":"x","params":{},"extra":1}"#,
      #"{"api":"iso-ci.control/v1","api":"iso-ci.control/v1","request_id":"00000000-0000-4000-8000-000000000000","method":"x","params":{}}"#,
    ] {
      #expect(throws: CIError.self) { _ = try ControlRequest.decode(Array(frame.utf8)) }
    }
  }
}

@Suite struct StrictJSONTests {
  @Test func refusesDuplicatesDepthAndBadUTF8() {
    #expect(throws: CIError.self) { _ = try StrictJSON.parse(#"{"a":1,"a":2}"#, limits: .control) }
    #expect(throws: CIError.self) {
      _ = try StrictJSON.parse(
        String(repeating: "[", count: 40) + String(repeating: "]", count: 40), limits: .control)
    }
    #expect(throws: CIError.self) {
      _ = try StrictJSON.parse([0x22, 0xFF, 0x22], limits: .control)
    }
    #expect(throws: CIError.self) { _ = try StrictJSON.parse("[1,]", limits: .control) }
  }

  @Test func canonicalEncodingIsStable() throws {
    let value = try StrictJSON.parse(#"{"b":[1,2.5,"x\n"],"a":null}"#, limits: .control)
    #expect(value.canonicalString == #"{"a":null,"b":[1,2.5,"x\n"]}"#)
  }
}
