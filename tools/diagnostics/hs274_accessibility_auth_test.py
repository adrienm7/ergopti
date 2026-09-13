# tools/diagnostics/hs274_accessibility_auth_test.py
"""Exercise authentication error handling without native credentials or UI."""
from contextlib import contextmanager
from types import SimpleNamespace
import subprocess
import unittest
from unittest.mock import patch

from hs274_accessibility_auth import authenticate_accessibility


class AuthenticationTests(unittest.TestCase):
    def exercise(self, response):
        report, lifecycle = {}, []

        @contextmanager
        def account(output, state):
            lifecycle.append("created")
            try:
                yield "fixture-user", "fixture-secret"
            finally:
                lifecycle.append("removed")

        with patch.dict("os.environ", {"RUNNER_TEMP": "fixture-output"}), \
                patch("hs274_accessibility_auth.approval_account", account), \
                patch("hs274_accessibility_auth.subprocess.run", side_effect=[response]) as run:
            with self.assertRaises(RuntimeError) as failure:
                authenticate_accessibility(report)
        self.assertEqual(lifecycle, ["created", "removed"])
        self.assertNotIn("fixture-secret", str(report) + str(failure.exception) + str(run.call_args.args))
        self.assertEqual(run.call_args.kwargs["env"]["HS274_APPROVAL_PASSWORD"], "fixture-secret")
        return report["hammerspoon_accessibility_authentication"]

    def test_rejection_redacts_receipt_and_retires_account(self):
        state = self.exercise(SimpleNamespace(returncode=1, stdout="fixture-secret", stderr="denied fixture-secret"))
        self.assertEqual(state, {"exit": 1, "stdout": "<redacted>", "stderr": "denied <redacted>"})

    def test_timeout_retires_account_without_exposing_partial_credentials(self):
        state = self.exercise(subprocess.TimeoutExpired("osascript", 10, output="fixture-secret"))
        self.assertEqual(state, {"timed_out": True})


if __name__ == "__main__":
    unittest.main()
