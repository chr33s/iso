import IsoConfiguration
import IsoCore
import Testing

@Suite struct ExecutionHostConfigTests {
  let environment = ConfigEnvironment(home: "/h", variables: [:])

  func load(_ text: String) throws(ConfigError) -> IsoConfig {
    try ConfigLoader.load(bytes: text, environment: environment)
  }

  func reason(_ text: String) -> String? {
    do {
      _ = try load(text)
      return nil
    } catch {
      if case .invalidField(_, let field, let reason) = error { return "\(field): \(reason)" }
      return "\(error)"
    }
  }

  @Test func existingConfigurationDefaultsToLocal() throws {
    let config = try load("{}")
    #expect(config.execution == .defaults)
    #expect(config.execution.defaultHost.isLocal)
    #expect(config.execution.remote.defaultSessionTTL == 8 * 3_600)
  }

  @Test func namedHostsDecode() throws {
    let config = try load(
      #"""
      { "execution": {
          "default_host": "build-mac",
          "hosts": { "build-mac": { "ssh_alias": "build", "agent_path": "/usr/local/bin/iso" } },
          "remote": { "default_session_ttl": "2h" } } }
      """#)
    let alias = try HostAlias("build-mac")
    #expect(config.execution.defaultHost == alias)
    #expect(config.execution.hosts[alias]?.sshAlias == (try HostAlias("build")))
    #expect(config.execution.hosts[alias]?.agentPath.rawValue == "/usr/local/bin/iso")
    #expect(config.execution.remote.defaultSessionTTL == 7_200)
  }

  @Test func localCannotBeRedirected() {
    #expect(
      reason(#"{"execution":{"hosts":{"local":{"ssh_alias":"x","agent_path":"/bin/iso"}}}}"#)?
        .contains("implicit local host") == true)
  }

  @Test func invalidValuesAreRefused() {
    let cases = [
      #"{"execution":{"default_host":"nowhere"}}"#,
      #"{"execution":{"hosts":{"-o":{"ssh_alias":"x","agent_path":"/bin/iso"}}}}"#,
      #"{"execution":{"hosts":{"h":{"ssh_alias":"-oProxyCommand=sh","agent_path":"/bin/iso"}}}}"#,
      #"{"execution":{"hosts":{"h":{"ssh_alias":"x","agent_path":"iso"}}}}"#,
      #"{"execution":{"hosts":{"h":{"ssh_alias":"x","agent_path":"/bin/../iso"}}}}"#,
      #"{"execution":{"hosts":{"h":{"ssh_alias":"x","agent_path":"/bin/iso; rm"}}}}"#,
      #"{"execution":{"hosts":{"h":{"ssh_alias":"x","agent_path":"/bin/iso","transport":"tcp"}}}}"#,
      #"{"execution":{"hosts":{"h":{"ssh_alias":"x","agent_path":"/bin/iso","key":"secret"}}}}"#,
      #"{"execution":{"remote":{"broker":"worker"}}}"#,
      #"{"execution":{"remote":{"default_session_ttl":"25h"}}}"#,
      #"{"execution":{"grant":"x"}}"#,
    ]
    for text in cases {
      #expect(reason(text) != nil, "\(text)")
    }
  }

  @Test func errorsDoNotEchoUnknownValues() {
    let message = reason(
      #"{"execution":{"hosts":{"h":{"ssh_alias":"x","agent_path":"/bin/iso","token":"sk-SECRET"}}}}"#
    )
    #expect(message?.contains("sk-SECRET") == false)
  }
}
