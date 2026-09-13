# tools/diagnostics/hs274_accessibility_test.py
"""Keep UI approval failures visible independently of native trust verification."""
from types import SimpleNamespace
from contextlib import contextmanager
import unittest
import subprocess
from unittest.mock import patch

from hs274_accessibility import approve_accessibility


class ApprovalTests(unittest.TestCase):
    def test_account_outlives_selection_and_admission_even_when_selection_fails(self):
        for rejected in (False, True):
            lifecycle = []

            @contextmanager
            def account(output, state):
                lifecycle.append("created")
                try:
                    yield "fixture-user", "fixture-secret"
                finally:
                    lifecycle.append("removed")

            def select(*args):
                self.assertEqual(lifecycle, ["created"])
                if rejected:
                    raise RuntimeError("Fixture selection refused")

            responses = iter(("no_sheet", "", "missing_application",
                              "addition_sheet_observed", "authentication_submitted", "enabled"))

            def native(*args, **kwargs):
                response = next(responses)
                if response == "enabled":
                    self.assertEqual(lifecycle, ["created"])
                return SimpleNamespace(returncode=0, stdout=response, stderr="")

            with self.subTest(rejected=rejected), \
                    patch.dict("os.environ", {"RUNNER_TEMP": "fixture-output"}), \
                    patch("hs274_accessibility_auth.approval_account", account), \
                    patch("hs274_accessibility.select_application", side_effect=select), \
                    patch("hs274_accessibility.subprocess.run", side_effect=native):
                if rejected:
                    with self.assertRaisesRegex(RuntimeError, "Fixture selection refused"):
                        approve_accessibility({}, "owned/Hammerspoon.app")
                else:
                    approve_accessibility({}, "owned/Hammerspoon.app")
                self.assertEqual(lifecycle, ["created", "removed"])

    def test_waits_for_added_row_but_does_not_repeat_authentication(self):
        report = {}
        responses = [SimpleNamespace(returncode=0, stdout=value, stderr="UI detail") for value in (
            "no_sheet", "", "missing_application", "addition_sheet_observed", "missing_application", "enabled")]
        with patch("hs274_accessibility.authenticate_accessibility") as authenticate, \
                patch("hs274_accessibility.select_application") as select, \
                patch("hs274_accessibility.subprocess.run", side_effect=responses):
            approve_accessibility(report, "owned/Hammerspoon.app")
        authenticate.assert_called_once()
        select.assert_called_once_with("owned/Hammerspoon.app", report)
        self.assertEqual(report["hammerspoon_accessibility"]["stdout"], "enabled")

    def test_opening_addition_sheet_does_not_claim_permission(self):
        report = {}
        with patch("hs274_accessibility.authenticate_accessibility"), \
                patch("hs274_accessibility.select_application"), patch("hs274_accessibility.subprocess.run", side_effect=[
                SimpleNamespace(returncode=0, stdout="no_sheet", stderr=""),
                SimpleNamespace(returncode=0),
                SimpleNamespace(returncode=0, stdout="missing_application", stderr="application list"),
                SimpleNamespace(returncode=0, stdout="addition_sheet_observed", stderr="sheet controls"),
                SimpleNamespace(returncode=0, stdout="missing_application", stderr="still absent"),
                SimpleNamespace(returncode=0, stdout="missing_application", stderr="still absent"),
                SimpleNamespace(returncode=0, stdout="missing_application", stderr="still absent")]):
            with self.assertRaisesRegex(RuntimeError, "not confirmed"):
                approve_accessibility(report, "owned/Hammerspoon.app")
        self.assertEqual(report["hammerspoon_accessibility"]["stage"], "verify_permission")
        self.assertEqual(report["hammerspoon_accessibility"]["stderr"], "still absent")
        self.assertEqual(report["hammerspoon_accessibility_listing"]["stderr"], "application list")
        self.assertEqual(len(report["hammerspoon_accessibility_admission"]), 3)

    def test_unrecognized_sheet_prevents_navigation_and_permission_changes(self):
        report = {}
        result = SimpleNamespace(returncode=0, stdout="unknown sheet", stderr="sheet detail")
        with patch("hs274_accessibility.subprocess.run", return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, "preparation was not confirmed"):
                approve_accessibility(report, "owned/Hammerspoon.app")
        self.assertEqual(run.call_count, 1)
        self.assertEqual(report["hammerspoon_accessibility"]["stage"], "prepare_settings")
        self.assertEqual(report["hammerspoon_settings_preparation"]["stdout"], "unknown sheet")

    def test_retains_partial_output_and_phase_on_native_timeout(self):
        report = {}
        timeout = subprocess.TimeoutExpired("osascript", 15, output=b"partial UI", stderr=b"pending")
        with patch("hs274_accessibility.subprocess.run", side_effect=[
                SimpleNamespace(returncode=0, stdout="dismissed", stderr=""), SimpleNamespace(returncode=0), timeout]):
            with self.assertRaises(subprocess.TimeoutExpired):
                approve_accessibility(report, "owned/Hammerspoon.app")
        self.assertEqual(report["hammerspoon_accessibility"], {
            "stage": "approval", "exit": None, "timed_out": True, "stdout": "partial UI", "stderr": "pending"})

    def test_requires_exact_success_and_retains_raw_failure_evidence(self):
        for code, stdout in ((0, "enabled\n"), (1, "enabled\n"), (0, "No unique Hammerspoon checkbox\n"), (0, "")):
            report = {}
            with self.subTest(code=code, stdout=stdout), patch("hs274_accessibility.subprocess.run", side_effect=[
                    SimpleNamespace(returncode=0, stdout="no_sheet", stderr=""),
                    SimpleNamespace(returncode=0), SimpleNamespace(returncode=code, stdout=stdout, stderr="UI detail")]):
                if code == 0 and stdout == "enabled\n":
                    approve_accessibility(report, "owned/Hammerspoon.app")
                else:
                    with self.assertRaisesRegex(RuntimeError, "not confirmed"):
                        approve_accessibility(report, "owned/Hammerspoon.app")
                self.assertEqual(report["hammerspoon_accessibility"], {
                    "stage": "approval", "exit": code, "stdout": stdout, "stderr": "UI detail"})


if __name__ == "__main__":
    unittest.main()
