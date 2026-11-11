import Darwin
import Foundation

/// One running VM's lease, written by the iso-sandbox owner process that
/// runs it (`iso.vm-lease/v1`) and held under an exclusive `flock` for that
/// process's lifetime. Interactive `iso` VMs and the host service's CI VMs
/// both write one; a lease whose lock is free is stale.
package struct VMLease: Sendable, Equatable {
  package static let schema = "iso.vm-lease/v1"

  /// The runtime's sandbox (machine) name, as host observations report it
  /// in `QualifiedInstance.runtimeID`.
  package let sandbox: String
  package let guestOS: GuestOS
  package let cpus: UInt32
  package let memoryMiB: UInt64

  package init(sandbox: String, guestOS: GuestOS, cpus: UInt32, memoryMiB: UInt64) {
    self.sandbox = sandbox
    self.guestOS = guestOS
    self.cpus = cpus
    self.memoryMiB = memoryMiB
  }

  /// Strict, bounded parse of one lease file.
  package static func parse(_ bytes: [UInt8]) -> VMLease? {
    guard
      let json = try? StrictJSON.parse(
        bytes, limits: JSONLimits(maxBytes: 4_096, maxKeys: 32, maxArrayElements: 0)),
      json["schema"]?.stringValue == schema,
      let sandbox = json["sandbox"]?.stringValue, (1...128).contains(sandbox.utf8.count),
      sandbox.unicodeScalars.allSatisfy(isSafeNameScalar),
      let os = json["guest_os"]?.stringValue.flatMap(GuestOS.init(rawValue:)),
      let cpus = json["cpus"]?.intValue, (0...1_024).contains(cpus),
      let memory = json["memory_mib"]?.intValue, (0...(1 << 24)).contains(memory)
    else { return nil }
    return VMLease(sandbox: sandbox, guestOS: os, cpus: UInt32(cpus), memoryMiB: UInt64(memory))
  }
}

/// Resources on a host that iso-ci does not own: interactive iso VMs and,
/// when tracked, other Virtualization.framework VMs.
package struct ExternalUsage: Sendable, Equatable {
  package var cpus: UInt32 = 0
  package var memoryMiB: UInt64 = 0
  package var vms: UInt32 = 0
  package var macOSVMs: UInt32 = 0

  package init(cpus: UInt32 = 0, memoryMiB: UInt64 = 0, vms: UInt32 = 0, macOSVMs: UInt32 = 0) {
    self.cpus = cpus
    self.memoryMiB = memoryMiB
    self.vms = vms
    self.macOSVMs = macOSVMs
  }

  package static let none = ExternalUsage()
}

/// Reads what other VMs use on a host. Only the local host's leases are
/// readable; an enrolled remote host reports none (its own host service
/// still admits physically).
package protocol ExternalUsageProbe: Sendable {
  /// `own` holds the runtime IDs of iso-ci's own VMs, so they are not
  /// counted twice.
  func usage(host: Name, budget: HostBudget?, own: Set<String>) -> ExternalUsage
}

package struct NoExternalUsage: ExternalUsageProbe {
  package init() {}
  package func usage(host: Name, budget: HostBudget?, own: Set<String>) -> ExternalUsage { .none }
}

/// The local Mac's lease directory and Virtualization.framework processes.
package struct LocalExternalUsageProbe: ExternalUsageProbe {
  package let leaseDirectory: String

  package init(leaseDirectory: String = HostCapacity.defaultLeaseDirectory) {
    self.leaseDirectory = leaseDirectory
  }

  package func usage(host: Name, budget: HostBudget?, own: Set<String>) -> ExternalUsage {
    guard host.rawValue == HostCapacity.localHost else { return .none }
    let leases = LeaseDirectory.live(leaseDirectory)
    var usage = HostCapacity.usage(of: leases, excluding: own)
    if budget?.trackExternalMacOSVMs == true {
      // A VZ VM process without any live lease is unattributed: count it
      // as a macOS VM, which is the conservative direction for the ceiling.
      let unattributed = max(0, VirtualizationProcesses.count() - leases.count)
      usage.macOSVMs += UInt32(unattributed)
    }
    return usage
  }
}

package enum LeaseDirectory {
  /// Lease files probed per scan; stale leases (their owner exited) stay
  /// on disk, so the bound is generous and applies to `.json` files only.
  package static let maxProbed = 8_192

  /// Live leases: those whose lock some process holds. A lock that can be
  /// taken, a missing file or a malformed lease is not live.
  package static func live(_ directory: String) -> [VMLease] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
      return []
    }
    var out: [VMLease] = []
    for name in names.filter({ $0.hasSuffix(".json") }).sorted().prefix(maxProbed) {
      let path = directory + "/" + name
      guard let fd = openLease(path) else { continue }
      defer { close(fd) }
      guard lockHeld(fd), let bytes = readBounded(fd, limit: 4_096),
        let lease = VMLease.parse(bytes)
      else { continue }
      out.append(lease)
    }
    return out
  }

  private static func openLease(_ path: String) -> Int32? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == getuid()
    else {
      close(fd)
      return nil
    }
    return fd
  }

  /// Only contention proves a holder; a successful probe is released.
  package static func lockHeld(_ fd: Int32) -> Bool {
    if flock(fd, LOCK_SH | LOCK_NB) == 0 {
      _ = flock(fd, LOCK_UN)
      return false
    }
    return errno == EWOULDBLOCK
  }

  private static func readBounded(_ fd: Int32, limit: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: limit + 1)
    var total = 0
    while total < buffer.count {
      let count = buffer.withUnsafeMutableBytes {
        read(fd, $0.baseAddress! + total, $0.count - total)
      }
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      total += count
    }
    guard total <= limit else { return nil }
    return Array(buffer.prefix(total))
  }
}

package enum VirtualizationProcesses {
  static let serviceName = "com.apple.Virtualization.VirtualMachine"

  package static func count() -> Int {
    let capacity = Int(proc_listallpids(nil, 0))
    guard capacity > 0 else { return 0 }
    var pids = [pid_t](repeating: 0, count: capacity + 64)
    let filled = pids.withUnsafeMutableBytes {
      proc_listallpids($0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return 0 }
    var matches = 0
    var name = [CChar](repeating: 0, count: 256)
    for pid in pids.prefix(Int(filled)) where pid > 0 {
      let length = proc_name(pid, &name, UInt32(name.count))
      guard length > 0 else { continue }
      let text = String(
        decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      // proc_name truncates to MAXCOMLEN; match the visible prefix.
      if serviceName.hasPrefix(text), text.utf8.count >= 16 { matches += 1 }
    }
    return matches
  }
}

/// The capacity CI may use on one host at this moment:
/// `ceiling = total - owner reservation - external use` for CPU and memory,
/// `max_vms` for CI VMs, and the shared two-macOS-VM ceiling.
package struct HostCapacity: Sendable, Equatable {
  package static let localHost = "local"
  package static var defaultLeaseDirectory: String { NSHomeDirectory() + "/.iso/run/leases" }

  package let budget: HostBudget
  package let external: ExternalUsage

  package init(budget: HostBudget, external: ExternalUsage) {
    self.budget = budget
    self.external = external
  }

  package var cpuCeiling: UInt32 {
    let reserved = UInt64(budget.ownerReservedCPUs ?? 0) + UInt64(external.cpus)
    return UInt32(max(0, Int64(budget.cpus) - Int64(reserved)))
  }

  package var memoryCeilingMiB: UInt64 {
    let reserved = (budget.ownerReservedMemoryMiB ?? 0) &+ external.memoryMiB
    return budget.memoryMiB > reserved ? budget.memoryMiB - reserved : 0
  }

  package var effectiveBudget: HostBudget {
    HostBudget(
      maxVMs: budget.maxVMs, cpus: cpuCeiling, memoryMiB: memoryCeilingMiB,
      diskGiB: budget.diskGiB)
  }

  package static func usage(of leases: [VMLease], excluding own: Set<String>) -> ExternalUsage {
    var usage = ExternalUsage()
    for lease in leases where !own.contains(lease.sandbox) {
      usage.cpus += lease.cpus
      usage.memoryMiB += lease.memoryMiB
      usage.vms += 1
      if lease.guestOS == .macos { usage.macOSVMs += 1 }
    }
    return usage
  }
}
