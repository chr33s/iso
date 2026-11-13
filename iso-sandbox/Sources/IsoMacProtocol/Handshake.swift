import Foundation

/// The host's decision on a helper `hello`, given what the host has on
/// record. Pure, so every branch is unit-testable.
package enum HandshakeDecision: Equatable, Sendable {
  /// Enrolled on both sides and the MAC verifies.
  case authenticated
  /// The host has not enrolled this clone: send `enroll`.
  /// Also when the guest already holds a key from an interrupted enrollment; re-enrolling trusts no more.
  case enroll
  /// Wrong MAC, malformed hello, or an enrollment claim that disagrees with the host: drop this
  /// connection only; an unauthenticated claim never changes host state.
  case reject(String)
}

package enum Handshake {
  package static func decide(
    hostEnrolled: Bool, hostKey: HelperKey?, hello: HelperMessage, nonce: String
  ) -> HandshakeDecision {
    guard hello.type == .hello, let boot = hello.boot, let guestEnrolled = hello.enrolled else {
      return .reject("malformed hello")
    }
    switch (hostEnrolled, guestEnrolled) {
    case (false, false):
      return .enroll
    case (true, true):
      guard let hostKey, let mac = hello.mac else { return .reject("missing mac") }
      return HelperProtocol.macMatches(
        mac, HelperProtocol.mac(key: hostKey, nonce: nonce, boot: boot))
        ? .authenticated : .reject("bad mac")
    case (true, false):
      return .reject("unauthenticated: guest reports no enrollment for an enrolled sandbox")
    case (false, true):
      return .enroll
    }
  }

  /// Checks the guest's `enrolled` reply: it must prove the new key and carry
  /// an SSH host key.
  package static func verifyEnrolled(
    _ reply: HelperMessage, key: HelperKey, nonce: String, boot: String
  ) -> Result<String, HelperError> {
    guard reply.type == .enrolled else { return .failure(.unexpected(reply.type.rawValue)) }
    guard let pub = reply.sshHostKey, SSHPublicKey.isEd25519(pub) else {
      return .failure(.malformed)
    }
    guard let mac = reply.mac,
      HelperProtocol.macMatches(mac, HelperProtocol.mac(key: key, nonce: nonce, boot: boot))
    else { return .failure(.badMAC) }
    return .success(SSHPublicKey.canonical(pub))
  }
}
