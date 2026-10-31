import Foundation
import IsoCore
import Security

/// Who must have signed a companion (`iso-proxy`, `iso-egress`) before a
/// release build of iso hands it a credential or a capability. In both cases
/// the companion must also pass `CompanionSignature.checkOwnership`. Debug
/// builds do not check: they run freshly built, unsigned companions.
enum CompanionSigner: Equatable, Sendable {
  /// iso carries this team: the companion must carry a Developer ID
  /// signature of the same team.
  case team(String)
  /// iso is signed ad hoc: the companion must be validly signed (ad hoc
  /// included).
  case adHoc

  /// The running iso's own signer.
  static func current() throws -> CompanionSigner {
    var code: SecCode?
    var status = SecCodeCopySelf([], &code)
    guard status == errSecSuccess, let code else {
      throw HostError("Failed to read iso's own code signature (OSStatus \(status))")
    }
    var staticCode: SecStaticCode?
    status = SecCodeCopyStaticCode(code, [], &staticCode)
    guard status == errSecSuccess, let staticCode else {
      throw HostError("Failed to read iso's own code signature (OSStatus \(status))")
    }
    var information: CFDictionary?
    status = SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    guard status == errSecSuccess, let information = information as? [String: Any] else {
      throw HostError("Failed to read iso's own signing information (OSStatus \(status))")
    }
    if let team = information[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
      return .team(team)
    }
    return .adHoc
  }

  /// The requirement a companion must satisfy; nil means any valid
  /// signature. For a team it is Apple's Developer ID designated requirement:
  /// the Developer ID intermediate (`6.2.6`) and leaf (`6.1.13`) markers rule
  /// out the same team's Apple Development and Distribution certificates.
  var requirement: String? {
    switch self {
    case .team(let team):
      "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"\(team)\""
    case .adHoc: nil
    }
  }
}

enum CompanionSignature {
  /// Release builds verify a companion before spawning it; debug builds keep
  /// the regular-file check alone.
  static func verifyForRelease(_ path: String) throws {
    #if ISO_RELEASE_BUILD
      try verify(path, signer: try CompanionSigner.current())
    #endif
  }

  /// Strict validation of the file `path` resolves to against `signer`,
  /// after the ownership check.
  static func verify(_ requested: String, signer: CompanionSigner) throws {
    guard let path = canonicalPath(requested) else {
      throw HostError.posix("Failed to resolve", requested)
    }
    try checkOwnership(path)
    var code: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
    guard status == errSecSuccess, let code else {
      throw HostError("Failed to read the code signature of \(path) (OSStatus \(status))")
    }
    var requirement: SecRequirement?
    if let text = signer.requirement {
      status = SecRequirementCreateWithString(text as CFString, [], &requirement)
      guard status == errSecSuccess, requirement != nil else {
        throw HostError("Invalid companion signing requirement (OSStatus \(status))")
      }
    }
    status = SecStaticCodeCheckValidity(
      code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement)
    guard status == errSecSuccess else {
      let expected =
        switch signer {
        case .team(let team): "signed by team \(team), like iso"
        case .adHoc: "validly signed"
        }
      throw HostError(
        "Refusing to start \(path): it is not \(expected) (OSStatus \(status)). Reinstall iso and its companions from one release."
      )
    }
  }

  /// Run for every signer. The companion must be an executable regular file
  /// (not a symlink) owned by root or this user, with no group or other write
  /// bit. Each ancestor directory up to `/` must be owned by root or this user
  /// and must not be other-writable unless it is sticky; group-writable
  /// ancestors (such as a `root:admin` 0775 directory) are accepted.
  static func checkOwnership(_ path: String, uid: uid_t = getuid()) throws {
    var status = stat()
    guard lstat(path, &status) == 0 else { throw HostError.posix("Failed to inspect", path) }
    guard status.st_mode & S_IFMT == S_IFREG, status.st_mode & 0o111 != 0 else {
      throw HostError("Refusing to start \(path): it is not an executable regular file")
    }
    guard status.st_uid == 0 || status.st_uid == uid, status.st_mode & 0o022 == 0 else {
      throw HostError(
        "Refusing to start \(path): it must be owned by root or you and writable by no one else")
    }
    var ancestor = (path as NSString).deletingLastPathComponent
    while true {
      guard lstat(ancestor, &status) == 0 else {
        throw HostError.posix("Failed to inspect", ancestor)
      }
      let otherWritable = status.st_mode & 0o002 != 0 && status.st_mode & S_ISVTX == 0
      guard status.st_uid == 0 || status.st_uid == uid, !otherWritable else {
        throw HostError("Refusing to start \(path): \(ancestor) lets another user replace it")
      }
      if ancestor == "/" || ancestor.isEmpty { return }
      ancestor = (ancestor as NSString).deletingLastPathComponent
    }
  }
}
