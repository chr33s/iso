// IsoVZProbe.app — guest-side oracle for the VZ context experiment.
//
//   open -n IsoVZProbe.app --args --token <hex8>
//
// One full-screen window with: the run token and a frame counter (incremented
// every 250 ms) as text and as 4x4 colour barcodes under a calibration row; a
// 10x10 grid (cells A01..J10) with magenta corner markers; a text field; a
// key/modifier display; a drag source with targets D01..D08; a scroll region.
//
// Writes ~/Library/Application Support/IsoVZProbe/state.json atomically on every
// tick and every input event, and appends every input event to events.jsonl
// there. Geometry is in screen pixels with a top-left origin. Everything the
// host trusts comes from these files, not from the host's own return values.

import AppKit

func arg(_ name: String) -> String? {
  let a = CommandLine.arguments
  guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
  return a[i + 1]
}

// Only the harness launches the fixture, always with a token. A launch without
// one (macOS relaunching it at guest login) would race the harness and put a
// stale instance in front, so it exits at once.
guard let tokenArg = arg("--token") else { exit(0) }
let token = tokenArg.lowercased()

let dir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/IsoVZProbe")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let stateURL = dir.appendingPathComponent("state.json")
let eventsURL = dir.appendingPathComponent("events.jsonl")
FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
let eventsFH = try! FileHandle(forWritingTo: eventsURL)

// MARK: - layout (points, top-left origin; the fixture view is flipped)

let cell: CGFloat = 40
let barcodeOrigin = NSPoint(x: 20, y: 20)
let gridRect = NSRect(x: 20, y: 260, width: 800, height: 620)
let textRect = NSRect(x: 860, y: 260, width: 560, height: 32)
let keysRect = NSRect(x: 860, y: 310, width: 560, height: 90)
let dragRect = NSRect(x: 860, y: 420, width: 560, height: 200)
let scrollRect = NSRect(x: 860, y: 640, width: 560, height: 240)
let gridN = 10
/// Drag handle and targets, relative to dragRect.
let handleRect = NSRect(x: 10, y: 80, width: 40, height: 40)
func dragTargetRect(_ i: Int) -> NSRect {
  let w: CGFloat = 115
  let h: CGFloat = 90
  return NSRect(
    x: 70 + CGFloat(i % 4) * (w + 5), y: 5 + CGFloat(i / 4) * (h + 10), width: w, height: h)
}

/// 4-colour palette; each barcode cell encodes 2 bits. No magenta: that is reserved for markers.
let palette: [NSColor] = [
  NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
  NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
  NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
  NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
]
let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

func cellID(row: Int, col: Int) -> String {
  "\(Character(UnicodeScalar(UInt8(65 + row))))\(String(format: "%02d", col + 1))"
}

// MARK: - state

@MainActor
final class Probe {
  var counter = 0
  var lastClickedCell: String?
  var lastClick: [String: Any]?
  var buttonsDown: Set<String> = []
  var keysDown: Set<Int> = []
  var modifiers = 0
  var dragTarget: String?
  var dragSteps = 0
  var scrollY: Double = 0
  var pointerPx: [Double]?
  var eventSeq = 0
  weak var textField: NSTextField?
  var window: NSWindow?

  var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 1 }

  func px(_ r: NSRect) -> [String: Double] {
    let k = Double(scale)
    return [
      "x": Double(r.minX) * k, "y": Double(r.minY) * k, "w": Double(r.width) * k,
      "h": Double(r.height) * k,
    ]
  }

  /// Window-content point (bottom-left origin) -> screen pixels (top-left origin).
  func screenPx(_ e: NSEvent) -> [Double] {
    guard let w = e.window ?? window, let screen = w.screen ?? NSScreen.main else {
      return [-1, -1]
    }
    let s = w.convertPoint(toScreen: e.locationInWindow)
    let k = Double(screen.backingScaleFactor)
    return [Double(s.x) * k, Double(screen.frame.height - s.y) * k]
  }

  func emit(_ obj: [String: Any]) {
    eventSeq += 1
    var o = obj
    o["seq"] = eventSeq
    o["t"] = ProcessInfo.processInfo.systemUptime
    o["counter"] = counter
    var d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    d.append(0x0A)
    eventsFH.write(d)
    writeState()
  }

  func writeState() {
    let screen = NSScreen.main!
    let k = Double(screen.backingScaleFactor)
    var targets: [String: Any] = [:]
    for i in 0..<8 {
      targets[String(format: "D%02d", i + 1)] = px(
        dragTargetRect(i).offsetBy(dx: dragRect.minX, dy: dragRect.minY))
    }
    let st: [String: Any] = [
      "run_token": token, "frame_counter": counter, "pid": Int(getpid()),
      "last_clicked_cell": lastClickedCell ?? NSNull(), "last_click": lastClick ?? NSNull(),
      "buttons_down": buttonsDown.sorted(), "received_text": textField?.stringValue ?? "",
      "keys_down": keysDown.sorted(), "modifiers": modifiers,
      "drag_target": dragTarget ?? NSNull(), "drag_steps": dragSteps, "scroll_y": scrollY,
      "pointer_px": pointerPx ?? NSNull(), "event_seq": eventSeq,
      "screen_px": ["w": Double(screen.frame.width) * k, "h": Double(screen.frame.height) * k],
      "scale": k,
      "layout": [
        "barcode": [
          "x": Double(barcodeOrigin.x) * k, "y": Double(barcodeOrigin.y) * k,
          "cell": Double(cell) * k,
        ],
        "grid": px(gridRect), "grid_n": gridN, "text": px(textRect), "keys": px(keysRect),
        "drag": px(dragRect),
        "drag_handle": px(handleRect.offsetBy(dx: dragRect.minX, dy: dragRect.minY)),
        "drag_targets": targets, "scroll": px(scrollRect),
      ],
    ]
    let d = try! JSONSerialization.data(withJSONObject: st, options: [.sortedKeys])
    try? d.write(to: stateURL, options: .atomic)
  }
}

let probe = MainActor.assumeIsolated { Probe() }

// MARK: - views

class Flipped: NSView {
  override var isFlipped: Bool { true }
}

final class RootView: Flipped {
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for t in trackingAreas { removeTrackingArea(t) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseMoved(with e: NSEvent) {
    probe.pointerPx = probe.screenPx(e)
    probe.emit(["ev": "move", "px": probe.pointerPx!])
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: 0.93, alpha: 1).setFill()
    bounds.fill()
  }
}

final class BarcodeView: Flipped {
  func bits(_ v: UInt32) -> [Int] { (0..<16).map { Int((v >> (UInt32(15 - $0) * 2)) & 3) } }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
    bounds.fill()
    // Row 0: calibration (palette 0..3). Rows 1..4: token at cols 0..3, counter at cols 5..8.
    func fill(_ col: Int, _ row: Int, _ c: NSColor) {
      c.setFill()
      NSRect(
        x: barcodeOrigin.x + CGFloat(col) * cell, y: barcodeOrigin.y + CGFloat(row) * cell,
        width: cell, height: cell
      ).fill()
    }
    for (i, c) in palette.enumerated() { fill(i, 0, c) }
    for (i, b) in bits(UInt32(token, radix: 16) ?? 0).enumerated() {
      fill(i % 4, i / 4 + 1, palette[b])
    }
    for (i, b) in bits(UInt32(truncatingIfNeeded: probe.counter)).enumerated() {
      fill(5 + i % 4, i / 4 + 1, palette[b])
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 40, weight: .bold),
      .foregroundColor: NSColor.black,
    ]
    ("token \(token)" as NSString).draw(at: NSPoint(x: 420, y: 50), withAttributes: attrs)
    ("frame \(probe.counter)" as NSString).draw(at: NSPoint(x: 420, y: 120), withAttributes: attrs)
  }
}

final class GridView: Flipped {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  func cellAt(_ e: NSEvent) -> (Int, Int) {
    let p = convert(e.locationInWindow, from: nil)
    let col = max(0, min(gridN - 1, Int(p.x / (bounds.width / CGFloat(gridN)))))
    let row = max(0, min(gridN - 1, Int(p.y / (bounds.height / CGFloat(gridN)))))
    return (row, col)
  }
  override func draw(_ dirtyRect: NSRect) {
    let w = bounds.width / CGFloat(gridN)
    let h = bounds.height / CGFloat(gridN)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray,
    ]
    for r in 0..<gridN {
      for c in 0..<gridN {
        ((r + c) % 2 == 0 ? NSColor.white : NSColor(white: 0.82, alpha: 1)).setFill()
        let rect = NSRect(x: CGFloat(c) * w, y: CGFloat(r) * h, width: w, height: h)
        rect.fill()
        let id = cellID(row: r, col: c)
        let hit = id == probe.lastClickedCell
        (id as NSString).draw(
          at: NSPoint(x: rect.minX + 6, y: rect.minY + 4),
          withAttributes: hit ? attrs.merging([.foregroundColor: NSColor.black]) { $1 } : attrs)
      }
    }
  }
  func record(_ kind: String, _ button: String, _ e: NSEvent) {
    let (r, c) = cellAt(e)
    let id = cellID(row: r, col: c)
    let px = probe.screenPx(e)
    if kind == "down" {
      probe.buttonsDown.insert(button)
      probe.lastClickedCell = id
      probe.lastClick = ["button": button, "click_count": e.clickCount, "px": px]
    } else {
      probe.buttonsDown.remove(button)
    }
    probe.emit([
      "ev": kind, "button": button, "cell": id, "click_count": e.clickCount, "px": px,
    ])
    needsDisplay = true
  }
  override func mouseDown(with e: NSEvent) { record("down", "left", e) }
  override func mouseUp(with e: NSEvent) { record("up", "left", e) }
  override func rightMouseDown(with e: NSEvent) { record("down", "right", e) }
  override func rightMouseUp(with e: NSEvent) { record("up", "right", e) }
}

final class KeysView: Flipped {
  var lines: [String] = []
  func add(_ s: String) {
    lines.append(s)
    if lines.count > 4 { lines.removeFirst() }
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(srgbRed: 0.9, green: 0.95, blue: 1, alpha: 1).setFill()
    bounds.fill()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
      .foregroundColor: NSColor.black,
    ]
    for (i, l) in lines.enumerated() {
      (l as NSString).draw(at: NSPoint(x: 8, y: 4 + CGFloat(i) * 20), withAttributes: attrs)
    }
  }
}

final class DragView: Flipped {
  var dragging = false
  var current: NSPoint?
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  func target(at p: NSPoint) -> String? {
    (0..<8).first { dragTargetRect($0).contains(p) }.map { String(format: "D%02d", $0 + 1) }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1).setFill()
    bounds.fill()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black,
    ]
    for i in 0..<8 {
      let r = dragTargetRect(i)
      let id = String(format: "D%02d", i + 1)
      (id == probe.dragTarget ? NSColor.systemGreen : NSColor.white).setFill()
      r.fill()
      (id as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 4), withAttributes: attrs)
    }
    NSColor.systemOrange.setFill()
    (current.map { NSRect(x: $0.x - 20, y: $0.y - 20, width: 40, height: 40) } ?? handleRect).fill()
  }
  override func mouseDown(with e: NSEvent) {
    let p = convert(e.locationInWindow, from: nil)
    dragging = handleRect.contains(p)
    probe.dragSteps = 0
    probe.emit(["ev": "drag_down", "on_handle": dragging, "px": probe.screenPx(e)])
  }
  override func mouseDragged(with e: NSEvent) {
    guard dragging else { return }
    probe.dragSteps += 1
    current = convert(e.locationInWindow, from: nil)
    needsDisplay = true
  }
  override func mouseUp(with e: NSEvent) {
    let p = convert(e.locationInWindow, from: nil)
    if dragging { probe.dragTarget = target(at: p) }
    probe.emit([
      "ev": "drag_up", "on_handle": dragging,
      "target": (dragging ? target(at: p) : nil) ?? NSNull(),
      "steps": probe.dragSteps, "px": probe.screenPx(e),
    ])
    dragging = false
    current = nil
    needsDisplay = true
  }
}

final class StripesView: Flipped {
  override func draw(_ dirtyRect: NSRect) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black,
    ]
    for i in 0..<100 {
      (i % 2 == 0 ? NSColor.white : NSColor(srgbRed: 0.85, green: 0.9, blue: 0.85, alpha: 1))
        .setFill()
      let r = NSRect(x: 0, y: CGFloat(i) * 40, width: bounds.width, height: 40)
      r.fill()
      ("row \(i)" as NSString).draw(at: NSPoint(x: 8, y: r.minY + 10), withAttributes: attrs)
    }
  }
}

final class MarkerView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    magenta.setFill()
    bounds.fill()
  }
}

final class ShieldWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

// MARK: - app

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  let barcode = BarcodeView()
  let keys = KeysView()

  func applicationDidFinishLaunching(_ n: Notification) {
    launch()
  }

  func launch() {
    let screen = NSScreen.main!.frame
    window = ShieldWindow(
      contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
    window.acceptsMouseMovedEvents = true
    let root = RootView(frame: NSRect(origin: .zero, size: screen.size))
    window.contentView = root
    probe.window = window

    barcode.frame = NSRect(x: 0, y: 0, width: screen.width, height: 240)
    root.addSubview(barcode)
    let grid = GridView(frame: gridRect)
    root.addSubview(grid)
    let text = NSTextField(frame: textRect)
    text.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    text.placeholderString = "text"
    root.addSubview(text)
    probe.textField = text
    keys.frame = keysRect
    root.addSubview(keys)
    root.addSubview(DragView(frame: dragRect))
    let scroll = NSScrollView(frame: scrollRect)
    let doc = StripesView(frame: NSRect(x: 0, y: 0, width: scrollRect.width - 20, height: 4000))
    scroll.documentView = doc
    scroll.hasVerticalScroller = true
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        probe.scrollY = Double(scroll.contentView.bounds.origin.y)
        probe.writeState()
      }
    }
    root.addSubview(scroll)
    for corner in [
      NSPoint(x: gridRect.minX, y: gridRect.minY), NSPoint(x: gridRect.maxX, y: gridRect.minY),
      NSPoint(x: gridRect.minX, y: gridRect.maxY), NSPoint(x: gridRect.maxX, y: gridRect.maxY),
    ] {
      root.addSubview(
        MarkerView(frame: NSRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)))
    }

    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(text)

    // One source for every key event, including keyUp while Command is held
    // (AppKit does not route those to views). Command-modified key-downs are
    // logged and swallowed so Cmd-Q / Cmd-S / Cmd-W cannot end the fixture.
    let keys = self.keys
    NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .scrollWheel]) {
      e in
      nonisolated(unsafe) let e = e
      let swallow = MainActor.assumeIsolated { () -> Bool in
        let mask = NSEvent.ModifierFlags.deviceIndependentFlagsMask
        let flags = Int(e.modifierFlags.intersection(mask).rawValue)
        switch e.type {
        case .scrollWheel:
          probe.emit([
            "ev": "scroll", "dy": Double(e.scrollingDeltaY), "dx": Double(e.scrollingDeltaX),
            "precise": e.hasPreciseScrollingDeltas,
          ])
          return false
        case .flagsChanged:
          probe.modifiers = flags
          keys.add("flags \(e.keyCode) 0x\(String(flags, radix: 16))")
          probe.emit(["ev": "flags", "keyCode": Int(e.keyCode), "flags": flags])
          return false
        default:
          let down = e.type == .keyDown
          if down {
            probe.keysDown.insert(Int(e.keyCode))
          } else {
            probe.keysDown.remove(Int(e.keyCode))
          }
          keys.add(
            "\(down ? "down" : "up") \(e.keyCode) \(e.characters ?? "") 0x\(String(flags, radix: 16))"
          )
          probe.emit([
            "ev": down ? "down" : "up", "keyCode": Int(e.keyCode), "chars": e.characters ?? "",
            "flags": flags, "repeat": down && e.isARepeat,
          ])
          return down && e.modifierFlags.contains(.command)
        }
      }
      return swallow ? nil : e
    }
    NSApp.activate()
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [barcode] _ in
      MainActor.assumeIsolated {
        probe.counter += 1
        barcode.needsDisplay = true
        probe.writeState()
      }
    }
    probe.emit(["ev": "ready", "token": token])
  }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { Delegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
// A login-time relaunch would race the harness and leave a stale instance (default token) in front.
app.disableRelaunchOnLogin()
app.run()
