# tools/diagnostics/hs_delayed_timer_probe_test.py
"""Refuse incomplete native observations and preserve the scripting preference."""

import copy
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

import hs_delayed_timer_probe as probe


EXECUTABLE = Path(
    "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
)
DOMAIN = "com.ergoptiplus.app.hammerspoon"
NONCE = "a" * 32


def receipt():
    """Return actual observation values for the complete native contract."""
    return {
        "schema_version": 1,
        "contract": "hs.timer.delayed",
        "nonce": NONCE,
        "pid": 42,
        "executable": str(EXECUTABLE),
        "bundle_id": DOMAIN,
        "version": "1.1.1",
        "complete": True,
        "errors": [],
        "observations": {
            **probe.CONTRACT["boolean_observations"],
            "override_remaining": 0.99,
            "default_remaining": 4.99,
            "active_configured_remaining": 2.99,
        },
        "deliveries": {"rearm": 2, "zero": 1},
    }


class ReceiptTests(unittest.TestCase):
    """Every missing or wrong native measurement must invalidate admission."""

    def test_complete_native_observations_pass_only_after_restoration(self):
        summary = probe.validate_receipt(receipt(), NONCE, 42, EXECUTABLE, DOMAIN)
        with self.assertRaises(ValueError):
            probe.validate_summary(summary)
        summary["preference_restored"] = True
        probe.validate_summary(summary)

    def test_wrong_identity_and_partial_receipts_fail(self):
        for field, replacement in {
            "nonce": "b" * 32,
            "pid": 43,
            "version": "0.0.0",
            "executable": "/other/Hammerspoon",
            "bundle_id": "org.hammerspoon.Hammerspoon",
            "complete": False,
            "schema_version": True,
            "errors": ["callback failed"],
        }.items():
            with self.subTest(field=field):
                changed = receipt()
                changed[field] = replacement
                with self.assertRaises(ValueError):
                    probe.validate_receipt(changed, NONCE, 42, EXECUTABLE, DOMAIN)
        for field in receipt():
            with self.subTest(missing=field):
                changed = receipt()
                del changed[field]
                with self.assertRaises(ValueError):
                    probe.validate_receipt(changed, NONCE, 42, EXECUTABLE, DOMAIN)

    def test_every_boolean_is_required_and_observed(self):
        for field, expected in probe.CONTRACT["boolean_observations"].items():
            for replacement in (not expected, 1 if expected else 0, None):
                with self.subTest(field=field, replacement=replacement):
                    changed = receipt()
                    changed["observations"][field] = replacement
                    with self.assertRaises(ValueError):
                        probe.validate_receipt(changed, NONCE, 42, EXECUTABLE, DOMAIN)

    def test_remaining_countdowns_and_delivery_counts_are_not_pass_flags(self):
        for field in probe.CONTRACT["remaining_limits"]:
            for replacement in (0, -1, True, float("nan"), float("inf"), 20):
                with self.subTest(field=field, replacement=replacement):
                    changed = receipt()
                    changed["observations"][field] = replacement
                    with self.assertRaises(ValueError):
                        probe.validate_receipt(changed, NONCE, 42, EXECUTABLE, DOMAIN)
        for field in probe.CONTRACT["deliveries"]:
            for replacement in (0, 1.0, True, 3):
                with self.subTest(delivery=field, replacement=replacement):
                    changed = receipt()
                    changed["deliveries"][field] = replacement
                    with self.assertRaises(ValueError):
                        probe.validate_receipt(changed, NONCE, 42, EXECUTABLE, DOMAIN)
        changed = receipt()
        changed["observations"]["default_remaining"] = 0.99
        with self.assertRaisesRegex(ValueError, "override"):
            probe.validate_receipt(changed, NONCE, 42, EXECUTABLE, DOMAIN)

    def test_duplicate_receipt_fields_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            json.loads('{"complete":false,"complete":true}', object_pairs_hook=probe.unique_object)


class DefaultsFixture:
    """Model the native defaults CLI without touching the user's preference domain."""

    def __init__(self, state=None):
        self.state = copy.deepcopy(state)
        self.fail_read = False
        self.fail_write = False
        self.fail_import = False
        self.refuse_import = False
        self.fail_delete = False
        self.refuse_delete = False
        self.calls = []

    def run(self, arguments, **options):
        self.calls.append(arguments)
        action = arguments[1]
        if action == "export":
            if self.fail_read:
                return subprocess.CompletedProcess(arguments, 2, b"", b"permission denied")
            if self.state is None:
                return subprocess.CompletedProcess(
                    arguments, 1, b"", f"Domain {DOMAIN} does not exist\n".encode()
                )
            return subprocess.CompletedProcess(arguments, 0, plistlib.dumps(self.state), b"")
        if action == "write":
            if self.state is None:
                self.state = {}
            self.state[probe.APPLE_SCRIPT_KEY] = True
            return subprocess.CompletedProcess(arguments, 1 if self.fail_write else 0, b"", b"")
        if action == "import":
            if not self.refuse_import:
                if self.state is None:
                    self.state = {}
                # Native import can merge keys; omission is not a delete receipt.
                self.state.update(plistlib.loads(options["input"]))
            return subprocess.CompletedProcess(arguments, 1 if self.fail_import else 0, b"", b"")
        if action == "delete":
            if not self.refuse_delete:
                self.state.pop(arguments[3], None)
            return subprocess.CompletedProcess(arguments, 1 if self.fail_delete else 0, b"", b"")
        raise AssertionError(f"Unexpected defaults command: {arguments!r}")


class PreferenceTests(unittest.TestCase):
    """Restoration keeps the exact previous value and every new runtime preference."""

    def test_absent_and_typed_prior_values_survive_with_new_runtime_keys(self):
        states = [None, {"other": "kept"}]
        states += [
            {probe.APPLE_SCRIPT_KEY: value, "other": "kept"}
            for value in (False, True, 0, "NO", {"prior": [1, False]})
        ]
        for state in states:
            with self.subTest(state=state):
                native = DefaultsFixture(state)
                owner = probe.AppleScriptPreference(DOMAIN, native.run)
                owner.enable()
                self.assertIs(native.state[probe.APPLE_SCRIPT_KEY], True)
                native.state["runtime-added"] = "preserved"
                owner.restore()
                expected = {**(state or {}), "runtime-added": "preserved"}
                self.assertEqual(plistlib.dumps(native.state), plistlib.dumps(expected))

    def test_ambiguous_read_refuses_before_any_mutation(self):
        native = DefaultsFixture({})
        native.fail_read = True
        owner = probe.AppleScriptPreference(DOMAIN, native.run)
        with self.assertRaisesRegex(RuntimeError, "could not be read"):
            owner.enable()
        owner.restore()
        self.assertEqual([call[1] for call in native.calls], ["export"])

    def test_a_failed_enable_that_wrote_still_restores_the_snapshot(self):
        native = DefaultsFixture({probe.APPLE_SCRIPT_KEY: "NO"})
        native.fail_write = True
        owner = probe.AppleScriptPreference(DOMAIN, native.run)
        with self.assertRaisesRegex(RuntimeError, "enable"):
            owner.enable()
        owner.restore()
        self.assertEqual(native.state[probe.APPLE_SCRIPT_KEY], "NO")

    def test_import_refusal_and_unacknowledged_restoration_fail(self):
        for fault in ("fail_import", "refuse_import"):
            with self.subTest(fault=fault):
                native = DefaultsFixture({probe.APPLE_SCRIPT_KEY: False})
                owner = probe.AppleScriptPreference(DOMAIN, native.run)
                owner.enable()
                setattr(native, fault, True)
                with self.assertRaisesRegex(RuntimeError, "restoration"):
                    owner.restore()

    def test_absent_key_requires_an_acknowledged_targeted_delete_after_import(self):
        native = DefaultsFixture({"other": "kept"})
        owner = probe.AppleScriptPreference(DOMAIN, native.run)
        owner.enable()
        native.state["runtime-added"] = "preserved"
        owner.restore()
        deletes = [call for call in native.calls if call[1] == "delete"]
        self.assertEqual(deletes, [["/usr/bin/defaults", "delete", DOMAIN, probe.APPLE_SCRIPT_KEY]])
        self.assertEqual(native.state, {"other": "kept", "runtime-added": "preserved"})

    def test_refused_or_unacknowledged_delete_does_not_claim_restoration(self):
        for fault in ("fail_delete", "refuse_delete"):
            with self.subTest(fault=fault):
                native = DefaultsFixture({"other": "kept"})
                owner = probe.AppleScriptPreference(DOMAIN, native.run)
                owner.enable()
                setattr(native, fault, True)
                with self.assertRaisesRegex(RuntimeError, "restoration"):
                    owner.restore()


class ObservationFailureTests(unittest.TestCase):
    """Cleanup refusal must neither replace the primary cause nor admit success."""

    def test_start_failure_and_cleanup_timeout_are_both_retained(self):
        primary = RuntimeError("initial AppleScript command refused by native process")
        cleanup = subprocess.TimeoutExpired(["osascript", "cleanup-owned-nonce"], 10)
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.nonce = NONCE
            with mock.patch.object(owner, "execute", side_effect=[primary, cleanup]) as execute:
                with self.assertRaisesRegex(
                    RuntimeError, "initial AppleScript command refused"
                ) as raised:
                    owner.observe(42, lambda _: [42])
                self.assertIn("cleanup", str(raised.exception))
                self.assertIn("TimeoutExpired", str(raised.exception))
                self.assertIs(raised.exception.__cause__, primary)
                self.assertEqual(execute.call_count, 2)
                self.assertIn(".cleanup", execute.call_args.args[0])

    def test_bad_native_receipt_and_cleanup_refusal_are_both_retained(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
            )
            owner.nonce = NONCE

            def execute(source):
                if ".cleanup" in source:
                    raise RuntimeError("cleanup nonce was not acknowledged")
                wrong = receipt()
                wrong["nonce"] = "b" * 32
                (output / "native-delayed-timers.json").write_text(json.dumps(wrong))

            with mock.patch.object(owner, "execute", side_effect=execute):
                with self.assertRaisesRegex(
                    RuntimeError, "identity or completion differs: nonce"
                ) as raised:
                    owner.observe(42, lambda _: [42])
                self.assertIn("cleanup nonce was not acknowledged", str(raised.exception))
                self.assertIsInstance(raised.exception.__cause__, ValueError)

    def test_cleanup_refusal_blocks_an_otherwise_valid_native_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
            )
            owner.nonce = NONCE

            def execute(source):
                if ".cleanup" in source:
                    raise RuntimeError("cleanup nonce was not acknowledged")
                (output / "native-delayed-timers.json").write_text(json.dumps(receipt()))

            with mock.patch.object(owner, "execute", side_effect=execute):
                with self.assertRaisesRegex(RuntimeError, "cleanup nonce was not acknowledged"):
                    owner.observe(42, lambda _: [42])


if __name__ == "__main__":
    unittest.main()
