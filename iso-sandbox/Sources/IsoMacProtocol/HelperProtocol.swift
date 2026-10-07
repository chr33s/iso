import CryptoKit
import Foundation

/// The vsock protocol between a macOS guest's `iso-macos-helper` and its
/// host owner: one JSON object per line, bounded, version 1. The host speaks
/// first on every connection (`challenge`); see
/// docs/design/macos-guest-computer-use.md.
package enum HelperProtocol {
  package static let version = 1
  package static let port: UInt32 = 7801
  /// Largest line either side reads; longer input fails the connection.
  package static let maxLine = 64 * 1024
  /// Unauthenticated connections the host keeps at once, and how long each
  /// may take to authenticate.
  package static let maxPending = 4
  package static let helloDeadline: TimeInterval = 10

  package static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  package static func randomHex(bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    arc4random_buf(&b, b.count)
    return hex(b)
  }

  /// HMAC-SHA256 over `nonce|boot` with the per-clone helper key.
  package static func mac(key: HelperKey, nonce: String, boot: String) -> String {
    hex(HMAC<SHA256>.authenticationCode(for: Data("\(nonce)|\(boot)".utf8), using: key.symmetric))
  }

  /// Constant-time comparison of two hex MACs.
  package static func macMatches(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
  }
}

/// A 32-byte key, carried as 64 lowercase hex characters.
package struct HelperKey: Equatable, Sendable {
  package let hex: String
  package init?(hex raw: String) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count == 64,
      s.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) })
    else { return nil }
    hex = s
  }
  package static func random() -> HelperKey {
    HelperKey(hex: HelperProtocol.randomHex(bytes: 32))!
  }
  package var symmetric: SymmetricKey {
    var bytes: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
      let j = hex.index(i, offsetBy: 2)
      bytes.append(UInt8(hex[i..<j], radix: 16)!)
      i = j
    }
    return SymmetricKey(data: bytes)
  }
}

/// Static IPv4 configuration the host assigns; the helper applies it every boot.
package struct HelperNetwork: Codable, Equatable, Sendable {
  package var address: String
  package var prefix: Int
  package var gateway: String
  package var dns: [String]

  package init(address: String, prefix: Int, gateway: String, dns: [String]) {
    self.address = address
    self.prefix = prefix
    self.gateway = gateway
    self.dns = dns
  }

  /// Dotted-quad check for values that reach `networksetup` argv.
  package var isWellFormed: Bool {
    func quad(_ s: String) -> Bool {
      let parts = s.split(separator: ".", omittingEmptySubsequences: false)
      return parts.count == 4
        && parts.allSatisfy { p in
          !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber)
            && (Int(p) ?? 256) <= 255
        }
    }
    return quad(address) && quad(gateway) && dns.count <= 4 && dns.allSatisfy(quad)
      && (8...30).contains(prefix)
  }

  /// The dotted netmask for `prefix`.
  package var netmask: String {
    let m: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
    return [24, 16, 8, 0].map { String((m >> UInt32($0)) & 0xff) }.joined(separator: ".")
  }
}

/// Every message on the channel. Unknown fields are ignored; unknown types
/// and a different `v` fail the connection.
package struct HelperMessage: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable {
    // host → guest
    case challenge, enroll, network, status, shutdown
    // guest → host
    case hello, enrolled
    case statusReply = "status_reply"
    case ack, error
  }

  package var v: Int = HelperProtocol.version
  package var type: Kind
  package var nonce: String? = nil
  package var boot: String? = nil
  package var build: String? = nil
  package var productVersion: String? = nil
  package var helperVersion: String? = nil
  package var enrolled: Bool? = nil
  package var mac: String? = nil
  package var key: String? = nil
  package var authorizedKey: String? = nil
  package var network: HelperNetwork? = nil
  package var sshHostKey: String? = nil
  package var message: String? = nil
  /// A host request's number, echoed in its reply, so a reply that arrives
  /// after its request timed out cannot answer the next one. Absent from
  /// helpers that predate it.
  package var id: Int? = nil

  enum CodingKeys: String, CodingKey {
    case v, type, nonce, boot, build, enrolled, mac, key, network, message, id
    case productVersion = "product_version"
    case helperVersion = "helper_version"
    case authorizedKey = "authorized_key"
    case sshHostKey = "ssh_host_key"
  }

  package init(type: Kind) { self.type = type }

  package func encodedLine() -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    var d = (try? e.encode(self)) ?? Data()
    d.append(0x0A)
    return d
  }

  /// Parses one line (without its newline). Refuses oversized input, a
  /// different protocol version, and values outside their bounds.
  package static func parse(_ line: some Collection<UInt8>) -> Result<HelperMessage, HelperError> {
    guard line.count <= HelperProtocol.maxLine else { return .failure(.tooLong) }
    guard let m = try? JSONDecoder().decode(HelperMessage.self, from: Data(line)) else {
      return .failure(.malformed)
    }
    guard m.v == HelperProtocol.version else { return .failure(.version(m.v)) }
    if let b = m.boot, !(1...64).contains(b.count) { return .failure(.malformed) }
    for s in [m.build, m.productVersion, m.helperVersion].compactMap({ $0 }) where s.count > 64 {
      return .failure(.malformed)
    }
    if let k = m.sshHostKey, !SSHPublicKey.isEd25519(k) { return .failure(.malformed) }
    if let k = m.authorizedKey, !SSHPublicKey.isEd25519(k) { return .failure(.malformed) }
    if let n = m.network, !n.isWellFormed { return .failure(.malformed) }
    if let k = m.key, HelperKey(hex: k) == nil { return .failure(.malformed) }
    if let i = m.id, !(0...Int(Int32.max)).contains(i) { return .failure(.malformed) }
    return .success(m)
  }
}

package enum HelperError: Error, Equatable, CustomStringConvertible {
  case tooLong, malformed
  case version(Int)
  case unexpected(String)
  case badMAC, deadline

  package var description: String {
    switch self {
    case .tooLong: "line exceeds \(HelperProtocol.maxLine) bytes"
    case .malformed: "malformed message"
    case .version(let v): "unsupported protocol version \(v)"
    case .unexpected(let t): "unexpected message \(t)"
    case .badMAC: "bad mac"
    case .deadline: "hello deadline exceeded"
    }
  }
}

/// `ssh-ed25519 <base64>` with an optional comment, as a single line.
package enum SSHPublicKey {
  package static func isEd25519(_ s: String) -> Bool {
    let parts = s.split(separator: " ", omittingEmptySubsequences: true)
    guard (2...3).contains(parts.count), parts[0] == "ssh-ed25519", s.count <= 512,
      !s.contains("\n"), !s.contains("\r"),
      let blob = Data(base64Encoded: String(parts[1])), blob.count == 51
    else { return false }
    return true
  }

  /// The key without its comment, for pin comparison.
  package static func canonical(_ s: String) -> String {
    s.split(separator: " ").prefix(2).joined(separator: " ")
  }
}

/// Reads newline-terminated lines from a file descriptor with a hard cap.
package struct LineReader {
  let fd: Int32
  var buffer: [UInt8] = []
  package init(fd: Int32) { self.fd = fd }

  package enum Next: Equatable {
    case line([UInt8])
    case closed
    case tooLong
    case deadline
  }

  /// The next line. With `deadline`, a wall-clock bound across reads: a
  /// per-read timeout alone would let a peer trickle bytes indefinitely.
  package mutating func next(deadline: Date? = nil) -> Next {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      if let nl = buffer.firstIndex(of: 0x0A) {
        let line = Array(buffer[..<nl])
        buffer.removeSubrange(...nl)
        return .line(line)
      }
      if buffer.count > HelperProtocol.maxLine { return .tooLong }
      if let deadline, Date() >= deadline { return .deadline }
      let n = read(fd, &chunk, chunk.count)
      if n < 0, errno == EINTR { continue }
      if n <= 0 { return .closed }
      buffer.append(contentsOf: chunk[0..<n])
    }
  }
}
