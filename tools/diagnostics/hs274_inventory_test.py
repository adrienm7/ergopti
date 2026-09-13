# tools/diagnostics/hs274_inventory_test.py
"""Keep absent, truncated and failed native inventories from passing admission."""

import json
import unittest

from hs274_inventory import MARKER, read_inventories


def receipt(**changes):
    row = {"version": 1, "device": "41", "coverage": "fixture_only", "enumerated": True,
           "exhausted": False, "readable": True, "elements": [{"usage": 44}]}
    row.update(changes)
    return MARKER + json.dumps(row) + "\n"


class InventoryTests(unittest.TestCase):
    def test_all_devices_and_monitor_restarts_are_retained(self):
        output = receipt() + receipt(device="42", readable=False) + receipt()
        records = read_inventories(output, 41)
        self.assertEqual([row["device"] for row in records], ["41", "42", "41"])
        self.assertFalse(records[1]["readable"])

    def test_missing_failed_and_malformed_evidence_cannot_admit_fixture(self):
        for output in ("", receipt(device="42"), receipt(readable=False), receipt().rstrip(),
                       receipt() + receipt(readable=False), receipt(elements=[]), receipt(exhausted=True),
                       receipt(enumerated=False), receipt(version=True), receipt(readable=1),
                       receipt(elements=[{}] * 257), receipt().replace('"version": 1', '"version": 1, "version": 2')):
            with self.subTest(output=output), self.assertRaises(ValueError):
                read_inventories(output, 41)


if __name__ == "__main__":
    unittest.main()
