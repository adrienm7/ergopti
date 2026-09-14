# tools/diagnostics/macos_release_launch_test.py
"""Reject the early-log false green observed in the published macOS application."""

import importlib.util
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
