import Foundation
import Testing

/// Compare the complete JSON value while ignoring object order and whitespace.
func canonicalJSON(_ text: String?) throws -> Data {
  let text = try #require(text)
  let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
  return try JSONSerialization.data(
    withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}

func jsonObject(_ text: String) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
