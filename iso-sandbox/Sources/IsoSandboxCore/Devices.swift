import Containerization
import Foundation
import Virtualization

/// Devices on the live `VZVirtualMachine`, not the configuration iso asked
/// for, read after `create` and before the guest's own init runs. The
/// brokered contract's network-device count is this reading, and every
/// sandbox, whatever its network mode, must match `requireExpected`.
///
/// The live machine exposes directory-sharing, console, memory-balloon,
/// USB-controller, graphics, network and socket devices (the macOS 27 SDK's
/// `VZVirtualMachine`); storage, serial ports and entropy are visible only
/// on the configuration the framework built, which `Owner` does not hand
/// it any of beyond the root disks and the boot console.
package struct VMDevices: Sendable, Equatable {
  /// A network device's attachment, as found on the live device.
  package enum NetworkAttachment: Sendable, Equatable {
    /// A vmnet network (this runtime's per-sandbox network).
    case vmnet
    /// No attachment, or any other kind, by class name.
    case other(String)
  }

  /// A directory-sharing device and the share it currently carries. The
  /// share is runtime-mutable, so this is the reading at check time.
  package enum DirectorySharing: Sendable, Equatable {
    package enum Share: Sendable, Equatable {
      case none
      /// A `VZMultipleDirectoryShare` exposing this many host directories.
      case multiple(directories: Int)
      /// Any other share (a single directory, Rosetta), by class name.
      case other(String)
    }
    case virtioFS(tag: String, share: Share)
    /// Any other directory-sharing device, by class name.
    case other(String)
  }

  package var network: [NetworkAttachment]
  package var socket: Int
  package var directorySharing: [DirectorySharing]
  package var console: Int
  package var memoryBalloon: Int
  package var usbControllers: Int
  package var graphics: Int

  package init(
    network: [NetworkAttachment], socket: Int, directorySharing: [DirectorySharing] = [],
    console: Int = 0, memoryBalloon: Int = 0, usbControllers: Int = 0, graphics: Int = 0
  ) {
    self.network = network
    self.socket = socket
    self.directorySharing = directorySharing
    self.console = console
    self.memoryBalloon = memoryBalloon
    self.usbControllers = usbControllers
    self.graphics = graphics
  }

  /// The inventory a Linux sandbox in `mode` must have: one vsock device;
  /// one vmnet network device, or none for brokered; no console, balloon,
  /// USB or graphics device; and at most the one virtio-fs device
  /// `apple/containerization` always attaches, carrying no host directory.
  /// Anything else fails closed.
  package func requireExpected(for mode: NetworkMode) throws(SandboxError) {
    let expectedNetwork = mode == .brokered ? 0 : 1
    guard network.count == expectedNetwork, socket == 1 else {
      throw SandboxError(
        "the VM was created with \(network.count) network and \(socket) socket devices; expected \(expectedNetwork) and 1"
      )
    }
    if let attachment = network.first(where: { $0 != .vmnet }) {
      throw SandboxError("the VM has a network device with a non-vmnet attachment (\(attachment))")
    }
    let unexpected: [(String, Int)] = [
      ("console", console),
      ("memory balloon", memoryBalloon),
      ("USB controller", usbControllers),
      ("graphics", graphics),
    ]
    for (name, count) in unexpected where count > 0 {
      throw SandboxError("the VM has \(count) \(name) device(s); expected none")
    }
    guard directorySharing.count <= 1 else {
      throw SandboxError(
        "the VM has \(directorySharing.count) directory-sharing devices; expected at most 1")
    }
    for device in directorySharing {
      switch device {
      case .virtioFS(_, .none), .virtioFS(_, .multiple(directories: 0)):
        continue
      default:
        throw SandboxError("the VM shares host directories (\(device)); expected none")
      }
    }
  }

  static func read(_ container: LinuxContainer) async throws -> VMDevices {
    try await container.withVirtualMachineInstance { instance in
      guard let vz = instance as? VZVirtualMachineInstance else {
        throw SandboxError("the VM is not a Virtualization.framework machine")
      }
      return vz.vmQueue.sync { observe(vz.vzVirtualMachine) }
    }
  }

  /// Must run on the machine's queue.
  static func observe(_ vm: VZVirtualMachine) -> VMDevices {
    func name(_ object: AnyObject?) -> String {
      object.map { String(describing: type(of: $0)) } ?? "none"
    }
    return VMDevices(
      network: vm.networkDevices.map {
        $0.attachment is VZVmnetNetworkDeviceAttachment ? .vmnet : .other(name($0.attachment))
      },
      socket: vm.socketDevices.count,
      directorySharing: vm.directorySharingDevices.map { device in
        guard let fs = device as? VZVirtioFileSystemDevice else { return .other(name(device)) }
        let share: DirectorySharing.Share =
          switch fs.share {
          case nil: .none
          case let multiple as VZMultipleDirectoryShare:
            .multiple(directories: multiple.directories.count)
          case let other: .other(name(other))
          }
        return .virtioFS(tag: fs.tag, share: share)
      },
      console: vm.consoleDevices.count,
      memoryBalloon: vm.memoryBalloonDevices.count,
      usbControllers: vm.usbControllers.count,
      graphics: vm.graphicsDevices.count)
  }
}
