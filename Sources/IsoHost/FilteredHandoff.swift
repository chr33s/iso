import Foundation

/// Proof that a filtered session may be handed to a guest. The isolation
/// gate does not see the user-space companion, so this is checked again at
/// hand-off and is not cached.
public enum FilteredHandoff {
  public enum Failure: Equatable, Sendable, CustomStringConvertible {
    case missingBoot
    case bootChanged
    case ownerDown
    case companionDown
    case tunnelDown

    public var description: String {
      switch self {
      case .missingBoot: "missing boot id"
      case .bootChanged: "boot id changed"
      case .ownerDown: "sandbox owner is not holding its lock"
      case .companionDown: "egress companion is not running"
      case .tunnelDown: "egress tunnel is not running"
      }
    }
  }

  public static func prove(
    filtered: Bool, recordedBootID: String?, liveBootID: String?, ownerLockHeld: Bool,
    companionAlive: Bool, tunnelAlive: Bool
  ) -> Failure? {
    guard filtered else { return nil }
    guard let recordedBootID, !recordedBootID.isEmpty else { return .missingBoot }
    guard recordedBootID == liveBootID else { return .bootChanged }
    guard ownerLockHeld else { return .ownerDown }
    guard companionAlive else { return .companionDown }
    guard tunnelAlive else { return .tunnelDown }
    return nil
  }

  public static func bootID(at path: String) -> String? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
