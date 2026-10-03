import CryptoKit
import Foundation
import IsoCore

/// The maintainer keys that may sign a release's `SHA256SUMS`, compiled in so
/// that no runtime lookup (not even `github.com/<user>.keys`) can change them.
/// Rotation ships as a release signed by a key already listed here whose
/// binary lists the next key; a key is dropped only in a later release.
package enum ReleaseSigners {
  /// Namespace passed to `ssh-keygen -Y sign -n`; a signature made for any
  /// other purpose with the same key does not verify here.
  package static let namespace = "release-sums@chr33s"

  /// `ssh-ed25519 <base64>` lines, kept in sync with `.github/release-signers`
  /// and the `ALLOWED_SIGNERS` block in `install.sh`.
  package static let keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGpguyE19BveEWHxNaowpmslcC3WE4BKZlXl4dgSmOmx"
  ]

  static var trusted: [SignerKey] { keys.map { try! SignerKey(parsing: $0) } }
}

/// Release archives withdrawn after publication. Neither a Sigstore bundle nor
/// an `SSHSIG` can be revoked once a client holds it, so a bad release is
/// withdrawn by listing its archive digest here in the next release; with
/// anti-rollback, an updated binary then never installs it again.
package enum ReleaseRevocations {
  package static let digests: Set<SHA256Hex> = []
}

/// An ed25519 public key in OpenSSH wire form.
struct SignerKey: Sendable, Equatable {
  /// The 51-byte `string "ssh-ed25519" || string key` blob.
  let blob: [UInt8]

  static let prefix: [UInt8] = [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]

  init(parsing line: String) throws(ReleaseSignatureError) {
    let fields = line.split(separator: " ")
    guard fields.count >= 2, fields[0] == "ssh-ed25519",
      let blob = Data(base64Encoded: String(fields[1])).map(Array.init)
    else { throw .malformed("signer key is not an ssh-ed25519 line") }
    try self.init(blob: blob)
  }

  init(blob: [UInt8]) throws(ReleaseSignatureError) {
    guard blob.count == 51, blob.starts(with: Self.prefix) else {
      throw .malformed("signer key is not an ed25519 public key")
    }
    self.blob = blob
  }

  var raw: [UInt8] { Array(blob[19...]) }

  /// OpenSSH `SHA256:<base64 without padding>`, as `ssh-keygen -lf` prints.
  var fingerprint: String {
    "SHA256:"
      + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }
}

package enum ReleaseSignatureError: Error, Equatable, Sendable, CustomStringConvertible {
  case malformed(String)
  case wrongNamespace(String)
  case untrustedKey(String)
  case badSignature

  package var description: String {
    switch self {
    case .malformed(let reason): "SHA256SUMS signature is malformed: \(reason)"
    case .wrongNamespace(let found):
      "SHA256SUMS signature is for namespace \(debugQuoted(sanitizeForDisplay(found))), not \(ReleaseSigners.namespace)"
    case .untrustedKey(let fingerprint):
      "SHA256SUMS is signed by \(fingerprint), which is not a trusted release signer"
    case .badSignature: "SHA256SUMS signature does not match its contents"
    }
  }
}

/// OpenSSH `SSHSIG` (PROTOCOL.sshsig) verification for ed25519 keys: the
/// format `ssh-keygen -Y sign` writes.
enum SSHSignature {
  static let magic = Array("SSHSIG".utf8)

  static func verify(
    armored: String, message: [UInt8], namespace: String = ReleaseSigners.namespace,
    trusted: [SignerKey] = ReleaseSigners.trusted
  ) throws(ReleaseSignatureError) {
    var reader = WireReader(try dearmor(armored))
    guard reader.take(magic.count) == magic else { throw .malformed("missing SSHSIG magic") }
    guard reader.uint32() == 1 else { throw .malformed("unsupported SSHSIG version") }
    guard let keyBlob = reader.string(), let signedNamespace = reader.string(),
      let reserved = reader.string(), let hashName = reader.string(),
      let signatureBlob = reader.string(), reader.atEnd
    else { throw .malformed("truncated or trailing data") }

    guard signedNamespace == Array(namespace.utf8) else {
      throw .wrongNamespace(String(decoding: signedNamespace, as: UTF8.self))
    }
    let key = try SignerKey(blob: keyBlob)
    guard trusted.contains(key) else { throw .untrustedKey(key.fingerprint) }

    let digest: [UInt8]
    switch String(decoding: hashName, as: UTF8.self) {
    case "sha512": digest = Array(SHA512.hash(data: message))
    case "sha256": digest = Array(SHA256.hash(data: message))
    default: throw .malformed("unsupported hash algorithm")
    }

    var inner = WireReader(signatureBlob)
    guard inner.string() == Array("ssh-ed25519".utf8), let signature = inner.string(),
      signature.count == 64, inner.atEnd
    else { throw .malformed("signature is not ssh-ed25519") }

    var signed = magic
    for field in [Array(namespace.utf8), reserved, hashName, digest] {
      signed += WireReader.encode(field)
    }
    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key.raw),
      publicKey.isValidSignature(signature, for: signed)
    else { throw .badSignature }
  }

  static func dearmor(_ text: String) throws(ReleaseSignatureError) -> [UInt8] {
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let begin = lines.firstIndex(of: "-----BEGIN SSH SIGNATURE-----"),
      let end = lines.firstIndex(of: "-----END SSH SIGNATURE-----"), begin < end,
      let bytes = Data(base64Encoded: lines[(begin + 1)..<end].joined())
    else { throw .malformed("not an armored SSH signature") }
    return Array(bytes)
  }
}

/// SSH wire-format reader: big-endian `uint32` and length-prefixed strings.
struct WireReader {
  private let bytes: [UInt8]
  private var offset = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  var atEnd: Bool { offset == bytes.count }

  mutating func take(_ count: Int) -> [UInt8]? {
    guard count >= 0, bytes.count - offset >= count else { return nil }
    defer { offset += count }
    return Array(bytes[offset..<(offset + count)])
  }

  mutating func uint32() -> UInt32? {
    take(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
  }

  mutating func string() -> [UInt8]? {
    guard let length = uint32(), let count = Int(exactly: length) else { return nil }
    return take(count)
  }

  static func encode(_ field: [UInt8]) -> [UInt8] {
    let count = UInt32(field.count)
    return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: count >> $0) } + field
  }
}
