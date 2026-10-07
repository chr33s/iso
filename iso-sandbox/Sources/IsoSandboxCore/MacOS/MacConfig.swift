import Containerization
import Foundation
import IsoMacProtocol
import Virtualization

/// Builds a macOS guest's `VZVirtualMachineConfiguration`: one display, one
/// absolute pointing device, one keyboard, one vmnet network device, one
/// vsock device, the clone's own disk, entropy. Nothing else: no directory
/// shares, audio, serial ports, USB, clipboard or host sockets (Gate O).
package enum MacConfig {
  package static func hardwareModel(_ url: URL) throws -> VZMacHardwareModel {
    guard let data = try? Data(contentsOf: url),
      let model = VZMacHardwareModel(dataRepresentation: data)
    else { throw SandboxError("unreadable hardware model \(url.path)") }
    guard model.isSupported else { throw SandboxError("hardware model not supported on this host") }
    return model
  }

  package static func machineIdentifier(_ url: URL) throws -> VZMacMachineIdentifier {
    guard let data = try? Data(contentsOf: url),
      let id = VZMacMachineIdentifier(dataRepresentation: data)
    else { throw SandboxError("unreadable machine identifier \(url.path)") }
    return id
  }

  package static func make(
    hardwareModel: VZMacHardwareModel, machineIdentifier: VZMacMachineIdentifier, aux: URL,
    disk: URL, cpus: Int, memoryBytes: UInt64, network: VZNetworkDeviceConfiguration
  ) throws -> VZVirtualMachineConfiguration {
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hardwareModel
    platform.machineIdentifier = machineIdentifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: aux)

    let c = VZVirtualMachineConfiguration()
    c.platform = platform
    c.bootLoader = VZMacOSBootLoader()
    c.cpuCount = cpus
    c.memorySize = memoryBytes
    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [
      VZMacGraphicsDisplayConfiguration(
        widthInPixels: MacDisplay.width, heightInPixels: MacDisplay.height,
        pixelsPerInch: MacDisplay.pixelsPerInch)
    ]
    c.graphicsDevices = [gfx]
    c.storageDevices = [
      VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))
    ]
    c.networkDevices = [network]
    c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    c.keyboards = [VZMacKeyboardConfiguration()]
    c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    try c.validate()
    try requireOnlyExpectedDevices(c)
    return c
  }

  /// Fails closed on any device this runtime did not put there.
  static func requireOnlyExpectedDevices(_ c: VZVirtualMachineConfiguration) throws {
    let unexpected: [(String, Int)] = [
      ("directory sharing", c.directorySharingDevices.count),
      ("audio", c.audioDevices.count),
      ("serial port", c.serialPorts.count),
      ("console", c.consoleDevices.count),
      ("memory balloon", c.memoryBalloonDevices.count),
      ("USB controller", c.usbControllers.count),
    ]
    for (name, count) in unexpected where count > 0 {
      throw SandboxError("refusing configuration with \(count) \(name) device(s)")
    }
    guard c.graphicsDevices.count == 1, c.storageDevices.count == 1, c.networkDevices.count == 1,
      c.pointingDevices.count == 1, c.keyboards.count == 1, c.socketDevices.count == 1
    else { throw SandboxError("refusing configuration with unexpected device counts") }
    // Only a vmnet network of this runtime's own: no NAT shared with other
    // VMs, no bridged or file-handle attachment.
    guard c.networkDevices.allSatisfy({ $0.attachment is VZVmnetNetworkDeviceAttachment }) else {
      throw SandboxError("refusing configuration with a non-vmnet network attachment")
    }
  }
}

/// What a running macOS guest was configured with (Gate O), read back from
/// the configuration the owner built.
package struct MacEffectiveConfig: Codable, Sendable {
  package var id: String
  package var template: String
  package var cpus: Int
  package var memoryBytes: UInt64
  package var displays: [String]
  package var pointingDevices: [String]
  package var keyboards: [String]
  package var storage: [String]
  package var network: String
  package var macAddress: String
  package var vsockPorts: [UInt32]
  package var directoryShares: Int
  package var audioDevices: Int
  package var serialPorts: Int
  package var usbControllers: Int
  package var clipboard: Bool
  package var ownerTopology: String

  /// Read from the configuration the VM booted with and the listeners it
  /// registered, not restated: an extra disk, socket listener, console or
  /// network attachment shows up here and fails the host's gate. The vmnet
  /// mode is not queryable from a network object, so it comes from the
  /// record; the subnet is the network's own.
  static func from(
    _ c: VZVirtualMachineConfiguration, record: MacSandboxRecord, vsockPorts: [UInt32],
    topology: String
  ) -> MacEffectiveConfig {
    MacEffectiveConfig(
      id: record.id.rawValue, template: record.template.rawValue, cpus: c.cpuCount,
      memoryBytes: c.memorySize,
      displays: c.graphicsDevices.flatMap { g in
        (g as? VZMacGraphicsDeviceConfiguration)?.displays.map {
          "\($0.widthInPixels)x\($0.heightInPixels)@\($0.pixelsPerInch)ppi"
        } ?? ["unknown"]
      },
      pointingDevices: c.pointingDevices.map { String(describing: type(of: $0)) },
      keyboards: c.keyboards.map { String(describing: type(of: $0)) },
      storage: c.storageDevices.map { device in
        ((device as? VZVirtioBlockDeviceConfiguration)?.attachment
          as? VZDiskImageStorageDeviceAttachment)?
          .url.path ?? "unknown:\(type(of: device))"
      },
      network: networkLabel(c, record: record),
      macAddress: (c.networkDevices.first?.macAddress.string ?? "").lowercased(),
      vsockPorts: c.socketDevices.count == 1 ? vsockPorts : [],
      directoryShares: c.directorySharingDevices.count, audioDevices: c.audioDevices.count,
      serialPorts: c.serialPorts.count, usbControllers: c.usbControllers.count,
      // A clipboard (the SPICE agent) needs a console device.
      clipboard: !c.consoleDevices.isEmpty, ownerTopology: topology)
  }

  static func networkLabel(_ c: VZVirtualMachineConfiguration, record: MacSandboxRecord) -> String {
    guard c.networkDevices.count == 1,
      let vmnet = c.networkDevices[0].attachment as? VZVmnetNetworkDeviceAttachment
    else { return "devices:\(c.networkDevices.count)" }
    var subnet = in_addr()
    var mask = in_addr()
    vmnet_network_get_ipv4_subnet(vmnet.network, &subnet, &mask)
    let address = UInt32(bigEndian: subnet.s_addr) & UInt32(bigEndian: mask.s_addr)
    let prefix = UInt32(bigEndian: mask.s_addr).nonzeroBitCount
    let octets = (0..<4).map { String((address >> (24 - 8 * $0)) & 0xff) }.joined(separator: ".")
    return "\(record.network == .shared ? "vmnet-shared" : "vmnet-host"):\(octets)/\(prefix)"
  }
}
