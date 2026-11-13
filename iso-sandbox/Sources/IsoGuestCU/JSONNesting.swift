/// A bound on JSON nesting, checked before a recursive parser sees the bytes: a few hundred
/// nested objects overflow a 512 KiB connection thread's stack, so deeper input is refused unparsed.
package enum JSONNesting {
  /// Whether `bytes` open more than `limit` objects or arrays at once. Brackets inside strings
  /// do not count.
  package static func exceeds(_ bytes: some Sequence<UInt8>, limit: Int) -> Bool {
    var depth = 0
    var inString = false
    var escaped = false
    for byte in bytes {
      if inString {
        if escaped {
          escaped = false
        } else if byte == UInt8(ascii: "\\") {
          escaped = true
        } else if byte == UInt8(ascii: "\"") {
          inString = false
        }
        continue
      }
      switch byte {
      case UInt8(ascii: "\""):
        inString = true
      case UInt8(ascii: "{"), UInt8(ascii: "["):
        depth += 1
        if depth > limit { return true }
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        depth = max(0, depth - 1)
      default:
        break
      }
    }
    return false
  }
}
