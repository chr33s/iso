import Foundation
import IsoConfiguration
import Testing

@testable import IsoCore
@testable import IsoHost

@Test func launchPlanReplacesProfilesAndRejectsIncompatibleAdapters() throws {
  let helper = try AgentDefinitionDecoder.decode(
    Array(
      #"{"schema_version":1,"id":"repo-helper","display_name":"h","environment":{"profiles":["node"]},"launch":{"argv":["repo-helper"]},"auth_adapter":"none","network_hints":{"suggested_hosts":["registry.npmjs.org"]}}"#
        .utf8), path: "d.json", format: .json)
  let plan = try AgentLaunchPlanner.plan(
    definition: helper, source: .installed, definitionHash: "sha256:abc", cliImage: nil,
    cliProfiles: ["python", "node"], ask: false)
  #expect(plan.environment.origin == .command)
  #expect(plan.environment.profiles == ["node", "python"])
  #expect(plan.environment.image.rawValue == "node-python")
  #expect(plan.networkHints.map(\.rawValue) == ["registry.npmjs.org"])
  #expect(throws: HostError.self) {
    try AgentLaunchPlanner.plan(
      definition: helper, source: .installed, definitionHash: "h", cliImage: nil, cliProfiles: [],
      ask: true)
  }
  let mismatched = AgentDefinition(
    id: try AgentDefinitionID("other-tool"), displayName: "o", environment: nil,
    launch: AgentLaunchSpec(
      argv: ["other"], workingDirectory: GuestPath("/workspace"), terminal: .auto, environment: []),
    authAdapter: .claude, networkHints: [])
  #expect(throws: HostError.self) {
    try AgentLaunchPlanner.plan(
      definition: mismatched, source: .installed, definitionHash: "h", cliImage: nil,
      cliProfiles: [], ask: false)
  }
}

@Test func dispatchUsesReviewedBinariesAndDoesNotGrantHints() throws {
  let claude = AgentCatalog.builtin(try AgentDefinitionID("claude"))!
  let plan = try AgentLaunchPlanner.plan(
    definition: claude, source: .builtin, definitionHash: AgentCatalog.definitionHash(claude),
    cliImage: nil, cliProfiles: [], ask: true)
  let invocation = try AgentDispatch.invocation(
    plan: plan, passthrough: ["--model", "opus"], guestUser: .default, codexAccount: false,
    stdinIsTerminal: true, stdoutIsTerminal: true)
  #expect(
    invocation.argv == [
      "/home/ubuntu/.local/bin/claude", "--permission-mode", "default", "--model", "opus",
    ])
  #expect(invocation.allocatePTY)
  let generic = try AgentDefinitionDecoder.decode(
    Array(
      #"{"schema_version":1,"id":"repo-helper","display_name":"h","launch":{"argv":["repo-helper","--fixed"],"terminal":"never","environment":{"NO_COLOR":"1"}},"auth_adapter":"none"}"#
        .utf8), path: "d.json", format: .json)
  let genericPlan = try AgentLaunchPlanner.plan(
    definition: generic, source: .installed, definitionHash: "h", cliImage: nil, cliProfiles: [],
    ask: false)
  let genericInvocation = try AgentDispatch.invocation(
    plan: genericPlan, passthrough: ["--help"], guestUser: .default, codexAccount: false,
    stdinIsTerminal: true, stdoutIsTerminal: true)
  #expect(genericInvocation.argv == ["repo-helper", "--fixed", "--help"])
  #expect(!genericInvocation.allocatePTY)
  #expect(genericInvocation.defaults.map(\.name.rawValue) == ["NO_COLOR"])
}

@Test func previewJSONOmitsSecretsAndDoesNotApproveHints() throws {
  let definition = AgentCatalog.builtins[0]
  let plan = try AgentLaunchPlanner.plan(
    definition: definition, source: .builtin, definitionHash: "sha256:abc", cliImage: nil,
    cliProfiles: [], ask: false)
  let preview = RunPreview.make(
    action: .unresolved, instanceName: "dev", match: "workspace", definition: definition,
    source: .builtin, definitionHash: plan.definitionHash, adapter: plan.adapter,
    environment: plan.environment, workingDirectory: plan.workingDirectory, terminal: plan.terminal,
    preparationRequired: false, egress: .none, proxyMode: .required, pullMode: .stage,
    recordedEgress: nil, networkHints: [try ExactHostname("github.com")],
    unresolved: ["runtime state"],
    cleanupIntent: "retain", ask: false, blockedReason: nil)
  let text = preview.json.rendered()
  #expect(text.contains("\"approved_hosts\": []"))
  #expect(text.contains("github.com"))
  #expect(!text.contains("sk-"))
  #expect(!text.contains("cmd:"))
  #expect(text.contains("run_preview"))
}

@Test func catalogInstallUsesTheReviewedValueAndRejectsSymlinks() throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "iso-agent-\(UUID().uuidString)"
  )
  .path
  defer { try? FileManager.default.removeItem(atPath: root) }
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  let config = try agentConfig(root)
  let source = root + "/repo-helper.json"
  let text = """
    {"schema_version":1,"id":"repo-helper","display_name":"Helper","launch":{"argv":["repo-helper"]},"auth_adapter":"none"}
    """
  try Data(text.utf8).write(to: URL(fileURLWithPath: source))
  let (definition, _) = try AgentCatalog.review(sourcePath: source)
  try Data("tampered".utf8).write(to: URL(fileURLWithPath: source))
  let installed = try AgentCatalog.install(definition, config: config, replace: false)
  let stored = try String(contentsOfFile: installed.path, encoding: .utf8)
  #expect(stored.contains("repo-helper"))
  #expect(!stored.contains("tampered"))
  #expect(throws: HostError.self) {
    try AgentCatalog.install(definition, config: config, replace: false)
  }
  let link = root + "/link.json"
  symlink(source, link)
  #expect(throws: HostError.self) { try AgentCatalog.readSource(link) }
  let reserved = root + "/claude.json"
  try Data(
    #"{"schema_version":1,"id":"claude","display_name":"x","launch":{"argv":["claude"]},"auth_adapter":"claude"}"#
      .utf8
  ).write(to: URL(fileURLWithPath: reserved))
  #expect(throws: HostError.self) { try AgentCatalog.review(sourcePath: reserved) }
}

private func handoffFailure(
  filtered: Bool = true, recordedBootID: String? = "boot", liveBootID: String? = "boot",
  ownerLockHeld: Bool = true, companionAlive: Bool = true, tunnelAlive: Bool = true,
  advertisedProtocol: UInt32 = 5, recordedPolicyHash: String? = "hash",
  wantedPolicyHash: String = "hash", ownerMatches: Bool = true
) -> FilteredHandoff.Failure? {
  FilteredHandoff.prove(
    filtered: filtered, recordedBootID: recordedBootID, liveBootID: liveBootID,
    ownerLockHeld: ownerLockHeld, companionAlive: companionAlive, tunnelAlive: tunnelAlive,
    advertisedProtocol: advertisedProtocol, recordedPolicyHash: recordedPolicyHash,
    wantedPolicyHash: wantedPolicyHash, ownerMatches: ownerMatches)
}

@Test func filteredHandoffRefusesAChangedBoot() {
  #expect(handoffFailure() == nil)
  #expect(handoffFailure(liveBootID: "other") == .bootChanged)
  #expect(handoffFailure(recordedBootID: nil) == .missingBoot)
  #expect(handoffFailure(recordedBootID: "") == .missingBoot)
  #expect(handoffFailure(companionAlive: false) == .companionDown)
  #expect(handoffFailure(tunnelAlive: false) == .tunnelDown)
  #expect(handoffFailure(ownerLockHeld: false) == .ownerDown)
}

@Test func filteredHandoffBindsProtocolPolicyAndOwner() {
  #expect(handoffFailure() == nil)
  for version: UInt32 in [0, 4, 6] {
    #expect(handoffFailure(advertisedProtocol: version) == .runtimeIncompatible)
  }
  #expect(handoffFailure(recordedPolicyHash: nil) == .policyChanged)
  #expect(handoffFailure(recordedPolicyHash: "other") == .policyChanged)
  #expect(handoffFailure(recordedPolicyHash: "", wantedPolicyHash: "") == .policyChanged)
  #expect(handoffFailure(ownerMatches: false) == .ownerChanged)
  #expect(
    handoffFailure(
      filtered: false, recordedBootID: nil, liveBootID: nil, ownerLockHeld: false,
      companionAlive: false, tunnelAlive: false, advertisedProtocol: 4,
      recordedPolicyHash: nil, ownerMatches: false) == nil)
}

@Test func egressLeaseRequiresTheOwnerLock() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let lock = directory.appending(path: "owner.lock")
  FileManager.default.createFile(atPath: lock.path, contents: nil)
  #expect(EgressLease.ownerLockHeld(at: lock.path) == false)
  #expect(
    EgressLease.ownerLockHeld(at: directory.appending(path: "missing.lock").path) == false)
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  child.arguments = [
    "-c",
    "import fcntl,time,sys; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(5)",
    lock.path,
  ]
  try child.run()
  defer { child.terminate() }
  let deadline = Date().addingTimeInterval(2)
  var held = false
  while Date() < deadline {
    if EgressLease.ownerLockHeld(at: lock.path) {
      held = true
      break
    }
    usleep(20_000)
  }
  #expect(held)
}

@Test func egressLeaseClosesAtTheSessionDeadline() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-lease-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let record = directory.appending(path: "record.json")
  try Data(#"{"expiresAt":"2020-01-01T00:00:00Z"}"#.utf8).write(to: record)
  #expect(EgressLease.sessionOpen(recordPath: record.path, now: Date()) == false)
  try Data("{}".utf8).write(to: record)
  #expect(EgressLease.sessionOpen(recordPath: record.path, now: Date()))
  #expect(
    EgressLease.sessionOpen(
      recordPath: directory.appending(path: "missing.json").path, now: Date()) == false)
}

@Test(arguments: [
  "0", "-1", "2147483648", "-2147483649", "9223372036854775807",
  "18446744073709551615", "1.5", "true", "false", "null", #""7""#,
])
func egressLeaseRejectsInvalidOwnerPIDs(pidJSON: String) throws {
  let root = try scratchDirectory("lease-pid")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/live.json"
  try writeFile(path, #"{"bootId":"boot","pid":\#(pidJSON)}"#)
  #expect(EgressLease.liveIdentity(at: path) == nil)
}

@Test func egressLeaseDecodesOnlyValidLiveIdentities() throws {
  let root = try scratchDirectory("lease-live")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/live.json"
  for pid in [Int32(1), Int32.max] {
    try writeFile(path, #"{"bootId":"boot","pid":\#(pid),"unused":true}"#)
    let identity = try #require(EgressLease.liveIdentity(at: path))
    #expect(identity.bootID == "boot")
    #expect(identity.pid == pid)
  }
  for text in [
    "{}", "[]", "not-json", #"{"bootId":"","pid":7}"#,
    #"{"bootId":true,"pid":7}"#, #"{"pid":7}"#, #"{"bootId":"boot"}"#,
  ] {
    try writeFile(path, text)
    #expect(EgressLease.liveIdentity(at: path) == nil)
  }
  #expect(EgressLease.liveIdentity(at: root + "/missing.json") == nil)
}

@Test(arguments: ["7", "false", "true", "[]", "{}", #""invalid-date""#])
func egressLeaseRejectsMalformedSessionDeadlines(deadlineJSON: String) throws {
  let root = try scratchDirectory("lease-deadline")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/record.json"
  try writeFile(path, #"{"expiresAt":\#(deadlineJSON)}"#)
  #expect(!EgressLease.sessionOpen(recordPath: path, now: Date()))
}

@Test func egressLeaseAcceptsOnlyOpenNativeSessionRecords() throws {
  let root = try scratchDirectory("lease-native-record")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/record.json"
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  for text in ["{}", #"{"expiresAt":null,"other":"ignored"}"#] {
    try writeFile(path, text)
    #expect(EgressLease.sessionOpen(recordPath: path, now: now))
  }
  for offset in [-1.0, 0.0, 1.0] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(["expiresAt": now.addingTimeInterval(offset)])
    try data.write(to: URL(fileURLWithPath: path))
    #expect(EgressLease.sessionOpen(recordPath: path, now: now) == (offset > 0))
  }
  for text in ["[]", "null", "not-json"] {
    try writeFile(path, text)
    #expect(!EgressLease.sessionOpen(recordPath: path, now: now))
  }
}

@Test func egressLeaseDoesNotMistakeLockProbeErrorsForContention() throws {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(fd >= 0)
  guard fd >= 0 else { return }
  defer { close(fd) }
  let path = "/dev/fd/\(fd)"
  let probe = open(path, O_RDWR | O_CLOEXEC)
  #expect(probe >= 0)
  guard probe >= 0 else { return }
  defer { close(probe) }
  #expect(flock(probe, LOCK_EX | LOCK_NB) == -1)
  #expect(errno == ENOTSUP)
  #expect(!EgressLease.ownerLockHeld(at: path))
}

@Test func egressLeaseControlFilesAreBoundedRegularFilesWithoutSymlinks() throws {
  let root = try scratchDirectory("lease-controls")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let live = root + "/live.json"
  let record = root + "/record.json"
  try writeFile(live, #"{"bootId":"boot","pid":7}"#)
  try writeFile(record, "{}")
  #expect(EgressLease.liveIdentity(at: live)?.pid == 7)
  #expect(EgressLease.sessionOpen(recordPath: record, now: Date()))
  try FileManager.default.createSymbolicLink(atPath: root + "/live-link", withDestinationPath: live)
  try FileManager.default.createSymbolicLink(
    atPath: root + "/record-link", withDestinationPath: record)
  #expect(EgressLease.liveIdentity(at: root + "/live-link") == nil)
  #expect(!EgressLease.sessionOpen(recordPath: root + "/record-link", now: Date()))
  let prefix = String(repeating: " ", count: 1 << 20)
  try writeFile(live, prefix + #"{"bootId":"boot","pid":7}"#)
  try writeFile(record, prefix + "{}")
  #expect(EgressLease.liveIdentity(at: live) == nil)
  #expect(!EgressLease.sessionOpen(recordPath: record, now: Date()))
  #expect(EgressLease.liveIdentity(at: root) == nil)
  #expect(!EgressLease.sessionOpen(recordPath: root, now: Date()))
}

@Test func egressLeaseStopsWhenTheRecordedOwnerChanges() {
  #expect(
    EgressLease.stillOwns(directory: "/no/such/instance", machineID: "missing", ownerPID: 1)
      == false)
  #expect(
    EgressLease.renewalAllowed(
      ownsRecordedIdentity: true, liveBootID: "previous", expectedBootID: "current", livePID: 7,
      expectedPID: 7, sessionOpen: true, ownerAlive: true) == false)
  #expect(
    EgressLease.renewalAllowed(
      ownsRecordedIdentity: true, liveBootID: "current", expectedBootID: "current", livePID: 7,
      expectedPID: 7, sessionOpen: true, ownerAlive: true))
  #expect(
    EgressLease.renewalAllowed(
      ownsRecordedIdentity: true, liveBootID: "current", expectedBootID: "current", livePID: 7,
      expectedPID: 7, sessionOpen: false, ownerAlive: true) == false)
  #expect(
    EgressLease.renewalAllowed(
      ownsRecordedIdentity: true, liveBootID: "current", expectedBootID: "current", livePID: 7,
      expectedPID: 7, sessionOpen: true, ownerAlive: false) == false)
}

@Test func disposableMarkerIsNotAnAffinityCandidateAndCleanupRequiresProof() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "iso-run-\(UUID().uuidString)")
    .path
  defer { try? FileManager.default.removeItem(atPath: root) }
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  let config = try agentConfig(root)
  let owner = Owner(
    schemaVersion: StateSchema.ownerVersion, backend: StateSchema.backend,
    ownerID: try OwnerID(String(repeating: "ab", count: 16)))
  try StateStore.ensurePrivateDirectory(config.stateRoot.path)
  try StateStore.writeControlFile(owner, to: Owner.path(config))
  let instance = try Instance.allocate(
    config, name: try InstanceName("scratch"), image: .default, workspacePath: nil)
  let session = try RunSessionStore.create(
    config, name: instance.name, workspace: "/tmp/proj", owner: owner)
  try RunSessionStore.writeMarker(instance, session)
  #expect(InstanceAffinity.eligibility(instance) == .disposable)
  var finished = session
  finished.state = .cleanupPending
  let decision = try RunSessionStore.reconcile(config, session: finished, dryRun: true)
  guard case .leave(let message) = decision else {
    Issue.record("expected a dry-run leave, got \(decision)")
    return
  }
  #expect(message.contains("would destroy"))
  var foreign = finished
  foreign.ownerID = try OwnerID(String(repeating: "cd", count: 16))
  #expect(throws: HostError.self) {
    try RunSessionStore.reconcile(config, session: foreign, dryRun: true)
  }
}

private func agentConfig(_ root: String) throws -> IsoConfig {
  let value = try ConfigLoader.parse(
    Array("{\"data_dir\": \"\(root)\"}".utf8), format: .json, path: "c", limits: .configuration)
  return try ConfigLoader.decode(value, path: "c", environment: .empty)
}
