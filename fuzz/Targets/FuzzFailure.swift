/// A violated harness property. Traps so libFuzzer records the input as a
/// crash; ordinary replay tests see the same trap. Messages carry no input.
func require(_ condition: @autoclosure () -> Bool, _ property: StaticString) {
  if !condition() { fatalError("fuzz property violated: \(property)") }
}
