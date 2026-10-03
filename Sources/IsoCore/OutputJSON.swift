// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Dynamic JSON for documents whose keys come from configuration or guest data.
/// Owned command responses should use concrete Encodable models.
package indirect enum OutputJSON: Equatable, Sendable, Encodable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string(String)
  case array([OutputJSON])
  case object([(String, OutputJSON)])

  package static func == (a: OutputJSON, b: OutputJSON) -> Bool {
    a.compactRendered() == b.compactRendered()
  }

  package static func optional(_ value: String?) -> OutputJSON {
    value.map(OutputJSON.string) ?? .null
  }

  package func encode(to encoder: any Encoder) throws {
    switch self {
    case .object(let members):
      var container = encoder.container(keyedBy: Key.self)
      for (key, value) in members { try container.encode(value, forKey: Key(key)) }
    case .array(let values):
      var container = encoder.unkeyedContainer()
      for value in values { try container.encode(value) }
    default:
      var container = encoder.singleValueContainer()
      switch self {
      case .null: try container.encodeNil()
      case .bool(let value): try container.encode(value)
      case .int(let value): try container.encode(value)
      case .uint(let value): try container.encode(value)
      case .double(let value):
        if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
      case .string(let value): try container.encode(value)
      case .array, .object: break
      }
    }
  }

  package func rendered() -> String { encoded(pretty: true) + "\n" }
  package func compactRendered() -> String { encoded(pretty: false) }

  private func encoded(pretty: Bool) -> String {
    // Safe because this closed value tree encodes only JSON primitives, handles
    // nonfinite doubles as null, and has no user-provided Encodable callbacks.
    try! JSONOutput.render(self, pretty: pretty)
  }

  package static func floatText(_ value: Double) -> String { String(value) }

  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
  }
}

/// One deterministic encoding policy for iso-owned JSON documents.
package enum JSONOutput {
  package static func render(_ value: some Encodable, pretty: Bool = true) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}
