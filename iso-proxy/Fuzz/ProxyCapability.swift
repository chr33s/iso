import IsoProxyCore

/// `Capability` decoding and the request authentication check. Only the exact
/// 64-character lowercase hex token, as `Bearer` or `x-api-key`, authorizes.
public enum ProxyCapabilityHarness {
  static let token = String(repeating: "0f", count: 32)
  static let capability = try! Capability(token)

  public static func run(_ bytes: [UInt8]) {
    let text = String(decoding: bytes, as: UTF8.self)
    let wellFormed =
      text.utf8.count == 64
      && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    let decoded = try? Capability(text)
    require((decoded != nil) == wellFormed, "decodes exactly lowercase 64-hex")
    if let decoded {
      require(decoded.verifies(text), "a token verifies itself")
      require(String(describing: decoded) == "<redacted>", "never rendered")
    }
    require(capability.verifies(text) == (text == token), "only the issued token verifies")
    let headers = headerLines(bytes).map { Header($0.0, $0.1) }
    let authorization = headers.filter { $0.name.lowercased() == "authorization" }
    let apiKeys = headers.filter { $0.name.lowercased() == "x-api-key" }
    let expected =
      authorization.count <= 1 && apiKeys.count <= 1
      && !(authorization.isEmpty && apiKeys.isEmpty)
      && authorization.allSatisfy { $0.value == "Bearer " + token }
      && apiKeys.allSatisfy { $0.value == token }
    require(capability.authorizes(headers) == expected, "authorization matches the oracle")
  }
}
