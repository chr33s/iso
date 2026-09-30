/// A violated harness property. Traps so libFuzzer records the input as a
/// crash; the corpus replay test sees the same trap. Messages carry no input.
func require(_ condition: @autoclosure () -> Bool, _ property: StaticString) {
  if !condition() { fatalError("fuzz property violated: \(property)") }
}
