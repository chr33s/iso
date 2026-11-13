import Foundation
import IsoCore
import Security

/// Who must have signed a companion (`iso-proxy`, `iso-egress`) before a release
/// build hands it a credential or capability; it must also pass `TrustedExecutable.verify`.
/// Debug builds do not check (freshly built, unsigned companions).
enum CompanionSigner: Equatable, Sendable {
  /// iso carries this team: the companion must carry a Developer ID
  /// signature of the same team.
  case team(String)
  /// iso is signed ad hoc: the companion must be validly signed (ad hoc
  /// included).
  case adHoc

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

  /// The requirement a companion must satisfy; nil means any valid signature. For
  /// a team, Apple's Developer ID designated requirement: the intermediate
  /// (`6.2.6`) and leaf (`6.1.13`) markers exclude the team's Apple Development
  /// and Distribution certificates.
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
  static func verifyForRelease(_ path: String) throws -> TrustedExecutable {
    #if ISO_RELEASE_BUILD
      return try verify(path, signer: try CompanionSigner.current())
    #else
      return .unverified(path)
    #endif
  }

  /// The companion to start: `requested` resolved, owned and unwritable
  /// (`TrustedExecutable`) and validly signed.
  static func verify(_ requested: String, signer: CompanionSigner) throws -> TrustedExecutable {
    let trusted: TrustedExecutable
    do {
      trusted = try TrustedExecutable.verify(requested)
    } catch {
      throw HostError("Refusing to start \(requested): \(error.message)")
    }
    let path = trusted.path
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
    return trusted
  }
}
