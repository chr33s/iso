import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

/// A controllable clock: wall and monotonic time advance only on `advance`.
final class ManualClock: HostClock {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)
  private let baseInstant = ContinuousClock.now
  private let offset = Mutex<Duration>(.zero)

  func now() -> Date { base.addingTimeInterval(offset.withLock { $0 }.seconds) }
  func monotonic() -> ContinuousClock.Instant { baseInstant + offset.withLock { $0 } }
  func advance(_ duration: Duration) { offset.withLock { $0 += duration } }
}

/// A native runtime fake recording every effect; faults are injected per call.
final class FakeNativeHost: NativeHost {
  enum VM: Equatable {
    case stopped
    case running(BootID)
  }

  struct State {
    var vms: [MachineName: VM] = [:]
    var calls: [String] = []
    var faults: [String: NativeFailure] = [:]
    /// Applies the effect, then reports this failure (a lost runtime reply).
    var afterEffect: [String: NativeFailure] = [:]
    var qualified = true
    var results: [UInt8] = tarArchive([("out.txt", Array("result\n".utf8))])
    var endpoint = GuestEndpoint(address: try! IPv4Address("127.0.0.1"), port: 22)
    var bootCounter = 0
    var preparedImages: Set<ImageName> = [.default]
    var builds = 0
    var lastExpiry: Date?
    /// Every stop fails with no effect until cleared (a VM that will not stop).
    var stopRefused = false
    /// The next boot comes up crashed; observed as unhealthy until stopped.
    var unhealthyAfterBoot = false
    /// The next create leaves its VM crashed (unhealthy) or running.
    var unhealthyAfterCreate = false
    var createdRunning = false
    var unhealthy: Set<MachineName> = []
    /// Runs once inside the named call, before its effect (an interleaving).
    var during: [String: @Sendable () -> Void] = [:]
  }

  let state = Mutex(State())

  func calls(_ name: String) -> Int { state.withLock { $0.calls.filter { $0 == name }.count } }
  func vm(_ name: MachineName) -> VM? { state.withLock { $0.vms[name] } }
  func inject(_ call: String, _ failure: NativeFailure) {
    state.withLock { $0.faults[call] = failure }
  }
  func injectAfterEffect(_ call: String, _ failure: NativeFailure) {
    state.withLock { $0.afterEffect[call] = failure }
  }
  func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }

  private func enter(_ call: String) throws(NativeFailure) {
    let (fault, during) = state.withLock { state in
      state.calls.append(call)
      return (state.faults.removeValue(forKey: call), state.during.removeValue(forKey: call))
    }
    during?()
    if let fault { throw fault }
  }

  private func leave(_ call: String) throws(NativeFailure) {
    if let fault = state.withLock({ $0.afterEffect.removeValue(forKey: call) }) { throw fault }
  }

  func qualification() -> RuntimeQualification {
    state.withLock { $0.qualified }
      ? .qualified("fake-runtime 1") : .unqualified("fake unqualified")
  }

  func observe(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure) -> NativeState {
    try enter("observe")
    if state.withLock({ $0.unhealthy.contains(runtime) }) { return .unhealthy("fake crashed") }
    switch vm(runtime) {
    case nil: return .absent
    case .stopped?: return .stopped
    case .running(let boot)?: return .running(boot: boot, address: "127.0.0.1", expiresAt: nil)
    }
  }

  func create(_ instance: InstanceID, runtime: MachineName, spec: VMSpec, owner: OwnerID)
    throws(NativeFailure)
  {
    try enter("create")
    state.withLock { state in
      state.vms[runtime] = .stopped
      if state.unhealthyAfterCreate {
        state.unhealthyAfterCreate = false
        state.unhealthy.insert(runtime)
      }
      if state.createdRunning {
        state.createdRunning = false
        state.bootCounter += 1
        state.vms[runtime] = .running(try! BootID("boot-\(state.bootCounter)"))
      }
    }
    try leave("create")
  }

  func start(_ instance: InstanceID, runtime: MachineName, expiresAt: Date?) throws(NativeFailure) {
    try enter("start")
    state.withLock { state in
      state.bootCounter += 1
      state.vms[runtime] = .running(try! BootID("boot-\(state.bootCounter)"))
      state.lastExpiry = expiresAt
      if state.unhealthyAfterBoot {
        state.unhealthyAfterBoot = false
        state.unhealthy.insert(runtime)
      }
    }
    try leave("start")
  }

  func stop(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure) {
    try enter("stop")
    if state.withLock({ $0.stopRefused }) { throw .failed("stop refused") }
    state.withLock { state in
      if state.vms[runtime] != nil { state.vms[runtime] = .stopped }
      state.unhealthy.remove(runtime)
    }
    try leave("stop")
  }

  func delete(_ instance: InstanceID, runtime: MachineName, owner: OwnerID) throws(NativeFailure) {
    try enter("delete")
    _ = state.withLock { state in
      state.unhealthy.remove(runtime)
      return state.vms.removeValue(forKey: runtime)
    }
    try leave("delete")
  }

  func guestEndpoint(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure)
    -> GuestEndpoint
  {
    try enter("endpoint")
    return state.withLock { $0.endpoint }
  }

  func maintain(_ instance: InstanceID, runtime: MachineName, _ change: Maintenance)
    throws(NativeFailure)
  {
    try enter("maintain")
    guard vm(runtime) == .stopped else { throw .failed("not stopped") }
    try leave("maintain")
  }

  func filteredPolicy(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure)
    -> FilteredGrantPolicy?
  {
    try enter("filtered")
    guard case .running(let boot)? = vm(runtime) else { throw .failed("not running") }
    return FilteredGrantPolicy(bootID: boot, policyHash: try! BootID("fake-policy"))
  }

  func imageReady(_ image: ImageName) -> Bool {
    state.withLock { $0.preparedImages.contains(image) }
  }

  func ensureImage(_ request: ImageRequest) throws(NativeFailure) -> String {
    try enter("image")
    state.withLock { state in
      state.builds += 1
      state.preparedImages.insert(request.image)
    }
    try leave("image")
    return "fake-ref \(String(repeating: "0", count: 64))"
  }

  func guestUser(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure) -> GuestUser {
    .default
  }

  func guestHostKey(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure) -> String {
    try enter("hostkey")
    return fakeGuestHostKey
  }

  func authorizeClientKey(_ instance: InstanceID, runtime: MachineName, key: ClientPublicKey)
    throws(NativeFailure)
  {
    try enter("authorize")
  }

  func removeClientKey(_ instance: InstanceID, runtime: MachineName, key: ClientPublicKey) {
    state.withLock { $0.calls.append("unauthorize") }
  }

  func exportResults(_ instance: InstanceID, runtime: MachineName, limit: UInt64)
    throws(NativeFailure) -> [UInt8]
  {
    try enter("export")
    guard case .running? = vm(runtime) else { throw .failed("not running") }
    return state.withLock { $0.results }
  }
}

/// A syntactically valid ed25519 public key line for tests.
func testPublicKey(_ seed: UInt8) -> String {
  let blob: [UInt8] =
    [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
    + [UInt8](repeating: seed, count: 32)
  return "ssh-ed25519 " + Data(blob).base64EncodedString()
}

let fakeGuestHostKey = testPublicKey(0x47)

/// A minimal ustar archive of regular files (and optional raw entries).
func tarArchive(_ files: [(String, [UInt8])], extra: [[UInt8]] = []) -> [UInt8] {
  var out: [UInt8] = []
  for (name, data) in files {
    out += tarHeader(name: name, size: data.count, type: "0")
    out += data
    out += [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
  }
  for entry in extra { out += entry }
  out += [UInt8](repeating: 0, count: 1024)
  return out
}

func tarHeader(name: String, size: Int, type: Character, link: String = "") -> [UInt8] {
  var header = [UInt8](repeating: 0, count: 512)
  func put(_ text: String, at offset: Int) {
    for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
  }
  put(name, at: 0)
  put("0000644", at: 100)
  put("0000000", at: 108)
  put("0000000", at: 116)
  put(String(size, radix: 8).leftPad(11), at: 124)
  put("00000000000", at: 136)
  header[156] = type.asciiValue ?? 0
  put(link, at: 157)
  put("ustar", at: 257)
  put("00", at: 263)
  for index in 148..<156 { header[index] = 32 }
  let sum = header.reduce(0) { $0 + Int($1) }
  put(String(sum, radix: 8).leftPad(6) + "\0 ", at: 148)
  return header
}

extension String {
  func leftPad(_ width: Int) -> String {
    count >= width ? self : String(repeating: "0", count: width - count) + self
  }
}

/// A supervisor on a fresh temporary root with manual dispatch.
struct SupervisorFixture {
  let root: String
  let owner: OwnerID
  let native: FakeNativeHost
  let clock: ManualClock
  let supervisor: HostSupervisor

  init(
    root existing: String? = nil, owner: OwnerID? = nil, native: FakeNativeHost = FakeNativeHost(),
    clock: ManualClock = ManualClock(), settings: HostSupervisor.Settings? = nil
  ) throws {
    root =
      existing
      ?? FileManager.default.temporaryDirectory.appending(path: "iso-hc-\(UUID())").path
    self.owner = try owner ?? OwnerID(String(repeating: "ab", count: 16))
    self.native = native
    self.clock = clock
    var configured = settings ?? HostSupervisor.Settings()
    configured.dispatch = .manual
    supervisor = try HostSupervisor(
      root: root, owner: self.owner, native: native, clock: clock, settings: configured)
  }

  /// The same root reopened: a new supervisor epoch, same installation.
  func restarted() throws -> SupervisorFixture {
    try SupervisorFixture(root: root, owner: owner, native: native, clock: clock)
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: root) }

  var hostID: HostID { supervisor.installation.hostID }

  func spec(name: String = "proj", egress: EgressMode = .open) throws -> VMSpec {
    try VMSpec.make(
      name: InstanceName(name), image: .default, imageDigest: nil, cpus: 2, memoryMiB: 4096,
      diskGiB: 8, guestOS: .linux, egress: egress)
  }

  func request(_ body: HostRequestBody, operation: HostOperationID? = nil) -> HostRequest {
    HostRequest(hostID: hostID, ownerID: owner, operationID: operation, body: body)
  }

  @discardableResult
  func call(
    _ body: HostRequestBody, operation: HostOperationID? = nil, transport: HostTransportKind = .ssh
  )
    -> Result<JSONValue, HostControlError>
  {
    supervisor.handle(request(body, operation: operation), transport: transport).outcome
  }

  func receipt(
    _ body: HostRequestBody, operation: HostOperationID = .generate(),
    transport: HostTransportKind = .ssh
  ) throws -> OperationReceipt {
    try OperationReceipt(wire: call(body, operation: operation, transport: transport).get())
  }

  func operation(_ id: HostOperationID) throws -> OperationReceipt {
    try OperationReceipt(wire: call(.operationGet(id)).get())
  }

  /// Creates and starts one instance; returns its identity and running observation.
  func running(name: String = "proj", egress: EgressMode = .open) throws -> (
    QualifiedInstance, VMObservation
  ) {
    let created = try receipt(.vmCreate(spec(name: name, egress: egress)))
    supervisor.runPending()
    let instance = try #require(created.instance)
    let spec = try spec(name: name, egress: egress)
    _ = try receipt(
      .vmStart(instance, expectedGeneration: 1, ttlSeconds: 3_600, policy: spec.policyHash))
    supervisor.runPending()
    let observation = try VMObservation(wire: call(.vmInspect(instance)).get())
    return (instance, observation)
  }
}

func failure<T>(_ result: Result<T, HostControlError>) -> HostControlError.Code? {
  if case .failure(let error) = result { return error.code }
  return nil
}
