import ArgumentParser
import CoopCore
import CoopHost
import Foundation
import Testing

@testable import CoopCLI

@Test func secretsCommandsParse() throws {
  let set = try #require(
    try CoopCommand.parseAsRoot(["secrets", "set", "anthropic", "--stdin"]) as? SecretsSet)
  #expect(set.name.rawValue == "anthropic" && set.stdin)
  #expect(throws: (any Error).self) { try CoopCommand.parseAsRoot(["secrets", "set", "../x"]) }
  #expect(throws: (any Error).self) {
    try CoopCommand.parseAsRoot(["secrets", "set", "a", "value"])
  }
  let initialize = try #require(
    try CoopCommand.parseAsRoot(["secrets", "init", "--accept-no-recovery"]) as? SecretsInit)
  #expect(initialize.acceptNoRecovery)
  #expect(try CoopCommand.parseAsRoot(["secrets", "rm", "db"]) is SecretsRemove)
  #expect(try CoopCommand.parseAsRoot(["secrets", "list"]) is SecretsList)
  #expect(try CoopCommand.parseAsRoot(["secrets", "status"]) is SecretsStatus)
}

private func pipeWith(_ text: String) -> Int32 {
  var fds: [Int32] = [0, 0]
  pipe(&fds)
  _ = Array(text.utf8).withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
  close(fds[1])
  return fds[0]
}

@Test func passphraseDescriptorIsReadOnceWithoutTrailingNewline() throws {
  PassphraseInput.reset()
  defer { PassphraseInput.reset() }
  let fd = pipeWith("hunter2 two\n")
  let secret = try PassphraseInput.read(
    prompt: "unused", environment: [PassphraseInput.descriptorVariable: String(fd)])
  #expect(secret.expose() == Array("hunter2 two".utf8))
  // A second batch in the same command reuses it; the closed descriptor
  // (whose number may already name something else) is never read again.
  let again = try PassphraseInput.read(
    prompt: "unused", environment: [PassphraseInput.descriptorVariable: "999"])
  #expect(again.expose() == Array("hunter2 two".utf8))
}

@Test func passphraseDescriptorRefusesUnsafeSources() throws {
  #expect(throws: HostError.self) { try PassphraseInput.fromDescriptor("0") }
  #expect(throws: HostError.self) { try PassphraseInput.fromDescriptor("-1") }
  #expect(throws: HostError.self) { try PassphraseInput.fromDescriptor("abc") }
  #expect(throws: HostError.self) { try PassphraseInput.fromDescriptor(String(pipeWith(""))) }
  let path = FileManager.default.temporaryDirectory.appending(path: "coop-pass-\(UUID())").path
  defer { unlink(path) }
  FileManager.default.createFile(atPath: path, contents: Data("pw".utf8))
  chmod(path, 0o644)
  #expect(throws: HostError.self) {
    try PassphraseInput.fromDescriptor(String(open(path, O_RDONLY)))
  }
  chmod(path, 0o600)
  #expect(
    try PassphraseInput.fromDescriptor(String(open(path, O_RDONLY))).expose() == Array("pw".utf8))
}
