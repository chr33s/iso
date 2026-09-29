#!/usr/bin/env python3
"""Tests for scripts/migrate-config-to-jsonc.py (H-01 migration evidence).

Run with Python 3.11+: python3 tests/test-migrate-config.py
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "migrate-config-to-jsonc.py"
SECRET = "SYNTHETIC-LITERAL-CREDENTIAL"


class MigrateConfigTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="iso-migrate-")
        self.root = Path(self.directory.name)
        self.home = self.root / "home"
        self.home.mkdir()

    def tearDown(self):
        self.directory.cleanup()

    def run_script(self, toml, *extra, output="config.jsonc", input_path=None):
        source = input_path or self.root / "config.toml"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(toml, encoding="utf-8")
        destination = self.root / output
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--input", str(source), "--output", str(destination), *extra],
            capture_output=True, text=True, env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
        )
        return result, source, destination

    def converted(self, toml, *extra, output="config.jsonc"):
        result, _, destination = self.run_script(toml, *extra, output=output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "", "the converter must never print the document")
        return json.loads(destination.read_text(encoding="utf-8"))

    def test_structure_is_preserved(self):
        doc = self.converted(
            'post_start = "x"\n'
            "forward_ports = [3000, \"1:2\", { guest = 5, label = \"db\" }]\n"
            "mixed = [1, \"a\", true, [], { k = 1.5 }]\n"
            "[profiles.\"a.b\"]\nplugins = [\"p\"]\n"
            "[profiles.a]\napt_packages = []\n"
            "[[future.items]]\nname = \"one\"\n[[future.items]]\nname = \"two\"\n"
            "[updates]\ncheck_interval_hours = 9223372036854775807\n"
        )
        self.assertEqual(doc["profiles"]["a.b"], {"plugins": ["p"]})
        self.assertEqual(doc["profiles"]["a"], {"apt_packages": []})
        self.assertEqual(doc["future"]["items"], [{"name": "one"}, {"name": "two"}])
        self.assertEqual(doc["mixed"], [1, "a", True, [], {"k": 1.5}])
        self.assertEqual(doc["forward_ports"][2], {"guest": 5, "label": "db"})
        self.assertEqual(doc["updates"]["check_interval_hours"], 2**63 - 1)

    def test_credential_references_are_not_executed(self):
        marker = self.root / "executed"
        doc = self.converted(
            f'[claude]\napi_key = "cmd:touch {marker}"\n'
            f'[proxy.anthropic]\ncredential = "cmd:touch {marker}"\n'
        )
        self.assertFalse(marker.exists())
        self.assertEqual(doc["proxy"]["anthropic"]["credential"], f"cmd:touch {marker}")

    def test_output_is_new_owner_only_and_source_untouched(self):
        toml = "ssh_port = 22\n"
        result, source, destination = self.run_script(toml)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        self.assertEqual(source.read_text(), toml)
        again, _, _ = self.run_script(toml)
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("already exists", again.stderr)
        self.assertEqual(json.loads(destination.read_text()), {"ssh_port": 22})

    def test_symlinked_destination_is_refused(self):
        target = self.root / "elsewhere.jsonc"
        (self.root / "link.jsonc").symlink_to(target)
        result, _, _ = self.run_script("ssh_port = 22\n", output="link.jsonc")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())
        leftovers = [p for p in self.root.iterdir() if p.name.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_retired_fields_are_refused_by_default(self):
        toml = (
            'firecracker_bin = "/secret/path/fc"\n[vm]\nvcpu_count = 4\nkernel_path = "/k"\n'
            '[network]\nhost_ip = "10.9.8.7"\n'
        )
        result, _, destination = self.run_script(toml)
        self.assertEqual(result.returncode, 1)
        for path in ("firecracker_bin", "vm.kernel_path", "network.host_ip"):
            self.assertIn(path, result.stderr)
        self.assertNotIn("/secret/path/fc", result.stderr)
        self.assertNotIn("10.9.8.7", result.stderr)
        self.assertFalse(destination.exists())

    def test_drop_retired_fields_removes_only_the_closed_list(self):
        doc = self.converted(
            'firecracker_bin = "/fc"\n[vm]\nvcpu_count = 4\nboot_args = "x"\n'
            '[network]\nsubnet_mask = "/24"\nhost_iface = "auto"\n',
            "--drop-retired-fields",
        )
        self.assertEqual(doc, {"vm": {"vcpu_count": 4}})
        empty = self.converted("[network]\n", "--drop-retired-fields", output="empty.jsonc")
        self.assertEqual(empty, {})

    def test_unknown_network_children_are_refused(self):
        result, _, destination = self.run_script(
            '[network]\nhost_ip = "172.16.0.1"\nmy_note = "keep"\n', "--drop-retired-fields"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("network.my_note", result.stderr)
        self.assertNotIn("keep", result.stderr.replace("network.my_note", ""))
        self.assertFalse(destination.exists())

    def test_literal_proxy_credentials_are_refused_without_echo(self):
        for provider in ("anthropic", "openai"):
            with self.subTest(provider=provider):
                result, _, destination = self.run_script(
                    f'[proxy.{provider}]\ncredential = "{SECRET}"\n', output=f"{provider}.jsonc"
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"proxy.{provider}.credential", result.stderr)
                self.assertIn("iso proxy setup", result.stderr)
                self.assertNotIn(SECRET, result.stderr + result.stdout)
                self.assertFalse(destination.exists())

    def test_lossy_values_are_refused(self):
        for toml, path in [
            ("when = 1979-05-27T07:32:00Z\n", "when"),
            ("[a]\nday = 1979-05-27\n", "a.day"),
            ("t = 07:32:00\n", "t"),
            ("x = nan\n", "x"),
            ("x = inf\n", "x"),
            ('[profiles."a.b"]\nwhen = 1979-05-27\n', '["a.b"]'),
        ]:
            with self.subTest(toml=toml):
                result, _, destination = self.run_script(toml)
                self.assertEqual(result.returncode, 1)
                self.assertIn(path, result.stderr)
                self.assertFalse(destination.exists())

    def test_invalid_toml_reports_position_not_content(self):
        result, _, _ = self.run_script(f'api_key = "{SECRET}\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("not valid TOML", result.stderr)
        self.assertNotIn(SECRET, result.stderr)

    def test_output_extension_is_checked(self):
        result, _, _ = self.run_script("", output="config.toml")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    if sys.version_info < (3, 11):
        sys.exit("tests/test-migrate-config.py requires Python 3.11+")
    unittest.main()
