#!/usr/bin/env python3
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

"""Exercise release preflight dispatch and version gates without building VMs."""
import importlib.util
import base64
import os
import re
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

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
if [[ "${0##*/} $*" == "swift build --package-path iso-proxy --show-bin-path" ]]; then
    printf '%s\\n' "$PWD/.build/proxy-test"
fi
if [[ "${0##*/} $*" == "swift test --package-path iso-proxy --force-resolved-versions" ]]; then
    printf 'proxy-e2e-binary=%s\\n' "$ISO_PROXY_E2E_BINARY" >> "$PREFLIGHT_CALLS"
fi
'''

PYTHON_GATES = [
    'tests/test-read-contract.py', 'tests/test-lifecycle-contract.py',
    'tests/test-data-root-contract.py', 'tests/test-machine-contract.py',
    'tests/test-cli-surface.py',
    'tests/test-preflight-release.py', 'tests/test-verify-candidate.py', 'tests/test-accept-release.py',
    'scripts/build-release.py',
    'scripts/test-swift-egress-jail.py', 'scripts/test-swift-egress-lease.py',
    'scripts/test-swift-egress-pressure.py',
    'tests/integration-filtered-broker-readiness.py',
    'scripts/test-swift-egress-mutations.py',
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
        for directory in ('scripts', 'tests', 'bin', 'Sources/IsoHost/Update'):
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
        (self.root / 'Sources/IsoHost/Update/UpdateVersion.swift').write_text(
            'package enum BuildInfo {\n'
            f'  package static let packageVersion = "{version}"\n'
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
                     'iso-egress/Package.swift iso-egress/Sources iso-egress/Tests '
                     'scripts/verify-egress-readiness.swift '
                     'iso-sandbox/Package.swift iso-sandbox/Sources iso-sandbox/Tests',
                     'swift build --force-resolved-versions',
                     'swift test --force-resolved-versions',
                     'swift test --package-path iso-sandbox --force-resolved-versions --no-parallel',
                     'test-read-contract.py --swift .build/debug/iso',
                     'test-lifecycle-contract.py --swift .build/debug/iso',
                     'test-data-root-contract.py --swift .build/debug/iso',
                     'test-machine-contract.py --swift .build/debug/iso',
                     'test-cli-surface.py --swift .build/debug/iso',
                     'test-preflight-release.py',
                     'test-verify-candidate.py', 'test-accept-release.py',
                     'zizmor .github/workflows/', 'integration-install.sh ',
                     'integration-update.sh ', 'integration-uninstall.sh '):
            self.assertIn(call, calls)
        # --quick skips the archive build, the VM suite and fuzzing.
        self.assertFalse([c for c in calls if c.startswith(('build-release.py', 'run-integration.sh', 'fuzz.sh'))])
        self.assertNotIn('integration-filtered-broker-readiness.py', calls)
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
        self.assertIn('swift build --package-path iso-proxy --force-resolved-versions', calls)
        self.assertIn('swift build --package-path iso-proxy --show-bin-path', calls)
        self.assertIn(f'proxy-e2e-binary={self.root}/.build/proxy-test/iso-proxy', calls)
        self.assertIn('swift test --package-path iso-egress --force-resolved-versions', calls)
        self.assertIn('swift build --package-path iso-egress --force-resolved-versions', calls)
        self.assertIn('test-swift-egress-jail.py', calls)
        self.assertIn('test-swift-egress-lease.py', calls)
        self.assertIn('test-swift-egress-mutations.py', calls)
        self.assertIn('integration-filtered-broker-readiness.py', calls)
        self.assertIn('All required checks passed for v9.8.7.', result.stdout)

    def test_proxy_build_and_e2e_failures_are_fatal(self):
        self.executable('bin/sw_vers', '#!/bin/bash\necho 27.0\n')
        for gate in ('swift build --package-path iso-proxy --force-resolved-versions',
                     'swift build --package-path iso-proxy --show-bin-path',
                     'swift test --package-path iso-proxy --force-resolved-versions'):
            with self.subTest(gate=gate):
                result = self.run_preflight('--quick', fail=gate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('FAIL: Swift proxy', result.stdout)
                self.assertIn('Preflight FAILED', result.stdout)

    def test_egress_process_and_mutation_failures_are_fatal(self):
        self.executable('bin/sw_vers', '#!/bin/bash\necho 27.0\n')
        for gate in ('test-swift-egress-lease.py', 'test-swift-egress-pressure.py', 'test-swift-egress-mutations.py'):
            with self.subTest(gate=gate):
                result = self.run_preflight('--quick', fail=gate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('FAIL: Swift egress tests and confined lease', result.stdout)
                self.assertIn('Preflight FAILED', result.stdout)

    def test_filtered_vm_failure_is_fatal(self):
        self.executable('bin/sw_vers', '#!/bin/bash\necho 27.0\n')
        result = self.run_preflight(fail='integration-filtered-broker-readiness.py')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL: Filtered VM transport, revocation and network', result.stdout)

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
        (self.root / 'Sources/IsoHost/Update/UpdateVersion.swift').write_text('// no version\n')
        result = self.run_preflight('--quick')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not read packageVersion', result.stderr)

    def test_host_test_failure_is_fatal(self):
        result = self.run_preflight('--quick', fail='swift test --force-resolved-versions')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL: Swift host build and tests', result.stdout)
        self.assertIn('Preflight FAILED', result.stdout)

    def test_baseline_failure_is_fatal(self):
        for gate in ('test-lifecycle-contract.py', 'test-machine-contract.py'):
            with self.subTest(gate=gate):
                result = self.run_preflight('--quick', fail=gate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('FAIL: Host behavior contracts', result.stdout)


class SigningTests(unittest.TestCase):
    VARIABLES = (
        'MACOS_CERTIFICATE_P12', 'MACOS_CERTIFICATE_PASSWORD', 'MACOS_SIGNING_IDENTITY',
        'NOTARY_API_KEY_P8', 'NOTARY_API_KEY_ID', 'NOTARY_API_ISSUER_ID',
    )

    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        root = Path(cls.fixture.name)
        cls.addClassCleanup(cls.fixture.cleanup)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem'),
                        '-days', '1', '-subj', '/CN=iso-synthetic'],
                       check=True, capture_output=True, timeout=20)
        subprocess.run(['openssl', 'pkcs12', '-export', '-in', str(root / 'cert.pem'),
                        '-inkey', str(root / 'key.pem'), '-out', str(root / 'cert.p12'),
                        '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES',
                        '-macalg', 'sha1', '-passout', 'pass:synthetic-value'],
                       check=True, capture_output=True, timeout=10)
        cls.certificate = base64.b64encode((root / 'cert.p12').read_bytes()).decode()
        cls.cer = base64.b64encode((root / 'cert.pem').read_bytes()).decode()

    def environment(self):
        return {**os.environ, **{name: 'synthetic-value' for name in self.VARIABLES},
                'MACOS_CERTIFICATE_P12': self.certificate}

    def test_environment_check_rejects_unreadable_certificate(self):
        for certificate, password in (
                ('!!!', 'synthetic-value'),
                (base64.b64encode(b'not a PKCS12 file').decode(), 'synthetic-value'),
                (self.cer, 'synthetic-value'),
                (self.certificate, 'incorrect-secret-password')):
            with self.subTest(certificate=certificate[:8], password=password):
                env = self.environment()
                env.update(MACOS_CERTIFICATE_P12=certificate, MACOS_CERTIFICATE_PASSWORD=password)
                result = subprocess.run(
                    ['bash', str(ROOT / 'scripts/macos-sign-notarize.sh'), '--check-env'],
                    env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('MACOS_CERTIFICATE_P12', result.stderr)
                self.assertNotIn(certificate, result.stdout + result.stderr)
                self.assertNotIn(password, result.stdout + result.stderr)

    def test_environment_check_reports_missing_names_without_secret_values(self):
        for name in self.VARIABLES:
            for unset in (False, True):
                with self.subTest(name=name, unset=unset):
                    env = self.environment()
                    if unset:
                        env.pop(name)
                    else:
                        env[name] = ''
                    result = subprocess.run(
                        ['bash', str(ROOT / 'scripts/macos-sign-notarize.sh'), '--check-env'],
                        env=env, capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f'{name} is not set', result.stderr)
                    self.assertNotIn('synthetic-value', result.stdout + result.stderr)
        result = subprocess.run(
            ['bash', str(ROOT / 'scripts/macos-sign-notarize.sh'), '--check-env'],
            env=self.environment(), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')

    def test_signed_builder_rejects_missing_environment_before_staging(self):
        spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/build-release.py')
        release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release)
        env = self.environment()
        env['NOTARY_API_KEY_ID'] = ''
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(release.platform, 'system', return_value='Darwin'), \
                mock.patch.object(release.platform, 'machine', return_value='arm64'), \
                mock.patch.object(release.platform, 'mac_ver', return_value=('27.0', '', '')), \
                mock.patch.object(release, 'source_state', return_value=('a' * 40, False)), \
                mock.patch.object(release, 'stage_source',
                                  side_effect=AssertionError('staged before checking signing environment')) as stage, \
                mock.patch.object(release, 'build',
                                  side_effect=AssertionError('built before checking signing environment')) as build, \
                mock.patch.object(sys, 'argv', ['build-release.py', '--release', '--sign',
                                              '--expected-revision', 'a' * 40,
                                              '--out', str(Path(directory) / 'out')]):
            with self.assertRaises(subprocess.CalledProcessError):
                release.main()
            stage.assert_not_called()
            build.assert_not_called()
            self.assertFalse((Path(directory) / 'out').exists())

    def run_signing(self, *, identity='Developer ID Application: Synthetic (TESTTEAM)',
                    identities=None, failure='', empty_keychains=False):
        if identities is None:
            identities = '  1) ' + 'A' * 40 + ' "Developer ID Application: Synthetic (TESTTEAM)"'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / 'tools'
            tools.mkdir()
            calls = root / 'calls'
            stub = '''#!/bin/bash
printf '%s %s\\n' "${0##*/}" "$*" >> "$SIGNING_CALLS"
case "${0##*/}" in
    uuidgen) echo synthetic-password ;;
    security)
        case "$1" in
            list-keychains)
                if [[ "$*" != *' -s '* && "$SIGNING_EMPTY_KEYCHAINS" != 1 ]]; then
                    printf '    "%s"\\n' '/test/Original Keychain.keychain-db' '/test/login.keychain-db'
                fi ;;
            find-identity) printf '%s\\n' "$SIGNING_IDENTITIES" ;;
            import) [[ "$SIGNING_FAILURE" != import ]] || exit 1 ;;
        esac
        ;;
    codesign)
        [[ "$SIGNING_FAILURE" != codesign ]] || exit 1 ;;
    xcrun) echo '{"status":"Accepted"}' ;;
    jq) echo Accepted ;;
esac
'''
            for name in ('uuidgen', 'security', 'codesign', 'ditto', 'xcrun', 'jq', 'spctl'):
                (tools / name).write_text(stub)
                (tools / name).chmod(0o755)
            env = {**self.environment(), 'PATH': str(tools) + ':' + os.environ['PATH'],
                   'SIGNING_CALLS': str(calls), 'MACOS_SIGNING_IDENTITY': identity,
                   'SIGNING_IDENTITIES': identities, 'SIGNING_FAILURE': failure,
                   'SIGNING_EMPTY_KEYCHAINS': str(int(empty_keychains))}
            result = subprocess.run(
                ['bash', str(ROOT / 'scripts/macos-sign-notarize.sh'), str(root / 'bundle')],
                env=env, capture_output=True, text=True, timeout=10)
            return result, calls.read_text().splitlines()

    def assert_keychains_restored(self, recorded):
        changes = [c for c in recorded if c.startswith('security list-keychains -d user -s')]
        self.assertEqual(len(changes), 2)
        self.assertRegex(changes[0], r'signing.keychain-db /test/Original Keychain.keychain-db /test/login.keychain-db$')
        self.assertEqual(changes[-1], 'security list-keychains -d user -s '
                         '/test/Original Keychain.keychain-db /test/login.keychain-db')
        self.assertTrue(recorded[-1].startswith('security delete-keychain '))

    def test_signing_and_gatekeeper_cover_every_archive_binary(self):
        result, recorded = self.run_signing()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_keychains_restored(recorded)
        self.assertTrue(any(c.startswith('security import ') and ' -f pkcs12 ' in c
                            for c in recorded))
        for binary in ('iso', 'iso-proxy', 'iso-egress', 'iso-sandbox', 'iso-macos-helper'):
            target = next(c.split()[-1] for c in recorded
                          if c.startswith('codesign --force ') and c.endswith('/' + binary))
            self.assertEqual(sum(c.startswith('codesign --force ') and c.endswith(target)
                                 for c in recorded), 1)
            self.assertIn(f'codesign --verify --strict --verbose=2 {target}', recorded)
            self.assertIn('spctl --assess --type open --context '
                          f'context:primary-signature --verbose=2 {target}', recorded)
        runtime_sign = next(c for c in recorded if c.startswith('codesign --force ')
                            and c.endswith('/iso-sandbox'))
        self.assertIn('--entitlements ' + str(ROOT / 'iso-sandbox/iso-sandbox.entitlements'),
                      runtime_sign)

    def test_signing_uses_the_resolved_certificate_hash(self):
        for identity in ('Developer ID Application: Synthetic (TESTTEAM)', 'A' * 40):
            with self.subTest(identity=identity):
                result, recorded = self.run_signing(identity=identity)
                self.assertEqual(result.returncode, 0, result.stderr)
                signing = [c for c in recorded if c.startswith('codesign --force ')]
                self.assertEqual(len(signing), 5)
                self.assertTrue(all('--sign ' + 'A' * 40 + ' ' in c for c in signing))

    def test_invalid_or_mismatched_identity_stops_before_signing(self):
        valid = '  1) ' + 'A' * 40 + ' "Developer ID Application: Synthetic (TESTTEAM)"'
        for identities in ('  0 valid identities found', valid.replace('Application:', 'Installer:'),
                           valid + ' (CSSMERR_TP_CERT_EXPIRED)', valid + '\n' + valid):
            with self.subTest(identities=identities):
                result, recorded = self.run_signing(identities=identities)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('MACOS_SIGNING_IDENTITY', result.stderr)
                self.assertNotIn('Synthetic', result.stdout + result.stderr)
                self.assertFalse(any(c.startswith(('codesign ', 'xcrun ')) for c in recorded))
                self.assert_keychains_restored(recorded)
        result, recorded = self.run_signing(identity='incorrect-secret-value')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('incorrect-secret-value', result.stdout + result.stderr)
        self.assert_keychains_restored(recorded)

    def test_empty_keychain_search_list_is_supported(self):
        result, recorded = self.run_signing(empty_keychains=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        changes = [c for c in recorded if c.startswith('security list-keychains -d user -s')]
        self.assertEqual(len(changes), 2)
        self.assertTrue(changes[0].endswith('/signing.keychain-db'))
        self.assertEqual(changes[1], 'security list-keychains -d user -s')

    def test_keychain_search_list_is_restored_when_signing_fails(self):
        result, recorded = self.run_signing(failure='codesign')
        self.assertNotEqual(result.returncode, 0)
        self.assert_keychains_restored(recorded)
        self.assertFalse(any(c.startswith('xcrun ') for c in recorded))

    def test_import_failure_reports_repair_and_restores_keychains(self):
        result, recorded = self.run_signing(failure='import')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('macOS cannot import MACOS_CERTIFICATE_P12', result.stderr)
        self.assertIn('Keychain Access', result.stderr)
        self.assertNotIn(self.certificate, result.stdout + result.stderr)
        self.assertNotIn('synthetic-value', result.stdout + result.stderr)
        self.assert_keychains_restored(recorded)
        self.assertFalse(any(c.startswith(('codesign ', 'xcrun ')) for c in recorded))


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
            git('config', 'commit.gpgsign', 'false')
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
