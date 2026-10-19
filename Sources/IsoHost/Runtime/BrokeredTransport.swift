import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets

/// The brokered transport (docs/design/brokered-network-isolation.md): a VM
/// with no network device, reached only through `iso-sandbox connect`, the
/// runtime's stream connector, as ssh's ProxyCommand. Everything here is
/// computed on the host from operator-controlled state; the guest supplies
/// none of it.

extension SHA256Hex {
  /// The digest of `bytes`: the form the runtime binds a boot's streams to
  /// (64 lowercase hex digits, no prefix).
  package static func of(_ bytes: [UInt8]) -> SHA256Hex {
    // sha256Hex is 64 lowercase hex digits by construction.
    try! SHA256Hex(sha256Hex(bytes))
  }
}

/// The channel policy iso expects a brokered owner to enforce, and its
/// digest computed here, never taken from the runtime's report.
package enum BrokeredChannel {
  /// The guest image's `iso-ssh-vsock.socket` port.
  package static let sshPort: UInt32 = 2222

  package static let expected = EffectiveChannelPolicy(
    schema: "iso.channels/v1",
    endpoints: [.init(purpose: "ssh", guestPort: sshPort, direction: "host-to-guest")],
    maxStreams: 64, maxOpensPerWindow: 64, windowSeconds: 10, requestBytes: 4096,
    setupTimeoutSeconds: 10, chunkBytes: 64 << 10)

  /// The runtime encodes its policy the same way (sorted keys, no other
  /// formatting); a different encoding refuses the boot rather than pass.
  package static var digest: SHA256Hex {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return .of(Array((try? encoder.encode(expected)) ?? Data()))
  }
}

/// The immutable per-boot network policy of a brokered VM (spec 6.1),
/// resolved on the host from configuration and the instance's own records.
/// Its digest is passed to the runtime at boot; every stream of that boot
/// must present it, and a handoff refuses a configuration that resolves to
/// a different one (`POLICY_CHANGE_REQUIRES_RESTART`).
package struct BrokeredNetworkPolicy: Sendable, Equatable, Codable {
  package struct PublicEgress: Sendable, Equatable, Codable {
    /// `filtered`: blind CONNECT to the recorded hosts on port 443.
    package let profile: String
    package let allowedHosts: [String]
    /// `NetworkPolicy.policyHash`, which the egress companion also binds.
    package let policyHash: String

    package init(profile: String, allowedHosts: [String], policyHash: String) {
      self.profile = profile
      self.allowedHosts = allowedHosts
      self.policyHash = policyHash
    }

    enum CodingKeys: String, CodingKey {
      case profile
      case allowedHosts = "allowed_hosts"
      case policyHash = "policy_hash"
    }
  }

  /// An explicit host-loopback service reached through a fixed reverse
  /// tunnel (local models). Named and visible; never a general host route.
  package struct LocalService: Sendable, Equatable, Codable {
    package let name: String
    package let guestPort: UInt16
    package let hostAddress: String
    package let hostPort: UInt16

    package init(name: String, guestPort: UInt16, hostAddress: String, hostPort: UInt16) {
      self.name = name
      self.guestPort = guestPort
      self.hostAddress = hostAddress
      self.hostPort = hostPort
    }

    enum CodingKeys: String, CodingKey {
      case name
      case guestPort = "guest_port"
      case hostAddress = "host_address"
      case hostPort = "host_port"
    }
  }

  package static let schemaName = "iso.network/v1"

  package let schema: String
  package let transport: String
  /// Always `forbidden`: no failure attaches a network device or widens
  /// this policy.
  package let fallback: String
  package let publicEgress: PublicEgress?
  /// Providers whose credential broker (`iso-proxy`) this boot may use.
  package let providerGrants: [String]
  package let localServices: [LocalService]
  package let channelPolicy: SHA256Hex

  enum CodingKeys: String, CodingKey {
    case schema, transport, fallback
    case publicEgress = "public_egress"
    case providerGrants = "provider_grants"
    case localServices = "local_services"
    case channelPolicy = "channel_policy"
  }

  package init(
    publicEgress: PublicEgress?, providerGrants: [String], localServices: [LocalService],
    channelPolicy: SHA256Hex = BrokeredChannel.digest
  ) {
    schema = Self.schemaName
    transport = NetworkTransport.brokered.rawValue
    fallback = "forbidden"
    self.publicEgress = publicEgress
    self.providerGrants = providerGrants.sorted()
    self.localServices = localServices.sorted { $0.guestPort < $1.guestPort }
    self.channelPolicy = channelPolicy
  }

  /// The policy `config` resolves to for `instance` now. Refuses what a
  /// brokered VM cannot carry: open egress, or a local model the guest
  /// would have to reach directly. `guestEnvironment` is the environment a
  /// boot is about to record (its `--env` provider secrets decide brokers);
  /// nil reads the recorded one.
  package static func resolve(
    _ config: IsoConfig, _ instance: Instance,
    guestEnvironment: [EnvVarName: EnvValue]? = nil
  ) throws -> BrokeredNetworkPolicy {
    if let conflict = config.transportConflict { throw HostError(conflict) }
    let egress = NetworkPolicy.make(config)
    let publicEgress =
      config.egress == .filtered
      ? PublicEgress(
        profile: EgressMode.filtered.rawValue, allowedHosts: egress.allowedHosts,
        policyHash: egress.policyHash) : nil
    var providers: [String] = []
    let routed = try guestEnvironment.map(GuestEnvState.providerSecrets)
    for provider in ProxyProvider.allCases {
      let granted: Bool
      if let routed {
        if let secret = routed[provider] {
          guard config.proxy.mode != .off else { throw ProxyState.unavailable(secret) }
          granted = true
        } else {
          granted = try ProxyState.load(instance).effective(provider, config: config.proxy) != nil
        }
      } else {
        granted = try ProxyState.effectiveUpstream(instance, provider, config: config.proxy) != nil
      }
      if granted { providers.append(provider.rawValue) }
    }
    let model = try ModelState.loadOrDefault(instance)
    var services: [LocalService] = []
    for (name, endpoint) in [
      ("claude-local-model", LocalEndpoints.active(model, model.resolvedClaude(config.claude))),
      ("codex-local-model", LocalEndpoints.active(model, model.resolvedCodex(config.codex))),
    ] {
      guard let endpoint else { continue }
      guard let tunnel = try LocalEndpoints.plan(endpoint.hostURL).tunnel else {
        throw HostError(
          "BROKERED_UNSUPPORTED: the \(name) endpoint \(EndpointURL(endpoint.hostURL).serialized) is not on the host's loopback; a brokered VM has no network device, so it reaches local models only through iso's loopback tunnel. Serve the model on 127.0.0.1 or localhost."
        )
      }
      services.append(
        LocalService(
          name: name, guestPort: tunnel.guestPort, hostAddress: tunnel.hostAddress.description,
          hostPort: tunnel.hostPort))
    }
    return BrokeredNetworkPolicy(
      publicEgress: publicEgress, providerGrants: providers, localServices: services)
  }

  /// Decoding refuses any schema, transport or fallback other than the
  /// constants, so no stored policy can claim another meaning.
  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    for (key, wanted) in [
      (CodingKeys.schema, Self.schemaName), (.transport, NetworkTransport.brokered.rawValue),
      (.fallback, "forbidden"),
    ] where try c.decode(String.self, forKey: key) != wanted {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: c, debugDescription: "must be \(wanted)")
    }
    self.init(
      publicEgress: try c.decodeIfPresent(PublicEgress.self, forKey: .publicEgress),
      providerGrants: try c.decode([String].self, forKey: .providerGrants),
      localServices: try c.decode([LocalService].self, forKey: .localServices),
      channelPolicy: try c.decode(SHA256Hex.self, forKey: .channelPolicy))
  }

  /// sha256 of the canonical (sorted-key) encoding.
  package var digest: SHA256Hex {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return .of(Array((try? encoder.encode(self)) ?? Data()))
  }
}

/// How the host reaches a gate-approved guest.
package enum GuestRoute: Sendable, Equatable {
  /// The guest's address on its dedicated vmnet network.
  case vmnet(IPv4Address)
  /// The runtime connector, bound to this boot and its verified digests.
  case brokered(BrokeredRoute)

  package var ipv4: IPv4Address? {
    if case .vmnet(let address) = self { return address }
    return nil
  }

  package var transport: NetworkTransport {
    switch self {
    case .vmnet: .vmnet
    case .brokered: .brokered
    }
  }
}

package struct BrokeredRoute: Sendable, Equatable {
  package let bootID: BootID
  package let channelPolicy: SHA256Hex
  package let networkPolicy: SHA256Hex
  /// The owner's reading of the live VM that the gate accepted (always 0).
  package let networkDevices: UInt32
}

/// A process to spawn directly: never empty, never shell-parsed.
package struct ConnectorCommand: Sendable, Equatable {
  package let executable: String
  package let arguments: [String]

  package init(executable: String, arguments: [String]) {
    self.executable = executable
    self.arguments = arguments
  }
}

/// The fixed runtime connector ssh runs as its ProxyCommand. The executable
/// and root are the resolved, ownership-checked runtime and its state root;
/// every other argument is a validated identifier, never a secret.
package struct BrokeredConnector: Sendable, Equatable {
  package let executable: String
  package let root: String

  /// The ProxyCommand line. ssh runs it through a shell and expands `%`, so
  /// every path must be plain (``ClientSessionCoordinator/requireRouteSafe(_:)``).
  package func proxyCommand(machine: MachineName, route: BrokeredRoute) throws -> String {
    try requireRouteSafe()
    let command = command(machine: machine, route: route)
    return ([command.executable] + command.arguments).joined(separator: " ")
  }

  package func requireRouteSafe() throws {
    try ClientSessionCoordinator.requireRouteSafe(executable)
    try ClientSessionCoordinator.requireRouteSafe(root)
  }

  /// The connector as an executable and arguments, for the relay's direct spawn.
  package func command(machine: MachineName, route: BrokeredRoute) -> ConnectorCommand {
    ConnectorCommand(
      executable: executable,
      arguments: [
        "connect", "--root", root, machine.rawValue, "--boot", route.bootID.rawValue,
        "--channel-policy", route.channelPolicy.rawValue, "--network-policy",
        route.networkPolicy.rawValue,
      ])
  }
}

extension SandboxRuntime {
  /// Refuses a runtime that cannot create brokered sandboxes.
  package func requireBrokered() throws(RuntimeError) {
    _ = try requireQualified()
    guard features.contains(RuntimeProtocol.brokeredFeature) else {
      throw .unqualified(
        "the brokered transport needs an iso-sandbox advertising \(RuntimeProtocol.brokeredFeature); rebuild it with scripts/build-iso-sandbox.sh"
      )
    }
  }

  /// The stream connector of this runtime, when it is a real executable.
  package func brokeredConnector() throws(RuntimeError) -> BrokeredConnector {
    try requireBrokered()
    guard let executable = executor.connectorExecutable else {
      throw .unavailable("this runtime has no stream connector executable")
    }
    return BrokeredConnector(executable: executable, root: root)
  }
}

extension ImageManifest {
  /// The guest adapter a brokered VM needs: `sshd -i` per vsock stream on
  /// ``BrokeredChannel/sshPort`` (`iso-ssh-vsock.socket`).
  package static let vsockSSHAdapter = "vsock-ssh-v1"

  package var supportsBrokered: Bool { guestAdapters?.contains(Self.vsockSSHAdapter) == true }

  /// Refuses an image without the adapter before any VM is created.
  package func requireBrokeredAdapter(_ image: ImageName) throws {
    guard guestOS == .linux else {
      throw HostError(
        "BROKERED_UNSUPPORTED: the brokered transport is qualified for Linux guests only; image '\(image)' is a macOS guest"
      )
    }
    guard supportsBrokered else {
      throw HostError(
        "BROKERED_UNSUPPORTED: image '\(image)' predates the brokered transport's guest SSH adapter; rebuild it with `iso setup --rebuild --image \(image)`"
      )
    }
  }
}

/// The effective state of a gate-approved brokered boot (spec 6.2): the
/// observation behind `iso status`, not a credential. It is recomputed on
/// every call and never persisted.
package struct BrokeredView: Sendable, Equatable {
  package let bootID: BootID
  /// The owner's reading of the live VM, which the gate required to be 0.
  package let externalNICCount: UInt32
  package let networkPolicy: SHA256Hex
  package let channelPolicy: SHA256Hex
  package let policy: BrokeredNetworkPolicy

  package init(
    bootID: BootID, externalNICCount: UInt32, networkPolicy: SHA256Hex,
    channelPolicy: SHA256Hex, policy: BrokeredNetworkPolicy
  ) {
    self.bootID = bootID
    self.externalNICCount = externalNICCount
    self.networkPolicy = networkPolicy
    self.channelPolicy = channelPolicy
    self.policy = policy
  }
}

extension AppleBackend {
  /// Nil unless `running` is a brokered boot with a recorded policy.
  package func brokeredView(_ running: Running) throws -> BrokeredView? {
    guard case .brokered(let route) = running.ready.route,
      let recorded = try NetworkPolicy.load(running.instance), let policy = recorded.brokered,
      recorded.brokeredDigest == route.networkPolicy
    else { return nil }
    return BrokeredView(
      bootID: route.bootID, externalNICCount: route.networkDevices,
      networkPolicy: route.networkPolicy,
      channelPolicy: route.channelPolicy, policy: policy)
  }
}

extension AppleBackend {
  /// The runtime connector for a relay to a running brokered instance,
  /// after a fresh gate pass of its current boot (no guest connection).
  package func brokeredRelayCommand(_ instance: Instance) throws -> ConnectorCommand {
    let (runtime, machine, route) = try gatedBrokeredRoute(instance)
    return try runtime.brokeredConnector().command(machine: machine, route: route)
  }

  /// The gate-approved route of a running brokered instance's current boot
  /// (no guest connection): the source of the host interface's network proof.
  package func brokeredRoute(_ instance: Instance) throws -> BrokeredRoute {
    try gatedBrokeredRoute(instance).route
  }

  private func gatedBrokeredRoute(_ instance: Instance) throws
    -> (runtime: SandboxRuntime, machine: MachineName, route: BrokeredRoute)
  {
    let sidecar = try ownedSidecar(instance)
    let runtime = try runtime()
    _ = try runtime.requireQualified()
    let observed = try observe(runtime, sidecar)
    let recorded = try NetworkPolicy.load(instance)
    let ready = try observed.gate(
      try expected(sidecar, runtime, networkPolicy: recorded?.brokeredDigest))
    guard case .brokered(let route) = ready.route else {
      throw RuntimeError.networkIsolation("instance '\(instance.name)' is not brokered")
    }
    return (runtime, sidecar.machineID, route)
  }
}
