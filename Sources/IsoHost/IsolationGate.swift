import Foundation
import IsoConfiguration
import IsoCore

/// Runtime qualification's companion: the isolation gate. Before any guest
/// is handed to a user or agent, the effective configuration the running
/// VM's owner reports is checked against what iso recorded. No flag or
/// configuration relaxes these checks.
public enum IsolationGate {
  /// Kernel pseudo-filesystems a sandbox may mount, as (type, source,
  /// destination). Nothing else — no share, bind, or block device.
  static let allowedMounts: [(String, String, String)] = [
    ("proc", "proc", "/proc"), ("sysfs", "sysfs", "/sys"), ("devtmpfs", "none", "/dev"),
    ("mqueue", "mqueue", "/dev/mqueue"), ("tmpfs", "tmpfs", "/dev/shm"),
    ("cgroup2", "none", "/sys/fs/cgroup"), ("devpts", "devpts", "/dev/pts"),
  ]

  /// What the gate compares the runtime's report against.
  public struct Expected: Sendable {
    public let sandbox: MachineName
    public let owner: OwnerID
    public let runtimeRoot: String
    public let resources: Resources
    /// The configured egress policy the sandbox must have been created with.
    public let egress: EgressMode
    /// Whether the sandbox must relay the inference gateway's socket
    /// (§22); otherwise it must relay nothing.
    public let inferenceRelay: Bool

    public init(
      sandbox: MachineName, owner: OwnerID, runtimeRoot: String, resources: Resources,
      egress: EgressMode, inferenceRelay: Bool
    ) {
      self.sandbox = sandbox
      self.owner = owner
      self.runtimeRoot = runtimeRoot
      self.resources = resources
      self.egress = egress
      self.inferenceRelay = inferenceRelay
    }
  }

  // MARK: Inference relay (secure-local-inference §22)

  /// Where the runtime puts the relays' host sockets: `iso-sbx/inference`
  /// in the per-user temporary directory, beside the owners' control
  /// sockets. The gateway binds its session sockets here.
  public static let relayDirectory: String = {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let temporary =
      count > 0 && count <= buffer.count
      ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      : NSTemporaryDirectory()
    return (temporary.hasSuffix("/") ? temporary : temporary + "/") + "iso-sbx/inference"
  }()
  public static let relayGuestPath = "/var/lib/iso-inference/gateway.sock"
  public static let relayMaxConnections = 32

  /// The host socket the runtime derives for `sandbox`: a hash of its
  /// canonical directory, as the runtime computes it.
  public static func inferenceSocket(runtimeRoot: String, sandbox: MachineName) -> String {
    let directory =
      (runtimeRoot.hasSuffix("/") ? String(runtimeRoot.dropLast()) : runtimeRoot)
      + "/sandboxes/\(sandbox)"
    let hash = directory.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return relayDirectory + "/" + String(hash, radix: 16) + ".sock"
  }

  /// Process-local proof that a sandbox's current boot passed the gate. Not
  /// `Codable`: it cannot be persisted, and it is re-established after every
  /// boot and before every hand-out.
  public struct Ready: Sendable, Equatable {
    public let sandbox: MachineName
    /// PID of the owner process; a different PID later means a restart.
    public let ownerPID: Int32
    public let ipv4: IPv4Address
    /// When the owner halts this boot (`limits.session_ttl`), if ever.
    public let sessionDeadline: Date?
    /// The verified host end of the inference relay, if the boot has one.
    public let inferenceSocket: String?
    fileprivate init(
      sandbox: MachineName, ownerPID: Int32, ipv4: IPv4Address, sessionDeadline: Date?,
      inferenceSocket: String?
    ) {
      self.sandbox = sandbox
      self.ownerPID = ownerPID
      self.ipv4 = ipv4
      self.sessionDeadline = sessionDeadline
      self.inferenceSocket = inferenceSocket
    }
  }

  public static func rootfsPath(runtimeRoot: String, sandbox: MachineName) -> String {
    (runtimeRoot.hasSuffix("/") ? runtimeRoot : runtimeRoot + "/")
      + "sandboxes/\(sandbox)/rootfs.ext4"
  }

  /// Pre-boot check of the runtime's persisted record.
  public static func verifyRecord(_ inspection: SandboxInspection, _ expected: Expected)
    throws(RuntimeError)
  {
    let record = inspection.record
    guard record.id == expected.sandbox.rawValue, record.owner == expected.owner.rawValue else {
      throw .identityConflict(
        "sandbox \(expected.sandbox) is recorded for owner \(debugQuoted(sanitizeForDisplay(record.owner))), not this installation"
      )
    }
    let hostOnly: Bool
    switch record.network {
    case nil: hostOnly = false
    case "host_only"?: hostOnly = true
    case let other?:
      throw .unqualified(
        "sandbox \(expected.sandbox) records unknown network mode \(debugQuoted(sanitizeForDisplay(other)))"
      )
    }
    guard hostOnly == (expected.egress == .none) else {
      throw .networkIsolation(
        "sandbox \(expected.sandbox) was created with egress \(hostOnly ? "none" : "open") but the configuration says \(expected.egress.rawValue); egress is fixed when an instance is created — recreate it (iso destroy, then iso up) or change `egress` back"
      )
    }
    let recorded = Resources(cpus: record.cpus, memoryBytes: record.memoryBytes)
    guard recorded == expected.resources else {
      throw .identityConflict(
        "sandbox \(expected.sandbox) records \(recorded), expected \(expected.resources)")
    }
  }

  /// Post-boot check of the effective configuration the owner reports.
  public static func verifyEffective(_ inspection: SandboxInspection, _ expected: Expected)
    throws(RuntimeError)
    -> Ready
  {
    try verifyRecord(inspection, expected)
    let name = expected.sandbox
    // The relay is set at each start from the configuration; a running boot
    // must match it (checked after boot: `start` sets it, §22).
    guard inspection.record.relaysInference == expected.inferenceRelay else {
      throw .hostExposure(
        "sandbox \(name) was booted \(inspection.record.relaysInference ? "with" : "without") the inference relay, but the configuration \(expected.inferenceRelay ? "requires" : "does not allow") it (inference.mode changed while it ran); restart it: `iso stop`, then `iso start`"
      )
    }
    guard inspection.status == .running else {
      throw .operationUncertain("sandbox \(name) is \(inspection.status.rawValue), not running")
    }
    guard let live = inspection.live, let effective = inspection.effective else {
      throw .unqualified("running sandbox \(name) reports no live state or effective configuration")
    }
    guard let ip = live.ipv4 else { throw .networkIsolation("sandbox \(name) reports no address") }
    // Independent of the owner's own timer: a hung owner past its deadline
    // is not handed out.
    if let recorded = inspection.record.expiresAt {
      guard let deadline = inspection.record.sessionDeadline else {
        throw .unqualified(
          "sandbox \(name) records an unreadable session deadline \(debugQuoted(recorded))")
      }
      if deadline <= Date() {
        throw .sessionExpired(
          "sandbox \(name)'s session ended at \(ISO8601DateFormatter().string(from: deadline)); `iso stop` then `iso start` begins a new one"
        )
      }
    }
    let running = Resources(cpus: effective.cpus, memoryBytes: effective.memoryBytes)
    guard running == expected.resources else {
      throw .identityConflict(
        "sandbox \(name) runs with \(running), expected \(expected.resources)")
    }
    guard effective.imageDigest == inspection.record.imageDigest else {
      throw .identityConflict(
        "sandbox \(name) booted \(effective.imageDigest) but records \(inspection.record.imageDigest)"
      )
    }
    try verifyHostExposure(
      name, effective, runtimeRoot: expected.runtimeRoot, inferenceRelay: expected.inferenceRelay)
    try verifyNetwork(name, effective, ip, egress: expected.egress)
    guard effective.initArgv == ["/sbin/init"], !effective.virtualization else {
      let argv = "[" + effective.initArgv.map(debugQuoted).joined(separator: ", ") + "]"
      throw .hostExposure(
        "sandbox \(name) runs \(argv) with nested virtualization \(effective.virtualization); expected /sbin/init without it"
      )
    }
    return Ready(
      sandbox: name, ownerPID: live.pid, ipv4: ip,
      sessionDeadline: inspection.record.sessionDeadline,
      inferenceSocket: effective.inferenceRelay?.host)
  }

  static func verifyHostExposure(
    _ name: MachineName, _ effective: Effective, runtimeRoot: String, inferenceRelay: Bool
  ) throws(RuntimeError) {
    guard !effective.sshAgentForwarding else {
      throw .hostExposure("sandbox \(name) forwards the host SSH agent")
    }
    // At most one relay: the inference gateway's derived socket into the
    // fixed guest path, capped, and only when the configuration asks.
    let relay = EffectiveRelay(
      host: inferenceSocket(runtimeRoot: runtimeRoot, sandbox: name), guest: relayGuestPath,
      maxConnections: relayMaxConnections)
    let relays =
      effective.socketRelays == (inferenceRelay ? 1 : 0)
      && effective.inferenceRelay == (inferenceRelay ? relay : nil)
    guard relays, effective.publishedPorts == 0 else {
      throw .hostExposure(
        "sandbox \(name) relays \(effective.socketRelays) sockets (\(effective.inferenceRelay.map { sanitizeForDisplay($0.host) + " -> " + sanitizeForDisplay($0.guest) } ?? "none")) and publishes \(effective.publishedPorts) ports; expected \(inferenceRelay ? "only the inference relay \(relay.host) -> \(relay.guest)" : "none")"
      )
    }
    let rootfs = rootfsPath(runtimeRoot: runtimeRoot, sandbox: name)
    guard effective.rootfs.type == "ext4", effective.rootfs.source == rootfs else {
      throw .hostExposure(
        "sandbox \(name) boots from \(sanitizeForDisplay(effective.rootfs.source)) (\(sanitizeForDisplay(effective.rootfs.type))), not its own disk \(rootfs)"
      )
    }
    for mount in effective.mounts
    where !allowedMounts.contains(where: { $0 == (mount.type, mount.source, mount.destination) }) {
      throw .hostExposure(
        "sandbox \(name) mounts \(sanitizeForDisplay(mount.type)) from \(sanitizeForDisplay(mount.source)) at \(sanitizeForDisplay(mount.destination)); only kernel pseudo-filesystems are allowed"
      )
    }
  }

  /// Exactly one interface, on a per-sandbox vmnet network of the expected
  /// mode (`vmnet-shared:10.231.N.0/24`, or `vmnet-host:` for egress none),
  /// carrying the address the owner reports.
  static func verifyNetwork(
    _ name: MachineName, _ effective: Effective, _ ip: IPv4Address, egress: EgressMode
  )
    throws(RuntimeError)
  {
    guard effective.interfaces.count == 1, let interface = effective.interfaces.first else {
      throw .networkIsolation(
        "sandbox \(name) has \(effective.interfaces.count) network interfaces; expected exactly one"
      )
    }
    let address = interface.ipv4.split(
      separator: "/", maxSplits: 1, omittingEmptySubsequences: false
    ).first
      .flatMap { try? IPv4Address(String($0)) }
    var subnetOK = false
    let prefix = egress == .none ? "vmnet-host:10.231." : "vmnet-shared:10.231."
    let suffix = ".0/24"
    if let address, interface.network.hasPrefix(prefix), interface.network.hasSuffix(suffix),
      interface.network.utf8.count > prefix.utf8.count + suffix.utf8.count
    {
      let middle = String(interface.network.dropFirst(prefix.count).dropLast(suffix.count))
      if let n = parseUnsigned(middle, as: UInt8.self) {
        subnetOK = Array(address.octets.prefix(3)) == [10, 231, n]
      }
    }
    guard address == ip, subnetOK else {
      throw .networkIsolation(
        "sandbox \(name) interface \(sanitizeForDisplay(interface.ipv4)) on \(sanitizeForDisplay(interface.network)) does not match its dedicated network address \(ip)"
      )
    }
  }
}
