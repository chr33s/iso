// Test-only verifier for the confined companion's Ed25519 response. Compiled
// by test-swift-egress-lease.py; no private keys or production startup bypass.
import CryptoKit
import Darwin
import Foundation

struct Fixture: Decodable {
  let publicKey: String
  let message: String
  let signature: String
}

do {
  let bytes = FileHandle.standardInput.readDataToEndOfFile()
  guard bytes.count <= 4096 else { exit(1) }
  let fixture = try JSONDecoder().decode(Fixture.self, from: bytes)
  guard let publicBytes = Data(base64Encoded: fixture.publicKey), publicBytes.count == 32,
    let signature = Data(base64Encoded: fixture.signature), signature.count == 64
  else { exit(1) }
  let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
  exit(key.isValidSignature(signature, for: Data(fixture.message.utf8)) ? 0 : 1)
} catch {
  exit(1)
}
