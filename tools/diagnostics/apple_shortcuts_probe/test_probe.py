# tools/diagnostics/apple_shortcuts_probe/test_probe.py
"""Portable closed-parser/registration controls; never claim native qualification."""

import json
import unittest
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
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
