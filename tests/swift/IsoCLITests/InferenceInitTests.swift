import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

private let environment = ConfigEnvironment(home: "/home/fixture", variables: [:])

private func initSettings(python: String? = "/opt/py/bin/python3", install: String? = nil)
  throws -> [([String], JSONValue)]
{
  try InferenceInit.settings(
    backend: "mlx-main", port: 18080, model: "/models/m", repo: nil, revision: nil,
    python: python, install: install, memoryLimit: "24GiB")
}

@Test func inferenceInitWritesAConfigThatResolves() throws {
  let (bytes, changed) = try ConfigEditor.applyDefaults(
    existing: nil, format: .jsonc, path: "c", settings: try initSettings(), force: false,
    environment: environment)
  #expect(changed.contains("inference.qualification_profiles.mlx-lm-0.31"))
  let config = try ConfigLoader.decode(
    try ConfigLoader.parse(bytes, format: .jsonc, path: "c", limits: .configuration), path: "c",
    environment: environment)
  #expect(config.inference.mode == .required)
  let resolved = try #require(config.inference.resolve(InferenceServiceName("local-chat")))
  #expect(resolved.backend.port == 18080)
  #expect(resolved.backend.managed?.memoryLimitBytes == 24 << 30)
  #expect(resolved.backend.runAs == ManagedBackendConfig.roleAccount)

  // Re-running is a no-op; a conflicting value needs --force.
  let again = try ConfigEditor.applyDefaults(
    existing: bytes, format: .jsonc, path: "c", settings: try initSettings(), force: false,
    environment: environment)
  #expect(again.changed.isEmpty)
  let other = try initSettings(python: nil, install: "0.31.3")
  #expect(throws: ConfigError.self) {
    _ = try ConfigEditor.applyDefaults(
      existing: bytes, format: .jsonc, path: "c", settings: other, force: false,
      environment: environment)
  }
  let forced = try ConfigEditor.applyDefaults(
    existing: bytes, format: .jsonc, path: "c", settings: other, force: true,
    environment: environment)
  #expect(forced.changed == ["inference.backends.mlx-main"])
}

@Test func inferenceInitRejectsAmbiguousSources() throws {
  #expect(throws: (any Error).self) { try initSettings(python: nil, install: nil) }
  #expect(throws: (any Error).self) { try initSettings(python: "/p", install: "0.31.3") }
  // The verified round-trip in applyDefaults enforces the configuration's
  // rules, such as an unprivileged port.
  let privileged = try InferenceInit.settings(
    backend: "mlx-main", port: 80, model: "/m", repo: nil, revision: nil, python: "/p",
    install: nil, memoryLimit: nil)
  #expect(throws: ConfigError.self) {
    _ = try ConfigEditor.applyDefaults(
      existing: nil, format: .jsonc, path: "c", settings: privileged, force: false,
      environment: environment)
  }
}

/// K1: the input bound fits the 32k context, the body bound the input, and
/// the stream-close drain covers that input's prefill at the qualified rate.
@Test func inferenceInitBoundsInputToTheContextWindow() throws {
  let (bytes, _) = try ConfigEditor.applyDefaults(
    existing: nil, format: .jsonc, path: "c", settings: try initSettings(), force: false,
    environment: environment)
  let config = try ConfigLoader.decode(
    try ConfigLoader.parse(bytes, format: .jsonc, path: "c", limits: .configuration), path: "c",
    environment: environment)
  let resolved = try #require(config.inference.resolve(InferenceServiceName("local-chat")))
  #expect(resolved.service.maxContextTokens == 32_768)
  #expect(resolved.profile.maxInputBytes == 128 << 10)
  #expect(resolved.profile.maxInputBytes <= 4 * resolved.service.maxContextTokens)
  #expect(resolved.profile.maxRequestBodyBytes == 256 << 10)
  // 32k tokens of prefill at about 3.3k tokens/s.
  let prefillMilliseconds = resolved.profile.maxInputBytes / 4 * 1000 / 3_300
  #expect(resolved.profile.streamCloseDrainMilliseconds >= prefillMilliseconds)
}

/// init leaves `network.transport` alone: a new configuration keeps the
/// brokered default, and a chosen transport stays chosen, even with --force.
@Test func inferenceInitLeavesTheTransportAlone() throws {
  #expect(!(try initSettings()).contains { $0.0.first == "network" })
  func transport(_ existing: String?, force: Bool = false) throws -> NetworkTransport {
    let (bytes, changed) = try ConfigEditor.applyDefaults(
      existing: existing.map { Array($0.utf8) }, format: .jsonc, path: "c",
      settings: try initSettings(), force: force, environment: environment)
    #expect(!changed.contains { $0.hasPrefix("network") })
    return try ConfigLoader.decode(
      try ConfigLoader.parse(bytes, format: .jsonc, path: "c", limits: .configuration), path: "c",
      environment: environment
    ).network.transport
  }
  #expect(try transport(nil) == .brokered)
  #expect(try transport(#"{"network": {"transport": "brokered"}}"#) == .brokered)
  #expect(try transport(#"{"network": {"transport": "vmnet"}}"#, force: true) == .vmnet)
}

/// K10: provisioning passes only with run-as, authentication and the token
/// challenge verified; `confinement: "none"` exempts only the sandbox.
@Test func provisioningVerificationExemptsOnlyConfinement() {
  var result = BackendVerification()
  result.runAs = .verified(account: "_isoinference")
  result.authenticated = true
  result.challenged = true
  result.confined = false
  #expect(InferenceProvision.passed(result, confinement: .none))
  #expect(!InferenceProvision.passed(result, confinement: .seatbelt))
  result.confined = true
  #expect(InferenceProvision.passed(result, confinement: .seatbelt))
  for change in [
    { (r: inout BackendVerification) in r.authenticated = false }, { $0.authenticated = nil },
    { $0.challenged = nil }, { $0.runAs = .notConfigured },
    { $0.runAs = .failed(account: "_isoinference", reason: "x") },
  ] as [(inout BackendVerification) -> Void] {
    var bad = result
    change(&bad)
    #expect(!InferenceProvision.passed(bad, confinement: .none))
  }
}
