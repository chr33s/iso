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
  var compiled: SecRequirement?
  #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
  #expect(CompanionSigner.adHoc.requirement == nil)
  _ = try CompanionSigner.current()
}

@Test func companionsMustBeValidlySignedOwnedAndUnwritable() throws {
  let root = try scratchDirectory("companion")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let signed = root + "/iso-proxy"
  try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: signed)
  chmod(signed, 0o755)
  let verified = try CompanionSignature.verify(signed, signer: .adHoc)
  #expect(verified.path == BinaryResolver.canonicalPath(signed))
  try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: signed)
  // A symlink is resolved: what was checked is what starts.
  #expect(try CompanionSignature.verify(root + "/link", signer: .adHoc) == verified)
  // Another team's requirement is not met.
  #expect(throws: HostError.self) {
    try CompanionSignature.verify(signed, signer: .team("ABCDE12345"))
  }
  let unsigned = root + "/iso-egress"
  try writeFile(unsigned, "#!/bin/sh\nexit 0\n", mode: 0o755)
  #expect(throws: HostError.self) { try CompanionSignature.verify(unsigned, signer: .adHoc) }
  // So is a validly signed file that others could replace.
  chmod(signed, 0o775)
  #expect(throws: HostError.self) { try CompanionSignature.verify(signed, signer: .adHoc) }
  chmod(signed, 0o755)
  chmod(root, 0o777)
  #expect(throws: HostError.self) { try CompanionSignature.verify(signed, signer: .adHoc) }
  // A group-writable ancestor is refused unless its group is root-equivalent:
  // every local user is in `staff`.
  #expect(chown(root, getuid(), 20) == 0)
  chmod(root, 0o775)
  #expect(throws: HostError.self) { try CompanionSignature.verify(signed, signer: .adHoc) }
  chmod(root, 0o755)
  try CompanionSignature.verify(signed, signer: .adHoc)
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
      return try CompanionSignature.verify(path, signer: .adHoc)
    })
  #expect(throws: HostError.self) { try launcher.locateProxyBinary() }
  #expect(throws: HostError.self) { try launcher.locateEgressBinary() }
  #expect(
    checked.withLock { $0 } == [guest.root + "/app/iso-proxy", guest.root + "/app/iso-egress"])
}

/// An extended ACL that grants write is as dangerous as a write mode bit, on
/// the companion or on any directory above it.
@Test func companionsUnderAnACLWriteGrantAreRefused() throws {
  let root = try scratchDirectory("companion-acl")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let signed = root + "/iso-proxy"
  try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: signed)
  chmod(signed, 0o755)
  _ = try CompanionSignature.verify(signed, signer: .adHoc)
  try setACL(root, "everyone allow add_file,delete_child")
  #expect(throws: HostError.self) { try CompanionSignature.verify(signed, signer: .adHoc) }
  try setACL(root, nil)
  try setACL(signed, "everyone allow write")
  #expect(throws: HostError.self) { try CompanionSignature.verify(signed, signer: .adHoc) }
  try setACL(signed, nil)
  // A deny entry grants nothing.
  try setACL(root, "everyone deny delete")
  _ = try CompanionSignature.verify(signed, signer: .adHoc)
}

/// The launcher starts the path verification returned, not the candidate.
@Test func launchersStartTheVerifiedPath() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let iso = try guest.installProxyStubs()
  try FileManager.default.copyItem(
    atPath: guest.root + "/app/iso-proxy", toPath: guest.root + "/app/iso-egress")
  let launcher = ProxyLauncher(
    environment: [:], resolver: CredentialResolver(environment: [:]),
    diagnostics: guest.sink.diagnostics, isoExecutable: iso,
    sandboxExec: guest.root + "/bin/sandbox-exec", controlRoot: guest.root,
    verifyCompanion: { _ in .unverified("/verified/target") })
  #expect(try launcher.locateProxyBinary() == "/verified/target")
  #expect(try launcher.locateEgressBinary() == "/verified/target")
}

/// `chmod -N` then, when given, `chmod +a ENTRY` on `path`.
private func setACL(_ path: String, _ entry: String?) throws {
  for arguments in [["-N", path]] + (entry.map { [["+a", $0, path]] } ?? []) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}
