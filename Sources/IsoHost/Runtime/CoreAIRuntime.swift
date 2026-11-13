import Foundation
import IsoConfiguration
import IsoCore
import Security

/// The experimental `iso-sandbox-coreai` build `coreai` needs
/// (docs/design/paravirtualized-coreai.md): built with `-DISO_COREAI` and signed
/// with `com.apple.private.virtualization`. Never released; iso only selects and
/// checks it before handing it a Core AI sandbox.
package enum CoreAIRuntime {
  package static let binaryName = "iso-sandbox-coreai"
  package static let entitlement = "com.apple.private.virtualization"
  package static let missing =
    "Core AI requires the experimental iso-sandbox-coreai build; see docs/coreai.md"

  /// The entitlements `path` is signed with; empty when it carries none.
  static func entitlements(_ path: String) throws -> [String: Any] {
    var code: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
    guard status == errSecSuccess, let code else {
      throw HostError("\(missing) (cannot read the signature of \(path): OSStatus \(status))")
    }
    var information: CFDictionary?
    status = SecCodeCopySigningInformation(
      code, SecCSFlags(rawValue: kSecCSRequirementInformation), &information)
    guard status == errSecSuccess, let information = information as? [String: Any] else {
      throw HostError("\(missing) (cannot read the entitlements of \(path): OSStatus \(status))")
    }
    return information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
  }

  /// Refuses a runtime that does not advertise Core AI or whose signature
  /// lacks the private entitlement.
  static func check(features: Set<String>, entitlements: [String: Any]?) throws {
    guard features.contains(RuntimeProtocol.macCoreAIFeature) else {
      throw HostError("\(missing) (this iso-sandbox does not advertise \"macos-coreai\")")
    }
    if let entitlements, entitlements[entitlement] as? Bool != true {
      throw HostError("\(missing) (its signature lacks \(entitlement))")
    }
  }
}

extension SandboxRuntime {
  /// For a Core AI sandbox: this runtime is the experimental build. As for
  /// companions, only a release build of iso reads the signature.
  package func requireCoreAI() throws {
    try requireMacGuests()
    #if ISO_RELEASE_BUILD
      guard let binary = (executor as? ProcessRuntimeExecutor)?.binary else {
        throw HostError("\(CoreAIRuntime.missing) (no runtime binary whose signature to check)")
      }
      let entitlements: [String: Any]? = try CoreAIRuntime.entitlements(binary)
    #else
      let entitlements: [String: Any]? = nil
    #endif
    try CoreAIRuntime.check(features: features, entitlements: entitlements)
  }
}

package enum CoreAIReport: Equatable, Sendable {
  case ok(String)
  /// Fewer kinds than requested, or no report: the instance still starts.
  case degraded(String)

  /// `ComputeUnitKind`'s name for a configured accelerator.
  static func kind(_ accelerator: String) -> String {
    accelerator == CoreAIConfig.Accelerator.neuralEngine.rawValue ? "neuralEngine" : accelerator
  }

  /// Whether `probe` reports every requested kind with the delegate on.
  package static func covers(_ recorded: MacCoreAIRecord, _ probe: MacCoreAIProbe?) -> Bool {
    guard let probe, probe.delegateEnabled else { return false }
    return recorded.accelerators.map(kind).allSatisfy(probe.availableKinds.contains)
  }

  package static func line(recorded: MacCoreAIRecord, probe: MacCoreAIProbe?) -> CoreAIReport {
    let requested = recorded.accelerators.map(kind)
    let suffix = "(paravirtualized; host security reduced)"
    guard let probe else {
      return .degraded(
        "core ai: requested \(requested.joined(separator: ", ")) \(suffix), but the guest has not reported its compute kinds"
      )
    }
    let missing = requested.filter { !probe.availableKinds.contains($0) }
    guard missing.isEmpty, probe.delegateEnabled else {
      let found = probe.availableKinds.filter { $0 != "cpu" }
      return .degraded(
        "core ai: guest reports \(found.isEmpty ? "no accelerators" : found.joined(separator: ", ")) of requested \(requested.joined(separator: ", ")) \(suffix)"
          + (probe.delegateEnabled ? "" : "; the paravirtualized delegate flag is off"))
    }
    return .ok("core ai: \(requested.joined(separator: ", ")) \(suffix)")
  }
}

/// The device class the owner attaches for each configured accelerator,
/// as `MacEffective.accelerators` reports it. Plain strings: the host
/// never touches the private classes.
package enum CoreAIDevices {
  package static func className(_ accelerator: String) -> String? {
    switch accelerator {
    case CoreAIConfig.Accelerator.gpu.rawValue: "_VZMacCoreAIDeviceConfiguration"
    case CoreAIConfig.Accelerator.neuralEngine.rawValue: "_VZMacNeuralEngineDeviceConfiguration"
    default: nil
    }
  }
}
