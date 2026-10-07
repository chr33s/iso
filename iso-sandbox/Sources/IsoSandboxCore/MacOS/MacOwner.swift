import AppKit
import Containerization
import ContainerizationExtras
import Foundation
import IsoMacProtocol
import Virtualization

/// Control protocol of a macOS owner (same socket conventions as Linux
/// owners: 0600, owning uid only, one request per connection).
package struct MacControlRequest: Codable, Sendable {
  package enum Op: String, Codable, Sendable {
    case ping, inspect, status, stop
    case cuSession = "cu-session"
    case cuFrame = "cu-frame"
    case cuAct = "cu-act"
  }
  package var op: Op
  package var session: String? = nil
  package var action: CUActionRequest? = nil
  package var basedOnFrame: String? = nil

  package init(
    op: Op, session: String? = nil, action: CUActionRequest? = nil, basedOnFrame: String? = nil
  ) {
    self.op = op
    self.session = session
    self.action = action
    self.basedOnFrame = basedOnFrame
  }
}

package struct MacStatus: Codable, Sendable {
  package var vmState: String
  package var vmInstance: String
  package var bootId: String
  package var enrollment: MacEnrollment
  package var helperConnected: Bool
  package var guestBoot: String?
  package var guestBuild: String?
  /// Bumps on every accepted hello and every loss of the active connection.
  package var helperGeneration: Int
  /// The pinned SSH host key.
  package var sshHostKey: String?
  /// Whether the guest just reported that same key over the authenticated channel.
  package var sshHostKeyConfirmed: Bool
  package var ipv4: String
  package var topology: String
}

package struct MacFrameInfo: Codable, Sendable {
  package var frameId: String
  package var seq: Int
  package var width: Int
  package var height: Int
  package var bootId: String
  package var guestBoot: String
  package var vmInstance: String
  package var sha256: String
  package var timestamp: Date
  package var png: Data
}

package struct MacControlResponse: Codable, Sendable {
  package var ok: Bool
  package var error: String? = nil
  package var inspect: MacEffectiveConfig? = nil
  package var status: MacStatus? = nil
  package var session: String? = nil
  package var binding: CUBinding? = nil
  package var frame: MacFrameInfo? = nil
  /// Input events handed to the view. Submission, not proof of delivery.
  package var submitted: Int? = nil
  package var stopPath: String? = nil

  package init(ok: Bool, error: String? = nil) {
    self.ok = ok
    self.error = error
  }
}

/// The record-backed enrollment store the helper link writes through.
final class MacRecordStore: MacEnrollmentStore, @unchecked Sendable {
  let paths: MacSandboxPaths
  let net: HelperNetwork
  private let lock = NSLock()
  private var record: MacSandboxRecord

  init(paths: MacSandboxPaths, record: MacSandboxRecord, network: HelperNetwork) {
    self.paths = paths
    self.record = record
    self.net = network
  }

  var current: MacSandboxRecord { lock.withLock { record } }
  var isEnrolled: Bool { lock.withLock { record.enrollment == .enrolled } }
  var helperKey: HelperKey? {
    (try? String(contentsOf: paths.helperKey, encoding: .utf8)).flatMap { HelperKey(hex: $0) }
  }
  var authorizedKey: String { lock.withLock { record.authorizedKey } }
  var network: HelperNetwork { net }

  func saveEnrollment(key: HelperKey, sshHostKey: String) throws {
    try lock.withLock {
      guard record.enrollment == .pending else { throw SandboxError("already enrolled") }
      try writeOwnerOnly(paths.helperKey, key.hex + "\n")
      try writeOwnerOnly(paths.sshHostKey, sshHostKey + "\n")
      // Disk first: memory says enrolled only once the record does.
      var updated = record
      updated.enrollment = .enrolled
      try paths.save(updated)
      record = updated
    }
  }

  func markMismatch(_ reason: String) {
    lock.withLock {
      record.enrollment = .identityMismatch
      do {
        try paths.save(record)
      } catch {
        // Memory still refuses this boot; the next boot would not know.
        MacOwner.log("identity mismatch not saved: \(error)")
      }
    }
  }
}

func writeOwnerOnly(_ url: URL, _ text: String) throws {
  let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
  let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw SandboxError("open \(tmp.path): errno \(errno)") }
  let bytes = Array(text.utf8)
  let ok = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
  fsync(fd)
  close(fd)
  guard ok, rename(tmp.path, url.path) == 0 else {
    unlink(tmp.path)
    throw SandboxError("write \(url.path) failed")
  }
}

package enum MacOwner {
  static func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }

  /// Owns one macOS VM until it stops; never returns normally (the process
  /// exits when the VM stops). Runs the AppKit main loop on the main thread.
  @MainActor
  package static func run(root: SandboxRoot, id: SandboxID) throws -> Never {
    let paths = root.macSandbox(id)
    signal(SIGPIPE, SIG_IGN)
    // Held (never closed) for the owner's life; the kernel releases it at exit.
    _ = try claim(paths)
    try? FileManager.default.removeItem(at: paths.live)
    var record = try paths.loadRecord()
    guard record.enrollment != .identityMismatch else {
      throw SandboxError("\(id) has an identity mismatch; recreate it")
    }
    if let expiresAt = record.expiresAt, expiresAt <= Date() {
      log("session expired at \(expiresAt); not booting")
      exit(0)
    }
    // The template must still exist: its hardware model is read below.
    _ = try root.macTemplate(record.template).load()
    // After the previous owner was killed, its VM service can outlive it
    // briefly, holding the disk images; booting before they are released
    // fails ("Failed to lock auxiliary storage"). Its vmnet network can
    // persist longer, in which case the sandbox moves to another subnet.
    try awaitImagesReleased([paths.aux, paths.disk], timeout: 120)
    var network = try makeNetwork(root: root, paths: paths, record: &record)
    guard let iface = try network.createInterface(id.rawValue) as? VmnetNetwork.Interface else {
      throw SandboxError("vmnet returned no interface")
    }
    let device = try iface.device()
    guard let mac = VZMACAddress(string: record.macAddress) else {
      throw SandboxError("bad MAC address \(record.macAddress)")
    }
    device.macAddress = mac
    let address = iface.ipv4Address.address.description
    let helperNet = HelperNetwork(
      address: address, prefix: Int(iface.ipv4Address.prefix.length),
      gateway: iface.ipv4Gateway?.description ?? record.gateway,
      dns: record.network == .shared ? [iface.ipv4Gateway?.description ?? record.gateway] : [])

    let config = try MacConfig.make(
      hardwareModel: try MacConfig.hardwareModel(root.macTemplate(record.template).hardwareModel),
      machineIdentifier: try MacConfig.machineIdentifier(paths.machineID), aux: paths.aux,
      disk: paths.disk, cpus: record.cpus, memoryBytes: record.memoryBytes, network: device)

    let store = MacRecordStore(paths: paths, record: record, network: helperNet)
    let link = MacHelperLink(store: store, log: { log($0) })
    let controlPath = paths.control
    let livePath = paths.live
    let ownerLog: @Sendable (String) -> Void = { log($0) }
    let vm = MacVM(configuration: config, label: id.rawValue, log: ownerLog) { reason in
      log("vm stopped: \(reason); owner exiting")
      try? FileManager.default.removeItem(at: livePath)
      // The vmnet network lives in this process and ends with it. A short
      // delay lets an in-flight `stop` reply reach its caller; the exit is
      // clean, so launchd does not restart the owner.
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        unlink(controlPath.path)
        exit(0)
      }
    }
    vm.setSocketListener(link, port: HelperProtocol.port)

    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    guard let adaptor = vm.makeViewAdaptor() else { throw SandboxError("no view adaptor") }
    let bootId = makeBootID()
    let screen = MacScreen(adaptor: adaptor) {
      guard let guestBoot = link.guestBoot, store.current.enrollment == .enrolled else {
        return nil
      }
      return CUBinding(
        bootId: bootId, vmInstance: vm.instance, guestBoot: guestBoot,
        helperGeneration: link.generation, width: MacDisplay.width, height: MacDisplay.height)
    }
    let effective = MacEffectiveConfig.from(
      config, record: record, vsockPorts: vm.listenerPorts, topology: screen.topology)

    Task { @MainActor in
      do {
        try await vm.start()
      } catch {
        try? Data("\(error)".utf8).write(to: paths.ownerFailed, options: .atomic)
        log("start failed: \(error)")
        exit(0)
      }
      let live = MacLiveState(pid: getpid(), startedAt: Date(), bootId: bootId, ipv4: address)
      try? JSONEncoder.pretty.encode(live).write(to: paths.live, options: .atomic)
      log("started pid=\(live.pid) ipv4=\(address) instance=\(vm.instance)")
    }

    let stopper = MacStopper(vm: vm, link: link)
    if let expiresAt = record.expiresAt {
      Task {
        while Date() < expiresAt {
          try? await Task.sleep(for: .seconds(min(30, max(1, expiresAt.timeIntervalSinceNow))))
        }
        log("session expired at \(expiresAt): stopping")
        _ = await stopper.stop()
      }
    }
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      src.setEventHandler {
        log("signal \(sig): stopping")
        Task { _ = await stopper.stop() }
      }
      src.resume()
      signalSources.append(src)
    }

    try ControlSocket.serveJSON(at: paths.control) {
      (req: MacControlRequest) async -> MacControlResponse in
      await handle(
        req, vm: vm, link: link, store: store, screen: screen, effective: effective, bootId: bootId,
        address: address, stopper: stopper)
    } failure: {
      MacControlResponse(ok: false, error: $0)
    }

    app.run()
    exit(0)
  }

  nonisolated(unsafe) static var signalSources: [any DispatchSourceSignal] = []

  @MainActor
  static func handle(
    _ req: MacControlRequest, vm: MacVM, link: MacHelperLink, store: MacRecordStore,
    screen: MacScreen,
    effective: MacEffectiveConfig, bootId: String, address: String, stopper: MacStopper
  ) async -> MacControlResponse {
    do {
      switch req.op {
      case .ping:
        return MacControlResponse(
          ok: vm.state == "running", error: vm.state == "running" ? nil : vm.state)
      case .inspect:
        var r = MacControlResponse(ok: true)
        r.inspect = effective
        return r
      case .status:
        let confirmed = await verifyPin(link: link, store: store)
        let pin = store.paths.loadPinnedHostKey()
        var r = MacControlResponse(ok: true)
        r.status = MacStatus(
          vmState: vm.state, vmInstance: vm.instance, bootId: bootId,
          enrollment: store.current.enrollment, helperConnected: link.isConnected,
          guestBoot: link.guestBoot, guestBuild: link.guestBuild,
          helperGeneration: link.generation,
          sshHostKey: store.current.enrollment == .enrolled ? pin : nil,
          sshHostKeyConfirmed: confirmed, ipv4: address,
          topology: screen.topology)
        return r
      case .stop:
        var r = MacControlResponse(ok: true)
        r.stopPath = await stopper.stop()
        return r
      case .cuSession:
        guard await verifyPin(link: link, store: store) else {
          throw SandboxError("guest SSH host key not confirmed against the pin")
        }
        guard store.current.enrollment == .enrolled else {
          throw SandboxError("sandbox is \(store.current.enrollment.rawValue)")
        }
        let (id, binding) = try screen.newSession()
        var r = MacControlResponse(ok: true)
        r.session = id
        r.binding = binding
        return r
      case .cuFrame:
        let f = try screen.frame(session: req.session)
        var r = MacControlResponse(ok: true)
        r.frame = MacFrameInfo(
          frameId: f.id, seq: f.seq, width: screen.width, height: screen.height,
          bootId: f.binding.bootId, guestBoot: f.binding.guestBoot,
          vmInstance: f.binding.vmInstance, sha256: f.sha256, timestamp: f.timestamp, png: f.png)
        return r
      case .cuAct:
        guard let action = req.action else { throw SandboxError("cu-act needs an action") }
        let n = try await screen.act(
          session: req.session, request: action, basedOnFrame: req.basedOnFrame)
        var r = MacControlResponse(ok: true)
        r.submitted = n
        return r
      }
    } catch {
      return MacControlResponse(ok: false, error: "\(error)")
    }
  }

  /// Asks the authenticated guest for its SSH host key; one that differs
  /// from the pin marks the sandbox `identity_mismatch` (authenticated
  /// evidence, so it may change host state).
  /// True only when the guest reported exactly the pinned key.
  @discardableResult
  static func verifyPin(link: MacHelperLink, store: MacRecordStore) async -> Bool {
    guard link.isConnected, store.current.enrollment == .enrolled,
      let pinned = store.paths.loadPinnedHostKey()
    else { return false }
    let reported = await Task.detached { link.status() }.value
    guard let reply = reported, reply.type == .statusReply, let got = reply.sshHostKey else {
      return false
    }
    if SSHPublicKey.canonical(got) != pinned {
      store.markMismatch("ssh host key changed")
      return false
    }
    return true
  }

  /// Takes the owner lock for the owner's whole life, under the mutation
  /// guard, as Linux owners do.
  static func claim(_ paths: MacSandboxPaths) throws -> Int32 {
    let guarded = try FileLock.acquire(paths.mutationLock, .exclusive)
    defer { withExtendedLifetime(guarded) {} }
    let fd = open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SandboxError("open \(paths.lock.path): errno \(errno)") }
    for _ in 0..<20 {
      if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
      usleep(100_000)
    }
    close(fd)
    throw SandboxError("\(paths.id) already has an owner")
  }

  /// Waits until no process holds an `flock` on any of `images`, as
  /// Virtualization.framework does while a VM runs. True when it had to wait.
  @discardableResult
  static func awaitImagesReleased(_ images: [URL], timeout: TimeInterval) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var waitedAny = false
    for image in images {
      let fd = open(image.path, O_RDONLY | O_CLOEXEC)
      guard fd >= 0 else { throw SandboxError("open \(image.lastPathComponent): errno \(errno)") }
      defer { close(fd) }
      var waited = false
      while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK, Date() < deadline else {
          throw SandboxError("\(image.lastPathComponent) is still in use by another VM")
        }
        if !waited { log("waiting for the previous VM to release \(image.lastPathComponent)") }
        waited = true
        Thread.sleep(forTimeInterval: 0.5)
      }
      waitedAny = waitedAny || waited
      flock(fd, LOCK_UN)
    }
    return waitedAny
  }

  static func makeNetwork(root: SandboxRoot, paths: MacSandboxPaths, record: inout MacSandboxRecord)
    throws -> any Network
  {
    var attempts = 0
    while true {
      do {
        let subnet = try CIDRv4(record.subnet)
        switch record.network {
        case .shared: return try VmnetNetwork(subnet: subnet)
        case .hostOnly: return try HostOnlyNetwork(subnet: subnet)
        }
      } catch {
        attempts += 1
        guard attempts < Owner.maxNetworkAttempts else { throw error }
        let failed = record.subnetIndex
        var updated = record
        try SubnetAllocator(root: root).quarantineAndReallocate(failed, for: record.id) { next in
          updated.subnetIndex = next
          try paths.save(updated)
        }
        record = updated
        log(
          "subnet \(SandboxRecord.subnet(failed)) unavailable (\(error)); moved to \(record.subnet)"
        )
      }
    }
  }
}

/// Runs the stop sequence once, however many callers ask.
actor MacStopper {
  let vm: MacVM
  let link: MacHelperLink
  private var result: Task<String, Never>?

  init(vm: MacVM, link: MacHelperLink) {
    self.vm = vm
    self.link = link
  }

  /// A stop that found the VM not running (e.g. still starting) is not
  /// remembered, so a later request runs the sequence again.
  func stop() async -> String {
    if let result {
      let path = await result.value
      if !path.hasPrefix("none") { return path }
      self.result = nil
    }
    let vm = self.vm
    let link = self.link
    let t = Task {
      let path = await vm.stop {
        await Task.detached { link.requestShutdown() }.value
      }
      MacOwner.log("stop path: \(path)")
      return path
    }
    result = t
    return await t.value
  }
}
