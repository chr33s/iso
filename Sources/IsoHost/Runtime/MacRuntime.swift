import Foundation
import IsoConfiguration
import IsoCore

/// Typed parsers and calls for `iso-sandbox macos …`. As for Linux
/// sandboxes, runtime output is untrusted: records decode into closed types,
/// reported identifiers are checked against the one requested, and the
/// effective configuration the gate reads rejects unknown fields.

package struct MacRecord: Sendable, Equatable, Decodable {
  package let id: String
  package let owner: String
  package let template: String
  package let templateBuild: String
  package let cpus: UInt32
  package let memoryBytes: UInt64
  package let macAddress: String
  package let subnetIndex: Int
  /// `shared` or `host_only`, as for Linux sandboxes.
  package let network: String
  /// `pending`, `enrolled` or `identity_mismatch`.
  package let enrollment: String
  package let authorizedKey: String
  package let createdAt: String
  package let expiresAt: String?
  /// Guest-driven computer use, fixed at create; nil when off.
  package let guestComputerUse: MacGuestComputerUse?
  /// Paravirtualized Core AI, fixed at create; nil when off.
  package let coreAI: MacCoreAIRecord?

  package var sessionDeadline: Date? {
    expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
  }
}

package struct MacLive: Sendable, Equatable, Decodable {
  package let pid: Int32
  package let startedAt: String
  package let bootId: String
  package let ipv4: String
}

/// What the running macOS VM was configured with, reported by its owner.
package struct MacEffective: Sendable, Equatable, Decodable {
  package let id: String
  package let template: String
  package let cpus: UInt32
  package let memoryBytes: UInt64
  package let displays: [String]
  package let pointingDevices: [String]
  package let keyboards: [String]
  package let storage: [String]
  package let network: String
  package let macAddress: String
  package let vsockPorts: [UInt32]
  package let directoryShares: Int
  package let audioDevices: Int
  package let serialPorts: Int
  package let usbControllers: Int
  package let clipboard: Bool
  package let ownerTopology: String
  /// Absent from owners that predate guest-driven computer use: off.
  package let guestComputerUse: MacGuestComputerUse?
  /// Accelerator device classes read back from the booted configuration;
  /// absent from owners that predate Core AI: none.
  package let accelerators: [String]
  /// A Core AI sandbox's owner preflight: whether AMFI is relaxed on the
  /// host. Nil for any other sandbox.
  package let hostSecurityReduced: Bool?
  /// Whether a loopback live-view listener is open now (`cu stream`, opt-in
  /// and token-gated); absent from owners that predate it: none.
  package let liveViewListening: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, template, cpus, memoryBytes, displays, pointingDevices, keyboards, storage, network
    case macAddress, vsockPorts, directoryShares, audioDevices, serialPorts, usbControllers
    case clipboard, ownerTopology, guestComputerUse, accelerators, hostSecurityReduced
    case liveViewListening
  }

  package init(from decoder: any Decoder) throws {
    let c = try StrictKeys.container(decoder, CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    template = try c.decode(String.self, forKey: .template)
    cpus = try c.decode(UInt32.self, forKey: .cpus)
    memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
    displays = try c.decode([String].self, forKey: .displays)
    pointingDevices = try c.decode([String].self, forKey: .pointingDevices)
    keyboards = try c.decode([String].self, forKey: .keyboards)
    storage = try c.decode([String].self, forKey: .storage)
    network = try c.decode(String.self, forKey: .network)
    macAddress = try c.decode(String.self, forKey: .macAddress)
    vsockPorts = try c.decode([UInt32].self, forKey: .vsockPorts)
    directoryShares = try c.decode(Int.self, forKey: .directoryShares)
    audioDevices = try c.decode(Int.self, forKey: .audioDevices)
    serialPorts = try c.decode(Int.self, forKey: .serialPorts)
    usbControllers = try c.decode(Int.self, forKey: .usbControllers)
    clipboard = try c.decode(Bool.self, forKey: .clipboard)
    ownerTopology = try c.decode(String.self, forKey: .ownerTopology)
    guestComputerUse = try c.decodeIfPresent(MacGuestComputerUse.self, forKey: .guestComputerUse)
    accelerators = try c.decodeIfPresent([String].self, forKey: .accelerators) ?? []
    hostSecurityReduced = try c.decodeIfPresent(Bool.self, forKey: .hostSecurityReduced)
    liveViewListening = try c.decodeIfPresent(Bool.self, forKey: .liveViewListening) ?? false
  }
}

/// `coreAI` in a macOS record: the accelerators the owner attaches.
package struct MacCoreAIRecord: Sendable, Equatable, Codable {
  /// `gpu` or `neural_engine`, as `macos create --coreai` takes them.
  package let accelerators: [String]

  package init(accelerators: [String]) { self.accelerators = accelerators }

  /// The same accelerators in any order (the gate compares them as a set).
  package static func same(_ a: MacCoreAIRecord?, _ b: MacCoreAIRecord?) -> Bool {
    a?.accelerators.sorted() == b?.accelerators.sorted()
  }

  package init?(_ config: CoreAIConfig?) {
    guard let config else { return nil }
    accelerators = config.accelerators.map(\.rawValue)
  }
}

/// The guest's `coreai_status` report (`runtime.coreAI`). Guest-authored:
/// the runtime bounds it, and the host re-checks each kind before display
/// or audit.
package struct MacCoreAIProbe: Sendable, Equatable, Decodable {
  package let availableKinds: [String]
  package let delegateEnabled: Bool

  package init(availableKinds: [String], delegateEnabled: Bool) {
    self.availableKinds = availableKinds
    self.delegateEnabled = delegateEnabled
  }

  enum CodingKeys: String, CodingKey { case availableKinds, delegateEnabled }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kinds = try c.decode([String].self, forKey: .availableKinds)
    guard kinds.count <= 8, kinds.allSatisfy(Self.isKind) else {
      throw DecodingError.dataCorruptedError(
        forKey: .availableKinds, in: c, debugDescription: "not a list of compute kinds")
    }
    self.init(
      availableKinds: kinds, delegateEnabled: try c.decode(Bool.self, forKey: .delegateEnabled))
  }

  /// ASCII letters, 1-32 of them, as the helper protocol allows.
  static func isKind(_ s: String) -> Bool {
    (1...32).contains(s.utf8.count)
      && s.utf8.allSatisfy { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
  }
}

/// `guestComputerUse` in a macOS record and effective configuration.
package struct MacGuestComputerUse: Sendable, Equatable, Codable {
  package let frameRate: Int

  package init(frameRate: Int) { self.frameRate = frameRate }

  package init?(_ config: ComputerUseConfig) {
    guard let rate = config.guestFrameRate else { return nil }
    frameRate = rate
  }
}

/// The owner's view of the guest helper (`runtime` in `macos inspect`).
package struct MacRuntimeStatus: Sendable, Equatable, Decodable {
  package let vmState: String
  package let bootId: String
  package let enrollment: String
  package let helperConnected: Bool
  package let sshHostKey: String?
  package let sshHostKeyConfirmed: Bool
  package let ipv4: String
  /// This boot's guest computer-use counts; absent when it is off. An
  /// invalid report (a negative count) is dropped: only the audit loses it.
  package let guestComputerUse: MacGuestCUCounts?
  /// The guest's Core AI report for this boot; absent until it answers, or
  /// when Core AI is off. An invalid report is dropped.
  package let coreAI: MacCoreAIProbe?
  /// This boot's live-view counts; absent when no stream started. An
  /// invalid report is dropped.
  package let liveView: MacLiveViewCounts?

  enum CodingKeys: String, CodingKey {
    case vmState, bootId, enrollment, helperConnected, sshHostKey, sshHostKeyConfirmed, ipv4
    case guestComputerUse, coreAI, liveView
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    vmState = try c.decode(String.self, forKey: .vmState)
    bootId = try c.decode(String.self, forKey: .bootId)
    enrollment = try c.decode(String.self, forKey: .enrollment)
    helperConnected = try c.decode(Bool.self, forKey: .helperConnected)
    sshHostKey = try c.decodeIfPresent(String.self, forKey: .sshHostKey)
    sshHostKeyConfirmed = try c.decode(Bool.self, forKey: .sshHostKeyConfirmed)
    ipv4 = try c.decode(String.self, forKey: .ipv4)
    guestComputerUse = try? c.decodeIfPresent(MacGuestCUCounts.self, forKey: .guestComputerUse)
    coreAI = (try? c.decodeIfPresent(MacCoreAIProbe.self, forKey: .coreAI)) ?? nil
    liveView = (try? c.decodeIfPresent(MacLiveViewCounts.self, forKey: .liveView)) ?? nil
  }
}

/// The owner's per-boot live-view counts (`runtime.liveView`).
package struct MacLiveViewCounts: Sendable, Equatable, Decodable {
  package let streams: Int
  package let viewers: Int
  package let takeovers: Int
  package let inputEvents: Int

  package init(streams: Int, viewers: Int, takeovers: Int, inputEvents: Int) {
    self.streams = streams
    self.viewers = viewers
    self.takeovers = takeovers
    self.inputEvents = inputEvents
  }

  enum CodingKeys: String, CodingKey {
    case streams, viewers, takeovers, inputEvents
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      streams: try nonNegative(c, .streams), viewers: try nonNegative(c, .viewers),
      takeovers: try nonNegative(c, .takeovers), inputEvents: try nonNegative(c, .inputEvents))
  }
}

/// An owner-reported count: required unless `fallback` is given (for a key an
/// older owner omits), and never negative.
private func nonNegative<Key: CodingKey>(
  _ c: KeyedDecodingContainer<Key>, _ key: Key, default fallback: Int? = nil
) throws -> Int {
  let value =
    if let fallback {
      try c.decodeIfPresent(Int.self, forKey: key) ?? fallback
    } else {
      try c.decode(Int.self, forKey: key)
    }
  guard value >= 0 else {
    throw DecodingError.dataCorruptedError(
      forKey: key, in: c, debugDescription: "a count is never negative")
  }
  return value
}

/// The owner's per-boot guest computer-use counts (`runtime.guestComputerUse`).
package struct MacGuestCUCounts: Sendable, Equatable, Decodable {
  package let frameRate: Int
  package let sessions: Int
  package let frames: Int
  package let actions: Int
  package let statusRequests: Int
  /// Screen-sync waits that ran to an outcome; 0 from an owner without them.
  package let waits: Int
  /// Waits by outcome (`settled`, `unchanged`, `timedOut`); anything else is dropped.
  package let waitOutcomes: [String: Int]
  package let preemptions: Int
  /// Refusal codes as the owner names them; anything else is dropped.
  package let refusals: [String: Int]

  /// The outcomes the runtime's `wait` reports.
  static let outcomes: Set<String> = ["settled", "unchanged", "timedOut"]

  package init(
    frameRate: Int, sessions: Int, frames: Int, actions: Int, statusRequests: Int,
    waits: Int = 0, waitOutcomes: [String: Int] = [:], preemptions: Int, refusals: [String: Int]
  ) {
    self.frameRate = frameRate
    self.sessions = sessions
    self.frames = frames
    self.actions = actions
    self.statusRequests = statusRequests
    self.waits = waits
    self.waitOutcomes = waitOutcomes.filter { Self.outcomes.contains($0.key) && $0.value >= 0 }
    self.preemptions = preemptions
    self.refusals = refusals.filter { Self.isCode($0.key) && $0.value >= 0 }
  }

  enum CodingKeys: String, CodingKey {
    case frameRate, sessions, frames, actions, statusRequests, waits, waitOutcomes, preemptions
    case refusals
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      frameRate: try nonNegative(c, .frameRate), sessions: try nonNegative(c, .sessions),
      frames: try nonNegative(c, .frames), actions: try nonNegative(c, .actions),
      statusRequests: try nonNegative(c, .statusRequests),
      // Absent from an owner that predates screen sync.
      waits: try nonNegative(c, .waits, default: 0),
      waitOutcomes: try c.decodeIfPresent([String: Int].self, forKey: .waitOutcomes) ?? [:],
      preemptions: try nonNegative(c, .preemptions),
      refusals: try c.decode([String: Int].self, forKey: .refusals))
  }

  /// Lowercase letters and underscores, as the runtime's refusal codes are.
  static func isCode(_ s: String) -> Bool {
    (1...32).contains(s.count) && s.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
  }
}

package struct MacInspection: Sendable, Equatable, Decodable {
  package let record: MacRecord
  package let status: SandboxStatus
  package let live: MacLive?
  package let effective: MacEffective?
  package let runtime: MacRuntimeStatus?
  /// Counts of recent boots that have ended; absent when none was recorded.
  package let endedBoots: EndedBoots?
  /// The pinned guest host key, present once the sandbox has enrolled.
  package let sshHostKey: String?
}

/// `iso-sandbox macos template build|list` entries.
package struct MacTemplateInfo: Sendable, Equatable, Decodable {
  package let name: String
  package let productVersion: String
  package let build: String
  package let ipswSha256: String
  package let helperSha256: String
  package let provisionSha256: String?
  package let minimumCPUs: UInt32
  package let minimumMemoryBytes: UInt64
  /// True for a template built with the Core AI feature flag.
  package let coreAIFeatureFlag: Bool?

  package var hasCoreAIFeatureFlag: Bool { coreAIFeatureFlag == true }
}

package struct MacListed: Sendable, Equatable, Decodable {
  package let id: String
  package let status: SandboxStatus
}

extension RuntimeProtocol {
  package static let macFeature = "macos-guests"
  /// Advertised only by the experimental `iso-sandbox-coreai` build.
  package static let macCoreAIFeature = "macos-coreai"

  package static func parseMacInspect(_ bytes: [UInt8], expected: MachineName)
    throws(RuntimeError) -> MacInspection
  {
    let inspection = try decode(MacInspection.self, bytes, "macos inspect")
    guard inspection.record.id == expected.rawValue else {
      throw .identityConflict(
        "macos inspect for \(expected) returned sandbox \(debugQuoted(inspection.record.id))")
    }
    if let effective = inspection.effective, effective.id != expected.rawValue {
      throw .identityConflict(
        "sandbox \(expected) reports an effective config for \(debugQuoted(effective.id))")
    }
    return inspection
  }

  package static func parseMacList(_ bytes: [UInt8]) throws(RuntimeError) -> [MacListed] {
    let listed = try decode([MacListed].self, bytes, "macos list")
    var seen = Set<String>()
    for entry in listed where !seen.insert(entry.id).inserted {
      throw .unqualified("`iso-sandbox macos list` reported \(entry.id) twice")
    }
    return listed
  }
}

extension SandboxRuntime {
  /// macOS guests need a runtime that advertises them.
  package func requireMacGuests() throws(RuntimeError) {
    _ = try requireQualified()
    guard features.contains(RuntimeProtocol.macFeature) else {
      throw .unqualified(
        "this iso-sandbox does not support macOS guests; rebuild it from this checkout with scripts/build-iso-sandbox.sh"
      )
    }
  }

  package func macInspect(_ name: MachineName) throws(RuntimeError) -> MacInspection {
    try RuntimeProtocol.parseMacInspect(
      Self.checked(
        executor, arguments(["macos", "inspect"], [name.rawValue]),
        deadline: probeDeadline + .seconds(30), limit: Self.jsonLimit),
      expected: name)
  }

  package func macList() throws(RuntimeError) -> [MacListed] {
    try RuntimeProtocol.parseMacList(probe(["macos", "list"]))
  }

  package func macListed(_ name: MachineName) throws(RuntimeError) -> SandboxStatus? {
    try macList().first { $0.id == name.rawValue }?.status
  }

  package func macTemplates() throws(RuntimeError) -> [MacTemplateInfo] {
    try RuntimeProtocol.decode(
      [MacTemplateInfo].self, probe(["macos", "template", "list"]), "macos template list")
  }

  /// Installs macOS from `ipsw` and publishes template `name`; takes as long
  /// as an operating-system install does. Each runtime progress line is
  /// passed to `progress`, sanitized.
  package func macBuildTemplate(
    _ name: MachineName, ipsw: String, provision: String, cpus: UInt32, memoryMiB: UInt64,
    diskGiB: UInt64, coreAI: Bool = false, deadline: Duration, progress: (String) -> Void
  ) throws -> MacTemplateInfo {
    var stdout: [UInt8] = []
    var lines = BoundedLineSplitter(limit: 4096)
    var tail: [String] = []
    func emit(_ bytes: [UInt8]) {
      let line = sanitizeForDisplay(String(decoding: bytes, as: UTF8.self))
      progress(line)
      tail = Array((tail + [line]).suffix(20))
    }
    let termination = try executor.stream(
      arguments(
        ["macos", "template", "build"],
        [
          "--ipsw", ipsw, "--name", name.rawValue, "--provision", provision, "--cpus", String(cpus),
          "--memory-mib", String(memoryMiB), "--disk-gib", String(diskGiB),
        ] + (coreAI ? ["--coreai"] : [])),
      deadline: deadline, cancellable: true
    ) { stream, bytes in
      switch stream {
      case .stdout:
        guard stdout.count + bytes.count <= Self.jsonLimit else {
          throw RuntimeError.unqualified("`iso-sandbox macos template build` output is too large")
        }
        stdout.append(contentsOf: bytes)
      case .stderr: lines.feed(bytes, emit)
      }
    }
    lines.finish(emit)
    guard termination == .exited(0) else {
      throw RuntimeError.failed(
        "`iso-sandbox macos template build` failed:\n\(tail.joined(separator: "\n"))")
    }
    let template = try RuntimeProtocol.decode(MacTemplateInfo.self, stdout, "macos template build")
    guard template.name == name.rawValue else {
      throw RuntimeError.identityConflict(
        "template build for \(name) returned \(debugQuoted(template.name))")
    }
    return template
  }

  package func macCreate(
    _ name: MachineName, template: MachineName, cpus: UInt32, memoryMiB: UInt64, owner: OwnerID,
    egress: EgressMode, authorizedKey: String, guestComputerUse: MacGuestComputerUse? = nil,
    coreAI: MacCoreAIRecord? = nil
  ) throws(RuntimeError) {
    _ = try Self.checked(
      executor,
      arguments(
        ["macos", "create"],
        [
          name.rawValue, "--template", template.rawValue, "--owner", owner.rawValue, "--cpus",
          String(cpus), "--memory-mib", String(memoryMiB), "--network",
          egress.requiresHostOnlyNetwork ? "host-only" : "shared", "--authorized-key",
          authorizedKey,
        ]
          + (guestComputerUse.map {
            ["--guest-computer-use", "--guest-frame-rate", String($0.frameRate)]
          } ?? [])
          + (coreAI.map { ["--coreai", $0.accelerators.joined(separator: ",")] } ?? [])),
      deadline: createDeadline, limit: Self.jsonLimit, cancellable: true)
  }

  package func macStart(_ name: MachineName, expiresAt: Date?) throws(RuntimeError) {
    _ = try Self.checked(
      executor,
      arguments(
        ["macos", "start"],
        [name.rawValue, "--wait-seconds", String(settings.bootTimeout.seconds)]
          + (expiresAt.map { ["--expires-at", String(Int64($0.timeIntervalSince1970))] } ?? [])),
      deadline: bootDeadline + .seconds(10), limit: Self.jsonLimit, cancellable: true)
  }

  /// The runtime's stop waits up to the timeout for the owner's reply, the
  /// same again for the owner to exit, then 220 seconds after the launchd
  /// bootout. Exit status ignored: callers confirm with `macos inspect`.
  package func macStop(_ name: MachineName) throws(RuntimeError) -> ProcessRunner.Output {
    try executor.run(
      arguments(
        ["macos", "stop"],
        [name.rawValue, "--timeout-seconds", String(settings.stopTimeout.seconds)]
      ),
      deadline: stopDeadline * 2 + .seconds(230), outputLimit: Self.textLimit, cancellable: false)
  }

  package func macDelete(_ name: MachineName, owner: OwnerID) throws(RuntimeError) {
    _ = try Self.checked(
      executor, arguments(["macos", "delete"], [name.rawValue, "--owner", owner.rawValue]),
      deadline: operationDeadline, limit: Self.textLimit)
  }

  package func macReconcileBestEffort(diagnostics: Diagnostics) {
    do {
      _ = try Self.checked(
        executor, arguments(["macos", "reconcile"]), deadline: operationDeadline,
        limit: Self.jsonLimit)
    } catch {
      diagnostics.debug("macos reconcile: \(error)")
    }
  }

  package func macDeleteTemplate(_ name: MachineName) throws(RuntimeError) {
    _ = try Self.checked(
      executor, arguments(["macos", "template", "delete"], [name.rawValue]),
      deadline: operationDeadline, limit: Self.textLimit)
  }
}
