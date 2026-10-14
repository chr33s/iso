import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

@Test(arguments: ["auto", "required"])
func remoteAgentsAlwaysRunWithTheProxyRequired(mode: String) throws {
  let config = try testConfig(#""proxy": {"mode": "\#(mode)"}"#)
  let brokered = try RemoteAgent.brokeredConfig(config)
  #expect(brokered.proxy.mode == .required)
  // Without an OpenAI proxy, `auto` would stage the client's auth.json; the
  // brokered config never does, whatever the egress.
  let staged = CodexConfigFiles.allowedFiles(
    proxyActive: false, proxyMode: brokered.proxy.mode, egress: .open, auth: .apiKey)
  #expect(!staged.contains("auth.json"))
  #expect(staged.contains("AGENTS.md"))
  #expect(
    CodexConfigFiles.allowedFiles(
      proxyActive: false, proxyMode: config.proxy.mode, egress: .open, auth: .apiKey
    ).contains("auth.json") == (mode == "auto"))
}

@Test func remoteAgentsRefuseProxyModeOff() throws {
  let config = try testConfig(#""proxy": {"mode": "off"}"#)
  let error = #expect(throws: HostError.self) { try RemoteAgent.brokeredConfig(config) }
  #expect(error?.description.contains("proxy.mode = \"off\"") == true)
}

@Test func bindingsRecordOnlyObservedStates() throws {
  let root = NSTemporaryDirectory() + "bindings-\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = ClientBindingStore(root: root)
  let binding = ClientBinding(
    host: try HostAlias("build-mac"), hostID: HostID.generate(),
    ownerID: try OwnerID(String(repeating: "ab", count: 16)),
    instanceID: InstanceID.generate(), runtimeID: try MachineName("iso-1a30dd1a-55014886318dd250"),
    guestOS: .linux, name: try InstanceName("app"),
    policyHash: SHA256Hex(digest: [UInt8](repeating: 0, count: 32)),
    createdBy: HostOperationID.generate(), lastState: .stopped, lastObservedAt: 7)
  try store.save(binding)
  #expect(try store.load(binding.hostID, binding.name) == binding)
  // An operation state written by an earlier build is not an observation.
  let path = root + "/" + binding.hostID.rawValue + "/app.json"
  let legacy = try String(contentsOfFile: path, encoding: .utf8)
    .replacingOccurrences(of: "\"stopped\"", with: "\"succeeded\"")
  try legacy.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  let loaded = try #require(try store.load(binding.hostID, binding.name))
  #expect(loaded.lastState == nil)
  #expect(loaded.name == binding.name)
}

@Test(arguments: [EgressMode.open, .none, .filtered])
func theAgentConfigKeepsTheProxyRequiredOnEveryEgress(egress: EgressMode) throws {
  let config = try testConfig(#""proxy": {"mode": "auto"}"#)
  let policy =
    egress == .filtered
    ? FilteredGrantPolicy(bootID: try BootID("boot-1"), policyHash: try BootID("policy-1")) : nil
  let effective = try RemoteAgent.agentConfig(config, filteredPolicy: policy, vmEgress: egress)
  // The egress choice must not replace the brokered proxy mode.
  #expect(effective.proxy.mode == .required)
  #expect(effective.egress == egress)
  #expect(
    !CodexConfigFiles.allowedFiles(
      proxyActive: false, proxyMode: effective.proxy.mode, egress: effective.egress,
      auth: .apiKey
    ).contains("auth.json"))
}

@Test func theAgentConfigRefusesAnUnprovenOrUnreportedEgress() throws {
  let config = try testConfig(#""proxy": {"mode": "auto"}"#)
  #expect(throws: HostError.self) {
    try RemoteAgent.agentConfig(config, filteredPolicy: nil, vmEgress: .filtered)
  }
  #expect(throws: HostError.self) {
    try RemoteAgent.agentConfig(config, filteredPolicy: nil, vmEgress: nil)
  }
}

@Test func remoteAgentsNeverReceiveMCPHeaderValues() throws {
  let config = try testConfig(
    #"""
    "codex": {"mcp_servers": {
      "private": {"type": "http", "url": "https://mcp.example.com/", "headers": {"Authorization": "cmd:printf tok"}},
      "public": {"type": "http", "url": "https://open.example.com/"},
      "local": {"command": "/usr/bin/mcp", "args": []}
    }}
    """#)
  #expect(config.headeredMCPServerNames == ["private"])
  let effective = try RemoteAgent.agentConfig(config, filteredPolicy: nil, vmEgress: .open)
  // Header values are resolved on this client; the remote guest gets none.
  #expect(effective.codex.mcpServers["private"] == nil)
  #expect(effective.codex.mcpServers["public"] != nil)
  #expect(effective.codex.mcpServers["local"] != nil)
}

@Test func remoteCodexReachesTheClientProxyThroughItsEnvKey() throws {
  let directory = NSTemporaryDirectory() + "remote-agent-\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let shadow = try testInstance(directory)
  // No proxy running: nothing is forwarded.
  #expect(!RemoteAgent.codex.agentEnvironment(shadow).contains(ModelRouting.codexLocalEnvKey))
  let token = ProxyLauncher.tokenPath(shadow, ProxyProvider.openai.rawValue)
  #expect(FileManager.default.createFile(atPath: token, contents: Data("cap-token\n".utf8)))
  #expect(chmod(token, 0o600) == 0)
  let env = RemoteAgent.codex.agentEnvironment(shadow)
  #expect(env.contains(ModelRouting.codexLocalEnvKey))
  #expect(env.overlay([:])[ModelRouting.codexLocalEnvKey] == "cap-token")
  #expect(env.sendEnvOptions == ["-o", "SendEnv=\(ModelRouting.codexLocalEnvKey)"])
  // Claude reads its proxy from settings, not the session environment.
  #expect(RemoteAgent.claude.agentEnvironment(shadow).sendEnvOptions.isEmpty)
}
