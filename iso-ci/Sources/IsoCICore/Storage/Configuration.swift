import Foundation

/// Administrator-controlled configuration (`schema: iso-ci/v2`, spec section
/// 12). Profiles reference named descriptors (image, network policy,
/// compatibility, limits); each descriptor has a content digest, and a pool
/// activates only when every descriptor it uses matches an approved digest.
/// Repository workflow content can request a pool or profile; it can never
/// define any of these values.
package struct CIConfiguration: Sendable, Equatable, Codable {
  /// The schema `setup` writes. `iso-ci/v1` files stay valid: every v2
  /// addition is optional, so a v1 file means the same thing under v2.
  package static let schema = "iso-ci/v2"
  package static let schemas: [String: Int64] = ["iso-ci/v1": 1, "iso-ci/v2": 2]

  package var images: [Name: ImageDescriptor]
  package var networkPolicies: [Name: NetworkPolicyDescriptor]
  package var compatibility: [Name: CompatibilityDescriptor]
  package var limits: [Name: LimitsDescriptor]
  package var hosts: [Name: HostBudget]
  package var profiles: [Name: RunnerProfile]
  package var pools: [Name: PoolConfiguration]
  package var preflight: PreflightConfiguration?

  package init(
    images: [Name: ImageDescriptor] = [:], networkPolicies: [Name: NetworkPolicyDescriptor] = [:],
    compatibility: [Name: CompatibilityDescriptor] = [:], limits: [Name: LimitsDescriptor] = [:],
    hosts: [Name: HostBudget] = [:], profiles: [Name: RunnerProfile] = [:],
    pools: [Name: PoolConfiguration] = [:], preflight: PreflightConfiguration? = nil
  ) {
    self.images = images
    self.networkPolicies = networkPolicies
    self.compatibility = compatibility
    self.limits = limits
    self.hosts = hosts
    self.profiles = profiles
    self.pools = pools
    self.preflight = preflight
  }
}

package struct ImageDescriptor: Sendable, Equatable, Codable {
  package var isoImage: String
  /// The required image digest, sent as `image_digest` on `run.create` and
  /// matched against the host's qualification evidence.
  package var digest: Digest
  package var runnerVersion: String
  package var docker: Bool
  package var runnerDirectory: String
  /// Hosts whose own qualified build of this image has another digest.
  package var hostDigests: [String: Digest]? = nil

  package var digestOfDescriptor: Digest { descriptorDigest(self) }

  package func digest(on host: Name) -> Digest { hostDigests?[host.rawValue] ?? digest }
}

/// The brokered network profile CI requests (spec sections 2 and 6).
package struct NetworkPolicyDescriptor: Sendable, Equatable, Codable {
  package var egress: EgressMode
  /// The reviewed endpoint profile that must be covered by the host's
  /// approved allowlist. Guest-requested hosts are never auto-allowed.
  package var requiredHosts: [HostRule]
  package var preflightService: Bool

  package var digestOfDescriptor: Digest { descriptorDigest(self) }
}

package enum ExecutionMode: String, Sendable, Codable, CaseIterable {
  case connected
  case preflight
}

package struct CompatibilityDescriptor: Sendable, Equatable, Codable {
  package var mode: ExecutionMode
  package var manifest: String?

  package var digestOfDescriptor: Digest { descriptorDigest(self) }
}

/// Finite resource and lifetime bounds (spec section 12): every value is
/// required and persisted; there are no undocumented defaults.
package struct LimitsDescriptor: Sendable, Equatable, Codable {
  package var cpus: UInt32
  package var memoryMiB: UInt64
  package var diskGiB: UInt64
  package var bootSeconds: UInt64
  package var idleSeconds: UInt64
  package var jobSeconds: UInt64
  package var hardDeadlineSeconds: UInt64
  package var stopGraceSeconds: UInt64
  package var exportGraceSeconds: UInt64
  package var outputBytes: UInt64
  package var logBytes: UInt64
  package var trafficBytes: UInt64
  package var liveRetentionSeconds: UInt64
  package var stoppedRetentionSeconds: UInt64

  package var reservation: ResourceReservation {
    ResourceReservation(cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB)
  }

  package var digestOfDescriptor: Digest { descriptorDigest(self) }
}

/// Per-host admission budgets on the controller side; the host still
/// admits physically under its own limits. `cpus` and `memoryMiB` are the
/// ceiling shared by iso and iso-ci on that Mac; the owner reservation and
/// any interactive iso VMs come off it before CI admission (`HostCapacity`).
package struct HostBudget: Sendable, Equatable, Codable {
  package var maxVMs: UInt32
  package var cpus: UInt32
  package var memoryMiB: UInt64
  package var diskGiB: UInt64
  /// Whether this budget sets a shared-host field, which makes the host
  /// budget an approved descriptor (`iso-ci setup --approve`).
  package var isApprovedDescriptor: Bool {
    ownerReservedCPUs != nil || ownerReservedMemoryMiB != nil || trackExternalMacOSVMs != nil
  }

  package var ownerReservedCPUs: UInt32? = nil
  package var ownerReservedMemoryMiB: UInt64? = nil
  /// Also count Virtualization.framework VM processes that hold no iso
  /// lease toward the two-macOS-VM ceiling (local host only).
  package var trackExternalMacOSVMs: Bool? = nil

  package init(
    maxVMs: UInt32, cpus: UInt32, memoryMiB: UInt64, diskGiB: UInt64,
    ownerReservedCPUs: UInt32? = nil, ownerReservedMemoryMiB: UInt64? = nil,
    trackExternalMacOSVMs: Bool? = nil
  ) {
    self.maxVMs = maxVMs
    self.cpus = cpus
    self.memoryMiB = memoryMiB
    self.diskGiB = diskGiB
    self.ownerReservedCPUs = ownerReservedCPUs
    self.ownerReservedMemoryMiB = ownerReservedMemoryMiB
    self.trackExternalMacOSVMs = trackExternalMacOSVMs
  }
}

/// The guest operating system a profile's VMs run, derived from its
/// platform. Virtualization.framework runs at most two macOS VMs per Mac.
package enum GuestOS: String, Sendable, Codable, CaseIterable {
  case linux
  case macos

  package static let macOSVMCeiling = 2
}

package enum Authority: String, Sendable, Codable, CaseIterable {
  case validation
  case privileged
}

package struct RunnerProfile: Sendable, Equatable, Codable {
  package static let platforms: [String: GuestOS] = ["linux/arm64": .linux, "macos/arm64": .macos]

  package var platform: String
  package var image: Name
  package var networkPolicy: Name
  package var compatibility: Name
  package var authority: Authority
  package var limits: Name
  /// Drain sibling allocations from the chosen host first and run alone.
  /// Stored only when true, so profiles without it keep their digests.
  package var exclusiveHost: Bool? = nil

  package init(
    platform: String, image: Name, networkPolicy: Name, compatibility: Name,
    authority: Authority, limits: Name, exclusiveHost: Bool? = nil
  ) {
    self.platform = platform
    self.image = image
    self.networkPolicy = networkPolicy
    self.compatibility = compatibility
    self.authority = authority
    self.limits = limits
    self.exclusiveHost = exclusiveHost == true ? true : nil
  }

  package var isExclusive: Bool { exclusiveHost == true }
  package var guestOS: GuestOS { Self.platforms[platform] ?? .linux }
}

package enum GitHubScope: Sendable, Equatable, Codable, Hashable {
  case repository(RepositoryName)
  case organization(String, runnerGroup: String)

  package var description: String {
    switch self {
    case .repository(let repository): "repository:\(repository.rawValue)"
    case .organization(let org, let group): "organization:\(org)/group:\(group)"
    }
  }
}

package enum FailureRetention: String, Sendable, Codable, CaseIterable {
  case disabled
  case live
  case stopped
}

/// How a connected pool provides runners: a warm pool keeps
/// `desired_idle_vms` registered ahead of demand; a scale set registers no
/// runner until GitHub offers it a job that passes the pool's job policy.
package enum ProvisioningMode: String, Sendable, Codable, CaseIterable {
  case warmPool = "warm_pool"
  case scaleSet = "scaleset"
}

/// Which queued jobs a scale-set pool acquires, evaluated before any VM or
/// registration exists. Default-deny: a job is acquired only when every
/// check passes and its facts could be read.
package struct JobPolicy: Sendable, Equatable, Codable {
  package static let defaultEvents = ["push", "pull_request", "workflow_dispatch", "merge_group"]
  /// Events a public repository may admit: each needs write access to the
  /// repository to trigger (a same-repository `pull_request` needs a pushed
  /// branch; fork pull requests are refused separately).
  package static let writeGatedEvents: Set<String> = [
    "push", "pull_request", "workflow_dispatch", "merge_group", "schedule",
  ]

  package var allowForkPRs: Bool
  package var allowPublicRepo: Bool
  package var allowedEvents: [String]
  /// Lowercased logins; empty admits any actor under `allowedEvents`.
  package var allowedActors: [String]

  package init(
    allowForkPRs: Bool = false, allowPublicRepo: Bool = false,
    allowedEvents: [String] = JobPolicy.defaultEvents, allowedActors: [String] = []
  ) {
    self.allowForkPRs = allowForkPRs
    self.allowPublicRepo = allowPublicRepo
    self.allowedEvents = allowedEvents
    self.allowedActors = allowedActors
  }
}

package struct ScaleSetConfiguration: Sendable, Equatable, Codable {
  package var name: String
  package var minRunners: UInt32
  package var maxRunners: UInt32
  package var jobPolicy: JobPolicy

  package init(name: String, minRunners: UInt32, maxRunners: UInt32, jobPolicy: JobPolicy) {
    self.name = name
    self.minRunners = minRunners
    self.maxRunners = maxRunners
    self.jobPolicy = jobPolicy
  }
}

package struct PoolConfiguration: Sendable, Equatable, Codable {
  package var profile: Name
  package var hosts: [Name]
  package var installation: Name
  package var scope: GitHubScope
  package var labels: [RunnerLabel]
  package var maxLiveVMs: UInt32
  package var desiredIdleVMs: UInt32
  package var retentionOnFailure: FailureRetention
  /// Present only for `provisioning_mode: scaleset`, so warm pools keep
  /// their digests.
  package var scaleSet: ScaleSetConfiguration? = nil

  package init(
    profile: Name, hosts: [Name], installation: Name, scope: GitHubScope, labels: [RunnerLabel],
    maxLiveVMs: UInt32, desiredIdleVMs: UInt32, retentionOnFailure: FailureRetention,
    scaleSet: ScaleSetConfiguration? = nil
  ) {
    self.profile = profile
    self.hosts = hosts
    self.installation = installation
    self.scope = scope
    self.labels = labels
    self.maxLiveVMs = maxLiveVMs
    self.desiredIdleVMs = desiredIdleVMs
    self.retentionOnFailure = retentionOnFailure
    self.scaleSet = scaleSet
  }

  package var provisioningMode: ProvisioningMode { scaleSet == nil ? .warmPool : .scaleSet }
}

package struct PreflightConfiguration: Sendable, Equatable, Codable {
  package var profile: Name
  package var hosts: [Name]
  /// Operator-approved `runs-on` label → platform mapping. Explicit only:
  /// ARM64 preflight is never silently equivalent to hosted x86/macOS.
  package var platformMap: [String: String]
  package var maxParallelJobs: UInt32
}

package func descriptorDigest<T: Encodable>(_ value: T) -> Digest {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(value) else { return Digest(hashing: [UInt8]()) }
  return Digest(hashing: data)
}

// MARK: - Loading

extension CIConfiguration {
  package static func load(path: String) throws(CIError) -> CIConfiguration {
    guard let bytes = try PrivateFiles.read(path, limit: 1 << 20) else {
      throw CIError.config("no configuration at \(path); run `iso-ci setup`")
    }
    guard let text = String(validating: bytes, as: UTF8.self) else {
      throw CIError.config("configuration is not valid UTF-8")
    }
    return try parse(text)
  }

  package static func parse(_ text: String) throws(CIError) -> CIConfiguration {
    let root: YAMLNode
    do { root = try YAML.parse(text) } catch { throw CIError.config(error.message) }
    var r = try ConfigReader(root, path: "")
    // `schema: iso-ci/vN` names the version; `schema_version: N` may say
    // the same, and alone means `iso-ci/vN`.
    let named = try r.optionalString("schema")
    let numbered = try r.optionalUnsigned("schema_version", max: 99).map { Int64($0) }
    guard let version = named.flatMap({ schemas[$0] }) ?? (named == nil ? numbered : nil),
      numbered == nil || numbered == version, schemas.values.contains(version)
    else {
      throw CIError.config(
        "schema must be iso-ci/v1 or iso-ci/v2 (or schema_version 1 or 2, matching any schema)")
    }
    var config = CIConfiguration()
    config.images = try r.namedMap("images") { (node, path) throws(CIError) in
      var d = try ConfigReader(node, path: path)
      let image = ImageDescriptor(
        isoImage: try d.isoName("iso_image"),
        digest: try { () throws(CIError) -> Digest in
          let raw = try d.string("digest")
          do { return try Digest(prefixed: raw) } catch {
            throw CIError.config("\(path).digest is not a sha256 digest")
          }
        }(),
        runnerVersion: try d.version("runner_version"), docker: try d.bool("docker"),
        runnerDirectory: try d.optionalString("runner_directory") ?? "/opt/actions-runner",
        hostDigests: try {
          () throws(CIError) -> [String: Digest]? in
          let entries = try d.namedMap("host_digests") { (node, entry) throws(CIError) in
            guard let raw = node.scalar?.value, let digest = try? Digest(prefixed: raw) else {
              throw CIError.config("\(entry) is not a sha256 digest")
            }
            return digest
          }
          return entries.isEmpty
            ? nil : Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
        }())
      guard image.runnerDirectory.hasPrefix("/"),
        image.runnerDirectory.unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" }),
        !image.runnerDirectory.contains("..")
      else { throw CIError.config("\(path).runner_directory must be a plain absolute path") }
      try d.finish()
      return image
    }
    config.networkPolicies = try r.namedMap("network_policies") { (node, path) throws(CIError) in
      var d = try ConfigReader(node, path: path)
      guard let egress = EgressMode(rawValue: try d.string("egress")), egress != .open else {
        throw CIError.config(
          "\(path).egress must be none or filtered; open egress is never used by CI")
      }
      var hosts: [HostRule] = []
      for host in try d.optionalStrings("required_hosts") ?? [] {
        guard let rule = HostRule(host) else {
          throw CIError.config(
            "\(path).required_hosts entries must be exact lowercase hostnames or '*.<suffix>' with at least three suffix labels"
          )
        }
        hosts.append(rule)
      }
      if egress == .none && !hosts.isEmpty {
        throw CIError.config("\(path): required_hosts needs egress filtered")
      }
      let policy = NetworkPolicyDescriptor(
        egress: egress, requiredHosts: Array(Set(hosts)).sorted { $0.rawValue < $1.rawValue },
        preflightService: try d.optionalBool("preflight_service") ?? false)
      try d.finish()
      return policy
    }
    config.compatibility = try r.namedMap("compatibility") { (node, path) throws(CIError) in
      var d = try ConfigReader(node, path: path)
      guard let mode = ExecutionMode(rawValue: try d.string("mode")) else {
        throw CIError.config("\(path).mode must be connected or preflight")
      }
      let manifest = try d.optionalString("manifest")
      if mode == .preflight && manifest == nil {
        throw CIError.config("\(path).manifest is required for preflight compatibility")
      }
      if mode == .connected && manifest != nil {
        throw CIError.config("\(path).manifest applies only to preflight compatibility")
      }
      try d.finish()
      return CompatibilityDescriptor(mode: mode, manifest: manifest)
    }
    config.limits = try r.namedMap("limits") { (node, path) throws(CIError) in
      var d = try ConfigReader(node, path: path)
      let limits = LimitsDescriptor(
        cpus: UInt32(try d.positive("cpus", max: 64)),
        memoryMiB: try d.positive("memory_mib", max: 1 << 20),
        diskGiB: try d.positive("disk_gib", max: 4_096),
        bootSeconds: try d.positive("boot_seconds", max: 3_600),
        idleSeconds: try d.positive("idle_seconds", max: 86_400),
        jobSeconds: try d.positive("job_seconds", max: 86_400),
        hardDeadlineSeconds: try d.positive("hard_deadline_seconds", max: 86_400),
        stopGraceSeconds: try d.positive("stop_grace_seconds", max: 3_600),
        exportGraceSeconds: try d.positive("export_grace_seconds", max: 3_600),
        outputBytes: try d.positive("output_bytes", max: 256 << 20),
        logBytes: try d.positive("log_bytes", max: 1 << 30),
        trafficBytes: try d.positive("traffic_bytes", max: 1 << 40),
        liveRetentionSeconds: try d.positive("live_retention_seconds", max: 14_400),
        stoppedRetentionSeconds: try d.positive("stopped_retention_seconds", max: 604_800))
      guard limits.memoryMiB >= 256 else {
        throw CIError.config("\(path).memory_mib must be at least 256")
      }
      guard limits.hardDeadlineSeconds >= limits.bootSeconds + limits.jobSeconds else {
        throw CIError.config("\(path).hard_deadline_seconds must cover boot_seconds + job_seconds")
      }
      try d.finish()
      return limits
    }
    config.hosts = try r.namedMap("hosts") { (node, path) throws(CIError) in
      var d = try ConfigReader(node, path: path)
      let budget = HostBudget(
        maxVMs: UInt32(try d.positive("max_vms", max: 64)),
        cpus: UInt32(try d.positive("cpus", max: 1_024)),
        memoryMiB: try d.positive("memory_mib", max: 1 << 24),
        diskGiB: try d.positive("disk_gib", max: 1 << 20),
        ownerReservedCPUs: try d.optionalUnsigned("owner_reserved_cpus", max: 1_024).map {
          UInt32($0)
        },
        ownerReservedMemoryMiB: try d.optionalUnsigned("owner_reserved_memory_mib", max: 1 << 24),
        trackExternalMacOSVMs: try d.optionalBool("track_external_macos_vms"))
      guard (budget.ownerReservedCPUs ?? 0) < budget.cpus,
        (budget.ownerReservedMemoryMiB ?? 0) < budget.memoryMiB
      else {
        throw CIError.config("\(path): the owner reservation must leave CPUs and memory for CI")
      }
      if budget.trackExternalMacOSVMs == true, path != "hosts.\(HostCapacity.localHost)" {
        throw CIError.config(
          "\(path).track_external_macos_vms applies only to the local host (alias \(HostCapacity.localHost))"
        )
      }
      try d.finish()
      return budget
    }
    config.profiles = try r.namedMap("profiles") { (node, path) throws(CIError) in
      var d = try ConfigReader(node, path: path)
      let platform = try d.string("platform")
      guard RunnerProfile.platforms[platform] != nil else {
        throw CIError.config("\(path).platform must be linux/arm64 or macos/arm64")
      }
      guard let authority = Authority(rawValue: try d.string("authority")) else {
        throw CIError.config("\(path).authority must be validation or privileged")
      }
      let profile = RunnerProfile(
        platform: platform, image: try d.name("image"), networkPolicy: try d.name("network_policy"),
        compatibility: try d.name("compatibility"), authority: authority,
        limits: try d.name("limits"), exclusiveHost: try d.optionalBool("exclusive_host"))
      try d.finish()
      return profile
    }
    config.pools = try r.namedMap("pools") { (node, path) throws(CIError) in
      var d = try ConfigReader(node, path: path)
      let profile = try d.name("profile")
      let hosts = try d.names("hosts")
      guard !hosts.isEmpty else {
        throw CIError.config("\(path).hosts must name at least one host")
      }
      var github = try d.object("github")
      let installation = try github.name("installation")
      var scopeReader = try github.object("scope")
      let scope: GitHubScope
      if let repository = try scopeReader.optionalString("repository") {
        guard try scopeReader.optionalString("organization") == nil else {
          throw CIError.config(
            "\(path).github.scope must name a repository or an organization, not both")
        }
        do { scope = .repository(try RepositoryName(repository)) } catch {
          throw CIError.config("\(path).github.scope.repository must be OWNER/REPOSITORY")
        }
      } else if let organization = try scopeReader.optionalString("organization") {
        guard RepositoryName.validOrganization(organization) else {
          throw CIError.config("\(path).github.scope.organization is not a valid organization")
        }
        guard let group = try scopeReader.optionalString("runner_group"), !group.isEmpty,
          group.utf8.count <= 100
        else {
          throw CIError.config(
            "\(path).github.scope.runner_group is required for organization pools")
        }
        scope = .organization(organization, runnerGroup: group)
      } else {
        throw CIError.config("\(path).github.scope needs repository or organization")
      }
      try scopeReader.finish()
      var labels: [RunnerLabel] = []
      for raw in try github.strings("labels") {
        do { labels.append(try RunnerLabel(raw)) } catch {
          throw CIError.config("\(path).github.labels has an invalid label")
        }
      }
      let normalized = Set(labels.map(\.normalized))
      guard normalized.count == labels.count else {
        throw CIError.config("\(path).github.labels has duplicates")
      }
      guard normalized.contains("self-hosted"), normalized.contains("linux"),
        normalized.contains("arm64")
      else {
        throw CIError.config("\(path).github.labels must include self-hosted, linux and ARM64")
      }
      guard labels.contains(where: { !["self-hosted", "linux", "arm64"].contains($0.normalized) })
      else {
        throw CIError.config(
          "\(path).github.labels needs a pool-specific label (for example iso-ci)")
      }
      try github.finish()
      guard
        let mode = ProvisioningMode(
          rawValue: try d.optionalString("provisioning_mode") ?? ProvisioningMode.warmPool.rawValue)
      else {
        throw CIError.config("\(path).provisioning_mode must be warm_pool or scaleset")
      }
      let scaleSet: ScaleSetConfiguration?
      let maxLive: UInt32
      let idle: UInt32
      switch mode {
      case .warmPool:
        guard d.optionalNode("scaleset") == nil else {
          throw CIError.config("\(path).scaleset needs provisioning_mode: scaleset")
        }
        scaleSet = nil
        maxLive = UInt32(try d.positive("max_live_vms", max: 64))
        idle = UInt32(try d.unsigned("desired_idle_vms", max: 64))
        guard idle <= maxLive else {
          throw CIError.config("\(path).desired_idle_vms exceeds max_live_vms")
        }
      case .scaleSet:
        for key in ["max_live_vms", "desired_idle_vms"] where d.optionalNode(key) != nil {
          throw CIError.config(
            "\(path).\(key) does not apply to a scale set; use scaleset.min_runners and max_runners"
          )
        }
        let parsed = try Self.parseScaleSet(try d.object("scaleset"), path: "\(path).scaleset")
        scaleSet = parsed
        maxLive = parsed.maxRunners
        idle = parsed.minRunners
      }
      guard
        let retention = FailureRetention(
          rawValue: try d.optionalString("retention_on_failure") ?? "disabled")
      else {
        throw CIError.config("\(path).retention_on_failure must be disabled, live or stopped")
      }
      try d.finish()
      return PoolConfiguration(
        profile: profile, hosts: hosts, installation: installation, scope: scope, labels: labels,
        maxLiveVMs: maxLive, desiredIdleVMs: idle, retentionOnFailure: retention,
        scaleSet: scaleSet)
    }
    if let node = r.optionalNode("preflight") {
      var d = try ConfigReader(node, path: "preflight")
      let profile = try d.name("profile")
      let hosts = try d.names("hosts")
      guard !hosts.isEmpty else {
        throw CIError.config("preflight.hosts must name at least one host")
      }
      guard try d.optionalString("architecture_mapping") ?? "explicit" == "explicit" else {
        throw CIError.config("preflight.architecture_mapping must be explicit")
      }
      guard try d.optionalString("retry") ?? "fresh-job" == "fresh-job" else {
        throw CIError.config(
          "preflight.retry must be fresh-job (failed-step continuation is unsupported)")
      }
      var map: [String: String] = [:]
      if let mapping = d.optionalNode("platform_map") {
        guard let pairs = mapping.mapping else {
          throw CIError.config("preflight.platform_map must be a mapping")
        }
        for pair in pairs {
          guard let value = pair.value.scalar?.value, value == "linux/arm64" else {
            throw CIError.config("preflight.platform_map values must be linux/arm64")
          }
          guard (1...100).contains(pair.key.value.utf8.count) else {
            throw CIError.config("preflight.platform_map has an invalid label")
          }
          map[pair.key.value.lowercased()] = value
        }
      }
      let parallel = UInt32(try d.optionalUnsigned("max_parallel_jobs", max: 64) ?? 1)
      guard parallel >= 1 else {
        throw CIError.config("preflight.max_parallel_jobs must be at least 1")
      }
      try d.finish()
      config.preflight = PreflightConfiguration(
        profile: profile, hosts: hosts, platformMap: map, maxParallelJobs: parallel)
    }
    try r.finish()
    try config.validateReferences()
    return config
  }

  static func parseScaleSet(_ reader: ConfigReader, path: String) throws(CIError)
    -> ScaleSetConfiguration
  {
    var d = reader
    let name = try d.string("name")
    guard (1...100).contains(name.utf8.count), name.unicodeScalars.allSatisfy(isSafeNameScalar)
    else { throw CIError.config("\(path).name is not a valid scale set name") }
    let minimum = UInt32(try d.unsigned("min_runners", max: 64))
    let maximum = UInt32(try d.positive("max_runners", max: 64))
    guard minimum <= maximum else {
      throw CIError.config("\(path).min_runners exceeds max_runners")
    }
    var policy = JobPolicy()
    if let node = d.optionalNode("job_policy") {
      var p = try ConfigReader(node, path: "\(path).job_policy")
      policy.allowForkPRs = try p.optionalBool("allow_fork_prs") ?? false
      policy.allowPublicRepo = try p.optionalBool("allow_public_repo") ?? false
      if let events = try p.optionalStrings("allowed_events") {
        guard !events.isEmpty,
          events.allSatisfy({
            (1...64).contains($0.utf8.count)
              && $0.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
          })
        else {
          throw CIError.config(
            "\(path).job_policy.allowed_events must list lowercase GitHub event names")
        }
        policy.allowedEvents = Array(Set(events)).sorted()
      }
      if let actors = try p.optionalStrings("allowed_actors") {
        guard actors.allSatisfy({ RepositoryName.validOrganization($0) }) else {
          throw CIError.config("\(path).job_policy.allowed_actors must list GitHub logins")
        }
        policy.allowedActors = Array(Set(actors.map { $0.lowercased() })).sorted()
      }
      try p.finish()
    }
    if policy.allowPublicRepo {
      // A public repository lets anyone open pull requests and trigger
      // events: only write-gated events, and never fork pull requests. An
      // idle runner could take any job GitHub assigns before it is vetted.
      guard minimum == 0 else {
        throw CIError.config("\(path): allow_public_repo needs min_runners: 0")
      }
      guard !policy.allowForkPRs else {
        throw CIError.config(
          "\(path).job_policy: allow_fork_prs cannot be combined with allow_public_repo")
      }
      let open = policy.allowedEvents.filter { !JobPolicy.writeGatedEvents.contains($0) }
      guard open.isEmpty || !policy.allowedActors.isEmpty else {
        throw CIError.config(
          "\(path).job_policy: a public repository may allow only write-gated events (\(JobPolicy.writeGatedEvents.sorted().joined(separator: ", "))) unless allowed_actors is set; \(open.joined(separator: ", ")) can be triggered by anyone"
        )
      }
    }
    try d.finish()
    return ScaleSetConfiguration(
      name: name, minRunners: minimum, maxRunners: maximum, jobPolicy: policy)
  }

  package func validateReferences() throws(CIError) {
    for (name, image) in images {
      for host in (image.hostDigests ?? [:]).keys.sorted()
      where (try? Name(host)).flatMap({ hosts[$0] }) == nil {
        throw CIError.config("image \(name) host_digests names unknown host \(host)")
      }
    }
    for (name, profile) in profiles {
      guard images[profile.image] != nil else {
        throw CIError.config("profile \(name) references unknown image \(profile.image)")
      }
      guard networkPolicies[profile.networkPolicy] != nil else {
        throw CIError.config(
          "profile \(name) references unknown network policy \(profile.networkPolicy)")
      }
      guard compatibility[profile.compatibility] != nil else {
        throw CIError.config(
          "profile \(name) references unknown compatibility \(profile.compatibility)")
      }
      guard limits[profile.limits] != nil else {
        throw CIError.config("profile \(name) references unknown limits \(profile.limits)")
      }
    }
    for (name, pool) in pools {
      guard let profile = profiles[pool.profile] else {
        throw CIError.config("pool \(name) references unknown profile \(pool.profile)")
      }
      guard compatibility[profile.compatibility]?.mode == .connected else {
        throw CIError.config("pool \(name) needs a profile with connected compatibility")
      }
      guard networkPolicies[profile.networkPolicy]?.preflightService == false else {
        throw CIError.config("pool \(name): connected profiles cannot carry the preflight endpoint")
      }
      try Self.requireBudgets(pool.hosts, hosts, user: "pool \(name)")
    }
    if let preflight {
      guard let profile = profiles[preflight.profile] else {
        throw CIError.config("preflight references unknown profile \(preflight.profile)")
      }
      guard compatibility[profile.compatibility]?.mode == .preflight else {
        throw CIError.config("preflight needs a profile with preflight compatibility")
      }
      guard networkPolicies[profile.networkPolicy]?.preflightService == true else {
        throw CIError.config("preflight needs a network policy with preflight_service: true")
      }
      try Self.requireBudgets(preflight.hosts, hosts, user: "preflight")
      guard profile.guestOS == .linux else {
        throw CIError.config("preflight needs a linux/arm64 profile")
      }
    }
    var scaleSets: [String: Name] = [:]
    for (name, pool) in pools.sorted(by: { $0.key < $1.key }) {
      guard let scaleSet = pool.scaleSet else { continue }
      let key = "\(GitHubRunnerScope(pool.scope).routingKey)/\(scaleSet.name.lowercased())"
      if let other = scaleSets[key] {
        throw CIError.config("pools \(other) and \(name) name the same scale set")
      }
      scaleSets[key] = name
    }
  }

  /// Placement budgets every host it may use: a host without a `hosts:`
  /// entry would have no controller-side budget at all.
  private static func requireBudgets(
    _ used: [Name], _ budgets: [Name: HostBudget], user: String
  ) throws(CIError) {
    for host in used where budgets[host] == nil {
      throw CIError.config("\(user) uses host \(host), which has no hosts: budget")
    }
  }

  package func poolDigest(_ name: Name) -> Digest? {
    guard let pool = pools[name], let profile = profiles[pool.profile] else { return nil }
    var members: [String: JSONValue] = [
      "pool": .string(descriptorDigest(pool).rawValue),
      "profile": .string(descriptorDigest(profile).rawValue),
    ]
    if let image = images[profile.image] {
      members["image"] = .string(image.digestOfDescriptor.rawValue)
    }
    if let network = networkPolicies[profile.networkPolicy] {
      members["network"] = .string(network.digestOfDescriptor.rawValue)
    }
    if let compat = compatibility[profile.compatibility] {
      members["compatibility"] = .string(compat.digestOfDescriptor.rawValue)
    }
    if let limits = limits[profile.limits] {
      members["limits"] = .string(limits.digestOfDescriptor.rawValue)
    }
    return Digest(hashing: JSONValue.object(members).canonical)
  }

  /// The host budgets among `hosts` that set shared-host fields (owner
  /// reservation, external macOS tracking), for approval checks. Budgets
  /// without them are not approved descriptors, so existing approvals hold.
  package func hostDescriptors(_ hosts: [Name]) -> [(ApprovalRecord.Kind, Name, Digest)] {
    hosts.sorted().compactMap { name in
      guard let budget = self.hosts[name], budget.isApprovedDescriptor else { return nil }
      return (.host, name, descriptorDigest(budget))
    }
  }

  package func descriptors(of profileName: Name) -> [(ApprovalRecord.Kind, Name, Digest)] {
    guard let profile = profiles[profileName] else { return [] }
    var out: [(ApprovalRecord.Kind, Name, Digest)] = [
      (.profile, profileName, descriptorDigest(profile))
    ]
    if let image = images[profile.image] {
      out.append((.image, profile.image, image.digestOfDescriptor))
    }
    if let network = networkPolicies[profile.networkPolicy] {
      out.append((.networkPolicy, profile.networkPolicy, network.digestOfDescriptor))
    }
    if let compat = compatibility[profile.compatibility] {
      out.append((.compatibility, profile.compatibility, compat.digestOfDescriptor))
    }
    if let limits = limits[profile.limits] {
      out.append((.limits, profile.limits, limits.digestOfDescriptor))
    }
    return out
  }
}

/// An egress allowlist entry, mirroring base iso's `HostRule` (IsoCore): an
/// exact hostname, or `*.<suffix>` for names one or more whole labels below
/// a suffix of at least three labels (never the suffix itself). It encodes
/// as its plain string, so descriptor digests are unchanged by the type.
package enum HostRule: Hashable, Sendable, Codable, CustomStringConvertible {
  case exact(String)
  case subdomains(of: String)

  package static let minimumSuffixLabels = 3

  package init?(_ raw: String) {
    if raw.hasPrefix("*.") {
      let suffix = String(raw.dropFirst(2))
      guard isExactHostname(suffix),
        suffix.split(separator: ".").count >= Self.minimumSuffixLabels
      else { return nil }
      self = .subdomains(of: suffix)
    } else {
      guard isExactHostname(raw) else { return nil }
      self = .exact(raw)
    }
  }

  package var rawValue: String {
    switch self {
    case .exact(let host): host
    case .subdomains(let suffix): "*." + suffix
    }
  }

  package var description: String { rawValue }

  package func matches(_ host: String) -> Bool {
    switch self {
    case .exact(let name): host == name
    case .subdomains(let suffix): host.hasSuffix("." + suffix)
    }
  }

  /// Whether an allowlist covers this required rule: a required wildcard
  /// must appear verbatim; a required exact name may be covered by a rule.
  package func isCovered(by allowed: [HostRule]) -> Bool {
    if allowed.contains(self) { return true }
    guard case .exact(let host) = self else { return false }
    return allowed.contains { $0.matches(host) }
  }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let rule = Self(raw) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid host rule"))
    }
    self = rule
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A canonical (lowercase) DNS name as base iso's `ExactHostname` accepts
/// it: two or more labels, not an all-numeric address alias.
package func isExactHostname(_ value: String) -> Bool {
  guard (1...253).contains(value.utf8.count), !value.hasSuffix("."), !value.hasPrefix(".") else {
    return false
  }
  let labels = value.split(separator: ".", omittingEmptySubsequences: false)
  guard labels.count >= 2 else { return false }
  for label in labels {
    guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
      label.unicodeScalars.allSatisfy({
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
      })
    else { return false }
  }
  return !labels.allSatisfy { $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }
}

package struct ConfigReader {
  let pairs: [YAMLPair]
  let path: String
  private var consumed: Set<String> = []

  package init(_ node: YAMLNode, path: String) throws(CIError) {
    guard let pairs = node.mapping else {
      throw CIError.config("\(path.isEmpty ? "configuration" : path) must be a mapping")
    }
    self.pairs = pairs
    self.path = path
  }

  private func name(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

  package mutating func optionalNode(_ key: String) -> YAMLNode? {
    consumed.insert(key)
    guard let node = pairs.first(where: { $0.key.value == key })?.value, !node.isNull else {
      return nil
    }
    return node
  }

  package mutating func node(_ key: String) throws(CIError) -> YAMLNode {
    guard let node = optionalNode(key) else { throw CIError.config("missing \(name(key))") }
    return node
  }

  package mutating func optionalString(_ key: String) throws(CIError) -> String? {
    guard let node = optionalNode(key) else { return nil }
    guard let scalar = node.scalar else { throw CIError.config("\(name(key)) must be a scalar") }
    return scalar.value
  }

  package mutating func string(_ key: String) throws(CIError) -> String {
    guard let value = try optionalString(key) else { throw CIError.config("missing \(name(key))") }
    return value
  }

  package mutating func name(_ key: String) throws(CIError) -> Name {
    let raw = try string(key)
    do { return try Name(raw) } catch { throw CIError.config("\(name(key)) is not a valid name") }
  }

  package mutating func isoName(_ key: String) throws(CIError) -> String {
    let raw = try string(key)
    guard (1...64).contains(raw.utf8.count), !raw.hasPrefix("."),
      raw.unicodeScalars.allSatisfy(isSafeNameScalar)
    else { throw CIError.config("\(name(key)) is not a valid iso image name") }
    return raw
  }

  package mutating func version(_ key: String) throws(CIError) -> String {
    let raw = try string(key)
    let parts = raw.split(separator: ".")
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
      throw CIError.config("\(name(key)) must be an exact version like 2.329.0")
    }
    return raw
  }

  package mutating func optionalBool(_ key: String) throws(CIError) -> Bool? {
    guard let node = optionalNode(key) else { return nil }
    guard let value = node.scalar?.bool else {
      throw CIError.config("\(name(key)) must be true or false")
    }
    return value
  }

  package mutating func bool(_ key: String) throws(CIError) -> Bool {
    guard let value = try optionalBool(key) else { throw CIError.config("missing \(name(key))") }
    return value
  }

  package mutating func optionalUnsigned(_ key: String, max: UInt64) throws(CIError) -> UInt64? {
    guard let node = optionalNode(key) else { return nil }
    guard let value = node.scalar?.int, value >= 0, UInt64(value) <= max else {
      throw CIError.config("\(name(key)) must be an integer from 0 to \(max)")
    }
    return UInt64(value)
  }

  package mutating func unsigned(_ key: String, max: UInt64) throws(CIError) -> UInt64 {
    guard let value = try optionalUnsigned(key, max: max) else {
      throw CIError.config("missing \(name(key))")
    }
    return value
  }

  package mutating func positive(_ key: String, max: UInt64) throws(CIError) -> UInt64 {
    let value = try unsigned(key, max: max)
    guard value > 0 else { throw CIError.config("\(name(key)) must be positive") }
    return value
  }

  package mutating func optionalStrings(_ key: String) throws(CIError) -> [String]? {
    guard let node = optionalNode(key) else { return nil }
    guard let items = node.sequence else { throw CIError.config("\(name(key)) must be a list") }
    var out: [String] = []
    for item in items {
      guard let scalar = item.scalar, !scalar.isNull else {
        throw CIError.config("\(name(key)) must contain scalars")
      }
      out.append(scalar.value)
    }
    return out
  }

  package mutating func strings(_ key: String) throws(CIError) -> [String] {
    guard let value = try optionalStrings(key) else { throw CIError.config("missing \(name(key))") }
    return value
  }

  package mutating func names(_ key: String) throws(CIError) -> [Name] {
    var out: [Name] = []
    for raw in try strings(key) {
      do { out.append(try Name(raw)) } catch {
        throw CIError.config("\(name(key)) has an invalid name")
      }
    }
    guard Set(out).count == out.count else { throw CIError.config("\(name(key)) has duplicates") }
    return out
  }

  package mutating func object(_ key: String) throws(CIError) -> ConfigReader {
    try ConfigReader(try node(key), path: name(key))
  }

  package mutating func namedMap<T>(
    _ key: String, _ make: (YAMLNode, String) throws(CIError) -> T
  ) throws(CIError) -> [Name: T] {
    guard let node = optionalNode(key) else { return [:] }
    guard let pairs = node.mapping else { throw CIError.config("\(name(key)) must be a mapping") }
    var out: [Name: T] = [:]
    for pair in pairs {
      let entryName: Name
      do { entryName = try Name(pair.key.value) } catch {
        throw CIError.config("\(name(key)) has an invalid name")
      }
      out[entryName] = try make(pair.value, "\(name(key)).\(entryName)")
    }
    return out
  }

  package func finish() throws(CIError) {
    for pair in pairs where !consumed.contains(pair.key.value) {
      throw CIError.config(
        "unknown key \(name(CIError.bounded(String(pair.key.value.prefix(64)))))")
    }
  }
}

extension CIConfiguration {
  /// The configuration `iso-ci setup` writes for operator review: one
  /// connected pool and the preflight profile, with illustrative values.
  package static func template(repository: String, host: String) -> String {
    """
    schema: iso-ci/v2

    # Approved immutable descriptors. Changing any of them requires
    # re-approval (`iso-ci setup --approve`) before a pool using it activates.
    images:
      approved-linux-arm64-runner:
        iso_image: ci-runner
        # The qualified image's digest, as `iso-ci status` shows it for the host
        # (the NET-HANDOFF-1 evidence names it). Replace before approving.
        digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
        runner_version: 2.338.0
        docker: true

    network_policies:
      approved-ci-public-egress:
        egress: filtered
        # GitHub's documented self-hosted runner endpoints. GitHub assigns
        # per-account and per-job hosts under actions.githubusercontent.com
        # (pipelines…, run-actions-N-<region>…), so that domain is the one
        # reviewed wildcard; job logs and results go to the listed storage
        # accounts. The host's iso egress allowlist must cover every entry.
        required_hosts:
          - github.com
          - api.github.com
          - codeload.github.com
          - objects.githubusercontent.com
          - "*.actions.githubusercontent.com"
          - productionresultssa0.blob.core.windows.net
          - productionresultssa1.blob.core.windows.net
          - productionresultssa2.blob.core.windows.net
          - productionresultssa3.blob.core.windows.net
          - productionresultssa4.blob.core.windows.net
          - productionresultssa5.blob.core.windows.net
          - productionresultssa6.blob.core.windows.net
          - productionresultssa7.blob.core.windows.net
          - productionresultssa8.blob.core.windows.net
          - productionresultssa9.blob.core.windows.net
          - productionresultssa10.blob.core.windows.net
          - productionresultssa11.blob.core.windows.net
          - productionresultssa12.blob.core.windows.net
          - productionresultssa13.blob.core.windows.net
          - productionresultssa14.blob.core.windows.net
          - productionresultssa15.blob.core.windows.net
          - productionresultssa16.blob.core.windows.net
          - productionresultssa17.blob.core.windows.net
          - productionresultssa18.blob.core.windows.net
          - productionresultssa19.blob.core.windows.net
          - ghcr.io
          - pkg-containers.githubusercontent.com
      approved-preflight-egress-and-service:
        egress: none
        preflight_service: true

    compatibility:
      approved-connected-linux:
        mode: connected
      approved-local-actions:
        mode: preflight
        manifest: local-actions/v1

    limits:
      operator-approved-ci-limits:
        cpus: 4
        memory_mib: 8192
        disk_gib: 64
        boot_seconds: 600
        idle_seconds: 3600
        job_seconds: 21600
        hard_deadline_seconds: 28800
        stop_grace_seconds: 60
        export_grace_seconds: 300
        output_bytes: 67108864
        log_bytes: 67108864
        traffic_bytes: 4294967296
        live_retention_seconds: 3600
        stopped_retention_seconds: 86400

    # The ceiling iso and iso-ci share on each Mac. CI admission subtracts the
    # owner reservation and the VMs iso-ci does not own (read from iso's VM
    # leases on the local host). Optional: owner_reserved_cpus,
    # owner_reserved_memory_mib, track_external_macos_vms (local only).
    hosts:
      \(host):
        max_vms: 2
        cpus: 8
        memory_mib: 16384
        disk_gib: 256

    profiles:
      linux-validation:
        platform: linux/arm64
        image: approved-linux-arm64-runner
        network_policy: approved-ci-public-egress
        compatibility: approved-connected-linux
        authority: validation
        limits: operator-approved-ci-limits

      linux-preflight:
        platform: linux/arm64
        image: approved-linux-arm64-runner
        network_policy: approved-preflight-egress-and-service
        compatibility: approved-local-actions
        authority: validation
        limits: operator-approved-ci-limits

    pools:
      validation:
        profile: linux-validation
        hosts: [\(host)]
        github:
          installation: selected-installation
          scope:
            repository: \(repository)
          labels: [self-hosted, linux, ARM64, iso-ci]
        max_live_vms: 2
        desired_idle_vms: 1
        retention_on_failure: disabled
        # For scale-to-zero, replace max_live_vms and desired_idle_vms with a
        # runner scale set; each offered job is checked before it is acquired:
        #   provisioning_mode: scaleset
        #   scaleset:
        #     name: iso-arm64
        #     min_runners: 0
        #     max_runners: 2
        #     job_policy: {allow_fork_prs: false, allow_public_repo: false}

    preflight:
      profile: linux-preflight
      hosts: [\(host)]
      architecture_mapping: explicit
      retry: fresh-job
      platform_map:
        ubuntu-latest: linux/arm64
        ubuntu-24.04-arm: linux/arm64
      max_parallel_jobs: 2

    """
  }
}
