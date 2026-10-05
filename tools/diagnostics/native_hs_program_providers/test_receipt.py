# tools/diagnostics/native_hs_program_providers/test_receipt.py
"""Portable parser controls only; this does not produce a native PASS verdict."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import run_native as subject

SHA = "a" * 40
NONCE = "b" * 32
# These literal expected values are authored independently from runner constants.
EXPECTED_FILES = (
    "static/ergopti_plus/macos/adapters/program_providers.lua",
    "static/ergopti_plus/macos/infra/fs_dir.lua",
    "static/ergopti_plus/_shared/lua/program_providers.lua",
    "static/ergopti_plus/_shared/modules/actions/program_providers.json",
    "static/ergopti_plus/_shared/lua/program_parameter.lua",
    "static/ergopti_plus/_shared/lua/json.lua",
    "static/ergopti_plus/_shared/lua/compat/utf8.lua",
    "tools/diagnostics/macos_owned_process.py",
)
EXPECTED_FULL = (
    "actual_native_runtime",
    "exact_source_pins_before",
    "inventory_independent_choices",
    "literal_v1_independent_argv",
    "real_interpreter_symlink",
    "interpreter_link_retarget_is_stale",
    "replaced_script_is_stale",
    "proven_missing_root_is_neutral",
    "script_root_symlink_is_refused",
    "native_bounded_directory_loop",
    "native_directory_close_observation",
    "native_listing_failure_is_private",
    "invalid_utf8_native_name_fails_closed",
    "configured_route_change_is_stale",
    "no_private_diagnostics_or_execution",
    "exact_source_pins_after",
)
EXPECTED_SHIM = (
    "actual_native_runtime",
    "exact_source_pins_before",
    "real_system_shim_present",
    "fixed_system_python_shim_is_not_installed_provider",
    "exact_source_pins_after",
)
EXPECTED_SCOPE = {
    "inventory": True,
    "program_execution": False,
    "effective_acl_verified": False,
    "closedir_errno_observed": False,
    "atomic_execution_lease": False,
}
HASHES = {path: "c" * 64 for path in EXPECTED_FILES}


def packet():
    return {
        "schema": 1,
        "contract": "macos-native-hs-program-providers",
        "source_sha": SHA,
        "nonce": NONCE,
        "pid": 123,
        "scenario": "full",
        "source_hashes": dict(HASHES),
        "scope": dict(EXPECTED_SCOPE),
        "cases": [{"id": name, "status": "passed"} for name in EXPECTED_FULL],
        "counts": {"passed": 16, "failed": 0, "skipped": 0},
    }


class ReceiptControls(unittest.TestCase):
    def validate(self, value):
        return subject.validate_receipt(value, "full", SHA, NONCE, 123, HASHES)

    def test_complete_structure_only(self):
        self.assertEqual(self.validate(packet()), 16)

    def test_independent_shim_census(self):
        value = packet()
        value["scenario"] = "shim"
        value["cases"] = [{"id": name, "status": "passed"} for name in EXPECTED_SHIM]
        value["counts"] = {"passed": 5, "failed": 0, "skipped": 0}
        self.assertEqual(subject.validate_receipt(value, "shim", SHA, NONCE, 123, HASHES), 5)

    def test_duplicate_json_field(self):
        with self.assertRaises(ValueError):
            subject.decode_receipt(b'{"schema":1,"schema":1}')

    def test_zero_case_census(self):
        value = packet()
        value["cases"] = []
        value["counts"] = {"passed": 0, "failed": 0, "skipped": 0}
        with self.assertRaises(ValueError):
            self.validate(value)

    def test_duplicate_or_missing_case(self):
        value = packet()
        value["cases"][1] = copy.deepcopy(value["cases"][0])
        with self.assertRaises(ValueError):
            self.validate(value)

    def test_stale_sha_nonce_pid_and_sources(self):
        for key, replacement in (
            ("source_sha", "d" * 40),
            ("nonce", "e" * 32),
            ("pid", 456),
            ("source_hashes", {}),
        ):
            with self.subTest(key=key):
                value = packet()
                value[key] = replacement
                with self.assertRaises(ValueError):
                    self.validate(value)

    def test_boolean_counters_and_fabricated_scope(self):
        for action in (
            lambda p: p["counts"].update(passed=True),
            lambda p: p["scope"].update(program_execution=True),
            lambda p: p["scope"].update(closedir_errno_observed=True),
        ):
            value = packet()
            action(value)
            with self.assertRaises(ValueError):
                self.validate(value)

    def test_failed_skipped_extra_and_oversize(self):
        for status in ("failed", "skipped"):
            value = packet()
            value["cases"][0]["status"] = status
            with self.assertRaises(ValueError):
                self.validate(value)
        value = packet()
        value["extra"] = True
        with self.assertRaises(ValueError):
            self.validate(value)
        with self.assertRaises(ValueError):
            subject.decode_receipt(b" " * (subject.BYTE_LIMIT + 1))

    def test_metadata_acquisition_register_then_raise_retires_exact_capability(self):
        retained = type(
            "KnownOwnership", (), {"settle": lambda self: self.calls.append("settle") or True}
        )()
        retained.calls = []

        def acquire(arguments, native, register, **options):
            register(retained)
            raise KeyboardInterrupt("controlled handoff interruption")

        owner = type("OwnershipPort", (), {"acquire_owned": staticmethod(acquire)})()
        with self.assertRaises(KeyboardInterrupt):
            subject.owned_tool(["metadata"], object(), owner)
        self.assertEqual(retained.calls, ["settle"])

    def test_runtime_acquisition_register_then_raise_retires_exact_capability(self):
        retained = type(
            "KnownOwnership",
            (),
            {
                "settle": lambda self: self.calls.append("settle") or True,
                "receipt": lambda self: {"controlled_parser_fixture_only": True},
            },
        )()
        retained.calls = []

        def acquire(arguments, native, register, **options):
            register(retained)
            raise KeyboardInterrupt("controlled handoff interruption")

        owner = type("OwnershipPort", (), {"acquire_owned": staticmethod(acquire)})()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with mock.patch.object(
                subject, "prepare", return_value={"receipt": str(output / "missing")}
            ):
                with self.assertRaises(KeyboardInterrupt):
                    subject.run_case(
                        "full",
                        Path("application"),
                        Path("source"),
                        SHA,
                        output,
                        HASHES,
                        object(),
                        owner,
                    )
            physical = list(output.glob("*/physical-group.json"))
            self.assertEqual(len(physical), 1)
            self.assertEqual(
                json.loads(physical[0].read_text()), {"controlled_parser_fixture_only": True}
            )
        self.assertEqual(retained.calls, ["settle"])

    def test_timeout_and_early_exit_never_admit_missing_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "missing"
            group = type("OnlyParserControl", (), {"observe_exit": lambda self: None})()
            times = iter((0, 46))
            with self.assertRaisesRegex(ValueError, "native_receipt_timeout"):
                subject.await_packet(
                    missing, group, clock=lambda: next(times), pause=lambda _: None
                )
            group.observe_exit = lambda: object()
            with self.assertRaisesRegex(ValueError, "native_runtime_exited_without_receipt"):
                subject.await_packet(missing, group)


if __name__ == "__main__":
    unittest.main()
