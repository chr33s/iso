import Foundation

/// An optional member written as `null` instead of being omitted; it reads
/// back from `null` or an absent key.
@propertyWrapper
package struct EncodedNull<Value> {
  package var wrappedValue: Value?
  package init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
}

extension EncodedNull: Sendable where Value: Sendable {}
extension EncodedNull: Equatable where Value: Equatable {}

extension EncodedNull: Encodable where Value: Encodable {
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
  }
}

extension EncodedNull: Decodable where Value: Decodable {
  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
  }
}

extension KeyedDecodingContainer {
  /// An absent key reads as nil, as it would for a plain optional.
  package func decode<Value: Decodable>(_ type: EncodedNull<Value>.Type, forKey key: Key) throws
    -> EncodedNull<Value>
  {
    try decodeIfPresent(type, forKey: key) ?? EncodedNull(wrappedValue: nil)
  }
}
