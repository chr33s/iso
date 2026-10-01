#!/usr/bin/env python3
"""Check VM harness cleanup and agent fixtures without booting a VM."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SUITE = (ROOT / 'tests/integration-apple-sandbox.sh').read_text()
CLEANUP = SUITE.split('cleanup() {', 1)[1].split('\ntrap cleanup EXIT', 1)[0]


class HarnessTests(unittest.TestCase):
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
