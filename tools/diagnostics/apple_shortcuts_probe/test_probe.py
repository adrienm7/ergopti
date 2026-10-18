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


class PermissionPreflightControls(unittest.TestCase):
    capture_case = CaptureDiagnosticControls.capture_case
    first = b"ASCP:1\nASCP:P:BEGIN\n"
    attempted = first + b"ASCP:P:CALL_ATTEMPT\n"
    tail = b"ASCP:2\nASCP:3\nASCP:4\n"

    def returned(self, code):
        return self.attempted + b"ASCP:P:RETURN:" + str(code).encode("ascii") + b"\n"

    def test_original_absence_is_exact_original_checkpoint_and_metadata_shape(self):
        for markers in (b"", b"ASCP:1\n", b"ASCP:1\n" + self.tail):
            raw, observation = subject.permission_preflight_summary(markers, "discovery")
            self.assertEqual(raw, markers)
            self.assertEqual(
                observation, {"state": "absent", "call_attempted": False, "native_returned": False}
            )
        _, failure, evidence = self.capture_case(
            SimpleNamespace(si_pid=321, si_code=1, si_status=0)
        )
        self.assertIsNone(failure)
        self.assertNotIn("permission_preflight", evidence["observation"])

    def test_native_returned_signed32_is_observation_not_catalogue_or_authority(self):
        for code in (0, -600, -1743, -1744, -2147483648, 2147483647, 71):
            markers = self.returned(code) + self.tail
            raw, observation = subject.permission_preflight_summary(markers, "discovery")
            self.assertEqual(raw, b"ASCP:1\n" + self.tail)
            self.assertEqual(
                observation,
                {
                    "state": "observed",
                    "call_attempted": True,
                    "native_returned": True,
                    "code": code,
                },
            )
            self.assertEqual(
                subject.checkpoint_summary(markers, "discovery"), {"valid": True, "last": 4}
            )
            self.assertNotIn("permission_granted", observation)
            self.assertNotIn("catalogue_observed", observation)
            self.assertNotIn("invocation_qualified", observation)

    def test_incomplete_bridge_and_unreturned_call_are_distinct_not_native_status(self):
        for markers, state, attempted in (
            (self.first, "preparing", False),
            (self.attempted, "call_unreturned", True),
        ):
            raw, observation = subject.permission_preflight_summary(markers, "discovery")
            self.assertEqual(raw, b"ASCP:1\n")
            self.assertEqual(
                observation, {"state": state, "call_attempted": attempted, "native_returned": False}
            )
            self.assertNotIn("code", observation)

    def test_closed_refusals_preserve_ordered_original_catalogue_checkpoints(self):
        for start, ending, state, attempted in (
            (self.first, b"UNAVAILABLE", "bridge_unavailable", False),
            (self.first, b"REFUSED", "bridge_refused", False),
            (self.attempted, b"REFUSED", "bridge_refused", True),
            (self.attempted, b"INVALID", "invalid_native_status", True),
        ):
            for tail in (b"", b"ASCP:2\n", self.tail):
                markers = start + b"ASCP:P:" + ending + b"\n" + tail
                raw, observation = subject.permission_preflight_summary(markers, "discovery")
                self.assertEqual(raw, b"ASCP:1\n" + tail)
                self.assertEqual(
                    observation,
                    {"state": state, "call_attempted": attempted, "native_returned": False},
                )

    def test_noncanonical_or_non_osstatus_codes_cannot_enter_evidence(self):
        for code in (
            b"+0",
            b"-0",
            b"00",
            b" 0",
            b"0 ",
            b"0.0",
            b"True",
            b"2147483648",
            b"-2147483649",
            b"PRIVATE",
            b"\xff",
            b"1_0",
        ):
            markers = self.attempted + b"ASCP:P:RETURN:" + code + b"\n"
            raw, observation = subject.permission_preflight_summary(markers, "discovery")
            self.assertIsNone(raw)
            self.assertEqual(observation["state"], "invalid_grammar")
            self.assertNotIn("code", observation)
            self.assertNotIn("PRIVATE", json.dumps(observation))
            self.assertEqual(
                subject.checkpoint_summary(markers, "discovery"), {"valid": False, "last": 0}
            )

    def test_duplicate_foreign_wrong_phase_and_truncated_line_refuse(self):
        for markers in (
            b"ASCP:P:BEGIN\n",
            b"ASCP:1\nASCP:2\nASCP:P:BEGIN\n",
            self.first + b"ASCP:P:BEGIN\n",
            self.first + b"ASCP:P:RETURN:0\n",
            self.attempted + b"ASCP:P:UNAVAILABLE\n",
            self.first + b"ASCP:P:INVALID\n",
            self.returned(0) + self.returned(0),
            self.returned(0) + b"ASCP:3\n",
            self.returned(0) + b"ASCP:2\nASCP:2\n",
            self.attempted + b"ASCP:P:RETURN:0",
            self.returned(0) + b"PRIVATE",
            self.first + b"ASCP:P:REFUSED:PRIVATE\n",
            self.attempted + b"ASCP:P:CALL_ATTEMPT\n",
            self.returned(0) + b"ASCP:1\n",
        ):
            raw, observation = subject.permission_preflight_summary(markers, "discovery")
            self.assertIsNone(raw)
            self.assertEqual(observation["state"], "invalid_grammar")
            self.assertEqual(
                subject.checkpoint_summary(markers, "discovery"), {"valid": False, "last": 0}
            )

    def test_wrong_role_types_and_stream_cap_remain_refused(self):
        markers = self.returned(0) + self.tail
        for role in ("help", "foreign", None):
            self.assertEqual(subject.checkpoint_summary(markers, role), {"valid": False, "last": 0})
        for malformed in (bytearray(markers), "ASCP:1\n", None, b" " * 65537):
            raw, observation = subject.permission_preflight_summary(malformed, "discovery")
            self.assertIsNone(raw)
            self.assertEqual(observation["state"], "invalid_grammar")

    def test_actual_owned_capture_zero_observation_keeps_payload_and_original_exit_oracle(self):
        for code in (0, -600, -1744):
            raw, failure, evidence = self.capture_case(
                SimpleNamespace(si_pid=321, si_code=1, si_status=0),
                errors=self.returned(code) + self.tail,
                output=b"ORIGINAL payload",
            )
            self.assertEqual(raw, b"ORIGINAL payload")
            self.assertIsNone(failure)
            self.assertTrue(evidence["retirement_ack"])
            self.assertEqual(evidence["registered"], 1)
            self.assertEqual(evidence["observation"]["permission_preflight"]["code"], code)
            self.assertEqual(evidence["observation"]["checkpoint"], {"valid": True, "last": 4})
        raw, failure, evidence = self.capture_case(
            SimpleNamespace(si_pid=321, si_code=1, si_status=3),
            code=3,
            errors=self.returned(0) + self.tail,
        )
        self.assertIsNone(raw)
        self.assertEqual(failure, "native_exit")
        self.assertTrue(evidence["retirement_ack"])

    def test_unreturned_capture_preserves_original_deadline_and_exact_retirement(self):
        raw, failure, evidence = self.capture_case(
            None, code=-15, timeout=True, errors=self.attempted
        )
        self.assertIsNone(raw)
        self.assertEqual(failure, "deadline")
        self.assertTrue(evidence["retirement_ack"])
        self.assertEqual(evidence["observation"]["checkpoint"], {"valid": True, "last": 1})
        self.assertEqual(
            evidence["observation"]["permission_preflight"],
            {"state": "call_unreturned", "call_attempted": True, "native_returned": False},
        )

    def test_malformed_optional_stream_cannot_turn_owned_capture_into_success(self):
        raw, failure, evidence = self.capture_case(
            SimpleNamespace(si_pid=321, si_code=1, si_status=0),
            errors=self.returned(2147483648) + self.tail,
        )
        self.assertIsNone(raw)
        self.assertEqual(failure, "diagnostic_shape")
        self.assertTrue(evidence["retirement_ack"])
        self.assertFalse(evidence["observation"]["metadata_available"])

    def test_exact_existing_owned_terminal_binding_remains_mandatory(self):
        for sample in (
            SimpleNamespace(si_pid=999, si_code=1, si_status=0),
            SimpleNamespace(si_pid=321, si_code=True, si_status=0),
        ):
            raw, failure, evidence = self.capture_case(sample, errors=self.returned(0) + self.tail)
            self.assertIsNone(raw)
            self.assertEqual(failure, "terminal_shape")
            self.assertTrue(evidence["retirement_ack"])

    def test_parser_observation_does_not_replace_original_catalogue_schema(self):
        self.assertEqual(
            subject.validate(
                b'{"version":1,"status":"refused","stage":1,"reason":"native_refused"}'
            ),
            {"observed": False, "status": "refused", "stage": 1, "reason": "native_refused"},
        )
        with self.assertRaises(ValueError):
            subject.validate(
                b'{"version":1,"status":"observed","choices":[],"truncated":false,"permission_granted":true}'
            )


class UnavailableRefinementControls(unittest.TestCase):
    capture_case = CaptureDiagnosticControls.capture_case
    first = b"ASCP:1\nASCP:P:BEGIN\n"

    def test_fixed_failure_labels_preserve_original_refusal_and_catalogue_checkpoints(self):
        for label, part in (
            (b"API", "api"),
            (b"METADATA", "metadata"),
            (b"CONSTANTS", "constants"),
            (b"DESCRIPTOR", "descriptor"),
            (b"POINTER", "pointer"),
        ):
            for tail in (b"", b"ASCP:2\n", b"ASCP:2\nASCP:3\nASCP:4\n"):
                markers = self.first + b"ASCP:B:" + label + b"\nASCP:P:UNAVAILABLE\n" + tail
                raw, observation = subject.permission_preflight_summary(markers, "discovery")
                self.assertEqual(raw, b"ASCP:1\n" + tail)
                self.assertEqual(
                    observation,
                    {
                        "state": "bridge_unavailable",
                        "call_attempted": False,
                        "native_returned": False,
                        "unavailable_part": part,
                    },
                )
                self.assertNotIn("code", observation)
                self.assertNotIn("permission_granted", observation)

    def test_unknown_duplicate_foreign_or_post_call_failure_annotation_refuses(self):
        for middle in (
            b"ASCP:B:PRIVATE\n",
            b"ASCP:B:api\n",
            b"ASCP:B:API",
            b"ASCP:B:API\nASCP:B:POINTER\n",
            b"ASCP:P:CALL_ATTEMPT\nASCP:B:API\n",
            b"ASCP:B:API\nASCP:P:CALL_ATTEMPT\n",
            b"ASCP:B:API\nASCP:P:RETURN:0\n",
        ):
            markers = self.first + middle + b"ASCP:P:UNAVAILABLE\n"
            raw, observation = subject.permission_preflight_summary(markers, "discovery")
            self.assertIsNone(raw)
            self.assertEqual(observation["state"], "invalid_grammar")
            self.assertNotIn("PRIVATE", json.dumps(observation))
        for ending in (
            b"ASCP:P:REFUSED\n",
            b"ASCP:P:INVALID\n",
            b"ASCP:P:RETURN:0\n",
            b"ASCP:P:CALL_ATTEMPT\nASCP:P:REFUSED\n",
        ):
            markers = self.first + b"ASCP:B:API\n" + ending
            raw, observation = subject.permission_preflight_summary(markers, "discovery")
            self.assertIsNone(raw)
            self.assertEqual(observation["state"], "invalid_grammar")
        valid = self.first + b"ASCP:B:API\nASCP:P:UNAVAILABLE\n"
        for role in ("help", "foreign", None):
            self.assertEqual(subject.checkpoint_summary(valid, role), {"valid": False, "last": 0})

    def test_actual_owned_deadline_retirement_preserves_failure_only_refinement(self):
        markers = self.first + b"ASCP:B:API\nASCP:P:UNAVAILABLE\n"
        raw, failure, evidence = self.capture_case(None, code=-15, timeout=True, errors=markers)
        self.assertIsNone(raw)
        self.assertEqual(failure, "deadline")
        self.assertTrue(evidence["retirement_ack"])
        self.assertEqual(evidence["registered"], 1)
        self.assertEqual(evidence["observation"]["checkpoint"], {"valid": True, "last": 1})
        self.assertEqual(
            evidence["observation"]["permission_preflight"],
            {
                "state": "bridge_unavailable",
                "call_attempted": False,
                "native_returned": False,
                "unavailable_part": "api",
            },
        )


class CaptureBudgetControls(unittest.TestCase):
    """Clock ports exercise actual capture without any native Mac invocation."""

    def invoke(self, acquisition_elapsed, observation_elapsed, native_status=0):
        now = [0.0]
        calls = []
        sample = SimpleNamespace(si_pid=321, si_code=1, si_status=native_status)
        group = SimpleNamespace(process=SimpleNamespace(pid=321, returncode=None))

        def observe():
            calls.append("observe")
            now[0] += observation_elapsed
            return sample

        def settle():
            calls.append("settle")
            group.process.returncode = native_status
            return True

        group.observe_exit = observe
        group.settle = settle
        group.receipt = lambda: {"closed": group.process.returncode is not None}

        def acquire(arguments, native, register, **options):
            calls.append("acquire")
            register(group)
            options["stdout"].write(b"{}")
            options["stderr"].write(b"ASCP:1\n")
            options["stdout"].flush()
            options["stderr"].flush()
            now[0] += acquisition_elapsed
            return group

        evidence = []
        ownership = SimpleNamespace(acquire_owned=acquire)
        caught, raw = None, None
        with patch.object(subject.time, "monotonic", side_effect=lambda: now[0]):
            try:
                raw = subject.capture(["fixture"], object(), ownership, evidence, "discovery")
            except subject.ProbeObservationRefused as error:
                caught = error.kind
        self.assertEqual(calls, ["acquire", "observe", "settle"])
        self.assertEqual(len(evidence), 1)
        self.assertTrue(evidence[0]["retirement_ack"])
        self.assertEqual(evidence[0]["groups"], [{"closed": True}])
        self.assertEqual(
            evidence[0]["observation"]["terminal_before_retirement"],
            {"pid": 321, "code": 1, "status": native_status},
        )
        self.assertEqual(group.process.returncode, native_status)
        return raw, caught, evidence[0]["observation"]

    def test_actual_capture_acquisition_consumes_original_budget(self):
        raw, failure, observation = self.invoke(19.0, 0.0)
        self.assertEqual(raw, b"{}")
        self.assertIsNone(failure)
        self.assertEqual(observation["failure"], "none")
        raw, failure, observation = self.invoke(20.0, 0.0)
        self.assertIsNone(raw)
        self.assertEqual(failure, "deadline", "acquisition must not start a fresh budget")
        self.assertEqual(observation["failure"], "deadline")
        self.assertEqual(observation["elapsed_us"], 20000000)

    def test_actual_capture_late_terminal_refuses_without_rewriting_native_facts(self):
        raw, failure, observation = self.invoke(0.0, 19.0)
        self.assertEqual(raw, b"{}")
        self.assertIsNone(failure)
        for native_status in (0, 3):
            with self.subTest(native_status=native_status):
                raw, failure, observation = self.invoke(0.0, 20.125, native_status)
                self.assertIsNone(raw)
                self.assertEqual(failure, "deadline", "a late terminal cannot bypass deadline")
                self.assertEqual(observation["failure"], "deadline")
                self.assertEqual(observation["elapsed_us"], 20125000)


def preflight_record(status):
    """Encode the native helper's closed record exactly as sdk_constants.c prints it."""
    return ('{"mode":"permission_preflight","status":%d,"version":1}\n' % status).encode()


class NativePreflightGateControls(unittest.TestCase):
    """Drive the real preflight gate and capture with scripted owned groups.

    The build has no leases, so these cases need no POSIX file modes and run on
    every host. They would fail against the old probe, which started osascript
    and its catalogue Apple event whatever the preflight answered.
    """

    image = "/controlled/sdk-build/sdk_constants"
    script = "/controlled/discover.js"
    launch = ["/usr/bin/open", "-g", "-j", "-b", "com.apple.shortcuts.events"]
    inventory = json.dumps(
        {
            "version": 1,
            "status": "observed",
            "choices": [
                {"id": "first", "name": "日本 é\n%PATH%", "accepts_input": False},
                {"id": "second", "name": "日本 é\n%PATH%", "accepts_input": True},
            ],
            "truncated": False,
        }
    ).encode()

    def run_gate(self, statuses, *, preflight_elapsed=0.0, launch=(0, b"", b""), catalogue=None):
        now = [0.0]
        calls, groups = [], []
        pending = list(statuses)

        def acquire(arguments, native, register, **options):
            arguments = list(arguments)
            calls.append(arguments)
            if arguments == [self.image, "--permission-preflight"]:
                status = pending.pop(0) if len(pending) > 1 else pending[0]
                code, raw, errors = 0, preflight_record(status), b""
                now[0] += preflight_elapsed
            elif arguments == self.launch:
                code, raw, errors = launch
            elif arguments[0] == "/usr/bin/osascript":
                code = 0
                raw = self.inventory if catalogue is None else catalogue
                errors = b"ASCP:1\nASCP:2\nASCP:3\nASCP:4\n"
            else:
                raise AssertionError("unexpected controlled acquisition argv")
            group = SimpleNamespace(process=SimpleNamespace(pid=321, returncode=None))
            group.settle_calls = 0
            group.observe_exit = lambda: SimpleNamespace(si_pid=321, si_code=1, si_status=code)

            def settle():
                group.settle_calls += 1
                group.process.returncode = code
                return True

            group.settle = settle
            group.receipt = lambda: {"closed": group.process.returncode is not None}
            groups.append(group)
            register(group)
            options["stdout"].write(raw)
            options["stderr"].write(errors)
            options["stdout"].flush()
            options["stderr"].flush()
            return group

        def sleep(seconds):
            now[0] += seconds

        evidence, record = [], {}
        build = {"image": self.image, "leases": {}}
        ownership = SimpleNamespace(acquire_owned=acquire)
        outcome, failure = None, None
        with (
            patch.object(subject.time, "monotonic", side_effect=lambda: now[0]),
            patch.object(subject.time, "sleep", side_effect=sleep),
        ):
            try:
                outcome = subject.discover_with_native_preflight(
                    self.script, build, object(), ownership, evidence, record
                )
            except subject.ProbeObservationRefused as error:
                failure = error.kind
        self.assertTrue(all(group.settle_calls == 1 for group in groups))
        self.assertTrue(all(row["retirement_ack"] for row in evidence))
        self.assertEqual(len(evidence), len(calls))
        return SimpleNamespace(
            outcome=outcome, failure=failure, calls=calls, evidence=evidence, record=record
        )

    def catalogue_calls(self, gate):
        return [call for call in gate.calls if call[0] == "/usr/bin/osascript"]

    def test_absent_consent_never_starts_the_catalogue_query(self):
        for status, permission in ((-1743, "refusal_code_observed"), (-1744, "consent_required")):
            with self.subTest(status=status):
                gate = self.run_gate([status])
                self.assertEqual(gate.outcome, (status, None))
                self.assertEqual(gate.calls, [[self.image, "--permission-preflight"]])
                self.assertEqual(self.catalogue_calls(gate), [])
                self.assertEqual(
                    gate.record,
                    {
                        "source": "native_sdk",
                        "statuses": [status],
                        "service_launch_attempted": False,
                        "catalogue_retrieval_attempted": False,
                    },
                )
                fields, failed = subject.preflight_outcome(*gate.outcome)
                self.assertFalse(failed, "absent consent is a complete hosted observation")
                self.assertEqual(
                    fields,
                    {
                        "permission": permission,
                        "reason": "automation_consent_absent",
                        "discovery_observed": False,
                        "catalogue_retrieval_attempted": False,
                    },
                )

    def test_absent_target_is_started_once_then_consent_required_is_observed(self):
        gate = self.run_gate([-600, -1744])
        self.assertIsNone(gate.failure)
        self.assertEqual(gate.outcome, (-1744, None))
        self.assertEqual(
            gate.calls,
            [
                [self.image, "--permission-preflight"],
                self.launch,
                [self.image, "--permission-preflight"],
            ],
        )
        self.assertEqual(
            [row["role"] for row in gate.evidence],
            ["permission_preflight", "service_launch", "permission_preflight"],
        )
        self.assertEqual(gate.record["statuses"], [-600, -1744])
        self.assertTrue(gate.record["service_launch_attempted"])
        self.assertFalse(gate.record["catalogue_retrieval_attempted"])

    def test_persistent_absent_target_fails_inside_the_shared_budget(self):
        gate = self.run_gate([-600], preflight_elapsed=1.0)
        self.assertIn(gate.failure, ("target_not_running", "deadline"))
        self.assertIsNone(gate.outcome)
        self.assertEqual(gate.calls.count(self.launch), 1, "the agent is started only once")
        self.assertEqual(self.catalogue_calls(gate), [])
        self.assertFalse(gate.record["catalogue_retrieval_attempted"])
        self.assertTrue(set(gate.record["statuses"]) == {-600})
        self.assertLessEqual(len(gate.record["statuses"]), 20)

    def test_unknown_status_and_failed_start_refuse_before_the_catalogue(self):
        for status in (1, -1708, -2147483648, 2147483647):
            with self.subTest(status=status):
                gate = self.run_gate([status])
                self.assertEqual(gate.failure, "permission_status")
                self.assertEqual(gate.calls, [[self.image, "--permission-preflight"]])
        for launch, kind in (
            ((1, b"", b""), "native_exit"),
            ((0, b"", b"PRIVATE"), "diagnostic_shape"),
        ):
            with self.subTest(kind=kind):
                gate = self.run_gate([-600, 0], launch=launch)
                self.assertEqual(gate.failure, kind)
                self.assertEqual(gate.calls[-1], self.launch)
                self.assertEqual(self.catalogue_calls(gate), [])
                self.assertNotIn("PRIVATE", json.dumps(gate.evidence))

    def test_existing_consent_runs_admitted_discovery_and_validates_rows(self):
        gate = self.run_gate([0])
        self.assertIsNone(gate.failure)
        self.assertEqual(
            self.catalogue_calls(gate),
            [
                [
                    "/usr/bin/osascript",
                    "-l",
                    "JavaScript",
                    self.script,
                    "--native-permission-status",
                    "0",
                ]
            ],
        )
        self.assertTrue(gate.record["catalogue_retrieval_attempted"])
        fields, failed = subject.preflight_outcome(*gate.outcome)
        self.assertFalse(failed)
        self.assertEqual(
            fields,
            {
                "permission": "preflight_permitted",
                "inventory": {"observed": True, "observed_choices": 2, "truncated": False},
                "discovery_observed": True,
                "catalogue_retrieval_attempted": True,
                "reason": "none",
            },
        )
        self.assertNotIn("first", json.dumps(fields))

    def test_existing_consent_with_refused_or_malformed_catalogue_stays_failed(self):
        for packet, reason in (
            (
                b'{"version":1,"status":"refused","stage":1,"reason":"native_refused"}',
                "native_refused",
            ),
            (
                b'{"version":1,"status":"refused","stage":1,"reason":"automation_permission_refused"}',
                "automation_permission_refused",
            ),
            (
                b'{"version":1,"status":"refused","stage":1,"reason":"consent_not_established"}',
                "consent_not_established",
            ),
        ):
            with self.subTest(reason=reason):
                gate = self.run_gate([0], catalogue=packet)
                fields, failed = subject.preflight_outcome(*gate.outcome)
                self.assertTrue(failed)
                self.assertFalse(fields["discovery_observed"])
                self.assertEqual(fields["reason"], reason)
        gate = self.run_gate([0], catalogue=b'{"version":1,"status":"PRIVATE"}')
        with self.assertRaises(ValueError):
            subject.preflight_outcome(*gate.outcome)

    def test_late_preflight_cannot_give_the_catalogue_a_fresh_budget(self):
        gate = self.run_gate([0], preflight_elapsed=20.0)
        self.assertEqual(gate.failure, "deadline")
        self.assertEqual(self.catalogue_calls(gate), [])
        self.assertFalse(gate.record["catalogue_retrieval_attempted"])

    def test_outcome_refuses_every_inconsistent_status_and_payload_pair(self):
        for status, raw in (
            (0, None),
            (-600, None),
            (True, None),
            (-1744, self.inventory),
            (-600, self.inventory),
            (False, self.inventory),
        ):
            with self.subTest(status=status, raw=raw is not None):
                with self.assertRaises(ValueError):
                    subject.preflight_outcome(status, raw)

    def test_native_preflight_record_is_closed_canonical_signed32(self):
        for status in (0, -600, -1743, -1744, -2147483648, 2147483647):
            self.assertEqual(
                subject.validate_permission_preflight(preflight_record(status)), status
            )
        original = preflight_record(0)
        for raw in (
            original[:-1],
            b" " + original,
            original + b"\n",
            original.replace(b'"status":0', b'"status": 0'),
            original.replace(b'"status":0', b'"status":0.0'),
            original.replace(b'"status":0', b'"status":true'),
            original.replace(b'"status":0', b'"status":"0"'),
            original.replace(b'"version":1', b'"version":true'),
            original.replace(b'"version":1', b'"version":2'),
            original.replace(b'"version":1', b'"version":1,"version":1'),
            original.replace(b'"version":1', b'"version":1,"extra":0'),
            original.replace(b"permission_preflight", b"constants"),
            b'{"status":0,"mode":"permission_preflight","version":1}\n',
            preflight_record(2147483648),
            preflight_record(-2147483649),
            b'{"event_class":0,"event_id":0,"target_type":0,"version":1}\n',
            b"",
            b" " * 1025,
        ):
            with self.subTest(raw=raw[:80]):
                with self.assertRaises(ValueError):
                    subject.validate_permission_preflight(raw)


# Additive controlled SDK transport cases; all image and SDK bytes below are fake.
class SDKConstantTransportControls(unittest.TestCase):
    """Drive production capture/build/lease code with registered controlled groups."""

    inventory = b'{"version":1,"status":"observed","choices":[],"truncated":false}'

    def fixture(self):
        temporary = subject.tempfile.TemporaryDirectory(prefix="controlled-sdk-transport-")
        self.addCleanup(temporary.cleanup)
        # sdk_tool_path resolves xcrun's answers; macOS temporary directories sit
        # behind the /var -> /private/var link, so the fixture uses canonical paths.
        base = subject.Path(temporary.name).resolve()
        root, output, sdk = base / "root", base / "output", base / "sdk"
        source = root / "tools/diagnostics/apple_shortcuts_probe/sdk_constants.c"
        source.parent.mkdir(parents=True)
        source_bytes = b"/* Controlled fake C bytes: never compiled or native-qualified. */\n"
        source.write_bytes(source_bytes)
        output.mkdir()
        sdk.mkdir()
        (sdk / "SDKSettings.json").write_bytes(b'{"controlled_fake_sdk":true}\n')
        header = sdk / "System/Library/Frameworks/CoreServices.framework/Headers/CoreServices.h"
        header.parent.mkdir(parents=True)
        header.write_bytes(b"/* CONTROLLED FAKE SDK HEADER; NOT NATIVE PROOF. */\n")
        compiler = base / "controlled-clang"
        compiler.write_bytes(b"CONTROLLED FAKE COMPILER IMAGE\n")
        compiler.chmod(0o700)
        script = source.with_name("discover.js")
        script.write_bytes(b"// Controlled JXA path; never executed natively.\n")
        return SimpleNamespace(
            root=root,
            output=output,
            sdk=sdk,
            source=source,
            source_bytes=source_bytes,
            compiler=compiler,
            script=script,
            calls=[],
            groups=[],
            now=[0.0],
            preflight_raw=preflight_record(0),
            preflight_error=b"",
            preflight_status=0,
            preflight_elapsed=0.0,
            discovery_elapsed=0.0,
            preflight_retired=True,
        )

    def ownership(self, fixture):
        def acquire(arguments, native, register, **options):
            arguments = list(arguments)
            fixture.calls.append({"argv": arguments, "options": options})
            group = SimpleNamespace(process=SimpleNamespace(pid=321, returncode=None))
            group.settle_calls = 0
            group.is_preflight = arguments[0].endswith("/sdk_constants")
            status = fixture.preflight_status if group.is_preflight else 0
            group.observe_exit = lambda: SimpleNamespace(si_pid=321, si_code=1, si_status=status)

            def settle():
                group.settle_calls += 1
                group.process.returncode = status
                if group.is_preflight:
                    fixture.now[0] += getattr(fixture, "preflight_retirement_elapsed", 0.0)
                return fixture.preflight_retired if group.is_preflight else True

            group.settle = settle
            group.receipt = lambda: {
                "closed": group.process.returncode is not None,
                "controlled_fake_group": True,
            }
            fixture.groups.append(group)
            register(group)
            errors = b""
            if arguments[:4] == ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]:
                raw = str(fixture.sdk).encode() + b"\n"
            elif arguments[:4] == ["/usr/bin/xcrun", "--sdk", "macosx", "--find"]:
                self.assertEqual(arguments[4:], ["clang"])
                raw = str(fixture.compiler).encode() + b"\n"
            elif arguments[0] == str(fixture.compiler):
                image = subject.Path(arguments[arguments.index("-o") + 1])
                image.write_bytes(b"CONTROLLED FAKE COMPILED IMAGE; NOT NATIVE PROOF\n")
                image.chmod(0o700)
                raw = b""
            elif group.is_preflight:
                self.assertEqual(arguments[1:], ["--permission-preflight"])
                raw, errors = fixture.preflight_raw, fixture.preflight_error
                fixture.now[0] += fixture.preflight_elapsed
            elif arguments[0] == "/usr/bin/osascript":
                raw = self.inventory
                errors = b"ASCP:1\nASCP:2\nASCP:3\nASCP:4\n"
                fixture.now[0] += fixture.discovery_elapsed
            else:
                raise AssertionError("unexpected controlled acquisition argv")
            options["stdout"].write(raw)
            options["stderr"].write(errors)
            options["stdout"].flush()
            options["stderr"].flush()
            stage = (
                "preflight"
                if group.is_preflight
                else "discovery"
                if arguments[0] == "/usr/bin/osascript"
                else "build"
            )
            if getattr(fixture, "mutation_stage", None) == stage:
                path = fixture.mutation_path
                if getattr(fixture, "mutation_replacement", False):
                    other = path.with_name(path.name + ".replacement")
                    other.write_bytes(path.read_bytes())
                    other.chmod(path.stat().st_mode & 0o777)
                    other.replace(path)
                else:
                    path.chmod(path.stat().st_mode | 0o200)
                    path.write_bytes(path.read_bytes() + b"controlled mutation")
            return group

        return SimpleNamespace(acquire_owned=acquire)

    def build(self, fixture):
        evidence, ownership = [], self.ownership(fixture)
        with patch.object(subject.time, "monotonic", side_effect=lambda: fixture.now[0]):
            build = subject.build_sdk_constants(
                fixture.root, fixture.output, object(), ownership, evidence, fixture.source_bytes
            )
        return build, ownership, evidence

    def discover(self, fixture, build, ownership, evidence):
        with patch.object(subject.time, "monotonic", side_effect=lambda: fixture.now[0]):
            return subject.discover_with_native_preflight(
                fixture.script, build, object(), ownership, evidence, {}
            )

    def catalogue_started(self, fixture):
        return any(call["argv"][0] == "/usr/bin/osascript" for call in fixture.calls)

    def test_controlled_build_records_real_capture_retirement_and_source_image_leases(self):
        fixture = self.fixture()
        build, _, evidence = self.build(fixture)
        self.assertEqual(
            set(build["leases"]),
            {"source", "snapshot", "compiler", "sdk_settings", "sdk_header", "image"},
        )
        self.assertEqual(
            build["image"].read_bytes(), b"CONTROLLED FAKE COMPILED IMAGE; NOT NATIVE PROOF\n"
        )
        self.assertEqual(len(evidence), 3)
        self.assertEqual(evidence[-1]["role"], "sdk_compile")
        for record, group in zip(evidence, fixture.groups):
            self.assertEqual(record["registered"], 1)
            self.assertTrue(record["retirement_ack"])
            self.assertEqual(group.settle_calls, 1)
            self.assertEqual(
                record["observation"]["terminal_before_retirement"],
                {"pid": 321, "code": 1, "status": 0},
            )
        self.assertTrue(fixture.calls[-1]["options"].get("env"))
        for lease in build["leases"].values():
            subject.require_lease(lease)

    def test_lease_replacement_same_bytes_and_mutation_refuse_without_new_acquisition(self):
        for target in ("source", "snapshot", "compiler", "sdk_settings", "sdk_header", "image"):
            for replacement in (True, False):
                with self.subTest(target=target, replacement=replacement):
                    fixture = self.fixture()
                    build, ownership, evidence = self.build(fixture)
                    path = build["leases"][target][0]
                    raw = path.read_bytes()
                    if replacement:
                        other = path.with_name(path.name + ".replacement")
                        other.write_bytes(raw)
                        other.chmod(path.stat().st_mode & 0o777)
                        other.replace(path)
                    else:
                        path.chmod(path.stat().st_mode | 0o200)
                        path.write_bytes(raw + b"changed")
                    before = len(fixture.calls)
                    with self.assertRaises(ValueError):
                        self.discover(fixture, build, ownership, evidence)
                    self.assertEqual(len(fixture.calls), before)

    def test_preflight_and_discovery_use_one_budget_and_exact_admitted_argv(self):
        fixture = self.fixture()
        build, ownership, evidence = self.build(fixture)
        fixture.preflight_elapsed, fixture.discovery_elapsed = 19.0, 0.5
        status, raw = self.discover(fixture, build, ownership, evidence)
        self.assertEqual((status, raw), (0, self.inventory))
        self.assertEqual(fixture.calls[-2]["argv"], [str(build["image"]), "--permission-preflight"])
        self.assertEqual(
            fixture.calls[-1]["argv"],
            [
                "/usr/bin/osascript",
                "-l",
                "JavaScript",
                str(fixture.script),
                "--native-permission-status",
                "0",
            ],
        )
        self.assertEqual(
            [record["role"] for record in evidence[-2:]], ["permission_preflight", "discovery"]
        )
        self.assertTrue(all(record["retirement_ack"] for record in evidence))
        self.assertTrue(all(group.settle_calls == 1 for group in fixture.groups))
        self.assertNotIn("permission_granted", json.dumps(evidence))

    def test_late_discovery_cannot_gain_a_second_twenty_second_budget(self):
        fixture = self.fixture()
        build, ownership, evidence = self.build(fixture)
        fixture.preflight_elapsed, fixture.discovery_elapsed = 19.0, 1.125
        with self.assertRaises(subject.ProbeObservationRefused) as caught:
            self.discover(fixture, build, ownership, evidence)
        self.assertEqual(caught.exception.kind, "deadline")
        self.assertEqual(evidence[-1]["role"], "discovery")
        self.assertTrue(evidence[-1]["retirement_ack"])
        self.assertEqual(
            evidence[-1]["observation"]["terminal_before_retirement"],
            {"pid": 321, "code": 1, "status": 0},
        )
        self.assertEqual(fixture.groups[-1].settle_calls, 1)

    def test_expired_preflight_capture_retires_without_acquiring_osascript(self):
        fixture = self.fixture()
        build, ownership, evidence = self.build(fixture)
        fixture.preflight_elapsed = 20.0
        with self.assertRaises(subject.ProbeObservationRefused) as caught:
            self.discover(fixture, build, ownership, evidence)
        self.assertEqual(caught.exception.kind, "deadline")
        self.assertEqual(evidence[-1]["role"], "permission_preflight")
        self.assertTrue(evidence[-1]["retirement_ack"])
        self.assertFalse(self.catalogue_started(fixture))
        self.assertEqual(fixture.groups[-1].settle_calls, 1)

    def test_malformed_preflight_records_refuse_before_osascript(self):
        for encoded in (
            b"{}",
            b"null",
            b" " * 1025,
            preflight_record(0).replace(b'"version":1', b'"version":1,"extra":0'),
            preflight_record(2147483648),
        ):
            with self.subTest(encoded=encoded[:100]):
                fixture = self.fixture()
                build, ownership, evidence = self.build(fixture)
                fixture.preflight_raw = encoded
                with self.assertRaises(ValueError):
                    self.discover(fixture, build, ownership, evidence)
                self.assertEqual(evidence[-1]["role"], "permission_preflight")
                self.assertTrue(evidence[-1]["retirement_ack"])
                self.assertEqual(fixture.groups[-1].settle_calls, 1)
                self.assertFalse(self.catalogue_started(fixture))

    def test_nonzero_unclean_and_unretired_preflight_group_cannot_reach_osascript(self):
        for field, value in (
            ("preflight_status", 3),
            ("preflight_error", b"PRIVATE"),
            ("preflight_retired", False),
        ):
            with self.subTest(field=field):
                fixture = self.fixture()
                build, ownership, evidence = self.build(fixture)
                setattr(fixture, field, value)
                with self.assertRaises(ValueError):
                    self.discover(fixture, build, ownership, evidence)
                self.assertEqual(evidence[-1]["role"], "permission_preflight")
                self.assertEqual(evidence[-1]["retirement_ack"], field != "preflight_retired")
                self.assertEqual(fixture.groups[-1].settle_calls, 1)
                self.assertFalse(self.catalogue_started(fixture))
                self.assertNotIn("PRIVATE", json.dumps(evidence))

    def test_post_capture_lease_mutation_refuses_and_retains_exact_retired_operations(self):
        for stage in ("preflight", "discovery"):
            for target in ("source", "snapshot", "compiler", "sdk_settings", "sdk_header", "image"):
                with self.subTest(stage=stage, target=target):
                    fixture = self.fixture()
                    build, ownership, evidence = self.build(fixture)
                    fixture.mutation_stage = stage
                    fixture.mutation_path = build["leases"][target][0]
                    with self.assertRaises(ValueError):
                        self.discover(fixture, build, ownership, evidence)
                    self.assertEqual(
                        evidence[-1]["role"],
                        "permission_preflight" if stage == "preflight" else "discovery",
                    )
                    self.assertTrue(evidence[-1]["retirement_ack"])
                    self.assertEqual(fixture.groups[-1].settle_calls, 1)
                    self.assertEqual(self.catalogue_started(fixture), stage == "discovery")

    def test_expired_or_invalid_absolute_deadline_never_acquires_a_group(self):
        fixture = self.fixture()
        ownership = self.ownership(fixture)
        evidence = []
        with patch.object(subject.time, "monotonic", return_value=0.0):
            with self.assertRaises(subject.ProbeObservationRefused) as caught:
                subject.capture(
                    ["fixture"], object(), ownership, evidence, "permission_preflight", deadline=0.0
                )
            self.assertEqual(caught.exception.kind, "deadline")
            self.assertEqual(evidence[-1]["registered"], 0)
            self.assertEqual(evidence[-1]["groups"], [])
            self.assertTrue(evidence[-1]["retirement_ack"])
            for deadline in (True, float("nan"), float("inf"), 20.001):
                with self.subTest(deadline=deadline):
                    before = len(evidence)
                    with self.assertRaises(ValueError):
                        subject.capture(
                            ["fixture"],
                            object(),
                            ownership,
                            evidence,
                            "permission_preflight",
                            deadline=deadline,
                        )
                    self.assertEqual(len(evidence), before)
        self.assertEqual(fixture.calls, [])

    def test_in_capture_same_byte_inode_replacement_refuses_before_osascript(self):
        for target in ("source", "image"):
            with self.subTest(target=target):
                fixture = self.fixture()
                build, ownership, evidence = self.build(fixture)
                fixture.mutation_stage = "preflight"
                fixture.mutation_path = build["leases"][target][0]
                fixture.mutation_replacement = True
                with self.assertRaises(ValueError):
                    self.discover(fixture, build, ownership, evidence)
                self.assertEqual(evidence[-1]["role"], "permission_preflight")
                self.assertTrue(evidence[-1]["retirement_ack"])
                self.assertEqual(fixture.groups[-1].settle_calls, 1)
                self.assertFalse(self.catalogue_started(fixture))

    def test_preflight_retirement_consumes_shared_budget_before_osascript_acquisition(self):
        fixture = self.fixture()
        build, ownership, evidence = self.build(fixture)
        fixture.preflight_retirement_elapsed = 20.0
        with self.assertRaises(subject.ProbeObservationRefused) as caught:
            self.discover(fixture, build, ownership, evidence)
        self.assertEqual(caught.exception.kind, "deadline")
        self.assertEqual(evidence[-1]["role"], "permission_preflight")
        self.assertTrue(evidence[-1]["retirement_ack"])
        self.assertEqual(fixture.groups[-1].settle_calls, 1)
        self.assertFalse(self.catalogue_started(fixture))

    def test_source_changed_before_build_refuses_without_any_acquisition(self):
        fixture = self.fixture()
        fixture.source.write_bytes(fixture.source_bytes + b"changed")
        evidence = []
        with self.assertRaises(ValueError):
            subject.build_sdk_constants(
                fixture.root,
                fixture.output,
                object(),
                self.ownership(fixture),
                evidence,
                fixture.source_bytes,
            )
        self.assertEqual(fixture.calls, [])
        self.assertEqual(evidence, [])


class SDKCanonicalEnvelopeControls(unittest.TestCase):
    def test_owned_sdk_lookup_resolves_real_alias_and_refuses_malformed_path(self):
        with subject.tempfile.TemporaryDirectory(prefix="controlled-sdk-path-") as raw_directory:
            # Canonical like sdk_tool_path's answers (macOS /var -> /private/var).
            directory = str(subject.Path(raw_directory).resolve())
            path = subject.Path(directory) / "official-lookup-model"
            path.write_bytes(b"CONTROLLED PATH MODEL; NO SDK OR COMPILER EXECUTION\n")
            alias = path.with_name("owned-lookup-alias")
            alias.symlink_to(path)
            self.assertEqual(subject.sdk_tool_path((str(alias) + "\n").encode()), path)
            for raw in (
                b"relative\n",
                b"",
                b"/one\n/two\n",
                b"/nul\0\n",
                b"/unterminated",
                b" " * 4097,
            ):
                with self.subTest(raw=raw[:30]):
                    with self.assertRaises(ValueError):
                        subject.sdk_tool_path(raw)
            with self.assertRaises(FileNotFoundError):
                subject.sdk_tool_path((str(path.with_name("absent")) + "\n").encode())

    def test_symlink_compiler_output_cannot_chmod_a_foreign_target(self):
        model = SDKConstantTransportControls()
        self.addCleanup(model.doCleanups)
        fixture = model.fixture()
        target = fixture.output / "controlled-foreign-target"
        target.write_bytes(b"UNCHANGED CONTROLLED TARGET\n")
        target.chmod(0o700)
        original = model.ownership(fixture).acquire_owned

        def acquire(arguments, native, register, **options):
            group = original(arguments, native, register, **options)
            if arguments[0] == str(fixture.compiler):
                image = subject.Path(arguments[arguments.index("-o") + 1])
                image.unlink()
                image.symlink_to(target)
            return group

        with patch.object(subject.time, "monotonic", side_effect=lambda: fixture.now[0]):
            with self.assertRaises((ValueError, OSError)):
                subject.build_sdk_constants(
                    fixture.root,
                    fixture.output,
                    object(),
                    SimpleNamespace(acquire_owned=acquire),
                    [],
                    fixture.source_bytes,
                )
        self.assertEqual(target.read_bytes(), b"UNCHANGED CONTROLLED TARGET\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o700)


# The SDK filesystem model depends on POSIX no-follow and executable modes.
# Windows still collects every case, but executes the portable cohort only.
SDK_FILESYSTEM_CASES = (
    "SDKCanonicalEnvelopeControls.test_owned_sdk_lookup_resolves_real_alias_and_refuses_malformed_path",
    "SDKCanonicalEnvelopeControls.test_symlink_compiler_output_cannot_chmod_a_foreign_target",
    "SDKConstantTransportControls.test_controlled_build_records_real_capture_retirement_and_source_image_leases",
    "SDKConstantTransportControls.test_expired_or_invalid_absolute_deadline_never_acquires_a_group",
    "SDKConstantTransportControls.test_expired_preflight_capture_retires_without_acquiring_osascript",
    "SDKConstantTransportControls.test_in_capture_same_byte_inode_replacement_refuses_before_osascript",
    "SDKConstantTransportControls.test_late_discovery_cannot_gain_a_second_twenty_second_budget",
    "SDKConstantTransportControls.test_lease_replacement_same_bytes_and_mutation_refuse_without_new_acquisition",
    "SDKConstantTransportControls.test_malformed_preflight_records_refuse_before_osascript",
    "SDKConstantTransportControls.test_nonzero_unclean_and_unretired_preflight_group_cannot_reach_osascript",
    "SDKConstantTransportControls.test_post_capture_lease_mutation_refuses_and_retains_exact_retired_operations",
    "SDKConstantTransportControls.test_preflight_and_discovery_use_one_budget_and_exact_admitted_argv",
    "SDKConstantTransportControls.test_preflight_retirement_consumes_shared_budget_before_osascript_acquisition",
    "SDKConstantTransportControls.test_source_changed_before_build_refuses_without_any_acquisition",
)


def load_tests(loader, tests, pattern):
    """Declare the POSIX fixture boundary without skipped or weakened cases."""
    portable_groups = (
        (Controls, 8),
        (CaptureDiagnosticControls, 6),
        (ObservationPriorityControls, 4),
        (PermissionPreflightControls, 12),
        (UnavailableRefinementControls, 3),
        (CaptureBudgetControls, 2),
        (NativePreflightGateControls, 9),
    )
    portable = unittest.TestSuite()
    for group, expected in portable_groups:
        collected = loader.loadTestsFromTestCase(group)
        if collected.countTestCases() != expected:
            raise AssertionError("portable Shortcuts cohort changed")
        portable.addTests(collected)
    sdk = []
    for group in (SDKCanonicalEnvelopeControls, SDKConstantTransportControls):
        sdk.extend(group.__name__ + "." + name for name in loader.getTestCaseNames(group))
    if tuple(sorted(sdk)) != SDK_FILESYSTEM_CASES or tests.countTestCases() != 58:
        raise AssertionError("complete Shortcuts SDK case census changed")
    if subject.sys.platform == "win32":
        print(
            "Shortcuts SDK filesystem scope: "
            + json.dumps(
                {
                    "case_names": list(SDK_FILESYSTEM_CASES),
                    "collected": 14,
                    "executed": 0,
                    "native": "UNRUN",
                    "status": "UNRUN_UNSUPPORTED",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return portable
    if subject.sys.platform not in ("linux", "darwin"):
        raise AssertionError("unsupported Shortcuts control host")
    return tests


if __name__ == "__main__":
    unittest.main()
