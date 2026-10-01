import Foundation
import Testing

@testable import IsoConfiguration
@testable import IsoCore

@Test func definitionRejectsUnknownFieldsAndBudgets() throws {
  let good = """
    {
      "schema_version": 1,
      "id": "repo-helper",
      "display_name": "Repository helper",
      "environment": { "image": "helper-tools" },
      "launch": {
        "argv": ["repo-helper"],
        "working_directory": "/workspace",
        "terminal": "auto",
        "environment": { "NO_COLOR": "1" }
      },
      "auth_adapter": "none",
      "network_hints": { "suggested_hosts": ["Registry.NPMJS.org."] }
    }
    """
  let definition = try AgentDefinitionDecoder.decode(
    Array(good.utf8), path: "d.json", format: .json)
  #expect(definition.authAdapter == .none)
  #expect(definition.networkHints.map(\.rawValue) == ["registry.npmjs.org"])
  #expect(definition.launch.environment.map(\.name.rawValue) == ["NO_COLOR"])

  let unknown = good.replacingOccurrences(
    of: "\"auth_adapter\"", with: "\"mounts\": [], \"auth_adapter\"")
  #expect(throws: AgentDefinitionError.self) {
    try AgentDefinitionDecoder.decode(Array(unknown.utf8), path: "d.json", format: .json)
  }
  let secret = good.replacingOccurrences(
    of: "\"NO_COLOR\": \"1\"", with: "\"ANTHROPIC_API_KEY\": \"x\"")
  let error = try #require(throws: AgentDefinitionError.self) {
    try AgentDefinitionDecoder.decode(Array(secret.utf8), path: "d.json", format: .json)
  }
  #expect(error.message.contains("allowlist"))
  #expect(!error.message.contains("ANTHROPIC_API_KEY="))
}

@Test func definitionRejectsTraversalAndDuplicateKeys() {
  let traversal = """
    {"schema_version":1,"id":"repo-helper","display_name":"n","launch":{"argv":["t"],"working_directory":"/workspace/../etc"},"auth_adapter":"none"}
    """
  #expect(throws: AgentDefinitionError.self) {
    try AgentDefinitionDecoder.decode(Array(traversal.utf8), path: "d.json", format: .json)
  }
  let duplicate = """
    {"schema_version":1,"id":"repo-helper","id":"other","display_name":"n","launch":{"argv":["t"]},"auth_adapter":"none"}
    """
  #expect(throws: AgentDefinitionError.self) {
    try AgentDefinitionDecoder.decode(Array(duplicate.utf8), path: "d.json", format: .json)
  }
}

@Test func claudeVariantSelectsTheReviewedAdapter() throws {
  let text = """
    {"schema_version":1,"id":"claude-review","display_name":"Claude review","launch":{"argv":["claude"]},"auth_adapter":"claude"}
    """
  let definition = try AgentDefinitionDecoder.decode(
    Array(text.utf8), path: "c.json", format: .json)
  #expect(definition.authAdapter == .claude)
  #expect(definition.launch.workingDirectory.rawValue == "/workspace")
}
