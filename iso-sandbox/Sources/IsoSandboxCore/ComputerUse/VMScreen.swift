import AppKit
import CryptoKit
import Foundation
import IsoMacProtocol
import Virtualization

/// The owner's computer-use surface (Gates C–H), for macOS and Linux
/// guests alike: a `VZVirtualMachineView` in an ordered-out window (V5),
/// sessions bound to the VM and guest boot, frames in framebuffer pixels,
/// and input synthesized into the view, which VZ forwards to the guest's
/// keyboard and pointer (a USB keyboard maps the Mac key codes to HID
/// usages). Nothing is posted to the host event system and the owner never
/// activates.
@MainActor
package final class VMScreen {
  /// How a frame is read from the view.
  package enum Capture: Sendable {
    /// `cacheDisplay(in:to:)` of the view: macOS guests, until the surface
    /// read is tested against one.
    case viewCache
    /// The IOSurface VZ renders the framebuffer into, alpha byte ignored
    /// (``FramebufferSurface``): Linux guests, whose XRGB framebuffer
    /// `cacheDisplay` treats as transparent
    /// (docs/design/linux-desktop-virtio-gpu.md §3).
    case framebufferSurface

    /// Whether a uniform frame means the framebuffer was not observed. The
    /// view cache renders a missing framebuffer as one flat colour and
    /// reports nothing; the surface read throws when there is no surface,
    /// so a uniform frame from it is what the guest drew (a bare desktop).
    var refusesUniformFrames: Bool {
      switch self {
      case .viewCache: true
      case .framebufferSurface: false
      }
    }
  }

  package let width = MacDisplay.width
  package let height = MacDisplay.height
  private let capture: Capture
  private let view: VZVirtualMachineView
  private let window: NSWindow
  private var table = CUSessions()
  /// Who drives the display: host holds win over the guest's session.
  private var control = CUControl()
  /// One action at a time: actions suspend between steps, and two in flight
  /// would interleave on the single pointer and keyboard.
  private var acting = false
  /// The display's damage, sampled only on frames, before actions and while
  /// a wait runs (docs/design/computer-use-screen-sync.md §3).
  private var damage = DamageGrid(width: MacDisplay.width, height: MacDisplay.height)
  /// The framebuffer-sized render target, reused so that each sample
  /// compares bytes drawn the same way.
  private var renderContext: CGContext?
  /// The bitmap the view is cached into, reused: a fresh 9 MB one for
  /// every sample is most of a millisecond of allocation and page faults.
  private var viewBitmap: NSBitmapImageRep?
  /// When the render target was last filled, for samplers that share one.
  private var renderedAt: ContinuousClock.Instant?
  private var waits = CUWaitSlots()
  /// Supplies the current binding; nil while the guest helper is not connected.
  private let current: () -> CUBinding?

  package init(
    adaptor: VZVirtualMachineViewAdaptor, capture: Capture,
    current: @escaping () -> CUBinding?
  ) {
    self.capture = capture
    self.current = current
    let v = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    v.adaptor = adaptor
    v.automaticallyReconfiguresDisplay = false
    v.capturesSystemKeys = true
    view = v
    let w = UnconstrainedWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.contentView = v
    // Ordered out: never visible, never key, never on a screen.
    w.orderOut(nil)
    window = w
  }

  package var topology: String {
    "V5 ordered-out window (\(window.isVisible ? "visible!" : "not visible"))"
      + (capture == .framebufferSurface ? ", framebuffer surface" : "")
  }

  // MARK: sessions

  /// A host session. Opening one takes no hold: a host may watch frames
  /// while the guest drives.
  package func newSession() throws -> (String, CUBinding) {
    try table.open(current: current())
  }

  /// The guest's session, replacing any earlier one; refused during a host
  /// hold.
  package func newGuestSession() throws -> (String, CUBinding) {
    let (id, binding) = try table.open(current: current())
    do {
      if let old = try control.openGuest(id, at: Date()) { table.revoke(old) }
    } catch {
      table.revoke(id)
      throw error
    }
    return (id, binding)
  }

  // MARK: control

  /// Guest sessions host holds have ended this boot.
  package private(set) var preemptions = 0

  /// Starts or extends a host hold, ending the guest's session.
  package func hold(_ kind: CUControl.Hold, seconds: TimeInterval) {
    if let guest = control.hold(kind, for: seconds, at: Date()) {
      table.revoke(guest)
      preemptions += 1
    }
  }

  /// `cu release`: ends every hold.
  package func release() { control.release() }

  /// A live-view viewer's release: a `cu hold` taken from the CLI runs on.
  package func releaseImplicitHold() { control.releaseImplicit() }

  package var controlState: (controller: GuestCUController, holdRemainingSeconds: Int) {
    let now = Date()
    return (control.controller(at: now), control.holdRemaining(at: now))
  }

  private func check(_ id: String?) throws -> CUBinding {
    let bound = try table.check(id, current: current())
    // A view outside a window renders nothing and drops pointer input.
    guard view.window != nil else {
      throw SandboxError("view has no window", refusal: .noWindow)
    }
    return bound
  }

  // MARK: frames

  package struct Frame: Sendable {
    package var id: String
    package var seq: Int
    package var png: Data
    package var sha256: String
    package var binding: CUBinding
    package var timestamp: Date
    package var damageSeq: UInt64
  }

  /// This boot's damage sequence; it restarts at 0 with each owner.
  package var damageSeq: UInt64 { damage.seq }

  /// Renders the view at framebuffer pixels, whatever the window's backing
  /// scale (Gate F), and samples damage from the result. A uniform render is
  /// still sampled; only `frame` refuses it, and only from the view cache.
  /// A sample no older than `maxAge` is returned as it is: the live view
  /// and each wait poll on their own clocks, and one capture serves those
  /// that fall together. Frames and action baselines always capture.
  private func render(maxAge: Duration = .zero) throws -> CGContext {
    let ctx = try context()
    let now = ContinuousClock.now
    if let renderedAt, maxAge > .zero, now - renderedAt < maxAge { return ctx }
    guard let data = ctx.data else { throw SandboxError("no drawing buffer") }
    // A capture that fails leaves the target half-drawn: never shared.
    renderedAt = nil
    switch capture {
    case .viewCache: try cacheView(into: ctx)
    case .framebufferSurface:
      do {
        try FramebufferSurface.read(
          under: view, width: width, height: height, into: data, bytesPerRow: ctx.bytesPerRow)
      } catch {
        // Never a `cacheDisplay` fallback: it drops every pixel the guest
        // wrote with alpha 0.
        throw SandboxError("framebuffer not observed: \(error)", refusal: .blankFrame)
      }
    }
    try damage.sample(UnsafeRawBufferPointer(start: data, count: ctx.bytesPerRow * height))
    renderedAt = now
    return ctx
  }

  /// How old a sample the polling samplers share: half a tick, so sharing
  /// never costs one of them a whole period.
  static let sharedSampleAge = Duration.milliseconds(ScreenWait.tickMs / 2)

  /// The framebuffer-sized RGBX render target, made once.
  private func context() throws -> CGContext {
    if let renderContext { return renderContext }
    guard
      let made = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw SandboxError("no drawing context") }
    made.interpolationQuality = .high
    // The context is reused: each draw must replace every pixel, or what a
    // transparent (missing) framebuffer leaves untouched is the last frame.
    made.setBlendMode(.copy)
    renderContext = made
    return made
  }

  private func cacheView(into ctx: CGContext) throws {
    // Cached straight at framebuffer pixels: the window's own backing (2x
    // on a Retina host) costs ~45 ms to cache and ~30 ms to scale back
    // down, against ~5 ms here (docs/design/computer-use-screen-sync.md §9).
    let rep = try bitmap()
    // Cleared first, as a new bitmap is: what a missing framebuffer leaves
    // undrawn must read as transparent, not as the last frame.
    if let pixels = rep.bitmapData { memset(pixels, 0, rep.bytesPerRow * rep.pixelsHigh) }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let source = rep.cgImage else { throw SandboxError("no image from the view") }
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
  }

  private func bitmap() throws -> NSBitmapImageRep {
    if let viewBitmap { return viewBitmap }
    guard
      let made = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { throw SandboxError("no bitmap for the view") }
    viewBitmap = made
    return made
  }

  package func frame(session: String?, origin: CUOrigin = .host) throws -> Frame {
    if origin == .guest { try control.requireGuest(session, at: Date()) }
    let bound = try check(session)
    // A copy: later renders into the context do not change it.
    guard let image = try render().makeImage() else { throw SandboxError("no frame image") }
    // A uniform frame is how a missing framebuffer looks in the view cache:
    // refuse it.
    if capture.refusesUniformFrames, let range = Self.channelRange(image), range <= 3 {
      throw SandboxError(
        "blank frame (channel range \(range)): framebuffer not observed", refusal: .blankFrame)
    }
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw SandboxError("png encoding failed") }
    let (id, seq) = table.recordFrame(bound)
    return Frame(
      id: id, seq: seq, png: png,
      sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), binding: bound,
      timestamp: Date(), damageSeq: damage.seq)
  }

  // MARK: live view

  /// One stream frame: the same render and damage sample as `frame`, with
  /// no session and no PNG. `body` reads the RGBX pixels, with the damage
  /// sequence after this sample, before the next render can change them.
  package func streamFrame(
    _ body: (UnsafeRawPointer, _ bytesPerRow: Int, _ damageSeq: UInt64) throws -> Void
  ) throws {
    let ctx = try render(maxAge: Self.sharedSampleAge)
    guard let data = ctx.data else { throw SandboxError("no drawing buffer") }
    try body(data, ctx.bytesPerRow, damage.seq)
  }

  /// Whether an action or typed viewer text is being sent.
  package var isActing: Bool { acting }

  /// The last viewer button press, for click counts.
  private var viewerPress: (button: CUButton, point: CUPoint, at: TimeInterval, count: Int)?

  /// Sends one raw viewer input (docs/design/computer-use-live-view.md §7)
  /// into the view, as actions are. `held` is the viewer's state after it.
  /// Viewers send only under a host hold, so no guest session is checked. A
  /// release is sent even while an action runs: a key left down is worse
  /// than an interleaved up.
  package func viewerSend(_ input: LiveViewInput, held: LiveViewHeld) throws {
    guard input.isRelease || !acting else {
      throw SandboxError("a host action is in progress", refusal: .busy)
    }
    switch input {
    case .move(let p):
      if let b = held.buttons.min(by: { $0.rawValue < $1.rawValue }) {
        try dragged(p, b)
      } else {
        try move(p)
      }
    case .button(let p, let b, let down):
      let now = ProcessInfo.processInfo.systemUptime
      var count = 1
      if let last = viewerPress, last.button == b, now - last.at < 0.5,
        abs(last.point.x - p.x) < 4, abs(last.point.y - p.y) < 4
      {
        count = down ? min(last.count + 1, 3) : last.count
      }
      if down { viewerPress = (b, p, now, count) }
      try button(p, b, down: down, clickCount: count)
    case .scroll(let p, let dx, let dy):
      try move(p)
      try scroll(dx: dx, dy: dy)
    case .key(let code, let down):
      let kind: CUKeyEvent.Kind =
        LiveViewKeys.modifier(keyCode: code) != nil ? .flags : (down ? .down : .up)
      try send(CUKeyEvent(kind: kind, keyCode: code, characters: "", flags: held.flags))
    }
  }

  /// Types viewer text (a paste) under the `type` action's rules, holding
  /// off host actions until it is done. `proceed` runs after each key, as
  /// an action re-checks its session: when it throws (the viewer's control
  /// ended) the paste stops and what it pressed is released.
  package func viewerType(_ text: String, proceed: () throws -> Void) async throws {
    guard !acting else { throw SandboxError("a host action is in progress", refusal: .busy) }
    acting = true
    defer { acting = false }
    try await sendKeys(CUKeys.events(forText: text)) {
      try await Task.sleep(for: .milliseconds(12))
      try proceed()
    }
  }

  private func sendKeys(_ keys: [CUKeyEvent], pause: () async throws -> Void) async throws {
    try await CUKeys.deliver(keys, send: { try send($0) }, pause: pause)
  }

  // MARK: wait

  /// Waits for `region` to settle (docs/design/computer-use-screen-sync.md
  /// §4), sampling at `ScreenWait.tickMs`. One wait runs at a time for the
  /// host and one for the guest; a host
  /// hold or a broken binding ends a guest's wait with its refusal. Host
  /// callers take no hold by waiting. Returns the result and the `seq` after.
  package func wait(
    session: String?, since: UInt64?, idleMs: Int?, timeoutMs: Int?,
    until: GuestCUWaitUntil?, region: GuestCURegion?, origin: CUOrigin = .host
  ) async throws -> (GuestCUWaitResult, damageSeq: UInt64) {
    func admitted() throws {
      if origin == .guest { try control.requireGuest(session, at: Date()) }
      _ = try check(session)
    }
    try admitted()
    let parameters = try ScreenWait.Parameters.validated(
      since: since, idleMs: idleMs, timeoutMs: timeoutMs, until: until, region: region,
      width: width, height: height, current: damage.seq)
    try waits.take(origin)
    defer { waits.free(origin) }
    _ = try render()
    let start = ContinuousClock.now
    let result = try await ScreenWait.run(
      ScreenWait(parameters, since: parameters.since ?? damage.seq),
      first: damage.latest(in: parameters.region),
      elapsedMs: {
        let d = (ContinuousClock.now - start).components
        return Int(d.seconds) * 1000 + Int(d.attoseconds / 1_000_000_000_000_000)
      },
      sleep: { try await Task.sleep(for: .milliseconds(ScreenWait.tickMs)) },
      check: admitted,
      sample: {
        _ = try render(maxAge: Self.sharedSampleAge)
        return damage.latest(in: parameters.region)
      })
    return (result, damage.seq)
  }

  static func channelRange(_ image: CGImage) -> Int? {
    let w = 64
    let h = 40
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = px.withUnsafeMutableBytes { buf in
      guard
        let ctx = CGContext(
          data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      ctx.interpolationQuality = .none
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard ok else { return nil }
    var spread = 0
    for c in 0..<3 {
      var lo = 255
      var hi = 0
      for i in stride(from: c, to: px.count, by: 4) {
        lo = min(lo, Int(px[i]))
        hi = max(hi, Int(px[i]))
      }
      spread = max(spread, hi - lo)
    }
    return spread
  }

  // MARK: actions

  /// Runs one validated action. `basedOnFrame`, if given, must be a frame
  /// captured under this session's binding. A failure part-way releases every
  /// button and key the action pressed. Returns the input events submitted
  /// and the damage sequence sampled just before the first of them.
  package func act(
    session: String?, request: CUActionRequest, basedOnFrame: String?, origin: CUOrigin = .host
  ) async throws -> (submitted: Int, damageSeq: UInt64) {
    let bound: CUBinding
    let action: CUAction
    let damageSeq: UInt64
    do {
      if origin == .guest { try control.requireGuest(session, at: Date()) }
      bound = try check(session)
      if let basedOnFrame { try table.requireFrame(basedOnFrame, from: bound) }
      do { action = try request.validated(width: width, height: height) } catch {
        throw SandboxError("\(error)", refusal: .invalidAction)
      }
      guard !acting else { throw SandboxError("another action is in progress", refusal: .busy) }
      // The baseline a settle wait after this action is anchored to.
      _ = try render()
      damageSeq = damage.seq
    } catch var e as SandboxError {
      e.beforeInput = true
      throw e
    }
    // Host input never interleaves with the guest's: it takes a hold first.
    if origin == .host { hold(.implicit, seconds: CUControl.implicitHold) }
    acting = true
    defer { acting = false }
    var pressed: [CUButton] = []
    var last = CUPoint(x: 0, y: 0)
    do {
      var keys: [CUKeyEvent] = []
      switch action {
      case .move(let p):
        try move(p)
      case .click(let p, let b, let count):
        last = p
        try move(p)
        try await step(session)
        for i in 1...count {
          try button(p, b, down: true, clickCount: i)
          pressed.append(b)
          try await step(session)
          try button(p, b, down: false, clickCount: i)
          pressed.removeAll { $0 == b }
          try await step(session)
        }
      case .down(let p, let b):
        try move(p)
        try button(p, b, down: true)
      case .up(let p, let b):
        try button(p, b, down: false)
      case .drag(let path, let b):
        try move(path[0])
        try await step(session)
        try button(path[0], b, down: true)
        pressed.append(b)
        last = path[0]
        for p in path.dropFirst() {
          try await step(session, ms: 8)
          try dragged(p, b)
          last = p
        }
        try await step(session)
        try button(path[path.count - 1], b, down: false)
        pressed.removeAll { $0 == b }
      case .scroll(let p, let dx, let dy):
        try move(p)
        try await step(session)
        try scroll(dx: dx, dy: dy)
      case .key(let code, let mods):
        keys = CUKeys.chord(keyCode: code, modifiers: mods)
      case .type(let text):
        keys = CUKeys.events(forText: text)
      }
      // Each key re-checks the session; a failure releases the keys sent.
      try await sendKeys(keys) { try await step(session, ms: 12) }
      return (max(1, keys.count), damageSeq)
    } catch {
      // Interrupted: release whatever buttons this action holds, where the
      // pointer is, not elsewhere on screen.
      for b in pressed { try? button(last, b, down: false) }
      throw error
    }
  }

  /// A pause between input steps that re-checks the session, so an action
  /// stops as soon as its binding breaks.
  private func step(_ session: String?, ms: Int = 15) async throws {
    try await Task.sleep(for: .milliseconds(ms))
    _ = try check(session)
  }

  private func viewPoint(_ p: CUPoint) -> NSPoint {
    let b = view.bounds
    return NSPoint(
      x: (p.x + 0.5) / Double(width) * b.width,
      y: b.height - (p.y + 0.5) / Double(height) * b.height)
  }

  private func mouseEvent(_ type: NSEvent.EventType, _ p: CUPoint, clickCount: Int = 1) -> NSEvent?
  {
    NSEvent.mouseEvent(
      with: type, location: view.convert(viewPoint(p), to: nil), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: clickCount,
      pressure: [.leftMouseUp, .mouseMoved].contains(type) ? 0 : 1)
  }

  private func move(_ p: CUPoint) throws {
    guard let e = mouseEvent(.mouseMoved, p) else { throw Self.unbuilt("move") }
    view.mouseMoved(with: e)
  }

  /// An event AppKit or Core Graphics would not build: the action fails
  /// rather than reporting input that never reached the guest.
  private static func unbuilt(_ kind: String) -> SandboxError {
    SandboxError("could not build the \(kind) event; nothing was sent for it")
  }

  /// An NSEvent built from a CGEvent that carries the button (never posted):
  /// `NSEvent.mouseEvent` cannot set the button number, and a right click
  /// built that way arrives as a left click.
  private func cgButtonEvent(_ p: CUPoint, _ b: CUButton, down: Bool, clickCount: Int) -> NSEvent? {
    let (type, button): (CGEventType, CGMouseButton) =
      switch b {
      case .left: (down ? .leftMouseDown : .leftMouseUp, .left)
      case .right: (down ? .rightMouseDown : .rightMouseUp, .right)
      case .middle: (down ? .otherMouseDown : .otherMouseUp, .center)
      }
    let inWindow = view.convert(viewPoint(p), to: nil)
    func make(_ at: NSPoint) -> NSEvent? {
      guard
        let cg = CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)
      else { return nil }
      cg.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
      cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
      return NSEvent(cgEvent: cg)
    }
    // NSEvent(cgEvent:) derives locationInWindow inconsistently; correct once.
    guard let first = make(inWindow) else { return nil }
    let dx = inWindow.x - first.locationInWindow.x
    let dy = inWindow.y - first.locationInWindow.y
    if abs(dx) < 0.01 && abs(dy) < 0.01 { return first }
    guard let fixed = make(NSPoint(x: inWindow.x + dx, y: inWindow.y - dy)),
      abs(fixed.locationInWindow.x - inWindow.x) < 0.01,
      abs(fixed.locationInWindow.y - inWindow.y) < 0.01
    else { return nil }
    return fixed
  }

  private func button(_ p: CUPoint, _ b: CUButton, down: Bool, clickCount: Int = 1) throws {
    switch b {
    case .left:
      guard let e = mouseEvent(down ? .leftMouseDown : .leftMouseUp, p, clickCount: clickCount)
      else { throw Self.unbuilt("button") }
      if down { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
    case .right:
      guard let e = cgButtonEvent(p, b, down: down, clickCount: clickCount) else {
        throw Self.unbuilt("button")
      }
      if down { view.rightMouseDown(with: e) } else { view.rightMouseUp(with: e) }
    case .middle:
      guard let e = cgButtonEvent(p, b, down: down, clickCount: clickCount) else {
        throw Self.unbuilt("button")
      }
      if down { view.otherMouseDown(with: e) } else { view.otherMouseUp(with: e) }
    }
  }

  private func dragged(_ p: CUPoint, _ b: CUButton) throws {
    let type: NSEvent.EventType =
      switch b {
      case .left: .leftMouseDragged
      case .right: .rightMouseDragged
      case .middle: .otherMouseDragged
      }
    guard let e = mouseEvent(type, p) else { throw Self.unbuilt("drag") }
    switch b {
    case .left: view.mouseDragged(with: e)
    case .right: view.rightMouseDragged(with: e)
    case .middle: view.otherMouseDragged(with: e)
    }
  }

  private func scroll(dx: Int, dy: Int) throws {
    guard
      let cg = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy),
        wheel2: Int32(dx), wheel3: 0),
      let e = NSEvent(cgEvent: cg)
    else { throw Self.unbuilt("scroll") }
    view.scrollWheel(with: e)
  }

  private func send(_ k: CUKeyEvent) throws {
    let type: NSEvent.EventType =
      switch k.kind {
      case .down: .keyDown
      case .up: .keyUp
      case .flags: .flagsChanged
      }
    guard
      let e = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: k.flags),
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: k.characters, charactersIgnoringModifiers: k.characters,
        isARepeat: false, keyCode: UInt16(k.keyCode))
    else { throw Self.unbuilt("key") }
    switch k.kind {
    case .down: view.keyDown(with: e)
    case .up: view.keyUp(with: e)
    case .flags: view.flagsChanged(with: e)
    }
  }
}

/// Who asked for a frame or an action: a host control-socket client or the
/// guest's computer-use channel.
package enum CUOrigin: Sendable { case host, guest }

/// AppKit pulls a titled window back onto a screen when it is ordered
/// front; this window must stay where it is put.
final class UnconstrainedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
