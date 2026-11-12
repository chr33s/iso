#!/usr/bin/env python3
"""Exercise the targeted Swift proxy policy and parser-limit mutations.

Mutations are applied to a scratch copy of iso-proxy (with the iso-policy
dependency and the proxy test fixtures it reads), so the working tree is never
modified, even if the run is killed. A compilation failure is not counted as a
killed mutant. This targeted gate supplements, rather than substitutes for, a
full Muter sweep.
"""

from pathlib import Path
import shutil
import subprocess
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


def run_tests(package):
    return subprocess.run(
        ["swift", "test", "--package-path", str(package)],
        capture_output=True, text=True, timeout=180,
    )


def main():
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
    for name, filename, before, after in MUTATIONS:
        path = sources / filename
        original = path.read_text()
        if original.count(before) != 1:
            raise SystemExit(f"Mutation no longer matches exactly once: {name}")
        try:
            path.write_text(original.replace(before, after, 1))
            result = run_tests(package)
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
