#!/usr/bin/env python3
"""Release acceptance orchestration controls; no network or real installation."""
import importlib.util
import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("acceptance", ROOT / "scripts/accept-release.py")
acceptance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acceptance)


class AcceptanceTests(unittest.TestCase):
    def check_fixture(self, *, missing=None, nonexecutable=None, version="iso 0.7.0 (abc123)\n",
                      assessment="source=Notarized Developer ID", failure=None):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / "bin").mkdir()
            for name in acceptance.BINARIES:
                if name != missing:
                    path = work / "bin" / name
                    path.write_text("fixture only")
                    path.chmod(0o600 if name == nonexecutable else 0o700)
            calls = []

            def command(args, env):
                calls.append([str(arg) for arg in args])
                if str(args[0]) == failure:
                    raise subprocess.CalledProcessError(1, args)
                if args[0] == "/usr/sbin/spctl":
                    return assessment
                if args[1] == "--version":
                    return version
                return ""

            with patch.object(acceptance, "command", side_effect=command):
                acceptance.check_bundle(work, "v0.7.0", {})
            self.assertEqual(sum(call[0] == "/usr/bin/codesign" for call in calls), len(acceptance.BINARIES))
            self.assertEqual(sum(call[0] == "/usr/sbin/spctl" for call in calls), len(acceptance.BINARIES))
            self.assertEqual(calls[-2][1], "version")
            self.assertEqual(calls[-1][1], "--help")

    def test_installed_bundle_positive_control(self):
        self.check_fixture()

    def test_missing_or_nonexecutable_companions_fail(self):
        for binary in acceptance.BINARIES:
            with self.subTest(binary=binary), self.assertRaisesRegex(ValueError, "missing"):
                self.check_fixture(missing=binary)
            with self.subTest(binary=binary), self.assertRaisesRegex(ValueError, "missing"):
                self.check_fixture(nonexecutable=binary)

    def test_signature_or_assessment_failure_propagates(self):
        for tool in ("/usr/bin/codesign", "/usr/sbin/spctl"):
            with self.subTest(tool=tool), self.assertRaises(subprocess.CalledProcessError):
                self.check_fixture(failure=tool)

    def test_unnotarized_and_wrong_version_fail(self):
        with self.assertRaisesRegex(ValueError, "not notarized"):
            self.check_fixture(assessment="source=Developer ID")
        for value in ("iso 0.7.0-dev (abc)", "iso 0.8.0 (abc)", "unexpected"):
            with self.subTest(version=value), self.assertRaisesRegex(ValueError, "version differs"):
                self.check_fixture(version=value)

    def test_environment_isolates_home_and_strips_credentials_and_overrides(self):
        with patch.dict(os.environ, {"GH_TOKEN": "secret", "GITHUB_TOKEN": "secret",
                                    "ANTHROPIC_API_KEY": "secret", "OPENAI_API_KEY": "secret",
                                    "HTTPS_PROXY": "secret", "ISO_UPDATE_API_BASE_URL": "evil"}):
            env = acceptance.environment(Path("/private/test"), "v0.7.0")
        self.assertEqual(env["HOME"], "/private/test/home")
        self.assertEqual(env["INSTALL_DIR"], "/private/test/bin")
        self.assertEqual(env["GH_CONFIG_DIR"], "/private/test/gh")
        self.assertNotIn("secret", env.values())
        self.assertNotIn("ISO_UPDATE_API_BASE_URL", env)

    def exercise(self, *, omit=None, replace=True, uninstall=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls = []

            def command(args, env):
                calls.append([str(arg) for arg in args])
                self.assertEqual(env["HOME"], str(root / "home"))
                if args[0] == "/bin/bash":
                    for name in acceptance.BINARIES:
                        (root / "bin" / name).write_text("first")
                    markers = ["SHA256SUMS signature verified.",
                               "Attestation verified against attestations.jsonl"]
                    return "\n".join(marker for marker in markers if marker != omit)
                if args[1] == "update" and replace:
                    for name in acceptance.BINARIES:
                        new = root / "bin" / (name + ".new")
                        new.write_text("second")
                        new.replace(root / "bin" / name)
                if args[1] == "uninstall" and uninstall:
                    (root / "bin/iso").unlink()
                return ""

            with patch.object(acceptance, "command", side_effect=command), \
                    patch.object(acceptance, "check_bundle") as check:
                report = acceptance.accept(root, "v0.7.0", "v0.7.0")
            self.assertEqual(check.call_count, 2)
            self.assertEqual(report["update_kind"], "same-version replacement")
            self.assertIn("--force", calls[1])
            self.assertIn("--keep-data", calls[2])

    def test_first_release_replaces_all_binaries(self):
        self.exercise()

    def test_missing_provenance_marker_fails(self):
        with self.assertRaisesRegex(ValueError, "bundled verification"):
            self.exercise(omit="Attestation verified against attestations.jsonl")

    def test_skipped_replacement_fails(self):
        with self.assertRaisesRegex(ValueError, "replace every"):
            self.exercise(replace=False)

    def test_noop_uninstall_fails(self):
        with self.assertRaisesRegex(ValueError, "retained"):
            self.exercise(uninstall=False)


if __name__ == "__main__":
    unittest.main()
