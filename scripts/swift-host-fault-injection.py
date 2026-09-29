#!/usr/bin/env python3
"""Show that critical Swift host tests fail when their protected behavior is
removed (docs/design/swift-host-spec.md section 7, H-04/H-12 evidence).

Each fault edits one production source line in a scratch copy of the package,
runs the named test filter there, and requires at least one failure. The
working tree is never modified. Exit status is non-zero if any fault survives.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (id, file, original text, replacement, swift test filter)
FAULTS = [
    ("scanner-strings", "Sources/CoopConfiguration/JSONCScanner.swift",
     "if byte == quote { state = .string }", "_ = quote",
     "commentMarkersInsideStringsAreData"),
    ("scanner-unterminated", "Sources/CoopConfiguration/JSONCScanner.swift",
     "&& policy == .configuration {", "&& policy == .devcontainer {",
     "unterminatedBlockCommentIsRejectedForConfiguration"),
    ("preflight-duplicates", "Sources/CoopConfiguration/JSONPreflight.swift",
     "guard objectKeys[objectKeys.count - 1].insert(key).inserted else {",
     "guard objectKeys[objectKeys.count - 1].insert(key).inserted || true else {",
     "duplicateKeysAreDetectedAfterDecoding"),
    ("preflight-trailing-comma", "Sources/CoopConfiguration/JSONPreflight.swift",
     "guard current == UInt8(ascii: \"\\\"\") else { throw fail(.syntax(\"expected an object key\")) }",
     "if current == UInt8(ascii: \"}\") { return }",
     "rejectsJSON5AndTrailingCommas"),
    ("preflight-depth", "Sources/CoopConfiguration/JSONPreflight.swift",
     "guard stack.count < limits.maxDepth else", "guard stack.count >= 0 else",
     "resourceLimitsAreEnforcedBeforeDecoding"),
    ("fractional-integers", "Sources/CoopConfiguration/JSONValue.swift",
     "if !fractional.contains(components) {", "if true {",
     "fractionalLiteralsDoNotSatisfyIntegerFields"),
    ("literal-credentials", "Sources/CoopConfiguration/CoopConfig.swift",
     "guard value.hasPrefix(\"cmd:\") || value.hasPrefix(\"vault:\") else { return nil }", "",
     "proxyCredentialsMustBeCommandReferences"),
    ("retired-fields", "Sources/CoopConfiguration/ConfigDecoding.swift",
     "if !retired.isEmpty { throw .retired(retired) }", "",
     "retiredFirecrackerFieldsAreRejectedByName"),
    ("apple-container-strict", "Sources/CoopConfiguration/ConfigDecoding.swift",
     "try r.rejectUnknown(allowing: appleContainerKeys)", "",
     "unknownKeysFollowPerSectionPolicy"),
    ("null-defaulted", "Sources/CoopConfiguration/ConfigDecoding.swift",
     "guard let value = members[key] else { return try fallback() }",
     "guard let value = members[key], value != .null else { return try fallback() }",
     "nullIsAbsentOnlyForOptionalFields"),
    ("spawn-cloexec", "Sources/CoopHost/ProcessRunner.swift",
     "(ownGroup ? POSIX_SPAWN_SETPGROUP : 0) | POSIX_SPAWN_CLOEXEC_DEFAULT",
     "(ownGroup ? POSIX_SPAWN_SETPGROUP : 0)",
     "childSeesOnlyTheExplicitEnvironmentAndNoExtraDescriptors"),
    ("spawn-process-group", "Sources/CoopHost/ProcessRunner.swift",
     "    if ownsGroup { kill(-pid, SIGKILL) }\n", "",
     "deadlineKillsTheWholeProcessGroup"),
    ("mode-widening", "Sources/CoopCore/AtomicFile.swift",
     "existing.st_mode & 0o777 & mode : mode", "mode : mode",
     "atomicWriteNeverWidensAnExistingMode"),
    ("gate-agent-forwarding", "Sources/CoopHost/IsolationGate.swift",
     "guard !effective.sshAgentForwarding else {", "guard true else {",
     "gateRejectsEachExposureNetworkAndIdentityChange"),
    ("gate-network", "Sources/CoopHost/IsolationGate.swift",
     "guard address == ip, subnetOK else {", "guard address == ip else {",
     "gateRejectsEachExposureNetworkAndIdentityChange"),
    ("gate-record-owner", "Sources/CoopHost/IsolationGate.swift",
     "guard record.id == expected.sandbox.rawValue, record.owner == expected.owner.rawValue else {",
     "guard record.id == expected.sandbox.rawValue else {",
     "gateRejectsEachExposureNetworkAndIdentityChange"),
    ("runtime-env", "Sources/CoopHost/SandboxRuntime.swift",
     "var out = parent.filter { inheritedVariables.contains($0.key) }", "var out = parent",
     "realExecutorSanitizesEnvironmentAndBoundsOutput"),
    ("control-file-nofollow", "Sources/CoopHost/StateStore.swift",
     "let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)", "let fd = open(path, O_RDONLY | O_CLOEXEC)",
     "controlFilesDoNotFollowSymlinks"),
    ("sidecar-owner", "Sources/CoopHost/StateStore.swift",
     "guard ownerID == owner.id, machineID.belongs(to: owner.id) else {",
     "guard machineID.belongs(to: ownerID) else {",
     "foreignAndRetiredSchemasAreRefused"),
    ("host-key-pin", "Sources/CoopHost/SSH.swift",
     "guard FileManager.default.fileExists(atPath: knownHosts) else {", "guard true else {",
     "pinnedTargetRequiresAnEnrolledKeyAndSafePaths"),
    ("host-key-pin-equality", "Sources/CoopHost/HostKeys.swift",
     "guard data == Data(line.utf8) else {", "guard !data.isEmpty else {",
     "enrollOnceThenThePinIsEnforced"),
    ("host-key-no-reenroll", "Sources/CoopHost/HostKeys.swift",
     "      if lstat(path, &status) == 0 {\n", "      if false {\n",
     "enrollOnceThenThePinIsEnforced"),
    ("destroy-owner-check", "Sources/CoopHost/AppleLifecycle.swift",
     "guard ownerID == owner.id, machine.belongs(to: owner.id) else {", "guard true else {",
     "destroyLeavesForeignSandboxesUntouched"),
    ("create-journal", "Sources/CoopHost/AppleLifecycle.swift",
     "    try Journal.complete(instance)\n  }\n\n  func provisionSandbox(",
     "  }\n\n  func provisionSandbox(",
     "createStopStartAndDestroyAgainstTheFakeRuntime"),
    ("config-writer-lock", "Sources/CoopHost/ConfigStore.swift",
     "let lock = try FileLock.sibling(of: path)\n    defer { lock.release() }\n", "",
     "concurrentProxyEditsAreAllRetained"),
    ("remote-command-escaping", "Sources/CoopCore/RemoteCommand.swift",
     "if character == \"'\" { escaped += \"'\\\\''\" } else { escaped.append(character) }",
     "escaped.append(character)",
     "remoteCommandEscapesArgumentsOnce"),
    ("env-forward-redaction", "Sources/CoopHost/GuestSession.swift",
     "\"\\(debugQuoted($0)): \\\"<redacted>\\\"\"", "\"\\($0)=\\(values[$0]!.expose())\"",
     "remoteCommandEscapesArgumentsOnce"),
    ("workspace-excludes", "Sources/CoopHost/Workspace.swift",
     "let defaultExcludes = [\"node_modules/\", ", "let defaultExcludes = [",
     "tarPipeCopiesTheProjectAndSkipsExcludes"),
    ("ssh-config-foreign-alias", "Sources/CoopHost/SSHConfig.swift",
     "try SSHConfigBlocks.checkAliasNotForeign(existing, host: host)", "",
     "sshConfigBlocksLeaveOtherNamespacesAlone"),
    ("mount-workspace-collision", "Sources/CoopHost/Workspace.swift",
     "if let collision, mounts.contains(where: { $0.guestPath == guestWorkspace }) {",
     "if let collision, mounts.isEmpty {",
     "mountSetsRejectWorkspaceCollisionsAndDuplicates"),
    ("forward-port-probe", "Sources/CoopHost/PortForwards.swift",
     "if let failure = probe(forward.host) {", "if let failure = Optional<Int32>.none {",
     "forwardStateRoundTripsAndBusyPortsAreRefused"),
    ("github-token-stdin", "Sources/CoopHost/GitHubAPI.swift",
     "if token != nil { arguments += [\"-H\", \"@-\"] }",
     "if let token { arguments += [\"-H\", \"Authorization: token \\(token.expose())\"] }",
     "tokensReachCurlOnStdinOnly"),
    ("update-checksum", "Sources/CoopHost/Update.swift",
     "guard actual == expected else {", "guard actual == expected || true else {",
     "verifySHA256AcceptsTheRightDigestOnly"),
    ("update-attestation-repo", "Sources/CoopHost/UpdateRelease.swift",
     "var arguments = [\"attestation\", \"verify\", tarball, \"--repo\", UpdateChannel.repository]",
     "var arguments = [\"attestation\", \"verify\", tarball]",
     "attestationArgumentsPinTheRepository"),
    ("update-attestation-signer", "Sources/CoopHost/UpdateRelease.swift",
     "\"--cert-identity\", UpdateChannel.signerIdentity(tag: tag), \"--source-ref\",\n      \"refs/tags/\\(tag)\", \"--deny-self-hosted-runners\",",
     "",
     "attestationArgumentsPinTheRepository"),
    ("update-signature", "Sources/CoopHost/Update.swift",
     "do { try SSHSignature.verify(armored: armored, message: bytes, trusted: signers) } catch {",
     "do { _ = armored } catch {",
     "unsignedOrForeignSignedSumsAreRefusedBeforeUse"),
    ("update-anti-rollback", "Sources/CoopHost/Update.swift",
     "if target < current && !options.allowDowngrade {", "if false {",
     "olderReleasesNeedAllowDowngrade"),
    ("update-revoked-digest", "Sources/CoopHost/Update.swift",
     "guard !revoked.contains(expected) else {", "guard true else {",
     "revokedArchivesAreRefused"),
    ("sshsig-trusted-key", "Sources/CoopHost/ReleaseSignature.swift",
     "guard trusted.contains(key) else", "guard trusted.contains(key) || true else",
     "sshSignatureVerifiesOnlyTheSignedBytesFromATrustedKey"),
    ("sshsig-namespace", "Sources/CoopHost/ReleaseSignature.swift",
     "guard signedNamespace == Array(namespace.utf8) else {",
     "guard signedNamespace == Array(namespace.utf8) || true else {",
     "sshSignatureVerifiesOnlyTheSignedBytesFromATrustedKey"),
    ("proxy-fail-closed", "Sources/CoopHost/ProxyLifecycle.swift",
     "    } catch {\n      stop(instance, provider: provider)\n      throw error\n    }\n    diagnostics.log(",
     "    } catch {\n    }\n    diagnostics.log(",
     "proxyStartFailsClosed"),
    ("keychain-no-fallback", "Sources/CoopHost/SecretStore.swift",
     "    guard isAvailable else {\n      throw HostError(\n        \"macOS Keychain is unavailable",
     "    guard isAvailable || true else {\n      throw HostError(\n        \"macOS Keychain is unavailable",
     "missingKeychainFailsWithoutFallback"),
    ("mcp-definition-stdin", "Sources/CoopHost/BootstrapClaude.swift",
     "            \" \\\"$(cat)\\\"\"),\n          stdin: Array(resolved.json.compact.utf8))",
     "            \" \").arg(resolved.json.compact),\n          stdin: [])",
     "firstBootBootstrapConfiguresBothAgents"),
    ("transport-environment", "Sources/CoopHost/SSH.swift",
     "    self.environment = Self.transportEnvironment(environment)",
     "    self.environment = environment",
     "guestTransportCarriesOnlyForwardedVariables"),
    ("pid-file-identity", "Sources/CoopHost/ProxyLifecycle.swift",
     "      if let command = Self.commandLine(pid), expect.matches(command) {",
     "      if true {",
     "aReusedPIDIsNotSignalled"),
    ("proxy-port-free", "Sources/CoopHost/ProxyLifecycle.swift",
     "    let deadline = ContinuousClock.now + .seconds(2)\n    while Self.accepts(port: port) {",
     "    let deadline = ContinuousClock.now + .seconds(2)\n    while false {",
     "occupiedProxyPortsAreRefusedAndForeignListenersRejected"),
    ("proxy-listener-identity", "Sources/CoopHost/ProxyLifecycle.swift",
     "    guard listeners == [pid] else {", "    guard listeners == [pid] || true else {",
     "occupiedProxyPortsAreRefusedAndForeignListenersRejected"),
    ("feature-layer-digest", "Sources/CoopHost/DevcontainerOCI.swift",
     "    guard sha256Hex(bytes) == expected.hash.rawValue else {",
     "    guard sha256Hex(bytes) == expected.hash.rawValue || true else {",
     "resolverFetchesOCIFeaturesWithBaselineArgv"),
    ("feature-read-nofollow", "Sources/CoopHost/DevcontainerOCI.swift",
     "    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)",
     "    let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)",
     "featureFilesAreReadOnlyAsBoundedRegularFiles"),
    ("stage-symlink-containment", "Sources/CoopHost/WorkspaceStage.swift",
     "guard let target, Self.staysInside(link: path, target: target) else {",
     "guard let target else {",
     "escapingSymlinksMakeTheStageInapplicable"),
    ("proxy-required-codex-auth", "Sources/CoopHost/BootstrapCodex.swift",
     "    proxyActive || proxyMode == .required || egress == .none || auth == .chatgpt",
     "    proxyActive || egress == .none || auth == .chatgpt",
     "codexAuthJSONIsStagedOnlyForDirectAPIKeyMode"),
    ("egress-none-withholds", "Sources/CoopHost/Bootstrap.swift",
     "      guard proxied || required || noEgress else { continue }",
     "      guard proxied || required else { continue }",
     "egressNoneNeverForwardsARawProviderKey"),
    ("proxy-required-withholds", "Sources/CoopHost/Bootstrap.swift",
     "guard proxied || required || noEgress else { continue }",
     "guard proxied || noEgress else { continue }",
     "requiredModeWithholdsEveryProviderVariableAndRefusesDeclarations"),
    ("proxy-off-ignores-upstreams", "Sources/CoopHost/ProxyLifecycle.swift",
     "    guard config.mode != .off else { return nil }\n", "",
     "offModeIgnoresConfiguredUpstreams"),
    ("proxy-required-start", "Sources/CoopHost/Bootstrap.swift",
     "    guard !configured else { return }\n", "    guard configured else { return }\n",
     "requiredModeFailsStartWithoutAnyProviderProxy"),
    ("vault-refused-for-guest-values", "Sources/CoopHost/CredentialResolver.swift",
     "    if raw.hasPrefix(\"vault:\") {\n      throw HostError(", "    if false {\n      throw HostError(",
     "vaultIsRefusedForValuesPlacedInTheGuest"),
    ("credential-separation", "Sources/CoopHost/GuestEnvState.swift",
     "        credentials.contains(name)\n", "        false\n",
     "aStoredSecretIsEitherAProxyCredentialOrGuestVisible"),
    ("preset-provider-only", "Sources/CoopConfiguration/CoopConfig.swift",
     "    case .providerOnly: .required\n", "    case .providerOnly: .auto\n",
     "securityPresetsSupplyDefaultsThatExplicitFieldsOverride"),
    ("audit-records-boot", "Sources/CoopHost/Bootstrap.swift",
     "    recordBoot(instance)\n", "",
     "requiredModeFailsStartWithoutAnyProviderProxy"),
    ("session-expiry-gate", "Sources/CoopHost/IsolationGate.swift",
     "      if deadline <= Date() {",
     "      if deadline < Date.distantPast {",
     "anExpiredSessionIsNotHandedOut"),
    ("session-deadline-unreadable", "Sources/CoopHost/IsolationGate.swift",
     "if let recorded = inspection.record.expiresAt {",
     "if let recorded = inspection.record.expiresAt, inspection.record.sessionDeadline != nil {",
     "anUnreadableSessionDeadlineIsNotTreatedAsNoLimit"),
    ("session-ttl-on-restart", "Sources/CoopHost/AppleLifecycle.swift",
     "        runtime, expected(sidecar, runtime), until: deadline, sessionTTL: config.limits.sessionTTL)",
     "        runtime, expected(sidecar, runtime), until: deadline)",
     "sessionTTLPassesAnExpiryToEveryBoot"),
    ("egress-record-mode", "Sources/CoopHost/IsolationGate.swift",
     "guard hostOnly == (expected.egress == .none) else {", "guard hostOnly || !hostOnly else {",
     "egressIsCheckedOnTheRecordBeforeBoot"),
    ("egress-interface-label", "Sources/CoopHost/IsolationGate.swift",
     "let prefix = egress == .none ? \"vmnet-host:10.231.\" : \"vmnet-shared:10.231.\"",
     "let prefix = \"vmnet-\"",
     "egressNoneRequiresAHostOnlySandbox"),
    ("provider-secret-skips-guest", "Sources/CoopHost/Bootstrap.swift",
     "          if routed.contains(name) { continue }\n", "",
     "providerSecretsNeverReachTheGuestAndSelectTheProxy"),
    ("provider-secret-off-unavailable", "Sources/CoopHost/ProxyLifecycle.swift",
     "      guard config.mode != .off else { throw unavailable(routed) }\n", "",
     "providerSecretsNeverReachTheGuestAndSelectTheProxy"),
    ("secrets-device-key-digest", "Sources/CoopSecrets/DeviceFactor.swift",
     "(1...4096).contains(data.count), Self.digest(Array(data)) == sha256",
     "(1...4096).contains(data.count)",
     "missingOrCorruptDeviceKeyIsPermanentAndMintsNothing"),
    ("secrets-kdf-bounds", "Sources/CoopSecrets/KDF.swift",
     "guard r == 8, p == 1 else {", "guard r > 0, p > 0 else {",
     "scryptParametersAreBoundedBeforeUse"),
    ("secrets-envelope-aad", "Sources/CoopSecrets/StoreFormat.swift",
     "plaintext, using: key, nonce: nonce, authenticating: additionalData(parameters))",
     "plaintext, using: key, nonce: nonce)",
     "envelopeBindsTheKDFParameters"),
    ("stage-symlink-chains", "Sources/CoopHost/WorkspaceStage.swift",
     "    try checkLinkChains()\n", "",
     "symlinkChainsCannotEscape"),
    ("stage-chain-fold", "Sources/CoopHost/WorkspaceStage.swift",
     "let staged = Set(links.map { Self.folded($0.path) })",
     "let staged = Set(links.map(\\.path))",
     "symlinkChainsAreDetectedCaseInsensitively"),
    ("stage-conspicuous-git", "Sources/CoopHost/WorkspaceStageReview.swift",
     "if let git = components.firstIndex(of: \".git\") {",
     "if let git = components.firstIndex(of: \".git-none\") {",
     "conspicuousPathsIgnoreCase"),
    ("stage-growth-bytes", "Sources/CoopHost/WorkspaceStage.swift",
     "if bytes > limits.maxBytes.bytes + entries * Self.blockSlack {", "if bytes < 0 {",
     "growthGuardStopsATransferThatOutgrowsTheBudget"),
    ("stage-depth", "Sources/CoopHost/WorkspaceStage.swift",
     "guard depth < Self.maxDepth else {", "guard depth >= 0 else {",
     "deeplyNestedDirectoriesAreRefusedNotWalked"),
    ("stage-growth-files", "Sources/CoopHost/WorkspaceStage.swift",
     "if entries > limits.maxFiles {", "if entries < 0 {",
     "growthGuardStopsATransferThatOutgrowsTheBudget"),
    ("stage-conspicuous-husky", "Sources/CoopHost/WorkspaceStageReview.swift",
     "if components.contains(\".husky\")", "if components.contains(\".husky-none\")",
     "conspicuousPathsIgnoreCase"),
    ("stage-conspicuous-envrc", "Sources/CoopHost/WorkspaceStageReview.swift",
     "if components.last == \".envrc\"", "if components.last == \".envrc-none\"",
     "conspicuousPathsIgnoreCase"),
    ("stage-conspicuous-vscode", "Sources/CoopHost/WorkspaceStageReview.swift",
     "if components.suffix(2) == [\".vscode\", \"tasks.json\"]",
     "if components.suffix(2) == [\".vscode\", \"tasks-none.json\"]",
     "conspicuousPathsIgnoreCase"),
    ("stage-conspicuous-hooks", "Sources/CoopHost/WorkspaceStageReview.swift",
     "if rest.contains(\"hooks\")", "if rest.contains(\"hooks-none\")",
     "reviewShowsChangesDiffsAndConspicuousPaths"),
    ("audit-append", "Sources/CoopHost/BoundaryAudit.swift",
     "O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW", "O_WRONLY | O_CREAT | O_NOFOLLOW",
     "concurrentRecordersLoseNoEvents"),
    ("destroy-stage-first", "Sources/CoopHost/AppleLifecycle.swift",
     "    try stage.remove()\n", "",
     "destroyRemovesStagesWithGuestChosenModes"),
    ("stage-lock-stage", "Sources/CoopHost/Workspace.swift",
     "    let lock = try location.lock()\n    defer { lock.release() }\n    try location.prepare()\n",
     "    try location.prepare()\n",
     "stagedTransferWaitsForTheLockAndStopsWhenItOutgrowsTheBudget"),
    ("stage-lock-apply", "Sources/CoopHost/Workspace.swift",
     "    let lock = try location.lock()\n    defer { lock.release() }\n    let manifest = try location.loadManifest()\n",
     "    let manifest = try location.loadManifest()\n",
     "applyAndDiscardWaitForTheStageLock"),
    ("stage-lock-discard", "Sources/CoopHost/Workspace.swift",
     "    let lock = try location.lock()\n    defer { lock.release() }\n    guard location.exists else { return false }\n",
     "    guard location.exists else { return false }\n",
     "applyAndDiscardWaitForTheStageLock"),
    ("stage-growth-wiring", "Sources/CoopHost/Workspace.swift",
     "sparse: true, cancel: growth.shouldCancel)", "sparse: true, cancel: nil)",
     "stagedTransferWaitsForTheLockAndStopsWhenItOutgrowsTheBudget"),
    ("stage-rsync-wiring", "Sources/CoopHost/Workspace.swift",
     "preserveLinks: true, cancel: growth.shouldCancel)", "preserveLinks: true, cancel: nil)",
     "stagedTransferWaitsForTheLockAndStopsWhenItOutgrowsTheBudget"),
    ("stage-rsync-cancel", "Sources/CoopHost/Workspace.swift",
     "    rsync.isCancelled = cancel\n", "",
     "stagedTransferWaitsForTheLockAndStopsWhenItOutgrowsTheBudget"),
    ("stage-tar-cancel", "Sources/CoopHost/Workspace.swift",
     "    producer.isCancelled = cancel\n", "",
     "stagedTransferWaitsForTheLockAndStopsWhenItOutgrowsTheBudget"),
    ("runner-kills-descendants", "Sources/CoopHost/ProcessRunner.swift",
     "        for pid in Self.descendants(of: child.pid).reversed() { kill(pid, SIGKILL) }\n", "",
     "cancellingAnAttachedRequestKillsItsDescendants"),
    ("stage-hard-links", "Sources/CoopHost/WorkspaceStage.swift",
     "guard info.st_nlink == 1 else {", "guard info.st_nlink >= 1 else {",
     "specialFilesHardLinksAndBadNamesAreIssues"),
    ("stage-byte-budget", "Sources/CoopHost/WorkspaceStage.swift",
     "guard bytes <= limits.maxBytes.bytes else {", "guard bytes >= 0 else {",
     "budgetsAbortStaging"),
    ("stage-destination-drift", "Sources/CoopHost/WorkspaceStageApply.swift",
     "if now != change.old { drifted.append(change.path) }", "_ = now",
     "destinationDriftSinceReviewIsRefusedBeforeWriting"),
    ("stage-content-digest", "Sources/CoopHost/WorkspaceStageApply.swift",
     "guard copied == digest else {", "guard copied == digest || true else {",
     "stageTamperingAfterReviewIsRefused"),
]


TOP_LEVEL_SKIPS = {".git", ".build", "target", "coop-proxy", "coop-sandbox"}


def skip_top_level(directory, names):
    if Path(directory) != ROOT:
        return set()
    return {name for name in names if name in TOP_LEVEL_SKIPS or name.startswith("mutants.out")}


def run_tests(scratch, test_filter):
    return subprocess.run(
        ["swift", "test", "--filter", test_filter],
        cwd=scratch, capture_output=True, text=True, timeout=1800,
    )


def passed_count(result):
    return result.stdout.count("\u2714 Test ") + result.stdout.count("✔ Test ")


def failed_a_test(result):
    """A test ran and failed — not a compile error, which proves nothing."""
    return result.returncode != 0 and ("✘ Test " in result.stdout or "\u2718 Test " in result.stdout)


def run_fault(scratch, fault, verbose):
    ident, relative, original, replacement, test_filter = fault
    path = scratch / relative
    source = path.read_text()
    if original not in source:
        return f"{ident}: anchor not found in {relative}"
    path.write_text(source.replace(original, replacement, 1))
    try:
        # Concurrency faults are timing dependent; retry to make detection robust.
        attempts = 5 if ident == "config-writer-lock" else 1
        for _ in range(attempts):
            result = run_tests(scratch, test_filter)
            if verbose:
                print(result.stdout[-2000:], result.stderr[-2000:])
            if failed_a_test(result):
                return None
            if result.returncode != 0:
                return f"{ident}: the fault does not compile, so it proves nothing ({test_filter})"
        return f"{ident}: tests still pass with the fault ({test_filter})"
    finally:
        path.write_text(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--only", help="run a single fault id")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    faults = [f for f in FAULTS if not args.only or f[0] == args.only]
    with tempfile.TemporaryDirectory(prefix="coop-fault-") as directory:
        scratch = Path(directory) / "coop"
        shutil.copytree(
            ROOT, scratch,
            # Top-level build output and the companion packages only: a
            # pattern would also drop same-named fixtures (tests/fixtures/
            # coop-sandbox), and fuzz/Targets is a package target.
            ignore=skip_top_level,
        )
        # Control: every filter passes unmodified, so a failure under a fault
        # is the fault's effect and not a broken copy or a flaky test.
        filters = "|".join(sorted({f[4] for f in faults}))
        control = run_tests(scratch, filters)
        if control.returncode != 0 or not passed_count(control):
            print(control.stdout[-3000:], control.stderr[-3000:], file=sys.stderr)
            print("control run failed: the unmodified copy does not pass", file=sys.stderr)
            return 2
        survivors = []
        for fault in faults:
            outcome = run_fault(scratch, fault, args.verbose)
            status = "detected" if outcome is None else ("ANCHOR MISSING" if "anchor not found" in outcome else "SURVIVED")
            print(f"{fault[0]}: {status}", flush=True)
            if outcome:
                survivors.append(outcome)
    for survivor in survivors:
        print(survivor, file=sys.stderr)
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
