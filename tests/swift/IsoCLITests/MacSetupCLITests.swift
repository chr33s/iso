import ArgumentParser
import IsoCore
import Testing

@testable import IsoCLI

@Test func setupGuestMacOSNeedsARestoreImageAndNoLinuxOptions() throws {
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["setup", "--guest", "macos"]) }
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["setup", "--ipsw", "x.ipsw"]) }
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["setup", "--guest", "windows"]) }
  for extra in [
    ["--profile", "python"], ["--dry-run"], ["--workspace", "."], ["--no-devcontainer"],
    ["--devcontainer", "d.json"], ["--guest-user", "vscode"], ["--post-install", "p.sh"],
    ["--extra-packages", "jq"], ["--config-only"],
  ] {
    #expect(throws: (any Error).self) {
      try IsoCommand.parseAsRoot(["setup", "--guest", "macos", "--ipsw", "x.ipsw"] + extra)
    }
  }
  let setup = try #require(
    try IsoCommand.parseAsRoot([
      "setup", "--guest", "macos", "--ipsw", "x.ipsw", "--image", "mac", "--rebuild",
    ]) as? Setup)
  #expect(setup.guest == .macos && setup.ipsw == "x.ipsw" && setup.rebuild)
}
