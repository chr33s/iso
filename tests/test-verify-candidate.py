#!/usr/bin/env python3
"""Candidate verifier adversarial archive and verification-order regressions."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("candidate", ROOT / "scripts/verify-candidate.py")
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)
REVISION = "a" * 40
NAME = f"iso-{REVISION[:12]}-aarch64-apple-darwin"


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / NAME
        self.bundle.mkdir()
        for binary in candidate.BINARIES:
            path = self.bundle / binary
            path.write_bytes(b"fixture executable, never run\n")
            path.chmod(0o700)
        self.data = dict(format=1, name=NAME, source_revision=REVISION, source_dirty=False,
                         release_build=True, tested=True, developer_id_signed=True,
                         configuration="release", architecture="arm64", minimum_macos="27.0",
                         tag=None, version="0.7.0", binaries={
                             binary: candidate.digest(self.bundle / binary) for binary in candidate.BINARIES})
        self.write_manifest()

    def write_manifest(self):
        (self.bundle / "BUILD.json").write_text(json.dumps(self.data))

    def archive(self, extra=None):
        archive = self.root / (NAME + ".tar.gz")
        with tarfile.open(archive, "w:gz") as output:
            output.add(self.bundle, arcname=NAME)
            if extra is not None:
                output.addfile(extra, io.BytesIO(b"x" * extra.size) if extra.isfile() else None)
        (self.root / "SHA256SUMS").write_text(candidate.digest(archive) + "  " + archive.name + "\n")
        (self.root / "attestations.jsonl").write_text('{"fixture":true}\n')
        return archive

    def test_valid_bundle_and_all_binary_tampering(self):
        candidate.manifest(self.bundle, REVISION)
        for binary in candidate.BINARIES:
            with self.subTest(binary=binary):
                path = self.bundle / binary
                original = path.read_bytes()
                path.write_bytes(b"tampered")
                with self.assertRaisesRegex(ValueError, "binary checksum mismatch"):
                    candidate.manifest(self.bundle, REVISION)
                path.write_bytes(original)

    def test_manifest_identity_and_boolean_types(self):
        for field, bad in [("source_revision", "b" * 40), ("source_dirty", True),
                           ("tested", False), ("release_build", 1), ("developer_id_signed", False),
                           ("configuration", "debug"), ("architecture", "x86_64"),
                           ("tag", "v0.7.0"), ("format", True)]:
            with self.subTest(field=field):
                original = self.data[field]
                self.data[field] = bad
                self.write_manifest()
                with self.assertRaises(ValueError):
                    candidate.manifest(self.bundle, REVISION)
                self.data[field] = original
        self.write_manifest()

    def test_archive_rejects_traversal_links_and_duplicates(self):
        for name, kind in [(NAME + "/../escape", tarfile.REGTYPE),
                           ("/tmp/escape", tarfile.REGTYPE),
                           (NAME + "/link", tarfile.SYMTYPE),
                           (NAME + "/hard", tarfile.LNKTYPE),
                           (NAME + "/fifo", tarfile.FIFOTYPE),
                           (NAME + "/iso", tarfile.REGTYPE)]:
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "/tmp/outside"
                archive = self.archive(member)
                with tempfile.TemporaryDirectory(dir=self.root) as destination:
                    with self.assertRaises(ValueError):
                        candidate.unpack(archive, Path(destination), NAME)

    def test_checksum_rejects_modified_or_duplicate_entries(self):
        archive = self.archive()
        sums = self.root / "SHA256SUMS"
        original = sums.read_text()
        sums.write_text(original * 2)
        with self.assertRaises(ValueError):
            candidate.checksum(self.root, archive.name)
        sums.write_text(original)
        archive.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            candidate.checksum(self.root, archive.name)

    def test_attestation_pins_and_execution_order(self):
        self.archive()
        events = []
        with redirect_stdout(io.StringIO()), patch.object(candidate, "run", side_effect=lambda *args: events.append(args)), \
                patch.object(candidate, "signing", side_effect=lambda path: events.append(("signed", path))):
            candidate.verify(self.root, REVISION)
        attestation = events[0]
        self.assertIn("chr33s/iso/.github/workflows/candidate.yml", attestation)
        self.assertIn("refs/heads/main", attestation)
        self.assertEqual(attestation[attestation.index("--source-digest") + 1], REVISION)
        self.assertEqual([Path(event[1]).name for event in events[1:5]], list(candidate.BINARIES))
        self.assertEqual(events[5][1], "--version")
        self.assertEqual(events[6][1], "version")

    def test_failed_attestation_or_signing_prevents_execution(self):
        self.archive()
        with patch.object(candidate, "run", side_effect=subprocess.CalledProcessError(1, "gh")), \
                patch.object(candidate, "unpack") as unpack:
            with self.assertRaises(subprocess.CalledProcessError):
                candidate.verify(self.root, REVISION)
            unpack.assert_not_called()
        with patch.object(candidate, "run") as run, \
                patch.object(candidate, "signing", side_effect=ValueError("unsigned")):
            with self.assertRaises(ValueError):
                candidate.verify(self.root, REVISION)
            self.assertEqual(run.call_count, 1)  # Attestation only; no binary launch.

    def test_unsigned_and_unnotarized_assessments_rejected(self):
        for identity, assessment in [("Signature=adhoc", "source=Notarized Developer ID"),
                                     ("Authority=Developer ID Application: Fixture", "source=Developer ID")]:
            with self.subTest(identity=identity, assessment=assessment), patch.object(candidate, "run"), \
                    patch.object(candidate.subprocess, "run", side_effect=[
                        subprocess.CompletedProcess([], 0, "", identity),
                        subprocess.CompletedProcess([], 0, "", assessment)]):
                with self.assertRaises(ValueError):
                    candidate.signing("fixture")

    def test_notarized_developer_id_control(self):
        with patch.object(candidate, "run") as verify, patch.object(candidate.subprocess, "run", side_effect=[
                subprocess.CompletedProcess([], 0, "", "Authority=Developer ID Application: Fixture"),
                subprocess.CompletedProcess([], 0, "", "source=Notarized Developer ID")]):
            candidate.signing("fixture")
        verify.assert_called_once_with("/usr/bin/codesign", "--verify", "--strict", "fixture")


if __name__ == "__main__":
    unittest.main()
