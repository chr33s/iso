#!/usr/bin/env python3
"""The release verifier refuses private entitlements and the Core AI build."""

import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release", ROOT / "scripts/build-release.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class PrivateEntitlementTests(unittest.TestCase):
    def required(self):
        return plistlib.loads((ROOT / RELEASE.ENTITLEMENTS).read_bytes())

    @unittest.skipUnless(sys.platform == "darwin", "codesign is macOS only")
    def test_signed_fixture_with_private_entitlement_is_refused(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            fixture = directory / "iso-sandbox"
            shutil.copyfile("/usr/bin/true", fixture)
            fixture.chmod(0o755)
            subprocess.run(
                ["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
                 ROOT / "iso-sandbox/iso-sandbox-coreai.entitlements", fixture],
                check=True, capture_output=True)
            granted = RELEASE.signed_entitlements(fixture, directory)
            self.assertIs(granted.get("com.apple.private.virtualization"), True)
            with self.assertRaisesRegex(SystemExit, "private entitlement.*com.apple.private.virtualization"):
                RELEASE.check_entitlements("iso-sandbox", granted, {})

    def test_required_entitlements_without_private_ones_pass(self):
        required = self.required()
        RELEASE.check_entitlements("iso", dict(required), required)

    def test_private_entitlement_alongside_required_ones_is_refused(self):
        required = self.required()
        granted = dict(required, **{"com.apple.private.anything": True})
        with self.assertRaisesRegex(SystemExit, "com.apple.private.anything"):
            RELEASE.check_entitlements("iso", granted, required)

    def test_bundle_with_coreai_binary_is_refused_before_signatures(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            (directory / "iso-sandbox-coreai").write_bytes(b"")
            with self.assertRaisesRegex(SystemExit, "iso-sandbox-coreai must never be in a release"):
                RELEASE.verify(directory, "iso 0.0.0", ROOT)

    def test_coreai_entitlements_extend_the_default_set_by_one_key(self):
        default = plistlib.loads((ROOT / "iso-sandbox/iso-sandbox.entitlements").read_bytes())
        coreai = plistlib.loads((ROOT / "iso-sandbox/iso-sandbox-coreai.entitlements").read_bytes())
        self.assertEqual(coreai, dict(default, **{"com.apple.private.virtualization": True}))


if __name__ == "__main__":
    unittest.main()
