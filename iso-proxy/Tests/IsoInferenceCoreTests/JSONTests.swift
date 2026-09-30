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

@Test func integralNumbersReadAsIntegers() throws {
  #expect(try json("1.0").number?.int64 == 1)
  #expect(try json("1e3").number?.int64 == 1000)
  #expect(try json("1.5").number?.int64 == nil)
  #expect(try json("123456789012345678901234567890").number?.int64 == nil)
}
