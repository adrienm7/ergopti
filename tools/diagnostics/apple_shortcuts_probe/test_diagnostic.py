# tools/diagnostics/apple_shortcuts_probe/test_diagnostic.py
"""Portable process/capture and closed event-frame models, never native proof."""

import importlib.machinery
import json
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_diagnostic as subject
import run_probe as probe

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_owned_process as actual_owner

RAW = b'{"version":1,"status":"observed","choices":[],"truncated":false}'


def frame(phase, stage, kind="undefined", available=False, number=0):
    return (
        b"ASCD:"
        + json.dumps(
            {
                "phase": phase,
                "stage": stage,
                "error_type": kind,
                "error_available": available,
                "error_number": number,
            }
        ).encode()
        + b"\n"
    )


HEALTHY = (
    b"ASCP:1\n"
    + frame("get_entered", 1)
    + frame("get_returned", 1)
    + b"ASCP:2\nASCP:3\n"
    + frame("get_entered", 4)
    + frame("get_returned", 4)
    + b"ASCP:4\n"
)


class Controls(unittest.TestCase):
    def test_complete_original_schema_and_closed_event_trace(self):
        reader = subject.MarkerReader()
        self.assertEqual(reader(HEALTHY, "discovery"), {"valid": True, "last": 4})
        self.assertTrue(reader.available)
        self.assertEqual(len(reader.events), 4)
        self.assertEqual(
            probe.validate(RAW), {"observed": True, "observed_choices": 0, "truncated": False}
        )

    def test_native_failure_number_retained_without_success(self):
        reader = subject.MarkerReader()
        wire = (
            b"ASCP:1\n" + frame("get_entered", 1) + frame("get_failed", 1, "integer", True, -1712)
        )
        self.assertEqual(reader(wire, "discovery"), {"valid": True, "last": 1})
        self.assertEqual(reader.events[-1]["error_number"], -1712)
        raw = b'{"version":1,"status":"refused","stage":1,"reason":"native_refused"}'
        self.assertFalse(probe.validate(raw)["observed"])

    def test_zero_native_number_is_available_but_not_a_success_code(self):
        reader = subject.MarkerReader()
        self.assertTrue(reader(frame("get_failed", 1, "integer", True, 0), "discovery")["valid"])
        self.assertTrue(reader.events[-1]["error_available"])
        self.assertFalse(
            probe.validate(b'{"version":1,"status":"refused","stage":1,"reason":"native_refused"}')[
                "observed"
            ]
        )

    def test_unknown_private_fields_types_bounds_and_duplicate_keys_refuse(self):
        examples = [
            HEALTHY + b"PRIVATE name\n",
            frame("PRIVATE", 1),
            frame("get_failed", True),
            frame("get_failed", 1, "PRIVATE"),
            frame("get_failed", 1, "integer", True, 2147483648),
            frame("get_failed", 1, "string", False, 99),
            frame("get_failed", 1, "integer", False, 0),
            b'ASCD:{"phase":"get_failed","phase":"get_failed"}\n',
            b"\xff",
            b"x" * 65537,
        ]
        for wire in examples:
            with self.subTest(wire_length=len(wire)):
                reader = subject.MarkerReader()
                self.assertEqual(reader(wire, "discovery"), {"valid": False, "last": 0})
                self.assertFalse(reader.available)
                self.assertEqual(reader.events, [])

    def test_out_of_order_and_post_failure_frames_refuse(self):
        for wire in (
            frame("get_entered", 1),
            b"ASCP:2\n",
            HEALTHY + frame("get_failed", 1),
            frame("get_failed", 1) + b"ASCP:1\n",
            HEALTHY + HEALTHY,
        ):
            self.assertFalse(subject.MarkerReader()(wire, "discovery")["valid"])

    def test_missing_diagnostic_is_unavailable_and_no_native_tuple_is_invented(self):
        reader = subject.MarkerReader()
        self.assertEqual(reader(b"ASCP:1\n", "discovery"), {"valid": True, "last": 1})
        self.assertFalse(reader.available)
        self.assertEqual(reader.events, [])

    def capture(self, clock, *, raw=RAW, errors=HEALTHY, primary=None, metadata=None):
        evidence = []
        timeline = []
        process = SimpleNamespace(pid=42, returncode=None)
        group = SimpleNamespace(process=process, receipt=lambda: {"closed": True, "worker_pid": 42})

        def acquire(_args, _native, register, **ports):
            register(group)
            timeline.append("acquire")
            ports["stdout"].write(raw)
            ports["stderr"].write(errors)
            return group

        def observe():
            timeline.append("observe")
            if primary is not None:
                raise primary
            return SimpleNamespace(si_pid=42, si_code=1, si_status=0)

        def retire(owners):
            self.assertEqual(owners, [group] if "acquire" in timeline else [])
            timeline.append("retire")
            process.returncode = 0

        group.observe_exit = observe
        ownership = SimpleNamespace(
            acquire_owned=acquire, OwnedProcessInterrupted=actual_owner.OwnedProcessInterrupted
        )
        reader = subject.MarkerReader()
        if metadata is not None:

            def markers(_raw, _role):
                raise metadata
        else:
            markers = reader
        with (
            patch.object(probe.time, "monotonic", side_effect=clock),
            patch.object(probe, "retire", side_effect=retire),
        ):
            try:
                value = probe.capture(
                    ["owned-model"],
                    None,
                    ownership,
                    evidence,
                    "discovery",
                    deadline=20,
                    marker_reader=markers,
                )
                return value, evidence, timeline, None
            except BaseException as error:
                return None, evidence, timeline, error

    def test_actual_capture_uses_original_owner_and_retirement_before_receipt(self):
        value, evidence, timeline, error = self.capture([0, 0, 0, 1, 2])
        self.assertIsNone(error)
        self.assertEqual(value, RAW)
        self.assertEqual(timeline, ["acquire", "observe", "retire"])
        self.assertEqual(
            evidence[0]["observation"]["terminal_before_retirement"],
            {"pid": 42, "code": 1, "status": 0},
        )
        self.assertTrue(evidence[0]["retirement_ack"])

    def test_setup_exhaustion_refuses_before_acquisition(self):
        _, evidence, timeline, error = self.capture([0, 20, 21])
        self.assertEqual(timeline, ["retire"], "expired_setup_must_not_acquire")
        self.assertIsInstance(error, probe.ProbeObservationRefused)
        self.assertEqual(error.kind, "deadline")
        self.assertEqual(evidence[0]["registered"], 0)

    def test_late_actual_terminal_tuple_cannot_be_admitted(self):
        _, evidence, timeline, error = self.capture(
            [0, 0, 20.02, 21], metadata=OSError("PRIVATE optional capture")
        )
        self.assertIsInstance(
            error, probe.ProbeObservationRefused, "late_terminal_must_remain_refused"
        )
        self.assertEqual(
            error.kind, "deadline", "late_terminal_first_cause_must_survive_metadata_io"
        )
        self.assertEqual(
            evidence[0]["observation"]["terminal_before_retirement"],
            {"pid": 42, "code": 1, "status": 0},
        )
        self.assertEqual(timeline[-1], "retire")

    def test_post_capture_tail_expiration_keeps_real_native_zero_and_refuses(self):
        _, evidence, _, error = self.capture([0, 0, 0, 1, 20.02])
        self.assertIsInstance(
            error, probe.ProbeObservationRefused, "late_capture_tail_must_remain_refused"
        )
        self.assertEqual(error.kind, "deadline")
        self.assertTrue(evidence[0]["retirement_ack"])
        self.assertEqual(evidence[0]["observation"]["terminal_before_retirement"]["status"], 0)

    def test_actual_capture_primary_cancellation_survives_optional_metadata_failure(self):
        for primary in (
            actual_owner.OwnedProcessInterrupted("probe_interrupted"),
            KeyboardInterrupt(),
            SystemExit(7),
            probe.ProbeObservationRefused("deadline"),
        ):
            _, evidence, timeline, error = self.capture(
                [0, 0, 1], primary=primary, metadata=OSError("PRIVATE path")
            )
            self.assertIs(error, primary)
            self.assertEqual(timeline[-1], "retire")
            self.assertEqual(evidence[0]["observation"]["metadata_failure"], "capture_io")
            self.assertNotIn("PRIVATE", json.dumps(evidence))

    def test_new_cancellation_wins_over_ordinary_primary(self):
        cancellation = KeyboardInterrupt()
        _, _, timeline, error = self.capture(
            [0, 0, 1], primary=ValueError("PRIVATE"), metadata=cancellation
        )
        self.assertIs(error, cancellation)
        self.assertEqual(timeline[-1], "retire")

    def test_observe_forwards_remaining_not_fresh_budget_and_fixed_native_command(self):
        evidence = []
        ownership = SimpleNamespace(NativeProcessGroups=lambda: "native-port")
        with (
            patch.object(subject.time, "monotonic", return_value=12),
            patch.object(probe, "capture", return_value=RAW) as call,
        ):
            result = subject.observe(
                Path("owned-model"), ownership, 20, evidence, subject.MarkerReader()
            )
        self.assertTrue(result["observed"])
        self.assertEqual(call.call_args.args[0][-1], "8000")
        self.assertEqual(call.call_args.args[0][:3], ["/usr/bin/osascript", "-l", "JavaScript"])
        self.assertEqual(call.call_args.kwargs["deadline"], 20)
        self.assertNotIn("shortcuts", call.call_args.args[0][:3])

    def main_model(self, primary=None, publication=None, print_error=None):
        root = Path(__file__).resolve().parents[3]

        class Loader:
            def create_module(self, _spec):
                return None

            def exec_module(self, module):
                module.OwnedProcessInterrupted = actual_owner.OwnedProcessInterrupted

        spec = importlib.machinery.ModuleSpec("native_shortcuts_owner", Loader())

        def observed(_root, _ownership, _deadline, _evidence, reader):
            reader(HEALTHY, "discovery")
            if primary is not None:
                raise primary
            return {"observed": True, "observed_choices": 0, "truncated": False}

        def committed(args, cwd):
            self.assertEqual(cwd, root)
            return (root / args[2].split(":", 1)[1]).read_bytes()

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "public"
            argv = [
                "run_diagnostic.py",
                "--source-root",
                str(root),
                "--source-sha",
                "a" * 40,
                "--output",
                str(output),
            ]
            with (
                patch.object(subject.sys, "argv", argv),
                patch.object(subject.sys, "platform", "darwin"),
                patch.object(subject.subprocess, "check_output", side_effect=committed),
                patch.object(subject.importlib.util, "spec_from_file_location", return_value=spec),
                patch.object(subject.signal, "signal"),
                patch.object(subject, "observe", side_effect=observed),
                patch("builtins.print", side_effect=print_error),
            ):
                if publication is not None:
                    with patch.object(Path, "write_text", side_effect=publication):
                        return subject.main(), None
                status = subject.main()
            return status, json.loads((output / "observation.json").read_text(encoding="utf-8"))

    def test_actual_main_preserves_owned_cancellation_and_baseexceptions_on_publication_io(self):
        for primary in (
            actual_owner.OwnedProcessInterrupted("probe_interrupted"),
            KeyboardInterrupt(),
            SystemExit(7),
        ):
            try:
                self.main_model(primary=primary, publication=OSError("PRIVATE path"))
            except BaseException as error:
                self.assertIs(error, primary, "primary_cancellation_was_replaced")
            else:
                self.fail("primary_cancellation_was_swallowed")

    def test_actual_main_new_cancellation_wins_over_ordinary_primary(self):
        for cancellation in (
            actual_owner.OwnedProcessInterrupted("probe_interrupted"),
            KeyboardInterrupt(),
            SystemExit(9),
        ):
            try:
                self.main_model(primary=ValueError("PRIVATE error"), print_error=cancellation)
            except BaseException as error:
                self.assertIs(error, cancellation)
            else:
                self.fail("new_publication_cancellation_was_swallowed")

    def test_actual_main_publication_io_without_primary_remains_refused(self):
        with self.assertRaises(probe.ProbeObservationRefused) as context:
            self.main_model(publication=OSError("PRIVATE path"))
        self.assertEqual(context.exception.kind, "diagnostic_publication")

    def test_actual_main_only_observes_and_never_qualifies_features(self):
        status, result = self.main_model()
        self.assertEqual(status, 0)
        self.assertFalse(result["feature_qualified"])
        self.assertFalse(result["invocation_qualified"])
        self.assertFalse(result["automation_cancellation_qualified"])
        self.assertEqual(result["permission"], "not_determined")
        self.assertEqual(result["inventory"]["observed_choices"], 0)
        self.assertEqual(
            result["physical_operations"], []
        )  # The orchestration port acquires nothing.
        self.assertNotIn("PRIVATE", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
