import Darwin
import Foundation
import IsoConfiguration
import IsoCore

/// The `run_as` check (§20.1).
public enum RunAsCheck: Sendable, Equatable {
  case notConfigured
  case verified(account: String)
  case failed(account: String, reason: String)

  public var account: String? {
    switch self {
    case .notConfigured: nil
    case .verified(let account), .failed(let account, _): account
    }
  }

  /// nil when no `run_as` is configured.
  public var passed: Bool? {
    switch self {
    case .notConfigured: nil
    case .verified: true
    case .failed: false
    }
  }
}

/// What iso can verify about a backend from an unprivileged host process
/// (secure-local-inference spec §20.1, §20.3, §20.4, §20.8).
public struct BackendVerification: Sendable, Equatable {
  public var reachable = false
  /// Non-loopback host addresses that also answer on the backend port.
  public var exposedAddresses: [String] = []
  public var runAs = RunAsCheck.notConfigured
  public var managed = false
  public var jobPID: Int32?
  /// An unauthenticated request was refused (401). nil when untested.
  public var authenticated: Bool?
  /// Kernel-reported sandbox state of the managed job; nil when unknown.
  public var confined: Bool?

  /// Run-as, authentication and confinement all verified.
  public var isolationVerified: Bool {
    runAs.passed == true && authenticated == true && confined == true
  }

  public var json: OutputJSON {
    func optional(_ value: Bool?) -> OutputJSON { value.map(OutputJSON.bool) ?? .null }
    return .object([
      ("reachable", .bool(reachable)),
      ("exposed_addresses", .array(exposedAddresses.map(OutputJSON.string))),
      ("run_as", .optional(runAs.account)), ("backend_run_as_verified", optional(runAs.passed)),
      ("backend_managed", .bool(managed)),
      ("job_pid", jobPID.map { .int(Int64($0)) } ?? .null),
      ("backend_authenticated", optional(authenticated)),
      ("backend_confined", optional(confined)),
      ("backend_isolation_verified", .bool(isolationVerified)),
    ])
  }
}

public enum BackendChecks {
  /// Observe a backend without failing.
  public static func verify(name: String, backend: InferenceBackendConfig) -> BackendVerification {
    var result = BackendVerification()
    result.reachable = InferenceController.backendAccepts(port: backend.port)
    result.exposedAddresses = InferenceController.exposedAddresses(port: backend.port)
    result.managed = backend.managed != nil
    // Configuration guarantees a managed backend's name is a valid
    // `ManagedBackendName`.
    let label =
      result.managed
      ? (try? ManagedBackendName(name)).map { ManagedBackendLayout(name: $0).label } : nil
    if let label {
      result.jobPID = launchdJobPID(label)
      result.confined = result.jobPID.flatMap(isSandboxed)
    }
    if let account = backend.runAs {
      do {
        try verifyRunAs(
          account, port: backend.port, managedJob: label.map { ($0, result.jobPID) })
        result.runAs = .verified(account: account)
      } catch {
        result.runAs = .failed(account: account, reason: "\(error)")
      }
    }
    if result.reachable, backend.requiresToken {
      result.authenticated = BackendProbe.status(port: backend.port, token: nil) == 401
    }
    return result
  }

  /// The preflight (§10, §20.1): fails with a stable code before any VM work.
  public static func enforce(name: String, backend: InferenceBackendConfig) throws {
    let result = verify(name: name, backend: backend)
    try InferenceController.requireSafeBinding(
      port: backend.port, reachable: result.reachable, exposedAddresses: result.exposedAddresses)
    if case .failed(let account, let reason) = result.runAs {
      throw HostError(
        "INFERENCE_BACKEND_UNSAFE_OWNER: backend '\(name)' must run as \(account): \(reason)")
    }
    guard let managed = backend.managed else { return }
    guard result.authenticated == true else {
      throw HostError(
        "INFERENCE_BACKEND_UNSAFE_OWNER: managed backend '\(name)' answers without its token; run `iso inference provision \(name)` again"
      )
    }
    if managed.confinement == .seatbelt, result.confined == false {
      throw HostError(
        "INFERENCE_BACKEND_UNSAFE_OWNER: managed backend '\(name)' is configured for Seatbelt but its process is not sandboxed; run `iso inference provision \(name)` again"
      )
    }
  }

  /// `managedJob` is the launchd label and the pid it reported, if any.
  static func verifyRunAs(_ account: String, port: UInt16, managedJob: (String, Int32?)?) throws {
    guard let entry = getpwnam(account) else {
      throw HostError("the account \(account) does not exist")
    }
    let uid = entry.pointee.pw_uid
    guard uid != getuid() else {
      throw HostError("\(account) is the invoking user; the backend must run as another account")
    }
    // `lsof` run unprivileged lists only this user's processes: any listener
    // it finds on the port is ours, so the backend is not isolated from us.
    if let own = ownListeners(port: port), !own.isEmpty {
      throw HostError(
        "127.0.0.1:\(port) is served by this user's process (pid \(own.map(String.init).joined(separator: ", ")))"
      )
    }
    if let (label, pid) = managedJob {
      guard let pid else { throw HostError("the launchd job \(label) is not running") }
      guard HostProcess.uid(pid) == uid else {
        throw HostError("the launchd job \(label) (pid \(pid)) does not run as \(account)")
      }
    }
  }

  /// PIDs of this user's processes listening on the port, on any address.
  static func ownListeners(port: UInt16) -> [Int32]? {
    ProxyLauncher.listenerPIDs(address: nil, port: port)
  }

  /// `launchctl print system/<label>` works unprivileged and reports the pid
  /// of a running job.
  static func launchdJobPID(_ label: String) -> Int32? {
    guard
      let output = try? ProcessRunner().capture(
        .init(
          executable: "/bin/launchctl", arguments: ["print", "system/\(label)"], environment: [:],
          deadline: .seconds(10), outputLimit: 1 << 20, overflow: .drain)),
      output.termination.succeeded
    else { return nil }
    for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
      let trimmed = String(line).trimmingUnicodeWhitespace()
      if trimmed.hasPrefix("pid = "), let pid = Int32(trimmed.dropFirst(6)) { return pid }
    }
    return nil
  }

  /// The kernel's answer for another process: sandboxed (true), not (false),
  /// unknown (nil). `sandbox_check` is looked up at run time.
  static func isSandboxed(_ pid: Int32) -> Bool? {
    typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
    guard let handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW),
      let symbol = dlsym(handle, "sandbox_check")
    else { return nil }
    let result = unsafeBitCast(symbol, to: Check.self)(pid, nil, 0)
    switch result {
    case 1: return true
    case 0: return false
    default: return nil
    }
  }

  /// Own-user TCP listeners on wildcard or non-loopback addresses: guests
  /// can reach these whatever `egress` says (§20.7). Other accounts'
  /// listeners are invisible without privilege.
  public static func guestReachableListeners() -> [(command: String, pid: Int32, address: String)] {
    guard
      let output = try? ProcessRunner().capture(
        .init(
          executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"],
          environment: [:], deadline: .seconds(20), outputLimit: 4 << 20, overflow: .drain))
    else { return [] }
    return parseListeners(String(decoding: output.stdout, as: UTF8.self))
  }

  /// `lsof -F pcn` records: `p<pid>`, `c<command>`, `n<address>`.
  static func parseListeners(_ text: String) -> [(command: String, pid: Int32, address: String)] {
    var out: [(String, Int32, String)] = []
    var pid: Int32 = 0
    var command = ""
    for line in text.split(separator: "\n") {
      guard let tag = line.first else { continue }
      let value = String(line.dropFirst())
      switch tag {
      case "p": pid = Int32(value) ?? 0
      case "c": command = value
      case "n":
        let host = value.lastIndex(of: ":").map { String(value[..<$0]) } ?? value
        let loopback = host == "127.0.0.1" || host == "[::1]" || host.hasPrefix("127.")
        if !loopback, !out.contains(where: { $0.1 == pid && $0.2 == value }) {
          out.append((command, pid, value))
        }
      default: break
      }
    }
    return out
  }
}
