import Testing

@testable import IsoCore

@Test func agentIDsRejectPathsAndReservedShapes() throws {
  #expect(throws: ValidationError.self) { try AgentDefinitionID("") }
  #expect(throws: ValidationError.self) { try AgentDefinitionID("Claude") }
  #expect(throws: ValidationError.self) { try AgentDefinitionID("1abc") }
  #expect(throws: ValidationError.self) { try AgentDefinitionID("a/b") }
  #expect(throws: ValidationError.self) { try AgentDefinitionID("a_b") }
  #expect(try AgentDefinitionID("repo-helper").rawValue == "repo-helper")
  #expect(try AgentDefinitionID("claude").isReserved)
  #expect(throws: ValidationError.self) { try AgentAdapterID("aider") }
  #expect(try AgentAdapterID("none").rawValue == "none")
}

@Test func exactHostnamesAreCaseFoldedAndNotHierarchical() throws {
  #expect(try ExactHostname("Example.COM.").rawValue == "example.com")
  #expect(try ExactHostname("a.example.com") != ExactHostname("example.com"))
  for bad in [
    "", "*.example.com", "localhost", "127.0.0.1", "1.2.3.4",
    "http://example.com", "user@example.com", "example.com/a", "ex ample.com",
    "example.com%2eattacker.test", "::1", "[::1]", "xn--.com", "-bad.com", "bad-.com",
  ] {
    #expect(throws: ValidationError.self, "\(bad)") { try ExactHostname(bad) }
  }
  // A trailing dot is normalized away.
  #expect(try ExactHostname("example.com.").rawValue == "example.com")
}
