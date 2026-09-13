# tools/diagnostics/hs274_accessibility_diagnostics_test.py
"""Exercise diagnostic ownership, bounded receipts and independent failures."""
from pathlib import Path
import plistlib
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import subprocess
import unittest
from unittest.mock import patch

from hs274_accessibility_diagnostics import OUTPUT_LIMIT, retain_failure


class DiagnosticTests(unittest.TestCase):
    def test_invalid_bundle_does_not_query_native_services(self):
        with TemporaryDirectory() as root, patch("hs274_accessibility_diagnostics.subprocess.run") as run:
            report = {}
            retain_failure(report, root)
            self.assertIn("bundle_error", report["hammerspoon_admission_diagnostics"])
            run.assert_not_called()

    def test_retains_identity_and_independent_errors_with_bounded_output(self):
        with TemporaryDirectory() as root:
            app = Path(root) / "Hammerspoon.app"
            executable = app / "Contents/MacOS/Hammerspoon"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "fixture.identity"}))
            responses = [SimpleNamespace(returncode=1, stdout="", stderr="invalid signature"),
                         subprocess.TimeoutExpired("codesign", 5,
                                                   output=b"x" * OUTPUT_LIMIT + b"partial identity",
                                                   stderr=b"native refusal\xff"),
                         SimpleNamespace(returncode=0, stdout="x" * OUTPUT_LIMIT + "refusal", stderr="")]
            report = {"primary_error": "approval refused"}
            with patch("hs274_accessibility_diagnostics.subprocess.run", side_effect=responses) as run:
                retain_failure(report, app)
            evidence = report["hammerspoon_admission_diagnostics"]
            self.assertEqual(evidence["bundle"]["CFBundleIdentifier"], "fixture.identity")
            self.assertEqual(evidence["signature_verify"]["exit"], 1)
            self.assertIn("TimeoutExpired", evidence["signature_identity"]["error"])
            self.assertEqual(len(evidence["signature_identity"]["stdout"]), OUTPUT_LIMIT)
            self.assertTrue(evidence["signature_identity"]["stdout"].endswith("partial identity"))
            self.assertEqual(evidence["signature_identity"]["stderr"], "native refusal\ufffd")
            self.assertTrue(evidence["signature_identity"]["truncated"])
            self.assertTrue(evidence["signature_identity"]["timed_out"])
            self.assertNotIn("exit", evidence["signature_identity"])
            self.assertTrue(evidence["tcc"]["truncated"])
            self.assertEqual(len(evidence["tcc"]["stdout"]), OUTPUT_LIMIT)
            self.assertTrue(evidence["tcc"]["stdout"].endswith("refusal"))
            self.assertEqual(report["primary_error"], "approval refused")
            self.assertEqual(run.call_count, 3)
            self.assertEqual(run.call_args_list[0].args[0][-1], str(app.resolve()))
            self.assertTrue(all(call.kwargs["timeout"] == 5 for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()
