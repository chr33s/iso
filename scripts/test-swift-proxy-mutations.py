#!/usr/bin/env python3
"""Exercise the five mandatory Swift policy mutations from the port spec.

Run against an idle worktree: each mutation is restored in finally, including
when a test times out. A compilation failure is not counted as a killed mutant.
This targeted gate supplements, rather than substitutes for, a full Muter sweep.
"""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "macos/coop-proxy"
SOURCES = PACKAGE / "Sources"
MUTATIONS = [
    ("deny becomes allow", "CoopProxyCore/OperationPolicy.swift", 'guard method == "POST" else { return false }',
     'guard method == "POST" else { return true }'),
    ("POST becomes any method", "CoopProxyCore/OperationPolicy.swift", 'guard method == "POST" else { return false }',
     'guard true else { return false }'),
    ("exact path becomes prefix", "CoopProxyCore/OperationPolicy.swift", 'target.path == "/v1/messages"',
     'target.path.hasPrefix("/v1/messages")'),
    ("stripped header is preserved", "CoopProxyCore/HeaderPolicy.swift", '!removed.contains($0.name.lowercased())', '!removed.contains($0.name.lowercased()) || true'),
    ("capability equality is inverted", "CoopProxyCore/Capability.swift",
     'return HMAC<SHA256>.isValidAuthenticationCode', 'return !HMAC<SHA256>.isValidAuthenticationCode'),
    ("header field limit removed", "CoopProxyTransport/InboundPipeline.swift",
     "limits.maxHeaderFieldSize = Limits.headerFieldBytes", "limits.maxHeaderFieldSize = 80 * 1024"),
    ("header block limit removed", "CoopProxyTransport/InboundPipeline.swift",
     "limits.maxHeaderListSize = Limits.headerBlockBytes", "limits.maxHeaderListSize = 2 * 1024 * 1024"),
    ("header count limit removed", "CoopProxyTransport/InboundPipeline.swift",
     "limits.maxHeaderFieldCount = Limits.headerCount", "limits.maxHeaderFieldCount = 256"),
]


def run_tests():
    return subprocess.run(
        ["swift", "test", "--package-path", str(PACKAGE)],
        capture_output=True, text=True, timeout=180,
    )


def main():
    baseline = run_tests()
    if baseline.returncode:
        raise SystemExit("Baseline failed:\n" + baseline.stdout + baseline.stderr)
    for name, filename, before, after in MUTATIONS:
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
