/// Retains the raw target. No Foundation URL parsing or normalization is used
/// before operation authorization or when preserving the query.
package struct RequestTarget: Sendable {
  package let raw: String
  package let path: String

  package init(_ raw: String) throws {
    let bytes = Array(raw.utf8)
    // Only RFC 3986 path and query characters. The Foundation URL parse that
    // builds the upstream request percent-encodes any other byte, and then
    // every `%`, so the forwarded query would differ from the guest's.
    guard bytes.first == 47, !raw.hasPrefix("//"),
      bytes.allSatisfy({ $0 > 32 && $0 < 127 && !Self.outsideURI.contains($0) })
    else { throw PolicyError.invalidTarget }
    // Percent escapes must be syntactically complete. They stay encoded;
    // encoded path variants will fail exact operation matching.
    var index = 0
    while index < bytes.count {
      if bytes[index] == 37 {
        guard index + 2 < bytes.count,
          Self.hex(bytes[index + 1]), Self.hex(bytes[index + 2])
        else { throw PolicyError.invalidTarget }
        index += 3
      } else {
        index += 1
      }
    }
    self.raw = raw
    path = String(raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
  }

  /// Visible ASCII that RFC 3986 allows in neither a path nor a query.
  private static let outsideURI = Set("#\\\"<>[]^`{|}".utf8)

  private static func hex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
  }
}
