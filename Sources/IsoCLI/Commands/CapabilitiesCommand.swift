import ArgumentParser
import Foundation
import IsoHost

/// Feature discovery for integrations. Side-effect free: it reads no
/// configuration, credentials or state, starts no runtime and checks for no
/// update.
struct Capabilities: MachineCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show the machine interface versions and commands this iso supports")

  @OptionGroup var global: GlobalOptions

  func run() throws {
    try IsoCLI.run(global, Self.self) {
      let result = MachineCapabilitiesResult()
      guard global.output == .text else { return result }
      let output = StandardStreams()
      output.out(result.cliVersion)
      output.out("Machine API: \(result.machineAPIVersions.joined(separator: ", "))")
      output.out("Backend: \(result.backend)")
      output.out(
        "Commands with --output json: \(MachineCommands.all.map { $0.machineName }.joined(separator: ", "))"
      )
      output.out(
        "Editor providers: "
          + result.editorProviders.map { "\($0.id) (\($0.displayName))" }.joined(separator: ", "))
      return result
    }
  }
}
