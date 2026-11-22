import Containerization
import Darwin
import Foundation
import Synchronization

/// The one socket relay a Linux sandbox can have (docs/design/secure-local-inference-spec.md
/// §22): the iso inference gateway's per-sandbox Unix socket, relayed into the guest at a fixed
/// path. The record can only switch it on; the host path is derived from the sandbox directory,
/// and the guest path, port and limits are constants.
///
/// The owner runs both halves on containerization's public API, so its limits hold without a
/// patched framework: it listens on ``vsockPort`` on the host side of the VM's socket device
/// (``InferenceRelayServer``), and asks the guest agent (vminitd) for a Unix socket that dials
/// that port once per guest connection, which the container sees at ``guestPath``.
package enum InferenceRelay {
  /// Outside `/run`, which systemd replaces with a tmpfs after the relay is mounted.
  package static let guestPath = "/var/lib/iso-inference/gateway.sock"
  /// Where vminitd creates the guest end: in the VM's own namespace, outside the container's root
  /// filesystem, as containerization stages its own relays under `/run/sockets`, so no path the
  /// guest controls is followed. `start` bind-mounts it at ``guestPath``.
  static let stagingPath = "/run/iso-inference/gateway.sock"
  /// The host vsock port relayed connections arrive on.
  package static let vsockPort: UInt32 = 7803
  /// Connections relayed at once. One arriving at the limit is closed before the gateway is
  /// dialed, so a guest cannot exhaust the owner's descriptors.
  package static let maxConnections = 32
  /// Bytes read per direction before they are written on; the only buffer.
  static let chunkBytes = 64 << 10
  /// `iso-sbx/inference` in the per-user temporary directory, beside the owners' control sockets.
  /// The gateway binds each sandbox's socket here (``SandboxPaths/inferenceSocket``).
  package static let hostDirectory = SandboxPaths.controlDirectory.appendingPathComponent(
    "inference", isDirectory: true)

  /// One sandbox's relay as its owner configures it.
  package struct Endpoint: Sendable, Equatable {
    /// The gateway's socket for this sandbox.
    package let host: URL

    package init(host: URL) { self.host = host }

    /// The relay `record` asks for, at `paths`' derived socket; nil when it asks for none.
    package static func of(_ record: SandboxRecord, at paths: SandboxPaths) -> Endpoint? {
      record.relaysInference ? Endpoint(host: paths.inferenceSocket) : nil
    }

    /// The guest end as the container sees it: vminitd's socket, bind-mounted at the guest path
    /// (the mount containerization itself adds for a relay into a container).
    var guestMount: Containerization.Mount {
      .any(type: "bind", source: stagingPath, destination: guestPath, options: ["bind"])
    }

    func isGuestMount(_ mount: Containerization.Mount) -> Bool {
      let wanted = guestMount
      return mount.type == wanted.type && mount.source == wanted.source
        && mount.destination == wanted.destination && mount.options == wanted.options
    }

    var view: EffectiveConfig.RelayView {
      .init(host: host.path, guest: guestPath, maxConnections: maxConnections)
    }

    /// Creates the host directory, or verifies an existing one, as the control socket's: a real
    /// directory owned by this user and closed to everyone else.
    package func prepare() throws {
      try ControlSocket.prepareDirectory(for: host)
    }
  }

  /// A connected descriptor to the gateway's socket at `path`, owned by the caller, after
  /// checking its directory as the control socket's.
  static func dialGateway(_ path: URL) throws -> Int32 {
    try ControlSocket.connectClient(path, timeout: nil)
  }

  /// Copies both ways between a guest connection and its gateway connection, each through one
  /// ``chunkBytes`` buffer with back-pressure; each side's EOF is passed on as a write shutdown.
  /// Returns once both directions have ended; the caller closes the descriptors.
  static func relay(guest: Int32, gateway: Int32) {
    var one: Int32 = 1
    for fd in [guest, gateway] {
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    Splice.bidirectional(guest, gateway, chunk: chunkBytes)
  }
}

/// The owner's half of one sandbox's inference relay: the host listener's connections, each
/// relayed to the gateway on its own thread, at most ``InferenceRelay/maxConnections`` at once.
package final class InferenceRelayServer: Sendable {
  struct State: Sendable {
    /// Each admitted connection's descriptors, closed only once it is removed from here, under
    /// this lock, so `shutdownAll` never reaches a reused number. Its count is the slots in use.
    var open: [UInt64: [Int32]] = [:]
    var next: UInt64 = 0
    var closed = false
    var rejections = RejectionBudget()
  }

  package let endpoint: InferenceRelay.Endpoint
  /// The boot's deadline: no connection is relayed at or after it, whatever the owner's halt
  /// timing.
  package let expiresAt: Date?
  private let log: @Sendable (String) -> Void
  private let state = Mutex(State())

  package init(
    endpoint: InferenceRelay.Endpoint, expiresAt: Date?,
    log: @escaping @Sendable (String) -> Void
  ) {
    self.endpoint = endpoint
    self.expiresAt = expiresAt
    self.log = log
  }

  /// Connections being relayed or dialing the gateway.
  package var active: Int { state.withLock { $0.open.count } }

  /// Starts both halves on a created VM, before its init runs: the host listener first, then the
  /// guest agent's socket at the staging path, which the container's `start` bind-mounts at
  /// ``InferenceRelay/guestPath``.
  func attach(_ container: LinuxContainer) async throws {
    let listener = try await container.withVirtualMachineInstance {
      try $0.listen(InferenceRelay.vsockPort)
    }
    // Listens for the VM's life: after `shutdownAll` each connection is closed on arrival, and
    // the listener is never removed from a stopping machine.
    Task.detached {
      // The descriptor is this relay's from here (the listener dup'd it and keeps no copy).
      for await handle in listener { self.accept(handle.fileDescriptor) }
    }
    let host = endpoint.host
    try await container.withVirtualMachineInstance { vm in
      let agent = try await vm.dialAgent()
      do {
        guard let relayAgent = agent as? any SocketRelayAgent else {
          throw SandboxError("the guest agent cannot relay sockets")
        }
        try await relayAgent.relaySocket(
          port: InferenceRelay.vsockPort,
          configuration: UnixSocketConfiguration(
            source: host, destination: URL(fileURLWithPath: InferenceRelay.stagingPath),
            direction: .into))
      } catch {
        try? await agent.close()
        throw error
      }
      try await agent.close()
    }
  }

  /// Takes ownership of `guest`, one connection from the guest, and relays it on its own thread;
  /// false, with `guest` closed at once and the gateway not dialed, when every slot is taken, the
  /// relay has shut down, or the boot's deadline has passed.
  @discardableResult
  package func accept(_ guest: Int32) -> Bool {
    let expired = expiresAt.map { Date() >= $0 } ?? false
    let admitted: Result<UInt64, SandboxError> = state.withLock { state in
      if state.closed { return .failure(SandboxError("the relay has shut down")) }
      if expired { return .failure(SandboxError("the boot's session has expired")) }
      guard state.open.count < InferenceRelay.maxConnections else {
        return .failure(
          SandboxError("\(InferenceRelay.maxConnections) connections are already relayed"))
      }
      state.next += 1
      state.open[state.next] = [guest]
      return .success(state.next)
    }
    guard case .success(let id) = admitted else {
      close(guest)
      if case .failure(let why) = admitted { reject(why.description) }
      return false
    }
    Thread.detachNewThread { self.serve(id, guest) }
    return true
  }

  private func serve(_ id: UInt64, _ guest: Int32) {
    defer { finish(id) }
    let gateway: Int32
    do {
      gateway = try InferenceRelay.dialGateway(endpoint.host)
    } catch {
      reject("\(error)")
      return
    }
    let registered = state.withLock { state -> Bool in
      guard !state.closed else { return false }
      state.open[id]?.append(gateway)
      return true
    }
    guard registered else {
      close(gateway)
      return
    }
    InferenceRelay.relay(guest: guest, gateway: gateway)
  }

  private func finish(_ id: UInt64) {
    state.withLock { state in
      for fd in state.open.removeValue(forKey: id) ?? [] { close(fd) }
    }
  }

  /// Refuses every new connection and closes the open ones (halt, session deadline, owner exit).
  package func shutdownAll() {
    state.withLock { state in
      state.closed = true
      for fd in state.open.values.joined() { shutdown(fd, SHUT_RDWR) }
    }
  }

  private func reject(_ why: String) {
    let (emit, suppressed) = state.withLock { $0.rejections.admit() }
    if suppressed > 0 { log("inference relay refusals: \(suppressed) more not logged") }
    if emit { log("inference relay refused a guest connection: \(why)") }
  }
}
