#!/usr/bin/env python3
"""Keep docs/design/swift-host-inventory.json complete and its references live.

Every captured baseline command path needs an inventory item; every item that
claims a disposition other than `pending` must cite an existing Swift test;
changed and removed items must record a scope decision or notes.
"""

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = json.loads((ROOT / "docs/design/swift-host-inventory.json").read_text())
BASELINE_CLI = json.loads((ROOT / "tests/fixtures/baseline-cli/commands.json").read_text())


class InventoryTests(unittest.TestCase):
    def test_every_baseline_command_is_inventoried(self):
        listed = {i["item"] for i in INVENTORY["items"] if i["surface"] == "cli"}
        missing = sorted(set(BASELINE_CLI["commands"]) - listed)
        self.assertEqual(missing, [], "baseline commands without an inventory item")

    def test_ids_are_unique_and_dispositions_known(self):
        ids = [i["id"] for i in INVENTORY["items"]]
        self.assertEqual(len(ids), len(set(ids)))
        for item in INVENTORY["items"]:
            self.assertIn(item["disposition"], INVENTORY["dispositions"], item["id"])

    def test_claimed_dispositions_cite_existing_tests(self):
        for item in INVENTORY["items"]:
            if item["disposition"] == "pending":
                continue
            with self.subTest(item=item["id"]):
                reference = item.get("swift_test")
                self.assertTrue(reference, "non-pending item without a Swift test")
                path, _, name = reference.partition("#")
                source = (ROOT / path).read_text()
                if name:
                    found = re.search(rf"func {re.escape(name)}\b", source)
                    self.assertTrue(found, f"{name} not found in {path}")

    def test_changes_and_removals_record_a_decision(self):
        for item in INVENTORY["items"]:
            if item["disposition"] in ("changed", "removed", "open"):
                with self.subTest(item=item["id"]):
                    self.assertTrue(item.get("decision") or item.get("notes"))

    def test_baseline_references_exist(self):
        """Test fixtures are in the tree; `src/` names the removed Rust host,
        so it is checked at the recorded baseline revision (git history)."""
        revision = INVENTORY["baseline_revision"]
        for item in INVENTORY["items"]:
            reference = item["baseline_reference"].split(" ")[0]
            with self.subTest(item=item["id"]):
                if reference.startswith("tests/"):
                    self.assertTrue((ROOT / reference).exists(), reference)
                elif reference.startswith("src/"):
                    found = subprocess.run(
                        ["git", "cat-file", "-e", f"{revision}:{reference}"], cwd=ROOT,
                        capture_output=True)
                    self.assertEqual(found.returncode, 0, f"{reference} at {revision}")


if __name__ == "__main__":
    sys.exit(unittest.main())
