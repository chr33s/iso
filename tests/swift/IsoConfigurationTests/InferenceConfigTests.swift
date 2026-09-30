import Foundation
import IsoCore
import Testing

@testable import IsoConfiguration

private func load(_ text: String) throws(ConfigError) -> IsoConfig {
  try ConfigLoader.load(bytes: text, environment: fixtureHome)
}

private func fieldError(_ text: String) -> (field: String, reason: String)? {
  do {
    _ = try load(text)
    return nil
  } catch {
    if case .invalidField(_, let field, let reason) = error { return (field, reason) }
    Issue.record("unexpected error \(error)")
    return nil
  }
}

/// A complete guarded configuration; `patch` replaces one fragment.
private func document(
  mode: String = "required", backendURL: String = "http://127.0.0.1:8080",
  apis: String = #"["anthropic-messages"]"#, codex: String = "", evidence: String = "drain",
  claude: String = #"{"service": "local-coder"}"#
) -> String {
  """
  {
    "inference": {
      "mode": "\(mode)",
      "qualification_profiles": {
        "mlx-reviewed": {
          "protocol": "anthropic-messages", "completion_evidence": "\(evidence)",
          "context_overflow": "reject",
          "input_overhead": {"per_request_bytes": 512, "per_message_bytes": 16},
          "max_input_bytes": "1MiB"
        }
      },
      "backends": {
        "mlx-main": {
          "base_url": "\(backendURL)", "protocol": "anthropic-messages",
          "qualification_profile": "mlx-reviewed"
        }
      },
      "services": {
        "local-coder": {
          "backend": "mlx-main", "upstream_model": "mlx-community/Model-4bit",
          "frontend_apis": \(apis), "max_context_tokens": 131072
        }
      }
    },
    "claude": {"local_model": \(claude)}\(codex)
  }
  """
}

@Test func guardedConfigurationDecodes() throws {
  let config = try load(document())
  #expect(config.inference.mode == .required)
  #expect(config.claude.localService?.rawValue == "local-coder")
  #expect(config.claude.localModel == nil)
  let resolved = try #require(config.inference.resolve(InferenceServiceName("local-coder")))
  #expect(resolved.backend.port == 8080)
  #expect(resolved.profile.maxInputBytes == 1 << 20)
  #expect(resolved.profile.maxRequestBodyBytes == 4 << 20)
  #expect(resolved.service.defaultOutputTokens == 4_096)
  #expect(resolved.service.maxOutputTokens == 8_192)
  #expect(config.inference.globalLimits == .defaults)
}

@Test func inferenceDefaultsOff() throws {
  let config = try load("{}")
  #expect(config.inference == .off)
}

@Test func backendURLMustBeIPv4Loopback() {
  for url in [
    "http://localhost:8080", "https://127.0.0.1:8080", "http://127.0.0.2:8080",
    "http://0.0.0.0:8080", "http://[::1]:8080", "http://192.168.1.2:8080",
    "http://127.0.0.1:80", "http://127.0.0.1:8080/v1", "http://127.0.0.1:8080?x=1",
    "http://user@127.0.0.1:8080", "http://127.0.0.1", "http://127.0.0.1:08080",
  ] {
    #expect(
      fieldError(document(backendURL: url))?.field == "inference.backends.mlx-main.base_url",
      "\(url)")
  }
  #expect(fieldError(document(backendURL: "http://127.0.0.1:8080/")) == nil)
}

@Test func unknownMembersAndMixedFormsAreRejected() {
  #expect(fieldError(#"{"inference": {"mode": "auto"}}"#)?.field == "inference.mode")
  #expect(fieldError(#"{"inference": {"surprise": 1}}"#)?.field == "inference.surprise")
  #expect(
    fieldError(document(claude: #"{"service": "local-coder", "host_url": "http://x"}"#))?.field
      == "claude.local_model.host_url")
  #expect(
    fieldError(document(claude: #"{"service": "local-coder", "auth_token": "x"}"#))?.field
      == "claude.local_model.auth_token")
  // `required` refuses the legacy raw endpoint form.
  #expect(
    fieldError(document(claude: #"{"host_url": "http://localhost:1", "model": "m"}"#))?.field
      == "claude.local_model")
  // A guarded reference needs `required`.
  #expect(fieldError(document(mode: "off"))?.field == "claude.local_model.service")
  #expect(
    fieldError(document(claude: #"{"service": "missing"}"#))?.field
      == "claude.local_model.service")
}

@Test func protocolsMustMatchTheAgentAndBackend() {
  // Claude needs anthropic-messages.
  let chatOnly = fieldError(
    document(
      apis: #"["anthropic-messages"]"#,
      codex: #", "codex": {"local_model": {"service": "local-coder"}}"#))
  #expect(chatOnly?.field == "codex.local_model.service")
  #expect(chatOnly?.reason.contains("INFERENCE_PROTOCOL_UNSUPPORTED") == true)
  // No translating adapter: an OpenAI API on an Anthropic backend fails.
  let mismatch = fieldError(document(apis: #"["anthropic-messages", "openai-responses"]"#))
  #expect(mismatch?.field == "inference.services.local-coder.frontend_apis")
  // count_tokens needs a qualified counter.
  #expect(
    fieldError(document(apis: #"["anthropic-messages", "anthropic-count-tokens"]"#))?.field
      == "inference.services.local-coder.frontend_apis")
  #expect(
    fieldError(document(evidence: "explicit"))?.field
      == "inference.qualification_profiles.mlx-reviewed.completion_evidence")
}

@Test func limitsAreBounded() {
  #expect(
    fieldError(#"{"inference": {"global_limits": {"max_active_requests": 0}}}"#)?.field
      == "inference.global_limits.max_active_requests")
  #expect(
    fieldError(#"{"inference": {"global_limits": {"max_request_buffer_bytes": 10}}}"#)?.field
      == "inference.global_limits.max_request_buffer_bytes")
  let tooMuchOutput = document().replacingOccurrences(
    of: #""max_context_tokens": 131072"#,
    with: #""max_context_tokens": 131072, "max_output_tokens": 40000"#)
  #expect(
    fieldError(tooMuchOutput)?.field == "inference.services.local-coder.max_output_tokens")
  let inverted = document().replacingOccurrences(
    of: #""max_context_tokens": 131072"#,
    with: #""max_context_tokens": 131072, "max_output_tokens": 100, "default_output_tokens": 200"#)
  #expect(
    fieldError(inverted)?.field == "inference.services.local-coder.default_output_tokens")
}

@Test func backendCredentialMustBeAReference() {
  let literal = document().replacingOccurrences(
    of: #""qualification_profile": "mlx-reviewed""#,
    with: #""qualification_profile": "mlx-reviewed", "credential": "sk-literal""#)
  #expect(fieldError(literal)?.field == "inference.backends.mlx-main.credential")
  let reference = document().replacingOccurrences(
    of: #""qualification_profile": "mlx-reviewed""#,
    with: #""qualification_profile": "mlx-reviewed", "credential": "cmd:echo x""#)
  #expect(fieldError(reference) == nil)
}

@Test func managedBackendsAndRunAsAreValidated() {
  func withBackend(_ extra: String) -> String {
    document().replacingOccurrences(
      of: #""qualification_profile": "mlx-reviewed""#,
      with: #""qualification_profile": "mlx-reviewed", "# + extra)
  }
  #expect(fieldError(withBackend(#""run_as": "_mlx""#)) == nil)
  #expect(
    fieldError(withBackend(#""run_as": "Bad User""#))?.field == "inference.backends.mlx-main.run_as"
  )
  let managed =
    #""managed": {"server": "mlx-lm", "python": "/opt/py/bin/python3", "model": "/models/m"}"#
  #expect(fieldError(withBackend(managed)) == nil)
  #expect(
    fieldError(withBackend(managed + #", "credential": "cmd:x""#))?.field
      == "inference.backends.mlx-main.credential")
  #expect(
    fieldError(withBackend(managed + #", "run_as": "someone""#))?.field
      == "inference.backends.mlx-main.run_as")
  for bad in [
    #""managed": {"server": "ollama", "python": "/p", "model": "/m"}"#,
    #""managed": {"server": "mlx-lm", "model": "/m"}"#,
    #""managed": {"server": "mlx-lm", "python": "/p", "install": "0.31.3", "model": "/m"}"#,
    #""managed": {"server": "mlx-lm", "install": "0.30.0", "model": "/m"}"#,
    #""managed": {"server": "mlx-lm", "python": "p", "model": "/m"}"#,
    #""managed": {"server": "mlx-lm", "python": "/p", "model": "relative"}"#,
    #""managed": {"server": "mlx-lm", "python": "/p", "model": {"repo": "a/b", "revision": "main"}}"#,
    #""managed": {"server": "mlx-lm", "python": "/p", "model": {"repo": "../x", "revision": "\#(String(repeating: "a", count: 40))"}}"#,
    #""managed": {"server": "mlx-lm", "python": "/p", "model": "/m", "memory_limit": "1MiB"}"#,
    #""managed": {"server": "mlx-lm", "python": "/p", "model": "/m", "confinement": "maybe"}"#,
  ] {
    #expect(fieldError(withBackend(bad)) != nil, "\(bad)")
  }
}

@Test func managedBackendNamesCannotBePathComponents() {
  let managed = document().replacingOccurrences(
    of: #""qualification_profile": "mlx-reviewed""#,
    with:
      #""qualification_profile": "mlx-reviewed", "managed": {"server": "mlx-lm", "python": "/p", "model": "/m"}"#
  )
  for name in ["..", ".", ".hidden"] {
    let renamed = managed.replacingOccurrences(of: #""mlx-main": {"#, with: "\"\(name)\": {")
      .replacingOccurrences(of: #""backend": "mlx-main""#, with: "\"backend\": \"\(name)\"")
    #expect(fieldError(renamed)?.field == "inference.backends[\"\(name)\"]", "\(name)")
  }
  #expect(throws: ValidationError.self) { try ManagedBackendName("..") }
}
