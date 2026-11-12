import Foundation
import IsoCore

// Linux guests with a virtio-gpu display (docs/design/linux-desktop-virtio-gpu.md):
// the image adapter that selects one, the runtime feature that creates one,
// and the isolation gate's expectations of its report.

extension RuntimeProtocol {
  /// `version` capability for `init --desktop-kernel`, `create --display
  /// virtio` and `cu` against Linux sandboxes.
  package static let linuxDisplayFeature = "linux-display"
}

extension SandboxRuntime {
  /// Refuses a runtime that cannot create a Linux sandbox with a display.
  package func requireLinuxDisplay() throws(RuntimeError) {
    _ = try requireQualified()
    guard features.contains(RuntimeProtocol.linuxDisplayFeature) else {
      throw .unqualified(
        "a desktop image needs an iso-sandbox advertising \(RuntimeProtocol.linuxDisplayFeature); rebuild it with scripts/build-iso-sandbox.sh"
      )
    }
  }
}

extension ImageManifest {
  /// The guest adapter of an image built with the `desktop` profile: a
  /// display server on `/dev/dri/card0`, so its instances are created with
  /// ``LinuxGuestDisplay/virtio``.
  package static let virtioDisplayAdapter = "virtio-display-v1"

  package var hasVirtioDisplay: Bool {
    guestOS == .linux && guestAdapters?.contains(Self.virtioDisplayAdapter) == true
  }

  /// Refuses to put this image's disk under an instance created with a
  /// different display. The display is fixed at create: a desktop instance
  /// on a disk without the adapter would bootstrap a computer-use server
  /// the disk lacks, and a headless one would boot a desktop disk with no
  /// display.
  package func requireDisplay(
    _ display: LinuxGuestDisplay?, image: ImageName, instance: InstanceName
  ) throws {
    switch (hasVirtioDisplay, display) {
    case (true, .virtio), (false, nil): return
    case (true, nil):
      throw HostError(
        "Image '\(image)' is a desktop image, but instance '\(instance)' was created without a display; create a new instance from it instead"
      )
    case (false, .virtio):
      throw HostError(
        "Image '\(image)' is not a desktop image, but instance '\(instance)' was created with a display; create a new instance from it instead"
      )
    }
  }
}

/// A Linux instance's display, fixed when its sandbox is created. Absent
/// (nil) for a headless instance, so its records are unchanged.
package enum LinuxGuestDisplay: String, Sendable, Equatable, Codable {
  /// The runtime's `virtio_display`: one 1920×1200 virtio-gpu scanout, a USB
  /// keyboard and a USB pointer.
  case virtio = "virtio_display"
}

/// The display members of a Linux sandbox's effective configuration: all
/// present for a display sandbox, all absent otherwise.
package struct EffectiveDisplay: Sendable, Equatable {
  package let display: String
  /// Each live graphics device's scanout sizes as `WxH`, or its class name.
  package let graphicsDevices: [[String]]
  /// Vsock ports the owner listens on.
  package let vsockPorts: [UInt32]
  /// Whether a loopback live-view listener is open now (`cu stream`, opt-in
  /// and token-gated), as a macOS owner reports it; absent from owners that
  /// predate the report: none.
  package let liveViewListening: Bool
}

/// A display sandbox owner's per-boot computer-use counts (`runtime` in
/// `inspect`), read before a stop for the audit (an ended boot's are in
/// ``EndedBoots``). An invalid report (a
/// negative count) is dropped: only the audit loses it.
package struct LinuxDesktopStatus: Sendable, Equatable, Decodable {
  /// Absent when the sandbox was created without guest-driven computer use.
  package let guestComputerUse: MacGuestCUCounts?
  /// Absent when no live-view stream started this boot.
  package let liveView: MacLiveViewCounts?

  enum CodingKeys: String, CodingKey { case guestComputerUse, liveView }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guestComputerUse =
      (try? c.decodeIfPresent(MacGuestCUCounts.self, forKey: .guestComputerUse)) ?? nil
    liveView = (try? c.decodeIfPresent(MacLiveViewCounts.self, forKey: .liveView)) ?? nil
  }
}

extension IsolationGate {
  /// The display a Linux sandbox must report.
  package enum ExpectedDisplay: Sendable, Equatable {
    case headless
    /// A virtio display; with guest-driven computer use the owner listens
    /// on vsock 7802 and on nothing else.
    case virtio(guestComputerUse: Bool)

    package init(_ display: LinuxGuestDisplay?, guestComputerUse: Bool) {
      switch display {
      case nil: self = .headless
      case .virtio: self = .virtio(guestComputerUse: guestComputerUse)
      }
    }
  }

  /// `GuestCUProtocol.port` in iso-sandbox.
  static let guestComputerUsePort: UInt32 = 7802
  /// `LinuxDisplay` in iso-sandbox.
  static let displayGeometry = "1920x1200"

  /// The recorded display mode against the expected one.
  static func verifyRecordedDisplay(
    _ name: MachineName, _ recorded: String?, _ expected: ExpectedDisplay
  )
    throws(RuntimeError)
  {
    let wanted: String? =
      switch expected {
      case .headless: nil
      case .virtio: LinuxGuestDisplay.virtio.rawValue
      }
    guard recorded == wanted else {
      throw .identityConflict(
        "sandbox \(name) records display \(debugQuoted(sanitizeForDisplay(recorded ?? "headless"))), expected \(wanted ?? "headless")"
      )
    }
  }

  /// The owner's display report: none for a headless sandbox; for a display
  /// sandbox exactly one virtio device with one scanout of the fixed
  /// geometry, and vsock 7802 exactly when guest computer use is on.
  static func verifyDisplay(
    _ name: MachineName, _ effective: Effective, _ expected: ExpectedDisplay
  )
    throws(RuntimeError)
  {
    switch expected {
    case .headless:
      guard effective.display == nil else {
        throw .hostExposure("headless sandbox \(name) reports a display")
      }
    case .virtio(let guestComputerUse):
      guard let display = effective.display, display.display == LinuxGuestDisplay.virtio.rawValue
      else {
        throw .hostExposure("sandbox \(name) does not report its virtio display")
      }
      guard display.graphicsDevices == [[displayGeometry]] else {
        throw .hostExposure(
          "sandbox \(name) reports graphics devices \(sanitizeForDisplay("\(display.graphicsDevices)")); expected one \(displayGeometry) virtio scanout"
        )
      }
      let ports: [UInt32] = guestComputerUse ? [guestComputerUsePort] : []
      guard display.vsockPorts == ports else {
        throw .hostExposure(
          "sandbox \(name) listens on vsock ports \(display.vsockPorts); expected \(ports)")
      }
    }
  }
}
