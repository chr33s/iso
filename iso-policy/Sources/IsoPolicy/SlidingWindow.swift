import Darwin

/// Admission timestamps for one rate guard, in a preallocated ring. An
/// admission `t` is charged at `now` while `0 <= now - t < window`; one
/// exactly `window` old has expired. Requests at the same tick count apart.
public struct SlidingWindow: Sendable, Equatable {
  public let capacity: Int
  /// Nanoseconds.
  public let window: UInt64
  private var slots: [UInt64]
  private var head = 0
  public private(set) var count = 0

  public init(capacity: Int, windowSeconds: Int) {
    precondition(PolicySchema.rateCapacity.contains(capacity))
    precondition(PolicySchema.rateWindowSeconds.contains(windowSeconds))
    self.capacity = capacity
    window = UInt64(windowSeconds) * 1_000_000_000
    slots = [UInt64](repeating: 0, count: capacity)
  }

  /// Housekeeping, not consumption: drops admissions that have expired.
  /// `now` must not precede any stored admission.
  public mutating func evict(now: UInt64) {
    while count > 0, now - slots[head] >= window {
      head = (head + 1) % capacity
      count -= 1
    }
  }

  public var isFull: Bool { count >= capacity }

  /// Nanoseconds until the oldest admission expires; nil when not full.
  public func wait(now: UInt64) -> UInt64? {
    guard isFull else { return nil }
    return window - (now - slots[head])
  }

  /// Callers check `isFull` first, under the same lock and time sample.
  public mutating func admit(_ now: UInt64) {
    precondition(!isFull)
    slots[(head + count) % capacity] = now
    count += 1
  }
}

/// A trusted elapsed-time source in nanoseconds; nil when unusable.
public protocol MonotonicClock: Sendable {
  func nanoseconds() -> UInt64?
}

/// `CLOCK_MONOTONIC_RAW`: elapsed time that keeps advancing while the host
/// sleeps and ignores wall-clock changes, so a quota window or approval does
/// not stretch across sleep. Values are process-local; never persist them.
public struct SystemMonotonicClock: MonotonicClock {
  public static let clockID = CLOCK_MONOTONIC_RAW

  public init() {}

  public func nanoseconds() -> UInt64? {
    let value = clock_gettime_nsec_np(Self.clockID)
    return value == 0 ? nil : value
  }
}

/// The admission state one proxy keeps for its bound provider and instance.
/// Pure and unsynchronized: the proxy adapter owns one instance behind one
/// lock shared by every connection, and calls `checkAndAdmit` inside it.
public struct ProviderAdmissions: Sendable {
  public let policy: CompiledPolicy
  public let provider: PolicyResource
  public let instance: String
  public let epoch: String
  /// Constant for a fixed policy, provider and instance: computed once, so
  /// the shared critical section holds only clock, eviction and admission.
  private let evaluation: StaticEvaluation
  /// Keyed by guard ID: distinct guards keep distinct windows.
  private var windows: [String: SlidingWindow]
  private var lastNow: UInt64 = 0

  public init(policy: CompiledPolicy, provider: PolicyResource, instance: String, epoch: String) {
    precondition(provider.kind == .provider)
    self.policy = policy
    self.provider = provider
    self.instance = instance
    self.epoch = epoch
    evaluation = PolicyEvaluator.evaluateStatic(
      PolicyEvaluator.providerBatch(provider, instance: instance), policy: policy)
    var windows: [String: SlidingWindow] = [:]
    for entry in evaluation.guards {
      if case .rateLimit(let capacity, let seconds) = entry.requirement {
        windows[entry.id] = SlidingWindow(capacity: capacity, windowSeconds: seconds)
      }
    }
    self.windows = windows
  }

  /// Timestamp slots allocated for this proxy.
  public var allocatedSlots: Int { windows.values.reduce(0) { $0 + $1.capacity } }

  /// Checks every governed action and every matching rate guard against one
  /// time sample, then charges every guard once, or none.
  public mutating func checkAndAdmit(now: UInt64?, decisionID: String) -> PolicyDecision {
    func decision(_ reason: PolicyReason, failed: [String] = [], retryAfter: Int? = nil)
      -> PolicyDecision
    {
      .from(
        evaluation, policy: policy, epoch: epoch, decisionID: decisionID, reason: reason,
        failed: failed, retryAfter: retryAfter)
    }
    switch evaluation.outcome {
    case .notGoverned: return decision(.notGoverned)
    case .denied(let reason): return decision(reason)
    case .permitted: break
    }
    guard let now, now >= lastNow else { return decision(.internalError) }
    lastNow = now
    var failed: [String] = []
    var longest: UInt64 = 0
    for entry in evaluation.guards {
      guard var window = windows[entry.id] else {
        if case .rateLimit = entry.requirement { return decision(.internalError) }
        continue
      }
      window.evict(now: now)
      windows[entry.id] = window
      if let wait = window.wait(now: now) {
        failed.append(entry.id)
        longest = max(longest, wait)
      }
    }
    guard failed.isEmpty else {
      let seconds = Int((longest + 999_999_999) / 1_000_000_000)
      return decision(.quotaExceeded, failed: failed, retryAfter: max(seconds, 1))
    }
    for entry in evaluation.guards where windows[entry.id] != nil {
      windows[entry.id]!.admit(now)
    }
    return decision(.allowed)
  }

  /// Charged admissions per guard, for tests and bounded diagnostics.
  public func charged(_ guardID: String) -> Int? { windows[guardID]?.count }
}
