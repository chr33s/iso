import Foundation
import IsoCore
import Testing

@testable import IsoHost

/// S1 (SSH-01/02): every managed SSH role, as the real `/usr/bin/ssh`
/// resolves it (`ssh -G` prints the effective configuration without
/// connecting). A hostile configuration file is put ahead of each role's own
/// arguments, standing in for `~/.ssh/config`: a guest role must discard it
/// (`-F none`), and the management role, which keeps its trusted
/// configuration by design, must still override the authority it grants.
@Suite struct ManagedSSHRoleTests {
  static let ssh = "/usr/bin/ssh"

  let hostile: String
  /// ssh ignores an `-i` file that does not exist; iso's key always does.
  let key: String

  init() throws {
    let directory = try scratchDirectory("ssh-roles")
    key = directory + "/key"
    try writeFile(key, "not a real key\n")
    hostile = directory + "/hostile-config"
    try writeFile(
      hostile,
      """
      Host *
        ProxyCommand /bin/sh -c 'touch /tmp/iso-ambient-proxy'
        LocalCommand /bin/sh -c 'touch /tmp/iso-ambient-local'
        PermitLocalCommand yes
        ForwardAgent yes
        ForwardX11 yes
        SendEnv *
        LocalForward 9999 127.0.0.1:22
        RemoteForward 9998 127.0.0.1:22
        IdentityAgent /tmp/iso-ambient-agent
        IdentityFile /tmp/iso-ambient-key
        StrictHostKeyChecking no
        UserKnownHostsFile /tmp/iso-ambient-known-hosts
        ControlMaster auto
        ControlPath /tmp/iso-ambient-control

      """)
  }

  /// `ssh -G` under the hostile configuration: effective option -> values.
  func effective(_ arguments: [String]) throws -> [String: [String]] {
    let output = try ProcessRunner().capture(
      .init(
        executable: Self.ssh, arguments: ["-G", "-F", hostile] + arguments, environment: [:],
        deadline: .seconds(10), outputLimit: 1 << 20, overflow: .drain))
    #expect(output.termination.succeeded, "\(String(decoding: output.stderr, as: UTF8.self))")
    var options: [String: [String]] = [:]
    for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
      if parts.count == 2 { options[parts[0], default: []].append(parts[1]) }
    }
    return options
  }

  func target(proxy: String? = nil) -> SSHTarget {
    var target = SSHTarget(
      host: "127.0.0.1", port: 2222, user: .default, keyPath: key,
      knownHosts: "/iso/known_hosts", alias: "iso-guest")
    target.proxyCommand = proxy
    return target
  }

  /// What every guest role must resolve to: iso's pin, key and route only.
  func expectGuestPolicy(
    _ options: [String: [String]], proxy: String? = nil, forwards: [String] = [],
    _ role: String
  ) {
    #expect(options["proxycommand"] == proxy.map { [$0] }, "\(role)")
    #expect(options["localcommand"] == nil, "\(role)")
    #expect(options["permitlocalcommand"] == ["no"], "\(role)")
    #expect(options["forwardagent"] == ["no"], "\(role)")
    #expect(options["forwardx11"] == ["no"], "\(role)")
    #expect(options["sendenv"] == nil, "\(role)")
    #expect(options["remoteforward"] == nil, "\(role)")
    #expect((options["localforward"] ?? []) == forwards, "\(role)")
    #expect(options["identityagent"] == ["none"], "\(role)")
    #expect(options["identityfile"] == [key], "\(role)")
    #expect(options["stricthostkeychecking"] == ["true"], "\(role)")
    #expect(options["userknownhostsfile"] == ["/iso/known_hosts"], "\(role)")
    #expect(options["hostkeyalias"] == ["iso-guest"], "\(role)")
    #expect(options["controlpath"] == nil, "\(role)")
  }

  @Test func guestCommandsProbesAndTunnelsIgnoreAmbientConfiguration() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.ssh) else { return }
    let guest = target()
    // Command, capture and readiness probes.
    expectGuestPolicy(try effective(guest.sshOptions + [guest.address]), "guest command")
    // Port forwards, the proxy's reverse tunnel and the editor's outer
    // tunnel: the shared options plus only their own explicit forward.
    expectGuestPolicy(
      try effective(
        guest.sshOptions + ["-N", "-L", "127.0.0.1:18080:127.0.0.1:8080", guest.address]),
      forwards: ["[127.0.0.1]:18080 [127.0.0.1]:8080"], "port forward")
    // A brokered or relayed route: exactly iso's connector, never the
    // ambient ProxyCommand.
    let connector = "/opt/iso/iso-sandbox connect --root /r m --boot b"
    let brokered = target(proxy: connector)
    expectGuestPolicy(
      try effective(brokered.sshOptions + [brokered.address]), proxy: connector, "brokered route")
  }

  @Test func transferRolesCarryTheSameGuestPolicy() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.ssh) else { return }
    let guest = target()
    // rsync's `-e`, tokenized as openrsync does (spaces; single quotes group).
    var words: [String] = []
    var word = ""
    var quoted = false
    for character in try guest.rsyncSSHCommand(ssh: Self.ssh) {
      if character == "'" {
        quoted.toggle()
      } else if character == " " && !quoted {
        if !word.isEmpty { words.append(word) }
        word = ""
      } else {
        word.append(character)
      }
    }
    if !word.isEmpty { words.append(word) }
    #expect(words.first == Self.ssh)
    expectGuestPolicy(try effective(Array(words.dropFirst()) + [guest.address]), "rsync -e")
    // scp hands its options to the ssh named by `-S`; `-P` is ssh's `-p`.
    var scp = guest.scpOptions(ssh: Self.ssh)
    #expect(scp.starts(with: ["-q", "-S", Self.ssh]))
    scp.removeFirst(3)
    if let port = scp.firstIndex(of: "-P") { scp[port] = "-p" }
    expectGuestPolicy(try effective(scp + [guest.address]), "scp")
  }

  /// SSH-03: teardown names only the owned socket and can never open a new
  /// connection (no ambient ControlMaster, ProxyCommand or route).
  @Test func controlTeardownUsesOnlyTheOwnedSocket() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.ssh) else { return }
    let options = try effective(target().controlExitArguments("/iso/instance/forwards.sock"))
    #expect(options["controlmaster"] == ["false"])
    #expect(options["controlpath"] == ["/iso/instance/forwards.sock"])
    #expect(options["proxycommand"] == nil && options["localcommand"] == nil)
    #expect(options["localforward"] == nil && options["remoteforward"] == nil)
    // S2: a missing (or removed) socket fails on the socket itself; nothing
    // dials the guest address (TEST-NET, which would hang if dialed).
    let unroutable = SSHTarget(
      host: "192.0.2.1", port: 22, user: .default, keyPath: key, knownHosts: "/iso/known_hosts",
      alias: "iso-guest")
    let started = ContinuousClock.now
    let output = try ProcessRunner().capture(
      .init(
        executable: Self.ssh,
        arguments: unroutable.controlExitArguments(try scratchDirectory("gone") + "/forwards.sock"),
        environment: [:], deadline: .seconds(20), outputLimit: 1 << 16, overflow: .drain))
    #expect(!output.termination.succeeded)
    #expect(String(decoding: output.stderr, as: UTF8.self).contains("Control socket connect"))
    #expect(ContinuousClock.now - started < .seconds(5))
  }

  /// The enrolled-host management role keeps its trusted configuration (its
  /// route and keys may live there) but grants no agent, X11, forward or
  /// local command, whatever that configuration says.
  @Test func managementSSHOverridesGrantedAuthority() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.ssh) else { return }
    let arguments = managementSSHArguments(
      alias: try HostAlias("build-mac"), agent: try AgentPath("/usr/local/bin/iso"), .relay)
    let options = try effective(arguments)
    #expect(options["forwardagent"] == ["no"])
    #expect(options["forwardx11"] == ["no"])
    #expect(options["permitlocalcommand"] == ["no"])
    #expect(options["clearallforwardings"] == ["yes"])
    #expect(options["stricthostkeychecking"] == ["true"])
    #expect(options["batchmode"] == ["yes"])
    // Positive witness: the trusted configuration is read for this role.
    #expect(options["identityfile"]?.contains("/tmp/iso-ambient-key") == true)
  }
}
