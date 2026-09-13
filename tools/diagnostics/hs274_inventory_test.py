# tools/diagnostics/hs274_inventory_test.py
"""Keep absent, truncated and failed native inventories from passing admission."""

import json
from pathlib import Path
import unittest

from hs274_inventory import MARKER, read_inventories


def receipt(**changes):
    row = {"version": 2, "device": "41", "coverage": "fixture_only", "capacity": 300, "enumerated": True,
           "exhausted": False, "readable": True, "elements": [{"usage": 44}]}
    row.update(changes)
    return MARKER + json.dumps(row) + "\n"


class InventoryTests(unittest.TestCase):
    def test_retained_native_scenarios_preserve_all_observations(self):
        evidence = json.loads((Path(__file__).parent / "fixtures" / "hs274-native-inventories.json").read_text(encoding="utf-8"))
        self.assertEqual(len(evidence["scenarios"]), 2)
        for scenario in evidence["scenarios"]:
            with self.subTest(run=scenario["run"]):
                output = "".join(MARKER + json.dumps(row) + "\n" for row in scenario["inventories"])
                records = read_inventories(output, int(scenario["fixture_device"]))
                self.assertEqual(records, scenario["inventories"])

    def test_all_devices_and_monitor_restarts_are_retained(self):
        output = receipt() + receipt(device="42", readable=False) + receipt()
        records = read_inventories(output, 41)
        self.assertEqual([row["device"] for row in records], ["41", "42", "41"])
        self.assertFalse(records[1]["readable"])

    def test_missing_failed_and_malformed_evidence_cannot_admit_fixture(self):
        for output in ("", receipt(device="42"), receipt(readable=False), receipt().rstrip(),
                       receipt() + receipt(readable=False), receipt(elements=[]), receipt(exhausted=True),
                       receipt(enumerated=False), receipt(version=True), receipt(readable=1),
                       receipt(capacity=0), receipt(capacity=True), receipt(version=1),
                       receipt(capacity=2, elements=[{}] * 3),
                       receipt().replace('"version": 2', '"version": 2, "version": 1')):
            with self.subTest(output=output), self.assertRaises(ValueError):
                read_inventories(output, 41)

    def test_declared_element_bound_is_not_a_usage_count_and_retains_every_leaf(self):
        elements = [{"usage": usage, "cookie": usage} for usage in range(1, 256)]
        elements += [{"usage": usage, "cookie": usage + 256} for usage in range(224, 232)]
        records = read_inventories(receipt(elements=elements), 41)
        self.assertEqual(records[0]["elements"], elements)
        self.assertEqual(len(records[0]["elements"]), 263)


if __name__ == "__main__":
    unittest.main()
