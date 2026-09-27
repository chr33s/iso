#!/usr/bin/env python3
"""Verify candidate source identity against an actual isolated Git checkout."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("transition", ROOT / "scripts/build-proxy-transition.py")
transition = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transition)


class CandidateSourceTests(unittest.TestCase):
    def test_clean_exact_revision_required(self):
        with tempfile.TemporaryDirectory(prefix="coop-candidate-source-") as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
            git("init", "-q")
            (root / "source").write_text("first revision\n")
            git("add", "source")
            git("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "-qm", "fixture")
            revision = git("rev-parse", "HEAD")
            original = transition.ROOT
            transition.ROOT = root
            try:
                self.assertEqual(transition.source_state(revision), (revision, False))
                with self.assertRaisesRegex(RuntimeError, "exact expected revision"):
                    transition.source_state("0" * 40)
                (root / "source").write_text("modified tracked source\n")
                with self.assertRaisesRegex(RuntimeError, "clean checkout"):
                    transition.source_state(revision)
                git("checkout", "--", "source")
                (root / "untracked-source").write_text("new source\n")
                with self.assertRaisesRegex(RuntimeError, "clean checkout"):
                    transition.source_state(revision)
                self.assertEqual(transition.source_state(), (revision, True))
                (root / "untracked-source").unlink()
                self.exercise_main_path(root, revision)
            finally:
                transition.ROOT = original

    def exercise_main_path(self, root, revision):
        # Keep generated build output outside the checkout, as in hosted CI.
        with tempfile.TemporaryDirectory(prefix="coop-candidate-output-") as output:
            output = Path(output)
            target = output / "target"
            binaries = target / "release"
            binaries.mkdir(parents=True)
            swift = output / "swift"
            swift.mkdir()
            (root / "LICENSE").write_text("fixture license\n")
            subprocess.run(["git", "add", "LICENSE"], cwd=root, check=True)
            # A staged addition is also dirty and must fail before tool execution.
            archive = output / "candidate.tar.gz"
            calls = []
            original_output = subprocess.check_output
            mutate_during_build = False
            def check_output(argv, **kwargs):
                if argv[:2] == ["cargo", "metadata"]:
                    return json.dumps({"target_directory": str(target)})
                if argv[0] == "swift":
                    return str(swift)
                return original_output(argv, **kwargs)
            def build(*args, signing=False):
                calls.append(args)
                if args[0].endswith("macos-sign-notarize.sh"):
                    self.assertTrue(signing, "signing script must receive signing secrets")
                    signed = Path(args[1])
                    self.assertEqual(sorted(p.name for p in signed.iterdir()),
                                     ["coop", "coop-proxy", "coop-sandbox"])
                    for binary in signed.iterdir():
                        binary.write_bytes(b"signed " + binary.read_bytes())
                    return
                self.assertFalse(signing, "build step received signing secrets")
                if mutate_during_build:
                    (root / "source").write_text("source changed during build\n")
                if args[0] == "cargo":
                    for name in ["coop", "coop-proxy", "coop-proxy-rs", "coop-proxy-swift"]:
                        (binaries / name).write_bytes(b"fixture binary")
                (swift / "coop-proxy-swift").write_bytes(b"fixture Swift binary")
                if args[0].endswith("build-coop-sandbox.sh"):
                    runtime = Path(args[1]) / "bin"
                    runtime.mkdir()
                    (runtime / "coop-sandbox").write_bytes(b"fixture runtime")
            arguments = ["builder", "--release", "--include-runtime", "--archive", str(archive),
                         "--expected-revision", revision]
            with patch.object(transition.platform, "system", return_value="Darwin"), \
                 patch.object(transition.platform, "machine", return_value="arm64"), \
                 patch.object(transition.platform, "mac_ver", return_value=("27.0", (), "")), \
                 patch.object(transition, "run", side_effect=build), \
                 patch.object(transition.subprocess, "check_output", side_effect=check_output), \
                 patch("sys.argv", arguments):
                with self.assertRaisesRegex(RuntimeError, "clean checkout"):
                    transition.main()
                self.assertEqual(calls, [], "dirty source reached the compiler")
                subprocess.run(["git", "reset", "--quiet", "--", "LICENSE"], cwd=root, check=True)
                (root / "LICENSE").unlink()
                # The archive needs a license, but a tracked fixture source can
                # serve as one without changing the checkout's identity.
                subprocess.run(["git", "mv", "source", "LICENSE"], cwd=root, check=True)
                subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                "commit", "-qm", "license fixture"], cwd=root, check=True)
                arguments[-1] = original_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
                transition.main()
                self.assertTrue(archive.is_file(), "clean exact revision must package")
                with tarfile.open(archive) as bundle:
                    self.assertEqual(set(bundle.getnames()), {
                        "coop-proxy-transition/" + name for name in
                        ["coop", "coop-proxy", "coop-sandbox", "LICENSE", "SHA256SUMS", "BUILD.json"]})
                    manifest = json.load(bundle.extractfile("coop-proxy-transition/BUILD.json"))
                    self.assertEqual(manifest["default_proxy"], "swift")
                self.assertEqual((binaries / "coop-proxy").read_bytes(), b"fixture Swift binary")
                self.assertFalse((binaries / "coop-proxy-swift").exists())
                self.assertFalse((binaries / "coop-proxy-rs").exists())
                self.assertFalse(any("coop-proxy" in call and call[0] == "cargo" for call in calls))
                self.assertFalse(any(call[0].endswith("macos-sign-notarize.sh") for call in calls))
                archive.unlink()
                calls.clear()
                arguments.append("--sign")
                transition.main()
                self.assertTrue(calls[-1][0].endswith("macos-sign-notarize.sh"))
                with tarfile.open(archive) as bundle:
                    sums = bundle.extractfile("coop-proxy-transition/SHA256SUMS").read().decode()
                    for name in ["coop", "coop-proxy", "coop-sandbox"]:
                        content = bundle.extractfile(f"coop-proxy-transition/{name}").read()
                        self.assertTrue(content.startswith(b"signed "), f"{name} archived unsigned")
                        self.assertIn(f"{hashlib.sha256(content).hexdigest()}  {name}\n", sums)
                    manifest = json.load(bundle.extractfile("coop-proxy-transition/BUILD.json"))
                    self.assertTrue(manifest["developer_id_signed"])
                self.assertEqual((binaries / "coop-proxy").read_bytes(), b"fixture Swift binary")
                arguments.remove("--sign")
                archive.unlink()
                calls.clear()
                mutate_during_build = True
                with self.assertRaisesRegex(RuntimeError, "clean checkout"):
                    transition.main()
                self.assertTrue(calls, "post-build case never reached the compiler")
                self.assertFalse(archive.exists(), "changed source was packaged")


class SigningEnvironmentTests(unittest.TestCase):
    def test_secrets_reach_only_the_signing_call(self):
        secrets = {name: "secret" for name in transition.SIGNING_ENV}
        with patch.dict(os.environ, secrets), patch.object(transition.subprocess, "run") as spawn:
            transition.run("cargo", "build")
            self.assertFalse(transition.SIGNING_ENV & spawn.call_args.kwargs["env"].keys())
            self.assertIn("PATH", spawn.call_args.kwargs["env"])
            transition.run("sign", signing=True)
            self.assertIsNone(spawn.call_args.kwargs["env"])


if __name__ == "__main__":
    unittest.main()
