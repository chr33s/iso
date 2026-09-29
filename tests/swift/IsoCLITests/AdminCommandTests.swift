import ArgumentParser
import Foundation
import IsoConfiguration
import IsoHost
import Synchronization
import Testing

@testable import IsoCLI

@Test func updateFlagsParseLikeTheBaseline() throws {
  let bare = try #require(try IsoCommand.parseAsRoot(["update"]) as? Update)
  #expect(!bare.check && !bare.force && !bare.yes && bare.targetVersion == nil)
  let full = try #require(
    try IsoCommand.parseAsRoot(["update", "--check", "--force", "--version", "v0.3.2", "-y"])
      as? Update)
  #expect(full.check && full.force && full.yes && full.targetVersion == "v0.3.2")
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["update", "--version"]) }
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["update", "0.3.2"]) }
}

@Test func uninstallFlagsParseAndConflict() throws {
  let bare = try #require(try IsoCommand.parseAsRoot(["uninstall"]) as? Uninstall)
  #expect(!bare.yes && !bare.keepData && !bare.purge)
  for (argv, check) in [
    (["uninstall", "--yes"], \Uninstall.yes), (["uninstall", "-y"], \Uninstall.yes),
    (["uninstall", "--keep-data"], \Uninstall.keepData),
    (["uninstall", "--purge"], \Uninstall.purge),
  ] {
    let parsed = try #require(try IsoCommand.parseAsRoot(argv) as? Uninstall)
    #expect(parsed[keyPath: check])
  }
  #expect(throws: (any Error).self) {
    try IsoCommand.parseAsRoot(["uninstall", "--keep-data", "--purge"])
  }
}

@Test func uninstallFallsBackToDefaultsOnABrokenConfig() throws {
  let home = FileManager.default.temporaryDirectory.appending(path: "iso-cli-\(UUID().uuidString)")
    .path
  defer { try? FileManager.default.removeItem(atPath: home) }
  try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
  let broken = home + "/broken.jsonc"
  try Data("{ not json".utf8).write(to: URL(fileURLWithPath: broken))
  let lines = Mutex<[String]>([])
  let diagnostics = Diagnostics(verbosity: 0) { line in lines.withLock { $0.append(line) } }
  let global = try GlobalOptions.parse(["--config", broken])
  let loaded = try AdminSupport.bestEffortConfig(
    global, ConfigEnvironment(home: home, variables: [:]), diagnostics)
  #expect(loaded.path == broken)
  #expect(loaded.config.dataDirectory.path == home + "/.iso")
  let warning = try #require(lines.withLock { $0 }.first)
  #expect(warning.contains("Failed to parse \(broken) ("))
  #expect(warning.contains("re-run with --keep-data if your data lives outside \(home)/.iso."))
}
