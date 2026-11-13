import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation
import Synchronization
import vmnet

/// The process that owns one running sandbox VM. Virtualization.framework
/// runs the VM in-process, so the owner's lifetime bounds the VM's.
func makeBootID() -> String {
  var bytes = [UInt8](repeating: 0, count: 16)
  arc4random_buf(&bytes, bytes.count)
  return bytes.map { String(format: "%02x", $0) }.joined()
}

package enum Owner {
  /// systemd's "halt" request: SIGRTMIN+3 on Linux (SIGRTMIN = 34).
  static let systemdHalt = Signal(rawValue: 37)
  static let haltGraceSeconds: UInt64 = 60
  /// After the forced kill, before the owner gives up on the guest agent.
  static let killGraceSeconds: UInt64 = 10

  /// The created VM's live inventory, read and checked against `mode`
  /// before the guest's init runs. Any failure stops the VM unbooted.
  static func checkDevices(
    of id: SandboxID, mode: NetworkMode, display: DisplayMode = .headless,
    read: () async throws -> VMDevices, stop: () async -> Void
  ) async throws -> VMDevices {
    do {
      let devices = try await read()
      try devices.requireExpected(for: mode, display: display)
      return devices
    } catch {
      await stop()
      throw SandboxError("sandbox \(id) stopped unbooted: \(error)")
    }
  }

  /// The kernel a sandbox with `display` boots.
  /// A desktop kernel is installed separately and re-checked against its own pin at every boot.
  static func kernel(root: SandboxRoot, display: DisplayMode) throws -> URL {
    switch display {
    case .headless:
      return root.kernel
    case .virtioDisplay:
      let url = root.desktopKernel
      guard KernelPin.isPinned(url, allowed: KernelPin.desktopAllowed) else {
        throw SandboxError(
          "no pinned desktop kernel in \(root.root.path); run `iso-sandbox init --desktop-kernel`")
      }
      return url
    }
  }

  /// The loop the process runs on its main thread. A display is rendered
  /// in a view, which draws only under AppKit's.
  package enum MainLoop: Sendable { case dispatch, appKit }

  /// The entry point picks the loop from the record before the owner starts, in a
  /// read of its own.
  /// If the record the owner then loads has a display the loop cannot render, it does not boot
  /// (frames would never arrive).
  static func requireLoop(_ loop: MainLoop, for display: DisplayMode) throws {
    guard display == .headless || loop == .appKit else {
      throw SandboxError(
        "this sandbox has a display, but its owner started without the AppKit loop that renders it; start it again"
      )
    }
  }

  package static func run(root: SandboxRoot, id: SandboxID, mainLoop: MainLoop) async throws {
    try root.requireInitialized()
    let paths = root.sandbox(id)
    signal(SIGPIPE, SIG_IGN)
    // Held until the process exits; the kernel then releases it.
    _ = try await claim(root: root, id: id)
    // A stale live.json means the previous owner died without cleanup.
    try? FileManager.default.removeItem(at: paths.live)

    var record = try paths.loadRecord()
    // A relaunch (launchd restarts a crashed owner) never outlives the
    // session: past the deadline the owner exits cleanly without booting,
    // and launchd does not restart a clean exit.
    if let expiresAt = record.expiresAt, expiresAt <= Date() {
      log("session expired at \(expiresAt); not booting")
      return
    }
    // Held (never closed) for the owner's life, like the claim.
    _ = VMLease.hold(
      sandbox: id.rawValue, guestOS: "linux", cpus: record.cpus, memoryBytes: record.memoryBytes)
    let display = record.displayMode
    try requireLoop(mainLoop, for: display)
    let vmm = display.manager(
      VZVirtualMachineManager(
        kernel: Kernel(path: try kernel(root: root, display: display), platform: .linuxArm),
        initialFilesystem: .block(
          format: "ext4", source: root.initfs.path, destination: "/", options: ["ro"])
      ))
    // One vmnet network per sandbox: the sandbox is the only peer on it. A
    // brokered sandbox gets none, and no network device at all.
    var network: (any Network)?
    var interface: (any Interface)?
    if record.network.usesSubnet {
      var opened = try makeNetwork(root: root, paths: paths, record: &record)
      guard let created = try opened.createInterface(id.rawValue) else {
        throw SandboxError("vmnet returned no interface")
      }
      network = opened
      interface = created
    }

    let rootfs = Containerization.Mount.block(
      format: "ext4", source: paths.rootfs.path, destination: "/", options: [])
    let console = try ConsoleLog(url: paths.bootLog)
    let config = machineConfiguration(
      record: record, interface: interface, bootLog: .fileHandle(console.writer))
    let container = try LinuxContainer(
      id.rawValue, rootfs: rootfs, vmm: vmm,
      vm: machineResources(cpus: record.cpus, memoryBytes: record.memoryBytes),
      configuration: config)
    // `create` boots the VM into the framework's init; the guest's own init runs
    // only at `start`, so the device check below precedes any guest-authored
    // code.
    // It runs for every network mode: the framework attaches devices iso did not ask for (a virtio-
    // fs share), and a VM whose live inventory differs never starts.
    try await container.create()
    let devices = try await checkDevices(
      of: id, mode: record.network, display: display,
      read: { try await VMDevices.read(container) },
      stop: { try? await container.stop() })
    try await container.start()

    let live = LiveState(
      pid: getpid(), startedAt: Date(),
      ipv4: interface?.ipv4Address.address.description,
      ipv6: interface?.ipv6Address?.address.description,
      bootId: makeBootID())
    var desktop: LinuxDesktop?
    if display == .virtioDisplay {
      do {
        desktop = try await LinuxDesktop.attach(
          container, bootId: live.bootId, guestComputerUse: record.guestComputerUse,
          log: { log($0) })
      } catch {
        try? await container.stop()
        throw SandboxError("sandbox \(id) stopped: its display did not attach: \(error)")
      }
    }
    let broker: StreamBroker? =
      record.network == .brokered
      ? StreamBroker(
        bootID: live.bootId, networkPolicy: record.networkPolicy, expiresAt: record.expiresAt
      ) { port in
        try await container.dialVsock(port: port)
      } : nil
    // Bound before live.json is written: `start` reports a brokered
    // sandbox ready only once its streams can be requested.
    try broker?.serve(at: paths.streams)
    try JSONEncoder.pretty.encode(live).write(to: paths.live, options: .atomic)
    log(
      "started pid=\(live.pid) ipv4=\(live.ipv4 ?? "-") ipv6=\(live.ipv6 ?? "-") network=\(record.network.rawValue)"
    )

    // The last resort: both kills below are guest-agent RPCs, which a root guest
    // can wedge.
    // The VM runs inside this process, so exiting ends it; a clean exit is not restarted by
    // launchd.
    let liveFile = paths.live
    let controlSocket = paths.control
    let streamSocket = paths.streams
    let attached = desktop
    // After live.json: until then `inspect` would take this boot's counts
    // for an ended boot's.
    let counts = attached.map { desktop in
      BootCountsRecorder(
        url: paths.bootCounts, bootId: live.bootId, log: { log($0) }, counts: { desktop.status })
    }
    await counts?.recordPeriodically()
    let endDisplay: @Sendable () async -> Void = {
      await attached?.stop()
      await counts?.record()
    }
    let lifecycle = Lifecycle(container: container, streams: broker, onHalt: endDisplay) {
      log("guest did not stop: exiting the owner to end the VM")
      try? FileManager.default.removeItem(at: liveFile)
      unlink(controlSocket.path)
      unlink(streamSocket.path)
      // No atexit handlers: a crash in one would exit non-zero and
      // launchd would relaunch the owner.
      _exit(0)
    }
    if let expiresAt = record.expiresAt {
      // Host wall clock, re-read at least every 30 s so host sleep and
      // clock changes count; the guest clock plays no part.
      Task {
        while Date() < expiresAt {
          try? await Task.sleep(for: .seconds(min(30, max(1, expiresAt.timeIntervalSinceNow))))
        }
        log("session expired at \(expiresAt): revoking streams and halting")
        // Existing host-held streams are revoked first; the halt follows.
        broker?.shutdownAll()
        await lifecycle.requestHalt()
      }
    }
    var reported = effectiveConfig(
      record: record, config: config, rootfs: rootfs, devices: devices)
    if let desktop { reported.vsockPorts = await desktop.listenerPorts }
    let effective = reported
    let sessionDeadline = record.expiresAt
    try ControlSocket.serve(at: paths.control) { request in
      switch request.op {
      case .ping:
        return ControlResponse(ok: true)
      case .inspect:
        var response = ControlResponse(ok: true, inspect: effective)
        if let attached {
          response.inspect?.liveViewListening = await attached.liveView.listening
          response.desktop = await attached.status
        }
        return response
      case .exec:
        if let sessionDeadline, Date() >= sessionDeadline {
          return ControlResponse(ok: false, error: "the boot's session has expired")
        }
        guard let argv = request.argv, !argv.isEmpty else {
          return ControlResponse(ok: false, error: "empty argv")
        }
        do {
          let timeout = try ExecTimeout(requested: request.timeoutSeconds)
          return try await exec(container, argv, stdin: request.stdin, timeout: timeout)
        } catch {
          return ControlResponse(ok: false, error: "\(error)")
        }
      case .stop:
        // The halt ends the live view, as on every other way to it.
        await lifecycle.requestHalt()
        await lifecycle.waitStopped()
        return ControlResponse(ok: true)
      case .streams:
        guard let broker else { return ControlResponse(ok: false, error: "not brokered") }
        return ControlResponse(ok: true, streams: broker.open)
      case .closeStreams:
        guard let broker else { return ControlResponse(ok: false, error: "not brokered") }
        if let session = request.session, !validStreamLabel(session) {
          return ControlResponse(ok: false, error: "invalid session label")
        }
        return ControlResponse(ok: true, streams: broker.close(session: request.session))
      case .cu:
        guard let attached else { return ControlResponse(ok: false, error: "no display") }
        guard let fields = request.cu else { return ControlResponse(ok: false, error: "empty cu") }
        // Only a computer-use operation: this owner answers `stop` and
        // `inspect` as its own control operations, never through `cu`.
        guard case .computerUse(let cu) = fields.route else {
          return ControlResponse(
            ok: false, error: "\(fields.op.rawValue) is not a computer-use request")
        }
        if let sessionDeadline, Date() >= sessionDeadline {
          return ControlResponse(ok: false, error: "the boot's session has expired")
        }
        var response = ControlResponse(ok: true)
        response.cu = await attached.respond(cu)
        return response
      }
    }

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let signalSources = [SIGTERM, SIGINT].map { sig in
      let source = DispatchSource.makeSignalSource(signal: sig)
      source.setEventHandler {
        log("signal \(sig): halting")
        Task { await lifecycle.requestHalt() }
      }
      source.resume()
      return source
    }

    // The machine ends when its init exits: a halt request or a guest poweroff.
    let status = try? await container.wait()
    log("init exited status=\(status?.exitCode ?? -1)")
    // A guest poweroff is no halt request: end the live view here too.
    await attached?.stop()
    await counts?.record()
    do {
      try await container.stop()
    } catch {
      log("stop error: \(error)")
    }
    broker?.shutdownAll()
    try? network?.releaseInterface(id.rawValue)
    try? FileManager.default.removeItem(at: paths.live)
    await lifecycle.markStopped()
    unlink(paths.control.path)
    if broker != nil { unlink(paths.streams.path) }
    _ = signalSources
    // Let in-flight `stop` responses flush.
    try? await Task.sleep(for: .milliseconds(200))
  }

  /// Take `id`'s owner lock for the owner's whole life, under the mutation guard,
  /// however the owner was launched: an owner never starts mid-update, and later
  /// mutations see it and refuse.
  /// An interrupted disk update is settled first; the guard is released on return.
  static func claim(root: SandboxRoot, id: SandboxID) async throws -> Int32 {
    let paths = root.sandbox(id)
    let guarded = try await FileLock.acquire(
      paths.mutationLock, .exclusive, polling: .milliseconds(50))
    defer { withExtendedLifetime(guarded) {} }
    let fd = open(paths.lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SandboxError("open \(paths.lock.path): errno \(errno)") }
    do {
      guard try await acquireOwnership(fd) else { throw SandboxError("\(id) already has an owner") }
      try DiskUpdate.settle(paths)
      return fd
    } catch {
      close(fd)
      throw error
    }
  }

  /// `status` probes the owner lock with a momentary non-blocking flock, so
  /// retry briefly rather than mistake a probe for a second owner.
  static func acquireOwnership(_ fd: Int32) async throws -> Bool {
    for _ in 0..<20 {
      if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  /// vmnet keeps a subnet reserved for hours after its owning process dies
  /// uncleanly, so a restarted sandbox may not get its old subnet back, and
  /// several neighbours may be taken the same way.
  /// Quarantine each refused subnet and move on (the address changes; the identity does not).
  static func makeNetwork(root: SandboxRoot, paths: SandboxPaths, record: inout SandboxRecord)
    throws -> any Network
  {
    var current = record
    defer { record = current }
    guard let index = current.subnetIndex else {
      throw SandboxError("\(current.id) records no subnet")
    }
    return try SubnetAllocator(root: root).open(
      from: index, for: current.id,
      attempt: { index -> any Network in
        let subnet = try CIDRv4(SandboxRecord.subnet(index))
        switch current.network {
        case .shared: return try VmnetNetwork(subnet: subnet)
        case .hostOnly: return try HostOnlyNetwork(subnet: subnet)
        case .brokered: throw SandboxError("a brokered sandbox has no network")
        }
      },
      commit: { next in
        var updated = current
        updated.subnetIndex = next
        try paths.save(updated)
        current = updated
      },
      refused: { failed, next, error in
        log(
          "subnet \(SandboxRecord.subnet(failed)) unavailable (\(error)); moved to \(SandboxRecord.subnet(next))"
        )
      })
  }

  /// The VM around a container with these cgroup limits: one more vCPU and
  /// ``VMResources/guestMemoryOverhead`` for the guest kernel and vminitd.
  /// Containerization sizes the VM only from this, never from the limits.
  static func machineResources(cpus: Int, memoryBytes: UInt64) -> VMResources {
    VMResources(cpus: cpus + 1, memoryInBytes: memoryBytes + VMResources.guestMemoryOverhead)
  }

  /// `interface` is nil exactly for a brokered sandbox.
  static func machineConfiguration(
    record: SandboxRecord, interface: (any Interface)?, bootLog: BootLog
  ) -> LinuxContainer.Configuration {
    var config = LinuxContainer.Configuration()
    var process = LinuxProcessConfiguration()
    process.arguments = ["/sbin/init"]
    process.environmentVariables = record.environment
    process.workingDirectory = "/"
    process.user = .init()
    process.capabilities = .allCapabilities
    process.terminal = false
    config.process = process
    config.cpus = record.cpus
    config.memoryInBytes = record.memoryBytes
    config.hostname = record.id.rawValue
    config.interfaces = interface.map { [$0] } ?? []
    // Host-only and brokered sandboxes get no resolver: the vmnet DNS
    // proxy is off, or there is no network.
    if record.network == .shared, let gateway = interface?.ipv4Gateway {
      config.dns = DNS(nameservers: [gateway.description])
    }
    var hosts = Hosts.default
    hosts.entries.append(
      .init(
        ipAddress: interface?.ipv4Address.address.description ?? "127.0.1.1",
        hostnames: [record.id.rawValue]))
    config.hosts = hosts
    // Kernel pseudo-filesystems only; no host shares, no socket relays.
    config.mounts = LinuxContainer.defaultMounts()
    config.sockets = []
    // systemd and dockerd need to write cgroup/sysctl state.
    config.maskedPaths = []
    config.readonlyPaths = []
    config.virtualization = false
    config.bootLog = bootLog
    return config
  }

  /// `devices` is the live inventory, already checked against
  /// `VMDevices.requireExpected`; only a brokered report carries its counts.
  static func effectiveConfig(
    record: SandboxRecord, config: LinuxContainer.Configuration, rootfs: Containerization.Mount,
    devices: VMDevices
  ) -> EffectiveConfig {
    func view(_ m: Containerization.Mount) -> EffectiveConfig.MountView {
      .init(type: m.type, source: m.source, destination: m.destination, options: m.options)
    }
    var effective = EffectiveConfig(
      id: record.id.rawValue,
      imageReference: record.imageReference,
      imageDigest: record.imageDigest,
      cpus: config.cpus,
      memoryBytes: config.memoryInBytes,
      rootfs: view(rootfs),
      mounts: config.mounts.map(view),
      interfaces: config.interfaces.map {
        .init(
          ipv4: $0.ipv4Address.description, ipv4Gateway: $0.ipv4Gateway?.description,
          ipv6: $0.ipv6Address?.description,
          network:
            "\(record.network == .shared ? "vmnet-shared" : "vmnet-host"):\(record.subnet ?? "none")"
        )
      },
      socketRelays: config.sockets.count,
      publishedPorts: 0,
      sshAgentForwarding: false,
      maskedPaths: config.maskedPaths,
      readonlyPaths: config.readonlyPaths,
      initArgv: config.process.arguments,
      virtualization: config.virtualization
    )
    if record.displayMode != .headless {
      effective.display = record.displayMode.rawValue
      effective.graphicsDevices = devices.graphics.map { device in
        switch device {
        case .virtio(let scanouts): scanouts.map { "\($0.width)x\($0.height)" }
        case .other(let name): [name]
        }
      }
      effective.vsockPorts = []
      effective.liveViewListening = false
    }
    if record.network == .brokered {
      let policy = ChannelPolicy.current
      effective.transport = NetworkMode.brokered.rawValue
      effective.networkDevices = devices.network.count
      effective.socketDevices = devices.socket
      effective.channelPolicy = policy
      effective.channelPolicyDigest = policy.digest
      effective.networkPolicy = record.networkPolicy
    }
    return effective
  }

  static func exec(
    _ container: LinuxContainer, _ argv: [String], stdin: Data?, timeout: ExecTimeout
  )
    async throws -> ControlResponse
  {
    let out = BufferWriter()
    let err = BufferWriter()
    let input = stdin.map(DataReader.init)
    let process = try await container.exec("x" + UUID().uuidString.prefix(12).lowercased()) { c in
      c.arguments = argv
      c.environmentVariables = ["PATH=\(LinuxProcessConfiguration.defaultPath)", "HOME=/root"]
      c.workingDirectory = "/"
      c.user = .init()
      c.capabilities = .allCapabilities
      c.stdout = out
      c.stderr = err
      c.stdin = input
    }
    let status = try await runGuestProcess(process, timeout: timeout)
    return ControlResponse(ok: true, exitCode: status.exitCode, stdout: out.data, stderr: err.data)
  }

  static func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

/// What `Lifecycle` needs of the machine: a signal to its init, delivered
/// over the guest agent.
protocol HaltableContainer: Sendable {
  func kill(_ signal: Signal) async throws
}

extension LinuxContainer: HaltableContainer {}

actor Lifecycle {
  private let container: any HaltableContainer
  /// Closed when a halt begins: no stream outlives a stop request.
  private let streams: StreamBroker?
  /// Run when a halt begins, for what else must not outlive it (the
  /// display's live view). Not awaited: it must not delay the halt.
  private let onHalt: @Sendable () async -> Void
  private var halting = false
  private var stopped = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let forceExit: @Sendable () -> Void
  private let haltGrace: Duration
  private let killGrace: Duration

  init(
    container: any HaltableContainer,
    streams: StreamBroker? = nil,
    onHalt: @escaping @Sendable () async -> Void = {},
    haltGrace: Duration = .seconds(Owner.haltGraceSeconds),
    killGrace: Duration = .seconds(Owner.killGraceSeconds),
    forceExit: @escaping @Sendable () -> Void
  ) {
    self.container = container
    self.streams = streams
    self.onHalt = onHalt
    self.haltGrace = haltGrace
    self.killGrace = killGrace
    self.forceExit = forceExit
  }

  /// Ask systemd to shut down cleanly; force the VM down if it has not halted
  /// within the grace period, and end the owner (and so the VM) if the guest
  /// agent cannot deliver even that.
  /// The guest-agent calls run in their own tasks so a wedged agent cannot stall the timers; `kill`
  /// holds the container's state lock across its RPC, so a wedged halt also stalls the forced kill,
  /// and ending the owner is the only step the guest cannot block.
  func requestHalt() {
    guard !halting else { return }
    halting = true
    Owner.log("halt requested")
    streams?.shutdownAll()
    let onHalt = self.onHalt
    Task { await onHalt() }
    let container = self.container
    let forceExit = self.forceExit
    Task {
      Task { try? await container.kill(Owner.systemdHalt) }
      try? await Task.sleep(for: self.haltGrace)
      guard !self.isStopped else { return }
      Task { try? await container.kill(.kill) }
      try? await Task.sleep(for: self.killGrace)
      if !self.isStopped { forceExit() }
    }
  }

  var isStopped: Bool { stopped }

  func markStopped() {
    stopped = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }

  func waitStopped() async {
    if stopped { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

/// Collects guest output up to `limit` bytes; the rest is dropped, so a
/// guest cannot exhaust the owner's memory.
final class BufferWriter: Writer, Sendable {
  static let limit = 8 * 1024 * 1024
  private let buffer = Mutex(Data())
  func write(_ data: Data) throws {
    buffer.withLock { $0.append(data.prefix(max(0, Self.limit - $0.count))) }
  }
  func close() throws {}
  var data: Data { buffer.withLock { $0 } }
}

struct DataReader: ReaderStream {
  let data: Data
  func stream() -> AsyncStream<Data> {
    AsyncStream { continuation in
      if !data.isEmpty { continuation.yield(data) }
      continuation.finish()
    }
  }
}

/// The host copy of the serial console. Guest root writes the console
/// freely, so the file is capped: past `limit` bytes it restarts with a
/// marker line. It is appended to across boots up to the same cap.
final class ConsoleLog: Sendable {
  static let limit = 8 * 1024 * 1024
  private let pipe = Pipe()
  var writer: FileHandle { pipe.fileHandleForWriting }

  init(url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let out = try FileHandle(forWritingTo: url)
    var start = try out.seekToEnd()
    if start > Self.limit {
      try out.truncate(atOffset: 0)
      start = 0
    }
    let reader = pipe.fileHandleForReading
    let written = Int(start)
    Thread.detachNewThread {
      ConsoleLog.copy(from: reader, to: out, written: written)
    }
  }

  /// Drains `reader` into `out` until EOF.
  /// Throwing I/O only (legacy FileHandle calls raise uncatchable exceptions; a full host disk
  /// would kill the owner and its VM); after a write error it keeps draining and discards, so the
  /// guest console never blocks.
  static func copy(from reader: FileHandle, to out: FileHandle, written: Int, limit: Int = limit) {
    var written = written
    var writable = true
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let n = read(reader.fileDescriptor, &buffer, buffer.count)
      if n < 0, errno == EINTR { continue }
      if n <= 0 { return }
      guard writable else { continue }
      var data = Data(buffer[0..<n])
      do {
        if written + data.count > limit {
          try out.truncate(atOffset: 0)
          let marker = Data("[iso-sandbox: console log passed \(limit) bytes; restarted]\n".utf8)
          try out.write(contentsOf: marker)
          written = marker.count
          data = data.suffix(max(0, limit - written))
        }
        try out.write(contentsOf: data)
        written += data.count
      } catch {
        writable = false
      }
    }
  }
}

/// vmnet host mode with no route beyond the host: NAT44, NAT66, the DNS proxy,
/// router advertisements and DHCP are all disabled on the configuration the
/// network is created from.
/// The host is the `.1` peer, so host-initiated SSH (and its tunnels) still reach the guest.
struct HostOnlyNetwork: Network {
  nonisolated(unsafe) let reference: vmnet_network_ref
  let subnet: CIDRv4

  init(subnet: CIDRv4) throws {
    var status: vmnet_return_t = .VMNET_FAILURE
    guard let config = vmnet_network_configuration_create(.VMNET_HOST_MODE, &status) else {
      throw SandboxError("vmnet host-mode configuration failed: \(status)")
    }
    vmnet_network_configuration_disable_dhcp(config)
    vmnet_network_configuration_disable_nat44(config)
    vmnet_network_configuration_disable_nat66(config)
    vmnet_network_configuration_disable_dns_proxy(config)
    vmnet_network_configuration_disable_router_advertisement(config)
    var gateway = in_addr()
    var mask = in_addr()
    guard inet_pton(AF_INET, subnet.gateway.description, &gateway) == 1,
      inet_pton(AF_INET, IPv4Address(subnet.prefix.prefixMask32).description, &mask) == 1,
      vmnet_network_configuration_set_ipv4_subnet(config, &gateway, &mask) == .VMNET_SUCCESS
    else { throw SandboxError("vmnet host-mode subnet \(subnet) rejected") }
    guard let network = vmnet_network_create(config, &status), status == .VMNET_SUCCESS else {
      throw SandboxError("vmnet host-mode network creation failed: \(status)")
    }
    reference = network
    self.subnet = subnet
  }

  mutating func createInterface(_ id: String) throws -> (any Interface)? {
    VmnetNetwork.Interface(
      reference: reference,
      ipv4Address: try CIDRv4(IPv4Address(subnet.lower.value + 2), prefix: subnet.prefix),
      ipv4Gateway: subnet.gateway)
  }

  mutating func releaseInterface(_ id: String) throws {}
}
