// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore

/// The subset of `devcontainer.json` iso reads, decoded with the baseline's
/// serde rules: missing and `null` optional keys are absent, a repeated
/// modeled key is an error, unmodeled keys keep document order (a repeated
/// one keeps its first position and last value), and `features` /
/// `containerEnv` are ordered by key bytes with the last duplicate winning.
struct RawDevcontainer: Sendable {
  var name: String?
  var image: DevcontainerJSON?
  var build: DevcontainerJSON?
  var dockerComposeFile: DevcontainerJSON?
  var features: [(key: String, value: DevcontainerJSON)]?
  var forwardPorts: [DevcontainerJSON]?
  var containerEnv: [(key: String, value: String)]?
  var remoteUser: String?
  var postStartCommand: DevcontainerJSON?
  var mounts: [DevcontainerJSON]?
  var hostRequirements: RawHostRequirements?
  var customizations: DevcontainerJSON?
  var extras: [(key: String, value: DevcontainerJSON)] = []
}

struct RawHostRequirements: Sendable {
  var cpus: UInt32?
  var memory: MemorySpec?
  var storage: MemorySpec?
  var extras: [(key: String, value: DevcontainerJSON)] = []
}

/// Keys merged as `serde_json::Map` (`IndexMap`) merges them.
func mergedMembers(_ members: [DevcontainerJSON.Member]) -> [(key: String, value: DevcontainerJSON)]
{
  var out: [(key: String, value: DevcontainerJSON)] = []
  for member in members {
    if let index = out.firstIndex(where: { $0.key == member.key }) {
      out[index].value = member.value
    } else {
      out.append((member.key, member.value))
    }
  }
  return out
}

/// Keys merged into a `BTreeMap`: byte order, last duplicate wins.
func sortedMembers<T>(_ pairs: [(key: String, value: T)]) -> [(key: String, value: T)] {
  var out: [(key: String, value: T)] = []
  for pair in pairs {
    if let index = out.firstIndex(where: { $0.key == pair.key }) {
      out[index].value = pair.value
    } else {
      out.append(pair)
    }
  }
  return out.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
}

struct DevcontainerDecoder {
  let source: DevcontainerSource

  func decode(_ root: DevcontainerJSON) throws(DevcontainerJSONError) -> RawDevcontainer {
    guard case .object(let members) = root.value else {
      throw source.invalidType(root, expected: "struct RawDevcontainer")
    }
    var raw = RawDevcontainer()
    var seen: Set<String> = []
    var extras: [DevcontainerJSON.Member] = []
    for member in members {
      let known = [
        "name", "image", "build", "dockerComposeFile", "features", "forwardPorts", "containerEnv",
        "remoteUser", "postStartCommand", "mounts", "hostRequirements", "customizations",
      ]
      guard known.contains(member.key) else {
        extras.append(member)
        continue
      }
      guard seen.insert(member.key).inserted else {
        throw source.error("duplicate field `\(member.key)`", consumed: member.keyEnd)
      }
      let value = member.value
      switch member.key {
      case "name": raw.name = try optionalString(value)
      case "image": raw.image = value.isNull ? nil : value
      case "build": raw.build = value.isNull ? nil : value
      case "dockerComposeFile": raw.dockerComposeFile = value.isNull ? nil : value
      case "postStartCommand": raw.postStartCommand = value.isNull ? nil : value
      case "customizations": raw.customizations = value.isNull ? nil : value
      case "remoteUser": raw.remoteUser = try optionalString(value)
      case "features":
        guard !value.isNull else { break }
        guard case .object(let entries) = value.value else {
          throw source.invalidType(value, expected: "a map")
        }
        raw.features = sortedMembers(entries.map { ($0.key, $0.value) })
      case "containerEnv":
        guard !value.isNull else { break }
        guard case .object(let entries) = value.value else {
          throw source.invalidType(value, expected: "a map")
        }
        var pairs: [(key: String, value: String)] = []
        for entry in entries {
          guard let text = entry.value.string else {
            throw source.invalidType(entry.value, expected: "a string")
          }
          pairs.append((entry.key, text))
        }
        raw.containerEnv = sortedMembers(pairs)
      case "forwardPorts": raw.forwardPorts = try optionalSequence(value)
      case "mounts": raw.mounts = try optionalSequence(value)
      case "hostRequirements":
        guard !value.isNull else { break }
        raw.hostRequirements = try hostRequirements(value)
      default: break
      }
    }
    raw.extras = mergedMembers(extras)
    return raw
  }

  func optionalString(_ value: DevcontainerJSON) throws(DevcontainerJSONError) -> String? {
    if value.isNull { return nil }
    guard let text = value.string else { throw source.invalidType(value, expected: "a string") }
    return text
  }

  func optionalSequence(_ value: DevcontainerJSON) throws(DevcontainerJSONError)
    -> [DevcontainerJSON]?
  {
    if value.isNull { return nil }
    guard case .array(let elements) = value.value else {
      throw source.invalidType(value, expected: "a sequence")
    }
    return elements
  }

  func hostRequirements(_ value: DevcontainerJSON) throws(DevcontainerJSONError)
    -> RawHostRequirements
  {
    guard case .object(let members) = value.value else {
      throw source.invalidType(value, expected: "struct RawHostRequirements")
    }
    var raw = RawHostRequirements()
    var seen: Set<String> = []
    var extras: [DevcontainerJSON.Member] = []
    for member in members {
      guard ["cpus", "memory", "storage"].contains(member.key) else {
        extras.append(member)
        continue
      }
      guard seen.insert(member.key).inserted else {
        throw source.error("duplicate field `\(member.key)`", consumed: member.keyEnd)
      }
      let field = member.value
      if field.isNull { continue }
      switch member.key {
      case "cpus":
        switch field.value {
        case .unsigned(let number):
          guard let cpus = UInt32(exactly: number) else {
            throw source.invalidValue(field, expected: "u32")
          }
          raw.cpus = cpus
        case .negative: throw source.invalidValue(field, expected: "u32")
        default: throw source.invalidType(field, expected: "u32")
        }
      default:
        guard let text = field.string else {
          throw source.invalidType(field, expected: "a string")
        }
        let spec: MemorySpec
        do { spec = try MemorySpec.parse(text) } catch {
          throw source.custom(error.message, after: field)
        }
        if member.key == "memory" { raw.memory = spec } else { raw.storage = spec }
      }
    }
    raw.extras = mergedMembers(extras)
    return raw
  }
}

// MARK: - Sizes

/// A `hostRequirements` memory or storage size, stored as non-zero MiB
/// rounded up from the parsed byte count. Accepts the devcontainer spec's
/// decimal units (`KB`…`TB`, single-letter aliases), binary units
/// (`KiB`…`TiB`), `B`, and bare byte counts; units match case-insensitively.
package struct MemorySpec: Sendable, Equatable {
  package let mib: MiB

  package static func parse(_ text: String) throws(ValidationError) -> MemorySpec {
    let bytes = try parseSizeBytes(text)
    let perMiB: UInt64 = 1 << 20
    let mib = bytes / perMiB + (bytes % perMiB == 0 ? 0 : 1)
    guard let value = UInt32(exactly: mib) else {
      throw ValidationError(
        "size '\(text)' overflows u32 MiB: out of range integral type conversion attempted")
    }
    guard let nonZero = MiB(value) else {
      throw ValidationError("size '\(text)' must be greater than zero")
    }
    return MemorySpec(mib: nonZero)
  }

  /// Gibibytes, rounded up from the stored MiB.
  package var gib: GiB { GiB((mib.value + 1023) / 1024)! }
}

func parseSizeBytes(_ text: String) throws(ValidationError) -> UInt64 {
  let trimmed = text.trimmingUnicodeWhitespace()
  guard !trimmed.isEmpty else { throw ValidationError("size string is empty") }
  if trimmed.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) {
    guard let bytes = UInt64(trimmed) else {
      throw ValidationError(
        "size '\(text)' overflows u64 bytes: number too large to fit in target type")
    }
    return bytes
  }
  let (numberText, multiplier) = try splitSize(trimmed)
  let number: Double
  do { number = try rustParseFloat(numberText) } catch {
    throw ValidationError(
      "expected '<decimal><unit>' (e.g. '4GB') or bare bytes; got '\(text)': \(error.message)")
  }
  guard number.isFinite, !(number < 0) else {
    throw ValidationError("size must be a non-negative finite number: '\(text)'")
  }
  let product = (number * Double(multiplier)).rounded()
  // Rust `as u64` saturates.
  if product >= 18_446_744_073_709_551_616.0 { return UInt64.max }
  return product > 0 ? UInt64(product) : 0
}

private let sizeSuffixes: [(String, UInt64)] = [
  ("TiB", 1 << 40), ("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10),
  ("TB", 1_000_000_000_000), ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000),
  ("T", 1_000_000_000_000), ("G", 1_000_000_000), ("M", 1_000_000), ("K", 1_000), ("B", 1),
]

func splitSize(_ text: String) throws(ValidationError) -> (String, UInt64) {
  let lower = Array(text.utf8).map {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 + 32 : $0
  }
  for (suffix, multiplier) in sizeSuffixes {
    let lowerSuffix = Array(suffix.lowercased().utf8)
    if lower.count >= lowerSuffix.count, Array(lower.suffix(lowerSuffix.count)) == lowerSuffix {
      let cut = text.utf8.count - lowerSuffix.count
      let head = String(decoding: Array(text.utf8)[..<cut], as: UTF8.self)
      return (head.trimmingUnicodeWhitespace(), multiplier)
    }
  }
  throw ValidationError(
    "expected a unit suffix (B, KB, MB, GB, TB; KiB/MiB/GiB/TiB also accepted): '\(text)'")
}

/// Rust `str::parse::<f64>()`: optional sign, then `inf`/`infinity`/`nan`
/// (any case) or decimal digits with optional fraction and exponent.
func rustParseFloat(_ text: String) throws(ValidationError) -> Double {
  guard !text.isEmpty else { throw ValidationError("cannot parse float from empty string") }
  var body = Substring(text)
  if body.first == "+" || body.first == "-" { body = body.dropFirst() }
  let lowered = body.lowercased()
  let special = ["inf", "infinity", "nan"].contains(lowered)
  if !special {
    var sawDigit = false
    var index = body.startIndex
    func digits() {
      while index < body.endIndex, body[index].isASCII, body[index].isNumber {
        sawDigit = true
        index = body.index(after: index)
      }
    }
    digits()
    if index < body.endIndex, body[index] == "." {
      index = body.index(after: index)
      digits()
    }
    guard sawDigit else { throw ValidationError("invalid float literal") }
    if index < body.endIndex, body[index] == "e" || body[index] == "E" {
      index = body.index(after: index)
      if index < body.endIndex, body[index] == "+" || body[index] == "-" {
        index = body.index(after: index)
      }
      sawDigit = false
      digits()
      guard sawDigit else { throw ValidationError("invalid float literal") }
    }
    guard index == body.endIndex else { throw ValidationError("invalid float literal") }
  }
  guard let value = Double(text) else { throw ValidationError("invalid float literal") }
  return value
}

// MARK: - Parsed file

/// A parsed `devcontainer.json`. `path` is retained for reporting.
package struct ParsedDevcontainer: Sendable {
  package let path: String
  /// Lowercase hex SHA-256 of the file text.
  package let contentHash: String
  let raw: RawDevcontainer

  /// Parse JSONC text; failures read `Failed to parse <path>`.
  package init(path: String, text: String) throws {
    self.path = path
    contentHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    do {
      let scanned = try JSONCScanner.strip(Array(text.utf8), policy: .devcontainer)
      let source = DevcontainerSource(bytes: scanned)
      raw = try withParserStack { () throws(DevcontainerJSONError) in
        try DevcontainerDecoder(source: source).decode(try DevcontainerParser.parse(scanned))
      }
    } catch {
      throw ContextError("Failed to parse \(path)", cause: error)
    }
  }

  /// Read and parse `path`; the report shows its canonical form.
  package static func load(_ path: String) throws -> ParsedDevcontainer {
    let text = try readUTF8File(path)
    return try ParsedDevcontainer(path: canonicalPath(path) ?? path, text: text)
  }
}

/// `fs::read_to_string` with the baseline's error text.
func readUTF8File(_ path: String) throws -> String {
  guard let handle = FileHandle(forReadingAtPath: path) else {
    throw ContextError("Failed to read \(path)", cause: HostError(ioErrorText(errno)))
  }
  defer { try? handle.close() }
  let data: Data
  do { data = try handle.readToEnd() ?? Data() } catch {
    throw ContextError("Failed to read \(path)", cause: error)
  }
  guard let text = String(validating: Array(data), as: UTF8.self) else {
    throw ContextError(
      "Failed to read \(path)", cause: HostError("stream did not contain valid UTF-8"))
  }
  return text
}

/// Rust `io::Error` display for an errno.
func ioErrorText(_ code: Int32) -> String {
  "\(String(cString: strerror(code))) (os error \(code))"
}

/// anyhow `to_string()`: the outermost message only.
func topMessage(_ error: any Error) -> String {
  (error as? ContextError)?.context ?? "\(error)"
}
