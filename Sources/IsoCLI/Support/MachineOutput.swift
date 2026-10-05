import ArgumentParser
import Foundation
import IsoCore
import IsoHost
import Synchronization

/// `--output`: human text (the default) or the versioned machine contract.
enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
  case text
  case json
}

/// A command that implements `--output json`. Any other command given
/// `--output json` fails with `UNSUPPORTED_MACHINE_OUTPUT`.
protocol MachineCommand: ParsableCommand {}

extension MachineCommand {
  static var machineName: String { _commandName }
}

enum MachineCommands {
  /// Every registered command `capabilities` advertises, in registration order.
  static var all: [any MachineCommand.Type] {
    IsoCommand.configuration.subcommands.compactMap { $0 as? any MachineCommand.Type }
  }
}

extension GlobalOptions {
  /// The options a parsed command was given, wherever its `@OptionGroup`
  /// sits; nil for a command without them.
  static func parsed(in command: any ParsableCommand) -> GlobalOptions? {
    Mirror(reflecting: command).children.lazy.compactMap {
      ($0.value as? OptionGroup<GlobalOptions>)?.wrappedValue
    }.first
  }

  /// `--output json` (or `--output=json`) before any `--`.
  static func requestsMachineOutput(_ arguments: [String]) -> Bool {
    let options = arguments.dropFirst().prefix { $0 != "--" }
    return options.contains("--output=json")
      || zip(options, options.dropFirst()).contains { $0 == "--output" && $1 == "json" }
  }

  /// Command-local `--json` keeps its legacy shape and cannot be mixed with
  /// the versioned contract.
  func rejectLegacyJSON(_ json: Bool) throws {
    if json && output == .json {
      throw ArgumentParser.ValidationError("--json cannot be combined with --output json")
    }
  }

  /// A dry run is a preview with its own JSON (`--dry-run --json`).
  func rejectDryRun(_ dryRun: Bool) throws {
    if dryRun && output == .json {
      throw ArgumentParser.ValidationError(
        "--dry-run cannot be combined with --output json; use --dry-run --json for the plan")
    }
  }
}

/// Machine mode owns the process's standard descriptors: stdout carries the
/// one protocol document and nothing else, so everything that would write to
/// fd 1 (this process or a child) goes to stderr; stdin is `/dev/null`, so no
/// prompt can wait on it.
enum MachineSession {
  /// The original stdout, kept close-on-exec so no child inherits it.
  private static let document = Mutex<Int32?>(nil)

  static var isActive: Bool { document.withLock { $0 != nil } }

  /// A standard descriptor closed at launch is filled with `/dev/null`, so
  /// no later open can land on 0-2.
  static func begin(quiet: Bool) throws {
    fflush(stdout)
    let saved = fcntl(1, F_DUPFD_CLOEXEC, 3)
    let opened = open("/dev/null", O_RDWR | O_CLOEXEC)
    // `opened` may itself be a closed standard descriptor; work from a copy
    // above 2 and leave that slot in place.
    let null = opened >= 0 ? fcntl(opened, F_DUPFD_CLOEXEC, 3) : -1
    if opened > 2 { close(opened) }
    defer { if null >= 0 { close(null) } }
    let stderrOpen = fcntl(2, F_GETFD) >= 0
    guard saved >= 0, null >= 0, dup2(null, 0) >= 0, quiet || stderrOpen || dup2(null, 2) >= 0,
      dup2(quiet ? null : 2, 1) >= 0, !quiet || dup2(null, 2) >= 0
    else { throw HostError("Failed to prepare the standard descriptors for --output json") }
    document.withLock { $0 = saved }
  }

  /// The descriptor holding the original stdout, which no reader may take.
  static func ownsDescriptor(_ fd: Int32) -> Bool { document.withLock { $0 == fd } }

  /// Writes `value` as one compact JSON document and a newline. Outside a
  /// session (tests), it goes to the current stdout.
  static func emit(_ value: some Encodable) throws {
    let bytes = Array((try JSONOutput.render(value, pretty: false) + "\n").utf8)
    try AtomicFile.writeAll(document.withLock { $0 } ?? 1, bytes, "the --output json document")
  }
}

/// `run(body)` with the result discarded in text mode (the body renders text
/// itself). In machine mode the result is the success document, and a
/// failure is the error document before the usual stderr line and exit status.
func run<Command: MachineCommand, Result: Encodable>(
  _ global: GlobalOptions, _ command: Command.Type, _ body: () throws -> Result
) throws {
  guard global.output == .json else { return try run { _ = try body() } }
  try run {
    let result: Result
    do {
      result = try body()
    } catch {
      if !(error is ExitCode) {
        try? MachineSession.emit(
          MachineEnvelope(command: command.machineName, ok: false, body: MachineFailure(error)))
      }
      throw error
    }
    try MachineSession.emit(MachineEnvelope(command: command.machineName, ok: true, body: result))
  }
}

/// `--output json` given to a command that does not implement it. The
/// document names the full command path (`secrets list`, or `iso` alone).
func rejectUnsupportedMachineOutput(_ command: any ParsableCommand) throws {
  let path = commandPath(type(of: command), under: IsoCommand.self) ?? []
  let name = path.isEmpty ? "iso" : path.joined(separator: " ")
  let failure = MachineFailure(
    code: .unsupportedMachineOutput,
    message: "`\(path.isEmpty ? "iso" : "iso " + name)` does not support --output json",
    details: nil)
  try MachineSession.emit(MachineEnvelope(command: name, ok: false, body: failure))
  throw ArgumentParser.ValidationError(failure.message)
}

/// Subcommand names from `root` down to `target`; empty for the root itself.
func commandPath(_ target: any ParsableCommand.Type, under root: any ParsableCommand.Type)
  -> [String]?
{
  if ObjectIdentifier(target) == ObjectIdentifier(root) { return [] }
  for child in root.configuration.subcommands {
    if let rest = commandPath(target, under: child) { return [child._commandName] + rest }
  }
  return nil
}
