#!/usr/bin/env python3
"""Check VM harness cleanup and agent fixtures without booting a VM."""
import os
import contextlib
import io
import json
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import unittest

from filtered_network_boundary import host_service_gateway, measure_host_service

ROOT = Path(__file__).resolve().parent.parent
SUITE = (ROOT / 'tests/integration-apple-sandbox.sh').read_text()
CLEANUP = SUITE.split('cleanup() {', 1)[1].split('\ntrap cleanup EXIT', 1)[0]


class HarnessTests(unittest.TestCase):
    def test_filtered_live_gate_requires_explicit_live_models(self):
        runner = ROOT / 'tests/integration-proxy-transition.py'
        for arguments, error in [
            (['--filtered'], '--filtered requires --live-agents'),
            (['--filtered', '--live-agents'], 'needs at least one'),
            (['--filtered', '--live-agents', '--claude-model', 'approved', '--controlled-upstream'],
             'runs on its own'),
        ]:
            with self.subTest(arguments=arguments):
                result = subprocess.run(['python3', str(runner), *arguments],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(error, result.stderr)
                self.assertNotIn('Artifacts:', result.stdout)

    def test_container_selection_honors_the_pinned_path(self):
        selection = 'CONTAINER=' + SUITE.split('CONTAINER=', 1)[1].split('for tool in', 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            executable = Path(temp) / 'container'
            executable.write_text('#!/bin/sh\nprintf "pinned-container\\n"\n')
            executable.chmod(0o755)
            result = subprocess.run(['/bin/bash', '-c', selection], env={'PATH': temp},
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'pinned-container\n')

    def test_host_service_gateway_comes_from_the_owned_runtime_record(self):
        record = {'subnetIndex': 42, 'network': 'host_only'}
        interface = {'addr_info': [{'family': 'inet', 'local': '10.231.42.2', 'prefixlen': 24}]}
        self.assertEqual(host_service_gateway(record, interface), '10.231.42.1')
        interface['addr_info'][0]['local'] = '192.168.0.2'
        with self.assertRaisesRegex(AssertionError, 'disagrees'):
            host_service_gateway(record, interface)

    def test_host_service_measurement_has_controls_and_closes_on_failure(self):
        def guest(_instance, *command, **kwargs):
            return subprocess.run(command, input=kwargs['input'], capture_output=True,
                                  text=True, timeout=kwargs['timeout'], check=True).stdout

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            measure_host_service(guest, '127.0.0.1')
        self.assertIn('"reachable": true', output.getvalue())
        captured = []

        def failed_guest(_instance, *command, **kwargs):
            captured.append(json.loads(kwargs['input'])[:2])
            raise RuntimeError('guest probe failed')

        with self.assertRaisesRegex(RuntimeError, 'guest probe failed'):
            measure_host_service(failed_guest, '127.0.0.1')
        with self.assertRaises(OSError):
            with socket.create_connection(tuple(captured[0]), timeout=1):
                self.fail('listener survived failed guest probe')

    def test_strict_peer_probe_requires_successful_injection(self):
        source = (ROOT / 'tests/fixtures/apple-sandbox/peer-probe.sh').read_text()
        body = source.split('inject() {', 1)[1].split('\n}', 1)[0]
        function = 'inject() {' + body + '\n}\n'
        for strict, command, expected in (("1", "false", 1), ("1", "true", 0), ("0", "false", 0)):
            with self.subTest(strict=strict, command=command):
                result = subprocess.run(
                    ['/bin/bash', '-c', 'set -uo pipefail\n' + function + f'inject {command} fixture\necho reached'],
                    env={**os.environ, 'ISO_REQUIRE_INJECTION': strict},
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual('reached' in result.stdout, expected == 0)

    def test_cleanup_preserves_failure_logs_but_not_resources(self):
        for code, keep in ((1, 0), (0, 0), (1, 1)):
            with self.subTest(code=code, keep=keep), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                work = root / 'work'
                image = work / 'iso-data/backends/apple-container-v1/images/default'
                image.mkdir(parents=True)
                (work / 'iso-setup.log').write_text('setup failed\n')
                (image / 'build.log').write_text('download failed\n')
                (work / 'disk.ext4').write_bytes(b'not a log')
                script = 'cleanup() {' + CLEANUP + '''
iso_cleanup() { printf 'cleaned\n' > "$TMPDIR/resources-cleaned"; }
# ROOT does not exist: no sandbox process should be spawned by this test.
WORK="$TMPDIR/work"
ROOT="$WORK/no-runtime"
SANDBOX=/usr/bin/true
CONTAINER=/usr/bin/true
KEEP="$1"
(exit "$2")
cleanup
'''
                result = subprocess.run(
                    ['/bin/bash', '-c', script, 'test', str(keep), str(code)],
                    env={**os.environ, 'TMPDIR': temp}, capture_output=True,
                    text=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(work.exists(), keep == 1)
                self.assertEqual((root / 'resources-cleaned').exists(), keep == 0)
                preserved = list(root.glob('iso-sandbox-failure.*'))
                self.assertEqual(len(preserved), int(code != 0 and keep == 0))
                if preserved:
                    logs = preserved[0]
                    self.assertIn(str(logs), result.stderr)
                    self.assertEqual(stat.S_IMODE(logs.stat().st_mode), 0o700)
                    self.assertEqual({p.name for p in logs.iterdir()},
                                     {'iso-setup.log', 'images-default-build.log'})
                    self.assertEqual((logs / 'images-default-build.log').read_text(),
                                     'download failed\n')
                    for path in logs.iterdir():
                        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_agent_stubs_cannot_masquerade_as_successful_agents(self):
        fixture = (ROOT / 'tests/fixtures/apple-sandbox/stub-agents.sh').read_text()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'usr/local/bin').mkdir(parents=True)
            # Rebase the fixture's fixed guest paths; never write host /usr/local.
            script = fixture.replace('/home/ubuntu', str(root / 'home/ubuntu'))
            script = script.replace('/usr/local/bin', str(root / 'usr/local/bin'))
            subprocess.run(['/bin/bash'], input=script, text=True, check=True, timeout=10)
            for agent in ('home/ubuntu/.local/bin/claude', 'usr/local/bin/codex'):
                result = subprocess.run([str(root / agent), '--version'],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 125)
                self.assertIn('agent execution is not supported', result.stderr)
                self.assertEqual(result.stdout, '')
        self.assertIn('iso setup -y --profile boundary-fixture', SUITE)
        self.assertIn('--rawfile stubs "$FIXTURES/stub-agents.sh"', SUITE)


if __name__ == '__main__':
    unittest.main()
