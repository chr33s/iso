import Containerization
import Darwin
import Foundation
import Synchronization
import Virtualization

/// The brokered transport (docs/design/brokered-network-isolation.md): a
/// sandbox with no network device whose host reaches it only through
/// streams its owner opens to fixed guest vsock ports. The guest decides
/// nothing here: a stream request names a purpose, never a port, and is
/// admitted against the current boot, the host's policy digests and the
/// owner's limits before any guest connection is made.
package struct ChannelPolicy: Codable, Sendable, Equatable {
  package struct Endpoint: Codable, Sendable, Equatable {
    package var purpose: String
    package var guestPort: UInt32
    package var direction: String
  }

  package var schema: String
  package var endpoints: [Endpoint]
  /// Streams open at once; the control socket is separate, so a full
  /// table never blocks stop or cleanup.
  package var maxStreams: Int
  /// Admissions per `windowSeconds`.
  package var maxOpensPerWindow: Int
  package var windowSeconds: Int
  /// Longest stream request line.
  package var requestBytes: Int
  /// A request line and a guest dial are each abandoned after this long.
  package var setupTimeoutSeconds: Int
  /// Bytes read per direction before they are written on; the only buffer.
  package var chunkBytes: Int

  /// The policy this runtime enforces. Fixed in the binary: nothing at run
  /// time widens it. Port 2222 is the guest image's `iso-ssh-vsock.socket`.
  package static let current = ChannelPolicy(
    schema: "iso.channels/v1",
    endpoints: [.init(purpose: "ssh", guestPort: 2222, direction: "host-to-guest")],
    maxStreams: 64, maxOpensPerWindow: 64, windowSeconds: 10, requestBytes: 4096,
    setupTimeoutSeconds: 10, chunkBytes: 64 << 10)

  /// sha256 of the sorted-key JSON encoding, which the host recomputes
  /// from its own copy of the expected policy.
  package var digest: String { sha256Hex((try? JSONEncoder.wire.encode(self)) ?? Data()) }

  func endpoint(_ purpose: String) -> Endpoint? { endpoints.first { $0.purpose == purpose } }
}

/// One line a connector sends before any stream bytes.
package struct StreamRequest: Codable, Sendable, Equatable {
  package var purpose: String
  package var bootId: String
  package var channelPolicy: String
  /// Must equal the boot's `--network-policy` (both absent, or equal).
  package var networkPolicy: String?
  /// An access-session label, for closing one session's streams.
  package var session: String?

  package init(
    purpose: String, bootId: String, channelPolicy: String, networkPolicy: String?,
    session: String?
  ) {
    self.purpose = purpose
    self.bootId = bootId
    self.channelPolicy = channelPolicy
    self.networkPolicy = networkPolicy
    self.session = session
  }
}

package struct StreamReply: Codable, Sendable, Equatable {
  package var ok: Bool
  package var error: String?
}

package struct StreamSummary: Codable, Sendable, Equatable {
  package var purpose: String
  package var session: String?
  package var openedAt: Date
}

/// Session labels: short, and safe to log.
package func validStreamLabel(_ label: String) -> Bool {
  let allowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
  return !label.isEmpty && label.utf8.count <= 64
    && label.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// The owner's stream table and server for a brokered sandbox.
package final class StreamBroker: Sendable {
  package enum Refusal: Error, Equatable, CustomStringConvertible {
    case malformed
    case stopping
    case bootChanged
    case channelPolicyChanged
    case networkPolicyChanged
    case unknownPurpose
    case badSession
    case tooManyStreams
    case rateLimited
    case guestUnavailable(String)

    package var description: String {
      switch self {
      case .malformed: "malformed stream request"
      case .stopping: "the sandbox is stopping"
      case .bootChanged: "the sandbox is running a different boot"
      case .channelPolicyChanged: "the runtime's channel policy differs from the one requested"
      case .networkPolicyChanged: "the boot's network policy differs from the one requested"
      case .unknownPurpose: "no guest endpoint serves that purpose"
      case .badSession: "invalid session label"
      case .tooManyStreams: "too many open streams"
      case .rateLimited: "too many new streams within the setup timeout; retry shortly"
      case .guestUnavailable(let purpose):
        "the guest \(purpose) endpoint did not accept a connection"
      }
    }
  }

  struct Open: Sendable {
    let client: Int32
    let guest: Int32
    let summary: StreamSummary
  }

  struct State: Sendable {
    var streams: [UInt64: Open] = [:]
    /// Admitted requests still dialing the guest; they count against
    /// `maxStreams`.
    var dialing = 0
    var next: UInt64 = 0
    var admissions: [ContinuousClock.Instant] = []
    var closed = false
    /// Connections being handled, admitted or not; each holds a thread.
    var handlers = 0
    /// Sessions closed by `close(session:)`: their later or still-dialing
    /// streams are refused too.
    var closedSessions: Set<String> = []
  }

  package let bootID: String
  package let networkPolicy: String?
  package let policy: ChannelPolicy
  private let dial: @Sendable (UInt32) async throws -> FileHandle
  private let state = Mutex(State())

  package init(
    bootID: String, networkPolicy: String?, policy: ChannelPolicy = .current,
    dial: @escaping @Sendable (UInt32) async throws -> FileHandle
  ) {
    self.bootID = bootID
    self.networkPolicy = networkPolicy
    self.policy = policy
    self.dial = dial
  }

  /// Checks `request` and, on success, reserves a slot: the caller must
  /// `register` or `release` it.
  package func admit(_ request: StreamRequest, now: ContinuousClock.Instant = .now)
    -> Result<ChannelPolicy.Endpoint, Refusal>
  {
    guard request.bootId == bootID else { return .failure(.bootChanged) }
    guard request.channelPolicy == policy.digest else { return .failure(.channelPolicyChanged) }
    guard request.networkPolicy == networkPolicy else { return .failure(.networkPolicyChanged) }
    if let session = request.session, !validStreamLabel(session) {
      return .failure(.badSession)
    }
    guard let endpoint = policy.endpoint(request.purpose) else {
      return .failure(.unknownPurpose)
    }
    let window = Duration.seconds(policy.windowSeconds)
    return state.withLock { state in
      guard !state.closed else { return .failure(.stopping) }
      if let session = request.session, state.closedSessions.contains(session) {
        return .failure(.stopping)
      }
      guard state.streams.count + state.dialing < policy.maxStreams else {
        return .failure(.tooManyStreams)
      }
      state.admissions.removeAll { now - $0 >= window }
      guard state.admissions.count < policy.maxOpensPerWindow else {
        return .failure(.rateLimited)
      }
      state.admissions.append(now)
      state.dialing += 1
      return .success(endpoint)
    }
  }

  package func release() {
    state.withLock { $0.dialing -= 1 }
  }

  /// Turns a reservation into an open stream; nil (reservation released)
  /// once the broker has closed.
  package func register(client: Int32, guest: Int32, purpose: String, session: String?)
    -> UInt64?
  {
    state.withLock { state in
      state.dialing -= 1
      guard !state.closed, !(session.map(state.closedSessions.contains) ?? false) else {
        return nil
      }
      state.next += 1
      state.streams[state.next] = Open(
        client: client, guest: guest,
        summary: StreamSummary(purpose: purpose, session: session, openedAt: Date()))
      return state.next
    }
  }

  package func unregister(_ id: UInt64) {
    state.withLock { _ = $0.streams.removeValue(forKey: id) }
  }

  package var open: [StreamSummary] {
    state.withLock { $0.streams.values.map(\.summary).sorted { $0.openedAt < $1.openedAt } }
  }

  /// Shuts down the matching streams (every stream when `session` is nil)
  /// and returns what was open. Descriptors close only after their stream
  /// unregisters, under this same lock, so a number here is never reused.
  @discardableResult
  package func close(session: String?) -> [StreamSummary] {
    state.withLock { state in
      if let session { state.closedSessions.insert(session) }
      let matching = state.streams.values.filter { session == nil || $0.summary.session == session }
      for stream in matching {
        shutdown(stream.client, SHUT_RDWR)
        shutdown(stream.guest, SHUT_RDWR)
      }
      return matching.map(\.summary).sorted { $0.openedAt < $1.openedAt }
    }
  }

  /// Refuses every new stream and closes the open ones (halt, owner exit).
  package func shutdownAll() {
    state.withLock { $0.closed = true }
    close(session: nil)
  }

  /// Connections handled at once, including ones still sending their
  /// request: a client that connects and stalls holds a thread until the
  /// setup timeout, so this bounds threads before admission applies.
  package var maxHandlers: Int { policy.maxStreams * 2 }

  /// Claims a handler slot; false (connection to be closed unread) when full.
  package func enterHandler() -> Bool {
    state.withLock { state in
      guard state.handlers < maxHandlers else { return false }
      state.handlers += 1
      return true
    }
  }

  package func leaveHandler() {
    state.withLock { $0.handlers -= 1 }
  }

  package func serve(at path: URL) throws {
    let fd = try ControlSocket.listen(at: path)
    ControlSocket.acceptLoop(fd) { conn in
      guard self.enterHandler() else {
        Darwin.close(conn)
        return
      }
      Thread.detachNewThread {
        defer { self.leaveHandler() }
        self.handle(conn)
      }
    }
  }

  /// One connection: request line, admission, guest dial, reply, then raw
  /// bytes both ways until each side ends. Closes `conn`.
  func handle(_ conn: Int32) {
    defer { Darwin.close(conn) }
    ControlSocket.setReceiveTimeout(conn, TimeInterval(policy.setupTimeoutSeconds))
    // The receive timeout bounds each read; the deadline bounds the line, so
    // a client trickling bytes cannot hold a handler slot.
    let deadline = ContinuousClock.now + .seconds(policy.setupTimeoutSeconds)
    guard let line = Splice.readLine(conn, limit: policy.requestBytes, deadline: deadline),
      let request = try? JSONDecoder().decode(StreamRequest.self, from: Data(line))
    else {
      _ = reply(conn, .malformed)
      return
    }
    guard let endpoint = admitWaiting(request, until: deadline, conn: conn) else { return }
    let guest: Int32
    do {
      guest = try dialGuest(endpoint.guestPort)
    } catch {
      release()
      Owner.log("stream \(endpoint.purpose): guest dial failed: \(error)")
      _ = reply(conn, .guestUnavailable(endpoint.purpose))
      return
    }
    defer { Darwin.close(guest) }
    var one: Int32 = 1
    setsockopt(guest, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    guard
      let id = register(
        client: conn, guest: guest, purpose: endpoint.purpose, session: request.session)
    else {
      _ = reply(conn, .stopping)
      return
    }
    defer { unregister(id) }
    guard reply(conn, nil) else { return }
    ControlSocket.setReceiveTimeout(conn, 0)
    Splice.bidirectional(conn, guest, chunk: policy.chunkBytes)
  }

  /// `admit`, waiting out a full admission window until `deadline` instead
  /// of refusing a burst of legitimate connections (each ssh command is one
  /// stream). Any other refusal, or the deadline, is replied to and is nil.
  func admitWaiting(_ request: StreamRequest, until deadline: ContinuousClock.Instant, conn: Int32)
    -> ChannelPolicy.Endpoint?
  {
    while true {
      switch admit(request) {
      case .success(let endpoint): return endpoint
      case .failure(.rateLimited) where ContinuousClock.now < deadline:
        Thread.sleep(forTimeInterval: 0.05)
      case .failure(let refusal):
        _ = reply(conn, refusal)
        return nil
      }
    }
  }

  /// A connected guest stream descriptor, owned by the caller.
  func dialGuest(_ port: UInt32) throws -> Int32 {
    let result = Mutex<Result<FileHandle, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    let dial = self.dial
    Task {
      let outcome: Result<FileHandle, any Error>
      do { outcome = .success(try await dial(port)) } catch { outcome = .failure(error) }
      // A dial that finishes after the timeout is closed here, unused.
      let late = result.withLock { slot -> Bool in
        if slot == nil {
          slot = outcome
          return false
        }
        return true
      }
      if late, case .success(let handle) = outcome { Darwin.close(handle.fileDescriptor) }
      done.signal()
    }
    let timedOut =
      done.wait(timeout: .now() + .seconds(policy.setupTimeoutSeconds)) == .timedOut
    let outcome = result.withLock { slot -> Result<FileHandle, any Error>? in
      if timedOut, slot == nil {
        slot = .failure(SandboxError("timed out"))
        return nil
      }
      return slot
    }
    guard let outcome else { throw SandboxError("guest dial timed out") }
    return try outcome.get().fileDescriptor
  }

  /// False when the reply could not be written; a refusal is final.
  func reply(_ conn: Int32, _ refusal: Refusal?) -> Bool {
    var line =
      (try? JSONEncoder.wire.encode(
        StreamReply(ok: refusal == nil, error: refusal?.description))) ?? Data()
    line.append(0x0A)
    return Splice.writeAll(conn, Array(line))
  }
}

/// `iso-sandbox connect`: ssh's ProxyCommand for a brokered sandbox. Carries
/// stdin and stdout through one admitted stream; diagnostics go to stderr
/// only, never onto the SSH byte stream.
package enum StreamConnector {
  package static func run(paths: SandboxPaths, request: StreamRequest) -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    func fail(_ message: String) -> Int32 {
      FileHandle.standardError.write(Data("iso-sandbox connect: \(message)\n".utf8))
      return 1
    }
    let fd: Int32
    do {
      fd = try ControlSocket.connectClient(
        paths.streams, timeout: TimeInterval(ChannelPolicy.current.setupTimeoutSeconds * 3))
    } catch {
      return fail("\(paths.id) has no stream channel (\(error))")
    }
    defer { close(fd) }
    guard var line = try? JSONEncoder.wire.encode(request) else { return fail("encode failed") }
    line.append(0x0A)
    guard Splice.writeAll(fd, Array(line)) else { return fail("the owner closed the channel") }
    guard let replyLine = Splice.readLine(fd, limit: ChannelPolicy.current.requestBytes),
      let reply = try? JSONDecoder().decode(StreamReply.self, from: Data(replyLine))
    else { return fail("the owner did not admit the stream") }
    guard reply.ok else { return fail(reply.error ?? "stream refused") }
    ControlSocket.setReceiveTimeout(fd, 0)
    let chunk = ChannelPolicy.current.chunkBytes
    Thread.detachNewThread {
      Splice.copy(from: STDIN_FILENO, to: fd, chunk: chunk)
      shutdown(fd, SHUT_WR)
    }
    // The guest side ending ends the connector, whatever stdin is doing.
    Splice.copy(from: fd, to: STDOUT_FILENO, chunk: chunk)
    return 0
  }
}

/// Blocking byte relays between descriptors, with one bounded buffer per
/// direction.
package enum Splice {
  /// Copies until either side ends or fails; returns the bytes copied.
  @discardableResult
  package static func copy(from source: Int32, to destination: Int32, chunk: Int) -> UInt64 {
    var buffer = [UInt8](repeating: 0, count: chunk)
    var total: UInt64 = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return total }
      guard writeAll(destination, buffer[0..<count]) else { return total }
      total += UInt64(count)
    }
  }

  package static func writeAll(_ fd: Int32, _ bytes: some Collection<UInt8>) -> Bool {
    let bytes = Array(bytes)
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { raw in
        write(fd, raw.baseAddress.map { $0 + offset }, raw.count - offset)
      }
      if written < 0 && errno == EINTR { continue }
      guard written > 0 else { return false }
      offset += written
    }
    return true
  }

  /// Both directions; each forwards EOF as a write shutdown, so a half-close
  /// on either side reaches the other while the opposite direction still
  /// flows. Returns when both have ended.
  package static func bidirectional(_ a: Int32, _ b: Int32, chunk: Int) {
    let done = DispatchGroup()
    for (from, to) in [(a, b), (b, a)] {
      done.enter()
      Thread.detachNewThread {
        copy(from: from, to: to, chunk: chunk)
        shutdown(to, SHUT_WR)
        done.leave()
      }
    }
    done.wait()
  }

  /// One `\n`-terminated line, read a byte at a time so nothing after it
  /// is consumed. Nil on EOF, timeout, error, more than `limit` bytes, or
  /// once `deadline` passes.
  package static func readLine(
    _ fd: Int32, limit: Int, deadline: ContinuousClock.Instant? = nil
  ) -> [UInt8]? {
    var line: [UInt8] = []
    var byte: UInt8 = 0
    while true {
      if let deadline, ContinuousClock.now >= deadline { return nil }
      let count = read(fd, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count == 1 else { return nil }
      if byte == UInt8(ascii: "\n") { return line }
      guard line.count < limit else { return nil }
      line.append(byte)
    }
  }
}

/// Devices on the live `VZVirtualMachine`, not the configuration iso asked
/// for: the brokered contract's network-device count is this reading.
package struct VMDevices: Sendable, Equatable {
  package var network: Int
  package var socket: Int

  static func read(_ container: LinuxContainer) async throws -> VMDevices {
    try await container.withVirtualMachineInstance { instance in
      guard let vz = instance as? VZVirtualMachineInstance else {
        throw SandboxError("the VM is not a Virtualization.framework machine")
      }
      return vz.vmQueue.sync {
        VMDevices(
          network: vz.vzVirtualMachine.networkDevices.count,
          socket: vz.vzVirtualMachine.socketDevices.count)
      }
    }
  }
}
