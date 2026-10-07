// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// Runtime qualification's companion: the isolation gate. Before any guest
/// is handed to a user or agent, the effective configuration the running
/// VM's owner reports is checked against what iso recorded. No flag or
/// configuration relaxes these checks.
package enum IsolationGate {
  /// Kernel pseudo-filesystems a sandbox may mount, as (type, source,
  /// destination). Nothing else — no share, bind, or block device.
  static let allowedMounts: [(String, String, String)] = [
    ("proc", "proc", "/proc"), ("sysfs", "sysfs", "/sys"), ("devtmpfs", "none", "/dev"),
    ("mqueue", "mqueue", "/dev/mqueue"), ("tmpfs", "tmpfs", "/dev/shm"),
    ("cgroup2", "none", "/sys/fs/cgroup"), ("devpts", "devpts", "/dev/pts"),
  ]

  /// What the gate compares the runtime's report against.
  package struct Expected: Sendable {
    package let sandbox: MachineName
    package let owner: OwnerID
    package let runtimeRoot: String
    package let resources: Resources
    /// The configured egress policy the sandbox must have been created with.
    package let egress: EgressMode

    package init(
      sandbox: MachineName, owner: OwnerID, runtimeRoot: String, resources: Resources,
      egress: EgressMode
    ) {
      self.sandbox = sandbox
      self.owner = owner
      self.runtimeRoot = runtimeRoot
      self.resources = resources
      self.egress = egress
    }
  }

  /// Process-local proof that a sandbox's current boot passed the gate. Not
  /// `Codable`: it cannot be persisted, and it is re-established after every
  /// boot and before every hand-out.
  package struct Ready: Sendable, Equatable {
    package let sandbox: MachineName
    /// PID of the owner process; a different PID later means a restart.
    package let ownerPID: Int32
    package let ipv4: IPv4Address
    fileprivate init(sandbox: MachineName, ownerPID: Int32, ipv4: IPv4Address) {
      self.sandbox = sandbox
      self.ownerPID = ownerPID
      self.ipv4 = ipv4
    }
  }

  package static func rootfsPath(runtimeRoot: String, sandbox: MachineName) -> String {
    (runtimeRoot.hasSuffix("/") ? runtimeRoot : runtimeRoot + "/")
      + "sandboxes/\(sandbox)/rootfs.ext4"
  }

  /// Pre-boot check of the runtime's persisted record.
  package static func verifyRecord(_ inspection: SandboxInspection, _ expected: Expected)
    throws(RuntimeError)
  {
    let record = inspection.record
    try verifyRecorded(
      id: record.id, owner: record.owner, network: record.network,
      resources: Resources(cpus: record.cpus, memoryBytes: record.memoryBytes), expected)
  }

  /// The record checks shared by Linux and macOS sandboxes: identity,
  /// owner, the network mode egress requires, and resources.
  static func verifyRecorded(
    id: String, owner: String, network: String, resources recorded: Resources, _ expected: Expected
  ) throws(RuntimeError) {
    guard id == expected.sandbox.rawValue, owner == expected.owner.rawValue else {
      throw .identityConflict(
        "sandbox \(expected.sandbox) is recorded for owner \(debugQuoted(sanitizeForDisplay(owner))), not this installation"
      )
    }
    let hostOnly: Bool
    switch network {
    case "shared": hostOnly = false
    case "host_only": hostOnly = true
    case let other:
      throw .unqualified(
        "sandbox \(expected.sandbox) records unknown network mode \(debugQuoted(sanitizeForDisplay(other)))"
      )
    }
    guard hostOnly == expected.egress.requiresHostOnlyNetwork else {
      throw .networkIsolation(
        "sandbox \(expected.sandbox) was created with \(hostOnly ? "host-only" : "shared") networking but the configuration says egress \(expected.egress.rawValue); egress is fixed when an instance is created — recreate it (iso destroy, then iso up) or change `egress` back"
      )
    }
    guard recorded == expected.resources else {
      throw .identityConflict(
        "sandbox \(expected.sandbox) records \(recorded), expected \(expected.resources)")
    }
  }

  /// Independent of the owner's own timer: a hung owner past its deadline
  /// is not handed out.
  static func verifySessionOpen(_ name: MachineName, expiresAt: String?, deadline: Date?)
    throws(RuntimeError)
  {
    guard let expiresAt else { return }
    guard let deadline else {
      throw .unqualified(
        "sandbox \(name) records an unreadable session deadline \(debugQuoted(expiresAt))")
    }
    if deadline <= Date() {
      throw .sessionExpired(
        "sandbox \(name)'s session ended at \(ISO8601DateFormatter().string(from: deadline)); `iso stop` then `iso start` begins a new one"
      )
    }
  }

  /// Post-boot check of the effective configuration the owner reports.
  package static func verifyEffective(_ inspection: SandboxInspection, _ expected: Expected)
    throws(RuntimeError)
    -> Ready
  {
    try verifyRecord(inspection, expected)
    let name = expected.sandbox
    guard inspection.status == .running else {
      throw .operationUncertain("sandbox \(name) is \(inspection.status.rawValue), not running")
    }
    guard let live = inspection.live, let effective = inspection.effective else {
      throw .unqualified("running sandbox \(name) reports no live state or effective configuration")
    }
    guard let ip = live.ipv4 else { throw .networkIsolation("sandbox \(name) reports no address") }
    try verifySessionOpen(
      name, expiresAt: inspection.record.expiresAt, deadline: inspection.record.sessionDeadline)
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
    try verifyHostExposure(name, effective, runtimeRoot: expected.runtimeRoot)
    try verifyNetwork(name, effective, ip, egress: expected.egress)
    guard effective.initArgv == ["/sbin/init"], !effective.virtualization else {
      let argv = "[" + effective.initArgv.map(debugQuoted).joined(separator: ", ") + "]"
      throw .hostExposure(
        "sandbox \(name) runs \(argv) with nested virtualization \(effective.virtualization); expected /sbin/init without it"
      )
    }
    return Ready(sandbox: name, ownerPID: live.pid, ipv4: ip)
  }

  static func verifyHostExposure(_ name: MachineName, _ effective: Effective, runtimeRoot: String)
    throws(RuntimeError)
  {
    guard !effective.sshAgentForwarding else {
      throw .hostExposure("sandbox \(name) forwards the host SSH agent")
    }
    guard effective.socketRelays == 0, effective.publishedPorts == 0 else {
      throw .hostExposure(
        "sandbox \(name) relays \(effective.socketRelays) sockets and publishes \(effective.publishedPorts) ports; expected none"
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
    let prefix = egress.requiresHostOnlyNetwork ? "vmnet-host:10.231." : "vmnet-shared:10.231."
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

// MARK: - macOS guests

extension IsolationGate {
  /// The guest helper's vsock port, `HelperProtocol.port` in iso-sandbox
  /// (a separate package): the only port a macOS guest may have.
  static let macVsockPorts: [UInt32] = [7801]

  package static func macDiskPath(runtimeRoot: String, sandbox: MachineName) -> String {
    SandboxNamespace.directory(root: runtimeRoot, sandbox, .macos) + "/disk.img"
  }

  /// Pre-boot check of a macOS sandbox's persisted record.
  package static func verifyMacRecord(
    _ inspection: MacInspection, _ expected: Expected, template: MachineName
  ) throws(RuntimeError) {
    let record = inspection.record
    try verifyRecorded(
      id: record.id, owner: record.owner, network: record.network,
      resources: Resources(cpus: record.cpus, memoryBytes: record.memoryBytes), expected)
    guard record.template == template.rawValue else {
      throw .identityConflict(
        "sandbox \(expected.sandbox) was cloned from \(debugQuoted(sanitizeForDisplay(record.template))), expected \(template)"
      )
    }
    switch record.enrollment {
    case "pending", "enrolled": break
    case "identity_mismatch":
      throw .hostKeyChanged(
        "guest of sandbox \(expected.sandbox) reported a different SSH host key over its authenticated helper channel; destroy and recreate the instance"
      )
    case let other:
      throw .unqualified(
        "sandbox \(expected.sandbox) records unknown enrollment \(debugQuoted(sanitizeForDisplay(other)))"
      )
    }
  }

  /// Why a booting macOS sandbox is not ready to gate yet, or nil once its
  /// helper has enrolled and confirmed the pinned host key on this boot.
  package static func macPending(_ inspection: MacInspection) -> String? {
    guard inspection.status == .running else { return "sandbox is \(inspection.status.rawValue)" }
    guard inspection.live != nil, inspection.effective != nil, let runtime = inspection.runtime
    else { return "owner has not reported its configuration" }
    guard runtime.helperConnected else { return "guest helper not connected" }
    guard runtime.enrollment == "enrolled", inspection.sshHostKey != nil else {
      return "guest not enrolled"
    }
    guard runtime.sshHostKeyConfirmed else { return "guest has not confirmed its SSH host key" }
    return nil
  }

  /// How much of the guest helper a macOS boot needs to pass the gate.
  package enum MacHelperCheck: Sendable {
    /// A boot: the helper has enrolled and confirmed the pinned host key on
    /// this boot.
    case confirmedThisBoot
    /// A later handoff: the pin is enforced by the instance's known_hosts,
    /// so a helper that is slow or reconnecting does not block it. Whatever
    /// the helper does report must still agree with the boot.
    case pinned
  }

  /// Post-boot check of a macOS guest: the effective configuration the
  /// owner reports and, as `helper` requires, the helper's authenticated
  /// confirmation of the pinned SSH host key on this boot.
  package static func verifyMacEffective(
    _ inspection: MacInspection, _ expected: Expected, template: MachineName,
    helper: MacHelperCheck
  ) throws(RuntimeError) -> Ready {
    try verifyMacRecord(inspection, expected, template: template)
    let name = expected.sandbox
    guard inspection.status == .running else {
      throw .operationUncertain("sandbox \(name) is \(inspection.status.rawValue), not running")
    }
    guard let live = inspection.live, let effective = inspection.effective else {
      throw .unqualified("running sandbox \(name) reports no live state or effective configuration")
    }
    guard inspection.record.enrollment == "enrolled", inspection.sshHostKey != nil else {
      throw .operationUncertain("sandbox \(name) is not ready: guest not enrolled")
    }
    try verifySessionOpen(
      name, expiresAt: inspection.record.expiresAt, deadline: inspection.record.sessionDeadline)
    if let runtime = inspection.runtime {
      guard runtime.enrollment != "identity_mismatch" else {
        throw .hostKeyChanged(
          "guest of sandbox \(name) reported a different SSH host key over its authenticated helper channel; destroy and recreate the instance"
        )
      }
      guard runtime.bootId == live.bootId, runtime.vmState == "running",
        runtime.ipv4 == live.ipv4
      else {
        throw .operationUncertain("sandbox \(name) reports a different boot than its live state")
      }
    }
    let running = Resources(cpus: effective.cpus, memoryBytes: effective.memoryBytes)
    guard running == expected.resources, effective.template == inspection.record.template else {
      throw .identityConflict(
        "sandbox \(name) runs \(debugQuoted(sanitizeForDisplay(effective.template))) with \(running), expected \(inspection.record.template) with \(expected.resources)"
      )
    }
    let disk = macDiskPath(runtimeRoot: expected.runtimeRoot, sandbox: name)
    guard effective.storage == [disk] else {
      throw .hostExposure(
        "sandbox \(name) attaches \(effective.storage.map { sanitizeForDisplay($0) }), not only its own disk \(disk)"
      )
    }
    guard effective.directoryShares == 0, effective.audioDevices == 0, effective.serialPorts == 0,
      effective.usbControllers == 0, !effective.clipboard, effective.displays.count == 1,
      effective.vsockPorts == macVsockPorts
    else {
      throw .hostExposure(
        "sandbox \(name) has \(effective.directoryShares) shares, \(effective.audioDevices) audio, \(effective.serialPorts) serial, \(effective.usbControllers) USB, clipboard \(effective.clipboard), \(effective.displays.count) displays, vsock \(effective.vsockPorts); expected none, one display and vsock \(macVsockPorts)"
      )
    }
    guard let ip = try? IPv4Address(live.ipv4) else {
      throw .networkIsolation("sandbox \(name) reports no usable address")
    }
    let prefix = expected.egress.requiresHostOnlyNetwork ? "vmnet-host:" : "vmnet-shared:"
    let index = inspection.record.subnetIndex
    guard (1...250).contains(index), effective.network == "\(prefix)10.231.\(index).0/24",
      ip.octets == [10, 231, UInt8(index), 2], effective.macAddress == inspection.record.macAddress
    else {
      throw .networkIsolation(
        "sandbox \(name) address \(ip) on \(sanitizeForDisplay(effective.network)) does not match its dedicated network"
      )
    }
    if case .confirmedThisBoot = helper, let pending = macPending(inspection) {
      throw .operationUncertain("sandbox \(name) is not ready: \(pending)")
    }
    return Ready(sandbox: name, ownerPID: live.pid, ipv4: ip)
  }
}
