import Darwin
import Testing

@testable import IsoEgressCore

@Test func hostnamesAreExact() throws {
  #expect(try ExactHostname("Example.COM.").rawValue == "example.com")
  #expect(try ExactHostname("a.example.com") != ExactHostname("example.com"))
  for bad in ["*.example.com", "127.0.0.1", "localhost", "http://example.com", "user@example.com"] {
    #expect(throws: PolicyError.self) { try ExactHostname(bad) }
  }
}

@Test func addressesDenySpecialPurposeRanges() {
  #expect(!AddressPolicy.isPublic("127.0.0.1"))
  #expect(!AddressPolicy.isPublic("10.1.2.3"))
  #expect(!AddressPolicy.isPublic("192.168.1.1"))
  #expect(!AddressPolicy.isPublic("169.254.1.1"))
  #expect(!AddressPolicy.isPublic("224.0.0.1"))
  #expect(!AddressPolicy.isPublic("::1"))
  #expect(!AddressPolicy.isPublic("fe80::1"))
  #expect(!AddressPolicy.isPublic("1.2.3.4", local: ["1.2.3.4"]))
  #expect(AddressPolicy.isPublic("1.1.1.1"))
}

@Test func unapprovedConnectIsDeniedBeforeAnyTargetIsChosen() throws {
  let allow = EgressAllowlist([try ExactHostname("example.com")])
  let denied = Array(
    "CONNECT other.example:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n"
      .utf8)
  #expect(
    ConnectGate.connectTarget(denied, allow: allow, capability: "secret")
      == .deny(.hostNotAllowed))
  let approved = Array(
    "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n".utf8)
  #expect(
    ConnectGate.connectTarget(approved, allow: allow, capability: "secret")
      == .connect(
        "example.com"))
  var pair: [Int32] = [-1, -1]
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  defer {
    close(pair[0])
    close(pair[1])
  }
  #expect(denied.withUnsafeBytes { send(pair[0], $0.baseAddress, $0.count, 0) } == denied.count)
  #expect(ConnectGate.approvedHost(pair[1], allow: allow, capability: "secret") == nil)
  let expected = ConnectGate.responseBytes(.hostNotAllowed)
  var buffer = [UInt8](repeating: 0, count: expected.count)
  #expect(recv(pair[0], &buffer, buffer.count, 0) == expected.count)
  #expect(buffer == expected)
  #expect(approved.withUnsafeBytes { send(pair[0], $0.baseAddress, $0.count, 0) } == approved.count)
  #expect(ConnectGate.approvedHost(pair[1], allow: allow, capability: "secret") == "example.com")
}

@Test func connectRequiresAuthAndPort443() throws {
  let ok = Array(
    "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n".utf8)
  let request = try ConnectParser.parse(ok)
  #expect(request.host.rawValue == "example.com")
  #expect(request.password == "secret")
  let missing = Array("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8)
  #expect(throws: DenialError.self) { try ConnectParser.parse(missing) }
  let port = Array(
    "CONNECT example.com:80 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n".utf8)
  #expect(throws: DenialError.self) { try ConnectParser.parse(port) }
  let body = Array(
    "CONNECT example.com:443 HTTP/1.1\r\nContent-Length: 1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n"
      .utf8)
  #expect(throws: DenialError.self) { try ConnectParser.parse(body) }
}
