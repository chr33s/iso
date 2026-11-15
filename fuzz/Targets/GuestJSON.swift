import IsoHost

/// The order-preserving JSON parser for guest-authored settings and import
/// snapshots (`OrderedJSON`): the host parses them, merges keys and writes them
/// back to the guest.
public enum GuestJSONHarness {
  static let canary = "CANARYSECRET"

  public static func run(_ bytes: [UInt8]) {
    let text = String(decoding: bytes, as: UTF8.self)
    if let value = try? OrderedJSON.parse(text) {
      require(depth(value) <= OrderedJSON.maxDepth, "nesting within the depth cap")
      let compact = value.compact
      guard let reread = try? OrderedJSON.parse(compact) else {
        require(false, "compact output re-parses")
        return
      }
      require(same(reread, value), "compact round trip")
      require(reread.compact == compact, "compact printing is canonical")
      require(
        (try? OrderedJSON.parse(value.pretty)).map { same($0, value) } == true, "pretty round trip")
    }
    errorsOmitValues(text)
  }

  /// Equal values with keys in the same order. A whole-valued double prints
  /// without a fraction (`1E10` as `10000000000`) and re-parses as an integer,
  /// so numbers compare by value across classes.
  static func same(_ a: OrderedJSON, _ b: OrderedJSON) -> Bool {
    switch (a, b) {
    case (.array(let x), .array(let y)):
      return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
    case (.object(let x), .object(let y)):
      return x.pairs.count == y.pairs.count
        && zip(x.pairs, y.pairs).allSatisfy { $0.0 == $1.0 && same($0.1, $1.1) }
    case (.double(let x), .int(let y)), (.int(let y), .double(let x)):
      return x == Double(y) && Int64(exactly: x) == y
    case (.double(let x), .uint(let y)), (.uint(let y), .double(let x)):
      return x == Double(y) && UInt64(exactly: x) == y
    default:
      return a == b
    }
  }

  /// Container levels; a scalar is 0, so a document of 128 nested arrays is 128.
  static func depth(_ value: OrderedJSON) -> Int {
    switch value {
    case .array(let elements): 1 + (elements.map(depth).max() ?? 0)
    case .object(let members): 1 + (members.pairs.map { depth($0.1) }.max() ?? 0)
    default: 0
    }
  }

  /// A rejected document's error names a position, never the guest's text.
  static func errorsOmitValues(_ text: String) {
    guard text.utf8.count < 256, !text.contains(canary) else { return }
    for document in [
      #"{"token": "\#(canary)"# + text, #"{"\#(canary)": "# + text, "[\"\(canary)\", " + text,
    ] {
      do {
        _ = try OrderedJSON.parse(document)
      } catch {
        require(!error.description.contains(canary), "guest value absent from errors")
      }
    }
  }
}
