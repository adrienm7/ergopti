#!/usr/bin/env python3
# tests/hardware/test_atspi_fixture_lifetime.py

"""Check the editor's bounded lifetime without requiring a graphical desktop."""

import pathlib
import runpy
import sys
import tempfile
import types
import unittest
from unittest import mock


class FixtureLifetimeTest(unittest.TestCase):
    """Keep standalone defaults and the longer daemon host lifetime distinct."""

    def launch(self, arguments):
        observations = {}

        class Widget:
            def __init__(self, **kwargs):
                observations.update(kwargs)

            def __getattr__(self, name):
                return lambda *args: observations.update({name: args})

        def timeout(milliseconds, callback):
            observations["lifetime"] = milliseconds / 1000

        def timeout_seconds(seconds, callback):
            observations["lifetime"] = seconds

        gi = types.ModuleType("gi")
        gi.require_version = lambda *args: None
        repository = types.ModuleType("gi.repository")
        repository.Gtk = types.SimpleNamespace(
            Window=Widget, Entry=Widget, main=lambda: None, main_quit=lambda: None
        )
        repository.GLib = types.SimpleNamespace(
            timeout_add=timeout, timeout_add_seconds=timeout_seconds
        )
        script = pathlib.Path(__file__).with_name("atspi_fixture_app.py")
        with mock.patch.dict(sys.modules, {"gi": gi, "gi.repository": repository}):
            with mock.patch.object(sys, "argv", [str(script), *arguments]):
                runpy.run_path(str(script), run_name="__main__")
        return observations

    def test_standalone_fixture_remains_bounded_to_thirty_seconds(self):
        self.assertEqual(self.launch(["editor"])["lifetime"], 30)

    def test_daemon_fixture_outlives_prerequisite_and_tray_budgets(self):
        observations = self.launch(["editor", "--lifetime-seconds", "120"])
        self.assertEqual(observations["lifetime"], 120)
        self.assertGreater(observations["lifetime"], 40 + 40 + 30)

    def test_password_fixture_keeps_its_visibility(self):
        observations = self.launch(["private", "password", "--lifetime-seconds", "120"])
        self.assertEqual(observations["set_visibility"], (False,))
        self.assertEqual(observations["title"], "private")

    def test_unbounded_or_negative_lifetime_is_rejected(self):
        for lifetime in ["0", "-1"]:
            with self.subTest(lifetime=lifetime):
                with mock.patch("sys.stderr"), self.assertRaises(SystemExit) as failure:
                    self.launch(["editor", "--lifetime-seconds", lifetime])
                self.assertEqual(failure.exception.code, 2)


class FixtureReadinessTest(unittest.TestCase):
    """The ready file names the state the secure-field probe reads, never earlier."""

    def launch(self, arguments):
        state = {"active": False, "focus": False, "handlers": {}}

        class Widget:
            def __init__(self, **kwargs):
                pass

            def connect(self, signal, handler):
                state["handlers"][signal] = handler

            def is_active(self):
                return state["active"]

            def has_focus(self):
                return state["focus"]

            def __getattr__(self, name):
                return lambda *args: None

        gi = types.ModuleType("gi")
        gi.require_version = lambda *args: None
        repository = types.ModuleType("gi.repository")
        repository.Gtk = types.SimpleNamespace(
            Window=Widget, Entry=Widget, main=lambda: None, main_quit=lambda: None
        )
        repository.GLib = types.SimpleNamespace(timeout_add_seconds=lambda *args: None)
        script = pathlib.Path(__file__).with_name("atspi_fixture_app.py")
        with mock.patch.dict(sys.modules, {"gi": gi, "gi.repository": repository}):
            with mock.patch.object(sys, "argv", [str(script), *arguments]):
                runpy.run_path(str(script), run_name="__main__")
        return state

    def test_ready_file_waits_for_an_active_window_and_a_focused_field(self):
        # A probe run after a fixed sleep read a first window still starting
        # on a cold runner and answered inconclusive (CI run 43549510667).
        with tempfile.TemporaryDirectory() as folder:
            ready = pathlib.Path(folder) / "editor.ready"
            state = self.launch(["editor", "--ready-file", str(ready)])
            notify = state["handlers"]
            self.assertEqual(set(notify), {"notify::is-active", "notify::has-focus"})
            state["focus"] = True
            notify["notify::has-focus"]()
            self.assertFalse(ready.exists(), "a focused field in an inactive window is not ready")
            state["active"] = True
            notify["notify::is-active"]()
            self.assertTrue(ready.exists(), "an active window with its field focused is ready")

    def test_without_a_ready_file_nothing_is_watched(self):
        self.assertEqual(self.launch(["editor"])["handlers"], {})


if __name__ == "__main__":
    unittest.main()
