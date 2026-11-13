import Foundation
import IsoCore
import Security

/// Who must have signed a compiled-in editor, and its executable.
package struct EditorBundleIdentity: Sendable, Equatable {
  package let bundleName: String
  package let identifier: String
  package let teamIdentifier: String
  package let executable: String

  var requirement: String {
    "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
  }
}

/// An editor bundle at a fixed path, verified before launch; never from `PATH`.
package struct TrustedEditorApp: Sendable, Equatable {
  package let bundle: String
  package let executable: String
  package let version: String

  package static func candidates(_ identity: EditorBundleIdentity, home: String?) -> [String] {
    ["/Applications/" + identity.bundleName]
      + (home.map { [$0 + "/Applications/" + identity.bundleName] } ?? [])
  }

  /// The first existing candidate; one that fails a check throws rather than
  /// falling through to another copy.
  package static func locate(
    _ identity: EditorBundleIdentity, candidates: [String],
    verifySignature: (String, EditorBundleIdentity) throws -> Void = CodeSignature.verify
  ) throws -> TrustedEditorApp? {
    for candidate in candidates {
      var status = stat()
      guard lstat(candidate, &status) == 0 else { continue }
      guard
        let bundle = realpath(candidate, nil).map({ pointer in
          defer { free(pointer) }
          return String(cString: pointer)
        })
      else { throw HostError.posix("Failed to resolve", candidate) }
      let executable = bundle + "/" + identity.executable
      try checkOwnership(executable, bundle: bundle)
      try verifySignature(bundle, identity)
      guard
        let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
        let version = info["CFBundleShortVersionString"] as? String,
        !version.isEmpty
      else { throw HostError("\(bundle) has no CFBundleShortVersionString") }
      return TrustedEditorApp(bundle: bundle, executable: executable, version: version)
    }
    return nil
  }

  /// The bundle is a directory owned by root or this user and writable by no
  /// one else; the executable, inside it, passes `TrustedExecutable` (which
  /// also covers every ancestor and refuses ACL write grants) and is not a
  /// symlink.
  static func checkOwnership(_ executable: String, bundle: String) throws {
    let uid = getuid()
    var status = stat()
    guard lstat(bundle, &status) == 0 else { throw HostError.posix("Failed to inspect", bundle) }
    guard status.st_mode & S_IFMT == S_IFDIR else {
      throw HostError("\(bundle) is not a regular directory")
    }
    guard status.st_uid == 0 || status.st_uid == uid, status.st_mode & 0o022 == 0 else {
      throw HostError("\(bundle) must be owned by root or you and writable by no one else")
    }
    let trusted: TrustedExecutable
    do {
      trusted = try TrustedExecutable.verify(executable, uid: uid)
    } catch {
      throw HostError("\(error.message), so another user could replace \(bundle)")
    }
    guard trusted.path == executable else {
      throw HostError("\(executable) is a symlink, not a regular file")
    }
  }
}

package enum CodeSignature {
  package static func verify(_ bundle: String, _ identity: EditorBundleIdentity) throws {
    var code: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundle) as CFURL, [], &code)
    guard status == errSecSuccess, let code else {
      throw HostError("Failed to read the code signature of \(bundle) (OSStatus \(status))")
    }
    var requirement: SecRequirement?
    status = SecRequirementCreateWithString(identity.requirement as CFString, [], &requirement)
    guard status == errSecSuccess, let requirement else {
      throw HostError("Invalid signing requirement for \(identity.identifier) (OSStatus \(status))")
    }
    status = SecStaticCodeCheckValidity(
      code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement)
    guard status == errSecSuccess else {
      throw HostError(
        "\(bundle) is not a valid \(identity.identifier) signed by team \(identity.teamIdentifier) (OSStatus \(status))"
      )
    }
  }
}
