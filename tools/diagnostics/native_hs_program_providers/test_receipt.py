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


class ClosedDiagnosticLogControls(unittest.TestCase):
    def test_invalid_diagnostic_facts_produce_no_log(self):
        for mutate in (
            lambda value: value.update(raw_error="private path scalar argv"),
            lambda value: value.update(pid=124),
            lambda value: value["runtime"].update(file_open="private path scalar argv"),
        ):
            value = facts()
            mutate(value)
            with mock.patch("builtins.print") as printed:
                with self.assertRaises(ValueError):
                    subject.report_diagnostic_facts(
                        value, packet(), "full", SHA, NONCE, 123, DIAGNOSTIC_HASHES
                    )
                printed.assert_not_called()

    def test_valid_failed_facts_log_only_closed_fields_and_never_promote_primary(self):
        import contextlib
        import io

        for scenario, census in (("full", EXPECTED_FULL), ("shim", EXPECTED_SHIM)):
            with self.subTest(scenario=scenario):
                primary, value = packet(), facts()
                primary.update(
                    scenario=scenario,
                    cases=[{"id": name, "status": "passed"} for name in census],
                    counts={"passed": len(census) - 1, "failed": 1, "skipped": 0},
                )
                primary["cases"][0]["status"] = "failed"
                value.update(
                    scenario=scenario,
                    case_facts=[{"case": name, "kind": "none", "ordinal": 0} for name in census],
                )
                value["case_facts"][0].update(kind="check", ordinal=4)
                logged = io.StringIO()
                with contextlib.redirect_stdout(logged):
                    result = subject.report_diagnostic_facts(
                        value, primary, scenario, SHA, NONCE, 123, DIAGNOSTIC_HASHES
                    )
                self.assertIsNone(result)
                observed = json.loads(logged.getvalue())
                self.assertEqual(
                    set(observed),
                    {
                        "contract",
                        "scenario",
                        "case_facts",
                        "runtime",
                        "interpreter",
                        "expected_path_equal",
                    },
                )
                self.assertEqual(
                    observed["case_facts"][0],
                    {"case": census[0], "kind": "check", "ordinal": 4},
                )
                for private in (
                    SHA,
                    NONCE,
                    *DIAGNOSTIC_FILES,
                    '"pid"',
                    '"source_hashes"',
                    '"counts"',
                    '"native_pass"',
                ):
                    self.assertNotIn(private, logged.getvalue())
                with self.assertRaisesRegex(ValueError, "native_case_failed"):
                    subject.validate_receipt(primary, scenario, SHA, NONCE, 123, HASHES)

    def test_both_native_scenarios_log_closed_failure_then_retire_without_success(self):
        import contextlib
        import io

        for scenario, census in (("full", EXPECTED_FULL), ("shim", EXPECTED_SHIM)):
            with (
                self.subTest(scenario=scenario),
                tempfile.TemporaryDirectory() as temporary,
            ):
                output = Path(temporary)
                primary, value = packet(), facts()
                primary.update(
                    scenario=scenario,
                    cases=[{"id": name, "status": "passed"} for name in census],
                    counts={"passed": len(census) - 1, "failed": 1, "skipped": 0},
                )
                primary["cases"][0]["status"] = "failed"
                value.update(
                    scenario=scenario,
                    case_facts=[{"case": name, "kind": "none", "ordinal": 0} for name in census],
                )
                value["case_facts"][0].update(kind="raised", ordinal=0)
                retained = type(
                    "ClosedMockOwner",
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

                def prepare_owned_link(base, *arguments):
                    (base / "bin").mkdir()
                    (base / "bin/python3").symlink_to(Path(sys.executable).resolve())
                    path = base / "primary.json"
                    path.write_text(json.dumps(primary))
                    (base / "diagnostic-facts.json").write_text(json.dumps(value))
                    return {"receipt": str(path)}

                logged = io.StringIO()
                with (
                    mock.patch.object(subject, "prepare", side_effect=prepare_owned_link),
                    mock.patch.object(subject, "runtime_origin", return_value={}),
                    mock.patch.object(subject.secrets, "token_hex", return_value=NONCE),
                    contextlib.redirect_stdout(logged),
                ):
                    with self.assertRaisesRegex(ValueError, "native_case_failed"):
                        subject.run_case(
                            scenario,
                            Path("application"),
                            Path("source"),
                            SHA,
                            output,
                            HASHES,
                            object(),
                            owner,
                            DIAGNOSTIC_HASHES,
                        )
                records = [json.loads(line) for line in logged.getvalue().splitlines()]
                diagnostic = [
                    record
                    for record in records
                    if record["contract"] == "macos-native-hs-program-provider-diagnostic-facts"
                ]
                self.assertEqual(len(diagnostic), 1)
                self.assertEqual(
                    diagnostic[0]["case_facts"][0],
                    {"case": census[0], "kind": "raised", "ordinal": 0},
                )
                self.assertNotIn(NONCE, logged.getvalue())
                self.assertNotIn(SHA, logged.getvalue())
                self.assertNotIn('"pid"', logged.getvalue())
                retained.settle.assert_called_once()
                retained.wait_for_exit.assert_not_called()


class BootstrapBoundaryControls(unittest.TestCase):
    """Actual network scopes; controlled HTTP objects, never native macOS PASS."""

    def facts(self, text, phase, family, status):
        self.assertEqual(
            json.loads(text),
            {
                "schema": 1,
                "contract": "macos-native-bootstrap-failure",
                "phase": phase,
                "family": family,
                "http_status": status,
                "native_pass": False,
            },
        )
        for private in ("PRIVATE_URL", "PRIVATE_MESSAGE", "PRIVATE_HEADER", "PRIVATE_BODY"):
            self.assertNotIn(private, text)

    def test_actual_metadata_http_failure_preserves_original_and_has_no_native_tool(self):
        import contextlib
        import io
        from urllib.error import HTTPError

        error = HTTPError(
            "https://PRIVATE_URL/PRIVATE_BODY",
            403,
            "PRIVATE_MESSAGE",
            {"PRIVATE_HEADER": "PRIVATE_BODY"},
            None,
        )
        logged = io.StringIO()
        with (
            mock.patch.object(subject, "urlopen", side_effect=error) as opening,
            mock.patch.object(subject, "owned_tool") as native,
            contextlib.redirect_stdout(logged),
        ):
            with self.assertRaises(HTTPError) as caught:
                subject.trusted_asset(Path("unused"))
        self.assertIs(caught.exception, error)
        self.facts(logged.getvalue(), "release_metadata", "http_error", 403)
        native.assert_not_called()
        request = opening.call_args.args[0]
        self.assertEqual(
            request.full_url,
            "https://api.github.com/repos/Hammerspoon/hammerspoon/releases/tags/1.1.1",
        )
        self.assertEqual(opening.call_args.kwargs, {"timeout": 20})

    def test_archive_open_and_read_http_errors_keep_exact_exception(self):
        import contextlib
        import io
        from urllib.error import HTTPError

        for boundary in ("open", "read"):
            with self.subTest(boundary=boundary):
                error = HTTPError(
                    "PRIVATE_URL", 503, "PRIVATE_MESSAGE", {"PRIVATE_HEADER": "PRIVATE_BODY"}, None
                )
                response = mock.MagicMock()
                response.__enter__.return_value = response
                response.read.side_effect = error
                logged = io.StringIO()
                with (
                    mock.patch.object(
                        subject,
                        "urlopen",
                        side_effect=error if boundary == "open" else None,
                        return_value=response,
                    ),
                    contextlib.redirect_stdout(logged),
                ):
                    with self.assertRaises(HTTPError) as caught:
                        with subject.bootstrap_response(
                            "archive_download", "PRIVATE_URL", timeout=30
                        ) as incoming:
                            incoming.read(1025)
                self.assertIs(caught.exception, error)
                self.facts(logged.getvalue(), "archive_download", "http_error", 503)
                if boundary == "read":
                    response.read.assert_called_once_with(1025)
                    self.assertIs(response.__exit__.call_args.args[1], error)

    def test_transport_tls_and_read_timeout_families_do_not_invent_status(self):
        import contextlib
        import io
        import ssl
        from urllib.error import URLError

        cases = [
            (URLError("PRIVATE_MESSAGE"), "transport_error"),
            (ssl.SSLCertVerificationError("PRIVATE_MESSAGE"), "tls_error"),
            (URLError(ssl.SSLCertVerificationError("PRIVATE_MESSAGE")), "tls_error"),
            (TimeoutError("PRIVATE_MESSAGE"), "read_timeout"),
        ]
        for error, family in cases:
            for phase in ("release_metadata", "archive_download"):
                with self.subTest(error=type(error).__name__, phase=phase):
                    logged = io.StringIO()
                    response = mock.MagicMock()
                    response.__enter__.return_value = response
                    response.read.side_effect = error
                    with (
                        mock.patch.object(subject, "urlopen", return_value=response),
                        contextlib.redirect_stdout(logged),
                    ):
                        with self.assertRaises(type(error)) as caught:
                            with subject.bootstrap_response(
                                phase, "PRIVATE_URL", timeout=20
                            ) as incoming:
                                incoming.read(17)
                    self.assertIs(caught.exception, error)
                    self.facts(logged.getvalue(), phase, family, None)

    def test_malformed_http_status_is_unknown_without_serializing_input(self):
        import contextlib
        import io
        from urllib.error import HTTPError

        for code in (True, False, 99, 600, -1, 403.0, "PRIVATE_BODY", None):
            with self.subTest(code_type=type(code).__name__):
                error = HTTPError("PRIVATE_URL", code, "PRIVATE_MESSAGE", None, None)
                logged = io.StringIO()
                with (
                    mock.patch.object(subject, "urlopen", side_effect=error),
                    contextlib.redirect_stdout(logged),
                ):
                    with self.assertRaises(HTTPError) as caught:
                        with subject.bootstrap_response(
                            "release_metadata", "PRIVATE_URL", timeout=20
                        ):
                            self.fail("refused request yielded")
                self.assertIs(caught.exception, error)
                self.facts(logged.getvalue(), "release_metadata", "http_error", None)

    def test_http_code_is_captured_once_and_getter_refusal_preserves_original(self):
        import contextlib
        import io
        from urllib.error import HTTPError

        class ChangingCode(HTTPError):
            reads = 0

            def __getattribute__(self, name):
                if name == "code":
                    count = object.__getattribute__(self, "reads") + 1
                    object.__setattr__(self, "reads", count)
                    return 403 if count == 1 else "PRIVATE_BODY"
                return super().__getattribute__(name)

        class RefusedCode(HTTPError):
            def __getattribute__(self, name):
                if name == "code":
                    raise OSError("PRIVATE_BODY")
                return super().__getattribute__(name)

        for error in (
            ChangingCode("PRIVATE_URL", 403, "PRIVATE_MESSAGE", None, None),
            RefusedCode("PRIVATE_URL", 403, "PRIVATE_MESSAGE", None, None),
        ):
            logged = io.StringIO()
            with (
                mock.patch.object(subject, "urlopen", side_effect=error),
                contextlib.redirect_stdout(logged),
            ):
                with self.assertRaises(type(error)) as caught:
                    with subject.bootstrap_response("release_metadata", "PRIVATE_URL", timeout=20):
                        self.fail("refused request yielded")
            self.assertIs(caught.exception, error)
            if isinstance(error, ChangingCode):
                self.assertEqual(error.reads, 1)
                self.facts(logged.getvalue(), "release_metadata", "http_error", 403)
            else:
                self.assertEqual(logged.getvalue(), "")

    def test_diagnostic_write_refusal_never_replaces_original_network_error(self):
        from urllib.error import HTTPError

        for refusal in (OSError("PRIVATE_MESSAGE"), RuntimeError("PRIVATE_BODY"), False, None):
            with self.subTest(refusal=type(refusal).__name__):
                error = HTTPError("PRIVATE_URL", 429, "PRIVATE_MESSAGE", None, None)
                options = (
                    {"side_effect": refusal}
                    if isinstance(refusal, Exception)
                    else {"return_value": refusal}
                )
                with (
                    mock.patch.object(subject, "urlopen", side_effect=error),
                    mock.patch("builtins.print", **options),
                ):
                    with self.assertRaises(HTTPError) as caught:
                        with subject.bootstrap_response(
                            "archive_download", "PRIVATE_URL", timeout=30
                        ):
                            self.fail("refused request yielded")
                self.assertIs(caught.exception, error)

    def test_diagnostic_cancellation_is_not_swallowed(self):
        from urllib.error import HTTPError

        for cancellation in (KeyboardInterrupt(), SystemExit(73)):
            with self.subTest(cancellation=type(cancellation).__name__):
                error = HTTPError("PRIVATE_URL", 403, "PRIVATE_MESSAGE", None, None)
                with (
                    mock.patch.object(subject, "urlopen", side_effect=error),
                    mock.patch("builtins.print", side_effect=cancellation),
                ):
                    with self.assertRaises(type(cancellation)) as caught:
                        with subject.bootstrap_response(
                            "release_metadata", "PRIVATE_URL", timeout=20
                        ):
                            self.fail("refused request yielded")
                self.assertIs(caught.exception, cancellation)

    def test_successful_metadata_preserves_exact_bound_and_archive_validation_inputs(self):
        import contextlib
        import io

        asset = {
            "name": "Hammerspoon-1.1.1.zip",
            "digest": "sha256:" + "f" * 64,
            "size": 1024,
            "browser_download_url": "https://github.com/Hammerspoon/hammerspoon/releases/download/1.1.1/Hammerspoon-1.1.1.zip",
        }
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps({"tag_name": "1.1.1", "assets": [asset]}).encode()
        logged = io.StringIO()
        with (
            mock.patch.object(subject, "urlopen", return_value=response) as opening,
            contextlib.redirect_stdout(logged),
        ):
            self.assertEqual(subject.trusted_asset(Path("unused")), asset)
        self.assertEqual(logged.getvalue(), "")
        response.read.assert_called_once_with(1048577)
        response.__exit__.assert_called_once_with(None, None, None)
        self.assertEqual(opening.call_args.kwargs, {"timeout": 20})

    def test_unknown_phase_refuses_before_request_or_diagnostic(self):
        for phase in (None, True, "PRIVATE_BODY", "metadata", ""):
            with (
                mock.patch.object(subject, "urlopen") as opening,
                mock.patch("builtins.print") as log,
            ):
                with self.assertRaises(ValueError):
                    with subject.bootstrap_response(phase, "PRIVATE_URL", timeout=20):
                        self.fail("foreign phase yielded")
                opening.assert_not_called()
                log.assert_not_called()


class MetadataAuthenticationControls(unittest.TestCase):
    TOKEN = "ghs_INDEPENDENT_PRIVATE_CREDENTIAL"

    def asset(self):
        return {
            "name": "Hammerspoon-1.1.1.zip",
            "digest": "sha256:" + "f" * 64,
            "size": 1024,
            "browser_download_url": "https://github.com/Hammerspoon/hammerspoon/releases/download/1.1.1/Hammerspoon-1.1.1.zip",
        }

    def reply(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps(
            {"tag_name": "1.1.1", "assets": [self.asset()]}
        ).encode()
        return response

    def test_actual_metadata_authentication_changes_controlled_403_to_valid_asset(self):
        from urllib.error import HTTPError
        from types import SimpleNamespace

        seen = []

        def api(request, *, timeout):
            seen.append(request)
            self.assertEqual(
                request.full_url,
                "https://api.github.com/repos/Hammerspoon/hammerspoon/releases/tags/1.1.1",
            )
            self.assertEqual(timeout, 20)
            if request.get_header("Authorization") != "Bearer " + self.TOKEN:
                raise HTTPError(request.full_url, 403, "PRIVATE_BODY", None, None)
            return self.reply()

        with (
            mock.patch.object(subject, "build_opener", return_value=SimpleNamespace(open=api)),
            mock.patch.object(subject, "urlopen", side_effect=AssertionError("anonymous fallback")),
        ):
            self.assertEqual(
                subject.trusted_asset(Path("unused"), metadata_token=self.TOKEN), self.asset()
            )
        self.assertEqual(len(seen), 1)
        self.assertIsNone(seen[0].data)

    def test_authenticated_401_and_403_preserve_exception_without_fallback_or_secret(self):
        import contextlib
        import io
        from types import SimpleNamespace
        from urllib.error import HTTPError

        for status in (401, 403):
            error = HTTPError(
                "PRIVATE_URL", status, self.TOKEN, {"Authorization": self.TOKEN}, None
            )
            log = io.StringIO()
            opening = mock.Mock(side_effect=error)
            with (
                mock.patch.object(
                    subject, "build_opener", return_value=SimpleNamespace(open=opening)
                ),
                mock.patch.object(subject, "urlopen") as anonymous,
                contextlib.redirect_stdout(log),
            ):
                with self.assertRaises(HTTPError) as caught:
                    subject.trusted_asset(Path("unused"), metadata_token=self.TOKEN)
            self.assertIs(caught.exception, error)
            anonymous.assert_not_called()
            opening.assert_called_once()
            self.assertEqual(json.loads(log.getvalue())["http_status"], status)
            for private in (self.TOKEN, "Authorization", "PRIVATE_URL"):
                self.assertNotIn(private, log.getvalue())

    def test_redirects_are_refused_without_forwarding_any_credential(self):
        from urllib.error import HTTPError
        from urllib.request import Request, build_opener
        from email.message import Message

        handler = subject.MetadataNoRedirect()
        opener = build_opener(handler)
        request = Request(
            "https://api.github.com/repos/Hammerspoon/hammerspoon/releases/tags/1.1.1",
            headers={"Authorization": "Bearer " + self.TOKEN},
        )
        for target in ("https://api.github.com/other", "https://foreign.invalid/secret"):
            for code in (301, 302, 303, 307, 308):
                headers = Message()
                headers["Location"] = target
                with self.assertRaises(HTTPError) as caught:
                    opener.error("http", request, mock.Mock(), code, "redirect", headers)
                self.assertEqual(caught.exception.code, code)
        self.assertIsNone(
            handler.redirect_request(request, None, 302, "redirect", {}, "https://foreign.invalid")
        )

    def test_authenticated_opener_preserves_default_tls_and_installs_only_redirect_refusal(self):
        from types import SimpleNamespace

        with mock.patch.object(
            subject, "build_opener", return_value=SimpleNamespace(open=lambda *a, **k: self.reply())
        ) as building:
            subject.trusted_asset(Path("unused"), metadata_token=self.TOKEN)
        self.assertEqual(len(building.call_args.args), 1)
        self.assertIsInstance(building.call_args.args[0], subject.MetadataNoRedirect)
        self.assertEqual(building.call_args.kwargs, {})

    def test_foreign_metadata_route_refuses_before_authenticated_request(self):
        with (
            mock.patch.object(subject, "API", "https://foreign.invalid"),
            mock.patch.object(subject, "build_opener") as building,
            mock.patch.object(subject, "urlopen") as opening,
        ):
            with self.assertRaisesRegex(ValueError, "^metadata_route_refused$"):
                subject.trusted_asset(Path("unused"), metadata_token=self.TOKEN)
        building.assert_not_called()
        opening.assert_not_called()

    def test_malformed_supplied_tokens_refuse_closed_without_request(self):
        for token in ("", "a b", "a\nPRIVATE", "é", "x" * 4097, True, 3, [], "a=b"):
            with (
                mock.patch.object(subject, "build_opener") as building,
                mock.patch.object(subject, "urlopen") as opening,
            ):
                with self.assertRaisesRegex(ValueError, "^metadata_token_refused$"):
                    subject.trusted_asset(Path("unused"), metadata_token=token)
            building.assert_not_called()
            opening.assert_not_called()
        self.assertIsNone(subject.validate_metadata_token(None))
        self.assertEqual(subject.validate_metadata_token(self.TOKEN), self.TOKEN)

    def test_archive_after_authenticated_metadata_has_no_authorization(self):
        from types import SimpleNamespace

        with (
            mock.patch.object(
                subject,
                "build_opener",
                return_value=SimpleNamespace(open=lambda *a, **k: self.reply()),
            ),
            mock.patch.object(subject, "urlopen", return_value=self.reply()) as archive,
        ):
            asset = subject.trusted_asset(Path("unused"), metadata_token=self.TOKEN)
            with subject.bootstrap_response(
                "archive_download", asset["browser_download_url"], timeout=30
            ):
                pass
        self.assertEqual(
            archive.call_args.args,
            (
                "https://github.com/Hammerspoon/hammerspoon/releases/download/1.1.1/Hammerspoon-1.1.1.zip",
            ),
        )
        self.assertEqual(archive.call_args.kwargs, {"timeout": 30})

    def test_inventory_entry_scrubs_token_before_platform_refusal(self):
        import os

        with (
            mock.patch.dict(os.environ, {"ERGOPTI_NATIVE_HS_METADATA_TOKEN": self.TOKEN}),
            mock.patch.object(
                subject.sys,
                "argv",
                ["probe", "--source-root", ".", "--source-sha", "a" * 40, "--output", "."],
            ),
            mock.patch.object(subject.sys, "platform", "linux"),
            mock.patch.object(subject, "source_hashes") as git,
            mock.patch.object(subject.importlib.util, "spec_from_file_location") as allocation,
        ):
            with self.assertRaisesRegex(ValueError, "native_python_prerequisite_refused"):
                subject.main()
            self.assertNotIn("ERGOPTI_NATIVE_HS_METADATA_TOKEN", os.environ)
        git.assert_not_called()
        allocation.assert_not_called()

    def test_inventory_malformed_entry_consumes_token_before_any_allocation(self):
        import os

        with (
            mock.patch.dict(os.environ, {"ERGOPTI_NATIVE_HS_METADATA_TOKEN": "PRIVATE\nTOKEN"}),
            mock.patch.object(subject, "source_hashes") as git,
            mock.patch.object(subject.importlib.util, "spec_from_file_location") as allocation,
        ):
            with self.assertRaisesRegex(ValueError, "^metadata_token_refused$"):
                subject.main()
            self.assertNotIn("ERGOPTI_NATIVE_HS_METADATA_TOKEN", os.environ)
        git.assert_not_called()
        allocation.assert_not_called()

    def test_anonymous_local_metadata_retains_original_urlopen_seam(self):
        with (
            mock.patch.object(subject, "urlopen", return_value=self.reply()) as opening,
            mock.patch.object(subject, "build_opener") as auth,
        ):
            self.assertEqual(subject.trusted_asset(Path("unused")), self.asset())
        auth.assert_not_called()
        request = opening.call_args.args[0]
        self.assertIsNone(request.get_header("Authorization"))
        self.assertEqual(opening.call_args.kwargs, {"timeout": 20})


class NativeEntryTokenBoundary(unittest.TestCase):
    def test_consumption_precedes_native_constructor_and_git_source_checks(self):
        import os
        from types import SimpleNamespace

        error = RuntimeError("CONTROLLED_CONSTRUCTOR_BOUNDARY")

        def construct():
            self.assertNotIn("ERGOPTI_NATIVE_HS_METADATA_TOKEN", os.environ)
            raise error

        owner = SimpleNamespace(NativeProcessGroups=construct, OwnedProcessInterrupted=RuntimeError)
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))
        with (
            mock.patch.dict(os.environ, {"ERGOPTI_NATIVE_HS_METADATA_TOKEN": "ghs_PRIVATE"}),
            mock.patch.object(
                subject.sys,
                "argv",
                ["probe", "--source-root", ".", "--source-sha", "a" * 40, "--output", "."],
            ),
            mock.patch.object(subject.sys, "platform", "darwin"),
            mock.patch.object(subject.sys, "version_info", (3, 13)),
            mock.patch.object(subject.importlib.util, "spec_from_file_location", return_value=spec),
            mock.patch.object(subject.importlib.util, "module_from_spec", return_value=owner),
            mock.patch.object(subject.signal, "signal"),
            mock.patch.object(subject, "source_hashes") as git,
        ):
            with self.assertRaises(RuntimeError) as caught:
                subject.main()
            self.assertIs(caught.exception, error)
        git.assert_not_called()


if __name__ == "__main__":
    unittest.main()
