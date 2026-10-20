import Foundation
import IsoConfiguration
import IsoCore

/// `host.capabilities`: what this host can do now and the evidence behind it
/// (docs/design/brokered-network-isolation.md, NET-HANDOFF-1). A capability
/// is advertised only while every condition for it holds; anything missing
/// leaves it out, never in with a caveat.
package enum HostCapabilityName: String, Sendable, CaseIterable {
  /// The brokered execution handoff: NIC-less boots under a published run
  /// policy, backed by current qualification evidence for this tuple.
  case netHandoff1 = "net-handoff-1"
  /// Host-owned live and stopped-disk run retention (`run.retain`).
  case runRetention1 = "run-retention-1"
}

/// Native facts behind `host.capabilities`, read fresh on every call.
package struct NetworkCapability: Sendable, Equatable {
  package let transport: NetworkTransport
  /// The runtime is qualified and advertises the brokered transport feature.
  package let runtimeBrokered: Bool
  /// The brokered boot policy a fresh `run.create` VM gets per egress mode;
  /// empty for vmnet, and a mode whose policy cannot be resolved is absent.
  package let runPolicies: [EgressMode: BrokeredNetworkPolicy]
  /// Tuple values this host can verify live. A qualification tuple key
  /// absent here is operator-attested.
  package let liveTuple: [String: String]

  package init(
    transport: NetworkTransport, runtimeBrokered: Bool,
    runPolicies: [EgressMode: BrokeredNetworkPolicy], liveTuple: [String: String]
  ) {
    self.transport = transport
    self.runtimeBrokered = runtimeBrokered
    self.runPolicies = runPolicies
    self.liveTuple = liveTuple
  }
}

extension BrokeredNetworkPolicy {
  /// The policy a fresh host-control VM boots with under `config` (whose
  /// egress is the requested mode): a new instance has no per-VM proxy
  /// override, recorded guest environment or model choice, so its grants
  /// come from configuration alone — exactly what `vm.create` and
  /// `run.create` resolve at first boot.
  package static func freshRun(_ config: IsoConfig) throws -> BrokeredNetworkPolicy {
    guard let index = InstanceIndex(0) else { throw HostError("instance index 0 is out of range") }
    // A directory that is never created: every per-instance record is absent.
    let probe = Instance(
      name: try InstanceName("capability-probe"), index: index,
      directory: NSTemporaryDirectory() + "/iso-capability-probe-" + UUID().uuidString,
      image: .default)
    return try resolve(config, probe)
  }
}

/// The macOS version as `major.minor.patch`.
package func hostOSVersion() -> String {
  let version = ProcessInfo.processInfo.operatingSystemVersion
  return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

/// An operator-installed NET-HANDOFF-1 evidence manifest
/// (`<host-control root>/qualification/net-handoff-1.json`). It names the
/// exact tuple that passed N-T01–N-T16 and when that evidence expires.
package struct QualificationManifest: Sendable, Equatable {
  package static let schema = "iso.qualification/v1"
  package static let capability = "NET-HANDOFF-1"
  package static let maxBytes = 64 << 10
  /// Every tuple key a manifest must name.
  package static let tupleKeys = [
    "host_os", "iso_version", "runtime", "transport", "image", "guest_kernel", "broker",
  ]
  /// Every release-blocking brokered test; each must be `passed`.
  package static let requiredTests = (1...16).map { String(format: "N-T%02d", $0) }
  /// Evidence lasts at most this long, and may be recorded at most this far
  /// ahead of the host clock.
  package static let maxLifetimeSeconds: UInt64 = 365 * 86_400
  package static let maxClockSkewSeconds: UInt64 = 300

  package let recordedAt: UInt64
  package let expiresAt: UInt64
  package let tuple: [String: String]
  package let tests: [String: String]
  package let digest: SHA256Hex
  /// The one qualified worker image: `tuple.image` is
  /// `<image name>@sha256:<64 lowercase hex>` (the image manifest digest).
  package let imageName: ImageName
  package let imageDigest: String

  package static func path(root: String) -> String {
    root + "/qualification/net-handoff-1.json"
  }

  /// Strict: closed structure, complete tuple, every required test passed,
  /// a bounded lifetime, recorded no later than `now` (plus skew).
  package init(bytes: [UInt8], now: UInt64) throws(HostControlError) {
    let value = try HostWire.parse(
      bytes,
      limits: JSONLimits(
        maxBytes: Self.maxBytes, maxDepth: 4, maxKeys: 256, maxArrayElements: 0,
        maxNumberLength: 20, maxStringBytes: 1_024))
    var r = try WireObject(value, field: "manifest")
    guard try r.string("schema") == Self.schema else {
      throw .invalidRequest("manifest.schema must be \(Self.schema)")
    }
    guard try r.string("capability") == Self.capability else {
      throw .invalidRequest("manifest.capability must be \(Self.capability)")
    }
    recordedAt = try r.unsigned("recorded_at")
    expiresAt = try r.unsigned("expires_at")
    guard expiresAt > recordedAt, expiresAt - recordedAt <= Self.maxLifetimeSeconds else {
      throw .invalidRequest("manifest.expires_at must be within 365 days after recorded_at")
    }
    guard recordedAt <= now + Self.maxClockSkewSeconds else {
      throw .invalidRequest("manifest.recorded_at is in the future")
    }
    tuple = try Self.strings(try r.object("tuple"), keys: Self.tupleKeys, field: "manifest.tuple")
    let image = (tuple["image"] ?? "").split(separator: "@", maxSplits: 1).map(String.init)
    guard image.count == 2, let name = try? ImageName(image[0]), image[1].hasPrefix("sha256:"),
      (try? SHA256Hex(String(image[1].dropFirst(7))))?.rawValue == String(image[1].dropFirst(7))
    else {
      throw .invalidRequest("manifest.tuple.image must be <image name>@sha256:<lowercase hex>")
    }
    imageName = name
    imageDigest = image[1]
    tests = try Self.strings(
      try r.object("tests"), keys: Self.requiredTests, field: "manifest.tests")
    for id in Self.requiredTests where tests[id] != "passed" {
      throw .invalidRequest("manifest.tests.\(id) is not passed")
    }
    _ = try r.optionalString("evidence")
    try r.finish()
    digest = HostWire.sha256(bytes)
  }

  private static func strings(_ object: WireObject, keys: [String], field: String)
    throws(HostControlError) -> [String: String]
  {
    var reader = object
    var out: [String: String] = [:]
    for key in keys {
      let text = try reader.string(key)
      guard !text.isEmpty, text.utf8.count <= 256 else {
        throw .invalidRequest("\(field).\(key) must be 1-256 bytes")
      }
      out[key] = text
    }
    try reader.finish()
    return out
  }

  /// Reads a private manifest: a regular file owned by this user that no
  /// other account can write. Nil when absent.
  package static func read(_ path: String) throws(HostControlError) -> [UInt8]? {
    // Nonblocking: a FIFO planted at the path must not hang the handler; it
    // is refused below as not a regular file.
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw .invalidRequest("the evidence manifest cannot be opened")
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == getuid(), status.st_mode & 0o022 == 0
    else {
      throw .invalidRequest("the evidence manifest must be a private file owned by this user")
    }
    do {
      return try StateStore.readBounded(
        fd, path: path, limit: maxBytes, tooLarge: "the evidence manifest is too large")
    } catch { throw .invalidRequest("the evidence manifest cannot be read") }
  }
}

/// The qualification of this host's current tuple.
package struct QualificationReport: Sendable, Equatable {
  package enum Status: String, Sendable, Equatable {
    case qualified
    /// No valid evidence: absent, unreadable, malformed or incomplete.
    case missing
    /// Valid evidence for a different tuple than the one running now.
    case mismatch
    case expired
  }

  package let status: Status
  package let reason: String?
  package let manifest: QualificationManifest?
  package let liveTuple: [String: String]

  /// Evaluates the manifest at `path` against live facts. `imageDigest`
  /// answers the current manifest digest of a worker image by name.
  package static func evaluate(
    path: String, network: NetworkCapability, now: UInt64,
    imageDigest: (ImageName) -> String?
  ) -> QualificationReport {
    func report(_ status: Status, _ reason: String?, _ manifest: QualificationManifest?)
      -> QualificationReport
    {
      QualificationReport(
        status: status, reason: reason, manifest: manifest, liveTuple: network.liveTuple)
    }
    let bytes: [UInt8]
    do {
      guard let read = try QualificationManifest.read(path) else {
        return report(.missing, "no NET-HANDOFF-1 evidence manifest is installed", nil)
      }
      bytes = read
    } catch { return report(.missing, error.message, nil) }
    let manifest: QualificationManifest
    do { manifest = try QualificationManifest(bytes: bytes, now: now) } catch {
      return report(.missing, "the evidence manifest is invalid: \(error.message)", nil)
    }
    for key in network.liveTuple.keys.sorted() where manifest.tuple[key] != network.liveTuple[key] {
      return report(.mismatch, "\(key) differs from the qualified tuple", manifest)
    }
    // The worker image must still be exactly the one that was qualified.
    guard imageDigest(manifest.imageName) == manifest.imageDigest else {
      return report(.mismatch, "the qualified image is absent or was rebuilt", manifest)
    }
    guard now < manifest.expiresAt else {
      return report(.expired, "the evidence manifest expired", manifest)
    }
    return report(.qualified, nil, manifest)
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("schema", QualificationManifest.schema)
    b.set("status", status.rawValue)
    if let reason { b.set("reason", HostControlError.sanitize(reason)) }
    if let manifest {
      b.set("manifest_digest", manifest.digest)
      b.set("recorded_at", manifest.recordedAt)
      b.set("expires_at", manifest.expiresAt)
    }
    // The qualified tuple when evidence exists, else what would need it.
    let tuple = manifest?.tuple ?? liveTuple
    b.set("tuple", .object(tuple.mapValues { .string($0) }))
    b.set("tests", .object((manifest?.tests ?? [:]).mapValues { .string($0) }))
    return b.value
  }
}

/// The `host.capabilities` result.
package struct HostCapabilitiesResult: Sendable, Equatable {
  package let capabilities: [HostCapabilityName]
  package let network: NetworkCapability
  package let qualification: QualificationReport
  /// Absent for local requests, which have no host maximum.
  package let maxTTLSeconds: UInt64?

  package init(
    network: NetworkCapability, qualification: QualificationReport, maxTTLSeconds: UInt64?
  ) {
    var names: [HostCapabilityName] = [.runRetention1]
    // Fail closed: every condition, or no handoff.
    if network.transport == .brokered, network.runtimeBrokered,
      qualification.status == .qualified
    {
      names.insert(.netHandoff1, at: 0)
    }
    capabilities = names
    self.network = network
    self.qualification = qualification
    self.maxTTLSeconds = maxTTLSeconds
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("capabilities", .array(capabilities.map { .string($0.rawValue) }))
    if network.transport == .brokered {
      var handoff = WireBuilder()
      handoff.set("id", QualificationManifest.capability)
      handoff.set("version", UInt64(1))
      handoff.set("transport", NetworkTransport.brokered.rawValue)
      handoff.set("fallback", "forbidden")
      var policies: [String: JSONValue] = [:]
      for (mode, policy) in network.runPolicies { policies[mode.rawValue] = Self.wire(policy) }
      handoff.set("run_policies", .object(policies))
      // The evidence covers one image: a client binds to it by requesting
      // this name and `image_digest`, which admission enforces.
      if capabilities.contains(.netHandoff1), let manifest = qualification.manifest {
        var image = WireBuilder()
        image.set("name", manifest.imageName)
        image.set("digest", manifest.imageDigest)
        handoff.set("qualified_image", image.value)
      }
      b.set("network_handoff", handoff.value)
    }
    b.set("qualification", qualification.wire)
    var retention = WireBuilder()
    retention.set("modes", .array(RetentionMode.allCases.map { .string($0.rawValue) }))
    retention.set("max_live_seconds", RunStore.maxLiveRetentionSeconds)
    retention.set("max_stopped_seconds", RunStore.maxStoppedRetentionSeconds)
    b.set("run_retention", retention.value)
    var limits = WireBuilder()
    limits.set("retention_slots", UInt64(RunStore.retentionSlots))
    limits.set("max_output_bytes", RunStore.maxOutputBytes)
    limits.setIfPresent("max_ttl_seconds", maxTTLSeconds)
    b.set("limits", limits.value)
    return b.value
  }

  static func wire(_ policy: BrokeredNetworkPolicy) -> JSONValue {
    var b = WireBuilder()
    b.set("digest", policy.digest)
    if let egress = policy.publicEgress {
      var e = WireBuilder()
      e.set("profile", egress.profile)
      e.set("allowed_hosts", .array(egress.allowedHosts.map { .string($0) }))
      e.set("policy_hash", egress.policyHash)
      b.set("public_egress", e.value)
    } else {
      b.set("public_egress", .null)
    }
    b.set("provider_grants", .array(policy.providerGrants.map { .string($0) }))
    b.set(
      "local_services",
      .array(
        policy.localServices.map { service in
          var s = WireBuilder()
          s.set("name", service.name)
          s.set("guest_port", UInt64(service.guestPort))
          s.set("host_address", service.hostAddress)
          s.set("host_port", UInt64(service.hostPort))
          return s.value
        }))
    b.set("channel_policy", policy.channelPolicy)
    return b.value
  }
}

extension HostSupervisor {
  /// `host.capabilities`, recomputed from live facts on every call.
  package func capabilities(transport: HostTransportKind) -> HostCapabilitiesResult {
    let network = native.networkCapability()
    let report = QualificationReport.evaluate(
      path: QualificationManifest.path(root: store.root), network: network, now: now.seconds,
      imageDigest: { native.imageDigest($0) })
    return HostCapabilitiesResult(
      network: network, qualification: report,
      maxTTLSeconds: transport == .ssh ? settings.remoteMaxTTL : nil)
  }
}
