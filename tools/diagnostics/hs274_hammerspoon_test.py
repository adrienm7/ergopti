# tools/diagnostics/hs274_hammerspoon_test.py
"""Reject native consumer receipts without exact physical and process evidence."""

import copy
from datetime import datetime
import json
import math
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from hs274_hammerspoon import CaptureReceipt, read_clock, validate_consumer, validate_clock, validate_context
from hs274_stream_test import fixture


def receipt():
    capture, _ = fixture()
    downs = [row for row in capture["records"] if row["page"] == 7 and row["usage"] in (41, 44) and row["value"] == 1]
    def date(row):
        epoch = 1000 + (row["timestamp"] * 125 // 3) / 1000000000
        return datetime.fromtimestamp(math.floor(epoch)).strftime("%Y-%m-%d %H:%M:%S") + f".{math.floor((epoch % 1) * 1000):03d}"
    return capture, {"runtime": "native Hammerspoon", "coverage": "fixture_only", "settled": True,
                     "context_source": "native app/window/AX", "context_stopped": True,
                     "context_observations": [{"observed_ns": "0", "allowed": True, "app": "Observed", "epoch": 1000}],
                     "clock": {"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3},
                     "capture_started_ns": "0", "clock_samples": [
                         {"original_ns": str(row["timestamp"] * 125 // 3),
                          "observed_ns": str(row["timestamp"] * 125 // 3 + 1)} for row in downs],
                     "stop_requested": True, "error_count": 0, "errors": [], "exit": 143, "counts": {"49": 1, "53": 1},
                     "contexts": [{"device": str(row["device"]), "timestamp": str(row["timestamp"])} for row in downs],
                     "presses": [{"device": str(row["device"]), "keycode": {41: 53, 44: 49}[row["usage"]],
                                  "app": "Observed", "timestamp": date(row)} for row in downs]}


class ConsumerTests(unittest.TestCase):
    def test_native_context_receipt_rejects_fabricated_app_and_arrival_time(self):
        capture, result = receipt()
        for field, value in (("context_source", "synthetic"), ("context_stopped", False),
                             ("context_observations", [])):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_consumer(dict(result, **{field: value}), capture)
        for field, value in (("app", "ArrivalApp"), ("timestamp", "2026-09-12 12:00:00.000")):
            altered = copy.deepcopy(result)
            altered["presses"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_consumer(altered, capture)
        altered = copy.deepcopy(result)
        altered["context_observations"][0]["allowed"] = False
        with self.assertRaisesRegex(ValueError, "retain private context"):
            validate_consumer(altered, capture)

    def test_native_context_validator_selects_original_observation_and_excludes_private_input(self):
        result = {"context_source": "native app/window/AX", "context_stopped": True,
                  "clock": {"version": 1, "domain": "mach_absolute_time", "numer": 1, "denom": 1},
                  "context_observations": [
                      {"observed_ns": "0", "allowed": True, "app": "Original", "epoch": 1000},
                      {"observed_ns": "2000000000", "allowed": False},
                      {"observed_ns": "3000000000", "allowed": True, "app": "Current", "epoch": 2000}],
                  "presses": [{"app": "Original", "timestamp": datetime.fromtimestamp(1001).strftime("%Y-%m-%d %H:%M:%S.000")}]}
        rows = [{"timestamp": 1000000000}, {"timestamp": 2000000000}]
        validate_context(result, rows)
        result["context_observations"][0]["observed_ns"] = "1000000001"
        with self.assertRaisesRegex(ValueError, "predates native context"):
            validate_context(result, rows)

    def test_native_clock_scale_rejects_coercion_and_missing_information(self):
        scale = {"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3}
        self.assertEqual(read_clock(scale), scale)
        for field, value in (("version", True), ("domain", "wall_clock"), ("numer", 0),
                             ("denom", 0), ("numer", "125"), ("denom", 3.0),
                             ("numer", 1 << 32), ("denom", -1)):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                read_clock(dict(scale, **{field: value}))
        for field in scale:
            with self.subTest(missing=field), self.assertRaises(ValueError):
                read_clock({key: value for key, value in scale.items() if key != field})

    def test_original_clock_is_scaled_and_bounded_by_native_capture_and_delivery(self):
        rows = [{"timestamp": 45824088534}, {"timestamp": 45828488808}]
        result = {"clock": {"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3},
                  "capture_started_ns": "1900000000000", "clock_samples": [
                      {"original_ns": "1909337022250", "observed_ns": "1910000000000"},
                      {"original_ns": "1909520367000", "observed_ns": "1911000000000"}]}
        validate_clock(result, rows)
        for field, value in (("original_ns", "45824088534"), ("original_ns", "1910000000000"),
                             ("original_ns", "1909337022251"), ("observed_ns", "1909337022249")):
            altered = copy.deepcopy(result)
            altered["clock_samples"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_clock(altered, rows)
        for field, value in (("clock_samples", []), ("capture_started_ns", "1910000000000")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_clock(dict(result, **{field: value}), rows)

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
