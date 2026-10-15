import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets

/// The boot options `up` (and its editor variants) and `start` share: what a
/// boot injects and runs, never how an instance is created.
struct BootArguments: ParsableArguments {
  @Flag(
    name: .customLong("no-agents"),
    help: "Skip injecting Claude Code and Codex credentials/config into the VM")
  var noAgents = false
  @Flag(help: "Use github = \"off\" for this invocation and skip the GitHub PAT prompt")
  var noGithub = false
  @Flag(
    help:
      "Suppress the interactive prompt to set up a scoped GitHub PAT when one is missing for the resolved repo"
  )
  var noPrompt = false
  @Option(
    help:
      "Forward a guest port to the host (`GUEST[:HOST]`, repeatable). `--forward-port 3000` forwards guest 3000 to host 3000; `--forward-port 3000:3001` forwards guest 3000 to host 3001",
    transform: parsePortForward)
  var forwardPort: [PortForward] = []
  @Option(
    help: ArgumentHelp(
      "Shell command to run inside the guest after boot (overrides `post_start` from the config). Failure is logged but does not fail the start",
      valueName: "CMD"))
  var postStart: String?
  @Option(
    name: .customLong("env"),
    help: ArgumentHelp(
      "Env var to set in the guest (`KEY=VALUE`, repeatable). A whole value `{vault:NAME}` is resolved from `iso secrets` for each session. Overrides `--env-file`, `guest_env` entries from config and any forwarded values with the same name",
      valueName: "KEY=VALUE"),
    transform: parseGuestEnvironment)
  var guestEnvironment: [(EnvVarName, EnvValue)] = []
  @Option(
    help: ArgumentHelp(
      "A `.env` file of guest env vars (`KEY=value`, `{vault:NAME}` references). Parsed strictly; never run by a shell",
      valueName: "PATH"))
  var envFile: String?
}

/// An explicit `devcontainer.json`, or none at all; neither means discovery.
struct DevcontainerArguments: ParsableArguments {
  @Option(
    help: ArgumentHelp(
      "Explicit path to a `devcontainer.json` to use (skips discovery)", valueName: "PATH"))
  var devcontainer: String?
  @Flag(help: "Ignore any discovered `devcontainer.json` (escape hatch for CI)")
  var noDevcontainer = false

  func validate() throws {
    if devcontainer != nil && noDevcontainer {
      throw UsageError(
        "the argument '--devcontainer <PATH>' cannot be used with '--no-devcontainer'")
    }
  }

  var isSet: Bool { devcontainer != nil || noDevcontainer }

  var input: DevcontainerInput { .fromFlags(path: devcontainer, noDevcontainer: noDevcontainer) }
}

extension EgressMode: ExpressibleByArgument {}

/// `--egress` and `--allow-host`, typed at parse time. Whether a valid value
/// may change a given boot is decided when the command runs.
struct EgressOptions: ParsableArguments {
  @Option(help: "Egress mode when creating an instance: open, none, or filtered")
  var egress: EgressMode?
  @Option(
    name: .customLong("allow-host"),
    help: "Exact host to approve for a filtered boot. Does not change none or open to filtered",
    transform: parseExactHostname)
  var allowHost: [ExactHostname] = []

  var isSet: Bool { egress != nil || !allowHost.isEmpty }
}

func parseExactHostname(_ text: String) throws -> ExactHostname {
  do { return try ExactHostname(text) } catch { throw UsageError("--allow-host: \(error.message)") }
}

/// One `--profile` value: comma-separated names, none of them empty. Order is
/// kept; callers that derive an image identity sort the set themselves.
func parseProfileList(_ text: String) throws -> [String] {
  let names = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
  guard !names.contains(where: \.isEmpty) else {
    throw UsageError("--profile \(debugQuoted(text)) contains an empty profile name")
  }
  return names
}

/// A `--ttl` in whole seconds, or `fallback` when none was given.
func ttlSeconds(_ ttl: Duration?, default fallback: UInt64) -> UInt64 {
  guard let ttl else { return fallback }
  return UInt64(ttl.components.seconds)
}
