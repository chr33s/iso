import Foundation
import IsoCore

/// A sandboxed editor session's private `0700` state: HOME, temporary files,
/// profile, extensions and SSH identity. It lives under a short directory
/// because editors bind Unix sockets inside it (104-byte path limit).
package struct EditorEnclave: Sendable {
  package static let prefix = "iso-ed-"
  /// Room for the deepest editor socket, e.g. Zed's
  /// `tmp/zed-askpassXXXXXX/askpass.sock`.
  static let socketReserve = 48
  static let socketLimit = 103

  package let root: String
  package let id: String

  package var home: String { root + "/home" }
  package var temporary: String { root + "/tmp" }
  package var data: String { root + "/data" }
  package var extensions: String { root + "/ext" }
  package var ssh: String { root + "/ssh" }
  package var log: String { root + "/editor.log" }
  package var identity: String { ssh + "/id_ed25519" }
  package var sshConfig: String { ssh + "/config" }
  package var knownHosts: String { ssh + "/known_hosts" }
  /// The guest alias this session's SSH config defines.
  package var alias: String { "iso-editor-" + id }
  /// The comment that marks this session's guest `authorized_keys` line.
  package var keyComment: String { "iso-editor-" + id }

  /// `/private/tmp/iso-editor-<uid>`: must be a real `0700` directory owned
  /// by this user, so no other user can pre-create or watch it.
  package static func sessionsDirectory(base: String = "/private/tmp") throws -> String {
    let path = base + "/iso-editor-\(getuid())"
    if mkdir(path, 0o700) != 0, errno != EEXIST {
      throw HostError.posix("Failed to create", path)
    }
    var status = stat()
    guard lstat(path, &status) == 0 else { throw HostError.posix("Failed to inspect", path) }
    guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid(),
      status.st_mode & 0o077 == 0
    else {
      throw HostError("\(path) must be a directory owned by you with mode 0700")
    }
    return path
  }

  package static func create(in parent: String) throws -> EditorEnclave {
    let id = randomHex(6)
    let root = parent + "/" + prefix + id
    guard root.utf8.count + socketReserve <= socketLimit else {
      throw HostError(
        "The editor session directory \(root) is too long for the editor's Unix sockets")
    }
    guard mkdir(root, 0o700) == 0 else { throw HostError.posix("Failed to create", root) }
    let enclave = EditorEnclave(root: root, id: id)
    do {
      try AtomicFile.write(
        Array("\(getpid())\n".utf8), to: root + "/owner", mode: .atMost(0o600))
      for directory in [
        enclave.home, enclave.temporary, enclave.data, enclave.extensions, enclave.ssh,
      ] {
        guard mkdir(directory, 0o700) == 0 else {
          throw HostError.posix("Failed to create", directory)
        }
      }
    } catch {
      enclave.remove()
      throw error
    }
    return enclave
  }

  /// Removes enclaves whose iso process is gone.
  package static func removeStale(in parent: String) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return }
    for name in names where name.hasPrefix(prefix) {
      let root = parent + "/" + name
      var status = stat()
      guard lstat(root, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
        status.st_uid == getuid()
      else { continue }
      let owner = (try? String(contentsOfFile: root + "/owner", encoding: .utf8))
        .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      if let owner, owner > 0, kill(owner, 0) == 0 || errno == EPERM { continue }
      try? FileManager.default.removeItem(atPath: root)
    }
  }

  package func remove() {
    try? FileManager.default.removeItem(atPath: root)
  }

  package func write(_ text: String, to path: String) throws {
    try AtomicFile.write(Array(text.utf8), to: path, mode: .atMost(0o600))
  }

  /// Copies the pinned host key so the editor never reads iso's state.
  package func pinHostKey(from knownHosts: String) throws {
    guard let bytes = FileManager.default.contents(atPath: knownHosts) else {
      throw HostError("Failed to read the pinned host key at \(knownHosts)")
    }
    try AtomicFile.write(Array(bytes), to: self.knownHosts, mode: .atMost(0o600))
  }

  /// A fresh Ed25519 key pair; returns the public key line.
  package func generateIdentity(runner: ProcessRunner = ProcessRunner()) throws -> String {
    let output = try runner.capture(
      .init(
        executable: "/usr/bin/ssh-keygen",
        arguments: ["-t", "ed25519", "-N", "", "-q", "-C", keyComment, "-f", identity],
        environment: ["PATH": "/usr/bin:/bin"], deadline: .seconds(60)))
    guard output.termination == .exited(0),
      let publicKey = try? String(contentsOfFile: identity + ".pub", encoding: .utf8)
    else { throw HostError("Failed to generate the editor session's SSH key") }
    return publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Guest `authorized_keys` line: `restrict`ed, from the tunnel only.
  package static func authorizedKey(_ publicKey: String, options: [String]) -> String {
    (["restrict", "from=\"127.0.0.1,::1\""] + options).joined(separator: ",") + " " + publicKey
  }

  /// The editor's only SSH config (`ssh -F`): the tunnel, with the pinned key.
  package func sshConfigText(tunnelPort: UInt16, user: GuestUser, hostKeyAlias: String) throws
    -> String
  {
    for value in [identity, knownHosts, hostKeyAlias]
    where value.unicodeScalars.contains(where: {
      $0 == "\"" || $0 == "'" || $0.properties.generalCategory == .control
    }) {
      throw HostError("\(value) contains a quote or control character; SSH cannot carry it")
    }
    return """
      Host \(alias)
          HostName 127.0.0.1
          Port \(tunnelPort)
          User \(user)
          IdentityFile \(SSHTarget.quoteValue(identity))
          IdentitiesOnly yes
          IdentityAgent none
          ForwardAgent no
          ForwardX11 no
          PermitLocalCommand no
          BatchMode yes
          StrictHostKeyChecking yes
          UserKnownHostsFile \(SSHTarget.quoteValue(knownHosts))
          GlobalKnownHostsFile /dev/null
          HostKeyAlias \(hostKeyAlias)
          UpdateHostKeys no
          LogLevel ERROR

      """
  }

  /// Only the locale is inherited from the caller.
  package func environment(caller: [String: String]) -> [String: String] {
    var environment = [
      "HOME": home, "TMPDIR": temporary + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name {
      environment["USER"] = String(cString: name)
      environment["LOGNAME"] = String(cString: name)
    }
    for (name, value) in caller where name == "LANG" || name.hasPrefix("LC_") {
      if value.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.generalCategory != .control }
      ) {
        environment[name] = value
      }
    }
    return environment
  }
}

func settingsJSON(_ object: [String: Any]) throws -> String {
  let data = try JSONSerialization.data(
    withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  return String(decoding: data, as: UTF8.self) + "\n"
}
