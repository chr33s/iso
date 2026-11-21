// Property tests for the configuration pipeline (JSONC scan, preflight,
// decode, validation, `ConfigEditor.encode`) over generated documents; the
// generator and reproduction knobs are in IsoPropertyTesting.

import Foundation
import IsoCore
import IsoPropertyTesting
import Testing

@testable import IsoConfiguration

private func expectHolds(
  _ failure: PropertyFailure?, sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
  if let failure {
    Issue.record(Comment(rawValue: failure.description), sourceLocation: sourceLocation)
  }
}

// MARK: - Generators

/// Text weighted toward what breaks JSON quoting and comment scanning:
/// comment markers, quotes and backslashes, controls, and an occasional
/// long run.
private func text(_ rng: inout PropertyRNG) -> String {
  if rng.oneIn(40) { return String(repeating: rng.string(maxScalars: 4), count: 600) }
  var out = ""
  for _ in 0..<rng.int(0...3) {
    out +=
      rng.oneIn(3)
      ? rng.element(["//", "/*", "*/", "\"", "\\", "\\\"", "*", "/", ",", "}", "]", "\u{0}"])
      : rng.string(maxScalars: 8)
  }
  return out
}

/// A guest-placed secret: anything but a `vault:` reference.
private func guestSecret(_ rng: inout PropertyRNG) -> String {
  let value = rng.oneIn(2) ? "cmd:" + text(&rng) : text(&rng)
  return SecretName.isVaultReference(value) ? "x" + value : value
}

private func envName(_ rng: inout PropertyRNG) -> String {
  let first = rng.element(Array("ABCxyz_"))
  return String(first) + String((0..<rng.int(0...8)).map { _ in rng.element(Array("AZaz09_")) })
}

private func secretName(_ rng: inout PropertyRNG) -> String {
  String(rng.element(Array("a0Z")))
    + String((0..<rng.int(0...10)).map { _ in rng.element(Array("az09._-")) })
}

/// A map key: plain, punctuated, or arbitrary Unicode (rendered in brackets
/// in field paths).
private func mapKey(_ rng: inout PropertyRNG) -> String {
  rng.oneIn(3) ? rng.string(maxScalars: 6) : rng.element(["s", "my-server", "a.b", "x y", "é"])
}

private func object(_ rng: inout PropertyRNG, _ build: (inout PropertyRNG) -> JSONValue)
  -> JSONValue
{
  var members: [String: JSONValue] = [:]
  for _ in 0..<rng.int(0...3) { members[mapKey(&rng)] = build(&rng) }
  return .object(members)
}

private func strings(_ rng: inout PropertyRNG, _ element: (inout PropertyRNG) -> String)
  -> JSONValue
{
  .array((0..<rng.int(0...3)).map { _ in .string(element(&rng)) })
}

private func int(_ value: Int) -> JSONValue { .number(.integer(Int64(value))) }

private func mcpServer(_ rng: inout PropertyRNG, agent: String) -> JSONValue {
  if rng.oneIn(2) {
    var env: [String: JSONValue] = [:]
    for _ in 0..<rng.int(0...3) {
      let name = envName(&rng)
      // Codex passes a variable only under its own name.
      env[name] = .string(agent == "codex" || rng.oneIn(2) ? name : envName(&rng))
    }
    var server: [String: JSONValue] = ["command": .string(text(&rng) + "x")]
    if rng.oneIn(2) { server["args"] = strings(&rng, text) }
    if rng.oneIn(2) { server["env"] = .object(env) }
    if rng.oneIn(3) { server["type"] = .string("stdio") }
    return .object(server)
  }
  var headers: [String: JSONValue] = [:]
  for _ in 0..<rng.int(0...2) { headers[mapKey(&rng)] = .string(guestSecret(&rng)) }
  let kind = agent == "claude" && rng.oneIn(2) ? "sse" : "http"
  return .object([
    "type": .string(kind),
    "url": .string("https://example.com/" + rng.element(["", "mcp", "a/b?c=d"])),
    "headers": .object(headers),
  ])
}

private func agent(_ rng: inout PropertyRNG, _ name: String) -> JSONValue {
  var section: [String: JSONValue] = [:]
  if rng.oneIn(2) { section["api_key"] = .string(guestSecret(&rng)) }
  if rng.oneIn(2) { section["env_forward"] = strings(&rng, envName) }
  if rng.oneIn(2) { section["plugins"] = strings(&rng, text) }
  if rng.oneIn(3) { section["marketplaces"] = strings(&rng, text) }
  if rng.oneIn(3) {
    section["config_dir"] = rng.oneIn(2) ? .bool(false) : .string("~/" + text(&rng))
  }
  if rng.oneIn(2) { section["mcp_servers"] = object(&rng) { mcpServer(&$0, agent: name) } }
  return .object(section)
}

private func upstream(_ rng: inout PropertyRNG, schemes: [String]) -> JSONValue {
  .object([
    // `cmd:` is a Character prefix: a combining mark right after it would
    // make the value a literal, which a proxy credential refuses.
    "credential": .string(rng.oneIn(2) ? "cmd: " + text(&rng) : "vault:" + secretName(&rng)),
    "auth": .string(rng.element(schemes)),
  ])
}

/// A configuration the decoder documents as valid, each section present
/// about half the time.
private func validConfiguration(_ rng: inout PropertyRNG) -> [String: JSONValue] {
  var root: [String: JSONValue] = [:]
  if rng.oneIn(2) {
    let path = rng.path(maxComponents: 3, ["a", "x y", "é", ".iso", ".."])
    root["data_dir"] = .string(rng.oneIn(5) ? "~" : rng.element(["/", "~/"]) + path)
  }
  if rng.oneIn(2) {
    root["vm"] = .object([
      "vcpu_count": int(rng.int(1...255)), "mem_size_mib": int(rng.int(128...1 << 20)),
      "template_size_gib": int(rng.int(1...4096)),
    ])
  }
  if rng.oneIn(3) { root["ssh_port"] = int(rng.int(1...65535)) }
  if rng.oneIn(3) { root["setup"] = .object(["prompt_for_pat": .bool(rng.oneIn(2))]) }
  if rng.oneIn(2) {
    var env: [String: JSONValue] = [:]
    for _ in 0..<rng.int(0...4) { env[envName(&rng)] = .string(text(&rng)) }
    root["guest_env"] = .object(env)
  }
  if rng.oneIn(2) { root["post_start"] = .string(text(&rng)) }
  if rng.oneIn(3) {
    root["updates"] = .object([
      "mode": .string(rng.element(["off", "notify"])),
      "check_interval_hours": rng.oneIn(2) ? int(rng.int(0...1000)) : .number(.unsigned(.max)),
    ])
  }
  if rng.oneIn(3) { root["egress"] = .string(rng.element(["none", "filtered"])) }
  if rng.oneIn(2) { root["claude"] = agent(&rng, "claude") }
  if rng.oneIn(2) { root["codex"] = agent(&rng, "codex") }
  if rng.oneIn(2) {
    var proxy: [String: JSONValue] = ["mode": .string(rng.element(["auto", "required", "off"]))]
    if rng.oneIn(2) { proxy["anthropic"] = upstream(&rng, schemes: ["api_key", "bearer"]) }
    if rng.oneIn(2) { proxy["openai"] = upstream(&rng, schemes: ["bearer"]) }
    root["proxy"] = .object(proxy)
  }
  if rng.oneIn(4) { root["limits"] = .object(["session_ttl": .string("unlimited")]) }
  return root
}

private func decode(_ value: JSONValue) -> Result<IsoConfig, ConfigError> {
  Result { () throws(ConfigError) in
    try ConfigLoader.decode(value, path: "prop", environment: fixtureHome)
  }
}

private func parse(_ text: String, _ format: ConfigFormat) -> Result<JSONValue, ConfigError> {
  Result { () throws(ConfigError) in
    try ConfigLoader.parse(Array(text.utf8), format: format, path: "prop", limits: .configuration)
  }
}

/// Free-form strings of the decoded snapshot, compared scalar by scalar:
/// `String ==` is canonical equivalence and would hide a normalizing trip.
private func scalars(_ config: IsoConfig) -> [[UInt32]] {
  var out = [config.postStart ?? ""] + config.guestEnvironment.map(\.value)
  for agent in [config.claude, config.codex] {
    out += [agent.apiKey?.expose() ?? ""] + agent.plugins + agent.marketplaces
  }
  return out.map { $0.unicodeScalars.map(\.value) }
}

// MARK: - JSONC rendering

/// Renders `value` as JSONC with generated whitespace and comments between
/// tokens, optional `\u` escapes in strings, and optionally one trailing
/// comma in the `trailingCommaAt`-th non-empty container.
private struct JSONCPrinter {
  var rng: PropertyRNG
  var noisy: Bool
  var trailingCommaAt: Int?
  var containers = 0
  var out = ""

  mutating func gap() {
    guard noisy else { return }
    for _ in 0..<rng.int(0...2) {
      switch rng.below(5) {
      case 0: out += rng.element([" ", "\t", "\n", "\r\n", "  "])
      case 1:
        // Line comment: anything but a newline, including `*/` and quotes.
        out += "//" + Self.lineCommentBody(text(&rng)) + "\n"
      case 2: out += "/*" + Self.blockCommentBody(text(&rng)) + " */"
      case 3: out += "/**/"
      default: out += " "
      }
    }
  }

  // Comment bodies are edited scalar by scalar: Foundation's
  // `replacingOccurrences` skips a match followed by a combining mark.

  static func lineCommentBody(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\n" }))
  }

  /// `text` with a space after every `*` so it cannot close the comment.
  static func blockCommentBody(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      out.append(scalar)
      if scalar == "*" { out.append(" ") }
    }
    return String(out)
  }

  mutating func string(_ value: String) {
    out += "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "/" where noisy && rng.oneIn(3): out += "\\/"
      case _ where scalar.value < 0x20 || (noisy && rng.oneIn(6)):
        for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
      default: out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
  }

  mutating func comma(closing members: Int) {
    guard members > 0 else { return }
    containers += 1
    if containers - 1 == trailingCommaAt {
      out += ","
      gap()
    }
  }

  mutating func value(_ value: JSONValue) {
    gap()
    switch value {
    case .null: out += "null"
    case .bool(let flag): out += flag ? "true" : "false"
    case .number(let number): out += number.description
    case .string(let text): string(text)
    case .array(let elements):
      out += "["
      for (index, element) in elements.enumerated() {
        if index > 0 { out += "," }
        self.value(element)
        gap()
      }
      comma(closing: elements.count)
      out += "]"
    case .object(let members):
      out += "{"
      for (index, key) in members.keys.sorted().enumerated() {
        if index > 0 { out += "," }
        gap()
        string(key)
        gap()
        out += ":"
        self.value(members[key]!)
        gap()
      }
      comma(closing: members.count)
      out += "}"
    }
    gap()
  }

  static func render(_ value: JSONValue, rng: PropertyRNG, noisy: Bool, trailingCommaAt: Int? = nil)
    -> String
  {
    var printer = JSONCPrinter(rng: rng, noisy: noisy, trailingCommaAt: trailingCommaAt)
    printer.value(value)
    return printer.out + "\n"
  }
}

private func nonEmptyContainers(_ value: JSONValue) -> Int {
  switch value {
  case .array(let elements):
    (elements.isEmpty ? 0 : 1) + elements.map(nonEmptyContainers).reduce(0, +)
  case .object(let members):
    (members.isEmpty ? 0 : 1) + members.values.map(nonEmptyContainers).reduce(0, +)
  default: 0
  }
}

// MARK: - Round trips

@Test func generatedConfigurationsSurviveEncodingAndReloadingExactly() {
  expectHolds(
    checkProperty(
      "ConfigEditor.encode/ConfigLoader round trip", iterations: 300,
      generate: { rng in JSONValue.object(validConfiguration(&rng)) },
      property: { (value: JSONValue) -> String? in
        guard case .success(let config) = decode(value) else {
          return "generated configuration refused: \(decode(value))"
        }
        guard let bytes = try? ConfigEditor.encode(value, path: "prop") else {
          return "valid configuration did not encode"
        }
        for format in [ConfigFormat.json, .jsonc] {
          guard case .success(let reread) = parse(String(decoding: bytes, as: UTF8.self), format)
          else { return "encoded document did not parse as \(format)" }
          guard reread.semanticallyEquals(value) else { return "structural round trip differs" }
          guard case .success(let again) = decode(reread) else {
            return "encoded document refused on reload"
          }
          guard again == config, scalars(again) == scalars(config) else {
            return "reloaded snapshot differs"
          }
        }
        return nil
      }))
}

@Test func commentsWhitespaceAndEscapesNeverChangeTheSnapshot() {
  expectHolds(
    checkProperty(
      "JSONC noise equivalence", iterations: 300,
      generate: { rng -> (JSONValue, PropertyRNG) in
        let value = JSONValue.object(validConfiguration(&rng))
        return (value, PropertyRNG(seed: rng.next()))
      },
      property: { (value: JSONValue, noise: PropertyRNG) -> String? in
        let plain = JSONCPrinter.render(value, rng: noise, noisy: false)
        let noisy = JSONCPrinter.render(value, rng: noise, noisy: true)
        let fromJSON: JSONValue
        let fromJSONC: JSONValue
        switch (parse(plain, .json), parse(noisy, .jsonc)) {
        case (.success(let a), .success(let b)):
          fromJSON = a
          fromJSONC = b
        case (.failure(let error), _): return "plain JSON refused: \(error)"
        case (_, .failure(let error)): return "JSONC refused: \(error)\n  document: \(noisy)"
        }
        guard fromJSON == value, fromJSONC == value else { return "parsed value differs" }
        guard case .success(let a) = decode(fromJSON), case .success(let b) = decode(fromJSONC),
          a == b, scalars(a) == scalars(b)
        else { return "snapshots differ" }
        return nil
      }))
}

@Test func trailingCommasAreRefusedWhereverTheyAppear() {
  expectHolds(
    checkProperty(
      "configuration refuses trailing commas", iterations: 300,
      generate: { rng -> (JSONValue, PropertyRNG, Bool, Int) in
        var root = validConfiguration(&rng)
        root["post_start"] = .string(text(&rng))
        let value = JSONValue.object(root)
        let noise = PropertyRNG(seed: rng.next())
        return (value, noise, rng.oneIn(2), rng.below(nonEmptyContainers(value)))
      },
      property: { (value: JSONValue, noise: PropertyRNG, noisy: Bool, at: Int) -> String? in
        let document = JSONCPrinter.render(
          value, rng: noise, noisy: noisy, trailingCommaAt: at)
        guard case .failure(.preflight) = parse(document, .jsonc) else {
          return "trailing comma accepted: \(parse(document, .jsonc))"
        }
        return nil
      }))
}

// MARK: - Refusals

/// A configuration this release refuses at load, with the field the
/// refusal must name.
private enum Refusal: CustomStringConvertible {
  case relativeDataDir(String)
  case vaultAPIKey(agent: String, value: String)
  case vaultHeader(agent: String, server: String, header: String, value: String)
  case codexSSE(server: String)
  case codexRename(server: String, from: String, to: String)

  var description: String {
    switch self {
    case .relativeDataDir(let raw): "data_dir \(printable(raw))"
    case .vaultAPIKey(let agent, _): "\(agent).api_key vault"
    case .vaultHeader(let agent, let server, let header, _):
      "\(agent) MCP \(printable(server)) header \(printable(header)) vault"
    case .codexSSE(let server): "codex MCP \(printable(server)) sse"
    case .codexRename(let server, let from, let to):
      "codex MCP \(printable(server)) env \(from)->\(to)"
    }
  }

  var field: String {
    switch self {
    case .relativeDataDir: "data_dir"
    case .vaultAPIKey(let agent, _): "\(agent).api_key"
    case .vaultHeader(let agent, let server, let header, _):
      renderPath([.key(agent), .key("mcp_servers"), .key(server), .key("headers"), .key(header)])
    case .codexSSE(let server):
      renderPath([.key("codex"), .key("mcp_servers"), .key(server), .key("type")])
    case .codexRename(let server, let from, _):
      renderPath([.key("codex"), .key("mcp_servers"), .key(server), .key("env"), .key(from)])
    }
  }

  /// A guest-placed value the refusal must not echo.
  var secret: String? {
    switch self {
    case .vaultAPIKey(_, let value), .vaultHeader(_, _, _, let value): value
    default: nil
    }
  }

  static let canary = "PROPCANARY"

  static func generate(_ rng: inout PropertyRNG) -> Refusal {
    let server = mapKey(&rng)
    switch rng.below(5) {
    case 0:
      var raw = rng.element(["", ".", "..", "./x", "../x", "rel", "~user/x", "~x", " /abs", "\t~/"])
      if rng.oneIn(2) { raw += rng.path(maxComponents: 3, ["a", "/", "..", "é", "~"]) }
      // `~` alone and `~/…` expand under the home, and `/…` is absolute.
      if raw.hasPrefix("/") || raw.hasPrefix("~/") || raw == "~" { raw = "rel" + raw }
      return .relativeDataDir(raw)
    case 1:
      return .vaultAPIKey(
        agent: rng.element(["claude", "codex"]), value: "vault:" + canary + text(&rng))
    case 2:
      return .vaultHeader(
        agent: rng.element(["claude", "codex"]), server: server, header: mapKey(&rng),
        value: "vault:" + rng.element([canary, canary + secretName(&rng)]))
    case 3: return .codexSSE(server: server)
    default:
      let from = envName(&rng)
      var to = envName(&rng)
      if to == from { to += "_" }
      return .codexRename(server: server, from: from, to: to)
    }
  }

  func apply(to root: inout [String: JSONValue]) {
    func section(_ agent: String, _ edit: (inout [String: JSONValue]) -> Void) {
      var members: [String: JSONValue] = [:]
      if case .object(let existing)? = root[agent] { members = existing }
      edit(&members)
      root[agent] = .object(members)
    }
    func server(_ agent: String, _ name: String, _ value: JSONValue) {
      section(agent) { members in
        var servers: [String: JSONValue] = [:]
        if case .object(let existing)? = members["mcp_servers"] { servers = existing }
        servers[name] = value
        members["mcp_servers"] = .object(servers)
      }
    }
    switch self {
    case .relativeDataDir(let raw):
      root["data_dir"] = .string(raw)
    case .vaultAPIKey(let agent, let value):
      section(agent) { $0["api_key"] = .string(value) }
    case .vaultHeader(let agent, let name, let header, let value):
      server(
        agent, name,
        .object([
          "type": .string("http"), "url": .string("https://example.com/mcp"),
          "headers": .object([header: .string(value)]),
        ]))
    case .codexSSE(let name):
      server("codex", name, .object(["type": .string("sse"), "url": .string("https://e.x/sse")]))
    case .codexRename(let name, let from, let to):
      server(
        "codex", name,
        .object([
          "command": .string("srv"),
          "env": .object([from: .string(to), "ZZ_SAME": .string("ZZ_SAME")]),
        ]))
    }
  }

  /// The same entry under Claude, which accepts SSE and renaming `env`.
  var claudeCounterpart: Refusal? {
    switch self {
    case .codexSSE, .codexRename: self
    default: nil
    }
  }
}

@Test func documentedRefusalsAreNeverAcceptedAndNameTheirField() {
  expectHolds(
    checkProperty(
      "configuration refusals", iterations: 400,
      generate: { rng -> ([String: JSONValue], Refusal) in
        (validConfiguration(&rng), Refusal.generate(&rng))
      },
      property: { (base: [String: JSONValue], refusal: Refusal) -> String? in
        var root = base
        refusal.apply(to: &root)
        switch decode(.object(root)) {
        case .success: return "accepted"
        case .failure(.invalidField(_, let field, let reason)):
          guard field == refusal.field else { return "named \(field), expected \(refusal.field)" }
          if refusal.secret != nil, reason != SecretName.guestPlacementRefusal {
            return "unexpected reason \(reason)"
          }
          if refusal.secret != nil, reason.contains(Refusal.canary) {
            return "reason echoes the value"
          }
        case .failure(let other): return "unexpected error \(other)"
        }
        // Claude registers SSE servers and renamed variables itself.
        if refusal.claudeCounterpart != nil, case .object(let codex)? = root["codex"] {
          var swapped = base
          swapped["claude"] = .object(codex.filter { $0.key == "mcp_servers" })
          guard case .success = decode(.object(swapped)) else {
            return "claude refused the same MCP servers: \(decode(.object(swapped)))"
          }
        }
        return nil
      }))
}
