import Synchronization
import Testing

@testable import IsoSandboxCore

/// The live-VM inventory every Linux sandbox must have, checked without a
/// VM. `apple/containerization` always attaches one virtio-fs device
/// (tag "virtiofs") with an empty multiple-directory share.
struct DeviceInventoryTests {
  static let frameworkShare = VMDevices.DirectorySharing.virtioFS(
    tag: "virtiofs", share: .multiple(directories: 0))

  static func expected(_ mode: NetworkMode) -> VMDevices {
    VMDevices(
      network: mode == .brokered ? [] : [.vmnet], socket: 1,
      directorySharing: [frameworkShare])
  }

  @Test(arguments: [NetworkMode.shared, .hostOnly, .brokered])
  func theFrameworkInventoryIsAccepted(mode: NetworkMode) throws {
    try Self.expected(mode).requireExpected(for: mode)
    // Without the framework's share, or with no share on the device.
    var bare = Self.expected(mode)
    bare.directorySharing = []
    try bare.requireExpected(for: mode)
    bare.directorySharing = [.virtioFS(tag: "virtiofs", share: .none)]
    try bare.requireExpected(for: mode)
  }

  @Test func aNetworkCountOtherThanTheModesIsRefused() {
    var brokered = Self.expected(.brokered)
    brokered.network = [.vmnet]
    #expect(throws: SandboxError.self) { try brokered.requireExpected(for: .brokered) }
    var shared = Self.expected(.shared)
    shared.network = []
    #expect(throws: SandboxError.self) { try shared.requireExpected(for: .shared) }
    shared.network = [.vmnet, .vmnet]
    #expect(throws: SandboxError.self) { try shared.requireExpected(for: .shared) }
  }

  @Test func aNonVmnetAttachmentIsRefused() {
    var shared = Self.expected(.shared)
    shared.network = [.other("VZNATNetworkDeviceAttachment")]
    #expect(throws: SandboxError.self) { try shared.requireExpected(for: .shared) }
    shared.network = [.other("none")]
    #expect(throws: SandboxError.self) { try shared.requireExpected(for: .hostOnly) }
  }

  @Test(arguments: [0, 2])
  func anythingButOneSocketDeviceIsRefused(count: Int) {
    var devices = Self.expected(.brokered)
    devices.socket = count
    #expect(throws: SandboxError.self) { try devices.requireExpected(for: .brokered) }
  }

  @Test func aSharedHostDirectoryIsRefused() {
    let refused: [[VMDevices.DirectorySharing]] = [
      [.virtioFS(tag: "virtiofs", share: .multiple(directories: 1))],
      [.virtioFS(tag: "rosetta", share: .other("VZLinuxRosettaDirectoryShare"))],
      [.virtioFS(tag: "virtiofs", share: .other("VZSingleDirectoryShare"))],
      [.other("VZDirectorySharingDevice")],
      [Self.frameworkShare, Self.frameworkShare],
    ]
    for sharing in refused {
      var devices = Self.expected(.shared)
      devices.directorySharing = sharing
      #expect(throws: SandboxError.self) { try devices.requireExpected(for: .shared) }
    }
  }

  @Test func anyConsoleBalloonUSBOrGraphicsDeviceIsRefused() {
    let mutations: [(inout VMDevices) -> Void] = [
      { $0.console = 1 }, { $0.memoryBalloon = 1 }, { $0.usbControllers = 1 },
      { $0.graphics = 1 },
    ]
    for mode in [NetworkMode.shared, .hostOnly, .brokered] {
      for mutate in mutations {
        var devices = Self.expected(mode)
        mutate(&devices)
        #expect(throws: SandboxError.self) { try devices.requireExpected(for: mode) }
      }
    }
  }

  /// The owner's path, not only the pure check: an unexpected inventory, or
  /// one that cannot be read, stops the VM before its init runs.
  @Test func theOwnerStopsAVMWhoseInventoryIsUnexpected() async throws {
    let id = try SandboxID("devices")
    let stops = Mutex(0)
    var console = Self.expected(.brokered)
    console.console = 1
    await #expect(throws: SandboxError.self) {
      try await Owner.checkDevices(
        of: id, mode: .brokered, read: { console }, stop: { stops.withLock { $0 += 1 } })
    }
    #expect(stops.withLock { $0 } == 1)
    // A shared-mode inventory is wrong for brokered.
    await #expect(throws: SandboxError.self) {
      try await Owner.checkDevices(
        of: id, mode: .brokered, read: { Self.expected(.shared) },
        stop: { stops.withLock { $0 += 1 } })
    }
    #expect(stops.withLock { $0 } == 2)
    await #expect(throws: SandboxError.self) {
      try await Owner.checkDevices(
        of: id, mode: .shared, read: { throw SandboxError("no instance") },
        stop: { stops.withLock { $0 += 1 } })
    }
    #expect(stops.withLock { $0 } == 3)
    let accepted = try await Owner.checkDevices(
      of: id, mode: .shared, read: { Self.expected(.shared) },
      stop: { stops.withLock { $0 += 1 } })
    #expect(accepted == Self.expected(.shared))
    #expect(stops.withLock { $0 } == 3)
  }
}
