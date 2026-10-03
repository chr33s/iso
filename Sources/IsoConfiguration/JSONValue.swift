import Foundation

/// Exact JSON number. Integer literals keep their exact value; literals
/// written with a fraction or exponent stay `decimal` even when integral, so
/// a typed integer field can reject `2.0` as the baseline did.
package enum JSONNumber: Hashable, Sendable, CustomStringConvertible {
  case integer(Int64)
  case unsigned(UInt64)
  case decimal(Decimal)

  package var description: String {
    switch self {
    case .integer(let value): String(value)
    case .unsigned(let value): String(value)
    case .decimal(let value): value.description
    }
  }
}

/// Lossless structural form of a decoded document: dynamic maps, unmodeled
/// keys and structural edits operate on this, never on typed models.
package enum JSONValue: Hashable, Sendable {
  case null
  case bool(Bool)
  case number(JSONNumber)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  package var typeName: String {
    switch self {
    case .null: "null"
    case .bool: "boolean"
    case .number: "number"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    }
  }

  package subscript(key: String) -> JSONValue? {
    if case .object(let members) = self { members[key] } else { nil }
  }
}

struct DynamicKey: CodingKey {
  let stringValue: String
  let intValue: Int?
  init(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }
  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

/// Carries preflight number-literal kinds into `JSONValue.init(from:)`.
final class FractionalPaths: Sendable {
  let paths: Set<[JSONPathComponent]>
  init(_ paths: Set<[JSONPathComponent]>) { self.paths = paths }
  static let userInfoKey = CodingUserInfoKey(rawValue: "iso.fractionalNumberPaths")!
}

extension JSONValue: Codable {
  package init(from decoder: any Decoder) throws {
    if var array = try? decoder.unkeyedContainer() {
      var elements: [JSONValue] = []
      while !array.isAtEnd { elements.append(try array.decode(JSONValue.self)) }
      self = .array(elements)
      return
    }
    if let object = try? decoder.container(keyedBy: DynamicKey.self) {
      var members: [String: JSONValue] = [:]
      for key in object.allKeys {
        members[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
      }
      self = .object(members)
      return
    }
    let single = try decoder.singleValueContainer()
    if single.decodeNil() {
      self = .null
    } else if let value = try? single.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? single.decode(String.self) {
      self = .string(value)
    } else {
      self = .number(
        try Self.decodeNumber(single, path: decoder.codingPath, userInfo: decoder.userInfo))
    }
  }

  private static func decodeNumber(
    _ single: any SingleValueDecodingContainer, path: [any CodingKey],
    userInfo: [CodingUserInfoKey: Any]
  ) throws -> JSONNumber {
    let fractional = (userInfo[FractionalPaths.userInfoKey] as? FractionalPaths)?.paths ?? []
    let components = path.map { key -> JSONPathComponent in
      key.intValue.map(JSONPathComponent.index) ?? .key(key.stringValue)
    }
    if !fractional.contains(components) {
      if let value = try? single.decode(Int64.self) { return .integer(value) }
      if let value = try? single.decode(UInt64.self) { return .unsigned(value) }
    }
    return .decimal(try single.decode(Decimal.self))
  }

  package func encode(to encoder: any Encoder) throws {
    switch self {
    case .null:
      var single = encoder.singleValueContainer()
      try single.encodeNil()
    case .bool(let value):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .string(let value):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .number(.integer(let value)):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .number(.unsigned(let value)):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .number(.decimal(let value)):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .array(let elements):
      var array = encoder.unkeyedContainer()
      for element in elements { try array.encode(element) }
    case .object(let members):
      var object = encoder.container(keyedBy: DynamicKey.self)
      for (key, value) in members { try object.encode(value, forKey: DynamicKey(stringValue: key)) }
    }
  }
}
