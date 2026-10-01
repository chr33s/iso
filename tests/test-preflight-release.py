#!/usr/bin/env python3
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

"""Exercise release preflight dispatch and version gates without building VMs."""
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

# Stand-in for every Python gate: records its path and arguments.
PYTHON_STUB = '''import os, sys
with open(os.environ["PREFLIGHT_CALLS"], "a") as f:
    f.write(" ".join([os.path.basename(sys.argv[0]), *sys.argv[1:]]) + "\\n")
sys.exit(1 if os.path.basename(sys.argv[0]) == os.environ.get("PREFLIGHT_FAIL") else 0)
'''

# Stand-in for tools and shell gates: records its name and arguments.
TOOL_STUB = '''#!/bin/bash
printf '%s %s\\n' "${0##*/}" "$*" >> "$PREFLIGHT_CALLS"
if [[ "${0##*/} $*" == "${PREFLIGHT_FAIL:-}" || "${0##*/}" == "${PREFLIGHT_FAIL:-}" ]]; then exit 1; fi
'''

PYTHON_GATES = [
    'tests/test-swift-host-read-parity.py', 'tests/test-swift-host-lifecycle-parity.py',
    'tests/test-swift-host-data-root-parity.py', 'tests/test-swift-host-cli-surface.py',
    'tests/test-migrate-config.py', 'tests/test-preflight-release.py',
    'scripts/test-swift-proxy-process.py', 'scripts/build-release.py',
]
SHELL_GATES = [
    'tests/integration-install.sh', 'tests/integration-update.sh',
    'tests/integration-uninstall.sh', 'tests/run-integration.sh', 'scripts/fuzz.sh',
]


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('scripts', 'tests', 'bin', 'Sources/IsoHost'):
            (self.root / directory).mkdir(parents=True)
        (self.root / 'scripts/preflight-release.sh').write_text(
            (ROOT / 'scripts/preflight-release.sh').read_text())
        self.version('9.8.7')
        (self.root / 'CHANGELOG.md').write_text('## v9.8.7\n\nRelease notes.\n')
        self.log = self.root / 'calls'
        # cargo and rustup must never be reached; they record if they are.
        for name in ('swift', 'zizmor', 'cargo', 'rustup'):
            self.executable('bin/' + name, TOOL_STUB)
        self.executable('bin/sw_vers', '#!/bin/bash\necho 26.0\n')
        self.executable('bin/uname', '#!/bin/bash\necho Darwin\n')
        self.executable('bin/git', '''#!/bin/bash
if [[ "$1" == rev-parse ]]; then exit 1; fi
''')
        for name in PYTHON_GATES:
            (self.root / name).write_text(PYTHON_STUB)
        for name in SHELL_GATES:
            self.executable(name, TOOL_STUB)

    def executable(self, name, contents):
        path = self.root / name
        path.write_text(contents)
        path.chmod(0o755)

    def version(self, version):
        (self.root / 'Sources/IsoHost/UpdateVersion.swift').write_text(
            'public enum BuildInfo {\n'
            f'  public static let packageVersion = "{version}"\n'
            '}\n')

    def run_preflight(self, *args, fail=''):
        return subprocess.run(
            ['bash', str(self.root / 'scripts/preflight-release.sh'), *args],
            env={**os.environ, 'PATH': str(self.root / 'bin') + ':' + os.environ['PATH'],
                 'PREFLIGHT_CALLS': str(self.log), 'PREFLIGHT_FAIL': fail},
            capture_output=True, text=True, timeout=20)

    def calls(self):
        return self.log.read_text().splitlines()

    def test_package_version_and_gates(self):
        result = self.run_preflight('--quick')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Version sources agree; tag v9.8.7 is free.', result.stdout)
        calls = self.calls()
        for call in ('swift format lint --recursive --strict Package.swift Sources tests/swift '
                     'fuzz/Targets fuzz/Entrypoints iso-proxy/Sources iso-proxy/Tests '
                     'iso-sandbox/Package.swift iso-sandbox/Sources iso-sandbox/Tests',
                     'swift build --force-resolved-versions',
                     'swift test --force-resolved-versions',
                     'swift test --package-path iso-sandbox --force-resolved-versions --no-parallel',
                     'test-swift-host-read-parity.py --swift .build/debug/iso',
                     'test-swift-host-lifecycle-parity.py --swift .build/debug/iso',
                     'test-swift-host-data-root-parity.py --swift .build/debug/iso',
                     'test-swift-host-cli-surface.py --swift .build/debug/iso',
                     'test-migrate-config.py', 'test-preflight-release.py',
                     'zizmor .github/workflows/', 'integration-install.sh ',
                     'integration-update.sh ', 'integration-uninstall.sh '):
            self.assertIn(call, calls)
        # --quick skips the archive build, the VM suite and fuzzing.
        self.assertFalse([c for c in calls if c.startswith(('build-release.py', 'run-integration.sh', 'fuzz.sh'))])
        self.assertFalse([c for c in calls if c.startswith(('cargo', 'rustup'))])
        self.assertNotIn('Next: tag', result.stdout)
        self.assertIn('unrun gates before tagging', result.stdout)

    def test_full_run_builds_the_release_archive_on_macos_27(self):
        self.executable('bin/sw_vers', '#!/bin/bash\necho 27.0\n')
        result = self.run_preflight('--fuzz')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn('build-release.py --release --tag v9.8.7 --out .build/preflight-release', calls)
        self.assertIn('run-integration.sh ', calls)
        self.assertIn('fuzz.sh smoke 30', calls)
        self.assertIn('swift test --package-path iso-proxy --force-resolved-versions', calls)
        self.assertIn('test-swift-proxy-process.py --skip-tls', calls)
        self.assertIn('All required checks passed for v9.8.7.', result.stdout)

    def test_older_macos_warns_instead_of_building_the_archive(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse([c for c in self.calls() if c.startswith('build-release.py')])
        self.assertIn('release archive not built locally', result.stdout)
        self.assertNotIn('Next: tag', result.stdout)

    def test_changelog_mismatch_fails(self):
        self.version('9.8.8')
        result = self.run_preflight('--quick')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CHANGELOG.md has no exact "## v9.8.8" header', result.stdout)
        self.assertIn('FAIL: Version consistency', result.stdout)

    def test_unreadable_version_fails(self):
        (self.root / 'Sources/IsoHost/UpdateVersion.swift').write_text('// no version\n')
        result = self.run_preflight('--quick')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not read packageVersion', result.stderr)

    def test_host_test_failure_is_fatal(self):
        result = self.run_preflight('--quick', fail='swift test --force-resolved-versions')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL: Swift host build and tests', result.stdout)
        self.assertIn('Preflight FAILED', result.stdout)

    def test_baseline_failure_is_fatal(self):
        result = self.run_preflight('--quick', fail='test-swift-host-lifecycle-parity.py')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL: Recorded-baseline parity', result.stdout)


class ReleaseBinaryTests(unittest.TestCase):
    def test_release_source_gate_rejects_commit_outside_main(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        script = re.search(
            r"- name: Require a release commit from main\n        run: (.*)",
            workflow)[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, check=True,
                                      capture_output=True, text=True).stdout.strip()
            git('init', '-b', 'main')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            git('commit', '--allow-empty', '-m', 'release source')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            accepted = subprocess.run(['bash', '-euc', script], cwd=root)
            self.assertEqual(accepted.returncode, 0)
            git('checkout', '-b', 'unpublished')
            git('commit', '--allow-empty', '-m', 'not on main')
            rejected = subprocess.run(['bash', '-euc', script], cwd=root)
            self.assertNotEqual(rejected.returncode, 0)

    def test_packaging_requires_release_identity_and_companions(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        block = re.search(
            r"      - name: Verify release binaries\n.*?        run: \|\n(.*?)\n\n",
            workflow, re.S)[1]
        script = "\n".join(line[10:] for line in block.splitlines())
        name = 'iso-v9.8.7-aarch64-apple-darwin'
        for version, has_proxy, has_runtime, expected in [
                ('iso 9.8.7 (abc1234)', True, True, 0),
                ('iso 9.8.7-dev (abc1234+dirty)', True, True, 1),
                ('iso 9.8.6 (abc1234)', True, True, 1),
                ('iso 9.8.7 (abc1235)', True, True, 1),
                ('iso 9.8.7 (abc1234)', False, True, 1),
                ('iso 9.8.7 (abc1234)', True, False, 1)]:
            with self.subTest(version=version, proxy=has_proxy, runtime=has_runtime), \
                    tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bundle = root / 'bundle' / name
                bundle.mkdir(parents=True)
                binaries = {'iso': f"#!/bin/sh\nprintf '%s\\n' '{version}'\n"}
                if has_proxy:
                    binaries['iso-proxy'] = '#!/bin/sh\nexit 0\n'
                if has_runtime:
                    binaries['iso-sandbox'] = '#!/bin/sh\nexit 0\n'
                for binary, text in binaries.items():
                    (bundle / binary).write_text(text)
                    (bundle / binary).chmod(0o755)
                (root / 'dist').mkdir()
                with tarfile.open(root / 'dist' / f'{name}.tar.gz', 'w:gz') as tar:
                    tar.add(bundle, arcname=name)
                github_env = root / 'github-env'
                result = subprocess.run(
                    ['bash', '-euc', script], cwd=root,
                    env={**os.environ, 'RUNNER_TEMP': str(root), 'GITHUB_ENV': str(github_env),
                         'BINARY': 'iso', 'TAG': 'v9.8.7', 'TARGET': 'aarch64-apple-darwin',
                         'REVISION': 'abc1234' + '0' * 33},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected == 0:
                    self.assertEqual(github_env.read_text(),
                                     f"TARBALL={root}/dist/{name}.tar.gz\n")


if __name__ == '__main__':
    unittest.main()
