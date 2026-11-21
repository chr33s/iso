// Property tests: the compiler, static evaluator, sliding-window admissions
// and approval check agree with a deliberately naive reading of
// docs/design/iso-policy.md (§4.2-4.4, §6.1, §7.1) over generated policies
// and requests. The reference functions below share no code with IsoPolicy.

import Testing

@testable import IsoPolicy

private func expectHolds(
  _ failure: PropertyFailure?, sourceLocation: SourceLocation = #_sourceLocation
) {
  if let failure {
    Issue.record(Comment(rawValue: failure.description), sourceLocation: sourceLocation)
  }
}

// MARK: - Reference model

/// §4.2: action equal, resource listed, and instance listed or omitted.
private func referenceMatches(
  _ action: PolicyAction, _ resources: [PolicyResource], _ instances: [String]?,
  _ request: PolicyRequest
) -> Bool {
  guard action == request.action else { return false }
  guard resources.contains(request.resource) else { return false }
  guard let instances else { return true }
  return instances.contains(request.instance)
}

private func isLowerASCII(_ c: Character) -> Bool { ("a"..."z").contains(c) && c.isASCII }
private func isDigitASCII(_ c: Character) -> Bool { ("0"..."9").contains(c) && c.isASCII }

/// §4.4: `[a-z][a-z0-9._-]*`, 1-64 ASCII characters.
private func referenceValidID(_ id: String) -> Bool {
  guard let first = id.first, id.count <= 64, id.utf8.count == id.count else { return false }
  return isLowerASCII(first)
    && id.allSatisfy { isLowerASCII($0) || isDigitASCII($0) || "._-".contains($0) }
}

/// iso's instance-name rule: `[A-Za-z0-9_-]`, 1-64 bytes.
private func referenceValidInstance(_ name: String) -> Bool {
  guard !name.isEmpty, name.utf8.count <= 64 else { return false }
  return name.allSatisfy {
    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
  }
}

private func hasDuplicates<T: Equatable>(_ values: [T]) -> Bool {
  for i in values.indices {
    for j in values.indices where i < j && values[i] == values[j] { return true }
  }
  return false
}

private func referenceSelectorValid(
  _ action: PolicyAction, _ resources: [PolicyResource], _ instances: [String]?,
  declared: [PolicyAction]
) -> Bool {
  guard declared.contains(action), !resources.isEmpty, !hasDuplicates(resources) else {
    return false
  }
  for resource in resources {
    let providerAction = action == .credentialUse || action == .proxyRequest
    let providerResource = resource == .anthropic || resource == .openai
    if providerAction != providerResource { return false }
  }
  guard let instances else { return true }
  return !instances.isEmpty && instances.count <= 64 && !hasDuplicates(instances)
    && instances.allSatisfy(referenceValidInstance)
}

/// Whether the compiler should accept `doc`, read straight off §4.2-4.4.
private func referenceIsValid(_ doc: PolicyDocument) -> Bool {
  guard doc.version == 1, !hasDuplicates(doc.actions) else { return false }
  if doc.actions.isEmpty && doc.mode != .off { return false }
  guard doc.rules.count <= 128, doc.guards.count <= 16 else { return false }
  let ids = doc.rules.map(\.id) + doc.guards.map(\.id)
  guard ids.allSatisfy(referenceValidID), !hasDuplicates(ids) else { return false }
  for rule in doc.rules
  where !referenceSelectorValid(rule.action, rule.resources, rule.instances, declared: doc.actions)
  {
    return false
  }
  for entry in doc.guards {
    guard
      referenceSelectorValid(entry.action, entry.resources, entry.instances, declared: doc.actions)
    else { return false }
    switch entry.requirement {
    case .rateLimit(let capacity, let window):
      guard entry.action == .proxyRequest, capacity >= 1, capacity <= 10_000, window >= 1,
        window <= 3_600
      else { return false }
    case .approvalWithin(let seconds):
      guard entry.action == .workspacePullApply, seconds >= 1, seconds <= 900 else {
        return false
      }
    }
  }
  // At most 4 rate guards, and 40,000 slots, for any one provider and
  // instance: every named instance, plus a name no guard mentions.
  let rateGuards = doc.guards.filter {
    if case .rateLimit = $0.requirement { true } else { false }
  }
  let named = rateGuards.flatMap { $0.instances ?? [] }
  for provider in [PolicyResource.anthropic, .openai] {
    for instance in named + ["unnamed instance"] {
      let request = PolicyRequest(action: .proxyRequest, resource: provider, instance: instance)
      let matching = rateGuards.filter {
        referenceMatches($0.action, $0.resources, $0.instances, request)
      }
      var slots = 0
      for entry in matching {
        if case .rateLimit(let capacity, _) = entry.requirement { slots += capacity }
      }
      if matching.count > 4 || slots > 40_000 { return false }
    }
  }
  return true
}

private struct ReferenceStatic: Equatable {
  var outcome: StaticEvaluation.Outcome
  var governed: [PolicyRequest]
  var permits: [String]
  var forbids: [String]
  var guards: [String]
}

/// §6.1 steps 3-4: any matching forbid denies; otherwise every governed
/// action needs a permit; collect every guard matching a governed action.
private func referenceStatic(_ doc: PolicyDocument, _ requests: [PolicyRequest])
  -> ReferenceStatic
{
  let governed = requests.filter { doc.mode != .off && doc.actions.contains($0.action) }
  if governed.isEmpty {
    return ReferenceStatic(
      outcome: .notGoverned, governed: [], permits: [], forbids: [], guards: [])
  }
  var permits: Set<String> = []
  var forbids: Set<String> = []
  var guards: Set<String> = []
  var everyActionPermitted = true
  for request in governed {
    var permitted = false
    for rule in doc.rules
    where referenceMatches(rule.action, rule.resources, rule.instances, request) {
      if rule.effect == .permit {
        permits.insert(rule.id)
        permitted = true
      } else {
        forbids.insert(rule.id)
      }
    }
    if !permitted { everyActionPermitted = false }
    for entry in doc.guards
    where referenceMatches(entry.action, entry.resources, entry.instances, request) {
      guards.insert(entry.id)
    }
  }
  let outcome: StaticEvaluation.Outcome
  if !forbids.isEmpty {
    outcome = .denied(.explicitForbid)
  } else if !everyActionPermitted {
    outcome = .denied(.noPermit)
  } else {
    outcome = .permitted
  }
  return ReferenceStatic(
    outcome: outcome, governed: governed, permits: permits.sorted(), forbids: forbids.sorted(),
    guards: guards.sorted())
}

private func observed(_ evaluation: StaticEvaluation) -> ReferenceStatic {
  ReferenceStatic(
    outcome: evaluation.outcome, governed: evaluation.governed,
    permits: evaluation.matchedPermitIDs, forbids: evaluation.matchedForbidIDs,
    guards: evaluation.guards.map(\.id))
}

// MARK: - Generators

/// Enough valid IDs for every entry of a generated policy, with boundary
/// spellings (64 characters, trailing `.`/`-`/`_`).
private let validIDs = [
  "a", "b", "c", "f", "g", "p", "s", "a.b", "a-b", "a_1", "z9", "x--", "q.", "r_", "m0.n-o_p",
  String(repeating: "a", count: 64),
]
private let invalidIDs = [
  "", "A", "1a", "-a", ".a", "a b", "aB", "\u{E9}", "a/b", "a:b", String(repeating: "a", count: 65),
]
/// Case variants of one name: instance names are compared exactly.
private let validInstances = [
  "vm", "VM", "Vm", "one", "two", "a-b", "a_b", "0", "-", String(repeating: "x", count: 64),
]
private let invalidInstances = [
  "", "a.b", "vm ", "\u{E9}", "a/b", "v\u{0}m", String(repeating: "x", count: 65),
]
private let requestInstances = validInstances + ["other", "vM", "Vm-"]

private func resources(for action: PolicyAction) -> [PolicyResource] {
  PolicyResource.allCases.filter { $0.kind == action.resourceKind }
}

private func selectorInstances(_ rng: inout PropertyRNG) -> [String]? {
  rng.oneIn(2) ? nil : Array(rng.shuffled(validInstances).prefix(rng.int(1...3)))
}

/// A policy that is valid by construction, except that up to five rate
/// guards may share a scope (which the compiler must reject).
private func validDocument(_ rng: inout PropertyRNG) -> PolicyDocument {
  let mode = rng.element(PolicyMode.allCases)
  var actions = rng.subset(PolicyAction.allCases)
  if actions.isEmpty && (mode != .off || rng.oneIn(2)) {
    actions = [rng.element(PolicyAction.allCases)]
  }
  var ids = rng.shuffled(validIDs)
  var rules: [PolicyRule] = []
  var guards: [PolicyGuard] = []
  if !actions.isEmpty {
    for _ in 0..<rng.int(0...6) {
      let action = rng.element(actions)
      rules.append(
        PolicyRule(
          id: ids.removeLast(), effect: rng.oneIn(3) ? .forbid : .permit, action: action,
          resources: rng.subset(resources(for: action), minCount: 1),
          instances: selectorInstances(&rng)))
    }
  }
  if actions.contains(.proxyRequest) {
    for _ in 0..<(rng.oneIn(8) ? 5 : rng.int(0...3)) {
      let capacity = rng.element([1, 2, 3, 9_999, 10_000, rng.int(1...10_000)])
      let window = rng.element([1, 2, 3_599, 3_600, rng.int(1...3_600)])
      guards.append(
        PolicyGuard(
          id: ids.removeLast(), action: .proxyRequest,
          resources: rng.subset(resources(for: .proxyRequest), minCount: 1),
          instances: selectorInstances(&rng),
          requirement: .rateLimit(maxRequests: capacity, withinSeconds: window)))
    }
  }
  if actions.contains(.workspacePullApply) {
    for _ in 0..<rng.int(0...2) {
      guards.append(
        PolicyGuard(
          id: ids.removeLast(), action: .workspacePullApply, resources: [.attachedWorkspace],
          instances: selectorInstances(&rng),
          requirement: .approvalWithin(seconds: rng.element([1, 2, 899, 900, rng.int(1...900)]))))
    }
  }
  return PolicyDocument(version: 1, mode: mode, actions: actions, rules: rules, guards: guards)
}

private struct Selector {
  var id: String
  var action: PolicyAction
  var resources: [PolicyResource]
  var instances: [String]?
}

/// One plausible authoring mistake applied to `doc`; the result may still
/// be valid when the chosen mistake does not apply.
private func corrupted(_ doc: PolicyDocument, _ rng: inout PropertyRNG) -> PolicyDocument {
  var version = doc.version
  var mode = doc.mode
  var actions = doc.actions
  var rules = doc.rules
  var guards = doc.guards
  func editSelector(_ rng: inout PropertyRNG, _ edit: (inout Selector, inout PropertyRNG) -> Void) {
    let total = rules.count + guards.count
    guard total > 0 else { return }
    let index = rng.below(total)
    if index < rules.count {
      let r = rules[index]
      var s = Selector(id: r.id, action: r.action, resources: r.resources, instances: r.instances)
      edit(&s, &rng)
      rules[index] = PolicyRule(
        id: s.id, effect: r.effect, action: s.action, resources: s.resources,
        instances: s.instances)
    } else {
      let g = guards[index - rules.count]
      var s = Selector(id: g.id, action: g.action, resources: g.resources, instances: g.instances)
      edit(&s, &rng)
      guards[index - rules.count] = PolicyGuard(
        id: s.id, action: s.action, resources: s.resources, instances: s.instances,
        requirement: g.requirement)
    }
  }
  switch rng.below(15) {
  case 0: version = rng.element([0, 2, -1])
  case 1: if let first = actions.first { actions.append(first) }
  case 2:
    actions = []
    mode = rng.element([.shadow, .enforce])
  case 3: editSelector(&rng) { s, rng in s.id = rng.element(invalidIDs) }
  case 4:
    let ids = rules.map(\.id) + guards.map(\.id)
    if let other = ids.first { editSelector(&rng) { s, _ in s.id = other } }
  case 5: editSelector(&rng) { s, rng in s.action = rng.element(PolicyAction.allCases) }
  case 6: editSelector(&rng) { s, _ in s.resources = [] }
  case 7: editSelector(&rng) { s, _ in s.resources += s.resources.prefix(1) }
  case 8: editSelector(&rng) { s, rng in s.resources.append(rng.element(PolicyResource.allCases)) }
  case 9: editSelector(&rng) { s, _ in s.instances = [] }
  case 10: editSelector(&rng) { s, rng in s.instances = (s.instances ?? ["vm"]) + ["vm"] }
  case 11:
    editSelector(&rng) { s, rng in
      s.instances = [rng.element(invalidInstances)] + (s.instances ?? [])
    }
  case 12:
    if !guards.isEmpty {
      let index = rng.below(guards.count)
      let g = guards[index]
      let requirement: GuardRequirement =
        switch rng.below(5) {
        case 0: .rateLimit(maxRequests: rng.element([0, -1, 10_001]), withinSeconds: 60)
        case 1: .rateLimit(maxRequests: 1, withinSeconds: rng.element([0, -1, 3_601]))
        case 2: .approvalWithin(seconds: rng.element([0, -1, 901]))
        // The right bounds on what may be the wrong action.
        case 3: .rateLimit(maxRequests: 1, withinSeconds: 1)
        default: .approvalWithin(seconds: 1)
        }
      guards[index] = PolicyGuard(
        id: g.id, action: g.action, resources: g.resources, instances: g.instances,
        requirement: requirement)
    }
  case 13:
    if let action = actions.first {
      let resource = resources(for: action)[0]
      let extra = rng.oneIn(2) ? 129 - rules.count : 0
      for index in 0..<max(extra, 0) {
        rules.append(
          PolicyRule(id: "n\(index)", effect: .permit, action: action, resources: [resource]))
      }
    }
  default:
    editSelector(&rng) { s, _ in
      s.instances = (0..<65).map { "i\($0)" }
    }
  }
  return PolicyDocument(
    version: version, mode: mode, actions: actions, rules: rules, guards: guards)
}

private func randomRequest(_ rng: inout PropertyRNG) -> PolicyRequest {
  // Includes action/resource kind mismatches, which simply match nothing.
  PolicyRequest(
    action: rng.element(PolicyAction.allCases), resource: rng.element(PolicyResource.allCases),
    instance: rng.element(requestInstances))
}

private func requestBatches(_ rng: inout PropertyRNG) -> [[PolicyRequest]] {
  var batches: [[PolicyRequest]] = []
  for _ in 0..<4 { batches.append((0..<rng.int(0...3)).map { _ in randomRequest(&rng) }) }
  for provider in [PolicyResource.anthropic, .openai] {
    batches.append(PolicyEvaluator.providerBatch(provider, instance: rng.element(requestInstances)))
  }
  let instance = rng.element(requestInstances)
  for action in PolicyAction.allCases {
    for resource in PolicyResource.allCases {
      batches.append([PolicyRequest(action: action, resource: resource, instance: instance)])
    }
  }
  return batches
}

private struct StaticCase: CustomDebugStringConvertible {
  let document: PolicyDocument
  let batches: [[PolicyRequest]]
  var debugDescription: String { "\(document)" }
}

// MARK: - Static evaluation and compilation

@Test func compilerAcceptsExactlyTheReferenceValidPolicies() {
  expectHolds(
    checkProperty(
      "compile validity", iterations: 1_500,
      generate: { rng in
        let doc = validDocument(&rng)
        return rng.oneIn(3) ? doc : corrupted(doc, &rng)
      },
      property: { doc in
        let accepted = (try? PolicyCompiler.compile(doc)) != nil
        let expected = referenceIsValid(doc)
        return accepted == expected ? nil : "compiler accepted=\(accepted), reference=\(expected)"
      }))
}

@Test func staticEvaluationAgreesWithTheReference() {
  expectHolds(
    checkProperty(
      "static evaluation", iterations: 1_000,
      generate: { rng in StaticCase(document: validDocument(&rng), batches: requestBatches(&rng)) },
      property: { input in
        guard let policy = try? PolicyCompiler.compile(input.document) else {
          return referenceIsValid(input.document) ? "reference-valid policy did not compile" : nil
        }
        for batch in input.batches {
          let actual = observed(PolicyEvaluator.evaluateStatic(batch, policy: policy))
          let expected = referenceStatic(input.document, batch)
          if actual != expected { return "batch \(batch): got \(actual), expected \(expected)" }
        }
        return nil
      }))
}

/// Shuffles every order-free part of `doc`: entry order, and set-valued arrays.
private func reordered(_ doc: PolicyDocument, _ rng: inout PropertyRNG) -> PolicyDocument {
  let rules = doc.rules.map {
    PolicyRule(
      id: $0.id, effect: $0.effect, action: $0.action, resources: rng.shuffled($0.resources),
      instances: $0.instances.map { rng.shuffled($0) })
  }
  let guards = doc.guards.map {
    PolicyGuard(
      id: $0.id, action: $0.action, resources: rng.shuffled($0.resources),
      instances: $0.instances.map { rng.shuffled($0) }, requirement: $0.requirement)
  }
  return PolicyDocument(
    version: doc.version, mode: doc.mode, actions: rng.shuffled(doc.actions),
    rules: rng.shuffled(rules), guards: rng.shuffled(guards))
}

@Test func compilationIsOrderFreeIdempotentAndRoundTrips() {
  expectHolds(
    checkProperty(
      "order-free compilation", iterations: 500,
      generate: { rng in
        let doc = validDocument(&rng)
        return (doc, reordered(doc, &rng))
      },
      property: { pair in
        guard let a = try? PolicyCompiler.compile(pair.0) else { return nil }
        guard let b = try? PolicyCompiler.compile(pair.1) else {
          return "a reordering of a valid policy did not compile"
        }
        if a != b { return "reordering changed the compiled policy: \(a.digest) vs \(b.digest)" }
        guard (try? PolicyCompiler.compile(a.document)) == a else {
          return "recompiling the normalized document changed it"
        }
        guard (try? PolicyCanonical.decode(a.canonicalBytes)) == a else {
          return "canonical bytes do not decode to the same policy"
        }
        return nil
      }))
}

@Test func addingAForbidNeverWidens() {
  expectHolds(
    checkProperty(
      "forbid only narrows", iterations: 500,
      generate: { rng -> (PolicyDocument, PolicyRule, [[PolicyRequest]]) in
        let doc = validDocument(&rng)
        let action = doc.actions.isEmpty ? PolicyAction.proxyRequest : rng.element(doc.actions)
        let forbid = PolicyRule(
          id: "added-forbid", effect: .forbid, action: action,
          resources: rng.subset(resources(for: action), minCount: 1),
          instances: selectorInstances(&rng))
        return (doc, forbid, requestBatches(&rng))
      },
      property: { input in
        let (doc, forbid, batches) = input
        let wider = PolicyDocument(
          version: doc.version, mode: doc.mode, actions: doc.actions, rules: doc.rules + [forbid],
          guards: doc.guards)
        guard let before = try? PolicyCompiler.compile(doc),
          let after = try? PolicyCompiler.compile(wider)
        else { return nil }
        for batch in batches {
          let old = PolicyEvaluator.evaluateStatic(batch, policy: before).outcome
          let new = PolicyEvaluator.evaluateStatic(batch, policy: after).outcome
          let hits = batch.contains {
            after.governedActions.contains($0.action)
              && referenceMatches(forbid.action, forbid.resources, forbid.instances, $0)
          }
          if hits && new != .denied(.explicitForbid) { return "matching forbid gave \(new)" }
          if !hits && new != old { return "non-matching forbid changed \(old) to \(new)" }
        }
        return nil
      }))
}

// MARK: - Sliding-window admissions

private struct AdmissionCase: CustomDebugStringConvertible {
  let document: PolicyDocument
  let provider: PolicyResource
  let instance: String
  /// Time samples in nanoseconds; nil is an unusable clock.
  let samples: [UInt64?]
  var debugDescription: String { "\(document) \(provider) \(instance) samples=\(samples)" }
}

private func admissionCase(_ rng: inout PropertyRNG) -> AdmissionCase {
  let provider = rng.element([PolicyResource.anthropic, .openai])
  let mode: PolicyMode = rng.oneIn(8) ? rng.element([.off, .shadow]) : .enforce
  let actions: [PolicyAction] =
    rng.oneIn(8) ? [rng.element(PolicyAction.allCases)] : [.credentialUse, .proxyRequest]
  var rules: [PolicyRule] = []
  for (index, action) in actions.enumerated() where action != .workspacePullApply {
    if !rng.oneIn(6) {
      rules.append(
        PolicyRule(
          id: "permit\(index)", effect: .permit, action: action,
          resources: rng.subset([.anthropic, .openai], minCount: 1),
          instances: rng.oneIn(4) ? selectorInstances(&rng) : nil))
    }
    if rng.oneIn(10) {
      rules.append(
        PolicyRule(id: "forbid\(index)", effect: .forbid, action: action, resources: [provider]))
    }
  }
  var guards: [PolicyGuard] = []
  if actions.contains(.proxyRequest) {
    for index in 0..<rng.int(1...4) {
      guards.append(
        PolicyGuard(
          id: "rate\(index)", action: .proxyRequest,
          resources: rng.subset([.anthropic, .openai], minCount: 1),
          instances: rng.oneIn(4) ? selectorInstances(&rng) : nil,
          requirement: .rateLimit(maxRequests: rng.int(1...4), withinSeconds: rng.int(1...3))))
    }
  }
  let doc = PolicyDocument(version: 1, mode: mode, actions: actions, rules: rules, guards: guards)
  var now = UInt64(rng.int(0...3)) * second + UInt64(rng.int(0...2))
  var samples: [UInt64?] = []
  for _ in 0..<rng.int(1...40) {
    switch rng.below(20) {
    case 0: samples.append(nil)
    case 1: samples.append(now == 0 ? 0 : now - 1)
    default:
      let step: UInt64 = rng.element([
        0, 0, 1, second - 1, second, second + 1, 2 * second - 1, 2 * second, 3 * second - 1,
        3 * second, UInt64(rng.int(0...1_500_000_000)),
      ])
      now += step
      samples.append(now)
    }
  }
  return AdmissionCase(
    document: doc, provider: provider, instance: rng.element(requestInstances), samples: samples)
}

private struct ReferenceAdmission: Equatable {
  var reason: PolicyReason
  var failed: [String]
  var retryAfter: Int?
}

@Test func admissionsAgreeWithANaiveTimestampLog() {
  expectHolds(
    checkProperty(
      "sliding-window admissions", iterations: 600,
      generate: { rng in admissionCase(&rng) },
      property: { input in
        guard let policy = try? PolicyCompiler.compile(input.document) else {
          return "generated admission policy did not compile"
        }
        var state = ProviderAdmissions(
          policy: policy, provider: input.provider, instance: input.instance, epoch: "e")
        let batch = PolicyEvaluator.providerBatch(input.provider, instance: input.instance)
        let staticResult = referenceStatic(input.document, batch)
        let rateGuards: [(id: String, capacity: Int, window: UInt64)] = input.document.guards
          .filter { staticResult.guards.contains($0.id) }
          .compactMap {
            if case .rateLimit(let capacity, let seconds) = $0.requirement {
              ($0.id, capacity, UInt64(seconds) * second)
            } else {
              nil
            }
          }
        // Every admission ever charged, per guard; never pruned.
        var log: [String: [UInt64]] = [:]
        var lastNow: UInt64 = 0
        for (step, sample) in input.samples.enumerated() {
          let expected: ReferenceAdmission
          if case .denied(let reason) = staticResult.outcome {
            expected = ReferenceAdmission(reason: reason, failed: [], retryAfter: nil)
          } else if staticResult.outcome == .notGoverned {
            expected = ReferenceAdmission(reason: .notGoverned, failed: [], retryAfter: nil)
          } else if let now = sample, now >= lastNow {
            lastNow = now
            var failed: [String] = []
            var longest: UInt64 = 0
            for entry in rateGuards {
              // §7.1: charged while 0 <= now - t < W.
              let live = (log[entry.id] ?? []).filter { now - $0 < entry.window }
              if live.count >= entry.capacity {
                failed.append(entry.id)
                longest = max(longest, entry.window - (now - live.min()!))
              }
            }
            if failed.isEmpty {
              for entry in rateGuards { log[entry.id, default: []].append(now) }
              expected = ReferenceAdmission(reason: .allowed, failed: [], retryAfter: nil)
            } else {
              let seconds = Int(longest / second) + (longest % second == 0 ? 0 : 1)
              expected = ReferenceAdmission(
                reason: .quotaExceeded, failed: failed.sorted(), retryAfter: max(seconds, 1))
            }
          } else {
            expected = ReferenceAdmission(reason: .internalError, failed: [], retryAfter: nil)
          }
          let decision = state.checkAndAdmit(now: sample, decisionID: "\(step)")
          let actual = ReferenceAdmission(
            reason: decision.reason, failed: decision.failedGuardIDs,
            retryAfter: decision.retryAfterSeconds)
          if actual != expected {
            return
              "step \(step) at \(String(describing: sample)): got \(actual), expected \(expected)"
          }
          if decision.requiredGuardIDs != staticResult.guards {
            return "step \(step): required guards \(decision.requiredGuardIDs)"
          }
          if (decision.verdict == .allow) != (expected.reason == .allowed) {
            return "step \(step): verdict \(decision.verdict) for \(expected.reason)"
          }
          for entry in rateGuards {
            let charged = (log[entry.id] ?? []).filter { lastNow - $0 < entry.window }.count
            if state.charged(entry.id) != charged {
              return
                "step \(step): guard \(entry.id) charged \(String(describing: state.charged(entry.id))), expected \(charged)"
            }
          }
        }
        return nil
      }))
}

// MARK: - Approvals

private struct ApprovalCase: CustomDebugStringConvertible {
  let document: PolicyDocument
  let instance: String
  let expected: ApprovalBinding
  let receipt: ApprovalReceipt?
  let now: UInt64?
  var debugDescription: String {
    "\(document) instance=\(instance) receipt=\(String(describing: receipt)) now=\(String(describing: now))"
  }
}

private func approvalCase(_ rng: inout PropertyRNG) -> ApprovalCase {
  let mode: PolicyMode = rng.oneIn(8) ? rng.element([.off, .shadow]) : .enforce
  let actions: [PolicyAction] =
    rng.oneIn(8) ? [.proxyRequest] : [.workspacePullApply, .proxyRequest]
  var rules: [PolicyRule] = []
  var guards: [PolicyGuard] = []
  if actions.contains(.workspacePullApply) {
    for index in 0..<rng.int(0...2) {
      rules.append(
        PolicyRule(
          id: "rule\(index)", effect: rng.oneIn(6) ? .forbid : .permit,
          action: .workspacePullApply, resources: [.attachedWorkspace],
          instances: rng.oneIn(3) ? selectorInstances(&rng) : nil))
    }
    for index in 0..<rng.int(0...3) {
      guards.append(
        PolicyGuard(
          id: "approval\(index)", action: .workspacePullApply, resources: [.attachedWorkspace],
          instances: rng.oneIn(4) ? selectorInstances(&rng) : nil,
          requirement: .approvalWithin(
            seconds: rng.element([1, 2, 60, 899, 900, rng.int(1...900)]))))
    }
  }
  let doc = PolicyDocument(version: 1, mode: mode, actions: actions, rules: rules, guards: guards)
  let digest =
    rng.oneIn(10) ? "sha256:stale" : ((try? PolicyCompiler.compile(doc))?.digest ?? "invalid")
  var fields = ["instance", "boot", "epoch", digest, "workspace", "1:2", "stage", "sha256:m"]
  let expected = binding(fields)
  if rng.oneIn(4) { fields[rng.below(fields.count)] += "x" }
  let issuedAt = UInt64(rng.int(0...1_000)) * second + UInt64(rng.int(0...2))
  var receipt: ApprovalReceipt? =
    rng.oneIn(6)
    ? nil : ApprovalReceipt(approvalID: "a", binding: binding(fields), issuedAt: issuedAt)
  if rng.oneIn(6) { receipt?.consume() }
  let seconds = guards.compactMap {
    if case .approvalWithin(let s) = $0.requirement { UInt64(s) } else { nil }
  }
  let now: UInt64? =
    switch rng.below(12) {
    case 0: nil
    case 1: issuedAt == 0 ? nil : issuedAt - 1
    case 2: issuedAt
    case 3, 4: issuedAt + UInt64(rng.int(0...1_000)) * second
    // A freshness boundary of one of the guards, or one tick either side.
    default:
      max(issuedAt + (seconds.isEmpty ? 1 : rng.element(seconds) * second) - 1, issuedAt)
        + UInt64(rng.int(0...2))
    }
  return ApprovalCase(
    document: doc, instance: rng.element(requestInstances), expected: expected, receipt: receipt,
    now: now)
}

private func binding(_ f: [String]) -> ApprovalBinding {
  ApprovalBinding(
    instanceID: f[0], bootID: f[1], policyEpoch: f[2], policyDigest: f[3],
    workspaceIdentity: f[4], destinationIdentity: f[5], stageID: f[6], manifestDigest: f[7])
}

@Test func approvalCheckAgreesWithTheReference() {
  expectHolds(
    checkProperty(
      "approval check", iterations: 2_000,
      generate: { rng in approvalCase(&rng) },
      property: { input in
        guard let policy = try? PolicyCompiler.compile(input.document) else {
          return "generated approval policy did not compile"
        }
        let request = PolicyRequest(
          action: .workspacePullApply, resource: .attachedWorkspace, instance: input.instance)
        let staticResult = referenceStatic(input.document, [request])
        let approvals: [(id: String, seconds: UInt64)] = input.document.guards
          .filter { staticResult.guards.contains($0.id) }
          .compactMap {
            if case .approvalWithin(let s) = $0.requirement { ($0.id, UInt64(s)) } else { nil }
          }
        // Decision order: static outcome, then receipt presence, reuse,
        // binding, clock, and every freshness bound (0 <= age < seconds).
        var reason = PolicyReason.allowed
        var failed: [String] = []
        var consumedAfter = input.receipt?.consumed ?? false
        if staticResult.outcome == .notGoverned {
          reason = .notGoverned
        } else if case .denied(let staticReason) = staticResult.outcome {
          reason = staticReason
        } else if approvals.isEmpty {
          reason = .allowed
        } else if let receipt = input.receipt {
          if receipt.consumed {
            reason = .approvalConsumed
          } else {
            consumedAfter = true
            if receipt.binding != input.expected || receipt.binding.policyDigest != policy.digest {
              reason = .approvalMismatch
            } else if let now = input.now, now >= receipt.issuedAt {
              let age = now - receipt.issuedAt
              failed = approvals.filter { !(age < $0.seconds * second) }.map(\.id).sorted()
              reason = failed.isEmpty ? .allowed : .approvalExpired
            } else {
              reason = .internalError
            }
          }
        } else {
          reason = .approvalRequired
          failed = approvals.map(\.id).sorted()
        }
        var receipt = input.receipt
        let decision = ApprovalCheck.authorizeAndConsume(
          &receipt, expected: input.expected, policy: policy, instance: input.instance,
          now: input.now, decisionID: "d")
        if decision.reason != reason || decision.failedGuardIDs != failed {
          return "got \(decision.reason) \(decision.failedGuardIDs), expected \(reason) \(failed)"
        }
        if decision.allows != (reason == .allowed) { return "verdict \(decision.verdict)" }
        if (receipt == nil) != (input.receipt == nil) { return "receipt presence changed" }
        if (receipt?.consumed ?? false) != consumedAfter {
          return "consumed=\(String(describing: receipt?.consumed)), expected \(consumedAfter)"
        }
        return nil
      }))
}
