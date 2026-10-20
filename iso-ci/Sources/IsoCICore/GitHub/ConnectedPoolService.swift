import Foundation
import Synchronization

/// The controller service for GitHub-connected pools: per pass it validates
/// configuration and approvals, evaluates GitHub-side authority, and runs
/// each pool's ready-capacity reconciler. Invalid or partial configuration,
/// unapproved descriptors and unverifiable authority leave a pool inactive.
package final class ConnectedPoolService: ControllerService {
  /// How long a GitHub-side authority evaluation is reused. A loosened
  /// control (a runner group that starts admitting public repositories, a
  /// widened permission) deactivates the pool, and retires its idle
  /// runners, within this window.
  package static let activationInterval: EpochSeconds = 60

  package let name = "pools"
  private let store: ControllerStore
  private let provider: any EnvironmentProvider
  private let loadConfiguration: @Sendable () -> Result<CIConfiguration, CIError>
  private let clients: @Sendable (InstallationRecord) throws(CIError) -> GitHubInstallationClient
  private let state = Mutex<State>(State())
  private let api: GitHubAPI
  private let credentials: any CredentialStore

  private struct State {
    var reports: [Name: ReconcileReport] = [:]
    var activation: [Name: (at: EpochSeconds, key: String, report: PoolActivationReport)] = [:]
    var resumedSessions: Set<AllocationID> = []
  }

  package init(
    store: ControllerStore, provider: any EnvironmentProvider,
    loadConfiguration: @escaping @Sendable () -> Result<CIConfiguration, CIError>,
    clients: @escaping @Sendable (InstallationRecord) throws(CIError) -> GitHubInstallationClient,
    api: GitHubAPI = GitHubAPI(http: URLSessionGitHubHTTP()),
    credentials: any CredentialStore = KeychainCredentialStore()
  ) {
    self.api = api
    self.credentials = credentials
    self.store = store
    self.provider = provider
    self.loadConfiguration = loadConfiguration
    self.clients = clients
  }

  /// Production wiring: the App key in the protected credential store, the
  /// GitHub REST API over URLSession.
  package static func installationClients(
    store: ControllerStore, credentials: any CredentialStore
  ) -> @Sendable (InstallationRecord) throws(CIError) -> GitHubInstallationClient {
    let api = GitHubAPI(http: URLSessionGitHubHTTP())
    let auths = Mutex<[Int64: GitHubAppAuth]>([:])
    return { (installation) throws(CIError) -> GitHubInstallationClient in
      guard let app = try store.app(installation.appID) else {
        throw CIError(.unauthorized, "GitHub App \(installation.appID) is not connected")
      }
      let auth = auths.withLock { cache -> GitHubAppAuth in
        if let existing = cache[app.appID] { return existing }
        let created = GitHubAppAuth(app: app, credentials: credentials, api: api)
        cache[app.appID] = created
        return created
      }
      return GitHubInstallationClient(
        api: api, auth: auth, installationID: installation.installationID)
    }
  }

  // MARK: Reconciliation

  package func reconcile(now: EpochSeconds) {
    // Owned VMs and registrations are offboarded even when the current
    // configuration is invalid or no longer names the pool: the last valid
    // configuration still describes how to reach and release them.
    let loaded = loadConfiguration()
    let lastGood = try? store.meta(Self.lastConfigurationKey).flatMap {
      try? ControllerStore.decode(CIConfiguration.self, $0)
    }
    var effective: CIConfiguration
    var current: CIConfiguration?
    switch loaded {
    case .success(let configuration):
      current = configuration
      effective = configuration
      try? store.setMeta(Self.lastConfigurationKey, try? ControllerStore.encode(configuration))
    case .failure(let error):
      for pool in (try? store.poolStatuses()) ?? [] where Self.isAutomatic(pool.state) {
        try? PoolControl.set(
          pool.name, .inactive, reason: "configuration invalid: \(error.message)", store: store)
      }
      guard let lastGood else { return }
      effective = lastGood
    }
    guard let controller = try? store.controllerID() else { return }
    for status in (try? store.poolStatuses()) ?? [] where status.state != .removed {
      guard current != nil, current?.pools[status.name] == nil else { continue }
      guard let previous = lastGood?.pools[status.name],
        let profile = lastGood?.profiles[previous.profile]
      else {
        try? PoolControl.set(
          status.name, .inactive,
          reason:
            "no longer configured and no earlier configuration to offboard it with; restore it, then `iso-ci pool remove`",
          store: store)
        continue
      }
      effective.pools[status.name] = previous
      effective.profiles[previous.profile] = profile
      for (kind, name, _) in lastGood?.descriptors(of: previous.profile) ?? [] {
        switch kind {
        case .image: effective.images[name] = effective.images[name] ?? lastGood?.images[name]
        case .networkPolicy:
          effective.networkPolicies[name] =
            effective.networkPolicies[name] ?? lastGood?.networkPolicies[name]
        case .compatibility:
          effective.compatibility[name] =
            effective.compatibility[name] ?? lastGood?.compatibility[name]
        case .limits: effective.limits[name] = effective.limits[name] ?? lastGood?.limits[name]
        case .profile: break
        }
      }
      if status.state != .removing {
        try? PoolControl.set(status.name, .removing, reason: "no longer configured", store: store)
      }
    }
    for (poolName, pool) in effective.pools.sorted(by: { $0.key < $1.key }) {
      let status = try? store.poolStatus(poolName)
      if status?.state == .removed {
        finishCredentialRemoval(poolName)
        continue
      }
      if let current, current.pools[poolName] != nil {
        let gate = activationGate(poolName, pool, configuration: current, now: now)
        if let status, Self.isAutomatic(status.state) || status.state == .inactive {
          let target: PoolState =
            gate == nil ? (pool.desiredIdleVMs == 0 ? .paused : .active) : .inactive
          let reason =
            gate ?? (pool.desiredIdleVMs == 0 ? "desired_idle_vms is 0 (no demand source)" : nil)
          if status.state != target || status.reason != reason {
            try? PoolControl.set(poolName, target, reason: reason, store: store)
          }
        } else if status == nil {
          try? PoolControl.set(
            poolName, gate == nil ? .active : .inactive, reason: gate, store: store)
        }
      }
      resumeSessions(pool: poolName)
      // Without GitHub access the reconciler still observes, stops and
      // releases owned VMs; registrations wait for access to return.
      let runners: any RunnerService
      if let installation = try? store.installation(pool.installation) {
        do { runners = InstallationRunnerService(client: try clients(installation)) } catch {
          runners = OfflineRunnerService(reason: error.message)
        }
      } else {
        runners = OfflineRunnerService(reason: "installation \(pool.installation) is not connected")
      }
      let reconciler = ConnectedPoolReconciler(
        pool: poolName, store: store, configuration: effective, provider: provider,
        runners: runners, controller: controller)
      let report = reconciler.reconcile()
      state.withLock { $0.reports[poolName] = report }
      if (try? store.poolStatus(poolName))?.state == .removed { finishCredentialRemoval(poolName) }
    }
  }

  static let lastConfigurationKey = "connected.last_configuration"
  static func credentialRemovalKey(_ pool: Name) -> String {
    "connected.remove_credentials." + pool.rawValue
  }

  /// Credential removal requested with `pool remove` runs only after the
  /// pool's owned registrations and VMs are offboarded.
  private func finishCredentialRemoval(_ pool: Name) {
    guard (try? store.meta(Self.credentialRemovalKey(pool))) != nil else { return }
    do {
      _ = try removePoolCredentials(pool)
      try store.setMeta(Self.credentialRemovalKey(pool), nil)
    } catch {
      _ = try? store.event(
        "pool:\(pool)", "pool.credentials_pending", "credential removal pending: \(error.message)")
    }
  }

  /// Operator-chosen states (paused, draining, removing) are never
  /// overridden by automatic activation.
  private static func isAutomatic(_ state: PoolState) -> Bool { state == .active }

  /// Why the pool cannot be active, or nil.
  private func activationGate(
    _ name: Name, _ pool: PoolConfiguration, configuration: CIConfiguration, now: EpochSeconds
  ) -> String? {
    for (kind, descriptor, digest) in configuration.descriptors(of: pool.profile) {
      guard let approval = try? store.approval(kind, descriptor), approval.digest == digest else {
        return
          "\(kind.rawValue) \(descriptor) is not approved at its current digest (run `iso-ci setup --approve`)"
      }
    }
    guard let installation = try? store.installation(pool.installation) else {
      return "installation \(pool.installation) is not connected (run `iso-ci setup`)"
    }
    let key = Self.activationKey(name, configuration)
    if let cached = state.withLock({ $0.activation[name] }), cached.key == key,
      now < cached.at + Self.activationInterval
    {
      return cached.report.state == .active ? nil : cached.report.reasons.joined(separator: "; ")
    }
    let report: PoolActivationReport
    do {
      let client = try clients(installation)
      report = PoolActivation.evaluate(
        pool: name, configuration: configuration, installation: installation,
        reader: APIAuthorityReader(client: client))
    } catch {
      return "GitHub authority could not be evaluated: \(error.message)"
    }
    state.withLock { $0.activation[name] = (now, key, report) }
    return report.state == .active ? nil : report.reasons.joined(separator: "; ")
  }

  /// What a cached activation depends on locally: the pool's own
  /// descriptors and every pool's scope and labels (routing exclusivity). A
  /// configuration edit that changes either is evaluated on the next pass,
  /// not after the cache interval.
  static func activationKey(_ name: Name, _ configuration: CIConfiguration) -> String {
    let routing = configuration.pools.sorted { $0.key < $1.key }.map { entry in
      let labels = entry.value.labels.map(\.normalized).sorted().joined(separator: ",")
      return "\(entry.key)|\(GitHubRunnerScope(entry.value.scope))|\(labels)"
    }
    return ([configuration.poolDigest(name)?.rawValue ?? "-"] + routing).joined(separator: "\n")
  }

  /// After a controller restart, live allocations get their controller-held
  /// session back so the host does not stop them for lack of a lease.
  private func resumeSessions(pool: Name) {
    for allocation in (try? store.openAllocations(pool: pool)) ?? []
    where allocation.readyAt != nil && allocation.observedRunPhase == .running
      && allocation.desired != .retainLive && allocation.vmCleanup != .verified
    {
      let first = state.withLock { $0.resumedSessions.insert(allocation.id).inserted }
      guard first else { continue }
      do { try provider.holdSession(allocation.id, forwards: []) } catch {
        state.withLock { _ = $0.resumedSessions.remove(allocation.id) }
      }
    }
  }

  // MARK: Control

  package func handle(_ request: ControlRequest) -> Result<JSONValue, CIError>? {
    guard owns(request.method) || request.method == "abort" else { return nil }
    do throws(CIError) {
      switch request.method {
      case "pool.pause", "pool.drain", "pool.resume", "pool.remove":
        var r = try ObjectReader(request.params, field: "params")
        let pool = try r.parsed("pool", as: Name.self)
        let abort = try r.optionalBool("abort") ?? false
        let removeCredentials = try r.optionalBool("remove_credentials") ?? false
        try r.finish()
        let configured = (try? loadConfiguration().get())?.pools[pool] != nil
        let recorded = try store.poolStatus(pool) != nil
        guard configured || recorded else {
          throw CIError(.notFound, "unknown pool \(pool)")
        }
        switch request.method {
        case "pool.pause": try PoolControl.pause(pool, store: store)
        case "pool.drain":
          try PoolControl.drain(pool, store: store)
          if abort {
            for allocation in try store.openAllocations(pool: pool) {
              try PoolControl.abort(allocation.id, store: store)
            }
          }
        case "pool.resume":
          try PoolControl.set(pool, .active, reason: nil, store: store)
          state.withLock { _ = $0.activation.removeValue(forKey: pool) }
        default:
          try PoolControl.remove(pool, store: store)
          if removeCredentials {
            // Deferred until offboarding completes, so GitHub access remains
            // available to delete this pool's exact registrations first.
            try store.setMeta(Self.credentialRemovalKey(pool), "requested")
          }
        }
        let open = try store.openAllocations(pool: pool)
        return .success([
          "pool": .string(pool.rawValue),
          "state": .string((try store.poolStatus(pool))?.state.rawValue ?? "unknown"),
          "open_allocations": .integer(Int64(open.count)),
          "pending_cleanup": .array(open.filter { !$0.isSettled }.map { .string($0.id.rawValue) }),
        ])
      case "abort":
        var r = try ObjectReader(request.params, field: "params")
        let target = try r.string("target")
        try r.finish()
        guard let id = try? AllocationID(target), let allocation = try store.allocation(id),
          allocation.kind == .connected
        else { return nil }
        try PoolControl.abort(id, store: store)
        return .success(["allocation": .string(id.rawValue), "desired": "stop"])
      case "registration.resolve":
        var r = try ObjectReader(request.params, field: "params")
        let id = try r.parsed("allocation", as: AllocationID.self)
        let runner = try r.optionalInt("runner_id")
        try r.finish()
        guard let allocation = try store.allocation(id), let pool = allocation.pool,
          case .success(let configuration) = loadConfiguration(),
          let poolConfig = configuration.pools[pool],
          let installation = try store.installation(poolConfig.installation)
        else { throw CIError(.notFound, "unknown connected allocation") }
        let reconciler = ConnectedPoolReconciler(
          pool: pool, store: store, configuration: configuration, provider: provider,
          runners: InstallationRunnerService(client: try clients(installation)),
          controller: try store.controllerID())
        try reconciler.superviseRegistration(id, runnerID: runner)
        return .success(["allocation": .string(id.rawValue), "resolved": true])
      case "smoke.verify":
        var r = try ObjectReader(request.params, field: "params")
        let first = try r.parsed("first", as: AllocationID.self)
        let second = try r.parsed("second", as: AllocationID.self)
        try r.finish()
        guard let a = try store.allocation(first), let b = try store.allocation(second) else {
          throw CIError(.notFound, "unknown allocation")
        }
        try SmokeVerification.verify(.init(a), .init(b))
        return .success(["verified": true])
      case "github.app.complete":
        var r = try ObjectReader(request.params, field: "params")
        let code = try r.string("code")
        try r.finish()
        guard (1...200).contains(code.utf8.count), code.unicodeScalars.allSatisfy(isSafeNameScalar)
        else {
          throw CIError.invalid("invalid manifest code")
        }
        let app = try ManifestFlow.complete(
          code: code, api: api, credentials: credentials, store: store)
        return .success(appSummary(app))
      case "github.app.connect":
        var r = try ObjectReader(request.params, field: "params")
        let appID = try r.int("app_id")
        let pem = try r.string("private_key_pem")
        try r.finish()
        let app = try ManifestFlow.connectExistingApp(
          appID: appID, privateKeyPEM: RedactedSecret(pem), api: api, credentials: credentials,
          store: store)
        return .success(appSummary(app))
      case "github.installation.find":
        var r = try ObjectReader(request.params, field: "params")
        let appID = try r.int("app_id")
        let repository = try r.parsed("repository", as: RepositoryName.self)
        try r.finish()
        guard let app = try store.app(appID) else {
          throw CIError(.notFound, "GitHub App \(appID) is not connected")
        }
        let info = try ManifestFlow.findInstallation(
          repository: repository, app: app, api: api, credentials: credentials)
        return .success([
          "installation_id": .integer(info.id), "account": .string(info.account),
          "repository_selection": .string(info.repositorySelection),
        ])
      case "github.installation.verify":
        var r = try ObjectReader(request.params, field: "params")
        let name = try r.parsed("name", as: Name.self)
        let installationID = try r.int("installation_id")
        let appID = try r.int("app_id")
        let account = try r.optionalString("account")
        var scopes: Set<ManifestFlow.ScopeKind> = []
        for raw in try r.strings("scopes") {
          guard let kind = ManifestFlow.ScopeKind(rawValue: raw) else {
            throw CIError.invalid("scopes must be repository or organization")
          }
          scopes.insert(kind)
        }
        try r.finish()
        guard let app = try store.app(appID) else {
          throw CIError(.notFound, "GitHub App \(appID) is not connected")
        }
        let record = try ManifestFlow.verifyInstallation(
          name: name, installationID: installationID, app: app, api: api, credentials: credentials,
          store: store, expectedAccount: account, scopes: scopes)
        state.withLock { $0.activation.removeAll() }
        return .success(jsonValue(record))
      case "inspect.pools":
        var r = try ObjectReader(request.params, field: "params")
        let target = try r.string("target")
        try r.finish()
        guard let pool = try? Name(target), let status = try store.poolStatus(pool) else {
          throw CIError(.notFound, "unknown pool")
        }
        return .success(["pool": jsonValue(status), "status": poolStatus(pool, status)])
      default:
        return nil
      }
    } catch {
      return .failure(error)
    }
  }

  /// The service answers only its own methods.
  package func owns(_ method: String) -> Bool {
    [
      "pool.pause", "pool.drain", "pool.resume", "pool.remove", "registration.resolve",
      "smoke.verify", "inspect.pools", "github.app.complete", "github.app.connect",
      "github.installation.find", "github.installation.verify",
    ].contains(method)
  }

  private func appSummary(_ app: GitHubAppRecord) -> JSONValue {
    [
      "app_id": .integer(app.appID), "slug": .string(app.slug), "owner": .string(app.owner),
      "install_url": .string(ManifestFlow.installURL(slug: app.slug)),
    ]
  }

  private func removePoolCredentials(_ pool: Name) throws(CIError) -> JSONValue {
    let current = try? loadConfiguration().get()
    let lastGood = try? store.meta(Self.lastConfigurationKey).flatMap {
      try? ControllerStore.decode(CIConfiguration.self, $0)
    }
    guard let poolConfig = current?.pools[pool] ?? lastGood?.pools[pool] else {
      throw CIError(.notFound, "pool \(pool) has no recorded configuration")
    }
    let others =
      (current ?? lastGood)?.pools.filter {
        $0.key != pool && $0.value.installation == poolConfig.installation
      } ?? [:]
    guard others.isEmpty else {
      throw CIError(
        .conflict, "installation \(poolConfig.installation) is still used by other pools")
    }
    guard let installation = try store.installation(poolConfig.installation) else {
      return ["pool": .string(pool.rawValue), "credentials_removed": false]
    }
    let stillUsed = try store.installations().contains {
      $0.name != installation.name && $0.appID == installation.appID
    }
    // Keychain first: a locked keychain leaves everything in place and is
    // reported, rather than dropping the record and orphaning the key.
    var removedKey = false
    if !stillUsed, let app = try store.app(installation.appID) {
      try ManifestFlow.removeCredentials(app: app, credentials: credentials)
      try store.removeApp(app.appID)
      removedKey = true
    }
    try store.removeInstallation(installation.name)
    try store.event("pool:\(pool)", "pool.credentials_removed", "CI-only credentials removed")
    // The GitHub App and its installation are not deleted on GitHub: they
    // may be operator-owned. Uninstalling them is a separate operator step.
    return [
      "pool": .string(pool.rawValue), "credentials_removed": true,
      "app_key_removed": .bool(removedKey),
      "note":
        "the GitHub App and installation still exist on GitHub; remove them there if no longer needed",
    ]
  }

  private func poolStatus(_ name: Name, _ status: PoolStatusRecord) -> JSONValue {
    let report = state.withLock { $0.reports[name] }
    let activation = state.withLock { $0.activation[name] }
    return [
      "state": .string(status.state.rawValue),
      "reason": status.reason.map(JSONValue.string) ?? .null,
      "live": .integer(Int64(report?.live ?? 0)), "idle": .integer(Int64(report?.idle ?? 0)),
      "deficit": .integer(Int64(report?.deficit ?? 0)),
      "admission_paused": report?.admissionPaused.map(JSONValue.string) ?? .null,
      "errors": .array((report?.errors ?? []).prefix(5).map { .string($0) }),
      "guarantees": .array(
        (activation?.report.guarantees ?? []).map {
          [
            "name": .string($0.name), "status": .string($0.status.rawValue),
            "detail": .string($0.detail),
          ]
        }),
    ]
  }

  package func status() -> JSONValue {
    var out: [String: JSONValue] = [:]
    for status in (try? store.poolStatuses()) ?? [] {
      out[status.name.rawValue] = poolStatus(status.name, status)
    }
    return .object(out)
  }
}
