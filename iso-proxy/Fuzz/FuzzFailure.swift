/// A violated harness property. Traps so libFuzzer records the input as a
/// crash; ordinary replay tests see the same trap. Messages carry no input.
func require(_ condition: @autoclosure () -> Bool, _ property: StaticString) {
  if !condition() { fatalError("fuzz property violated: \(property)") }
}

/// Guest header lines (`name:value`, one per line) as the proxy sees them.
func headerLines(_ bytes: [UInt8]) -> [(String, String)] {
  String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
    .compactMap { line -> (String, String)? in
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    }
}
