import Foundation
import IsoMacProtocol

/// Per-boot live-view counts for `status` and the host's audit: no token,
/// pixels, coordinates or text.
package struct MacLiveViewCounters: Codable, Equatable, Sendable {
  package var streams = 0
  package var viewers = 0
  package var takeovers = 0
  package var inputEvents = 0

  package init() {}
}

/// One VM's live view (docs/design/computer-use-live-view.md): off until
/// `start`, then a loopback listener whose viewers get the display as
/// H.264 and may take control under the host hold. It samples and encodes
/// only while a viewer is connected, and stops after
/// `LiveView.idleStop` with none.
@MainActor
package final class LiveViewSession {
  private let screen: VMScreen
  private let log: @Sendable (String) -> Void
  private var server: LiveViewServer?
  private var bridge: Bridge?
  private var encoder: LiveViewEncoder?
  private var control = LiveViewControl()
  private var held = LiveViewHeld()
  private var viewers: Set<Int> = []
  private var loop: Task<Void, Never>?
  private var idle: Task<Void, Never>?
  private var lastChange = Date.distantPast
  private var lastInput = Date.distantPast
  private var lastSeq: UInt64?
  /// Set by a keyframe: the next sample is encoded even if nothing
  /// changed. A browser decoder holds a frame until the next one arrives,
  /// so a keyframe alone on a static screen would never be shown.
  private var trailing = false
  package private(set) var counters = MacLiveViewCounters()

  package init(screen: VMScreen, log: @escaping @Sendable (String) -> Void) {
    self.screen = screen
    self.log = log
  }

  package var listening: Bool { server != nil }

  /// Starts the stream, or returns the running one's URL.
  package func start() throws -> String {
    if let server { return server.url }
    let bridge = Bridge(session: self)
    let s = try LiveViewServer(token: try .random(), host: bridge, log: log)
    s.start()
    server = s
    self.bridge = bridge
    counters.streams += 1
    log("live view listening on 127.0.0.1:\(s.port)")
    scheduleIdleStop()
    return s.url
  }

  /// Ends the stream: held viewer input is released, the listener and every
  /// viewer closed. A host hold a viewer took is left to expire.
  package func stop() {
    guard let server else { return }
    idle?.cancel()
    idle = nil
    releaseHeld()
    control = LiveViewControl()
    server.stop()
    self.server = nil
    bridge = nil
    stopStreaming()
    viewers = []
    log("live view stopped")
  }

  // MARK: viewers (called through the bridge, on the main actor)

  fileprivate func joined(_ viewer: Int) {
    viewers.insert(viewer)
    counters.viewers += 1
    idle?.cancel()
    idle = nil
    bridge?.requestKeyframe()
    if encoder == nil {
      do {
        let server = server
        encoder = try LiveViewEncoder(width: screen.width, height: screen.height) {
          bytes, key, micros in
          server?.broadcast(bytes, keyframe: key, micros: micros)
        }
      } catch {
        log("live view: \(error)")
        server?.send(text: Self.error("no H.264 encoder on this host"), to: viewer)
      }
    }
    if loop == nil { loop = Task { await run() } }
    server?.send(text: state(for: viewer), to: viewer)
  }

  fileprivate func left(_ viewer: Int) {
    viewers.remove(viewer)
    // A closed tab releases what it held but not the hold: it expires.
    for input in control.disconnect(viewer, held: &held) {
      try? screen.viewerSend(input, held: held)
    }
    broadcastState()
    guard viewers.isEmpty else { return }
    stopStreaming()
    if server != nil { scheduleIdleStop() }
  }

  fileprivate func handle(_ viewer: Int, _ message: LiveViewMessage) async -> String? {
    let now = Date()
    switch message {
    case .auth:
      return nil
    case .take:
      guard control.take(viewer, at: now) == .taken else {
        return Self.error("another viewer has control")
      }
      screen.hold(.implicit, seconds: CUControl.implicitHold)
      counters.takeovers += 1
      broadcastState()
      return nil
    case .release:
      if control.release(viewer) {
        releaseHeld()
        // Only the hold viewers take: a `cu hold` from the CLI runs on.
        screen.releaseImplicitHold()
      }
      broadcastState()
      return nil
    case .input(let input):
      if case .drop(let reply) = admitInput(viewer, releasing: input.isRelease, at: now) {
        return reply
      }
      var next = held
      guard next.apply(input) else { return nil }
      held = next
      return await deliver { try screen.viewerSend(input, held: next) }
    case .text(let text):
      if case .drop(let reply) = admitInput(viewer, releasing: false, at: now) { return reply }
      return await deliver { try await screen.viewerType(text) }
    }
  }

  private enum InputAdmission {
    case send
    /// Not sent; answer the viewer with `reply`, if any.
    case drop(reply: String?)
  }

  /// Whether `viewer` may send input now; each admitted input extends the
  /// hold to 60 s from now.
  private func admitInput(_ viewer: Int, releasing: Bool, at now: Date) -> InputAdmission {
    switch control.admit(viewer, at: now) {
    case .viewOnly:
      return .drop(reply: nil)
    case .expired:
      releaseHeld()
      broadcastState()
      return .drop(reply: nil)
    case .accepted:
      break
    }
    // A key or button up is sent even while a host action runs: the
    // browser has already let go, so a dropped up would stay down.
    guard releasing || !screen.isActing else {
      return .drop(reply: Self.error("busy: a host action is in progress"))
    }
    screen.hold(.implicit, seconds: CUControl.implicitHold)
    lastInput = now
    return .send
  }

  /// Sends one admitted input; a failure releases everything held.
  private func deliver(_ send: () async throws -> Void) async -> String? {
    do {
      try await send()
      counters.inputEvents += 1
      return nil
    } catch {
      releaseHeld()
      return Self.error("input not sent: \(error)")
    }
  }

  // MARK: frames

  /// Samples at the frame-rate cap while the screen changed or the viewer
  /// gave input in the last second, otherwise at 2 Hz, and encodes only a
  /// changed screen or a forced keyframe.
  private func run() async {
    while !Task.isCancelled, !viewers.isEmpty {
      let now = Date()
      if control.lapse(at: now) != nil {
        releaseHeld()
        broadcastState()
      }
      let key = bridge?.takeKeyframe() ?? false
      do {
        try screen.streamFrame { data, bytesPerRow, seq in
          if seq != lastSeq { lastChange = now }
          guard let encoder, key || trailing || seq != lastSeq else { return }
          let keyframe = key || lastSeq == nil
          try encoder.encode(rgbx: data, bytesPerRow: bytesPerRow, keyframe: keyframe)
          trailing = keyframe
          lastSeq = seq
        }
      } catch {
        if key { bridge?.requestKeyframe() }
      }
      let active = now.timeIntervalSince(max(lastChange, lastInput)) < 1
      let rate = active ? LiveView.frameRateCap : LiveView.staticFrameRate
      try? await Task.sleep(for: .milliseconds(1000 / rate))
    }
  }

  // MARK: helpers

  private func releaseHeld() {
    let releases = held.releaseAll()
    for input in releases { try? screen.viewerSend(input, held: held) }
  }

  /// Stops sampling and encoding, as when the last viewer leaves.
  private func stopStreaming() {
    loop?.cancel()
    loop = nil
    encoder?.invalidate()
    encoder = nil
    lastSeq = nil
  }

  private func scheduleIdleStop() {
    idle?.cancel()
    idle = Task { [weak self] in
      try? await Task.sleep(for: .seconds(LiveView.idleStop))
      guard !Task.isCancelled, let self, self.viewers.isEmpty, self.server != nil else { return }
      self.log("live view: no viewer for \(Int(LiveView.idleStop)) s")
      self.stop()
    }
  }

  private func state(for viewer: Int) -> String {
    let controlling = control.controller == viewer
    let other = control.controller != nil && !controlling
    return #"{"type":"state","controlling":\#(controlling),"otherControls":\#(other)}"#
  }

  private func broadcastState() {
    for v in viewers { server?.send(text: state(for: v), to: v) }
  }

  private static func error(_ message: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "message": message])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"type":"error"}"#
  }
}

/// The server's way into the session: each call runs on the main actor while
/// the connection thread waits, so one viewer's messages stay in order.
private final class Bridge: LiveViewHost, @unchecked Sendable {
  nonisolated(unsafe) weak var session: LiveViewSession?
  private let lock = NSLock()
  private var keyframe = false

  init(session: LiveViewSession) { self.session = session }

  func requestKeyframe() { lock.withLock { keyframe = true } }

  func takeKeyframe() -> Bool {
    lock.withLock {
      defer { keyframe = false }
      return keyframe
    }
  }

  func needKeyframe() { requestKeyframe() }

  func joined(_ viewer: Int) { onMain { $0.joined(viewer) } }

  func left(_ viewer: Int) { onMain { $0.left(viewer) } }

  func message(_ viewer: Int, _ message: LiveViewMessage) -> String? {
    let box = ReplyBox()
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor [weak self] in
      box.value = await self?.session?.handle(viewer, message)
      done.signal()
    }
    done.wait()
    return box.value
  }

  private func onMain(_ body: @MainActor (LiveViewSession) -> Void) {
    DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        if let session { body(session) }
      }
    }
  }
}

private final class ReplyBox: @unchecked Sendable {
  var value: String?
}
