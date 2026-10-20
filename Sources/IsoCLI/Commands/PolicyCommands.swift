import ArgumentParser
import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

struct PolicyCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "policy",
    abstract: "Inspect the authorization policy a VM boot runs under (docs/policy.md)",
    subcommands: [PolicyShow.self, PolicyEffective.self])
}

/// `iso policy effective`: requested versus recorded policy and every
/// relaxation from the secure-default baseline. Read-only: no secret is
/// resolved, no VM is started or changed, nothing is audited.
struct PolicyEffective: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "effective",
    abstract:
      "Report requested and recorded transport, egress, credentials, return, imports and lifetime, and every relaxation from the secure defaults (read-only)"
  )

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (default: the only instance, if any)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Emit JSON instead of the text report") var json = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global, intent: .preview)
      let instance =
        name != nil
        ? try InstanceStore.resolve(context.config, name: name)
        : (try? InstanceStore.list(context.config, skipped: { _, _ in }))
          .flatMap { $0.count == 1 ? $0[0] : nil }
      let report = EffectivePolicyReport.json(context.config, instance: instance)
      if json {
        context.output.write(report.rendered())
      } else {
        EffectivePolicyReport.text(report).map(neutralizeControls).forEach(context.output.out)
      }
    }
  }
}

struct PolicyShow: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract:
      "Show the active policy snapshot, its epoch and digest, proxy launch claims, and whether the configured policy is pending the next boot"
  )

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Emit JSON instead of the text report") var json = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      let report = try PolicyReport.json(instance, configured: context.config.policy)
      if json {
        context.output.write(report.rendered())
      } else {
        PolicyReport.text(report).map(neutralizeControls).forEach(context.output.out)
      }
    }
  }
}

/// The trusted host-terminal confirmation for a governed `iso pull --apply`.
/// Nil (so the apply reports `approval_required`) in machine-output mode or
/// without an interactive terminal. The review is written to, and the
/// answer read from, the controlling terminal: piped input, environment
/// variables and `--force` cannot approve.
enum TerminalStageConfirmation {
  static func make(global: GlobalOptions, instance: Instance) -> StageConfirmation? {
    guard global.output != .json, isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
      return nil
    }
    return { selected in
      let manifest = selected.manifest
      let tty = open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
      guard tty >= 0 else { return false }
      defer { close(tty) }
      let review = StageReview(selected)
      var stale = false
      let diffs = review.textDiffs(markOmitted: true, stale: &stale)
      // A review that no longer matches the manifest cannot approve it.
      guard !stale else { return false }
      var text = (review.summary(instance: instance.name.rawValue) + diffs).joined(separator: "\n")
      text +=
        "\n\nThe policy requires approving this exact stage before it is applied.\nType the stage id (\(manifest.id)) to apply it now; anything else cancels: "
      guard (try? AtomicFile.writeAll(tty, Array(text.utf8), "/dev/tty")) != nil else {
        return false
      }
      return readLine(tty) == manifest.id
    }
  }

  /// One line, keeping at most 256 bytes. The rest of the line is still
  /// consumed, so nothing typed here reaches the shell after iso exits.
  private static func readLine(_ fd: Int32) -> String? {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
      let count = Darwin.read(fd, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count == 1 else { return nil }
      if byte == 0x0A { break }
      if bytes.count < 256 { bytes.append(byte) } else { bytes = [0] }
    }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
