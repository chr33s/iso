import AppKit
import Containerization
import Foundation
import IsoMacProtocol
import Virtualization

/// The display side of a ``DisplayMode/virtioDisplay`` owner
/// (docs/design/linux-desktop-virtio-gpu.md §6, §8): the VM's
/// `VZVirtualMachineView` in an ordered-out window, host computer use over
/// the control socket, the opt-in live view, and, when the sandbox was
/// created with it, guest-driven computer use on vsock 7802. The owner runs
/// the AppKit main loop for it (`Entry`).
@MainActor
package final class LinuxDesktop {
  let screen: VMScreen
  let liveView: LiveViewSession
  /// Nil unless the sandbox was created with guest-driven computer use.
  let guestLink: MacGuestCULink?
  private var accepting: Task<Void, Never>?
  /// Set when the owner begins to halt: no live view starts after it.
  private var halting = false

  private init(screen: VMScreen, liveView: LiveViewSession, guestLink: MacGuestCULink?) {
    self.screen = screen
    self.liveView = liveView
    self.guestLink = guestLink
  }

  /// The binding a Linux guest's sessions hold. A Linux guest cannot reboot
  /// inside its VM: its init exiting ends the container and so this owner.
  /// The owner's boot is therefore also the guest's boot, and both come
  /// from the host; nothing guest-reported takes part.
  nonisolated static func binding(bootId: String, vmInstance: String) -> CUBinding {
    CUBinding(
      bootId: bootId, vmInstance: vmInstance, guestBoot: bootId, helperGeneration: 0,
      width: LinuxDisplay.width, height: LinuxDisplay.height)
  }

  /// Attaches to the created and started VM.
  static func attach(
    _ container: LinuxContainer, bootId: String, guestComputerUse: MacGuestComputerUse?,
    log: @escaping @Sendable (String) -> Void
  ) async throws -> LinuxDesktop {
    let adaptor = try await container.withVirtualMachineInstance { instance in
      guard let vz = instance as? VZVirtualMachineInstance else {
        throw SandboxError("the VM is not a Virtualization.framework machine")
      }
      let made = vz.vmQueue.sync {
        VZVirtualMachineViewAdaptor(virtualMachine: vz.vzVirtualMachine)
      }
      return made
    }
    let binding = binding(bootId: bootId, vmInstance: makeBootID())
    let screen = VMScreen(adaptor: adaptor, capture: .framebufferSurface) { binding }
    let guestLink = guestComputerUse.map { guestCU in
      MacGuestCULink(frameRate: guestCU.frameRate, log: log) { request in
        await MacGuestCULink.serve(request, screen: screen)
      }
    }
    let desktop = LinuxDesktop(
      screen: screen, liveView: LiveViewSession(screen: screen, log: log), guestLink: guestLink)
    if let guestLink {
      let listener = try await container.withVirtualMachineInstance {
        try $0.listen(GuestCUProtocol.port)
      }
      desktop.accepting = Task.detached {
        for await handle in listener {
          // The link owns the descriptor from here and closes it.
          guestLink.accept(fd: handle.fileDescriptor, retaining: nil)
        }
      }
      log("guest computer use listening on vsock \(GuestCUProtocol.port)")
    }
    return desktop
  }

  /// The vsock ports the host side listens on, for the effective config.
  var listenerPorts: [UInt32] { guestLink == nil ? [] : [GuestCUProtocol.port] }

  /// This boot's counts, for `inspect` and so the host's stop-time audit.
  var status: DesktopStatus {
    DesktopStatus(
      guest: guestLink?.counters, preemptions: screen.preemptions, liveView: liveView.counters)
  }

  /// One host computer-use request. No session check precedes the
  /// screen's own: the guest has no helper whose identity a session could
  /// pin.
  func respond(_ request: CURequest) async -> MacControlResponse {
    await CUService.respond(
      request, screen: screen, liveView: liveView,
      streams: .deciding(vmState: "running", halting: halting)
    ) {}
  }

  /// The owner is halting, however it was asked (`stop`, a signal, session
  /// expiry, guest poweroff): the live view ends now and none starts again.
  func stop() {
    halting = true
    liveView.stop()
    accepting?.cancel()
  }
}
