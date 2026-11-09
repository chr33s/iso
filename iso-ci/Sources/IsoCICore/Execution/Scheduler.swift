import Foundation
import Synchronization

/// One unit of pending CI demand: a scale-set job awaiting a runner, or one
/// missing warm-pool runner.
package struct ScheduleRequest: Sendable, Equatable {
  package let id: String
  package let enqueuedAt: EpochSeconds
  package let pool: Name
  /// Hosts the pool may use, in configuration order.
  package let candidates: [Name]
  package let reservation: ResourceReservation
  package let exclusive: Bool
  package let guestOS: GuestOS

  package init(
    id: String, enqueuedAt: EpochSeconds, pool: Name, candidates: [Name],
    reservation: ResourceReservation, exclusive: Bool = false, guestOS: GuestOS = .linux
  ) {
    self.id = id
    self.enqueuedAt = enqueuedAt
    self.pool = pool
    self.candidates = candidates
    self.reservation = reservation
    self.exclusive = exclusive
    self.guestOS = guestOS
  }

  /// The single queue order across every pool: oldest first, then id.
  package static func precedes(_ a: Self, _ b: Self) -> Bool {
    a.enqueuedAt != b.enqueuedAt ? a.enqueuedAt < b.enqueuedAt : a.id < b.id
  }
}

/// A CI allocation that holds resources on a host.
package struct ScheduledAllocation: Sendable, Equatable {
  package let id: AllocationID
  package let reservation: ResourceReservation
  package let exclusive: Bool
  package let guestOS: GuestOS
  /// A ready warm runner with no job, which may be retired to drain a host.
  package let idle: Bool

  package init(
    id: AllocationID, reservation: ResourceReservation, exclusive: Bool = false,
    guestOS: GuestOS = .linux, idle: Bool = false
  ) {
    self.id = id
    self.reservation = reservation
    self.exclusive = exclusive
    self.guestOS = guestOS
    self.idle = idle
  }
}

/// What the scheduler knows about one host this tick.
package struct SchedulerHost: Sendable, Equatable {
  package let name: Name
  package let capacity: HostCapacity
  /// Physical slots the host reports (0 = unknown, not limiting).
  package let slots: UInt64
  package let allocations: [ScheduledAllocation]
  /// Why the host takes no new work at all (disabled, unqualified), or nil.
  package let ineligible: String?

  package init(
    name: Name, capacity: HostCapacity, slots: UInt64 = 0, allocations: [ScheduledAllocation],
    ineligible: String? = nil
  ) {
    self.name = name
    self.capacity = capacity
    self.slots = slots
    self.allocations = allocations
    self.ineligible = ineligible
  }
}

/// Room held on a host for the oldest job that is waiting only for
/// capacity there; later jobs may not take the capacity it accumulates.
package struct RoomReservation: Sendable, Equatable, Codable {
  package let jobID: String
  package let cpus: UInt32
  package let memoryMiB: UInt64
  package let diskGiB: UInt64
  package let exclusive: Bool

  package init(_ request: ScheduleRequest) {
    jobID = request.id
    cpus = request.reservation.cpus
    memoryMiB = request.reservation.memoryMiB
    diskGiB = request.reservation.diskGiB
    exclusive = request.exclusive
  }

  package var reservation: ResourceReservation {
    ResourceReservation(cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB)
  }
}

package enum HostMode: Sendable, Equatable {
  case normal
  /// Retiring idle runners and placing nothing until the host is empty.
  case drainingForExclusive(jobID: String)
  /// An exclusive allocation is booting or running alone.
  case exclusiveBusy

  package var label: String {
    switch self {
    case .normal: "NORMAL"
    case .drainingForExclusive: "DRAINING_FOR_EXCLUSIVE"
    case .exclusiveBusy: "EXCLUSIVE_BUSY"
    }
  }

  package var admitsPlacement: Bool { self == .normal }
}

/// Why a request was not placed this tick.
package enum WaitReason: Sendable, Equatable {
  /// Two macOS VMs already run on every candidate host.
  case vzSlot
  /// Holds the room reservation on `host` and waits for capacity there.
  case room(host: Name)
  /// Waits behind an earlier job's room reservation.
  case behindReservation(host: Name, jobID: String)
  /// Its host is draining (for this job or another exclusive job).
  case draining(host: Name)
  /// No candidate host is eligible, or none could ever fit it.
  case noHost(String)

  package var code: String {
    switch self {
    case .vzSlot: "QUEUED_WAITING_VZ_SLOT"
    case .room: "QUEUED_WAITING_ROOM"
    case .behindReservation: "QUEUED_BEHIND_RESERVATION"
    case .draining: "QUEUED_WAITING_DRAIN"
    case .noHost: "QUEUED_NO_HOST"
    }
  }

  package var detail: String {
    switch self {
    case .vzSlot: "two macOS VMs already run on every candidate host"
    case .room(let host): "room reserved on \(host); waiting for running work to finish"
    case .behindReservation(let host, let job): "behind \(job)'s room reservation on \(host)"
    case .draining(let host): "\(host) is draining for an exclusive job"
    case .noHost(let reason): reason
    }
  }
}

package struct CapacityDecision: Sendable, Equatable {
  /// Requests to start now, in queue order, with their host.
  package var placements: [(request: String, host: Name)] = []
  package var waiting: [String: WaitReason] = [:]
  package var reservations: [Name: RoomReservation] = [:]
  package var modes: [Name: HostMode] = [:]
  /// Idle allocations to retire so a host can drain for an exclusive job.
  package var retire: [AllocationID] = []

  package init() {}

  package static func == (a: Self, b: Self) -> Bool {
    a.placements.map { "\($0.request)@\($0.host)" }
      == b.placements.map { "\($0.request)@\($0.host)" }
      && a.waiting == b.waiting && a.reservations == b.reservations && a.modes == b.modes
      && a.retire == b.retire
  }
}

/// Deterministic anti-starvation scheduling across every pool sharing a set
/// of hosts (one tick, no I/O). Requests are taken in one queue ordered by
/// `(enqueued_at, id)`:
///
/// - The oldest request that waits only for capacity on a host reserves room
///   there. A later request may use that host only if, after it is placed,
///   the reserved request would still fit; otherwise it waits, and capacity
///   freed by finishing work accumulates for the reserved request.
/// - An exclusive request drains its host: idle runners there are retired,
///   nothing else is placed, and it starts once the host has no CI
///   allocation. The host stays exclusive while it runs.
/// - A macOS request waits while two macOS VMs (CI and external) run.
package enum Scheduler {
  /// `previous` carries the last tick's host modes, so a host that began
  /// draining for an exclusive request keeps draining for it.
  package static func schedule(
    requests: [ScheduleRequest], hosts: [SchedulerHost], previous: [Name: HostMode] = [:]
  ) -> CapacityDecision {
    var decision = CapacityDecision()
    var state: [Name: HostTick] = [:]
    let pending = Set(requests.filter(\.exclusive).map(\.id))
    for host in hosts {
      var tick = HostTick(host)
      if host.allocations.contains(where: \.exclusive) {
        tick.mode = .exclusiveBusy
      } else if case .drainingForExclusive(let job)? = previous[host.name], pending.contains(job) {
        tick.mode = .drainingForExclusive(jobID: job)
      }
      state[host.name] = tick
      decision.modes[host.name] = tick.mode
    }
    for request in requests.sorted(by: ScheduleRequest.precedes) {
      let candidates = request.candidates.filter { state[$0] != nil }
      if candidates.isEmpty {
        decision.waiting[request.id] = .noHost("no configured host is known")
        continue
      }
      let eligible = candidates.filter { state[$0]?.host.ineligible == nil }
      if eligible.isEmpty {
        decision.waiting[request.id] = .noHost(
          candidates.compactMap { name in state[name]?.host.ineligible.map { "\(name): \($0)" } }
            .joined(separator: "; "))
        continue
      }
      let fitting = eligible.filter { state[$0]!.couldEverFit(request) }
      if fitting.isEmpty {
        decision.waiting[request.id] = .noHost(
          "larger than the CI ceiling of every candidate host")
        continue
      }
      if request.guestOS == .macos,
        fitting.allSatisfy({ state[$0]!.macOSVMs >= UInt32(GuestOS.macOSVMCeiling) })
      {
        decision.waiting[request.id] = .vzSlot
        continue
      }
      let usable = fitting.filter {
        request.guestOS != .macos || state[$0]!.macOSVMs < UInt32(GuestOS.macOSVMCeiling)
      }
      if request.exclusive {
        placeExclusive(request, usable, &state, &decision)
      } else {
        placeShared(request, usable, &state, &decision)
      }
    }
    for (name, tick) in state {
      decision.modes[name] = tick.mode
      if let reservation = tick.reservation { decision.reservations[name] = reservation }
    }
    decision.retire.sort { $0.rawValue < $1.rawValue }
    return decision
  }

  private static func placeShared(
    _ request: ScheduleRequest, _ hosts: [Name], _ state: inout [Name: HostTick],
    _ decision: inout CapacityDecision
  ) {
    var firstBlock: WaitReason?
    var roomCandidate: Name?
    for name in preference(hosts, state) {
      let tick = state[name]!
      guard tick.mode.admitsPlacement else {
        firstBlock = firstBlock ?? .draining(host: name)
        continue
      }
      if !tick.fits(request.reservation) {
        if tick.reservation == nil { roomCandidate = roomCandidate ?? name }
        if let held = tick.reservation {
          firstBlock = firstBlock ?? .behindReservation(host: name, jobID: held.jobID)
        }
        continue
      }
      if let held = tick.reservation,
        !tick.fits(request.reservation, alongside: held.reservation)
      {
        firstBlock = firstBlock ?? .behindReservation(host: name, jobID: held.jobID)
        continue
      }
      state[name]!.add(request)
      decision.placements.append((request.id, name))
      return
    }
    if let name = roomCandidate {
      state[name]!.reservation = RoomReservation(request)
      decision.waiting[request.id] = .room(host: name)
    } else {
      decision.waiting[request.id] = firstBlock ?? .noHost("no candidate host admits it")
    }
  }

  private static func placeExclusive(
    _ request: ScheduleRequest, _ hosts: [Name], _ state: inout [Name: HostTick],
    _ decision: inout CapacityDecision
  ) {
    // A host already draining for this request keeps it; otherwise the
    // normal host with the fewest CI allocations drains fastest.
    let target =
      hosts.first { state[$0]!.mode == .drainingForExclusive(jobID: request.id) }
      ?? hosts.filter { name in
        state[name]!.mode == .normal
          && (state[name]!.reservation == nil || state[name]!.reservation?.jobID == request.id)
      }.min { a, b in
        let ca = state[a]!.vms
        let cb = state[b]!.vms
        return ca != cb ? ca < cb : a < b
      }
    guard let name = target else {
      let busy = hosts.first.map { WaitReason.draining(host: $0) }
      decision.waiting[request.id] = busy ?? .noHost("no candidate host can drain")
      return
    }
    // One request drains one host: an earlier drain elsewhere ends.
    for other in state.keys where other != name {
      if state[other]!.mode == .drainingForExclusive(jobID: request.id) {
        state[other]!.mode = .normal
        if state[other]!.reservation?.jobID == request.id { state[other]!.reservation = nil }
      }
    }
    var tick = state[name]!
    if tick.vms == 0 && tick.fits(request.reservation) {
      tick.add(request)
      tick.mode = .exclusiveBusy
      tick.reservation = nil
      state[name] = tick
      decision.placements.append((request.id, name))
      return
    }
    tick.mode = .drainingForExclusive(jobID: request.id)
    tick.reservation = RoomReservation(request)
    for allocation in tick.host.allocations where allocation.idle {
      if !decision.retire.contains(allocation.id) { decision.retire.append(allocation.id) }
    }
    state[name] = tick
    decision.waiting[request.id] = .draining(host: name)
  }

  /// Least utilized first, then name: deterministic and fair enough without
  /// a cross-tick history.
  private static func preference(_ hosts: [Name], _ state: [Name: HostTick]) -> [Name] {
    hosts.sorted { a, b in
      let ra = state[a]!.utilization
      let rb = state[b]!.utilization
      return ra != rb ? ra < rb : a < b
    }
  }

  /// Mutable per-host accounting within one tick.
  private struct HostTick {
    let host: SchedulerHost
    var mode: HostMode = .normal
    var reservation: RoomReservation?
    var vms: UInt32
    var cpus: UInt64
    var memoryMiB: UInt64
    var diskGiB: UInt64
    var macOSVMs: UInt32

    init(_ host: SchedulerHost) {
      self.host = host
      vms = UInt32(host.allocations.count)
      cpus = host.allocations.reduce(0) { $0 + UInt64($1.reservation.cpus) }
      memoryMiB = host.allocations.reduce(0) { $0 + $1.reservation.memoryMiB }
      diskGiB = host.allocations.reduce(0) { $0 + $1.reservation.diskGiB }
      macOSVMs =
        UInt32(host.allocations.filter { $0.guestOS == .macos }.count)
        + host.capacity.external.macOSVMs
    }

    var budget: HostBudget { host.capacity.effectiveBudget }

    var utilization: Double {
      budget.maxVMs == 0 ? Double(vms) : Double(vms) / Double(budget.maxVMs)
    }

    func couldEverFit(_ request: ScheduleRequest) -> Bool {
      budget.maxVMs >= 1 && UInt64(request.reservation.cpus) <= UInt64(budget.cpus)
        && request.reservation.memoryMiB <= budget.memoryMiB
        && request.reservation.diskGiB <= budget.diskGiB
    }

    func fits(_ need: ResourceReservation, alongside held: ResourceReservation? = nil) -> Bool {
      let extraVMs: UInt64 = held == nil ? 1 : 2
      if host.slots > 0, UInt64(vms) + extraVMs > host.slots { return false }
      return UInt64(vms) + extraVMs <= UInt64(budget.maxVMs)
        && cpus + UInt64(need.cpus) + UInt64(held?.cpus ?? 0) <= UInt64(budget.cpus)
        && memoryMiB + need.memoryMiB + (held?.memoryMiB ?? 0) <= budget.memoryMiB
        && diskGiB + need.diskGiB + (held?.diskGiB ?? 0) <= budget.diskGiB
    }

    mutating func add(_ request: ScheduleRequest) {
      vms += 1
      cpus += UInt64(request.reservation.cpus)
      memoryMiB += request.reservation.memoryMiB
      diskGiB += request.reservation.diskGiB
      if request.guestOS == .macos { macOSVMs += 1 }
    }
  }
}

/// The latest scheduling outcome, shared with every placement path so that
/// preflight admission honours the same reservations, drains and external
/// usage as connected pools.
package final class SchedulerBoard: Sendable {
  package struct Snapshot: Sendable, Equatable {
    package var modes: [Name: HostMode] = [:]
    package var reservations: [Name: RoomReservation] = [:]
    package var external: [Name: ExternalUsage] = [:]
    package var waiting: [String: WaitReason] = [:]
    package var queue: [ScheduleRequest] = []

    package init() {}
  }

  private let state = Mutex(Snapshot())

  package init() {}

  package var snapshot: Snapshot { state.withLock { $0 } }

  package func publish(_ snapshot: Snapshot) { state.withLock { $0 = snapshot } }

  package func setExternal(_ usage: ExternalUsage, for host: Name) {
    state.withLock { $0.external[host] = usage }
  }

  /// Why a placement outside the queue (preflight) may not use `host` now.
  package func refusal(
    host: Name, adding need: ResourceReservation, load: HostLoad, budget: HostBudget
  )
    -> String?
  {
    let snapshot = self.snapshot
    let mode = snapshot.modes[host] ?? .normal
    guard mode.admitsPlacement else { return mode.label.lowercased() }
    if let held = snapshot.reservations[host] {
      let fits =
        load.vms + 2 <= budget.maxVMs
        && UInt64(load.cpus) + UInt64(need.cpus) + UInt64(held.cpus) <= UInt64(budget.cpus)
        && load.memoryMiB + need.memoryMiB + held.memoryMiB <= budget.memoryMiB
        && load.diskGiB + need.diskGiB + held.diskGiB <= budget.diskGiB
      if !fits { return "room reserved for \(held.jobID)" }
    }
    return nil
  }
}

/// `iso-ci status` → `services.scheduler`: the shared queue with each
/// request's wait reason, host modes, room reservations and external use.
package final class SchedulerStatusService: ControllerService {
  package let name = "scheduler"
  let board: SchedulerBoard

  package init(board: SchedulerBoard) { self.board = board }

  package func reconcile(now: EpochSeconds) {}

  package func handle(_ request: ControlRequest) -> Result<JSONValue, CIError>? { nil }

  package func status() -> JSONValue {
    let snapshot = board.snapshot
    let queue: [JSONValue] = snapshot.queue.map { request in
      let wait = snapshot.waiting[request.id]
      return [
        "id": .string(request.id), "pool": .string(request.pool.rawValue),
        "enqueued_at": .integer(Int64(request.enqueuedAt)),
        "cpus": .integer(Int64(request.reservation.cpus)),
        "memory_mib": .integer(Int64(request.reservation.memoryMiB)),
        "exclusive": .bool(request.exclusive), "guest_os": .string(request.guestOS.rawValue),
        "state": .string(wait?.code ?? "PLACED"),
        "detail": wait.map { .string($0.detail) } ?? .null,
      ]
    }
    var hosts: [String: JSONValue] = [:]
    for name in Set(snapshot.modes.keys).union(snapshot.external.keys).sorted() {
      let external = snapshot.external[name] ?? .none
      hosts[name.rawValue] = [
        "mode": .string((snapshot.modes[name] ?? .normal).label),
        "reservation": snapshot.reservations[name].map { jsonValue($0) } ?? .null,
        "external": [
          "cpus": .integer(Int64(external.cpus)), "memory_mib": .integer(Int64(external.memoryMiB)),
          "vms": .integer(Int64(external.vms)), "macos_vms": .integer(Int64(external.macOSVMs)),
        ],
      ]
    }
    return ["queue": .array(queue), "hosts": .object(hosts)]
  }
}
