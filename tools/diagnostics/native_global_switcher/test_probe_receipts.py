# tools/diagnostics/native_global_switcher/test_probe_receipts.py
"""Constructed independent controls, not native switcher qualification."""

import copy
import json
import unittest
from probe_receipts import qualify

PHASES = [
    {"tag": 0x47534F01, "key": 55, "type": "flagsChanged", "cmd": True},
    {"tag": 0x47534F02, "key": 48, "type": "keyDown", "cmd": True},
    {"tag": 0x47534F03, "key": 48, "type": "keyUp", "cmd": True},
    {"tag": 0x47534F04, "key": 55, "type": "flagsChanged", "cmd": False},
]


def independent_receipt():
    return {
        "status": "observed",
        "coverage": "isolated_fixture_only",
        "hs_pid": 303,
        "before_pid": 101,
        "after_pid": 202,
        "observations": copy.deepcopy(PHASES),
        "hardware": [
            {
                "version": 1,
                "request": i,
                "source": "hid_system",
                "held": [],
                "flags": 0,
                "listen_access": True,
                "post_access": True,
                "session": {
                    "version": 1,
                    "request": i,
                    "source": "combined_session",
                    "held": [55] if i in (2, 3, 4) else [],
                    "flags": (1 << 20) if i in (2, 3, 4) else 0,
                },
            }
            for i in range(1, 6)
        ],
        "hardware_sample_count": 5,
        "hardware_truncated": False,
        "ax_trusted": True,
        "tap_retired": True,
        "timer_retired": True,
        "tasks_retired": True,
        "session_retired": True,
        "source_current": True,
        "cleanup_debt": False,
    }


class ProbeReceipts(unittest.TestCase):
    def test_independent_observed_and_retired_receipt(self):
        self.assertTrue(qualify(independent_receipt(), 101, 202, 303))

    def test_integer_pid_receipt_survives_json_round_trip(self):
        value = independent_receipt()
        for key in ("before_pid", "after_pid", "hs_pid"):
            self.assertIs(type(value[key]), int)
        decoded = json.loads(json.dumps(value))
        self.assertTrue(qualify(decoded, 101, 202, 303))

    def test_matching_float_pid_refuses_after_json_round_trip(self):
        for key in ("before_pid", "after_pid", "hs_pid"):
            with self.subTest(key=key):
                value = independent_receipt()
                value[key] = float(value[key])
                decoded = json.loads(json.dumps(value))
                self.assertIs(type(decoded[key]), float)
                self.assertEqual(decoded[key], independent_receipt()[key])
                self.assertFalse(qualify(decoded, 101, 202, 303))

    def test_matching_boolean_pid_refuses_after_json_round_trip(self):
        for index, key in enumerate(("before_pid", "after_pid", "hs_pid")):
            with self.subTest(key=key):
                value = independent_receipt()
                expected = [101, 202, 303]
                expected[index] = 1
                value[key] = 1
                self.assertTrue(qualify(value, *expected))
                value[key] = True
                decoded = json.loads(json.dumps(value))
                self.assertIs(type(decoded[key]), bool)
                self.assertEqual(decoded[key], expected[index])
                self.assertFalse(qualify(decoded, *expected))

    def test_other_wrong_pid_types_refuse(self):
        for key in ("before_pid", "after_pid", "hs_pid"):
            for replacement in (None, False, "101", [], {}):
                with self.subTest(key=key, replacement=replacement):
                    value = independent_receipt()
                    value[key] = replacement
                    self.assertFalse(qualify(value, 101, 202, 303))

    def test_expected_pid_wrong_types_remain_refused(self):
        for index, key in enumerate(("before_pid", "after_pid", "hs_pid")):
            for replacement in (float((101, 202, 303)[index]), True):
                with self.subTest(key=key, replacement=replacement):
                    value = independent_receipt()
                    expected = [101, 202, 303]
                    if replacement is True:
                        value[key] = 1
                    expected[index] = replacement
                    self.assertFalse(qualify(value, *expected))

    def test_native_post_return_cannot_replace_observation(self):
        value = independent_receipt()
        value["observations"] = []
        value["post_returned_self"] = True
        self.assertFalse(qualify(value, 101, 202, 303))

    def test_observation_without_native_effect_refuses(self):
        value = independent_receipt()
        value["after_pid"] = 101
        self.assertFalse(qualify(value, 101, 202, 303))

    def test_each_owned_phase_identity_and_order_is_mandatory(self):
        for index in range(4):
            for field, replacement in (
                ("tag", 0),
                ("key", 0),
                ("type", "keyDown" if index != 1 else "keyUp"),
                ("cmd", not PHASES[index]["cmd"]),
            ):
                with self.subTest(index=index, field=field):
                    value = independent_receipt()
                    value["observations"][index][field] = replacement
                    self.assertFalse(qualify(value, 101, 202, 303))
        value = independent_receipt()
        value["observations"].reverse()
        self.assertFalse(qualify(value, 101, 202, 303))

    def test_every_physical_snapshot_refuses_held_or_unknown_hardware(self):
        for index in range(5):
            for field, replacement in (
                ("held", [54]),
                ("held", [55]),
                ("held", [48]),
                ("source", "combined_session"),
                ("flags", None),
                ("flags", 1 << 20),
                ("request", 0),
                ("post_access", False),
                ("listen_access", None),
            ):
                with self.subTest(index=index, field=field):
                    value = independent_receipt()
                    value["hardware"][index][field] = replacement
                    self.assertFalse(qualify(value, 101, 202, 303))

    def test_no_cleanup_receipt_may_be_inferred_from_elapsed_time(self):
        for key in (
            "tap_retired",
            "timer_retired",
            "tasks_retired",
            "session_retired",
            "source_current",
            "ax_trusted",
        ):
            for replacement in (False, None, 1):
                with self.subTest(key=key, replacement=replacement):
                    value = independent_receipt()
                    value[key] = replacement
                    self.assertFalse(qualify(value, 101, 202, 303))
        value = independent_receipt()
        value["cleanup_debt"] = True
        self.assertFalse(qualify(value, 101, 202, 303))

    def test_truncated_hardware_evidence_cannot_be_qualified(self):
        for key, value in (
            ("hardware_truncated", True),
            ("hardware_truncated", None),
            ("hardware_sample_count", 4),
            ("hardware_sample_count", True),
        ):
            candidate = independent_receipt()
            candidate[key] = value
            self.assertFalse(qualify(candidate, 101, 202, 303))

    def test_local_up_and_clear_hid_cannot_replace_terminal_session_release(self):
        for field, replacement in (
            ("held", [55]),
            ("held", [54]),
            ("held", [48]),
            ("flags", 1 << 20),
        ):
            candidate = independent_receipt()
            candidate["hardware"][-1]["session"][field] = replacement
            self.assertFalse(qualify(candidate, 101, 202, 303))

    def test_session_schema_and_same_attempt_identity_are_required(self):
        for index in range(5):
            for field, replacement in (
                ("version", True),
                ("request", 0),
                ("request", True),
                ("source", "hid_system"),
                ("held", False),
                ("held", [True]),
                ("flags", None),
                ("flags", True),
                ("flags", -1),
            ):
                with self.subTest(index=index, field=field):
                    value = independent_receipt()
                    value["hardware"][index]["session"][field] = replacement
                    self.assertFalse(qualify(value, 101, 202, 303))
        for malformed in (None, {}, {"extra": 1}):
            value = independent_receipt()
            value["hardware"][-1]["session"] = malformed
            self.assertFalse(qualify(value, 101, 202, 303))
        value = independent_receipt()
        value["hardware"][-1]["session"]["extra"] = 1
        self.assertFalse(qualify(value, 101, 202, 303))

    def test_foreign_application_or_runtime_refuses(self):
        for key, replacement in (
            ("before_pid", 999),
            ("after_pid", 999),
            ("hs_pid", 999),
            ("status", "post_returned"),
            ("coverage", "product_qualified"),
        ):
            value = independent_receipt()
            value[key] = replacement
            self.assertFalse(qualify(value, 101, 202, 303))


if __name__ == "__main__":
    unittest.main(verbosity=2)
