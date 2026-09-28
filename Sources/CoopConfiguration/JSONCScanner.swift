// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

/// The one JSONC comment scanner, shared by host configuration and
/// devcontainer input (S-06). It never interprets JSON values: it replaces
/// comment bytes with spaces (keeping line breaks, so diagnostics keep their
/// line numbers) and leaves syntax and value decoding to later stages.
public enum JSONCSyntaxPolicy: Sendable {
  /// Host configuration: RFC 8259 JSON plus `//` and non-nesting `/* */`
  /// comments. An unterminated block comment is an error; trailing commas
  /// are left in place for the structural preflight to reject.
  case configuration
  /// `devcontainer.json`: comments and trailing commas, as the devcontainer
  /// specification allows. A trailing comma is blanked; an unterminated block
  /// comment runs to end of input (the baseline Rust scanner's behavior).
  case devcontainer
}

public struct JSONCScanError: Error, Equatable, Sendable, CustomStringConvertible {
  public enum Kind: Sendable, Equatable {
    case invalidUTF8
    case unterminatedBlockComment
  }
  public let kind: Kind
  public let location: SourceLocation?

  public var description: String {
    switch kind {
    case .invalidUTF8: "configuration is not valid UTF-8"
    case .unterminatedBlockComment:
      "unterminated block comment" + (location.map { " starting at \($0)" } ?? "")
    }
  }
}

public struct SourceLocation: Hashable, Sendable, CustomStringConvertible {
  public let line: Int
  public let column: Int
  public var description: String { "line \(line), column \(column)" }

  /// 1-based line and byte column of `offset` within `bytes`.
  static func of(offset: Int, in bytes: [UInt8]) -> SourceLocation {
    var line = 1
    var lineStart = 0
    for index in 0..<min(offset, bytes.count) where bytes[index] == UInt8(ascii: "\n") {
      line += 1
      lineStart = index + 1
    }
    return SourceLocation(line: line, column: offset - lineStart + 1)
  }
}

public enum JSONCScanner {
  private enum State {
    case normal, string, escape, lineComment, blockComment, blockCommentStar
  }

  private static let slash = UInt8(ascii: "/")
  private static let star = UInt8(ascii: "*")
  private static let quote = UInt8(ascii: "\"")
  private static let backslash = UInt8(ascii: "\\")
  private static let newline = UInt8(ascii: "\n")
  private static let carriageReturn = UInt8(ascii: "\r")
  private static let space = UInt8(ascii: " ")
  private static let comma = UInt8(ascii: ",")

  /// Returns `input` with comments (and, for `.devcontainer`, trailing
  /// commas) replaced by spaces. Output length always equals input length.
  public static func strip(_ input: [UInt8], policy: JSONCSyntaxPolicy) throws(JSONCScanError)
    -> [UInt8]
  {
    guard String(validating: input, as: UTF8.self) != nil else {
      throw JSONCScanError(kind: .invalidUTF8, location: nil)
    }
    var output = input
    var state = State.normal
    var blockStart = 0
    // Every comma since the last value token: a run like `, ,]` is all
    // trailing, as in the baseline scanner.
    var pendingCommas: [Int] = []
    var index = 0
    func blank(_ i: Int) {
      if output[i] != newline && output[i] != carriageReturn { output[i] = space }
    }
    while index < input.count {
      let byte = input[index]
      switch state {
      case .normal:
        if byte == slash, index + 1 < input.count, input[index + 1] == slash {
          blank(index)
          blank(index + 1)
          index += 1
          state = .lineComment
        } else if byte == slash, index + 1 < input.count, input[index + 1] == star {
          blank(index)
          blank(index + 1)
          blockStart = index
          index += 1
          state = .blockComment
        } else if policy == .devcontainer, byte == comma {
          pendingCommas.append(index)
        } else if byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") {
          for comma in pendingCommas { output[comma] = space }
          pendingCommas.removeAll()
        } else if !isJSONWhitespace(byte) {
          pendingCommas.removeAll()
          if byte == quote { state = .string }
        }
      case .string:
        if byte == backslash {
          state = .escape
        } else if byte == quote {
          state = .normal
        }
      case .escape:
        state = .string
      case .lineComment:
        if byte == newline {
          state = .normal
        } else {
          blank(index)
        }
      case .blockComment:
        blank(index)
        if byte == star { state = .blockCommentStar }
      case .blockCommentStar:
        blank(index)
        if byte == slash {
          state = .normal
        } else if byte != star {
          state = .blockComment
        }
      }
      index += 1
    }
    if (state == .blockComment || state == .blockCommentStar) && policy == .configuration {
      throw JSONCScanError(
        kind: .unterminatedBlockComment,
        location: SourceLocation.of(offset: blockStart, in: input))
    }
    return output
  }

  static func isJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == newline
      || byte == carriageReturn
  }
}
