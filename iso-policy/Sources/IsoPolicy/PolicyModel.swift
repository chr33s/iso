// The typed policy document (docs/design/iso-policy.md §4). Parsing adapters
// build a `PolicyDocument`; `PolicyCompiler` validates its semantics. Nothing
// here holds a credential, a capability or a guest-supplied identity.

/// A governed operation. The set is closed: an unknown action is an error.
public enum PolicyAction: String, Sendable, CaseIterable, Comparable, Hashable, Codable {
  case credentialUse = "credential.use"
  case proxyRequest = "proxy.request"
  case workspacePullApply = "workspace.pull.apply"

  /// The resource kind every selector for this action names.
  public var resourceKind: PolicyResource.Kind {
    switch self {
    case .credentialUse, .proxyRequest: .provider
    case .workspacePullApply: .workspace
    }
  }

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum PolicyMode: String, Sendable, CaseIterable, Hashable, Codable {
  case off, shadow, enforce
}

public enum PolicyEffect: String, Sendable, CaseIterable, Hashable {
  case permit, forbid
}

/// A resource selector. These are names, never filesystem paths or URLs.
public enum PolicyResource: String, Sendable, CaseIterable, Comparable, Hashable {
  case anthropic = "provider:anthropic"
  case openai = "provider:openai"
  /// The instance's recorded attached workspace.
  case attachedWorkspace = "workspace:attached"

  public enum Kind: Sendable, Equatable { case provider, workspace }

  public var kind: Kind {
    switch self {
    case .anthropic, .openai: .provider
    case .attachedWorkspace: .workspace
    }
  }

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Exactly one requirement per guard.
public enum GuardRequirement: Sendable, Equatable, Hashable {
  case rateLimit(maxRequests: Int, withinSeconds: Int)
  case approvalWithin(seconds: Int)
}

public struct PolicyRule: Sendable, Equatable {
  public let id: String
  public let effect: PolicyEffect
  public let action: PolicyAction
  public let resources: [PolicyResource]
  /// Nil means every instance the snapshot applies to; never empty.
  public let instances: [String]?

  public init(
    id: String, effect: PolicyEffect, action: PolicyAction, resources: [PolicyResource],
    instances: [String]? = nil
  ) {
    self.id = id
    self.effect = effect
    self.action = action
    self.resources = resources
    self.instances = instances
  }
}

public struct PolicyGuard: Sendable, Equatable {
  public let id: String
  public let action: PolicyAction
  public let resources: [PolicyResource]
  public let instances: [String]?
  public let requirement: GuardRequirement

  public init(
    id: String, action: PolicyAction, resources: [PolicyResource], instances: [String]? = nil,
    requirement: GuardRequirement
  ) {
    self.id = id
    self.action = action
    self.resources = resources
    self.instances = instances
    self.requirement = requirement
  }
}

/// The `policy` object as written, before semantic validation.
public struct PolicyDocument: Sendable, Equatable {
  public let version: Int
  public let mode: PolicyMode
  public let actions: [PolicyAction]
  public let rules: [PolicyRule]
  public let guards: [PolicyGuard]

  public init(
    version: Int, mode: PolicyMode, actions: [PolicyAction], rules: [PolicyRule],
    guards: [PolicyGuard]
  ) {
    self.version = version
    self.mode = mode
    self.actions = actions
    self.rules = rules
    self.guards = guards
  }
}

/// One governed request: the action, its concrete resource, and the
/// host-derived instance name. Never built from guest-supplied identity.
public struct PolicyRequest: Sendable, Equatable, Hashable {
  public let action: PolicyAction
  public let resource: PolicyResource
  public let instance: String

  public init(action: PolicyAction, resource: PolicyResource, instance: String) {
    self.action = action
    self.resource = resource
    self.instance = instance
  }
}

/// Field names and limits of the v1 schema, shared by every adapter.
public enum PolicySchema {
  public static let version = 1
  public static let canonicalizationVersion = 1
  public static let maxCanonicalBytes = 64 * 1024
  public static let maxRules = 128
  public static let maxGuards = 16
  public static let maxIDLength = 64
  public static let maxInstancesPerEntry = 64
  public static let maxInstanceNameLength = 64
  public static let rateWindowSeconds = 1...3_600
  public static let rateCapacity = 1...10_000
  public static let maxRateGuardsPerScope = 4
  public static let maxTimestampSlots = 40_000
  public static let approvalSeconds = 1...900

  public static let policyKeys: Set<String> = ["version", "mode", "actions", "rules", "guards"]
  public static let ruleKeys: Set<String> = ["id", "effect", "action", "resources", "instances"]
  public static let guardKeys: Set<String> = ["id", "action", "resources", "instances", "require"]
  public static let requireKeys: Set<String> = ["rate_limit", "approval_within"]
  public static let rateLimitKeys: Set<String> = ["max_requests", "within_seconds"]
  public static let approvalKeys: Set<String> = ["seconds"]

  /// `[a-z][a-z0-9._-]*`, 1–64 ASCII characters.
  public static func isValidID(_ id: String) -> Bool {
    let bytes = Array(id.utf8)
    guard (1...maxIDLength).contains(bytes.count), (0x61...0x7A).contains(bytes[0]) else {
      return false
    }
    return bytes.allSatisfy {
      (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x5F
        || $0 == 0x2D
    }
  }

  /// iso's instance-name rule: `[A-Za-z0-9_-]`, 1–64 bytes.
  public static func isValidInstanceName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard (1...maxInstanceNameLength).contains(bytes.count) else { return false }
    return bytes.allSatisfy {
      (0x61...0x7A).contains($0) || (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
        || $0 == 0x2D || $0 == 0x5F
    }
  }
}
