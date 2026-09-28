import CoopConfiguration

/// The production JSONC scanner under both syntax policies.
public enum JSONCToJSONHarness {
  public static func run(_ bytes: [UInt8]) {
    for policy in [JSONCSyntaxPolicy.configuration, .devcontainer] {
      let stripped: [UInt8]
      do {
        stripped = try JSONCScanner.strip(bytes, policy: policy)
      } catch {
        continue
      }
      require(stripped.count == bytes.count, "length preserved")
      require(
        zip(bytes, stripped).allSatisfy { $0 == $1 || ($1 == 0x20 && $0 != 0x0A && $0 != 0x0D) },
        "only non-newline bytes are blanked")
      require((try? JSONCScanner.strip(stripped, policy: policy)) == stripped, "idempotent")
    }
    // Configuration and devcontainer policies differ only in trailing commas
    // and unterminated block comments.
    if let strict = try? JSONCScanner.strip(bytes, policy: .configuration) {
      let lenient = try? JSONCScanner.strip(bytes, policy: .devcontainer)
      require(lenient != nil, "devcontainer accepts what configuration accepts")
      require(
        zip(strict, lenient!).allSatisfy { $0 == $1 || ($0 == 0x2C && $1 == 0x20) },
        "policies differ only by blanked commas")
    }
  }
}
