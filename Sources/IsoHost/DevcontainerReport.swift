import IsoCore

/// Loud per-key translation report (Rust `devcontainer::Report`).
public struct DevcontainerReport: Sendable, Equatable {
  public enum Status: String, Sendable, Equatable {
    /// The devcontainer value took effect.
    case applied
    /// A CLI flag or existing config won.
    case overridden
    /// Not supported by iso; ignored.
    case unsupported
    /// Could not be parsed; ignored.
    case invalid
  }

  public enum Source: String, Sendable, Equatable {
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
  public struct Entry: Sendable, Equatable {
    public let key: String
    public let status: Status
    public let source: Source
    public let value: String
    public let note: String
  }

  public var entries: [Entry] = []
  public var sourcePath: String?
  /// Discovered files that lost to the winner (workspace first).
  public var ignoredPaths: [String] = []

  public init() {}

  public mutating func push(
    _ key: String, _ status: Status, _ source: Source, _ value: String, _ note: String = ""
  ) {
    entries.append(Entry(key: key, status: status, source: source, value: value, note: note))
  }

  /// Plain-text table for stderr. Column widths are byte lengths and
  /// padding counts characters, as the baseline's `{:<w$}` did. Cells come
  /// from an untrusted file, so control characters other than newline and
  /// tab, and format characters, are shown as `?`.
  public func render() -> String {
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

  /// serde shape: `{entries, source_path, ignored_paths}`.
  public var json: OutputJSON {
    .object([
      (
        "entries",
        .array(
          entries.map {
            .object([
              ("key", .string($0.key)), ("status", .string($0.status.rawValue)),
              ("source", .string($0.source.rawValue)), ("value", .string($0.value)),
              ("note", .string($0.note)),
            ])
          })
      ),
      ("source_path", .optional(sourcePath)),
      ("ignored_paths", .array(ignoredPaths.map(OutputJSON.string))),
    ])
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
