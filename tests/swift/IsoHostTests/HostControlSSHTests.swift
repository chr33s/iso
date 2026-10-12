import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

@Suite struct LocalHostControlTests {
  func serve(_ f: SupervisorFixture) throws -> HostControlPaths {
    let paths = HostControlPaths(
      directory: FileManager.default.temporaryDirectory.appending(
        path: "iso-hc-\(UUID().uuidString.prefix(8))"
      ).path)
    let server = LocalHostServer(
      supervisor: f.supervisor, paths: paths, diagnostics: Diagnostics(verbosity: 0, sink: { _ in })
    )
    let listeners = try server.bind()
    Thread.detachNewThread { server.serve(listeners) }
    return paths
  }

  @Test func helloAndMutationsTravelOverThePrivateSocket() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let paths = try serve(f)
    defer { try? FileManager.default.removeItem(atPath: paths.directory) }
    var status = stat()
    #expect(lstat(paths.directory, &status) == 0)
    #expect(status.st_mode & 0o777 == 0o700)
    #expect(lstat(paths.control, &status) == 0)
    #expect(status.st_mode & 0o077 == 0)

    let enrolling = HostControlClient(transport: LocalHostTransport(paths: paths), expected: nil)
    let hello = try enrolling.hello(clientBuild: "test")
    #expect(hello.hostID == f.hostID)
    let client = HostControlClient(
      transport: LocalHostTransport(paths: paths), expected: (hello.hostID, hello.ownerID))
    let op = HostOperationID.generate()
    let receipt = try OperationReceipt(wire: client.call(.vmCreate(try f.spec()), operation: op))
    #expect(receipt.disposition == .accepted)
    // A second frontend sees the same durable operation.
    let other = HostControlClient(
      transport: LocalHostTransport(paths: paths), expected: (hello.hostID, hello.ownerID))
    #expect(try OperationReceipt(wire: other.call(.operationGet(op))).operationID == op)
    // A client expecting another installation refuses the reply.
    let wrong = HostControlClient(
      transport: LocalHostTransport(paths: paths), expected: (.generate(), hello.ownerID))
    #expect(throws: HostControlError.self) { try wrong.call(.vmList(cursor: nil, limit: 1)) }
  }

  @Test func malformedFrameClosesOnlyThatStream() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let paths = try serve(f)
    defer { try? FileManager.default.removeItem(atPath: paths.directory) }
    let fd = try #require(connectUnix(paths.control))
    defer { close(fd) }
    _ = write(fd, "not json\n", 9)
    var byte: UInt8 = 0
    #expect(read(fd, &byte, 1) == 0)
    // The service still answers new streams.
    let client = HostControlClient(transport: LocalHostTransport(paths: paths), expected: nil)
    #expect(try client.hello(clientBuild: "test").hostID == f.hostID)
  }

  @Test func lostReplyOnAMutationIsUncertainNotFailed() throws {
    struct Dropping: HostTransport {
      func exchange(_ frame: [UInt8]) throws(HostControlError) -> [UInt8] {
        throw HostControlError(.hostUnreachable, "connection reset")
      }
    }
    let client = HostControlClient(
      transport: Dropping(),
      expected: (.generate(), try OwnerID(String(repeating: "ab", count: 16))))
    let op = HostOperationID.generate()
    let spec = try VMSpec.make(
      name: InstanceName("x"), image: .default, imageDigest: nil, cpus: 2, memoryMiB: 2048,
      diskGiB: 8, guestOS: .linux, egress: .open)
    do {
      _ = try client.call(.vmCreate(spec), operation: op)
      Issue.record("expected a failure")
    } catch {
      #expect(error.code == .operationUncertain)
      #expect(error.retry == .retrySameOperationID)
      #expect(error.details["operation_id"] == op.rawValue)
    }
    do {
      _ = try client.call(.vmList(cursor: nil, limit: 1))
      Issue.record("expected a failure")
    } catch { #expect(error.code == .hostUnreachable) }
  }

  @Test func provenanceComesFromTheAcceptingSocket() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let paths = try serve(f)
    defer { try? FileManager.default.removeItem(atPath: paths.directory) }
    let created = try f.receipt(.vmCreate(f.spec()))
    f.supervisor.runPending()
    let instance = try #require(created.instance)
    let policy = try f.spec().policyHash
    func send(_ path: String, _ body: HostRequestBody, _ operation: HostOperationID?) throws
      -> HostResponse
    {
      let request = f.request(body, operation: operation)
      let fd = try #require(connectUnix(path))
      defer { close(fd) }
      _ = request.frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      return try HostResponse.decode(frame: try #require(Socket.readLine(fd, limit: 1 << 20)))
    }
    // The SSH frontend's socket: a start without a TTL gets the finite remote default.
    let remote = HostOperationID.generate()
    _ = try send(
      paths.remote, .vmStart(instance, expectedGeneration: 1, ttlSeconds: nil, policy: policy),
      remote)
    #expect(try f.supervisor.store.loadOperation(remote)?.deadline != nil)
    let resize = try send(
      paths.remote,
      .maintenance(instance, expectedGeneration: 1, .resize(cpus: 4, memoryMiB: nil, diskGiB: nil)),
      .generate())
    if case .failure(let error) = resize.outcome {
      #expect(error.code == .unsupportedCapability)
      #expect(error.message.contains("remote host"))
    } else {
      Issue.record("resize was accepted over the remote socket")
    }
  }

  @Test func socketDirectoryMustBePrivate() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "iso-hc-\(UUID().uuidString.prefix(8))"
    ).path
    mkdir(directory, 0o755)
    defer { rmdir(directory) }
    #expect(throws: HostError.self) { try HostControlPaths(directory: directory).prepare() }
  }
}

@Suite struct HostControlSSHTests {
  let alias = try! HostAlias("build-mac")
  let agent = try! AgentPath("/usr/local/bin/iso")

  @Test func remoteCommandIsTheFixedEntrypointOnly() {
    let arguments = managementSSHArguments(alias: alias, agent: agent, .serve)
    #expect(arguments.suffix(2) == ["build-mac", "'/usr/local/bin/iso' host-agent serve --stdio"])
    #expect(arguments.contains("StrictHostKeyChecking=yes"))
    #expect(arguments.contains("ForwardAgent=no"))
    #expect(arguments.contains("BatchMode=yes"))
    #expect(arguments[arguments.count - 3] == "--")
    let relay = managementSSHArguments(alias: alias, agent: agent, .relay)
    #expect(relay.last == "'/usr/local/bin/iso' host-agent relay --stdio")
  }

  @Test func agentPathsAreConservative() {
    for bad in [
      "iso", "/usr/bin/../iso", "/usr//iso", "/usr/bin/iso;id", "/a b/iso", "/usr/bin/$(id)",
    ] {
      #expect(throws: ValidationError.self, "\(bad)") { try AgentPath(bad) }
    }
  }

  @Test func managementKeyChangeIsDistinct() {
    let changed = SSHHostTransport.classify(
      Array(
        "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed."
          .utf8),
      alias: alias)
    #expect(changed.code == .hostIdentityChanged)
    #expect(changed.details["layer"] == "management")
    #expect(changed.retry == .explicitIdentityResolution)
    let down = SSHHostTransport.classify(
      Array("ssh: connect to host x port 22: Connection refused".utf8), alias: alias)
    #expect(down.code == .hostUnreachable)
  }

  @Test func requestBytesTravelOnStdinNotArgv() throws {
    let script = FileManager.default.temporaryDirectory.appending(path: "fake-ssh-\(UUID())").path
    defer { unlink(script) }
    // A fake ssh that echoes stdin back as the reply and records argv.
    let argvLog = script + ".argv"
    defer { unlink(argvLog) }
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argvLog)'\ncat\n".utf8).write(
      to: URL(fileURLWithPath: script))
    chmod(script, 0o755)
    let transport = SSHHostTransport(alias: alias, agent: agent, ssh: script, environment: [:])
    let frame = Array("{\"secret\":\"bearer-value\"}\n".utf8)
    #expect(try transport.exchange(frame) == Array(frame.dropLast()))
    let argv = try String(contentsOfFile: argvLog, encoding: .utf8)
    #expect(!argv.contains("bearer-value"))
  }

  @Test func registryKeepsOneIdentityPerAlias() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iso-hosts-\(UUID())")
      .path
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let registry = HostRegistry(directory: directory)
    let owner = try OwnerID(String(repeating: "ab", count: 16))
    let host = HostID.generate()
    try registry.save(
      HostEnrollment(
        alias: alias, sshAlias: alias, agentPath: agent, hostID: host, ownerID: owner, enrolledAt: 1
      ))
    #expect(throws: HostError.self) {
      try registry.save(
        HostEnrollment(
          alias: alias, sshAlias: alias, agentPath: agent, hostID: .generate(), ownerID: owner,
          enrolledAt: 2))
    }
    let second = try HostAlias("build-mac-2")
    try registry.save(
      HostEnrollment(
        alias: second, sshAlias: alias, agentPath: agent, hostID: host, ownerID: owner,
        enrolledAt: 3))
    #expect(Set(try registry.list().map(\.hostID)) == [host])
  }
}

@Suite struct RemoteGuestRouteTests {
  @Test func relayedTargetCarriesTheProxyAndKeepsThePin() throws {
    var target = SSHTarget(
      host: "proj.build-mac.iso-remote", port: 22, user: .default, keyPath: "/k/key",
      knownHosts: "/k/known_hosts", alias: "proj.build-mac.iso-remote")
    let direct = target
    target.proxyCommand = "/usr/local/bin/iso host-agent connect --descriptor /k/s.json"
    let options = target.sshOptions
    #expect(
      options.contains("ProxyCommand=/usr/local/bin/iso host-agent connect --descriptor /k/s.json"))
    #expect(options.contains("StrictHostKeyChecking=yes"))
    #expect(options.contains("UserKnownHostsFile=/k/known_hosts"))
    #expect(options.contains("HostKeyAlias=proj.build-mac.iso-remote"))
    // Route identity is part of connection identity.
    #expect(target != direct)
    #expect(!direct.sshOptions.contains { $0.hasPrefix("ProxyCommand=") })
  }

  @Test func remoteStagesAreKeyedByInstanceNotName() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "iso-rw-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let config = try testConfig(#""data_dir": "\#(root)""#)
    func binding(_ instance: InstanceID) throws -> ClientBinding {
      ClientBinding(
        host: try HostAlias("build-mac"),
        hostID: try HostID("aaaaaaaa-1111-4111-8111-111111111111"),
        ownerID: try OwnerID(String(repeating: "ab", count: 16)), instanceID: instance,
        runtimeID: try MachineName("iso-abababab-0011223344556677"), guestOS: .linux,
        name: try InstanceName("proj"), policyHash: HostWire.sha256([]), createdBy: .generate(),
        lastState: nil, lastObservedAt: nil)
    }
    let first = try RemoteWorkspace.shadow(config, binding(.generate()))
    let replacement = try RemoteWorkspace.shadow(config, binding(.generate()))
    // A replacement VM with the same name never reuses the old stage directory.
    #expect(first.directory != replacement.directory)
    #expect(first.name == replacement.name)
    var status = stat()
    #expect(lstat(first.directory, &status) == 0 && status.st_mode & 0o077 == 0)
  }
}

@Suite struct ClientSessionCoordinatorTests {
  @Test func aCoordinatorIsReusedOnlyWhileItHoldsItsLock() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "iso-co-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let config = try testConfig(#""data_dir": "\#(root)""#)
    let binding = ClientBinding(
      host: try HostAlias("build-mac"), hostID: .generate(),
      ownerID: try OwnerID(String(repeating: "ab", count: 16)), instanceID: .generate(),
      runtimeID: try MachineName("iso-abababab-0011223344556677"), guestOS: .linux,
      name: try InstanceName("proj"), policyHash: HostWire.sha256([]), createdBy: .generate(),
      lastState: nil, lastObservedAt: nil)
    let lock = try CoordinatorRecord.claim(config, binding)
    // One coordinator per binding.
    #expect(throws: HostControlError.self) { try CoordinatorRecord.claim(config, binding) }
    let descriptor = root + "/descriptor.json"
    try Data("{}".utf8).write(to: URL(fileURLWithPath: descriptor))
    let record = CoordinatorRecord.Published(
      pid: getpid(), session: .generate(), boot: try BootID("boot-1"), guestUser: .default,
      alias: "proj.build-mac.iso-remote", descriptor: descriptor, knownHosts: root + "/kh",
      sshConfig: root + "/cfg")
    let directory = RemoteWorkspace.directory(config, binding)
    try StateStore.writeControlFile(record, to: directory + "/coordinator.json")
    // The route is rebuilt from the session id, never from recorded paths.
    let target = try CoordinatorRecord.target(record, config: config)
    #expect(target.proxyCommand?.hasSuffix(SessionDescriptor.path(config, record.session)) == true)
    #expect(target.knownHosts.hasSuffix(record.session.rawValue + ".known_hosts"))
    // This test process is not an `iso host session`: its record is not live.
    #expect(CoordinatorRecord.live(config, binding) == nil)
    lock.release()
    // A new claim clears a stale record.
    try StateStore.writeControlFile(record, to: directory + "/coordinator.json")
    let second = try CoordinatorRecord.claim(config, binding)
    defer { second.release() }
    #expect(!FileManager.default.fileExists(atPath: directory + "/coordinator.json"))
  }
}
