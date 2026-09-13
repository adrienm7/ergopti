# tools/diagnostics/hs274_accessibility_test.py
"""Keep UI approval failures visible independently of native trust verification."""
from types import SimpleNamespace
import unittest
import subprocess
from unittest.mock import patch

from hs274_accessibility import approve_accessibility


class ApprovalTests(unittest.TestCase):
    def test_unrecognized_sheet_prevents_navigation_and_permission_changes(self):
        report = {}
        result = SimpleNamespace(returncode=0, stdout="unknown sheet", stderr="sheet detail")
        with patch("hs274_accessibility.subprocess.run", return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, "preparation was not confirmed"):
                approve_accessibility(report)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(report["hammerspoon_accessibility"]["stage"], "prepare_settings")
        self.assertEqual(report["hammerspoon_settings_preparation"]["stdout"], "unknown sheet")

    def test_retains_partial_output_and_phase_on_native_timeout(self):
        report = {}
        timeout = subprocess.TimeoutExpired("osascript", 15, output=b"partial UI", stderr=b"pending")
        with patch("hs274_accessibility.subprocess.run", side_effect=[
                SimpleNamespace(returncode=0, stdout="dismissed", stderr=""), SimpleNamespace(returncode=0), timeout]):
            with self.assertRaises(subprocess.TimeoutExpired):
                approve_accessibility(report)
        self.assertEqual(report["hammerspoon_accessibility"], {
            "stage": "approval", "exit": None, "timed_out": True, "stdout": "partial UI", "stderr": "pending"})

    def test_requires_exact_success_and_retains_raw_failure_evidence(self):
        for code, stdout in ((0, "enabled\n"), (1, "enabled\n"), (0, "No unique Hammerspoon checkbox\n"), (0, "")):
            report = {}
            with self.subTest(code=code, stdout=stdout), patch("hs274_accessibility.subprocess.run", side_effect=[
                    SimpleNamespace(returncode=0, stdout="no_sheet", stderr=""),
                    SimpleNamespace(returncode=0), SimpleNamespace(returncode=code, stdout=stdout, stderr="UI detail")]):
                if code == 0 and stdout == "enabled\n":
                    approve_accessibility(report)
                else:
                    with self.assertRaisesRegex(RuntimeError, "not confirmed"):
                        approve_accessibility(report)
                self.assertEqual(report["hammerspoon_accessibility"], {
                    "stage": "approval", "exit": code, "stdout": stdout, "stderr": "UI detail"})


if __name__ == "__main__":
    unittest.main()
