import CoopConfiguration
import CoopCore
import Foundation

/// Just-in-time resolution of secret-bearing configuration values. A value
/// beginning `cmd:` is a trusted, user-authored host command run through
/// `/bin/sh -c`; its trimmed stdout is the secret. Other values pass through
/// unchanged. Only callers whose operation needs the secret invoke this;
/// configuration loading never does.
public struct CredentialResolver: Sendable {
  public static let timeout: Duration = .seconds(10)

  let runner: ProcessRunner
  let environment: [String: String]

  public init(runner: ProcessRunner = ProcessRunner(), environment: [String: String]) {
    self.runner = runner
    self.environment = environment
  }

  public func resolve(_ value: Secret<String>) throws(HostError) -> Secret<String> {
    let raw = value.expose()
    guard raw.hasPrefix("cmd:") else { return value }
    let command = String(raw.dropFirst(4)).trimmingUnicodeWhitespace()
    guard !command.isEmpty else { throw HostError("Empty command after 'cmd:' prefix") }
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        .init(
          executable: "/bin/sh", arguments: ["-c", command], environment: environment,
          deadline: Self.timeout, outputLimit: 1 << 20))
    } catch .timedOut {
      throw HostError(
        "Secret command timed out after 10s: \(command)\nEnsure the command runs non-interactively."
      )
    } catch .spawn {
      throw HostError("Failed to spawn secret command: \(command)")
    } catch .outputLimitExceeded {
      throw HostError("Secret command produced more than 1 MiB of output: \(command)")
    } catch {
      throw HostError("Failed to read output: \(command)")
    }
    guard output.termination == .exited(0) else {
      let code =
        switch output.termination {
        case .exited(let status): String(status)
        case .signaled: "signal"
        }
      let stderr = String(decoding: output.stderr.prefix(4096), as: UTF8.self)
      throw HostError("Secret command failed (exit \(code)): \(command)\nstderr: \(stderr)")
    }
    guard let stdout = String(validating: output.stdout, as: UTF8.self) else {
      throw HostError("Secret command output is not valid UTF-8")
    }
    let resolved = stdout.trimmingUnicodeWhitespace()
    guard !resolved.isEmpty else {
      throw HostError(
        "Secret command produced empty output: \(command)\nThe command succeeded but stdout was empty after trimming."
      )
    }
    return Secret(resolved)
  }

  public func resolve(_ reference: CredentialReference) throws(HostError) -> Secret<String> {
    try resolve(reference.command)
  }
}
