import AppKit
import CryptoKit
import Foundation
import Virtualization

/// `vm-view`: Phase 3/4 owner (spec §11–§14). The VM runs on its own serial
/// queue; a `VZVirtualMachineView` on the main actor is attached through
/// `VZVirtualMachineViewAdaptor`, with `automaticallyReconfiguresDisplay = false`,
/// in one of the V0–V8 window topologies.
///
/// Control: JSON lines on a Unix socket (mode 0600):
///   state | frame{path,method:cache|layer} | session
///   move{session,x,y} | click{session,x,y,button,count} | button{session,x,y,button,down}
///   drag{session,x0,y0,x1,y1,steps} | scroll{session,x,y,dy,dx} | key{session,events}
///   hostinput | stop | restart_vm | quit
/// Coordinates are framebuffer pixels, origin top-left. Input is synthesized
/// NSEvents handed straight to the view's responder methods: nothing is posted
/// to the host event system.
enum Topology: String, CaseIterable {
  case v0 = "V0"
  case v1 = "V1"
  case v2 = "V2"
  case v3 = "V3"
  case v4 = "V4"
  case v5 = "V5"
  case v6 = "V6"
  case v7 = "V7"
  case v8 = "V8"

  var summary: String {
    switch self {
    case .v0: "visible window, key/focused"
    case .v1: "visible window, not key"
    case .v2: "visible window, fully occluded"
    case .v3: "window on an inactive Space (operator moves it)"
    case .v4: "minimized window"
    case .v5: "hidden / ordered-out window"
    case .v6: "fully offscreen window"
    case .v7: "view retained, not in any window"
    case .v8: "no view"
    }
  }
}

/// AppKit pulls a titled window back onto a screen when it is ordered front
/// (`constrainFrameRect`). V6 needs the window to stay where it is placed.
final class PlaceableWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

struct Refusal: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}

struct Session {
  let id: String
  let vmInstance: String
  let bootID: String
  let generation: Int
}

@MainActor
final class ViewOwner {
  let bundle: VMBundle
  let log: EventLog
  let queue = DispatchQueue(label: "dev.iso.vzprobe.vm")
  let boot: BootIdentity
  var host: VMHost?
  var adaptor: VZVirtualMachineViewAdaptor?
  var view: VZVirtualMachineView?
  var window: NSWindow?
  var cover: NSWindow?
  var topology: Topology
  var sessions: [String: Session] = [:]
  var restarting = false
  var frameSeq = 0
  var appKeyEvents = 0  // key events that reached this app's own event queue (must stay 0)
  let ciContext = CIContext()
  let cpus: Int
  let memoryGiB: UInt64

  init(bundle: VMBundle, log: EventLog, topology: Topology, cpus: Int, memoryGiB: UInt64) {
    self.bundle = bundle
    self.log = log
    self.topology = topology
    self.cpus = cpus
    self.memoryGiB = memoryGiB
    boot = BootIdentity(log: log, key: bundle.helperKey)
  }

  var vmState: String { host?.state ?? "none" }
  var vmInstance: String { host?.instance ?? "none" }

  /// A new VM (new `instance`) on the same bundle; the view switches to it.
  func makeHost() -> VMHost? {
    do {
      let cfg = try makeConfiguration(bundle, cpus: cpus, memoryGiB: memoryGiB)
      try cfg.validate()
      log.emit("vm_validation", ["result": "pass"])
      let h = VMHost(configuration: cfg, queue: queue, log: log, boot: boot)
      host = h
      adaptor = h.makeAdaptor()
      view?.adaptor = adaptor
      return h
    } catch {
      log.emit("vm_validation", ["result": "fail", "error": errorInfo(error)])
      return nil
    }
  }

  func start() {
    guard let h = makeHost() else { exit(1) }
    applyTopology(topology)
    NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
      MainActor.assumeIsolated { self?.appKeyEvents += 1 }
      return e
    }
    Task {
      let r = await h.start()
      if r["result"] as? String != "pass" { exit(1) }
    }
  }

  /// Stop this VM and boot a new one in the same owner: sessions bound to the old
  /// instance must be refused ("vm instance changed").
  func restartVM() async -> [String: Any] {
    guard !restarting else { return ["ok": false, "error": "restart already in progress"] }
    guard let old = host, old.state == "running" else {
      return ["ok": false, "error": "vm not running (\(vmState))"]
    }
    restarting = true
    defer { restarting = false }
    let stop = await old.stop()
    // Never boot a second VM on the same disk while the first may still be up.
    guard old.state == "stopped" else {
      return ["ok": false, "error": "old vm did not stop (\(old.state))", "stop": stop]
    }
    old.teardown()
    guard let h = makeHost() else { return ["ok": false, "error": "validation", "stop": stop] }
    let started = await h.start()
    return [
      "ok": started["result"] as? String == "pass", "stop": stop, "start": started,
      "old_instance": old.instance, "new_instance": h.instance,
    ]
  }

  // MARK: topology

  func makeView() -> VZVirtualMachineView {
    if let view { return view }
    let v = VZVirtualMachineView(
      frame: NSRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
    v.adaptor = adaptor
    v.automaticallyReconfiguresDisplay = false
    v.capturesSystemKeys = true
    view = v
    return v
  }

  func makeWindow(styleMask: NSWindow.StyleMask = [.titled]) -> NSWindow {
    if let window { return window }
    let w = PlaceableWindow(
      contentRect: NSRect(x: 80, y: 80, width: displayWidth, height: displayHeight),
      styleMask: styleMask,
      backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.title = "vz-context-probe"
    w.contentView = makeView()
    window = w
    return w
  }

  func applyTopology(_ t: Topology) {
    cover?.orderOut(nil)
    cover = nil
    if let window, window.isMiniaturized { window.deminiaturize(nil) }
    switch t {
    case .v0:
      NSApp.setActivationPolicy(.regular)
      let w = makeWindow(styleMask: [.titled, .miniaturizable])
      w.setFrameOrigin(NSPoint(x: 80, y: 80))
      w.makeKeyAndOrderFront(nil)
      NSApp.activate()
    case .v1, .v2, .v3, .v4:
      NSApp.setActivationPolicy(.accessory)
      let w = makeWindow(styleMask: [.titled, .miniaturizable])
      w.setFrameOrigin(NSPoint(x: 80, y: 80))
      w.orderFrontRegardless()
      if t == .v2 {
        let c = NSWindow(
          contentRect: w.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        c.isReleasedWhenClosed = false
        c.backgroundColor = .darkGray
        c.isOpaque = true
        c.level = NSWindow.Level(rawValue: w.level.rawValue + 1)
        c.orderFrontRegardless()
        cover = c
      }
      if t == .v4 { w.miniaturize(nil) }
    case .v5:
      NSApp.setActivationPolicy(.prohibited)
      makeWindow().orderOut(nil)
    case .v6:
      NSApp.setActivationPolicy(.prohibited)
      let w = makeWindow()
      w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
      w.orderFrontRegardless()
    case .v7:
      NSApp.setActivationPolicy(.prohibited)
      let v = makeView()
      window?.contentView = nil
      window?.orderOut(nil)
      window = nil
      v.removeFromSuperview()
    case .v8:
      NSApp.setActivationPolicy(.prohibited)
      window?.contentView = nil
      window?.orderOut(nil)
      window = nil
      view?.adaptor = nil
      view = nil
    }
    topology = t
    log.emit("topology", ["topology": t.rawValue, "summary": t.summary, "window": windowInfo()])
  }

  func windowInfo() -> [String: Any] {
    guard let w = window else { return ["present": false, "view_present": view != nil] }
    return [
      "present": true, "view_present": view != nil, "view_in_window": view?.window === w,
      "visible": w.isVisible, "key": w.isKeyWindow, "on_active_space": w.isOnActiveSpace,
      "miniaturized": w.isMiniaturized, "occlusion_visible": w.occlusionState.contains(.visible),
      "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height],
      "window_number": w.windowNumber, "on_screen": w.screen != nil,
      "occluded_by_cover": cover != nil,
    ]
  }

  // MARK: sessions

  func newSession() throws -> Session {
    guard vmState == "running" else { throw Refusal("vm not running (\(vmState))") }
    guard let bootID = boot.bootID else {
      throw Refusal("no boot identity: guest helper not connected")
    }
    let s = Session(
      id: UUID().uuidString, vmInstance: vmInstance, bootID: bootID, generation: boot.generation)
    sessions[s.id] = s
    return s
  }

  /// Validates session binding only. Topology is deliberately not a refusal
  /// here: the experiment measures what happens to input in each topology.
  func check(_ id: String?) throws {
    guard let id, let s = sessions[id] else { throw Refusal("unknown session") }
    guard vmState == "running" else { throw Refusal("vm not running (\(vmState))") }
    guard s.vmInstance == vmInstance else { throw Refusal("vm instance changed") }
    guard boot.generation == s.generation, boot.bootID == s.bootID else {
      sessions[id] = nil
      throw Refusal(
        "boot identity changed (session bound to \(s.bootID), now \(boot.bootID ?? "none"))")
    }
    guard view != nil else { throw Refusal("no view (V8): no input path") }
  }

  // MARK: input

  func viewPoint(_ x: Double, _ y: Double) -> NSPoint {
    let b = view!.bounds
    return NSPoint(
      x: (x + 0.5) / Double(displayWidth) * b.width,
      y: b.height - (y + 0.5) / Double(displayHeight) * b.height)
  }

  func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clickCount: Int = 1) -> NSEvent {
    let v = view!
    return NSEvent.mouseEvent(
      with: type, location: v.convert(p, to: nil), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 0, clickCount: clickCount,
      pressure: [.leftMouseUp, .rightMouseUp, .mouseMoved].contains(type) ? 0 : 1)!
  }

  func pause(_ ms: Int = 15) async { try? await Task.sleep(for: .milliseconds(ms)) }

  func move(_ x: Double, _ y: Double) {
    view!.mouseMoved(with: mouse(.mouseMoved, viewPoint(x, y)))
  }

  /// How synthesized mouse-button events are built. `nsevent`: `NSEvent.mouseEvent`,
  /// which cannot set `buttonNumber` (always 0). `cgevent`: an NSEvent made from a
  /// CGEvent that carries the button; the CGEvent is never posted.
  var buttonSource = "nsevent"

  func cgMouse(_ type: CGEventType, _ p: NSPoint, button: CGMouseButton, clickCount: Int)
    -> NSEvent?
  {
    let v = view!
    let inWindow = v.convert(p, to: nil)
    var global = inWindow
    if let w = window {
      let s = w.convertPoint(toScreen: inWindow)
      global = NSPoint(x: s.x, y: (NSScreen.screens.first?.frame.height ?? 0) - s.y)
    }
    func make(_ at: NSPoint) -> NSEvent? {
      guard
        let cg = CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)
      else { return nil }
      cg.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
      if let w = window {
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
      }
      return NSEvent(cgEvent: cg)
    }
    // NSEvent(cgEvent:) does not derive locationInWindow the same way in every
    // topology. Check it and correct the CG location once (CG y grows downward).
    guard let first = make(global) else { return nil }
    let dx = inWindow.x - first.locationInWindow.x
    let dy = inWindow.y - first.locationInWindow.y
    if abs(dx) < 0.01 && abs(dy) < 0.01 { return first }
    guard let fixed = make(NSPoint(x: global.x + dx, y: global.y - dy)),
      abs(fixed.locationInWindow.x - inWindow.x) < 0.01,
      abs(fixed.locationInWindow.y - inWindow.y) < 0.01
    else { return nil }
    return fixed
  }

  func button(_ x: Double, _ y: Double, button: String, down: Bool, clickCount: Int = 1) {
    let v = view!
    let p = viewPoint(x, y)
    if buttonSource == "cgevent" {
      let right = button == "right"
      let type: CGEventType =
        right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
      guard let e = cgMouse(type, p, button: right ? .right : .left, clickCount: clickCount) else {
        return
      }
      switch (right, down) {
      case (true, true): v.rightMouseDown(with: e)
      case (true, false): v.rightMouseUp(with: e)
      case (false, true): v.mouseDown(with: e)
      case (false, false): v.mouseUp(with: e)
      }
      return
    }
    switch (button, down) {
    case ("right", true): v.rightMouseDown(with: mouse(.rightMouseDown, p, clickCount: clickCount))
    case ("right", false): v.rightMouseUp(with: mouse(.rightMouseUp, p, clickCount: clickCount))
    case (_, true): v.mouseDown(with: mouse(.leftMouseDown, p, clickCount: clickCount))
    case (_, false): v.mouseUp(with: mouse(.leftMouseUp, p, clickCount: clickCount))
    }
  }

  func click(_ x: Double, _ y: Double, button b: String, count: Int) async {
    move(x, y)
    await pause()
    for i in 1...max(1, count) {
      button(x, y, button: b, down: true, clickCount: i)
      await pause()
      button(x, y, button: b, down: false, clickCount: i)
      await pause()
    }
  }

  func drag(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, steps: Int) async {
    move(x0, y0)
    await pause()
    button(x0, y0, button: "left", down: true)
    await pause(30)
    let n = max(1, steps)
    for i in 1...n {
      let f = Double(i) / Double(n)
      view!.mouseDragged(
        with: mouse(.leftMouseDragged, viewPoint(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f)))
      await pause(8)
    }
    await pause(30)
    button(x1, y1, button: "left", down: false)
  }

  func scroll(_ x: Double, _ y: Double, dy: Int32, dx: Int32) async {
    move(x, y)
    await pause()
    guard
      let cg = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx,
        wheel3: 0),
      let e = NSEvent(cgEvent: cg)
    else { return }
    view!.scrollWheel(with: e)
  }

  func key(_ events: [[String: Any]]) async {
    let v = view!
    for e in events {
      let type = e["type"] as? String ?? "down"
      let code = UInt16(e["keyCode"] as? Int ?? 0)
      let chars = e["chars"] as? String ?? ""
      let flags = NSEvent.ModifierFlags(rawValue: UInt(e["flags"] as? Int ?? 0))
      let t: NSEvent.EventType = type == "up" ? .keyUp : type == "flags" ? .flagsChanged : .keyDown
      let ev = NSEvent.keyEvent(
        with: t, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil,
        characters: t == .flagsChanged ? "" : chars,
        charactersIgnoringModifiers: t == .flagsChanged ? "" : chars, isARepeat: false,
        keyCode: code)!
      switch t {
      case .flagsChanged: v.flagsChanged(with: ev)
      case .keyUp: v.keyUp(with: ev)
      default: v.keyDown(with: ev)
      }
      await pause(12)
    }
  }

  // MARK: host focus / leak oracle

  func hostInput() -> [String: Any] {
    let p = NSEvent.mouseLocation
    let front = NSWorkspace.shared.frontmostApplication
    var frontWindow: [String: Any] = [:]
    if let list = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]],
      let w = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 })
    {
      frontWindow = [
        "owner_pid": w[kCGWindowOwnerPID as String] ?? NSNull(),
        "owner_name": w[kCGWindowOwnerName as String] ?? NSNull(),
        "window_number": w[kCGWindowNumber as String] ?? NSNull(),
      ]
    }
    return [
      "cursor": [p.x, p.y], "modifier_flags": Int(NSEvent.modifierFlags.rawValue),
      "pressed_mouse_buttons": NSEvent.pressedMouseButtons,
      "frontmost_bundle": front?.bundleIdentifier ?? NSNull(),
      "frontmost_pid": Int(front?.processIdentifier ?? 0),
      "front_window": frontWindow, "probe_active": NSApp.isActive,
      "probe_window_key": window?.isKeyWindow ?? false,
      "probe_app_key_events": appKeyEvents, "console_locked": consoleLocked() ?? NSNull(),
    ]
  }

  // MARK: frames (O1)

  func frame(to path: String, method: String) throws -> [String: Any] {
    guard let view else { throw Refusal("no view (V8): nothing to capture") }
    let image: CGImage
    switch method {
    case "layer": image = try captureLayer(view)
    default: image = try captureCache(view)
    }
    guard let rep = Optional(NSBitmapImageRep(cgImage: image)),
      let png = rep.representation(using: .png, properties: [:])
    else { throw Refusal("png encode") }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    frameSeq += 1
    return [
      "seq": frameSeq, "method": method, "path": path, "image_width": image.width,
      "image_height": image.height,
      "display_width": displayWidth, "display_height": displayHeight,
      "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
      "channel_range": channelRange(image) ?? NSNull(), "boot_id": boot.bootID ?? NSNull(),
      "vm_instance": vmInstance, "t": Date().timeIntervalSince1970, "window": windowInfo(),
    ]
  }

  func captureCache(_ v: VZVirtualMachineView) throws -> CGImage {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
      throw Refusal("no bitmap rep")
    }
    v.cacheDisplay(in: v.bounds, to: rep)
    guard let img = rep.cgImage else { throw Refusal("no cgImage") }
    return img
  }

  /// Walks the view's private layer tree for the framebuffer IOSurface. Not API;
  /// recorded as a diagnostic alongside the public `cacheDisplay` path.
  func captureLayer(_ v: VZVirtualMachineView) throws -> CGImage {
    guard let root = v.layer else { throw Refusal("view has no layer") }
    var found: CGImage?
    func walk(_ l: CALayer) {
      if found != nil { return }
      if let c = l.contents {
        let cf = c as CFTypeRef
        if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
          let ci = CIImage(ioSurface: unsafeDowncast(cf, to: IOSurfaceRef.self))
          found = ciContext.createCGImage(ci, from: ci.extent)
          return
        }
        if CFGetTypeID(cf) == CGImage.typeID {
          found = (cf as! CGImage)
          return
        }
      }
      for s in l.sublayers ?? [] { walk(s) }
    }
    walk(root)
    guard let found else { throw Refusal("no readable layer contents") }
    return found
  }
}

/// Largest per-channel spread over a 64x40 downsample; ≤ 3 means a uniform (blank) frame.
func channelRange(_ image: CGImage) -> Int? {
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

// MARK: - control

@MainActor
func handleView(_ o: ViewOwner, _ req: [String: Any]) async -> [String: Any] {
  let op = req["op"] as? String ?? ""
  func num(_ k: String) -> Double { (req[k] as? Double) ?? (req[k] as? Int).map(Double.init) ?? -1 }
  func inRange(_ x: Double, _ y: Double) throws {
    guard x >= 0, y >= 0, x < Double(displayWidth), y < Double(displayHeight) else {
      throw Refusal("coordinate out of range")
    }
  }
  do {
    switch op {
    case "state":
      return [
        "ok": true, "vm_state": o.vmState, "vm_instance": o.vmInstance,
        "boot_id": o.boot.bootID ?? NSNull(), "boot_generation": o.boot.generation,
        "hello": o.boot.hello ?? NSNull(), "topology": o.topology.rawValue,
        "window": o.windowInfo(),
        "display": [displayWidth, displayHeight], "pid": Int(getpid()),
      ]
    case "frame":
      var r = try o.frame(
        to: req["path"] as? String ?? "/dev/null", method: req["method"] as? String ?? "cache")
      r["ok"] = true
      return r
    case "session":
      let s = try o.newSession()
      return ["ok": true, "session": s.id, "boot_id": s.bootID, "vm_instance": s.vmInstance]
    case "move":
      try o.check(req["session"] as? String)
      try inRange(num("x"), num("y"))
      o.move(num("x"), num("y"))
      return ["ok": true]
    case "click":
      try o.check(req["session"] as? String)
      try inRange(num("x"), num("y"))
      o.buttonSource = req["source"] as? String ?? "nsevent"
      defer { o.buttonSource = "nsevent" }
      await o.click(
        num("x"), num("y"), button: req["button"] as? String ?? "left",
        count: req["count"] as? Int ?? 1)
      return ["ok": true]
    case "button":
      try o.check(req["session"] as? String)
      try inRange(num("x"), num("y"))
      o.button(
        num("x"), num("y"), button: req["button"] as? String ?? "left",
        down: req["down"] as? Bool ?? true)
      return ["ok": true]
    case "drag":
      try o.check(req["session"] as? String)
      try inRange(num("x0"), num("y0"))
      try inRange(num("x1"), num("y1"))
      await o.drag(num("x0"), num("y0"), num("x1"), num("y1"), steps: req["steps"] as? Int ?? 20)
      return ["ok": true]
    case "scroll":
      try o.check(req["session"] as? String)
      try inRange(num("x"), num("y"))
      await o.scroll(
        num("x"), num("y"), dy: Int32(req["dy"] as? Int ?? 0), dx: Int32(req["dx"] as? Int ?? 0))
      return ["ok": true]
    case "key":
      try o.check(req["session"] as? String)
      await o.key(req["events"] as? [[String: Any]] ?? [])
      return ["ok": true]
    case "hostinput":
      return o.hostInput().merging(["ok": true]) { $1 }
    case "stop":
      guard let h = o.host else { return ["ok": false, "error": "no vm"] }
      let r = await h.stop()
      return r.merging(["ok": r["graceful_stop"] as? Bool == true, "vm_state": h.state]) { $1 }
    case "restart_vm":
      return await o.restartVM()
    case "quit":
      o.log.emit("owner_exit", ["status": 0])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
      return ["ok": true]
    default:
      throw Refusal("unknown op \(op)")
    }
  } catch {
    return ["ok": false, "error": "\(error)"]
  }
}

@MainActor
func handleViewLine(_ o: ViewOwner, _ line: Data) async -> Data {
  let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
  return jsonLine(await handleView(o, req))
}

func serveControl(
  at path: String, handler: @escaping @Sendable (Data) async -> Data
) {
  guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
    die("socket path too long: \(path)")
  }
  unlink(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &addr.sun_path) { p in
    _ = path.utf8CString.withUnsafeBytes {
      memcpy(p.baseAddress!, $0.baseAddress!, min($0.count, p.count - 1))
    }
  }
  let len = socklen_t(MemoryLayout<sockaddr_un>.size)
  let old = umask(0o077)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
  }
  umask(old)
  guard rc == 0 else { die("bind \(path): \(errno)") }
  listen(fd, 4)
  Thread.detachNewThread {
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 { continue }
      Thread.detachNewThread {
        // read(2), not FileHandle.availableData, which raises on ECONNRESET.
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while true {
          let n = read(c, &raw, raw.count)
          if n <= 0 { break }
          buf.append(contentsOf: raw[0..<n])
          while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[..<nl]
            buf = Data(buf[(nl + 1)...])
            let req = Data(line)
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out = Data()
            Task {
              out = await handler(req)
              sem.signal()
            }
            sem.wait()
            out.withUnsafeBytes { _ = write(c, $0.baseAddress!, $0.count) }
          }
        }
        close(c)
      }
    }
  }
}

func runView(_ args: Arguments) -> Never {
  guard let path = args.positional.first else {
    die("usage: vm-view <bundle> --topology V0..V8 [--socket S]")
  }
  guard let topology = Topology(rawValue: args.value("--topology") ?? "V0") else {
    die("bad --topology")
  }
  let runDir = args.value("--run-dir")
  if let runDir {
    try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
  }
  let log = EventLog(
    path: runDir.map { $0 + "/vm-events.jsonl" },
    runID: args.value("--run-id") ?? UUID().uuidString,
    context: args.value("--context") ?? "unknown")
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let ctx = hostContext(windowServer: true)
    if let runDir { writeJSON(ctx, to: runDir + "/context.json") }
    log.emit("owner_start", ["mode": "vm-view", "argv": args.all, "host_context": ctx])
    let owner = ViewOwner(
      bundle: VMBundle(root: URL(fileURLWithPath: path)), log: log, topology: topology,
      cpus: args.int("--cpus", 4), memoryGiB: UInt64(args.int("--memory-gib", 8)))
    owner.start()
    let sock = args.value("--socket") ?? "/tmp/vzprobe-\(getuid()).sock"
    serveControl(at: sock) { req in await handleViewLine(owner, req) }
    log.emit("control_socket", ["path": sock])
    app.run()
  }
  exit(0)
}
