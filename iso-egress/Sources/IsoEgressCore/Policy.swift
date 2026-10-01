import Darwin
import Foundation

/// Exact ASCII DNS name. A name does not match a parent, child, or suffix.
public struct ExactHostname: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ raw: String) throws {
    guard !raw.isEmpty else { throw PolicyError("hostname must not be empty") }
    for scalar in raw.unicodeScalars {
      guard scalar.isASCII, scalar.value >= 0x21, scalar.value <= 0x7E else {
        throw PolicyError("hostname must be printable ASCII")
      }
    }
    if raw.contains("://") || raw.contains("/") || raw.contains("?") || raw.contains("#")
      || raw.contains("@") || raw.contains("%") || raw.contains("*") || raw.contains(":")
      || raw.contains("[") || raw.contains("]")
    {
      throw PolicyError("hostname must be an exact DNS name")
    }
    var name = raw
    if name.hasSuffix(".") {
      name.removeLast()
      guard !name.isEmpty, !name.hasSuffix(".") else { throw PolicyError("empty label") }
    }
    let lower = name.lowercased()
    guard lower.utf8.count <= 253 else { throw PolicyError("hostname is too long") }
    let labels = lower.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count >= 2 else { throw PolicyError("single-label names are not allowed") }
    var allNumeric = true
    for label in labels {
      guard !label.isEmpty, label.utf8.count <= 63 else { throw PolicyError("invalid label") }
      guard label.first != "-", label.last != "-" else { throw PolicyError("invalid label") }
      for byte in label.utf8 {
        let ok = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        guard ok else { throw PolicyError("invalid hostname character") }
        if byte < 0x30 || byte > 0x39 { allNumeric = false }
      }
    }
    if allNumeric { throw PolicyError("numeric-address aliases are not allowed") }
    rawValue = lower
  }

  public var description: String { rawValue }
}

public struct PolicyError: Error, Equatable, CustomStringConvertible {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
}

public enum Denial: String, Sendable {
  case hostNotAllowed = "HOST_NOT_ALLOWED"
  case portNotAllowed = "PORT_NOT_ALLOWED"
  case addressNotPublic = "ADDRESS_NOT_PUBLIC"
  case authRequired = "AUTH_REQUIRED"
  case unsupported = "UNSUPPORTED"
}

/// IPv4/IPv6 classification. Transition forms are denied rather than unwrapped
/// except IPv4-mapped addresses, which are classified as the embedded IPv4.
public enum AddressPolicy {
  public static func isPublicIPv4(_ octets: [UInt8]) -> Bool {
    guard octets.count == 4 else { return false }
    let a = octets[0]
    let b = octets[1]
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100 && (b & 0xC0) == 64 { return false }
    if a == 169 && b == 254 { return false }
    if a == 172 && (16...31).contains(b) { return false }
    if a == 192 && b == 168 { return false }
    if a == 192 && b == 0 { return false }
    if a == 198 && (b == 18 || b == 19) { return false }
    if a == 192 && b == 0 && octets[2] == 2 { return false }
    if a == 198 && b == 51 && octets[2] == 100 { return false }
    if a == 203 && b == 0 && octets[2] == 113 { return false }
    return true
  }

  public static func isPublic(_ address: String, local: Set<String> = []) -> Bool {
    if local.contains(address.lowercased()) { return false }
    if let v4 = ipv4(address) { return isPublicIPv4(v4) }
    return isPublicIPv6(address)
  }

  static func ipv4(_ text: String) -> [UInt8]? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [UInt8] = []
    for part in parts {
      guard (1...3).contains(part.count), part.allSatisfy(\.isNumber), let value = UInt8(part),
        part.count == 1 || part.first != "0"
      else { return nil }
      octets.append(value)
    }
    return octets
  }

  static func isPublicIPv6(_ text: String) -> Bool {
    let lower = text.lowercased()
    if lower.contains(".") { return false }
    if lower == "::" || lower == "::1" { return false }
    if lower.hasPrefix("fe80:") || lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
      || lower.hasPrefix("fea") || lower.hasPrefix("feb")
    {
      return false
    }
    if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return false }
    if lower.hasPrefix("ff") { return false }
    if lower.hasPrefix("2001:db8") { return false }
    if lower.hasPrefix("64:ff9b") { return false }
    if lower.hasPrefix("::ffff:") { return false }
    return lower.contains(":")
  }
}

public struct ConnectRequest: Sendable, Equatable {
  public let host: ExactHostname
  public let port: Int
  public let password: String
}

public enum ConnectParser {
  public static let username = "iso"

  /// Parse one HTTP/1.1 CONNECT head. Authentication is extracted but not
  /// checked here. Rejects framing that would not be a blind tunnel.
  public static func parse(_ bytes: [UInt8]) throws -> ConnectRequest {
    guard bytes.count <= 16 * 1024 else { throw DenialError(.unsupported) }
    guard let text = String(bytes: bytes, encoding: .utf8) else { throw DenialError(.unsupported) }
    guard !text.contains("\u{0}") else { throw DenialError(.unsupported) }
    let lines = text.components(separatedBy: "\r\n")
    guard lines.count >= 2, lines.last == "" || text.hasSuffix("\r\n\r\n") else {
      throw DenialError(.unsupported)
    }
    let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard request.count == 3, request[0] == "CONNECT", request[2] == "HTTP/1.1" else {
      throw DenialError(.unsupported)
    }
    let target = String(request[1])
    guard !target.contains("@"), let colon = target.lastIndex(of: ":") else {
      throw DenialError(.portNotAllowed)
    }
    let hostText = String(target[..<colon])
    let portText = String(target[target.index(after: colon)...])
    guard portText == "443", let port = Int(portText) else { throw DenialError(.portNotAllowed) }
    let host: ExactHostname
    do { host = try ExactHostname(hostText) } catch { throw DenialError(.hostNotAllowed) }
    var password: String?
    var seenAuth = false
    for line in lines.dropFirst() where !line.isEmpty {
      let lower = line.lowercased()
      if lower.hasPrefix("transfer-encoding:") || lower.hasPrefix("content-length:") {
        throw DenialError(.unsupported)
      }
      if lower.hasPrefix("proxy-authorization:") {
        if seenAuth { throw DenialError(.authRequired) }
        seenAuth = true
        password = basicPassword(String(line.dropFirst("Proxy-Authorization:".count)))
      }
    }
    guard let password else { throw DenialError(.authRequired) }
    return ConnectRequest(host: host, port: port, password: password)
  }

  static func basicPassword(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.lowercased().hasPrefix("basic ") else { return nil }
    let encoded = String(trimmed.dropFirst(6))
    guard let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8),
      let colon = text.firstIndex(of: ":"), String(text[..<colon]) == username
    else { return nil }
    return String(text[text.index(after: colon)...])
  }

  public static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let a = Array(left.utf8)
    let b = Array(right.utf8)
    var diff = a.count ^ b.count
    for index in 0..<max(a.count, b.count) {
      let x = index < a.count ? a[index] : 0
      let y = index < b.count ? b[index] : 0
      diff |= Int(x ^ y)
    }
    return diff == 0
  }
}

public struct DenialError: Error, Equatable {
  public let denial: Denial
  public init(_ denial: Denial) { self.denial = denial }
}

public struct EgressAllowlist: Sendable, Equatable {
  public let hosts: Set<String>
  public init(_ hosts: [ExactHostname]) { self.hosts = Set(hosts.map(\.rawValue)) }
  public func allows(_ host: ExactHostname) -> Bool { hosts.contains(host.rawValue) }
}

/// Decision before any upstream connection. An unapproved host never becomes
/// a connect target.
public enum ConnectDecision: Equatable, Sendable {
  case connect(String)
  case deny(Denial)
}

public enum ConnectGate {
  public static func decide(_ head: [UInt8], allow: EgressAllowlist, capability: String)
    -> ConnectDecision
  {
    do {
      let request = try ConnectParser.parse(head)
      guard ConnectParser.constantTimeEqual(request.password, capability) else {
        return .deny(.authRequired)
      }
      guard allow.allows(request.host) else { return .deny(.hostNotAllowed) }
      return .connect(request.host.rawValue)
    } catch let error as DenialError {
      return .deny(error.denial)
    } catch {
      return .deny(.unsupported)
    }
  }

  public static func responseBytes(_ denial: Denial?) -> [UInt8] {
    let text =
      denial == nil
      ? "HTTP/1.1 200 Connection Established\r\n\r\n"
      : "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    return Array(text.utf8)
  }

  /// The host to connect, or a denial. The caller connects only on success.
  public static func connectTarget(_ head: [UInt8], allow: EgressAllowlist, capability: String)
    -> ConnectDecision
  {
    decide(head, allow: allow, capability: capability)
  }

  public static func readHead(_ client: Int32) -> [UInt8] {
    var head = [UInt8]()
    var byte: UInt8 = 0
    while head.count < 16 * 1024 {
      if recv(client, &byte, 1, 0) != 1 { return head }
      head.append(byte)
      if head.suffix(4) == [13, 10, 13, 10] { break }
    }
    return head
  }

  public static func writeResponse(_ client: Int32, _ denial: Denial?) {
    let bytes = responseBytes(denial)
    _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
  }

  /// Reads one CONNECT. A denial is written and no host is returned, so the
  /// caller cannot connect. An approval returns the host and writes nothing.
  public static func approvedHost(_ client: Int32, allow: EgressAllowlist, capability: String)
    -> String?
  {
    switch connectTarget(readHead(client), allow: allow, capability: capability) {
    case .deny(let denial):
      writeResponse(client, denial)
      return nil
    case .connect(let host):
      return host
    }
  }
}
