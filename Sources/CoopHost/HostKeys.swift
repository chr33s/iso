// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore
import CryptoKit
import Foundation

/// A guest's ed25519 host public key, read over the runtime's own channel
/// (never `ssh-keyscan`) and pinned per instance.
public struct HostPublicKey: Sendable, Equatable {
  /// Base64 exactly as the guest printed it.
  public let base64: String
  let blob: [UInt8]

  /// One non-blank line: `ssh-ed25519 <base64> [comment]`, whose blob is
  /// the 51-byte ed25519 wire encoding. The comment is dropped.
  public init(parsing text: String) throws(RuntimeError) {
    func fail(_ reason: String) -> RuntimeError {
      .hostKeyChanged("guest host public key \(reason)")
    }
    let lines = rustLines(text).filter { !$0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }
    guard lines.count == 1 else { throw fail("must be exactly one line") }
    let fields = lines[0].split(whereSeparator: {
      $0.unicodeScalars.allSatisfy(\.properties.isWhitespace)
    })
    guard fields.count >= 2 else { throw fail("is malformed") }
    guard fields[0] == "ssh-ed25519" else {
      throw fail("has type \(debugQuoted(sanitizeForDisplay(String(fields[0])))), not ssh-ed25519")
    }
    guard let blob = lenientBase64Decode(String(fields[1])) else {
      throw fail("is not valid base64")
    }
    let prefix: [UInt8] = [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
    guard blob.count == 51, blob.starts(with: prefix) else {
      throw fail("is not an ed25519 public key")
    }
    base64 = String(fields[1])
    self.blob = blob
  }

  /// OpenSSH `SHA256:<base64 without padding>`, as `ssh-keygen -lf` prints.
  public var fingerprint: String {
    "SHA256:"
      + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  public func knownHostsLine(machine: MachineName) -> String {
    "\(machine).coop ssh-ed25519 \(base64)\n"
  }
}

/// How a freshly read host key is checked against the instance's pin.
public enum HostKeyTrust: Sendable {
  /// A new instance: write the pin; refuse if one exists.
  case enroll
  /// A normal start: the pin must match byte for byte.
  case requirePin
  /// Only after coop itself replaced the disk (`restore`).
  case reenrollAfterRestore
}

public enum HostKeyPin {
  public static func apply(
    _ trust: HostKeyTrust, instance: Instance, machine: MachineName, key: HostPublicKey
  ) throws {
    let path = instance.knownHostsPath
    let line = key.knownHostsLine(machine: machine)
    switch trust {
    case .enroll:
      var status = stat()
      if lstat(path, &status) == 0 {
        throw RuntimeError.hostKeyChanged(
          "instance '\(instance.name)' already has a pinned host key at \(path); refusing to re-enroll"
        )
      }
      try write(line, path)
    case .reenrollAfterRestore:
      try write(line, path)
    case .requirePin:
      guard let data = FileManager.default.contents(atPath: path) else {
        throw RuntimeError.hostKeyChanged(
          "instance '\(instance.name)' has no pinned host key; recreate the instance")
      }
      guard data == Data(line.utf8) else {
        throw RuntimeError.hostKeyChanged(
          "the SSH host key of instance '\(instance.name)' changed (now \(key.fingerprint)); refusing to connect. Recreate the instance, or re-enroll deliberately after review."
        )
      }
    }
  }

  static func write(_ line: String, _ path: String) throws {
    do {
      try AtomicFile.write(Array(line.utf8), to: path, mode: .atMost(0o600))
    } catch {
      throw ContextError("Failed to write pinned host key", cause: error)
    }
  }
}

/// The Rust host's decoder: trailing `=` ignored, standard alphabet only,
/// leftover bits dropped.
func lenientBase64Decode(_ text: String) -> [UInt8]? {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
  var bytes = Array(text.utf8)
  while bytes.last == UInt8(ascii: "=") { bytes.removeLast() }
  var out: [UInt8] = []
  var accumulator: UInt32 = 0
  var bits: UInt32 = 0
  for byte in bytes {
    guard let value = alphabet.firstIndex(of: byte) else { return nil }
    accumulator = (accumulator << 6) | UInt32(value)
    bits += 6
    if bits >= 8 {
      bits -= 8
      out.append(UInt8((accumulator >> bits) & 0xFF))
    }
  }
  return out
}
