import Foundation
import IsoConfiguration

/// The full configuration pipeline on in-memory input: JSONC scan,
/// duplicate/limit preflight, Foundation decoding, domain validation, and a
/// structural write/read round trip. No filesystem, environment, network or
/// credential command is touched.
public enum ConfigLoadHarness {
  static let environment = ConfigEnvironment(home: "/fuzz/home", variables: [:])
  static let canary = "CANARYSECRET"

  public static func run(_ bytes: [UInt8]) {
    for format in [ConfigFormat.jsonc, .json] {
      document(bytes, format: format)
    }
    secretFields(bytes)
  }

  static func document(_ bytes: [UInt8], format: ConfigFormat) {
    guard
      let value = try? ConfigLoader.parse(
        bytes, format: format, path: "fuzz", limits: .configuration)
    else {
      return
    }
    let decoded = Result { () throws(ConfigError) in
      try ConfigLoader.decode(value, path: "fuzz", environment: environment)
    }
    guard let encoded = try? ConfigEditor.encode(value, path: "fuzz") else {
      require(false, "decoded values re-encode")
      return
    }
    let reread: JSONValue
    do {
      reread = try ConfigLoader.parse(encoded, format: .json, path: "fuzz", limits: .configuration)
    } catch {
      // Encoding may lengthen escapes past a limit; nothing else may fail.
      if case .preflight(_, let failure) = error {
        switch failure.kind {
        case .tooLarge, .stringTooLong, .numberTooLong: return
        default: break
        }
      }
      require(false, "encoded document re-parses")
      return
    }
    require(reread.semanticallyEquals(value), "structural round trip")
    let redecoded = Result { () throws(ConfigError) in
      try ConfigLoader.decode(reread, path: "fuzz", environment: environment)
    }
    // Encoding cannot keep a literal's spelling (`1e2` is written `100`),
    // so only an accepted document must decode identically after the trip.
    if case .success(let original) = decoded {
      guard case .success(let again) = redecoded else {
        require(false, "accepted document still accepted after round trip")
        return
      }
      require(original == again, "domain round trip")
    }
  }

  /// Arbitrary text placed in every secret-bearing field must never appear
  /// in an error, whatever else the document gets wrong.
  static func secretFields(_ bytes: [UInt8]) {
    guard bytes.count < 256 else { return }
    let secret = canary + String(decoding: bytes, as: UTF8.self)
    guard let data = try? JSONEncoder().encode(secret),
      let literal = String(data: data, encoding: .utf8)
    else {
      return
    }
    let documents = [
      #"{"proxy": {"anthropic": {"credential": \#(literal)}}}"#,
      #"{"proxy": {"openai": {"credential": \#(literal), "auth": 1}}}"#,
      #"{"claude": {"api_key": \#(literal), "plugins": 1}}"#,
      #"{"github": {"pat": {"o/r": {"token": \#(literal)}}, "skip": [1]}}"#,
      #"{"codex": {"mcp_servers": {"s": {"type": "http", "url": "::", "headers": {"A": \#(literal)}}}}}"#,
      #"{"claude": {"local_model": {"host_url": "ftp://x", "model": "m", "auth_token": \#(literal)}}}"#,
      #"{"a": \#(literal), "a": \#(literal)}"#,
    ]
    for document in documents {
      do {
        _ = try ConfigLoader.decode(
          try ConfigLoader.parse(
            Array(document.utf8), format: .jsonc, path: "fuzz", limits: .configuration),
          path: "fuzz", environment: environment)
      } catch {
        require(!error.description.contains(canary), "secret-bearing value absent from errors")
      }
    }
  }
}
