# tools/diagnostics/hs_delayed_timer_probe_test.py
"""Refuse incomplete native observations and preserve the scripting preference."""

import base64
import copy
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import textwrap
import unittest
from unittest import mock

import hs_delayed_timer_probe as probe


EXECUTABLE = Path(
    "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
)
DOMAIN = "com.ergoptiplus.app.hammerspoon"
NONCE = "a" * 32


def observe_child_budgets(child):
    """Measure actual communicate deadlines while preserving the native child call."""
    budgets = []
    native_communicate = child.communicate

    def communicate(*args, **options):
        budgets.append(options.get("timeout"))
        return native_communicate(*args, **options)

    child.communicate = communicate
    return budgets


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


class NativeControlTests(unittest.TestCase):
    """The transport control owns a real child and never stands in for the feature."""

    def test_real_control_child_acknowledges_exact_nonce_and_exit(self):
        native_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.nonce = NONCE
            launched = []

            def launch(arguments, **options):
                launched.append(arguments)
                return native_popen([sys.executable, "-c", "print(" + repr(NONCE) + ")"], **options)

            with mock.patch.object(probe.subprocess, "Popen", side_effect=launch):
                summary = owner.control(42, lambda _: [42])
            probe.validate_control_summary(summary)
            self.assertEqual(summary["nonce"], NONCE)
            self.assertEqual(summary["pid"], 42)
            self.assertEqual(summary["executable"], str(EXECUTABLE))
            self.assertEqual(launched[0][0], "/usr/bin/osascript")
            self.assertEqual(launched[0][-1], 'return "' + NONCE + '"')
            self.assertEqual(owner.scripting_commands, [])
            self.assertFalse(owner.started, "control must not mark the feature as started")

    def test_native_control_refuses_missing_foreign_whitespace_and_nonzero_replies(self):
        for stdout, status in (
            ("", 0),
            (NONCE, 0),
            ("b" * 32 + "\n", 0),
            (" " + NONCE + "\n", 0),
            (NONCE + " \n", 0),
            (NONCE + "\n\n", 0),
            (NONCE + "\n", 1),
        ):
            with (
                self.subTest(stdout=stdout, status=status),
                tempfile.TemporaryDirectory() as folder,
            ):
                owner = probe.NativeDelayedTimerProbe(
                    Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
                )
                owner.nonce = NONCE
                child = mock.Mock(returncode=status)
                child.communicate.return_value = (stdout, "native refusal")
                with mock.patch.object(probe.subprocess, "Popen", return_value=child):
                    with self.assertRaisesRegex(RuntimeError, "nonce"):
                        owner.control(42, lambda _: [42])
                self.assertEqual(child.communicate.call_args, mock.call(timeout=10))
                self.assertEqual(
                    owner.scripting_commands, [], "terminal refused child is still joined"
                )

    def test_control_refuses_dispatch_acknowledgement_and_changed_live_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.nonce = NONCE
            for refused in (None, False, True, "b" * 32):
                with (
                    self.subTest(refused=refused),
                    mock.patch.object(owner, "execute", return_value=refused),
                ):
                    with self.assertRaisesRegex(RuntimeError, "did not acknowledge"):
                        owner.control(42, lambda _: [42])
            with mock.patch.object(owner, "execute", return_value=NONCE):
                with self.assertRaisesRegex(RuntimeError, "process changed"):
                    owner.control(42, mock.Mock(side_effect=[[42], [43]]))
            with mock.patch.object(owner, "execute") as native:
                with self.assertRaisesRegex(RuntimeError, "foreign or changed"):
                    owner.control(42, lambda _: [43])
            native.assert_not_called()

    def test_control_receipt_requires_strict_identity_and_same_feature_owner(self):
        valid = {
            "schema_version": 1,
            "contract": "hs.applescript.control",
            "phase": "control",
            "acknowledged": True,
            "nonce": NONCE,
            "pid": 42,
            "executable": str(EXECUTABLE),
        }
        probe.validate_control_summary(
            valid, {"nonce": NONCE, "pid": 42, "executable": str(EXECUTABLE)}
        )
        for field, value in (
            ("schema_version", True),
            ("acknowledged", False),
            ("acknowledged", "true"),
            ("pid", True),
            ("pid", 0),
            ("phase", "observation"),
            ("nonce", "foreign"),
            ("executable", "relative"),
        ):
            with self.subTest(field=field, value=value):
                with self.assertRaises(ValueError):
                    probe.validate_control_summary(dict(valid, **{field: value}))
        for changed in (None, {}, dict(valid, extra="unowned")):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                probe.validate_control_summary(changed)
        for field in ("nonce", "pid", "executable"):
            feature = {"nonce": NONCE, "pid": 42, "executable": str(EXECUTABLE)}
            feature[field] = 43 if field == "pid" else "foreign"
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "owners differ"):
                probe.validate_control_summary(valid, feature)

    def test_control_phase_cannot_bypass_retained_transport_debt(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            pending = mock.Mock()
            owner.scripting_commands.append(pending)
            with mock.patch.object(probe.subprocess, "Popen") as native:
                with self.assertRaisesRegex(RuntimeError, "has not settled"):
                    owner.control(42, lambda _: [42])
                with self.assertRaisesRegex(ValueError, "phase is unknown"):
                    owner.execute("return 'unowned'", phase="unowned")
            native.assert_not_called()
            self.assertEqual(owner.scripting_commands, [pending])


class PidControlTests(unittest.TestCase):
    """Keep native transport construction distinct from portable child proofs."""

    def owner(self, folder):
        owner = probe.NativeDelayedTimerProbe(
            Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
        )
        owner.nonce = NONCE
        return owner

    def test_distinct_pid_control_targets_same_event_without_path_resolution(self):
        native_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            launched = []

            def launch(arguments, **options):
                launched.append(arguments)
                return native_popen([sys.executable, "-c", "print(" + repr(NONCE) + ")"], **options)

            with mock.patch.object(probe.subprocess, "Popen", side_effect=launch):
                path = owner.control(42, lambda _: [42])
                alternative = owner.control_pid(42, lambda _: [42])
            self.assertEqual(launched[0][:2], ["/usr/bin/osascript", "-e"])
            self.assertIn(str(owner.app), launched[0][2])
            arguments = launched[1]
            self.assertEqual(arguments[:4], ["/usr/bin/osascript", "-l", "JavaScript", "-e"])
            self.assertEqual(arguments[-2:], ["42", 'return "' + NONCE + '"'])
            source = arguments[4]
            self.assertIn("descriptorWithProcessIdentifier(pid)", source)
            self.assertIn("Number(target.descriptorType) !== 0x6b706964", source)
            self.assertIn("0x486d5370, 0x45584543, target, -1, 0", source)
            self.assertIn("descriptorWithString(source), 0x2d2d2d2d", source)
            self.assertIn("constructOwnedEvent(Number(argv[0]), argv[1])", source)
            self.assertIn("sendEventWithOptionsTimeoutError(3, 10, error)", source)
            self.assertIn("paramDescriptorForKeyword(0x6572726e)", source)
            self.assertIn("Number(errorNumber.int32Value) !== 0", source)
            self.assertIn("paramDescriptorForKeyword(0x2d2d2d2d)", source)
            self.assertNotIn(str(owner.app), source)
            self.assertNotIn("Application(", source)
            self.assertNotIn("bundleIdentifier", source)
            probe.validate_pid_control_summary(alternative, path)
            with self.assertRaises(ValueError):
                probe.validate_control_summary(alternative)
            with self.assertRaises(ValueError):
                probe.validate_pid_control_summary(path)
            self.assertEqual(owner.scripting_commands, [])
            self.assertFalse(owner.started)
            self.assertEqual(owner.diagnostic_receipts[0]["phase"], "pid_control")

    def test_pid_control_rejects_strict_reply_and_nonterminal_child(self):
        for stdout, status in (
            ("", 0),
            (NONCE, 0),
            ("b" * 32 + "\n", 0),
            (" " + NONCE + "\n", 0),
            (NONCE + " \n", 0),
            (NONCE + "\n\n", 0),
            (NONCE + "\n", 1),
            (NONCE + "\n", None),
        ):
            with (
                self.subTest(stdout=stdout, status=status),
                tempfile.TemporaryDirectory() as folder,
            ):
                owner = self.owner(folder)
                child = mock.Mock(returncode=status)
                child.communicate.return_value = (stdout, "native refusal")
                with mock.patch.object(probe.subprocess, "Popen", return_value=child):
                    with self.assertRaises(RuntimeError):
                        owner.control_pid(42, lambda _: [42])
                self.assertEqual(child.communicate.call_args, mock.call(timeout=10))
                self.assertEqual(owner.scripting_commands, [child] if status is None else [])

    def test_pid_control_timeout_reaps_real_owned_child_before_retry(self):
        native_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            children = []
            communicate_budgets = []

            def launch(arguments, **options):
                source = (
                    "import time; time.sleep(5)" if not children else "print(" + repr(NONCE) + ")"
                )
                child = native_popen([sys.executable, "-c", source], **options)
                communicate_budgets.append(observe_child_budgets(child))
                children.append(child)
                return child

            try:
                with (
                    mock.patch.object(probe.subprocess, "Popen", side_effect=launch),
                    mock.patch.object(
                        owner, "sample_scripting_command", return_value=["owned child sampled"]
                    ),
                    mock.patch.object(
                        owner, "sample_native_runtime", return_value=["modeled native server"]
                    ),
                ):
                    with mock.patch.object(probe, "SCRIPTING_TIMEOUT_SECONDS", 0.05):
                        with self.assertRaisesRegex(RuntimeError, "TimeoutExpired"):
                            owner.control_pid(42, lambda _: [42])
                    self.assertIsNotNone(children[0].returncode)
                    self.assertEqual(owner.scripting_commands, [])
                    summary = owner.control_pid(42, lambda _: [42])
                probe.validate_pid_control_summary(summary)
                self.assertEqual(len(children), 2)
                self.assertIsNotNone(children[1].returncode)
                self.assertEqual(communicate_budgets[0], [0.05, 2])
                self.assertEqual(communicate_budgets[1][0], 10)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=2)

    def test_pid_control_contract_identity_and_diagnostics_are_bounded(self):
        valid = {
            "schema_version": 1,
            "contract": "hs.applescript.pid-control",
            "phase": "pid_control",
            "acknowledged": True,
            "nonce": NONCE,
            "pid": 42,
            "executable": str(EXECUTABLE),
        }
        for field, value in (
            ("schema_version", True),
            ("contract", "hs.applescript.control"),
            ("phase", "control"),
            ("acknowledged", 1),
            ("nonce", "foreign"),
            ("pid", True),
            ("executable", "relative"),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.validate_pid_control_summary(dict(valid, **{field: value}))
        with self.assertRaises(ValueError):
            probe.validate_pid_control_summary(dict(valid, extra="unowned"))
        with self.assertRaises(ValueError):
            probe.validate_pid_control_summary(valid, dict(valid, pid=43))
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            cause = subprocess.TimeoutExpired(["osascript", "SOURCE_ARG_MUST_NOT_LEAK"], 10)
            error = RuntimeError("wrapper containing SOURCE_ARG_MUST_NOT_LEAK")
            error.__cause__ = cause
            detail = owner.pid_control_error_diagnostic(error)
            self.assertIn("TimeoutExpired", detail)
            self.assertNotIn("SOURCE_ARG_MUST_NOT_LEAK", detail)
            detail = owner.pid_control_error_diagnostic(
                RuntimeError("/private/user/path " + "line\n" * 4000)
            )
            self.assertNotIn("/private/user/path", detail)
            self.assertIn("[path redacted]", detail)
            self.assertLessEqual(len(detail), probe.SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT)
            self.assertLessEqual(len(detail.splitlines()), probe.SCRIPT_DIAGNOSTIC_LINE_LIMIT)
            self.assertIn("[native diagnostic truncated]", detail)

    def test_pid_control_refuses_unbound_changed_foreign_or_debted_dispatch(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            with mock.patch.object(probe.subprocess, "Popen") as native:
                with self.assertRaisesRegex(RuntimeError, "no bound"):
                    owner.execute("return 'unowned'", phase="pid_control", _target_pid=42)
                owner.bind_runtime(42, lambda _: [42])
                for target in (True, 0, 43, None):
                    with (
                        self.subTest(target=target),
                        self.assertRaisesRegex(RuntimeError, "target differs"),
                    ):
                        owner.execute("return 'unowned'", phase="pid_control", _target_pid=target)
                owner.runtime_owner = (42, lambda _: [43])
                with self.assertRaisesRegex(RuntimeError, "target differs"):
                    owner.execute("return 'unowned'", phase="pid_control", _target_pid=42)
                owner.scripting_commands.append(mock.Mock())
                with self.assertRaisesRegex(RuntimeError, "has not settled"):
                    owner.control_pid(42, lambda _: [42])
                with self.assertRaisesRegex(ValueError, "reserved"):
                    owner.scripting_commands.clear()
                    owner.execute("return 'unowned'", phase="control", _target_pid=42)
            native.assert_not_called()

    def test_pid_control_rechecks_owner_before_dispatch_and_after_reply(self):
        for observations in ([[42], [43]], [[42], [42], [43]]):
            with self.subTest(observations=observations), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                child = mock.Mock(returncode=0)
                child.communicate.return_value = (NONCE + "\n", "")
                with mock.patch.object(probe.subprocess, "Popen", return_value=child) as native:
                    with self.assertRaisesRegex(RuntimeError, "target differs|process changed"):
                        owner.control_pid(42, mock.Mock(side_effect=observations))
                self.assertEqual(native.call_count, 0 if len(observations) == 2 else 1)
                self.assertEqual(owner.scripting_commands, [])

    def test_pid_control_refusal_cleanup_retains_debt_and_blocks_successor(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            primary = subprocess.TimeoutExpired(["osascript"], 10)
            cleanup = subprocess.TimeoutExpired(["osascript"], 2)
            child = mock.Mock(pid=43, returncode=None)
            child.poll.return_value = None
            child.communicate.side_effect = [primary, cleanup]
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=child) as native,
                mock.patch.object(owner, "sample_scripting_command", return_value=["owned sample"]),
                mock.patch.object(
                    owner, "sample_native_runtime", return_value=["owned server sample"]
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "TimeoutExpired"):
                    owner.control_pid(42, lambda _: [42])
                self.assertEqual(owner.scripting_commands, [child])
                with self.assertRaisesRegex(RuntimeError, "has not settled"):
                    owner.control_pid(42, lambda _: [42])
                self.assertEqual(native.call_count, 1)
            child.kill.assert_called_once_with()
            self.assertEqual(
                child.communicate.call_args_list, [mock.call(timeout=10), mock.call(timeout=2)]
            )
            self.assertEqual(owner.diagnostic_receipts[0]["phase"], "pid_control")


def no_prompt_receipt(status=0, result=NONCE, error_origin="none"):
    """Return independent native event outcomes without granting feature proof."""
    return {
        "schema_version": 1,
        "contract": "hs.applescript.pid-no-prompt",
        "phase": "pid_no_prompt",
        "nonce": NONCE,
        "pid": 42,
        "send_options": 131075,
        "status": status,
        "result": result,
        "error_origin": error_origin,
        "error_domain": "NSOSStatusErrorDomain" if error_origin == "send" else None,
    }


SENDER_PID = 31415
SENDER_STAGES = [
    "constructed",
    "send_entered",
    "send_returned",
    "error_decode_entered",
    "error_decode_complete",
    "reply_decode_complete",
]


SCALAR_STAGES = [
    "nserror_construct_entered",
    "nserror_construct_returned",
    "nserror_code_entered",
    "nserror_code_returned",
    "nserror_domain_entered",
    "nserror_domain_returned",
    "descriptor_construct_entered",
    "descriptor_construct_returned",
    "descriptor_int32_entered",
    "descriptor_int32_returned",
    "nil_ref_entered",
    "nil_ref_returned",
    "absent_errn_entered",
    "absent_errn_returned",
]
DECODER_STAGES = {
    "send": [
        "reference_entered",
        "reference_returned",
        "code_entered",
        "code_returned",
        "domain_entered",
        "domain_returned",
    ],
    "handler": ["errn_entered", "errn_returned", "int32_entered", "int32_returned"],
}


def supplemental_scalar_packets(scope, sender_pid, status):
    """Independent native constructor and branch goldens, not production-derived values."""
    identity = {"schema_version": 1, "nonce": NONCE, "target_pid": 42, "sender_pid": sender_pid}
    scalar = dict(
        identity,
        contract="hs.applescript.scalar-controls",
        stages=SCALAR_STAGES,
        facts={
            "code": {"type": "number", "integer": -1712},
            "domain": {"type": "string", "matches": True},
            "int32": {"type": "number", "integer": -50},
            "nil_ref": {"type": "undefined", "absent": True},
            "absent_errn": {
                "raw_type": "function",
                "type": "object",
                "native_absent": True,
                "absent": True,
            },
        },
    )
    branch = "send" if status != 0 else "handler"
    decoder = dict(
        identity,
        contract="hs.applescript.decoder-boundaries",
        branch=branch,
        stages=DECODER_STAGES[branch]
        if status != 0
        else ["errn_entered", "errn_returned", "absent_errn"],
        facts={
            "code": {"type": "number", "integer": status},
            "domain": {"type": "string", "recognized": True},
        }
        if status != 0
        else {
            "errn": {
                "raw_type": "function",
                "type": "object",
                "native_absent": True,
                "absent": True,
            }
        },
    )
    for name, packet in (("scalar.json", scalar), ("decoder.json", decoder)):
        if name in scope.allowed_names:
            (scope.path / name).write_text(json.dumps(packet) + "\n")


def publish_supplemental_fixture(
    owner, sender_pid, status, server="completed", stages=None, mutation=None
):
    """Model actual native file writes with independent closed protocol expectations."""
    scope = getattr(owner, "no_prompt_scope", None)
    if scope is None:
        return
    stages = stages if stages is not None else SENDER_STAGES if status == 0 else SENDER_STAGES[:-1]
    sender = {
        "schema_version": 1,
        "contract": "hs.applescript.sender-stages",
        "nonce": NONCE,
        "target_pid": 42,
        "sender_pid": sender_pid,
        "stages": stages,
    }
    (scope.path / "sender.json").write_text(json.dumps(sender) + "\n")
    supplemental_scalar_packets(scope, sender_pid, status)
    phases = (
        ["entry", "completion"]
        if server == "completed"
        else ["entry"]
        if server == "entered"
        else []
    )
    for phase in phases:
        witness = {
            "schema_version": 1,
            "contract": "hs.applescript.server-witness",
            "nonce": NONCE,
            "pid": 42,
            "executable": str(EXECUTABLE),
            "bundle_id": DOMAIN,
            "phase": phase,
        }
        (scope.path / (phase + ".json")).write_text(json.dumps(witness) + "\n")
    if mutation:
        mutation(scope.path)


def supplemental_mock_child(owner, native, server=None, stages=None, mutation=None, code=0):
    """Return a terminal fake sender whose files are not inferred from production policy."""
    child = mock.Mock(returncode=code, pid=SENDER_PID)

    def communicate(**options):
        publish_supplemental_fixture(
            owner,
            child.pid,
            native["status"],
            server if server is not None else "completed" if native["status"] == 0 else "none",
            stages,
            mutation,
        )
        return json.dumps(native) + "\n", ""

    child.communicate.side_effect = communicate
    return child


class SupplementalReadinessTests(unittest.TestCase):
    """Execution witnesses never substitute for the unchanged mandatory controls."""

    def owner(self, folder):
        owner = probe.NativeDelayedTimerProbe(
            Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
        )
        owner.nonce = NONCE
        return owner

    def invoke(self, owner, status=0, server="completed", stages=None, mutation=None, code=0):
        native = no_prompt_receipt(
            status, NONCE if status == 0 else None, "none" if status == 0 else "send"
        )
        child = supplemental_mock_child(owner, native, server, stages, mutation, code)
        with mock.patch.object(probe.subprocess, "Popen", return_value=child):
            return owner.control_pid_no_prompt(42, lambda _: [42])

    def test_acknowledged_reply_requires_both_owned_server_witnesses(self):
        for server in ("none", "entered"):
            with self.subTest(server=server), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                with self.assertRaises(ValueError):
                    self.invoke(owner, server=server)
                self.assertEqual(list(Path(folder).iterdir()), [])
                self.assertEqual(owner.scripting_commands, [])

    def test_completion_without_reply_is_execution_not_transport_admission(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            result = self.invoke(owner, status=-1712)
            self.assertEqual(result["outcome"], "refused")
            self.assertEqual(result["status"], -1712)
            self.assertIn("server witness: completed", str(owner.diagnostic_receipts))
            self.assertIn("sender stage: error_decode_complete", str(owner.diagnostic_receipts))
            self.assertNotIn(folder, str(owner.diagnostic_receipts))
            with self.assertRaises(ValueError):
                probe.validate_control_summary(result)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_sigsegv_retains_last_sender_stage_without_inventing_admission(self):
        for index in range(1, len(SENDER_STAGES) + 1):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                with self.assertRaises(RuntimeError) as error:
                    self.invoke(
                        owner, status=-1712, server="none", stages=SENDER_STAGES[:index], code=-11
                    )
                self.assertIn("exit -11", str(error.exception))
                self.assertIn(
                    "sender stage: " + SENDER_STAGES[index - 1], str(owner.diagnostic_receipts)
                )
                self.assertNotIn("denied", str(owner.diagnostic_receipts))
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_stale_malformed_and_foreign_server_receipts_refuse_reply(self):
        def edit(field, value):
            def mutation(path):
                file = path / "entry.json"
                data = json.loads(file.read_text())
                data[field] = value
                file.write_text(json.dumps(data) + "\n")

            return mutation

        mutations = [
            edit("nonce", "b" * 32),
            edit("pid", 43),
            edit("pid", True),
            edit("executable", "/foreign"),
            edit("bundle_id", "foreign"),
            edit("phase", "completion"),
            edit("unknown", True),
            lambda path: (path / "entry.json").write_text(
                '{"schema_version":1,"schema_version":1}\n'
            ),
            lambda path: (path / "entry.json").write_text("x" * 2049),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(ValueError):
                    self.invoke(self.owner(folder), mutation=mutation)
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_sender_identity_and_nonmonotonic_stage_prefix_are_rejected(self):
        def mutate(field, value):
            def mutation(path):
                file = path / "sender.json"
                data = json.loads(file.read_text())
                data[field] = value
                file.write_text(json.dumps(data) + "\n")

            return mutation

        mutations = [
            mutate("sender_pid", SENDER_PID + 1),
            mutate("sender_pid", True),
            mutate("target_pid", 43),
            mutate("nonce", "b" * 32),
            mutate("stages", ["send_entered"]),
            mutate("stages", SENDER_STAGES + ["foreign"]),
            mutate("stages", ["constructed", "constructed"]),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(ValueError):
                    self.invoke(self.owner(folder), mutation=mutation)

    def test_symlink_receipt_is_refused_without_touching_its_target(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            foreign = Path(outside) / "untouched.json"
            foreign.write_text("private-neighbour")

            def mutation(path):
                (path / "entry.json").unlink()
                (path / "entry.json").symlink_to(foreign)

            with self.assertRaises(ValueError):
                self.invoke(self.owner(folder), mutation=mutation)
            self.assertEqual(foreign.read_text(), "private-neighbour")
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_cleanup_refusal_retains_debt_and_does_not_skip_preference_restore(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            with mock.patch.object(Path, "rmdir", side_effect=OSError("owned removal refused")):
                with self.assertRaises(OSError):
                    self.invoke(owner)
            self.assertIsNotNone(owner.no_prompt_scope)
            with (
                mock.patch.object(probe.subprocess, "Popen") as spawn,
                self.assertRaises(RuntimeError),
            ):
                owner.control_pid_no_prompt(42, lambda _: [42])
            spawn.assert_not_called()
            with mock.patch.object(owner.preference, "restore") as restore:
                owner.restore()
            restore.assert_called_once_with()
            self.assertIsNone(owner.no_prompt_scope)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_refused_send_distinguishes_no_entry_and_entered_only_without_acknowledgement(self):
        for server, expected in (("none", "not_observed"), ("entered", "entered")):
            with self.subTest(server=server), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                result = self.invoke(owner, status=-1712, server=server)
                self.assertEqual(result["outcome"], "refused")
                self.assertIn("server witness: " + expected, str(owner.diagnostic_receipts))
                with self.assertRaises(ValueError):
                    probe.validate_pid_control_summary(result)

    def test_inode_replacement_during_read_cannot_admit_stale_witness(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            original_fdopen = os.fdopen

            class ReplacingReader:
                def __init__(self, descriptor, mode):
                    self.handle = original_fdopen(descriptor, mode)

                def __enter__(self):
                    self.handle.__enter__()
                    return self

                def __exit__(self, *args):
                    return self.handle.__exit__(*args)

                def fileno(self):
                    return self.handle.fileno()

                def read(self, size):
                    raw = self.handle.read(size)
                    path = owner.no_prompt_scope.path / "entry.json"
                    temporary = path.with_name("entry.json.pending")
                    temporary.write_bytes(raw)
                    os.replace(temporary, path)
                    return raw

            with mock.patch.object(os, "fdopen", side_effect=ReplacingReader):
                with self.assertRaises(ValueError):
                    self.invoke(owner)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_nonregular_receipt_is_refused_and_foreign_directory_is_never_removed(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)

            def mutation(path):
                file = path / "entry.json"
                file.unlink()
                file.mkdir()

            with self.assertRaises(RuntimeError):
                self.invoke(owner, mutation=mutation)
            self.assertIsNotNone(owner.no_prompt_scope)
            directory = owner.no_prompt_scope.path / "entry.json"
            self.assertTrue(directory.is_dir())
            directory.rmdir()
            with mock.patch.object(owner.preference, "restore"):
                owner.restore()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_crashed_sender_cannot_qualify_witnesses_after_live_owner_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            native = no_prompt_receipt()
            child = supplemental_mock_child(owner, native, code=-11)
            live = mock.Mock(side_effect=[[42], [42], [43]])
            with mock.patch.object(probe.subprocess, "Popen", return_value=child):
                with self.assertRaisesRegex(RuntimeError, "owner changed") as failure:
                    owner.control_pid_no_prompt(42, live)
            self.assertIn("exit -11", str(failure.exception.__cause__))
            self.assertNotIn("server witness: completed", str(owner.diagnostic_receipts))
            self.assertEqual(list(Path(folder).iterdir()), [])
            self.assertEqual(owner.scripting_commands, [])

    def test_timeout_retains_scope_until_actual_child_retirement_and_cleanup_acknowledge(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            native = no_prompt_receipt()
            child = mock.Mock(returncode=None, pid=SENDER_PID)
            child.poll.return_value = None
            captured = []

            def timed_out(**options):
                if options["timeout"] == 10:
                    captured.append(owner.no_prompt_scope)
                    publish_supplemental_fixture(owner, child.pid, 0, "entered", SENDER_STAGES[:2])
                raise subprocess.TimeoutExpired(["osascript"], options["timeout"])

            child.communicate.side_effect = timed_out
            spawn = mock.Mock(return_value=child)
            sample_child = mock.Mock(returncode=2)
            sample_arguments = []

            def create_owned_child(arguments, **options):
                if arguments[0] == "/usr/bin/osascript":
                    return spawn(arguments, **options)
                if arguments[0] != "/usr/bin/sample":
                    raise RuntimeError("The fixture refused an unknown child owner")
                sample_arguments.append(arguments)
                return sample_child

            with (
                mock.patch.object(probe.subprocess, "Popen", side_effect=create_owned_child),
                mock.patch.object(owner, "sample_scripting_command", return_value=[]),
                mock.patch.object(owner, "sample_native_runtime", return_value=[]),
            ):
                with self.assertRaisesRegex(RuntimeError, "TimeoutExpired"):
                    owner.control_pid_no_prompt(42, lambda _: [42])
            self.assertIsNotNone(owner.no_prompt_scope)
            scope = captured[0]
            self.assertIs(owner.no_prompt_scope, scope)
            self.assertEqual(owner.nonce, NONCE)
            self.assertEqual(scope.identity["nonce"], NONCE)
            self.assertTrue(scope.path.is_dir())
            retained = (scope.path / "entry.json").read_bytes()
            self.assertEqual(owner.scripting_commands, [child])
            self.assertEqual(spawn.call_count, 1)
            self.assertEqual(owner.server_sample_workers, [])
            self.assertIsNotNone(sample_child.returncode)
            sample_child.kill.assert_not_called()
            for arguments in sample_arguments:
                self.assertEqual(arguments[:4], ["/usr/bin/sample", "42", "1", "-file"])
                self.assertEqual(
                    arguments[4], str(Path(folder) / "sample-hammerspoon-no-prompt-1.txt")
                )
            self.assertEqual(
                child.communicate.call_args_list, [mock.call(timeout=10), mock.call(timeout=2)]
            )
            child.kill.assert_called_once_with()
            with mock.patch.object(probe.subprocess, "Popen") as replacement:
                with self.assertRaisesRegex(RuntimeError, "cleanup has not settled"):
                    owner.control_pid_no_prompt(42, lambda _: [42])
            replacement.assert_not_called()
            with self.assertRaises(subprocess.TimeoutExpired):
                owner.restore()
            self.assertIs(owner.no_prompt_scope, scope)
            self.assertEqual(owner.scripting_commands, [child])
            self.assertEqual((scope.path / "entry.json").read_bytes(), retained)

            def retired(**options):
                child.returncode = -9
                return "", ""

            child.communicate.side_effect = retired
            with mock.patch.object(Path, "rmdir", side_effect=OSError("owned removal refused")):
                with self.assertRaisesRegex(OSError, "removal refused"):
                    owner.restore()
            self.assertEqual(owner.scripting_commands, [])
            self.assertEqual(child.returncode, -9)
            self.assertIs(owner.no_prompt_scope, scope)
            self.assertTrue(scope.path.is_dir())
            with mock.patch.object(probe.subprocess, "Popen") as replacement:
                with self.assertRaisesRegex(RuntimeError, "cleanup has not settled"):
                    owner.control_pid_no_prompt(42, lambda _: [42])
            replacement.assert_not_called()
            owner.restore()
            self.assertIsNone(owner.no_prompt_scope)
            self.assertEqual(list(Path(folder).iterdir()), [])
            next_scopes = []
            next_child = supplemental_mock_child(owner, native)
            next_communicate = next_child.communicate.side_effect

            def next_receipt(**options):
                next_scopes.append(owner.no_prompt_scope)
                return next_communicate(**options)

            next_child.communicate.side_effect = next_receipt
            with mock.patch.object(probe.subprocess, "Popen", return_value=next_child):
                result = owner.control_pid_no_prompt(42, lambda _: [42])
            self.assertEqual(result["outcome"], "acknowledged")
            self.assertNotEqual(next_scopes[0].path, scope.path)
            self.assertEqual(list(Path(folder).iterdir()), [])
            self.assertEqual(owner.scripting_commands, [])

    def test_unacknowledged_process_exit_retains_exact_scope_and_child(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            child = supplemental_mock_child(owner, no_prompt_receipt(), code=None)
            child.poll.return_value = None
            with mock.patch.object(probe.subprocess, "Popen", return_value=child):
                with self.assertRaisesRegex(RuntimeError, "actual process exit"):
                    owner.control_pid_no_prompt(42, lambda _: [42])
            self.assertIsNotNone(owner.no_prompt_scope)
            self.assertEqual(owner.scripting_commands, [child])
            scope = owner.no_prompt_scope
            self.assertTrue((scope.path / "completion.json").is_file())
            with mock.patch.object(probe.subprocess, "Popen") as replacement:
                with self.assertRaisesRegex(RuntimeError, "cleanup has not settled"):
                    owner.control_pid_no_prompt(42, lambda _: [42])
            replacement.assert_not_called()
            child.returncode = -9
            child.communicate.side_effect = None
            child.communicate.return_value = ("", "")
            owner.restore()
            self.assertEqual(owner.scripting_commands, [])
            self.assertIsNone(owner.no_prompt_scope)
            self.assertFalse(scope.path.exists())

    def test_duplicate_unknown_receipt_key_never_enters_public_primary_error(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            marker = "PRIVATE_RECEIPT_KEY_MUST_NOT_LEAK"

            def corrupt(path):
                (path / "entry.json").write_text('{"' + marker + '":1,"' + marker + '":2}\n')

            with self.assertRaises(ValueError) as failure:
                self.invoke(owner, mutation=corrupt)
            owner.retain_primary_error(failure.exception, "pid_no_prompt")
            self.assertNotIn(marker, str(failure.exception))
            self.assertNotIn(marker, str(owner.diagnostic_receipts))
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_native_body_and_stages_use_actual_identity_and_checked_bounded_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            native = no_prompt_receipt()
            child = supplemental_mock_child(owner, native)
            with mock.patch.object(probe.subprocess, "Popen", return_value=child) as spawn:
                result = owner.control_pid_no_prompt(42, lambda _: [42])
            script = spawn.call_args.args[0][4]
            self.assertIn("i.processID", script)
            self.assertIn("i.executablePath", script)
            self.assertIn("i.bundleID", script)
            self.assertIn("writeToFileAtomically", script)
            self.assertIn("size > 2048", script)
            self.assertIn("Supplemental stage write refused", script)
            self.assertIn("ownedWitnessSource(argv[1], pid, argv[2])", script)
            self.assertEqual(result["status"], 0)
            self.assertIn("server witness: completed", str(owner.diagnostic_receipts))
            self.assertEqual(child.communicate.call_args, mock.call(timeout=10))


class NoPromptControlTests(unittest.TestCase):
    def owner(self, folder):
        owner = probe.NativeDelayedTimerProbe(
            Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
        )
        owner.nonce = NONCE
        return owner

    def test_exact_outcomes_use_same_constructor_sender_and_owned_terminal_child(self):
        for status, outcome in (
            (0, "acknowledged"),
            (-1744, "consent_required"),
            (-1743, "denied"),
            (-1708, "refused"),
        ):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                native = no_prompt_receipt(
                    status, NONCE if status == 0 else None, "none" if status == 0 else "send"
                )
                child = supplemental_mock_child(owner, native)
                with mock.patch.object(probe.subprocess, "Popen", return_value=child) as spawn:
                    receipt = owner.control_pid_no_prompt(42, lambda _: [42])
                self.assertEqual(receipt["outcome"], outcome)
                self.assertEqual(receipt["status"], status)
                self.assertEqual(receipt["executable"], str(EXECUTABLE))
                self.assertEqual(child.communicate.call_args, mock.call(timeout=10))
                arguments = spawn.call_args.args[0]
                self.assertEqual(arguments[:4], ["/usr/bin/osascript", "-l", "JavaScript", "-e"])
                self.assertEqual(arguments[-3:], ["42", 'return "' + NONCE + '"', NONCE])
                self.assertTrue(arguments[4].startswith(owner.pid_event_constructor()))
                self.assertIn("sendEventWithOptionsTimeoutError(131075, 8, error)", arguments[4])
                self.assertIn("var constructorRawCode = nativeError.code;", arguments[4])
                self.assertIn("Number(constructorRawCode)", arguments[4])
                self.assertEqual(
                    arguments[4].count("var constructorRawCode = nativeError.code;"), 1
                )
                self.assertIn("Number(errorNumber.int32Value)", arguments[4])
                self.assertEqual(owner.scripting_commands, [])
                self.assertFalse(owner.started)
                self.assertIn(str(status), owner.diagnostic_receipts[0]["observations"])
                with self.assertRaises(ValueError):
                    probe.validate_control_summary(receipt)
                with self.assertRaises(ValueError):
                    probe.validate_pid_control_summary(receipt)

    def test_receipt_refuses_identity_field_type_reply_and_error_ambiguity(self):
        valid = no_prompt_receipt()
        for field, value in (
            ("pid", 43),
            ("nonce", "b" * 32),
            ("send_options", 3),
            ("status", True),
            ("status", None),
            ("status", 2**32),
            ("result", NONCE + " "),
            ("error_origin", "send"),
            ("phase", "pid_control"),
        ):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                probe.validate_no_prompt_receipt(
                    json.dumps(dict(valid, **{field: value})) + "\n", NONCE, 42
                )
        for invalid in (
            dict(valid, extra=True),
            no_prompt_receipt(-1744, NONCE, "send"),
            no_prompt_receipt(-1743, None, "handler"),
            no_prompt_receipt(-50, None, "none"),
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                probe.validate_no_prompt_receipt(json.dumps(invalid) + "\n", NONCE, 42)
        foreign = no_prompt_receipt(-1744, None, "send")
        foreign["error_domain"] = "OtherErrorDomain"
        self.assertEqual(
            probe.validate_no_prompt_receipt(json.dumps(foreign) + "\n", NONCE, 42)["outcome"],
            "refused",
        )
        raw = json.dumps(valid)
        for invalid in (
            raw,
            raw + "\n\n",
            " " + raw + "\n",
            raw[:-1] + ', "status":0}\n',
            "x" * 9000,
        ):
            with self.subTest(invalid=invalid[:80]), self.assertRaises(ValueError):
                probe.validate_no_prompt_receipt(invalid, NONCE, 42)

    def test_owner_change_and_retained_child_debt_refuse_admission(self):
        for observations in (([43],), ([42], [43]), ([42], [42], [43])):
            with self.subTest(observations=observations), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                child = mock.Mock(returncode=0, pid=SENDER_PID)
                child.communicate.return_value = (json.dumps(no_prompt_receipt()) + "\n", "")
                with (
                    mock.patch.object(probe.subprocess, "Popen", return_value=child),
                    self.assertRaises(RuntimeError),
                ):
                    owner.control_pid_no_prompt(42, mock.Mock(side_effect=observations))
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            owner.scripting_commands.append(mock.Mock())
            with (
                mock.patch.object(probe.subprocess, "Popen") as spawn,
                self.assertRaises(RuntimeError),
            ):
                owner.control_pid_no_prompt(42, lambda _: [42])
            spawn.assert_not_called()

    def test_nonterminal_refused_and_timeout_children_never_offer_numeric_outcomes(self):
        for code in (None, 1):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                child = mock.Mock(returncode=code, pid=SENDER_PID)
                child.communicate.return_value = (
                    json.dumps(no_prompt_receipt(-1744, None, "send")) + "\n",
                    "refused",
                )
                with (
                    mock.patch.object(probe.subprocess, "Popen", return_value=child),
                    self.assertRaises(RuntimeError),
                ):
                    owner.control_pid_no_prompt(42, lambda _: [42])
                self.assertEqual(owner.scripting_commands, [child] if code is None else [])
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            child = mock.Mock(returncode=None, pid=SENDER_PID)
            primary = subprocess.TimeoutExpired(["osascript", "PRIVATE_SOURCE"], 10)
            child.communicate.side_effect = [primary, subprocess.TimeoutExpired(["osascript"], 2)]
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=child),
                mock.patch.object(
                    owner, "sample_scripting_command", return_value=["actual sender frame"]
                ),
                mock.patch.object(owner, "sample_native_runtime", return_value=[]),
            ):
                with self.assertRaises(RuntimeError) as error:
                    owner.control_pid_no_prompt(42, lambda _: [42])
            owner.retain_primary_error(error.exception, "pid_no_prompt")
            self.assertEqual(owner.scripting_commands, [child])
            self.assertIn("unchanged deadline", owner.diagnostic_receipts[0]["primary_error"])
            self.assertNotIn("PRIVATE_SOURCE", str(owner.diagnostic_receipts))
            with (
                mock.patch.object(probe.subprocess, "Popen") as spawn,
                self.assertRaises(RuntimeError),
            ):
                owner.control_pid_no_prompt(42, lambda _: [42])
            spawn.assert_not_called()

    def test_primary_error_survives_existing_samples_and_remains_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            owner.retain_diagnostics(["actual native frame"], "pid_control")
            owner.retain_primary_error(
                RuntimeError("Native status -1743\n::error::foreign\n" + "x\n" * 10000),
                "pid_control",
            )
            receipt = owner.diagnostic_receipts[0]
            self.assertEqual(receipt["observations"], "actual native frame")
            self.assertIn("Native status -1743", receipt["primary_error"])
            self.assertLessEqual(len(receipt["primary_error"]), 8192)
            self.assertLessEqual(len(receipt["primary_error"].splitlines()), 128)

    def test_native_send_budget_leaves_real_executor_time_for_construction_and_receipt(self):
        native_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            children = []
            communicate_budgets = []
            native_budgets = []

            def launch(arguments, **options):
                # Model only the native boundary; execute/communicate and retirement
                # remain real. The status is independent of the production builder.
                match = re.search(
                    r"sendEventWithOptionsTimeoutError\(131075, ([0-9.]+), error\)",
                    arguments[4],
                )
                self.assertIsNotNone(match)
                native_budget = float(match.group(1))
                native_budgets.append(native_budget)
                self.assertEqual(arguments[:4], ["/usr/bin/osascript", "-l", "JavaScript", "-e"])
                self.assertEqual(arguments[-3:], ["42", 'return "' + NONCE + '"', NONCE])
                receipt = {
                    "schema_version": 1,
                    "contract": "hs.applescript.pid-no-prompt",
                    "phase": "pid_no_prompt",
                    "nonce": NONCE,
                    "pid": 42,
                    "send_options": 131075,
                    "status": -1712,
                    "result": None,
                    "error_origin": "send",
                    "error_domain": "NSOSStatusErrorDomain",
                }
                source = (
                    "import time; time.sleep(1); time.sleep("
                    + repr(native_budget)
                    + "); print("
                    + repr(json.dumps(receipt))
                    + ", flush=True)"
                )
                child = native_popen([sys.executable, "-c", source], **options)
                communicate_budgets.append(observe_child_budgets(child))
                children.append(child)
                publish_supplemental_fixture(owner, child.pid, -1712, "none")
                return child

            try:
                with (
                    mock.patch.object(probe.subprocess, "Popen", side_effect=launch),
                    mock.patch.object(owner, "sample_scripting_command", return_value=[]),
                    mock.patch.object(owner, "sample_native_runtime", return_value=[]),
                ):
                    result = owner.control_pid_no_prompt(42, lambda _: [42])
                self.assertEqual(result["status"], -1712)
                self.assertEqual(result["outcome"], "refused")
                self.assertEqual(result["error_origin"], "send")
                self.assertEqual(result["error_domain"], "NSOSStatusErrorDomain")
                self.assertEqual(result["executable"], str(EXECUTABLE))
                self.assertEqual(communicate_budgets, [[10]])
                self.assertEqual(native_budgets, [8])
                self.assertEqual(children[0].returncode, 0)
                self.assertEqual(owner.scripting_commands, [])
                self.assertFalse(owner.started)
                with self.assertRaises(ValueError):
                    probe.validate_control_summary(result)
                with self.assertRaises(ValueError):
                    probe.validate_pid_control_summary(result)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=2)

    def test_real_owned_child_timeout_settles_before_native_receipt_retry(self):
        native_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            children = []
            communicate_budgets = []

            def launch(arguments, **options):
                source = (
                    "import time; time.sleep(5)"
                    if not children
                    else "print(" + repr(json.dumps(no_prompt_receipt(-1744, None, "send"))) + ")"
                )
                child = native_popen([sys.executable, "-c", source], **options)
                communicate_budgets.append(observe_child_budgets(child))
                children.append(child)
                publish_supplemental_fixture(owner, child.pid, -1744, "none")
                return child

            try:
                with (
                    mock.patch.object(probe.subprocess, "Popen", side_effect=launch),
                    mock.patch.object(owner, "sample_scripting_command", return_value=[]),
                    mock.patch.object(owner, "sample_native_runtime", return_value=[]),
                ):
                    with mock.patch.object(probe, "SCRIPTING_TIMEOUT_SECONDS", 0.05):
                        with self.assertRaises(RuntimeError):
                            owner.control_pid_no_prompt(42, lambda _: [42])
                    self.assertIsNotNone(children[0].returncode)
                    self.assertEqual(owner.scripting_commands, [])
                    result = owner.control_pid_no_prompt(42, lambda _: [42])
                    self.assertEqual(result["outcome"], "consent_required")
                    self.assertIsNotNone(children[1].returncode)
                    self.assertEqual(communicate_budgets[0], [0.05, 2])
                    self.assertEqual(communicate_budgets[1][0], 10)
                    self.assertEqual(owner.scripting_commands, [])
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=2)


def constructor_receipt():
    """Independent descriptor expectations; never derive them from the builder."""
    return {
        "schema_version": 1,
        "contract": "hs.applescript.constructor",
        "phase": "constructor",
        "constructed": True,
        "nonce": NONCE,
        "pid": 42,
        "address_type": 0x6B706964,
        "address_bytes_base64": base64.b64encode((42).to_bytes(4, sys.byteorder)).decode("ascii"),
        "event_class": 0x486D5370,
        "event_id": 0x45584543,
        "direct_type": 0x75747874,
        "direct_text": 'return "' + NONCE + ' — ù ★"',
    }


class ConstructorTests(unittest.TestCase):
    """Portable ownership proves no native API execution; scenarios own that proof."""

    def owner(self, folder):
        owner = probe.NativeDelayedTimerProbe(
            Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
        )
        owner.nonce = NONCE
        return owner

    def test_constructor_reuses_sender_native_builder_and_real_owned_child(self):
        native_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            receipt = constructor_receipt()
            raw = json.dumps(receipt, ensure_ascii=False)
            launched = []

            def launch(arguments, **options):
                launched.append(arguments)
                return native_popen([sys.executable, "-c", "print(" + repr(raw) + ")"], **options)

            with mock.patch.object(probe.subprocess, "Popen", side_effect=launch):
                result = owner.constructor_control(42, lambda _: [42])
            self.assertEqual(result, dict(receipt, executable=str(EXECUTABLE)))
            arguments = launched[0]
            self.assertEqual(arguments[:4], ["/usr/bin/osascript", "-l", "JavaScript", "-e"])
            self.assertEqual(arguments[-3:], ["42", receipt["direct_text"], NONCE])
            script = arguments[4]
            builder = owner.pid_event_constructor()
            self.assertTrue(script.startswith(builder))
            self.assertTrue(owner.pid_control_script().startswith(builder))
            self.assertEqual(script.count(builder), 1)
            self.assertIn("event.attributeDescriptorForKeyword(0x61646472)", script)
            self.assertIn("address.data.base64EncodedStringWithOptions(0)", script)
            self.assertIn("event.eventClass", script)
            self.assertIn("event.eventID", script)
            self.assertIn("direct.descriptorType", script)
            self.assertIn("direct.stringValue", script)
            for forbidden in ("sendEvent", "Application(", "launch", str(owner.app)):
                self.assertNotIn(forbidden, script)
            self.assertEqual(owner.scripting_commands, [])
            self.assertFalse(owner.started)
            self.assertEqual(owner.diagnostic_receipts[0]["phase"], "constructor")
            with self.assertRaises(ValueError):
                probe.validate_control_summary(result)
            with self.assertRaises(ValueError):
                probe.validate_pid_control_summary(result)

    def test_constructor_receipt_requires_exact_measured_descriptor_fields(self):
        valid = constructor_receipt()
        raw = json.dumps(valid, ensure_ascii=False) + "\n"
        self.assertEqual(
            probe.validate_constructor_receipt(raw, NONCE, 42, valid["direct_text"]), valid
        )
        for key, value in (
            ("constructed", 1),
            ("constructed", False),
            ("schema_version", True),
            ("contract", "hs.applescript.pid-control"),
            ("phase", "pid_control"),
            ("nonce", "foreign"),
            ("pid", True),
            ("pid", 43),
            ("address_type", 0x70736E20),
            ("event_class", 0x61657674),
            ("event_id", 0x6F617070),
            ("direct_type", 0x54455854),
            ("direct_text", 'return "ASCII replacement"'),
            ("address_bytes_base64", ""),
            ("address_bytes_base64", "!!!!AAAA"),
            (
                "address_bytes_base64",
                base64.b64encode((43).to_bytes(4, sys.byteorder)).decode("ascii"),
            ),
            ("address_bytes_base64", "KgAAAB=="),
        ):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                probe.validate_constructor_receipt(
                    json.dumps(dict(valid, **{key: value})) + "\n", NONCE, 42, valid["direct_text"]
                )
        for changed in (
            dict(valid, extra="unowned"),
            {key: value for key, value in valid.items() if key != "address_type"},
        ):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                probe.validate_constructor_receipt(
                    json.dumps(changed) + "\n", NONCE, 42, valid["direct_text"]
                )
        for malformed in (
            raw[:-1],
            raw + "\n",
            " " + raw,
            "[]\n",
            '{"pid":42,"pid":43}\n',
            "x" * 9000 + "\n",
        ):
            with self.subTest(malformed=malformed[:80]), self.assertRaises(ValueError):
                probe.validate_constructor_receipt(malformed, NONCE, 42, valid["direct_text"])

    def test_constructor_refuses_foreign_identity_and_retained_child_debt(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            with mock.patch.object(probe.subprocess, "Popen") as native:
                with self.assertRaisesRegex(RuntimeError, "foreign or changed"):
                    owner.constructor_control(42, lambda _: [43])
                pending = mock.Mock()
                owner.scripting_commands.append(pending)
                with self.assertRaisesRegex(RuntimeError, "has not settled"):
                    owner.constructor_control(42, lambda _: [42])
            native.assert_not_called()
            self.assertEqual(owner.scripting_commands, [pending])

    def test_constructor_rechecks_owner_before_dispatch_and_after_receipt(self):
        for observations in ([[42], [43]], [[42], [42], [43]]):
            with self.subTest(observations=observations), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                child = mock.Mock(returncode=0)
                child.communicate.return_value = (json.dumps(constructor_receipt()) + "\n", "")
                with mock.patch.object(probe.subprocess, "Popen", return_value=child) as native:
                    with self.assertRaisesRegex(RuntimeError, "target differs|process changed"):
                        owner.constructor_control(42, mock.Mock(side_effect=observations))
                self.assertEqual(native.call_count, 0 if len(observations) == 2 else 1)
                self.assertEqual(owner.scripting_commands, [])

    def test_constructor_rejects_malformed_refused_and_unsettled_native_results(self):
        for status, stdout in (
            (1, "{}\n"),
            (0, "{}\n"),
            (None, json.dumps(constructor_receipt()) + "\n"),
        ):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                child = mock.Mock(returncode=status)
                child.communicate.return_value = (stdout, "constructor refused")
                with mock.patch.object(probe.subprocess, "Popen", return_value=child):
                    with self.assertRaises((RuntimeError, ValueError)):
                        owner.constructor_control(42, lambda _: [42])
                self.assertEqual(child.communicate.call_args_list, [mock.call(timeout=10)])
                self.assertEqual(owner.scripting_commands, [child] if status is None else [])

    def test_constructor_timeout_retains_exact_child_until_cleanup_then_retries(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            primary = subprocess.TimeoutExpired(["osascript", "constructor"], 10)
            cleanup = subprocess.TimeoutExpired(["osascript", "constructor cleanup"], 2)
            child = mock.Mock(pid=43, returncode=None)
            child.poll.return_value = None
            child.communicate.side_effect = [primary, cleanup]
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=child) as native,
                mock.patch.object(
                    owner, "sample_scripting_command", return_value=["owned constructor sampled"]
                ),
                mock.patch.object(owner, "sample_native_runtime", return_value=[]),
            ):
                with self.assertRaisesRegex(RuntimeError, "TimeoutExpired"):
                    owner.constructor_control(42, lambda _: [42])
                with self.assertRaisesRegex(RuntimeError, "has not settled"):
                    owner.constructor_control(42, lambda _: [42])
                self.assertEqual(native.call_count, 1)
            self.assertEqual(owner.scripting_commands, [child])
            child.kill.assert_called_once_with()
            self.assertEqual(
                child.communicate.call_args_list, [mock.call(timeout=10), mock.call(timeout=2)]
            )
            child.returncode = -9
            child.communicate.side_effect = None
            child.communicate.return_value = ("", "")
            owner.retire_scripting_command(child)
            self.assertEqual(owner.scripting_commands, [])
            self.assertEqual(owner.diagnostic_receipts[0]["phase"], "constructor")


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
                self.assertEqual(execute.call_args.kwargs, {"phase": "cleanup"})

    def test_bad_native_receipt_and_cleanup_refusal_are_both_retained(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
            )
            owner.nonce = NONCE

            def execute(source, phase="observation"):
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

            def execute(source, phase="observation"):
                if ".cleanup" in source:
                    raise RuntimeError("cleanup nonce was not acknowledged")
                (output / "native-delayed-timers.json").write_text(json.dumps(receipt()))

            with mock.patch.object(owner, "execute", side_effect=execute):
                with self.assertRaisesRegex(RuntimeError, "cleanup nonce was not acknowledged"):
                    owner.observe(42, lambda _: [42])


class ScriptingLifecycleTests(unittest.TestCase):
    """An expired scripting child remains owned through sampling and real reaping."""

    def test_real_hanging_child_is_sampled_before_retirement(self):
        native_popen = subprocess.Popen
        children = []
        calls = []
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.bind_runtime(42, lambda _: [42])

            def launch(arguments, **options):
                calls.append(("launch", arguments))
                child = native_popen(
                    [sys.executable, "-c", "import time; time.sleep(30)"], **options
                )
                children.append(child)
                return child

            def sample(arguments, **options):
                if arguments[0] == "/usr/bin/osascript":
                    raise subprocess.TimeoutExpired(arguments, options["timeout"])
                pid = int(arguments[1])
                if pid == 42:
                    # This server port is explicitly modeled; the scripting
                    # child remains a real process and must still be alive.
                    os.kill(children[0].pid, 0)
                    calls.append(("server", pid, options["timeout"]))
                    Path(arguments[-1]).write_text(
                        f"Process: Hammerspoon [42]\nPath: {owner.executable}\nCall graph:\n"
                        "HSAppleScriptRunString (fixture server frame)\n"
                        "Binary Images:\ncom.apple.TCC (loaded image only)\n"
                    )
                    return subprocess.CompletedProcess(arguments, 0, "", "")
                os.kill(pid, 0)
                calls.append(("sample", pid, options["timeout"]))
                Path(arguments[-1]).write_text(
                    "Owned fixture process observed before retirement\nAESendMessage (fixture frame)\n"
                    "Binary Images:\ncom.apple.TCC (loaded image only)\n"
                )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            try:
                with (
                    mock.patch.object(probe.subprocess, "Popen", side_effect=launch),
                    mock.patch.object(probe.subprocess, "run", side_effect=sample),
                    mock.patch.object(probe, "SCRIPTING_TIMEOUT_SECONDS", 0.05),
                ):
                    with self.assertRaisesRegex(RuntimeError, "TimeoutExpired") as raised:
                        owner.execute("return 'fixture'", phase="control")
                self.assertIsInstance(raised.exception.__cause__, subprocess.TimeoutExpired)
                self.assertIn("sample-osascript-1.txt", str(raised.exception))
                self.assertIn("AESendMessage (fixture frame)", str(raised.exception))
                self.assertIn(
                    "HSAppleScriptRunString (fixture server frame)", str(raised.exception)
                )
                self.assertNotIn("loaded image only", str(raised.exception))
                self.assertEqual(calls[0][1][0], "/usr/bin/osascript")
                self.assertIn(str(owner.app), calls[0][1][2])
                self.assertEqual(
                    calls[1], ("sample", children[0].pid, probe.SCRIPT_CLEANUP_TIMEOUT_SECONDS)
                )
                self.assertEqual(calls[2], ("server", 42, probe.SCRIPT_CLEANUP_TIMEOUT_SECONDS))
                self.assertIsNotNone(
                    children[0].returncode, "the original child must actually be reaped"
                )
                self.assertEqual(owner.scripting_commands, [])
                retained = owner.diagnostic_receipts
                self.assertEqual(len(retained), 1)
                self.assertEqual(retained[0]["command"], 1)
                self.assertEqual(retained[0]["phase"], "control")
                self.assertIn(
                    "HSAppleScriptRunString (fixture server frame)", retained[0]["observations"]
                )
                self.assertNotIn("loaded image only", retained[0]["observations"])
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=2)

    def test_plain_native_receipts_redact_private_paths_and_bound_each_command(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.scripting_command_number = 1
            owner.retain_diagnostics(
                [
                    "observed native Hammerspoon server thread: Thread_42\n"
                    "TCCAccessRequest (source /Users/private/name/native.m:4)\n"
                    "https://private.example/signed?secret=hidden\n"
                    + "native frame\n"
                    * probe.SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT,
                ]
            )
            first = owner.diagnostic_receipts[0]
            self.assertEqual(first["command"], 1)
            self.assertNotIn("/Users/private", first["observations"])
            self.assertNotIn("private.example", first["observations"])
            self.assertNotIn("secret=hidden", first["observations"])
            self.assertIn("TCCAccessRequest (location redacted)", first["observations"])
            self.assertIn("[native diagnostic truncated]", first["observations"])
            self.assertLessEqual(
                len(first["observations"]), probe.SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT
            )
            self.assertLessEqual(
                len(first["observations"].splitlines()), probe.SCRIPT_DIAGNOSTIC_LINE_LIMIT
            )
            owner.scripting_command_number = 2
            owner.retain_diagnostics(["actual cleanup sample\n" + "x\n" * 500])
            self.assertIn(
                "[native diagnostic truncated]", owner.diagnostic_receipts[1]["observations"]
            )
            self.assertLessEqual(
                len(owner.diagnostic_receipts[1]["observations"].splitlines()),
                probe.SCRIPT_DIAGNOSTIC_LINE_LIMIT,
            )
            owner.scripting_command_number = 3
            owner.retain_diagnostics(["actual cleanup sample"], phase="cleanup")
            owner.scripting_command_number = 4
            owner.retain_diagnostics(["actual PID control sample"], phase="pid_control")
            owner.scripting_command_number = 5
            owner.retain_diagnostics(["actual constructor sample"], phase="constructor")
            owner.scripting_command_number = 6
            owner.retain_diagnostics(["actual no-prompt sample"], phase="pid_no_prompt")
            owner.scripting_command_number = 7
            owner.retain_diagnostics(["extra request"])
            self.assertEqual(len(owner.diagnostic_receipts), probe.SCRIPT_DIAGNOSTIC_RECEIPT_LIMIT)
            self.assertTrue(owner.diagnostic_receipts[-1]["additional_commands_omitted"])
            self.assertEqual(owner.diagnostic_receipts[-1]["phase"], "pid_no_prompt")

    def test_cleanup_refusal_keeps_lua_arguments_out_of_plain_sample_receipts(self):
        primary = subprocess.TimeoutExpired(["osascript", "PRIMARY_LUA_ARGUMENT"], 10)
        cleanup = subprocess.TimeoutExpired(["osascript", "CLEANUP_LUA_ARGUMENT"], 2)
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.bind_runtime(42, lambda _: [42])
            command = mock.Mock(pid=43, returncode=None)
            command.poll.return_value = None
            command.communicate.side_effect = [primary, cleanup]
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=command),
                mock.patch.object(
                    owner,
                    "sample_scripting_command",
                    return_value=["native scripting sample retained: sample-osascript-1.txt"],
                ),
                mock.patch.object(
                    owner,
                    "sample_native_runtime",
                    return_value=["observed native Hammerspoon server thread: Thread_42"],
                ),
            ):
                with self.assertRaises(RuntimeError) as raised:
                    owner.execute("PRIVATE_FIXTURE_LUA_SOURCE")
            self.assertIs(raised.exception.__cause__, primary)
            self.assertIn("PRIMARY_LUA_ARGUMENT", str(raised.exception))
            self.assertIn("CLEANUP_LUA_ARGUMENT", str(raised.exception))
            self.assertEqual(
                owner.scripting_commands,
                [command],
                "refused cleanup must retain its exact owned process",
            )
            retained = str(owner.diagnostic_receipts)
            self.assertIn("Thread_42", retained)
            self.assertNotIn("PRIMARY_LUA_ARGUMENT", retained)
            self.assertNotIn("CLEANUP_LUA_ARGUMENT", retained)
            self.assertNotIn("PRIVATE_FIXTURE_LUA_SOURCE", retained)

    def test_runtime_binding_requires_the_single_exact_live_integer_pid(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            for pid, observed in ((True, [True]), (0, [0]), (42, []), (42, [43]), (42, [42, 43])):
                with self.subTest(pid=pid, observed=observed):
                    with self.assertRaisesRegex(RuntimeError, "foreign or changed"):
                        owner.bind_runtime(pid, lambda _: observed)
                    self.assertIsNone(owner.runtime_owner)

    def test_server_sampler_never_observes_a_changed_or_unbound_process(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            with mock.patch.object(probe.subprocess, "run") as native:
                self.assertIn("no qualified owner", owner.sample_native_runtime()[0])
                owner.bind_runtime(42, lambda _: [42])
                owner.runtime_owner = (42, lambda _: [43])
                self.assertIn("exact owner changed", owner.sample_native_runtime()[0])
            native.assert_not_called()

    def test_native_server_sample_identity_and_post_sample_owner_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), output, DOMAIN
            )
            for process, path, post_owner in (
                ("Hammerspoon [43]", str(owner.executable), [42]),
                ("Hammerspoon [42]", "/foreign/Hammerspoon", [42]),
                ("Hammerspoon [42]", str(owner.executable), [43]),
            ):
                with self.subTest(process=process, path=path, post_owner=post_owner):
                    owner.bind_runtime(42, lambda _: [42])
                    owner.runtime_owner = (42, mock.Mock(side_effect=[[42], post_owner]))

                    def sample(arguments, **options):
                        Path(arguments[-1]).write_text(
                            f"Process: {process}\nPath: {path}\nCall graph:\nHSAppleScriptRunString (unqualified)\n"
                        )
                        return subprocess.CompletedProcess(arguments, 0, "", "")

                    with mock.patch.object(probe.subprocess, "run", side_effect=sample):
                        messages = owner.sample_native_runtime()
                    self.assertIn("unqualified", messages[0])
                    self.assertNotIn("unqualified)", " ".join(messages))

    def test_loaded_native_images_alone_are_never_reported_as_stack_frames(self):
        text = "Call graph:\nCFRunLoopRun (actual frame)\nBinary Images:\ncom.apple.TCC\ncom.apple.LaunchServices\n"
        self.assertEqual(
            probe.NativeDelayedTimerProbe.observed_sample_frames(text, ("TCC", "LaunchServices")),
            [],
        )
        self.assertEqual(
            probe.NativeDelayedTimerProbe.observed_sample_frames(text, ("CFRunLoop", "TCC")),
            ["CFRunLoopRun (actual frame)"],
        )

    def test_server_sampler_refusal_preserves_primary_timeout_and_actual_child_cleanup(self):
        primary = subprocess.TimeoutExpired(["osascript"], probe.SCRIPTING_TIMEOUT_SECONDS)
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.bind_runtime(42, lambda _: [42])
            command = mock.Mock(pid=43, returncode=None)
            command.poll.return_value = None
            command.communicate.side_effect = [primary, ("", "")]
            command.kill.side_effect = lambda: setattr(command, "returncode", -9)
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=command),
                mock.patch.object(
                    owner, "sample_scripting_command", return_value=["owned client sampled"]
                ),
                mock.patch.object(
                    probe.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(
                        [], 2, "", "actual server sampler denied"
                    ),
                ) as native,
            ):
                with self.assertRaisesRegex(RuntimeError, "actual server sampler denied") as raised:
                    owner.execute("return 'fixture'")
            self.assertIs(raised.exception.__cause__, primary)
            self.assertIn("TimeoutExpired", str(raised.exception))
            self.assertEqual(native.call_args.args[0][1], "42")
            self.assertEqual(native.call_args.kwargs["timeout"], 2)
            self.assertEqual(owner.scripting_commands, [])
            command.kill.assert_called_once_with()
            self.assertEqual(
                command.communicate.call_args_list, [mock.call(timeout=10), mock.call(timeout=2)]
            )

    def test_server_modal_frame_remains_visible_beyond_generic_main_loop_frames(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.bind_runtime(42, lambda _: [42])

            def sample(arguments, **options):
                Path(arguments[-1]).write_text(
                    f"Process: Hammerspoon [42]\nPath: {owner.executable}\nCall graph:\n"
                    + "\n".join(f"mach_msg fixture{i}" for i in range(10))
                    + "\nNSAlert runModal (actual modal frame)\nBinary Images:\ncom.apple.TCC (image only)\n"
                )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with mock.patch.object(probe.subprocess, "run", side_effect=sample):
                messages = owner.sample_native_runtime()
            self.assertIn("actual modal frame", messages[1])
            self.assertNotIn("image only", " ".join(messages))

    def test_server_sample_keeps_main_lua_and_background_wait_in_their_native_threads(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.bind_runtime(42, lambda _: [42])
            stacks = """Call graph:
617 Thread_33233 DispatchQueue_1: com.apple.main-thread (serial)
+ 617 start (in dyld) + 20
+ ! 615 NSApplicationMain (in AppKit) + 40
+ ! : 610 CFRunLoopRunSpecific (in CoreFoundation) + 50
+                   ! : |   + !   4 lua_pcallk (in LuaSkin) + 368
+                   ! : |   + !           :       3 HSAppleScriptRunString (in Hammerspoon) + 12
617 Thread_33234 DispatchQueue_2: com.apple.CFNetwork (serial)
+ 617 thread_start (in libsystem_pthread.dylib) + 8
+ ! 617 _dispatch_worker_thread2 (in libdispatch.dylib) + 36
+ ! : 617 CFNetworkNativeCaller (source /Users/private/secret.txt)
+                           617 _dispatch_semaphore_wait_slow (in libdispatch.dylib) + 132
617 Thread_33235 /Users/private/unrelated-thread
+ 617 unrelated (source /Users/private/unrelated-secret.txt)
Binary Images:
com.apple.TCC (loaded image only /Users/private/image-secret.txt)
"""

            def sample(arguments, **options):
                Path(arguments[-1]).write_text(
                    f"Process: Hammerspoon [42]\nPath: {owner.executable}\n"
                    + "Unrelated: /Users/private/header-secret.txt\n"
                    + stacks
                )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with mock.patch.object(probe.subprocess, "run", side_effect=sample):
                messages = owner.sample_native_runtime()
            self.assertEqual(len(messages), 3)
            self.assertIn("Thread_33233 DispatchQueue_1: com.apple.main-thread", messages[1])
            self.assertIn("+ ! 615 NSApplicationMain", messages[1])
            self.assertIn("+                   ! : |   + !   4 lua_pcallk", messages[1])
            self.assertIn(
                "+                   ! : |   + !           :       3 HSAppleScriptRunString",
                messages[1],
            )
            self.assertNotIn("semaphore", messages[1])
            self.assertIn("Thread_33234 DispatchQueue_2: com.apple.CFNetwork", messages[2])
            self.assertIn("+ ! 617 _dispatch_worker_thread2", messages[2])
            self.assertIn("CFNetworkNativeCaller", messages[2])
            self.assertIn(
                "+                           617 _dispatch_semaphore_wait_slow", messages[2]
            )
            self.assertNotIn("lua_pcallk", messages[2])
            observed = "\n".join(messages)
            for foreign in ("/Users/private", "Thread_33235", "com.apple.TCC", "loaded image only"):
                self.assertNotIn(foreign, observed)

    def test_native_thread_branches_do_not_inherit_a_sibling_call(self):
        sample = """Call graph:
9 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)
+ 9 root (in Hammerspoon) + 1
+ ! 4 unrelatedSibling (in Hammerspoon) + 2
+ ! : 4 unrelatedLeaf (in Hammerspoon) + 3
+ ! 5 nativeOwner (in Hammerspoon) + 4
+ ! : 5 lua_pcallk (in LuaSkin) + 5
9 Thread_2
+ 9 backgroundOwner (in Hammerspoon) + 6
+ ! 9 lua_pcallk (in LuaSkin) + 7
Binary Images:
lua_pcallk image only
"""
        contexts = probe.NativeDelayedTimerProbe.observed_sample_contexts(sample, ("lua_pcall",))
        self.assertEqual(len(contexts), 2)
        self.assertIn("root (in Hammerspoon)", contexts[0])
        self.assertIn("nativeOwner (in Hammerspoon)", contexts[0])
        self.assertNotIn("unrelatedSibling", contexts[0])
        self.assertNotIn("unrelatedLeaf", contexts[0])
        self.assertIn("Thread_2", contexts[1])
        self.assertIn("backgroundOwner", contexts[1])
        self.assertIn("lua_pcallk", contexts[0])
        self.assertIn("lua_pcallk", contexts[1])
        self.assertNotIn("image only", "\n".join(contexts))

    def test_native_thread_contexts_are_bounded_without_losing_the_selected_wait(self):
        lines = ["Call graph:", "9 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)"]
        lines.extend(
            "+ " + "! " * depth + f"9 caller{depth} (in Hammerspoon) + 1" for depth in range(35)
        )
        lines.append("+ " + "! " * 35 + "9 lua_pcallk (in LuaSkin) + 368")
        for thread in range(2, 7):
            lines.extend(
                (
                    f"9 Thread_{thread}",
                    "+ 9 backgroundOwner (in libdispatch.dylib) + 1",
                    "+ ! 9 _dispatch_semaphore_wait_slow (in libdispatch.dylib) + 132",
                )
            )
        contexts = probe.NativeDelayedTimerProbe.observed_sample_contexts(
            "\n".join(lines), ("lua_pcall", "dispatch_semaphore_wait")
        )
        self.assertEqual(len(contexts), probe.SCRIPT_SAMPLE_CONTEXT_THREAD_LIMIT)
        self.assertLessEqual(sum(map(len, contexts)), probe.SCRIPT_SAMPLE_CONTEXT_CHARACTER_LIMIT)
        self.assertIn("lua_pcallk", contexts[0])
        self.assertIn("native sample context truncated", contexts[0])
        self.assertIn("native ancestry omitted", contexts[0])
        self.assertIn("additional native thread contexts omitted", contexts[-1])
        self.assertNotIn("Thread_4", "\n".join(contexts))
        self.assertLessEqual(
            sum(line.lstrip().startswith("+") for line in contexts[0].splitlines()),
            probe.SCRIPT_SAMPLE_CONTEXT_FRAME_LIMIT,
        )

    def test_native_sample_headers_are_not_accepted_as_executing_stack_frames(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.bind_runtime(42, lambda _: [42])

            def sample(arguments, **options):
                Path(arguments[-1]).write_text(
                    f"Process: Hammerspoon [42]\nPath: {owner.executable}\n"
                    + "Source: /Users/private/TCC-secret.txt\nBinary Images:\nlua_pcallk image only\n"
                )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with mock.patch.object(probe.subprocess, "run", side_effect=sample):
                messages = owner.sample_native_runtime()
            self.assertIn("no Call graph section", messages[1])
            for foreign in ("/Users/private", "TCC-secret", "lua_pcallk", "observed native"):
                self.assertNotIn(foreign, "\n".join(messages))

    def test_unattributed_native_frames_redact_complete_source_locations(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            owner.bind_runtime(42, lambda _: [42])

            def sample(arguments, **options):
                Path(arguments[-1]).write_text(
                    f"Process: Hammerspoon [42]\nPath: {owner.executable}\nCall graph:\n"
                    + "NSAlert runModal (source /Users/private/secret data.txt)\n"
                )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with mock.patch.object(probe.subprocess, "run", side_effect=sample):
                messages = owner.sample_native_runtime()
            self.assertIn("thread unattributed", messages[1])
            self.assertIn("NSAlert runModal", messages[1])
            self.assertNotIn("/Users/private", messages[1])
            self.assertNotIn("secret data.txt", messages[1])
            self.assertNotIn("data.txt", messages[1])

    def test_sampling_and_retirement_failures_keep_primary_and_owner_debt(self):
        primary = subprocess.TimeoutExpired(["osascript"], probe.SCRIPTING_TIMEOUT_SECONDS)
        cleanup = subprocess.TimeoutExpired(["osascript"], probe.SCRIPT_CLEANUP_TIMEOUT_SECONDS)
        command = mock.Mock(pid=42)
        command.returncode = -9
        command.poll.return_value = None
        command.communicate.side_effect = [primary, cleanup, ("", "")]
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
            )
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=command) as launch,
                mock.patch.object(
                    probe.subprocess, "run", side_effect=RuntimeError("sampler refused")
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "sampler refused") as raised:
                    owner.execute("return 'fixture'")
                self.assertIs(raised.exception.__cause__, primary)
                self.assertIn("owned scripting process cleanup failed", str(raised.exception))
                self.assertEqual(owner.scripting_commands, [command])
                with self.assertRaisesRegex(RuntimeError, "prior native scripting command"):
                    owner.execute("return 'successor'")
                self.assertEqual(launch.call_count, 1)
                with mock.patch.object(owner.preference, "restore") as restore:
                    owner.restore()
                    restore.assert_called_once_with()
                self.assertEqual(owner.scripting_commands, [])
                self.assertEqual(command.communicate.call_args_list[0].kwargs["timeout"], 10)

    def test_complete_command_requires_exact_nonce_and_reaped_zero_status(self):
        for code, output in ((2, NONCE), (None, NONCE), (0, "wrong")):
            with self.subTest(code=code, output=output), tempfile.TemporaryDirectory() as folder:
                owner = probe.NativeDelayedTimerProbe(
                    Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
                )
                owner.nonce = NONCE
                command = mock.Mock(returncode=code)
                command.communicate.return_value = (output, "explicit refusal")
                with mock.patch.object(probe.subprocess, "Popen", return_value=command):
                    with self.assertRaisesRegex(RuntimeError, "did not acknowledge"):
                        owner.execute("return 'fixture'")
                self.assertEqual(owner.scripting_commands, [command] if code is None else [])


class SupplementalScalarBranchTests(unittest.TestCase):
    """Native scalar facts must be closed, bound, and separate from admission."""

    owner = SupplementalReadinessTests.owner
    invoke = SupplementalReadinessTests.invoke

    def mutate_packet(self, name, edit):
        def mutate(folder):
            file = folder / name
            if file.exists():
                data = json.loads(file.read_text())
                edit(data)
                file.write_text(json.dumps(data) + "\n")

        return mutate

    def test_scalar_and_branch_missing_receipts_refuse_terminal_reply(self):
        for name in ("scalar.json", "decoder.json"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)

                def remove(path):
                    (path / name).unlink(missing_ok=True)

                with self.assertRaises(ValueError):
                    self.invoke(owner, mutation=remove)
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_scalar_native_getter_mismatch_refuses_without_status_substitution(self):
        changes = [
            lambda d: d["facts"]["code"].update(integer=None, type="object"),
            lambda d: d["facts"]["int32"].update(integer=-49),
            lambda d: d["facts"]["domain"].update(matches=False),
            lambda d: d["facts"]["nil_ref"].update(absent=False),
            lambda d: d["facts"]["absent_errn"].update(absent=False),
            lambda d: d["facts"]["nil_ref"].update(type="boolean", absent=True),
            lambda d: d["facts"]["absent_errn"].update(type="number", absent=True),
            lambda d: d.update(sender_pid=42),
            lambda d: d.update(nonce="b" * 32),
            lambda d: d["stages"].append("future"),
            lambda d: d["facts"]["code"].update(integer=True),
            lambda d: d["facts"].update(private="secret-marker"),
        ]
        for edit in changes:
            with self.subTest(edit=edit), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                with self.assertRaises(ValueError):
                    self.invoke(owner, mutation=self.mutate_packet("scalar.json", edit))
                self.assertNotIn("secret-marker", str(owner.diagnostic_receipts))
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_decoder_closed_branch_prefix_and_status_match_are_mandatory(self):
        changes = [
            lambda d: d.update(branch="future"),
            lambda d: d.update(stages=["errn_returned"]),
            lambda d: d.update(sender_pid=True),
            lambda d: d["facts"]["errn"].update(absent=False),
            lambda d: d["facts"].update(code={"type": "number", "integer": 0}),
        ]
        for edit in changes:
            with self.subTest(edit=edit), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)
                with self.assertRaises(ValueError):
                    self.invoke(owner, mutation=self.mutate_packet("decoder.json", edit))
                self.assertEqual(list(Path(folder).iterdir()), [])
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            with self.assertRaises(ValueError):
                self.invoke(
                    owner,
                    status=-1712,
                    mutation=self.mutate_packet(
                        "decoder.json", lambda d: d["facts"]["code"].update(integer=-50)
                    ),
                )

    def test_partial_decoder_crash_retains_closed_read_boundary(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)

            def truncate(d):
                d.update(
                    stages=["reference_entered", "reference_returned", "code_entered"], facts={}
                )

            with self.assertRaisesRegex(RuntimeError, "exit -11"):
                self.invoke(
                    owner,
                    status=-1712,
                    code=-11,
                    mutation=self.mutate_packet("decoder.json", truncate),
                )
            self.assertIn(
                "decoder branch: send; boundary: code_entered", str(owner.diagnostic_receipts)
            )
            self.assertNotIn("denied", str(owner.diagnostic_receipts))
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_generated_supplemental_script_contains_exact_native_scalar_calls(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            script = probe.NativeDelayedTimerProbe.no_prompt_script(scope)
            for expression in (
                "$.NSError.errorWithDomainCodeUserInfo",
                "$.NSAppleEventDescriptor.descriptorWithInt32(-50)",
                "var rawCode = nativeError.code;",
                "Number(rawCode)",
                "ObjC.unwrap(nativeError.domain)",
                "var rawInt32 = errorNumber.int32Value;",
                "Number(rawInt32)",
                "recordDecoderBoundary('send', 'code_entered')",
                "recordDecoderBoundary('handler', 'int32_returned', 'int32', integerFact(status))",
            ):
                self.assertIn(expression, script)
            self.assertEqual(script.count("event.sendEventWithOptionsTimeoutError("), 1)
            scope.cleanup()

    def test_present_scalar_packets_require_actual_bound_sender_but_missing_does_not(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            owner = mock.Mock(no_prompt_scope=scope)
            # A physically present receipt with null sender matches the old expected None.
            publish_supplemental_fixture(owner, None, 0)
            with self.assertRaisesRegex(ValueError, "actual bound sender"):
                scope.observe()
            scope.cleanup()
        with tempfile.TemporaryDirectory() as folder:
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            self.assertEqual(scope.observe()["sender_stage"], "not_observed")
            self.assertIsNone(scope.sender_pid)
            scope.cleanup()

    def run_native_source_port(self, scope, mode):
        """Execute exact generated source against independent Foundation ports, never Cocoa."""
        port = r"""
const fs = require('fs');
const native = new WeakSet();
function wrap(value) { native.add(value); return value; }
const nil = wrap({isNil:()=>true});
const mode = __MODE__;
let sends = 0;
function $(...args) { if(args.length) throw Error('Unexpected nil constructor'); return wrap({isNil:()=>true}); }
$.NSUTF8StringEncoding=4;
$.NSProcessInfo={processInfo:{processIdentifier:31415}};
$.NSString={stringWithString:text=>({dataUsingEncoding:encoding=>{
    if(encoding!==4) throw Error('Encoding changed');
    return {isNil:()=>false,length:Buffer.byteLength(text),writeToFileAtomically:(path,atomic)=>{
        if(atomic!==true) throw Error('Atomic write changed');
        if(mode==='write_refusal' && path.endsWith('scalar.json')) return false;
        fs.writeFileSync(path,text); return true;
    }};
}})};
function nativeError(code) { return wrap({isNil:()=>false,isKindOfClass:klass=>klass===$.NSError,code:code,domain:'NSOSStatusErrorDomain'}); }
$.NSError={errorWithDomainCodeUserInfo:(domain,code,userInfo)=>{
    if(domain!=='NSOSStatusErrorDomain'||code!==-1712||userInfo.isNil()!==true) throw Error('NSError constructor changed');
    return nativeError(mode==='invalid_scalar'?undefined:code);
}};
$.NSAppleEventDescriptor={
    descriptorWithProcessIdentifier:pid=>({isNil:()=>false,descriptorType:0x6b706964}),
    descriptorWithString:text=>({isNil:()=>false,stringValue:text}),
    descriptorWithInt32:value=>{
        if(value!==-50) throw Error('Int32 constructor changed');
        return {isNil:()=>false,int32Value:value};
    },
    appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID:(klass,id,target,rid,tid)=>{
        if(klass!==0x486d5370||id!==0x45584543||rid!==-1||tid!==0) throw Error('Bridge changed');
        return {setParamDescriptorForKeyword:()=>{},paramDescriptorForKeyword:key=>{
            if(key!==0x6572726e) throw Error('Absent errn key changed'); return nil;
        },sendEventWithOptionsTimeoutError:(options,timeout,error)=>{
            if(options!==131075||timeout!==8) throw Error('Native deadline/options changed'); sends++;
            if(mode==='handler') return {isNil:()=>false,paramDescriptorForKeyword:key=>{
                if(key!==0x6572726e) throw Error('Handler errn key changed');
                return wrap({isNil:()=>false,isKindOfClass:klass=>klass===$.NSAppleEventDescriptor,int32Value:-50});
            }};
            Object.assign(error,nativeError(mode==='invalid_send'?undefined:-1712)); return nil;
        }};
    }
};
const ObjC={import:name=>{if(name!=='Foundation') throw Error('Import changed');},unwrap:value=>value,castObjectToRef:value=>{if(!native.has(value))throw Error('Native provenance refused');return {};}};
const Ref=()=>({});
__SCRIPT__
try { const result=run(['42','return "fixture"',__NONCE__]); process.stdout.write(result+'\n'); }
catch(error) { process.stdout.write(JSON.stringify({closed_failure:true,sends:sends})+'\n'); process.exitCode=1; }
"""
        source = (
            port.replace("__MODE__", json.dumps(mode))
            .replace("__SCRIPT__", probe.NativeDelayedTimerProbe.no_prompt_script(scope))
            .replace("__NONCE__", json.dumps(NONCE))
        )
        return subprocess.run(
            ["node", "-"], input=source, text=True, capture_output=True, timeout=5
        )

    def test_actual_generated_native_constructor_and_both_decoder_ports(self):
        for mode, expected_status, branch in (("send", -1712, "send"), ("handler", -50, "handler")):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
                scope.bind_sender(SENDER_PID)
                result = self.run_native_source_port(scope, mode)
                self.assertEqual(result.returncode, 0, "The generated native port refused")
                native = json.loads(result.stdout)
                self.assertEqual(native["status"], expected_status)
                self.assertEqual(native["error_origin"], branch)
                self.assertIsNotNone(
                    scope.read("scalar.json"), "The generated source omitted native scalar controls"
                )
                evidence = scope.observe(terminal=True, native=native)
                self.assertTrue(evidence["scalar_qualified"])
                self.assertEqual(evidence["decoder_branch"], branch)
                self.assertEqual(scope.read("scalar.json")["facts"]["code"]["integer"], -1712)
                self.assertEqual(scope.read("scalar.json")["facts"]["int32"]["integer"], -50)
                scope.cleanup()

    def test_actual_generated_native_port_keeps_invalid_scalars_and_write_refusal_closed(self):
        for mode in ("invalid_scalar", "invalid_send", "write_refusal"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
                scope.bind_sender(SENDER_PID)
                result = self.run_native_source_port(scope, mode)
                if mode == "invalid_scalar":
                    self.assertEqual(result.returncode, 0)
                    self.assertIsNotNone(
                        scope.read("scalar.json"),
                        "The native constructor control was not exercised",
                    )
                    with self.assertRaises(ValueError):
                        scope.observe(terminal=True, native=json.loads(result.stdout))
                    self.assertIsNone(scope.read("scalar.json")["facts"]["code"]["integer"])
                else:
                    self.assertEqual(result.returncode, 1, "The native port must refuse")
                    self.assertTrue(json.loads(result.stdout)["closed_failure"])
                    evidence = scope.observe()
                    if mode == "invalid_send":
                        self.assertIn("decoder_boundary", evidence)
                        self.assertEqual(evidence["decoder_boundary"], "domain_returned")
                        self.assertIsNone(scope.read("decoder.json")["facts"]["code"]["integer"])
                    else:
                        self.assertEqual(json.loads(result.stdout)["sends"], 0)
                scope.cleanup()


class SupplementalScalarFactSummaryTests(unittest.TestCase):
    """Closed constructor facts remain observable after their physical scope retires."""

    owner = SupplementalReadinessTests.owner
    invoke = SupplementalReadinessTests.invoke
    mutate_packet = SupplementalScalarBranchTests.mutate_packet

    def test_unqualified_constructor_identifies_exact_closed_getter_after_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            with self.assertRaises(ValueError):
                self.invoke(
                    owner,
                    mutation=self.mutate_packet(
                        "scalar.json", lambda d: d["facts"]["code"].update(integer=None)
                    ),
                )
            observed = str(owner.diagnostic_receipts)
            self.assertIn("code(type=number,integer=unavailable)", observed)
            self.assertIn("int32(type=number,integer=-50)", observed)
            self.assertIn("domain(type=string,matches=true)", observed)
            self.assertIn("nil_ref(type=undefined,absent=true)", observed)
            self.assertIn("absent_errn(type=object,absent=true)", observed)
            self.assertIn("qualified: false", observed)
            self.assertNotIn(folder, observed)
            self.assertNotIn(NONCE, observed)
            self.assertEqual(list(Path(folder).iterdir()), [])
            self.assertIsNone(owner.no_prompt_scope)

    def test_unexpected_constructor_integer_is_closed_not_raw_payload(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            with self.assertRaises(ValueError):
                self.invoke(
                    owner,
                    mutation=self.mutate_packet(
                        "scalar.json", lambda d: d["facts"]["int32"].update(integer=987654321)
                    ),
                )
            observed = str(owner.diagnostic_receipts)
            self.assertIn("code(type=number,integer=-1712)", observed)
            self.assertIn("int32(type=number,integer=unexpected_integer)", observed)
            self.assertNotIn("987654321", observed)
            self.assertNotIn(NONCE, observed)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_actual_decoder_scalar_invalid_and_partial_reads_are_observations_only(self):
        for partial in (False, True):
            with self.subTest(partial=partial), tempfile.TemporaryDirectory() as folder:
                owner = self.owner(folder)

                def mutate(d):
                    if partial:
                        d.update(stages=["reference_entered"], facts={})
                    else:
                        d["facts"]["code"]["integer"] = None

                with self.assertRaisesRegex(RuntimeError, "exit -11"):
                    self.invoke(
                        owner,
                        status=-1712,
                        code=-11,
                        mutation=self.mutate_packet("decoder.json", mutate),
                    )
                observed = str(owner.diagnostic_receipts)
                if partial:
                    self.assertIn("Supplemental decoder scalars: not_observed", observed)
                    self.assertIn("boundary: reference_entered", observed)
                else:
                    self.assertIn(
                        "Supplemental decoder scalars: code(type=number,integer=unavailable)",
                        observed,
                    )
                    self.assertIn("domain(type=string,recognized=true)", observed)
                self.assertNotIn("admitted", observed)
                self.assertNotIn("denied", observed)
                self.assertNotIn(NONCE, observed)
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_unknown_synthetic_fact_type_never_projects_private_payload(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            with self.assertRaises(ValueError) as error:
                self.invoke(
                    owner,
                    mutation=self.mutate_packet(
                        "scalar.json",
                        lambda d: d["facts"]["code"].update(type="private-secret-marker"),
                    ),
                )
            self.assertNotIn("private-secret-marker", str(error.exception))
            self.assertNotIn("private-secret-marker", str(owner.diagnostic_receipts))
            self.assertEqual(list(Path(folder).iterdir()), [])


class NSErrorOutSlotCalibrationTests(unittest.TestCase):
    """Execute exact supplemental source against independent bridge identity ports."""

    def run_source(self, scope, mode="native", capture=False):
        port = r"""
const fs=require('fs');
const mode=__MODE__;
const nativeString=mode.startsWith('native_string');
const native=new WeakSet();
let parses=0,sends=0;
function callableInteger(value) { const getter=()=>{throw Error('Scalar getters must not be invoked');}; getter.valueOf=()=>value; return getter; }
function wrapper(nil, klass) {
    const value=function(){throw Error('Native wrappers are not JS callbacks');};
    native.add(value);
    value.isNil=()=>nil;
    value.isKindOfClass=kind=>kind===klass;
    return value;
}
const nil=wrapper(true,null);
const NSError={};
function error(code,domain) { const value=wrapper(false,NSError); value.code=code; value.domain=domain; return value; }
function $() { return wrapper(true,null); }
$.NSUTF8StringEncoding=4;
$.NSProcessInfo={processInfo:{processIdentifier:31415}};
$.NSString={stringWithString:text=>({dataUsingEncoding:encoding=>{
    if(encoding!==4) throw Error('Expected actual UTF8 encoding');
    return {isNil:()=>false,length:Buffer.byteLength(text),utf8:text,writeToFileAtomically:(path,atomic)=>{
        if(atomic!==true) throw Error('Expected atomic publication');
        if(mode==='write_refusal'&&path.endsWith('calibration.json')) return false;
        if(mode==='getter_write_refusal'&&path.endsWith('getter.json')) return false;
        fs.writeFileSync(path,text); return true;
    }};
}})};
$.NSError=NSError;
$.NSNumber={numberWithInteger:raw=>{
    if(mode==='box_refusal') throw Error('Owned NSNumber constructor refused');
    if(mode==='box_forged'||(mode==='send_string'&&typeof raw==='string')||mode==='native_string_box_forged') return {isNil:()=>false,isKindOfClass:()=>true,integerValue:Number(raw)};
    const box=wrapper(mode==='native_string_box_nil',mode==='box_wrong_class'||mode==='native_string_box_wrong_class'?null:$.NSNumber);
    const integer=mode==='box_mismatch'||mode==='native_string_box_mismatch'?Number(raw)+1:Number(raw);
    box.integerValue=mode==='box_callable'||mode==='native_string_box_callable'?callableInteger(integer):mode==='native_string_box_boolean'?true:mode==='native_string_box_fraction'?'-1712.5':nativeString?String(integer):integer;
    return box;
}};
$.NSError.errorWithDomainCodeUserInfo=(domain,code,userInfo)=>{
    if(domain!=='NSOSStatusErrorDomain'||code!==-1712||!native.has(userInfo)||!userInfo.isNil())
        throw Error('Constructor control changed');
    return error(mode==='send_callable'?callableInteger(-1712):nativeString?'-1712':-1712,'NSOSStatusErrorDomain');
};
$.NSJSONSerialization={JSONObjectWithDataOptionsError:(data,options,out)=>{
    if(data.utf8!=='['||options!==0) throw Error('Expected independent inert UTF8 payload');
    parses++;
    if(out.rawRef===true) {
        out[0]=mode==='raw_valid'?error(3840,'NSCocoaErrorDomain'):wrapper(false,null);
    } else {
        if(!native.has(out)) throw Error('Expected native object holder');
        out.isNil=()=>false;
        out.isKindOfClass=klass=>mode==='wrong_class'?false:klass===NSError;
        out.code=mode==='wrong_status'?3841:mode==='boolean_status'?true:nativeString?'3840':3840;
        if(mode==='send_callable') out.code=callableInteger(3840);
        out.domain=mode==='wrong_domain'?'private-secret-marker':'NSCocoaErrorDomain';
    }
    return mode==='nonnil_result'?wrapper(false,null):nil;
}};
const Ref=()=>({rawRef:true});
let absent=nil;
if(mode==='fake_function') { absent=function(){}; absent.isNil=()=>true; }
if(mode==='number') absent=42;
if(mode==='false_nil') { absent=wrapper(false,null); absent.isNil=()=>false; }
if(mode==='truthy_nil') { absent=wrapper(false,null); absent.isNil=()=>1; }
$.NSAppleEventDescriptor={
    descriptorWithProcessIdentifier:pid=>({isNil:()=>false,descriptorType:0x6b706964}),
    descriptorWithString:text=>({isNil:()=>false,stringValue:text}),
    descriptorWithInt32:value=>({isNil:()=>false,int32Value:value}),
    appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID:(klass,id,target,rid,tid)=>({
        setParamDescriptorForKeyword:()=>{},
        paramDescriptorForKeyword:key=>{
            if(key!==0x6572726e) throw Error('Expected real absent errn keyword');
            return absent;
        },
        sendEventWithOptionsTimeoutError:(options,timeout,out)=>{
            if(options!==131075||timeout!==8) throw Error('Original admission/budget changed');
            sends++;
            if(mode==='handler_valid'||mode==='handler_nil'||mode==='handler_forged'||mode==='handler_forged_nil'||mode==='handler_boolean') {
                const handler=wrapper(false,$.NSAppleEventDescriptor);
                handler.paramDescriptorForKeyword=key=>{
                    if(key===0x2d2d2d2d) { const text=wrapper(false,$.NSAppleEventDescriptor); text.stringValue=__NONCE__; return text; }
                    if(key!==0x6572726e) throw Error('Unexpected handler keyword');
                    if(mode==='handler_nil') return nil;
                    if(mode==='handler_forged'||mode==='handler_forged_nil') { const fake=function(){}; fake.isNil=()=>mode==='handler_forged_nil'; fake.int32Value=-50; return fake; }
                    const descriptor=wrapper(false,$.NSAppleEventDescriptor);
                    descriptor.int32Value=mode==='handler_boolean'?true:-50;
                    return descriptor;
                };
                return handler;
            }
            if(out.rawRef===true) { out[0]=wrapper(false,null); return nil; }
            if(!native.has(out)) throw Error('Expected exact native NSError object holder');
            out.isNil=()=>mode==='send_nil';
            out.isKindOfClass=klass=>mode!=='send_wrong_class'&&klass===NSError;
            out.code=mode==='send_boolean'?true:mode==='send_string'?'-1712':mode==='send_valid'||mode==='send_wrong_class'||mode==='send_nil'||mode==='send_other_domain'||mode==='send_missing_domain'?-1712:NaN;
            if(mode==='send_callable') out.code=callableInteger(-1712);
            if(nativeString) {
                const codes={native_string_fraction:'-1712.5',native_string_unsafe:'9007199254740993',
                    native_string_exponent:'-1.712e3',native_string_hex:'0xF',native_string_space:' -1712',
                    native_string_zero_prefix:'-01712',native_string_boolean:true};
                out.code=Object.hasOwn(codes,mode)?codes[mode]:'-1712';
                if(mode==='native_string_owner_changes') { let reads=0; Object.defineProperty(out,'code',{get:()=>++reads===1?'-1712':'-50'}); }
                if(mode==='native_string_foreign_owner') native.delete(out);
            }
            out.domain=mode==='send_other_domain'||mode==='native_string_other_domain'?'NSCocoaErrorDomain':mode==='send_missing_domain'?'':mode.startsWith('send_')||nativeString?'NSOSStatusErrorDomain':undefined;
            return nil;
        }
    })
};
const ObjC={import:name=>{if(name!=='Foundation')throw Error('Import changed');},unwrap:value=>value,
    castObjectToRef:value=>{if(!native.has(value))throw Error('Not a native ObjC wrapper');return {};}};
__SCRIPT__
let output=null,refused=false;
try { output=run(['42','return "fixture"',__NONCE__]); }
catch(error) { refused=true; /* Keep every unknown AppleEvent status a refusal. */ }
process.stdout.write(JSON.stringify({parses:parses,sends:sends,...(__CAPTURE__?{output:output,refused:refused}:{})})+'\n');
"""
        source = (
            port.replace("__MODE__", json.dumps(mode))
            .replace("__SCRIPT__", probe.NativeDelayedTimerProbe.no_prompt_script(scope))
            .replace("__NONCE__", json.dumps(NONCE))
            .replace("__CAPTURE__", json.dumps(capture))
        )
        result = subprocess.run(
            ["node", "-"], input=source, text=True, capture_output=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, "The independent source executor crashed")
        return json.loads(result.stdout)

    def test_raw_callable_integer_is_observed_with_native_box_but_remains_a_refusal(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            observed = self.run_source(scope, "send_callable", capture=True)
            self.assertEqual(observed, {"parses": 2, "sends": 1, "output": None, "refused": True})
            packet = scope.read("getter.json")
            self.assertIsNotNone(packet, "Exact emitted source did not record the raw getter")
            self.assertEqual(set(packet["facts"]), {"calibration", "constructor", "send"})
            for name in ("calibration", "constructor", "send"):
                fact = packet["facts"][name]
                self.assertEqual(fact["raw_type"], "function")
                for flag in (
                    "owner_native",
                    "converted_integer",
                    "box_native",
                    "box_integer",
                    "box_matches",
                ):
                    self.assertIs(fact[flag], True, (name, flag))
                self.assertIs(fact["control_matches"], None if name == "send" else True)
            script = probe.NativeDelayedTimerProbe.no_prompt_script(scope)
            self.assertIn("typeof rawCode !== 'number' || !Number.isInteger(rawCode)", script)
            self.assertIn("typeof rawInt32 !== 'number' || !Number.isInteger(rawInt32)", script)
            self.assertEqual(script.count("sendEventWithOptionsTimeoutError("), 1)
            evidence = scope.getter_evidence()
            self.assertIn(
                "send(raw_type=function,owner_native=true,converted_integer=true", evidence
            )
            for private in (NONCE, folder, "-1712", "3840", "NSOSStatusErrorDomain"):
                self.assertNotIn(private, evidence)
            self.assertEqual(scope.observe()["server"], "not_observed")
            scope.cleanup()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_native_number_projection_requires_real_class_and_exact_integer_match(self):
        for mode, native, matches, raw_type in (
            ("box_forged", False, False, "undefined"),
            ("box_wrong_class", False, False, "undefined"),
            ("box_refusal", False, False, "undefined"),
            ("box_mismatch", True, False, "number"),
            ("box_callable", True, True, "function"),
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                observed = self.run_source(scope, mode, capture=True)
                self.assertEqual((observed["parses"], observed["sends"]), (2, 1))
                self.assertIs(observed["refused"], True)
                fact = scope.read("getter.json")["facts"]["constructor"]
                self.assertIs(fact["box_native"], native)
                self.assertIs(fact["box_matches"], matches)
                self.assertEqual(fact["box_raw_type"], raw_type)
                self.assertIn("qualified=true", scope.calibration_evidence())
                scope.getter_evidence()
                scope.cleanup()

    def test_getter_owner_closed_shape_and_native_match_refuse_fabricated_packets(self):
        mutations = (
            lambda p: p.update(sender_pid=43),
            lambda p: p.update(nonce="b" * 32),
            lambda p: p["facts"].update(foreign={}),
            lambda p: p["facts"]["send"].update(raw_type="private-secret-marker"),
            lambda p: p["facts"]["send"].update(control_matches=True),
            lambda p: p["facts"]["constructor"].update(box_native=False, box_matches=True),
            lambda p: p["facts"]["constructor"].update(owner_native=1),
            lambda p: p["facts"]["constructor"].update(raw_value="private-secret-marker"),
        )
        for edit in mutations:
            with self.subTest(edit=edit), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                self.run_source(scope, "send_callable")
                path = scope.path / "getter.json"
                packet = scope.read("getter.json")
                edit(packet)
                path.write_text(json.dumps(packet) + "\n")
                with self.assertRaises(ValueError) as failure:
                    scope.getter_evidence()
                self.assertNotIn("private-secret-marker", str(failure.exception))
                scope.cleanup()

    def test_getter_publication_refusal_preserves_original_send_and_controls(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            observed = self.run_source(scope, "getter_write_refusal", capture=True)
            self.assertEqual((observed["parses"], observed["sends"]), (2, 1))
            self.assertIs(observed["refused"], True)
            self.assertEqual(scope.getter_evidence(), "not_observed")
            self.assertIn("qualified=true", scope.calibration_evidence())
            self.assertTrue(scope.scalar_evidence()["scalar_qualified"])
            self.assertIsNotNone(scope.read("decoder.json"))
            scope.cleanup()

    def test_original_numeric_send_status_is_unchanged_by_supplemental_getter(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            observed = self.run_source(scope, "send_valid", capture=True)
            self.assertEqual((observed["parses"], observed["sends"]), (2, 1))
            self.assertIs(observed["refused"], False)
            native = json.loads(observed["output"])
            self.assertEqual(
                (native["status"], native["error_origin"], native["error_domain"]),
                (-1712, "send", "NSOSStatusErrorDomain"),
            )
            self.assertIn("send(raw_type=number,owner_native=true", scope.getter_evidence())
            scope.cleanup()

    def test_getter_receipt_remains_bounded_nonfollowing_and_cleanup_owned(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            self.run_source(scope, "send_callable")
            path = scope.path / "getter.json"
            self.assertLessEqual(path.stat().st_size, probe.SUPPLEMENTAL_RECEIPT_LIMIT)
            neighbour = Path(folder) / "foreign.json"
            neighbour.write_text("private-secret-marker\n")
            path.unlink()
            path.symlink_to(neighbour)
            with self.assertRaises(ValueError) as failure:
                scope.getter_evidence()
            self.assertNotIn("private-secret-marker", str(failure.exception))
            scope.cleanup()
            self.assertEqual(neighbour.read_text(), "private-secret-marker\n")
            self.assertEqual(list(Path(folder).iterdir()), [neighbour])

    def scope(self, folder):
        scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
        scope.bind_sender(SENDER_PID)
        return scope

    def test_object_holder_calibration_retains_actual_callable_nil_without_admitting_event(
        self,
    ):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            observations = self.run_source(scope)
            self.assertEqual(observations, {"parses": 2, "sends": 1})
            packet = scope.read("calibration.json")
            self.assertIsNotNone(packet, "The supplemental calibration did not run")
            self.assertEqual(packet["outcome"], "completed")
            self.assertEqual(packet["facts"]["ref"]["nserror"], False)
            self.assertEqual(packet["facts"]["object"]["code"], {"type": "number", "integer": 3840})
            self.assertEqual(
                packet["facts"]["nullable"],
                {
                    "raw_type": "function",
                    "type": "object",
                    "native_absent": True,
                    "absent": True,
                },
            )
            self.assertIn("qualified=true", scope.calibration_evidence())
            # The calibrated native nullable projection qualifies controls only: the unknown
            # actual send status still cannot acknowledge transport or readiness.
            original = scope.scalar_evidence()
            self.assertTrue(original["scalar_qualified"])
            self.assertIn("absent_errn(type=object,absent=true)", original["scalar_facts"])
            self.assertIn(
                "absent_errn_bridge(raw_type=function,native_absent=true)",
                original["scalar_facts"],
            )
            self.assertIn("code(type=number,integer=unavailable)", original["decoder_facts"])
            with self.assertRaises(ValueError):
                scope.observe(
                    terminal=True,
                    native={
                        "error_origin": "send",
                        "status": -1712,
                        "error_domain": "NSOSStatusErrorDomain",
                    },
                )
            scope.cleanup()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_raw_holder_success_is_observed_without_fallback_or_changed_holder_choice(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            self.assertEqual(self.run_source(scope, "raw_valid"), {"parses": 2, "sends": 1})
            self.assertEqual(
                scope.read("calibration.json")["facts"]["ref"]["code"]["integer"], 3840
            )
            self.assertIn("qualified=true", scope.calibration_evidence())
            scope.cleanup()

    def test_wrong_native_class_status_domain_and_parse_result_cannot_qualify(self):
        for mode in (
            "wrong_class",
            "wrong_status",
            "boolean_status",
            "wrong_domain",
            "nonnil_result",
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                observed = self.run_source(scope, mode)
                self.assertEqual(observed, {"parses": 2, "sends": 1})
                evidence = scope.calibration_evidence()
                self.assertIn("qualified=false", evidence)
                self.assertNotIn("private-secret-marker", evidence)
                self.assertNotIn(folder, evidence)
                self.assertNotIn(NONCE, evidence)
                scope.cleanup()

    def test_nullable_projection_rejects_fake_callable_numeric_and_unacknowledged_native_nil(self):
        for mode in ("fake_function", "number", "false_nil", "truthy_nil"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                self.run_source(scope, mode)
                packet = scope.read("calibration.json")
                self.assertIsNotNone(packet, "No closed refusal was retained")
                self.assertEqual(packet["outcome"], "refused")
                self.assertEqual(packet["stages"][-1], "nullable_entered")
                self.assertNotIn("nullable", packet["facts"])
                self.assertIn("qualified=false", scope.calibration_evidence())
                scope.cleanup()

    def test_calibration_publication_refusal_cannot_suppress_original_send(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            self.assertEqual(self.run_source(scope, "write_refusal"), {"parses": 0, "sends": 1})
            self.assertEqual(scope.calibration_evidence(), "not_observed")
            self.assertIsNotNone(scope.read("scalar.json"))
            self.assertIsNotNone(scope.read("decoder.json"))
            scope.cleanup()

    def test_packet_owner_shape_prefix_and_projected_nil_acknowledgement_remain_strict(self):
        mutations = (
            lambda p: p.update(sender_pid=43),
            lambda p: p.update(nonce="b" * 32),
            lambda p: p.update(outcome="private-secret-marker"),
            lambda p: p["facts"].update(private="private-secret-marker"),
            lambda p: p["facts"]["object"]["code"].update(integer=True),
            lambda p: p["facts"]["nullable"].update(raw_type="private-secret-marker"),
            lambda p: p["stages"].append("future"),
        )
        for edit in mutations:
            with self.subTest(edit=edit), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                self.run_source(scope)
                path = scope.path / "calibration.json"
                packet = json.loads(path.read_text())
                edit(packet)
                path.write_text(json.dumps(packet) + "\n")
                with self.assertRaises(ValueError) as failure:
                    scope.calibration_evidence()
                self.assertNotIn("private-secret-marker", str(failure.exception))
                scope.cleanup()
        for field, value in (
            ("raw_type", "number"),
            ("type", "function"),
            ("native_absent", False),
            ("absent", False),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                self.run_source(scope)
                path = scope.path / "calibration.json"
                packet = json.loads(path.read_text())
                packet["facts"]["nullable"][field] = value
                path.write_text(json.dumps(packet) + "\n")
                self.assertIn("qualified=false", scope.calibration_evidence())
                scope.cleanup()

    def test_unbound_present_calibration_and_unexpected_integer_remain_private(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            self.run_source(scope)
            path = scope.path / "calibration.json"
            packet = json.loads(path.read_text())
            packet["facts"]["object"]["code"]["integer"] = 987654321
            path.write_text(json.dumps(packet) + "\n")
            evidence = scope.calibration_evidence()
            self.assertIn("unexpected_integer", evidence)
            self.assertNotIn("987654321", evidence)
            scope.sender_pid = None
            with self.assertRaisesRegex(ValueError, "actual bound sender"):
                scope.calibration_evidence()
            scope.cleanup()


class QualifiedNSErrorOwnerTests(unittest.TestCase):
    """Replay calibrated bridge representations through the exact original decoder."""

    scope = NSErrorOutSlotCalibrationTests.scope
    run_source = NSErrorOutSlotCalibrationTests.run_source

    def test_actual_object_holder_retains_native_send_refusal_without_server_acknowledgement(
        self,
    ):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            result = self.run_source(scope, "send_valid", capture=True)
            self.assertFalse(result["refused"])
            native = probe.validate_no_prompt_receipt(result["output"] + "\n", NONCE, 42)
            self.assertEqual(native["status"], -1712)
            self.assertEqual(native["outcome"], "refused")
            self.assertEqual(native["error_domain"], "NSOSStatusErrorDomain")
            observed = scope.observe(terminal=True, native=native)
            self.assertTrue(observed["scalar_qualified"])
            self.assertEqual(observed["decoder_boundary"], "domain_returned")
            self.assertEqual(observed["server"], "not_observed")
            self.assertEqual(
                scope.read("scalar.json")["facts"]["absent_errn"],
                {
                    "raw_type": "function",
                    "type": "object",
                    "native_absent": True,
                    "absent": True,
                },
            )
            self.assertIn("raw_type=function", observed["scalar_facts"])
            self.assertNotIn("denied", str(observed))
            scope.cleanup()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_real_handler_descriptor_and_nullable_reply_preserve_mandatory_server_proof(
        self,
    ):
        for mode, status in (("handler_valid", -50), ("handler_nil", 0)):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                result = self.run_source(scope, mode, capture=True)
                self.assertFalse(result["refused"])
                native = probe.validate_no_prompt_receipt(result["output"] + "\n", NONCE, 42)
                self.assertEqual(native["status"], status)
                self.assertEqual(
                    scope.read("decoder.json")["facts"]["errn"],
                    {
                        "raw_type": "function",
                        "type": "object" if status == 0 else "function",
                        "native_absent": status == 0,
                        "absent": status == 0,
                    },
                )
                self.assertTrue(
                    scope.scalar_evidence(terminal=True, native=native)["scalar_qualified"]
                )
                if status == 0:
                    with self.assertRaisesRegex(ValueError, "incomplete server witnesses"):
                        scope.observe(terminal=True, native=native, require_completion=True)
                else:
                    self.assertEqual(
                        scope.observe(terminal=True, native=native)["server"],
                        "not_observed",
                    )
                scope.cleanup()

    def test_missing_native_error_identity_integer_and_domain_refuse_actual_generated_owner(
        self,
    ):
        for mode in (
            "send_nil",
            "send_wrong_class",
            "send_boolean",
            "send_string",
            "send_missing_domain",
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                result = self.run_source(scope, mode, capture=True)
                self.assertEqual(result["sends"], 1)
                self.assertTrue(result["refused"])
                self.assertIsNone(result["output"])
                observed = scope.observe()
                self.assertEqual(observed["server"], "not_observed")
                self.assertNotIn("denied", str(observed))
                self.assertNotIn(NONCE, str(observed))
                scope.cleanup()
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_actual_non_osstatus_error_domain_is_retained_without_tcc_classification(
        self,
    ):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            result = self.run_source(scope, "send_other_domain", capture=True)
            self.assertFalse(result["refused"])
            native = probe.validate_no_prompt_receipt(result["output"] + "\n", NONCE, 42)
            self.assertEqual(native["error_domain"], "NSCocoaErrorDomain")
            self.assertEqual(native["outcome"], "refused")
            self.assertEqual(scope.observe(terminal=True, native=native)["server"], "not_observed")
            scope.cleanup()

    def test_forged_handler_callable_and_boolean_integer_cannot_acknowledge_native_status(
        self,
    ):
        for mode in ("handler_forged", "handler_forged_nil", "handler_boolean"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                result = self.run_source(scope, mode, capture=True)
                self.assertTrue(result["refused"])
                self.assertIsNone(result["output"])
                self.assertEqual(result["sends"], 1)
                self.assertEqual(scope.observe()["server"], "not_observed")
                scope.cleanup()

    def test_nullable_packet_raw_identity_and_projection_are_strict_and_private(self):
        for edit in (
            lambda f: f.update(raw_type="number"),
            lambda f: f.update(raw_type="private-secret-marker"),
            lambda f: f.update(raw_type={}),
            lambda f: f.update(native_absent=False),
            lambda f: f.update(native_absent=1),
            lambda f: f.update(type="function"),
            lambda f: f.pop("raw_type"),
            lambda f: f.update(private="private-secret-marker"),
        ):
            with self.subTest(edit=edit), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                result = self.run_source(scope, "send_valid", capture=True)
                self.assertFalse(result["refused"])
                packet = scope.read("scalar.json")
                edit(packet["facts"]["absent_errn"])
                (scope.path / "scalar.json").write_text(json.dumps(packet) + "\n")
                with self.assertRaises(ValueError) as failure:
                    scope.scalar_evidence()
                self.assertNotIn("private-secret-marker", str(failure.exception))
                scope.cleanup()

    def test_default_and_pid_native_sources_and_deadlines_remain_byte_exact(self):
        # These independent pinned source hashes predate the supplementary correction.
        import hashlib

        self.assertEqual(
            hashlib.sha256(probe.NativeDelayedTimerProbe.no_prompt_script().encode()).hexdigest(),
            "c6487804c8096deca481e5036a45898c655ee5a91f54725f7109e193bd745911",
        )
        self.assertEqual(
            hashlib.sha256(probe.NativeDelayedTimerProbe.pid_control_script().encode()).hexdigest(),
            "f6071d8c7bc0065b91f0260c0734c11bc1c8bacc25c71db38e351e741b2236d7",
        )
        self.assertEqual(
            hashlib.sha256(
                probe.NativeDelayedTimerProbe.pid_event_constructor().encode()
            ).hexdigest(),
            "9786b4c904ea4fdb2ed1c4f0496a76928af310dfc4c6ede0616f149aa0be9136",
        )
        self.assertEqual(probe.NO_PROMPT_NATIVE_TIMEOUT_SECONDS, 8)
        self.assertEqual(probe.SCRIPTING_TIMEOUT_SECONDS, 10)


class QualifiedNativeStringIntegerTests(unittest.TestCase):
    """Replay the actual Cocoa string bridge through the real generated sender."""

    scope = NSErrorOutSlotCalibrationTests.scope
    run_source = NSErrorOutSlotCalibrationTests.run_source

    def test_actual_calibrated_native_string_getters_retain_numeric_refusal(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            result = self.run_source(scope, "native_string", capture=True)
            self.assertEqual((result["parses"], result["sends"]), (2, 1))
            self.assertFalse(result["refused"])
            native = probe.validate_no_prompt_receipt(result["output"] + "\n", NONCE, 42)
            self.assertEqual(native["status"], -1712)
            self.assertEqual(native["error_origin"], "send")
            self.assertEqual(native["error_domain"], "NSOSStatusErrorDomain")
            self.assertEqual(native["outcome"], "refused")
            evidence = scope.observe(terminal=True, native=native)
            self.assertTrue(evidence["scalar_qualified"])
            self.assertEqual(evidence["server"], "not_observed")
            for name, fact in scope.read("getter.json")["facts"].items():
                self.assertEqual(fact["raw_type"], "string", name)
                self.assertEqual(fact["box_raw_type"], "string", name)
                for field in (
                    "owner_native",
                    "converted_integer",
                    "box_native",
                    "box_integer",
                    "box_matches",
                ):
                    self.assertIs(fact[field], True, (name, field))
                self.assertIs(fact["control_matches"], None if name == "send" else True)
            self.assertNotIn(NONCE, str(evidence))
            self.assertNotIn(folder, str(evidence))
            scope.cleanup()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_string_projection_refuses_unowned_box_mismatch_and_invalid_representations(self):
        modes = (
            "send_string",
            "native_string_box_forged",
            "native_string_box_wrong_class",
            "native_string_box_nil",
            "native_string_box_mismatch",
            "native_string_box_callable",
            "native_string_box_boolean",
            "native_string_box_fraction",
            "native_string_foreign_owner",
            "native_string_owner_changes",
            "native_string_fraction",
            "native_string_unsafe",
            "native_string_exponent",
            "native_string_hex",
            "native_string_space",
            "native_string_zero_prefix",
            "native_string_boolean",
        )
        for mode in modes:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = self.scope(folder)
                result = self.run_source(scope, mode, capture=True)
                self.assertEqual((result["parses"], result["sends"]), (2, 1))
                self.assertTrue(result["refused"])
                self.assertIsNone(result["output"])
                self.assertEqual(scope.observe()["server"], "not_observed")
                scope.cleanup()
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_string_error_domain_and_server_witness_admission_remain_independent(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            result = self.run_source(scope, "native_string_other_domain", capture=True)
            self.assertFalse(result["refused"])
            native = probe.validate_no_prompt_receipt(result["output"] + "\n", NONCE, 42)
            self.assertEqual(native["error_domain"], "NSCocoaErrorDomain")
            self.assertEqual(native["outcome"], "refused")
            self.assertEqual(scope.observe(terminal=True, native=native)["server"], "not_observed")
            scope.cleanup()

    def direct_projection(self, scope, mode):
        port = r"""
const native=new WeakSet();
const mode=__MODE__;
const NSError={},NSNumber={};
function wrapper(klass,value) {
    const owner=function(){throw Error('Do not call native wrappers');};
    native.add(owner); owner.isNil=()=>false; owner.isKindOfClass=expected=>expected===klass;
    owner.code=value;return owner;
}
const owner=wrapper(mode==='wrong_owner_class'?NSNumber:NSError,'-1712');
const ObjC={castObjectToRef:value=>{if(!native.has(value))throw Error('Foreign native identity');return {};}};
const $={NSError:NSError,NSNumber:NSNumber};
$.NSNumber.numberWithInteger=raw=>{
    const box=wrapper(mode==='wrong_box_class'?NSError:NSNumber,null);
    box.integerValue=mode==='box_mismatch'?'-1711':String(Number(raw));return box;
};
__SCRIPT__
let input=owner,raw='-1712';
if(mode==='foreign_string') input='-1712';
if(mode==='foreign_function') {input=function(){};input.code=raw;input.isNil=()=>false;input.isKindOfClass=()=>true;}
if(mode==='different_owned_code') raw='-50';
if(mode==='nonprimitive_owned_getter') {raw=function(){};raw.valueOf=()=>-1712;raw.toString=()=>'-1712';owner.code=raw;}
let refused=false,value=null;
try { value=projectOwnedNSErrorInteger(input,raw); } catch(error) {refused=true;}
process.stdout.write(JSON.stringify({refused:refused,value:value})+'\n');
"""
        port = port.replace("__MODE__", json.dumps(mode)).replace(
            "__SCRIPT__", scope.javascript_prelude()
        )
        result = subprocess.run(
            ["node", "-"], input=port, text=True, capture_output=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, "Independent projection source execution failed")
        return json.loads(result.stdout)

    def test_direct_owner_provenance_and_matching_box_cannot_be_bypassed(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = self.scope(folder)
            self.assertEqual(
                self.direct_projection(scope, "valid"), {"refused": False, "value": -1712}
            )
            for mode in (
                "foreign_string",
                "foreign_function",
                "wrong_owner_class",
                "wrong_box_class",
                "box_mismatch",
                "different_owned_code",
                "nonprimitive_owned_getter",
            ):
                self.assertEqual(
                    self.direct_projection(scope, mode), {"refused": True, "value": None}, mode
                )
            self.assertEqual(scope.observe()["server"], "not_observed")
            scope.cleanup()


class InflightNoPromptSampleTests(unittest.TestCase):
    """A deterministic process model proves ownership and phase association, not macOS."""

    def owner(self, folder):
        owner = probe.NativeDelayedTimerProbe(
            Path("/Applications/ErgoptiPlus.app"), Path(folder), DOMAIN
        )
        owner.nonce = NONCE
        return owner

    def sender(self, scope, stages, **overrides):
        packet = {
            "schema_version": 1,
            "contract": "hs.applescript.sender-stages",
            "nonce": NONCE,
            "target_pid": 42,
            "sender_pid": SENDER_PID,
            "stages": stages,
        }
        packet.update(overrides)
        temporary = scope.path / "sender.json.pending"
        temporary.write_text(json.dumps(packet) + "\n")
        os.replace(temporary, scope.path / "sender.json")

    def sampler(self, action=None):
        process = mock.Mock(returncode=None)
        observations = []

        def wait(**options):
            observations.append(("wait", options["timeout"]))
            if action:
                action()
            if process.returncode is None:
                process.returncode = 0
            return process.returncode

        def kill():
            observations.append(("kill", None))
            process.returncode = -9

        process.wait.side_effect = wait
        process.kill.side_effect = kill
        return process, observations

    def test_exact_send_interval_and_native_header_associate_observation_without_admission(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            ended = threading.Event()
            seen = []
            native = no_prompt_receipt(-1712, None, "send")
            child = mock.Mock(pid=SENDER_PID, returncode=0)
            sample_process, sample_calls = self.sampler()
            original_worker = getattr(probe, "NoPromptServerSample", object)

            class ObservedWorker(original_worker):
                def _run(self):
                    try:
                        super()._run()
                    finally:
                        ended.set()

            def communicate(**options):
                seen.append(("sender_timeout", options["timeout"]))
                self.sender(owner.no_prompt_scope, ["constructed", "send_entered"])
                seen.append(("sampler_completed_before_reply", ended.wait(timeout=2)))
                publish_supplemental_fixture(owner, SENDER_PID, -1712, "none")
                return json.dumps(native) + "\n", ""

            child.communicate.side_effect = communicate

            def spawn(arguments, **options):
                if arguments[0] == "/usr/bin/osascript":
                    return child
                seen.append(("sample_arguments", arguments))
                seen.append(("sample_streams", options))
                Path(arguments[-1]).write_text(
                    f"Process: Hammerspoon [42]\nPath: {EXECUTABLE}\nCall graph:\n"
                    "1 Thread_1 DispatchQueue_1: com.apple.main-thread\n"
                    " + 1 NSApplicationMain (in AppKit)\n"
                    " +   1 HSAppleScriptRunString (in Hammerspoon)\n"
                    "Binary Images:\nTCC PRIVATE_IMAGE_ONLY\n"
                )
                return sample_process

            with (
                mock.patch.object(probe, "NoPromptServerSample", ObservedWorker, create=True),
                mock.patch.object(probe.subprocess, "Popen", side_effect=spawn),
            ):
                result = owner.control_pid_no_prompt(42, lambda _: [42])
            self.assertIn(("sender_timeout", 10), seen)
            self.assertIn(("sampler_completed_before_reply", True), seen)
            self.assertEqual(result["status"], -1712)
            self.assertEqual(result["outcome"], "refused")
            expected_sample = [
                "/usr/bin/sample",
                "42",
                "1",
                "-file",
                str(Path(folder) / "sample-hammerspoon-no-prompt-1.txt"),
            ]
            self.assertIn(("sample_arguments", expected_sample), seen)
            self.assertIn(
                (
                    "sample_streams",
                    {
                        "stdin": subprocess.DEVNULL,
                        "stdout": subprocess.DEVNULL,
                        "stderr": subprocess.DEVNULL,
                    },
                ),
                seen,
            )
            self.assertEqual(sample_calls, [("wait", 0.02)])
            text = str(owner.diagnostic_receipts)
            self.assertIn("phase=pid_no_prompt command=1", text)
            self.assertIn("send_interval=observed worker=retired sample_owner=qualified", text)
            self.assertIn("HSAppleScriptRunString", text)
            self.assertIn("status -1712, origin send", text)
            self.assertNotIn("PRIVATE_IMAGE_ONLY", text)
            self.assertNotIn(NONCE, text)
            self.assertNotIn(str(EXECUTABLE), text)
            self.assertEqual(owner.server_sample_workers, [])
            self.assertEqual(owner.scripting_commands, [])
            self.assertIsNone(owner.no_prompt_scope)
            self.assertFalse(
                ended.is_set()
                and any(t.name == "owned-no-prompt-sample" for t in threading.enumerate())
            )

    def test_late_or_foreign_stage_cannot_spawn_or_claim_an_inflight_sample(self):
        for stages, overrides in (
            (["constructed", "send_entered", "send_returned"], {}),
            (["constructed", "send_entered"], {"sender_pid": SENDER_PID + 1}),
            (["constructed", "send_entered"], {"target_pid": 43}),
            (["constructed", "send_entered"], {"nonce": "b" * 32}),
            (["send_entered"], {}),
        ):
            with (
                self.subTest(stages=stages, overrides=overrides),
                tempfile.TemporaryDirectory() as folder,
            ):
                scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
                scope.bind_sender(SENDER_PID)
                self.sender(scope, stages, **overrides)
                worker = probe.NoPromptServerSample(scope, 42, Path(folder) / "owned.txt")
                with mock.patch.object(probe.subprocess, "Popen") as spawn:
                    worker._run()
                    observed = worker.finish()
                self.assertFalse(observed)
                spawn.assert_not_called()
                self.assertFalse(worker.interval_qualified)
                scope.cleanup()

    def test_interval_change_nonzero_or_untyped_exit_refuses_sample_after_exact_retirement(self):
        for mode in ("returned", "exit_nonzero", "exit_bool", "cancelled"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
                scope.bind_sender(SENDER_PID)
                self.sender(scope, ["constructed", "send_entered"])
                worker = probe.NoPromptServerSample(scope, 42, Path(folder) / "owned.txt")

                def action():
                    if mode == "returned":
                        self.sender(scope, ["constructed", "send_entered", "send_returned"])
                    elif mode == "exit_nonzero":
                        process.returncode = 2
                    elif mode == "exit_bool":
                        process.returncode = False
                    else:
                        worker.stop.set()

                process, observations = self.sampler(action)
                with mock.patch.object(probe.subprocess, "Popen", return_value=process):
                    worker._run()
                    result = worker.finish()
                self.assertFalse(result)
                self.assertIsNotNone(process.returncode)
                self.assertTrue(observations)
                scope.cleanup()

    def test_exact_worker_retirement_failure_retains_debt_and_blocks_restoration(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            scope.bind_sender(SENDER_PID)
            owner.no_prompt_scope = scope
            self.sender(scope, ["constructed", "send_entered"])
            worker = probe.NoPromptServerSample(scope, 42, Path(folder) / "owned.txt")
            worker.started = True
            worker.thread = mock.Mock()
            worker.thread.is_alive.return_value = True
            owner.server_sample_workers.append(worker)
            with mock.patch.object(owner.preference, "restore") as restore:
                with self.assertRaisesRegex(RuntimeError, "worker has not retired"):
                    owner.restore()
                restore.assert_not_called()
            self.assertEqual(owner.server_sample_workers, [worker])
            self.assertIs(owner.no_prompt_scope, scope)
            with self.assertRaisesRegex(RuntimeError, "prior native scripting"):
                owner.execute("return 'foreign-successor'")
            worker.thread.is_alive.return_value = False
            with mock.patch.object(owner.preference, "restore") as restore:
                owner.restore()
                restore.assert_called_once_with()
            worker.thread.join.assert_called_with(timeout=2)
            self.assertEqual(owner.server_sample_workers, [])
            self.assertIsNone(owner.no_prompt_scope)

    def test_owned_sampler_pending_exit_is_retried_without_touching_unrelated_process(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            scope.bind_sender(SENDER_PID)
            worker = probe.NoPromptServerSample(scope, 42, Path(folder) / "owned.txt")
            process = mock.Mock(returncode=None)
            worker.process = process
            foreign = mock.Mock()
            process.wait.side_effect = [subprocess.TimeoutExpired(["sample"], 2), -9]
            with self.assertRaises(subprocess.TimeoutExpired):
                worker.finish()
            self.assertIsNone(process.returncode)
            process.wait.side_effect = lambda **_: setattr(process, "returncode", -9)
            self.assertFalse(worker.finish())
            self.assertEqual(process.kill.call_count, 2)
            foreign.kill.assert_not_called()
            scope.cleanup()

    def test_native_sample_header_and_current_server_still_refuse_foreign_frames(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            sample = Path(folder) / "owned.txt"
            for header, current in (
                (f"Process: Hammerspoon [43]\nPath: {EXECUTABLE}", [42]),
                ("Process: Hammerspoon [42]\nPath: /foreign/Hammerspoon", [42]),
                (f"Process: Hammerspoon [42]\nPath: {EXECUTABLE}", [43]),
            ):
                sample.write_text(header + "\nCall graph:\nHSAppleScript PRIVATE_FOREIGN_FRAME\n")
                text = str(owner.read_native_runtime_sample(sample, 42, lambda _: current))
                self.assertIn("unqualified", text)
                self.assertNotIn("PRIVATE_FOREIGN_FRAME", text)
            sample.unlink()
            foreign = Path(folder) / "foreign.txt"
            foreign.write_text("PRIVATE_FOREIGN_FRAME")
            sample.symlink_to(foreign)
            text = str(owner.read_native_runtime_sample(sample, 42, lambda _: [42]))
            self.assertIn("unqualified", text)
            self.assertNotIn("PRIVATE_FOREIGN_FRAME", text)

    def test_completed_sampler_read_refusal_keeps_primary_sender_timeout(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            owner.bind_runtime(42, lambda _: [42])
            owner.no_prompt_scope = probe.NoPromptDiagnosticScope(
                Path(folder), NONCE, 42, EXECUTABLE, DOMAIN
            )
            primary = subprocess.TimeoutExpired(["osascript"], 10)
            child = mock.Mock(pid=SENDER_PID, returncode=None)
            child.poll.return_value = None
            child.communicate.side_effect = [primary, ("", "")]
            child.kill.side_effect = lambda: setattr(child, "returncode", -9)
            worker = mock.Mock()
            worker.finish.return_value = True
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=child),
                mock.patch.object(probe, "NoPromptServerSample", return_value=worker),
                mock.patch.object(owner, "sample_scripting_command", return_value=[]),
                mock.patch.object(owner, "sample_native_runtime", return_value=[]),
                mock.patch.object(
                    owner,
                    "read_native_runtime_sample",
                    side_effect=OSError("PRIVATE_READER_MARKER"),
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "TimeoutExpired") as failure:
                    owner.execute("return 'owned-source'", phase="pid_no_prompt", _target_pid=42)
            self.assertIs(failure.exception.__cause__, primary)
            self.assertNotIn("PRIVATE_READER_MARKER", str(failure.exception))
            self.assertIn("sample_owner=unqualified", str(owner.no_prompt_sample_diagnostics))
            self.assertIn("sample admission refused", str(owner.no_prompt_sample_diagnostics))
            self.assertNotIn("PRIVATE_READER_MARKER", str(owner.no_prompt_sample_diagnostics))
            self.assertEqual(owner.server_sample_workers, [])
            self.assertEqual(owner.scripting_commands, [])
            self.assertEqual(
                child.communicate.call_args_list, [mock.call(timeout=10), mock.call(timeout=2)]
            )
            child.kill.assert_called_once_with()
            with mock.patch.object(owner.preference, "restore"):
                owner.restore()
            self.assertIsNone(owner.no_prompt_scope)

    def test_sample_read_refusal_never_invents_context_or_replaces_mandatory_reply(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            native = no_prompt_receipt()
            child = supplemental_mock_child(owner, native)
            worker = mock.Mock()
            worker.finish.return_value = True
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=child),
                mock.patch.object(probe, "NoPromptServerSample", return_value=worker),
                mock.patch.object(
                    owner,
                    "read_native_runtime_sample",
                    side_effect=OSError("PRIVATE_READER_MARKER"),
                ),
            ):
                result = owner.control_pid_no_prompt(42, lambda _: [42])
            self.assertEqual(result["status"], 0)
            self.assertEqual(result["result"], NONCE)
            text = str(owner.diagnostic_receipts)
            self.assertIn("sample_owner=unqualified", text)
            self.assertIn("sample admission refused", text)
            self.assertIn("server witness: completed", text)
            self.assertNotIn("sample retained:", text)
            self.assertNotIn("PRIVATE_READER_MARKER", text)
            self.assertEqual(owner.server_sample_workers, [])
            self.assertEqual(owner.scripting_commands, [])
            self.assertIsNone(owner.no_prompt_scope)

    def test_sampler_only_cleanup_timeout_never_impersonates_sender_deadline(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = self.owner(folder)
            native = no_prompt_receipt()
            child = supplemental_mock_child(owner, native)
            child.poll.return_value = 0
            worker = mock.Mock()
            worker.finish.side_effect = subprocess.TimeoutExpired(["sample"], 2)
            with (
                mock.patch.object(probe.subprocess, "Popen", return_value=child),
                mock.patch.object(probe, "NoPromptServerSample", return_value=worker),
            ):
                with self.assertRaisesRegex(
                    RuntimeError, "sampler cleanup has not settled"
                ) as failure:
                    owner.control_pid_no_prompt(42, lambda _: [42])
            detail = owner.pid_control_error_diagnostic(failure.exception)
            self.assertIn("sampler cleanup has not settled", detail)
            self.assertNotIn("PID scripting command exceeded", detail)
            self.assertIsNone(failure.exception.__cause__)
            self.assertEqual(owner.server_sample_workers, [worker])
            self.assertEqual(owner.scripting_commands, [child])
            self.assertIsNotNone(owner.no_prompt_scope)
            worker.finish.side_effect = None
            worker.finish.return_value = False
            with mock.patch.object(owner.preference, "restore"):
                owner.restore()
            self.assertEqual(owner.server_sample_workers, [])
            self.assertEqual(owner.scripting_commands, [])
            self.assertIsNone(owner.no_prompt_scope)

    def test_sampler_worker_never_inherits_a_detached_callers_daemon_flag(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            scope.bind_sender(SENDER_PID)
            workers = []

            def construct():
                workers.append(probe.NoPromptServerSample(scope, 42, Path(folder) / "owned.txt"))

            caller = threading.Thread(target=construct, daemon=True)
            caller.start()
            caller.join(timeout=2)
            self.assertFalse(caller.is_alive())
            self.assertEqual(len(workers), 1)
            self.assertFalse(workers[0].thread.daemon)
            self.assertFalse(workers[0].finish())
            scope.cleanup()

    def test_owned_real_python_child_retires_while_unrelated_child_remains_alive(self):
        """Physical process retirement is measured on Linux, not native macOS sampling."""
        with tempfile.TemporaryDirectory() as folder:
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            scope.bind_sender(SENDER_PID)
            self.sender(scope, ["constructed", "send_entered"])
            worker = probe.NoPromptServerSample(scope, 42, Path(folder) / "owned.txt")
            native_popen = subprocess.Popen
            created = threading.Event()
            children = []
            foreign = native_popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            def spawn(arguments, **options):
                child = native_popen(
                    [sys.executable, "-c", "import time; time.sleep(30)"], **options
                )
                children.append((child, arguments))
                created.set()
                return child

            try:
                with mock.patch.object(probe.subprocess, "Popen", side_effect=spawn):
                    worker.start()
                    ready = created.wait(timeout=2)
                    result = worker.finish()
                self.assertTrue(ready, "The owned physical child was not created")
                self.assertFalse(result)
                self.assertEqual(len(children), 1)
                child, arguments = children[0]
                self.assertEqual(arguments[:4], ["/usr/bin/sample", "42", "1", "-file"])
                self.assertEqual(child.returncode, -9)
                self.assertEqual(child.poll(), -9)
                self.assertFalse(worker.thread.is_alive())
                self.assertIsNone(foreign.poll(), "Sampler cleanup stole another process")
            finally:
                worker.stop.set()
                worker.thread.join(timeout=2)
                for child in [foreign] + [item[0] for item in children]:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=2)
                scope.cleanup()

    def test_cancelled_sampler_is_killed_and_waited_with_original_cleanup_budget(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = probe.NoPromptDiagnosticScope(Path(folder), NONCE, 42, EXECUTABLE, DOMAIN)
            scope.bind_sender(SENDER_PID)
            self.sender(scope, ["constructed", "send_entered"])
            worker = probe.NoPromptServerSample(scope, 42, Path(folder) / "owned.txt")
            process = mock.Mock(returncode=None)
            seen = []

            def wait(**options):
                seen.append(options["timeout"])
                if options["timeout"] == 0.02:
                    worker.stop.set()
                    raise subprocess.TimeoutExpired(["sample"], options["timeout"])
                process.returncode = -9
                return -9

            process.wait.side_effect = wait
            with mock.patch.object(probe.subprocess, "Popen", return_value=process):
                worker._run()
                result = worker.finish()
            self.assertFalse(result)
            process.kill.assert_called_once_with()
            self.assertEqual(seen, [0.02, 2])
            scope.cleanup()


class EarlyReceivedLuaStageTests(unittest.TestCase):
    """Exercise the generated payload and actual physical journal writer."""

    @staticmethod
    def selected_interpreter(machine):
        """Use explicit CI keg paths; configured refusal never falls back to PATH."""
        variable = {"lua5.4": "ERGOPTI_DIAGNOSTIC_LUA54", "luajit": "ERGOPTI_DIAGNOSTIC_LUAJIT"}[
            machine
        ]
        if variable not in os.environ:
            return machine
        selected = Path(os.environ[variable])
        if not selected.is_absolute() or not selected.is_file() or not os.access(selected, os.X_OK):
            raise ValueError("Configured physical journal interpreter refused")
        return str(selected)

    def run_lua(self, mode="ok", later="body", pid="42", module="actual", machine="lua5.4"):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            owner = probe.NativeDelayedTimerProbe(root / "app", root, DOMAIN)
            owner.nonce = NONCE
            owner.runtime_owner = (42, lambda executable: [])
            scope = probe.NoPromptDiagnosticScope(root, NONCE, 42, EXECUTABLE, DOMAIN)
            prefix, suffix = scope.lua_parts()
            body = "return " + json.dumps(NONCE)
            if later == "body":
                body = "error('controlled later body refusal')"
            code = prefix + body + suffix
            journal = root / "journal.log"
            journal_source = (
                Path(__file__).parents[2] / "static/ergopti_plus/macos/adapters/boot_journal.lua"
            )
            version = (
                "assert(_VERSION=='Lua 5.4','Physical journal Lua version differs')\n"
                if machine == "lua5.4"
                else "assert(_VERSION=='Lua 5.1' and type(jit)=='table' and jit.version_num>=20100 and jit.version_num<20200,'Physical journal LuaJIT version differs')\n"
            )
            script = (
                version
                + r"""
local journal_path=__JOURNAL__
package.preload['infra.logger']=function() return {FALLBACK_BOOT_LOG_FILE=journal_path} end
local actual=dofile(__MODULE__)
local calls={write=0,flush=0,close=0,append=0}
local mode=__MODE__
local function opener(path,flag)
    local native,err=io.open(path,flag)
    if not native then return nil,err end
    return {
        write=function(_,text)
            calls.write=calls.write+1
            local wrote=native:write(text)
            if mode=='write_false' then return false end
            if mode=='write_throw' then error('controlled write refusal') end
            return wrote
        end,
        flush=function()
            calls.flush=calls.flush+1
            local flushed=native:flush()
            if mode=='flush_false' then return false end
            if mode=='flush_throw' then error('controlled flush refusal') end
            return flushed
        end,
        close=function()
            calls.close=calls.close+1
            local closed=native:close()
            if mode=='close_false' then return false end
            if mode=='close_throw' then error('controlled close refusal') end
            return closed
        end,
    }
end
actual.configure_for_tests({open=opener})
local appended=actual.append
actual.append=function(...)
    calls.append=calls.append+1
    local ack=appended(...)
    if mode=='ack_false' then return false end
    if mode=='ack_nil' then return nil end
    if mode=='ack_throw' then error('controlled append refusal') end
    return ack
end
package.loaded['adapters.boot_journal']=actual
__MODULE_SHAPE__
hs={processInfo={processID=__PID__,executablePath=__EXECUTABLE__,bundleID=__DOMAIN__},
    json={encode=function() __ENCODE__ return '{}' end}}
local fn,err=load(__CODE__)
assert(fn,err)
local completed,result=pcall(fn)
-- These observations run after the protected production payload has returned.
print(tostring(completed))
print(calls.append..','..calls.write..','..calls.flush..','..calls.close)
print(completed and tostring(result) or 'closed later refusal')
"""
            )
            replacement = {
                "__JOURNAL__": json.dumps(str(journal)),
                "__MODULE__": json.dumps(str(journal_source)),
                "__MODE__": json.dumps(mode),
                "__MODULE_SHAPE__": {
                    "actual": "",
                    "missing": "package.loaded['adapters.boot_journal']=nil",
                    "malformed": "package.loaded['adapters.boot_journal']={append=true}",
                }[module],
                "__PID__": pid,
                "__EXECUTABLE__": json.dumps("foreign" if later == "identity" else str(EXECUTABLE)),
                "__DOMAIN__": json.dumps(DOMAIN),
                "__ENCODE__": "error('controlled later JSON refusal')" if later == "json" else "",
                "__CODE__": "[====[" + code + "]====]",
            }
            for token, value in replacement.items():
                script = script.replace(token, value)
            native = subprocess.run(
                [self.selected_interpreter(machine), "-"],
                input=script,
                text=True,
                capture_output=True,
                timeout=5,
            )
            self.assertEqual(native.returncode, 0, native.stderr)
            lines = native.stdout.splitlines()
            self.assertEqual(len(lines), 3)
            text = journal.read_text() if journal.exists() else ""
            stage = owner.observe_early_lua_stage(text)
            scope.cleanup()
            return stage, text, lines

    def test_actual_generated_stage_precedes_later_identity_json_and_body_refusal(self):
        for later in ("identity", "json", "body"):
            with self.subTest(later=later):
                stage, text, seen = self.run_lua(later=later)
                self.assertEqual(seen[0], "false")
                self.assertEqual(stage["body_stage"], "observed")
                self.assertIn("pid=42; nonce=" + NONCE + ".\n", text)
                self.assertFalse(stage["qualified"])
                self.assertEqual(stage["publication_ack"], "unobserved")
                self.assertEqual(stage["timing"], "unknown")

    def test_actual_generated_stage_preserves_successful_original_nonce_and_receipts(
        self,
    ):
        for machine in ("lua5.4", "luajit"):
            with self.subTest(machine=machine):
                stage, text, seen = self.run_lua(later="success", machine=machine)
                self.assertEqual(seen[0], "true")
                self.assertEqual(seen[2], NONCE)
                self.assertEqual(stage["body_stage"], "observed")
                self.assertFalse(stage["qualified"])

    def test_exact_false_nil_and_throw_append_acknowledgements_never_qualify(self):
        for mode in ("ack_false", "ack_nil", "ack_throw"):
            with self.subTest(mode=mode):
                stage, text, seen = self.run_lua(mode=mode, later="success")
                self.assertEqual(seen[0], "true")
                self.assertEqual(seen[2], NONCE)
                self.assertTrue(text.endswith("\n"))
                self.assertEqual(stage["publication_ack"], "unobserved")
                self.assertFalse(stage["qualified"])

    def test_real_write_flush_close_refusal_may_leave_bytes_but_never_success_ack(self):
        for mode in (
            "write_false",
            "write_throw",
            "flush_false",
            "flush_throw",
            "close_false",
            "close_throw",
        ):
            with self.subTest(mode=mode):
                stage, text, seen = self.run_lua(mode=mode, later="success")
                self.assertEqual(seen[0], "true")
                self.assertEqual(seen[2], NONCE)
                self.assertTrue(text.endswith("\n"))
                self.assertEqual(seen[1].split(",")[0], "1")
                self.assertEqual(
                    seen[1].split(",")[-1],
                    "1",
                    "physical file must close even after refusal",
                )
                self.assertFalse(stage["qualified"])
                self.assertEqual(stage["publication_ack"], "unobserved")

    def test_missing_malformed_or_foreign_actual_pid_never_publishes_expected_pid(self):
        for pid in ("nil", "true", "'42'", "43", "0", "0/0", "math.huge", "42.5"):
            with self.subTest(pid=pid):
                stage, text, seen = self.run_lua(pid=pid)
                self.assertEqual(seen[0], "false")
                self.assertEqual(seen[1], "0,0,0,0")
                self.assertEqual(text, "")
                self.assertEqual(stage["body_stage"], "unobserved")

    def test_missing_or_malformed_loaded_module_preserves_original_payload(self):
        for module in ("missing", "malformed"):
            with self.subTest(module=module):
                stage, text, seen = self.run_lua(module=module, later="success")
                self.assertEqual(seen[0], "true")
                self.assertEqual(seen[2], NONCE)
                self.assertEqual(seen[1], "0,0,0,0")
                self.assertEqual(stage["body_stage"], "unobserved")

    def test_closed_observer_refuses_stale_foreign_incomplete_and_ambiguous_lines(self):
        with tempfile.TemporaryDirectory() as folder:
            owner = probe.NativeDelayedTimerProbe(Path(folder) / "app", Path(folder), DOMAIN)
            owner.nonce = NONCE
            owner.runtime_owner = (42, lambda executable: [])
            valid = (
                "2026-10-04 00:00:00 [INFO] [init] Native scripting Lua body stage: "
                "phase=received_lua_body; pid=42; nonce=" + NONCE + ".\n"
            )
            self.assertEqual(owner.observe_early_lua_stage(valid)["body_stage"], "observed")
            for changed in (
                None,
                valid.replace(NONCE, "b" * 32),
                valid.replace("pid=42", "pid=43"),
                valid.replace("phase=received_lua_body", "phase=completed"),
                valid[:-1],
                valid.replace("\n", "\r\n"),
                valid + valid,
                "x" * (probe.SCRIPT_SAMPLE_READ_LIMIT + 1),
            ):
                with self.subTest(kind=type(changed).__name__):
                    stage = owner.observe_early_lua_stage(changed)
                    self.assertEqual(stage["body_stage"], "unobserved")
                    self.assertFalse(stage["qualified"])
            owner.scripting_commands.append(object())
            self.assertEqual(owner.observe_early_lua_stage(valid)["body_stage"], "unobserved")
            owner.scripting_commands.clear()
            owner.runtime_owner = (True, lambda executable: [])
            self.assertEqual(owner.observe_early_lua_stage(valid)["body_stage"], "unobserved")


class EarlyLuaInterpreterPrerequisiteTests(unittest.TestCase):
    """The actual package step selects both real interpreters without PATH guesses."""

    def test_explicit_keg_paths_run_both_physical_journals_and_invalid_paths_refuse(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            environment = {}
            for machine, variable in (
                ("lua5.4", "ERGOPTI_DIAGNOSTIC_LUA54"),
                ("luajit", "ERGOPTI_DIAGNOSTIC_LUAJIT"),
            ):
                target = shutil.which(EarlyReceivedLuaStageTests.selected_interpreter(machine))
                self.assertIsNotNone(target, "Both physical calibration interpreters are mandatory")
                selected = root / (machine + " selected keg")
                selected.symlink_to(target)
                environment[variable] = str(selected)
            with mock.patch.dict(os.environ, environment):
                subject = EarlyReceivedLuaStageTests()
                for machine in ("lua5.4", "luajit"):
                    stage, text, seen = subject.run_lua(later="success", machine=machine)
                    self.assertEqual(seen[0], "true")
                    self.assertEqual(seen[2], NONCE)
                    self.assertEqual(stage["body_stage"], "observed")
                    self.assertFalse(stage["qualified"])
            for invalid in ("", "relative/path", str(root / "missing")):
                with mock.patch.dict(os.environ, {"ERGOPTI_DIAGNOSTIC_LUA54": invalid}):
                    with self.assertRaisesRegex(ValueError, "interpreter refused"):
                        EarlyReceivedLuaStageTests.selected_interpreter("lua5.4")
            with mock.patch.dict(
                os.environ,
                {
                    "ERGOPTI_DIAGNOSTIC_LUA54": shutil.which(
                        EarlyReceivedLuaStageTests.selected_interpreter("luajit")
                    )
                },
            ):
                with self.assertRaises(AssertionError):
                    EarlyReceivedLuaStageTests().run_lua(later="success", machine="lua5.4")

    def test_actual_package_step_provisions_then_passes_exact_resolved_keg_paths(self):
        workflow = Path(__file__).parents[2] / ".github/workflows/ci-macos.yml"
        source = workflow.read_text()
        step = "      - name: Self-test the launch verdict\n"
        self.assertEqual(source.count(step), 1)
        block = source.split(step)[1].split("\n      - name:")[0]
        self.assertIn("HOMEBREW_NO_AUTO_UPDATE: '1'", block)
        self.assertEqual(block.count("        run: |\n"), 1)
        script = textwrap.dedent(block.split("        run: |\n")[1]).rstrip() + "\n"
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            ports, lua_keg, jit_keg = root / "ports", root / "Lua 5.4 keg", root / "LuaJIT keg"
            ports.mkdir()
            for keg, name in ((lua_keg, "lua"), (jit_keg, "luajit")):
                (keg / "bin").mkdir(parents=True)
                native = shutil.which(
                    EarlyReceivedLuaStageTests.selected_interpreter(
                        "lua5.4" if name == "lua" else "luajit"
                    )
                )
                self.assertIsNotNone(native)
                (keg / "bin" / name).symlink_to(native)
            receipt = root / "commands.jsonl"
            brew = ports / "brew"
            brew.write_text(
                "#!" + sys.executable + "\n"
                "import json,sys\n"
                "from pathlib import Path\n"
                "args=sys.argv[1:]\n"
                "with Path("
                + repr(str(receipt))
                + ").open('a') as log: log.write(json.dumps(args)+'\\n')\n"
                "if args==['install','lua@5.4','luajit']: pass\n"
                "elif args==['--prefix','lua@5.4']: print(" + repr(str(lua_keg)) + ")\n"
                "elif args==['--prefix','luajit']: print(" + repr(str(jit_keg)) + ")\n"
                "else: sys.exit(9)\n"
            )
            python = ports / "python3"
            selected_receipt = root / "selected.json"
            python.write_text(
                "#!" + sys.executable + "\n"
                "import json,os,sys,subprocess\n"
                "from pathlib import Path\n"
                "assert sys.argv[1:]==['tools/diagnostics/macos_launch_gate_test.py']\n"
                "names=['ERGOPTI_DIAGNOSTIC_LUA54','ERGOPTI_DIAGNOSTIC_LUAJIT']\n"
                "selected=[os.environ[name] for name in names]\n"
                "versions=[\"assert(_VERSION=='Lua 5.4')\",\"assert(_VERSION=='Lua 5.1' and jit.version_num>=20100 and jit.version_num<20200)\"]\n"
                "for native,check in zip(selected,versions): subprocess.run([native,'-e',check],check=True)\n"
                "Path(" + repr(str(selected_receipt)) + ").write_text(json.dumps(selected))\n"
            )
            for port in (brew, python):
                port.chmod(0o700)
            environment = dict(os.environ)
            for name in ("ERGOPTI_DIAGNOSTIC_LUA54", "ERGOPTI_DIAGNOSTIC_LUAJIT"):
                environment.pop(name, None)
            environment["PATH"] = str(ports) + os.pathsep + environment["PATH"]
            result = subprocess.run(
                ["/bin/bash", "-c", script],
                text=True,
                capture_output=True,
                env=environment,
                timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            # Assertions are outside all recorded child ports and production protection.
            self.assertEqual(
                [json.loads(line) for line in receipt.read_text().splitlines()],
                [["install", "lua@5.4", "luajit"], ["--prefix", "lua@5.4"], ["--prefix", "luajit"]],
            )
            self.assertEqual(
                json.loads(selected_receipt.read_text()),
                [str(lua_keg / "bin/lua"), str(jit_keg / "bin/luajit")],
            )


class ManagedLaunchObservationTests(unittest.TestCase):
    """Independent executors cannot let launch-state information admit transport."""

    def owner(self):
        return probe.ManagedLaunchObservation(42, EXECUTABLE, DOMAIN, NONCE, lambda _: [42])

    def packet(self, sender=123):
        return {
            "schema_version": 1,
            "contract": probe.ManagedLaunchObservation.CONTRACT,
            "nonce": NONCE,
            "pid": 42,
            "sender_pid": sender,
            "executable": str(EXECUTABLE),
            "bundle_id": DOMAIN,
            "native_class": True,
            "terminated": False,
            "raw_type": "boolean",
            "finished_launching": True,
        }

    def test_real_held_observer_cannot_delay_original_first_control(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "release"
            original_popen = subprocess.Popen
            seen = []
            script = "import os,json,sys,time; p=json.loads(sys.argv[2]); p['sender_pid']=os.getpid();\nwhile not os.path.exists(sys.argv[1]): time.sleep(.005)\nprint(json.dumps(p))"

            def spawn(arguments, **options):
                seen.append(arguments)
                child = original_popen(
                    [sys.executable, "-c", script, str(release), json.dumps(self.packet())],
                    **options,
                )
                # The list is populated later by actual communicate calls.
                child._observed_budgets = observe_child_budgets(child)
                return child

            owner = probe.NativeDelayedTimerProbe(
                Path("/Applications/ErgoptiPlus.app"), Path(directory), DOMAIN
            )
            owner.nonce = NONCE
            with mock.patch.object(probe.subprocess, "Popen", side_effect=spawn):
                observation = owner.start_managed_launch_observation(42, lambda _: [42])
                control_seen = []

                def execute(source, **options):
                    control_seen.append((source, observation.thread.is_alive(), release.exists()))
                    return NONCE

                with mock.patch.object(owner, "execute", side_effect=execute):
                    result = owner.control(42, lambda _: [42])
                self.assertEqual(len(control_seen), 1)
                self.assertEqual(control_seen[0], ('return "' + NONCE + '"', True, False))
                self.assertTrue(result["acknowledged"])
                release.write_text("now the independent observer may reply")
                summary = observation.finish()
            self.assertEqual(len(seen), 1)
            self.assertNotIn("sendEvent", seen[0][4])
            self.assertNotIn("NSAppleEvent", seen[0][4])
            self.assertEqual(observation.process._observed_budgets, [10])
            self.assertEqual(observation.process.returncode, 0)
            self.assertIn(summary["timing"], ("overlaps_path", "after_path"))
            self.assertFalse(summary["qualified"])
            self.assertEqual(summary["readiness"], "unobserved")

    def test_parent_brackets_classify_only_completed_before_actual_entry(self):
        for begin, end, expected in [
            (1, 2, "before_path"),
            (2, 5, "overlaps_path"),
            (3.1, 3.2, "overlaps_path"),
            (4, 5, "after_path"),
        ]:
            with self.subTest(expected=expected, begin=begin):
                owner = self.owner()
                owner.packet = self.packet()
                owner.query_begin, owner.query_end = begin, end
                owner.control_begin, owner.control_end = 3, 4
                result = owner.finish()
                self.assertEqual(result["timing"], expected)
                self.assertFalse(result["qualified"])
        owner.control_end = None
        self.assertEqual(owner.finish()["timing"], "unknown")

    def test_packet_requires_native_identity_nonce_actual_sender_and_boolean(self):
        owner = self.owner()
        owner.process = mock.Mock(pid=123)
        self.assertTrue(owner.valid_packet(self.packet()))
        for field, value in [
            ("native_class", False),
            ("terminated", True),
            ("pid", True),
            ("pid", 43),
            ("sender_pid", 124),
            ("nonce", "b" * 32),
            ("executable", "/foreign"),
            ("bundle_id", "foreign"),
            ("raw_type", "number"),
            ("finished_launching", 1),
            ("finished_launching", "true"),
            ("schema_version", True),
        ]:
            changed = self.packet()
            changed[field] = value
            self.assertFalse(owner.valid_packet(changed), field)
        for field in self.packet():
            changed = self.packet()
            del changed[field]
            self.assertFalse(owner.valid_packet(changed), field)
        changed = self.packet()
        changed["foreign"] = True
        self.assertFalse(owner.valid_packet(changed))
        changed = self.packet()
        changed["finished_launching"] = False
        self.assertTrue(
            owner.valid_packet(changed), "false is a public value, not a refusal or readiness"
        )

    def test_foreign_owner_refuses_without_spawning_and_failure_is_closed(self):
        owner = self.owner()
        owner.processes = lambda _: [43]
        with mock.patch.object(probe.subprocess, "Popen") as spawned:
            result = owner.start().finish()
        spawned.assert_not_called()
        self.assertEqual(result["observation"], "unobserved")
        self.assertEqual(result["failure"], "identity-refused")
        owner = self.owner()
        with mock.patch.object(
            probe.subprocess, "Popen", side_effect=OSError("PRIVATE arbitrary path")
        ):
            result = owner.start().finish()
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertEqual(result["failure"], "query-refused")

    def test_actual_child_timeout_retires_without_promoting_missing_result(self):
        native_popen = subprocess.Popen
        with (
            mock.patch.object(probe, "SCRIPTING_TIMEOUT_SECONDS", 0.05),
            mock.patch.object(
                probe.subprocess,
                "Popen",
                side_effect=lambda arguments, **options: native_popen(
                    [sys.executable, "-c", "import time; time.sleep(30)"], **options
                ),
            ),
        ):
            owner = self.owner()
            result = owner.start().finish()
        self.assertIsNotNone(owner.process.returncode)
        self.assertFalse(owner.thread.is_alive())
        self.assertEqual(result["observation"], "unobserved")
        self.assertFalse(result["qualified"])

    def test_unsettled_child_and_thread_remain_cleanup_debt(self):
        owner = self.owner()
        owner.thread = mock.Mock()
        owner.thread.is_alive.return_value = True
        owner.process = mock.Mock(returncode=None)
        with self.assertRaisesRegex(RuntimeError, "cleanup has not settled"):
            owner.finish()
        self.assertIsNotNone(owner.process)
        self.assertIsNotNone(owner.thread)
        owner.process.kill.assert_called_once()

    def test_restore_cannot_release_preferences_with_observer_debt(self):
        owner = probe.NativeDelayedTimerProbe(
            Path("/Applications/ErgoptiPlus.app"), Path("/tmp"), DOMAIN
        )
        owner.managed_launch_observation = mock.Mock()
        owner.managed_launch_observation.finish.side_effect = RuntimeError("owned debt")
        with mock.patch.object(owner.preference, "restore") as restored:
            with self.assertRaisesRegex(RuntimeError, "owned debt"):
                owner.restore()
        restored.assert_not_called()

    def test_actual_cleanup_timeout_keeps_debt_and_never_exposes_child_argv(self):
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)", "PRIVATE-NONCE-SOURCE"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        retire = child.kill
        owner = self.owner()
        owner.process = child
        owner.thread = mock.Mock()
        owner.thread.is_alive.return_value = False
        try:
            with (
                mock.patch.object(child, "kill"),
                mock.patch.object(probe, "SCRIPT_CLEANUP_TIMEOUT_SECONDS", 0.03),
            ):
                with self.assertRaisesRegex(RuntimeError, "cleanup has not settled") as error:
                    owner.finish()
            self.assertNotIn("PRIVATE", str(error.exception))
            self.assertNotIn("sleep", str(error.exception))
            self.assertIs(owner.process, child)
            self.assertIsNone(child.returncode)
        finally:
            retire()
            child.communicate(timeout=2)
        self.assertIsNotNone(child.returncode)


class ManagedLaunchNativeCalibrationTests(unittest.TestCase):
    """Mandatory on native Mac collection; Linux does not claim Cocoa calibration."""

    @unittest.skipUnless(sys.platform == "darwin", "native AppKit calibration unexecuted on Linux")
    def test_real_nsworkspace_identity_bool_foreign_and_closed_observations(self):
        swift = r"""
import AppKit
import Foundation
import Darwin
let args = CommandLine.arguments
if args.count > 1 && args[1] == "--app" {
    final class Delegate: NSObject, NSApplicationDelegate {
        let marker: String
        init(_ marker: String) { self.marker = marker }
        func applicationDidFinishLaunching(_ note: Notification) {
            DispatchQueue.main.async {
                try! Data("ready".utf8).write(to: URL(fileURLWithPath: self.marker))
            }
        }
    }
    let application = NSApplication.shared
    let delegate = Delegate(args[2]); application.delegate = delegate
    application.setActivationPolicy(.prohibited); application.run()
} else {
    let url = URL(fileURLWithPath: args[1])
    let ready = args[2], receipt = args[3]
    var application: NSRunningApplication?
    var launchFailed = false
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    configuration.arguments = ["--app", ready]
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "__CFBundleIdentifier")
    environment.removeValue(forKey: "XPC_SERVICE_NAME")
    configuration.environment = environment
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
        application = app; launchFailed = error != nil
    }
    let deadline = Date().addingTimeInterval(10)
    while (application == nil || !FileManager.default.fileExists(atPath: ready)) && Date() < deadline && !launchFailed {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard let app = application, !app.isTerminated, FileManager.default.fileExists(atPath: ready),
          let executable = app.executableURL, let bundle = app.bundleIdentifier else { exit(2) }
    let packet: [String:Any] = ["pid":Int(app.processIdentifier),"executable":executable.path,
        "bundle_id":bundle,"finished_launching":app.isFinishedLaunching]
    try JSONSerialization.data(withJSONObject: packet).write(to: URL(fileURLWithPath: receipt))
    let end = Date().addingTimeInterval(30)
    while !app.isTerminated && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    if !app.isTerminated { kill(app.processIdentifier, SIGKILL); exit(3) }
    exit(0)
}
"""
        import signal
        import time

        directory = tempfile.mkdtemp(prefix="ergopti-appkit-calibration-")
        root = Path(directory)
        source = root / "Calibration.swift"
        source.write_text(swift)
        controllers, children, owned_executables, bundles = [], [], set(), []

        def native_owned_pids(expected_executables=None):
            listing = subprocess.run(
                ["/bin/ps", "-axo", "pid=,comm="],
                check=True,
                capture_output=True,
                text=True,
                timeout=2,
            )
            result = []
            for line in listing.stdout.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) == 2 and fields[1] in (
                    owned_executables if expected_executables is None else expected_executables
                ):
                    result.append(int(fields[0]))
            return result

        try:
            for name in ("Owned", "Foreign"):
                app = root / (name + ".app")
                exe = app / "Contents/MacOS/Calibration"
                exe.parent.mkdir(parents=True)
                with (app / "Contents/Info.plist").open("wb") as file:
                    plistlib.dump(
                        {
                            "CFBundleIdentifier": "com.ergopti.calibration." + name,
                            "CFBundleExecutable": "Calibration",
                            "CFBundlePackageType": "APPL",
                        },
                        file,
                    )
                subprocess.run(
                    [
                        "/usr/bin/xcrun",
                        "swiftc",
                        "-framework",
                        "AppKit",
                        str(source),
                        "-o",
                        str(exe),
                    ],
                    check=True,
                    capture_output=True,
                    timeout=60,
                )
                subprocess.run(
                    ["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                    check=True,
                    capture_output=True,
                    timeout=10,
                )
                bundles.append((name, app, exe))
            # Compile and sign both before either native lifetime begins.
            for name, app, exe in bundles:
                ready, receipt = root / (name + ".ready"), root / (name + ".json")
                controller = subprocess.Popen(
                    [str(exe), str(app), str(ready), str(receipt)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                controllers.append(controller)
                owned_executables.add(str(exe.resolve()))
                owned_executables.add(str(exe))
                deadline = time.monotonic() + 10
                while (
                    not receipt.exists()
                    and controller.poll() is None
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertTrue(
                    receipt.exists(),
                    "real NSWorkspace launch did not publish its native identity",
                )
                identity = json.loads(receipt.read_text())
                children.append(identity)
                self.assertIs(type(identity["finished_launching"]), bool)
                self.assertTrue(
                    identity["finished_launching"],
                    "independent native Swift owner observes finished launch",
                )
            identity = children[0]
            observation = probe.ManagedLaunchObservation(
                identity["pid"],
                Path(identity["executable"]),
                identity["bundle_id"],
                NONCE,
                lambda _: [identity["pid"]],
            )
            result = observation.start().finish()
            self.assertEqual(result["observation"], "observed")
            self.assertEqual(result["finished_launching"], identity["finished_launching"])
            self.assertFalse(result["qualified"])
            foreign = children[1]
            mismatch = probe.ManagedLaunchObservation(
                foreign["pid"],
                Path(identity["executable"]),
                identity["bundle_id"],
                NONCE,
                lambda _: [foreign["pid"]],
            )
            self.assertEqual(mismatch.start().finish()["observation"], "unobserved")
            self.assertIsNone(
                controllers[0].poll(), "actual retained native controller remains live"
            )
            self.assertIn(
                identity["executable"],
                {str(bundles[0][2]), str(bundles[0][2].resolve())},
                "native receipt names only the independently built Owned executable",
            )
            self.assertIn(
                identity["pid"],
                native_owned_pids({identity["executable"]}),
                "fresh physical exact Owned executable admits retirement, never remembered PID alone",
            )
            os.kill(identity["pid"], signal.SIGKILL)
            controllers[0].communicate(timeout=2)
            self.assertEqual(
                controllers[0].returncode,
                0,
                "native retained NSRunningApplication observed its actual termination",
            )
            closed = probe.ManagedLaunchObservation(
                identity["pid"],
                Path(identity["executable"]),
                identity["bundle_id"],
                NONCE,
                lambda _: [identity["pid"]],
            )
            self.assertEqual(closed.start().finish()["observation"], "unobserved")
        finally:
            primary_error = sys.exc_info()[1]
            settled = self.retire_native_owners(controllers, native_owned_pids, os.kill)
            if settled:
                try:
                    self.assertEqual(
                        native_owned_pids(), [], "every actual owned native calibration PID retired"
                    )
                except Exception:
                    settled = False
            if settled:
                shutil.rmtree(root)
            else:
                # Missing physical ownership never authorizes remembered target PID kills.
                # Retain executable paths and fixture bytes if an app may remain outstanding.
                self.native_cleanup_debt = {
                    "owned_executables": sorted(owned_executables),
                    "controllers": [controller.pid for controller in controllers],
                    "directory": root,
                }
                print(
                    "Native AppKit calibration cleanup refused; owned target debt retained.",
                    file=sys.stderr,
                )
                if primary_error is None:
                    self.fail(
                        "Native AppKit calibration cleanup refused; owned target debt retained"
                    )

    @staticmethod
    def retire_native_owners(controllers, owned_pids, kill):
        import signal
        import time

        refused = False
        try:
            for pid in owned_pids():
                try:
                    kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except Exception:
                    refused = True
        except Exception:
            refused = True
        finally:
            for controller in controllers:
                try:
                    if controller.poll() is None:
                        controller.kill()
                except Exception:
                    refused = True
                try:
                    controller.communicate(timeout=2)
                    if controller.returncode is None:
                        refused = True
                except Exception:
                    refused = True
        try:
            deadline = time.monotonic() + 2
            while owned_pids() and time.monotonic() < deadline:
                time.sleep(0.01)
            if owned_pids():
                refused = True
        except Exception:
            refused = True
        return not refused

    def test_path_enumeration_refusal_still_retires_controllers_and_keeps_target_debt(self):
        seen = []
        controller = mock.Mock(returncode=0)
        controller.poll.side_effect = lambda: seen.append("poll")
        controller.kill.side_effect = lambda: seen.append("kill")
        controller.communicate.side_effect = lambda **options: seen.append(("communicate", options))

        def owned_pids():
            seen.append("physical-enumeration")
            raise subprocess.TimeoutExpired(["ps", "PRIVATE"], 2)

        kill = mock.Mock()
        result = self.retire_native_owners([controller], owned_pids, kill)
        self.assertFalse(result, "controller-only cleanup cannot acknowledge native-app retirement")
        self.assertEqual(
            seen,
            [
                "physical-enumeration",
                "poll",
                "kill",
                ("communicate", {"timeout": 2}),
                "physical-enumeration",
            ],
        )
        kill.assert_not_called()


class ManagedLaunchScriptPortTests(unittest.TestCase):
    """Execute the emitted getter code; portable ports never claim Cocoa ABI."""

    def test_generated_read_only_script_refuses_other_native_class_and_raw_truthiness(self):
        port = r"""
const vm=require('vm');const code=JSON.parse(process.argv[1]);
const modes=['true','false','wrong-class','number','foreign','terminated','forged'];
for (const mode of modes) {
 const app={processIdentifier:42,isTerminated:mode==='terminated',
   isFinishedLaunching:mode==='number'?1:mode!=='false',
   executableURL:{path:mode==='foreign'?'/foreign':process.argv[2]},bundleIdentifier:process.argv[3],
   isNil:()=>false,isKindOfClass:()=>mode!=='wrong-class'};
 const context={ObjC:{import:()=>{},castObjectToRef:obj=>{if(mode==='forged')throw Error('not native');},unwrap:x=>x},
   $:{NSRunningApplication:{runningApplicationWithProcessIdentifier:()=>app},NSProcessInfo:{processInfo:{processIdentifier:123}}}};
 vm.createContext(context);vm.runInContext(code,context);
 try { const packet=JSON.parse(context.run(['42',process.argv[2],process.argv[3],process.argv[4]]));
       process.stdout.write(JSON.stringify({mode,observed:true,value:packet.finished_launching})+'\n'); }
 catch (_) {process.stdout.write(JSON.stringify({mode,observed:false})+'\n');}
}
"""
        result = subprocess.run(
            [
                "node",
                "-e",
                port,
                json.dumps(probe.ManagedLaunchObservation.script()),
                str(EXECUTABLE),
                DOMAIN,
                NONCE,
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [json.loads(line) for line in result.stdout.splitlines()],
            [
                {"mode": "true", "observed": True, "value": True},
                {"mode": "false", "observed": True, "value": False},
            ]
            + [
                {"mode": name, "observed": False}
                for name in ("wrong-class", "number", "foreign", "terminated", "forged")
            ],
        )


if __name__ == "__main__":
    unittest.main()
