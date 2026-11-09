import Foundation
import Testing

@testable import IsoCICore

/// The shared-host scheduler: one queue across pools, room reservation,
/// exclusive drains and the two-macOS-VM ceiling.
@Suite struct SchedulerTests {
  static func host(
    _ name: Name = "local", cpus: UInt32 = 8, memoryMiB: UInt64 = 32_768, maxVMs: UInt32 = 4,
    ownerCPUs: UInt32? = nil, external: ExternalUsage = .none,
    allocations: [ScheduledAllocation] = [], ineligible: String? = nil
  ) -> SchedulerHost {
    SchedulerHost(
      name: name,
      capacity: HostCapacity(
        budget: HostBudget(
          maxVMs: maxVMs, cpus: cpus, memoryMiB: memoryMiB, diskGiB: 1_024,
          ownerReservedCPUs: ownerCPUs),
        external: external),
      allocations: allocations, ineligible: ineligible)
  }

  static func request(
    _ id: String, at: EpochSeconds, cpus: UInt32 = 2, exclusive: Bool = false,
    guest: GuestOS = .linux, hosts: [Name] = ["local"]
  ) -> ScheduleRequest {
    ScheduleRequest(
      id: id, enqueuedAt: at, pool: "p", candidates: hosts,
      reservation: ResourceReservation(cpus: cpus, memoryMiB: 1_024, diskGiB: 8),
      exclusive: exclusive, guestOS: guest)
  }

  static func running(
    cpus: UInt32 = 2, exclusive: Bool = false, guest: GuestOS = .linux, idle: Bool = false
  )
    -> ScheduledAllocation
  {
    ScheduledAllocation(
      id: .generate(), reservation: ResourceReservation(cpus: cpus, memoryMiB: 1_024, diskGiB: 8),
      exclusive: exclusive, guestOS: guest, idle: idle)
  }

  /// C-T21: an 8-vCPU job behind a running 2-vCPU job reserves the host;
  /// three later 2-vCPU jobs that would fit wait; it starts once the
  /// running job exits.
  @Test func oldestStarvedJobReservesRoomAndLaterJobsWait() {
    let queue = [
      Self.request("j0", at: 10, cpus: 8), Self.request("j1", at: 11),
      Self.request("j2", at: 12), Self.request("j3", at: 13),
    ]
    let busy = Scheduler.schedule(
      requests: queue, hosts: [Self.host(allocations: [Self.running()])])
    #expect(busy.placements.isEmpty)
    #expect(busy.waiting["j0"] == .room(host: "local"))
    for id in ["j1", "j2", "j3"] {
      #expect(busy.waiting[id] == .behindReservation(host: "local", jobID: "j0"))
    }
    #expect(busy.reservations["local"]?.jobID == "j0")
    let freed = Scheduler.schedule(requests: queue, hosts: [Self.host()])
    #expect(freed.placements.map(\.request) == ["j0"])
    #expect(freed.waiting["j1"] != nil)
  }

  /// A later job may use the host while the reserved job would still fit
  /// beside it.
  @Test func laterJobsBackfillOnlyAlongsideTheReservation() {
    let queue = [Self.request("big", at: 1, cpus: 6), Self.request("small", at: 2, cpus: 2)]
    let decision = Scheduler.schedule(
      requests: queue,
      hosts: [Self.host(cpus: 12, allocations: [Self.running(cpus: 4), Self.running(cpus: 4)])])
    // 8 used of 12: big (6) waits; small (2) leaves 2, not the 6 big needs.
    #expect(decision.placements.isEmpty)
    let roomy = Scheduler.schedule(
      requests: queue, hosts: [Self.host(cpus: 16, maxVMs: 6, allocations: [Self.running(cpus: 8)])]
    )
    // 8 used of 16: big fits now and is placed first; small fits after it.
    #expect(roomy.placements.map(\.request) == ["big", "small"])
  }

  /// The queue order is (enqueued_at, id) across pools, not submission order.
  @Test func queueOrderIsAgeThenID() {
    let decision = Scheduler.schedule(
      requests: [Self.request("b", at: 5), Self.request("a", at: 5), Self.request("z", at: 1)],
      hosts: [Self.host(maxVMs: 2)])
    #expect(decision.placements.map(\.request) == ["z", "a"])
  }

  /// Owner reservation and interactive VMs come off the ceiling.
  @Test func ownerReservationAndExternalUseReduceTheCeiling() {
    let external = ExternalUsage(cpus: 2, memoryMiB: 4_096, vms: 1)
    let capacity = HostCapacity(
      budget: HostBudget(
        maxVMs: 4, cpus: 12, memoryMiB: 32_768, diskGiB: 256, ownerReservedCPUs: 2,
        ownerReservedMemoryMiB: 4_096),
      external: external)
    #expect(capacity.cpuCeiling == 8)
    #expect(capacity.memoryCeilingMiB == 24_576)
    let decision = Scheduler.schedule(
      requests: [Self.request("fits", at: 1, cpus: 6), Self.request("over", at: 2, cpus: 4)],
      hosts: [Self.host(cpus: 10, ownerCPUs: 2, external: ExternalUsage(cpus: 2))])
    #expect(decision.placements.map(\.request) == ["fits"])
  }

  /// A request larger than every ceiling never reserves (it would block
  /// the host forever).
  @Test func impossibleRequestsDoNotReserve() {
    let decision = Scheduler.schedule(
      requests: [Self.request("huge", at: 1, cpus: 64), Self.request("ok", at: 2)],
      hosts: [Self.host()])
    #expect(decision.reservations.isEmpty)
    #expect(decision.placements.map(\.request) == ["ok"])
    #expect(decision.waiting["huge"]?.code == "QUEUED_NO_HOST")
  }

  /// C-T22: the exclusive job retires the idle runner, blocks placement,
  /// waits for the running VM, then runs alone.
  @Test func exclusiveJobDrainsTheHost() {
    let idle = Self.running(idle: true)
    let busy = Self.running()
    let queue = [Self.request("x", at: 1, cpus: 8, exclusive: true), Self.request("later", at: 2)]
    let draining = Scheduler.schedule(
      requests: queue, hosts: [Self.host(allocations: [idle, busy])])
    #expect(draining.retire == [idle.id])
    #expect(draining.modes["local"] == .drainingForExclusive(jobID: "x"))
    #expect(draining.waiting["x"] == .draining(host: "local"))
    #expect(draining.waiting["later"] == .draining(host: "local"))
    #expect(draining.placements.isEmpty)
    // The idle runner is gone; the busy one still runs: keep draining.
    let still = Scheduler.schedule(
      requests: queue, hosts: [Self.host(allocations: [busy])], previous: draining.modes)
    #expect(still.modes["local"] == .drainingForExclusive(jobID: "x"))
    #expect(still.placements.isEmpty)
    let empty = Scheduler.schedule(requests: queue, hosts: [Self.host()], previous: still.modes)
    #expect(empty.placements.map(\.request) == ["x"])
    #expect(empty.modes["local"] == .exclusiveBusy)
    #expect(empty.waiting["later"] == .draining(host: "local"))
    // While it runs, nothing else is placed; afterwards scheduling resumes.
    let running = Scheduler.schedule(
      requests: [Self.request("later", at: 2)],
      hosts: [Self.host(allocations: [Self.running(cpus: 8, exclusive: true)])])
    #expect(running.modes["local"] == .exclusiveBusy && running.placements.isEmpty)
    let after = Scheduler.schedule(requests: [Self.request("later", at: 2)], hosts: [Self.host()])
    #expect(after.placements.map(\.request) == ["later"])
  }

  /// The exclusive job picks the host that drains fastest and keeps it.
  @Test func exclusiveJobKeepsItsDrainingHost() {
    let request = Self.request("x", at: 1, cpus: 4, exclusive: true, hosts: ["a", "b"])
    let first = Scheduler.schedule(
      requests: [request],
      hosts: [
        Self.host("a", allocations: [Self.running(), Self.running()]),
        Self.host("b", allocations: [Self.running()]),
      ])
    #expect(first.modes["b"] == .drainingForExclusive(jobID: "x"))
    #expect(first.modes["a"] == .normal)
    let second = Scheduler.schedule(
      requests: [request],
      hosts: [
        Self.host("a"),
        Self.host("b", allocations: [Self.running()]),
      ], previous: first.modes)
    #expect(second.modes["b"] == .drainingForExclusive(jobID: "x"))
    #expect(second.placements.isEmpty)
  }

  /// A drain that moves to another host releases the first one.
  @Test func oneExclusiveRequestDrainsOneHost() {
    let request = Self.request("x", at: 1, cpus: 4, exclusive: true, hosts: ["a", "b"])
    let first = Scheduler.schedule(
      requests: [request],
      hosts: [
        Self.host("a", allocations: [Self.running()]),
        Self.host("b", allocations: [Self.running(), Self.running()]),
      ])
    #expect(first.modes["a"] == .drainingForExclusive(jobID: "x"))
    let moved = Scheduler.schedule(
      requests: [request],
      hosts: [
        Self.host("a", allocations: [Self.running()], ineligible: "quarantined"),
        Self.host("b", allocations: [Self.running()]),
      ], previous: first.modes)
    #expect(moved.modes["b"] == .drainingForExclusive(jobID: "x"))
    #expect(moved.modes["a"] == .normal)
  }

  /// C-T23: one interactive macOS VM plus one CI macOS VM fill the
  /// Virtualization.framework ceiling; the next macOS job waits, Linux does not.
  @Test func macOSJobsWaitForAVirtualizationSlot() {
    let hosts = [
      Self.host(
        external: ExternalUsage(cpus: 4, memoryMiB: 8_192, vms: 1, macOSVMs: 1),
        allocations: [Self.running(guest: .macos)])
    ]
    let decision = Scheduler.schedule(
      requests: [Self.request("mac", at: 1, guest: .macos), Self.request("lin", at: 2)],
      hosts: hosts)
    #expect(decision.waiting["mac"] == .vzSlot)
    #expect(decision.waiting["mac"]?.code == "QUEUED_WAITING_VZ_SLOT")
    #expect(decision.placements.map(\.request) == ["lin"])
    let released = Scheduler.schedule(
      requests: [Self.request("mac", at: 1, guest: .macos)],
      hosts: [Self.host(allocations: [Self.running(guest: .macos)])])
    #expect(released.placements.map(\.request) == ["mac"])
  }

  @Test func ineligibleHostsAreReported() {
    let decision = Scheduler.schedule(
      requests: [Self.request("j", at: 1)], hosts: [Self.host(ineligible: "qualification expired")])
    #expect(decision.waiting["j"] == .noHost("local: qualification expired"))
  }

  /// Preflight placement honours the board's drains and reservations.
  @Test func boardRefusesPlacementOutsideTheQueue() {
    let board = SchedulerBoard()
    var snapshot = SchedulerBoard.Snapshot()
    snapshot.modes = ["a": .drainingForExclusive(jobID: "x"), "b": .normal]
    snapshot.reservations = [
      "b": RoomReservation(Self.request("big", at: 1, cpus: 6))
    ]
    board.publish(snapshot)
    let budget = HostBudget(maxVMs: 4, cpus: 8, memoryMiB: 32_768, diskGiB: 1_024)
    let need = ResourceReservation(cpus: 2, memoryMiB: 1_024, diskGiB: 8)
    #expect(board.refusal(host: "a", adding: need, load: HostLoad(), budget: budget) != nil)
    #expect(board.refusal(host: "b", adding: need, load: HostLoad(), budget: budget) == nil)
    var load = HostLoad()
    load.add(need)
    #expect(board.refusal(host: "b", adding: need, load: load, budget: budget) != nil)
  }
}

/// Lease files written by iso-sandbox owners, probed with `flock`.
@Suite struct HostCapacityTests {
  static func writeLease(
    _ directory: String, _ sandbox: String, guest: String, cpus: Int, lock: Bool
  )
    throws -> Int32
  {
    let path = "\(directory)/\(sandbox).json"
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(fd >= 0)
    let body =
      #"{"cpus":\#(cpus),"guest_os":"\#(guest)","memory_mib":4096,"pid":1,"sandbox":"\#(sandbox)","schema":"iso.vm-lease/v1","started_at":"2026-11-09T00:00:00Z"}"#
    _ = body.withCString { write(fd, $0, strlen($0)) }
    if lock { #expect(flock(fd, LOCK_EX | LOCK_NB) == 0) }
    return fd
  }

  @Test func onlyLockedLeasesCountAndOwnVMsAreExcluded() throws {
    let directory = scratchDirectory("leases")
    try PrivateFiles.ensureDirectory(directory)
    let mac = try Self.writeLease(directory, "iso-mac-1", guest: "macos", cpus: 4, lock: true)
    let linux = try Self.writeLease(directory, "iso-lin-1", guest: "linux", cpus: 2, lock: true)
    let ci = try Self.writeLease(directory, "iso-ci-1", guest: "linux", cpus: 4, lock: true)
    let stale = try Self.writeLease(directory, "iso-old", guest: "macos", cpus: 8, lock: false)
    try PrivateFiles.write(Array("not json".utf8), to: directory + "/garbage.json")
    defer { for fd in [linux, ci, stale] { close(fd) } }
    let leases = LeaseDirectory.live(directory)
    #expect(Set(leases.map(\.sandbox)) == ["iso-mac-1", "iso-lin-1", "iso-ci-1"])
    let probe = LocalExternalUsageProbe(leaseDirectory: directory)
    let budget = HostBudget(maxVMs: 2, cpus: 12, memoryMiB: 32_768, diskGiB: 256)
    let usage = probe.usage(host: "local", budget: budget, own: ["iso-ci-1"])
    #expect(usage == ExternalUsage(cpus: 6, memoryMiB: 8_192, vms: 2, macOSVMs: 1))
    // Only the local host's leases are readable.
    #expect(probe.usage(host: "remote", budget: budget, own: []) == .none)
    // A released lease stops counting.
    close(mac)
    #expect(probe.usage(host: "local", budget: budget, own: ["iso-ci-1"]).macOSVMs == 0)
  }

  @Test func leaseParsingIsStrict() {
    let good =
      #"{"cpus":4,"guest_os":"macos","memory_mib":8192,"sandbox":"iso-a","schema":"iso.vm-lease/v1"}"#
    #expect(VMLease.parse(Array(good.utf8))?.guestOS == .macos)
    for bad in [
      good.replacingOccurrences(of: "v1", with: "v9"),
      good.replacingOccurrences(of: "macos", with: "windows"),
      good.replacingOccurrences(of: "iso-a", with: "../x"),
      good.replacingOccurrences(of: "\"cpus\":4", with: "\"cpus\":-1"),
    ] {
      #expect(VMLease.parse(Array(bad.utf8)) == nil)
    }
  }
}
