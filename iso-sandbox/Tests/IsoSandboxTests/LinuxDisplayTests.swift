import Containerization
import Foundation
import IsoMacProtocol
import Synchronization
import Testing

@testable import IsoSandboxCore

/// docs/design/linux-desktop-virtio-gpu.md §4–§6, checked without a VM.
@Suite struct LinuxDisplayTests {
  static let frameworkShare = VMDevices.DirectorySharing.virtioFS(
    tag: "virtiofs", share: .multiple(directories: 0))

  static func devices(_ graphics: [VMDevices.Graphics]) -> VMDevices {
    VMDevices(
      network: [.vmnet], socket: 1, directorySharing: [frameworkShare], graphics: graphics)
  }

  static let scanout = VMDevices.Graphics.Size(width: 1920, height: 1200)

  // MARK: inventory

  @Test func aDisplaySandboxNeedsExactlyItsOneScanout() throws {
    try Self.devices([.virtio(scanouts: [Self.scanout])])
      .requireExpected(for: .shared, display: .virtioDisplay)
    let refused: [[VMDevices.Graphics]] = [
      [],
      [.virtio(scanouts: [])],
      [.virtio(scanouts: [.init(width: 1920, height: 1080)])],
      [.virtio(scanouts: [Self.scanout, Self.scanout])],
      [.virtio(scanouts: [Self.scanout]), .virtio(scanouts: [Self.scanout])],
      [.other("VZMacGraphicsDevice")],
    ]
    for graphics in refused {
      #expect(throws: SandboxError.self) {
        try Self.devices(graphics).requireExpected(for: .shared, display: .virtioDisplay)
      }
    }
  }

  @Test func aHeadlessSandboxStillRefusesTheDisplayDevice() {
    #expect(throws: SandboxError.self) {
      try Self.devices([.virtio(scanouts: [Self.scanout])]).requireExpected(for: .shared)
    }
    #expect(throws: SandboxError.self) {
      try Self.devices([.virtio(scanouts: [Self.scanout])])
        .requireExpected(for: .shared, display: .headless)
    }
  }

  @Test func aDisplaySandboxStillRefusesAUSBControllerAndTheRest() {
    let mutations: [(inout VMDevices) -> Void] = [
      { $0.usbControllers = 1 }, { $0.console = 1 }, { $0.memoryBalloon = 1 },
      { $0.socket = 2 }, { $0.network = [] },
      { $0.directorySharing = [.virtioFS(tag: "virtiofs", share: .multiple(directories: 1))] },
    ]
    for mutate in mutations {
      var d = Self.devices([.virtio(scanouts: [Self.scanout])])
      mutate(&d)
      #expect(throws: SandboxError.self) {
        try d.requireExpected(for: .shared, display: .virtioDisplay)
      }
    }
  }

  @Test func theOwnerStopsADisplaySandboxWithoutItsDisplay() async throws {
    let stops = Mutex(0)
    await #expect(throws: SandboxError.self) {
      try await Owner.checkDevices(
        of: try SandboxID("desk"), mode: .shared, display: .virtioDisplay,
        read: { Self.devices([]) }, stop: { stops.withLock { $0 += 1 } })
    }
    #expect(stops.withLock { $0 } == 1)
  }

  @Test func theDisplayIsOneScanoutAtTheGuestGeometry() {
    #expect(VMDevices.Graphics.display == .virtio(scanouts: [Self.scanout]))
  }

  // MARK: capture

  @Test func theSurfaceConversionIgnoresTheAlphaByte() {
    let width = 3
    let height = 2
    let sourceRow = 16  // padded, as IOSurface rows may be
    var source = [UInt8](repeating: 0xEE, count: sourceRow * height)
    // B, G, R, A per pixel; alpha 0 as Xorg at depth 24 writes it.
    let pixels: [(UInt8, UInt8, UInt8, UInt8)] = [
      (0x00, 0x00, 0xFF, 0x00), (0x00, 0xFF, 0x00, 0x00), (0xFF, 0x00, 0x00, 0x7F),
      (0x10, 0x20, 0x30, 0xFF), (0x01, 0x02, 0x03, 0x00), (0xAA, 0xBB, 0xCC, 0x00),
    ]
    for (i, p) in pixels.enumerated() {
      let o = (i / width) * sourceRow + (i % width) * 4
      source[o] = p.0
      source[o + 1] = p.1
      source[o + 2] = p.2
      source[o + 3] = p.3
    }
    var out = [UInt8](repeating: 0, count: width * 4 * height)
    source.withUnsafeBytes { src in
      out.withUnsafeMutableBytes { dst in
        FramebufferSurface.convert(
          bgra: src.baseAddress!, bytesPerRow: sourceRow, into: dst.baseAddress!,
          bytesPerRow: width * 4, width: width, height: height)
      }
    }
    for (i, p) in pixels.enumerated() {
      #expect(Array(out[(i * 4)..<(i * 4 + 4)]) == [p.2, p.1, p.0, 0xFF], "pixel \(i)")
    }
  }

  @Test func theSurfacePixelFormatIsBGRA() {
    let fourCC = withUnsafeBytes(of: FramebufferSurface.pixelFormat.bigEndian) {
      String(decoding: $0, as: UTF8.self)
    }
    #expect(fourCC == "BGRA")
  }

  // MARK: binding

  @Test func theBindingIsHostAnchored() {
    let b = LinuxDesktop.binding(bootId: "boot-a", vmInstance: "vm-a")
    #expect(b.guestBoot == "boot-a")
    #expect(b.helperGeneration == 0)
    #expect(b.width == 1920 && b.height == 1200)
    #expect(b.mismatch(b) == nil)
    #expect(b.mismatch(LinuxDesktop.binding(bootId: "boot-b", vmInstance: "vm-a")) != nil)
    #expect(b.mismatch(LinuxDesktop.binding(bootId: "boot-a", vmInstance: "vm-b")) != nil)
  }

  // MARK: record and kernel

  static func record(display: SandboxDisplay = .headless) throws -> SandboxRecord {
    SandboxRecord(
      id: try SandboxID("desk"), owner: "o", imageReference: "i", imageDigest: "sha256:0",
      baseDisk: nil, environment: [], cpus: 1, memoryBytes: 1 << 30, diskBytes: 1 << 30,
      subnetIndex: 3, createdAt: Date(timeIntervalSince1970: 0), display: display)
  }

  @Test func aHeadlessRecordIsUnchangedOnDisk() throws {
    let json = try JSONEncoder.pretty.encode(try Self.record())
    let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    #expect(object["display"] == nil)
    #expect(object["guestComputerUse"] == nil)
    // A record written before display modes reads as headless.
    #expect(try JSONDecoder.iso.decode(SandboxRecord.self, from: json).displayMode == .headless)
  }

  @Test func aDisplayRecordRoundTrips() throws {
    let r = try Self.record(display: .virtio(guestComputerUse: try .init(frameRate: 4)))
    let json = try JSONEncoder.pretty.encode(r)
    let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    #expect(object["display"] as? String == "virtio_display")
    let back = try JSONDecoder.iso.decode(SandboxRecord.self, from: json)
    #expect(back.displayMode == .virtioDisplay)
    #expect(back.guestComputerUse == (try .init(frameRate: 4)))
  }

  @Test func aRecordWithGuestComputerUseAndNoDisplayDoesNotDecode() throws {
    let r = try Self.record(display: .virtio(guestComputerUse: try .init(frameRate: 4)))
    var object =
      try JSONSerialization.jsonObject(with: try JSONEncoder.pretty.encode(r)) as! [String: Any]
    object["display"] = nil
    let json = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try JSONDecoder.iso.decode(SandboxRecord.self, from: json)
    }
  }

  @Test func theTwoKernelPinsAreDisjoint() {
    #expect(KernelPin.allowed.isDisjoint(with: KernelPin.desktopAllowed))
    #expect(!KernelPin.desktopAllowed.isEmpty)
  }

  static func tempRoot() throws -> SandboxRoot {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "desk-\(UUID().uuidString)")
    let root = try SandboxRoot(dir.path)
    try root.createDirectories()
    return root
  }

  @Test func eachDisplayModeBootsItsOwnKernel() throws {
    let root = try Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root.root) }
    #expect(root.kernel != root.desktopKernel)
    #expect(try Owner.kernel(root: root, display: .headless) == root.kernel)
    // Missing, then present but not a pinned desktop kernel.
    #expect(throws: SandboxError.self) { try Owner.kernel(root: root, display: .virtioDisplay) }
    try Data("not a kernel".utf8).write(to: root.desktopKernel)
    #expect(throws: SandboxError.self) { try Owner.kernel(root: root, display: .virtioDisplay) }
  }

  @Test func aDesktopKernelInstallsBesideTheQualifiedOne() throws {
    let root = try Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root.root) }
    let candidate = root.root.appendingPathComponent("candidate")
    let bytes = Data("desktop kernel".utf8)
    try bytes.write(to: candidate)
    let sha = sha256Hex(bytes)
    let installed = try KernelPin.select(
      installed: root.desktopKernel, requested: candidate.path, allowed: [sha])
    #expect(installed.install && installed.sha256 == sha)
    // The qualified kernel's pin does not admit it.
    #expect(throws: SandboxError.self) {
      try KernelPin.select(
        installed: root.kernel, requested: candidate.path, allowed: KernelPin.allowed)
    }
    #expect(throws: SandboxError.self) {
      try KernelPin.select(
        installed: root.desktopKernel, requested: candidate.path,
        allowed: KernelPin.desktopAllowed)
    }
  }

  // MARK: control

  @Test func aDisplayOwnerReportsItsListenerAndCounts() throws {
    let rootfs = Mount.block(format: "ext4", source: "/r", destination: "/", options: [])
    func effective(_ display: SandboxDisplay) throws -> EffectiveConfig {
      let record = try Self.record(display: display)
      let config = Owner.machineConfiguration(
        record: record, interface: nil, bootLog: .file(path: URL(fileURLWithPath: "/dev/null")))
      return Owner.effectiveConfig(
        record: record, config: config, rootfs: rootfs,
        devices: Self.devices(display == .headless ? [] : [.virtio(scanouts: [Self.scanout])]))
    }
    // The listener state is part of every display report, and of no other.
    #expect(try effective(.virtio(guestComputerUse: nil)).liveViewListening == false)
    let headless = try effective(.headless)
    #expect(headless.liveViewListening == nil)
    #expect(
      !String(decoding: try JSONEncoder.wire.encode(headless), as: UTF8.self)
        .contains("liveViewListening"))

    // Guest counts carry the screen's preemptions; live-view counts appear
    // once a stream has started.
    var guest = MacGuestCUCounters(frameRate: 4)
    guest.frames = 7
    var liveView = MacLiveViewCounters()
    let idle = DesktopStatus(guest: guest, preemptions: 2, liveView: liveView)
    #expect(idle.guestComputerUse?.frames == 7 && idle.guestComputerUse?.preemptions == 2)
    #expect(idle.liveView == nil)
    liveView.streams = 1
    liveView.inputEvents = 9
    let streamed = DesktopStatus(guest: nil, preemptions: 2, liveView: liveView)
    #expect(streamed.guestComputerUse == nil && streamed.liveView == liveView)

    // `inspect` carries them as `runtime`, and only for a display sandbox.
    var response = ControlResponse(ok: true)
    response.desktop = streamed
    let back = try JSONDecoder.iso.decode(
      ControlResponse.self, from: try JSONEncoder.wire.encode(response))
    #expect(back.desktop == streamed)
    func inspect(_ runtime: DesktopStatus?) throws -> [String: Any] {
      let output = InspectOutput(
        record: try Self.record(), status: .running, live: nil, effective: nil, runtime: runtime,
        disk: DiskSummary(name: "rootfs", logicalBytes: 0, allocatedBytes: 0))
      return try JSONSerialization.jsonObject(with: try JSONEncoder.wire.encode(output))
        as! [String: Any]
    }
    #expect(try inspect(nil)["runtime"] == nil)
    let counts = try inspect(streamed)["runtime"] as? [String: Any]
    #expect((counts?["liveView"] as? [String: Any])?["inputEvents"] as? Int == 9)
  }

  @Test func onlyTheViewCacheTakesAUniformFrameForAMissingFramebuffer() {
    #expect(VMScreen.Capture.viewCache.refusesUniformFrames)
    // The surface read throws without a surface: a flat frame from it is a
    // bare desktop, not a missing framebuffer.
    #expect(!VMScreen.Capture.framebufferSurface.refusesUniformFrames)
  }

  @MainActor @Test func refusalsKeepTheirCode() {
    var e = SandboxError("busy", refusal: .busy)
    e.beforeInput = true
    let act = CUService.failure(e, op: .cuAct)
    #expect(!act.ok && act.refusal == .busy && act.beforeInput == true)
    let frame = CUService.failure(e, op: .cuFrame)
    #expect(frame.refusal == .busy && frame.beforeInput == nil)
  }
}
