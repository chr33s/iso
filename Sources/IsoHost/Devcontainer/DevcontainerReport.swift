// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import IsoCore

/// Loud per-key translation report (Rust `devcontainer::Report`).
package struct DevcontainerReport: Sendable, Equatable, Encodable {
  package enum Status: String, Sendable, Equatable, Encodable {
    case applied
    case overridden
    case unsupported
    case invalid
  }

  package enum Source: String, Sendable, Equatable, Encodable {
    case cli
    case devcontainer

    var label: String {
      switch self {
      case .cli: "CLI"
      case .devcontainer: "devcontainer.json"
      }
    }
  }

  /// `key` is the dotted devcontainer path; `value` the effective value.
  package struct Entry: Sendable, Equatable, Encodable {
    package let key: String
    package let status: Status
    package let source: Source
    package let value: String
    package let note: String
  }

  package var entries: [Entry] = []
  package var sourcePath: String?
  /// Discovered files that lost to the winner (workspace first).
  package var ignoredPaths: [String] = []

  package init() {}

  package mutating func push(
    _ key: String, _ status: Status, _ source: Source, _ value: String, _ note: String = ""
  ) {
    entries.append(Entry(key: key, status: status, source: source, value: value, note: note))
  }

  /// Plain-text table for stderr. Column widths are byte lengths and
  /// padding counts characters, as the baseline's `{:<w$}` did. Cells come
  /// from an untrusted file, so control characters other than newline and
  /// tab, and format characters, are shown as `?`.
  package func render() -> String {
    var out = ""
    if let sourcePath { out += "devcontainer.json: \(displaySafe(sourcePath))\n" }
    for ignored in ignoredPaths {
      out += "  ignored: \(displaySafe(ignored)) (workspace's takes precedence)\n"
    }
    guard !entries.isEmpty else {
      out += "  (no recognised keys)\n"
      return out
    }
    let headers = ["Key", "Status", "Source", "Value", "Note"]
    let rows = entries.map {
      [
        displaySafe($0.key), $0.status.rawValue, $0.source.label, displaySafe($0.value),
        displaySafe($0.note),
      ]
    }
    var widths = headers.map(\.utf8.count)
    for row in rows {
      for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.utf8.count) }
    }
    func line(_ cells: [String]) {
      out += cells.enumerated().map { index, cell in
        let count = cell.unicodeScalars.count
        return count >= widths[index]
          ? cell : cell + String(repeating: " ", count: widths[index] - count)
      }.joined(separator: "  ")
      out += "\n"
    }
    line(headers)
    line(widths.map { String(repeating: "-", count: $0) })
    for row in rows { line(row) }
    return out
  }

  enum CodingKeys: String, CodingKey {
    case entries
    case sourcePath = "source_path"
    case ignoredPaths = "ignored_paths"
  }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(entries, forKey: .entries)
    try values.encode(sourcePath, forKey: .sourcePath)
    try values.encode(ignoredPaths, forKey: .ignoredPaths)
  }

}

/// Replace control (other than newline and tab) and format characters so
/// file content cannot drive the terminal; unlike `sanitizeForDisplay` it
/// keeps surrounding whitespace.
func displaySafe(_ text: String) -> String {
  var out = String.UnicodeScalarView()
  for scalar in text.unicodeScalars {
    let category = scalar.properties.generalCategory
    let unsafe = (category == .control && scalar != "\n" && scalar != "\t") || category == .format
    out.append(unsafe ? "?" : scalar)
  }
  return String(out)
}
