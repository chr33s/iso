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
                       "InferenceRequest", "InferenceStream", "InferenceControl"):
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
