# tools/diagnostics/hs274_hammerspoon_test.py
"""Reject native consumer receipts without exact physical and process evidence."""

import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from hs274_hammerspoon import CaptureReceipt, validate_consumer
from hs274_stream_test import fixture


def receipt():
    capture, _ = fixture()
    downs = [row for row in capture["records"] if row["page"] == 7 and row["usage"] in (41, 44) and row["value"] == 1]
    return capture, {"runtime": "native Hammerspoon", "coverage": "fixture_only", "settled": True,
                     "stop_requested": True, "error_count": 0, "errors": [], "exit": 143, "counts": {"49": 1, "53": 1},
                     "contexts": [{"device": str(row["device"]), "timestamp": str(row["timestamp"])} for row in downs],
                     "presses": [{"device": str(row["device"]), "keycode": {41: 53, 44: 49}[row["usage"]]} for row in downs]}


class ConsumerTests(unittest.TestCase):
    def test_requires_physical_pair_and_complete_native_settlement(self):
        capture, result = receipt()
        validate_consumer(result, capture)
        for field, value in (("runtime", "Lua fixture"), ("coverage", "complete"), ("settled", False),
                             ("stop_requested", False), ("error_count", False), ("error_count", 1),
                             ("errors", ["failure"]),
                             ("exit", 143.0), ("exit", 0), ("counts", {"49": 2, "53": 0}),
                             ("counts", {"49": True, "53": 1}), ("presses", [])):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_consumer(dict(result, **{field: value}), capture)
        with self.assertRaises(ValueError):
            validate_consumer(dict(result, presses=[], contexts=[]), {"records": []})

    def test_rejects_changed_original_context_or_physical_key(self):
        capture, result = receipt()
        for group, field, value in (("contexts", "timestamp", "0"), ("contexts", "device", "9"),
                                    ("presses", "keycode", 49), ("presses", "device", "9")):
            altered = copy.deepcopy(result)
            altered[group][0][field] = value
            with self.subTest(group=group, field=field), self.assertRaises(ValueError):
                validate_consumer(altered, capture)

    def test_receipt_requires_observed_native_process_and_actual_task_exit(self):
        _, result = receipt()
        with tempfile.TemporaryDirectory(prefix="hs274-consumer-") as directory:
            path = Path(directory) / "result.json"
            native = SimpleNamespace(matching=lambda _: [42])
            client = CaptureReceipt(path, native, Path("owned-executable"))
            self.assertIsNone(client.poll())
            path.write_text(json.dumps(result), encoding="utf-8")
            self.assertEqual(client.poll(), 143)
            self.assertTrue(client.observed)
            native.matching = lambda _: []
            unseen = CaptureReceipt(path, native, Path("owned-executable"))
            with self.assertRaisesRegex(RuntimeError, "No exact Hammerspoon"):
                unseen.poll()
            for field, value in (("settled", False), ("exit", 143.0), ("error_count", 1), ("error_count", False)):
                path.write_text(json.dumps(dict(result, **{field: value})), encoding="utf-8")
                with self.subTest(field=field), self.assertRaises(RuntimeError):
                    client.poll()


if __name__ == "__main__":
    unittest.main()
