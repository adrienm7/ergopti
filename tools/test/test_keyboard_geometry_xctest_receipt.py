"""Portable controls for the real selected-XCTest receipt evaluator."""

import importlib.util
import unittest
from pathlib import Path

SOURCE = "func testOne() {}\nfunc testTwo() throws {}\n"
CLASS = "KeyboardGeometryTests"
ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "tools/diagnostics/keyboard_geometry_xctest_receipt.py"
SPEC = importlib.util.spec_from_file_location("geometry_receipt", MODULE)
RECEIPT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECEIPT)


def transcript(style="swift"):
    rows = ["Test Suite 'Selected tests' started at time"]
    for name in ("testOne", "testTwo"):
        identity = (
            f"ErgoptiPlusTests.{CLASS}.{name}"
            if style == "swift"
            else f"-[ErgoptiPlusTests.{CLASS} {name}]"
        )
        rows.extend(
            [f"Test Case '{identity}' started.", f"Test Case '{identity}' passed (0.001 seconds)."]
        )
    rows.append("Test Suite 'Selected tests' passed at time")
    return "\n".join(rows)


class ReceiptControls(unittest.TestCase):
    def result(self, log, test=0, capture=0):
        return RECEIPT.evaluate(SOURCE, log, CLASS, test, capture)

    def test_both_actual_xctest_identity_grammars(self):
        for style in ("swift", "objc"):
            result = self.result(transcript(style))
            self.assertTrue(result["passed"])
            self.assertFalse(result["physical_keyboard_qualified"])

    def test_zero_match_is_not_pass(self):
        self.assertFalse(self.result("warning: No matching test cases were run")["passed"])

    def test_missing_start_is_not_pass(self):
        self.assertFalse(
            self.result(
                transcript().replace(f"Test Case 'ErgoptiPlusTests.{CLASS}.testOne' started.", "")
            )["passed"]
        )

    def test_missing_terminal_is_not_pass(self):
        self.assertFalse(
            self.result(
                transcript().replace(
                    f"Test Case 'ErgoptiPlusTests.{CLASS}.testOne' passed (0.001 seconds).", ""
                )
            )["passed"]
        )

    def test_skipped_and_failed_are_not_pass(self):
        for status in ("failed", "skipped"):
            self.assertFalse(
                self.result(transcript().replace("passed (", status + " (", 1))["passed"]
            )

    def test_engine_and_capture_failures_remain_visible(self):
        for test, capture in ((1, 0), (0, 1), (2, 1)):
            result = self.result(transcript(), test, capture)
            self.assertFalse(result["passed"])
            self.assertEqual(result["test_exit"], test)
            self.assertEqual(result["capture_exit"], capture)

    def test_duplicate_rows_are_not_pass(self):
        self.assertFalse(self.result(transcript() + "\n" + transcript())["passed"])

    def test_foreign_class_is_refused(self):
        with self.assertRaises(ValueError):
            self.result(transcript().replace(CLASS, "ForeignTests"))

    def test_missing_suite_completion_is_not_pass(self):
        self.assertFalse(
            self.result(transcript().replace("Test Suite 'Selected tests' passed at time", ""))[
                "passed"
            ]
        )

    def test_native_observation_is_required_and_bounded(self):
        native_name = "testActualNativeCarbonCanonicalAndOlderModels"
        source = SOURCE.replace("testTwo", native_name)
        log = transcript().replace("testTwo", native_name)
        self.assertFalse(RECEIPT.evaluate(source, log, CLASS, 0, 0)["passed"])
        row = "KEYBOARD_GEOMETRY_OBSERVATION ranges=11 env_bytes=800 elapsed_ns=123456 arg_max=262144 physical_qualified=false"
        result = RECEIPT.evaluate(source, log + "\n" + row, CLASS, 0, 0)
        self.assertTrue(result["passed"])
        self.assertEqual(result["native_map_observation"]["range_count"], 11)
        for invalid in (
            row.replace("ranges=11", "ranges=0"),
            row.replace("env_bytes=800", "env_bytes=999999"),
            row + "\n" + row,
        ):
            self.assertFalse(RECEIPT.evaluate(source, log + "\n" + invalid, CLASS, 0, 0)["passed"])


if __name__ == "__main__":
    unittest.main()
