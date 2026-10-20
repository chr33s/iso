import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets
import Testing

@testable import IsoHost

// The brokered transport (docs/design/brokered-network-isolation.md): the
// gate's NIC-less proof, digest parity with the runtime, the per-boot policy
// record, the connector route and the configuration refusals.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../fixtures/iso-sandbox").standardized
private let sandbox = try! MachineName("iso-0a1b2c3d-00112233445566ff")
private let owner = try! OwnerID("0a1b2c3d00112233445566778899aabb")
private let root = "/Users/me/.iso/backends/apple-container-v1/runtime"
/// The digests in the captured fixture: the runtime's own channel-policy
/// digest and the network-policy digest that boot was started with.
private let runtimeChannelDigest =
  "1beae82700a50cad9663c46faaea554ae4a815f5330c82cdcaa412b5c6a59301"
private let bootNetworkPolicy = try! SHA256Hex(
  "fa482a1dda592f86ddcf7b3dfe98577d9f849c046cc5914d81312cdd39a05e73")

private func expected(
  network: IsolationGate.ExpectedNetwork = .brokered(networkPolicy: bootNetworkPolicy),
  egress: EgressMode = .none
) -> IsolationGate.Expected {
  .init(
    sandbox: sandbox, owner: owner, runtimeRoot: root,
    resources: Resources(cpus: 2, memoryBytes: 2048 * 1024 * 1024), egress: egress,
    network: network)
}

private func fixture(_ name: String) throws -> [String: Any] {
  let data = try Data(contentsOf: fixtures.appending(path: name))
  return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func gate(_ object: [String: Any], _ expected: IsolationGate.Expected) throws(RuntimeError)
  -> IsolationGate.Ready
{
  let bytes = Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
  return try IsolationGate.verifyEffective(
    RuntimeProtocol.parseInspect(bytes, expected: sandbox), expected)
}

private func edit(_ object: [String: Any], _ section: String, _ body: (inout [String: Any]) -> Void)
  -> [String: Any]
{
  var copy = object
  var inner = copy[section] as? [String: Any] ?? [:]
  body(&inner)
  copy[section] = inner
  return copy
}

private enum Refusal: Equatable { case network, exposure, unqualified, identity, other }

private func refusal(_ body: () throws(RuntimeError) -> IsolationGate.Ready) -> Refusal? {
  do {
    _ = try body()
    return nil
  } catch {
    switch error {
    case .networkIsolation: return .network
    case .hostExposure: return .exposure
    case .unqualified: return .unqualified
    case .identityConflict: return .identity
    default: return .other
    }
  }
}

@Test func hostChannelDigestEqualsTheRuntimesOwn() throws {
  // The runtime encodes and hashes its ChannelPolicy; the host recomputes
  // the digest from its own copy. Both sides must agree byte for byte.
  #expect(BrokeredChannel.digest.rawValue == runtimeChannelDigest)
  let brokered = try fixture("inspect-brokered-running.json")
  let effective = try #require(brokered["effective"] as? [String: Any])
  let reported = try JSONSerialization.data(withJSONObject: effective["channelPolicy"] as Any)
  #expect(
    try JSONDecoder().decode(EffectiveChannelPolicy.self, from: reported)
      == BrokeredChannel.expected)
}

@Test func gateAcceptsTheCapturedBrokeredBoot() throws {
  let ready = try gate(try fixture("inspect-brokered-running.json"), expected())
  #expect(ready.ipv4 == nil)
  guard case .brokered(let route) = ready.route else {
    Issue.record("expected a brokered route")
    return
  }
  #expect(route.bootID.rawValue == "b7ad1194a3cc79a7720b4f169833bb62")
  #expect(route.networkPolicy == bootNetworkPolicy)
  #expect(route.channelPolicy.rawValue == runtimeChannelDigest)
  #expect(route.networkDevices == 0)
}

@Test func gateRefusesEveryWeakeningOfTheBrokeredShape() throws {
  let base = try fixture("inspect-brokered-running.json")
  let interface: [String: Any] = [
    "ipv4": "10.231.2.2/24", "ipv4Gateway": "10.231.2.1", "network": "vmnet-shared:10.231.2.0/24",
  ]
  let cases: [(String, [String: Any], Refusal)] = [
    ("a network device", edit(base, "effective") { $0["networkDevices"] = 1 }, .network),
    ("no device count", edit(base, "effective") { $0["networkDevices"] = nil }, .unqualified),
    ("a second socket device", edit(base, "effective") { $0["socketDevices"] = 2 }, .network),
    ("an interface", edit(base, "effective") { $0["interfaces"] = [interface] }, .network),
    ("an address", edit(base, "live") { $0["ipv4"] = "10.231.2.2" }, .network),
    ("no transport", edit(base, "effective") { $0["transport"] = nil }, .unqualified),
    ("another transport", edit(base, "effective") { $0["transport"] = "vmnet" }, .network),
    (
      "another vsock endpoint",
      edit(base, "effective") { effective in
        var policy = effective["channelPolicy"] as? [String: Any] ?? [:]
        var endpoints = policy["endpoints"] as? [Any] ?? []
        endpoints.append(["purpose": "agent", "guestPort": 1024, "direction": "host-to-guest"])
        policy["endpoints"] = endpoints
        effective["channelPolicy"] = policy
      }, .exposure
    ),
    (
      "a wider stream limit",
      edit(base, "effective") { effective in
        var policy = effective["channelPolicy"] as? [String: Any] ?? [:]
        policy["maxStreams"] = 4096
        effective["channelPolicy"] = policy
      }, .exposure
    ),
    (
      "a forged channel digest",
      edit(base, "effective") { $0["channelPolicyDigest"] = String(repeating: "0", count: 64) },
      .exposure
    ),
    (
      "another boot's network policy",
      edit(base, "effective") { $0["networkPolicy"] = String(repeating: "1", count: 64) }, .network
    ),
    ("an unknown field", edit(base, "effective") { $0["guestForwarding"] = true }, .unqualified),
    ("a host share", edit(base, "effective") { $0["socketRelays"] = 1 }, .exposure),
    ("no socket device", edit(base, "effective") { $0["socketDevices"] = 0 }, .network),
    (
      "no channel digest", edit(base, "effective") { $0["channelPolicyDigest"] = nil }, .unqualified
    ),
    ("an invalid boot id", edit(base, "live") { $0["bootId"] = "a b" }, .unqualified),
  ]
  for (label, object, wanted) in cases {
    #expect(
      refusal { () throws(RuntimeError) in try gate(object, expected()) } == wanted, "\(label)")
  }
}

@Test func gateNeverCrossesTransports() throws {
  let brokered = try fixture("inspect-brokered-running.json")
  let vmnet = try fixture("inspect-running.json")
  // A brokered sandbox under a vmnet configuration, and the reverse.
  #expect(
    refusal { () throws(RuntimeError) in
      try gate(brokered, expected(network: .vmnet, egress: .none))
    } == .network)
  #expect(
    refusal { () throws(RuntimeError) in try gate(vmnet, expected(egress: .open)) } == .network)
  // A vmnet report carrying brokered fields is not a vmnet report.
  // The whole brokered group, so it decodes and only the gate refuses it.
  let brokeredEffective = try #require(brokered["effective"] as? [String: Any])
  let mixed = edit(vmnet, "effective") { effective in
    for key in [
      "transport", "networkDevices", "socketDevices", "channelPolicy", "channelPolicyDigest",
      "networkPolicy",
    ] {
      effective[key] = brokeredEffective[key]
    }
  }
  #expect(
    refusal { () throws(RuntimeError) in
      try gate(mixed, expected(network: .vmnet, egress: .open))
    } == .unqualified)
  // Brokered with open egress is never a valid record.
  #expect(
    refusal { () throws(RuntimeError) in try gate(brokered, expected(egress: .open)) } == .network)
}

// MARK: - Configuration

private func decode(_ json: String) throws -> IsoConfig {
  try ConfigLoader.decode(
    ConfigLoader.parse(Array(json.utf8), format: .json, path: "c", limits: .configuration),
    path: "c", environment: .empty)
}

@Test func networkTransportDecodesAndRefusesOpenEgress() throws {
  #expect(try decode("{}").network.transport == .vmnet)
  #expect(
    try decode(#"{"network":{"transport":"brokered"},"egress":"none"}"#).network.transport
      == .brokered)
  #expect(
    try decode(#"{"network":{"transport":"brokered"},"egress":"filtered"}"#).network.transport
      == .brokered)
  for bad in [
    #"{"network":{"transport":"brokered"}}"#,
    #"{"network":{"transport":"brokered"},"egress":"open"}"#,
    #"{"network":{"transport":"nat"}}"#, #"{"network":{"transport":"brokered","policy":"x"}}"#,
    #"{"network":"brokered"}"#,
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try decode(bad) }
  }
  let brokered = try decode(#"{"network":{"transport":"brokered"},"egress":"none"}"#)
  #expect(brokered.transportConflict == nil)
  // A CLI `--egress open` override cannot make a brokered VM networked.
  #expect(brokered.overridingEgress(.open).transportConflict != nil)
  #expect(brokered.overridingEgress(.filtered).network.transport == .brokered)
  // The presets keep their meaning: none of them selects the brokered transport.
  for preset in SecurityPreset.allCases {
    #expect(
      try decode(#"{"security":{"preset":"\#(preset.rawValue)"}}"#).network.transport == .vmnet)
  }
}

// MARK: - Per-boot network policy

private func withInstance(_ json: String, _ body: (Instance, IsoConfig) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-brokered-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let instance = Instance(
    name: try InstanceName("t"), index: try #require(InstanceIndex(0)), directory: directory,
    image: .default)
  try body(instance, try decode(json))
}

private let filteredBrokered =
  #"{"network":{"transport":"brokered"},"egress":"filtered","egress_filter":{"allowed_hosts":["api.example.com"]}}"#

@Test func brokeredPolicyRecordIsSchemaFourAndSelfConsistent() throws {
  try withInstance(filteredBrokered) { instance, config in
    try NetworkPolicy.save(config, instance)
    let record = try #require(try NetworkPolicy.load(instance))
    #expect(record.schemaVersion == NetworkPolicy.brokeredSchema)
    #expect(record.recordedTransport == .brokered)
    let policy = try #require(record.brokered)
    #expect(record.brokeredDigest == policy.digest)
    #expect(policy.fallback == "forbidden")
    #expect(policy.publicEgress?.allowedHosts == ["api.example.com"])
    #expect(policy.channelPolicy == BrokeredChannel.digest)
    #expect(policy.providerGrants.isEmpty && policy.localServices.isEmpty)
    try NetworkPolicy.enforce(instance, config: config)

    // Tamper with the stored record: every inconsistent shape is refused.
    let path = NetworkPolicy.path(instance)
    let stored = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        as? [String: Any])
    func refused(_ change: (inout [String: Any]) -> Void) throws -> Bool {
      var json = stored
      change(&json)
      try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: path))
      return (try? NetworkPolicy.load(instance)) == nil
    }
    // A brokered record cannot pose as vmnet, nor a vmnet record as brokered.
    #expect(try refused { $0["schemaVersion"] = 3 })
    #expect(try refused { $0["brokered"] = nil })
    #expect(try refused { $0["schemaVersion"] = 99 })
    // The boot policy's constants and egress half are checked.
    for (key, value) in [("fallback", "allowed"), ("transport", "vmnet"), ("schema", "x")] {
      #expect(
        try refused { json in
          var brokered = json["brokered"] as? [String: Any] ?? [:]
          brokered[key] = value
          json["brokered"] = brokered
        })
    }
    #expect(
      try refused { json in
        json["allowedHosts"] = []
        json["mode"] = "none"
        json["policyHash"] =
          NetworkPolicy.make(
            (try? decode(#"{"egress":"none"}"#)) ?? config
          ).policyHash
      })
    // No separately stored transport or digest to drift from the policy.
    #expect(stored["transport"] == nil && stored["brokeredDigest"] == nil)
  }
}

@Test func vmnetPolicyRecordIsUnchanged() throws {
  try withInstance(#"{"egress":"none"}"#) { instance, config in
    try NetworkPolicy.save(config, instance)
    let bytes = try #require(try StateStore.readControlFile(NetworkPolicy.path(instance)))
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("transport") && !text.contains("brokered"))
    #expect(try NetworkPolicy.load(instance)?.schemaVersion == NetworkPolicy.currentSchema)
  }
}

@Test func theTransportIsFixedAtCreation() throws {
  try withInstance(#"{"egress":"none"}"#) { instance, vmnet in
    try NetworkPolicy.save(vmnet, instance)
    let brokered = try decode(#"{"network":{"transport":"brokered"},"egress":"none"}"#)
    #expect(throws: HostError.self) { try NetworkPolicy.enforceMode(instance, config: brokered) }
    try NetworkPolicy.save(brokered, instance)
    do {
      try NetworkPolicy.enforceMode(instance, config: vmnet)
      Issue.record("a brokered instance was accepted under vmnet")
    } catch let error as HostError {
      #expect(error.message.hasPrefix("POLICY_CHANGE_REQUIRES_RESTART"))
    }
  }
}

@Test func aChangedGrantRequiresARestart() throws {
  try withInstance(filteredBrokered) { instance, config in
    try NetworkPolicy.save(config, instance)
    let widened = try decode(
      #"{"network":{"transport":"brokered"},"egress":"filtered","egress_filter":{"allowed_hosts":["api.example.com","other.example.com"]}}"#
    )
    #expect(throws: HostError.self) { try NetworkPolicy.enforce(instance, config: widened) }
    // A local-model grant added after boot is a new policy too.
    let local = try decode(
      #"{"network":{"transport":"brokered"},"egress":"filtered","egress_filter":{"allowed_hosts":["api.example.com"]},"claude":{"local_model":{"host_url":"http://127.0.0.1:1234","model":"m"}}}"#
    )
    var model = ModelState()
    model.mode = .local
    try model.save(instance)
    #expect(throws: HostError.self) { try NetworkPolicy.enforce(instance, config: local) }
    let resolved = try BrokeredNetworkPolicy.resolve(local, instance)
    #expect(
      resolved.localServices == [
        .init(name: "claude-local-model", guestPort: 1234, hostAddress: "127.0.0.1", hostPort: 1234)
      ])
    #expect(resolved.digest != (try #require(try NetworkPolicy.load(instance)?.brokeredDigest)))
  }
}

@Test func providerGrantsFollowTheEnvironmentBeingRecorded() throws {
  try withInstance(#"{"network":{"transport":"brokered"},"egress":"none"}"#) { instance, config in
    // Nothing recorded yet: the --env secret this boot will record decides.
    let pending: [EnvVarName: EnvValue] = [
      try EnvVarName("ANTHROPIC_API_KEY"): .secret(try SecretName("k"))
    ]
    let atBoot = try BrokeredNetworkPolicy.resolve(config, instance, guestEnvironment: pending)
    #expect(atBoot.providerGrants == ["anthropic"])
    #expect(try BrokeredNetworkPolicy.resolve(config, instance).providerGrants.isEmpty)
    // Once recorded, a handoff resolves the same digest the boot used.
    try GuestEnvState(entries: pending).save(instance, diagnostics: nil)
    #expect(try BrokeredNetworkPolicy.resolve(config, instance).digest == atBoot.digest)
    // proxy.mode off: a provider secret is refused, never granted.
    let off = try decode(
      #"{"network":{"transport":"brokered"},"egress":"none","proxy":{"mode":"off"}}"#)
    #expect(throws: HostError.self) {
      try BrokeredNetworkPolicy.resolve(off, instance, guestEnvironment: pending)
    }
  }
}

@Test func aLocalModelOffTheHostLoopbackIsRefused() throws {
  let json =
    #"{"network":{"transport":"brokered"},"egress":"none","claude":{"local_model":{"host_url":"http://192.168.1.5:11434","model":"m"}}}"#
  try withInstance(json) { instance, config in
    var model = ModelState()
    model.mode = .local
    try model.save(instance)
    do {
      _ = try BrokeredNetworkPolicy.resolve(config, instance)
      Issue.record("a LAN model endpoint was accepted for a brokered VM")
    } catch let error as HostError {
      #expect(error.message.hasPrefix("BROKERED_UNSUPPORTED"))
    }
  }
}

@Test func brokeredPolicyDigestIsCanonical() throws {
  let a = BrokeredNetworkPolicy(
    publicEgress: nil, providerGrants: ["openai", "anthropic"], localServices: [])
  let b = BrokeredNetworkPolicy(
    publicEgress: nil, providerGrants: ["anthropic", "openai"], localServices: [])
  #expect(a.digest == b.digest)
  #expect(a.providerGrants == ["anthropic", "openai"])
  let c = BrokeredNetworkPolicy(publicEgress: nil, providerGrants: ["anthropic"], localServices: [])
  #expect(a.digest != c.digest)
  #expect(throws: ValidationError.self) { try SHA256Hex("SHA256") }
  #expect(
    SHA256Hex.of(Array("x".utf8)).rawValue.utf8.allSatisfy { $0 < 0x80 && !(65...90).contains($0) })
}

// MARK: - Connector route

private let route = BrokeredRoute(
  bootID: try! BootID("b7ad1194a3cc79a7720b4f169833bb62"), channelPolicy: BrokeredChannel.digest,
  networkPolicy: bootNetworkPolicy, networkDevices: 0)

@Test func brokeredTargetRunsOnlyTheFixedConnector() throws {
  try withInstance(#"{"network":{"transport":"brokered"},"egress":"none"}"#) { instance, config in
    try StateStore.writeControlFile(
      Array("x.iso ssh-ed25519 AAAA\n".utf8), to: instance.knownHostsPath)
    let connector = BrokeredConnector(executable: "/opt/iso/bin/iso-sandbox", root: root)
    let target = try SSHTarget.pinned(
      config: config, instance: instance, machine: sandbox, route: .brokered(route),
      user: .default, connector: connector)
    #expect(target.host == "\(sandbox).iso" && target.alias == "\(sandbox).iso")
    let command =
      "/opt/iso/bin/iso-sandbox connect --root \(root) \(sandbox) --boot b7ad1194a3cc79a7720b4f169833bb62 --channel-policy \(runtimeChannelDigest) --network-policy \(bootNetworkPolicy)"
    #expect(target.proxyCommand == command)
    #expect(target.sshOptions.contains("ProxyCommand=\(command)"))
    #expect(target.hostKeyOptions.contains("StrictHostKeyChecking=yes"))
    // No connector, or one ssh's shell would re-parse, is refused.
    #expect(throws: (any Error).self) {
      try SSHTarget.pinned(
        config: config, instance: instance, machine: sandbox, route: .brokered(route),
        user: .default, connector: nil)
    }
    #expect(throws: HostError.self) {
      try SSHTarget.pinned(
        config: config, instance: instance, machine: sandbox, route: .brokered(route),
        user: .default,
        connector: BrokeredConnector(executable: "/opt/iso/iso-sandbox", root: "/Users/me/my root"))
    }
    for unsafe in ["/opt/my iso/iso-sandbox", "/opt/iso/%h", "/opt/iso/x;rm"] {
      #expect(throws: HostError.self) {
        try SSHTarget.pinned(
          config: config, instance: instance, machine: sandbox, route: .brokered(route),
          user: .default, connector: BrokeredConnector(executable: unsafe, root: root))
      }
    }
  }
}

@Test func runtimeCallsCarryTheBrokeredArguments() throws {
  let brokeredVersion =
    #"{"name":"iso-sandbox","version":"0.5.0","protocol":5,"containerization":"0.45.0","features":["macos-guests","brokered-transport"]}"#
  for (version, supported) in [(brokeredVersion, true), (qualifiedVersion, false)] {
    let scripted = ScriptedRuntime { arguments in
      arguments == ["version"] ? ScriptedRuntime.ok(version) : ScriptedRuntime.ok("{}")
    }
    let runtime = SandboxRuntime(executor: scripted, root: root, settings: .defaults)
    let name = try MachineName("iso-0a1b2c3d-0000000000000001")
    do {
      try runtime.create(
        name, source: .image("local/x:1"), cpus: 2, memoryMiB: 2048, diskGiB: 8, owner: owner,
        egress: .none, transport: .brokered)
      #expect(supported)
    } catch {
      #expect(!supported)
      #expect(error.description.hasPrefix("APPLE_RUNTIME_UNQUALIFIED"))
    }
    try runtime.start(name, networkPolicy: bootNetworkPolicy)
    let calls = scripted.calls.withLock { $0 }
    let create = calls.first { $0.first == "create" }
    #expect(supported ? create?.suffix(2) == ["--network", "brokered"] : create == nil)
    let start = try #require(calls.first { $0.first == "start" })
    #expect(start.suffix(2) == ["--network-policy", bootNetworkPolicy.rawValue])
    // A scripted executor has no connector executable to hand to ssh.
    #expect(throws: RuntimeError.self) { try runtime.brokeredConnector() }
  }
}

// MARK: - Images

@Test func brokeredInstancesNeedAnImageWithTheGuestAdapter() throws {
  func manifest(_ adapters: [String]?, platform: String = BuildContext.platform) -> ImageManifest {
    ImageManifest(
      schemaVersion: StateSchema.version, backend: StateSchema.backend, imageRef: "local/x:1",
      digest: "sha256:" + String(repeating: "0", count: 64), disk: nil, manifestID: "m",
      baseImage: BuildContext.baseImage, platform: platform, guestUser: .default, created: "t",
      guestAdapters: adapters)
  }
  #expect(throws: HostError.self) { try manifest(nil).requireBrokeredAdapter(.default) }
  #expect(throws: HostError.self) { try manifest([]).requireBrokeredAdapter(.default) }
  #expect(throws: HostError.self) {
    try manifest(BuildContext.guestAdapters, platform: ImageManifest.macPlatform)
      .requireBrokeredAdapter(.default)
  }
  try manifest(BuildContext.guestAdapters).requireBrokeredAdapter(.default)
  // Older manifests decode without the field and simply lack the adapter.
  let legacy = try JSONEncoder().encode(manifest(nil))
  #expect(!String(decoding: legacy, as: UTF8.self).contains("guest_adapters"))
  #expect(try JSONDecoder().decode(ImageManifest.self, from: legacy).supportsBrokered == false)
}

@Test func theImageRecipeInstallsTheVsockAdapter() throws {
  let context = BuildContext.render(
    publicKey: "ssh-ed25519 AAAA", profiles: [], guestUser: .default)
  let socket = try #require(context.files.first { $0.name == "iso-ssh-vsock.socket" }?.content)
  #expect(socket.contains("ListenStream=vsock::\(BrokeredChannel.sshPort)"))
  #expect(socket.contains("Accept=yes"))
  let service = try #require(context.files.first { $0.name == "iso-ssh-vsock@.service" }?.content)
  // Nothing but sshd's protocol may reach the stream.
  #expect(service.contains("StandardError=journal"))
  #expect(service.contains("ExecStart=-/usr/sbin/sshd -i"))
  let setup = try #require(context.files.first { $0.name == "machine-setup.sh" }?.content)
  let enable = try #require(setup.split(separator: "\n").first { $0.contains("systemctl enable") })
  #expect(enable.contains("iso-ssh-vsock.socket"))
}

// MARK: - Remote relay last hop

@Test func relayCarriesABrokeredGuestThroughTheConnector() throws {
  let f = try SupervisorFixture()
  defer { f.cleanup() }
  // `/bin/cat` stands in for the runtime connector: the relay must spawn the
  // argv from native proof and carry bytes through it, with no address.
  f.native.set {
    $0.endpoint = GuestEndpoint(brokered: ConnectorCommand(executable: "/bin/cat", arguments: []))
  }
  let (instance, observation) = try f.running()
  let request = try f.openRequest(instance, observation)
  _ = try f.open(request).get()
  var pair: [Int32] = [0, 0]
  socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
  let client = pair[0]
  let server = pair[1]
  defer { close(client) }
  Thread.detachNewThread { f.supervisor.serveRelay(client: server) }
  let preamble = RelayPreamble(
    session: request.session, bearer: request.bearer, epoch: f.supervisor.epoch
  ).frame
  _ = preamble.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
  let status = Socket.readLine(client, limit: 4_096)
  #expect(status.map { String(decoding: $0, as: UTF8.self) } == #"{"ok":true}"#)
  _ = write(client, "ping", 4)
  var buffer = [UInt8](repeating: 0, count: 4)
  var tv = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  #expect(read(client, &buffer, 4) == 4)
  #expect(buffer == Array("ping".utf8))
  // Revoking the session ends the connector and the stream.
  f.supervisor.sessions.revoke(instance: instance.instanceID)
  #expect(read(client, &buffer, 4) == 0)
}

// MARK: - Handoff continuity

/// A brokered Running for the captured boot, optionally as another boot.
private func brokeredRunning(_ guest: FakeGuest, boot: String? = nil) throws -> AppleBackend.Running
{
  var object = try fixture("inspect-brokered-running.json")
  if let boot { object = edit(object, "live") { $0["bootId"] = boot } }
  let ready = try gate(object, expected())
  let sidecar = try workloadRunning(guest, identity: nil).sidecar
  guard case .brokered(let route) = ready.route else { throw HostError("not brokered") }
  var target = SSHTarget(
    host: "\(sandbox).iso", port: 22, user: .default, keyPath: guest.target.keyPath,
    knownHosts: guest.target.knownHosts, alias: "\(sandbox).iso")
  target.proxyCommand = try BrokeredConnector(executable: "/opt/iso/iso-sandbox", root: root)
    .proxyCommand(machine: sandbox, route: route)
  return AppleBackend.Running(
    instance: try testInstance(guest.root + "/instance"), sidecar: sidecar, ready: ready,
    target: target, handoffIdentity: nil)
}

@Test func aBrokeredHandoffIsSupervisedAndRefusesAReplacementBoot() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let original = try brokeredRunning(guest)
  #expect(original.hasLiveProof)
  #expect(SessionSupervisor.interval(for: original) == SessionSupervisor.interval)
  try WorkloadHandoff.require(original) { original }
  let replacement = try brokeredRunning(guest, boot: "0123456789abcdef0123456789abcdef")
  do {
    try WorkloadHandoff.require(original) { replacement }
    Issue.record("a prepared brokered session adopted a replacement boot")
  } catch let error as HostError {
    #expect(error.message.hasPrefix("BROKERED_HANDOFF_CHANGED"))
  }
  #expect(throws: HostError.self) { try WorkloadHandoff.require(original) { nil } }
  // The bound target rechecks before every guest operation.
  let bound = WorkloadHandoff.bind(original) { replacement }
  #expect(throws: GuestHandoffFailure.self) { try bound.requireHandoff() }
  // A vmnet instance without filtered egress keeps its unsupervised behavior.
  let vmnet = try workloadRunning(guest, identity: nil)
  #expect(!vmnet.hasLiveProof && SessionSupervisor.interval(for: vmnet) == nil)
}

// MARK: - Guest egress clients

@Test func guestDockerEgressWiringCarriesNoCapability() throws {
  let user = try GuestUser("dev")
  let script = EgressClients.script(port: 10789, user: user)
  // The URL with its per-boot capability arrives on stdin only.
  #expect(script.contains("IFS= read -r url"))
  #expect(!script.contains("http://iso:"))
  #expect(script.contains("ListenStream=\(EgressClients.dockerGateway):10789"))
  #expect(script.contains("systemd-socket-proxyd 127.0.0.1:10789"))
  #expect(script.contains("getent passwd dev"))
  #expect(script.contains("systemctl try-restart docker"))
  #expect(script.contains("git config --system http.proxyAuthMethod basic"))
  // Every guest session (host-control ones included) gets the proxy from
  // /etc/environment; the URL still arrives only on stdin.
  #expect(script.contains("envfile=/etc/environment"))
  #expect(script.contains(#"for k in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY"#))
  #expect(!script.contains("c0ffee"))
  let rendered = EgressClients.command(port: 10789, user: user).rendered
  #expect(rendered.hasPrefix("sudo sh -c '"))
  #expect(
    EgressClients.proxyURL(capability: "c0ffee", port: 10789) == "http://iso:c0ffee@127.0.0.1:10789"
  )
}
