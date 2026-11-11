import Darwin
import Foundation
import IsoMacProtocol

/// What the server asks of the owner. Every call is made from a connection
/// thread, and each blocks that thread until the owner has answered, so one
/// viewer's messages are handled in order.
package protocol LiveViewHost: AnyObject, Sendable {
  /// An authenticated viewer joined.
  func joined(_ viewer: Int)
  /// One parsed message; returns state text to send back to that viewer.
  func message(_ viewer: Int, _ message: LiveViewMessage) -> String?
  /// A viewer left, however it went.
  func left(_ viewer: Int)
  /// A viewer that dropped frames has sent what it had queued: the next
  /// frame should be a keyframe, which now fits.
  func needKeyframe()
}

/// The live-view listener (docs/design/computer-use-live-view.md §5): one
/// TCP socket on `127.0.0.1` at an ephemeral port, serving the embedded
/// viewer and one WebSocket per viewer. Every byte a client sends is
/// untrusted: requests are routed only after exact `Host` and `Origin`
/// checks, the first WebSocket message must carry the stream token within
/// `LiveView.tokenDeadline`, connections are capped at
/// `LiveView.maxConnections` before any byte is read, and messages are
/// bounded, closed and rate limited. The token is never logged.
package final class LiveViewServer: @unchecked Sendable {
  package let port: UInt16
  /// The address the listener is bound to, read back from the socket.
  package let address: String
  private let stalledViewer: TimeInterval
  private let listener: Int32
  private let token: LiveViewToken
  private let log: @Sendable (String) -> Void
  private weak var host: (any LiveViewHost)?
  private let lock = NSLock()
  private var viewers: [Int: Viewer] = [:]
  private var nextViewer = 1
  private var stopped = false
  private var rejections = 0
  private var rejectionWindow = Date()
  /// Connections being served, authenticated or not: a loopback port is
  /// open to every local process, and each connection holds a thread and a
  /// descriptor of the process that runs the VM.
  private let slots = ConnectionSlots(limit: LiveView.maxConnections)

  final class Viewer: @unchecked Sendable {
    let id: Int
    let fd: Int32
    let ready = NSCondition()
    /// Signalled when the writer thread has returned and no longer uses `fd`.
    let writerDone = DispatchSemaphore(value: 0)
    var queue: [[UInt8]] = []
    var queued = 0
    /// Frames are dropped until the next keyframe after an overflow.
    var dropping = false
    /// The keyframe that ends `dropping` has been asked for: once per
    /// overflow, when the queue has drained, so a slow viewer cannot make
    /// every frame a keyframe for everyone.
    var keyframeRequested = false
    var closed = false

    init(id: Int, fd: Int32) {
      self.id = id
      self.fd = fd
    }
  }

  package init(
    token: LiveViewToken, host: any LiveViewHost,
    stalledViewer: TimeInterval = LiveView.stalledViewer,
    log: @escaping @Sendable (String) -> Void
  ) throws {
    self.stalledViewer = stalledViewer
    self.token = token
    self.host = host
    self.log = log
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SandboxError("no socket for the live view") }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    // Loopback only, never a wildcard.
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
      close(fd)
      throw SandboxError("could not listen on 127.0.0.1 for the live view")
    }
    var got = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &got) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    listener = fd
    port = UInt16(bigEndian: got.sin_port)
    address = String(cString: inet_ntoa(got.sin_addr))
  }

  /// The viewer's URL, at the address the socket is really bound to.
  package var url: String { "http://\(address):\(port)/#\(token.value)" }

  package var viewerCount: Int { lock.withLock { viewers.count } }

  package func start() {
    Thread.detachNewThread { [self] in
      // The accept thread owns the listener and closes it: `stop` only
      // flags it, and the poll below notices within half a second.
      defer { close(listener) }
      while !lock.withLock({ stopped }) {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 500) > 0 else { continue }
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { continue }
        guard !lock.withLock({ stopped }) else {
          close(fd)
          return
        }
        // Past the limit a connection is closed unread, as on the control
        // socket and the guest link.
        guard slots.enter() else {
          close(fd)
          reject("too many connections")
          continue
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking, so a write larger than the helper-line chunk cannot
        // block past its deadline; every read and write polls first. The
        // descriptor is this connection's alone (no `dup`).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        Thread.detachNewThread { [self] in
          defer { slots.leave() }
          serve(fd)
        }
      }
    }
  }

  /// Stops accepting and closes every viewer. Threads end on their own.
  package func stop() {
    let all: [Viewer] = lock.withLock {
      stopped = true
      return Array(viewers.values)
    }
    for v in all { shutdown(v.fd, SHUT_RDWR) }
  }

  // MARK: output

  /// Queues one encoded frame for every viewer: `[1][flags][µs, 8 bytes BE][Annex-B]`.
  package func broadcast(_ annexB: [UInt8], keyframe: Bool, micros: UInt64) {
    let payload: [UInt8] = [1, keyframe ? 1 : 0] + LiveView.bigEndian(micros) + annexB
    let frame = WSFrame.encode(opcode: 0x2, payload)
    var drained = false
    for v in lock.withLock({ Array(viewers.values) }) {
      v.ready.lock()
      switch LiveViewQueue.offer(
        frame.count, keyframe: keyframe, queued: v.queued, dropping: v.dropping)
      {
      case .queue:
        v.dropping = false
        v.keyframeRequested = false
        v.queue.append(frame)
        v.queued += frame.count
        v.ready.signal()
      case .drop:
        v.dropping = true
        // Nothing queued means the writer will not run to ask for the
        // keyframe, so ask here; otherwise the writer asks once it drains.
        if v.queue.isEmpty && !v.keyframeRequested {
          v.keyframeRequested = true
          drained = true
        }
      }
      v.ready.unlock()
    }
    if drained { host?.needKeyframe() }
  }

  /// Queues state text for one viewer, or for all when `viewer` is nil.
  package func send(text: String, to viewer: Int? = nil) {
    let frame = WSFrame.encode(opcode: 0x1, Array(text.utf8))
    let targets = lock.withLock {
      viewer.map { viewers[$0].map { [$0] } ?? [] } ?? Array(viewers.values)
    }
    for v in targets { enqueue(v, frame) }
  }

  /// Queues a pong or state text. These are never dropped, so a viewer
  /// whose queue they would overfill is disconnected: it is not reading,
  /// and its queue is memory of the process that runs the VM.
  private func enqueue(_ v: Viewer, _ frame: [UInt8]) {
    v.ready.lock()
    let fits = v.queued + frame.count <= LiveView.queueLimit
    if fits {
      v.queue.append(frame)
      v.queued += frame.count
      v.ready.signal()
    }
    v.ready.unlock()
    if !fits {
      reject("viewer queue full")
      shutdown(v.fd, SHUT_RDWR)
    }
  }

  /// Writes a viewer's queue; a viewer that accepts nothing for
  /// `stalledViewer` is disconnected.
  private func write(_ v: Viewer) {
    while true {
      v.ready.lock()
      while v.queue.isEmpty && !v.closed { v.ready.wait() }
      if v.closed {
        v.ready.unlock()
        return
      }
      let next = v.queue.removeFirst()
      v.queued -= next.count
      let caughtUp = v.dropping && v.queue.isEmpty && !v.keyframeRequested
      if caughtUp { v.keyframeRequested = true }
      v.ready.unlock()
      let sent = BoundedWrite.all(
        v.fd, next, deadline: ContinuousClock.now + .seconds(stalledViewer),
        chunk: LiveView.writeChunk)
      if !sent {
        shutdown(v.fd, SHUT_RDWR)
        return
      }
      if caughtUp { host?.needKeyframe() }
    }
  }

  // MARK: connections

  private func serve(_ fd: Int32) {
    defer { close(fd) }
    let deadline = Date().addingTimeInterval(LiveView.tokenDeadline)
    var buffer: [UInt8] = []
    guard let head = readHead(fd, &buffer, until: deadline),
      let request = LiveViewHTTPRequest.parse(head)
    else {
      reject("malformed request")
      return
    }
    switch LiveViewRoute.decide(request, port: port) {
    case .refused(let status, let reason):
      reject("request refused: \(reason.rawValue)")
      respond(fd, status: status, type: "text/plain", body: Array("refused\n".utf8))
    case .asset(let contentType, let body):
      respond(fd, status: 200, type: contentType, body: Array(body.utf8))
    case .upgrade(let accept):
      let reply =
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
      guard BoundedWrite.all(fd, Array(reply.utf8), deadline: .now + .seconds(5)) else { return }
      webSocket(fd, buffer: &buffer, authDeadline: deadline)
    }
  }

  /// The request head, read until the blank line or the deadline.
  private func readHead(_ fd: Int32, _ buffer: inout [UInt8], until deadline: Date) -> [UInt8]? {
    let end: [UInt8] = [13, 10, 13, 10]
    while true {
      if let r = buffer.firstRange(of: end) {
        let head = Array(buffer[..<r.upperBound])
        buffer.removeFirst(r.upperBound)
        return head
      }
      guard buffer.count < LiveView.maxRequestHead, read(fd, &buffer, until: deadline) else {
        return nil
      }
    }
  }

  /// Appends what arrives before `deadline`; false on timeout, EOF or error.
  private func read(_ fd: Int32, _ buffer: inout [UInt8], until deadline: Date) -> Bool {
    while true {
      let left = deadline.timeIntervalSinceNow
      guard left > 0 else { return false }
      var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let polled = poll(&ready, 1, Int32(min(left * 1000 + 1, 60_000)))
      if polled < 0, errno == EINTR { continue }
      guard polled >= 0 else { return false }
      // A quiet viewer is not a closed one: poll again until the deadline.
      if polled == 0 { continue }
      var chunk = [UInt8](repeating: 0, count: 4096)
      let n = Darwin.read(fd, &chunk, chunk.count)
      if n < 0, errno == EAGAIN || errno == EINTR { continue }
      guard n > 0 else { return false }
      buffer += chunk[..<n]
      return true
    }
  }

  private func respond(_ fd: Int32, status: Int, type: String, body: [UInt8]) {
    let reason =
      [
        200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 421: "Misdirected Request",
      ][status] ?? "Error"
    let head =
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
      + "Content-Security-Policy: default-src 'self'\r\nCache-Control: no-store\r\n"
      + "Referrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
      + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
    _ = BoundedWrite.all(fd, Array(head.utf8) + body, deadline: .now + .seconds(5))
  }

  /// The WebSocket: authenticate, register, then read messages until the
  /// viewer leaves.
  private func webSocket(_ fd: Int32, buffer: inout [UInt8], authDeadline: Date) {
    func next(until deadline: Date) -> WSFrame? {
      while true {
        do {
          if let f = try WSFrame.decode(&buffer) { return f }
        } catch {
          reject("bad frame: \(error)")
          return nil
        }
        guard read(fd, &buffer, until: deadline) else { return nil }
      }
    }
    guard case .text(let first)? = next(until: authDeadline),
      case .success(.auth(let presented)) = LiveViewMessage.parse(
        first, width: MacDisplay.width, height: MacDisplay.height),
      token.matches(presented)
    else {
      reject("viewer not authenticated")
      return
    }
    let viewer: Viewer? = lock.withLock {
      guard !stopped, viewers.count < LiveView.maxViewers else { return nil }
      let v = Viewer(id: nextViewer, fd: fd)
      nextViewer += 1
      viewers[v.id] = v
      return v
    }
    guard let viewer else {
      reject(LiveViewServer.viewerLimitRejection)
      _ = BoundedWrite.all(
        fd,
        WSFrame.encode(
          opcode: 0x1, Array(#"{"type":"error","message":"viewer limit reached"}"#.utf8)),
        deadline: .now + .seconds(2))
      return
    }
    let writer = Thread { [self] in
      write(viewer)
      viewer.writerDone.signal()
    }
    writer.start()
    defer {
      lock.withLock { _ = viewers.removeValue(forKey: viewer.id) }
      viewer.ready.lock()
      viewer.closed = true
      viewer.ready.signal()
      viewer.ready.unlock()
      // Unblocks a write in progress; the caller closes `fd` only once the
      // writer is done with it, so its number is never reused under it.
      shutdown(fd, SHUT_RDWR)
      viewer.writerDone.wait()
      host?.left(viewer.id)
    }
    host?.joined(viewer.id)
    var limits = LiveViewLimits(now: Date())
    while let frame = next(until: .distantFuture) {
      switch frame {
      case .close: return
      case .ping(let p):
        // Charged like any message: a flood of pings gets no flood of pongs.
        guard limits.admitPing(at: Date()) else { continue }
        enqueue(viewer, WSFrame.encode(opcode: 0xA, p))
      case .pong: continue
      case .binary:
        reject("binary message")
        return
      case .text(let text):
        let parsed = LiveViewMessage.parse(
          text, width: MacDisplay.width, height: MacDisplay.height)
        // Charged after parsing: what lets go of input has its own budget.
        guard limits.admit(parsed, at: Date()) else { continue }
        switch parsed {
        case .success(.auth): continue
        case .success(let m):
          if let reply = host?.message(viewer.id, m) { send(text: reply, to: viewer.id) }
        case .failure(.unknownKey): continue
        case .failure(let why): reject("message refused: \(why)")
        }
      }
    }
  }

  static let viewerLimitRejection = "viewer limit reached"

  /// Logs a rejection's kind (never client bytes), at most 20 a minute.
  private func reject(_ why: String) {
    let emit: Bool = lock.withLock {
      if Date().timeIntervalSince(rejectionWindow) > 60 {
        rejections = 0
        rejectionWindow = Date()
      }
      rejections += 1
      return rejections <= 20
    }
    if emit { log("live view: \(why)") }
  }
}
