import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

private enum AdministrativeOperation: CaseIterable, Sendable {
  case execTarget, execSession, inputTarget, inputSession, capture, checkedCapture, succeeds, copy
  case wait, tarPush, tarPull, rsyncPush, rsyncPull, dirtyCheck, hook, alias, editor, forward,
    rsyncProbe

  func perform(_ guest: FakeGuest, _ target: SSHTarget) throws {
    let session = SSHSession(target: target)
    let command = RemoteCommand().literal("query")
    let transfer = WorkspaceTransfer(client: guest.client, diagnostics: guest.sink.diagnostics)
    switch self {
    case .execTarget: try guest.client.exec(target, command)
    case .execSession: try guest.client.exec(session, command)
    case .inputTarget: try guest.client.exec(target, command, stdin: Array("fixture".utf8))
    case .inputSession: try guest.client.exec(session, command, stdin: Array("fixture".utf8))
    case .capture:
      guard guest.client.capture(target, "query") == "fixture-output\n" else {
        throw HostError("capture refused")
      }
    case .checkedCapture:
      #expect(try guest.client.captureChecked(target, command) == "fixture-output\n")
    case .succeeds:
      guard guest.client.succeeds(target, command) else { throw HostError("probe refused") }
    case .copy:
      try guest.client.copy(target, local: guest.root + "/source", remote: GuestPath("./copy"))
    case .wait:
      try guest.client.waitUntilReady(
        target, timeout: .milliseconds(100), diagnostics: guest.sink.diagnostics)
    case .rsyncProbe: #expect(try transfer.guestHasRsync(target))
    case .tarPush:
      try transfer.tarPipe(target, source: guest.root, to: guestWorkspace, excludeGit: false)
    case .tarPull:
      try transfer.tarPull(target, guest: guestWorkspace, to: guest.root, excludeGit: false)
    case .rsyncPush:
      try transfer.rsyncPush(target, source: guest.root, to: guestWorkspace, excludeGit: false)
    case .rsyncPull:
      try transfer.rsyncPull(target, guest: guestWorkspace, to: guest.root, excludeGit: false)
    case .dirtyCheck: try transfer.checkGuestClean(target, guestWorkspace)
    case .hook: try guest.bootstrap(testConfig()).runPostStart(session, command: "query")
    case .alias:
      try SSHConfigFile(path: guest.root + "/alias", diagnostics: guest.sink.diagnostics).update(
        target, testInstance(guest.root + "/instance"))
    case .forward:
      try PortForwards(client: guest.client, diagnostics: guest.sink.diagnostics).spawn(
        testInstance(guest.root), target, [PortForward(guest: 12345, host: 12346)])
    case .editor:
      let base = try workloadRunning(guest, identity: nil)
      let running = AppleBackend.Running(
        instance: base.instance, sidecar: base.sidecar, ready: base.ready, target: target,
        handoffIdentity: nil)
      try EditorLauncher(environment: guest.environment, diagnostics: guest.sink.diagnostics)
        .launch(
          running, SSHConnectionTarget(running, guestPath: guestWorkspace, egress: .open),
          choice: .only(VSCodeEditorProvider()))
    }
  }
}

@Test(arguments: AdministrativeOperation.allCases)
private func administrativeHandoffsRefuseLateInvalidation(operation: AdministrativeOperation) throws
{
  let guest = try FakeGuest()
  defer { guest.remove() }
  let marker = guest.root + "/spawned"
  for tool in ["ssh", "scp", "rsync", "tar", "code"] {
    try writeFile(
      guest.root + "/bin/" + tool,
      """
      #!/bin/sh
      case "$*" in *'-O exit'*) exit 0 ;; esac
      printf '%s\\n' '\(tool)' >> '\(marker)'
      case "$*" in
        'xf -'*|*'tar xf -'*) cat >/dev/null ;;
        'cf -'*|*'tar cf -'*) printf 'archive-fixture' ;;
        *query*) printf 'fixture-output\\n' ;;
      esac
      exit 0
      """, mode: 0o755)
  }
  let state = Mutex((healthy: true, checks: 0))
  let target = guest.target.validating {
    let allowed = state.withLock { value in
      value.checks += 1
      return value.healthy
    }
    guard allowed else { throw HostError("test administrative readiness revoked") }
  }
  try operation.perform(guest, target)
  #expect(state.withLock { $0.checks } >= 1)
  if operation == .alias {
    #expect(readFile(guest.root + "/alias")?.contains(target.host) == true)
    try FileManager.default.removeItem(atPath: guest.root + "/alias")
  } else {
    #expect(readFile(marker)?.isEmpty == false)
    try FileManager.default.removeItem(atPath: marker)
  }
  let previous = state.withLock { value in
    value.healthy = false
    return value.checks
  }
  #expect(throws: (any Error).self) { try operation.perform(guest, target) }
  #expect(state.withLock { $0.checks } == previous + 1)
  #expect(!FileManager.default.fileExists(atPath: marker))
  #expect(!FileManager.default.fileExists(atPath: guest.root + "/alias"))
}

@Test(arguments: [1, 2, 3])
func reverseForwardRechecksBeforeMasterAndRequestAndCleansOnRefusal(revokeAt: Int) throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let marker = guest.root + "/reverse-starts"
  let masterPID = guest.root + "/reverse-master.pid"
  // The shim is a shell, not SSH: production identity checks correctly refuse
  // to signal it. The fixture owns and reaps its child instead.
  defer {
    if let pid = readFile(masterPID).flatMap({
      Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }) {
      var status: Int32 = 0
      var observed = waitpid(pid, &status, WNOHANG)
      while observed < 0 && errno == EINTR { observed = waitpid(pid, &status, WNOHANG) }
      if observed == 0 {
        _ = Darwin.kill(-pid, SIGKILL)
        _ = Darwin.kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      }
    }
  }
  try writeFile(
    guest.root + "/bin/ssh",
    """
    #!/bin/sh
    master=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -N) master=1 ;; -S) shift; control="$1" ;; esac
      shift
    done
    if [ "$master" = 1 ]; then
      printf '%s\\n' "$$" > '\(masterPID)'
      printf 'master\\n' >> '\(marker)'
      /usr/bin/touch "$control"
      trap 'exit 0' TERM
      while :; do /bin/sleep .02; done
    else
      printf 'request\\n' >> '\(marker)'
    fi
    """, mode: 0o755)
  let checks = Mutex(0)
  let target = guest.target.validating {
    let count = checks.withLock {
      $0 += 1
      return $0
    }
    guard count < revokeAt else { throw HostError("reverse forward revoked") }
  }
  let proxies = ProxyLauncher(
    environment: guest.environment,
    resolver: CredentialResolver(environment: guest.environment),
    diagnostics: guest.sink.diagnostics, isoExecutable: nil,
    sandboxExec: "/usr/bin/sandbox-exec", controlRoot: guest.root)
  let instance = try testInstance(guest.root)
  if revokeAt < 3 {
    #expect(throws: (any Error).self) {
      try proxies.spawnReverseForward(
        instance, name: "openai", target: target, guestPort: 12345,
        hostAddress: IPv4Address("127.0.0.1"), hostPort: 12346)
    }
    #expect(
      !FileManager.default.fileExists(atPath: ProxyLauncher.forwardPIDPath(instance, "openai")))
    #expect(!(readFile(marker) ?? "").contains("request"))
    if revokeAt == 2,
      let pid = readFile(masterPID).flatMap({
        Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
      })
    {
      #expect(Darwin.kill(pid, 0) != 0)
    }
    if revokeAt == 1 { #expect(!FileManager.default.fileExists(atPath: marker)) }
  } else {
    defer { proxies.stop(instance, provider: .openai) }
    try proxies.spawnReverseForward(
      instance, name: "openai", target: target, guestPort: 12345,
      hostAddress: IPv4Address("127.0.0.1"), hostPort: 12346)
    #expect(readFile(marker) == "master\nrequest\n")
    #expect(
      FileManager.default.fileExists(atPath: ProxyLauncher.forwardPIDPath(instance, "openai")))
  }
  #expect(checks.withLock { $0 } == min(revokeAt, 2))
}

@Test func administrativeTargetsRetainOriginalIdentityAndNonfilteredCompatibility() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let policy = FilteredHandoff.BootPolicy(
    bootID: String(repeating: "a", count: 32),
    policyHash: "sha256:" + String(repeating: "b", count: 64))
  let identity = WorkloadHandoff.Identity(
    policy: policy, egressKey: "verified-egress", brokerKeys: [.openai: "verified-broker"])
  let original = try workloadRunning(guest, identity: identity)
  let replacement = try workloadRunning(guest, identity: identity, pid: 81565)
  let live = Mutex<AppleBackend.Running?>(original)
  let checked = WorkloadHandoff.bind(original) { live.withLock { $0 } }
  #expect(checked == original.target)
  try checked.requireHandoff()
  live.withLock { $0 = replacement }
  #expect(throws: GuestHandoffFailure.self) { try checked.requireHandoff() }
  live.withLock { $0 = nil }
  #expect(throws: GuestHandoffFailure.self) { try checked.requireHandoff() }
  let nonfiltered = try workloadRunning(guest, identity: nil)
  let compatible = WorkloadHandoff.bind(nonfiltered) {
    throw HostError("must not inspect nonfiltered")
  }
  try compatible.requireHandoff()
}

@Test func postStartStillWarnsOnGuestFailureButPropagatesReadinessFailure() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  try writeFile(guest.root + "/bin/ssh", "#!/bin/sh\nexit 1\n", mode: 0o755)
  let agents = try guest.bootstrap(testConfig())
  try agents.runPostStart(SSHSession(target: guest.target), command: "false")
  #expect(guest.sink.text.contains("post_start hook failed (continuing)"))
  let revoked = guest.target.validating { throw HostError("test hook handoff revoked") }
  #expect(throws: GuestHandoffFailure.self) {
    try agents.runPostStart(SSHSession(target: revoked), command: "false")
  }
}

@Test func administrativePreparationRejectsInvalidatedTarget() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let base = try workloadRunning(guest, identity: nil)
  let target = base.target.validating { throw HostError("changed during preparation") }
  let running = AppleBackend.Running(
    instance: base.instance, sidecar: base.sidecar, ready: base.ready, target: target,
    handoffIdentity: nil)
  #expect(throws: GuestHandoffFailure.self) {
    _ = try guest.bootstrap(testConfig()).session(for: running)
  }
  #expect(guest.log("commands.log").isEmpty)
}

@Test(arguments: ["unchanged", "owner", "target", "boot", "policy", "egress", "missing"])
func bootstrapCompletionRetainsOriginalTransportIdentity(change: String) throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let policy = FilteredHandoff.BootPolicy(
    bootID: String(repeating: "a", count: 32),
    policyHash: "sha256:" + String(repeating: "b", count: 64))
  let original = try workloadRunning(
    guest, identity: .init(policy: policy, egressKey: "original-egress", brokerKeys: [:]))
  let currentPolicy = FilteredHandoff.BootPolicy(
    bootID: change == "boot" ? String(repeating: "c", count: 32) : policy.bootID,
    policyHash: change == "policy"
      ? "sha256:" + String(repeating: "d", count: 64) : policy.policyHash)
  let current = try workloadRunning(
    guest,
    identity: change == "missing"
      ? nil
      : .init(
        policy: currentPolicy,
        egressKey: change == "egress" ? "replacement-egress" : "original-egress",
        brokerKeys: [.openai: "newly-verified-broker"]), pid: change == "owner" ? 81565 : 81564,
    host: change == "target" ? "10.231.2.3" : "10.231.2.2")
  if change == "unchanged" {
    try WorkloadHandoff.requireTransport(original, current)
    #expect(current.handoffIdentity?.brokerKeys[.openai] == "newly-verified-broker")
  } else {
    #expect(throws: (any Error).self) { try WorkloadHandoff.requireTransport(original, current) }
  }
  let nonfiltered = try workloadRunning(guest, identity: nil)
  try WorkloadHandoff.requireTransport(nonfiltered, current)
}

@Test func bootstrapProofDoesNotDemandFutureBrokersButCompositeProofDoes() throws {
  let transport = try AppleBackend.HandoffProof.transport.brokerKeys {
    throw HostError("future brokers unavailable")
  }
  #expect(transport.isEmpty)
  var calls = 0
  let composite = AppleBackend.HandoffProof.composite.brokerKeys {
    calls += 1
    return [.openai: "actually-verified-key"]
  }
  #expect(composite == [.openai: "actually-verified-key"])
  #expect(calls == 1)
  #expect(throws: HostError("required broker unavailable")) {
    _ = try AppleBackend.HandoffProof.composite.brokerKeys {
      throw HostError("required broker unavailable")
    }
  }
}

@Test(arguments: [AgentUpdate.Agent.claude, .codex])
func agentUpdatePreservesReadinessFailuresInsteadOfReportingUnknownOrContinuing(
  agent: AgentUpdate.Agent
) throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let revoked = guest.target.validating { throw HostError("agent check readiness revoked") }
  var lookups = 0
  #expect(throws: GuestHandoffFailure.self) {
    _ = try AgentUpdate.check(
      guest.client, SSHSession(target: revoked), .init(claude: false, codex: true),
      latestCodexTag: {
        lookups += 1
        return "v1.0.0"
      }, diagnostics: guest.sink.diagnostics)
  }
  #expect(lookups == 0)
  let state = Mutex(0)
  let late = guest.target.validating {
    let count = state.withLock {
      $0 += 1
      return $0
    }
    guard count == 1 else { throw HostError("agent update readiness revoked") }
  }
  var lines: [String] = []
  #expect(throws: GuestHandoffFailure.self) {
    try AgentUpdate.run(
      guest.client, SSHSession(target: late),
      .init(claude: agent == .claude, codex: agent == .codex)
    ) {
      lines.append($0)
    }
  }
  #expect(lines.isEmpty)
  #expect(state.withLock { $0 } == 2)
}
