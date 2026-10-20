# iso-ci provenance and license review

The iso-ci specification (section 9 and 15) requires recorded provenance and
a license review before any external workflow, protocol or fixture
implementation is reused. This file records every external source the
preflight data plane was derived from.

## Local preflight data plane (`Sources/IsoCICore/Preflight/DataPlane/`)

**Nature of reuse:** protocol interoperability, derived by *reading* the
sources below to learn wire formats (routes, JSON field names, token and
context-data encodings, file formats). **No code was copied or translated.**
The Swift implementation, fixtures and tests are original to iso-ci. The
test fixtures under `Tests/IsoCICoreTests/Fixtures/dataplane/` are
hand-written request bodies shaped after the documented contracts; they were
**not** captured from a live runner or client.

| Source | Version / commit | License | What was learned |
|---|---|---|---|
| [actions/runner](https://github.com/actions/runner) | tag `v2.338.0` (commit `197ca027b90de199464dee3bb9ff198a1db60967`); also read at `v2.329.0` (`c76c59996c8fa32e989164a5a695efb12608ae5a`) to bound the compatible range | MIT | Run-service ("V2") listener flow: `Runner.Listener/BrokerMessageListener.cs`, `Runner.Common/BrokerServer.cs`, `Sdk/WebApi/WebApi/BrokerHttpClient.cs` (session, message, acknowledge routes); `Runner.Listener/Runner.cs` (jitconfig decoding, message-type dispatch); `Runner.Listener/JobDispatcher.cs` (renew via run service); `Sdk/RSWebApi/RunServiceHttpClient.cs` and `Contracts/*` (acquire/renew/complete bodies, `StepResult`); `Runner.Worker/JobRunner.cs`, `Runner.Common/JobServerQueue.cs`, `Sdk/WebApi/WebApi/ResultsHttpClient.cs` and `Contracts.cs` (results receiver twirp routes, snake_case naming, unspecified blob storage uploads, step update enums); `Sdk/WebApi/WebApi/LaunchHttpClient.cs`, `LaunchContracts.cs`, `Runner.Worker/ActionManager.cs` (action resolution and `x-access-token` Basic archive download); `Sdk/DTPipelines/Pipelines/AgentJobRequestMessage.cs`, `ActionStep.cs`, `ActionStepDefinitionReference.cs`, `Step.cs`, `JobStep.cs`; `Sdk/DTObjectTemplating/ObjectTemplating/Tokens/TemplateTokenJsonConverter.cs`, `TokenType.cs`; `Sdk/DTPipelines/Pipelines/ContextData/PipelineContextDataJsonConverter.cs`; `Runner.Worker/Handlers/NodeScriptActionHandler.cs` (endpoint data → `ACTIONS_*` env, cache v2 switch); `Runner.Worker/Variables.cs`, `ExecutionContext.cs` (secrets context); `Runner.Listener/Configuration/OAuthCredential.cs`, `RSAFileKeyManager.cs`, `IRSAKeyManager.cs` (`RSAParametersSerializable` field names); `Sdk/WebApi/WebApi/OAuth/*` and `Jwt/JsonWebToken.cs` (client-assertion claims, RS256, 5-minute lifetime, form fields); `Runner.Common/ConfigurationStore.cs` (`.runner` fields, `IsHostedServer`). |
| [actions/toolkit](https://github.com/actions/toolkit) `packages/cache` | commit `7e25f67e8fd17369aa21e6e816ac99654106e0dc` (`@actions/cache` 6.3.0) | MIT | Cache service selection (`config.ts`), v1 REST routes and bodies (`internal/cacheHttpClient.ts`: lookup, reserve, chunked `PATCH` with `Content-Range`, commit). |
| [actions/toolkit](https://github.com/actions/toolkit) `packages/artifact` | commit `7e25f67e8fd17369aa21e6e816ac99654106e0dc` (`@actions/artifact` 6.3.1) | MIT | Twirp service and proto JSON field names (`generated/results/api/v1/artifact.ts`, `artifact.twirp-client.ts`), upload/finalize sequence (`internal/upload/*`), backend ids from the runtime token `scp` claim (`internal/shared/util.ts`), GHES detection (`internal/shared/config.ts`), signed-URL download handling (`internal/download/download-artifact.ts`). |
| Azure Blob Storage REST semantics (as used by `@azure/storage-blob` through the toolkit) | — (behavior only) | n/a (no code read beyond the toolkit's calls) | `PUT ?comp=block&blockid=`, `PUT ?comp=blocklist` XML body, append blobs (`comp=appendblock`, `seal`), path-style URLs on IP hosts. |

**License review:** all code sources are MIT-licensed. iso-ci reuses no
source text from them, so no notice obligation arises from copying; the
interoperability knowledge is recorded here as the specification requires.
The repository-level `PROVENANCE.md` and `THIRD_PARTY_LICENSES.md` are
unchanged because nothing was vendored.

**Qualification status:** none of the data-plane protocol surface has been
exercised against a real official runner binary or a real toolkit client in
this repository. Fixture success is *not* qualification of the protocol
(spec section 2, last paragraph; section 9 differential testing).
