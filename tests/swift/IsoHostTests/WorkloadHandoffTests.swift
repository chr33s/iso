import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

private enum WorkloadLaunch: CaseIterable, Sendable {
  case shell, command, exec, reporting

  func launch(_ guest: FakeGuest, _ session: WorkloadSession) throws {
    switch self {
    case .shell:
      try InteractiveSSH.run(guest.client, session, [], diagnostics: guest.sink.diagnostics)
    case .command:
      try InteractiveSSH.runCommand(
        guest.client, session, ["true"], diagnostics: guest.sink.diagnostics)
    case .exec:
      try InteractiveSSH.exec(guest.client, session, ["true"], diagnostics: guest.sink.diagnostics)
    case .reporting:
      let result = try InteractiveSSH.runReporting(
        guest.client, session, ["true"], workingDirectory: GuestPath("/workspace"),
        allocatePTY: false, diagnostics: guest.sink.diagnostics)
      #expect(result.succeeded)
    }
  }
}

@Test(arguments: WorkloadLaunch.allCases)
private func workloadLaunchRechecksImmediatelyBeforeSpawning(launch: WorkloadLaunch) throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let marker = guest.root + "/launched"
  try writeFile(
    guest.root + "/bin/ssh", "#!/bin/sh\nprintf '%s' \"$GUEST_VAR\" > '\(marker)'\n", mode: 0o755)
  let state = Mutex((healthy: true, checks: 0))
  var session = try WorkloadSession(session: SSHSession(target: guest.target)) {
    let healthy = state.withLock { value in
      value.checks += 1
      return value.healthy
    }
    guard healthy else { throw HostError("test readiness revoked") }
  }
  #expect(state.withLock { $0.checks } == 1)
  session.env.set("GUEST_VAR", Secret("intentionally-forwarded"))
  try launch.launch(guest, session)
  #expect(readFile(marker) == "intentionally-forwarded")
  #expect(state.withLock { $0.checks } == 2)
  try FileManager.default.removeItem(atPath: marker)
  state.withLock { $0.healthy = false }
  #expect(throws: HostError("test readiness revoked")) { try launch.launch(guest, session) }
  #expect(state.withLock { $0.checks } == 3)
  #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func workloadConstructionRefusesPreparationInvalidatedReadiness() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let healthy = Mutex(true)
  let prepared = SSHSession(target: guest.target)
  // Represents a lifecycle change while resolving the prepared environment.
  healthy.withLock { $0 = false }
  #expect(throws: HostError("test changed during preparation")) {
    _ = try WorkloadSession(session: prepared) {
      guard healthy.withLock({ $0 }) else { throw HostError("test changed during preparation") }
    }
  }
  #expect(guest.log("commands.log").isEmpty)
}

func workloadRunning(
  _ guest: FakeGuest, identity: WorkloadHandoff.Identity?, pid: Int32 = 81564,
  host: String = "10.231.2.2"
) throws -> AppleBackend.Running {
  let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../fixtures/iso-sandbox").standardized
  let bytes = try Data(contentsOf: fixtures.appending(path: "inspect-running.json"))
  let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(
    of: "81564", with: String(pid))
  let inspection = try StateStore.decode(SandboxInspection.self, Array(text.utf8), path: "fixture")
  let machine = try MachineName("iso-0a1b2c3d-00112233445566ff")
  let owner = try OwnerID("0a1b2c3d00112233445566778899aabb")
  let ready = try IsolationGate.verifyEffective(
    inspection,
    .init(
      sandbox: machine, owner: owner,
      runtimeRoot: "/Users/me/.iso/backends/apple-container-v1/runtime",
      resources: Resources(cpus: 2, memoryBytes: 2_147_483_648), egress: .open))
  let sidecar = try StateStore.decode(
    MachineSidecar.self,
    Array(
      #"""
      {"schema_version":2,"backend":"apple-container","owner_id":"0a1b2c3d00112233445566778899aabb",
       "machine_id":"iso-0a1b2c3d-00112233445566ff","image_ref":"iso-image/default:1",
       "image_digest":"sha256:\#(String(repeating: "b", count: 64))","image_manifest_id":"m1",
       "guest_user":"ubuntu","requested_cpus":2,"requested_memory_bytes":2147483648,
       "host_key_fingerprint":"SHA256:synthetic","last_observed_owner_pid":81564,
       "last_observed_ip":"10.231.2.2","reenroll_host_key":false,
       "created_at":"2026-09-27T00:00:00Z","runtime_identity":"fixture","lifecycle":"reusable"}
      """#.utf8), path: "fixture")
  return AppleBackend.Running(
    instance: try testInstance(guest.root + "/instance"), sidecar: sidecar, ready: ready,
    target: SSHTarget(
      host: host, port: 22, user: .default, keyPath: guest.target.keyPath,
      knownHosts: guest.target.knownHosts, alias: guest.target.alias), handoffIdentity: identity)
}

@Test(arguments: [
  "healthy", "stopped", "unhealthy", "owner", "target", "boot", "policy", "egress-key",
  "broker-key", "providers", "missing-identity",
])
func workloadHandoffRequiresFreshUnchangedIdentity(change: String) throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let policy = FilteredHandoff.BootPolicy(
    bootID: String(repeating: "a", count: 32),
    policyHash: "sha256:" + String(repeating: "b", count: 64))
  let identity = WorkloadHandoff.Identity(
    policy: policy, egressKey: "verified-egress-key",
    brokerKeys: [.anthropic: "verified-anthropic-key", .openai: "verified-openai-key"])
  let expected = try workloadRunning(guest, identity: identity)
  let changed = WorkloadHandoff.Identity(
    policy: FilteredHandoff.BootPolicy(
      bootID: change == "boot" ? String(repeating: "c", count: 32) : policy.bootID,
      policyHash: change == "policy"
        ? "sha256:" + String(repeating: "d", count: 64) : policy.policyHash),
    egressKey: change == "egress-key" ? "replacement-egress-key" : identity.egressKey,
    brokerKeys: change == "providers"
      ? [.anthropic: "verified-anthropic-key"]
      : [
        .anthropic: change == "broker-key" ? "replacement-anthropic-key" : "verified-anthropic-key",
        .openai: "verified-openai-key",
      ])
  let current = try workloadRunning(
    guest, identity: change == "missing-identity" ? nil : changed,
    pid: change == "owner" ? 81565 : 81564,
    host: change == "target" ? "10.231.2.3" : "10.231.2.2")
  var inspections = 0
  func inspect() throws -> AppleBackend.Running? {
    inspections += 1
    if change == "unhealthy" { throw HostError("test authenticated probe failed") }
    return change == "stopped" ? nil : current
  }
  if change == "healthy" {
    try WorkloadHandoff.require(expected, inspect: inspect)
  } else {
    #expect(throws: (any Error).self) { try WorkloadHandoff.require(expected, inspect: inspect) }
  }
  #expect(inspections == 1)
}

@Test func workloadHandoffPreservesNonfilteredCompatibility() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let running = try workloadRunning(guest, identity: nil)
  try WorkloadHandoff.require(running) {
    throw HostError("nonfiltered compatibility should not re-probe")
  }
}
