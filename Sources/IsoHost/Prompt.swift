// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoCore

/// Interactive y/N prompt for `iso update` and `iso uninstall`: the
/// question goes to stderr, the answer comes from stdin. A non-terminal
/// stdin answers no without reading, so non-interactive callers must opt in
/// with their own `--yes`.
public enum Prompt {
  public static var stdinIsTerminal: Bool { isatty(0) == 1 }

  public static let confirm: @Sendable (String) throws -> Bool = { prompt in
    guard stdinIsTerminal else { return false }
    FileHandle.standardError.write(Data("\(prompt) [y/N] ".utf8))
    let reply = readLine(strippingNewline: true) ?? ""
    return isYes(reply)
  }

  static func isYes(_ reply: String) -> Bool {
    ["y", "yes"].contains(reply.trimmingUnicodeWhitespace().lowercased())
  }
}
