"""Portable clock frame/context controls; no Swift or Darwin acceptance.

Load the actual independent receiver through a fixed repository-relative path.
These controls never run its native TestCase, native setup, compiler or helper.
"""

import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py"
spec = importlib.util.spec_from_file_location("portable_clock_native_receiver", SOURCE)
CLIENT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CLIENT)
frame = CLIENT.native_clock_frame
epoch = CLIENT.native_clock_epoch
Refused = CLIENT.NativeClockRefused


class ClockFrameContractTests(unittest.TestCase):
    def encoded(self, samples=None, **changes):
        fields = {
            "version": 1,
            "system_uptime": [50.125 + index / 128 for index in range(16)]
            if samples is None
            else samples,
        }
        fields.update(changes)
        return json.dumps(fields).encode("ascii") + b"\n"

    def test_valid_independently_authored_frame_retains_all_sixteen_samples(self):
        samples = [50.125 + index / 128 for index in range(16)]
        self.assertEqual(frame(self.encoded(samples), 50.0, 51.0), samples)

    def test_missing_or_added_samples_refuse(self):
        for count in (0, 1, 15, 17):
            with self.subTest(count=count):
                with self.assertRaises(Refused):
                    frame(self.encoded([50.5] * count), 50.0, 51.0)

    def test_every_interior_sample_must_have_closed_finite_numeric_shape(self):
        for index in range(1, 15):
            for value in (True, None, "50.5", 10**1000, float("nan"), float("inf")):
                with self.subTest(index=index, category=type(value).__name__):
                    samples = [50.5] * 16
                    samples[index] = value
                    with self.assertRaises(Refused):
                        frame(self.encoded(samples), 50.0, 51.0)

    def test_every_interior_out_of_epoch_sample_refuses(self):
        for index in range(1, 15):
            for value in (49.0, 52.0):
                with self.subTest(index=index, value=value):
                    samples = [50.5] * 16
                    samples[index] = value
                    with self.assertRaises(Refused):
                        frame(self.encoded(samples), 50.0, 51.0)

    def test_regressed_order_inside_otherwise_valid_epoch_refuses(self):
        samples = [50.5] * 16
        samples[8] = 50.25
        with self.assertRaises(Refused):
            frame(self.encoded(samples), 50.0, 51.0)

    def test_duplicate_extra_and_false_version_fields_refuse(self):
        frames = [
            b'{"version":1,"version":1,"system_uptime":'
            + json.dumps([50.5] * 16).encode()
            + b"}\n",
            self.encoded(extra=True),
            self.encoded(version=True),
            self.encoded(version=2),
        ]
        for raw in frames:
            with self.subTest(raw_size=len(raw)):
                with self.assertRaises(Refused):
                    frame(raw, 50.0, 51.0)

    def test_extra_reply_missing_newline_and_oversized_output_refuse(self):
        valid = self.encoded()
        for raw in (valid + valid, valid[:-1], b" " * 4097 + b"\n", valid.decode("ascii")):
            with self.subTest(category=type(raw).__name__, size=len(raw)):
                with self.assertRaises(Refused):
                    frame(raw, 50.0, 51.0)

    def test_original_fifteen_second_cap_is_never_renewed(self):
        for before, after in (
            (50.0, 65.000001),
            (50.0, 49.0),
            (0, 1),
            (float("nan"), 51),
            (True, 51),
            (10**1000, 10**1000 + 1),
        ):
            with self.subTest(before_type=type(before).__name__, after_type=type(after).__name__):
                with self.assertRaises(Refused):
                    frame(self.encoded(), before, after)


class ClockContextContractTests(unittest.TestCase):
    def test_absent_local_epoch_remains_explicitly_unbound(self):
        self.assertIsNone(epoch({}, "arm64"))

    def test_actual_supplied_fields_keep_exact_provenance(self):
        context = {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"}
        self.assertEqual(
            epoch(context, "amd64"),
            {
                "candidate": "a" * 40,
                "run_id": "123",
                "run_attempt": "2",
                "architecture": "amd64",
                "provenance": "github_environment",
            },
        )

    def test_partial_malformed_or_zero_epoch_cannot_claim_bound_context(self):
        valid = {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"}
        for name in valid:
            for value in (None, "", "0", "1\n", 1):
                with self.subTest(name=name, category=type(value).__name__):
                    candidate = dict(valid, **{name: value})
                    with self.assertRaises(Refused):
                        epoch(candidate, "arm64")

    def test_foreign_or_missing_architecture_cannot_claim_bound_context(self):
        for architecture in (None, "", "x86_64", "ARM64", "linux"):
            with self.subTest(architecture=architecture):
                with self.assertRaises(Refused):
                    epoch({}, architecture)

    def test_independent_twenty_digit_run_and_six_digit_attempt_boundaries(self):
        valid = {
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "12345678901234567890",
            "GITHUB_RUN_ATTEMPT": "999999",
        }
        self.assertEqual(epoch(valid, "arm64")["run_id"], "12345678901234567890")
        self.assertEqual(epoch(valid, "arm64")["run_attempt"], "999999")
        for name, oversized in (
            ("GITHUB_RUN_ID", "123456789012345678901"),
            ("GITHUB_RUN_ATTEMPT", "1000000"),
        ):
            with self.subTest(name=name):
                with self.assertRaises(Refused):
                    epoch(dict(valid, **{name: oversized}), "arm64")


EXPECTED_TEST_IDENTITIES = {
    "ClockFrameContractTests": (
        "test_duplicate_extra_and_false_version_fields_refuse",
        "test_every_interior_out_of_epoch_sample_refuses",
        "test_every_interior_sample_must_have_closed_finite_numeric_shape",
        "test_extra_reply_missing_newline_and_oversized_output_refuse",
        "test_missing_or_added_samples_refuse",
        "test_original_fifteen_second_cap_is_never_renewed",
        "test_regressed_order_inside_otherwise_valid_epoch_refuses",
        "test_valid_independently_authored_frame_retains_all_sixteen_samples",
    ),
    "ClockContextContractTests": (
        "test_absent_local_epoch_remains_explicitly_unbound",
        "test_actual_supplied_fields_keep_exact_provenance",
        "test_foreign_or_missing_architecture_cannot_claim_bound_context",
        "test_independent_twenty_digit_run_and_six_digit_attempt_boundaries",
        "test_partial_malformed_or_zero_epoch_cannot_claim_bound_context",
    ),
}


def enrolled_cases():
    """Expose exactly8+5 controls; any identity or census drift refuses import."""
    classes = (ClockFrameContractTests, ClockContextContractTests)
    for case in classes:
        actual = tuple(unittest.defaultTestLoader.getTestCaseNames(case))
        if case.__module__ != __name__ or actual != EXPECTED_TEST_IDENTITIES[case.__name__]:
            raise RuntimeError("Portable native clock control identity refused")
    if sum(len(EXPECTED_TEST_IDENTITIES[case.__name__]) for case in classes) != 13:
        raise RuntimeError("Portable native clock control census refused")
    return classes
