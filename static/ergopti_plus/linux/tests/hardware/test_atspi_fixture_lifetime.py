#!/usr/bin/env python3
# tests/hardware/test_atspi_fixture_lifetime.py

"""Check the editor's bounded lifetime without requiring a graphical desktop."""

import pathlib
import runpy
import sys
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


if __name__ == "__main__":
    unittest.main()
