import ArgumentParser
import Foundation
import Testing

@testable import IsoCLI

private func hint(_ argv: [String]) -> String? {
  do {
    _ = try IsoCommand.parseAsRoot(argv)
    return nil
  } catch {
    return CommandSuggestion.hint(for: error, arguments: ["iso"] + argv)
  }
}

@Test func mistypedSubcommandsGetOneDeterministicSuggestion() {
  #expect(hint(["pul"]) == "Did you mean 'pull'?")
  #expect(hint(["shel"]) == "Did you mean 'shell'?")
  #expect(hint(["audti"]) == "Did you mean 'audit'?")
  #expect(hint(["--config", "/x.jsonc", "stp"]) == "Did you mean 'stop'?")
  // Nested groups suggest among their own subcommands.
  #expect(hint(["host", "pul", "x", "y"]) == "Did you mean 'pull'?")
  // Too far from anything, or equally close to several: no guess.
  #expect(hint(["zzzzzz"]) == nil)
  #expect(hint(["s"]) == nil)
  // A real command with a stray argument is not a spelling problem.
  #expect(hint(["pull", "a", "b"]) == nil)
}

@Test func editDistanceCountsTranspositionsOnce() {
  #expect(CommandSuggestion.distance("pull", "pull") == 0)
  #expect(CommandSuggestion.distance("plul", "pull") == 1)
  #expect(CommandSuggestion.distance("pul", "pull") == 1)
  #expect(CommandSuggestion.distance("", "abc") == 3)
  #expect(CommandSuggestion.nearest("sta", in: ["start", "status", "stop"]) == nil)
  #expect(CommandSuggestion.nearest("star", in: ["start", "status", "stop"]) == "start")
}

@Test func conflictsNameExactlyTheFlagsGiven() throws {
  #expect(CommandSuggestion.exclusive(["--a": true, "--b": false], why: "x") == nil)
  #expect(
    CommandSuggestion.exclusive(["--a": true, "--b": true], why: "x")?.message
      == "--a and --b cannot be combined: x")
  #expect(
    CommandSuggestion.exclusive(["--a": true, "--b": true, "--c": true], why: "x")?.message
      == "--a, --b and --c cannot be combined: x")
  #expect(throws: (any Error).self) {
    _ = try IsoCommand.parseAsRoot(["pull", "--review", "--apply"])
  }
  do {
    _ = try IsoCommand.parseAsRoot(["pull", "--apply", "--discard"])
  } catch {
    #expect(IsoCommand.message(for: error).hasPrefix("--apply and --discard cannot be combined"))
  }
}
