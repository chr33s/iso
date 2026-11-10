import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private func auditInstance() throws -> Instance {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "iso-audit-\(UUID().uuidString)").path
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
    try canonicalJSON(lines[0])
      == canonicalJSON(
        #"{"time":"2027-01-15T08:00:00Z","event":"boot","egress":"none","proxy_mode":"required","proxied":["anthropic"],"provider_secrets":["ANTHROPIC_API_KEY"],"guest_references":2,"session_ttl_seconds":3600}"#
      ))
  var info = stat()
  #expect(stat(BoundaryAudit.path(instance), &info) == 0 && info.st_mode & 0o777 == 0o600)
}

@Test func guestComputerUseIsAuditedAsCountsWithKnownCodesOnly() throws {
  let instance = try auditInstance()
  defer { try? FileManager.default.removeItem(atPath: instance.directory) }
  let json = #"""
    {"frameRate":4,"sessions":2,"frames":30,"actions":12,"statusRequests":1,"waits":5,
     "waitOutcomes":{"settled":4,"timedOut":1,"other":2},"preemptions":1,
     "refusals":{"held_by_host":3,"rate_limited":1,"Bad Code!":9}}
    """#
  let counts = try JSONDecoder().decode(MacGuestCUCounts.self, from: Data(json.utf8))
  #expect(counts.refusals == ["held_by_host": 3, "rate_limited": 1])
  #expect(counts.waitOutcomes == ["settled": 4, "timedOut": 1])
  let time = Date(timeIntervalSince1970: 1_800_000_000)
  BoundaryAudit.record(instance, .guestComputerUse(counts), now: time)
  #expect(
    try canonicalJSON(try BoundaryAudit.lines(instance)[0])
      == canonicalJSON(
        #"{"time":"2027-01-15T08:00:00Z","event":"guest_computer_use","frame_rate":4,"sessions":2,"frames":30,"actions":12,"status_requests":1,"waits":5,"wait_outcomes":{"settled":4,"timedOut":1},"preemptions":1,"refusals":{"held_by_host":3,"rate_limited":1}}"#
      ))
  #expect(BoundaryAudit.Event.guestComputerUse(counts).auditKind == .boundaryGuestComputerUse)
  // A negative count is refused at decode, never trapped on when recorded.
  let negative = json.replacingOccurrences(of: #""frames":30"#, with: #""frames":-1"#)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(MacGuestCUCounts.self, from: Data(negative.utf8))
  }
  let negativeWaits = json.replacingOccurrences(of: #""waits":5"#, with: #""waits":-5"#)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(MacGuestCUCounts.self, from: Data(negativeWaits.utf8))
  }
  // An owner from before screen sync reports no waits.
  let older = #"""
    {"frameRate":4,"sessions":2,"frames":30,"actions":12,"statusRequests":1,"preemptions":1,
     "refusals":{}}
    """#
  let previous = try JSONDecoder().decode(MacGuestCUCounts.self, from: Data(older.utf8))
  #expect(previous.waits == 0 && previous.waitOutcomes.isEmpty)
}

@Test func liveViewIsAuditedAsCountsOnly() throws {
  let instance = try auditInstance()
  defer { try? FileManager.default.removeItem(atPath: instance.directory) }
  let json = #"{"streams":2,"viewers":3,"takeovers":1,"inputEvents":40}"#
  let counts = try JSONDecoder().decode(MacLiveViewCounts.self, from: Data(json.utf8))
  let time = Date(timeIntervalSince1970: 1_800_000_000)
  BoundaryAudit.record(instance, .liveView(counts), now: time)
  #expect(
    try canonicalJSON(try BoundaryAudit.lines(instance)[0])
      == canonicalJSON(
        #"{"time":"2027-01-15T08:00:00Z","event":"live_view","streams":2,"viewers":3,"takeovers":1,"input_events":40}"#
      ))
  #expect(BoundaryAudit.Event.liveView(counts).auditKind == .boundaryLiveView)
  let negative = json.replacingOccurrences(of: #""viewers":3"#, with: #""viewers":-3"#)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(MacLiveViewCounts.self, from: Data(negative.utf8))
  }
}

@Test func coreAIIsAuditedAsMetadataOnly() throws {
  let instance = try auditInstance()
  defer { try? FileManager.default.removeItem(atPath: instance.directory) }
  let time = Date(timeIntervalSince1970: 1_800_000_000)
  let events: [BoundaryAudit.Event] = [
    .hostSecurityReduced,
    .macCoreAIAttached(
      accelerators: ["_VZMacCoreAIDeviceConfiguration"], template: "iso-0a1b2c3d-00-coreai",
      templateBuild: "27D1\u{1b}[2J", runtime: "iso-sandbox 0.1.0"),
    .macCoreAIProbe(availableKinds: ["cpu", "gpu"], delegateEnabled: true),
  ]
  for event in events { BoundaryAudit.record(instance, event, now: time) }
  let lines = try BoundaryAudit.lines(instance).map(canonicalJSON)
  #expect(
    lines == [
      try canonicalJSON(#"{"time":"2027-01-15T08:00:00Z","event":"host_security_reduced"}"#),
      try canonicalJSON(
        #"{"time":"2027-01-15T08:00:00Z","event":"mac_coreai_attached","accelerators":["_VZMacCoreAIDeviceConfiguration"],"template":"iso-0a1b2c3d-00-coreai","template_build":"27D1?[2J","runtime":"iso-sandbox 0.1.0"}"#
      ),
      try canonicalJSON(
        #"{"time":"2027-01-15T08:00:00Z","event":"mac_coreai_probe","available_kinds":["cpu","gpu"],"delegate_enabled":true}"#
      ),
    ])
  #expect(
    events.map(\.auditKind) == [.hostSecurityReduced, .macCoreAIAttached, .macCoreAIProbe])
  #expect(
    events.map(\.auditKind.rawValue)
      == ["host.security.reduced", "mac.coreai.attached", "mac.coreai.probe"])
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
  let records = try lines.map(jsonObject)
  #expect(records.allSatisfy { $0["time"] is String })
  let last = try #require(records.last)
  #expect(last["event"] as? String == "pull_apply")
  #expect(last["applied"] as? Int == 7)
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
  // Unknown events never change the suggestion.
  #expect(BoundaryAudit.suggestConfig(Array(raw.prefix(2))).joined(separator: "\n") == loose)
}

@Test func bootsAndPullsAreRecordedAtTheirCallSites() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let config = try testConfig(
    #""egress": "none", "proxy": {"anthropic": {"credential": "cmd:printf x"}}"#)
  guest.bootstrap(config).recordBoot(instance)
  let boot = try #require(try BoundaryAudit.lines(instance).last)
  let record = try jsonObject(boot)
  #expect(record["event"] as? String == "boot")
  #expect(record["egress"] as? String == "none")
  #expect(record["proxy_mode"] as? String == "auto")
  #expect(record["proxied"] as? [String] == ["anthropic"])
  #expect(!boot.contains("printf"))
}

@Test func dryRunSecuritySummaryShowsThePresetExpansion() throws {
  let config = try testConfig(
    #""security": {"preset": "offline"}, "limits": {"session_ttl": "2h"}"#)
  #expect(
    try canonicalJSON(config.securitySummary.compactRendered())
      == canonicalJSON(
        #"{"preset":"offline","egress":"none","proxy_mode":"off","workspace_pull":"stage","session_ttl":"2h"}"#
      ))
}

@Test func suggestedConfigNeverEndsWithATrailingComma() {
  // A real member followed only by commented-out ones must not carry a comma.
  let proxiedOpenEgress: [[String: Any]] = [
    ["event": "boot", "egress": "open", "proxied": ["anthropic"]]
  ]
  let lines = BoundaryAudit.suggestConfig(proxiedOpenEgress)
  #expect(lines.last == "}")
  let body = lines.dropLast().filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
  #expect(body.last?.hasSuffix(",") == false)
  let both: [[String: Any]] = [
    ["event": "boot", "egress": "none", "proxied": ["anthropic"]]
  ]
  #expect(BoundaryAudit.suggestConfig(both).joined(separator: "\n").contains("},\n"))
}
