import Foundation
import Synchronization

/// One reconciling part of the controller (the GitHub pool reconciler, the
/// preflight session manager). Each pass catches and records its own
/// failures; `handle` returns nil for methods it does not own.
package protocol ControllerService: Sendable {
  var name: String { get }
  func reconcile(now: EpochSeconds)
  func handle(_ request: ControlRequest) -> Result<JSONValue, CIError>?
  func status() -> JSONValue
}

/// Converts an `Encodable` record to `JSONValue` for control replies.
package func jsonValue<T: Encodable>(_ value: T) -> JSONValue {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(value),
    let parsed = try? StrictJSON.parse(
      data, limits: .init(maxBytes: 16 << 20, maxKeys: 1 << 20, maxArrayElements: 1 << 18))
  else { return .null }
  return parsed
}

/// The durable controller for one operator data root (spec section 3). It
/// holds the ownership lock, serves the private control channel, and runs
/// reconciliation passes. Workload leases belong to the controller, not to
/// an attached terminal: a disconnected CLI never revokes them.
package final class Controller: Sendable {
  package let root: DataRoot
  package let store: ControllerStore
  package let driver: AllocationDriver
  package let hosts: HostDirectory
  private let services: Mutex<[any ControllerService]>
  private let configuration: Mutex<(CIConfiguration?, String?)>
  private let debugSessions = Mutex<[String: GuestSession]>([:])
  package let interval: TimeInterval

  package init(
    root: DataRoot, store: ControllerStore, driver: AllocationDriver, hosts: HostDirectory,
    configuration: CIConfiguration?, configurationError: String?, interval: TimeInterval = 15
  ) {
    self.root = root
    self.store = store
    self.driver = driver
    self.hosts = hosts
    self.services = Mutex([])
    self.configuration = Mutex((configuration, configurationError))
    self.interval = interval
  }

  package func add(_ service: any ControllerService) { services.withLock { $0.append(service) } }

  /// Takes the ownership lock and serves until the process is stopped.
  package func run() throws(CIError) -> Never {
    try root.prepare()
    guard let lock = try OwnershipLock.attempt(path: root.lock) else {
      throw CIError(.controllerBusy, "another iso-ci controller owns \(root.path)")
    }
    let server = ControlServer(path: root.controlSocket) { [self] request in handle(request) }
    try server.start()
    try store.event("controller", "controller.started", "controller started (pid \(getpid()))")
    signal(SIGPIPE, SIG_IGN)
    while true {
      reconcile()
      Thread.sleep(forTimeInterval: interval)
    }
    _ = lock
  }

  private let passLock = NSLock()

  /// One pass over every service, then cleanup-debt retries. Passes are
  /// serialized: a control-requested pass never overlaps the loop's.
  package func reconcile() {
    passLock.lock()
    defer { passLock.unlock() }
    let now = store.now
    refreshHostCapabilities(now: now)
    for service in services.withLock({ $0 }) { service.reconcile(now: now) }
    retryCleanupDebt()
  }

  /// How long a host capability snapshot is trusted for placement.
  package static let capabilityRefreshSeconds: UInt64 = 60

  /// Placement reads cached snapshots; refresh stale ones so evidence
  /// recorded or withdrawn after `enable` reaches placement.
  private func refreshHostCapabilities(now: EpochSeconds) {
    guard let records = try? store.hosts() else { return }
    for record in records where record.state == .enabled {
      if let observed = record.observedAt, now >= observed,
        now < observed &+ Self.capabilityRefreshSeconds
      {
        continue
      }
      try? hosts.refreshCapabilities(record.alias)
    }
  }

  /// Allocations whose cleanup is unverified are retried each pass and stay
  /// visible (and budgeted) until verified.
  private func retryCleanupDebt() {
    guard let open = try? store.openAllocations() else { return }
    for allocation in open where allocation.vmCleanup == .debt || allocation.desired == .release {
      if allocation.job != nil && allocation.desired != .release { continue }
      do { try driver.release(allocation.id) } catch {
        _ = try? store.event(
          "allocation:\(allocation.id)", "cleanup.retry_failed",
          "cleanup still unverified: \(error.message)")
      }
    }
  }

  // MARK: Control dispatch

  package func handle(_ request: ControlRequest) -> Result<JSONValue, CIError> {
    do throws(CIError) {
      switch request.method {
      case "ping":
        return .success([
          "version": .string(IsoCIVersion.current),
          "controller_id": .string(try store.controllerID().rawValue),
          "pid": .integer(Int64(getpid())),
        ])
      case "status":
        return .success(try status())
      case "events":
        return .success(try events(request.params))
      case "results":
        var r = try ObjectReader(request.params, field: "params")
        let id = try r.parsed("allocation") { try AllocationID($0) }
        let save = try r.optionalString("save")
        try r.finish()
        if let save, !save.hasPrefix("/") {
          throw CIError.invalid("results --save needs an absolute directory")
        }
        return .success(try driver.results(id, saveInto: save))
      case "inspect":
        return .success(try inspect(request.params))
      case "host.enable":
        var r = try ObjectReader(request.params, field: "params")
        let alias = try r.parsed("host", as: Name.self)
        try r.finish()
        return .success(jsonValue(try hosts.enable(alias)))
      case "debug.open":
        return .success(try openDebug(request.params))
      case "debug.close":
        var r = try ObjectReader(request.params, field: "params")
        let id = try r.string("session")
        try r.finish()
        debugSessions.withLock { $0.removeValue(forKey: id) }?.close()
        return .success(["closed": true])
      case "approve":
        return .success(try approve(request.params))
      case "reconcile":
        reconcile()
        return .success(["ok": true])
      default:
        for service in services.withLock({ $0 }) {
          if let result = service.handle(request) { return result }
        }
        return .failure(CIError(.unsupported, "unknown control method \(request.method)"))
      }
    } catch {
      return .failure(error)
    }
  }

  /// Records the operator's approval of every descriptor digest the current
  /// configuration uses (or only those listed). `dry_run` reports without
  /// recording, so setup can show what is being approved first.
  private func approve(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let dryRun = try r.optionalBool("dry_run") ?? false
    try r.finish()
    let config = try CIConfiguration.load(path: root.configuration)
    configuration.withLock { $0 = (config, nil) }
    var rows: [JSONValue] = []
    var seen: Set<String> = []
    for profile in config.profiles.keys.sorted() {
      for (kind, name, digest) in config.descriptors(of: profile)
      where seen.insert("\(kind.rawValue)/\(name)").inserted {
        let previous = try store.approval(kind, name)
        let changed = previous?.digest != digest
        if !dryRun && changed {
          try store.save(
            ApprovalRecord(kind: kind, name: name, digest: digest, approvedAt: store.now))
          try store.event(
            "approvals", "descriptor.approved", "\(kind.rawValue) \(name) approved",
            data: ["digest": digest.rawValue])
        }
        rows.append([
          "kind": .string(kind.rawValue), "name": .string(name.rawValue),
          "digest": .string(digest.rawValue), "changed": .bool(changed),
          "previous": previous.map { .string($0.digest.rawValue) } ?? .null,
        ])
      }
    }
    return ["approved": .bool(!dryRun), "descriptors": .array(rows)]
  }

  private func status() throws(CIError) -> JSONValue {
    let (config, configError) = configuration.withLock { $0 }
    let open = try store.openAllocations()
    var hostsSection: [JSONValue] = []
    for host in try store.hosts() {
      let usage = HostLoad.of(open.filter { $0.host == host.alias })
      hostsSection.append([
        "alias": .string(host.alias.rawValue), "state": .string(host.state.rawValue),
        "reason": host.reason.map(JSONValue.string) ?? .null,
        "net_handoff_1": .bool(
          host.capabilities?.advertised.contains(HostCapabilityName.netHandoff1.rawValue) ?? false),
        "qualification": .string(host.capabilities?.qualificationStatus ?? "unknown"),
        "qualification_digest": host.capabilities?.qualificationDigest.map { .string($0.rawValue) }
          ?? .null,
        "qualified_image": host.capabilities?.qualificationTuple["image"].map(JSONValue.string)
          ?? .null,
        "live_vms": .integer(Int64(usage.vms)), "uncertain": .integer(Int64(usage.uncertain)),
        "observed_at": host.observedAt.map { .integer(Int64($0)) } ?? .null,
      ])
    }
    var allocations: [JSONValue] = []
    var debt: [JSONValue] = []
    for allocation in open {
      let row: JSONValue = [
        "id": .string(allocation.id.rawValue), "kind": .string(allocation.kind.rawValue),
        "pool": allocation.pool.map { .string($0.rawValue) } ?? .null,
        "preflight_run": allocation.preflightRun.map { .string($0.rawValue) } ?? .null,
        "host": .string(allocation.host.rawValue), "phase": .string(allocation.phase),
        "execution": .string(allocation.execution.rawValue),
        "export": .string(allocation.export.rawValue),
        "vm_cleanup": .string(allocation.vmCleanup.rawValue),
        "registration": .string(allocation.registration.rawValue),
        "uncertainty": allocation.uncertainty.map(JSONValue.string) ?? .null,
        "job": allocation.job.map { jsonValue($0) } ?? .null,
      ]
      allocations.append(row)
      if allocation.vmCleanup == .debt || allocation.uncertainty != nil
        || allocation.registration == .uncertain || allocation.registration == .removalPending
      {
        debt.append(row)
      }
    }
    var servicesSection: [String: JSONValue] = [:]
    for service in services.withLock({ $0 }) { servicesSection[service.name] = service.status() }
    return [
      "controller_id": .string(try store.controllerID().rawValue),
      "configuration": config == nil
        ? ["valid": false, "error": .string(configError ?? "missing")] : ["valid": true],
      "hosts": .array(hostsSection), "allocations": .array(allocations),
      "unresolved_cleanup": .array(debt), "services": .object(servicesSection),
    ]
  }

  private func events(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let after = try r.optionalInt("after") ?? 0
    let limit = Int(try r.optionalInt("limit") ?? 200)
    var subject = try r.optionalString("subject")
    if let raw = subject, isCanonicalUUID(raw) {
      let isAllocation = try store.allocation(try AllocationID(raw)) != nil
      subject = isAllocation ? "allocation:\(raw)" : "run:\(raw)"
    }
    try r.finish()
    let records = try store.events(after: after, subject: subject, limit: limit)
    return [
      "events": .array(records.map { jsonValue($0) }),
      "cursor": .integer(records.last?.sequence ?? after),
    ]
  }

  private func inspect(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let target = try r.string("target")
    try r.finish()
    if let id = try? AllocationID(target), let record = try store.allocation(id) {
      return [
        "allocation": jsonValue(record), "phase": .string(record.phase),
        "intents": .array(try store.intents(allocation: id).map { jsonValue($0) }),
      ]
    }
    for service in services.withLock({ $0 }) {
      if let result = service.handle(
        ControlRequest(method: "inspect.\(service.name)", params: ["target": .string(target)])),
        case .success(let value) = result
      {
        return value
      }
    }
    throw CIError(.notFound, "nothing named \(CIError.bounded(String(target.prefix(64))))")
  }

  /// Explicitly authorized access to a retained environment. No new
  /// privileged credentials are acquired; existing guest state may hold some.
  private func openDebug(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let id = try r.parsed("allocation", as: AllocationID.self)
    try r.finish()
    guard let record = try store.allocation(id) else {
      throw CIError(.notFound, "unknown allocation")
    }
    guard record.desired == .retainLive, record.observedRunPhase == .running else {
      throw CIError(
        .conflict, "debug needs a live-retained allocation (current phase: \(record.phase))")
    }
    let session = try driver.debugSession(id)
    let key = session.grant.session.rawValue
    debugSessions.withLock { $0[key] = session }
    try store.event("allocation:\(id)", "debug.opened", "operator debug session opened")
    return [
      "session": .string(key), "ssh": .string(session.sshExecutable),
      "arguments": .array(session.interactiveArguments.map { .string($0) }),
      "lease_expires_at": .integer(Int64(session.grant.leaseExpiresAt)),
    ]
  }
}
