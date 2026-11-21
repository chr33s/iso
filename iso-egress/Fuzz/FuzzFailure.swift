/// A violated harness property. Traps so libFuzzer records the input as a
/// crash; ordinary replay tests see the same trap. Messages carry no input.
func require(_ condition: @autoclosure () -> Bool, _ property: StaticString) {
  if !condition() { fatalError("fuzz property violated: \(property)") }
}

let terminator: [UInt8] = [13, 10, 13, 10]

/// The end of the first `\r\n\r\n` in `bytes`, by plain search.
func firstTerminatorEnd(_ bytes: [UInt8]) -> Int? {
  guard bytes.count >= 4 else { return nil }
  for index in 0...(bytes.count - 4) where Array(bytes[index..<(index + 4)]) == terminator {
    return index + 4
  }
  return nil
}
