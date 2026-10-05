# tools/diagnostics/native_hs_program_providers/test_receipt.py
"""Portable parser controls only; this does not produce a native PASS verdict."""

import copy
import json
from pathlib import Path
import tempfile
import sys
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


DIAGNOSTIC_FILES = (
    "tools/diagnostics/native_hs_program_providers/fixture.lua",
    "tools/diagnostics/native_hs_program_providers/fixture_shim.lua",
    "tools/diagnostics/native_hs_program_providers/run_native.py",
)
DIAGNOSTIC_HASHES = {path: "d" * 64 for path in DIAGNOSTIC_FILES}


def facts():
    return {
        "schema": 1,
        "contract": "macos-native-hs-program-provider-diagnostic-facts",
        "source_sha": SHA,
        "nonce": NONCE,
        "pid": 123,
        "scenario": "full",
        "source_hashes": dict(DIAGNOSTIC_HASHES),
        "case_facts": [{"case": name, "kind": "none", "ordinal": 0} for name in EXPECTED_FULL],
        "runtime": {
            "lua_version": "Lua 5.4",
            "dir": "C",
            "attributes": "C",
            "symlink_attributes": "Lua",
            "path_to_absolute": "C",
            "file_open": "C",
        },
        "interpreter": {
            "resolved_scalar_observed": True,
            "interpreter_equal": False,
            "argv_count_equal": True,
            "script_argument_equal": True,
        },
        "expected_path_equal": True,
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

            def prepare_owned_link(base, *arguments):
                (base / "bin").mkdir()
                (base / "bin/python3").symlink_to(Path(sys.executable).resolve())
                return {"receipt": str(output / "missing")}

            with (
                mock.patch.object(subject, "prepare", side_effect=prepare_owned_link),
                # This control exercises native acquisition handoff, not bundle admission.
                mock.patch.object(subject, "runtime_origin", return_value={}),
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


class DiagnosticFactControls(unittest.TestCase):
    def validate(self, value, primary=None):
        return subject.validate_diagnostic_facts(
            value,
            packet() if primary is None else primary,
            "full",
            SHA,
            NONCE,
            123,
            DIAGNOSTIC_HASHES,
        )

    def test_closed_diagnostic_facts_have_no_native_verdict(self):
        self.assertIsNone(self.validate(facts()))
        self.assertNotIn("native_pass", facts())
        self.assertEqual(subject.validate_receipt(packet(), "full", SHA, NONCE, 123, HASHES), 16)
        # A primary all-pass packet is insufficient when auxiliary publication refused.
        retained = type(
            "ClosedOwner",
            (),
            {
                "process": type("ControlledProcess", (), {"pid": 123, "returncode": 0})(),
                "settle": mock.Mock(return_value=True),
                "receipt": lambda self: {"controlled_parser_fixture_only": True},
                "wait_for_exit": mock.Mock(),
            },
        )()

        def acquire(arguments, native, register, **options):
            register(retained)
            return retained

        owner = type("OwnershipPort", (), {"acquire_owned": staticmethod(acquire)})()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            primary = output / "primary.json"
            primary.write_text(json.dumps(packet()))

            def prepare_owned_link(base, *arguments):
                (base / "bin").mkdir()
                (base / "bin/python3").symlink_to(Path(sys.executable).resolve())
                return {"receipt": str(primary)}

            with (
                mock.patch.object(subject, "prepare", side_effect=prepare_owned_link),
                # Bundle admission is separate from the missing-facts retirement control.
                mock.patch.object(subject, "runtime_origin", return_value={}),
                mock.patch.object(subject.secrets, "token_hex", return_value=NONCE),
                mock.patch("builtins.print"),
            ):
                with self.assertRaises(FileNotFoundError):
                    subject.run_case(
                        "full",
                        Path("application"),
                        Path("source"),
                        SHA,
                        output,
                        HASHES,
                        object(),
                        owner,
                        DIAGNOSTIC_HASHES,
                    )
            self.assertEqual(len(list(output.glob("*/physical-group.json"))), 1)
        retained.settle.assert_called_once()
        retained.wait_for_exit.assert_not_called()

    def test_valid_failure_facts_never_promote_primary_failure(self):
        primary = packet()
        primary["cases"][0]["status"] = "failed"
        primary["cases"][4]["status"] = "failed"
        primary["counts"] = {"passed": 14, "failed": 2, "skipped": 0}
        value = facts()
        value["case_facts"][0].update(kind="check", ordinal=4)
        value["case_facts"][4].update(kind="check", ordinal=1)
        self.assertIsNone(self.validate(value, primary))
        with self.assertRaisesRegex(ValueError, "native_case_failed"):
            subject.validate_receipt(primary, "full", SHA, NONCE, 123, HASHES)
        value["case_facts"][4].update(kind="raised", ordinal=0)
        self.assertIsNone(self.validate(value, primary))
        with self.assertRaisesRegex(ValueError, "native_case_failed"):
            subject.validate_receipt(primary, "full", SHA, NONCE, 123, HASHES)

    def test_stale_fact_owner_and_source_pins_refused(self):
        for key, replacement in (
            ("source_sha", "e" * 40),
            ("nonce", "f" * 32),
            ("pid", 124),
            ("source_hashes", {}),
            ("scenario", "shim"),
            ("pid", True),
        ):
            with self.subTest(key=key, replacement=replacement):
                value = facts()
                value[key] = replacement
                with self.assertRaises(ValueError):
                    self.validate(value)

    def test_extra_private_fields_and_unbounded_values_refused(self):
        for action in (
            lambda v: v.update(raw_error="private scalar"),
            lambda v: v["runtime"].update(path="private scalar"),
            lambda v: v["runtime"].update(symlink_attributes="private scalar"),
            lambda v: v["runtime"].update(lua_version="private scalar"),
            lambda v: v["interpreter"].update(interpreter_equal="private scalar"),
            lambda v: v.update(expected_path_equal="private scalar"),
            lambda v: v["case_facts"][0].update(error="private scalar"),
        ):
            value = facts()
            action(value)
            with self.assertRaises(ValueError):
                self.validate(value)

    def test_case_census_and_original_failure_kind_refused(self):
        for action in (
            lambda v: v.update(case_facts=[]),
            lambda v: v["case_facts"].pop(),
            lambda v: v["case_facts"].__setitem__(1, copy.deepcopy(v["case_facts"][0])),
            lambda v: v["case_facts"][0].update(kind="check", ordinal=4),
            lambda v: v["case_facts"][0].update(ordinal=True),
        ):
            value = facts()
            action(value)
            with self.assertRaises(ValueError):
                self.validate(value)
        primary = packet()
        primary["cases"][0]["status"] = "failed"
        for kind, ordinal in (
            ("none", 0),
            ("check", 0),
            ("raised", 4),
            ("check", 1 << 53),
            ("private scalar", 1),
        ):
            value = facts()
            value["case_facts"][0].update(kind=kind, ordinal=ordinal)
            with self.assertRaises(ValueError):
                self.validate(value, primary)

    def test_diagnostic_template_pins_are_verified_against_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for path in DIAGNOSTIC_FILES:
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(b"independent committed bytes")
            with mock.patch.object(
                subject.subprocess, "check_output", return_value=b"independent committed bytes"
            ) as read:
                observed = subject.source_hashes(root, SHA, DIAGNOSTIC_FILES)
                self.assertEqual(set(observed), set(DIAGNOSTIC_FILES))
                self.assertEqual(read.call_count, 3)
                self.assertEqual(
                    read.call_args_list[0].args[0], ["git", "show", SHA + ":" + DIAGNOSTIC_FILES[0]]
                )
            (root / DIAGNOSTIC_FILES[0]).write_bytes(b"foreign bytes")
            with mock.patch.object(
                subject.subprocess, "check_output", return_value=b"independent committed bytes"
            ):
                with self.assertRaisesRegex(ValueError, "source_worktree_drift"):
                    subject.source_hashes(root, SHA, DIAGNOSTIC_FILES)


if __name__ == "__main__":
    unittest.main()
