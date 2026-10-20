import Foundation

/// The per-allocation runner configuration for local preflight, in the
/// official runner's `--jitconfig` form: base64 of a JSON object mapping
/// `.runner`, `.credentials` and `.credentials_rsaparams` to base64 file
/// contents (actions/runner v2.338.0 `Runner.cs` jitconfig handling).
///
/// The runner is configured for the run-service flow (`UseV2Flow`,
/// `ServerUrlV2`) with `ServerUrl` equal to `ServerUrlV2`, so the listener
/// never opens a legacy VSS connection; it is ephemeral (one job), never
/// self-updates, and is explicitly not a hosted runner. Every URL points at
/// the allocation's guest-local forward of the scoped endpoint.
package struct PreflightRunnerConfig: Sendable {
  package let runnerName: String
  package let endpoint: JobMessageBuilder.Endpoint
  package let clientID: String
  package let keys: RunnerKeyPair

  package var runnerFile: JSONValue {
    [
      "AgentId": 1, "AgentName": .string(runnerName), "PoolId": 1, "PoolName": "iso-ci-preflight",
      "ServerUrl": .string(endpoint.broker), "ServerUrlV2": .string(endpoint.broker),
      "GitHubUrl": .string(endpoint.serverURL), "WorkFolder": "_work", "UseV2Flow": true,
      "DisableUpdate": true, "Ephemeral": true, "IsHostedServer": false,
    ]
  }

  package var credentialsFile: JSONValue {
    [
      "Scheme": "OAuth",
      "Data": [
        "clientId": .string(clientID), "authorizationUrl": .string(endpoint.oauth),
        "requireFipsCryptography": "False",
      ],
    ]
  }

  /// The files the runner writes into its root directory.
  package var files: [String: [UInt8]] {
    [
      ".runner": runnerFile.canonical, ".credentials": credentialsFile.canonical,
      ".credentials_rsaparams": keys.rsaParametersJSON,
    ]
  }

  /// The `--jitconfig` argument. Guest-visible by design; never logged.
  package var encoded: String {
    let object = JSONValue.object(files.mapValues { .string(Data($0).base64EncodedString()) })
    return Data(object.canonical).base64EncodedString()
  }
}
