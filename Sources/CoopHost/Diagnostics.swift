import CoopCore
import Foundation

/// Diagnostics on stderr (never stdout, which carries command output and
/// `--json`). Format follows the Rust host's `tracing` output:
/// `<RFC 3339 UTC timestamp>  WARN coop: <message>`.
public struct Diagnostics: Sendable {
  public enum Level: Int, Sendable, Comparable {
    case error = -1
    case warn = 0
    case info, debug, trace
    public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    var label: String {
      switch self {
      case .error: "ERROR"
      case .warn: " WARN"
      case .info: " INFO"
      case .debug: "DEBUG"
      case .trace: "TRACE"
      }
    }
  }

  public let threshold: Level
  let sink: @Sendable (String) -> Void

  /// `-v` enables debug, `-vv` trace; info is the default.
  public init(verbosity: Int, sink: @escaping @Sendable (String) -> Void = Self.standardError) {
    threshold = verbosity >= 2 ? .trace : verbosity == 1 ? .debug : .info
    self.sink = sink
  }

  public static let standardError: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  public func log(_ level: Level, _ message: @autoclosure () -> String) {
    guard level <= threshold else { return }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Messages can embed guest-authored text (hook and transfer errors).
    sink("\(formatter.string(from: Date())) \(level.label) coop: \(neutralizeControls(message()))")
  }

  public func warn(_ message: @autoclosure () -> String) { log(.warn, message()) }
  public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
}
