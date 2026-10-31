import Foundation
import IsoCore
import Security
import Synchronization
import Testing

@testable import IsoHost

@Test func companionSignersRequireIsosTeamOrAValidSignature() throws {
  let requirement = try #require(CompanionSigner.team("ABCDE12345").requirement)
  #expect(
    requirement
      == #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "ABCDE12345""#
  )
  // Security.framework accepts it as written.
  var compiled: SecRequirement?
  #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
  #expect(CompanionSigner.adHoc.requirement == nil)
  // The test runner's own signer is readable, whichever it is.
  _ = try CompanionSigner.current()
}

/// What a release build of iso checks before it starts `iso-proxy` or
/// `iso-egress`.
@Test func companionsMustBeValidlySignedOwnedAndUnwritable() throws {
  let root = try scratchDirectory("companion")
  defer { try? FileManager.default.removeItem(atPath: root) }
  // A copy of a signed system binary keeps its valid signature.
  let signed = root + "/iso-proxy"
  try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: signed)
  chmod(signed, 0o755)
  try CompanionSignature.verify(signed, signer: .adHoc)
  // A symlink to it is checked as the file it names.
  try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: signed)
  try CompanionSignature.verify(root + "/link", signer: .adHoc)
  // Another team's requirement is not met.
  #expect(throws: HostError.self) {
    try CompanionSignature.verify(signed, signer: .team("ABCDE12345"))
  }
  // Unsigned code is refused.
  let unsigned = root + "/iso-egress"
  try writeFile(unsigned, "#!/bin/sh\nexit 0\n", mode: 0o755)
  #expect(throws: HostError.self) { try CompanionSignature.verify(unsigned, signer: .adHoc) }
  // So is a validly signed file that others could replace.
  chmod(signed, 0o775)
  #expect(throws: HostError.self) { try CompanionSignature.verify(signed, signer: .adHoc) }
  chmod(signed, 0o755)
  chmod(root, 0o777)
  #expect(throws: HostError.self) { try CompanionSignature.verify(signed, signer: .adHoc) }
  // A group-writable ancestor is accepted; only other-writable ones are refused.
  chmod(root, 0o775)
  try CompanionSignature.verify(signed, signer: .adHoc)
  chmod(root, 0o755)
  #expect(throws: HostError.self) {
    try CompanionSignature.verify(root + "/missing", signer: .adHoc)
  }
}

/// Both companions go through the launcher's check once located; release
/// builds check signatures there, and a refusal stops the start.
@Test func locatedCompanionsAreVerifiedBeforeUse() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let iso = try guest.installProxyStubs()
  try FileManager.default.copyItem(
    atPath: guest.root + "/app/iso-proxy", toPath: guest.root + "/app/iso-egress")
  let checked = Mutex<[String]>([])
  let launcher = ProxyLauncher(
    environment: [:], resolver: CredentialResolver(environment: [:]),
    diagnostics: guest.sink.diagnostics, isoExecutable: iso,
    sandboxExec: guest.root + "/bin/sandbox-exec", controlRoot: guest.root,
    verifyCompanion: { path in
      checked.withLock { $0.append(path) }
      try CompanionSignature.verify(path, signer: .adHoc)
    })
  // The stand-ins are unsigned scripts.
  #expect(throws: HostError.self) { try launcher.locateProxyBinary() }
  #expect(throws: HostError.self) { try launcher.locateEgressBinary() }
  #expect(
    checked.withLock { $0 } == [guest.root + "/app/iso-proxy", guest.root + "/app/iso-egress"])
}
