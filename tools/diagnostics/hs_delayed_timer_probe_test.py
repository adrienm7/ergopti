# tools/diagnostics/hs_delayed_timer_probe_test.py
"""Refuse incomplete native observations and preserve the scripting preference."""

import base64
import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
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

            def launch(arguments, **options):
                source = (
                    "import time; time.sleep(5)" if not children else "print(" + repr(NONCE) + ")"
                )
                child = native_popen([sys.executable, "-c", source], **options)
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
                    mock.patch.object(probe, "SCRIPTING_TIMEOUT_SECONDS", 0.05),
                ):
                    with self.assertRaisesRegex(RuntimeError, "TimeoutExpired"):
                        owner.control_pid(42, lambda _: [42])
                    self.assertIsNotNone(children[0].returncode)
                    self.assertEqual(owner.scripting_commands, [])
                    summary = owner.control_pid(42, lambda _: [42])
                probe.validate_pid_control_summary(summary)
                self.assertEqual(len(children), 2)
                self.assertIsNotNone(children[1].returncode)
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
            owner.retain_diagnostics(["extra request"])
            self.assertEqual(len(owner.diagnostic_receipts), probe.SCRIPT_DIAGNOSTIC_RECEIPT_LIMIT)
            self.assertTrue(owner.diagnostic_receipts[-1]["additional_commands_omitted"])
            self.assertEqual(owner.diagnostic_receipts[-1]["phase"], "constructor")

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


if __name__ == "__main__":
    unittest.main()
