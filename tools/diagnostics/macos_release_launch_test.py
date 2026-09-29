# tools/diagnostics/macos_release_launch_test.py
"""Reject the early-log false green observed in the published macOS application."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_launch", Path(__file__).with_name("macos-release-launch.py"))
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class StartupReadinessTests(unittest.TestCase):
    """Both real startup branches need their own completed operation receipt."""

    def test_published_failure_does_not_count_as_readiness(self):
        with self.assertRaisesRegex(RuntimeError, "never completed"):
            observer.require_startup_ready(
                "Path: log file open (retention purge deferred)\n"
                "Native asynchronous logger transport unavailable: "
                "LuaSocket UDP bootstrap capability is unavailable."
            )

    def test_opening_wizard_does_not_mean_it_opened(self):
        with self.assertRaisesRegex(RuntimeError, "never completed"):
            observer.require_startup_ready("Opening onboarding wizard...")

    def test_first_install_accepts_completed_onboarding(self):
        marker = "Onboarding wizard opened."
        self.assertEqual(observer.require_startup_ready(marker), marker)

    def test_later_javascript_error_invalidates_opened_wizard(self):
        with self.assertRaisesRegex(RuntimeError, "Lua error"):
            observer.require_startup_ready(
                "Onboarding wizard opened.\n"
                "[ERROR] [onboarding] Onboarding JavaScript execution failed."
            )

    def test_existing_configuration_accepts_completed_runtime(self):
        marker = "User interface initialized successfully."
        self.assertEqual(observer.require_startup_ready(marker), marker)


class FailureEvidenceTests(unittest.TestCase):
    """A failed launch must explain itself in the job log, not only the artifact."""

    def test_names_the_failure_and_the_error_lines(self):
        with tempfile.TemporaryDirectory() as folder:
            logs = Path(folder)
            (logs / "ErgoptiPlus_boot.log").write_text(
                "[INFO] booting\n[ERROR] [llm] Profile catalogue failed.\n", encoding="utf-8")
            (logs / "launcher.log").write_text("FATAL: child exited\n", encoding="utf-8")
            lines = observer.failure_evidence({"error": "RuntimeError: boom"}, logs)
        self.assertEqual(lines[0], "release launch failed: RuntimeError: boom")
        self.assertIn("ErgoptiPlus_boot.log: [ERROR] [llm] Profile catalogue failed.", lines)
        self.assertIn("launcher.log: FATAL: child exited", lines)
        self.assertNotIn("ErgoptiPlus_boot.log: [INFO] booting", lines)

    def test_caps_a_noisy_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            logs = Path(folder)
            (logs / "a.log").write_text("[ERROR] x\n" * 500, encoding="utf-8")
            lines = observer.failure_evidence({"error": "RuntimeError: boom"}, logs)
        self.assertEqual(len(lines), observer.MAX_EVIDENCE_LINES)

    def test_missing_log_folder_still_names_the_failure(self):
        lines = observer.failure_evidence({"error": "RuntimeError: boom"}, Path("/nonexistent/ergopti"))
        self.assertEqual(lines, ["release launch failed: RuntimeError: boom"])


if __name__ == "__main__":
    unittest.main()
