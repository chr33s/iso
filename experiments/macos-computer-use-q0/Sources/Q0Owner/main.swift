// q0host — Q0 spike VM owner for a macOS guest.
//
//   q0host install <bundle> <ipsw>
//   q0host run <bundle> --mode visible|hidden|offscreen|nowindow [--capture layer|cache|sck]
//
// `run` boots the VM and serves a JSON-lines control socket at --socket (default /tmp/q0spike-<uid>.sock):
//   {"op":"state"}                                -> vm state, boot identity, display geometry
//   {"op":"frame","path":P}                       -> capture PNG to P, returns frame metadata
//   {"op":"session"}                              -> new computer-use session bound to boot identity
//   {"op":"click","session":S,"x":X,"y":Y,"button":"left","count":1}
//   {"op":"move","session":S,"x":X,"y":Y}
//   {"op":"key","session":S,"events":[{"type":"down"|"up"|"flags","keyCode":K,"chars":C,"flags":F}]}
//   {"op":"hostinput"}                            -> host pointer location + modifier flags (leak oracle)
//   {"op":"stop"} / {"op":"requestStop"}
// Coordinates are framebuffer pixels, origin top-left.

import AppKit
import CoreImage
import Foundation
import ScreenCaptureKit
import Virtualization

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
  FileHandle.standardError.write(("q0host: " + s + "\n").data(using: .utf8)!)
}

func die(_ s: String) -> Never {
  log("fatal: " + s)
  exit(1)
}

// MARK: - Bundle

struct Bundle {
  let root: URL
  var disk: URL { root.appendingPathComponent("disk.img") }
  var aux: URL { root.appendingPathComponent("aux.img") }
  var hw: URL { root.appendingPathComponent("hardware-model.bin") }
  var mid: URL { root.appendingPathComponent("machine-id.bin") }
  var provisioned: URL { root.appendingPathComponent("provisioned") }
  var mac: URL { root.appendingPathComponent("mac.txt") }
}

let displayWidth = 1920
let displayHeight = 1200
let displayPPI = 80  // low PPI keeps the guest at 1x backing scale: points == pixels
let vsockPort: UInt32 = 7700

func makeConfiguration(
  _ b: Bundle, hardwareModel: VZMacHardwareModel, machineID: VZMacMachineIdentifier, cpus: Int,
  memory: UInt64
) throws
  -> VZVirtualMachineConfiguration
{
  let platform = VZMacPlatformConfiguration()
  platform.hardwareModel = hardwareModel
  platform.machineIdentifier = machineID
  platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: b.aux)

  let c = VZVirtualMachineConfiguration()
  c.platform = platform
  c.bootLoader = VZMacOSBootLoader()
  c.cpuCount = cpus
  c.memorySize = memory

  let gfx = VZMacGraphicsDeviceConfiguration()
  gfx.displays = [
    VZMacGraphicsDisplayConfiguration(
      widthInPixels: displayWidth, heightInPixels: displayHeight, pixelsPerInch: displayPPI)
  ]
  c.graphicsDevices = [gfx]

  c.storageDevices = [
    VZVirtioBlockDeviceConfiguration(
      attachment: try VZDiskImageStorageDeviceAttachment(url: b.disk, readOnly: false))
  ]

  let net = VZVirtioNetworkDeviceConfiguration()
  net.attachment = VZNATNetworkDeviceAttachment()
  if let s = try? String(contentsOf: b.mac, encoding: .utf8),
    let m = VZMACAddress(string: s.trimmingCharacters(in: .whitespacesAndNewlines))
  {
    net.macAddress = m
  }
  c.networkDevices = [net]

  c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  c.keyboards = [VZMacKeyboardConfiguration()]
  c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
  c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
  try c.validate()
  return c
}

// MARK: - install

@MainActor
func install(_ b: Bundle, ipsw: URL) async {
  do {
    try FileManager.default.createDirectory(at: b.root, withIntermediateDirectories: true)
    let image = try await VZMacOSRestoreImage.image(from: ipsw)
    guard let req = image.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else {
      die("restore image not supported on this host")
    }
    log(
      "restore image \(image.buildVersion) min cpu \(req.minimumSupportedCPUCount) min mem \(req.minimumSupportedMemorySize)"
    )
    let mid = VZMacMachineIdentifier()
    try req.hardwareModel.dataRepresentation.write(to: b.hw)
    try mid.dataRepresentation.write(to: b.mid)
    try VZMACAddress.randomLocallyAdministered().string.write(
      to: b.mac, atomically: true, encoding: .utf8)
    _ = try VZMacAuxiliaryStorage(
      creatingStorageAt: b.aux, hardwareModel: req.hardwareModel, options: [.allowOverwrite])
    FileManager.default.createFile(atPath: b.disk.path, contents: nil)
    let fh = try FileHandle(forWritingTo: b.disk)
    try fh.truncate(atOffset: 64 << 30)
    try fh.close()

    let cfg = try makeConfiguration(
      b, hardwareModel: req.hardwareModel, machineID: mid,
      cpus: max(4, req.minimumSupportedCPUCount),
      memory: max(8 << 30, req.minimumSupportedMemorySize))
    let vm = VZVirtualMachine(configuration: cfg)  // main queue
    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
    let obs = installer.progress.observe(\.fractionCompleted) { p, _ in
      log(String(format: "install %.1f%%", p.fractionCompleted * 100))
    }
    try await installer.install()
    obs.invalidate()
    log("install complete")
    exit(0)
  } catch {
    die("install failed: \(error)")
  }
}

// MARK: - Boot identity via vsock helper

/// The guest helper connects to host vsock port 7700 at login and sends one line:
/// {"hello":1,"boot":"<kern.bootsessionuuid>"}. The connection stays open for the life of the boot.
@MainActor
final class BootIdentity: NSObject, VZVirtioSocketListenerDelegate {
  var bootID: String?
  var connection: VZVirtioSocketConnection?
  var generation = 0  // bumps on every hello and every disconnect
  private var reader: Thread?

  nonisolated func listener(
    _ listener: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
    from device: VZVirtioSocketDevice
  ) -> Bool {
    let fd = dup(conn.fileDescriptor)
    Thread.detachNewThread { [weak self] in
      var buf = [UInt8](repeating: 0, count: 512)
      var line = Data()
      while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        line.append(contentsOf: buf[0..<n])
        if line.count > 4096 { break }  // bounded
        if let nl = line.firstIndex(of: 0x0A) {
          let msg = line[..<nl]
          line = Data(line[(nl + 1)...])
          if let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any],
            obj["hello"] as? Int == 1, let boot = obj["boot"] as? String, boot.count <= 64
          {
            DispatchQueue.main.async {
              self?.bootID = boot
              self?.generation += 1
              log("helper hello boot=\(boot)")
            }
          } else {
            break  // malformed: drop the connection
          }
        }
      }
      close(fd)
      DispatchQueue.main.async {
        self?.bootID = nil
        self?.generation += 1
        log("helper disconnected")
      }
    }
    return true
  }
}

// MARK: - Owner

struct Session {
  let id: String
  let vmInstance: String
  let bootID: String
  let bootGeneration: Int
  let width: Int
  let height: Int
}

enum Mode: String { case visible, hidden, offscreen, nowindow }
enum Capture: String { case layer, cache, sck }

@MainActor
final class Owner: NSObject, VZVirtualMachineDelegate {
  let b: Bundle
  let mode: Mode
  var capture: Capture
  var vm: VZVirtualMachine!
  var view: VZVirtualMachineView!
  var window: NSWindow?
  let boot = BootIdentity()
  var vmInstance = UUID().uuidString
  var hostState = "starting"
  var sessions: [String: Session] = [:]
  var frameSeq = 0
  let ciContext = CIContext()

  init(_ b: Bundle, mode: Mode, capture: Capture) {
    self.b = b
    self.mode = mode
    self.capture = capture
  }

  func start() {
    do {
      guard let hwData = try? Data(contentsOf: b.hw),
        let hw = VZMacHardwareModel(dataRepresentation: hwData),
        let midData = try? Data(contentsOf: b.mid),
        let mid = VZMacMachineIdentifier(dataRepresentation: midData)
      else { die("bundle missing hardware model / machine id; run install first") }
      let cfg = try makeConfiguration(
        b, hardwareModel: hw, machineID: mid, cpus: 4, memory: 8 << 30)
      vm = VZVirtualMachine(configuration: cfg)
      vm.delegate = self
      vmInstance = UUID().uuidString

      view = VZVirtualMachineView(
        frame: NSRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
      view.virtualMachine = vm
      view.capturesSystemKeys = true
      attachView()

      if let sock = vm.socketDevices.first as? VZVirtioSocketDevice {
        let l = VZVirtioSocketListener()
        l.delegate = boot
        sock.setSocketListener(l, forPort: vsockPort)
      }

      let opts = VZMacOSVirtualMachineStartOptions()
      if !FileManager.default.fileExists(atPath: b.provisioned.path) {
        let p = VZMacGuestProvisioningOptions()
        p.fullName = "iso"
        p.username = "iso"
        p.password = "iso-q0-spike"
        p.logsInAutomatically = true
        p.enablesRemoteLogin = true
        try opts.setGuestProvisioning(p)
        log("first boot: guest provisioning enabled (user iso, autologin, ssh)")
      }
      vm.start(options: opts) { [self] err in
        if let err {
          hostState = "failed"
          die("start failed: \(err)")
        }
        hostState = "running"
        FileManager.default.createFile(atPath: b.provisioned.path, contents: Data())
        log("vm running instance=\(vmInstance)")
      }
    } catch {
      die("configuration: \(error)")
    }
  }

  func attachView() {
    switch mode {
    case .nowindow:
      // Production topology: no window, no Dock icon. The view is never on screen.
      view.wantsLayer = true
    case .visible, .hidden, .offscreen:
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: displayWidth, height: displayHeight),
        styleMask: [.titled], backing: .buffered, defer: false)
      w.contentView = view
      w.isReleasedWhenClosed = false
      window = w
      switch mode {
      case .visible: w.makeKeyAndOrderFront(nil)
      case .hidden: w.orderOut(nil)
      case .offscreen:
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
      default: break
      }
    }
  }

  // MARK: delegate

  nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    MainActor.assumeIsolated {
      hostState = "stopped"
      log("guest did stop")
      sessions.removeAll()
    }
  }

  nonisolated func virtualMachine(
    _ virtualMachine: VZVirtualMachine, didStopWithError error: any Error
  ) {
    MainActor.assumeIsolated {
      hostState = "error"
      log("vm stopped with error: \(error)")
      sessions.removeAll()
    }
  }

  // MARK: geometry

  var displaySize: (Int, Int) {
    if let d = vm.graphicsDevices.first?.displays.first {
      return (Int(d.sizeInPixels.width), Int(d.sizeInPixels.height))
    }
    return (displayWidth, displayHeight)
  }

  /// framebuffer pixel (top-left origin) -> view point (bottom-left origin)
  func viewPoint(_ x: Double, _ y: Double) -> NSPoint {
    let (w, h) = displaySize
    let bx = view.bounds
    return NSPoint(
      x: (x + 0.5) / Double(w) * bx.width, y: bx.height - (y + 0.5) / Double(h) * bx.height)
  }

  // MARK: sessions

  func newSession() throws -> Session {
    guard hostState == "running" else { throw Refusal("vm not running (\(hostState))") }
    guard let bootID = boot.bootID else {
      throw Refusal("no boot identity: guest helper not connected")
    }
    let (w, h) = displaySize
    let s = Session(
      id: UUID().uuidString, vmInstance: vmInstance, bootID: bootID,
      bootGeneration: boot.generation, width: w, height: h)
    sessions[s.id] = s
    return s
  }

  func check(_ id: String?) throws -> Session {
    guard let id, let s = sessions[id] else { throw Refusal("unknown session") }
    guard hostState == "running" else { throw Refusal("vm not running (\(hostState))") }
    // A VZVirtualMachineView outside a window accepts synthesized events and drops
    // them: the API would report success for input the guest never receives.
    guard view.window != nil else { throw Refusal("view has no window: input cannot be delivered") }
    guard s.vmInstance == vmInstance else { throw Refusal("vm instance changed") }
    guard boot.generation == s.bootGeneration, boot.bootID == s.bootID else {
      sessions[id] = nil
      throw Refusal(
        "boot identity changed (session bound to \(s.bootID), now \(boot.bootID ?? "none"))")
    }
    let (w, h) = displaySize
    guard w == s.width, h == s.height else { throw Refusal("display geometry changed") }
    return s
  }

  // MARK: input

  func windowNumber() -> Int { window?.windowNumber ?? 0 }

  func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clickCount: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: view.convert(p, to: nil), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber(), context: nil, eventNumber: 0, clickCount: clickCount,
      pressure: type == .leftMouseUp ? 0 : 1)!
  }

  func move(x: Double, y: Double) {
    view.mouseMoved(with: mouse(.mouseMoved, viewPoint(x, y)))
  }

  func click(x: Double, y: Double, button: String, count: Int) async {
    let p = viewPoint(x, y)
    view.mouseMoved(with: mouse(.mouseMoved, p))
    try? await Task.sleep(for: .milliseconds(15))
    for i in 1...max(1, count) {
      switch button {
      case "right":
        view.rightMouseDown(with: mouse(.rightMouseDown, p, clickCount: i))
        try? await Task.sleep(for: .milliseconds(15))
        view.rightMouseUp(with: mouse(.rightMouseUp, p, clickCount: i))
      default:
        view.mouseDown(with: mouse(.leftMouseDown, p, clickCount: i))
        try? await Task.sleep(for: .milliseconds(15))
        view.mouseUp(with: mouse(.leftMouseUp, p, clickCount: i))
      }
      try? await Task.sleep(for: .milliseconds(15))
    }
  }

  func key(_ events: [[String: Any]]) async {
    for e in events {
      let type = e["type"] as? String ?? "down"
      let code = UInt16(e["keyCode"] as? Int ?? 0)
      let chars = e["chars"] as? String ?? ""
      let flags = NSEvent.ModifierFlags(rawValue: UInt(e["flags"] as? Int ?? 0))
      let t: NSEvent.EventType = type == "up" ? .keyUp : type == "flags" ? .flagsChanged : .keyDown
      let ev: NSEvent
      if t == .flagsChanged {
        ev = NSEvent.keyEvent(
          with: .flagsChanged, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: windowNumber(), context: nil, characters: "",
          charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        view.flagsChanged(with: ev)
      } else {
        ev = NSEvent.keyEvent(
          with: t, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber(),
          context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
          keyCode: code)!
        if t == .keyDown { view.keyDown(with: ev) } else { view.keyUp(with: ev) }
      }
      try? await Task.sleep(for: .milliseconds(12))
    }
  }

  // MARK: frames

  func frame(to path: String, via: Capture?) async throws -> [String: Any] {
    guard hostState == "running" else { throw Refusal("vm not running (\(hostState))") }
    guard view.window != nil else {
      throw Refusal("view has no window: framebuffer is not rendered")
    }
    let method = via ?? capture
    let image: CGImage
    switch method {
    case .layer: image = try captureLayer()
    case .cache: image = try captureCache()
    case .sck: image = try await captureSCK()
    }
    // Never hand out a uniform frame as an observation: a black or empty surface
    // is how a missing framebuffer looks, whatever the cause.
    if let range = channelRange(image), range <= 3 {
      throw Refusal("blank frame (channel range \(range)): framebuffer not observed")
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else {
      throw Refusal("png destination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Refusal("png write") }
    frameSeq += 1
    let (w, h) = displaySize
    return [
      "frame_id": "\(vmInstance.prefix(8))-\(frameSeq)", "boot_id": boot.bootID ?? NSNull(),
      "vm_instance": vmInstance,
      "width": w, "height": h, "image_width": image.width, "image_height": image.height,
      "seq": frameSeq,
      "timestamp": Date().timeIntervalSince1970, "capture": method.rawValue, "path": path,
    ]
  }

  /// Largest per-channel spread over a 64x40 downsample; nil if the image cannot be drawn.
  func channelRange(_ image: CGImage) -> Int? {
    let w = 64
    let h = 40
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = px.withUnsafeMutableBytes { buf in
      guard
        let ctx = CGContext(
          data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      ctx.interpolationQuality = .none
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
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

  /// Read the framebuffer surface the view's layer tree presents, if it is in-process.
  func captureLayer() throws -> CGImage {
    guard let root = view.layer else { throw Refusal("view has no layer") }
    var found: CGImage?
    var kinds: [String] = []
    func walk(_ l: CALayer) {
      if found != nil { return }
      if let c = l.contents {
        let cf = c as CFTypeRef
        kinds.append(
          CFGetTypeID(cf) == IOSurfaceGetTypeID() ? "IOSurface" : String(describing: type(of: c)))
        if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
          let surface = unsafeDowncast(cf, to: IOSurfaceRef.self)
          let ci = CIImage(ioSurface: surface)
          found = ciContext.createCGImage(ci, from: ci.extent)
          return
        }
        if CFGetTypeID(cf) == CGImage.typeID {
          found = (cf as! CGImage)
          return
        }
      } else {
        kinds.append(String(describing: type(of: l)))
      }
      for s in l.sublayers ?? [] { walk(s) }
    }
    walk(root)
    guard let found else {
      throw Refusal("no readable layer contents (layers: \(kinds.joined(separator: ",")))")
    }
    return found
  }

  func captureCache() throws -> CGImage {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw Refusal("no bitmap rep")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let img = rep.cgImage else { throw Refusal("no cgImage") }
    return img
  }

  func captureSCK() async throws -> CGImage {
    guard let window else { throw Refusal("sck capture needs a window (mode \(mode.rawValue))") }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let scw = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
    else {
      throw Refusal("window not in shareable content")
    }
    let filter = SCContentFilter(desktopIndependentWindow: scw)
    let cfg = SCStreamConfiguration()
    let (w, h) = displaySize
    cfg.width = w
    cfg.height = h
    cfg.showsCursor = false
    cfg.ignoreShadowsSingleWindow = true
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
  }
}

struct Refusal: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}

// MARK: - Control socket

@MainActor
func handle(_ owner: Owner, _ req: [String: Any]) async -> [String: Any] {
  let op = req["op"] as? String ?? ""
  do {
    switch op {
    case "state":
      let (w, h) = owner.displaySize
      return [
        "ok": true, "state": owner.hostState, "vm_state": owner.vm.state.rawValue,
        "vm_instance": owner.vmInstance,
        "boot_id": owner.boot.bootID ?? NSNull(), "boot_generation": owner.boot.generation,
        "width": w, "height": h,
        "mode": owner.mode.rawValue, "capture": owner.capture.rawValue,
      ]
    case "frame":
      let via = (req["capture"] as? String).flatMap(Capture.init(rawValue:))
      var r = try await owner.frame(to: req["path"] as? String ?? "/dev/null", via: via)
      r["ok"] = true
      return r
    case "session":
      let s = try owner.newSession()
      return [
        "ok": true, "session": s.id, "boot_id": s.bootID, "vm_instance": s.vmInstance,
        "width": s.width, "height": s.height,
      ]
    case "move":
      let s = try owner.check(req["session"] as? String)
      let x = req["x"] as? Double ?? -1
      let y = req["y"] as? Double ?? -1
      guard x >= 0, y >= 0, x < Double(s.width), y < Double(s.height) else {
        throw Refusal("coordinate out of range")
      }
      owner.move(x: x, y: y)
      return ["ok": true]
    case "click":
      let s = try owner.check(req["session"] as? String)
      let x = req["x"] as? Double ?? -1
      let y = req["y"] as? Double ?? -1
      guard x >= 0, y >= 0, x < Double(s.width), y < Double(s.height) else {
        throw Refusal("coordinate out of range")
      }
      await owner.click(
        x: x, y: y, button: req["button"] as? String ?? "left", count: req["count"] as? Int ?? 1)
      return ["ok": true]
    case "key":
      _ = try owner.check(req["session"] as? String)
      await owner.key(req["events"] as? [[String: Any]] ?? [])
      return ["ok": true]
    case "hostinput":
      let p = NSEvent.mouseLocation
      return [
        "ok": true, "x": p.x, "y": p.y, "flags": Int(NSEvent.modifierFlags.rawValue),
        "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
      ]
    case "requestStop":
      try owner.vm.requestStop()
      return ["ok": true]
    case "stop":
      try await owner.vm.stop()
      owner.hostState = "stopped"
      owner.sessions.removeAll()
      return ["ok": true]
    case "quit":
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
      return ["ok": true]
    default:
      throw Refusal("unknown op \(op)")
    }
  } catch {
    return ["ok": false, "error": "\(error)"]
  }
}

func serve(_ owner: Owner, at path: String) {
  guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
    die("socket path too long (\(path.utf8.count) bytes): \(path)")
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
  guard
    withUnsafePointer(
      to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } })
      == 0
  else {
    die("bind \(path): \(errno)")
  }
  chmod(path, 0o600)
  listen(fd, 4)
  Thread.detachNewThread {
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 { continue }
      Thread.detachNewThread {
        let input = FileHandle(fileDescriptor: c, closeOnDealloc: false)
        var buf = Data()
        while true {
          let chunk = input.availableData
          if chunk.isEmpty { break }
          buf.append(chunk)
          while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[..<nl]
            buf = Data(buf[(nl + 1)...])
            let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var resp: [String: Any] = [:]
            nonisolated(unsafe) let r = req
            Task { @MainActor in
              resp = await handle(owner, r)
              sem.signal()
            }
            sem.wait()
            var out =
              (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{\"ok\":false}".utf8)
            out.append(0x0A)
            out.withUnsafeBytes { _ = write(c, $0.baseAddress!, $0.count) }
          }
        }
        close(c)
      }
    }
  }
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 3 else {
  die("usage: q0host install <bundle> <ipsw> | run <bundle> --mode M [--capture C]")
}
let bundle = Bundle(root: URL(fileURLWithPath: args[2]))

func opt(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  return args[i + 1]
}

let app = NSApplication.shared
switch args[1] {
case "install":
  guard args.count >= 4 else { die("install needs <ipsw>") }
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in await install(bundle, ipsw: URL(fileURLWithPath: args[3])) }
case "run":
  let mode = Mode(rawValue: opt("--mode") ?? "visible") ?? .visible
  let cap = Capture(rawValue: opt("--capture") ?? "layer") ?? .layer
  app.setActivationPolicy(mode == .visible ? .regular : .prohibited)
  MainActor.assumeIsolated {
    let owner = Owner(bundle, mode: mode, capture: cap)
    owner.start()
    let sock = opt("--socket") ?? "/tmp/q0spike-\(getuid()).sock"
    serve(owner, at: sock)
    log("control socket \(sock) mode=\(mode.rawValue) capture=\(cap.rawValue)")
  }
default:
  die("unknown command \(args[1])")
}
app.run()
