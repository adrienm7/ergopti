# tools/diagnostics/macos_launch_gate_test.py
"""Prove the packaged launch verdict rejects every failure it exists to catch."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("launch_gate", Path(__file__).with_name("macos_launch_gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

HEALTHY = {
    "launcher_log": "[t] embedded Hammerspoon bootstrap logger configured\n",
    "driver_log": "[SUCCESS] [onboarding] Onboarding wizard opened.\n",
    "alive_after_window": True,
    "quit_seconds": 1.5,
    "state_problems": [],
}


# The fallback boot log line every fatal Lua abort now writes before exiting.
REFUSED_BOOT_LOG = "t [ERROR] [init] FATAL at boot stage 'native_logger_transport': refused\n"


def observe(**changes):
    """Return a healthy observation with only the named criteria changed."""
    observation = dict(HEALTHY)
    observation.update(changes)
    return observation


class VerdictTests(unittest.TestCase):
    """Each criterion must fail on its own, and a healthy launch must pass."""

    def test_healthy_launch_passes(self):
        self.assertEqual(gate.evaluate("clean", observe()), [])

    def test_published_symlink_failure_is_rejected(self):
        # The exact launcher.log of the reported dev.127 failure.
        failures = gate.evaluate("symlink_logs", observe(
            launcher_log="[t] FATAL: Embedded Hammerspoon stopped unexpectedly with exit code 0.\n",
            driver_log="", alive_after_window=False, quit_seconds=None))
        self.assertTrue(any("acknowledged" in failure for failure in failures))
        self.assertTrue(any("FATAL" in failure for failure in failures))
        self.assertTrue(any("no driver log" in failure for failure in failures))

    def test_early_log_without_marker_is_not_startup(self):
        failures = gate.evaluate("clean", observe(driver_log="Path: log file open\n"))
        self.assertEqual(failures, ["the driver log has no completed startup marker"])

    def test_driver_error_invalidates_marker(self):
        failures = gate.evaluate("clean", observe(
            driver_log="Onboarding wizard opened.\n[ERROR] [x] later failure\n"))
        self.assertEqual(len(failures), 1)
        self.assertIn("ERROR", failures[0])

    def test_process_death_after_marker_is_rejected(self):
        failures = gate.evaluate("clean", observe(alive_after_window=False, quit_seconds=None))
        self.assertEqual(len(failures), 2)

    def test_hanging_quit_is_rejected(self):
        failures = gate.evaluate("clean", observe(quit_seconds=None))
        self.assertEqual(failures, [f"Quit did not end both processes within {gate.QUIT_TIMEOUT_SECONDS} s"])

    def test_refused_state_needs_a_named_reason(self):
        generic = observe(
            launcher_log="[t] FATAL: Embedded Hammerspoon stopped unexpectedly with exit code 0.\n",
            boot_log=REFUSED_BOOT_LOG, alive_after_window=False)
        self.assertEqual(len(gate.evaluate("dangling_logs", generic)), 1)
        named = observe(
            launcher_log="[t] FATAL: log folder /u/.config/ergopti_plus/hammerspoon/logs is a "
                         "symbolic link whose target does not exist\n",
            boot_log=REFUSED_BOOT_LOG, alive_after_window=False)
        self.assertEqual(gate.evaluate("dangling_logs", named), [])

    def test_refused_state_must_not_keep_running(self):
        observation = observe(
            launcher_log="FATAL: hammerspoon/logs is a symbolic link to nothing\n",
            boot_log=REFUSED_BOOT_LOG)
        self.assertEqual(len(gate.evaluate("dangling_logs", observation)), 1)

    def test_published_silent_configured_exit_is_rejected(self):
        # The exact dev.128 shape: logger configured, child gone, no FATAL, no dialog.
        failures = gate.evaluate("configured_symlink", observe(
            launcher_log="[t] embedded Hammerspoon bootstrap logger configured\n"
                         "[t] embedded Hammerspoon terminated\n"
                         "[t] applicationWillTerminate; stopping embedded Hammerspoon\n",
            boot_log="[SUCCESS] [config_paths] Config paths initialized\n",
            driver_log="", alive_after_window=False, quit_seconds=None))
        self.assertIn("the refused state produced no FATAL launcher diagnostic", failures)
        self.assertIn("the fatal abort never reached the fallback boot log", failures)

    def test_named_configured_refusal_passes(self):
        failures = gate.evaluate("configured_symlink", observe(
            launcher_log="[t] embedded Hammerspoon FATAL at boot stage 'accessibility': untrusted\n"
                         "[t] FATAL: Embedded Hammerspoon stopped at boot stage 'accessibility': untrusted\n",
            boot_log="t [ERROR] [init] FATAL at boot stage 'accessibility': untrusted\n",
            alive_after_window=False, quit_seconds=None))
        self.assertEqual(failures, [])

    def test_lua_fatal_line_alone_is_not_the_launcher_verdict(self):
        failures = gate.evaluate("configured_symlink", observe(
            launcher_log="[t] embedded Hammerspoon FATAL at boot stage 'accessibility': untrusted\n",
            boot_log="FATAL at boot stage 'accessibility'\n", alive_after_window=False))
        self.assertEqual(failures, ["the refused state produced no FATAL launcher diagnostic"])

    def test_plain_open_launches_like_a_double_click(self):
        app = Path("/Applications/ErgoptiPlus.app")
        self.assertEqual(gate.launch_command("plain_open", app), ["open", str(app)])
        self.assertEqual(gate.launch_command("clean", app), ["open", "-n", str(app)])
        self.assertIn("plain_open", gate.SCENARIOS)
        self.assertIn("configured_symlink", gate.SCENARIOS)


class StateTests(unittest.TestCase):
    """The application must never rewrite the user's own folder layout."""

    def test_configured_state_has_a_completed_config_behind_a_symlink(self):
        self.assertTrue(gate.CONFIG_TEMPLATE.is_file(), gate.CONFIG_TEMPLATE)
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            try:
                state = gate.seed("configured_symlink", home, "", "2026-09-22")
            except OSError as error:
                self.skipTest(f"symbolic links unavailable here: {error}")
            default = home / ".config/ergopti_plus"
            self.assertTrue(default.is_symlink())
            self.assertTrue((default / "config.toml").is_file())
            self.assertEqual(state["symlinks"], [str(default)])

    def test_replaced_symlink_and_unpersisted_tilde_are_reported(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            real = home / "real"
            real.mkdir()
            paths = gate.write_paths_toml(home, "~/gitcfg/ergopti_plus/")
            state = {"symlinks": [str(real)], "paths_toml": paths}
            problems = gate.check_state("tilde_paths", state, home)
            self.assertEqual(len(problems), 2)
            paths.write_text(f'ConfigDirPath = "{home}/gitcfg/ergopti_plus/"\n', encoding="utf-8")
            link = home / "link"
            link.symlink_to(real, target_is_directory=True)
            state["symlinks"] = [str(link)]
            self.assertEqual(gate.check_state("tilde_paths", state, home), [])


if __name__ == "__main__":
    unittest.main()
