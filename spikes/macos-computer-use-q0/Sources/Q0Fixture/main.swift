// q0fixture — guest-side oracle for the Q0 spike.
//
//   Q0Fixture.app --args render <token-hex8>   token text + color barcode at a fixed window
//   Q0Fixture.app --args grid                  full-screen 10x10 target grid, logs hits
//   Q0Fixture.app --args keys                  key logger, logs every key/flags event
//
// Writes ~/q0/state.json (geometry in screen pixels, origin top-left) and appends
// ~/q0/events.jsonl. Everything the host oracle trusts comes from here, not from
// the host's own API return values.

import AppKit

let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("q0")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let eventsURL = out.appendingPathComponent("events.jsonl")
FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
let eventsFH = try! FileHandle(forWritingTo: eventsURL)
var eventSeq = 0

@MainActor
func emit(_ obj: [String: Any]) {
  eventSeq += 1
  var o = obj
  o["seq"] = eventSeq
  o["t"] = ProcessInfo.processInfo.systemUptime
  var d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
  d.append(0x0A)
  eventsFH.write(d)
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "render"
let token = args.count > 2 ? args[2] : "00000000"

/// 4-color palette; each barcode cell encodes 2 bits.
let palette: [NSColor] = [
  NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
  NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
  NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
  NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
]
let cell: CGFloat = 48

final class KeyWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// screen point rect (bottom-left origin) -> pixel rect (top-left origin) on the main screen
func pixelRect(_ r: NSRect) -> [String: Double] {
  let s = NSScreen.main!
  let k = s.backingScaleFactor
  return [
    "x": Double(r.minX * k), "y": Double((s.frame.height - r.maxY) * k),
    "w": Double(r.width * k), "h": Double(r.height * k),
  ]
}

func writeState(_ extra: [String: Any]) {
  let s = NSScreen.main!
  var st: [String: Any] = [
    "mode": mode, "token": token, "pid": getpid(),
    "screen_points": ["w": s.frame.width, "h": s.frame.height],
    "scale": s.backingScaleFactor,
  ]
  for (k, v) in extra { st[k] = v }
  let d = try! JSONSerialization.data(withJSONObject: st, options: [.sortedKeys, .prettyPrinted])
  try! d.write(to: out.appendingPathComponent("state.json"), options: .atomic)
}

// MARK: render

final class RenderView: NSView {
  var bits: [Int] {
    let v = UInt32(token, radix: 16) ?? 0
    return (0..<16).map { Int((v >> (UInt32(15 - $0) * 2)) & 3) }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
    bounds.fill()
    // row 0: calibration (palette 0..3), rows 1..4: 16 data cells as 4x4
    for (i, c) in palette.enumerated() {
      c.setFill()
      NSRect(x: CGFloat(i) * cell, y: bounds.height - cell, width: cell, height: cell).fill()
    }
    for (i, b) in bits.enumerated() {
      palette[b].setFill()
      let col = i % 4
      let row = i / 4 + 1
      NSRect(
        x: CGFloat(col) * cell, y: bounds.height - CGFloat(row + 1) * cell, width: cell,
        height: cell
      ).fill()
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold),
      .foregroundColor: NSColor.black,
    ]
    (token.uppercased() as NSString).draw(
      at: NSPoint(x: 4 * cell + 40, y: bounds.height - 3 * cell), withAttributes: attrs)
  }
}

// MARK: grid

final class GridView: NSView {
  let n = 10
  var hits = 0
  func cellAt(_ p: NSPoint) -> (Int, Int) {
    let col = min(n - 1, Int(p.x / (bounds.width / CGFloat(n))))
    let rowFromBottom = min(n - 1, Int(p.y / (bounds.height / CGFloat(n))))
    return (col, n - 1 - rowFromBottom)
  }
  override func draw(_ dirtyRect: NSRect) {
    let w = bounds.width / CGFloat(n)
    let h = bounds.height / CGFloat(n)
    for r in 0..<n {
      for c in 0..<n {
        ((r + c) % 2 == 0 ? NSColor.white : NSColor(white: 0.85, alpha: 1)).setFill()
        NSRect(x: CGFloat(c) * w, y: bounds.height - CGFloat(r + 1) * h, width: w, height: h).fill()
      }
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black,
    ]
    ("hits \(hits)" as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: attrs)
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  func log(_ kind: String, _ e: NSEvent) {
    let p = convert(e.locationInWindow, from: nil)
    let (c, r) = cellAt(p)
    let s = window!.convertPoint(toScreen: e.locationInWindow)
    let k = NSScreen.main!.backingScaleFactor
    emit([
      "ev": kind, "cell": r * n + c, "row": r, "col": c, "click": e.clickCount,
      "px": Double(s.x * k), "py": Double((NSScreen.main!.frame.height - s.y) * k),
    ])
  }
  override func mouseDown(with e: NSEvent) {
    log("down", e)
    hits += 1
    needsDisplay = true
  }
  override func mouseUp(with e: NSEvent) { log("up", e) }
  override func rightMouseDown(with e: NSEvent) { log("rdown", e) }
  override func rightMouseUp(with e: NSEvent) { log("rup", e) }
}

// MARK: keys

final class KeyView: NSView {
  override var acceptsFirstResponder: Bool { true }
  func log(_ kind: String, _ e: NSEvent) {
    let mask = NSEvent.ModifierFlags.deviceIndependentFlagsMask
    emit([
      "ev": kind, "keyCode": Int(e.keyCode),
      "chars": kind == "flags" ? "" : (e.characters ?? ""),
      "flags": Int(e.modifierFlags.intersection(mask).rawValue),
      "global_flags": Int(NSEvent.modifierFlags.intersection(mask).rawValue),
    ])
  }
  override func keyDown(with e: NSEvent) { log("down", e) }
  // keyUp is logged by the app-level monitor: AppKit never routes keyUp to the
  // view while Command is held, and the oracle must see every delivered event.
  override func flagsChanged(with e: NSEvent) { log("flags", e) }
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    if e.type == .keyDown {
      log("down", e)
      return true
    }
    return false
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(srgbRed: 0.9, green: 0.95, blue: 1, alpha: 1).setFill()
    bounds.fill()
  }
}

// MARK: app

final class Delegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  func applicationDidFinishLaunching(_ n: Notification) {
    let screen = NSScreen.main!.frame
    let view: NSView
    let rect: NSRect
    switch mode {
    case "grid":
      rect = screen
      view = GridView()
    case "keys":
      rect = NSRect(x: 200, y: 200, width: 800, height: 400)
      view = KeyView()
    default:
      rect = NSRect(x: 160, y: screen.height - 160 - 6 * cell, width: 1100, height: 6 * cell)
      view = RenderView()
    }
    window = KeyWindow(
      contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.level =
      mode == "grid" ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1) : .floating
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    if let kv = view as? KeyView {
      NSEvent.addLocalMonitorForEvents(matching: .keyUp) { e in
        kv.log("up", e)
        return e
      }
    }
    NSApp.activate()
    var extra: [String: Any] = ["window": pixelRect(rect)]
    if mode == "render" {
      extra["cell_px"] = Double(cell * NSScreen.main!.backingScaleFactor)
      extra["palette"] = ["black", "white", "red", "blue"]
    }
    if mode == "grid" { extra["grid"] = 10 }
    writeState(extra)
    emit(["ev": "ready", "mode": mode])
  }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
