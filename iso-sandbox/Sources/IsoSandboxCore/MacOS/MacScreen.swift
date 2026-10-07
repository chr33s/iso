import AppKit
import CryptoKit
import Foundation
import Virtualization

/// The owner's computer-use surface (Gates C–H): a `VZVirtualMachineView` in
/// an ordered-out window (V5), sessions bound to the VM and guest boot,
/// frames in framebuffer pixels, and input synthesized into the view. Nothing
/// is posted to the host event system and the owner never activates.
@MainActor
package final class MacScreen {
  package let width = MacDisplay.width
  package let height = MacDisplay.height
  private let view: VZVirtualMachineView
  private let window: NSWindow
  private var table = CUSessions()
  /// One action at a time: actions suspend between steps, and two in flight
  /// would interleave on the single pointer and keyboard.
  private var acting = false
  /// Supplies the current binding; nil while the guest helper is not connected.
  private let current: () -> CUBinding?

  package init(adaptor: VZVirtualMachineViewAdaptor, current: @escaping () -> CUBinding?) {
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
  }

  // MARK: sessions

  package func newSession() throws -> (String, CUBinding) {
    try table.open(current: current())
  }

  private func check(_ id: String?) throws -> CUBinding {
    let bound = try table.check(id, current: current())
    // A view outside a window renders nothing and drops pointer input.
    guard view.window != nil else { throw SandboxError("view has no window") }
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
  }

  package func frame(session: String?) throws -> Frame {
    let bound = try check(session)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw SandboxError("no bitmap for the view")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let source = rep.cgImage else { throw SandboxError("no image from the view") }
    // Framebuffer pixels whatever the window's backing scale (Gate F).
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw SandboxError("no drawing context") }
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = ctx.makeImage() else { throw SandboxError("no frame image") }
    // A uniform frame is how a missing framebuffer looks: refuse it.
    if let range = Self.channelRange(image), range <= 3 {
      throw SandboxError("blank frame (channel range \(range)): framebuffer not observed")
    }
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw SandboxError("png encoding failed") }
    let (id, seq) = table.recordFrame(bound)
    return Frame(
      id: id, seq: seq, png: png,
      sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), binding: bound,
      timestamp: Date())
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
  /// button and key the action pressed.
  package func act(session: String?, request: CUActionRequest, basedOnFrame: String?) async throws
    -> Int
  {
    let bound = try check(session)
    if let basedOnFrame { try table.requireFrame(basedOnFrame, from: bound) }
    let action = try request.validated(width: width, height: height)
    guard !acting else { throw SandboxError("another action is in progress") }
    acting = true
    defer { acting = false }
    var pressed: [CUButton] = []
    var last = CUPoint(x: 0, y: 0)
    var keys: [CUKeyEvent] = []
    var sentKeys = 0
    do {
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
      for e in keys {
        try send(e)
        sentKeys += 1
        try await step(session, ms: 12)
      }
      return max(1, keys.count)
    } catch {
      // Interrupted: release whatever this action holds.
      // Released where the pointer is, not elsewhere on screen.
      for b in pressed { try? button(last, b, down: false) }
      for e in CUKeys.releases(after: keys.prefix(sentKeys)) { try? send(e) }
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

/// AppKit pulls a titled window back onto a screen when it is ordered
/// front; this window must stay where it is put.
final class UnconstrainedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
