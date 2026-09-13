# tools/diagnostics/hs274_accessibility_test.py
"""Keep UI approval failures visible independently of native trust verification."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from hs274_accessibility import approve_accessibility


class ApprovalTests(unittest.TestCase):
    def test_requires_exact_success_and_retains_raw_failure_evidence(self):
        for code, stdout in ((0, "enabled\n"), (1, "enabled\n"), (0, "No unique Hammerspoon checkbox\n"), (0, "")):
            report = {}
            with self.subTest(code=code, stdout=stdout), patch("hs274_accessibility.subprocess.run", side_effect=[
                    SimpleNamespace(returncode=0), SimpleNamespace(returncode=code, stdout=stdout, stderr="UI detail")]):
                if code == 0 and stdout == "enabled\n":
                    approve_accessibility(report)
                else:
                    with self.assertRaisesRegex(RuntimeError, "not confirmed"):
                        approve_accessibility(report)
                self.assertEqual(report["hammerspoon_accessibility"], {"exit": code, "stdout": stdout, "stderr": "UI detail"})


if __name__ == "__main__":
    unittest.main()
