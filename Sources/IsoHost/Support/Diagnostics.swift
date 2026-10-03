// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoCore

/// Diagnostics on stderr (never stdout, which carries command output and
/// `--json`). Each entry includes its UTC timestamp and severity:
/// `<RFC 3339 UTC timestamp>  WARN iso: <message>`.
package struct Diagnostics: Sendable {
  package enum Level: Int, Sendable, Comparable {
    case error = -1
    case warn = 0
    case info, debug, trace
    package static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
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

  package let threshold: Level
  let sink: @Sendable (String) -> Void

  /// `-v` enables debug, `-vv` trace; info is the default.
  package init(verbosity: Int, sink: @escaping @Sendable (String) -> Void = Self.standardError) {
    threshold = verbosity >= 2 ? .trace : verbosity == 1 ? .debug : .info
    self.sink = sink
  }

  package static let standardError: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  package func log(_ level: Level, _ message: @autoclosure () -> String) {
    guard level <= threshold else { return }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Messages can embed guest-authored text (hook and transfer errors).
    sink("\(formatter.string(from: Date())) \(level.label) iso: \(neutralizeControls(message()))")
  }

  package func warn(_ message: @autoclosure () -> String) { log(.warn, message()) }
  package func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
}
