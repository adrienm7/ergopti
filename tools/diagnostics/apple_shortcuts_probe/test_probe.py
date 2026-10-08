# tools/diagnostics/apple_shortcuts_probe/test_probe.py
"""Portable closed-parser/registration controls; never claim native qualification."""

import json
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import run_probe as subject


class Controls(unittest.TestCase):
    def test_independent_structured_names_and_ids(self):
        raw = json.dumps(
            {
                "version": 1,
                "status": "observed",
                "choices": [
                    {"id": "first", "name": "日本 e\u0301\n%PATH%", "accepts_input": False},
                    {"id": "second", "name": "日本 e\u0301\n%PATH%", "accepts_input": True},
                ],
                "truncated": False,
            }
        ).encode()
        self.assertEqual(
            subject.validate(raw), {"observed": True, "observed_choices": 2, "truncated": False}
        )

    def test_permission_refusal_stays_failed_observation(self):
        raw = b'{"version":1,"status":"refused","stage":1,"reason":"automation_permission_refused"}'
        self.assertEqual(
            subject.validate(raw),
            {
                "observed": False,
                "status": "refused",
                "stage": 1,
                "reason": "automation_permission_refused",
            },
        )

    def test_empty_observation_does_not_qualify_invocation(self):
        result = subject.validate(
            b'{"version":1,"status":"observed","choices":[],"truncated":false}'
        )
        self.assertEqual(result, {"observed": True, "observed_choices": 0, "truncated": False})
        self.assertNotIn("invocation_qualified", result)

    def test_private_refusal_fields_are_rejected(self):
        for raw in (
            b'{"version":1,"status":"refused","stage":1,"reason":"PRIVATE name"}',
            b'{"version":1,"status":"refused","stage":true,"reason":"native_refused"}',
            b'{"version":1,"status":"refused","stage":1,"reason":"native_refused","error":"PRIVATE"}',
        ):
            with self.assertRaises(ValueError):
                subject.validate(raw)

    def test_duplicate_fields_ids_and_malformed_census(self):
        for raw in (
            b'{"version":1,"version":1}',
            b'{"version":1,"status":"observed","choices":{},"truncated":false}',
            b'{"version":1,"status":"observed","choices":[],"truncated":0}',
            b'{"version":true,"status":"observed","choices":[],"truncated":false}',
        ):
            with self.assertRaises(ValueError):
                subject.validate(raw)
        value = {
            "version": 1,
            "status": "observed",
            "choices": [
                {"id": "same", "name": "one", "accepts_input": False},
                {"id": "same", "name": "two", "accepts_input": False},
            ],
            "truncated": False,
        }
        with self.assertRaises(ValueError):
            subject.validate(json.dumps(value).encode())

    def test_bounded_output_and_names(self):
        with self.assertRaises(ValueError):
            subject.validate(b" " * 65537)
        value = {
            "version": 1,
            "status": "observed",
            "choices": [{"id": "id", "name": "日" * 1366, "accepts_input": False}],
            "truncated": False,
        }
        with self.assertRaises(ValueError):
            subject.validate(json.dumps(value).encode())

    def test_acquisition_handoff_failure_retains_exact_closed_receipt(self):
        retained = type(
            "KnownCapability",
            (),
            {
                "settle": lambda self: self.calls.append("settle") or True,
                "receipt": lambda self: {"closed": True, "worker_pid": 123, "fixture_only": True},
            },
        )()
        retained.calls = []

        def acquire(arguments, native, register, **options):
            register(retained)
            raise KeyboardInterrupt("controlled interrupted handoff")

        ownership = type("Ownership", (), {"acquire_owned": staticmethod(acquire)})()
        evidence = []
        with self.assertRaises(KeyboardInterrupt):
            subject.capture(["fixture"], object(), ownership, evidence, "discovery")
        self.assertEqual(retained.calls, ["settle"])
        self.assertEqual(
            evidence,
            [
                {
                    "role": "discovery",
                    "registered": 1,
                    "retirement_ack": True,
                    "groups": [{"closed": True, "worker_pid": 123, "fixture_only": True}],
                    "observation": evidence[0]["observation"],
                }
            ],
        )

    def test_retirement_refusal_has_no_false_closed_ack(self):
        retained = type(
            "KnownCapability",
            (),
            {
                "settle": lambda self: False,
                "receipt": lambda self: {"closed": False, "fixture_only": True},
            },
        )()

        def acquire(arguments, native, register, **options):
            register(retained)
            raise KeyboardInterrupt("controlled interrupted handoff")

        ownership = type("Ownership", (), {"acquire_owned": staticmethod(acquire)})()
        evidence = []
        with self.assertRaises(ValueError):
            subject.capture(["fixture"], object(), ownership, evidence, "discovery")
        self.assertEqual(
            evidence,
            [
                {
                    "role": "discovery",
                    "registered": 1,
                    "retirement_ack": False,
                    "groups": [{"closed": False, "fixture_only": True}],
                    "observation": evidence[0]["observation"],
                }
            ],
        )


class CaptureDiagnosticControls(unittest.TestCase):
    def capture_case(self, observed, code=0, errors=b"ASCP:1\n", output=b"{}", timeout=False):
        calls = []
        group = SimpleNamespace(process=SimpleNamespace(pid=321, returncode=None))
        group.observe_exit = lambda: calls.append("observe") or observed

        def settle():
            calls.append("settle")
            group.process.returncode = code
            return True

        group.settle = settle
        group.receipt = lambda: {"closed": group.process.returncode is not None}

        def acquire(arguments, native, register, **options):
            register(group)
            options["stdout"].write(output)
            options["stdout"].flush()
            options["stderr"].write(errors)
            options["stderr"].flush()
            return group

        ownership = SimpleNamespace(acquire_owned=acquire)
        evidence = []
        ticks = iter([0, 0, 21, 21]) if timeout else None
        with patch.object(
            subject.time,
            "monotonic",
            side_effect=(lambda: next(ticks)) if timeout else None,
            return_value=0,
        ):
            try:
                raw = subject.capture(["owned-fixture"], object(), ownership, evidence, "discovery")
                failure = None
            except subject.ProbeObservationRefused as error:
                raw, failure = None, error.kind
        self.assertEqual(calls[-1], "settle")
        self.assertEqual(calls.count("settle"), 1)
        return raw, failure, evidence[0]

    def test_checkpoint_prefix_is_closed_ordered_and_content_free(self):
        self.assertEqual(
            subject.checkpoint_summary(b"ASCP:1\nASCP:2\n", "discovery"), {"valid": True, "last": 2}
        )
        for raw in (b"ASCP:2\n", b"ASCP:1\nASCP:1\n", b"ASCP:1\nPRIVATE", b"ASCP:1", b"ASCP:5\n"):
            self.assertEqual(
                subject.checkpoint_summary(raw, "discovery"), {"valid": False, "last": 0}
            )

    def test_actual_capture_deadline_retains_no_precleanup_terminal_and_fixed_stage(self):
        raw, failure, evidence = self.capture_case(None, code=-15, timeout=True)
        self.assertIsNone(raw)
        self.assertEqual(failure, "deadline")
        self.assertTrue(evidence["retirement_ack"])
        self.assertEqual(evidence["observation"]["failure"], "deadline")
        self.assertIsNone(evidence["observation"]["terminal_before_retirement"])
        self.assertEqual(evidence["observation"]["checkpoint"], {"valid": True, "last": 1})

    def test_actual_capture_native_nonzero_keeps_original_wnowait_tuple(self):
        raw, failure, evidence = self.capture_case(
            SimpleNamespace(si_pid=321, si_code=1, si_status=3), code=3
        )
        self.assertIsNone(raw)
        self.assertEqual(failure, "native_exit")
        self.assertEqual(
            evidence["observation"]["terminal_before_retirement"],
            {"pid": 321, "code": 1, "status": 3},
        )

    def test_actual_capture_unknown_diagnostics_never_become_success(self):
        raw, failure, evidence = self.capture_case(
            SimpleNamespace(si_pid=321, si_code=1, si_status=0), errors=b"PRIVATE"
        )
        self.assertIsNone(raw)
        self.assertEqual(failure, "diagnostic_shape")
        self.assertEqual(evidence["observation"]["checkpoint"], {"valid": False, "last": 0})
        self.assertNotIn("PRIVATE", json.dumps(evidence))

    def test_actual_capture_valid_checkpoint_transport_keeps_exact_payload(self):
        raw, failure, evidence = self.capture_case(
            SimpleNamespace(si_pid=321, si_code=1, si_status=0),
            errors=b"ASCP:1\nASCP:2\nASCP:3\nASCP:4\n",
        )
        self.assertEqual(raw, b"{}")
        self.assertIsNone(failure)
        self.assertEqual(evidence["observation"]["checkpoint"], {"valid": True, "last": 4})

    def test_foreign_or_boolean_terminal_sample_refuses_before_acceptance(self):
        for sample in (
            SimpleNamespace(si_pid=322, si_code=1, si_status=0),
            SimpleNamespace(si_pid=321, si_code=True, si_status=0),
        ):
            raw, failure, evidence = self.capture_case(sample)
            self.assertIsNone(raw)
            self.assertEqual(failure, "terminal_shape")
            self.assertTrue(evidence["retirement_ack"])


class ObservationPriorityControls(unittest.TestCase):
    """Exercise actual capture IO and the genuine owner cancellation class only."""

    @classmethod
    def setUpClass(cls):
        path = subject.Path(__file__).resolve().parents[1] / "macos_owned_process.py"
        spec = subject.importlib.util.spec_from_file_location("shortcuts_priority_owner", path)
        cls.native_owner = subject.importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.native_owner)

    def interruptions(self):
        return (
            self.native_owner.OwnedProcessInterrupted("owned interruption"),
            KeyboardInterrupt("keyboard interruption"),
            SystemExit(19),
        )

    def invoke(self, primary=None, diagnostic=None, invalid=False, retirement=None):
        calls = []
        group = SimpleNamespace(process=SimpleNamespace(pid=321, returncode=None))
        group.observe_exit = lambda: SimpleNamespace(si_pid=321, si_code=1, si_status=0)

        def settle():
            calls.append("settle")
            if retirement is not None:
                raise retirement
            group.process.returncode = 0
            return True

        group.settle = settle
        group.receipt = lambda: {"closed": group.process.returncode is not None}

        def acquire(arguments, native, register, **options):
            register(group)
            options["stdout"].write(b"{}")
            options["stderr"].write(b"ASCP:1\n")
            options["stdout"].flush()
            options["stderr"].flush()
            if primary is not None:
                raise primary
            return group

        ownership = SimpleNamespace(
            acquire_owned=acquire,
            OwnedProcessInterrupted=self.native_owner.OwnedProcessInterrupted,
        )
        evidence = []
        fault = (
            patch.object(subject, "_checkpoint_from_capture", side_effect=diagnostic)
            if diagnostic is not None
            else patch.object(
                subject, "_checkpoint_from_capture", return_value={"valid": True, "last": 9}
            )
            if invalid
            else patch.object(
                subject, "_checkpoint_from_capture", wraps=subject._checkpoint_from_capture
            )
        )
        caught, raw = None, None
        with fault:
            try:
                raw = subject.capture(["fixture"], object(), ownership, evidence, "discovery")
            except BaseException as error:
                caught = error
        self.assertEqual(calls, ["settle"])
        self.assertEqual(len(evidence), 1)
        self.assertEqual(evidence[0]["registered"], 1)
        self.assertEqual(evidence[0]["retirement_ack"], retirement is None)
        self.assertEqual(evidence[0]["groups"], [{"closed": retirement is None}])
        self.assertIsNone(raw)
        self.assertNotIn("private capture", json.dumps(evidence))
        return caught, evidence[0]["observation"]

    def test_optional_io_or_shape_refusal_preserves_each_primary_cancellation(self):
        for primary in self.interruptions():
            for kind in ("io", "shape"):
                with self.subTest(primary=type(primary).__name__, fault=kind):
                    caught, observation = self.invoke(
                        primary=primary,
                        diagnostic=OSError("private capture") if kind == "io" else None,
                        invalid=kind == "shape",
                    )
                    self.assertIs(caught, primary)
                    self.assertFalse(observation["metadata_available"])
                    self.assertEqual(
                        observation["metadata_failure"],
                        "capture_io" if kind == "io" else "diagnostic_shape",
                    )
                    self.assertEqual(observation["failure"], "capture_refused")
                    self.assertIsNone(observation["terminal_before_retirement"])
                    self.assertNotIn("checkpoint", observation)

    def test_new_observation_cancellation_wins_over_an_ordinary_primary_error(self):
        for cancellation in self.interruptions():
            with self.subTest(cancellation=type(cancellation).__name__):
                caught, observation = self.invoke(
                    primary=ValueError("original ordinary refusal"), diagnostic=cancellation
                )
                self.assertIs(caught, cancellation)
                self.assertFalse(observation["metadata_available"])
                self.assertEqual(observation["metadata_failure"], "observation_interrupted")

    def test_no_primary_diagnostic_io_and_shape_refusals_cannot_return_success(self):
        for kind in ("io", "shape"):
            with self.subTest(fault=kind):
                caught, observation = self.invoke(
                    diagnostic=OSError("private capture") if kind == "io" else None,
                    invalid=kind == "shape",
                )
                self.assertIsInstance(caught, subject.ProbeObservationRefused)
                self.assertEqual(caught.kind, "capture_io" if kind == "io" else "diagnostic_shape")
                self.assertFalse(observation["metadata_available"])
                self.assertEqual(observation["failure"], caught.kind)
                self.assertEqual(
                    observation["terminal_before_retirement"], {"pid": 321, "code": 1, "status": 0}
                )

    def test_original_retirement_refusal_still_precedes_capture_cancellation(self):
        original = ValueError("original retirement refusal")
        caught, observation = self.invoke(
            primary=self.native_owner.OwnedProcessInterrupted("owned interruption"),
            diagnostic=OSError("private capture"),
            retirement=original,
        )
        self.assertIs(caught, original)
        self.assertFalse(observation["metadata_available"])
        self.assertEqual(observation["metadata_failure"], "capture_io")


if __name__ == "__main__":
    unittest.main()
