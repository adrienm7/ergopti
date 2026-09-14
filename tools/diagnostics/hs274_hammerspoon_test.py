# tools/diagnostics/hs274_hammerspoon_test.py
"""Reject native consumer receipts without exact physical and process evidence."""

import copy
from contextlib import contextmanager
from datetime import datetime
import json
import math
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from hs274_hammerspoon import CaptureReceipt, owned_capture, read_clock, validate_consumer, validate_clock, validate_context
from hs274_stream_test import fixture
from hs274_hammerspoon_registration import register_application


def receipt():
    capture, _ = fixture()
    downs = [row for row in capture["records"] if row["page"] == 7 and row["usage"] in (41, 44) and row["value"] == 1]
    def date(row):
        epoch = 1000 + (row["timestamp"] * 125 // 3) / 1000000000
        return datetime.fromtimestamp(math.floor(epoch)).strftime("%Y-%m-%d %H:%M:%S") + f".{math.floor((epoch % 1) * 1000):03d}"
    return capture, {"runtime": "native Hammerspoon", "coverage": "fixture_only", "settled": True,
                     "field_focus": {"source": "native AX", "accessibility": True, "value": True,
                                     "fixture_id": 51, "focused_id": 51, "role": "AXTextField"},
                     "context_source": "native app/window/AX", "context_stopped": True,
                     "context_observations": [dict(observed_ns=str(index), allowed=allowed,
                         **({"app": "Observed", "epoch": 1000 + index / 1000000000} if allowed else {}))
                         for index, allowed in enumerate((True, False, True, False, True))],
                     "context_probe": [{"phase": phase, "observation": index + 2}
                         for index, phase in enumerate(("private", "public", "secure", "resumed"))],
                     "clock": {"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3},
                     "capture_started_ns": "0", "clock_samples": [
                         {"original_ns": str(row["timestamp"] * 125 // 3),
                          "observed_ns": str(row["timestamp"] * 125 // 3 + 1)} for row in downs],
                     "stop_requested": True, "error_count": 0, "errors": [], "exit": 143, "counts": {"49": 1, "53": 1},
                     "contexts": [{"device": str(row["device"]), "timestamp": str(row["timestamp"])} for row in downs],
                     "presses": [{"device": str(row["device"]), "keycode": {41: 53, 44: 49}[row["usage"]],
                                  "app": "Observed", "timestamp": date(row)} for row in downs]}


class ConsumerTests(unittest.TestCase):
    def setUp(self):
        @contextmanager
        def target(*args):
            yield {"target_pid": 900, "target_request": "fixture-request", "target_response": "fixture-response"}
        patcher = patch("hs274_hammerspoon.owned_target", target)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_registration_requires_success_and_exact_bundle_readback(self):
        with tempfile.TemporaryDirectory(prefix="hs274-registration-") as directory:
            app = Path(directory).resolve() / "Hammerspoon.app"
            executable = app / "Contents/MacOS/Hammerspoon"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            good = {"identifier": "org.hammerspoon.Hammerspoon", "before": None, "status": 0, "after": str(app)}
            for changes in ({}, {"status": -10811}, {"status": False}, {"after": str(app.parent / "Foreign.app")},
                            {"after": None}, {"identifier": "foreign"}):
                report = {}
                result = dict(good, **changes)
                with self.subTest(changes=changes), patch("hs274_hammerspoon_registration.subprocess.run",
                        return_value=SimpleNamespace(returncode=0, stdout=json.dumps(result), stderr="")) as run:
                    if changes:
                        with self.assertRaisesRegex(RuntimeError, "resolution is not exact"):
                            register_application(report, app)
                    else:
                        register_application(report, app)
                    self.assertEqual(report["hammerspoon_registration"]["resolution"], result)
                    self.assertEqual(run.call_args.args[0][-1], str(app))
                    self.assertEqual(run.call_args.kwargs["timeout"], 10)
            for failure in (SimpleNamespace(returncode=1, stdout="", stderr="native refusal"),
                            subprocess.TimeoutExpired("osascript", 10, output=b"partial", stderr=b"pending")):
                report = {}
                with patch("hs274_hammerspoon_registration.subprocess.run", **(
                        {"side_effect": failure} if isinstance(failure, Exception) else {"return_value": failure})):
                    with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)):
                        register_application(report, app)
                state = report["hammerspoon_registration"]
                if isinstance(failure, Exception):
                    self.assertTrue(state["timed_out"])
                    self.assertEqual(state["stdout"], "partial")
                    self.assertNotIn("exit", state)
                else:
                    self.assertEqual(state["exit"], 1)
                    self.assertEqual(state["stderr"], "native refusal")

    def test_native_start_is_released_only_after_successful_ui_approval(self):
        for rejected in (False, True, "restart"):
            with self.subTest(rejected=rejected), tempfile.TemporaryDirectory(prefix="hs274-permission-") as directory:
                root = Path(directory).resolve()
                scratch, output = root / "scratch", root / "output"
                scratch.mkdir()
                output.mkdir()
                (scratch / "permission-request.json").write_text("{}", encoding="utf-8")
                ready = scratch / "permission-ready"
                live, launches = [], []
                native = SimpleNamespace(matching=lambda _: list(live))
                def cleanup(*args):
                    if rejected == "restart":
                        raise RuntimeError("old permission owner did not stop")
                    live.clear()
                lifecycle = SimpleNamespace(NativeProcesses=lambda: native, cleanup=cleanup)
                client = SimpleNamespace(wait=lambda **kwargs: None, returncode=143, result={})
                clock = json.dumps({"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3})

                def approve(report, app):
                    self.assertFalse(ready.exists())
                    self.assertEqual(app, scratch / "Hammerspoon.app")
                    if rejected is True:
                        raise ValueError("approval refused")

                registered = []
                def launch(*args, **kwargs):
                    self.assertEqual(registered, [scratch / "Hammerspoon.app"])
                    self.assertEqual(live, [])
                    launches.append(args[0])
                    live.append(41 + len(launches))
                    if len(launches) == 2:
                        (output / "hs274-remap-physical-stream.log").write_text("", encoding="utf-8")
                    return SimpleNamespace(poll=lambda: None)

                with patch("hs274_hammerspoon.native_lifecycle", return_value=lifecycle), \
                        patch("hs274_hammerspoon.subprocess.run", return_value=SimpleNamespace(stdout=clock)), \
                        patch("hs274_hammerspoon.subprocess.Popen", side_effect=launch), \
                        patch("hs274_hammerspoon_registration.register_application", side_effect=lambda report, app: registered.append(app)), \
                        patch("hs274_hammerspoon.Path.home", return_value=root), \
                        patch("hs274_hammerspoon.tempfile.mkdtemp", return_value=str(scratch)) as temporary, \
                        patch("hs274_hammerspoon.CaptureReceipt", return_value=client), \
                        patch("hs274_hammerspoon.approve_accessibility", side_effect=approve):
                    if rejected:
                        kind, message = (RuntimeError, "old permission owner") if rejected == "restart" else (ValueError, "approval refused")
                        with self.assertRaisesRegex(kind, message):
                            with owned_capture(root / "app", root / "cli", output, {}):
                                self.fail("Rejected permission admitted capture")
                        self.assertFalse(ready.exists())
                        self.assertEqual(len(launches), 1)
                    else:
                        with owned_capture(root / "app", root / "cli", output, {}):
                            self.assertEqual(ready.read_text(encoding="utf-8"), "approved\n")
                            self.assertEqual(len(launches), 2)
                            self.assertEqual(launches[0], launches[1])
                    self.assertEqual(temporary.call_args.kwargs.get("dir"), root / "Applications")
                    self.assertTrue((root / "Applications").is_dir())

    def test_capture_preserves_primary_failure_when_settlement_also_fails(self):
        with tempfile.TemporaryDirectory(prefix="hs274-primary-failure-") as directory:
            root = Path(directory)
            scratch, output = root / "scratch", root / "output"
            scratch.mkdir()
            output.mkdir()
            (output / "hs274-remap-physical-stream.log").write_text("", encoding="utf-8")
            cleaned, report = [], {}
            native = SimpleNamespace(matching=lambda _: [42])
            lifecycle = SimpleNamespace(NativeProcesses=lambda: native, cleanup=lambda *args: cleaned.append(args))
            def settle(timeout):
                raise RuntimeError("settlement failure")
            def diagnose(receipt, app, pids):
                self.assertEqual(cleaned, [])
                self.assertEqual(pids, [42])
                self.assertEqual(app, scratch.resolve() / "Hammerspoon.app")
                raise RuntimeError("diagnostic failure")
            client = SimpleNamespace(wait=settle)
            clock = json.dumps({"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3})
            with patch("hs274_hammerspoon.native_lifecycle", return_value=lifecycle), \
                    patch("hs274_hammerspoon_registration.register_application"), \
                    patch("hs274_hammerspoon.subprocess.run", return_value=SimpleNamespace(stdout=clock)), \
                    patch("hs274_hammerspoon.subprocess.Popen", return_value=object()), \
                    patch("hs274_hammerspoon.Path.home", return_value=root), \
                    patch("hs274_hammerspoon.tempfile.mkdtemp", return_value=str(scratch)), \
                    patch("hs274_accessibility_diagnostics.retain_failure", side_effect=diagnose) as diagnostic, \
                    patch("hs274_hammerspoon.CaptureReceipt", return_value=client):
                with self.assertRaisesRegex(ValueError, "primary failure"):
                    with owned_capture(root / "app", root / "cli", output, report):
                        raise ValueError("primary failure")
            self.assertEqual(len(cleaned), 1)
            self.assertEqual(report["hammerspoon_primary_error"], "ValueError: primary failure")
            self.assertEqual(report["hammerspoon_settlement_error"], "RuntimeError: settlement failure")
            diagnostic.assert_called_once()
            self.assertEqual(report["hammerspoon_diagnostic_error"], "RuntimeError: diagnostic failure")

    def test_modifier_consumer_keeps_all_eight_sides_and_the_collision_pair(self):
        from hs274_modifiers import KEYCODES
        capture, result = receipt()
        down = next(row for row in capture["records"] if row["usage"] == 41 and row["value"] == 1)
        capture["records"] = [dict(down, usage=usage) for usage in KEYCODES] + capture["records"]
        for field in ("presses", "contexts", "clock_samples"):
            result[field] = [dict(result[field][0]) for _ in KEYCODES] + result[field]
        for index, keycode in enumerate(KEYCODES.values()):
            result["presses"][index]["keycode"] = keycode
            result["counts"][str(keycode)] = 1
        validate_consumer(result, capture, modifiers=True)
        for keycode in KEYCODES.values():
            broken = copy.deepcopy(result)
            broken["counts"][str(keycode)] = 2
            with self.subTest(keycode=keycode), self.assertRaises(ValueError):
                validate_consumer(broken, capture, modifiers=True)
        with self.assertRaises(ValueError):
            validate_consumer(result, capture, held=True, modifiers=True)

    def test_held_consumer_credits_only_the_fresh_space(self):
        capture, result = receipt()
        capture["records"] = [row for row in capture["records"] if row["usage"] != 41]
        for field in ("presses", "contexts", "clock_samples"):
            result[field] = result[field][1:]
        result["counts"] = {"49": 1}
        validate_consumer(result, capture, held=True)
        with self.assertRaises(ValueError):
            validate_consumer(result, capture)
        for counts in ({}, {"49": 2}, {"49": 1, "53": 1}):
            with self.subTest(counts=counts), self.assertRaises(ValueError):
                validate_consumer(dict(result, counts=counts), capture, held=True)
        inherited = copy.deepcopy(capture)
        down = next(row for row in inherited["records"] if row["usage"] == 44 and row["value"] == 1)
        inherited["records"].insert(0, dict(down))
        with self.assertRaises(ValueError):
            validate_consumer(result, inherited, held=True)

    def test_native_consumer_requires_trusted_exact_field_focus(self):
        capture, result = receipt()
        validate_consumer(result, capture)
        for field, value in (("source", "DOM"), ("accessibility", False), ("fixture_id", True), ("focused_id", 53),
                             ("value", False), ("role", "AXWindow")):
            altered = copy.deepcopy(result)
            altered["field_focus"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "field focus"):
                validate_consumer(altered, capture)

    def test_native_consumer_requires_distinct_observed_privacy_transitions(self):
        capture, result = receipt()
        validate_consumer(result, capture)
        for probe in (None, [], result["context_probe"][:-1],
                      [dict(row, observation=2) for row in result["context_probe"]],
                      [dict(row, phase="public") for row in result["context_probe"]],
                      [dict(row, observation=True) for row in result["context_probe"]]):
            with self.subTest(probe=probe), self.assertRaisesRegex(ValueError, "context probe"):
                validate_consumer(dict(result, context_probe=probe), capture)

    def test_native_context_receipt_rejects_fabricated_app_and_arrival_time(self):
        capture, result = receipt()
        for field, value in (("context_source", "synthetic"), ("context_stopped", False),
                             ("context_observations", [])):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_consumer(dict(result, **{field: value}), capture)
        for field, value in (("app", "ArrivalApp"), ("timestamp", "2026-09-12 12:00:00.000")):
            altered = copy.deepcopy(result)
            altered["presses"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_consumer(altered, capture)
        altered = copy.deepcopy(result)
        altered["context_observations"][0]["allowed"] = False
        with self.assertRaisesRegex(ValueError, "retain private context"):
            validate_consumer(altered, capture)

    def test_native_context_validator_selects_original_observation_and_excludes_private_input(self):
        result = {"context_source": "native app/window/AX", "context_stopped": True,
                  "clock": {"version": 1, "domain": "mach_absolute_time", "numer": 1, "denom": 1},
                  "context_observations": [
                      {"observed_ns": "0", "allowed": True, "app": "Original", "epoch": 1000},
                      {"observed_ns": "2000000000", "allowed": False},
                      {"observed_ns": "3000000000", "allowed": True, "app": "Current", "epoch": 2000}],
                  "presses": [{"app": "Original", "timestamp": datetime.fromtimestamp(1001).strftime("%Y-%m-%d %H:%M:%S.000")}]}
        rows = [{"timestamp": 1000000000}, {"timestamp": 2000000000}]
        validate_context(result, rows)
        result["context_observations"][0]["observed_ns"] = "1000000001"
        with self.assertRaisesRegex(ValueError, "predates native context"):
            validate_context(result, rows)

    def test_native_clock_scale_rejects_coercion_and_missing_information(self):
        scale = {"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3}
        self.assertEqual(read_clock(scale), scale)
        for field, value in (("version", True), ("domain", "wall_clock"), ("numer", 0),
                             ("denom", 0), ("numer", "125"), ("denom", 3.0),
                             ("numer", 1 << 32), ("denom", -1)):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                read_clock(dict(scale, **{field: value}))
        for field in scale:
            with self.subTest(missing=field), self.assertRaises(ValueError):
                read_clock({key: value for key, value in scale.items() if key != field})

    def test_original_clock_is_scaled_and_bounded_by_native_capture_and_delivery(self):
        rows = [{"timestamp": 45824088534}, {"timestamp": 45828488808}]
        result = {"clock": {"version": 1, "domain": "mach_absolute_time", "numer": 125, "denom": 3},
                  "capture_started_ns": "1900000000000", "clock_samples": [
                      {"original_ns": "1909337022250", "observed_ns": "1910000000000"},
                      {"original_ns": "1909520367000", "observed_ns": "1911000000000"}]}
        validate_clock(result, rows)
        for field, value in (("original_ns", "45824088534"), ("original_ns", "1910000000000"),
                             ("original_ns", "1909337022251"), ("observed_ns", "1909337022249")):
            altered = copy.deepcopy(result)
            altered["clock_samples"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_clock(altered, rows)
        for field, value in (("clock_samples", []), ("capture_started_ns", "1910000000000")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_clock(dict(result, **{field: value}), rows)

    def test_requires_physical_pair_and_complete_native_settlement(self):
        capture, result = receipt()
        validate_consumer(result, capture)
        for field, value in (("runtime", "Lua fixture"), ("coverage", "complete"), ("settled", False),
                             ("stop_requested", False), ("error_count", False), ("error_count", 1),
                             ("errors", ["failure"]),
                             ("exit", 143.0), ("exit", 0), ("counts", {"49": 2, "53": 0}),
                             ("counts", {"49": True, "53": 1}), ("presses", [])):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_consumer(dict(result, **{field: value}), capture)
        with self.assertRaises(ValueError):
            validate_consumer(dict(result, presses=[], contexts=[]), {"records": []})

    def test_rejects_changed_original_context_or_physical_key(self):
        capture, result = receipt()
        for group, field, value in (("contexts", "timestamp", "0"), ("contexts", "device", "9"),
                                    ("presses", "keycode", 49), ("presses", "device", "9")):
            altered = copy.deepcopy(result)
            altered[group][0][field] = value
            with self.subTest(group=group, field=field), self.assertRaises(ValueError):
                validate_consumer(altered, capture)

    def test_receipt_requires_observed_native_process_and_actual_task_exit(self):
        _, result = receipt()
        with tempfile.TemporaryDirectory(prefix="hs274-consumer-") as directory:
            path = Path(directory) / "result.json"
            native = SimpleNamespace(matching=lambda _: [42])
            client = CaptureReceipt(path, native, Path("owned-executable"))
            self.assertIsNone(client.poll())
            path.write_text(json.dumps(result), encoding="utf-8")
            self.assertEqual(client.poll(), 143)
            self.assertTrue(client.observed)
            native.matching = lambda _: []
            unseen = CaptureReceipt(path, native, Path("owned-executable"))
            with self.assertRaisesRegex(RuntimeError, "No exact Hammerspoon"):
                unseen.poll()
            for field, value in (("settled", False), ("exit", 143.0), ("error_count", 1), ("error_count", False)):
                path.write_text(json.dumps(dict(result, **{field: value})), encoding="utf-8")
                with self.subTest(field=field), self.assertRaises(RuntimeError):
                    client.poll()


if __name__ == "__main__":
    unittest.main()
