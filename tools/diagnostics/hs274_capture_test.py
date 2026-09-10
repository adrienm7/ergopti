# tools/diagnostics/hs274_capture_test.py
"""Require actual physical transitions; missing coverage cannot pass."""

import copy
import json
from pathlib import Path
import unittest

from hs274_capture import MARKER, validate_capture


def fixture():
    """Use unequal and backwards timestamps so the verdict cannot normalize them."""
    return {"coverage": "fixture_only", "seen": 4, "overflow": 0, "contention": 0,
            "records": [{"device": 123, "timestamp": timestamp, "value": value,
                         "has_page": True, "has_usage": True, "page": 7,
                         "usage": usage, "sequence": index}
                        for index, (timestamp, usage, value) in enumerate(
                            ((100, 41, 1), (90, 41, 0), (0, 44, 1), (110, 44, 0)), 1)]}


def encode(capture):
    """Mirror the producer's explicit line boundary."""
    return MARKER + json.dumps(capture) + "\n"


class CaptureVerdictTests(unittest.TestCase):
    """Keep malformed receipts distinct from successful fixture coverage."""

    def test_preserves_original_capture_and_timestamps(self):
        expected = fixture()
        self.assertEqual(validate_capture("startup log\n" + encode(expected), 123), expected)

    def test_preserves_complete_native_capture_with_auxiliary_elements(self):
        path = Path(__file__).with_name("fixtures") / "hs274-native-capture.json"
        expected = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(len(expected["records"]), 20)
        self.assertEqual(validate_capture(encode(expected), 4294968869), expected)

    def test_active_hid_errors_and_unknown_keyboard_usages_fail(self):
        for usage, value in ((1, 1), (2, 1), (3, 1), (1, -1), (-2, 0), (42, 1)):
            candidate = fixture()
            extra = dict(candidate["records"][0], usage=usage, value=value, sequence=5)
            candidate["records"].append(extra)
            candidate["seen"] = 5
            with self.subTest(usage=usage, value=value), self.assertRaises(ValueError):
                validate_capture(encode(candidate), 123)

    def test_missing_duplicate_truncated_and_invalid_receipts_fail(self):
        valid = encode(fixture())
        duplicate_field = valid.replace('"seen": 4', '"seen": 5, "seen": 4')
        for output in ("", "startup log\n", valid + valid, valid.rstrip("\n"), MARKER + "{\n", duplicate_field):
            with self.subTest(output=output), self.assertRaises(ValueError):
                validate_capture(output, 123)

    def test_retains_supplementary_signed_and_absent_usage_metadata(self):
        expected = fixture()
        for page, usage, present in ((-1, -2, True), (0, 0, False)):
            expected["records"].append({"device": 123, "timestamp": 0, "value": 0,
                                        "has_page": present, "has_usage": present,
                                        "page": page, "usage": usage, "sequence": len(expected["records"]) + 1})
        expected["seen"] = len(expected["records"])
        self.assertEqual(validate_capture(encode(expected), 123), expected)

    def test_empty_losses_and_wrong_coverage_fail(self):
        for key, value in (("records", []), ("seen", 5), ("seen", True),
                           ("overflow", 1), ("contention", 1), ("coverage", "all_devices")):
            candidate = fixture()
            candidate[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                validate_capture(encode(candidate), 123)

    def test_corrupted_record_identity_and_types_fail(self):
        for key, value in (("device", 124), ("sequence", 2), ("timestamp", True),
                           ("timestamp", -1), ("value", 0.0), ("has_page", 1),
                           ("has_usage", False), ("page", 1 << 31), ("usage", -(1 << 31) - 1)):
            candidate = fixture()
            candidate["records"][0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                validate_capture(encode(candidate), 123)

    def test_missing_duplicate_reordered_and_remapped_physical_keys_fail(self):
        original = fixture()
        variants = [original["records"][:-1], original["records"] + [original["records"][-1]],
                    list(reversed(original["records"]))]
        remapped = copy.deepcopy(original["records"])
        remapped[0]["usage"] = remapped[1]["usage"] = 44
        variants.append(remapped)
        for records in variants:
            candidate = fixture()
            candidate["records"] = copy.deepcopy(records)
            candidate["seen"] = len(records)
            for index, row in enumerate(candidate["records"], 1):
                row["sequence"] = index
            with self.subTest(records=records), self.assertRaises(ValueError):
                validate_capture(encode(candidate), 123)


if __name__ == "__main__":
    unittest.main()
