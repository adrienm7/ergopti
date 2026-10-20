#!/usr/bin/env python3
# tools/diagnostics/macos_launch_reset_test.py
"""Portable controls of the launch reset between two scenarios of one job.

A fake system answers the defaults, launchctl and ps commands, so these run on
any host; the launch job runs them before it records the fresh runner.
"""

import json
from pathlib import Path
import signal
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macos_launch_reset as reset  # noqa: E402


class FakeSystem:
    """The preference daemon, launchd and the process table of one runner."""

    def __init__(self, application):
        self.application = application
        self.domains = {"com.apple.finder", "NSGlobalDomain"}
        self.labels = {"com.apple.Finder"}
        self.pids = {}
        self.commands = []
        self.stubborn = False

    def __call__(self, command):
        self.commands.append(command)
        if command == ["defaults", "domains"]:
            return ", ".join(sorted(self.domains)) + "\n"
        if command[:2] == ["defaults", "delete"]:
            self.domains.discard(command[2])
            return ""
        if command == ["launchctl", "list"]:
            rows = ["PID\tStatus\tLabel"] + [f"-\t0\t{label}" for label in sorted(self.labels)]
            return "\n".join(rows) + "\n"
        if command[:2] == ["launchctl", "remove"]:
            self.labels.discard(command[2])
            return ""
        if command == ["ps", "-axo", "pid=,command="]:
            return "".join(f"{pid} {path}\n" for pid, path in sorted(self.pids.items()))
        raise AssertionError(f"Unexpected command {command}")

    def kill(self, pid, sent):
        assert sent == signal.SIGKILL
        if not self.stubborn:
            self.pids.pop(pid, None)


class LaunchResetControls(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        root = Path(self.scratch.name)
        self.home = root / "home"
        for folder in (".config", "Documents", "Library/Logs", "Library/Preferences"):
            (self.home / folder).mkdir(parents=True)
        (self.home / ".config/gh").mkdir()
        (self.home / "Documents/notes.txt").write_text("user file\n", encoding="utf-8")
        self.application = root / "Applications/ErgoptiPlus.app"
        self.application.parent.mkdir()
        self.system = FakeSystem(self.application)
        self.record = root / "fresh.json"
        reset.snapshot(self.record, self.home, self.system, self.application)

    def tearDown(self):
        self.scratch.cleanup()

    def restore(self):
        return reset.restore(
            self.record,
            self.home,
            self.system,
            self.application,
            killer=self.system.kill,
            sleep=lambda seconds: None,
        )

    def leave_a_scenario_behind(self):
        """What one install, seeded state and launch leave on the runner."""
        (self.application / "Contents/MacOS").mkdir(parents=True)
        (self.application / "Contents/MacOS/ErgoptiPlus").write_text("", encoding="utf-8")
        (self.home / "gitcfg/ergopti_plus/hammerspoon").mkdir(parents=True)
        (self.home / ".config/ergopti_plus").symlink_to(
            self.home / "gitcfg/ergopti_plus", target_is_directory=True
        )
        (self.home / "Documents/GitHub/config").mkdir(parents=True)
        (self.home / "Library/Logs/ergopti_plus").mkdir()
        (self.home / "Library/Logs/ergopti_plus/launcher.log").write_text("x\n", encoding="utf-8")
        (self.home / "Library/Preferences/com.ergoptiplus.app.plist").write_text(
            "", encoding="utf-8"
        )
        self.system.domains |= {"com.ergoptiplus.app.hammerspoon", "com.ergoptiplus.app"}
        self.system.labels.add("com.ergoptiplus.remap-guardian")
        self.system.pids[4242] = f"{self.application}/Contents/MacOS/ErgoptiPlus --child"

    def test_snapshot_records_the_fresh_runner_once(self):
        fresh = json.loads(self.record.read_text(encoding="utf-8"))
        self.assertEqual(fresh["schema"], 1)
        self.assertIn(".config/gh", fresh["entries"])
        self.assertFalse(fresh["application"])
        with self.assertRaises(FileExistsError):
            reset.snapshot(self.record, self.home, self.system, self.application)

    def test_snapshot_refuses_a_runner_that_already_holds_the_application(self):
        self.application.mkdir()
        with self.assertRaisesRegex(RuntimeError, "already holds"):
            reset.snapshot(
                Path(self.scratch.name) / "other.json", self.home, self.system, self.application
            )

    def test_restore_removes_every_owned_leftover_and_keeps_user_files(self):
        self.leave_a_scenario_behind()
        report = self.restore()
        self.assertFalse(self.application.exists())
        for gone in (
            "gitcfg",
            ".config/ergopti_plus",
            "Documents/GitHub",
            "Library/Logs/ergopti_plus",
        ):
            self.assertFalse((self.home / gone).exists() or (self.home / gone).is_symlink(), gone)
        self.assertTrue((self.home / "Documents/notes.txt").is_file())
        self.assertTrue((self.home / ".config/gh").is_dir())
        self.assertEqual(self.system.pids, {})
        self.assertNotIn("com.ergoptiplus.app", self.system.domains)
        self.assertNotIn("com.ergoptiplus.remap-guardian", self.system.labels)
        self.assertIn("defaults:com.ergoptiplus.app.hammerspoon", report["removed"])
        # A symbolic link is removed, never followed into its target.
        self.assertEqual(report["foreign_unowned"], [])

    def test_preferences_leave_through_the_daemon_before_their_files(self):
        self.leave_a_scenario_behind()
        plist = self.home / "Library/Preferences/com.ergoptiplus.app.plist"
        seen = []
        real = self.system.__call__

        def observed(command):
            if command[:2] == ["defaults", "delete"]:
                seen.append(plist.exists())
            return real(command)

        reset.restore(
            self.record,
            self.home,
            observed,
            self.application,
            killer=self.system.kill,
            sleep=lambda seconds: None,
        )
        self.assertEqual(seen, [True, True])
        self.assertFalse(plist.exists())

    def test_a_second_scenario_starts_from_the_same_fresh_state(self):
        for _ in range(2):
            self.leave_a_scenario_behind()
            self.restore()
        after = reset.state(self.home, self.system, self.application)
        fresh = json.loads(self.record.read_text(encoding="utf-8"))
        self.assertEqual(after, fresh)

    def test_unowned_new_entries_are_reported_never_removed(self):
        (self.home / "Library/Logs/DiagnosticReports").mkdir()
        report = self.restore()
        self.assertEqual(report["foreign_unowned"], ["Library/Logs/DiagnosticReports"])
        self.assertTrue((self.home / "Library/Logs/DiagnosticReports").is_dir())

    def test_a_surviving_process_refuses(self):
        self.leave_a_scenario_behind()
        self.system.stubborn = True
        bound = reset.QUIT_TIMEOUT_SECONDS
        reset.QUIT_TIMEOUT_SECONDS = 0
        try:
            with self.assertRaisesRegex(RuntimeError, "survived"):
                self.restore()
        finally:
            reset.QUIT_TIMEOUT_SECONDS = bound

    def test_an_irremovable_leftover_refuses(self):
        self.leave_a_scenario_behind()
        real = self.system.__call__

        def sticky(command):
            if command[:2] == ["defaults", "delete"]:
                return ""
            return real(command)

        with self.assertRaisesRegex(RuntimeError, "leftovers=.*com.ergoptiplus.app"):
            reset.restore(
                self.record,
                self.home,
                sticky,
                self.application,
                killer=self.system.kill,
                sleep=lambda seconds: None,
            )

    def test_a_vanished_owned_baseline_entry_refuses(self):
        self.restore()
        (self.home / "Library/Logs/ergopti_plus").mkdir()
        record = Path(self.scratch.name) / "with-logs.json"
        reset.snapshot(record, self.home, self.system, self.application)
        (self.home / "Library/Logs/ergopti_plus").rmdir()
        with self.assertRaisesRegex(RuntimeError, "missing=.*ergopti_plus"):
            reset.restore(record, self.home, self.system, self.application, killer=self.system.kill)

    def test_a_record_of_another_home_refuses(self):
        with self.assertRaisesRegex(RuntimeError, "another home"):
            reset.restore(self.record, self.home / "other", self.system, self.application)


if __name__ == "__main__":
    unittest.main()
