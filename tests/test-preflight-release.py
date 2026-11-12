#!/usr/bin/env python3
# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

"""Exercise release preflight dispatch and version gates without building VMs."""
import importlib.util
import base64
import contextlib
import fnmatch
import hashlib
import io
import json
import os
import plistlib
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
RELEASE_SPEC = importlib.util.spec_from_file_location('release', ROOT / 'scripts/build-release.py')
RELEASE = importlib.util.module_from_spec(RELEASE_SPEC)
RELEASE_SPEC.loader.exec_module(RELEASE)

# Stand-in for every Python gate: records its path and arguments.
PYTHON_STUB = '''import os, sys
call = " ".join([os.path.basename(sys.argv[0]), *sys.argv[1:]])
with open(os.environ["PREFLIGHT_CALLS"], "a") as f:
    f.write(call + "\\n")
fail = os.environ.get("PREFLIGHT_FAIL")
sys.exit(1 if fail in (os.path.basename(sys.argv[0]), call) else 0)
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
    'tests/test-audit-contract.py', 'tests/test-cli-surface.py',
    'tests/test-preflight-release.py', 'tests/test-verify-candidate.py', 'tests/test-accept-release.py',
    'tests/test-check-release-signatures.py',
    'scripts/hygiene.py', 'tests/test-release-legal.py',
    'tests/test-apple-integration-harness.py', 'tests/test-proxy-vm-fixture.py',
    'tests/test-proxy-live.py', 'tests/test-proxy-agent-smoke.py', 'tests/test-codex-account.py',
    'scripts/build-release.py',
    'scripts/test-swift-egress-jail.py', 'scripts/test-swift-egress-lease.py',
    'scripts/test-swift-egress-pressure.py',
    'tests/integration-filtered-broker-readiness.py',
    'scripts/test-swift-egress-mutations.py',
    'scripts/test-proxy-contract.py', 'scripts/test-swift-proxy-mutations.py',
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
        for name in ('swift', 'zizmor', 'mise', 'jactionlint', 'cargo', 'rustup'):
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
        for call in ('hygiene.py --all', 'mise run lint', 'mise run check-policy',
                     'jactionlint ', 'test-release-legal.py',
                     'test-apple-integration-harness.py', 'test-proxy-vm-fixture.py',
                     'test-proxy-live.py', 'test-proxy-agent-smoke.py', 'test-codex-account.py',
                     'swift build --force-resolved-versions',
                     'swift test --force-resolved-versions',
                     'swift test --package-path iso-sandbox --force-resolved-versions --no-parallel',
                     'test-read-contract.py --swift .build/debug/iso',
                     'test-lifecycle-contract.py --swift .build/debug/iso',
                     'test-data-root-contract.py --swift .build/debug/iso',
                     'test-machine-contract.py --swift .build/debug/iso',
                     'test-audit-contract.py --swift .build/debug/iso',
                     'test-cli-surface.py --swift .build/debug/iso',
                     'test-preflight-release.py',
                     'test-verify-candidate.py', 'test-accept-release.py',
                     'test-check-release-signatures.py',
                     'zizmor .github/workflows/', 'integration-install.sh ',
                     'integration-update.sh ', 'integration-uninstall.sh '):
            self.assertIn(call, calls)
        # --quick skips the archive build, the VM suite and fuzzing.
        self.assertFalse([c for c in calls if c.startswith(('build-release.py', 'run-integration.sh', 'fuzz.sh'))])
        self.assertFalse([c for c in calls if c.startswith('integration-filtered-broker-readiness.py')])
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
        self.assertIn(f'test-proxy-contract.py --swift {self.root}/.build/proxy-test/iso-proxy', calls)
        self.assertIn('test-swift-proxy-mutations.py', calls)
        self.assertIn('swift test --package-path iso-egress --force-resolved-versions', calls)
        self.assertIn('swift build --package-path iso-egress --force-resolved-versions', calls)
        self.assertIn('mise run check-ci', calls)
        self.assertIn('test-swift-egress-jail.py', calls)
        self.assertIn('test-swift-egress-lease.py', calls)
        self.assertIn('test-swift-egress-mutations.py', calls)
        filtered = [c for c in calls if c.startswith('integration-filtered-broker-readiness.py')]
        self.assertEqual(filtered, ['integration-filtered-broker-readiness.py --transport vmnet',
                                    'integration-filtered-broker-readiness.py --transport brokered'])
        self.assertIn('All required checks passed for v9.8.7.', result.stdout)

    def test_proxy_build_and_e2e_failures_are_fatal(self):
        self.executable('bin/sw_vers', '#!/bin/bash\necho 27.0\n')
        for gate in ('swift build --package-path iso-proxy --force-resolved-versions',
                     'swift build --package-path iso-proxy --show-bin-path',
                     'swift test --package-path iso-proxy --force-resolved-versions',
                     'test-proxy-contract.py', 'test-swift-proxy-mutations.py'):
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
        # A failure of either transport fails the step; neither masks the other.
        for transport in ('vmnet', 'brokered'):
            with self.subTest(transport=transport):
                self.log.unlink(missing_ok=True)
                result = self.run_preflight(
                    fail=f'integration-filtered-broker-readiness.py --transport {transport}')
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
        for gate in ('test-lifecycle-contract.py', 'test-machine-contract.py',
                     'test-audit-contract.py'):
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
    def test_signing_checkout_includes_every_file_the_signer_reads(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        block = re.search(
            r"  sign-macos:\n.*?          sparse-checkout: \|\n(.*?)\n          sparse-checkout-cone-mode",
            workflow, re.S)[1]
        checkout = {line.strip() for line in block.splitlines()}
        signer = (ROOT / 'scripts/macos-sign-notarize.sh').read_text()
        read = set(re.findall(r'\$\{root\}/([\w./-]+)', signer))
        self.assertIn('scripts/enhanced-security.entitlements', read)
        self.assertLessEqual(read | {'scripts/macos-sign-notarize.sh'}, checkout)

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
        members = ('iso-proxy', 'iso-sandbox', 'iso-macos-helper', 'skill',
                   'iso-cu-mcp', 'vmlinux-desktop', 'kernel-source')
        cases = [('iso 9.8.7 (abc1234)', None, 0),
                 ('iso 9.8.7-dev (abc1234+dirty)', None, 1),
                 ('iso 9.8.6 (abc1234)', None, 1),
                 ('iso 9.8.7 (abc1235)', None, 1)]
        # Each member alone: one check must not stand in for another's.
        cases += [('iso 9.8.7 (abc1234)', member, 1) for member in members]
        for version, missing, expected in cases:
            with self.subTest(version=version, missing=missing), \
                    tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bundle = root / 'bundle' / name
                bundle.mkdir(parents=True)
                binaries = {'iso': f"#!/bin/sh\nprintf '%s\\n' '{version}'\n",
                            'iso-proxy': '#!/bin/sh\nexit 0\n',
                            'iso-sandbox': '#!/bin/sh\nexit 0\n',
                            'iso-macos-helper': '#!/bin/sh\nexit 0\n',
                            'iso-cu-mcp': 'elf\n'}
                for binary, text in binaries.items():
                    if binary != missing:
                        (bundle / binary).write_text(text)
                        (bundle / binary).chmod(0o755)
                if missing != 'skill':
                    (bundle / 'skills' / 'iso').mkdir(parents=True)
                    (bundle / 'skills' / 'iso' / 'SKILL.md').write_text('---\nname: iso\n---\n')
                if missing != 'vmlinux-desktop':
                    (bundle / 'vmlinux-desktop').write_text('kernel\n')
                (root / 'dist').mkdir()
                with tarfile.open(root / 'dist' / f'{name}.tar.gz', 'w:gz') as tar:
                    tar.add(bundle, arcname=name)
                if missing != 'kernel-source':
                    (root / 'dist' / 'iso-v9.8.7-vmlinux-desktop-source.tar.gz').write_bytes(b'src')
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

    def test_kernel_source_is_uploaded_where_the_publish_job_collects(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        upload = re.search(
            r"      - name: Upload the desktop kernel's source\n.*?"
            r"          name: (\S+)\n          path: \$\{\{ runner\.temp \}\}/dist/(\S+)\n",
            workflow, re.S)
        artifact, path = upload[1], upload[2]
        publish = workflow[workflow.index('      - name: Download all artifacts'):]
        pattern = re.search(r"          pattern: (\S+)\n", publish)[1]
        checksummed = re.search(r"run: sha256sum (\S+) > SHA256SUMS", publish)[1]
        attested = re.search(r'subject-path: "(\S+)"', publish)[1]
        asset = RELEASE.source_asset_name(f'iso-v9.8.7-{RELEASE.TRIPLE}')
        self.assertEqual(asset, 'iso-v9.8.7-vmlinux-desktop-source.tar.gz')
        # Published only if the artifact matches the publish job's pattern,
        # and checksummed and attested only if the file matches its globs.
        self.assertTrue(fnmatch.fnmatchcase(artifact, pattern), (artifact, pattern))
        for glob in (path, checksummed, attested):
            self.assertTrue(fnmatch.fnmatchcase(asset, glob), (asset, glob))

    def test_release_and_candidate_take_the_kernel_from_the_linux_job(self):
        kernel = (ROOT / '.github/workflows/desktop-kernel.yml').read_text()
        self.assertIn('runs-on: ubuntu-24.04-arm\n', kernel)
        uploaded = re.search(r"          name: (\S+)\n          path: \$\{\{ runner\.temp \}\}/(\S+)\n",
                             kernel)
        # The job itself fails on a kernel that is not pinned.
        self.assertIn(f'--engine docker --pinned "$RUNNER_TEMP/{uploaded[2]}"\n', kernel)
        for name, job in (('release.yml', 'build'), ('candidate.yml', 'candidate')):
            with self.subTest(workflow=name):
                workflow = (ROOT / '.github/workflows' / name).read_text()
                self.assertRegex(workflow, r"\n  kernel:\n(?:    .*\n)*?"
                                 r"    uses: \$/\.github/workflows/desktop-kernel\.yml\n")
                needs = re.search(rf"\n  {job}:\n    needs: \[(.*?)\]\n", workflow)[1]
                self.assertIn('kernel', needs.split(', '))
                steps = workflow[workflow.index(f"\n  {job}:\n"):]
                download = re.search(
                    r"download-artifact@\S+ # \S+\n        with:\n          name: (\S+)\n"
                    r"          path: \$\{\{ runner\.temp \}\}/(\S+)\n", steps)
                self.assertEqual(download[1], uploaded[1])
                self.assertIn(f'--desktop-kernel "$RUNNER_TEMP/{download[2]}"', steps)
                # A hosted macOS runner cannot start the `container` build VM.
                self.assertNotIn('container system start', workflow)
        # The kernel is published only inside the archive.
        publish = (ROOT / '.github/workflows/release.yml').read_text()
        publish = publish[publish.index('      - name: Download all artifacts'):]
        pattern = re.search(r"          pattern: (\S+)\n", publish)[1]
        self.assertFalse(fnmatch.fnmatchcase(uploaded[1], pattern))

    def test_the_kernel_script_checks_its_pins_and_engine(self):
        script = ROOT / 'scripts/build-desktop-kernel.sh'
        with tempfile.TemporaryDirectory() as directory:
            for arguments, message in ((['--engine', 'podman', directory], '--engine must be container or docker'),
                                       ([], 'OUT_DIR is required')):
                result = subprocess.run(['bash', script, *arguments], capture_output=True, text=True,
                                        timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
        # `--pinned` reads the same block build-release.py reads.
        layout = (ROOT / 'iso-sandbox/Sources/IsoSandboxCore/Layout.swift').read_text()
        listed = subprocess.run(['sed', '-n', r'/package static let desktopAllowed/,/\]/p'],
                                input=layout, capture_output=True, text=True, check=True).stdout
        for pin in RELEASE.desktop_kernel_pins(ROOT):
            self.assertIn(f'"{pin}"', listed)
        self.assertNotIn('static let allowed', listed)


def arm64_elf():
    """The smallest header build-release.py accepts as iso-cu-mcp."""
    header = bytearray(64)
    header[:6] = b'\x7fELF\x02\x01'
    header[18:20] = b'\xb7\x00'
    return bytes(header)


class LinuxGuestFileTests(unittest.TestCase):
    KERNEL = b'synthetic desktop kernel\n'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def source(self, pinned=True):
        """A source tree with the files the bundle checks read."""
        source = self.root / 'src'
        layout = source / 'iso-sandbox/Sources/IsoSandboxCore/Layout.swift'
        layout.parent.mkdir(parents=True)
        pin = hashlib.sha256(self.KERNEL).hexdigest() if pinned else 'a' * 64
        layout.write_text('enum KernelPin {\n  package static let desktopAllowed: Set<String> = [\n'
                          f'    "{pin}"\n  ]\n}}\n')
        entitlements = source / RELEASE.ENTITLEMENTS
        entitlements.parent.mkdir(parents=True)
        entitlements.write_bytes((ROOT / RELEASE.ENTITLEMENTS).read_bytes())
        return source

    def bundle(self, mcp=None, kernel=None):
        bundle = self.root / 'bundle'
        bundle.mkdir()
        for name in RELEASE.BINARIES:
            (bundle / name).write_text('#!/bin/sh\n')
            (bundle / name).chmod(0o755)
        (bundle / 'iso-cu-mcp').write_bytes(arm64_elf() if mcp is None else mcp)
        (bundle / 'vmlinux-desktop').write_bytes(self.KERNEL if kernel is None else kernel)
        return bundle

    def test_the_checked_in_runtime_pins_a_desktop_kernel(self):
        pins = RELEASE.desktop_kernel_pins(ROOT)
        self.assertTrue(pins)
        for pin in pins:
            self.assertRegex(pin, r'^[0-9a-f]{64}$')

    def test_guest_file_content_checks(self):
        source = self.source()
        RELEASE.verify_linux_guest_files(self.bundle(), source)
        macho = b'\xcf\xfa\xed\xfe' + bytes(60)
        x86_64 = bytearray(arm64_elf())
        x86_64[18:20] = b'\x3e\x00'
        for mcp in (macho, bytes(x86_64), b''):
            with self.subTest(mcp=mcp[:20]):
                shutil.rmtree(self.root / 'bundle')
                with self.assertRaisesRegex(SystemExit, 'iso-cu-mcp is not an arm64 Linux'):
                    RELEASE.verify_linux_guest_files(self.bundle(mcp=mcp), source)
        shutil.rmtree(self.root / 'bundle')
        with self.assertRaisesRegex(SystemExit, 'vmlinux-desktop .* is not a pinned desktop kernel'):
            RELEASE.verify_linux_guest_files(self.bundle(kernel=b'another kernel\n'), source)

    def verify(self, bundle, source):
        """`verify` with the signing tools stubbed out; guest-file checks are real."""
        required = plistlib.loads((ROOT / RELEASE.ENTITLEMENTS).read_bytes())

        def run(argv, cwd, signing=False, capture=False):
            return 'iso 9.8.7 (abc1234)\n' if str(argv[-1]) == '--version' else ''

        with mock.patch.object(RELEASE, 'run', side_effect=run), \
                mock.patch.object(RELEASE, 'signed_entitlements', return_value=required):
            RELEASE.verify(bundle, 'iso 9.8.7 (abc1234)', source)

    def test_bundle_verification_checks_the_guest_files(self):
        self.verify(self.bundle(), self.source())
        shutil.rmtree(self.root / 'bundle')
        with self.assertRaisesRegex(SystemExit, 'iso-cu-mcp is not an arm64 Linux'):
            self.verify(self.bundle(mcp=b'#!/bin/sh\n'), self.root / 'src')
        shutil.rmtree(self.root / 'bundle')
        shutil.rmtree(self.root / 'src')
        with self.assertRaisesRegex(SystemExit, 'is not a pinned desktop kernel'):
            self.verify(self.bundle(), self.source(pinned=False))

    def test_the_runtime_build_requires_the_mcp_server_and_the_kernel(self):
        staging, prefix = self.root / 'src', self.root / 'runtime'
        commands = []

        def run(argv, cwd, signing=False, capture=False):
            commands.append([str(a) for a in argv])
            return str(self.root / 'bin') + '\n' if capture else None

        with mock.patch.object(RELEASE, 'run', side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()):
            built = RELEASE.build(staging, 'release', True, prefix)
        # Without the flag a host that lacks the Static Linux SDK skips iso-cu-mcp.
        self.assertIn([str(staging / 'scripts/build-iso-sandbox.sh'), '--require-cu-mcp',
                       str(prefix)], commands)
        self.assertIn([str(staging / 'scripts/build-desktop-kernel.sh'), str(prefix / 'kernel')],
                      commands)
        self.assertEqual(built['iso-cu-mcp'], prefix / 'bin/iso-cu-mcp')
        self.assertEqual(built['vmlinux-desktop'], prefix / 'kernel/vmlinux-desktop')
        self.assertEqual(set(built), set(RELEASE.BINARIES + RELEASE.LINUX_GUEST_FILES))
        flag = (ROOT / 'scripts/build-iso-sandbox.sh').read_text()
        self.assertIn('--require-cu-mcp)', flag)

    def prebuilt_kernel(self, source, kernel=None, tarball=b'linux source\n', omit=None):
        """A build-desktop-kernel.sh output directory, and the tree that pins it."""
        script = source / 'scripts/build-desktop-kernel.sh'
        script.parent.mkdir(parents=True, exist_ok=True)
        pinned_source = hashlib.sha256(b'linux source\n').hexdigest()
        script.write_text('KVER=9.9.9\n'
                          'SOURCE_URL="https://kernel.invalid/linux-${KVER}.tar.xz"\n'
                          f'SOURCE_SHA256={pinned_source}\n'
                          'BASE_CONFIG_SHA256=' + 'b' * 64 + '\n')
        directory = self.root / 'prebuilt'
        directory.mkdir()
        files = {'vmlinux-desktop': self.KERNEL if kernel is None else kernel,
                 'vmlinux-desktop.config': b'final\n', 'vmlinux-desktop.input.config': b'input\n',
                 'linux-9.9.9.tar.xz': tarball}
        for name, content in files.items():
            if name != omit:
                (directory / name).write_bytes(content)
        return directory

    def test_a_prebuilt_kernel_replaces_the_kernel_build(self):
        staging, prefix = self.source(), self.root / 'runtime'
        directory = self.prebuilt_kernel(staging)
        commands = []

        def run(argv, cwd, signing=False, capture=False):
            commands.append([str(a) for a in argv])
            return str(self.root / 'bin') + '\n' if capture else None

        with mock.patch.object(RELEASE, 'run', side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()):
            built = RELEASE.build(staging, 'release', True, prefix, directory)
        self.assertFalse([c for c in commands if 'build-desktop-kernel.sh' in c[0]])
        self.assertEqual(built['vmlinux-desktop'].read_bytes(), self.KERNEL)
        # Everything the bundle's legal notices and the source asset read.
        self.assertEqual(sorted(p.name for p in (prefix / 'kernel').iterdir()),
                         ['linux-9.9.9.tar.xz', 'vmlinux-desktop', 'vmlinux-desktop.config',
                          'vmlinux-desktop.input.config'])

    def test_a_prebuilt_kernel_must_be_the_pinned_kernel_and_source(self):
        cases = [(dict(kernel=b'another kernel\n'), 'is not a pinned desktop kernel'),
                 (dict(tarball=b'another source\n'), 'linux-9.9.9.tar.xz is not the pinned Linux source'),
                 (dict(omit='vmlinux-desktop.config'), '--desktop-kernel has no vmlinux-desktop.config'),
                 (dict(omit='linux-9.9.9.tar.xz'), '--desktop-kernel has no linux-9.9.9.tar.xz')]
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                shutil.rmtree(self.root / 'src', ignore_errors=True)
                shutil.rmtree(self.root / 'prebuilt', ignore_errors=True)
                staging = self.source()
                directory = self.prebuilt_kernel(staging, **arguments)
                with mock.patch.object(RELEASE, 'run') as run, \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaisesRegex(SystemExit, message):
                    RELEASE.build(staging, 'release', True, self.root / 'runtime', directory)
                # Refused before anything is built.
                run.assert_not_called()
                self.assertFalse((self.root / 'runtime/kernel').exists())

    def test_a_prebuilt_kernel_must_not_be_a_link(self):
        staging = self.source()
        directory = self.prebuilt_kernel(staging, omit='vmlinux-desktop')
        (self.root / 'elsewhere').write_bytes(self.KERNEL)
        (directory / 'vmlinux-desktop').symlink_to(self.root / 'elsewhere')
        with self.assertRaisesRegex(SystemExit, '--desktop-kernel has no vmlinux-desktop'):
            RELEASE.copy_desktop_kernel(directory, staging, self.root / 'runtime/kernel')

    def test_manifest_and_checksums_cover_the_guest_files_and_the_kernel_source(self):
        out = self.root / 'out'
        fixture = self.root / 'fixture'
        fixture.mkdir()
        contents = {name: f'{name}\n'.encode() for name in RELEASE.BINARIES}
        contents.update({'iso-cu-mcp': arm64_elf(), 'vmlinux-desktop': self.KERNEL})
        for name, data in contents.items():
            (fixture / name).write_bytes(data)
        verified = []

        def stage_source(staging, stamp):
            for relative in ('scripts/build-desktop-kernel.sh', 'iso-sandbox/kernel/desktop.config',
                             'iso-sandbox/kernel/build.sh', 'iso-sandbox/kernel/Dockerfile'):
                (staging / relative).parent.mkdir(parents=True, exist_ok=True)
                (staging / relative).write_bytes((ROOT / relative).read_bytes())

        def build(staging, configuration, release, prefix, desktop_kernel=None):
            (prefix / 'bin').mkdir(parents=True)
            (prefix / 'kernel').mkdir()
            (prefix / 'bin/iso-cu-mcp.sbom.spdx.json').write_text('{}\n')
            version = RELEASE.desktop_kernel_source_pins(staging)['KVER']
            for name in (f'linux-{version}.tar.xz', 'vmlinux-desktop.input.config',
                         'vmlinux-desktop.config'):
                (prefix / 'kernel' / name).write_text(name + '\n')
            return {name: fixture / name for name in contents}

        with mock.patch.object(RELEASE.platform, 'system', return_value='Darwin'), \
                mock.patch.object(RELEASE.platform, 'machine', return_value='arm64'), \
                mock.patch.object(RELEASE.platform, 'mac_ver', return_value=('27.0', '', '')), \
                mock.patch.object(RELEASE, 'source_state', return_value=('a' * 40, False)), \
                mock.patch.object(RELEASE, 'stage_source', side_effect=stage_source), \
                mock.patch.object(RELEASE, 'build', side_effect=build), \
                mock.patch.object(RELEASE, 'copy_legal_files'), \
                mock.patch.object(RELEASE, 'copy_skill'), \
                mock.patch.object(RELEASE, 'adhoc_sign'), \
                mock.patch.object(RELEASE, 'verify',
                                  side_effect=lambda bundle, *_: verified.append(
                                      sorted(p.name for p in bundle.iterdir() if p.is_file()))), \
                mock.patch.object(sys, 'argv', ['build-release.py', '--release', '--out', str(out)]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(RELEASE.main(), 0)

        name = f"iso-{'a' * 12}-{RELEASE.TRIPLE}"
        archive = out / f'{name}.tar.gz'
        source_asset = out / f"iso-{'a' * 12}-vmlinux-desktop-source.tar.gz"
        # The bundle is verified with every member in place, before BUILD.json.
        self.assertEqual(verified, [sorted(contents)])
        with tarfile.open(archive) as tar:
            manifest = json.load(tar.extractfile(f'{name}/BUILD.json'))
            for member, data in contents.items():
                self.assertEqual(tar.extractfile(f'{name}/{member}').read(), data)
            pins = json.load(tar.extractfile(f'{name}/third-party/vmlinux-desktop/SOURCE.json'))
        digest = lambda data: hashlib.sha256(data).hexdigest()
        self.assertEqual(manifest['linux_guest_files'],
                         {member: digest(contents[member]) for member in RELEASE.LINUX_GUEST_FILES})
        self.assertEqual(manifest['binaries'],
                         {member: digest(contents[member]) for member in RELEASE.BINARIES})
        self.assertEqual(pins['source_asset'], source_asset.name)
        # Both published files are checksummed, so both are signed and verified.
        self.assertEqual((out / 'SHA256SUMS').read_text(),
                         f'{digest(archive.read_bytes())}  {archive.name}\n'
                         f'{digest(source_asset.read_bytes())}  {source_asset.name}\n')
        with tarfile.open(source_asset) as tar:
            names = tar.getnames()
        root = source_asset.name.removesuffix('.tar.gz')
        version = RELEASE.desktop_kernel_source_pins(ROOT)['KVER']
        for member in (f'linux-{version}.tar.xz', 'vmlinux-desktop.config',
                       'vmlinux-desktop.input.config', 'scripts/build-desktop-kernel.sh'):
            self.assertIn(f'{root}/{member}', names)


if __name__ == '__main__':
    unittest.main()
