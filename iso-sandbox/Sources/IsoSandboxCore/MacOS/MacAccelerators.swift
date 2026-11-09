import Foundation
import Virtualization

/// Paravirtualized Core AI accelerators for macOS guests
/// (docs/design/paravirtualized-coreai.md). The devices are private
/// Virtualization.framework API that loads only with
/// `com.apple.private.virtualization`, so every reference to them is
/// compiled only into the experimental `iso-sandbox-coreai` build
/// (`-DISO_COREAI`). The default build attaches nothing and reads back
/// nothing, so its Gate O check is unchanged.
///
/// Classes and selectors are resolved at run time: absent means
/// unavailable, never a crash.
package enum MacAccelerators {
  /// Whether this binary was built with Core AI support.
  package static var compiledIn: Bool {
    #if ISO_COREAI
      true
    #else
      false
    #endif
  }

  /// The macOS release (host and guest) that introduced the devices.
  package static let minimumVersion = OperatingSystemVersion(
    majorVersion: 27, minorVersion: 3, patchVersion: 0)

  package static func atLeastMinimum(_ v: OperatingSystemVersion) -> Bool {
    (v.majorVersion, v.minorVersion, v.patchVersion)
      >= (minimumVersion.majorVersion, minimumVersion.minorVersion, minimumVersion.patchVersion)
  }

  package static var minimumVersionString: String {
    "\(minimumVersion.majorVersion).\(minimumVersion.minorVersion)"
  }

  #if ISO_COREAI
    static let setter = "_setAcceleratorDevices:"
    static let getter = "_acceleratorDevices"

    /// The device configuration class for `kind`.
    package static func className(_ kind: MacAccelerator) -> String {
      switch kind {
      case .gpu: "_VZMacCoreAIDeviceConfiguration"
      case .neuralEngine: "_VZMacNeuralEngineDeviceConfiguration"
      }
    }

    /// The selector is reported on `VZVirtualMachineConfiguration`; the
    /// platform configuration is the fallback until that is confirmed.
    static func owner(of selector: String, in c: VZVirtualMachineConfiguration) -> NSObject? {
      let sel = NSSelectorFromString(selector)
      if c.responds(to: sel) { return c }
      if c.platform.responds(to: sel) { return c.platform }
      return nil
    }
  #endif

  /// True when both device classes and the setter resolve on this host.
  package static func isAvailable() -> Bool {
    #if ISO_COREAI
      MacAccelerator.allCases.allSatisfy { NSClassFromString(className($0)) != nil }
        && owner(of: setter, in: VZVirtualMachineConfiguration()) != nil
    #else
      false
    #endif
  }

  /// Attaches exactly `kinds` to `c`.
  package static func apply(_ kinds: [MacAccelerator], to c: VZVirtualMachineConfiguration)
    throws
  {
    guard !kinds.isEmpty else { return }
    #if ISO_COREAI
      var devices: [NSObject] = []
      for kind in kinds {
        guard let type = NSClassFromString(className(kind)) as? NSObject.Type else {
          throw SandboxError("Core AI accelerators unavailable on this host")
        }
        devices.append(type.init())
      }
      guard let target = owner(of: setter, in: c) else {
        throw SandboxError("Core AI accelerators unavailable on this host")
      }
      _ = target.perform(NSSelectorFromString(setter), with: devices as NSArray)
    #else
      throw SandboxError(
        "this iso-sandbox build has no Core AI support; build iso-sandbox-coreai with scripts/build-iso-sandbox.sh --experimental-coreai (see docs/coreai.md)"
      )
    #endif
  }

  /// The class names of the accelerator devices attached to `c`; empty
  /// when none are, or the getter does not resolve.
  package static func attached(_ c: VZVirtualMachineConfiguration) -> [String] {
    #if ISO_COREAI
      guard let target = owner(of: getter, in: c),
        let devices = target.perform(NSSelectorFromString(getter))?.takeUnretainedValue()
          as? [AnyObject]
      else { return [] }
      return devices.map { NSStringFromClass(type(of: $0)) }
    #else
      return []
    #endif
  }

  /// Fails unless `c` carries exactly the `expected` accelerators: none
  /// when Core AI is off, and only the two known device classes.
  package static func requireExactly(
    _ expected: [MacAccelerator], in c: VZVirtualMachineConfiguration
  ) throws {
    try requireExactly(expected, attached: attached(c))
  }

  static func requireExactly(_ expected: [MacAccelerator], attached: [String]) throws {
    guard !expected.isEmpty || !attached.isEmpty else { return }
    #if ISO_COREAI
      let known = Set(MacAccelerator.allCases.map(className))
      if let unknown = attached.first(where: { !known.contains($0) }) {
        throw SandboxError("refusing configuration with unknown accelerator \(unknown)")
      }
      guard attached.sorted() == expected.map(className).sorted() else {
        throw SandboxError(
          "refusing configuration with accelerators \(attached.sorted()); expected \(expected.map(\.rawValue))"
        )
      }
    #else
      throw SandboxError(
        "refusing configuration: \(expected.count) Core AI accelerator(s) requested, \(attached.count) attached; this iso-sandbox build has no Core AI support"
      )
    #endif
  }
}

/// The host-side preconditions of `com.apple.private.virtualization`: the
/// entitlement loads on a non-Apple binary only with AMFI relaxed. iso never
/// changes boot-args or SIP; it reports the state and refuses a fully
/// secured host.
package enum MacHostSecurity {
  package struct Report: Equatable, Sendable {
    /// Whether code-signing enforcement is relaxed on this host.
    package var reduced: Bool
    /// What was found, for the owner log and errors.
    package var detail: String
  }

  /// Boot-args that turn AMFI's enforcement off.
  static let amfiBootArgs = ["amfi_get_out_of_my_way=1", "amfi_get_out_of_my_way=0x1", "amfi=0xff"]

  package static func evaluate(bootArgs: String, csrStatus: String) -> Report {
    let args = bootArgs.split(separator: " ").map(String.init)
    let amfi = args.filter { amfiBootArgs.contains($0) }
    let sip = csrStatus.lowercased()
    let sipEnabled = sip.contains("status: enabled.")
    var found: [String] = []
    if !amfi.isEmpty { found.append("boot-args \(amfi.joined(separator: " "))") }
    if !sipEnabled {
      found.append(sip.contains("disabled") ? "SIP disabled" : "SIP custom configuration")
    }
    guard !amfi.isEmpty else {
      return Report(
        reduced: false,
        detail: found.isEmpty
          ? "host is fully secured (no AMFI boot-args, SIP enabled)"
          : "AMFI is enforcing (\(found.joined(separator: ", ")); no AMFI boot-args)")
    }
    return Report(reduced: true, detail: found.joined(separator: ", "))
  }

  /// Reads `kern.bootargs` and `csrutil status` (a fixed argv, no input).
  package static func current() -> Report {
    var size = 0
    sysctlbyname("kern.bootargs", nil, &size, nil, 0)
    var buf = [UInt8](repeating: 0, count: max(size, 1))
    sysctlbyname("kern.bootargs", &buf, &size, nil, 0)
    let bootArgs = String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    let csr =
      (try? Subprocess.run(
        ["/usr/bin/csrutil", "status"], environment: ["PATH": "/usr/bin:/bin"], stdin: nil,
        timeout: 10))?.output ?? ""
    return evaluate(bootArgs: bootArgs, csrStatus: csr)
  }

  /// The owner's preflight for a Core AI sandbox, before any VM is built.
  package static func preflight(
    hostVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    report: () -> Report = current
  ) throws -> Report {
    guard MacAccelerators.compiledIn else {
      throw SandboxError(
        "this sandbox was created with Core AI, which needs the experimental iso-sandbox-coreai build (see docs/coreai.md)"
      )
    }
    guard MacAccelerators.atLeastMinimum(hostVersion) else {
      throw SandboxError(
        "Core AI needs a macOS \(MacAccelerators.minimumVersionString) host; this host runs \(hostVersion.majorVersion).\(hostVersion.minorVersion).\(hostVersion.patchVersion)"
      )
    }
    let r = report()
    guard r.reduced else {
      throw SandboxError(
        "Core AI refused: \(r.detail). com.apple.private.virtualization loads only with AMFI relaxed, which iso never changes for you; see docs/coreai.md"
      )
    }
    guard MacAccelerators.isAvailable() else {
      throw SandboxError(
        "Core AI accelerators unavailable on this host (the private device classes did not resolve)"
      )
    }
    return r
  }
}
