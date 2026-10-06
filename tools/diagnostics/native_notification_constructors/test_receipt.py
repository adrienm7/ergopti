# tools/diagnostics/native_notification_constructors/test_receipt.py
"""Independent portable controls; these never qualify native construction."""

import copy
import hashlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import receipt
import run_native

SHA, NONCE, PID = "a" * 40, "b" * 32, 123
EXPECTED = (
    "authenticated_native_notify_runtime",
    "exact_source_pins_before",
    "native_callback_caption_body_options",
    "native_nil_callback_empty_label",
    "native_default_label_and_payload",
    "callback_registry_preserves_exact_function",
    "owned_callback_unregister_readback",
    "constructor_only_no_delivery",
    "exact_source_pins_after",
)
HASHES = {"independent_fixture_source.lua": "c" * 64}


def packet():
    return {
        "schema": 1,
        "contract": "macos-native-application-notification-constructors",
        "source_sha": SHA,
        "nonce": NONCE,
        "pid": PID,
        "source_hashes": dict(HASHES),
        "cases": [{"id": name, "status": "passed"} for name in EXPECTED],
        "counts": {"passed": 9, "failed": 0, "skipped": 0},
        "scope": {
            "constructor_only": True,
            "notification_delivery": False,
            "callback_invocation": False,
            "gc_native_destruction_verified": False,
            "user_configuration_modified": False,
        },
        "forbidden_attempts": 0,
        "callback_invocations": 0,
        "owned_tags_remaining": 0,
        "input_properties_unchanged": True,
    }


class PortableControls(unittest.TestCase):
    def validate(self, value):
        return receipt.validate(value, SHA, NONCE, PID, HASHES)

    def test_independent_full_census(self):
        self.assertEqual(self.validate(packet()), 9)

    def test_zero_missing_duplicate_extra_case_refused(self):
        for action in (
            lambda p: p.update(cases=[]),
            lambda p: p["cases"].pop(),
            lambda p: p["cases"].__setitem__(1, copy.deepcopy(p["cases"][0])),
            lambda p: p["cases"].append({"id": "fabricated", "status": "passed"}),
        ):
            value = packet()
            action(value)
            with self.assertRaises(ValueError):
                self.validate(value)

    def test_failure_skip_and_false_counters_never_pass(self):
        for status in ("failed", "skipped"):
            for index in range(9):
                value = packet()
                value["cases"][index]["status"] = status
                with self.assertRaises(ValueError):
                    self.validate(value)
        for action in (
            lambda p: p["counts"].update(passed=True),
            lambda p: p["counts"].update(failed=1),
            lambda p: p["counts"].update(skipped=1),
        ):
            value = packet()
            action(value)
            with self.assertRaises(ValueError):
                self.validate(value)

    def test_stale_identity_source_and_extra_private_fields_refused(self):
        for key, replacement in (
            ("source_sha", "d" * 40),
            ("nonce", "e" * 32),
            ("pid", 456),
            ("pid", True),
            ("source_hashes", {}),
            ("raw_native_error", "private"),
        ):
            value = packet()
            value[key] = replacement
            with self.assertRaises(ValueError):
                self.validate(value)

    def test_forbidden_delivery_click_and_callback_debt_refused(self):
        for key in ("forbidden_attempts", "callback_invocations", "owned_tags_remaining"):
            for count in (1, False, None):
                value = packet()
                value[key] = count
                with self.assertRaises(ValueError):
                    self.validate(value)
        value = packet()
        value["input_properties_unchanged"] = False
        with self.assertRaises(ValueError):
            self.validate(value)

    def test_scope_cannot_claim_gc_delivery_or_user_configuration(self):
        for key in packet()["scope"]:
            value = packet()
            value["scope"][key] = not value["scope"][key]
            with self.assertRaises(ValueError):
                self.validate(value)

    def test_duplicate_json_and_oversize_refused(self):
        with self.assertRaises(ValueError):
            receipt.decode(b'{"schema":1,"schema":1}')
        with self.assertRaises(ValueError):
            receipt.decode(b" " * 32769)

    def test_early_registration_survives_adopter_failure(self):
        capability, native, owners = object(), object(), []

        def acquire(arguments, actual, register, **options):
            self.assertIs(actual, native)
            register(capability)

        ownership = SimpleNamespace(acquire_owned=acquire)
        borrowed = run_native.retained_acquirer(ownership, native, owners)

        def refuse(cap):
            self.assertIs(owners[0], cap)
            raise KeyboardInterrupt()

        with self.assertRaises(KeyboardInterrupt):
            borrowed.acquire_owned(["fixed"], native, refuse)
        self.assertEqual(owners, [capability])
        with self.assertRaisesRegex(ValueError, "foreign_native_owner_refused"):
            borrowed.acquire_owned(["fixed"], object(), refuse)
        self.assertEqual(owners, [capability])

    def test_existing_retirement_refusal_preserves_caps_until_recovery(self):
        capability = SimpleNamespace(reaped=False, receipt=lambda: {"closed": False})
        calls = []

        def settle(caps):
            self.assertIs(caps[0], capability)
            calls.append(capability)
            if len(calls) == 1:
                raise ValueError("controlled_native_refusal")
            capability.reaped = True

        inventory = SimpleNamespace(settle_registered=settle)
        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(run_native.time, "sleep"),
        ):
            self.assertFalse(run_native.retire_registered(inventory, [capability], Path(directory)))
        self.assertTrue(capability.reaped)
        self.assertEqual(len(calls), 2)

    def test_retirement_report_io_failure_cannot_abandon_caps(self):
        capability = SimpleNamespace(reaped=False, receipt=lambda: {"closed": False})
        calls = []

        def settle(caps):
            calls.append(caps[0])
            capability.reaped = len(calls) == 2

        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(run_native.time, "sleep"),
            mock.patch.object(Path, "write_text", side_effect=OSError("controlled IO refusal")),
        ):
            self.assertFalse(
                run_native.retire_registered(
                    SimpleNamespace(settle_registered=settle), [capability], Path(directory)
                )
            )
        self.assertEqual(calls, [capability, capability])
        self.assertTrue(capability.reaped)

    def test_cancellation_during_retirement_pause_cannot_abandon_caps(self):
        capability = SimpleNamespace(reaped=False, receipt=lambda: {"closed": False})
        calls = []

        def settle(caps):
            calls.append(caps[0])
            capability.reaped = len(calls) == 2

        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(run_native.time, "sleep", side_effect=KeyboardInterrupt),
        ):
            self.assertFalse(
                run_native.retire_registered(
                    SimpleNamespace(settle_registered=settle), [capability], Path(directory)
                )
            )
        self.assertEqual(calls, [capability, capability])
        self.assertTrue(capability.reaped)

    def test_pinned_module_executes_one_captured_verified_read(self):
        raw = b"observed = 'independent_verified_bytes'\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "module.py"
            path.write_bytes(raw)
            with (
                mock.patch.dict(
                    run_native.DEPENDENCIES, {"ownership": hashlib.sha256(raw).hexdigest()}
                ),
                mock.patch.object(Path, "read_bytes", return_value=raw) as read,
            ):
                loaded = run_native.pinned_module(path, "ownership")
                self.assertEqual(loaded.observed, "independent_verified_bytes")
                read.assert_called_once()
        with self.assertRaises(ValueError):
            with mock.patch.object(Path, "read_bytes", return_value=b"foreign source"):
                run_native.pinned_module(Path("module.py"), "ownership")

    def test_linux_rejects_before_any_native_module_or_allocation(self):
        with (
            mock.patch.object(run_native.sys, "platform", "linux"),
            mock.patch.object(run_native, "pinned_module") as acquire,
            mock.patch("builtins.print"),
        ):
            self.assertEqual(
                run_native.main(["--source-root", ".", "--source-sha", SHA, "--output", "unused"]),
                77,
            )
            acquire.assert_not_called()


class BootstrapCallerControls(unittest.TestCase):
    def test_actual_pinned_inventory_accepts_only_current_verified_source(self):
        path = Path(__file__).resolve().parents[1] / "native_hs_program_providers/run_native.py"
        raw = path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), run_native.DEPENDENCIES["inventory"])
        inventory = run_native.pinned_module(path, "inventory")
        self.assertTrue(callable(inventory.bootstrap_response))
        with mock.patch.object(Path, "read_bytes", return_value=raw + b"\nforeign = True\n"):
            with self.assertRaises(ValueError):
                run_native.pinned_module(path, "inventory")

    def test_actual_archive_scope_logs_closed_failure_then_retains_original_cleanup_policy(self):
        import contextlib
        import io
        import json
        from urllib.error import HTTPError

        path = Path(__file__).resolve().parents[1] / "native_hs_program_providers/run_native.py"
        inventory = run_native.pinned_module(path, "inventory")
        allocation = mock.Mock(
            side_effect=AssertionError("native acquisition forbidden in portable control")
        )
        ownership = SimpleNamespace(NativeProcessGroups=lambda: object(), acquire_owned=allocation)
        error = HTTPError(
            "PRIVATE_URL", 503, "PRIVATE_MESSAGE", {"PRIVATE_HEADER": "PRIVATE_BODY"}, None
        )
        logged = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "scope"
            with (
                mock.patch.object(run_native.sys, "platform", "darwin"),
                mock.patch.object(run_native.sys, "version_info", (3, 13)),
                mock.patch.object(
                    run_native,
                    "pinned_module",
                    side_effect=lambda _path, kind: ownership if kind == "ownership" else inventory,
                ),
                mock.patch.object(inventory, "source_hashes", return_value={}),
                mock.patch.object(
                    inventory,
                    "trusted_asset",
                    return_value={"browser_download_url": "PRIVATE_URL", "size": 1024},
                ),
                mock.patch.object(inventory, "urlopen", side_effect=error),
                mock.patch.object(run_native, "urlopen", side_effect=error, create=True),
                contextlib.redirect_stdout(logged),
            ):
                with self.assertRaisesRegex(ValueError, "^native_probe_failed$"):
                    run_native.main(
                        [
                            "--source-root",
                            directory,
                            "--source-sha",
                            SHA,
                            "--output",
                            str(output),
                            "--download",
                        ]
                    )
            failure = json.loads((output / "failure.json").read_text())
            physical = json.loads((output / "physical-group.json").read_text())
        self.assertEqual(failure["reason"], "native_probe_failed")
        self.assertFalse(failure["native_pass"])
        self.assertTrue(failure["native_processes_retired"])
        self.assertEqual(physical["capabilities"], [])
        self.assertTrue(physical["closed"])
        allocation.assert_not_called()
        self.assertEqual(
            json.loads(logged.getvalue()),
            {
                "schema": 1,
                "contract": "macos-native-bootstrap-failure",
                "phase": "archive_download",
                "family": "http_error",
                "http_status": 503,
                "native_pass": False,
            },
        )
        for secret in ("PRIVATE_URL", "PRIVATE_MESSAGE", "PRIVATE_HEADER", "PRIVATE_BODY"):
            self.assertNotIn(secret, logged.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
