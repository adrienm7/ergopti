# tools/diagnostics/macos_launch_gate_test.py
"""Prove the packaged launch verdict rejects every failure it exists to catch."""

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import hs_delayed_timer_probe as timer_probe

spec = importlib.util.spec_from_file_location(
    "launch_gate", Path(__file__).with_name("macos_launch_gate.py")
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def timer_summary():
    """Return the complete admission receipt produced by the native judge."""
    return {
        "schema_version": 1,
        "contract": timer_probe.CONTRACT["contract"],
        "runtime": "native Hammerspoon",
        "version": timer_probe.CONTRACT["runtime_version"],
        "complete": True,
        "checks": timer_probe.CHECK_COUNT,
        "nonce": "a" * 32,
        "pid": 42,
        "executable": "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon",
        "preference_restored": True,
    }


HEALTHY = {
    "launcher_log": "[t] embedded Hammerspoon bootstrap logger configured\n",
    "driver_log": "[SUCCESS] [onboarding] Onboarding wizard opened.\n",
    "alive_after_window": True,
    "quit_seconds": 1.5,
    "state_problems": [],
    "native_delayed_timer": timer_summary(),
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

    def test_clean_launch_requires_native_timer_evidence(self):
        for value in (
            None,
            {},
            dict(timer_summary(), complete=False),
            dict(timer_summary(), preference_restored=False),
        ):
            with self.subTest(value=value):
                failures = gate.evaluate("clean", observe(native_delayed_timer=value))
                self.assertTrue(any("native delayed-timer" in failure for failure in failures))

    def test_clean_launch_retains_native_probe_refusal(self):
        failures = gate.evaluate("clean", observe(native_delayed_timer_error="scripting refused"))
        self.assertTrue(any("scripting refused" in failure for failure in failures))

    def test_cli_annotates_the_failure_cause_without_weakening_its_exit(self):
        cause = "native scripting refused: 50%\r\n::notice::foreign text"
        report = {"failures": [cause]}
        with tempfile.TemporaryDirectory(prefix="ergopti-native-annotation-") as root:
            output = Path(root) / "evidence"
            stdout = io.StringIO()
            with (
                mock.patch.object(gate.sys, "platform", "darwin"),
                mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                mock.patch.object(gate, "run", return_value=report),
                mock.patch.object(gate, "print_tails"),
                contextlib.redirect_stdout(stdout),
            ):
                status = gate.main(["/Applications/ErgoptiPlus.app", str(output), "clean"])
            self.assertEqual(status, 1, "annotating a cause must retain the negative verdict")
            self.assertEqual(
                stdout.getvalue().splitlines(),
                [
                    "::error::macOS launch gate [clean] failed",
                    "::error::native scripting refused: 50%25%0D%0A::notice::foreign text",
                ],
            )
            self.assertEqual(json.loads((output / "result.json").read_text())["failures"], [cause])

    def test_healthy_launch_passes(self):
        self.assertEqual(gate.evaluate("clean", observe()), [])

    def test_window_timeout_does_not_discard_other_native_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder) / "home"
            home.mkdir()
            output = Path(folder) / "output"
            output.mkdir()
            calls = []

            def native_run(arguments, **options):
                calls.append(arguments[0])
                if arguments[0] == "osascript":
                    raise subprocess.TimeoutExpired(arguments, options["timeout"])
                return subprocess.CompletedProcess(arguments, 0, "retained native evidence", "")

            with mock.patch.object(gate.subprocess, "run", side_effect=native_run):
                errors = gate.collect(output, {"logs_dir": home / "missing-logs"}, home)
            self.assertEqual(len(errors), 1)
            self.assertIn("TimeoutExpired", errors[0])
            self.assertIn("TimeoutExpired", (output / "windows.txt").read_text())
            self.assertIn(
                "log", calls, "the window timeout must not prevent unified-log collection"
            )
            self.assertEqual((output / "unified.log").read_text(), "retained native evidence")

    def test_quit_and_collection_failures_still_write_primary_report(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder) / "home"
            app = Path(folder) / "ErgoptiPlus.app"
            for executable in (
                app / "Contents/MacOS/ErgoptiPlus",
                timer_probe.NativeDelayedTimerProbe.executable_path(app),
            ):
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text("owned fixture executable")
            with (app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": "com.ergoptiplus.app"}, handle)
            live = {"started": False}
            killed = []

            def processes(executable):
                return [42 if executable.name == "Hammerspoon" else 41] if live["started"] else []

            def native_run(arguments, **options):
                if arguments[0] == "open":
                    live["started"] = True
                return subprocess.CompletedProcess(arguments, 0, "arm64", "")

            with (
                mock.patch.object(gate.sys, "platform", "darwin"),
                mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                mock.patch.object(gate.Path, "home", return_value=home),
                mock.patch.object(
                    gate, "seed", return_value={"logs_dir": home / "logs", "symlinks": []}
                ),
                mock.patch.object(gate, "processes", side_effect=processes),
                mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                mock.patch.object(gate, "STARTUP_TIMEOUT_SECONDS", 0),
                mock.patch.object(gate, "read_text", return_value=HEALTHY["launcher_log"]),
                mock.patch.object(gate, "driver_logs", return_value=HEALTHY["driver_log"]),
                mock.patch.object(gate, "check_state", return_value=[]),
                mock.patch.object(
                    gate, "quit_application", side_effect=RuntimeError("original quit failure")
                ),
                mock.patch.object(
                    gate, "collect", side_effect=RuntimeError("independent collection failure")
                ),
                mock.patch.object(gate.os, "kill", side_effect=lambda pid, _: killed.append(pid)),
                mock.patch.object(gate, "print_tails"),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                status = gate.main([str(app), str(Path(folder) / "evidence"), "symlink_logs_dir"])
            report = json.loads((Path(folder) / "evidence/result.json").read_text())
            self.assertEqual(status, 1)
            self.assertIn("RuntimeError: original quit failure", report["failures"])
            self.assertTrue(
                any("independent collection failure" in error for error in report["failures"])
            )
            self.assertEqual(
                sorted(killed),
                [41, 42],
                "failed evidence collection must still stop both exact processes",
            )

    def test_published_symlink_failure_is_rejected(self):
        # The exact launcher.log of the reported dev.127 failure.
        failures = gate.evaluate(
            "symlink_logs",
            observe(
                launcher_log="[t] FATAL: Embedded Hammerspoon stopped unexpectedly with exit code 0.\n",
                driver_log="",
                alive_after_window=False,
                quit_seconds=None,
            ),
        )
        self.assertTrue(any("acknowledged" in failure for failure in failures))
        self.assertTrue(any("FATAL" in failure for failure in failures))
        self.assertTrue(any("no driver log" in failure for failure in failures))

    def test_environment_key_named_fatal_is_not_a_fatal_line(self):
        # The boot log lists the launcher environment, which has ERGOPTI_FATAL_REPORT_FILE.
        healthy = observe()
        failures = gate.evaluate(
            "clean",
            observe(
                launcher_log=healthy["launcher_log"]
                + "[t] embedded Hammerspoon boot INFO: Launcher environment keys present: "
                "ERGOPTI_CONFIG_DIR, ERGOPTI_FATAL_REPORT_FILE.\n"
            ),
        )
        self.assertEqual(failures, [])

    def test_early_log_without_marker_is_not_startup(self):
        failures = gate.evaluate("clean", observe(driver_log="Path: log file open\n"))
        self.assertEqual(failures, ["the driver log has no completed startup marker"])

    def test_driver_error_invalidates_marker(self):
        failures = gate.evaluate(
            "clean", observe(driver_log="Onboarding wizard opened.\n[ERROR] [x] later failure\n")
        )
        self.assertEqual(len(failures), 1)
        self.assertIn("ERROR", failures[0])

    def test_process_death_after_marker_is_rejected(self):
        failures = gate.evaluate("clean", observe(alive_after_window=False, quit_seconds=None))
        self.assertEqual(len(failures), 2)

    def test_hanging_quit_is_rejected(self):
        failures = gate.evaluate("clean", observe(quit_seconds=None))
        self.assertEqual(
            failures, [f"Quit did not end both processes within {gate.QUIT_TIMEOUT_SECONDS} s"]
        )

    def test_refused_state_needs_a_named_reason(self):
        generic = observe(
            launcher_log="[t] FATAL: Embedded Hammerspoon stopped unexpectedly with exit code 0.\n",
            boot_log=REFUSED_BOOT_LOG,
            alive_after_window=False,
        )
        self.assertEqual(len(gate.evaluate("dangling_logs", generic)), 1)
        named = observe(
            launcher_log="[t] FATAL: log folder /u/gitcfg/ergopti_plus is a "
            "symbolic link whose target does not exist\n",
            boot_log=REFUSED_BOOT_LOG,
            alive_after_window=False,
        )
        self.assertEqual(gate.evaluate("dangling_logs", named), [])

    def test_refused_state_must_not_keep_running(self):
        observation = observe(
            launcher_log="FATAL: gitcfg/ergopti_plus is a symbolic link to nothing\n",
            boot_log=REFUSED_BOOT_LOG,
        )
        self.assertEqual(len(gate.evaluate("dangling_logs", observation)), 1)

    def test_published_silent_configured_exit_is_rejected(self):
        # The exact dev.128 shape: logger configured, child gone, no FATAL, no dialog.
        failures = gate.evaluate(
            "configured_symlink",
            observe(
                launcher_log="[t] embedded Hammerspoon bootstrap logger configured\n"
                "[t] embedded Hammerspoon terminated\n"
                "[t] applicationWillTerminate; stopping embedded Hammerspoon\n",
                boot_log="[SUCCESS] [config_paths] Config paths initialized\n",
                driver_log="",
                alive_after_window=False,
                quit_seconds=None,
            ),
        )
        self.assertIn("no driver log appeared under the configured logs folder", failures)
        self.assertIn(
            "the launcher and embedded Hammerspoon did not both survive the observation window",
            failures,
        )

    def test_configured_boot_waits_for_accessibility(self):
        waiting = observe(
            driver_log="[INFO] [accessibility_wait] Waiting for the Accessibility "
            "permission (up to 600 s)…\n"
        )
        self.assertEqual(gate.evaluate("configured_symlink", waiting), [])
        self.assertEqual(gate.ready_marker("clean"), gate.READY_MARKER)

    def test_configured_accessibility_exit_is_rejected(self):
        # The dev.141 shape: a named FATAL exit that sent the user to relaunch.
        failures = gate.evaluate(
            "configured_symlink",
            observe(
                launcher_log="[t] embedded Hammerspoon bootstrap logger configured\n"
                "[t] FATAL: Embedded Hammerspoon stopped at boot stage 'accessibility': untrusted\n",
                boot_log="t [ERROR] [init] FATAL at boot stage 'accessibility': untrusted\n",
                driver_log="",
                alive_after_window=False,
                quit_seconds=None,
            ),
        )
        self.assertTrue(any("FATAL" in failure for failure in failures))
        self.assertTrue(any("survive" in failure for failure in failures))

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
            synced_home = home / "synced"
            dangling_home = home / "dangling"
            try:
                synced = gate.seed("symlink_logs_dir", synced_home, "", "2026-09-24")
                dangling = gate.seed("dangling_logs", dangling_home, "", "2026-09-24")
            except OSError as error:
                self.skipTest(f"symbolic links unavailable here: {error}")
            self.assertNotEqual(synced["paths_toml"], dangling["paths_toml"])
            self.assertEqual(synced["logs_dir"], synced_home / "SyncedLogs/ergopti_plus")
            self.assertIn(
                f'LogsDirPath = "{synced_home}/SyncedLogs"',
                synced["paths_toml"].read_text(encoding="utf-8"),
            )
            self.assertIn(
                f'LogsDirPath = "{dangling_home}/gitcfg/ergopti_plus"',
                dangling["paths_toml"].read_text(encoding="utf-8"),
            )
            self.assertTrue((synced_home / "SyncedLogs").is_symlink())
            self.assertTrue((dangling_home / "gitcfg/ergopti_plus").is_symlink())
            self.assertFalse((dangling_home / "gitcfg/ergopti_plus").exists())
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


# Keep independent oracles for every approved scenario, including the picked
# logs-directory link added when launcher and driver log ownership converged.
CI_PROFILE = [
    "clean",
    "upgraded",
    "symlink_config",
    "symlink_hammerspoon",
    "symlink_logs",
    "symlink_logs_dir",
    "tilde_paths",
    "dangling_logs",
    "configured_symlink",
    "plain_open",
]
RELEASE_PROFILE = [
    "clean",
    "upgraded",
    "source_logs",
    "symlink_config",
    "symlink_config_documents",
    "symlink_hammerspoon",
    "symlink_logs",
    "symlink_logs_dir",
    "tilde_paths",
    "dangling_logs",
    "configured_symlink",
    "plain_open",
]
SCRIPT = Path(__file__).with_name("macos_launch_gate.py")


def print_matrix(*arguments):
    """Run the matrix mode the way the workflow does, outside GitHub Actions."""
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_ACTIONS"}
    return subprocess.run(
        [sys.executable, str(SCRIPT), *arguments],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )


class ProfileTests(unittest.TestCase):
    """The workflow's launch matrix comes from these profiles alone, so they must not drift."""

    def test_ci_profile_keeps_the_approved_gated_scenarios(self):
        self.assertEqual(
            list(gate.PROFILES["ci"]),
            CI_PROFILE,
            "the CI launch profile changed; update CI_PROFILE only for a deliberate change",
        )

    def test_release_profile_launches_every_scenario(self):
        self.assertEqual(gate.PROFILES["release"], gate.SCENARIOS)
        self.assertEqual(
            list(gate.SCENARIOS),
            RELEASE_PROFILE,
            "the release scenarios changed; update this oracle only for a deliberate change",
        )

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
        for arguments in (
            ("--print-matrix", "nightly"),
            ("--print-matrix", "ci", "/Applications/ErgoptiPlus.app"),
            ("--print-matrix", "release", "--seed-tag", "v0.0.0-dev.24"),
        ):
            result = print_matrix(*arguments)
            self.assertEqual(result.returncode, 2, arguments)
            self.assertEqual(result.stdout, "", arguments)

    def test_launch_mode_still_needs_all_its_arguments(self):
        result = print_matrix("/Applications/ErgoptiPlus.app", "evidence")
        self.assertEqual(result.returncode, 2)
        self.assertIn("app, output and scenario", result.stderr)


def load_tests(loader, tests, pattern):
    """Keep native receipt and preference checks in the existing package self-test."""
    import hs_delayed_timer_probe_test

    tests.addTests(loader.loadTestsFromModule(hs_delayed_timer_probe_test))
    return tests


if __name__ == "__main__":
    unittest.main()
