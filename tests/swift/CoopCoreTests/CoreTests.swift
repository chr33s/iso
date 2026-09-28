import Testing

@testable import CoopCore

@Test(arguments: [
  ("https://github.com/trailofbits/coop", "trailofbits/coop"),
  ("https://github.com/trailofbits/coop.git", "trailofbits/coop"),
  ("https://github.com/trailofbits/coop/", "trailofbits/coop"),
  ("https://github.com/trailofbits/coop.git//", "trailofbits/coop"),
  ("git@github.com:trailofbits/coop", "trailofbits/coop"),
  ("git@github.com:trailofbits/coop.git", "trailofbits/coop"),
  ("ssh://git@github.com/trailofbits/coop.git", "trailofbits/coop"),
  ("http://github.com/trailofbits/coop", "trailofbits/coop"),
  ("  https://github.com/o/r\n", "o/r"),
  ("https://github.com/o/r.git.git", "o/r.git"),
])
func parsesGitHubRemoteURLs(_ url: String, _ slug: String) {
  #expect(RepoSlug.parse(url: url)?.rawValue == slug)
}

@Test(arguments: [
  "https://gitlab.com/owner/repo", "https://github.com/owner/repo/pulls/1",
  "https://github.com/owner",
  "https://github.com/", "https://github.com/.git", "HTTPS://github.com/o/r",
  "https://github.com/o/r\u{301}",
  "git@github.com:o/r;rm", "https://github.com/o/r?x=1", "", "\u{0}",
])
func rejectsOtherURLs(_ url: String) {
  #expect(RepoSlug.parse(url: url) == nil)
}

@Test func repoSlugValidation() throws {
  #expect(throws: Never.self) { try RepoSlug("user-name/repo.name_v2") }
  for bad in ["trailofbits", "/coop", "trailofbits/", "a/b/c", "owner!/repo", "o/r e", "ö/r", ""] {
    #expect(throws: ValidationError.self) { try RepoSlug(bad) }
  }
  let slug = try RepoSlug("owner/repo")
  #expect(slug.owner == "owner")
  #expect(slug.repo == "repo")
  #expect(try RepoSlug.parseCLI("  a/b \t") == RepoSlug("a/b"))
}

@Test func instanceNames() throws {
  #expect(try InstanceName("my_vm-2").rawValue == "my_vm-2")
  #expect(throws: ValidationError("Instance name must not be empty")) { try InstanceName("") }
  #expect(throws: ValidationError("Instance name too long (65 chars, max 64)")) {
    try InstanceName(String(repeating: "a", count: 65))
  }
  #expect(throws: Never.self) { try InstanceName(String(repeating: "a", count: 64)) }
  for bad in ["a.b", "a b", "é", "a\n"] {
    #expect(throws: ValidationError.self) { try InstanceName(bad) }
  }
  do {
    _ = try InstanceName("~/projects/foo")
    Issue.record("accepted a path")
  } catch {
    #expect(error.message.contains("coop up <PATH>"))
  }
}

@Test func imageNames() throws {
  #expect(ImageName.default.rawValue == "default")
  #expect(throws: Never.self) { try ImageName("ubuntu-24.04_x") }
  for bad in ["", ".", "..", ".hidden", "a/b", "a b", String(repeating: "x", count: 65)] {
    #expect(throws: ValidationError.self) { try ImageName(bad) }
  }
}

@Test func environmentVariableNames() throws {
  for good in ["A", "_", "a_1", "PATH"] { #expect(throws: Never.self) { try EnvVarName(good) } }
  for bad in ["", "1A", "A-B", "A B", "É"] {
    #expect(throws: ValidationError.self) { try EnvVarName(bad) }
  }
}

@Test func unsignedParsingMatchesRust() {
  #expect(parseUnsigned("42", as: UInt32.self) == 42)
  #expect(parseUnsigned("+42", as: UInt32.self) == 42)
  #expect(parseUnsigned("007", as: UInt32.self) == 7)
  #expect(parseUnsigned("4294967295", as: UInt32.self) == .max)
  for bad in ["", "+", "-1", "-0", " 1", "1 ", "4294967296", "1e3", "0x10", "١"] {
    #expect(parseUnsigned(bad, as: UInt32.self) == nil, "\(bad)")
  }
}

@Test func memoryAndDiskQuantities() throws {
  #expect(try VmMemory.parseCLI("128").mib.value == 128)
  #expect(throws: ValidationError("mem_size_mib=127 is too low (minimum 128)")) {
    try VmMemory.parseCLI("127")
  }
  #expect(throws: ValidationError("MiB must be > 0, got '0'")) { try VmMemory.parseCLI("0") }
  #expect(throws: ValidationError("expected positive integer MiB, got 'x'")) {
    try MiB.parseCLI("x")
  }
  #expect(try DiskSize.parse("150") == .absolute(GiB(150)!))
  #expect(try DiskSize.parse("150G") == .absolute(GiB(150)!))
  #expect(try DiskSize.parse("+20g") == .relative(GiB(20)!))
  for bad in ["", "+", "0", "+0", "G", "1.5", "-1", "20GB"] {
    #expect(throws: ValidationError.self) { try DiskSize.parse(bad) }
  }
  #expect(try DiskSize.relative(GiB(20)!).resolve(current: GiB(8)!) == GiB(28)!)
  #expect(try DiskSize.absolute(GiB(5)!).resolve(current: GiB(8)!) == GiB(5)!)
  #expect(throws: ValidationError("Disk size overflow")) {
    try DiskSize.relative(GiB(.max)!).resolve(current: GiB(1)!)
  }
}

@Test func timeoutsAndIndexes() throws {
  #expect(try TimeoutSecs(1).seconds == 1)
  #expect(try TimeoutSecs(86_400).duration == .seconds(86_400))
  #expect(throws: ValidationError.self) { try TimeoutSecs(0) }
  #expect(throws: ValidationError.self) { try TimeoutSecs(86_401) }
  #expect(InstanceIndex(252) != nil)
  #expect(InstanceIndex(253) == nil)
}

@Test func portForwardSpecs() throws {
  #expect(try PortForward.parse("3000") == PortForward(guest: 3000))
  #expect(try PortForward.parse(" 3000 : 3001 ") == PortForward(guest: 3000, host: 3001))
  for bad in ["", "0", "3000:0", "70000", "a:1", "1:b", "1:2:3"] {
    #expect(throws: ValidationError.self) { try PortForward.parse(bad) }
  }
  let merged = PortForward.merge(
    config: [try PortForward(guest: 1), try PortForward(guest: 2, host: 20)],
    cli: [try PortForward(guest: 2, host: 30), try PortForward(guest: 3)])
  #expect(merged.map(\.guest) == [1, 2, 3])
  #expect(merged.map(\.host) == [1, 30, 3])
}

@Test func secretsNeverRender() {
  let secret = Secret("SYNTHETIC-SECRET")
  let rendered = [
    "\(secret)", String(describing: secret), String(reflecting: secret), "\([secret])",
    "\(Optional(secret) as Any)",
  ]
  for text in rendered { #expect(!text.contains("SYNTHETIC-SECRET")) }
  var dumped = ""
  dump(secret, to: &dumped)
  #expect(!dumped.contains("SYNTHETIC-SECRET"))
  #expect(secret.expose() == "SYNTHETIC-SECRET")
}

@Test func outputJSONMatchesSerdeJSONPretty() {
  let expected: [(Double, String)] = [
    (0.0, "0.0"), (1.0, "1.0"), (0.12, "0.12"), (1.5, "1.5"), (100.0, "100.0"),
    (1e15, "1000000000000000.0"), (1e16, "1e+16"), (1.5e-7, "1.5e-7"), (0.00001, "0.00001"),
    (0.000012, "0.000012"), (123456789.125, "123456789.125"), (-2.5, "-2.5"), (1e21, "1e+21"),
    (9.999e15, "9999000000000000.0"), (0.3, "0.3"), (.nan, "null"),
  ]
  for (value, text) in expected { #expect(OutputJSON.formatDouble(value) == text, "\(value)") }
  let document = OutputJSON.array([
    .object([("name", .string("web")), ("state", .string("running")), ("usage", .null)]),
    .object([("list", .array([])), ("map", .object([])), ("esc", .string("a\"\\\n\u{01}é/"))]),
  ])
  #expect(
    document.rendered() == """
      [
        {
          "name": "web",
          "state": "running",
          "usage": null
        },
        {
          "list": [],
          "map": {},
          "esc": "a\\"\\\\\\n\\u0001é/"
        }
      ]

      """)
  #expect(OutputJSON.array([]).rendered() == "[]\n")
}

@Test func byteCountsParseBinarySuffixes() throws {
  #expect(try ByteCount(parsing: "1048576").bytes == 1 << 20)
  #expect(try ByteCount(parsing: "512KiB").bytes == 512 << 10)
  #expect(try ByteCount(parsing: "256MiB").bytes == 256 << 20)
  #expect(try ByteCount(parsing: "1GiB").description == "1GiB")
  #expect(ByteCount(bytes: 1536)!.description == "1536")
  #expect(ByteCount(bytes: 3 << 10)!.description == "3KiB")
  for bad in ["", "0", "0MiB", "1 MiB", "1MB", "-1", "1.5GiB", "99999999999GiB"] {
    #expect(throws: ValidationError.self) { try ByteCount(parsing: bad) }
  }
}

@Test func vaultReferencesNameOnlyValidStoredSecrets() throws {
  #expect(SecretName.vaultReference("vault:api-key") == (try SecretName("api-key")))
  #expect(SecretName.vaultReference("cmd:printf x") == nil)
  #expect(SecretName.vaultReference("github_pat_x") == nil)
  #expect(SecretName.vaultReference("vault:") == nil)
  #expect(SecretName.vaultReference("vault:bad name") == nil)
  #expect(SecretName.vaultReference("VAULT:name") == nil)
}

@Test func sessionTTLParsesAndBounds() throws {
  #expect(try SessionTTL(parsing: "8h").seconds == 8 * 3600)
  #expect(try SessionTTL(parsing: "90m").description == "90m")
  #expect(try SessionTTL(parsing: "3600").description == "1h")
  #expect(try SessionTTL(seconds: 61).description == "61s")
  for bad in ["", "30s", "59", "721h", "1d", "-1h", "h"] {
    #expect(throws: ValidationError.self, "\(bad)") { try SessionTTL(parsing: bad) }
  }
}
