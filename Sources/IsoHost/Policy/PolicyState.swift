import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy

// Host-owned policy state for one instance (docs/design/iso-policy.md §5,
// §7.4, §11): a stable instance identity, and one immutable boot binding per
// VM boot with its proxy launch claims. Owner-only, versioned, written
// atomically under the instance policy lock; never guest-visible.

/// `<instance>/policy-instance.json`: created once per instance, so a
/// destroyed and recreated instance with the same name gets a new identity.
package enum PolicyInstanceIdentity {
  struct Record: Codable, Equatable {
    let recordVersion: Int
    let instanceID: String
  }

  static func path(_ instance: Instance) -> String { instance.directory + "/policy-instance.json" }

  static func load(_ instance: Instance) throws(HostError) -> String? {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let record = try StateStore.decode(Record.self, bytes, path: path)
    guard record.recordVersion == 1, PolicyBinding.isHex(record.instanceID, count: 32) else {
      throw HostError("\(path) is not a supported policy instance identity")
    }
    return record.instanceID
  }

  /// Caller holds the policy lock.
  static func loadOrCreate(_ instance: Instance) throws(HostError) -> String {
    if let existing = try load(instance) { return existing }
    let id = randomHex(16)
    try StateStore.writeControlFile(Record(recordVersion: 1, instanceID: id), to: path(instance))
    return id
  }
}

/// The immutable policy a VM boot runs under, plus its proxy launch claims.
/// An explicit `off` binding is written for boots without a policy, so a
/// missing record is never read as "enforcement disabled".
package struct PolicyBinding: Codable, Equatable, Sendable {
  package static let currentVersion = 1

  package struct Claim: Codable, Equatable, Sendable {
    package let provider: ProxyProvider
    package let proxyGenerationID: String
    /// Diagnostic UTC time only; never used for authorization.
    package let claimedAt: String
  }

  package let recordVersion: Int
  package let instanceID: String
  package let instanceName: String
  /// Host-generated per boot (32 hex), distinct from any runtime boot ID.
  package let bootID: String
  /// A fresh UUID per boot, even when the policy text is unchanged.
  package let policyEpoch: String
  package let policyMode: PolicyMode
  package let policyDigest: String?
  package let governedActions: [PolicyAction]
  package let canonicalizationVersion: Int
  package let canonicalPolicy: String?
  package let createdAt: String
  package fileprivate(set) var claims: [Claim]

  package static func path(_ instance: Instance) -> String {
    instance.directory + "/policy-binding.json"
  }

  /// Serializes binding writes, launch claims and governed applies for one
  /// instance; the first lock in the apply order (policy → workspace → stage).
  package static func lock(_ instance: Instance) throws(HostError) -> FileLock {
    try FileLock(path: instance.directory + "/.policy.lock")
  }

  /// The verified snapshot; nil for an `off` binding. Any inconsistency is
  /// an error, so governed callers fail closed.
  func compiled() throws(HostError) -> CompiledPolicy? {
    guard let canonicalPolicy else {
      guard policyMode == .off, policyDigest == nil, governedActions.isEmpty
      else { throw HostError("policy binding for '\(instanceName)' is inconsistent") }
      return nil
    }
    let compiled: CompiledPolicy
    do {
      compiled = try PolicyCanonical.decode(Array(canonicalPolicy.utf8))
    } catch {
      throw HostError("policy binding for '\(instanceName)' holds an invalid policy: \(error)")
    }
    guard compiled.digest == policyDigest, compiled.mode == policyMode,
      compiled.governedActions.sorted() == governedActions
    else { throw HostError("policy binding for '\(instanceName)' does not match its digest") }
    return compiled
  }

  package func claim(_ provider: ProxyProvider) -> Claim? {
    claims.first { $0.provider == provider }
  }

  /// The binding, verified. Nil when the instance has no binding (it never
  /// booted, or booted before policy bindings existed); corrupt records throw.
  package static func load(_ instance: Instance) throws(HostError) -> PolicyBinding? {
    try loadVerified(instance)?.binding
  }

  /// One read, decode and policy compile; `ActivePolicy.load` reuses it.
  static func loadVerified(_ instance: Instance) throws(HostError)
    -> (binding: PolicyBinding, policy: CompiledPolicy?)?
  {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let binding = try StateStore.decode(PolicyBinding.self, bytes, path: path)
    guard binding.recordVersion == currentVersion,
      binding.canonicalizationVersion == PolicySchema.canonicalizationVersion,
      binding.instanceName == instance.name.rawValue, isHex(binding.instanceID, count: 32),
      isHex(binding.bootID, count: 32), isUUID(binding.policyEpoch),
      binding.claims.allSatisfy({ isUUID($0.proxyGenerationID) })
    else { throw HostError("\(path) is not a supported policy binding; start a new VM boot") }
    return (binding, try binding.compiled())
  }

  func save(_ instance: Instance) throws(HostError) {
    try StateStore.writeControlFile(self, to: Self.path(instance))
  }

  static func isHex(_ text: String, count: Int) -> Bool {
    text.utf8.count == count
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func isUUID(_ text: String) -> Bool {
    UUID(uuidString: text) != nil && text == text.lowercased() && text.utf8.count == 36
  }
}

/// What a governed operation sees for an instance.
package enum ActivePolicy: Sendable {
  /// No binding: a boot that predates policy bindings, or no boot yet.
  case unbound
  case off(PolicyBinding)
  case active(PolicyBinding, CompiledPolicy)

  package var binding: PolicyBinding? {
    switch self {
    case .unbound: nil
    case .off(let binding), .active(let binding, _): binding
    }
  }

  package var policy: CompiledPolicy? {
    if case .active(_, let policy) = self { policy } else { nil }
  }

  /// Corrupt state throws; callers on a governed path must not proceed.
  package static func load(_ instance: Instance) throws(HostError) -> ActivePolicy {
    guard let (binding, policy) = try PolicyBinding.loadVerified(instance) else {
      // Every boot since policy bindings exist records one before starting,
      // so an instance identity without a binding means the binding was lost.
      guard try PolicyInstanceIdentity.load(instance) == nil else {
        throw HostError(
          "policy_state_unavailable: the policy binding for '\(instance.name)' is missing; start a new VM boot"
        )
      }
      return .unbound
    }
    guard let policy else { return .off(binding) }
    return .active(binding, policy)
  }

  /// A boot without a binding cannot gain enforcement mid-boot: refuse when
  /// the configuration asks for any of `actions`, otherwise keep the legacy
  /// behavior. One load serves every action.
  package static func requireBoundIfRequested(
    _ instance: Instance, configured: CompiledPolicy?, _ actions: PolicyAction...
  ) throws(HostError) -> ActivePolicy {
    let active = try load(instance)
    if case .unbound = active,
      let action = actions.first(where: { configured?.enforces($0) == true })
    {
      throw HostError(
        "policy_state_unavailable: '\(instance.name)' booted without a policy binding; enforcing \(action.rawValue) requires a new VM boot (`iso stop` then `iso start`)"
      )
    }
    return active
  }
}

/// Boot binding and proxy launch claims.
package enum PolicyBoot {
  /// Records a new immutable binding for a VM boot that is starting now:
  /// a fresh boot ID and epoch, the configured policy or an explicit `off`.
  /// Replaces the previous boot's binding and claims.
  @discardableResult
  package static func begin(
    _ instance: Instance, configured: CompiledPolicy?, diagnostics: Diagnostics,
    now: Date = Date()
  ) throws -> PolicyBinding {
    let lock = try PolicyBinding.lock(instance)
    defer { lock.release() }
    let binding = PolicyBinding(
      recordVersion: PolicyBinding.currentVersion,
      instanceID: try PolicyInstanceIdentity.loadOrCreate(instance),
      instanceName: instance.name.rawValue, bootID: randomHex(16),
      policyEpoch: UUID().uuidString.lowercased(),
      policyMode: configured?.mode ?? .off, policyDigest: configured?.digest,
      governedActions: (configured?.governedActions ?? []).sorted(),
      canonicalizationVersion: PolicySchema.canonicalizationVersion,
      canonicalPolicy: configured?.canonicalJSON, createdAt: utcTimestamp(now), claims: [])
    try binding.save(instance)
    BoundaryAudit.record(
      instance,
      .policyBoot(
        mode: binding.policyMode, digest: binding.policyDigest, epoch: binding.policyEpoch,
        actions: binding.governedActions), diagnostics: diagnostics)
    return binding
  }

  /// Claims this boot's single launch slot for `provider` before a proxy is
  /// spawned. Nil when the policy does not govern provider actions (the
  /// legacy startup protocol applies). An enforcing slot that is already
  /// claimed — even by a launch that never finished — is refused: quota
  /// state is never replaced with empty counters within an enforcing boot.
  package static func claimProxyLaunch(
    _ instance: Instance, provider: ProxyProvider, configured: CompiledPolicy?,
    diagnostics: Diagnostics, now: Date = Date()
  ) throws -> ProxyAuthorizationStartup? {
    let lock = try PolicyBinding.lock(instance)
    defer { lock.release() }
    let active = try ActivePolicy.requireBoundIfRequested(
      instance, configured: configured, .proxyRequest, .credentialUse)
    guard case .active(var binding, let policy) = active, policy.governsProviderActions else {
      return nil
    }
    if let existing = binding.claim(provider) {
      guard policy.mode == .shadow else {
        BoundaryAudit.record(
          instance,
          .policyProxyClaim(
            provider: provider, generation: existing.proxyGenerationID, outcome: .refused),
          diagnostics: diagnostics)
        throw HostError(
          "policy_state_unavailable: the \(provider.rawValue) proxy for this enforcing boot of '\(instance.name)' was already launched (generation \(existing.proxyGenerationID)); a replacement would reset its quota. Start a new VM boot (`iso stop` then `iso start`) to restore provider access."
        )
      }
      diagnostics.warn(
        "policy shadow simulation for \(provider.rawValue) restarts with empty counters (previous generation \(existing.proxyGenerationID))"
      )
      binding.claims.removeAll { $0.provider == provider }
    }
    let claim = PolicyBinding.Claim(
      provider: provider, proxyGenerationID: UUID().uuidString.lowercased(),
      claimedAt: utcTimestamp(now))
    binding.claims.append(claim)
    try binding.save(instance)
    BoundaryAudit.record(
      instance,
      .policyProxyClaim(
        provider: provider, generation: claim.proxyGenerationID,
        outcome: policy.mode == .shadow ? .shadow : .claimed),
      diagnostics: diagnostics)
    return ProxyAuthorizationStartup(binding: binding, policy: policy, claim: claim)
  }
}

/// The `authorization` block of a version 3 proxy startup document, and the
/// identity its signed readiness reply must carry. Never holds a credential.
package struct ProxyAuthorizationStartup: Sendable, Equatable {
  package let instanceID: String
  package let instanceName: String
  package let bootID: String
  package let policyEpoch: String
  package let proxyGenerationID: String
  package let policyDigest: String
  package let canonicalPolicy: String

  init(binding: PolicyBinding, policy: CompiledPolicy, claim: PolicyBinding.Claim) {
    instanceID = binding.instanceID
    instanceName = binding.instanceName
    bootID = binding.bootID
    policyEpoch = binding.policyEpoch
    proxyGenerationID = claim.proxyGenerationID
    policyDigest = policy.digest
    canonicalPolicy = policy.canonicalJSON
  }

  /// The identity a running proxy for `provider` must prove, from the stored
  /// binding; nil when that proxy was launched without policy.
  static func expected(_ instance: Instance, provider: ProxyProvider) throws(HostError)
    -> ProxyAuthorizationStartup?
  {
    guard case .active(let binding, let policy) = try ActivePolicy.load(instance),
      policy.governsProviderActions, let claim = binding.claim(provider)
    else { return nil }
    return ProxyAuthorizationStartup(binding: binding, policy: policy, claim: claim)
  }
}

/// `iso policy show`: read-only. Never reads proxy counters, resolves a
/// credential, or mints an approval.
package enum PolicyReport {
  package static func json(
    _ instance: Instance, configured: CompiledPolicy?,
    processObserved: ((ProxyProvider) -> Bool)? = nil
  ) throws -> OutputJSON {
    let processObserved =
      processObserved ?? { provider in
        ProxyLauncher.recordedProcessAlive(
          ProxyLauncher.pidPath(instance, provider.rawValue), expect: .proxy)
      }
    let active = try ActivePolicy.load(instance)
    let configuredMode = configured?.mode ?? .off
    var activeJSON = OutputJSON.null
    var pending = configured != nil
    if let binding = active.binding {
      pending = binding.policyDigest != configured?.digest || binding.policyMode != configuredMode
      activeJSON = .object([
        ("mode", .string(binding.policyMode.rawValue)),
        ("digest", binding.policyDigest.map(OutputJSON.string) ?? .null),
        ("epoch", .string(binding.policyEpoch)), ("boot_id", .string(binding.bootID)),
        ("governed_actions", .array(binding.governedActions.map { .string($0.rawValue) })),
        ("bound_at", .string(binding.createdAt)),
        (
          "proxy_claims",
          .array(
            binding.claims.map { claim in
              .object([
                ("provider", .string(claim.provider.rawValue)),
                ("generation", .string(claim.proxyGenerationID)),
                ("claimed_at", .string(claim.claimedAt)),
                // Observed now; not a health check and not a quota reading.
                (
                  "process_observed",
                  .bool(processObserved(claim.provider))
                ),
              ])
            })
        ),
      ])
    }
    return .object([
      ("instance", .string(instance.name.rawValue)),
      ("active", activeJSON),
      (
        "configured",
        configured.map {
          .object([("mode", .string($0.mode.rawValue)), ("digest", .string($0.digest))])
        } ?? .null
      ),
      ("pending_next_boot", .bool(pending)),
    ])
  }

  package static func text(_ report: OutputJSON) -> [String] {
    guard case .object(let members) = report else { return [] }
    let fields = Dictionary(members, uniquingKeysWith: { a, _ in a })
    var lines: [String] = []
    if case .string(let name) = fields["instance"] { lines.append("Instance: \(name)") }
    if case .object(let active) = fields["active"] {
      let a = Dictionary(active, uniquingKeysWith: { x, _ in x })
      func text(_ key: String) -> String {
        if case .string(let value) = a[key] { value } else { "-" }
      }
      lines.append("Active policy (this boot): mode \(text("mode")), digest \(text("digest"))")
      lines.append("  epoch \(text("epoch")), bound \(text("bound_at"))")
      if case .array(let actions) = a["governed_actions"] {
        let names = actions.compactMap { if case .string(let s) = $0 { s } else { nil } }
        lines.append("  governed: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
      }
      if case .array(let claims) = a["proxy_claims"] {
        for case .object(let claim) in claims {
          let c = Dictionary(claim, uniquingKeysWith: { x, _ in x })
          let provider = if case .string(let p) = c["provider"] { p } else { "?" }
          let generation = if case .string(let g) = c["generation"] { g } else { "?" }
          let observed = c["process_observed"] == .bool(true)
          lines.append(
            "  \(provider) proxy generation \(generation): launch slot claimed; process \(observed ? "observed" : "not observed") (not a health check)"
          )
        }
      }
    } else {
      lines.append("Active policy: none recorded (no boot since policy bindings were introduced)")
    }
    if case .object(let configured) = fields["configured"] {
      let c = Dictionary(configured, uniquingKeysWith: { x, _ in x })
      let mode = if case .string(let m) = c["mode"] { m } else { "-" }
      let digest = if case .string(let d) = c["digest"] { d } else { "-" }
      lines.append("Configured policy: mode \(mode), digest \(digest)")
    } else {
      lines.append("Configured policy: none")
    }
    if fields["pending_next_boot"] == .bool(true) {
      lines.append(
        "The configured policy differs from the active one; it applies at the next VM boot.")
    }
    return lines
  }
}
