// Measures static evaluation and check-and-admit apart from any transport
// (docs/design/iso-policy.md §14.4). Prints one JSON object; no claim holds
// beyond the machine, toolchain, policy size and contention it reports.
import Darwin
import Foundation
import IsoPolicy
import Synchronization

func compile(_ object: [String: Any]) -> CompiledPolicy {
  let data = try! JSONSerialization.data(withJSONObject: object)
  return try! PolicyCompiler.compile(
    PolicyDocument.parse(PolicyJSON(foundation: JSONSerialization.jsonObject(with: data))))
}

/// The largest policy v1 accepts under 64 KiB: 128 rules, 16 guards (4 of
/// them rate guards of 10,000 admissions each).
func largestPolicy() -> CompiledPolicy {
  var rules: [[String: Any]] = []
  for index in 0..<128 {
    rules.append([
      "id": "r\(index)", "effect": index == 127 ? "permit" : (index % 2 == 0 ? "permit" : "forbid"),
      "action": ["credential.use", "proxy.request"][index % 2],
      "resources": ["provider:anthropic", "provider:openai"],
      "instances": index == 127 ? ["vm"] : (0..<3).map { "other-\(index)-\($0)" },
    ])
  }
  rules.append(contentsOf: [
    [
      "id": "use", "effect": "permit", "action": "credential.use",
      "resources": ["provider:anthropic"],
    ],
    [
      "id": "request", "effect": "permit", "action": "proxy.request",
      "resources": ["provider:anthropic"],
    ],
  ])
  rules.removeFirst(2)
  var guards: [[String: Any]] = (0..<4).map {
    [
      "id": "rate\($0)", "action": "proxy.request", "resources": ["provider:anthropic"],
      "require": ["rate_limit": ["max_requests": 10_000, "within_seconds": 3_600]],
    ]
  }
  guards += (0..<12).map {
    [
      "id": "approve\($0)", "action": "workspace.pull.apply", "resources": ["workspace:attached"],
      "require": ["approval_within": ["seconds": 900]],
    ]
  }
  return compile([
    "version": 1, "mode": "enforce",
    "actions": ["credential.use", "proxy.request", "workspace.pull.apply"],
    "rules": rules, "guards": guards,
  ])
}

func nanos(_ body: () -> Void) -> UInt64 {
  let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  body()
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
}

func sysctl(_ name: String) -> String {
  var size = 0
  sysctlbyname(name, nil, &size, nil, 0)
  var buffer = [CChar](repeating: 0, count: max(size, 1))
  sysctlbyname(name, &buffer, &size, nil, 0)
  return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}

let policy = largestPolicy()
let batch = PolicyEvaluator.providerBatch(.anthropic, instance: "vm")
let iterations = 200_000
var sink = 0
for _ in 0..<10_000 { sink &+= PolicyEvaluator.evaluateStatic(batch, policy: policy).guards.count }
let staticNs = nanos {
  for _ in 0..<iterations {
    sink &+= PolicyEvaluator.evaluateStatic(batch, policy: policy).guards.count
  }
}

// Uncontended: the clock advances 1 µs per request, so every ring stays below
// capacity long enough to measure both admits and (after 10,000) denials.
var admissions = ProviderAdmissions(
  policy: policy, provider: .anthropic, instance: "vm", epoch: "e")
var now: UInt64 = 1
var admitted = 0
let admitNs = nanos {
  for _ in 0..<iterations {
    now += 1_000
    if admissions.checkAndAdmit(now: now, decisionID: "b").allows { admitted += 1 }
  }
}

// Contended: one shared lock, as in the proxy, across 8 threads.
let threads = 8
let perThread = 25_000
let shared = Mutex(
  ProviderAdmissions(policy: policy, provider: .anthropic, instance: "vm", epoch: "e"))
let clock = SystemMonotonicClock()
let contendedNs = nanos {
  DispatchQueue.concurrentPerform(iterations: threads) { _ in
    for _ in 0..<perThread {
      _ = shared.withLock { $0.checkAndAdmit(now: clock.nanoseconds(), decisionID: "c") }
    }
  }
}
let contendedAdmitted = shared.withLock { $0.charged("rate0") ?? 0 }

let report: [String: Any] = [
  "machine": sysctl("hw.model"), "cpu": sysctl("machdep.cpu.brand_string"),
  "os": ProcessInfo.processInfo.operatingSystemVersionString,
  "policy_canonical_bytes": policy.canonicalBytes.count, "rules": policy.document.rules.count,
  "guards": policy.document.guards.count, "timestamp_slots": admissions.allocatedSlots,
  "static_evaluation_ns_per_batch": Double(staticNs) / Double(iterations),
  "check_and_admit_ns_uncontended": Double(admitNs) / Double(iterations),
  "uncontended_admitted": admitted, "uncontended_requests": iterations,
  "check_and_admit_ns_per_request_8_threads": Double(contendedNs) / Double(threads * perThread),
  "contended_admitted": contendedAdmitted, "contended_requests": threads * perThread,
  "sink": sink & 1,
]
let data = try! JSONSerialization.data(
  withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
