import Darwin
import Foundation
import IsoMacProtocol
import Virtualization

/// What the helper link needs from the sandbox's records.
package protocol MacEnrollmentStore: Sendable {
  var isEnrolled: Bool { get }
  var helperKey: HelperKey? { get }
  var authorizedKey: String { get }
  var network: HelperNetwork { get }
  /// Persist a completed enrollment: the helper key and the SSH host key pin.
  func saveEnrollment(key: HelperKey, sshHostKey: String) throws
  func markMismatch(_ reason: String)
}

/// The host side of the helper channel (Gate I), on vsock port 7801.
/// The host speaks first on each connection; a connection becomes the
/// active one only after it authenticates (or enrolls a fresh clone). An
/// unauthenticated connection never replaces the active one.
package final class MacHelperLink: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
  private let store: any MacEnrollmentStore
  private let log: @Sendable (String) -> Void
  private let lock = NSLock()
  private var pending = 0
  private var nextID = 0
  private var activeID = 0
  private var writeFD: Int32 = -1
  /// The active connection's reader, shut down when it is replaced.
  private var readFD: Int32 = -1
  private var connection: AnyObject?
  private var _guestBoot: String?
  private var _guestBuild: String?
  private var _generation = 0
  /// One request at a time on the active connection; its reply lands here.
  private let requestLock = NSLock()
  private var replySlot: HelperMessage?
  /// The id of the request awaiting a reply.
  private var outstanding = 0
  private var lastRequest = 0
  private let replySignal = DispatchSemaphore(value: 0)

  package init(store: any MacEnrollmentStore, log: @escaping @Sendable (String) -> Void) {
    self.store = store
    self.log = log
  }

  package var guestBoot: String? { lock.withLock { _guestBoot } }
  package var guestBuild: String? { lock.withLock { _guestBuild } }
  /// Bumps on every accepted hello and every loss of the active connection.
  package var generation: Int { lock.withLock { _generation } }
  package var isConnected: Bool { lock.withLock { activeID != 0 } }

  // MARK: requests on the active connection

  private func request(_ m: HelperMessage, timeout: TimeInterval) -> HelperMessage? {
    requestLock.lock()
    defer { requestLock.unlock() }
    // A reply that arrived after an earlier request timed out must not
    // answer this one.
    while replySignal.wait(timeout: .now()) == .success {}
    // Written outside `lock`: a guest that stops reading must not stall the
    // owner's other readers of this link.
    var numbered = m
    let fd: Int32 = lock.withLock {
      replySlot = nil
      lastRequest = lastRequest == Int(Int32.max) ? 1 : lastRequest + 1
      outstanding = lastRequest
      numbered.id = lastRequest
      return writeFD >= 0 ? dup(writeFD) : -1
    }
    guard fd >= 0 else { return nil }
    let line = numbered.encodedLine()
    let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
    close(fd)
    guard sent else { return nil }
    // A signal left by a reply that raced the reset above finds the slot
    // empty: keep waiting for this request's own reply.
    let deadline = DispatchTime.now() + timeout
    while replySignal.wait(timeout: deadline) == .success {
      if let reply = lock.withLock({ replySlot }) { return reply }
    }
    lock.withLock { outstanding = 0 }
    return nil
  }

  /// Ask the guest to shut itself down; true if it acknowledged.
  package func requestShutdown() -> Bool {
    request(HelperMessage(type: .shutdown), timeout: 10)?.type == .ack
  }

  /// The guest's current SSH host key, which must equal the pin.
  package func status() -> HelperMessage? {
    request(HelperMessage(type: .status), timeout: 10)
  }

  // MARK: listener

  package func listener(
    _ listener: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
    from device: VZVirtioSocketDevice
  ) -> Bool {
    // The listener contract: keep the accepted connection alive while in use.
    accept(fd: dup(conn.fileDescriptor), retaining: conn)
  }

  /// Takes ownership of `fd` (a connected stream) and runs the protocol on it
  /// in its own thread. False when too many connections are pending; the
  /// caller then refuses the connection and `fd` is closed. `retaining` is
  /// kept alive with the active connection.
  @discardableResult
  package func accept(fd: Int32, retaining object: AnyObject?) -> Bool {
    let id: Int? = lock.withLock {
      guard pending < HelperProtocol.maxPending else { return nil }
      pending += 1
      nextID += 1
      return nextID
    }
    guard let id else {
      reject("too many pending connections")
      close(fd)
      return false
    }
    // A peer that went away must not kill the owner on our next write.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    nonisolated(unsafe) let object = object
    Thread.detachNewThread { [self] in
      guard let reader = handshake(fd: fd, id: id, retaining: object) else {
        lock.withLock { pending -= 1 }
        close(fd)
        return
      }
      serve(fd: fd, id: id, reader: reader)
    }
    return true
  }

  package var pendingCount: Int { lock.withLock { pending } }

  private var rejections = 0
  private var rejectionWindow = Date()

  /// Logs a rejection, at most 20 a minute: a guest must not be able to
  /// grow the host log without bound by reconnecting.
  private func reject(_ why: String) {
    let (emit, suppressed): (Bool, Int) = lock.withLock {
      if Date().timeIntervalSince(rejectionWindow) > 60 {
        let dropped = max(0, rejections - 20)
        rejections = 0
        rejectionWindow = Date()
        rejections += 1
        return (true, dropped)
      }
      rejections += 1
      return (rejections <= 20, 0)
    }
    if suppressed > 0 { log("helper rejections: \(suppressed) more not logged") }
    if emit { log("helper rejected: \(GuestText.printable(why))") }
  }

  private func send(_ fd: Int32, _ m: HelperMessage) -> Bool {
    let line = m.encodedLine()
    return line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
  }

  /// Challenge, hello, and (first boot) enrollment. Returns the connection's
  /// reader when it became the active one, nil otherwise.
  private func handshake(fd: Int32, id: Int, retaining object: AnyObject?) -> LineReader? {
    var tv = timeval(tv_sec: Int(HelperProtocol.helloDeadline), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let deadline = Date().addingTimeInterval(HelperProtocol.helloDeadline)
    let nonce = HelperProtocol.randomHex(bytes: 16)
    var challenge = HelperMessage(type: .challenge)
    challenge.nonce = nonce
    guard send(fd, challenge) else { return nil }
    var reader = LineReader(fd: fd)
    guard case .line(let line) = reader.next(deadline: deadline) else {
      reject("no hello before the deadline")
      return nil
    }
    guard case .success(let hello) = HelperMessage.parse(line), let boot = hello.boot else {
      reject("malformed hello")
      return nil
    }
    switch Handshake.decide(
      hostEnrolled: store.isEnrolled, hostKey: store.helperKey, hello: hello, nonce: nonce)
    {
    case .reject(let why):
      reject("\(why)")
      return nil
    case .enroll:
      let key = HelperKey.random()
      var enroll = HelperMessage(type: .enroll)
      enroll.key = key.hex
      enroll.authorizedKey = store.authorizedKey
      guard send(fd, enroll) else { return nil }
      // ssh-keygen in the guest may take a while on first boot.
      tv = timeval(tv_sec: 120, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      guard case .line(let replyLine) = reader.next(deadline: Date().addingTimeInterval(120)),
        case .success(let reply) = HelperMessage.parse(replyLine)
      else {
        reject("enrollment failed: no reply")
        return nil
      }
      switch Handshake.verifyEnrolled(reply, key: key, nonce: nonce, boot: boot) {
      case .failure(let e):
        reject("enrollment failed: \(e)")
        return nil
      case .success(let pin):
        do {
          try store.saveEnrollment(key: key, sshHostKey: pin)
          log("helper enrolled; ssh host key pinned")
        } catch {
          log("helper enrollment not saved: \(error)")
          return nil
        }
      }
    case .authenticated:
      break
    }
    // Active from here: this connection replaces any earlier one.
    tv = timeval(tv_sec: 0, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let wfd = dup(fd)
    lock.withLock {
      if writeFD >= 0 { close(writeFD) }
      // End the replaced connection's reader (and its thread) too.
      if readFD >= 0 { shutdown(readFD, SHUT_RDWR) }
      writeFD = wfd
      readFD = fd
      connection = object
      activeID = id
      _guestBoot = boot
      _guestBuild = hello.build
      _generation += 1
      pending -= 1
    }
    log(
      "helper connected boot=\(GuestText.printable(boot)) build=\(GuestText.printable(hello.build ?? "?"))"
    )
    // Apply the static network every boot; the reader loop collects the ack.
    var net = HelperMessage(type: .network)
    net.network = store.network
    Thread.detachNewThread { [self, net] in
      let r = request(net, timeout: 30)
      log(
        "helper network \(r?.type == .ack ? "applied" : "failed: \(GuestText.printable(String((r?.message ?? "no reply").prefix(200))))")"
      )
    }
    return reader
  }

  /// Reads replies on the active connection until it closes.
  private func serve(fd: Int32, id: Int, reader: LineReader) {
    var reader = reader
    while case .line(let line) = reader.next() {
      guard case .success(let m) = HelperMessage.parse(line),
        [.ack, .error, .statusReply].contains(m.type)
      else {
        log("helper sent an unexpected message; closing")
        break
      }
      // Only the active connection answers requests: a late reply from a
      // superseded one must not answer a request made on its replacement.
      // A numbered reply answers only the request with that number.
      let current = lock.withLock { () -> Bool? in
        guard activeID == id else { return nil }
        if let rid = m.id, rid != outstanding { return false }
        replySlot = m
        return true
      }
      guard let current else { break }
      if current { replySignal.signal() }
    }
    // Forget the descriptor before closing it: once closed, its number can
    // be reused by a new connection, which activation must not shut down.
    let wasActive = lock.withLock { () -> Bool in
      guard activeID == id else { return false }
      activeID = 0
      readFD = -1
      _guestBoot = nil
      _generation += 1
      if writeFD >= 0 { close(writeFD) }
      writeFD = -1
      connection = nil
      return true
    }
    close(fd)
    if wasActive { log("helper disconnected") }
  }
}
