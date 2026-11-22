#!/usr/bin/env python3
"""Exercise the targeted Swift proxy and inference gateway policy and parser-limit mutations.

Mutations are applied to a scratch copy of iso-proxy (with the iso-policy
dependency and the proxy test fixtures it reads), so the working tree is never
modified, even if the run is killed. A compilation failure is not counted as a
killed mutant. This targeted gate supplements, rather than substitutes for, a
full Muter sweep.
"""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MUTATIONS = [
    ("broker paused response deadline removed", "IsoProxyTransport/InboundGate.swift",
     'context.eventLoop.scheduleTask(in: .seconds(1))', 'context.eventLoop.scheduleTask(in: .seconds(3600))'),
    ("broker nonce validation removed", "IsoProxyCore/Readiness.swift",
     'nonces.count == 1, Self.hex(nonces[0].value, count: 16) != nil', 'nonces.count == 1'),
    ("broker method check removed", "IsoProxyCore/Readiness.swift", 'method == "GET",', 'true,'),
    ("broker exact URI check removed", "IsoProxyCore/Readiness.swift", 'uri == path,', 'true,'),
    ("broker closed headers removed", "IsoProxyCore/Readiness.swift", 'headers.count == 4', 'true'),
    ("broker provider identity changed", "IsoProxyCore/Readiness.swift", 'self.provider = provider', 'self.provider = .anthropic'),
    ("broker version separation removed", "IsoProxyCore/ProxyConfig.swift",
     'guard wire.readiness == nil, wire.authorization == nil else {', 'guard wire.authorization == nil else {'),
    ("deny becomes allow", "IsoProxyCore/OperationPolicy.swift", 'guard method == "POST" else { return false }',
     'guard method == "POST" else { return true }'),
    ("POST becomes any method", "IsoProxyCore/OperationPolicy.swift", 'guard method == "POST" else { return false }',
     'guard true else { return false }'),
    ("exact path becomes prefix", "IsoProxyCore/OperationPolicy.swift", 'target.path == "/v1/messages"',
     'target.path.hasPrefix("/v1/messages")'),
    ("stripped header is preserved", "IsoProxyCore/HeaderPolicy.swift", '!removed.contains($0.name.lowercased())', '!removed.contains($0.name.lowercased()) || true'),
    ("capability equality is inverted", "IsoProxyCore/Capability.swift",
     'return HMAC<SHA256>.isValidAuthenticationCode', 'return !HMAC<SHA256>.isValidAuthenticationCode'),
    ("header field limit removed", "IsoProxyTransport/InboundPipeline.swift",
     "limits.maxHeaderFieldSize = Limits.headerFieldBytes", "limits.maxHeaderFieldSize = 80 * 1024"),
    ("header block limit removed", "IsoProxyTransport/InboundPipeline.swift",
     "limits.maxHeaderListSize = Limits.headerBlockBytes", "limits.maxHeaderListSize = 2 * 1024 * 1024"),
    ("header count limit removed", "IsoProxyTransport/InboundPipeline.swift",
     "limits.maxHeaderFieldCount = Limits.headerCount", "limits.maxHeaderFieldCount = 256"),
]

# iso-inference (docs/design/secure-local-inference-spec.md §15). Each runs
# only the inference test targets; the credential proxy mutants above skip them.
INFERENCE_TESTS = ["IsoInferenceCoreTests", "IsoInferenceGatewayTests", "IsoProxyFuzzReplayTests"]
INFERENCE_MUTATIONS = [
    ("inference capability bypassed", "IsoInferenceGateway/RequestHandler.swift",
     "guard session.capability.authorizes(headers) else {",
     "guard session.capability.authorizes(headers) || true else {"),
    ("inference inactive session admitted", "IsoInferenceGateway/RequestHandler.swift",
     "guard session.admits(at: .now) else {", "guard session.admits(at: .now) || true else {"),
    ("inference unknown field dropped", "IsoInferenceCore/Schema.swift",
     "throw InferenceError(.unsupported, \"field '\\(field)' is not supported\")", "continue"),
    ("inference denied field dropped", "IsoInferenceCore/Schema.swift",
     "throw InferenceError(.policyDenied, \"field '\\(field)' is not permitted\")", "continue"),
    ("inference duplicate keys accepted", "IsoInferenceCore/JSON.swift",
     "guard seen.insert(key).inserted else { throw .duplicateKey }", "_ = seen.insert(key)"),
    ("inference query allowlist removed", "IsoInferenceCore/Protocols.swift",
     "guard api.allowedQueries.contains(String(pieces[1])) else { return nil }", ""),
    ("inference upstream model not rewritten", "IsoInferenceCore/Normalizer.swift",
     "document[\"model\"] = .string(grant.upstreamModel)", ""),
    ("inference transport start ignored", "IsoInferenceGateway/Gateway.swift",
     "&& identity.start == binding.start", ""),
    ("inference drain releases on disconnect", "IsoInferenceGateway/RequestHandler.swift",
     "      cancellation = .draining\n", "      cancellation = .draining\n      settle()\n"),
    ("inference session socket name unchecked", "IsoInferenceCore/ControlProtocol.swift",
     "guard Registration.isSocketName(socket) else {", "guard true else {"),
    ("inference backend port outside the launch list", "IsoInferenceGateway/Gateway.swift",
     "if let allowed = backendPorts,", "if let allowed = backendPorts, allowed.isEmpty,"),
    ("inference handler keeps its context", "IsoInferenceGateway/RequestHandler.swift",
     "    self.context = nil\n    clientGone = true\n", "    clientGone = true\n"),
    ("inference connection slots never released", "IsoInferenceGateway/RequestHandler.swift",
     "      own.release()\n      shared.release()\n", ""),
    ("inference close deadline removed", "IsoInferenceGateway/RequestHandler.swift",
     "in: TimeAmount(timing.close)) {\n      channel.close(promise: nil)\n    }",
     "in: TimeAmount(timing.close)) {}"),
    ("inference session buffer share ignored", "IsoInferenceGateway/RequestHandler.swift",
     "gateway.buffers.reserve(length, alsoFrom: session.buffers)", "gateway.buffers.reserve(length)"),
    ("inference rate token free", "IsoInferenceCore/Scheduler.swift",
     "      session.tokens -= 1\n      state.sessions[name] = session",
     "      state.sessions[name] = session"),
    ("inference audit window never aggregates", "IsoInferenceGateway/AuditLog.swift",
     "      guard instant - open.since >= Self.window else {", "      guard false else {"),
    ("inference rejection audited twice", "IsoInferenceGateway/RequestHandler.swift",
     "    } else {\n      clientError(error)\n    }",
     "    } else {\n      gateway.audit.rejected(session: session.id, code: error.code)\n"
     "      clientError(error)\n    }"),
    ("inference header read deadline removed", "IsoInferenceGateway/RequestHandler.swift",
     "    arm(&readDeadline, after: timing.headerRead) { handler in",
     "    arm(&readDeadline, after: .seconds(3600)) { handler in"),
    ("inference header overflow is a plain 400", "IsoInferenceGateway/RequestHandler.swift",
     "== .headerOverflow ? .requestHeaderFieldsTooLarge : .badRequest",
     "== .headerOverflow ? .badRequest : .badRequest"),
    ("inference HTTP/1.0 accepted", "IsoInferenceGateway/RequestHandler.swift",
     "    guard head.version == .http1_1 else {", "    guard head.version == .http1_1 || true else {"),
    ("inference session connection cap removed", "IsoInferenceGateway/RequestHandler.swift",
     "    guard let own = session.connections.acquire() else {",
     "    guard let own = session.connections.acquire() ?? SlotPool(1).acquire() else {"),
    ("inference auth failure window ignored", "IsoInferenceGateway/RequestHandler.swift",
     "    guard !session.failures.tripped, let shared", "    guard let shared"),
    ("inference 100-continue before authentication", "IsoInferenceGateway/RequestHandler.swift",
     "    wireBudget.headReceived()\n    guard head.version",
     "    wireBudget.headReceived()\n    context?.writeAndFlush(wrapOutboundOut(.head("
     "HTTPResponseHead(version: .http1_1, status: .continue))), promise: nil)\n    guard head.version"),
    ("inference pipelined request ignored", "IsoInferenceGateway/RequestHandler.swift",
     "    guard phase == .head || phase == .body else { return context.close(promise: nil) }\n"
     "    switch unwrapInboundIn(data) {",
     "    guard phase == .head || phase == .body else { return }\n    switch unwrapInboundIn(data) {"),
    ("inference stream-close leaves the stream open", "IsoInferenceGateway/RequestHandler.swift",
     "      cancellation = .closing\n      upstream?.close()\n      // Closing",
     "      cancellation = .closing\n      // Closing"),
    ("inference missing usage accepted", "IsoInferenceGateway/RequestHandler.swift",
     "    } else if completed, usage.inputTokens == nil {",
     "    } else if false, completed, usage.inputTokens == nil {"),
    ("inference accept failure ends the control plane", "IsoInferenceGateway/ControlServer.swift",
     "        usleep(pause)\n        pause = min(pause * 2, 1_000_000)", "        return"),
    ("inference activation ignores the boot identity", "IsoInferenceGateway/Gateway.swift",
     "    guard binding.pid == session.boot.ownerPID, binding.start == session.boot.ownerStart else {",
     "    guard true else {"),
    ("inference another instance's socket name accepted", "IsoInferenceGateway/Gateway.swift",
     "      $0.socketName == registration.socket && $0.instance != registration.instance",
     "      false && $0.socketName == registration.socket"),
    ("inference revocation keeps the socket file", "IsoInferenceGateway/Gateway.swift",
     "    if let socket { removeSocket(socket) }", ""),
    ("inference revocation unlinks a replaced file", "IsoInferenceGateway/Sockets.swift",
     "    guard BoundSocket(path: path) == self else { return }", ""),
    ("inference stale sockets kept", "IsoInferenceGateway/Gateway.swift",
     "      BoundSocket.removeStale(relayDirectory + \"/\" + name)", ""),
    ("inference content type split traps", "IsoInferenceCore/HeaderTable.swift",
     "let media = value.prefix { $0 != \";\" }", "let media = value.split(separator: \";\")[0]"),
    ("inference parse tree unbounded", "IsoInferenceCore/JSON.swift",
     "      guard values <= maxValues else { throw .tooManyValues }", ""),
    ("inference opaque tool choice", "IsoInferenceCore/FieldTables.swift",
     "      \"tool_choice\": .forward(responsesToolChoice),",
     "      \"tool_choice\": .forward(.opaque(maxBytes: Size.smallObject)),"),
    ("inference dropped fields unchecked", "IsoInferenceCore/FieldTables.swift",
     "  static let droppedObject: Schema = .opaqueObject(maxBytes: Size.smallObject)",
     "  static let droppedObject: Schema = .opaque(maxBytes: Size.smallObject)"),
    ("inference event name unchecked", "IsoInferenceCore/StreamTranslator.swift",
     "guard case .string(let type)? = event[\"type\"], Self.isEventName(type) else {",
     "guard case .string(let type)? = event[\"type\"] else {"),
    ("inference usage range unchecked", "IsoInferenceCore/StreamTranslator.swift",
     "if let count = number.int64, (0...Int64(Usage.maxTokens)).contains(count) {",
     "if let count = number.int64 {"),
    ("inference backend error text relayed", "IsoInferenceCore/StreamTranslator.swift",
     "    if outcome == .failed { return Self.backendError.streamEvent(for: api) }\n", ""),
    ("inference integers rounded", "IsoInferenceCore/JSON.swift",
     "  package var int64: Int64? { Int64(text) }",
     "  package var int64: Int64? { Int64(text) ?? Double(text).flatMap { Int64(exactly: $0) } }"),
    ("inference top-level model not rewritten", "IsoInferenceCore/StreamTranslator.swift",
     "    if object[\"model\"] != nil { object[\"model\"] = .string(alias) }\n", ""),
]


def run_tests(package, filters=(), skips=()):
    command = ["swift", "test", "--package-path", str(package)]
    for name in filters:
        command += ["--filter", name]
    for name in skips:
        command += ["--skip", name]
    return subprocess.run(command, capture_output=True, text=True, timeout=180)


def main():
    # Manifests keep warnings-as-errors off for scratch builds (see Package.swift).
    os.environ["ISO_MUTATION_BUILD"] = "1"
    with tempfile.TemporaryDirectory(prefix="iso-proxy-mutation-") as directory:
        scratch = Path(directory)
        # The proxy package resolves ../iso-policy, and its tests read the
        # proxy fixtures and the production Seatbelt profile relative to the
        # repository root.
        build_output = shutil.ignore_patterns(".build", ".swiftpm")
        for package in ("iso-proxy", "iso-policy"):
            shutil.copytree(ROOT / package, scratch / package, ignore=build_output)
        shutil.copytree(ROOT / "tests/fixtures/credential-proxy",
                        scratch / "tests/fixtures/credential-proxy")
        # The fuzz corpus replay test reads ../fuzz/corpus.
        for target in ("ProxyRequestTarget", "ProxyHeaders", "ProxyCapability",
                       "InferenceRequest", "InferenceStream", "InferenceControl",
                       "InferenceHeaders"):
            shutil.copytree(ROOT / "fuzz/corpus" / target, scratch / "fuzz/corpus" / target)
        profile = Path("Sources/IsoHost/Guest/Resources/seatbelt-proxy.sb")
        (scratch / profile.parent).mkdir(parents=True)
        shutil.copy2(ROOT / profile, scratch / profile)
        run_mutations(scratch / "iso-proxy")


def run_mutations(package):
    sources = package / "Sources"
    # The scratch copy starts without build output; build it once outside the
    # per-run test timeout.
    subprocess.run(["swift", "build", "--build-tests", "--package-path", str(package)],
                   capture_output=True, timeout=1800, check=True)
    baseline = run_tests(package)
    if baseline.returncode:
        raise SystemExit("Baseline failed:\n" + baseline.stdout + baseline.stderr)
    selected = [(m, (), ("IsoInference",)) for m in MUTATIONS]
    selected += [(m, INFERENCE_TESTS, ()) for m in INFERENCE_MUTATIONS]
    # An optional argument selects mutations whose name contains it.
    if len(sys.argv) > 1:
        selected = [entry for entry in selected if sys.argv[1] in entry[0][0]]
    for (name, filename, before, after), filters, skips in selected:
        path = sources / filename
        original = path.read_text()
        if original.count(before) != 1:
            raise SystemExit(f"Mutation no longer matches exactly once: {name}")
        try:
            path.write_text(original.replace(before, after, 1))
            result = run_tests(package, filters, skips)
            output = result.stdout + result.stderr
            if result.returncode == 0:
                raise SystemExit(f"SURVIVED: {name}")
            if "Test run with" not in output or "failed" not in output:
                raise SystemExit(f"Unviable mutation: {name}\n{output}")
            print(f"Killed: {name}", flush=True)
        finally:
            path.write_text(original)
    restored = run_tests(package)
    if restored.returncode:
        raise SystemExit("Restored baseline failed:\n" + restored.stdout + restored.stderr)
    print("All policy and parser-limit mutations killed; restored baseline passed.")


if __name__ == "__main__":
    main()
