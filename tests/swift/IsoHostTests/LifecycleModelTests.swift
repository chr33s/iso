// A model-based property test of the host instance lifecycle: generated
// operation sequences run against the real lifecycle code and the stateful
// fake runtime, and after every step the host and runtime state must equal a
// small reference model. The generator and reproduction knobs are in
// IsoPropertyTesting (docs/testing.md "Property tests").

import Foundation
import IsoConfiguration
import IsoCore
import IsoPropertyTesting
import Testing

@testable import IsoHost

// MARK: - Reference model

/// What the host and runtime hold for one instance.
private struct ModelInstance: Equatable {
  enum Phase: Equatable {
    case running
    case stopped
    /// A create killed after the runtime made the sandbox: a create journal
    /// and a stopped sandbox; only `destroy` finishes it.
    case interrupted
    /// A destroy that failed after its journal began; only `destroy` finishes it.
    case destroyPending
  }

  var phase: Phase
  var machine: MachineName
  /// `apple-machine.json` exists (an interrupted create never wrote it).
  var recorded: Bool
  /// `handoff-fence.json`: an unconfirmed stop after a failed start.
  var fenced = false
  /// Retained return state (`StageLocation.exists`).
  var retained = false
}

/// One generated operation on the instance in `slot`. Faults are marker files
/// the runtime wrapper turns into a failed call, standing in for a runtime
/// that refuses or a host process killed mid-operation.
private enum Step: Equatable, CustomStringConvertible {
  case up(Int)
  case upFailingBoot(Int)
  /// `create` succeeds, `start` fails, and the host never runs its cleanup.
  case killedUp(Int)
  case start(Int)
  case startFailingBoot(Int)
  /// The sandbox boots but presents an unpinned host key, and the stop after
  /// that failure is refused: the instance is left running and fenced.
  case startUnconfirmed(Int)
  case stop(Int)
  case stopUnconfirmed(Int)
  /// The sandbox stops behind iso's back (guest shutdown or owner exit).
  case crash(Int)
  case destroy(Int)
  case destroyFailingDelete(Int)
  /// `destroy --all`'s per-instance loop over the listed instances.
  case destroyAll
  case stage(Int)
  /// A receive whose host process died: its quiescent incoming tree remains.
  case killedReceive(Int)
  case discard(Int)
  case inputs(Int)
  case grants(Int)
  /// Best-effort audit writers that may run after a racing destroy.
  case lateWrites(Int)
}

extension Step {
  /// `up(0)`, not the module-qualified reflection.
  var description: String {
    guard let child = Mirror(reflecting: self).children.first, let label = child.label else {
      return "destroyAll"
    }
    return "\(label)(\(child.value))"
  }
}

private enum Outcome: Equatable {
  case succeeds, fails
}

private let slotNames = ["la", "lb"]

/// The model's transition for `step`: the expected outcome and the new state.
/// `created` is the sandbox a successful create made.
private func apply(_ step: Step, _ model: inout [ModelInstance?], created: MachineName?)
  -> Outcome
{
  func update(_ slot: Int, _ body: (inout ModelInstance) -> Outcome) -> Outcome {
    guard var instance = model[slot] else { return .fails }
    let outcome = body(&instance)
    model[slot] = instance
    return outcome
  }
  switch step {
  case .up(let slot), .killedUp(let slot):
    guard model[slot] == nil else { return .fails }
    let up = step == .up(slot)
    if let created {
      model[slot] = ModelInstance(
        phase: up ? .running : .interrupted, machine: created, recorded: up)
    }
    return .succeeds
  case .upFailingBoot:
    // A failed first boot destroys what it created.
    return .fails
  case .start(let slot):
    return update(slot) { instance in
      guard instance.phase == .stopped, !instance.fenced else { return .fails }
      instance.phase = .running
      return .succeeds
    }
  case .startFailingBoot:
    return .fails
  case .startUnconfirmed(let slot):
    return update(slot) { instance in
      if instance.phase == .stopped, !instance.fenced {
        instance.phase = .running
        instance.fenced = true
      }
      return .fails
    }
  case .stop(let slot), .stopUnconfirmed(let slot):
    let refused = step == .stopUnconfirmed(slot)
    return update(slot) { instance in
      switch instance.phase {
      case .running:
        if refused { return .fails }
        instance.phase = .stopped
      case .stopped: break
      case .interrupted: return .fails
      case .destroyPending: if !instance.recorded { return .fails }
      }
      instance.fenced = false
      return .succeeds
    }
  case .crash(let slot):
    if model[slot]?.phase == .running { model[slot]?.phase = .stopped }
    return .succeeds
  case .destroy(let slot):
    model[slot] = nil
    return .succeeds
  case .destroyFailingDelete(let slot):
    guard var instance = model[slot] else { return .succeeds }
    instance.retained = false
    instance.phase = .destroyPending
    model[slot] = instance
    return .fails
  case .destroyAll:
    model = model.map { _ in nil }
    return .succeeds
  case .stage(let slot), .killedReceive(let slot):
    return update(slot) { instance in
      instance.retained = true
      return .succeeds
    }
  case .discard(let slot):
    return update(slot) { instance in
      instance.retained = false
      return .succeeds
    }
  case .inputs(let slot), .grants(let slot):
    return model[slot] == nil ? .fails : .succeeds
  case .lateWrites:
    return .succeeds
  }
}

/// Sequences that mostly reach the interesting states: the generator tracks
/// the model, prefers an existing instance and the steps legal in its state,
/// and probes destroyed or never-created instances with stale handles. One
/// step in six is drawn from every operation.
private func generateSteps(_ rng: inout PropertyRNG) -> [Step] {
  let any: [(Int) -> Step] = [
    Step.up, Step.upFailingBoot, Step.killedUp, Step.start, Step.startFailingBoot,
    Step.startUnconfirmed, Step.stop, Step.stopUnconfirmed, Step.crash, Step.destroy,
    Step.destroyFailingDelete, Step.stage, Step.killedReceive, Step.discard, Step.inputs,
    Step.grants, Step.lateWrites,
  ]
  let workspace: [(Int) -> Step] = [
    Step.stage, Step.killedReceive, Step.discard, Step.inputs, Step.grants,
  ]
  let creates: [(Int) -> Step] = [Step.up, Step.up, Step.upFailingBoot, Step.killedUp]
  let stale: [(Int) -> Step] = workspace + [Step.lateWrites, Step.stop, Step.start, Step.destroy]
  func likely(_ instance: ModelInstance?) -> [(Int) -> Step] {
    guard let instance else { return rng.oneIn(4) ? stale : creates }
    switch instance.phase {
    case .running where !instance.fenced:
      return [
        Step.stop, Step.stop, Step.stop, Step.stopUnconfirmed, Step.crash, Step.destroy,
        Step.destroyFailingDelete,
      ] + workspace
    case .stopped where !instance.fenced:
      return [
        Step.start, Step.start, Step.startFailingBoot, Step.startUnconfirmed,
        Step.startUnconfirmed, Step.startUnconfirmed, Step.destroy, Step.destroyFailingDelete,
        Step.stage, Step.discard, Step.grants,
      ]
    case .running, .stopped:
      return [
        Step.stop, Step.stop, Step.stop, Step.stop, Step.start, Step.destroy,
        Step.destroyFailingDelete,
      ]
    case .interrupted, .destroyPending:
      return [Step.destroy, Step.destroy, Step.stop, Step.start, Step.stage]
    }
  }
  // Only the model's shape matters here; the real machine is named at run time.
  guard let placeholder = try? MachineName("iso-00000000-0000000000000000") else { return [] }
  var model: [ModelInstance?] = slotNames.map { _ in nil }
  var steps: [Step] = []
  for _ in 0..<rng.int(6...10) {
    let step: Step
    if rng.oneIn(25) {
      step = .destroyAll
    } else {
      let present = model.indices.filter { model[$0] != nil }
      let slot =
        present.isEmpty || rng.oneIn(4) ? rng.below(slotNames.count) : rng.element(present)
      step = rng.element(rng.oneIn(6) ? any : likely(model[slot]))(slot)
    }
    _ = apply(step, &model, created: placeholder)
    steps.append(step)
  }
  return steps
}

// MARK: - Harness over the real lifecycle and the fake runtime

/// The fake runtime behind a wrapper that fails a verb while `<bin>/fail-<verb>`
/// exists.
private final class LifecycleHarness {
  let install: FakeInstallation
  let lifecycle: ProjectLifecycle
  let workspace: String
  /// The last handle each slot had; a destroyed slot keeps its stale one, as a
  /// command that resolved it before a racing destroy would.
  var handles: [Instance]

  init() throws {
    install = try FakeInstallation()
    let bin = install.root + "/bin"
    try FileManager.default.moveItem(
      atPath: bin + "/iso-sandbox", toPath: bin + "/iso-sandbox-real")
    try Data(
      "#!/bin/sh\nif [ -e '\(bin)/fail-'\"$1\" ]; then echo \"injected $1 failure\" >&2; exit 1; fi\nexec '\(bin)/iso-sandbox-real' \"$@\"\n"
        .utf8
    ).write(to: URL(fileURLWithPath: bin + "/iso-sandbox"))
    chmod(bin + "/iso-sandbox", 0o755)
    try install.backend.setup(
      SetupOptions(
        rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
    let environment = ConfigEnvironment(
      home: install.root,
      variables: ["HOME": install.root, "PATH": "\(bin):/usr/bin:/bin"])
    lifecycle = ProjectLifecycle(
      context: CommandContext(
        environment: environment, config: install.config, backend: install.backend,
        output: SilentOutput(), diagnostics: Diagnostics(verbosity: 0) { _ in },
        ssh: SSHClient(environment: environment.variables, tools: .searchPath)),
      noGitHub: true, secretResolver: NoSecrets(), executable: nil,
      prepareGitHub: { config, _, _, _ in config })
    workspace = install.root + "/work"
    try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    try writeFile(workspace + "/file.txt", "workspace\n")
    let root = install.config.instancesDirectory
    handles = try slotNames.enumerated().map { slot, name in
      guard let index = InstanceIndex(UInt16(200 + slot)) else {
        throw HostError("no instance index \(200 + slot)")
      }
      return Instance(
        name: try InstanceName(name), index: index, directory: root.appending(name).path,
        image: .default)
    }
  }

  var backend: AppleBackend { install.backend }
  var bootOptions: BootOptions {
    BootOptions(
      noAgents: true, noPrompt: true,
      configTarget: ConfigTarget(path: install.root + "/c.jsonc", format: .jsonc))
  }

  func withFaults<T>(_ verbs: [String], _ body: () throws -> T) throws -> T {
    let markers = verbs.map { install.root + "/bin/fail-" + $0 }
    for marker in markers { FileManager.default.createFile(atPath: marker, contents: nil) }
    defer { for marker in markers { try? FileManager.default.removeItem(atPath: marker) } }
    return try body()
  }

  /// Runs `step` for real: its outcome, the machine a create made, and why
  /// it failed.
  func run(_ step: Step) -> (Outcome, MachineName?, String?) {
    do {
      let machine = try perform(step)
      return (.succeeds, machine, nil)
    } catch {
      return (.fails, nil, oneLine(error))
    }
  }

  private func allocate(_ slot: Int) throws -> Instance {
    let instance = try Instance.allocate(
      install.config, name: handles[slot].name, image: .default, workspacePath: nil)
    handles[slot] = instance
    return instance
  }

  private func createdMachine(_ instance: Instance) throws -> MachineName? {
    if let sidecar = try MachineSidecar.loadIfPresent(instance) { return sidecar.machineID }
    return try Journal.loadIfPresent(instance)?.machineID
  }

  private func perform(_ step: Step) throws -> MachineName? {
    switch step {
    case .up(let slot):
      let instance = try lifecycle.allocateAndStart(
        name: handles[slot].name, image: .default, workspacePath: nil,
        CreationRequest(boot: bootOptions))
      handles[slot] = instance
      return try createdMachine(instance)
    case .upFailingBoot(let slot):
      _ = try withFaults(["start"]) {
        try lifecycle.allocateAndStart(
          name: handles[slot].name, image: .default, workspacePath: nil,
          CreationRequest(boot: bootOptions))
      }
    case .killedUp(let slot):
      let instance = try allocate(slot)
      do {
        try withFaults(["start"]) { try backend.createAndStart(instance, diskGiB: nil) }
      } catch {
        // The killed process never reached its cleanup; report what it left.
        if let machine = try createdMachine(instance) { return machine }
        throw error
      }
      throw HostError("the injected boot failure did not fail the create")
    case .start(let slot):
      try lifecycle.restart(handles[slot], RestartRequest(boot: bootOptions))
    case .startFailingBoot(let slot):
      try withFaults(["start"]) {
        try lifecycle.restart(handles[slot], RestartRequest(boot: bootOptions))
      }
    case .startUnconfirmed(let slot):
      // Only an enrolled instance has a pin for the boot to contradict.
      let pin = URL(fileURLWithPath: handles[slot].knownHostsPath)
      let pinned = FileManager.default.contents(atPath: pin.path)
      if pinned != nil { try Data("unpinned\n".utf8).write(to: pin) }
      defer { if let pinned { try? pinned.write(to: pin) } }
      try withFaults(["stop"]) {
        try lifecycle.restart(handles[slot], RestartRequest(boot: bootOptions))
      }
    case .stop(let slot):
      try lifecycle.stop(handles[slot])
    case .stopUnconfirmed(let slot):
      _ = try withFaults(["stop"]) { try lifecycle.stop(handles[slot]) }
    case .crash(let slot):
      if let sidecar = try? MachineSidecar.loadIfPresent(handles[slot]),
        try backend.runtime().listed(sidecar.machineID) == .running
      {
        _ = try backend.runtime().stop(sidecar.machineID)
      }
    case .destroy(let slot):
      try destroy(handles[slot])
    case .destroyFailingDelete(let slot):
      try withFaults(["delete"]) { try destroy(handles[slot]) }
    case .destroyAll:
      for instance in try lifecycle.listInstances() { try destroy(instance) }
    case .stage(let slot):
      try makeSelectedStage(StageLocation(handles[slot]), destination: workspace) { tree in
        try writeFile(tree + "/returned.txt", "from the guest\n")
      }
    case .killedReceive(let slot):
      let location = StageLocation(handles[slot])
      let lock = try location.lock()
      defer { lock.release() }
      _ = try ReceiveAttempt(location)
    case .discard(let slot):
      _ = try WorkspaceTransfer(
        client: lifecycle.context.ssh, diagnostics: lifecycle.context.diagnostics
      )
      .discardStage(handles[slot])
    case .inputs(let slot):
      let snapshot = try InputSnapshot.capture(
        root: workspace, input: .defaults,
        budget: InputBudget(WorkspaceInputConfig.defaults.limits),
        stateDirectory: handles[slot].directory + "/inputs", wholeRoot: true)
      snapshot.remove()
    case .grants(let slot):
      _ = try GrantLedger.reconcile(
        handles[slot], revoked: [], environment: [try EnvVarName("MODEL_GRANT"): .literal("1")],
        forwards: [], fresh: ["MODEL_GRANT"])
    case .lateWrites(let slot):
      BoundaryAudit.record(handles[slot], .stop)
      ComputerUseAudit.record(handles[slot], boot: String(repeating: "b", count: 32), [.stop])
    }
    return nil
  }

  /// `iso destroy`'s per-instance removal.
  private func destroy(_ instance: Instance) throws {
    lifecycle.agents.proxies.stopAll(instance)
    try backend.destroyInstance(instance)
  }

  // MARK: Observation

  /// Every disagreement between the host and runtime state and `model`.
  func disagreements(_ model: [ModelInstance?]) throws -> [String] {
    var problems: [String] = []
    let listed = try runtimeSandboxes()
    var expectedSandboxes: [String: String] = [:]
    let instancesRoot = install.config.instancesDirectory.path
    for (slot, expected) in model.enumerated() {
      let handle = handles[slot]
      let name = slotNames[slot]
      var info = stat()
      let exists = lstat(handle.directory, &info) == 0
      guard let expected else {
        if exists {
          problems.append("\(name): destroyed or never created, but its directory exists")
        }
        continue
      }
      guard exists else {
        problems.append("\(name): expected \(expected.phase), but its directory is gone")
        continue
      }
      expectedSandboxes[expected.machine.rawValue] =
        expected.phase == .running ? "running" : "stopped"
      let journal = try Journal.loadIfPresent(handle)?.op
      switch (expected.phase, journal) {
      case (.running, nil), (.stopped, nil), (.interrupted, .create?), (.destroyPending, .destroy?):
        break
      default:
        problems.append(
          "\(name): expected \(expected.phase), journal is \(String(describing: journal))")
      }
      let recorded = try MachineSidecar.loadIfPresent(handle) != nil
      if recorded != expected.recorded {
        problems.append(
          "\(name): machine record present is \(recorded), expected \(expected.recorded)")
      }
      let fenced = FileManager.default.fileExists(atPath: HandoffFence.path(handle))
      if fenced != expected.fenced {
        problems.append("\(name): fenced is \(fenced), expected \(expected.fenced)")
      }
      let retained = StageLocation(handle).exists
      if retained != expected.retained {
        problems.append(
          "\(name): retained return state is \(retained), expected \(expected.retained)")
      }
    }
    if listed != expectedSandboxes {
      problems.append("runtime sandboxes are \(listed), expected \(expectedSandboxes)")
    }
    let present = Set(model.indices.filter { model[$0] != nil }.map { slotNames[$0] })
    let entries = Set(
      ((try? FileManager.default.contentsOfDirectory(atPath: instancesRoot)) ?? [])
        .filter { !$0.hasPrefix(".") })
    if entries != present {
      problems.append("instances directory holds \(entries.sorted()), expected \(present.sorted())")
    }
    let listedNames = Set(try InstanceStore.list(install.config).map(\.name.rawValue))
    if listedNames != present {
      problems.append("instance listing is \(listedNames.sorted()), expected \(present.sorted())")
    }
    problems += heldLocks()
    return problems
  }

  /// Every sandbox the fake runtime holds and its status, read from its state
  /// file (what `iso-sandbox list` reports) without another runtime call.
  func runtimeSandboxes() throws -> [String: String] {
    let path = try backend.runtime().root + "/fake-state.json"
    let state = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    let sandboxes = (state as? [String: Any])?["sandboxes"] as? [String: [String: Any]] ?? [:]
    return sandboxes.compactMapValues { $0["status"] as? String }
  }

  /// Lock and lease files under the data directory that another descriptor
  /// still holds once an operation has returned.
  func heldLocks() -> [String] {
    let data = install.config.dataDirectory.path
    guard let walker = FileManager.default.enumerator(atPath: data) else { return [] }
    var held: [String] = []
    while let relative = walker.nextObject() as? String {
      let name = (relative as NSString).lastPathComponent
      guard name.hasSuffix(".lock") || name == "lease" else { continue }
      let fd = open(data + "/" + relative, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { continue }
      if flock(fd, LOCK_EX | LOCK_NB) != 0 { held.append(relative) }
      close(fd)
    }
    return held.map { "lock still held after the operation returned: \($0)" }
  }
}

// MARK: - The property

@Test func instanceLifecycleAgreesWithAStateModel() throws {
  let harness = try LifecycleHarness()
  defer { harness.install.remove() }
  var harnessError: (any Error)?
  let failure = checkProperty(
    "instance lifecycle against its state model", iterations: 3, generate: generateSteps
  ) { steps -> String? in
    var model: [ModelInstance?] = slotNames.map { _ in nil }
    var trace: [String] = []
    // Every case ends with `destroy --all`, so the next starts from setup.
    for step in steps + [.destroyAll] {
      let (observed, machine, reason) = harness.run(step)
      let expected = apply(step, &model, created: machine)
      trace.append("\(step): " + (reason.map { "fails (\($0))" } ?? "succeeds"))
      if observed != expected {
        return
          "\(step) \(observed == .succeeds ? "succeeded" : "failed"), the model says it \(expected == .succeeds ? "succeeds" : "fails")\n  trace: \(trace)"
      }
      do {
        let problems = try harness.disagreements(model)
        if !problems.isEmpty {
          return "after \(step): \(problems.joined(separator: "; "))\n  trace: \(trace)"
        }
      } catch {
        harnessError = error
        return "observation failed after \(step): \(error)"
      }
    }
    return nil
  }
  if let harnessError { throw harnessError }
  if let failure { Issue.record(Comment(rawValue: failure.description)) }
}
