import Foundation
import Testing

@testable import CoopProxyCore

private func fixture() -> [String: Any] {
  [
    "version": 1, "listen": "127.0.0.1:8788", "provider": "anthropic",
    "capability_token": String(repeating: "a", count: 64),
    "injection": ["scheme": "x_api_key", "credential": "real-secret"],
  ]
}
private func parse(_ value: [String: Any]) throws -> ProxyConfig {
  try ProxyConfig(json: JSONSerialization.data(withJSONObject: value))
}

@Test func configValidatesBeforeServing() throws {
  let config = try parse(fixture())
  #expect(config.listen.host == "127.0.0.1")
  #expect(config.listen.port == 8788)
  #expect(config.provider == .anthropic)
  #expect(config.injection.credential.expose() == "real-secret")
  #expect(!String(reflecting: config).contains("real-secret"))
  #expect(!String(reflecting: config).contains(String(repeating: "a", count: 64)))
  for (provider, scheme) in [("anthropic", "bearer"), ("openai", "bearer")] {
    var value = fixture()
    value["provider"] = provider
    value["injection"] = ["scheme": scheme, "credential": "real-secret"]
    #expect(throws: Never.self) { try parse(value) }
  }
  for (field, invalid) in [
    ("version", 0 as Any), ("version", 2), ("provider", "evil"),
    ("provider", "openai"), ("upstream_host", "api.anthropic.com"), ("extra", true),
    ("capability_token", ""), ("capability_token", String(repeating: "A", count: 64)),
  ] {
    var value = fixture()
    value[field] = invalid
    #expect(throws: PolicyError.self) { try parse(value) }
  }
  for field in fixture().keys {
    var value = fixture()
    value.removeValue(forKey: field)
    #expect(throws: PolicyError.self) { try parse(value) }
  }
  for injection in [
    ["scheme": "basic", "credential": "real-secret"],
    ["scheme": "bearer", "credential": ""], ["scheme": "bearer", "credential": "real-secret\r\n"],
    ["scheme": "bearer", "credential": "real-secret", "extra": "real-secret"],
  ] {
    var value = fixture()
    value["injection"] = injection
    #expect(throws: PolicyError.self) { try parse(value) }
  }
}

@Test func loopbackOnly() throws {
  for invalid in [
    "0.0.0.0:1", "[::]:1", "192.168.1.1:1", "[2001:db8::1]:1", "localhost:1",
    "127.0.0.01:1", "127.0.0.256:1", "127.0.0.1:-1", "127.0.0.1:65536", "127.0.0.1:",
  ] {
    #expect(throws: PolicyError.self) { try LoopbackAddress(invalid) }
  }
  for valid in ["127.0.0.1:0", "127.1.2.3:65535", "[::1]:8788"] {
    #expect(throws: Never.self) { try LoopbackAddress(valid) }
  }
}
