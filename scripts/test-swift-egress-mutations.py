#!/usr/bin/env python3
"""Check that filtered-egress DNS/ownership tests detect deliberately broken behavior.

Runs only local numeric-resolution and stalled-worker fixtures. No public DNS,
provider traffic, VM, or production policy bypass. Compile failures do not count.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FAULTS = [
    ('dns-slot-follows-worker',
     'return Deadline.wait(deadline) {\n      defer { admission.endDNS() }',
     'defer { admission.endDNS() }\n    return Deadline.wait(deadline) {',
     'resolverTimeoutKeepsActualWorkAdmittedAndFreesLateResults'),
    ('dns-owned-list-cleanup', 'deinit { release(info) }', 'deinit {}',
     'resolverTimeoutKeepsActualWorkAdmittedAndFreesLateResults'),
    ('dns-success-list-cleanup', 'deinit { release(info) }', 'deinit {}',
     'resolverSuccessOwnsItsListAndReleasesTheWorkSlot'),
    ('dns-failure-list-cleanup', 'if let info { release(info) }', 'if let info { _ = info }',
     'resolverFailureReleasesItsSlotAndAnyReturnedList'),
    ('dns-late-result',
     'state = DispatchTime.now() <= deadline ? .finished(value) : .abandoned',
     'state = .finished(value)',
     'deadlineRejectsAResultFinishedAfterItsMonotonicDeadline'),
]


def run_tests(package, test_filter):
    return subprocess.run(['swift', 'test', '--package-path', str(package),
                           '--force-resolved-versions', '--filter', test_filter],
                          capture_output=True, text=True, timeout=180)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--only', choices=[fault[0] for fault in FAULTS])
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()
    faults = [fault for fault in FAULTS if not args.only or fault[0] == args.only]
    with tempfile.TemporaryDirectory(prefix='iso-egress-fault-') as directory:
        package = Path(directory) / 'iso-egress'
        shutil.copytree(ROOT / 'iso-egress', package,
                        ignore=shutil.ignore_patterns('.build', '.swiftpm'))
        filters = '|'.join(sorted({fault[3] for fault in faults}))
        control = run_tests(package, filters)
        if control.returncode != 0 or any(f'✔ Test {fault[3]}' not in control.stdout
                                          for fault in faults):
            print(control.stdout[-6000:], control.stderr[-6000:], file=sys.stderr)
            print('FAIL: unmodified control did not run and pass every target test', file=sys.stderr)
            return 2
        path = package / 'Sources/IsoEgressCore/Dial.swift'
        source = path.read_text()
        failures = []
        for ident, original, replacement, test_filter in faults:
            if source.count(original) != 1:
                failures.append(ident)
                print(f'FAIL {ident}: anchor must match exactly once', flush=True)
                continue
            path.write_text(source.replace(original, replacement, 1))
            try:
                result = run_tests(package, test_filter)
            finally:
                path.write_text(source)
            if args.verbose:
                print(result.stdout[-6000:], result.stderr[-2000:], flush=True)
            if result.returncode != 0 and f'✘ Test {test_filter}' in result.stdout:
                print(f'PASS {ident}: test detected fault', flush=True)
            else:
                failures.append(ident)
                print(result.stdout[-6000:], result.stderr[-2000:], file=sys.stderr)
                print(f'FAIL {ident}: survived or did not compile/run its test', flush=True)
        return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
