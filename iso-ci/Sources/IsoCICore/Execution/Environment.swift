import Foundation

/// A profile with every reference resolved and its digests computed, as
/// admitted for one allocation.
package struct ResolvedProfile: Sendable, Equatable {
  package let name: Name
  package let profile: RunnerProfile
  package let image: ImageDescriptor
  package let network: NetworkPolicyDescriptor
  package let compatibility: CompatibilityDescriptor
  package let limits: LimitsDescriptor

  package init(name: Name, configuration: CIConfiguration) throws(CIError) {
    guard let profile = configuration.profiles[name],
      let image = configuration.images[profile.image],
      let network = configuration.networkPolicies[profile.networkPolicy],
      let compatibility = configuration.compatibility[profile.compatibility],
      let limits = configuration.limits[profile.limits]
    else { throw CIError.config("profile \(name) is incomplete") }
    self.name = name
    self.profile = profile
    self.image = image
    self.network = network
    self.compatibility = compatibility
    self.limits = limits
  }

  package var digest: Digest {
    Digest(
      hashing: JSONValue.object([
        "profile": .string(descriptorDigest(profile).rawValue),
        "image": .string(image.digestOfDescriptor.rawValue),
        "network": .string(network.digestOfDescriptor.rawValue),
        "compatibility": .string(compatibility.digestOfDescriptor.rawValue),
        "limits": .string(limits.digestOfDescriptor.rawValue),
      ]).canonical)
  }
}

/// The result of a successful admission check: the evidence references that
/// are stored with the allocation (spec section 2).
package struct Admission: Sendable, Equatable {
  package let host: Name
  package let hostID: HostID
  package let ownerID: OwnerID
  package let epoch: DaemonEpoch
  package let expectedNetworkPolicy: Digest
  package let qualificationDigest: Digest
  package let qualificationTuple: [String: String]
  package let qualificationExpiresAt: EpochSeconds?
  package let retentionModes: Set<RetentionMode>
}

/// A bounded guest command. Arguments are rendered with POSIX single
/// quoting; `stdin` carries secret-bearing material so it never reaches any
/// argv on the host or in logs.
package struct GuestCommand: Sendable, Equatable {
  package var argv: [String]
  package var stdin: [UInt8]
  package var timeoutSeconds: UInt64
  package var outputLimit: Int
  /// Whether stdout may be recorded in diagnostics (false for anything that
  /// could echo secret material).
  package var recordOutput: Bool

  package init(
    _ argv: [String], stdin: [UInt8] = [], timeoutSeconds: UInt64 = 120,
    outputLimit: Int = 64 << 10,
    recordOutput: Bool = true
  ) {
    self.argv = argv
    self.stdin = stdin
    self.timeoutSeconds = timeoutSeconds
    self.outputLimit = outputLimit
    self.recordOutput = recordOutput
  }

  /// One shell word per argument.
  package var rendered: String { argv.map(shellQuote).joined(separator: " ") }
}

package struct GuestCommandResult: Sendable, Equatable {
  package let exitStatus: Int32
  package let stdout: [UInt8]
  package let stderr: [UInt8]
  package let timedOut: Bool

  package init(exitStatus: Int32, stdout: [UInt8], stderr: [UInt8], timedOut: Bool) {
    self.exitStatus = exitStatus
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
  }

  package var succeeded: Bool { exitStatus == 0 && !timedOut }
  package var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

/// A reverse forward from guest loopback to a controller-side Unix socket,
/// carried inside the allocation's VM-bound SSH session. This is how the
/// single scoped preflight endpoint reaches the guest; no host TCP listener
/// exists and no generic controller port is granted.
package struct ServiceForward: Sendable, Equatable {
  package let guestPort: UInt16
  package let hostSocket: String

  package init(guestPort: UInt16, hostSocket: String) {
    self.guestPort = guestPort
    self.hostSocket = hostSocket
  }
}

/// How the controller drives environments. The concrete implementation is
/// `AllocationDriver` over the iso host client; tests use fakes. Every
/// mutation persists its intent before sending and is safe to call again
/// with the same allocation (same durable identities).
package protocol EnvironmentProvider: Sendable {
  /// Verifies the host's current NET-HANDOFF-1 capability, qualification
  /// evidence, grant-free run policy and profile compatibility. Fails
  /// closed; never falls back to vmnet, a NIC or developer credentials.
  func admit(host: Name, profile: ResolvedProfile) throws(CIError) -> Admission

  /// Creates the clean VM for an allocation already persisted with its host
  /// run and operation identities. Returns once the run is running and its
  /// live brokered proof matches the admitted policy, or throws. A lost
  /// reply leaves the allocation uncertain, never duplicated.
  func provision(_ allocation: AllocationID, profile: ResolvedProfile, admission: Admission)
    throws(CIError)

  /// Refreshes host observations into the allocation record.
  func observe(_ allocation: AllocationID) throws(CIError)

  /// Runs one bounded command in the guest over the VM-bound SSH session.
  func execute(_ allocation: AllocationID, _ command: GuestCommand) throws(CIError)
    -> GuestCommandResult

  /// Keeps a controller-held session (and optional service forwards) open
  /// for the allocation until `closeSession`. Losing it lets the host stop
  /// the VM after its grace period.
  func holdSession(_ allocation: AllocationID, forwards: [ServiceForward]) throws(CIError)
  func closeSession(_ allocation: AllocationID)

  /// Host-owned finite retention (`run.retain`).
  func retain(_ allocation: AllocationID, mode: RetentionMode, seconds: UInt64) throws(CIError)

  /// Completes the run: stage permitted results and stop. Execution and
  /// export outcomes are recorded independently.
  func complete(_ allocation: AllocationID, exitStatus: Int32?) throws(CIError)

  /// Destroys the VM and verifies cleanup; unverifiable cleanup is recorded
  /// as debt, never as success.
  func release(_ allocation: AllocationID) throws(CIError)
}

/// POSIX single-quote one shell word.
package func shellQuote(_ word: String) -> String {
  if !word.isEmpty,
    word.unicodeScalars.allSatisfy({
      isSafeNameScalar($0) || $0 == "/" || $0 == "=" || $0 == ":" || $0 == "," || $0 == "+"
        || $0 == "@"
    })
  {
    return word
  }
  return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
