import IsoEgressCore

/// `ConnectParser.parse` and `ConnectGate.decide` on guest-sent CONNECT heads:
/// the guest chooses every byte before the tunnel opens.
public enum EgressConnectHarness {
  static let capability = "secret"
  static let allow = EgressAllowlist(rules: [
    .exact(try! ExactHostname("example.com")),
    .subdomains(of: try! ExactHostname("jobs.example.org")),
  ])

  public static func run(_ bytes: [UInt8]) {
    let parsed = try? ConnectParser.parse(bytes)
    if let parsed {
      require(bytes.count <= EgressBudgets.maxHeadBytes, "head within its budget")
      // No second header block can hide before the terminator.
      require(firstTerminatorEnd(bytes) == bytes.count, "the only blank line ends the head")
      require(bytes.starts(with: Array("CONNECT ".utf8)), "CONNECT method")
      require(parsed.port == 443, "port 443 only")
      let host = parsed.host.rawValue
      require((try? ExactHostname(host)) == parsed.host, "host revalidates")
      require(
        host.utf8.allSatisfy {
          (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D || $0 == 0x2E
        },
        "lowercase LDH host")
      require(host.utf8.count <= 253 && host.split(separator: ".").count >= 2, "host shape")
    }
    switch ConnectGate.decide(bytes, allow: allow, capability: capability) {
    case .connect(let host):
      require(parsed?.password == capability, "connect needs the capability")
      require(parsed?.host.rawValue == host, "connect target is the parsed host")
      let suffix = ".jobs.example.org"
      require(
        host == "example.com" || (host.hasSuffix(suffix) && host.utf8.count > suffix.utf8.count),
        "connect target is allowlisted on a label boundary")
    case .deny:
      if let parsed, parsed.password == capability {
        require(!allow.allows(parsed.host), "an allowed, authenticated CONNECT is not denied")
      }
    }
  }
}
