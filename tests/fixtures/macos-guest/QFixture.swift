// Gate Q fixture: one guest app with an AppKit, a SwiftUI and a WKWebView
// window. Every control appends what it received to events.jsonl and
// reports its frame, in screen pixels with a top-left origin, to
// state.json. The qualification driver acts only through computer use and
// reads these files over SSH as its oracle.
//
//     xcrun swiftc -parse-as-library -O QFixture.swift -o IsoQFixture
import AppKit
import SwiftUI
import WebKit

let support = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/IsoQFixture")
let eventsURL = support.appendingPathComponent("events.jsonl")
let stateURL = support.appendingPathComponent("state.json")

@MainActor final class Fixture {
  static let shared = Fixture()
  var frames: [String: [String: Double]] = [:]
  var seq = 0
  let handle: FileHandle

  init() {
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
    handle = try! FileHandle(forWritingTo: eventsURL)
  }

  func event(_ fw: String, _ control: String, _ event: String, _ value: Any = NSNull()) {
    seq += 1
    let o: [String: Any] = [
      "seq": seq, "fw": fw, "control": control, "event": event, "value": value,
      "t": ProcessInfo.processInfo.systemUptime,
    ]
    var d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    d.append(0x0A)
    handle.write(d)
  }

  /// `rect` in screen points, bottom-left origin.
  func report(_ name: String, screenRect rect: NSRect) {
    guard let screen = NSScreen.main else { return }
    let k = Double(screen.backingScaleFactor)
    frames[name] = [
      "x": Double(rect.minX) * k, "y": Double(screen.frame.height - rect.maxY) * k,
      "w": Double(rect.width) * k, "h": Double(rect.height) * k,
    ]
  }

  func report(_ name: String, view: NSView) {
    guard let window = view.window else { return }
    report(name, screenRect: window.convertToScreen(view.convert(view.bounds, to: nil)))
  }

  func writeState() {
    let d = try! JSONSerialization.data(
      withJSONObject: ["pid": Int(getpid()), "frames": frames], options: [.sortedKeys])
    try? d.write(to: stateURL, options: .atomic)
  }
}

// MARK: - AppKit

final class DragSource: NSTextField, NSDraggingSource {
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }

  override func mouseDragged(with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: "iso-dragged-payload" as NSString)
    item.setDraggingFrame(bounds, contents: nil)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  override func mouseDown(with event: NSEvent) {}
}

final class DropTarget: NSTextField {
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.string])
  }
  required init?(coder: NSCoder) { nil }
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let text = sender.draggingPasteboard.string(forType: .string) ?? ""
    Fixture.shared.event("appkit", "drop", "dropped", text)
    stringValue = "Dropped"
    return true
  }
}

final class ContextTarget: NSTextField {
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    for title in ["Ctx One", "Ctx Two"] {
      let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    return menu
  }
  @objc func pick(_ sender: NSMenuItem) {
    Fixture.shared.event("appkit", "context", "selected", sender.title)
  }
}

@MainActor final class AppKitWindow: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
  let window = NSWindow(
    contentRect: NSRect(x: 40, y: 200, width: 560, height: 760),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  var views: [String: NSView] = [:]
  var sheet: NSWindow?
  var child: NSWindow?

  func label(_ s: String) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = .systemFont(ofSize: 15, weight: .semibold)
    return f
  }

  func build() {
    window.title = "AppKit Fixture"
    let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
    window.contentView = root
    // Top to bottom: `y` is the top edge of the next view (bottom-left origin).
    var y: CGFloat = 740
    func place(_ name: String, _ v: NSView, height: CGFloat = 28, width: CGFloat = 240) {
      y -= height
      v.frame = NSRect(x: 30, y: y, width: width, height: height)
      root.addSubview(v)
      views[name] = v
      y -= 12
    }
    let button = NSButton(title: "AK Button", target: self, action: #selector(pressed))
    place("ak_button", button)
    let field = NSTextField(string: "")
    field.placeholderString = "AK Field"
    field.delegate = self
    place("ak_field", field)
    let scrollText = NSTextView.scrollableTextView()
    (scrollText.documentView as! NSTextView).delegate = self
    place("ak_editor", scrollText, height: 70)
    let check = NSButton(
      checkboxWithTitle: "AK Check", target: self, action: #selector(checked(_:)))
    place("ak_check", check)
    let radioA = NSButton(
      radioButtonWithTitle: "AK Radio A", target: self, action: #selector(radio(_:)))
    place("ak_radio_a", radioA)
    let radioB = NSButton(
      radioButtonWithTitle: "AK Radio B", target: self, action: #selector(radio(_:)))
    place("ak_radio_b", radioB)
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.addItems(withTitles: ["Alpha", "Beta", "Gamma"])
    popup.target = self
    popup.action = #selector(popped(_:))
    place("ak_popup", popup)
    let slider = NSSlider(
      value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(slid(_:)))
    place("ak_slider", slider, width: 400)
    let scroll = NSScrollView()
    let list = NSTextView()
    list.string = (1...60).map { "Row \($0)" }.joined(separator: "\n")
    list.isEditable = false
    scroll.documentView = list
    scroll.hasVerticalScroller = true
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak scroll] _ in
      MainActor.assumeIsolated {
        let offset = Double(scroll?.contentView.bounds.minY ?? 0)
        Fixture.shared.event("appkit", "scroll", "scrolled", offset)
      }
    }
    place("ak_scroll", scroll, height: 90)
    let context = ContextTarget(labelWithString: "AK Context")
    place("ak_context", context)
    place("ak_sheet", NSButton(title: "AK Sheet", target: self, action: #selector(openSheet)))
    place("ak_child", NSButton(title: "AK Child", target: self, action: #selector(openChild)))
    let source = DragSource(labelWithString: "AK Drag Me")
    source.isBezeled = true
    place("ak_drag", source)
    let target = DropTarget(frame: .zero)
    target.stringValue = "AK Drop Here"
    target.isEditable = false
    place("ak_drop", target, height: 40)
    window.setFrameTopLeftPoint(NSPoint(x: 40, y: (NSScreen.main?.frame.height ?? 1200) - 60))
    window.makeKeyAndOrderFront(nil)
  }

  func report() {
    for (name, v) in views { Fixture.shared.report(name, view: v) }
    if let sheet, let ok = sheet.contentView?.subviews.first {
      Fixture.shared.report("ak_sheet_ok", view: ok)
    }
    if let child, let ok = child.contentView?.subviews.first {
      Fixture.shared.report("ak_child_ok", view: ok)
    }
  }

  @objc func pressed() { Fixture.shared.event("appkit", "button", "pressed") }
  @objc func checked(_ b: NSButton) {
    Fixture.shared.event("appkit", "check", "set", b.state == .on)
  }
  @objc func radio(_ b: NSButton) {
    for case let other as NSButton in [views["ak_radio_a"], views["ak_radio_b"]] where other !== b {
      other.state = .off
    }
    Fixture.shared.event("appkit", "radio", "selected", b.title)
  }
  @objc func popped(_ p: NSPopUpButton) {
    Fixture.shared.event("appkit", "popup", "selected", p.titleOfSelectedItem ?? "")
  }
  @objc func slid(_ s: NSSlider) {
    Fixture.shared.event("appkit", "slider", "value", s.doubleValue)
  }
  func controlTextDidChange(_ n: Notification) {
    Fixture.shared.event("appkit", "field", "text", (n.object as! NSTextField).stringValue)
  }
  func textDidChange(_ n: Notification) {
    Fixture.shared.event("appkit", "editor", "text", (n.object as! NSTextView).string)
  }

  @objc func openSheet() {
    let s = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    let ok = NSButton(title: "Sheet OK", target: self, action: #selector(closeSheet))
    ok.frame = NSRect(x: 100, y: 40, width: 100, height: 30)
    s.contentView?.addSubview(ok)
    sheet = s
    Fixture.shared.event("appkit", "sheet", "opened")
    window.beginSheet(s)
  }
  @objc func closeSheet() {
    guard let sheet else { return }
    window.endSheet(sheet)
    self.sheet = nil
    Fixture.shared.event("appkit", "sheet", "ok")
  }
  @objc func openChild() {
    let c = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    c.title = "Child"
    let ok = NSButton(title: "Child OK", target: self, action: #selector(closeChild))
    ok.frame = NSRect(x: 80, y: 40, width: 100, height: 30)
    c.contentView?.addSubview(ok)
    c.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX - 300, y: window.frame.maxY - 120))
    window.addChildWindow(c, ordered: .above)
    child = c
    Fixture.shared.event("appkit", "child", "opened")
  }
  @objc func closeChild() {
    guard let child else { return }
    window.removeChildWindow(child)
    child.orderOut(nil)
    self.child = nil
    Fixture.shared.event("appkit", "child", "ok")
  }
}

// MARK: - SwiftUI

struct Frames: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  func reporting(_ name: String) -> some View {
    background(
      GeometryReader { g in
        Color.clear.preference(key: Frames.self, value: [name: g.frame(in: .named("root"))])
      })
  }
}

struct SwiftUIFixture: View {
  @State var text = ""
  @State var on = false
  @State var color = "Red"
  @State var level = 0.0
  @State var notes = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Button("SU Button") { Fixture.shared.event("swiftui", "button", "pressed") }.reporting(
        "su_button")
      TextField("SU Field", text: $text).frame(width: 240).reporting("su_field")
        .onChange(of: text) { _, v in Fixture.shared.event("swiftui", "field", "text", v) }
      Toggle("SU Toggle", isOn: $on).reporting("su_toggle")
        .onChange(of: on) { _, v in Fixture.shared.event("swiftui", "toggle", "set", v) }
      Picker("SU Picker", selection: $color) {
        ForEach(["Red", "Green", "Blue"], id: \.self) { Text($0) }
      }.pickerStyle(.menu).frame(width: 240).reporting("su_picker")
        .onChange(of: color) { _, v in Fixture.shared.event("swiftui", "picker", "selected", v) }
      Slider(value: $level, in: 0...100).frame(width: 300).reporting("su_slider")
        .onChange(of: level) { _, v in Fixture.shared.event("swiftui", "slider", "value", v) }
      TextEditor(text: $notes).frame(width: 300, height: 70).border(.gray).reporting("su_editor")
        .onChange(of: notes) { _, v in Fixture.shared.event("swiftui", "editor", "text", v) }
    }
    .padding(30)
    .frame(width: 460, height: 460, alignment: .topLeading)
    .coordinateSpace(name: "root")
  }
}

@MainActor final class SwiftUIWindow {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 460, height: 460), styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  var frames: [String: CGRect] = [:]

  func build() {
    window.title = "SwiftUI Fixture"
    window.contentView = NSHostingView(
      rootView: SwiftUIFixture().onPreferenceChange(Frames.self) { f in
        MainActor.assumeIsolated { self.frames = f }
      })
    window.setFrameTopLeftPoint(NSPoint(x: 640, y: (NSScreen.main?.frame.height ?? 1200) - 60))
    window.orderFront(nil)
  }

  /// Frames are in the root view's space: the hosting view's own points,
  /// top-left origin (`.global` would include the title bar).
  func report() {
    guard let content = window.contentView else { return }
    for (name, r) in frames {
      // NSHostingView is flipped: its coordinates are already top-left.
      let y = content.isFlipped ? r.minY : content.bounds.height - r.maxY
      let local = NSRect(x: r.minX, y: y, width: r.width, height: r.height)
      Fixture.shared.report(
        name, screenRect: window.convertToScreen(content.convert(local, to: nil)))
    }
  }
}

// MARK: - WKWebView

let page = """
  <!doctype html><html><body style="font: 16px -apple-system; padding: 20px">
  <p><input id="wk_field" placeholder="WK Field" style="font-size:16px"></p>
  <p><button id="wk_button" style="font-size:16px">WK Button</button></p>
  <p><label><input id="wk_check" type="checkbox"> WK Check</label></p>
  <p><select id="wk_select" style="font-size:16px"><option>One</option><option>Two</option><option>Three</option></select></p>
  <p><a id="wk_link" href="#done">WK Link</a></p>
  <script>
  const post = (control, event, value) =>
    window.webkit.messageHandlers.iso.postMessage({control, event, value});
  wk_field.addEventListener('input', e => post('field', 'text', e.target.value));
  wk_button.addEventListener('click', () => post('button', 'pressed', null));
  wk_check.addEventListener('change', e => post('check', 'set', e.target.checked));
  wk_select.addEventListener('change', e => post('select', 'selected', e.target.value));
  window.addEventListener('hashchange', () => post('link', 'followed', location.hash));
  function rects() {
    const out = {};
    for (const id of ['wk_field', 'wk_button', 'wk_check', 'wk_select', 'wk_link']) {
      const r = document.getElementById(id).getBoundingClientRect();
      out[id] = [r.left, r.top, r.width, r.height];
    }
    window.webkit.messageHandlers.layout.postMessage(out);
  }
  window.addEventListener('load', rects);
  setInterval(rects, 1000);
  </script></body></html>
  """

@MainActor final class WebWindow: NSObject, WKScriptMessageHandler {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  var web: WKWebView!
  var rects: [String: [Double]] = [:]

  func build() {
    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "iso")
    config.userContentController.add(self, name: "layout")
    web = WKWebView(frame: window.contentRect(forFrameRect: window.frame), configuration: config)
    window.title = "WebKit Fixture"
    window.contentView = web
    window.setFrameTopLeftPoint(NSPoint(x: 1160, y: (NSScreen.main?.frame.height ?? 1200) - 60))
    web.loadHTMLString(page, baseURL: nil)
    window.orderFront(nil)
  }

  nonisolated func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    MainActor.assumeIsolated {
      if message.name == "layout", let r = message.body as? [String: [Double]] {
        rects = r
        return
      }
      guard let body = message.body as? [String: Any] else { return }
      Fixture.shared.event(
        "webkit", body["control"] as? String ?? "?", body["event"] as? String ?? "?",
        body["value"] ?? NSNull())
    }
  }

  /// Web view coordinates are top-left; the web view fills the content.
  func report() {
    for (name, r) in rects where r.count == 4 {
      // WKWebView is flipped, like the page's own coordinates.
      let y = web.isFlipped ? r[1] : web.bounds.height - r[1] - r[3]
      let local = NSRect(x: r[0], y: y, width: r[2], height: r[3])
      Fixture.shared.report(name, screenRect: window.convertToScreen(web.convert(local, to: nil)))
    }
  }
}

// MARK: - App

@main @MainActor final class App: NSObject, NSApplicationDelegate {
  let appKit = AppKitWindow()
  let swiftUI = SwiftUIWindow()
  let webKit = WebWindow()

  static func main() {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    menu.addItem(appItem)
    let appMenu = NSMenu(title: "IsoQFixture")
    appMenu.addItem(
      withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let fixtureItem = NSMenuItem()
    menu.addItem(fixtureItem)
    let fixtureMenu = NSMenu(title: "Fixture")
    let action = NSMenuItem(title: "Menu Action", action: #selector(menuAction), keyEquivalent: "m")
    action.keyEquivalentModifierMask = [.command, .shift]
    action.target = self
    fixtureMenu.addItem(action)
    fixtureItem.submenu = fixtureMenu
    NSApp.mainMenu = menu
    swiftUI.build()
    webKit.build()
    appKit.build()
    NSApp.activate()
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
      MainActor.assumeIsolated {
        self.appKit.report()
        self.swiftUI.report()
        self.webKit.report()
        Fixture.shared.writeState()
      }
    }
    Fixture.shared.event("app", "app", "launched")
  }

  @objc func menuAction() { Fixture.shared.event("appkit", "menu", "selected", "Menu Action") }
}
