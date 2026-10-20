// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Document syntax, chosen by file extension only (never by sniffing).
package enum ConfigFormat: Sendable, Equatable {
  case jsonc
  case json

  package init(path: String) throws(ConfigError) {
    switch (path as NSString).pathExtension {
    case "jsonc": self = .jsonc
    case "json": self = .json
    default: throw .unsupportedExtension(path: path)
    }
  }
}

/// Where a command's configuration comes from (spec section 3.4).
package enum ConfigSelection: Sendable, Equatable {
  /// A selected file must exist when loaded.
  case file(path: String, format: ConfigFormat)
  /// No configuration file exists at the default location.
  case defaultsOnly(defaultPath: String)
}

package enum ConfigLoader {
  package static let defaultFileName = "config.jsonc"

  package static func defaultDirectory(home: String?) -> String {
    HostPath(expanding: "~/.iso", home: home ?? ".").path
  }

  /// Resolve `--config` or the default path. An explicit path is used as-is
  /// (even if missing); the default never falls back across formats.
  package static func select(
    explicitPath: String?, home: String?,
    fileExists: (String) -> Bool = FileManager.default.fileExists
  ) throws(ConfigError) -> ConfigSelection {
    if let explicitPath {
      return .file(path: explicitPath, format: try ConfigFormat(path: explicitPath))
    }
    let directory = defaultDirectory(home: home)
    let jsonc = directory + "/" + defaultFileName
    if fileExists(jsonc) { return .file(path: jsonc, format: .jsonc) }
    return .defaultsOnly(defaultPath: jsonc)
  }

  /// Load the selected file, or defaults when the implicit configuration was absent.
  /// A missing selected file is an error, including a file removed after selection.
  package static func load(
    _ selection: ConfigSelection, environment: ConfigEnvironment,
    limits: JSONLimits = .configuration
  ) throws(ConfigError) -> IsoConfig {
    switch selection {
    case .defaultsOnly:
      return try decode(.object([:]), path: "<defaults>", environment: environment)
    case .file(let path, let format):
      guard let bytes = try readSnapshot(path, limit: limits.maxBytes) else {
        throw .missingFile(path: path)
      }
      let value = try parse(bytes, format: format, path: path, limits: limits)
      return try decode(value, path: path, environment: environment)
    }
  }

  /// Steps 2–5 of the pipeline on an in-memory snapshot: UTF-8, comment
  /// scan, structural preflight, Foundation decode into `JSONValue`.
  package static func parse(
    _ bytes: [UInt8], format: ConfigFormat, path: String, limits: JSONLimits
  )
    throws(ConfigError) -> JSONValue
  {
    guard bytes.count <= limits.maxBytes else {
      throw .preflight(
        path: path, JSONPreflightError(kind: .tooLarge(limit: limits.maxBytes), location: nil))
    }
    let clean: [UInt8]
    switch format {
    case .jsonc:
      do { clean = try JSONCScanner.strip(bytes, policy: .configuration) } catch {
        throw .scan(path: path, error)
      }
    case .json:
      guard String(validating: bytes, as: UTF8.self) != nil else {
        throw .scan(path: path, JSONCScanError(kind: .invalidUTF8, location: nil))
      }
      clean = bytes
    }
    let preflight: JSONPreflightResult
    do { preflight = try JSONPreflight.check(clean, limits: limits) } catch {
      throw .preflight(path: path, error)
    }
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = false
    decoder.userInfo[FractionalPaths.userInfoKey] = FractionalPaths(preflight.fractionalNumberPaths)
    do {
      return try decoder.decode(JSONValue.self, from: Data(clean))
    } catch {
      // Foundation's message can quote document bytes; report only the fact.
      throw .undecodable(path: path)
    }
  }

  /// Step 6: typed decoding and domain validation of a parsed document.
  package static func decode(_ value: JSONValue, path: String, environment: ConfigEnvironment)
    throws(ConfigError) -> IsoConfig
  {
    do {
      return try ConfigDecoder.decode(value, environment: environment)
    } catch {
      switch error {
      case .rootNotObject: throw .rootNotObject(path: path)
      case .field(let failure):
        throw .invalidField(path: path, field: failure.field, reason: failure.reason)
      }
    }
  }

  /// Reads a regular file, at most `limit + 1` bytes (so an oversized file
  /// is detected without reading all of it); nil when it does not exist.
  package static func readSnapshot(_ path: String, limit: Int) throws(ConfigError) -> [UInt8]? {
    // The C string is borrowed only for open; the resulting descriptor is owned here.
    let descriptor = unsafe open(path, O_RDONLY | O_CLOEXEC)
    if descriptor < 0 {
      let code = errno
      if code == ENOENT { return nil }
      throw .unreadable(path: path, reason: posixMessage(code))
    }
    defer { close(descriptor) }
    var status = stat()
    // fstat writes exactly one initialized stat value, borrowed for this call.
    guard unsafe fstat(descriptor, &status) == 0 else {
      throw .unreadable(path: path, reason: posixMessage(errno))
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw .unreadable(path: path, reason: "not a regular file")
    }
    try ConfigTrust.check(descriptor, status: status, path: path)
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while bytes.count <= limit {
      // read cannot exceed the writable buffer; the pointer stays inside this closure.
      let count = chunk.withUnsafeMutableBytes { unsafe read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw .unreadable(path: path, reason: posixMessage(errno))
      }
      if count == 0 { break }
      bytes.append(contentsOf: chunk[0..<count])
    }
    return bytes
  }

  private static func posixMessage(_ code: Int32) -> String {
    // libc supplies a NUL-terminated message; copy it before another libc call.
    unsafe String(cString: strerror(code))
  }
}

/// Host configuration grants authority, so it is read only from a file that
/// no other principal can change (POL-01): a regular file owned by this user
/// or root, not group/other-writable, with no ACL entry allowing anyone to
/// write it, below directories that satisfy the same rule (a sticky
/// world-writable directory such as `/tmp` excepted). Symlinks in the
/// given path are followed when it is opened; the checks apply to the
/// opened file and the ancestors of its resolved path, not to the links.
package enum ConfigTrust {
  static func check(_ descriptor: Int32, status: stat, path: String) throws(ConfigError) {
    let user = geteuid()
    func untrusted(_ reason: String) -> ConfigError {
      .unreadable(path: path, reason: "refusing an untrusted configuration file: \(reason)")
    }
    guard status.st_uid == user || status.st_uid == 0 else {
      throw untrusted("it is owned by another user")
    }
    guard status.st_mode & 0o022 == 0 else {
      throw untrusted("it is writable by group or others")
    }
    guard !grantsWrite(descriptor) else { throw untrusted("an ACL lets others write it") }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    // F_GETPATH writes a NUL-terminated path into the MAXPATHLEN buffer.
    guard unsafe fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
      throw untrusted("its location cannot be resolved")
    }
    var directory =
      (String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self) as NSString).deletingLastPathComponent
    while true {
      let fd = unsafe open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0 else { throw untrusted("\(directory) cannot be inspected") }
      defer { close(fd) }
      var info = stat()
      guard unsafe fstat(fd, &info) == 0 else {
        throw untrusted("\(directory) cannot be inspected")
      }
      let sticky = info.st_mode & S_ISVTX != 0
      guard info.st_uid == user || info.st_uid == 0 else {
        throw untrusted("\(directory) is owned by another user")
      }
      guard info.st_mode & 0o022 == 0 || sticky else {
        throw untrusted("\(directory) is writable by group or others")
      }
      guard sticky || !grantsWrite(fd) else {
        throw untrusted("an ACL lets others write \(directory)")
      }
      if directory == "/" || directory.isEmpty { return }
      directory = (directory as NSString).deletingLastPathComponent
    }
  }

  /// Whether an extended ACL allows anyone to write, append, add or delete
  /// entries, or change ownership or permissions. Deny entries are fine.
  static func grantsWrite(_ descriptor: Int32) -> Bool {
    guard let acl = unsafe acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return false }
    defer { unsafe acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t? = nil
    var which = ACL_FIRST_ENTRY.rawValue
    let writes: [acl_perm_t] = [
      ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
      ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
    ]
    while unsafe acl_get_entry(acl, Int32(which), &entry) == 0, let current = unsafe entry {
      which = ACL_NEXT_ENTRY.rawValue
      var tag = ACL_UNDEFINED_TAG
      guard unsafe acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_ALLOW else { continue }
      var permissions: acl_permset_t? = nil
      guard unsafe acl_get_permset(current, &permissions) == 0, let permissions = unsafe permissions
      else { continue }
      if writes.contains(where: { unsafe acl_get_perm_np(permissions, $0) == 1 }) { return true }
    }
    return false
  }
}
