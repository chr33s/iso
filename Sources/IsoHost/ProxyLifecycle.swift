// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

// Host-side lifecycle of the credential proxy (issue #411) and of the
// local-model reverse tunnels. One `iso-proxy` process and one `ssh -R`
// tunnel run per (VM, provider), both tracked by PID files in the instance
// directory. The proxy binds host loopback, runs under `sandbox-exec`, and
// receives its credential on stdin only; the guest gets a synthetic
// capability token and reaches the proxy through its own tunnel.

extension ProxyProvider {
  /// 1000 apart so the per-instance ranges (index 0...252) never overlap.
  var basePort: UInt16 {
    switch self {
    case .anthropic: 8788
    case .openai: 9788
    }
  }

  /// Host-loopback listen port: base + instance index.
  func port(_ instance: Instance) -> UInt16 {
    basePort &+ instance.index.value
  }

  /// Codex forwards the capability token through `SendEnv` on later
  /// sessions, so it is kept on host disk; Claude's rides in the guest
  /// `settings.json` and stays in memory.
  var persistsToken: Bool { self == .openai }

  /// Keychain service name used by `iso proxy setup`.
  public var keychainService: String {
    switch self {
    case .anthropic: "coop-anthropic"
    case .openai: "coop-openai"
    }
  }
}

/// The upstream a VM's proxy uses for one provider.
public struct EffectiveUpstream: Sendable, Equatable {
  public let credential: CredentialReference
  public let auth: ProxyAuthScheme

  public init(credential: CredentialReference, auth: ProxyAuthScheme) {
    self.credential = credential
    self.auth = auth
  }
}

extension ProxyState {
  /// `proxy.mode = "off"` → none; otherwise override → configuration
  /// default → off. A stored literal override is
  /// never used (C-04): it fails closed until replaced.
  public func effective(_ provider: ProxyProvider, config: ProxyConfig, instance: InstanceName)
    throws -> EffectiveUpstream?
  {
    guard config.mode != .off else { return nil }
    if let stored = override(for: provider) {
      switch stored.credential {
      case .reference(let reference):
        return EffectiveUpstream(credential: reference, auth: stored.auth)
      case .literal:
        throw HostError(
          "proxy.json for '\(instance)' holds a literal \(provider.rawValue) credential, which is no longer accepted; run `iso proxy setup --vm \(instance)\(provider == .openai ? " --openai" : "")` to store it in the macOS Keychain, or replace it with a `cmd:` reference"
        )
      }
    }
    return config.upstream(for: provider).map {
      EffectiveUpstream(credential: $0.credential, auth: $0.auth)
    }
  }

  /// A `--env`/`--env-file` provider secret for this instance first, then
  /// the per-VM override and the configuration default (D-003).
  public static func effectiveUpstream(
    _ instance: Instance, _ provider: ProxyProvider, config: ProxyConfig
  ) throws -> EffectiveUpstream? {
    if let routed = try GuestEnvState.tryLoad(instance)?.providerSecrets()[provider] {
      guard config.mode != .off else { throw unavailable(routed) }
      return EffectiveUpstream(
        credential: CredentialReference("vault:\(routed.name)")!, auth: routed.auth)
    }
    return try load(instance).effective(provider, config: config, instance: instance.name)
  }

  /// A provider secret under `proxy.mode = "off"`: unavailable, never
  /// forwarded into the guest instead.
  public static func unavailable(_ routed: GuestEnvState.ProviderSecret) -> HostError {
    HostError(
      "\(routed.variable)={vault:\(routed.name)} is a provider credential for iso-proxy, but proxy.mode is \"off\"; it is not forwarded into the guest. Set proxy.mode to \"auto\" or remove it."
    )
  }

  /// Record a per-VM override. The other provider's member is carried over
  /// as stored (it may be a literal awaiting remediation, which is neither
  /// read into a credential nor printed); unknown members are dropped, as
  /// the Rust round trip did. Owner-only.
  public static func setOverride(
    _ instance: Instance, provider: ProxyProvider, credential: CredentialReference,
    auth: ProxyAuthScheme
  ) throws {
    _ = try load(instance)  // refuse to rewrite a malformed file
    var raw: [String: JSONValue] = [:]
    if let bytes = try StateStore.readControlFile(instance.proxyStatePath),
      case .object(let members) = try ConfigLoader.parse(
        bytes, format: .json, path: instance.proxyStatePath, limits: .configuration)
    {
      raw = members
    }
    raw[provider.rawValue] = .object([
      "credential": .string(credential.command.expose()), "auth": .string(auth.rawValue),
    ])
    var members: [(String, OutputJSON)] = []
    for provider in ProxyProvider.allCases {
      guard case .object(let entry)? = raw[provider.rawValue] else { continue }
      var fields: [(String, OutputJSON)] = []
      if case .string(let credential)? = entry["credential"] {
        fields.append(("credential", .string(credential)))
      }
      if case .string(let auth)? = entry["auth"] { fields.append(("auth", .string(auth))) }
      members.append((provider.rawValue, .object(fields)))
    }
    do {
      try AtomicFile.write(
        Array(OutputJSON.object(members).rendered().dropLast().utf8), to: instance.proxyStatePath,
        mode: .atMost(0o600))
    } catch {
      throw ContextError("Failed to write proxy.json", cause: error)
    }
  }
}

/// A running proxy: the guest-facing URL and the capability token the
/// guest presents. The token is not a provider credential.
public struct ProxyHandle: Sendable {
  public let baseURL: String
  public let capabilityToken: Secret<String>
}

/// Starts and stops per-instance proxies and tunnels.
public struct ProxyLauncher: Sendable {
  /// SSH authentication plus the guest's forwarding acknowledgment.
  static let tunnelReadyTimeout: Duration = .seconds(30)
  /// The proxy must answer HTTP 401 within this window or the start aborts.
  static let proxyReadyGrace: Duration = .seconds(5)

  let environment: [String: String]
  let resolver: CredentialResolver
  let diagnostics: Diagnostics
  /// The running `iso` executable; `iso-proxy` must sit beside it.
  let isoExecutable: String?
  /// Test seam: the confinement wrapper (`/usr/bin/sandbox-exec`).
  let sandboxExec: String
  /// Where tunnel control sockets are created (short, private paths).
  let controlRoot: String

  public init(
    environment: [String: String], resolver: CredentialResolver, diagnostics: Diagnostics,
    isoExecutable: String?
  ) {
    self.init(
      environment: environment, resolver: resolver, diagnostics: diagnostics,
      isoExecutable: isoExecutable, sandboxExec: "/usr/bin/sandbox-exec", controlRoot: "/tmp")
  }

  init(
    environment: [String: String], resolver: CredentialResolver, diagnostics: Diagnostics,
    isoExecutable: String?, sandboxExec: String, controlRoot: String
  ) {
    self.environment = environment
    self.resolver = resolver
    self.diagnostics = diagnostics
    self.isoExecutable = isoExecutable
    self.sandboxExec = sandboxExec
    self.controlRoot = controlRoot
  }

  // MARK: Paths

  static func pidPath(_ instance: Instance, _ name: String) -> String {
    instance.directory + "/proxy-\(name).pid"
  }
  static func forwardPIDPath(_ instance: Instance, _ name: String) -> String {
    instance.directory + "/proxy-\(name)-fwd.pid"
  }
  static func tokenPath(_ instance: Instance, _ name: String) -> String {
    instance.directory + "/proxy-\(name).token"
  }
  static func logPath(_ instance: Instance, _ name: String) -> String {
    instance.directory + "/proxy-\(name).log"
  }
  static func forwardLogPath(_ instance: Instance, _ name: String) -> String {
    instance.directory + "/proxy-\(name)-fwd.log"
  }
  static func modelTunnelName(_ port: UInt16) -> String { "model-\(port)" }
  static func modelSpecPath(_ instance: Instance, _ port: UInt16) -> String {
    instance.directory + "/proxy-\(modelTunnelName(port))-fwd.spec"
  }

  // MARK: Provider proxies

  /// Resolve the credential, start the confined proxy on host loopback, and
  /// expose it to the guest at `127.0.0.1:<port>`. Fails closed: any error
  /// leaves no proxy, tunnel or token behind.
  public func start(
    _ instance: Instance, provider: ProxyProvider, upstream: EffectiveUpstream, target: SSHTarget
  ) throws -> ProxyHandle {
    let credential: Secret<String>
    do {
      credential = try resolver.resolve(upstream.credential)
    } catch {
      throw ContextError(
        "Failed to resolve the \(provider.rawValue) proxy credential — aborting VM start (fail-closed); the guest must never come up without the injected credential",
        cause: error)
    }
    let token = Secret(randomHex(32))
    let port = provider.port(instance)
    let startup = Self.wireConfig(
      listen: "127.0.0.1:\(port)", capabilityToken: token, provider: provider, auth: upstream.auth,
      credential: credential)
    try spawnProxy(instance, name: provider.rawValue, port: port, startup: startup)
    if provider.persistsToken {
      do {
        try AtomicFile.write(
          Array(token.expose().utf8), to: Self.tokenPath(instance, provider.rawValue),
          mode: .atMost(0o600))
      } catch {
        stop(instance, provider: provider)
        throw ContextError(
          "Failed to write proxy token file \(Self.tokenPath(instance, provider.rawValue))",
          cause: error)
      }
    }
    do {
      try spawnReverseForward(
        instance, name: provider.rawValue, target: target, guestPort: port,
        hostAddress: try! IPv4Address("127.0.0.1"), hostPort: port)
    } catch {
      stop(instance, provider: provider)
      throw error
    }
    diagnostics.log(
      .info,
      "Started \(provider.rawValue) credential proxy on 127.0.0.1:\(port) (guest → 127.0.0.1:\(port))"
    )
    return ProxyHandle(baseURL: "http://127.0.0.1:\(port)", capabilityToken: token)
  }

  /// Best-effort teardown of one provider's proxy, tunnel and token file.
  public func stop(_ instance: Instance, provider: ProxyProvider) {
    killPIDFile(Self.pidPath(instance, provider.rawValue), label: "proxy", expect: .proxy)
    killPIDFile(
      Self.forwardPIDPath(instance, provider.rawValue), label: "proxy tunnel", expect: .ssh)
    let token = Self.tokenPath(instance, provider.rawValue)
    if unlink(token) != 0 && errno != ENOENT {
      diagnostics.debug("Failed to remove proxy token file \(token) (non-fatal)")
    }
  }

  /// Every provider proxy, the filtered-egress companion, and every model tunnel.
  public func stopAll(_ instance: Instance) {
    for provider in ProxyProvider.allCases { stop(instance, provider: provider) }
    stopEgress(instance)
    stopModelTunnels(instance)
  }

  /// Start the credential-free CONNECT companion for a filtered boot. A missing
  /// binary fails the boot; nothing falls back to NAT.
  public func startEgress(_ instance: Instance, config: IsoConfig, target: SSHTarget) throws {
    guard config.egress == .filtered else { return }
    let binary = try locateEgressBinary()
    let port = EgressPorts.port(instance)
    let capability = randomHex(32)
    let hosts = config.egressFilter.allowedHosts.map(\.rawValue)
    let startup = OutputJSON.object([
      ("listen", .string("127.0.0.1:\(port)")),
      ("capability", .string(capability)),
      ("allowedHosts", .array(hosts.map(OutputJSON.string))),
    ])
    guard let sidecar = try MachineSidecar.loadIfPresent(instance),
      let ownerPID = sidecar.lastObservedOwnerPID
    else {
      throw HostError("filtered egress requires a recorded sandbox owner for '\(instance.name)'")
    }
    var leasePipe: [Int32] = [-1, -1]
    guard pipe(&leasePipe) == 0 else { throw HostError("Failed to create the egress lease pipe") }
    defer {
      if leasePipe[0] >= 0 { close(leasePipe[0]) }
      if leasePipe[1] >= 0 { close(leasePipe[1]) }
    }
    try spawnLease(
      instance, machineID: sidecar.machineID.rawValue, ownerPID: ownerPID, writeEnd: leasePipe[1])
    do {
      try spawnEgress(
        instance, port: port, binary: binary, startup: Array(startup.compactRendered().utf8),
        controlRead: leasePipe[0])
    } catch {
      stopEgress(instance)
      throw error
    }
    do {
      try AtomicFile.write(
        Array(capability.utf8), to: EgressPorts.capabilityPath(instance), mode: .atMost(0o600))
    } catch {
      stopEgress(instance)
      throw error
    }
    do {
      try spawnReverseForward(
        instance, name: "egress", target: target, guestPort: port,
        hostAddress: try IPv4Address("127.0.0.1"), hostPort: port)
    } catch {
      stopEgress(instance)
      throw error
    }
    diagnostics.log(
      .info,
      "Started filtered egress companion on 127.0.0.1:\(port) (guest loopback, port 443 only)"
    )
  }

  public func stopEgress(_ instance: Instance) {
    killPIDFile(instance.directory + "/egress-lease.pid", label: "egress lease", expect: .lease)
    killPIDFile(Self.pidPath(instance, "egress"), label: "egress", expect: .egress)
    killPIDFile(Self.forwardPIDPath(instance, "egress"), label: "egress tunnel", expect: .ssh)
    let capability = EgressPorts.capabilityPath(instance)
    if unlink(capability) != 0 && errno != ENOENT {
      diagnostics.debug("Failed to remove egress capability \(capability) (non-fatal)")
    }
  }

  func locateEgressBinary() throws -> String {
    guard let isoExecutable else { throw HostError("Failed to locate the iso executable") }
    let directory = (isoExecutable as NSString).deletingLastPathComponent
    let candidate = directory + "/iso-egress"
    var status = stat()
    guard stat(candidate, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw HostError(
        "iso-egress not found next to iso at \(directory). Filtered egress cannot start; build iso-egress and place it beside iso. No NAT fallback is used."
      )
    }
    return candidate
  }

  func spawnLease(_ instance: Instance, machineID: String, ownerPID: Int32, writeEnd: Int32) throws
  {
    guard let isoExecutable else { throw HostError("Failed to locate the iso executable") }
    let logPath = instance.directory + "/egress-lease.log"
    let log = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard log >= 0 else { throw HostError.posix("Failed to create egress lease log", logPath) }
    defer { close(log) }
    let child = try DetachedChild.spawn(
      executable: isoExecutable,
      arguments: ["egress-lease", instance.directory, machineID, String(ownerPID)],
      environment: ["PATH": "/usr/bin:/bin"], stdin: .null, stderr: log, inherit: [(writeEnd, 3)])
    try AtomicFile.write(
      Array(String(child.pid).utf8), to: instance.directory + "/egress-lease.pid",
      mode: .atMost(0o644))
  }

  func spawnEgress(
    _ instance: Instance, port: UInt16, binary: String, startup: [UInt8], controlRead: Int32
  ) throws {
    killPIDFile(Self.pidPath(instance, "egress"), label: "stale egress", expect: .egress)
    try Self.requireFreePort(port)
    let resolved =
      realpath(binary, nil).map { pointer in
        defer { free(pointer) }
        return String(cString: pointer)
      } ?? binary
    let logPath = Self.logPath(instance, "egress")
    let log = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard log >= 0 else { throw HostError.posix("Failed to create egress log", logPath) }
    defer { close(log) }
    var child: DetachedChild
    do {
      child = try DetachedChild.spawn(
        executable: sandboxExec,
        arguments: ["-D", "EGRESS_BIN=\(resolved)", "-p", SeatbeltProfile.egress, resolved],
        environment: [:], stdin: .pipe, stderr: log, inherit: [(controlRead, 3)])
    } catch {
      throw ContextError("Failed to spawn \(binary)", cause: error)
    }
    do {
      try child.writeAndCloseStdin(startup)
      let deadline = ContinuousClock.now + .seconds(5)
      while !Self.accepts(port: port) {
        if let status = child.poll() {
          throw HostError("iso-egress exited before listening (\(status))")
        }
        if ContinuousClock.now >= deadline {
          throw HostError("Timed out waiting for iso-egress to listen on 127.0.0.1:\(port)")
        }
        usleep(50_000)
      }
      try Self.requireListener(child.pid, port: port)
    } catch {
      child.kill()
      throw error
    }
    do {
      try AtomicFile.write(
        Array(String(child.pid).utf8), to: Self.pidPath(instance, "egress"), mode: .atMost(0o644))
    } catch {
      child.kill()
      throw error
    }
  }

  /// The persisted Codex capability token, if a proxy is running.
  public static func capabilityToken(_ instance: Instance, provider: ProxyProvider) -> Secret<
    String
  >? {
    guard let bytes = try? StateStore.readControlFile(tokenPath(instance, provider.rawValue)),
      let text = String(validating: bytes, as: UTF8.self)
    else { return nil }
    let token = text.trimmingUnicodeWhitespace()
    return token.isEmpty ? nil : Secret(token)
  }

  /// The `iso-proxy` stdin startup document (protocol version 1).
  static func wireConfig(
    listen: String, capabilityToken: Secret<String>, provider: ProxyProvider,
    auth: ProxyAuthScheme, credential: Secret<String>
  ) -> Secret<[UInt8]> {
    let scheme = auth.wireName
    let json = OrderedJSON.object(
      .init([
        ("listen", .string(listen)), ("capability_token", .string(capabilityToken.expose())),
        ("version", .uint(1)), ("provider", .string(provider.rawValue)),
        (
          "injection",
          .object(
            .init([("scheme", .string(scheme)), ("credential", .string(credential.expose()))]))
        ),
      ]))
    return Secret(Array(json.compact.utf8))
  }

  func locateProxyBinary() throws -> String {
    guard let isoExecutable else { throw HostError("Failed to locate the iso executable") }
    let directory = (isoExecutable as NSString).deletingLastPathComponent
    let candidate = directory + "/iso-proxy"
    var status = stat()
    guard stat(candidate, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw HostError(
        "Swift proxy iso-proxy not found next to iso at \(directory) — build with scripts/build-release.py or reinstall iso"
      )
    }
    return candidate
  }

  func spawnProxy(_ instance: Instance, name: String, port: UInt16, startup: Secret<[UInt8]>)
    throws
  {
    // A crashed run may have left one bound to the port.
    killPIDFile(Self.pidPath(instance, name), label: "stale proxy", expect: .proxy)
    try Self.requireFreePort(port)
    let binary = try locateProxyBinary()
    let resolved =
      realpath(binary, nil).map { pointer in
        defer { free(pointer) }
        return String(cString: pointer)
      } ?? binary
    let logPath = Self.logPath(instance, name)
    let log = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard log >= 0 else { throw HostError.posix("Failed to create proxy log", logPath) }
    defer { close(log) }
    // sandbox-exec applies the profile, then replaces itself with the proxy
    // (the only exec the profile allows). No caller environment crosses.
    var child: DetachedChild
    do {
      child = try DetachedChild.spawn(
        executable: sandboxExec,
        arguments: ["-D", "PROXY_BIN=\(resolved)", "-p", SeatbeltProfile.proxy, resolved],
        environment: [:], stdin: .pipe, stderr: log)
    } catch {
      throw ContextError("Failed to spawn \(binary)", cause: error)
    }
    do {
      try child.writeAndCloseStdin(startup.expose())
      try awaitProxyReady(&child, port: port, logPath: logPath)
      try Self.requireListener(child.pid, port: port)
    } catch {
      child.kill()
      throw error
    }
    do {
      try AtomicFile.write(
        Array(String(child.pid).utf8), to: Self.pidPath(instance, name), mode: .atMost(0o644))
    } catch {
      // Without a PID file nothing could stop it later.
      child.kill()
      throw ContextError(
        "Failed to write proxy pid file \(Self.pidPath(instance, name))", cause: error)
    }
  }

  /// The proxy port must be free before the proxy starts: the ports are
  /// predictable, and a readiness probe answered by another local listener
  /// would hand the guest's capability token to it. A just-signalled stale
  /// proxy gets a moment to release it.
  static func requireFreePort(_ port: UInt16) throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while Self.accepts(port: port) {
      guard ContinuousClock.now < deadline else {
        throw HostError(
          "127.0.0.1:\(port) is already in use by another process — refusing to start the credential proxy there (fail-closed)"
        )
      }
      usleep(100_000)
    }
  }

  /// After readiness: the listener on `port` is the proxy iso started.
  static func requireListener(_ pid: pid_t, port: UInt16) throws {
    guard
      let output = try? ProcessRunner().capture(
        .init(
          executable: "/usr/sbin/lsof",
          arguments: ["-nP", "-a", "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-t"],
          environment: [:], deadline: .seconds(10), outputLimit: 64 << 10, overflow: .drain))
    else {
      throw HostError(
        "could not confirm which process serves 127.0.0.1:\(port) — refusing to start the VM (fail-closed)"
      )
    }
    let listeners = rustLines(String(decoding: output.stdout, as: UTF8.self)).compactMap {
      pid_t($0.trimmingUnicodeWhitespace())
    }
    guard listeners == [pid] else {
      throw HostError(
        "127.0.0.1:\(port) is served by pid \(listeners.map(String.init).joined(separator: ", ")), not the credential proxy iso started (pid \(pid)) — refusing to start the VM (fail-closed)"
      )
    }
  }

  /// Whether something accepts connections on `127.0.0.1:port`.
  static func accepts(port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  /// Poll until the proxy answers `HTTP/1.1 401` on its listener; fail
  /// closed with its log if it exits first or never serves.
  func awaitProxyReady(_ child: inout DetachedChild, port: UInt16, logPath: String) throws {
    let start = ContinuousClock.now
    while true {
      if let status = child.poll() {
        throw HostError(
          "credential proxy exited before it began serving (\(status)) — its confinement or bind failed; refusing to start the VM (fail-closed).\n\(Self.readLog(logPath))"
        )
      }
      if Self.httpReady(port: port) { return }
      if ContinuousClock.now - start >= Self.proxyReadyGrace {
        throw HostError(
          "credential proxy did not begin serving on 127.0.0.1:\(port) within 5s — refusing to start the VM (fail-closed).\n\(Self.readLog(logPath))"
        )
      }
      usleep(100_000)
    }
  }

  static func readLog(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "" }
    return String(decoding: data.prefix(64 << 10), as: UTF8.self).trimmingUnicodeWhitespace()
  }

  /// A bounded, credential-free probe: the status line must be exactly an
  /// `HTTP/1.1 401` response.
  static func httpReady(port: UInt16, budget: Duration = .milliseconds(200)) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let deadline = ContinuousClock.now + budget
    func wait(_ events: Int16) -> Bool {
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { return false }
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      return Darwin.poll(&descriptor, 1, Int32(clamping: max(remaining.milliseconds, 1))) == 1
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected != 0 {
      guard errno == EINPROGRESS, wait(Int16(POLLOUT)) else { return false }
      var error: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
        return false
      }
    }
    var request = Array(
      "GET /v1/messages HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)[...]
    while !request.isEmpty {
      guard wait(Int16(POLLOUT)) else { return false }
      let sent = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
      guard sent > 0 else { return false }
      request = request.dropFirst(sent)
    }
    var status: [UInt8] = []
    var byte: UInt8 = 0
    while status.count < 128 {
      guard wait(Int16(POLLIN)), recv(fd, &byte, 1, 0) == 1 else { return false }
      status.append(byte)
      if status.suffix(2) == [0x0D, 0x0A] {
        return status.starts(with: Array("HTTP/1.1 401 ".utf8))
      }
    }
    return false
  }

  // MARK: Reverse tunnels

  /// `ssh -N -R 127.0.0.1:<guestPort>:<hostAddress>:<hostPort>` to the
  /// pinned target, detached and PID-tracked. The master authenticates
  /// first; `-O forward` then waits for the guest to acknowledge the bind,
  /// so a clash or refusal fails the start.
  func spawnReverseForward(
    _ instance: Instance, name: String, target: SSHTarget, guestPort: UInt16,
    hostAddress: IPv4Address, hostPort: UInt16
  ) throws {
    killPIDFile(Self.forwardPIDPath(instance, name), label: "stale proxy tunnel", expect: .ssh)
    let client = SSHClient(environment: environment)
    guard let ssh = client.sshExecutable() else {
      throw HostError("Failed to spawn the reverse SSH tunnel for the credential proxy")
    }
    var template = Array((controlRoot + "/iso-proxy-XXXXXX").utf8CString)
    guard let directory = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) })
    else { throw HostError("Failed to create proxy tunnel control directory") }
    let controlDirectory = String(cString: directory)
    defer { try? FileManager.default.removeItem(atPath: controlDirectory) }
    let controlPath = controlDirectory + "/ssh.sock"
    let logPath = Self.forwardLogPath(instance, name)
    let log = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard log >= 0 else { throw HostError.posix("Failed to create proxy tunnel log", logPath) }
    defer { close(log) }

    var master: DetachedChild
    do {
      master = try DetachedChild.spawn(
        executable: ssh,
        arguments: target.sshOptions + [
          "-N", "-T", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o",
          "ForkAfterAuthentication=no", "-S", controlPath, target.address,
        ], environment: SSHClient.transportEnvironment(environment), stdin: .null,
        stderr: log)
    } catch {
      throw ContextError(
        "Failed to spawn the reverse SSH tunnel for the credential proxy", cause: error)
    }
    do {
      let deadline = ContinuousClock.now + Self.tunnelReadyTimeout
      while true {
        try Shutdown.check()
        if let status = master.poll() {
          throw HostError(
            "reverse SSH tunnel exited before its control socket became ready (\(status))")
        }
        if FileManager.default.fileExists(atPath: controlPath) { break }
        if ContinuousClock.now >= deadline {
          throw HostError("Timed out waiting for proxy tunnel authentication")
        }
        usleep(100_000)
      }
      var request: DetachedChild
      do {
        request = try DetachedChild.spawn(
          executable: ssh,
          arguments: target.sshOptions + [
            "-S", controlPath, "-O", "forward", "-R",
            "127.0.0.1:\(guestPort):\(hostAddress):\(hostPort)", target.address,
          ], environment: SSHClient.transportEnvironment(environment), stdin: .null,
          stderr: log)
      } catch {
        throw ContextError("Failed to request the credential proxy's reverse forward", cause: error)
      }
      try Self.awaitForwardingAck(&request, deadline: deadline)
      do {
        try AtomicFile.write(
          Array(String(master.pid).utf8), to: Self.forwardPIDPath(instance, name),
          mode: .atMost(0o644))
      } catch {
        throw ContextError(
          "Failed to write proxy tunnel pid file \(Self.forwardPIDPath(instance, name))",
          cause: error)
      }
    } catch {
      master.kill()
      throw ContextError(
        "Failed to establish the credential proxy's reverse SSH tunnel.\n\(Self.readLog(logPath))",
        cause: error)
    }
  }

  /// The setup client is reaped on every path, including a guest that never
  /// answers.
  static func awaitForwardingAck(_ request: inout DetachedChild, deadline: ContinuousClock.Instant)
    throws
  {
    do {
      while true {
        try Shutdown.check()
        if let status = request.poll() {
          guard status.succeeded else {
            throw HostError("Proxy reverse forwarding request failed (\(status))")
          }
          return
        }
        if ContinuousClock.now >= deadline {
          throw HostError("Timed out waiting for proxy reverse forwarding acknowledgment")
        }
        usleep(100_000)
      }
    } catch {
      request.kill()
      throw error
    }
  }

  /// What a recorded PID must still be before it is signalled.
  enum RecordedProcess {
    /// `iso-proxy` (sandbox-exec replaced itself with it).
    case proxy
    /// `iso-egress` (sandbox-exec replaced itself with it).
    case egress
    /// A tunnel `ssh`.
    case ssh
    /// `iso egress-lease`, the renewal process.
    case lease

    func matches(_ command: String) -> Bool {
      let words = command.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
      switch self {
      case .proxy: return words.contains { ($0 as NSString).lastPathComponent == "iso-proxy" }
      case .egress: return words.contains { ($0 as NSString).lastPathComponent == "iso-egress" }
      case .ssh: return words.first.map { ($0 as NSString).lastPathComponent == "ssh" } ?? false
      case .lease: return words.contains("egress-lease")
      }
    }
  }

  /// The command line of `pid`, nil when no such process.
  static func commandLine(_ pid: Int32) -> String? {
    guard
      let output = try? ProcessRunner().capture(
        .init(
          executable: "/bin/ps", arguments: ["-ww", "-o", "command=", "-p", String(pid)],
          environment: [:], deadline: .seconds(10), outputLimit: 64 << 10, overflow: .drain)),
      output.termination.succeeded
    else { return nil }
    return String(decoding: output.stdout, as: UTF8.self).trimmingUnicodeWhitespace()
  }

  /// SIGTERM the process a PID file names — only while it is still the
  /// process recorded (a PID can be reused after a reboot or crash) — then
  /// remove the file.
  func killPIDFile(_ path: String, label: String, expect: RecordedProcess) {
    guard let bytes = try? StateStore.readControlFile(path) else { return }
    let text = String(decoding: bytes, as: UTF8.self).trimmingUnicodeWhitespace()
    if let pid = Int32(text), pid > 0 {
      if let command = Self.commandLine(pid), expect.matches(command) {
        Darwin.kill(pid, SIGTERM)
        diagnostics.debug("Sent SIGTERM to \(label) (pid \(pid))")
      } else {
        diagnostics.debug("Not signalling pid \(pid) from \(path): no longer the \(label)")
      }
    } else {
      diagnostics.debug("Ignoring malformed pid file \(path)")
    }
    if unlink(path) != 0 && errno != ENOENT {
      diagnostics.debug("Failed to remove pid file \(path) (non-fatal)")
    }
  }

  // MARK: Local-model tunnels

  /// Reconcile the instance's model tunnels with `wanted`: a live tunnel
  /// with the same target and destination is kept; others are closed;
  /// missing ones are opened. A forward the guest does not acknowledge
  /// fails the bootstrap before any URL that depends on it is published.
  public func syncModelTunnels(
    _ instance: Instance, target: SSHTarget, wanted: [UInt16: ReverseTunnel]
  ) throws {
    var kept = Set<UInt16>()
    for port in Self.recordedModelTunnels(instance) {
      if let tunnel = wanted[port],
        modelTunnelIsCurrent(instance, port: port, spec: Self.modelTunnelSpec(target, tunnel))
      {
        kept.insert(port)
      } else {
        stopModelTunnel(instance, port: port)
      }
    }
    for port in wanted.keys.sorted() where !kept.contains(port) {
      let tunnel = wanted[port]!
      do {
        try spawnReverseForward(
          instance, name: Self.modelTunnelName(port), target: target, guestPort: port,
          hostAddress: tunnel.hostAddress, hostPort: tunnel.hostPort)
      } catch {
        throw ContextError(
          "Failed to tunnel local model \(tunnel.hostAddress):\(tunnel.hostPort) into the guest",
          cause: error)
      }
      try AtomicFile.write(
        Array(Self.modelTunnelSpec(target, tunnel).utf8), to: Self.modelSpecPath(instance, port),
        mode: .atMost(0o600))
    }
  }

  /// Which guest a tunnel serves and where it forwards on the host.
  static func modelTunnelSpec(_ target: SSHTarget, _ tunnel: ReverseTunnel) -> String {
    "\(target.address):\(target.port) \(target.alias) \(tunnel.guestPort):\(tunnel.hostAddress):\(tunnel.hostPort)"
  }

  /// A recorded PID counts only while `ps` still names it `ssh`, so a
  /// reused PID is never trusted or signalled.
  func modelTunnelPID(_ instance: Instance, port: UInt16) -> Int32? {
    guard
      let bytes = try? StateStore.readControlFile(
        Self.forwardPIDPath(instance, Self.modelTunnelName(port))),
      let pid = Int32(String(decoding: bytes, as: UTF8.self).trimmingUnicodeWhitespace()), pid > 0,
      let output = try? ProcessRunner().capture(
        .init(
          executable: "/bin/ps", arguments: ["-o", "comm=", "-p", String(pid)], environment: [:],
          deadline: .seconds(10), outputLimit: 64 << 10, overflow: .drain)),
      output.termination.succeeded,
      Self.isSSHCommand(String(decoding: output.stdout, as: UTF8.self))
    else { return nil }
    return pid
  }

  static func isSSHCommand(_ comm: String) -> Bool {
    (comm.trimmingUnicodeWhitespace() as NSString).lastPathComponent == "ssh"
  }

  func modelTunnelIsCurrent(_ instance: Instance, port: UInt16, spec: String) -> Bool {
    let recorded = (try? StateStore.readControlFile(Self.modelSpecPath(instance, port))).flatMap {
      $0.map { String(decoding: $0, as: UTF8.self) }
    }
    return modelTunnelPID(instance, port: port) != nil && recorded == spec
  }

  func stopModelTunnel(_ instance: Instance, port: UInt16) {
    if let pid = modelTunnelPID(instance, port: port) { Darwin.kill(pid, SIGTERM) }
    unlink(Self.forwardPIDPath(instance, Self.modelTunnelName(port)))
    unlink(Self.modelSpecPath(instance, port))
  }

  static func recordedModelTunnels(_ instance: Instance) -> [UInt16] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: instance.directory)
    else { return [] }
    return names.compactMap { name in
      guard name.hasPrefix("proxy-model-"), name.hasSuffix("-fwd.pid") else { return nil }
      return UInt16(name.dropFirst("proxy-model-".count).dropLast("-fwd.pid".count))
    }
  }

  /// Every recorded model tunnel. Each boot starts by closing those of the
  /// previous boot, which may outlive it and pass as current.
  public func stopModelTunnels(_ instance: Instance) {
    for port in Self.recordedModelTunnels(instance) { stopModelTunnel(instance, port: port) }
  }
}

/// A child that outlives the call: its own process group (so Ctrl-C to
/// iso does not reach it), stdout to `/dev/null`, stderr to a log. It is
/// reaped by `poll` once it exits, or killed and reaped by `kill`.
struct DetachedChild {
  enum Input { case null, pipe }

  let pid: pid_t
  private var stdinWriter: Int32
  private var reaped = false

  static func spawn(
    executable: String, arguments: [String], environment: [String: String], stdin: Input,
    stderr: Int32, inherit: [(Int32, Int32)] = []
  ) throws -> DetachedChild {
    var pipeFDs: [Int32] = [-1, -1]
    if stdin == .pipe {
      guard pipe(&pipeFDs) == 0 else {
        throw HostError.posix("Failed to create pipe for", executable)
      }
      _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
      _ = fcntl(pipeFDs[1], F_SETNOSIGPIPE, 1)
    }
    defer { if pipeFDs[0] >= 0 { close(pipeFDs[0]) } }
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if stdin == .pipe {
      posix_spawn_file_actions_adddup2(&actions, pipeFDs[0], 0)
    } else {
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, stderr, 2)
    for (source, target) in inherit {
      posix_spawn_file_actions_adddup2(&actions, source, target)
    }
    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setpgroup(&attributes, 0)
    var signals = sigset_t()
    sigemptyset(&signals)
    posix_spawnattr_setsigmask(&attributes, &signals)
    sigfillset(&signals)
    posix_spawnattr_setsigdefault(&attributes, &signals)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETSIGDEF))
    let argv = [executable] + arguments
    let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let result = withCStrings(argv) { argvPointer in
      withCStrings(env) { envPointer in
        posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
      }
    }
    guard result == 0 else {
      if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
      throw HostError("Failed to spawn \(executable): \(String(cString: strerror(result)))")
    }
    return DetachedChild(pid: pid, stdinWriter: pipeFDs[1])
  }

  private init(pid: pid_t, stdinWriter: Int32) {
    self.pid = pid
    self.stdinWriter = stdinWriter
  }

  /// Write everything, then EOF. A child that closed its stdin yields EPIPE.
  mutating func writeAndCloseStdin(_ bytes: [UInt8]) throws {
    guard stdinWriter >= 0 else { throw HostError("proxy child stdin unexpectedly missing") }
    defer {
      close(stdinWriter)
      stdinWriter = -1
    }
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes { write(stdinWriter, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw ContextError(
          "Failed to write proxy startup config to stdin",
          cause: HostError(String(cString: strerror(errno))))
      }
      offset += count
    }
  }

  /// The exit status once the child has exited (and is reaped), else nil.
  mutating func poll() -> ProcessRunner.Termination? {
    guard !reaped else { return nil }
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    guard result == pid else { return nil }
    reaped = true
    return ChildProcess.decode(status)
  }

  mutating func kill() {
    if stdinWriter >= 0 {
      close(stdinWriter)
      stdinWriter = -1
    }
    guard !reaped else { return }
    Darwin.kill(-pid, SIGKILL)
    Darwin.kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    reaped = true
  }
}

/// `iso proxy setup` provisioning (C-04): the credential goes only to the
/// macOS Keychain, under the existing service/account names, and the
/// configuration or per-VM override records the `cmd:` reference that
/// reads it back. There is no fallback store.
public enum ProxyProvisioning {
  public static let securityTool = "/usr/bin/security"

  /// OpenAI keys are always Bearer; Anthropic uses `x-api-key` for an API
  /// key and Bearer for a `setup-token`.
  public static func auth(for provider: ProxyProvider, apiKey: Bool) -> ProxyAuthScheme {
    provider == .anthropic && apiKey ? .apiKey : .bearer
  }

  /// A per-VM override appends `-<vm>` so it never collides with the
  /// default entry.
  public static func service(for provider: ProxyProvider, vm: InstanceName?) -> String {
    vm.map { "\(provider.keychainService)-\($0)" } ?? provider.keychainService
  }

  /// The Rust `shell_quote`: bare when every character is safe.
  static func shellQuote(_ text: String) -> String {
    let safe =
      !text.isEmpty
      && text.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || "-_./:=".unicodeScalars.contains($0)
      }
    return safe ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  public static func reference(service: String, account: String) -> CredentialReference {
    CredentialReference(
      "cmd:security find-generic-password -s \(shellQuote(service)) -a \(shellQuote(account)) -w")!
  }

  /// `security add-generic-password -U`. The CLI takes the secret only on
  /// argv (a documented exception); nothing else sees it and it is never
  /// logged. Fails when the Keychain is unavailable or refuses the write.
  public static func storeInKeychain(
    service: String, account: String, secret: Secret<String>, environment: [String: String],
    runner: ProcessRunner = ProcessRunner(), tool: String = securityTool
  ) throws -> CredentialReference {
    guard access(tool, X_OK) == 0 else {
      throw HostError(
        "macOS Keychain is unavailable (\(tool) not found); `iso proxy setup` stores credentials only in the Keychain. Alternatively write a `cmd:` reference to a command that prints the credential into proxy.<provider>.credential"
      )
    }
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        .init(
          executable: tool,
          arguments: [
            "add-generic-password", "-U", "-s", service, "-a", account, "-w", secret.expose(),
          ], environment: environment, deadline: .seconds(120), outputLimit: 64 << 10,
          overflow: .drain))
    } catch {
      throw ContextError(
        "Failed to write secret to macOS Keychain", cause: HostError("security could not run"))
    }
    guard output.termination.succeeded else {
      throw ContextError(
        "Failed to write secret to macOS Keychain",
        cause: HostError("security add-generic-password exited with \(output.termination)"))
    }
    return reference(service: service, account: account)
  }
}
