import Foundation
import IOKit

/// The guest side of `coreai_status` (docs/design/paravirtualized-coreai.md):
/// which Core AI compute kinds this guest can use and whether the
/// paravirtualized delegate's feature flag is on. Read-only.
enum CoreAIProbe {
  static let flagPath = "/Library/Preferences/FeatureFlags/Domain/ParavirtualizedCoreAI.plist"

  /// IOKit classes whose presence means the kind is backed by a
  /// paravirtual device. `PVAIDevice` is the guest GPU device the 27.3
  /// finding names; the Neural Engine class is the one Apple Silicon's
  /// driver registers. Both are confirmed in qualification (Gate AI).
  static let deviceClasses: [(kind: String, classes: [String])] = [
    ("gpu", ["PVAIDevice"]),
    ("neuralEngine", ["H11ANEIn"]),
  ]

  /// `cpu` always, then each kind whose device is present, named as
  /// `ComputeUnitKind` names them.
  static func availableKinds() -> [String] {
    ["cpu"]
      + deviceClasses.compactMap { entry in
        entry.classes.contains(where: serviceExists) ? entry.kind : nil
      }
  }

  static func serviceExists(_ className: String) -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
    guard service != IO_OBJECT_NULL else { return false }
    IOObjectRelease(service)
    return true
  }

  /// `enable_pv_delegate = {Enabled = true}` in the feature-flag domain.
  static func delegateEnabled(path: String = flagPath) -> Bool {
    guard let domain = NSDictionary(contentsOfFile: path),
      let flag = domain["enable_pv_delegate"] as? [String: Any]
    else { return false }
    return flag["Enabled"] as? Bool == true
  }
}
