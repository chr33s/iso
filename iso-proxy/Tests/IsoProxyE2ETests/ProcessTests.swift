import CryptoKit
import Foundation
import IsoProxyTestSupport
import Testing

private let secret = "iso-process-test-secret-never-real"
private let token = String(repeating: "a", count: 64)

private func config(port: UInt16, provider: String = "anthropic") -> [String: Any] {
  [
    "version": 1, "listen": "127.0.0.1:\(port)", "provider": provider,
    "capability_token": token,
    "injection": [
      "scheme": provider == "anthropic" ? "x_api_key" : "bearer", "credential": secret,
    ],
  ]
}

private func confined(
  binary: URL, input: Int32, evidence: Evidence, name: String, profile: URL? = nil,
  arguments: [String] = []
) throws -> TestProcessRunner {
  try TestProcessRunner(
    executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
    arguments: [
      "-D", "PROXY_BIN=\(binary.path)", "-f",
      (profile ?? proxyRepository.appendingPathComponent("Sources/IsoHost/seatbelt-proxy.sb")).path,
      binary.path,
    ] + arguments,
    input: input, evidence: evidence, name: name)
}

private func redacted(_ data: Data, secrets: [String] = [secret, token]) throws {
  for value in secrets {
    try check(data.range(of: Data(value.utf8)) == nil, "synthetic secret leaked")
  }
}

private func ready(_ child: TestProcessRunner, port: UInt16) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    try check(try child.poll() == nil, "proxy exited before HTTP readiness: \(child.stderr.path)")
    if let response = try? request(port) {
      try check(response.starts(with: Data("HTTP/1.1 401".utf8)), "unauthenticated status")
      return
    }
    try await Task.sleep(for: .milliseconds(30))
  }
  throw ObservationFailure.invalid("proxy readiness deadline exceeded")
}

@Suite(.serialized)
struct IsoProxyProcessE2ETests {
  @Test func unconfinedRefusesBeforeReadingStdin() async throws {
    let evidence = try Evidence("unconfined")
    let stdin = Pipe()
    let child = try TestProcessRunner(
      executable: proxyBinary(), input: stdin.fileHandleForReading.fileDescriptor,
      evidence: evidence, name: "proxy")
    defer {
      child.cleanup()
      try? stdin.fileHandleForWriting.close()
      try? stdin.fileHandleForReading.close()
    }
    try check(try await child.wait() != 0, "unconfined startup accepted or waited for stdin")
    try redacted(child.output())
  }

  @Test func strictBoundedStartupRedactsDiagnostics() async throws {
    let evidence = try Evidence("startup")
    let binary = try proxyBinary()
    var invalid: [[String: Any]] = []
    for index in 0..<5 {
      var value = config(port: try freePort())
      switch index {
      case 0: value["version"] = 2
      case 1: value["listen"] = "0.0.0.0:8788"
      case 2: value["capability_token"] = "bad"
      case 3: value["upstream_host"] = secret
      default: value["injection"] = ["scheme": secret, "credential": secret]
      }
      invalid.append(value)
    }
    let inputs =
      try invalid.map { try JSONSerialization.data(withJSONObject: $0) } + [
        Data(repeating: 120, count: 65537)
      ]
    for (index, data) in inputs.enumerated() {
      let input = try inputFile(data, evidence: evidence, name: "case-\(index)")
      defer { try? input.close() }
      let child = try confined(
        binary: binary, input: input.fileDescriptor, evidence: evidence, name: "case-\(index)")
      defer { child.cleanup() }
      try check(try await child.wait() != 0, "invalid startup accepted")
      try redacted(child.output())
    }
  }

  @Test func productionProfileListenerSecretsAndShutdown() async throws {
    let evidence = try Evidence("listener")
    let port = try freePort()
    let input = try inputFile(
      JSONSerialization.data(withJSONObject: config(port: port)), evidence: evidence, name: "proxy")
    defer { try? input.close() }
    let child = try confined(
      binary: proxyBinary(), input: input.fileDescriptor, evidence: evidence, name: "proxy")
    defer { child.cleanup() }
    try await ready(child, port: port)
    try check(
      try request(port, headers: "Authorization: Bearer \(token)\r\n").starts(
        with: Data("HTTP/1.1 403".utf8)), "authenticated GET status")
    let null = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    defer { try? null.close() }
    let ps = try TestProcessRunner(
      executable: URL(fileURLWithPath: "/bin/ps"),
      arguments: ["-ww", "-p", String(child.pid), "-o", "command="], input: null.fileDescriptor,
      evidence: evidence, name: "argv")
    defer { ps.cleanup() }
    try check(try await ps.wait() == 0, "ps failed")
    try redacted(ps.output())
    let held = try LoopbackSocket()
    defer { held.close() }
    try held.connect(port: port)
    try held.send("POST /v1/")
    child.terminate()
    try check(try await child.wait() == 0, "proxy did not terminate cleanly")
    try check(try held.receive().isEmpty, "shutdown retained guest connection")
    try redacted(child.output())
  }

  @Test(arguments: ["anthropic", "openai"])
  func signedReadinessUsesIndependentPublicKey(provider: String) async throws {
    let evidence = try Evidence("readiness-\(provider)")
    let port = try freePort()
    let boot = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let policy = "sha256:" + String(repeating: "e", count: 64)
    let privateKey = String(repeating: "b", count: 64)
    var value = config(port: port, provider: provider)
    value["version"] = 2
    value["readiness"] = ["privateKeyHex": privateKey, "bootID": boot, "policyHash": policy]
    let input = try inputFile(
      JSONSerialization.data(withJSONObject: value), evidence: evidence, name: "proxy")
    defer { try? input.close() }
    let child = try confined(
      binary: proxyBinary(), input: input.fileDescriptor, evidence: evidence, name: "proxy")
    defer { child.cleanup() }
    try await ready(child, port: port)
    // Public key is an independently recorded vector, not derived from the configured private key.
    let hex = "7d59c5623dd40a74aa4d5a32ac645d3b3f95daeae4c22be25476dd6a486f7382"
    var publicBytes = Data()
    for offset in stride(from: 0, to: hex.count, by: 2) {
      let start = hex.index(hex.startIndex, offsetBy: offset)
      publicBytes.append(try #require(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)))
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    for _ in 0..<2 {
      let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      let wire = try request(
        port, headers: "X-Iso-Nonce: \(nonce)\r\n", target: "/__iso/broker-ready", host: "localhost"
      )
      try check(wire.count <= 1024, "unbounded readiness reply")
      let separator = try #require(wire.range(of: Data("\r\n\r\n".utf8)))
      let body = Data(wire[separator.upperBound...])
      let headers = String(decoding: wire[..<separator.lowerBound], as: UTF8.self).lowercased()
      try check(
        headers == "http/1.1 200 ok\r\ncontent-length: \(body.count)\r\nconnection: close",
        "readiness headers")
      let reply = Record(try #require(JSONSerialization.jsonObject(with: body) as? [String: Any]))
      try reply.keys(["version", "nonce", "provider", "bootID", "policyHash", "signature"])
      try check(
        try reply.integer("version") == 1 && reply.string("nonce") == nonce
          && reply.string("provider") == provider && reply.string("bootID") == boot
          && reply.string("policyHash") == policy, "readiness context")
      let signature = try #require(Data(base64Encoded: reply.string("signature")))
      let message = Data(
        "iso-broker-readiness-v1\n\(nonce)\n\(provider)\n\(boot)\n\(policy)\n".utf8)
      try check(key.isValidSignature(signature, for: message), "readiness signature")
      try check(
        !key.isValidSignature(Data(repeating: 0, count: 64), for: message),
        "invalid signature accepted")
      try redacted(wire, secrets: [secret, token, privateKey])
      let denied = try request(
        port, headers: "X-Iso-Nonce: \(nonce)\r\nAuthorization: Bearer \(token)\r\n",
        target: "/__iso/broker-ready", host: "localhost")
      try check(
        denied.starts(with: Data("HTTP/1.1 400".utf8)), "readiness accepted provider authorization")
    }
    child.terminate()
    try check(try await child.wait() == 0, "readiness shutdown")
    try redacted(child.output(), secrets: [secret, token, privateKey])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["ISO_PROXY_LIVE_TLS_GATE"] == "1"))
  func productionSystemTLSRequiresTrustdPermission() async throws {
    let evidence = try Evidence("live-system-tls")
    let binary = try proxyBinary()
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    defer { try? input.close() }
    let child = try confined(
      binary: binary, input: input.fileDescriptor, evidence: evidence, name: "production",
      arguments: ["--jail-selftest"])
    defer { child.cleanup() }
    try check(try await child.wait(seconds: 65) == 0, "production system TLS self-test")
    try check(
      try String(decoding: child.output(), as: UTF8.self).contains("DNS/system TLS passed"),
      "TLS self-test did not execute")
    let profile = try String(
      contentsOf: proxyRepository.appendingPathComponent("Sources/IsoHost/seatbelt-proxy.sb"),
      encoding: .utf8)
    let permission = "(allow mach-lookup (global-name \"com.apple.trustd.agent\"))"
    try check(
      profile.components(separatedBy: permission).count == 2, "trustd permission not unique")
    let mutant = evidence.file("without-trustd.sb")
    try profile.replacingOccurrences(of: permission, with: "").write(
      to: mutant, atomically: true, encoding: .utf8)
    let restricted = try confined(
      binary: binary, input: input.fileDescriptor, evidence: evidence, name: "restricted",
      profile: mutant, arguments: ["--jail-selftest"])
    defer { restricted.cleanup() }
    try check(try await restricted.wait(seconds: 65) != 0, "trustd removal did not break TLS")
    try check(
      try String(decoding: restricted.output(), as: UTF8.self).contains(
        "self-test failure category: NIOSSLError"), "unexpected TLS failure category")
  }
}
