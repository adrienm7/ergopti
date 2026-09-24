# tools/diagnostics/macos_launch_gate_test.py
"""Prove the packaged launch verdict rejects every failure it exists to catch."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
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

    def test_environment_key_named_fatal_is_not_a_fatal_line(self):
        # The boot log lists the launcher environment, which has ERGOPTI_FATAL_REPORT_FILE.
        healthy = observe()
        failures = gate.evaluate("clean", observe(launcher_log=healthy["launcher_log"]
            + "[t] embedded Hammerspoon boot INFO: Launcher environment keys present: "
            "ERGOPTI_CONFIG_DIR, ERGOPTI_FATAL_REPORT_FILE.\n"))
        self.assertEqual(failures, [])

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
            launcher_log="[t] FATAL: log folder /u/gitcfg/ergopti_plus is a "
                         "symbolic link whose target does not exist\n",
            boot_log=REFUSED_BOOT_LOG, alive_after_window=False)
        self.assertEqual(gate.evaluate("dangling_logs", named), [])

    def test_refused_state_must_not_keep_running(self):
        observation = observe(
            launcher_log="FATAL: gitcfg/ergopti_plus is a symbolic link to nothing\n",
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
            self.assertTrue((default / "hammerspoon/config.toml").is_file())
            self.assertEqual(state["symlinks"], [str(default)])

    def test_logs_scenarios_seed_logs_dir_path(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            try:
                synced = gate.seed("symlink_logs_dir", home, "", "2026-09-24")
                dangling = gate.seed("dangling_logs", home, "", "2026-09-24")
            except OSError as error:
                self.skipTest(f"symbolic links unavailable here: {error}")
            self.assertEqual(synced["logs_dir"], home / "SyncedLogs/ergopti_plus")
            self.assertIn(f'LogsDirPath = "{home}/SyncedLogs"',
                synced["paths_toml"].read_text(encoding="utf-8"))
            self.assertIn(f'LogsDirPath = "{home}/gitcfg/ergopti_plus"',
                dangling["paths_toml"].read_text(encoding="utf-8"))
            self.assertIn("symlink_logs_dir", gate.SCENARIOS)
            self.assertEqual(gate.logs_folder(home), home / "Library/Logs/ergopti_plus")

    def test_picked_logs_folder_losing_its_permissions_is_reported(self):
        if os.name != "posix":
            self.skipTest("POSIX permission bits are unavailable here")
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            picked = home / "picked"
            picked.mkdir()
            picked.chmod(0o755)
            state = {"symlinks": [], "foreign_folder": (picked, 0o755)}
            self.assertEqual(gate.check_state("symlink_logs_dir", state, home), [])
            state["foreign_folder"] = (picked, 0o700)
            self.assertEqual(len(gate.check_state("symlink_logs_dir", state, home)), 1)

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
            try:
                link.symlink_to(real, target_is_directory=True)
            except OSError as error:
                # Only Windows refuses an unprivileged symbolic link. On the macOS
                # job that runs this self-test, a failure here is a real error.
                if sys.platform != "win32":
                    raise
                self.skipTest(f"symbolic links unavailable here: {error}")
            state["symlinks"] = [str(link)]
            self.assertEqual(gate.check_state("tilde_paths", state, home), [])


# The nine scenarios the pull-request and plain-push gate launched before the
# profiles moved into the script (the scenario list in ci.yml at ca1a4d64a).
CI_PROFILE = [
    "clean", "upgraded", "symlink_config", "symlink_hammerspoon", "symlink_logs",
    "tilde_paths", "dangling_logs", "configured_symlink", "plain_open",
]
SCRIPT = Path(__file__).with_name("macos_launch_gate.py")


def print_matrix(*arguments):
    """Run the matrix mode the way the workflow does, outside GitHub Actions."""
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_ACTIONS"}
    return subprocess.run([sys.executable, str(SCRIPT), *arguments], capture_output=True, text=True,
        env=env, timeout=60)


class ProfileTests(unittest.TestCase):
    """The workflow's launch matrix comes from these profiles alone, so they must not drift."""

    def test_ci_profile_keeps_the_nine_gated_scenarios(self):
        self.assertEqual(list(gate.PROFILES["ci"]), CI_PROFILE,
            "the CI launch profile changed; update CI_PROFILE only for a deliberate change")

    def test_release_profile_launches_every_scenario(self):
        self.assertEqual(gate.PROFILES["release"], gate.SCENARIOS)
        self.assertEqual(len(gate.SCENARIOS), 11,
            "the scenario count changed; update this pin only for a deliberate change")

    def test_ci_profile_is_a_strict_subset_of_release(self):
        self.assertLess(set(gate.PROFILES["ci"]), set(gate.PROFILES["release"]))
        self.assertLessEqual(set(gate.RELEASE_ONLY_SCENARIOS), set(gate.SCENARIOS))

    def test_print_matrix_emits_one_output_line_off_macos(self):
        # GITHUB_ACTIONS is removed, so the launch guard would refuse this run
        # on every host if the matrix mode reached it.
        for profile in ("ci", "release"):
            result = print_matrix("--print-matrix", profile)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 1, result.stdout)
            key, _, value = lines[0].partition("=")
            self.assertEqual(key, "scenarios")
            self.assertEqual(json.loads(value), list(gate.PROFILES[profile]))

    def test_print_matrix_rejects_unknown_profiles_and_launch_arguments(self):
        for arguments in (("--print-matrix", "nightly"), ("--print-matrix", "ci", "/Applications/ErgoptiPlus.app"),
                ("--print-matrix", "release", "--seed-tag", "v0.0.0-dev.24")):
            result = print_matrix(*arguments)
            self.assertEqual(result.returncode, 2, arguments)
            self.assertEqual(result.stdout, "", arguments)

    def test_launch_mode_still_needs_all_its_arguments(self):
        result = print_matrix("/Applications/ErgoptiPlus.app", "evidence")
        self.assertEqual(result.returncode, 2)
        self.assertIn("app, output and scenario", result.stderr)


if __name__ == "__main__":
    unittest.main()
