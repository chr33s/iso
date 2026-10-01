import Testing

@testable import IsoCLI

@Test func runParsesAgentWorkspaceAndRefusesJSONWithoutDryRun() throws {
  let run = try #require(
    try IsoCommand.parseAsRoot([
      "run", "claude", "--workspace", ".", "--ask", "--", "--model", "opus",
    ])
      as? RunCommand)
  #expect(run.agent == "claude")
  #expect(run.ask)
  #expect(run.workspace == ".")
  #expect(run.args == ["--model", "opus"])
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["run", "claude", "--json"]) }
  let preview = try #require(
    try IsoCommand.parseAsRoot(["run", "codex", "--dry-run", "--json", "--rm"]) as? RunCommand)
  #expect(preview.dryRun && preview.json && preview.remove)
  #expect(try IsoCommand.parseAsRoot(["agent", "list"]) is AgentListCommand)
  #expect(try IsoCommand.parseAsRoot(["images", "inspect", "default"]) is ImagesInspect)
  #expect(try IsoCommand.parseAsRoot(["images", "cache", "status"]) is ImagesCacheStatus)
}
