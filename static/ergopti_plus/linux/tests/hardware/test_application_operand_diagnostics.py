#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/test_application_operand_diagnostics.py
"""Constructed ownership controls; these never substitute native GTK evidence."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import application_operand_diagnostics as diagnostic


class DiagnosticControls(unittest.TestCase):
    def context(self, root):
        return {
            "directory": str(root),
            "nonce": "controlled-owner",
            "identity": "ordinary-app",
            "receipt": str(root / "application-receipt"),
        }

    def test_exact_argv_status_and_terminal_precede_capture_disposal(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            context = self.context(root)
            ticks = iter((10, 20, 30))
            calls = []

            def spawn(arguments, **ports):
                self.assertEqual(arguments, ["/usr/bin/gtk-launch", "--", "ordinary-app"])
                calls.append(arguments)

                class Child:
                    pid = 73136

                    def wait(self):
                        self_case.assertFalse(ports["stdout"].closed)
                        self_case.assertFalse(ports["stderr"].closed)
                        self_case.assertTrue((root / "gtk-started.json").exists())
                        ports["stderr"].write(b"independent native refusal\n")
                        return 3

                return Child()

            self_case = self
            self.assertEqual(
                diagnostic.run_wrapper(
                    context, ["--", "ordinary-app"], spawn=spawn, clock=lambda: next(ticks)
                ),
                3,
            )
            packet = json.loads((root / "gtk-terminal.json").read_bytes())
            self.assertEqual(len(calls), 1)
            self.assertEqual(packet["native_exit"], 3)
            self.assertTrue(packet["native_terminal_observed"])
            self.assertEqual(packet["terminal_observed_ns"], 30)
            self.assertEqual(packet["stderr"]["text"], "independent native refusal\n")

    def test_observer_interruption_retains_child_until_actual_wait_then_stays_failed(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            waits = []

            class Child:
                pid = 73136

                def wait(self):
                    waits.append(1)
                    if len(waits) == 1:
                        raise KeyboardInterrupt("constructed observer interruption")
                    return 0

            result = diagnostic.run_wrapper(
                self.context(root), ["--", "ordinary-app"], spawn=lambda *_args, **_ports: Child()
            )
            self.assertEqual(result, 1)
            self.assertEqual(len(waits), 2)
            packet = json.loads((root / "gtk-terminal.json").read_bytes())
            self.assertEqual(packet["native_exit"], 0)
            self.assertEqual(packet["observer_failure"], "KeyboardInterrupt")
            self.assertTrue(packet["native_terminal_observed"])

    def test_capture_bound_is_explicit_and_late_snapshot_does_not_change_verdict(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "bytes"
            self.assertFalse(diagnostic.receipt_snapshot(path)["present"])
            path.write_bytes(b"a" * 4097)
            packet = diagnostic.receipt_snapshot(path)
            self.assertEqual(packet["bytes_total"], 4097)
            self.assertEqual(packet["captured_bytes"], 4096)
            self.assertTrue(packet["truncated"])
            self.assertNotIn("passed", packet)

    def test_spawn_refusal_never_invents_native_terminal_or_success(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)

            def refused(*_arguments, **_ports):
                raise FileNotFoundError(2, "constructed absent launcher")

            self.assertEqual(
                diagnostic.run_wrapper(self.context(root), ["--", "ordinary-app"], spawn=refused), 1
            )
            packet = json.loads((root / "gtk-terminal.json").read_bytes())
            self.assertFalse(packet["native_terminal_observed"])
            self.assertIsNone(packet["native_exit"])
            self.assertEqual(packet["spawn_errno"], 2)

    def test_native_failure_is_refused_despite_worker_zero_and_exact_application_receipt(self):
        worker = SimpleNamespace(returncode=0, observer_timed_out=False)
        receipt = {"present": True, "text": "ordinary-app"}
        terminal = {"native_terminal_observed": True, "observer_failure": "", "native_exit": 3}
        self.assertEqual(worker.returncode, 0)
        self.assertFalse(worker.observer_timed_out)
        self.assertEqual(receipt["text"], "ordinary-app")
        self.assertFalse(diagnostic.native_launch_complete(terminal))
        self.assertTrue(diagnostic.native_launch_complete({**terminal, "native_exit": 0}))
        self.assertFalse(diagnostic.native_launch_complete({**terminal, "native_exit": False}))

    def test_session_timeout_retains_real_owner_until_completion_and_stays_failed(self):
        events = []
        judge = self

        class Child:
            returncode = None

            def communicate(self, **options):
                if options:
                    judge.assertEqual(options, {"timeout": 10})
                    judge.assertIsNone(self.returncode)
                    events.append("timeout-while-live")
                    raise diagnostic.subprocess.TimeoutExpired(["dbus-run-session"], 10)
                judge.assertIsNone(self.returncode)
                events.append("actual-terminal-and-streams")
                self.returncode = 0
                return "later native stdout", ""

            def kill(self):
                judge.fail("A diagnostic timeout cannot kill the acquired process")

            def terminate(self):
                judge.fail("A diagnostic timeout cannot replace actual completion")

        child = Child()
        with patch.object(diagnostic.subprocess, "Popen", return_value=child) as launch:
            result = diagnostic.run_owned_case(["dbus-run-session"], {})
        launch.assert_called_once()
        self.assertEqual(events, ["timeout-while-live", "actual-terminal-and-streams"])
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.observer_timed_out)
        self.assertEqual(result.stdout, "later native stdout")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
