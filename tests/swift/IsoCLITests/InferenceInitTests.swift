import Foundation
import IsoConfiguration
import IsoCore
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
