// Property tests for the CONNECT gate: hostnames, allowlist matching, head
// parsing and the capability check, each against an independent model.

import Foundation
import Testing

@testable import IsoEgressCore

// MARK: - Hostnames

/// The documented exact-hostname grammar, written independently: printable
/// ASCII, at most one trailing dot, two or more 1–63 byte LDH labels with no
/// edge hyphen, 253 bytes, and not every label numeric. Returns the
/// canonical (lowercase, no trailing dot) name, or nil when refused.
private func modelHostname(_ raw: String) -> String? {
  var bytes = Array(raw.utf8)
  guard !bytes.isEmpty, raw.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
    return nil
  }
  if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
  bytes = bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
  guard !bytes.isEmpty, bytes.count <= 253 else { return nil }
  let labels = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
  guard labels.count >= 2 else { return nil }
  for label in labels {
    guard (1...63).contains(label.count), label.first != 0x2D, label.last != 0x2D,
      label.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D })
    else { return nil }
  }
  if labels.allSatisfy({ $0.allSatisfy { (0x30...0x39).contains($0) } }) { return nil }
  return String(decoding: bytes, as: UTF8.self)
}

private let labelPool = [
  "a", "b", "api", "github", "Example", "x-1", "0a", "123", "XN--P1AI", "co",
  String(repeating: "l", count: 63),
]
private let hostilePieces = [
  "", "-", "-a", "a-", "..", "@", ":", ":443", "%2e", "%", "*", "[", "]", "/", "\\", "?", "#",
  " ", "\t", "\u{0}", "\u{7F}", "é", "\u{FF0E}", "\u{200B}", String(repeating: "m", count: 64),
]

/// A hostname-shaped string: LDH labels, sometimes one hostile piece, an
/// odd case or a trailing dot, sometimes past the length limits.
private func hostText(_ rng: inout PropertyRNG) -> String {
  var labels = (0..<rng.int(1...4)).map { _ in rng.element(labelPool) }
  if rng.oneIn(12) { labels = Array(repeating: String(repeating: "q", count: 63), count: 4) }
  if rng.oneIn(4) {
    let index = rng.below(labels.count)
    let piece = rng.element(hostilePieces)
    labels[index] = rng.oneIn(2) ? piece : labels[index] + piece
  }
  if rng.oneIn(8) { labels = labels.map { _ in String(rng.int(0...255)) } }
  var host = labels.joined(separator: ".")
  if rng.oneIn(5) { host += "." }
  if rng.oneIn(6) { host = host.uppercased() }
  return host
}

@Test func exactHostnameMatchesTheGrammarAndIsCanonical() {
  expectHolds(
    checkProperty("ExactHostname matches the grammar", iterations: 2000, generate: hostText) {
      raw in
      let expected = modelHostname(raw)
      let parsed = try? ExactHostname(raw)
      guard parsed?.rawValue == expected else {
        return "parsed \(parsed?.rawValue ?? "nil"), model \(expected ?? "nil")"
      }
      if let parsed, (try? ExactHostname(parsed.rawValue)) != parsed {
        return "canonical form \(parsed.rawValue) does not round-trip"
      }
      return nil
    })
}

// MARK: - Allowlist

private struct AllowCase: CustomStringConvertible {
  let rules: [String]
  let host: String
  var description: String { "rules \(rules) host \(host)" }
}

/// `*.suffix` matches one or more whole labels below the suffix; an exact
/// rule matches only itself.
private func modelAllows(rules: [String], host: String) -> Bool {
  let labels = host.split(separator: ".")
  return rules.contains { rule in
    if rule.hasPrefix("*.") {
      let suffix = rule.dropFirst(2).split(separator: ".")
      return labels.count > suffix.count && Array(labels.suffix(suffix.count)) == suffix
    }
    return rule == host
  }
}

@Test func allowlistMatchesWholeLabelsOnly() {
  // A tiny alphabet so rules and hosts share suffixes, prefixes and labels.
  let small = ["a", "b", "ab", "ba", "c-d"]
  func name(_ rng: inout PropertyRNG, labels: ClosedRange<Int>) -> String {
    (0..<rng.int(labels)).map { _ in rng.element(small) }.joined(separator: ".")
  }
  expectHolds(
    checkProperty(
      "EgressAllowlist matches whole labels", iterations: 2000,
      generate: { rng in
        let rules = (0..<rng.int(0...4)).map { _ in
          rng.oneIn(2) ? "*." + name(&rng, labels: 3...4) : name(&rng, labels: 2...5)
        }
        var host = name(&rng, labels: 2...6)
        // A host built on a rule exercises the boundaries exactly.
        if let rule = rules.first, rng.oneIn(2) {
          let base = rule.hasPrefix("*.") ? String(rule.dropFirst(2)) : rule
          host = rng.element([base, "a." + base, "a" + base, "b.a." + base])
        }
        return AllowCase(rules: rules, host: host)
      },
      property: { input in
        guard let rules = try? input.rules.map(HostRule.init),
          let host = try? ExactHostname(input.host)
        else { return "generated an invalid rule or host" }
        let allowed = EgressAllowlist(rules: rules).allows(host)
        let expected = modelAllows(rules: input.rules, host: input.host)
        return allowed == expected ? nil : "allows \(allowed), model \(expected)"
      }))
}

// MARK: - Head terminator

@Test func headTerminatorTakesThroughTheFirstBlankLine() {
  let alphabet: [UInt8] = [13, 13, 10, 10, 0x61]
  expectHolds(
    checkProperty(
      "HeadTerminator.take stops at the first CRLFCRLF", iterations: 3000,
      generate: { rng -> ([UInt8], [UInt8]) in
        var head = (0..<rng.int(0...8)).map { _ in rng.element(alphabet) }
        // `head` is what readHead holds so far: it never contains a terminator.
        while head.count >= 4,
          (0...(head.count - 4)).contains(where: {
            Array(head[$0..<($0 + 4)]) == [13, 10, 13, 10]
          })
        {
          head.removeLast()
        }
        return (head, (0..<rng.int(0...10)).map { _ in rng.element(alphabet) })
      },
      property: { head, next in
        let joined = head + next
        var expected = next.count
        for end in head.count..<joined.count where end >= 3 {
          if Array(joined[(end - 3)...end]) == [13, 10, 13, 10] {
            expected = end - head.count + 1
            break
          }
        }
        let took = HeadTerminator.take(after: head, next: next[...])
        return took == expected ? nil : "took \(took), model \(expected)"
      }))
}

// MARK: - CONNECT heads and the capability

private enum HeaderKind: CustomStringConvertible {
  /// `Proxy-Authorization` for user `iso` with this password.
  case auth(String)
  /// A `Proxy-Authorization` that carries no usable `iso` password.
  case badAuth
  /// `Host` with this value.
  case host(String)
  case framing
  case benign
  case malformed

  var description: String {
    switch self {
    case .auth: "auth"
    case .badAuth: "badAuth"
    case .host(let value): "host(\(value))"
    case .framing: "framing"
    case .benign: "benign"
    case .malformed: "malformed"
    }
  }
}

private struct ConnectCase: CustomStringConvertible {
  let head: [UInt8]
  let lineIsConnect: Bool
  /// The bytes between `CONNECT ` and ` HTTP/1.1`.
  let target: String
  let headers: [HeaderKind]
  let capability: String
  let allowed: [String]
  var description: String {
    "head \(String(decoding: head, as: UTF8.self)) kinds \(headers) capability \(capability) allow \(allowed)"
  }
}

/// A `Host` value naming the target, a variant of it, or another authority.
private func hostHeader(_ rng: inout PropertyRNG, hostPart: String) -> String {
  rng.element([
    hostPart, hostPart + ":443", hostPart.uppercased(), " " + hostPart + "\t", " " + hostPart,
    "evil.example", hostPart + ":80", hostPart + ".evil", "", hostPart + ":", hostPart + ":0443",
  ])
}

/// The authority a `Host` value names when it is a valid name with an
/// optional `:443`: surrounding blanks are ignored.
private func modelHostHeader(_ value: String) -> String? {
  var text = Substring(value)
  while let first = text.first, first == " " || first == "\t" { text.removeFirst() }
  while let last = text.last, last == " " || last == "\t" { text.removeLast() }
  if text.hasSuffix(":443") { text.removeLast(4) }
  return modelHostname(String(text))
}

private func basic(_ credentials: String) -> String {
  "Basic " + Data(credentials.utf8).base64EncodedString()
}

private func connectCase(_ rng: inout PropertyRNG) -> ConnectCase {
  let hostPart = hostText(&rng)
  let port =
    rng.oneIn(4) ? rng.element(["", "80", "0443", "+443", "443 ", "4430", "443:443"]) : "443"
  var target = hostPart + ":" + port
  switch rng.below(10) {
  case 0: target = "iso@" + target
  case 1: target = hostPart
  case 2: target = "https://" + target
  case 3: target = "[::1]:" + port
  default: break
  }
  var line = "CONNECT " + target + " HTTP/1.1"
  var lineIsConnect = true
  if rng.oneIn(10) {
    line = rng.element([
      "connect " + target + " HTTP/1.1", "CONNECT " + target + " HTTP/1.0",
      "GET " + target + " HTTP/1.1", "CONNECT  " + target + " HTTP/1.1",
      "CONNECT " + target + " HTTP/1.1 x",
    ])
    lineIsConnect = false
  }
  let password = String(
    (0..<rng.int(0...12)).map { _ in rng.element(Array("abcXYZ019:@ =+/-_~é")) })
  var kinds: [HeaderKind] = []
  var lines: [String] = []
  for _ in 0..<rng.int(0...5) {
    let kind: HeaderKind =
      switch rng.below(7) {
      case 0, 1: .auth(password)
      case 2: .badAuth
      case 3: .host(hostHeader(&rng, hostPart: hostPart))
      case 4: rng.oneIn(3) ? .framing : .benign
      case 5: .benign
      default: rng.oneIn(2) ? .malformed : .benign
      }
    kinds.append(kind)
    switch kind {
    case .auth(let password):
      let name = rng.element(["Proxy-Authorization", "proxy-authorization", "PROXY-AUTHORIZATION"])
      let scheme = rng.element(["Basic ", "basic ", "BASIC "])
      let value = scheme + Data(("iso:" + password).utf8).base64EncodedString()
      lines.append(
        name + ":" + rng.element(["", " ", "\t", "  "]) + value + rng.element(["", " "]))
    case .badAuth:
      lines.append(
        "Proxy-Authorization: "
          + rng.element([
            basic("ISO:" + password), basic("root:" + password), basic("iso"), "Bearer x",
            "Basic !!!", "Basic", basic(" iso:" + password),
          ]))
    case .host(let value):
      lines.append(rng.element(["Host", "host", "HOST"]) + ":" + value)
    case .framing:
      lines.append(rng.element(["Transfer-Encoding: chunked", "content-length: 0"]))
    case .benign:
      lines.append(rng.element(["User-Agent: curl/8", "X-Thing:", "Accept: */*", "a:b\tc"]))
    case .malformed:
      lines.append(rng.element(["No colon", "Bad Name: x", ": empty", "X: a\u{1}b", "X: \u{7F}"]))
    }
  }
  let head = Array((([line] + lines).joined(separator: "\r\n") + "\r\n\r\n").utf8)
  let capability =
    rng.oneIn(2)
    ? password
    : rng.element([
      "", password + "x", "x" + password, String(password.dropLast()), password.uppercased(),
      password + " ",
    ])
  let allowed = (0..<rng.int(0...2)).map { _ in
    rng.oneIn(2) ? hostPart : rng.element(["github.com", "api.github.com", "example.co"])
  }
  return ConnectCase(
    head: head, lineIsConnect: lineIsConnect, target: target, headers: kinds,
    capability: capability, allowed: allowed)
}

/// The request a generated head must parse to: the request line is exactly
/// `CONNECT <host>:443 HTTP/1.1` for a valid host, every header line is well
/// formed, nothing frames a body, any `Host` names the target, and exactly
/// one `iso` credential is present.
private func expectedRequest(_ input: ConnectCase) -> (host: String, password: String)? {
  guard input.lineIsConnect, input.target.hasSuffix(":443"),
    let host = modelHostname(String(input.target.dropLast(4)))
  else { return nil }
  var password: String?
  var auths = 0
  var hosts = 0
  for kind in input.headers {
    switch kind {
    case .auth(let value):
      auths += 1
      password = value
    case .badAuth: auths += 1
    case .host(let value):
      hosts += 1
      if modelHostHeader(value) != host { return nil }
    case .framing, .malformed: return nil
    case .benign: break
    }
  }
  guard auths == 1, hosts <= 1, let password else { return nil }
  return (host, password)
}

@Test func connectParserYieldsOnlyTheRequestLineAuthority() {
  expectHolds(
    checkProperty(
      "ConnectParser parses exactly the generated authority", iterations: 3000,
      generate: connectCase,
      property: { input in
        let expected = expectedRequest(input)
        let parsed = try? ConnectParser.parse(input.head)
        switch (parsed, expected) {
        case (nil, nil): return nil
        case (let parsed?, let expected?):
          guard parsed.host.rawValue == expected.host, parsed.port == 443,
            parsed.password == expected.password
          else { return "parsed \(parsed.host):\(parsed.port), expected \(expected.host):443" }
          return nil
        case (let parsed?, nil): return "accepted \(parsed.host):\(parsed.port); model refuses"
        case (nil, _?): return "refused a well-formed CONNECT"
        }
      }))
}

@Test func connectGateConnectsOnlyWithTheExactCapabilityToAnAllowedHost() {
  expectHolds(
    checkProperty(
      "ConnectGate.decide admits exactly the capability and allowlist", iterations: 3000,
      generate: connectCase,
      property: { input in
        let rules = input.allowed.compactMap { try? HostRule($0) }
        let decision = ConnectGate.decide(
          input.head, allow: EgressAllowlist(rules: rules), capability: input.capability)
        guard let expected = expectedRequest(input) else {
          if case .connect(let host) = decision {
            return "connected to \(host) from a refused head"
          }
          return nil
        }
        guard expected.password == input.capability else {
          return decision == .deny(.credentialsRequired)
            ? nil : "a different capability gave \(decision)"
        }
        let allowed = rules.contains { $0.rawValue == expected.host }
        let want: ConnectDecision = allowed ? .connect(expected.host) : .deny(.hostNotAllowed)
        return decision == want ? nil : "decided \(decision), model \(want)"
      }))
}
