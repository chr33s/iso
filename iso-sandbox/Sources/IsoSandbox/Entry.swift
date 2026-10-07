import ArgumentParser
import Foundation
import IsoSandboxCore

/// Process entry. Synchronous so that `macos run` can own the AppKit main
/// loop on the main thread; every other command runs the async command tree.
@main
enum Entry {
  static func main() {
    // Everything this binary writes (records, disks, logs, the owner it
    // runs under launchd) is for this user alone.
    umask(0o077)
    let args = CommandLine.arguments
    // ssh's password prompt during a macOS template build (MacTemplates):
    // the secret is in this child's environment only, never in argv.
    let env = ProcessInfo.processInfo.environment
    if let secret = env[MacTemplates.askpassEnv], args.count == 2,
      let askpass = env["SSH_ASKPASS"],
      askpass == (Bundle.main.executablePath ?? args[0])
    {
      print(secret)
      exit(0)
    }
    if args.count >= 3, args[1] == "macos", args[2] == "run" {
      // Exit 0 whatever happens, including a bad argument or root, so
      // launchd does not respawn a configuration error.
      do {
        let command = try MacRun.parse(Array(args.dropFirst(3)))
        try command.run()
      } catch {
        FileHandle.standardError.write(Data("owner failed: \(MacRun.message(for: error))\n".utf8))
      }
      exit(0)
    }
    Task {
      await IsoSandbox.main(nil)
      exit(0)
    }
    dispatchMain()
  }
}
