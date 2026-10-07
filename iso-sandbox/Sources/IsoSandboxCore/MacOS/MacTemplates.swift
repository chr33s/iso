import CryptoKit
import Foundation
import Synchronization
import Virtualization
import vmnet

/// Builds and publishes macOS templates (Gates A, B, M). A template is
/// built in `macos/templates/.build-<uuid>` and published by one rename only
/// after the guest shut itself down cleanly; any failure deletes the build.
package enum MacTemplates {
  package static let guestUser = "iso"
  package static let helperGuestPath = "/usr/local/libexec/iso-macos-helper"
  package static let helperLabel = "dev.iso.macos-helper"
  /// The environment variable through which `iso-sandbox` answers ssh's
  /// password prompt during a template build (see `Entry.main`).
  package static let askpassEnv = "ISO_SANDBOX_ASKPASS_SECRET"

  static func log(_ s: String) {
    FileHandle.standardError.write(Data("macos template: \(s)\n".utf8))
  }

  package static func sha256(_ url: URL) throws -> String {
    let h = FileHandle(forReadingAtPath: url.path)
    guard let h else { throw SandboxError("cannot read \(url.path)") }
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  package static func list(root: SandboxRoot) -> [MacTemplate] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.macTemplates.path)) ?? []
    return names.sorted().compactMap { n in
      (try? SandboxID(n)).flatMap { try? root.macTemplate($0).load() }
    }
  }

  /// Every boot reads the template's hardware model, so a template is
  /// removed only once no sandbox records it.
  package static func delete(root: SandboxRoot, name: SandboxID) throws {
    let operation = try OperationLock.shared(root)
    defer { withExtendedLifetime(operation) {} }
    let guarded = try FileLock.acquire(root.macTemplateLock(name), .exclusive)
    defer { withExtendedLifetime(guarded) {} }
    let t = root.macTemplate(name)
    _ = try t.load()
    let users = try root.allMacRecords().filter { $0.template == name }.map(\.id.rawValue)
    guard users.isEmpty else {
      throw SandboxError("template \(name) is used by \(users.joined(separator: ", "))")
    }
    try FileManager.default.removeItem(at: t.dir)
  }

  package static func build(
    root: SandboxRoot, name: SandboxID, ipsw: URL, helper: URL, provision: URL? = nil,
    executable: String, cpus: Int, memoryBytes: UInt64, diskBytes: UInt64
  ) async throws -> MacTemplate {
    try root.createMacDirectories()
    // Held for the whole build, so `reconcile` never removes a live build.
    let operation = try OperationLock.shared(root)
    defer { withExtendedLifetime(operation) {} }
    let final = root.macTemplate(name)
    guard !FileManager.default.fileExists(atPath: final.dir.path) else {
      throw SandboxError("template \(name) already exists")
    }
    let build = MacTemplatePaths(
      dir: root.macTemplates.appendingPathComponent(".build-\(UUID().uuidString.lowercased())"))
    try FileManager.default.createDirectory(
      at: build.dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let template = try await buildInto(
        build, name: name, ipsw: ipsw, helper: helper, provision: provision,
        executable: executable, cpus: cpus, memoryBytes: memoryBytes, diskBytes: diskBytes)
      try JSONEncoder.pretty.encode(template).write(to: build.metadata, options: .atomic)
      guard rename(build.dir.path, final.dir.path) == 0 else {
        throw SandboxError("publish \(name): errno \(errno)")
      }
      log("published \(name)")
      return template
    } catch {
      try? FileManager.default.removeItem(at: build.dir)
      throw error
    }
  }

  static func buildInto(
    _ b: MacTemplatePaths, name: SandboxID, ipsw: URL, helper: URL, provision: URL?,
    executable: String, cpus: Int, memoryBytes: UInt64, diskBytes: UInt64
  ) async throws -> MacTemplate {
    // The small inputs first: a missing helper (an install that predates
    // it) fails before the restore image is read.
    guard FileManager.default.isReadableFile(atPath: helper.path) else {
      throw SandboxError(
        "iso-macos-helper not found at \(helper.path); reinstall iso (install.sh or `iso update`) or pass --helper"
      )
    }
    let helperSha = try sha256(helper)
    let provisionSha = try provision.map(sha256)
    let ipswSha = try sha256(ipsw)
    log("restore image sha256 \(ipswSha)")
    let image = try await VZMacOSRestoreImage.image(from: ipsw)
    guard let req = image.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else {
      throw SandboxError("restore image \(image.buildVersion) is not supported on this host")
    }
    guard cpus >= req.minimumSupportedCPUCount, memoryBytes >= req.minimumSupportedMemorySize else {
      throw SandboxError(
        "restore image needs at least \(req.minimumSupportedCPUCount) CPUs and \(req.minimumSupportedMemorySize >> 20) MiB"
      )
    }
    try req.hardwareModel.dataRepresentation.write(to: b.hardwareModel)
    let machineID = VZMacMachineIdentifier()
    _ = try VZMacAuxiliaryStorage(
      creatingStorageAt: b.aux, hardwareModel: req.hardwareModel, options: [])
    guard
      FileManager.default.createFile(
        atPath: b.disk.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw SandboxError("create \(b.disk.path)") }
    let fh = try FileHandle(forWritingTo: b.disk)
    try fh.truncate(atOffset: diskBytes)
    try fh.close()

    // A vmnet network of the build's own: the build VM is its only peer, so
    // the session below cannot reach (or be answered by) any other VM.
    let buildNet = try BuildNetwork.create()
    log("build network \(buildNet.subnet)")
    func config(mac: VZMACAddress) throws -> VZVirtualMachineConfiguration {
      let net = VZVirtioNetworkDeviceConfiguration()
      net.attachment = VZVmnetNetworkDeviceAttachment(network: buildNet.reference)
      net.macAddress = mac
      return try MacConfig.make(
        hardwareModel: req.hardwareModel, machineIdentifier: machineID, aux: b.aux, disk: b.disk,
        cpus: cpus, memoryBytes: memoryBytes, network: net)
    }
    let mac = VZMACAddress.randomLocallyAdministered()

    // 1. Install, on the VM queue.
    let installer = MacVM(
      configuration: try config(mac: mac), label: "install-\(name)", log: { log($0) })
    let lastTenth = Mutex(-1)
    try await installer.install(restoreImage: ipsw) { fraction in
      let tenth = Int(fraction * 10)
      let report = lastTenth.withLock { last -> Bool in
        defer { last = max(last, tenth) }
        return tenth > last
      }
      if report { log("install \(tenth * 10)%") }
    }
    installer.teardown()
    log("installed \(image.buildVersion)")

    // 2. Provisioning first boot: user, password (memory only), autologin, Remote Login.
    let password = TemplatePassword.random()
    let stopped = StopFlag()
    let options = VZMacOSVirtualMachineStartOptions()
    let p = VZMacGuestProvisioningOptions()
    p.fullName = "iso"
    p.username = guestUser
    p.password = password
    p.logsInAutomatically = true
    p.enablesRemoteLogin = true
    try options.setGuestProvisioning(p)
    // The installer's VM releases the auxiliary-storage lock when it is
    // deallocated, which can trail its teardown briefly. A VM whose start
    // failed cannot be started again, so each attempt gets a new one.
    var vm: MacVM
    var attempt = 0
    while true {
      stopped.reset()
      let buildLog: @Sendable (String) -> Void = { log($0) }
      vm = MacVM(configuration: try config(mac: mac), label: "provision-\(name)", log: buildLog) {
        _ in stopped.set()
      }
      do {
        try await vm.start(options: options)
        break
      } catch  where attempt < 10 {
        vm.teardown()
        attempt += 1
        log("provisioning boot attempt \(attempt) failed (\(error)); retrying")
        try await Task.sleep(for: .seconds(3))
      }
    }
    defer { vm.teardown() }
    log("provisioning boot started")

    do {
      let ip = try await buildNet.findGuest(mac: mac.string, timeout: 900)
      log("guest at \(ip)")
      let ssh = TemplateSSH(
        ip: ip, knownHosts: b.dir.appendingPathComponent("known_hosts"), password: password,
        askpass: executable)
      try await ssh.waitReady(timeout: 900)
      // Read before setup: setup ends by deleting the host keys, after which
      // the guest's sshd accepts no new connection.
      let build = try GuestText.version(ssh.run("sw_vers -buildVersion", timeout: 30).output)
      let version = try GuestText.version(ssh.run("sw_vers -productVersion", timeout: 30).output)
      try ssh.copy(helper, to: "iso-macos-helper")
      if let provision { try ssh.copy(provision, to: "iso-provision.sh") }
      try ssh.put(guestSetupScript(provision: provision != nil), to: "iso-setup.sh")
      let setup = try ssh.run(
        "sudo -S -p '' /bin/sh /Users/iso/iso-setup.sh", stdin: password + "\n", timeout: 3600)
      guard setup.status == 0 else {
        throw SandboxError(
          "guest setup failed (\(setup.status)): \(GuestText.printable(String(setup.output.suffix(2000))))"
        )
      }
      // The script scheduled the guest's own shutdown: a template is only
      // ever cleanly stopped.
      guard await waitUntil(300, { stopped.isSet }) else {
        await vm.forceStop()
        throw SandboxError("guest did not shut down cleanly; template not published")
      }
      try? FileManager.default.removeItem(at: b.dir.appendingPathComponent("known_hosts"))
      return MacTemplate(
        name: name, productVersion: version, build: build, ipswSha256: ipswSha,
        helperSha256: helperSha, provisionSha256: provisionSha, diskBytes: diskBytes,
        minimumCPUs: req.minimumSupportedCPUCount,
        minimumMemoryBytes: req.minimumSupportedMemorySize, createdAt: Date())
    } catch {
      await vm.forceStop()
      throw error
    }
  }

  /// Run as root in the guest during the build. Ends by removing the SSH
  /// host keys, so every clone generates its own at enrollment. With
  /// `provision`, the operator's script runs as root after the runtime's own
  /// setup and before that cleanup; its failure fails the build.
  static func guestSetupScript(provision: Bool = false) -> String {
    """
    #!/bin/sh
    set -eu
    install -d -m 0755 /usr/local/libexec
    install -m 0755 -o root -g wheel /Users/iso/iso-macos-helper \(helperGuestPath)
    cat > /Library/LaunchDaemons/\(helperLabel).plist <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(helperLabel)</string>
    <key>ProgramArguments</key><array><string>\(helperGuestPath)</string></array>
    <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    </dict></plist>
    PLIST
    chown root:wheel /Library/LaunchDaemons/\(helperLabel).plist
    chmod 0644 /Library/LaunchDaemons/\(helperLabel).plist
    # Passwordless sudo, as in Linux guests: the VM is the boundary.
    printf 'iso ALL=(ALL) NOPASSWD: ALL\\n' > /etc/sudoers.d/iso
    chmod 0440 /etc/sudoers.d/iso
    /usr/sbin/visudo -c -f /etc/sudoers.d/iso
    # Key-only SSH; keys are authorized per clone at enrollment.
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PasswordAuthentication no\\nKbdInteractiveAuthentication no\\nPermitRootLogin no\\n' > /etc/ssh/sshd_config.d/100-iso.conf
    # No sleep, no display sleep, no screensaver, no app relaunch at login.
    pmset -a sleep 0 displaysleep 0 disksleep 0
    sudo -u iso defaults -currentHost write com.apple.screensaver idleTime 0
    sudo -u iso defaults write com.apple.loginwindow TALLogoutSavesState -bool false
    sudo -u iso defaults write -g NSQuitAlwaysKeepsWindows -bool false
    # Updates are explicit (Gate R policy): nothing is downloaded or
    # installed automatically. macOS keeps checking; without device
    # management, `softwareupdate --schedule off` has no effect.
    defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
    defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
    \(provision ? "/bin/bash /Users/iso/iso-provision.sh </dev/null" : ":")
    rm -f /Users/iso/iso-macos-helper /Users/iso/iso-setup.sh /Users/iso/iso-provision.sh
    # Last: no host keys in the template, then a clean shutdown once this
    # session has returned.
    rm -f /etc/ssh/ssh_host_*
    ( sleep 3; /sbin/shutdown -h now ) >/dev/null 2>&1 &
    """
  }
}

final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.withLock { value = true } }
  func reset() { lock.withLock { value = false } }
  var isSet: Bool { lock.withLock { value } }
}

enum TemplatePassword {
  /// 32 characters from a password-safe alphabet.
  static func random() -> String {
    let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var out = ""
    for _ in 0..<32 { out.append(alphabet[Int(arc4random_uniform(UInt32(alphabet.count)))]) }
    return out
  }
}

/// The template build's only SSH session: password auth answered by this
/// binary as `SSH_ASKPASS` (the password travels in that child's
/// environment only), trust-on-first-use into the build's own known_hosts.
struct TemplateSSH {
  let ip: String
  let knownHosts: URL
  let password: String
  let askpass: String

  var options: [String] {
    // No user configuration, agent, forwarding or multiplexing: this session
    // talks to a guest trusted on first use.
    [
      "-F", "/dev/null", "-o", "UserKnownHostsFile=\(knownHosts.path)",
      "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=accept-new",
      "-o", "PreferredAuthentications=password,keyboard-interactive", "-o",
      "PubkeyAuthentication=no", "-o", "IdentityAgent=none", "-o", "ForwardAgent=no",
      "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no",
      "-o", "ControlPath=none", "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=5",
      "-o", "NumberOfPasswordPrompts=1", "-o", "LogLevel=ERROR",
    ]
  }

  var environment: [String: String] {
    [
      "PATH": "/usr/bin:/bin", "SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force",
      "DISPLAY": "none", MacTemplates.askpassEnv: password, "HOME": NSHomeDirectory(),
    ]
  }

  func run(_ command: String, stdin: String? = nil, timeout: TimeInterval) throws -> (
    status: Int32, output: String
  ) {
    try Subprocess.run(
      ["/usr/bin/ssh"] + options + ["\(MacTemplates.guestUser)@\(ip)", command],
      environment: environment, stdin: stdin.map { Data($0.utf8) }, timeout: timeout)
  }

  func waitReady(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    var last = ""
    while Date() < deadline {
      if let r = try? run("true", timeout: 20) {
        if r.status == 0 { return }
        last = r.output
      }
      try await Task.sleep(for: .seconds(5))
    }
    throw SandboxError(
      "guest SSH not ready within \(Int(timeout))s: \(GuestText.printable(String(last.suffix(300))))"
    )
  }

  func copy(_ local: URL, to remoteName: String) throws {
    let r = try Subprocess.run(
      ["/usr/bin/scp", "-q"] + options + [
        local.path, "\(MacTemplates.guestUser)@\(ip):\(remoteName)",
      ],
      environment: environment, stdin: nil, timeout: 300)
    guard r.status == 0 else { throw SandboxError("scp failed: \(r.output.suffix(500))") }
  }

  func put(_ text: String, to remoteName: String) throws {
    let r = try run("cat > \(remoteName)", stdin: text, timeout: 60)
    guard r.status == 0 else { throw SandboxError("write \(remoteName) failed: \(r.output)") }
  }
}

/// Argv-only subprocesses with bounded output and a deadline.
enum Subprocess {
  static func run(
    _ argv: [String], environment: [String: String], stdin: Data?, timeout: TimeInterval
  ) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.environment = environment
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    let input = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : input
    try p.run()
    if let stdin {
      try? input.fileHandleForWriting.write(contentsOf: stdin)
      try? input.fileHandleForWriting.close()
    }
    final class Box: @unchecked Sendable { var data = Data() }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    let reader = out.fileHandleForReading
    Thread.detachNewThread {
      box.data = reader.readDataToEndOfFile()
      done.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning, Date() < deadline { usleep(50_000) }
    if p.isRunning {
      p.terminate()
      _ = done.wait(timeout: .now() + 2)
      return (-2, "timeout after \(Int(timeout))s")
    }
    _ = done.wait(timeout: .now() + 2)
    return (p.terminationStatus, String(decoding: box.data.suffix(64 * 1024), as: UTF8.self))
  }
}

/// A vmnet shared-mode network with DHCP, created for one template build:
/// no other VM is on it. Its subnet is outside the sandbox range.
struct BuildNetwork: @unchecked Sendable {
  let reference: vmnet_network_ref
  let subnet: String
  let prefix: String

  static func create() throws -> BuildNetwork {
    var last = "no attempt"
    for _ in 0..<16 {
      let n = Int(arc4random_uniform(250)) + 1
      let prefix = "10.232.\(n)"
      var status: vmnet_return_t = .VMNET_FAILURE
      guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        throw SandboxError("vmnet configuration failed: \(status)")
      }
      var gateway = in_addr()
      var mask = in_addr()
      guard inet_pton(AF_INET, "\(prefix).1", &gateway) == 1,
        inet_pton(AF_INET, "255.255.255.0", &mask) == 1,
        vmnet_network_configuration_set_ipv4_subnet(config, &gateway, &mask) == .VMNET_SUCCESS
      else { throw SandboxError("vmnet subnet \(prefix).0/24 rejected") }
      if let network = vmnet_network_create(config, &status), status == .VMNET_SUCCESS {
        return BuildNetwork(reference: network, subnet: "\(prefix).0/24", prefix: prefix)
      }
      last = "\(status)"
    }
    throw SandboxError("no build network could be created (\(last))")
  }

  /// The guest's address: its DHCP lease if the host records one, else the
  /// one address on this network that answers on port 22 (the build VM is
  /// the network's only peer).
  func findGuest(mac: String, timeout: TimeInterval) async throws -> String {
    let want = mac.lowercased().split(separator: ":").map { p -> String in
      let s = p.drop { $0 == "0" }
      return s.isEmpty ? "0" : String(s)
    }.joined(separator: ":")
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) {
        for block in text.components(separatedBy: "}") {
          var fields: [String: String] = [:]
          for line in block.split(separator: "\n") {
            let kv = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
          }
          if fields["hw_address"]?.split(separator: ",", maxSplits: 1).last.map(String.init)
            == want,
            let ip = fields["ip_address"], ip.hasPrefix(prefix + ".")
          {
            return ip
          }
        }
      }
      for host in 2...20 {
        let ip = "\(prefix).\(host)"
        let r = try? Subprocess.run(
          ["/usr/bin/nc", "-z", "-G", "1", ip, "22"], environment: ["PATH": "/usr/bin:/bin"],
          stdin: nil, timeout: 3)
        if r?.status == 0 { return ip }
      }
      try await Task.sleep(for: .seconds(3))
    }
    throw SandboxError("guest not reachable on \(subnet) within \(Int(timeout))s")
  }
}

/// Guest-authored text bound for host logs, errors and records.
package enum GuestText {
  /// Control characters (including newlines and ESC) replaced.
  package static func printable(_ s: String) -> String {
    String(s.unicodeScalars.map { $0.properties.generalCategory == .control ? "?" : Character($0) })
  }

  /// A version string: letters, digits and dots, at most 32 characters.
  static func version(_ raw: String) throws -> String {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, s.count <= 32,
      s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
    else { throw SandboxError("unexpected version string from the guest") }
    return s
  }
}
