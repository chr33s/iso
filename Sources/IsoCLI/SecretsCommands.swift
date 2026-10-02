import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets
import Synchronization

struct SecretsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "secrets",
    abstract: "Manage the local secret store bound to this Mac's Secure Enclave",
    subcommands: [
      SecretsInit.self, SecretsSet.self, SecretsRemove.self, SecretsList.self, SecretsStatus.self,
    ])
}

extension CommandContext {
  var secretStore: EnclaveStore {
    EnclaveStore(directory: config.dataDirectory.appending("secrets").path)
  }

  /// Shared by every session this command opens, so the store is unlocked
  /// at most once per command for a given set of names.
  var secretResolver: StoreSecretResolver { StoreSecretResolver.shared(secretStore) }
}

/// Resolves `{vault:}` references through the secret store: one passphrase
/// prompt and one Secure Enclave check per batch of new names. Resolved
/// values live only in this process's memory.
final class StoreSecretResolver: SecretReferenceResolver {
  let store: EnclaveStore
  private let cache = Mutex<[SecretName: Secret<[UInt8]>]>([:])

  init(store: EnclaveStore) { self.store = store }

  private static let instances = Mutex<[String: StoreSecretResolver]>([:])

  static func shared(_ store: EnclaveStore) -> StoreSecretResolver {
    instances.withLock { instances in
      if let existing = instances[store.directory] { return existing }
      let created = StoreSecretResolver(store: store)
      instances[store.directory] = created
      return created
    }
  }

  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>] {
    try cache.withLock { cache in
      let missing = names.subtracting(cache.keys)
      if !missing.isEmpty {
        disableCoreDumps()
        let passphrase = try PassphraseInput.read(prompt: "Passphrase for iso secrets")
        cache.merge(try store.resolve(missing, passphrase: passphrase)) { $1 }
      }
      return cache.filter { names.contains($0.key) }
    }
  }
}

/// Secret-bearing commands never write core dumps (spec §37).
func disableCoreDumps() {
  var limit = rlimit(rlim_cur: 0, rlim_max: 0)
  setrlimit(RLIMIT_CORE, &limit)
}

/// Passphrases come from `/dev/tty` with echo off, or for automation from
/// the descriptor named by `ISO_SECRETS_PASSPHRASE_FD` — never argv or a
/// plaintext environment value (spec §16).
enum PassphraseInput {
  static let descriptorVariable = "ISO_SECRETS_PASSPHRASE_FD"
  static let maxLength = 4096

  private static let cached = Mutex<Secret<[UInt8]>?>(nil)

  /// The command's passphrase, read at most once per process: the descriptor
  /// is closed after its first read, and a command prompts only once.
  static func read(
    prompt: String, confirm: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Secret<[UInt8]> {
    try cached.withLock { cached in
      if let cached { return cached }
      let passphrase = try readFresh(prompt: prompt, confirm: confirm, environment: environment)
      cached = passphrase
      return passphrase
    }
  }

  /// Test seam: forget the cached passphrase.
  static func reset() { cached.withLock { $0 = nil } }

  static func readFresh(
    prompt: String, confirm: Bool, environment: [String: String]
  ) throws -> Secret<[UInt8]> {
    if let raw = environment[descriptorVariable] {
      return try fromDescriptor(raw)
    }
    let first = try TerminalInput.hidden(prompt)
    if confirm {
      let second = try TerminalInput.hidden("Repeat passphrase")
      guard first.expose() == second.expose() else { throw HostError("Passphrases do not match") }
    }
    guard !first.expose().isEmpty else { throw HostError("Empty passphrase") }
    return first
  }

  /// Reads the whole descriptor once, drops one trailing newline, closes it.
  /// A group- or world-readable regular file is refused.
  static func fromDescriptor(_ raw: String) throws -> Secret<[UInt8]> {
    guard let parsed = parseUnsigned(raw, as: UInt16.self), parsed > 2 else {
      throw HostError("\(descriptorVariable) must name an open descriptor above 2")
    }
    let fd = Int32(parsed)
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw HostError("\(descriptorVariable) does not name an open descriptor")
    }
    if info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o044 != 0 {
      throw HostError("Refusing a group- or world-readable passphrase file")
    }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw HostError("Failed to read the passphrase descriptor") }
      if count == 0 { break }
      bytes += chunk[0..<count]
      guard bytes.count <= maxLength else { throw HostError("Passphrase is too long") }
    }
    if bytes.last == 0x0A { bytes.removeLast() }
    guard !bytes.isEmpty else { throw HostError("Empty passphrase") }
    return Secret(bytes)
  }
}

/// Prompts on the controlling terminal, so stdin stays free for `--stdin`.
enum TerminalInput {
  static func open() throws -> Int32 {
    let fd = Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC)
    guard fd >= 0 else {
      throw HostError(
        "No terminal for the prompt; use \(PassphraseInput.descriptorVariable) for automation")
    }
    return fd
  }

  static func write(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
  }

  /// One line without its newline. Longer input, EOF before a newline, or a
  /// read error is an error, never a silent truncation.
  static func readLine(_ fd: Int32, limit: Int) throws -> [UInt8] {
    var line: [UInt8] = []
    var byte: UInt8 = 0
    while true {
      let count = Darwin.read(fd, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw HostError("Failed to read from the terminal") }
      guard count == 1 else { throw HostError("Input ended before a newline") }
      if byte == 0x0A { return line }
      line.append(byte)
      guard line.count <= limit else { throw HostError("Input is longer than \(limit) bytes") }
    }
  }

  /// A line read with echo off through `readpassphrase(3)`, which requires a
  /// terminal and restores it on every signal (including a stop and resume,
  /// where it turns echo off again and re-prompts).
  static func hidden(_ prompt: String) throws -> Secret<[UInt8]> {
    // Canonical terminal input is capped at MAX_CANON per line.
    var buffer = [CChar](repeating: 0, count: Int(MAX_CANON) + 1)
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard readpassphrase("\(prompt): ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
      throw HostError(
        "Could not read from the terminal; use \(PassphraseInput.descriptorVariable) for automation"
      )
    }
    let line = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard line.count < buffer.count - 2 else {
      throw HostError("Input may have been truncated by the terminal; pipe it with --stdin instead")
    }
    return Secret(line)
  }

  static func confirm(_ prompt: String) throws -> Bool {
    let fd = try open()
    defer { close(fd) }
    write(fd, "\(prompt) [y/N] ")
    let reply = String(decoding: try readLine(fd, limit: 16), as: UTF8.self)
      .trimmingUnicodeWhitespace()
      .lowercased()
    return reply == "y" || reply == "yes"
  }
}

private func parseSecretName(_ text: String) throws -> SecretName {
  do {
    return try SecretName(text)
  } catch {
    throw ArgumentParser.ValidationError(error.message)
  }
}

struct SecretsInit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init", abstract: "Create the secret store (no recovery path by design)")

  static let warning = """
    WARNING: Iso secrets are bound to this Mac's Secure Enclave.

    There is no recovery key and no password-only fallback.

    If this Mac or the Secure Enclave key is lost, these secrets cannot be
    recovered, even if you know the passphrase or have a copy of the encrypted
    store.

    Keep independent copies of critical credentials with their original provider.
    """

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Accept the no-recovery warning without a prompt (automation)")
  var acceptNoRecovery = false

  func run() throws {
    disableCoreDumps()
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let store = context.secretStore
      guard !store.exists else { throw EnclaveStoreError.alreadyInitialized }
      context.output.error(Self.warning + "\n")
      if !acceptNoRecovery {
        guard try TerminalInput.confirm("Continue?") else { throw HostError("Aborted") }
      }
      let passphrase = try PassphraseInput.read(prompt: "New passphrase", confirm: true)
      try store.initialize(passphrase: passphrase, acknowledgement: .accepted)
      context.diagnostics.log(.info, "Created the secret store at \(store.directory)")
    }
  }
}

struct SecretsSet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set", abstract: "Add or replace a secret (the value is never read from argv)")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Secret name", transform: parseSecretName) var name: SecretName
  @Flag(help: "Read the value from stdin, byte for byte") var stdin = false

  func run() throws {
    disableCoreDumps()
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let value: Secret<[UInt8]>
      if stdin {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= StoreLimits.valueBytes else {
          throw EnclaveStoreError.limitExceeded("a secret value is limited to 1 MiB")
        }
        value = Secret(Array(data))
      } else {
        value = try TerminalInput.hidden("Value for \(name)")
      }
      guard !value.expose().isEmpty else { throw HostError("Empty secret value") }
      let passphrase = try PassphraseInput.read(prompt: "Passphrase")
      try context.secretStore.set(name, value: value, passphrase: passphrase)
      context.diagnostics.log(.info, "Stored secret '\(name)'")
    }
  }
}

struct SecretsRemove: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm", abstract: "Remove a secret from the store")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Secret name", transform: parseSecretName) var name: SecretName

  func run() throws {
    disableCoreDumps()
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let passphrase = try PassphraseInput.read(prompt: "Passphrase")
      try context.secretStore.remove(name, passphrase: passphrase)
      context.diagnostics.log(.info, "Removed secret '\(name)'")
    }
  }
}

struct SecretsList: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List secret names (never values)")

  @OptionGroup var global: GlobalOptions

  func run() throws {
    disableCoreDumps()
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let passphrase = try PassphraseInput.read(prompt: "Passphrase")
      for entry in try context.secretStore.list(passphrase: passphrase) {
        context.output.out("\(entry.name)\t\(entry.updatedAt)")
      }
    }
  }
}

struct SecretsStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Show whether the store exists (does not unlock it)")

  @OptionGroup var global: GlobalOptions

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let store = context.secretStore
      context.output.out("Store: \(store.directory)")
      let state =
        store.exists
        ? "yes" : store.leftovers.isEmpty ? "no" : "incomplete (see `iso secrets list`)"
      context.output.out("Initialized: \(state)")
      context.output.out(
        "Secure Enclave: \(SecureEnclaveFactor.available ? "available" : "unavailable")")
    }
  }
}
