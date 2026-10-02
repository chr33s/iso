import Foundation
import IsoCore

/// Metadata prerequisites for filtered handoffs. AppleBackend additionally
/// requires fresh authenticated companion and guest-loopback responses.
public enum FilteredHandoff {
  /// Written atomically when the companion starts for this boot. This is
  /// descriptive host state, not a persisted live-readiness proof.
  public struct BootPolicy: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let backend: String
    public let bootID: String
    public let policyHash: String

    init(bootID: String, policyHash: String) {
      schemaVersion = 1
      backend = StateSchema.backend
      self.bootID = bootID
      self.policyHash = policyHash
    }
  }

  public static func policyPath(_ instance: Instance) -> String {
    instance.directory + "/egress-boot-policy.json"
  }

  public static func recordedPolicy(_ instance: Instance) throws(HostError) -> BootPolicy? {
    let path = policyPath(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let policy = try StateStore.decode(BootPolicy.self, bytes, path: path)
    guard policy.schemaVersion == 1, policy.backend == StateSchema.backend else {
      throw HostError("\(path) is not a supported egress boot policy")
    }
    guard !policy.bootID.isEmpty, !policy.policyHash.isEmpty else {
      throw HostError("\(path) has an empty egress boot identity or policy hash")
    }
    return policy
  }

  public enum Failure: Equatable, Sendable, CustomStringConvertible {
    case runtimeIncompatible
    case missingBoot
    case bootChanged
    case policyChanged
    case ownerChanged
    case ownerDown
    case companionDown
    case tunnelDown

    public var description: String {
      switch self {
      case .runtimeIncompatible: "filtered egress requires runtime protocol 5"
      case .missingBoot: "missing boot policy; restart the instance"
      case .bootChanged: "boot id changed"
      case .policyChanged: "egress policy does not match this boot; restart the instance"
      case .ownerChanged: "sandbox owner identity changed"
      case .ownerDown: "sandbox owner is not holding its lock"
      case .companionDown: "egress companion is not running"
      case .tunnelDown: "egress tunnel is not running"
      }
    }
  }

  public static func prove(
    filtered: Bool, recordedBootID: String?, liveBootID: String?, ownerLockHeld: Bool,
    companionAlive: Bool, tunnelAlive: Bool, advertisedProtocol: UInt32,
    recordedPolicyHash: String?, wantedPolicyHash: String, ownerMatches: Bool
  ) -> Failure? {
    guard filtered else { return nil }
    guard advertisedProtocol == RuntimeProtocol.bootIdentity else { return .runtimeIncompatible }
    guard let recordedBootID, !recordedBootID.isEmpty else { return .missingBoot }
    guard recordedBootID == liveBootID else { return .bootChanged }
    guard recordedPolicyHash == wantedPolicyHash, !wantedPolicyHash.isEmpty else {
      return .policyChanged
    }
    guard ownerMatches else { return .ownerChanged }
    guard ownerLockHeld else { return .ownerDown }
    guard companionAlive else { return .companionDown }
    guard tunnelAlive else { return .tunnelDown }
    return nil
  }
}
