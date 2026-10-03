import CryptoKit
import Darwin
import Foundation

/// Versioned challenge on the existing listener. The signing key never goes
/// to the guest; a guest-visible CONNECT capability cannot authenticate replies.
package struct EgressReadiness: Sendable {
  package static let requestLine = "GET /__iso/egress-ready HTTP/1.1"
  private let key: Curve25519.Signing.PrivateKey
  private let bootID: String
  private let policyHash: String

  package init(privateKeyHex: String, bootID: String, allow: EgressAllowlist) throws {
    guard let bytes = Self.hex(privateKeyHex, count: 32), Self.hex(bootID, count: 16) != nil,
      let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    else {
      throw PolicyError("invalid readiness identity")
    }
    key = signingKey
    self.bootID = bootID
    let canonical =
      "mode=filtered\nhosts=\(allow.hosts.sorted().joined(separator: ","))\nport=443\n"
    policyHash =
      "sha256:"
      + SHA256.hash(data: Data(canonical.utf8)).map {
        String(format: "%02x", $0)
      }.joined()
  }

  static func hex(_ text: String, count: Int) -> [UInt8]? {
    let bytes = Array(text.utf8)
    guard bytes.count == count * 2 else { return nil }
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: byte - 48
      case 97...102: byte - 87
      default: nil
      }
    }
    var decoded: [UInt8] = []
    for index in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
      decoded.append(high * 16 + low)
    }
    return decoded
  }

  /// Exact framing keeps the private route separate from CONNECT and never
  /// turns a malformed probe into an upstream operation.
  static func challenge(_ head: [UInt8], capability: String) -> String? {
    guard head.count <= 1024, let text = String(bytes: head, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    guard lines.count == 5, lines[0] == requestLine, lines[3].isEmpty, lines[4].isEmpty,
      lines[1].hasPrefix("Proxy-Authorization: "), lines[2].hasPrefix("X-Iso-Nonce: "),
      let password = ConnectParser.basicPassword(String(lines[1].dropFirst(21))),
      ConnectParser.constantTimeEqual(password, capability)
    else { return nil }
    let nonce = String(lines[2].dropFirst(13))
    return hex(nonce, count: 16) != nil ? nonce : nil
  }

  package func response(_ head: [UInt8], capability: String, alive: () -> Bool) -> [UInt8] {
    guard let nonce = Self.challenge(head, capability: capability), alive() else {
      return ConnectGate.responseBytes(.authRequired)
    }
    let message = "iso-egress-readiness-v2\n\(nonce)\n\(bootID)\n\(policyHash)\n"
    guard let signature = try? key.signature(for: Data(message.utf8)) else {
      return ConnectGate.responseBytes(.unsupported)
    }
    let reply = Reply(
      version: 2, nonce: nonce, bootID: bootID, policyHash: policyHash,
      signature: signature.base64EncodedString())
    guard let body = try? JSONEncoder().encode(reply) else {
      return ConnectGate.responseBytes(.unsupported)
    }
    let headers = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return Array(headers.utf8) + body
  }

  private struct Reply: Encodable {
    let version: Int
    let nonce: String
    let bootID: String
    let policyHash: String
    let signature: String
  }

  /// A bounded, nonblocking write; a paused or disconnected probe cannot
  /// occupy a worker indefinitely or terminate the companion with SIGPIPE.
  package static func write(_ bytes: [UInt8], to fd: Int32, alive: () -> Bool) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    var noSignal: Int32 = 1
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    guard
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { return false }
    let deadline = ContinuousClock.now + .seconds(1)
    var offset = 0
    while offset < bytes.count && ContinuousClock.now < deadline && alive() {
      let written = bytes.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return send(fd, base.advanced(by: offset), bytes.count - offset, 0)
      }
      if written > 0 {
        offset += written
        continue
      }
      if written == 0 { return false }
      guard errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK else { return false }
      var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      if poll(&event, 1, 20) < 0 && errno != EINTR { return false }
    }
    return offset == bytes.count
  }
}
