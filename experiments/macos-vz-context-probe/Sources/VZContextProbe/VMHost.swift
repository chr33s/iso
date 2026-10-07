import Foundation
import Virtualization

/// One VM on its own serial queue: construction, state observation, delegate,
/// start and the stop sequence. `vm-run` and `vm-view` both use it, so the only
/// difference between the two owners is the view. Every VZ call happens on
/// `queue`; `instance` is new for every VM, so a session bound to one VM cannot
/// act on its replacement.
final class VMHost: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
  let queue: DispatchQueue
  let log: EventLog
  let boot: BootIdentity
  let instance = UUID().uuidString

  private let lock = NSLock()
  private var vm: VZVirtualMachine?
  private var observation: NSKeyValueObservation?
  private var _state = "none"
  private var _stopEvent: [String: Any]?

  init(
    configuration: VZVirtualMachineConfiguration, queue: DispatchQueue, log: EventLog,
    boot: BootIdentity
  ) {
    self.queue = queue
    self.log = log
    self.boot = boot
    super.init()
    nonisolated(unsafe) let cfg = configuration
    queue.sync {
      let machine = VZVirtualMachine(configuration: cfg, queue: queue)
      machine.delegate = self
      if let sock = machine.socketDevices.first as? VZVirtioSocketDevice {
        let l = VZVirtioSocketListener()
        l.delegate = boot
        sock.setSocketListener(l, forPort: vsockPort)
      }
      observation = machine.observe(\.state, options: [.initial, .new]) { [weak self] m, _ in
        self?.setState(stateName(m.state))
      }
      vm = machine
    }
  }

  var state: String { lock.withLock { _state } }
  var stopEvent: [String: Any]? { lock.withLock { _stopEvent } }

  private func setState(_ s: String) {
    let changed = lock.withLock { () -> Bool in
      defer { _state = s }
      return _state != s
    }
    if changed { log.emit("vm_state", ["state": s, "vm_instance": instance]) }
  }

  // MARK: delegate (called on `queue`)

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    lock.withLock { _stopEvent = ["kind": "guest_did_stop"] }
    log.emit("vm_guest_did_stop")
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
    lock.withLock { _stopEvent = ["kind": "did_stop_with_error", "error": errorInfo(error)] }
    log.emit("vm_did_stop_with_error", ["error": errorInfo(error)])
  }

  // MARK: lifecycle

  func makeAdaptor() -> VZVirtualMachineViewAdaptor? {
    queue.sync { vm.map { VZVirtualMachineViewAdaptor(virtualMachine: $0) } }
  }

  /// Start and wait for `running`. Result: `result` pass/fail, `error`, `seconds`.
  func start() async -> [String: Any] {
    let t0 = Date()
    var r: [String: Any] = await withCheckedContinuation { cont in
      queue.async { [self] in
        guard let vm else { return cont.resume(returning: ["result": "fail", "error": "no vm"]) }
        vm.start(options: VZMacOSVirtualMachineStartOptions()) { error in
          cont.resume(
            returning: error.map { ["result": "fail", "error": errorInfo($0)] } ?? [
              "result": "pass"
            ])
        }
      }
    }
    r["seconds"] = Date().timeIntervalSince(t0)
    r["vm_instance"] = instance
    log.emit("vm_start", r)
    if r["result"] as? String == "pass" {
      r["running"] = await waitUntil(30) { state == "running" }
    }
    return r
  }

  /// Graceful stop: `requestStop`, then the guest helper's `shutdown -h now`
  /// (a macOS guest may ignore `requestStop`), then `stop()`. `graceful_stop`
  /// is true only for a stop we asked for that ended without `stop()`.
  func stop(requestWait: Double = 60, helperWait: Double = 120) async -> [String: Any] {
    let t0 = Date()
    let before = state
    var r: [String: Any] = ["state_before_stop": before]
    guard before == "running" else {
      r["stop_path"] = "none (already \(before))"
      r["graceful_stop"] = false
      r["final_state"] = before
      return r
    }
    let requested: [String: Any] = await withCheckedContinuation { cont in
      queue.async { [self] in
        guard let vm else { return cont.resume(returning: ["result": "fail", "error": "no vm"]) }
        guard vm.canRequestStop else {
          return cont.resume(returning: [
            "result": "fail", "error": "cannot request stop in \(stateName(vm.state))",
          ])
        }
        do {
          try vm.requestStop()
          cont.resume(returning: ["result": "pass"])
        } catch {
          cont.resume(returning: ["result": "fail", "error": errorInfo(error)])
        }
      }
    }
    log.emit("vm_request_stop", requested)
    r["request_stop"] = requested["result"]
    if let e = requested["error"] { r["request_stop_error"] = e }
    func stopped() -> Bool { state == "stopped" || state == "error" }
    var done =
      requested["result"] as? String == "pass"
      ? await waitUntil(requestWait, interval: 0.5, stopped) : false
    r["request_stop_stopped"] = done
    var path = "request_stop"
    if !done {
      path = "guest_helper_shutdown"
      let sent = boot.requestGuestShutdown()
      log.emit("guest_helper_shutdown", ["sent": sent])
      r["guest_helper_shutdown_sent"] = sent
      if sent { done = await waitUntil(helperWait, interval: 0.5, stopped) }
    }
    if !done {
      path = "forced"
      let forced = await forceStop()
      log.emit("vm_force_stop", forced)
      r["force_stop"] = forced["result"]
    }
    r["stop_path"] = path
    r["graceful_stop"] = done && state == "stopped"
    r["stop_seconds"] = Date().timeIntervalSince(t0)
    r["stop_event"] = stopEvent ?? NSNull()
    r["final_state"] = state
    return r
  }

  func forceStop() async -> [String: Any] {
    await withCheckedContinuation { cont in
      queue.async { [self] in
        guard let vm, vm.state != .stopped else {
          return cont.resume(returning: ["result": "pass"])
        }
        vm.stop { error in
          cont.resume(
            returning: error.map { ["result": "fail", "error": errorInfo($0)] } ?? [
              "result": "pass"
            ])
        }
      }
    }
  }

  func teardown() {
    queue.sync {
      observation?.invalidate()
      observation = nil
      vm = nil
    }
  }
}
