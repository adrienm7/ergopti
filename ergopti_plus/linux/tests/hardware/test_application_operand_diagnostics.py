#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/test_application_operand_diagnostics.py
"""Constructed ownership controls; these never substitute native GTK evidence."""

import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import application_operand_diagnostics as diagnostic
import run_application_operand_receipts as receiver


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
            ticks = iter((10, 20, 25, 30))
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


class X11ReadinessControls(unittest.TestCase):
    def client(self, outcomes, *, kill_failure=None):
        events = []
        outcomes = iter(outcomes)

        class Child:
            returncode = None

            def wait(self, **options):
                events.append(("wait", options))
                result = next(outcomes)
                if isinstance(result, BaseException):
                    raise result
                self.returncode = result
                return result

            def kill(self):
                events.append(("kill", self.returncode))
                if kill_failure is not None:
                    raise kill_failure

        return Child(), events

    def server(self):
        return SimpleNamespace(poll=lambda: None)

    def test_real_client_path_exact_owned_display_and_one_bounded_wait(self):
        child, events = self.client([0])
        with patch.object(diagnostic.subprocess, "Popen", return_value=child) as spawn:
            self.assertTrue(diagnostic.require_x11_ready(":87", self.server(), spawn=spawn))
        spawn.assert_called_once_with(
            ["/usr/bin/xdpyinfo", "-display", ":87"],
            stdin=diagnostic.subprocess.DEVNULL,
            stdout=diagnostic.subprocess.DEVNULL,
            stderr=diagnostic.subprocess.DEVNULL,
        )
        self.assertEqual(events, [("wait", {"timeout": 5})])
        self.assertEqual(child.returncode, 0)

    def test_native_nonzero_is_refused_after_actual_terminal_wait(self):
        child, events = self.client([3])
        with self.assertRaisesRegex(RuntimeError, "refused"):
            diagnostic.require_x11_ready(":87", self.server(), spawn=lambda *_a, **_p: child)
        self.assertEqual(events, [("wait", {"timeout": 5})])
        self.assertEqual(child.returncode, 3)

    def test_timeout_kills_and_waits_exact_acquired_client_before_refusal(self):
        child, events = self.client(
            [diagnostic.subprocess.TimeoutExpired(["/usr/bin/xdpyinfo"], 5), -9]
        )
        with self.assertRaises(diagnostic.subprocess.TimeoutExpired):
            diagnostic.require_x11_ready(":87", self.server(), spawn=lambda *_a, **_p: child)
        self.assertEqual(events, [("wait", {"timeout": 5}), ("kill", None), ("wait", {})])
        self.assertEqual(child.returncode, -9)

    def test_interruption_cannot_drop_client_or_become_success(self):
        child, events = self.client([KeyboardInterrupt("controlled interruption"), -9])
        with self.assertRaises(KeyboardInterrupt):
            diagnostic.require_x11_ready(":87", self.server(), spawn=lambda *_a, **_p: child)
        self.assertEqual(events, [("wait", {"timeout": 5}), ("kill", None), ("wait", {})])
        self.assertEqual(child.returncode, -9)

    def test_interrupted_retirement_still_waits_the_same_client(self):
        child, events = self.client(
            [
                diagnostic.subprocess.TimeoutExpired(["/usr/bin/xdpyinfo"], 5),
                KeyboardInterrupt(),
                -9,
            ]
        )
        with self.assertRaises(diagnostic.subprocess.TimeoutExpired):
            diagnostic.require_x11_ready(":87", self.server(), spawn=lambda *_a, **_p: child)
        self.assertEqual(
            events,
            [("wait", {"timeout": 5}), ("kill", None), ("wait", {}), ("wait", {})],
        )
        self.assertEqual(child.returncode, -9)

    def test_signal_exit_race_still_requires_actual_wait(self):
        child, events = self.client(
            [diagnostic.subprocess.TimeoutExpired(["/usr/bin/xdpyinfo"], 5), -9],
            kill_failure=ProcessLookupError("controlled completed client"),
        )
        with self.assertRaises(diagnostic.subprocess.TimeoutExpired):
            diagnostic.require_x11_ready(":87", self.server(), spawn=lambda *_a, **_p: child)
        self.assertEqual(events[-1], ("wait", {}))
        self.assertEqual(child.returncode, -9)

    def test_interrupted_kill_retries_signal_before_waiting_on_blocked_client(self):
        events = []

        class Child:
            returncode = None
            kill_count = 0

            def wait(self, **options):
                events.append(("wait", options))
                if options:
                    raise diagnostic.subprocess.TimeoutExpired(["/usr/bin/xdpyinfo"], 5)
                self.returncode = -9
                return -9

            def kill(self):
                self.kill_count += 1
                events.append(("kill", self.kill_count))
                if self.kill_count == 1:
                    raise KeyboardInterrupt("controlled interruption before native signal")

        child = Child()
        with self.assertRaises(diagnostic.subprocess.TimeoutExpired):
            diagnostic.require_x11_ready(":87", self.server(), spawn=lambda *_a, **_p: child)
        self.assertEqual(
            events,
            [("wait", {"timeout": 5}), ("kill", 1), ("kill", 2), ("wait", {})],
        )
        self.assertEqual(child.returncode, -9)

    def test_owned_server_exit_after_handshake_still_refuses(self):
        child, events = self.client([0])
        states = iter([None, 0])
        server = SimpleNamespace(poll=lambda: next(states))
        with self.assertRaisesRegex(RuntimeError, "refused"):
            diagnostic.require_x11_ready(":87", server, spawn=lambda *_a, **_p: child)
        self.assertEqual(events, [("wait", {"timeout": 5})])
        self.assertEqual(child.returncode, 0)

    def test_missing_client_has_no_native_owner_to_invent_or_warm(self):
        with patch.object(
            diagnostic.subprocess, "Popen", side_effect=FileNotFoundError("controlled absence")
        ) as spawn:
            with self.assertRaises(FileNotFoundError):
                diagnostic.require_x11_ready(":87", self.server(), spawn=spawn)
        self.assertEqual(spawn.call_count, 1)

    def test_invalid_or_retired_owned_display_never_spawns_client(self):
        with patch.object(diagnostic.subprocess, "Popen") as spawn:
            for name in ("", "87", ":", ":8.0", ":８", "--display", None):
                with self.subTest(name=name), self.assertRaises(RuntimeError):
                    diagnostic.require_x11_ready(name, self.server(), spawn=spawn)
            with self.assertRaises(RuntimeError):
                diagnostic.require_x11_ready(":87", SimpleNamespace(poll=lambda: 0), spawn=spawn)
        spawn.assert_not_called()

    def test_unknown_native_success_status_cannot_admit_readiness(self):
        child, events = self.client([False])
        with self.assertRaisesRegex(RuntimeError, "refused"):
            diagnostic.require_x11_ready(":87", self.server(), spawn=lambda *_a, **_p: child)
        self.assertEqual(events, [("wait", {"timeout": 5})])


class PhaseObservationControls(unittest.TestCase):
    def context(self, root):
        return {
            "directory": str(root),
            "nonce": "independent-phase-owner",
            "identity": "ordinary-app",
            "receipt": str(root / "application-receipt"),
        }

    def test_native_observation_separates_spawn_durable_publication_and_wait(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            ticks = iter((100, 120, 500, 600))
            events = []

            class Child:
                pid = 80173

                def wait(self):
                    events.append("actual-terminal-wait")
                    self_case.assertTrue((root / "gtk-started.json").is_file())
                    return 0

            def spawn(arguments, **ports):
                self.assertEqual(arguments, ["/usr/bin/gtk-launch", "--", "ordinary-app"])
                events.append("exact-native-acquisition")
                return Child()

            self_case = self
            self.assertEqual(
                diagnostic.run_wrapper(
                    self.context(root),
                    ["--", "ordinary-app"],
                    spawn=spawn,
                    clock=lambda: next(ticks),
                ),
                0,
            )
            terminal = json.loads((root / "gtk-terminal.json").read_bytes())
            started = json.loads((root / "gtk-started.json").read_bytes())
            self.assertEqual(events, ["exact-native-acquisition", "actual-terminal-wait"])
            self.assertEqual(started["before_spawn_ns"], 100)
            self.assertEqual(started["after_spawn_ns"], 120)
            self.assertEqual(terminal["before_spawn_ns"], 100)
            self.assertEqual(terminal["after_spawn_ns"], 120)
            self.assertEqual(terminal["started_published_ns"], 500)
            self.assertEqual(terminal["terminal_observed_ns"], 600)
            self.assertTrue(diagnostic.native_launch_complete(terminal))

    def test_refused_started_publication_retains_owner_and_no_completed_phase(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            ticks = iter((100, 120, 600))
            waits = []
            publish = diagnostic.publish

            class Child:
                pid = 80173

                def wait(self):
                    waits.append("exact-native-wait")
                    return 0

            def refused(path, packet):
                if Path(path).name == "gtk-started.json":
                    raise OSError("independent diagnostic publication refusal")
                return publish(path, packet)

            with patch.object(diagnostic, "publish", side_effect=refused):
                result = diagnostic.run_wrapper(
                    self.context(root),
                    ["--", "ordinary-app"],
                    spawn=lambda *_args, **_ports: Child(),
                    clock=lambda: next(ticks),
                )
            self.assertEqual(result, 1)
            self.assertEqual(waits, ["exact-native-wait"])
            terminal = json.loads((root / "gtk-terminal.json").read_bytes())
            self.assertEqual(terminal["after_spawn_ns"], 120)
            self.assertIsNone(terminal["started_published_ns"])
            self.assertEqual(terminal["terminal_observed_ns"], 600)
            self.assertEqual(terminal["native_exit"], 0)
            self.assertEqual(terminal["observer_failure"], "OSError")
            self.assertFalse(diagnostic.native_launch_complete(terminal))

    def test_spawn_refusal_never_invents_phase_or_native_completion(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            ticks = iter((100, 600))

            def refused(*_args, **_ports):
                raise FileNotFoundError(2, "independent native acquisition refusal")

            self.assertEqual(
                diagnostic.run_wrapper(
                    self.context(root),
                    ["--", "ordinary-app"],
                    spawn=refused,
                    clock=lambda: next(ticks),
                ),
                1,
            )
            terminal = json.loads((root / "gtk-terminal.json").read_bytes())
            self.assertIsNone(terminal["after_spawn_ns"])
            self.assertIsNone(terminal["started_published_ns"])
            self.assertFalse(terminal["native_terminal_observed"])
            self.assertIsNone(terminal["native_exit"])
            self.assertEqual(terminal["spawn_errno"], 2)
            self.assertFalse(diagnostic.native_launch_complete(terminal))

    def test_interrupted_wait_preserves_phases_and_refuses_after_exact_retirement(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            ticks = iter((100, 120, 500, 600))
            waits = []

            class Child:
                pid = 80173

                def wait(self):
                    waits.append("owned-wait")
                    if len(waits) == 1:
                        raise KeyboardInterrupt("independent observer interruption")
                    return 0

            self.assertEqual(
                diagnostic.run_wrapper(
                    self.context(root),
                    ["--", "ordinary-app"],
                    spawn=lambda *_args, **_ports: Child(),
                    clock=lambda: next(ticks),
                ),
                1,
            )
            terminal = json.loads((root / "gtk-terminal.json").read_bytes())
            self.assertEqual(waits, ["owned-wait", "owned-wait"])
            self.assertEqual(terminal["after_spawn_ns"], 120)
            self.assertEqual(terminal["started_published_ns"], 500)
            self.assertEqual(terminal["terminal_observed_ns"], 600)
            self.assertEqual(terminal["native_exit"], 0)
            self.assertEqual(terminal["observer_failure"], "KeyboardInterrupt")
            self.assertFalse(diagnostic.native_launch_complete(terminal))


class PhaseTimestampControls(unittest.TestCase):
    def test_only_nonnegative_native_integer_phases_are_exposed(self):
        self.assertEqual(diagnostic.phase_timestamp(0), 0)
        self.assertEqual(diagnostic.phase_timestamp(120), 120)
        self.assertEqual(diagnostic.phase_timestamp((1 << 63) - 1), (1 << 63) - 1)
        for value in (
            None,
            True,
            False,
            -1,
            1.5,
            float("inf"),
            1 << 63,
            "private-phase-token",
            {"private": "phase-token"},
        ):
            with self.subTest(kind=type(value).__name__):
                self.assertIsNone(diagnostic.phase_timestamp(value))

    def test_unknown_publication_phase_never_exports_a_private_callback_value(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            ticks = iter((100, 120, "private-phase-token", 600))

            class Child:
                pid = 80173

                def wait(self):
                    return 0

            context = PhaseObservationControls().context(root)
            self.assertEqual(
                diagnostic.run_wrapper(
                    context,
                    ["--", "ordinary-app"],
                    spawn=lambda *_args, **_ports: Child(),
                    clock=lambda: next(ticks),
                ),
                0,
            )
            raw = (root / "gtk-terminal.json").read_bytes()
            self.assertNotIn(b"private-phase-token", raw)
            terminal = json.loads(raw)
            self.assertEqual(terminal["after_spawn_ns"], 120)
            self.assertIsNone(terminal["started_published_ns"])
            self.assertEqual(terminal["terminal_observed_ns"], 600)
            self.assertTrue(diagnostic.native_launch_complete(terminal))


class AdmissionControls(unittest.TestCase):
    def facts(self):
        identity = "ordinary-app"
        data = identity.encode("utf-8")
        return {
            "nonce": "owned-case",
            "identity": identity,
            "worker_exit": 0,
            "observer_timed_out": False,
            "gtk": {
                "nonce": "owned-case",
                "identity": identity,
                "native_terminal_observed": True,
                "native_exit": 0,
                "observer_failure": "",
            },
            "receipt_after_worker": {
                "present": True,
                "truncated": False,
                "text": identity,
                "bytes_total": len(data),
                "captured_bytes": len(data),
                "prefix_sha256": hashlib.sha256(data).hexdigest(),
            },
        }

    def accepted(self, facts):
        return diagnostic.application_receive_complete(facts, "owned-case", "ordinary-app")

    def test_exact_settled_receipt_does_not_depend_on_an_earlier_poll(self):
        facts = self.facts()
        facts["poll"] = {"phase": "missing", "after_receipt": {"present": False}}
        self.assertTrue(self.accepted(facts))
        facts["worker_exit"] = 1
        self.assertFalse(self.accepted(facts), "A real worker error cannot be waived")

    def test_worker_keeps_actual_admission_but_does_not_impose_delivery_polling(self):
        for statement in (
            'local id = assert(Chooser.desktop_id(os.getenv("ERGOPTI_NATIVE_APPLICATION_ENTRY")))',
            'assert(Actions.set_action_parameter("tap_3", "open_app", id))',
            'assert(Actions.execute_action("open_app", "tap_3"))',
        ):
            self.assertIn(statement, receiver.WORKER)
        self.assertTrue(receiver.WORKER.rstrip().endswith("return"))
        self.assertNotIn('os.execute("sleep 0.02")', receiver.WORKER)
        self.assertNotIn("the selected desktop entry did not launch", receiver.WORKER)

    def test_native_and_case_failures_cannot_admit_an_exact_receipt(self):
        cases = (
            ("gtk", None),
            ("worker_exit", 1),
            ("worker_exit", False),
            ("observer_timed_out", True),
            ("observer_timed_out", None),
            ("nonce", "other-case"),
            ("identity", "other-app"),
        )
        for key, value in cases:
            with self.subTest(key=key, value=value):
                facts = self.facts()
                facts[key] = value
                self.assertFalse(self.accepted(facts))
        for key, value in (
            ("native_exit", 3),
            ("native_exit", False),
            ("native_terminal_observed", False),
            ("observer_failure", "Interrupted"),
            ("nonce", "other-case"),
            ("identity", "other-app"),
        ):
            with self.subTest(native_key=key, value=value):
                facts = self.facts()
                facts["gtk"][key] = value
                self.assertFalse(self.accepted(facts))

    def test_missing_wrong_extra_truncated_and_wrong_digest_receipts_refuse(self):
        facts = self.facts()
        facts["receipt_after_worker"] = None
        self.assertFalse(self.accepted(facts))
        for key, value in (
            ("present", False),
            ("text", "other-app"),
            ("text", "ordinary-app-extra"),
            ("truncated", True),
            ("bytes_total", 13),
            ("captured_bytes", 11),
            ("prefix_sha256", "0" * 64),
        ):
            with self.subTest(key=key, value=value):
                facts = copy.deepcopy(self.facts())
                facts["receipt_after_worker"][key] = value
                self.assertFalse(self.accepted(facts))


if __name__ == "__main__":
    unittest.main()
