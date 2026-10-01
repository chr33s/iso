#!/usr/bin/env python3
"""Exercise the five mandatory Swift policy mutations from the port spec.

Run against an idle worktree: each mutation is restored in finally, including
when a test times out. A compilation failure is not counted as a killed mutant.
This targeted gate supplements, rather than substitutes for, a full Muter sweep.
"""

from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "iso-proxy"
SOURCES = PACKAGE / "Sources"
MUTATIONS = [
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
    # iso-inference (docs/design/secure-local-inference-spec.md §15).
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


def run_tests():
    return subprocess.run(
        ["swift", "test", "--package-path", str(PACKAGE)],
        capture_output=True, text=True, timeout=180,
    )


def main():
    # An optional argument selects mutations whose name contains it.
    selected = [m for m in MUTATIONS if len(sys.argv) < 2 or sys.argv[1] in m[0]]
    baseline = run_tests()
    if baseline.returncode:
        raise SystemExit("Baseline failed:\n" + baseline.stdout + baseline.stderr)
    for name, filename, before, after in selected:
        path = SOURCES / filename
        original = path.read_text()
        if original.count(before) != 1:
            raise SystemExit(f"Mutation no longer matches exactly once: {name}")
        try:
            path.write_text(original.replace(before, after, 1))
            result = run_tests()
            output = result.stdout + result.stderr
            if result.returncode == 0:
                raise SystemExit(f"SURVIVED: {name}")
            if "Test run with" not in output or "failed" not in output:
                raise SystemExit(f"Unviable mutation: {name}\n{output}")
            print(f"Killed: {name}", flush=True)
        finally:
            path.write_text(original)
    restored = run_tests()
    if restored.returncode:
        raise SystemExit("Restored baseline failed:\n" + restored.stdout + restored.stderr)
    print("All policy and parser-limit mutations killed; restored baseline passed.")


if __name__ == "__main__":
    main()
