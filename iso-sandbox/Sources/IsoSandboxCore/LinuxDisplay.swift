import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

/// Fixed display geometry of a ``DisplayMode/virtioDisplay`` sandbox: the
/// same as every macOS guest's, so a coordinate means the same thing on both
/// guest families (docs/design/linux-desktop-virtio-gpu.md §4).
package enum LinuxDisplay {
  package static let width = MacDisplay.width
  package static let height = MacDisplay.height
}

/// The display devices of a ``DisplayMode/virtioDisplay`` sandbox, added to
/// the finished `VZVirtualMachineConfiguration` just before it is
/// validated. A fixed value: nothing in it comes from the guest or the
/// image.
struct VirtioDisplayDevices: VZInstanceExtension {
  func configureVZ(
    _ config: inout VZVirtualMachineConfiguration, allocator: any AddressAllocator<Character>,
    storageDeviceCount: Int, mountsByID: [String: [Containerization.Mount]]
  ) throws {
    // The framework adds none of these; finding any means it changed.
    guard config.graphicsDevices.isEmpty, config.keyboards.isEmpty,
      config.pointingDevices.isEmpty
    else {
      throw SandboxError(
        "the VM configuration already has graphics or input devices; refusing to add more")
    }
    let gpu = VZVirtioGraphicsDeviceConfiguration()
    gpu.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: LinuxDisplay.width, heightInPixels: LinuxDisplay.height)
    ]
    config.graphicsDevices = [gpu]
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  }
}

/// `LinuxContainer` builds its VM configuration without `extensions`
/// (containerization 0.54.0, `LinuxContainer.swift:794`); this manager
/// appends them before creating the VM. Only the display mode's own
/// extensions are ever passed.
struct ExtendingManager: VirtualMachineManager {
  let inner: VZVirtualMachineManager
  let extensions: [any Sendable]

  func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
    var extended = StandardVMConfig(configuration: config.configuration)
    extended.configuration.extensions += extensions
    return try inner.create(config: extended)
  }
}

extension DisplayMode {
  /// The manager that creates this mode's VM: the bare manager for a
  /// headless sandbox, so its configuration is unchanged.
  func manager(_ inner: VZVirtualMachineManager) -> any VirtualMachineManager {
    switch self {
    case .headless: inner
    case .virtioDisplay: ExtendingManager(inner: inner, extensions: [VirtioDisplayDevices()])
    }
  }
}
