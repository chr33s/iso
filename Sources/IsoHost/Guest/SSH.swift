// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// SSH connection to a guest whose host key was pinned at enrollment,
/// looked up under a stable alias rather than the (reassignable) address.
package struct SSHTarget: Sendable, Equatable {
  package let host: String
  package let port: UInt16
  package let user: GuestUser
  package let keyPath: String
  package let knownHosts: String
  package let alias: String
  var handoffCheck: (@Sendable () throws -> Void)? = nil

  /// Connection identity excludes the process-local validator. Boot/policy and
  /// signer identity are compared separately by WorkloadHandoff.
  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.host == rhs.host && lhs.port == rhs.port && lhs.user == rhs.user
      && lhs.keyPath == rhs.keyPath && lhs.knownHosts == rhs.knownHosts && lhs.alias == rhs.alias
  }

  func validating(_ check: @escaping @Sendable () throws -> Void) -> Self {
    var target = self
    target.handoffCheck = check
    return target
  }

  func requireHandoff() throws {
    do { try handoffCheck?() } catch { throw GuestHandoffFailure(cause: error) }
  }

  /// Build the pinned target for `machine` at `ip`. Refuses a data path that
  /// ssh could not carry safely and an instance with no enrolled key.
  package static func pinned(
    config: IsoConfig, instance: Instance, machine: MachineName, ip: IPv4Address, user: GuestUser
  ) throws -> SSHTarget {
    let knownHosts = instance.knownHostsPath
    // The path is passed as a (possibly quoted) option value and written
    // into ~/.ssh/config; a quote or control character could change parsing.
    if knownHosts.unicodeScalars.contains(where: {
      $0 == "\"" || $0 == "'" || $0.properties.generalCategory == .control
    }) {
      throw HostError(
        "data directory path \(knownHosts) contains a quote or control character; SSH options cannot carry it safely"
      )
    }
    guard FileManager.default.fileExists(atPath: knownHosts) else {
      throw RuntimeError.hostKeyChanged(
        "instance '\(instance.name)' has no pinned host key at \(knownHosts); recreate the instance"
      )
    }
    return SSHTarget(
      host: ip.description, port: 22, user: user, keyPath: config.sshKeyPath.path,
      knownHosts: knownHosts,
      alias: "\(machine).iso")
  }

  /// OpenSSH splits some option values on whitespace; quoting keeps a path
  /// with a space whole in `-o`, rsync `-e` and `~/.ssh/config` alike.
  package static func quoteValue(_ value: String) -> String {
    value.unicodeScalars.contains(where: { $0.properties.isWhitespace }) ? "\"\(value)\"" : value
  }

  /// `-o` values for the pinned host-key policy, in order.
  package var hostKeyOptions: [String] {
    [
      "StrictHostKeyChecking=yes", "UserKnownHostsFile=\(Self.quoteValue(knownHosts))",
      "GlobalKnownHostsFile=/dev/null", "HostKeyAlias=\(alias)", "UpdateHostKeys=no",
      "ForwardAgent=no",
      // Authentication uses iso's key file only, never the host agent.
      "IdentityAgent=none",
    ]
  }

  /// Options every transport shares, up to the port flag. `BatchMode`
  /// refuses prompts; `ServerAlive*` bounds a dead established session.
  package var transportOptions: [String] {
    var options = [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30", "-o",
      "ServerAliveCountMax=3",
    ]
    for option in hostKeyOptions { options += ["-o", option] }
    return options + ["-o", "IdentitiesOnly=yes", "-o", "LogLevel=ERROR", "-i", keyPath]
  }

  package var sshOptions: [String] { transportOptions + ["-p", String(port)] }
  package var address: String { "\(user)@\(host)" }
}

package struct SSHClient: Sendable {
  let environment: [String: String]
  let runner: ProcessRunner
  /// ssh bounds connection and liveness itself; this caps the whole call.
  package static let captureDeadline: Duration = .seconds(300)

  /// Guest-bound `ssh`, `scp` and `rsync` inherit only this much of the
  /// host environment. A user's own `SendEnv` (with the guest's
  /// `AcceptEnv *`) would otherwise carry any host variable — a raw
  /// provider key in proxy mode — into the guest; values iso forwards on
  /// purpose are added back by `EnvForward`.
  package static func transportEnvironment(_ environment: [String: String]) -> [String: String] {
    let names: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "TERM", "LANG"]
    return environment.filter { names.contains($0.key) || $0.key.hasPrefix("LC_") }
  }

  package init(environment: [String: String], runner: ProcessRunner = ProcessRunner()) {
    self.environment = Self.transportEnvironment(environment)
    self.runner = runner
  }

  /// `ssh` from the caller's `PATH`, as the Rust host resolved it.
  package func sshExecutable() -> String? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    where !directory.isEmpty {
      let candidate = "\(directory)/ssh"
      if access(candidate, X_OK) == 0 { return candidate }
    }
    return nil
  }

  /// stdout of `command` on the guest; stderr is discarded. Nil when ssh
  /// fails, times out, or prints non-UTF-8 output.
  package func capture(_ target: SSHTarget, _ command: String) -> String? {
    guard let ssh = sshExecutable(), (try? target.requireHandoff()) != nil else { return nil }
    guard
      let output = try? runner.capture(
        .init(
          executable: ssh, arguments: target.sshOptions + [target.address, command],
          environment: environment,
          deadline: Self.captureDeadline)),
      output.termination == .exited(0)
    else { return nil }
    return String(validating: output.stdout, as: UTF8.self)
  }
}

package struct ResourceUsage: Sendable, Equatable {
  package let load1m: Double
  package let memUsedMiB: UInt64
  package let memTotalMiB: UInt64
  package let diskUsedMiB: UInt64
  package let diskTotalMiB: UInt64

  /// Linux reads /proc; a macOS guest prints the same line formats from
  /// sysctl and vm_stat, and the data volume (the system volume is sealed).
  package static let command =
    "if [ -r /proc/loadavg ]; then cat /proc/loadavg; cat /proc/meminfo; df -m /; else "
    + "/usr/sbin/sysctl -n vm.loadavg | /usr/bin/tr -d '{}'; "
    + "echo \"MemTotal: $(( $(/usr/sbin/sysctl -n hw.memsize) / 1024 )) kB\"; "
    + "/usr/bin/vm_stat | /usr/bin/awk '/page size of/ {ps=$8} /^Pages (free|inactive|speculative):/ "
    + "{gsub(/\\./,\"\",$NF); n+=$NF} END {print \"MemAvailable: \" int(n*ps/1024) \" kB\"}'; "
    + "/bin/df -m /System/Volumes/Data; fi"

  var memPercent: UInt64 { memTotalMiB > 0 ? memUsedMiB * 100 / memTotalMiB : 0 }
  var diskPercent: UInt64 { diskTotalMiB > 0 ? diskUsedMiB * 100 / diskTotalMiB : 0 }

  /// Memory is `unavailable` when the guest reported no `MemTotal`.
  package var display: String {
    let memory =
      memTotalMiB > 0 ? "\(memUsedMiB)/\(memTotalMiB) MiB (\(memPercent)%)" : "unavailable"
    return
      "Load: \(formatFixed(load1m, 2))  Mem: \(memory)  Disk: \(diskUsedMiB)/\(diskTotalMiB) MiB (\(diskPercent)%)"
  }

  package var summary: String {
    "load=\(formatFixed(load1m, 2)) mem=\(memPercent)% disk=\(diskPercent)%"
  }

  /// Parses `/proc/loadavg`, `/proc/meminfo` and `df -m /` output, or the
  /// same line formats a macOS guest prints from sysctl, vm_stat and
  /// `df -m /System/Volumes/Data`. Values that are absent stay zero
  /// (baseline behavior, including its quirk of trying later lines for the
  /// load while it is still `0.0`).
  package static func parse(_ output: String) -> ResourceUsage {
    var load = 0.0
    var memTotalKiB: UInt64 = 0
    var memAvailableKiB: UInt64 = 0
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    for line in rustLines(output) {
      let fields = line.split(whereSeparator: {
        $0.unicodeScalars.allSatisfy(\.properties.isWhitespace)
      })
      .map(String.init)
      if load == 0.0, let first = fields.first, let value = parseRustFloat(first) {
        load = value
        continue
      }
      if line.hasPrefix("MemTotal:") {
        if let value = firstUnsigned(line.dropFirst("MemTotal:".count)) { memTotalKiB = value }
      } else if line.hasPrefix("MemAvailable:"),
        let value = firstUnsigned(line.dropFirst("MemAvailable:".count))
      {
        memAvailableKiB = value
      }
      if fields.count >= 4, let total = parseUnsigned(fields[1], as: UInt64.self),
        let used = parseUnsigned(fields[2], as: UInt64.self), fields.last!.hasPrefix("/")
      {
        diskTotal = total
        diskUsed = used
      }
    }
    let used = memTotalKiB >= memAvailableKiB ? memTotalKiB - memAvailableKiB : 0
    return ResourceUsage(
      load1m: load, memUsedMiB: used / 1024, memTotalMiB: memTotalKiB / 1024, diskUsedMiB: diskUsed,
      diskTotalMiB: diskTotal)
  }

  static func firstUnsigned(_ rest: Substring) -> UInt64? {
    rest.split(whereSeparator: \.isWhitespace).first.flatMap {
      parseUnsigned(String($0), as: UInt64.self)
    }
  }

  package static func query(_ ssh: SSHClient, _ target: SSHTarget) -> ResourceUsage? {
    ssh.capture(target, command).map(parse)
  }
}

/// Rust `str::lines`: split on `\n`, strip one trailing `\r`, no final empty line.
/// Works on bytes: Swift treats `\r\n` as one `Character`, so splitting a
/// `String` on `"\n"` would miss CRLF line ends.
func rustLines(_ text: String) -> [String] {
  var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
  if lines.last?.isEmpty == true { lines.removeLast() }
  return lines.map { line in
    String(decoding: line.last == UInt8(ascii: "\r") ? line.dropLast() : line, as: UTF8.self)
  }
}

/// Rust `f64::from_str`: decimal or exponent forms, `inf`/`nan` spellings,
/// optional sign; no surrounding whitespace or hex.
func parseRustFloat(_ text: String) -> Double? {
  let lower = text.lowercased()
  let unsigned = lower.hasPrefix("+") || lower.hasPrefix("-") ? String(lower.dropFirst()) : lower
  if ["inf", "infinity", "nan"].contains(unsigned) {
    return Double(lower.replacingOccurrences(of: "infinity", with: "inf"))
  }
  guard !unsigned.isEmpty,
    unsigned.unicodeScalars.allSatisfy({
      ("0"..."9").contains($0) || $0 == "." || $0 == "e" || $0 == "+" || $0 == "-"
    }),
    !unsigned.hasPrefix("e")
  else { return nil }
  return Double(text)
}

/// Rust `{:.N}` fixed-point formatting (round half to even on the binary value).
package func formatFixed(_ value: Double, _ digits: Int) -> String {
  if value.isNaN { return "NaN" }
  if value.isInfinite { return value < 0 ? "-inf" : "inf" }
  return String(format: "%.\(digits)f", value)
}

extension SSHClient {
  /// Short control-socket path (macOS caps Unix socket paths at 104 bytes),
  /// distinct per host, port and pinned alias.
  package func controlPath(_ target: SSHTarget) -> String {
    let directory = environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
    var hash: UInt32 = 2_166_136_261
    for byte in "\(target.host):\(target.port):\(target.alias)".utf8 {
      hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    let name = "iso-" + String(format: "%08x", hash) + ".sock"
    return directory.hasSuffix("/") ? directory + name : directory + "/" + name
  }

  /// Probe `true` over SSH until it succeeds, backing off 250 ms → 4 s, then
  /// close the multiplexing master so later sessions start clean.
  package func waitUntilReady(_ target: SSHTarget, timeout: Duration, diagnostics: Diagnostics)
    throws
  {
    guard let ssh = sshExecutable() else {
      throw HostError("Failed to run SSH command: ssh not found on PATH")
    }
    diagnostics.log(.info, "Probing SSH readiness (timeout: \(rustDuration(timeout)))")
    let control = controlPath(target)
    let options =
      target.sshOptions + [
        "-o", "ControlMaster=auto", "-o", "ControlPath=\(control)", "-o", "ControlPersist=60",
      ]
    let start = ContinuousClock.now
    var delay: Duration = .milliseconds(250)
    let closeMaster = {
      _ = try? runner.capture(
        .init(
          executable: ssh,
          arguments: ["-O", "exit", "-o", "ControlPath=\(control)", target.address],
          environment: environment, deadline: .seconds(10), outputLimit: 64 << 10,
          overflow: .drain))
    }
    defer { closeMaster() }
    while true {
      let remaining = timeout - (ContinuousClock.now - start)
      try target.requireHandoff()
      let probe = try? runner.capture(
        .init(
          executable: ssh, arguments: options + [target.address, "true"], environment: environment,
          deadline: max(remaining, .seconds(15)), outputLimit: 64 << 10, overflow: .drain))
      if probe?.termination == .exited(0) {
        diagnostics.log(.info, "SSH is ready")
        return
      }
      guard ContinuousClock.now - start < timeout else {
        throw HostError(
          "SSH not ready after \(rustDuration(timeout)) — sshd may not be running in the guest")
      }
      Thread.sleep(
        forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds)
          / 1e18)
      delay = min(delay * 2, .seconds(4))
    }
  }
}
