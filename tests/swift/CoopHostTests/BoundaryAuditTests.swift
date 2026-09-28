import CoopConfiguration
import CoopCore
import Foundation
import Testing

@testable import CoopHost

private func auditInstance() throws -> Instance {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "coop-audit-\(UUID().uuidString)").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  return Instance(
    name: try InstanceName("a"), index: InstanceIndex(1)!, directory: directory,
    image: try ImageName("default"))
}

@Test func auditRecordsMetadataOnlyAndOwnerOnly() throws {
  let instance = try auditInstance()
  defer { try? FileManager.default.removeItem(atPath: instance.directory) }
  let time = Date(timeIntervalSince1970: 1_800_000_000)
  BoundaryAudit.record(
    instance,
    .boot(
      egress: .none, proxyMode: .required, proxied: [.anthropic],
      providerSecrets: ["ANTHROPIC_API_KEY"], guestReferences: 2,
      sessionTTL: try SessionTTL(seconds: 3600)), now: time)
  BoundaryAudit.record(instance, .pullStage(changes: 3, bytes: 42, applicable: true), now: time)
  let lines = try BoundaryAudit.lines(instance)
  #expect(lines.count == 2)
  #expect(
    lines[0]
      == #"{"time":"2027-01-15T08:00:00Z","event":"boot","egress":"none","proxy_mode":"required","proxied":["anthropic"],"provider_secrets":["ANTHROPIC_API_KEY"],"guest_references":2,"session_ttl_seconds":3600}"#
  )
  var info = stat()
  #expect(stat(BoundaryAudit.path(instance), &info) == 0 && info.st_mode & 0o777 == 0o600)
}

@Test func auditLogStaysBounded() throws {
  let instance = try auditInstance()
  defer { try? FileManager.default.removeItem(atPath: instance.directory) }
  for _ in 0..<30_000 { BoundaryAudit.record(instance, .stop) }
  BoundaryAudit.record(instance, .pullApply(applied: 7))
  var info = stat()
  #expect(stat(BoundaryAudit.path(instance), &info) == 0)
  #expect(info.st_size <= BoundaryAudit.maxBytes)
  let lines = try BoundaryAudit.lines(instance)
  // The older half is dropped, whole lines only, and the newest event kept.
  #expect(lines.count > 1000 && lines.count < 30_000)
  #expect(lines.allSatisfy { $0.hasPrefix("{\"time\"") })
  #expect(lines.last?.contains(#""event":"pull_apply","applied":7"#) == true)
}

@Test func concurrentRecordersLoseNoEvents() throws {
  let instance = try auditInstance()
  defer { try? FileManager.default.removeItem(atPath: instance.directory) }
  DispatchQueue.concurrentPerform(iterations: 8) { worker in
    for count in 0..<50 {
      BoundaryAudit.record(instance, .pullApply(applied: worker * 100 + count))
    }
  }
  #expect(try BoundaryAudit.lines(instance).count == 400)
}

@Test func unreadableLogIsNeverReplacedByOneLine() throws {
  let instance = try auditInstance()
  defer { try? FileManager.default.removeItem(atPath: instance.directory) }
  // Over the read cap: rotation cannot read it, so the event is dropped.
  let big = [UInt8](repeating: 0x0A, count: BoundaryAudit.maxBytes * 2 + 1)
  try Data(big).write(to: URL(fileURLWithPath: BoundaryAudit.path(instance)))
  BoundaryAudit.record(instance, .stop)
  var info = stat()
  #expect(stat(BoundaryAudit.path(instance), &info) == 0)
  #expect(Int(info.st_size) == big.count)
}

@Test func suggestedConfigOnlyNarrowsWhatWasObserved() throws {
  // One unproxied boot means "required" would break it: not suggested.
  let mixed: [[String: Any]] = [
    ["event": "boot", "egress": "open", "proxied": ["anthropic"]],
    ["event": "boot", "egress": "open", "proxied": []],
  ]
  #expect(
    BoundaryAudit.suggestConfig(mixed).joined(separator: "\n").contains(
      #"// "proxy": { "mode": "required" }"#))

  let proxiedOnly: [[String: Any]] = [
    ["event": "boot", "egress": "none", "proxied": ["anthropic"]],
    ["event": "pull_stage"],
  ]
  let suggestion = BoundaryAudit.suggestConfig(proxiedOnly).joined(separator: "\n")
  #expect(suggestion.contains(#""proxy": { "mode": "required" }"#))
  #expect(suggestion.contains(#""egress": "none""#) && !suggestion.contains(#"// "egress""#))
  #expect(suggestion.contains(#""mode": "stage""#))
  #expect(suggestion.contains("Advisory only"))
  #expect(BoundaryAudit.suggestConfig(proxiedOnly) == BoundaryAudit.suggestConfig(proxiedOnly))

  let raw: [[String: Any]] = [
    ["event": "boot", "egress": "open", "proxied": []], ["event": "raw_provider_forward"],
    ["event": "future_event_kind", "wide": true],
  ]
  let loose = BoundaryAudit.suggestConfig(raw).joined(separator: "\n")
  #expect(loose.contains(#"// "proxy": { "mode": "required" }"#))
  #expect(loose.contains(#"// "egress": "none""#))
  // Unknown events never widen anything.
  #expect(!loose.contains("open\""))
}

@Test func bootsAndPullsAreRecordedAtTheirCallSites() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let config = try testConfig(
    #""egress": "none", "proxy": {"anthropic": {"credential": "cmd:printf x"}}"#)
  guest.bootstrap(config).recordBoot(instance)
  let boot = try #require(try BoundaryAudit.lines(instance).last)
  #expect(
    boot.contains(#""event":"boot","egress":"none","proxy_mode":"auto","proxied":["anthropic"]"#))
  #expect(!boot.contains("printf"))
}

@Test func dryRunSecuritySummaryShowsThePresetExpansion() throws {
  let config = try testConfig(
    #""security": {"preset": "offline"}, "limits": {"session_ttl": "2h"}"#)
  #expect(
    config.securitySummary.compactRendered()
      == #"{"preset":"offline","egress":"none","proxy_mode":"off","workspace_pull":"stage","session_ttl":"2h"}"#
  )
}
