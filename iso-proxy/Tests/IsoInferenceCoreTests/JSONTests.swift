import Testing

@testable import IsoInferenceCore

private let limits = JSONParser.Limits(maxBytes: 1 << 20, maxDepth: 8)

@Test func parsesAndReserializesWithoutReordering() throws {
  let text = #"{"b":1,"a":[true,false,null,"x\né😀"],"n":-1.5e3,"z":{}}"#
  let value = try JSONParser.parse(Array(text.utf8), limits: limits)
  #expect(value["n"]?.number?.text == "-1.5e3")
  #expect(value.object?.keys == ["b", "a", "n", "z"])
  #expect(value["a"]?.array?[3].string == "x\né😀")
  #expect(value.serializedString == #"{"b":1,"a":[true,false,null,"x\né😀"],"n":-1.5e3,"z":{}}"#)
  #expect(try JSONParser.parse(value.serialized, limits: limits) == value)
}

@Test func rejectsHostileDocuments() {
  let cases: [(String, JSONParseError)] = [
    (#"{"a":1,"a":2}"#, .duplicateKey),
    (#"{"a":{"b":1,"b":2}}"#, .duplicateKey),
    (#"[[[[[[[[[1]]]]]]]]]"#, .tooDeep),
    (#"{"a":1} x"#, .trailingData),
    (#"{"a":"\ud800"}"#, .invalidUTF8),
    (#"{"a":"\udc00"}"#, .invalidUTF8),
    (#"{"a":01}"#, .syntax),
    (#"{"a":1.}"#, .syntax),
    (#"{"a":"tab\#tinside"}"#, .syntax),
    (#"{'a':1}"#, .syntax),
    ("", .syntax),
  ]
  for (text, expected) in cases {
    #expect(throws: expected) { try JSONParser.parse(Array(text.utf8), limits: limits) }
  }
  #expect(throws: JSONParseError.invalidUTF8) {
    try JSONParser.parse([0x22, 0xFF, 0x22], limits: limits)
  }
  #expect(throws: JSONParseError.tooLarge) {
    try JSONParser.parse(
      Array(repeating: 0x20, count: 11), limits: .init(maxBytes: 10, maxDepth: 4))
  }
}

@Test func escapesControlCharactersWhenSerializing() {
  let value = JSON.string("a\u{01}\"\\\r\t")
  #expect(value.serializedString == #""a\u0001\"\\\r\t""#)
}

@Test func integersNeedIntegerSyntax() throws {
  #expect(try json("-0").number?.int64 == 0)
  #expect(try json("9223372036854775807").number?.int64 == .max)
  for text in ["0.99999999999999999999", "1e-400", "1.0", "1e3", "9223372036854775808"] {
    #expect(try json(text).number?.int64 == nil, "\(text)")
  }
}

@Test func valueCountIsBounded() throws {
  let limits = JSONParser.Limits(maxBytes: 1 << 20, maxDepth: 8, maxValues: 10)
  _ = try JSONParser.parse(Array("[1,2,3,4,5,6,7,8,9]".utf8), limits: limits)
  #expect(throws: JSONParseError.tooManyValues) {
    try JSONParser.parse(Array("[1,2,3,4,5,6,7,8,9,10]".utf8), limits: limits)
  }
  #expect(throws: JSONParseError.tooManyValues) {
    try JSONParser.parse(Array(#"{"a":{"b":{"c":{"d":{"e":[1,2,3,4,5]}}}}}"#.utf8), limits: limits)
  }
}
