import Foundation
import Virtualization

/// One macOS VM on its own serial queue (Gate A). Every VZ call — creation,
/// installer, start, stop, device access — happens on `queue`, and the
/// delegate runs there. Each async transition resolves exactly once.
package final class MacVM: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
  package let queue: DispatchQueue
  /// New for every VM object; sessions bound to one VM die with it.
  package let instance = UUID().uuidString
  private let lock = NSLock()
  private var vm: VZVirtualMachine?
  /// Ports with a registered vsock listener (on the VM queue).
  private var ports: [UInt32] = []
  private var observation: NSKeyValueObservation?
  private var _state = "none"
  private var _stopReason: String?
  private let onStop: @Sendable (String) -> Void
  private let log: @Sendable (String) -> Void

  /// `onStop` runs once, on the VM queue, when the guest stops or the VM
  /// fails; its argument says which.
  package init(
    configuration: VZVirtualMachineConfiguration, label: String,
    log: @escaping @Sendable (String) -> Void,
    onStop: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    // Drain autoreleased VZ objects after every block: a VM object that is
    // never released keeps its auxiliary-storage lock.
    queue = DispatchQueue(
      label: "dev.iso.sandbox.macos.\(label)", autoreleaseFrequency: .workItem)
    self.log = log
    self.onStop = onStop
    super.init()
    nonisolated(unsafe) let cfg = configuration
    queue.sync {
      let machine = VZVirtualMachine(configuration: cfg, queue: queue)
      machine.delegate = self
      observation = machine.observe(\.state, options: [.initial, .new]) { [weak self] m, _ in
        self?.setState(MacVM.name(m.state))
      }
      vm = machine
    }
  }

  package var state: String { lock.withLock { _state } }
  package var stopReason: String? { lock.withLock { _stopReason } }

  private func setState(_ s: String) {
    let changed = lock.withLock { () -> Bool in
      defer { _state = s }
      return _state != s
    }
    if changed { log("vm state \(s)") }
  }

  static func name(_ s: VZVirtualMachine.State) -> String {
    switch s {
    case .stopped: "stopped"
    case .running: "running"
    case .paused: "paused"
    case .error: "error"
    case .starting: "starting"
    case .pausing: "pausing"
    case .resuming: "resuming"
    case .stopping: "stopping"
    case .saving: "saving"
    case .restoring: "restoring"
    @unknown default: "unknown(\(s.rawValue))"
    }
  }

  private func stopped(_ reason: String) {
    let first = lock.withLock { () -> Bool in
      guard _stopReason == nil else { return false }
      _stopReason = reason
      return true
    }
    if first { onStop(reason) }
  }

  package func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    log("guest did stop")
    stopped("guest stopped")
  }

  package func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error)
  {
    log("vm stopped with error: \(error)")
    stopped("vm error: \(error)")
  }

  /// Runs `body` on the VM queue with the VM.
  package func onQueue<T: Sendable>(_ body: @escaping @Sendable (VZVirtualMachine) -> T) async -> T?
  {
    await withCheckedContinuation { cont in
      queue.async { [self] in cont.resume(returning: vm.map(body)) }
    }
  }

  /// Registers `delegate` for host-side vsock `port`, on the VM queue.
  package func setSocketListener(_ delegate: any VZVirtioSocketListenerDelegate, port: UInt32) {
    nonisolated(unsafe) let d = delegate
    queue.sync {
      guard let device = vm?.socketDevices.first as? VZVirtioSocketDevice else { return }
      let listener = VZVirtioSocketListener()
      listener.delegate = d
      device.setSocketListener(listener, forPort: port)
      ports.append(port)
    }
  }

  /// The vsock ports this VM listens on, as registered.
  package var listenerPorts: [UInt32] { queue.sync { ports.sorted() } }

  package func makeViewAdaptor() -> VZVirtualMachineViewAdaptor? {
    queue.sync { vm.map { VZVirtualMachineViewAdaptor(virtualMachine: $0) } }
  }

  package func start(options: VZMacOSVirtualMachineStartOptions = .init()) async throws {
    nonisolated(unsafe) let opts = options
    let error: (any Error)? = await withCheckedContinuation { cont in
      queue.async { [self] in
        guard let vm else { return cont.resume(returning: SandboxError("no vm")) }
        vm.start(options: opts) { cont.resume(returning: $0) }
      }
    }
    if let error { throw error }
    guard await waitUntil(30, { self.state == "running" }) else {
      throw SandboxError("vm did not reach running (\(state))")
    }
  }

  /// `VZMacOSInstaller`, created and started on the VM queue.
  package func install(restoreImage: URL, progress: @escaping @Sendable (Double) -> Void)
    async throws
  {
    let holder = InstallerHolder()
    let error: (any Error)? = await withCheckedContinuation { cont in
      queue.async { [self] in
        guard let vm else { return cont.resume(returning: SandboxError("no vm")) }
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImage)
        holder.observation = installer.progress.observe(\.fractionCompleted) { p, _ in
          progress(p.fractionCompleted)
        }
        holder.installer = installer
        installer.install { result in
          if case .failure(let e) = result {
            cont.resume(returning: e)
          } else {
            cont.resume(returning: nil)
          }
        }
      }
    }
    holder.observation?.invalidate()
    if let error { throw error }
  }

  private final class InstallerHolder: @unchecked Sendable {
    var installer: VZMacOSInstaller?
    var observation: NSKeyValueObservation?
  }

  /// The graceful stop sequence (Gate K): `requestStop`, then the guest
  /// helper's shutdown, then `stop()`. Returns the path taken.
  package func stop(
    // A macOS guest ignored `requestStop` in every qualification run, so its
    // wait is short; the helper's shutdown is the path that works.
    requestWait: TimeInterval = 15, helperWait: TimeInterval = 120,
    helperShutdown: () async -> Bool
  ) async -> String {
    guard state == "running" else { return "none (\(state))" }
    let requested: Bool =
      await onQueue { vm in
        guard vm.canRequestStop else { return false }
        return (try? vm.requestStop()) != nil
      } ?? false
    func isStopped() -> Bool { ["stopped", "error"].contains(state) }
    if requested, await waitUntil(requestWait, isStopped) { return "request_stop" }
    if await helperShutdown(), await waitUntil(helperWait, isStopped) {
      return "guest_helper_shutdown"
    }
    await forceStop()
    return "forced"
  }

  /// `stop()`, bounded: the VM runs in this process, so the caller's exit
  /// (via `onStop`) ends it even if `stop()` never completes.
  package func forceStop(timeout: TimeInterval = 30) async {
    let done = StopFlag()
    queue.async { [self] in
      guard let vm, vm.state != .stopped else { return done.set() }
      vm.stop { _ in done.set() }
    }
    _ = await waitUntil(timeout) { done.isSet }
    stopped("forced stop")
  }

  package func teardown() {
    queue.sync {
      observation?.invalidate()
      observation = nil
      vm = nil
    }
  }
}

/// Poll `cond` until true or timeout.
package func waitUntil(
  _ timeout: TimeInterval, interval: Duration = .milliseconds(250), _ cond: () -> Bool
)
  async -> Bool
{
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if cond() { return true }
    try? await Task.sleep(for: interval)
  }
  return cond()
}
