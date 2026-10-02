#!/usr/bin/env python3
"""Exercise release legal-file copying and the actual archive writer."""

import importlib.util
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release", ROOT / "scripts/build-release.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseLegalTests(unittest.TestCase):
    def stage(self, directory):
        staging = directory / "src"
        for name in ("LICENSE", "NOTICE", "PROVENANCE.md", "THIRD_PARTY_LICENSES.md",
                     "fuzz/libfuzzer/LICENSE.TXT"):
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())
        for package in (Path("."), Path("iso-proxy"), Path("iso-sandbox")):
            path = staging / package
            path.mkdir(parents=True, exist_ok=True)
            (path / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "example"}]}))
            checkout = path / ".build/checkouts/example"
            (checkout / "vendor").mkdir(parents=True)
            (checkout / "LICENSE.txt").write_text("Dependency license\n")
            (checkout / "vendor/NOTICE").write_text("Vendored attribution\n")
        return staging

    def test_archive_preserves_legal_bytes_and_nested_notices(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            staging = self.stage(directory)
            bundle = directory / "iso-test"
            bundle.mkdir()
            RELEASE.copy_legal_files(staging, bundle)
            archive = directory / "release.tar.gz"
            RELEASE.archive_bundle(bundle, archive)
            with tarfile.open(archive) as tar:
                for name in ("LICENSE", "NOTICE", "PROVENANCE.md", "THIRD_PARTY_LICENSES.md",
                             "fuzz/libfuzzer/LICENSE.TXT"):
                    self.assertEqual(tar.extractfile(f"iso-test/{name}").read(),
                                     (ROOT / name).read_bytes())
                for package in ("host", "iso-proxy", "iso-sandbox"):
                    self.assertEqual(tar.extractfile(
                        f"iso-test/third-party/{package}/example/LICENSE.txt").read(),
                        b"Dependency license\n")
                    self.assertEqual(json.loads(tar.extractfile(
                        f"iso-test/third-party/{package}/example/SOURCE.json").read()),
                        {"identity": "example"})
                    self.assertEqual(tar.extractfile(
                        f"iso-test/third-party/{package}/example/vendor/NOTICE").read(),
                        b"Vendored attribution\n")
                self.assertTrue(all(member.uid == 0 and member.gid == 0 for member in tar.getmembers()))

    def test_missing_project_notice_fails(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            staging = self.stage(directory)
            (staging / "NOTICE").unlink()
            with self.assertRaises(FileNotFoundError):
                RELEASE.copy_legal_files(staging, directory / "bundle")

    def test_missing_dependency_license_fails_even_with_nested_notice(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            staging = self.stage(directory)
            (staging / ".build/checkouts/example/LICENSE.txt").unlink()
            with self.assertRaisesRegex(SystemExit, "missing dependency license"):
                RELEASE.copy_legal_files(staging, directory / "bundle")


if __name__ == "__main__":
    unittest.main()
