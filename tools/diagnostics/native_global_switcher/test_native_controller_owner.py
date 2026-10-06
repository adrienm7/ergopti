# tools/diagnostics/native_global_switcher/test_native_controller_owner.py
"""Controlled exact-capability proofs; no native macOS process is allocated."""

import ast
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_controller_owner import ProbeControllerOwner


class Capsule:
    def __init__(self, pid):
        self.process = SimpleNamespace(pid=pid)
        self.reaped, self.calls, self.refusal = False, 0, None

    def settle(self):
        self.calls += 1
        if isinstance(self.refusal, BaseException):
            raise self.refusal
        if self.refusal is not None:
            return self.refusal
        self.reaped = True
        return True

    def receipt(self):
        return {"worker_pid": self.process.pid, "closed": self.reaped}


class ControllerOwnership(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.native = object()
        self.ownership = SimpleNamespace(acquire_owned=self.acquire)
        self.owner = ProbeControllerOwner(self.native, self.ownership, Path(self.directory.name))
        self.created = []

    def acquire(self, arguments, native, register, **options):
        cap = Capsule(101 + len(self.created))
        self.created.append(cap)
        register(cap)
        return cap

    def closed_hs_receipt(self):
        return {
            "coverage": "isolated_fixture_only",
            "hs_pid": self.owner.hs.process.pid,
            "status": "refused",
            "cleanup_debt": False,
            "tasks_retired": True,
            "tap_retired": True,
            "timer_retired": True,
            "session_retired": True,
        }

    def test_early_registered_carrier_survives_adopter_throw_after_transfer(self):
        def refuse(cap):
            raise RuntimeError("independent adopter refusal")

        with self.assertRaises(RuntimeError):
            self.owner.acquire_external(["fixed"], self.native, refuse)
        self.assertEqual(len(self.owner.capabilities), 1)
        self.assertIs(self.owner.capabilities[0][1], self.created[0])
        self.assertTrue(self.owner.retirement_step(None))
        self.assertTrue(self.created[0].reaped)

    def test_no_numeric_pid_record_can_replace_live_hs_capsule(self):
        hs = self.owner.acquire("hammerspoon", ["fixed"])
        app = self.owner.acquire("fixture_a", ["fixed"])
        for value in (None, {}, {"hs_pid": hs.process.pid, "status": "pending"}):
            self.assertFalse(self.owner.retirement_step(value))
            self.assertEqual((hs.calls, app.calls), (0, 0))
            self.assertIs(self.owner.hs, hs)

    def test_every_physical_cleanup_clause_is_required_before_signals(self):
        hs = self.owner.acquire("hammerspoon", ["fixed"])
        receipt = self.closed_hs_receipt()
        for key in ("tasks_retired", "tap_retired", "timer_retired", "session_retired"):
            for refused in (False, None, 1):
                candidate = dict(receipt)
                candidate[key] = refused
                self.assertFalse(self.owner.retirement_step(candidate))
                self.assertEqual(hs.calls, 0)
        for key, value in (
            ("cleanup_debt", True),
            ("hs_pid", 999),
            ("hs_pid", True),
            ("coverage", "foreign"),
            ("status", "pending"),
        ):
            candidate = dict(receipt)
            candidate[key] = value
            self.assertFalse(self.owner.retirement_step(candidate))
            self.assertEqual(hs.calls, 0)

    def test_refused_or_throwing_native_retirement_keeps_exact_capsule(self):
        hs = self.owner.acquire("hammerspoon", ["fixed"])
        receipt = self.closed_hs_receipt()
        for failure in (False, 0, RuntimeError("native syscall refused"), KeyboardInterrupt()):
            hs.refusal = failure
            self.assertFalse(self.owner.retirement_step(receipt))
            self.assertIs(self.owner.hs, hs)
            self.assertIs(self.owner.capabilities[0][1], hs)
            self.assertFalse(hs.reaped)
        hs.refusal = None
        self.assertTrue(self.owner.retirement_step(receipt))

    def test_cancel_source_marker_does_not_drop_capsules_or_authorize_shutdown(self):
        hs = self.owner.acquire("hammerspoon", ["fixed"])
        self.owner.request_cancel("independent source revocation")
        self.assertTrue((Path(self.directory.name) / "cancel").is_file())
        with self.assertRaises(RuntimeError):
            self.owner.acquire("fixture_a", ["later"])
        self.assertFalse(self.owner.retirement_step(None))
        self.assertEqual(hs.calls, 0)
        self.assertIs(self.owner.hs, hs)

    def test_actual_retirement_loop_retains_caps_through_cancel_marker_io_refusal(self):
        hs = self.owner.acquire("hammerspoon", ["fixed"])
        current = [None]
        pauses = []

        def pause(_):
            self.assertIs(self.owner.hs, hs)
            self.assertFalse(hs.reaped)
            self.assertEqual(hs.calls, 0)
            pauses.append(True)
            current[0] = self.closed_hs_receipt()

        with patch.object(Path, "touch", side_effect=OSError("PRIVATE_IO_VALUE")):
            receipt = self.owner.retire_until_settled(
                lambda: current[0], lambda: True, lambda _: None, pause
            )
        self.assertTrue(hs.reaped)
        self.assertEqual(pauses, [True])
        self.assertEqual(receipt, self.closed_hs_receipt())
        self.assertTrue(self.owner.cancel_requested and self.owner.qualification_refused)

    def test_actual_retirement_loop_retains_caps_through_pending_report_io_refusal(self):
        hs = self.owner.acquire("hammerspoon", ["fixed"])
        app = self.owner.acquire("fixture_a", ["fixed"])
        current, pauses = [None], []

        def publish(_):
            self.assertIs(self.owner.hs, hs)
            self.assertFalse(hs.reaped or app.reaped)
            raise OSError("PRIVATE_IO_VALUE")

        def pause(_):
            self.assertFalse(hs.reaped or app.reaped)
            self.assertEqual((hs.calls, app.calls), (0, 0))
            pauses.append(True)
            current[0] = self.closed_hs_receipt()

        self.owner.retire_until_settled(lambda: current[0], lambda: True, publish, pause)
        self.assertTrue(hs.reaped and app.reaped)
        self.assertEqual(pauses, [True])
        self.assertTrue(self.owner.qualification_refused)
        self.assertNotIn("PRIVATE_IO_VALUE", self.owner.pending_reason)

    def test_actual_hammerspoon_acquisition_argv_suppresses_only_reviewed_startup_checks(
        self,
    ):
        source = Path(__file__).with_name("run_native_probe.py").read_text()
        main = next(
            node
            for node in ast.parse(source).body
            if isinstance(node, ast.FunctionDef) and node.name == "main"
        )
        selected = [
            node
            for node in ast.walk(main)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "owner"
            and node.func.attr == "acquire"
            and node.args
            and isinstance(node.args[0], ast.Constant)
            and node.args[0].value == "hammerspoon"
        ]
        self.assertEqual(len(selected), 1, "actual native Hammerspoon acquisition must be unique")
        observed = []
        owner = SimpleNamespace(
            acquire=lambda role, argv, **options: observed.append((role, argv, options))
        )
        hs_binary = Path("/owned/日本 e\u0301/Official Hammerspoon.app/Contents/MacOS/Hammerspoon")
        init = Path("/owned/private fixture/line\nnext.lua")
        log = object()
        expression = ast.Expression(body=selected[0])
        eval(
            compile(
                ast.fix_missing_locations(expression),
                "actual-native-launch-argv",
                "eval",
            ),
            {
                "owner": owner,
                "hs_binary": hs_binary,
                "init": init,
                "log": log,
                "str": str,
            },
        )
        self.assertEqual(
            observed,
            [
                (
                    "hammerspoon",
                    [
                        str(hs_binary),
                        "-MJConfigFile",
                        str(init),
                        "-SUEnableAutomaticChecks",
                        "NO",
                        "-SUHasLaunchedBefore",
                        "YES",
                    ],
                    {"stdout": log, "stderr": log},
                )
            ],
        )

    def test_cooperative_cleanup_then_native_retirement_may_release(self):
        hs = self.owner.acquire("hammerspoon", ["fixed"])
        app = self.owner.acquire("fixture_a", ["fixed"])
        self.assertTrue(self.owner.retirement_step(self.closed_hs_receipt()))
        self.assertEqual((hs.calls, app.calls), (1, 1))
        self.assertTrue(hs.reaped and app.reaped)


if __name__ == "__main__":
    unittest.main(verbosity=2)
