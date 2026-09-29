/// Retains the raw target. No Foundation URL parsing or normalization is used
/// before operation authorization or when preserving the query.
public struct RequestTarget: Sendable {
  public let raw: String
  public let path: String

  public init(_ raw: String) throws {
    let bytes = Array(raw.utf8)
    guard bytes.first == 47, !raw.hasPrefix("//"),
      bytes.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 35 && $0 != 92 })
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

  private static func hex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
  }
}
