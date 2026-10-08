#!/usr/bin/env python3
"""check-release-signatures.py accepts only releases signed by a listed key."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "signatures", ROOT / "scripts/check-release-signatures.py")
signatures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signatures)


class ReleaseSignatureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.published = self.root / "published"
        self.published.mkdir()
        self.work = self.root / "work"
        self.work.mkdir()
        self.trusted = self.keypair("trusted")
        self.signers = self.root / "allowed_signers"
        public = (self.root / "trusted.pub").read_text().split()[:2]
        self.signers.write_text(
            f'release namespaces="{signatures.NAMESPACE}" {" ".join(public)}\n')
        (self.published / "SHA256SUMS").write_text(
            "0" * 64 + "  iso-v9.9.9-aarch64-apple-darwin.tar.gz\n")

    def keypair(self, name):
        key = self.root / name
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name,
                        "-f", str(key)], check=True)
        return key

    def sign(self, key, namespace=signatures.NAMESPACE):
        with (self.published / "SHA256SUMS").open("rb") as message, \
                (self.published / "SHA256SUMS.sig").open("wb") as signature:
            subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", str(key),
                            "-n", namespace], stdin=message, stdout=signature, check=True)

    def fake_download(self, tag, name, directory):
        source = self.published / name
        if not source.is_file():
            return False
        shutil.copy(source, directory / name)
        return True

    def check(self):
        with patch.object(signatures, "download", self.fake_download):
            return signatures.check_release("v9.9.9", self.work, self.signers)

    def test_trusted_signature_passes(self):
        self.sign(self.trusted)
        self.assertIsNone(self.check())

    def test_missing_signature_fails(self):
        self.assertEqual(self.check(), "could not download SHA256SUMS.sig")

    def test_untrusted_signer_fails(self):
        self.sign(self.keypair("untrusted"))
        self.assertRegex(self.check(), "not a valid signature")

    def test_wrong_namespace_fails(self):
        self.sign(self.trusted, namespace="file")
        self.assertRegex(self.check(), "not a valid signature")

    def test_changed_sums_fail(self):
        self.sign(self.trusted)
        (self.published / "SHA256SUMS").write_text("tampered\n")
        self.assertRegex(self.check(), "not a valid signature")

    def test_shipped_signers_file_lists_a_key(self):
        lines = [line for line in signatures.SIGNERS.read_text().splitlines()
                 if line.strip() and not line.startswith("#")]
        self.assertTrue(lines)


if __name__ == "__main__":
    unittest.main()
