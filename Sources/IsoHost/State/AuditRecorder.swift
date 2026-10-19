import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// The recorder for one managed or administrative invocation. Recording is
/// best effort: a failure warns once on stderr and never changes the
/// workload's behavior, exit status or cleanup.
package final class AuditInvocation: Sendable {
  package let runID: AuditRunID
  let store: AuditStore
  let diagnostics: Diagnostics

  private struct State {
    var warned = false
    var launchObserved = false
    var excludedVariables: Set<String> = []
  }
  private let state = Mutex(State())

  /// Every local launch goes through `InteractiveSSH.attach`.
  static let transport = "ssh"

  init(runID: AuditRunID, store: AuditStore, diagnostics: Diagnostics) {
    self.runID = runID
    self.store = store
    self.diagnostics = diagnostics
  }

  /// Records the request and names the run on stderr; workload stdout is
  /// untouched.
  package static func begin(
    store: AuditStore, request: AuditFacts.Request, diagnostics: Diagnostics,
    notice: (String) -> Void
  ) -> AuditInvocation {
    let invocation = AuditInvocation(runID: .generate(), store: store, diagnostics: diagnostics)
    if invocation.record(.requested(invocation.runID, request)) {
      notice(
        "Audit run \(invocation.runID); inspect with `iso audit --run \(invocation.runID)`")
    }
    return invocation
  }

  @discardableResult
  func record(_ record: AuditRecord) -> Bool {
    do {
      try store.append(record)
      return true
    } catch {
      let first = state.withLock { state in
        defer { state.warned = true }
        return !state.warned
      }
      if first {
        diagnostics.warn(
          "audit: could not record evidence for \(runID) (the command continues): \(neutralizeControls("\(error)"))"
        )
      }
      return false
    }
  }

  /// Whether the launch seam recorded the handoff or its refusal; after
  /// that, a failure is the launch's outcome, not a preparation failure.
  package var launchObserved: Bool { state.withLock { $0.launchObserved } }

  /// Adapter defaults the launch adds; never listed as forwarded names.
  package func exclude(variables: some Sequence<String>) {
    state.withLock { $0.excludedVariables.formUnion(variables) }
  }

  package func preparationFailed(_ stage: AuditFacts.Stage) {
    record(.preparationFailed(runID, .init(stage: stage)))
  }

  package func environment(_ environment: AuditFacts.Environment) {
    record(.environment(runID, environment))
  }

  package func cleanup(_ session: RunSessionID, _ outcome: AuditFacts.CleanupOutcome) {
    record(.cleanup(runID, .init(sessionID: session, outcome: outcome)))
  }

  /// Runs `body`; a failure before the handoff is recorded at `stage`.
  package func during<T>(_ stage: AuditFacts.Stage, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      if !launchObserved { preparationFailed(stage) }
      throw error
    }
  }

  // The launch seam (`InteractiveSSH.attach`).

  func handoff(pty: Bool, forwarded names: [String]) {
    let excluded = state.withLock { state in
      state.launchObserved = true
      return state.excludedVariables
    }
    record(
      .handoff(
        runID,
        .init(
          transport: Self.transport, pty: pty,
          forwardedVariables: names.filter { !excluded.contains($0) }.sorted())))
  }

  /// The isolation recheck refused the handoff: no transport was started.
  func revalidationFailed() {
    state.withLock { $0.launchObserved = true }
    transportFailed(.revalidationFailed)
  }

  func transportEnded(_ termination: ProcessRunner.Termination) {
    record(
      .transportEnded(runID, .init(transport: Self.transport, termination: .init(termination))))
  }

  func transportFailed(_ reason: AuditFacts.TransportFailure) {
    record(.transportFailed(runID, .init(transport: Self.transport, reason: reason)))
  }
}

extension AuditStore {
  /// A best-effort record outside any invocation (`run-cleanup`).
  package func recordOrWarn(_ record: AuditRecord, diagnostics: Diagnostics) {
    do { try append(record) } catch {
      diagnostics.warn(
        "audit: could not record evidence (the command continues): \(neutralizeControls("\(error)"))"
      )
    }
  }
}

extension AgentBootstrap {
  /// The effective exposure of a running instance from host records, after
  /// its handoff proof; `requested` is this invocation's configuration.
  package func auditEnvironment(
    _ running: AppleBackend.Running, action: AuditFacts.StartAction, agent: AuditFacts.Agent?,
    session: RunSessionID?
  ) -> AuditFacts.Environment {
    let instance = running.instance
    // A record that exists but cannot be read is named, never shown as absent.
    var unreadable: [String] = []
    func read<T>(_ name: String, _ body: () throws -> T?) -> T? {
      do { return try body() } catch {
        unreadable.append(name)
        return nil
      }
    }
    let identity = read("vm_identity") { try PolicyInstanceIdentity.load(instance) }
    let binding = read("policy_binding") { try PolicyBinding.load(instance) }
    let network = read("network_policy") { try NetworkPolicy.load(instance) }
    let workspace: AuditFacts.Environment.Workspace
    if let state = read("workspace", { try WorkspaceState.load(instance) }) {
      switch state.source {
      case .workspace: workspace = .copy
      case .mount: workspace = .mount
      case .gitRepo: workspace = .gitRepo
      }
    } else {
      workspace = unreadable.contains("workspace") ? .unknown : .none
    }
    let proxied = read("proxy") {
      try ProxyProvider.allCases.filter { try proxyConfigured(instance, $0) }
    }
    return AuditFacts.Environment(
      action: action, instanceName: instance.name.rawValue,
      vmID: identity.flatMap { try? HexID($0) }, bootID: binding.flatMap { try? HexID($0.bootID) },
      image: instance.image.rawValue, guestOS: running.sidecar.kind.rawValue,
      workspace: workspace,
      egress: network.map { .init(mode: $0.mode, transport: $0.recordedTransport.rawValue) },
      policy: binding.map { .init(mode: $0.policyMode.rawValue, digest: $0.policyDigest) },
      proxiedProviders: (proxied ?? []).map(\.rawValue),
      requested: .init(
        egress: config.egress.rawValue, proxyMode: config.proxy.mode.rawValue,
        sessionTTLSeconds: config.limits.sessionTTL.map { UInt64($0.seconds) }),
      agent: agent, disposableSessionID: session, unreadable: unreadable)
  }
}

extension BoundaryAudit {
  /// The same event in the instance-independent store, attributed to the
  /// VM's stable identity and, when known, its current boot.
  static func recordAudit(
    _ instance: Instance, _ event: Event, now: Date, diagnostics: Diagnostics?
  ) {
    guard let store = AuditStore.forInstance(instance) else { return }
    do {
      // An instance that never booted under a binding has no identity yet;
      // an unreadable one is reported, not silently dropped.
      guard let identity = try PolicyInstanceIdentity.load(instance) else { return }
      let vm = try HexID(identity)
      let boot = try PolicyBinding.load(instance).map { try HexID($0.bootID) }
      try store.append(
        .boundary(vmID: vm, bootID: boot, instanceName: instance.name, event), now: now)
    } catch {
      diagnostics?.warn(
        "audit: could not record a boundary event (the operation continues): \(neutralizeControls("\(error)"))"
      )
    }
  }
}
