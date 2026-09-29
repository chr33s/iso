import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

// MARK: - Streaming and line bounds (S-03)

@Test func streamModeDeliversChunksAndHonorsSinkFailure() throws {
  var collected: [ProcessRunner.Stream: [UInt8]] = [:]
  let termination = try ProcessRunner().stream(
    .init(
      executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 2"],
      environment: [:], deadline: .seconds(5)),
    deadline: .seconds(5)
  ) { (stream, bytes) throws(ProcessRunner.Failure) in collected[stream, default: []] += bytes }
  #expect(termination == .exited(2))
  #expect(collected[.stdout] == Array("out".utf8))
  #expect(collected[.stderr] == Array("err".utf8))

  // A sink failure stops the run and kills the child.
  let start = ContinuousClock.now
  #expect(throws: ProcessRunner.Failure.self) {
    try ProcessRunner().stream(
      .init(
        executable: "/bin/sh", arguments: ["-c", "echo x; sleep 30"], environment: [:],
        deadline: .seconds(60)),
      deadline: nil
    ) { (_, _) throws(ProcessRunner.Failure) in throw .io(errno: EPIPE) }
  }
  #expect(ContinuousClock.now - start < .seconds(5))
}

@Test func boundedLinesTruncateAndKeepTheFinalLine() {
  var splitter = BoundedLineSplitter(limit: 4)
  var lines: [String] = []
  let emit = { (bytes: [UInt8]) in lines.append(String(decoding: bytes, as: UTF8.self)) }
  splitter.feed(Array("ab\ncdefgh\nij".utf8)[...], emit)
  splitter.feed(Array("kl".utf8)[...], emit)
  splitter.finish(emit)
  #expect(lines == ["ab", "cdef [line truncated]", "ijkl"])
  var empty = BoundedLineSplitter(limit: 4)
  var none: [[UInt8]] = []
  empty.finish { none.append($0) }
  #expect(none.isEmpty)
}

// MARK: - Guest usage

@Test func resourceUsageParsesTypicalOutput() {
  let sample = """
    0.12 0.08 0.03 1/42 1234
    MemTotal:        2048000 kB
    MemFree:          512000 kB
    MemAvailable:    1024000 kB
    Buffers:          128000 kB
    Filesystem     1M-blocks  Used Available Use% Mounted on
    /dev/vda1          20480  3200     16000  17% /

    """
  let usage = ResourceUsage.parse(sample)
  #expect(
    usage
      == ResourceUsage(
        load1m: 0.12, memUsedMiB: 1000, memTotalMiB: 2000, diskUsedMiB: 3200, diskTotalMiB: 20480))
  #expect(usage.summary == "load=0.12 mem=50% disk=15%")
  #expect(
    ResourceUsage.parse("")
      == ResourceUsage(load1m: 0, memUsedMiB: 0, memTotalMiB: 0, diskUsedMiB: 0, diskTotalMiB: 0))
  #expect(ResourceUsage.parse("0.00 0.00 0.00 0/0 0\n").memTotalMiB == 0)
  let display = ResourceUsage(
    load1m: 1.5, memUsedMiB: 512, memTotalMiB: 2048, diskUsedMiB: 5000, diskTotalMiB: 20000
  ).display
  #expect(display == "Load: 1.50  Mem: 512/2048 MiB (25%)  Disk: 5000/20000 MiB (25%)")
}

// MARK: - Profiles

private func config(_ text: String) throws -> IsoConfig {
  try ConfigLoader.decode(
    ConfigLoader.parse(Array(text.utf8), format: .jsonc, path: "c", limits: .configuration),
    path: "c",
    environment: .empty)
}

@Test func profilesShadowAndSummarize() throws {
  let c = try config(
    #"{"profiles": {"python": {"apt_packages": ["x"]}, "b": {}, "a": {"plugins": ["p", "q"], "pre_install": ""}}}"#
  )
  #expect(try Profiles.lookup("python", config: c).aptPackages == ["x"])
  #expect(try Profiles.lookup("rust", config: c).postInstall != nil)
  do {
    _ = try Profiles.lookup("zzz", config: c)
    Issue.record("unknown profile accepted")
  } catch {
    #expect(
      error.message
        == "Unknown profile: zzz\nAvailable profiles: python, node, c, fuzz, rust, go, a, b, python"
    )
  }
  let (builtin, custom) = Profiles.listing(c)
  #expect(builtin.map(\.name) == ["python", "node", "c", "fuzz", "rust", "go"])
  #expect(builtin[1].summary == "nodejs; pre-install script")
  #expect(
    builtin[4].summary == "post-install script; plugins: rust-analyzer-lsp@claude-plugins-official")
  #expect(
    custom.map(\.summary) == ["(pre-install script, 2 plugins)", "(empty)", "(1 apt packages)"])
  #expect(Profiles.scriptSummary(nil) == "(none)")
  #expect(Profiles.scriptSummary("") == "(none)")
  #expect(Profiles.scriptSummary("one\n") == "one")
  #expect(Profiles.scriptSummary("one\r\ntwo\nthree") == "one ... (3 lines)")
}

@Test func embeddedGuestScriptsMatchTheRepository() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..")
    .standardized
  let directory = root.appending(path: "scripts/guest")
  let files = FileManager.default.enumerator(atPath: directory.path)!.compactMap { $0 as? String }
    .filter {
      !$0.hasSuffix("/")
        && FileManager.default.contents(atPath: directory.appending(path: $0).path) != nil
    }
    .filter {
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(
        atPath: directory.appending(path: $0).path, isDirectory: &isDirectory)
      return !isDirectory.boolValue
    }
  #expect(
    Set(files) == Set(EmbeddedResources.guestScripts.keys),
    "run scripts/generate-embedded-resources.py")
  for file in files {
    let text = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
    #expect(
      EmbeddedResources.guestScripts[file] == text,
      "\(file) is stale; run scripts/generate-embedded-resources.py")
  }
}

// MARK: - Proxy state (C-04)

@Test func proxyOverridesResolveAndLiteralsAreNotKept() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-proxy-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let instance = Instance(
    name: try InstanceName("vm"), index: InstanceIndex(0)!, directory: directory, image: .default)
  #expect(try ProxyState.load(instance) == .empty)
  try Data(
    #"{"openai": {"credential": "cmd:pass x", "auth": "bearer"}, "anthropic": {"credential": "sk-SYNTHETIC"}, "extra": 1}"#
      .utf8
  )
  .write(to: URL(fileURLWithPath: instance.proxyStatePath))
  let state = try ProxyState.load(instance)
  #expect(state.anthropic == StoredUpstream(credential: .literal, auth: .apiKey))
  #expect(!String(reflecting: state).contains("sk-SYNTHETIC"))
  let c = try config(#"{"proxy": {"anthropic": {"credential": "cmd:default"}}}"#)
  #expect(
    ProxyResolution.resolve(.anthropic, state: state, config: c.proxy).description
      == "override — api_key, <literal credential, redacted>")
  #expect(
    ProxyResolution.resolve(.openai, state: state, config: c.proxy).description
      == "override — bearer, cmd:pass x")
  #expect(
    ProxyResolution.resolve(.anthropic, state: nil, config: c.proxy).description
      == "default — api_key, cmd:default")
  #expect(
    ProxyResolution.resolve(.openai, state: nil, config: c.proxy).description
      == "off (no default, no override)")
  try Data("{".utf8).write(to: URL(fileURLWithPath: instance.proxyStatePath))
  #expect(throws: HostError("Failed to parse proxy.json")) { try ProxyState.load(instance) }
}

@Test func storedCredentialNamesIncludePerVMOverridesAndFailOnCorruption() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-proxy-names-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let instance = Instance(
    name: try InstanceName("vm"), index: InstanceIndex(0)!, directory: directory, image: .default)
  let c = try config(#"{"proxy": {"anthropic": {"credential": "vault:shared"}}}"#)
  try Data(#"{"openai": {"credential": "vault:per-vm", "auth": "bearer"}}"#.utf8)
    .write(to: URL(fileURLWithPath: instance.proxyStatePath))
  #expect(
    try ProxyState.storedCredentialNames(c.proxy, instance: instance)
      == [try SecretName("shared"), try SecretName("per-vm")])
  #expect(
    try ProxyState.storedCredentialNames(c.proxy, instance: nil) == [try SecretName("shared")])
  try Data("{".utf8).write(to: URL(fileURLWithPath: instance.proxyStatePath))
  #expect(throws: HostError.self) {
    try ProxyState.storedCredentialNames(c.proxy, instance: instance)
  }
  let off = try config(
    #"{"proxy": {"mode": "off", "anthropic": {"credential": "vault:shared"}}}"#)
  #expect(try ProxyState.storedCredentialNames(off.proxy, instance: instance).isEmpty)
}

// MARK: - Images

@Test func imageListingSkipsInvalidNamesAndTolerantConfigs() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "iso-img-\(UUID().uuidString)")
    .path
  defer { try? FileManager.default.removeItem(atPath: root) }
  let c = try config("{\"data_dir\": \"\(root)\"}")
  let images = c.imagesDirectory.path
  let good =
    #"{"version":1,"created":"t","install_script_hash":"\#(String(repeating: "A", count: 64))","profiles":["rust"],"extra_packages":[],"post_install_hash":null}"#
  for (name, body) in [
    ("b", good), ("a", #"{"version":1}"#), (".hidden", good),
    (
      "c", good.replacingOccurrences(of: "rust", with: "x\"], \"guest_user\": \"root\", \"y\": [\"")
    ),
  ] {
    try FileManager.default.createDirectory(
      atPath: images + "/" + name, withIntermediateDirectories: true)
    try Data(body.utf8).write(
      to: URL(fileURLWithPath: images + "/" + name + "/template-config.json"))
  }
  var skipped: [String] = []
  let listed = try ImageStore.list(c) { raw, _ in skipped.append(raw) }
  #expect(listed.map(\.name.rawValue) == ["a", "b", "c"])
  #expect(listed[0].config == nil)
  #expect(listed[1].config?.profiles == ["rust"])
  #expect(listed[1].config?.guestUser == .default)
  #expect(listed[2].config == nil)  // guest_user "root" is invalid
  #expect(skipped == [".hidden"])
}

// MARK: - Running resolution with a scripted runtime

@Test func resolveRunningFollowsTheBaselineTable() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "iso-rr-\(UUID().uuidString)")
    .path
  defer { try? FileManager.default.removeItem(atPath: root) }
  let c = try config("{\"data_dir\": \"\(root)\"}")
  var instances: [Instance] = []
  for (index, name) in ["a", "b"].enumerated() {
    let directory = c.instancesDirectory.path + "/" + name
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    instances.append(
      Instance(
        name: try InstanceName(name), index: InstanceIndex(UInt16(index))!, directory: directory,
        image: .default))
  }
  let backend = AppleBackend(config: c, environment: [:]) { () throws(RuntimeError) in
    SandboxRuntime(
      executor: ScriptedRuntime { _ in ScriptedRuntime.ok(qualifiedVersion) }, root: "/r",
      settings: .defaults)
  }
  func message(_ name: String?, _ list: [Instance]) -> String {
    do {
      _ = try backend.resolveRunning(name.map { try! InstanceName($0) }, instances: list)
      return "resolved"
    } catch { return "\(error)" }
  }
  #expect(
    message(nil, instances)
      == "No running instances. Stopped: a, b\nStart one with: iso start <name>")
  #expect(
    message(nil, [instances[0]])
      == "Instance 'a' exists but is stopped.\nStart it with: iso start a")
  #expect(message(nil, []).hasPrefix("No instances found."))
  #expect(
    message("zz", instances) == "No instance named 'zz'.\nCreate one with: iso up . --name zz")
  #expect(message("a", instances).hasPrefix("No Apple sandbox backend state at"))
}

// MARK: - Pinned SSH target

@Test func pinnedTargetRequiresAnEnrolledKeyAndSafePaths() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "iso-ssh-\(UUID().uuidString)")
    .path
  defer { try? FileManager.default.removeItem(atPath: root) }
  let c = try config("{\"data_dir\": \"\(root)\"}")
  let directory = root + "/inst dir"
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("vm"), index: InstanceIndex(0)!, directory: directory, image: .default)
  let machine = try MachineName("coop-0a1b2c3d-00112233445566ff")
  let ip = try IPv4Address("10.231.2.2")
  do {
    _ = try SSHTarget.pinned(
      config: c, instance: instance, machine: machine, ip: ip, user: .default)
    Issue.record("unenrolled instance accepted")
  } catch let error as RuntimeError {
    guard case .hostKeyChanged = error else { throw error }
  }
  try Data("pin\n".utf8).write(to: URL(fileURLWithPath: instance.knownHostsPath))
  let target = try SSHTarget.pinned(
    config: c, instance: instance, machine: machine, ip: ip, user: .default)
  #expect(target.address == "ubuntu@10.231.2.2")
  #expect(
    target.hostKeyOptions == [
      "StrictHostKeyChecking=yes", "UserKnownHostsFile=\"\(directory)/known_hosts\"",
      "GlobalKnownHostsFile=/dev/null",
      "HostKeyAlias=coop-0a1b2c3d-00112233445566ff.coop", "UpdateHostKeys=no",
      "ForwardAgent=no", "IdentityAgent=none",
    ])
  #expect(target.sshOptions.suffix(4) == ["-i", c.sshKeyPath.path, "-p", "22"])
  #expect(target.sshOptions.prefix(2) == ["-o", "BatchMode=yes"])
  let quoted = root + "/it's"
  try FileManager.default.createDirectory(atPath: quoted, withIntermediateDirectories: true)
  try Data("pin\n".utf8).write(to: URL(fileURLWithPath: quoted + "/known_hosts"))
  let bad = Instance(
    name: try InstanceName("vm"), index: InstanceIndex(0)!, directory: quoted, image: .default)
  #expect(throws: HostError.self) {
    try SSHTarget.pinned(config: c, instance: bad, machine: machine, ip: ip, user: .default)
  }
  #expect(SSHTarget.quoteValue("/a b") == "\"/a b\"")
  #expect(SSHTarget.quoteValue("/a/b") == "/a/b")
}
