# tools/build/remap_runtime_source_controls_test.py
"""Portable receipt/closure refusals; native AUTH leaves are never qualified here."""

import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "owned_auth_source_controls", Path(__file__).with_name("remap_runtime_build.py")
)
SUBJECT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUBJECT
SPEC.loader.exec_module(SUBJECT)

COMPANIONS = (
    (
        "tools/build/remap_runtime_auth_transport_test.py",
        "958eec8bc543db610956601a39f9074cd9926d18da1339e3c1de069f605d6481",
    ),
    (
        "tools/build/remap_runtime_auth_test.py",
        "0093ec937550298fed3aaee2f4faf5b11c5fbb898926bb60f8b2ded0407fa42a",
    ),
    (
        "tools/build/remap_runtime_auth_hs274_test.py",
        "02ecfacf75406969eba420f20f8344c228ebf1e79c017d63c71b4260e068a082",
    ),
    (
        "tools/build/fixtures/remap_runtime_auth_policy26.json",
        "ef999db672cf22e5dff512c418826bfc3a13ea2ac0581b0a070803a2de1a003a",
    ),
    (
        "tools/build/fixtures/remap_runtime_auth_hs27422.json",
        "3581dbbe0af267a44d6544a06e0ec25279c0ae9d68660537517cfb91b994b2dc",
    ),
)
PHASES = (
    "acquisition",
    "checkout",
    "submodules",
    "identity_upstream",
    "identity_cpm",
    "identity_vhd",
    "source_clean",
    "auth_transport21",
    "auth_policy26",
    "auth_hs27422",
)
AUTH_STDERR = "." * 21 + "\n" + "-" * 70 + "\nRan 21 tests in 61.868s\n\nOK\n"
PASS = "PASS owned AUTH source controls=21 policy=26 hs274=22; native authentication unqualified\n"
POLICY_HASH = "ae249b8c9d410a8629ceca19442c6c5c293d5b5a427a11771b8f83350f42ed50"


def policy(count):
    return {
        "qualification": "PORTABLE_LITERAL_POLICY_ONLY",
        "native_executed": 0,
        "oracle_sha256": dict(COMPANIONS)[
            "tools/build/fixtures/remap_runtime_auth_"
            + ("policy26" if count == 26 else "hs27422")
            + ".json"
        ],
        "policy_sha256": POLICY_HASH,
        "adapter": {"ordinary_supported_request": "frontmost_application_changed"},
        "receipts": [
            {
                "mode": mode,
                "compile_exit": 0,
                "run_exit": 0,
                "literal_policy_cases": count,
                "native_executed": 0,
            }
            for mode in ("unoptimized", "optimized")
        ],
    }


def record():
    return {
        "schema": 1,
        "status": "passed",
        "qualification": "portable_owned_auth_source_controls_on_genuine_pristine",
        "budget_seconds": 300,
        "pins": {
            "upstream": "9312593e1a3bf72b94c63c524ebabe2637442e8a",
            "cpm": "6a8b2d64b993746d489432b45455e33b7fb8e09f",
            "vhd": "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb",
        },
        "source_inventory_entries": 4505,
        "companions": [{"path": p, "sha256": h} for p, h in COMPANIONS],
        "phases": [
            {"schema": 1, "phase": p, "status": "passed", "exit_status": 0, "elapsed_seconds": 0.01}
            for p in PHASES
        ],
        "controls": [
            {"name": n, "tests": c, "failures": 0, "errors": 0, "skipped": 0, "native_executed": 0}
            for n, c in (("auth_transport21", 21), ("auth_policy26", 26), ("auth_hs27422", 22))
        ],
        "native_compilation_executed": False,
        "native_capture_executed": False,
        "installation_executed": False,
        "signing_executed": False,
        "auth_executed": False,
    }


class SourceControls(unittest.TestCase):
    def refusal(self, call):
        with self.assertRaises(SUBJECT.BASE.NativeBuildError):
            call()

    def test_actual_auth_summary_has_exact_count_and_no_native_output(self):
        self.assertIsNone(SUBJECT.auth_source_output(0, "", AUTH_STDERR))

    def test_auth_failed_child_cannot_be_replaced_by_healthy_metadata(self):
        for status in (1, True, -9):
            self.refusal(lambda: SUBJECT.auth_source_output(status, "", AUTH_STDERR))

    def test_auth_count_failures_errors_and_skips_refuse(self):
        for text in (
            AUTH_STDERR.replace("Ran 21", "Ran 20"),
            AUTH_STDERR.replace("OK", "OK (skipped=1)"),
            AUTH_STDERR.replace("OK", "FAILED (failures=1)"),
            AUTH_STDERR.replace("OK", "FAILED (errors=1)"),
            AUTH_STDERR.replace(".", "s", 1),
        ):
            self.refusal(lambda: SUBJECT.auth_source_output(0, "", text))

    def test_auth_extra_stdout_or_stderr_refuses(self):
        self.refusal(lambda: SUBJECT.auth_source_output(0, "PASS\n", AUTH_STDERR))
        for text in ("warning\n" + AUTH_STDERR, AUTH_STDERR + "warning\n", AUTH_STDERR.rstrip()):
            self.refusal(lambda: SUBJECT.auth_source_output(0, "", text))

    def test_auth_elapsed_is_finite_bounded(self):
        for value in ("nan", "inf", "301.0", "-1.0", "1e999", "9" * 400):
            self.refusal(
                lambda: SUBJECT.auth_source_output(0, "", AUTH_STDERR.replace("61.868", value))
            )

    def test_policy_two_real_modes_accept_exact_frozen_counts(self):
        for count in (26, 22):
            r = policy(count)
            self.assertIsNone(
                SUBJECT.policy_source_output(
                    0, json.dumps(r), "", r, count, r["oracle_sha256"], POLICY_HASH
                )
            )

    def test_policy_failed_child_cannot_be_replaced_by_saved_receipt(self):
        r = policy(26)
        self.refusal(
            lambda: SUBJECT.policy_source_output(
                1, json.dumps(r), "", r, 26, r["oracle_sha256"], POLICY_HASH
            )
        )

    def test_policy_compile_run_count_and_native_claims_refuse(self):
        for field, value in (
            ("compile_exit", 1),
            ("run_exit", 1),
            ("literal_policy_cases", 25),
            ("native_executed", 1),
            ("compile_exit", False),
        ):
            r = policy(26)
            r["receipts"][0][field] = value
            self.refusal(
                lambda: SUBJECT.policy_source_output(
                    0, json.dumps(r), "", r, 26, r["oracle_sha256"], POLICY_HASH
                )
            )

    def test_policy_missing_duplicate_or_reordered_modes_refuse(self):
        for modes in (
            ("unoptimized",),
            ("optimized", "unoptimized"),
            ("unoptimized", "unoptimized"),
        ):
            r = policy(26)
            r["receipts"] = [{**policy(26)["receipts"][0], "mode": mode} for mode in modes]
            self.refusal(
                lambda: SUBJECT.policy_source_output(
                    0, json.dumps(r), "", r, 26, r["oracle_sha256"], POLICY_HASH
                )
            )

    def test_policy_corpus_source_and_adapter_refuse_mismatch(self):
        for key, value in (
            ("oracle_sha256", "0" * 64),
            ("policy_sha256", "0" * 64),
            ("adapter", {}),
            ("native_executed", False),
            ("extra", True),
        ):
            r = policy(26)
            r[key] = value
            self.refusal(
                lambda: SUBJECT.policy_source_output(
                    0, json.dumps(r), "", r, 26, policy(26)["oracle_sha256"], POLICY_HASH
                )
            )

    def test_policy_stdout_matches_actual_retained_result(self):
        r = policy(26)
        self.refusal(
            lambda: SUBJECT.policy_source_output(
                0, json.dumps(policy(22)), "", r, 26, r["oracle_sha256"], POLICY_HASH
            )
        )
        self.refusal(
            lambda: SUBJECT.policy_source_output(
                0, json.dumps(r), "warning", r, 26, r["oracle_sha256"], POLICY_HASH
            )
        )

    def test_duplicate_json_key_cannot_override_failure(self):
        self.refusal(lambda: SUBJECT.parse_json(b'{"status":"refused","status":"passed"}'))

    def test_exact_closed_source_record_has_no_native_authority(self):
        self.assertIsNone(SUBJECT.validate_source_controls_record(record()))

    def test_source_record_rejects_phase_missing_reorder_and_extra(self):
        for phases in (
            record()["phases"][:-1],
            list(reversed(record()["phases"])),
            record()["phases"] + [record()["phases"][0]],
        ):
            r = record()
            r["phases"] = phases
            self.refusal(lambda: SUBJECT.validate_source_controls_record(r))

    def test_phase_status_exit_and_elapsed_are_strict(self):
        for field, value in (
            ("status", "refused"),
            ("exit_status", 1),
            ("exit_status", False),
            ("schema", True),
            ("elapsed_seconds", True),
            ("elapsed_seconds", 10**400),
        ):
            r = record()
            r["phases"][0][field] = value
            self.refusal(lambda: SUBJECT.validate_source_controls_record(r))

    def test_source_record_counts_failures_and_authority_are_closed(self):
        for key, value in (
            ("tests", 20),
            ("failures", 1),
            ("errors", 1),
            ("skipped", 1),
            ("native_executed", 1),
            ("failures", False),
        ):
            r = record()
            r["controls"][0][key] = value
            self.refusal(lambda: SUBJECT.validate_source_controls_record(r))
        for key in (
            "auth_executed",
            "native_capture_executed",
            "native_compilation_executed",
            "installation_executed",
            "signing_executed",
        ):
            r = record()
            r[key] = True
            self.refusal(lambda: SUBJECT.validate_source_controls_record(r))

    def test_source_record_current_pin_companion_and_fields_are_fixed(self):
        for edit in (
            lambda r: r["pins"].update(upstream="0" * 40),
            lambda r: r["companions"][0].update(sha256="0" * 64),
            lambda r: r.update(extra=True),
            lambda r: r.update(source_inventory_entries=4504),
        ):
            r = record()
            edit(r)
            self.refusal(lambda: SUBJECT.validate_source_controls_record(r))

    def test_genuine_process_gate_precedes_final_receipt_parser(self):
        self.assertIsNone(SUBJECT.source_controls_output(0, PASS, ""))
        for status, stdout, stderr in (
            (1, PASS, ""),
            (True, PASS, ""),
            (0, PASS + PASS, ""),
            (0, PASS, "warning"),
            (0, PASS.rstrip(), ""),
        ):
            self.refusal(lambda: SUBJECT.source_controls_output(status, stdout, stderr))

    def test_bad_budget_refuses_before_any_acquisition_or_source_read(self):
        with patch.object(SUBJECT, "_source_factory", side_effect=AssertionError("source read")):
            for budget in (True, 300.0, 299, 301):
                self.refusal(
                    lambda: SUBJECT.source_controls(Path("/absent"), Path("/absent"), budget)
                )

    def test_foreign_owner_is_preserved_before_acquisition(self):
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary).resolve()
            owner.chmod(0o700)
            sentinel = owner / "foreign"
            sentinel.write_bytes(b"unchanged\n")
            with patch.object(
                SUBJECT, "_source_factory", side_effect=AssertionError("source read")
            ):
                self.refusal(lambda: SUBJECT.source_controls(Path("/absent"), owner, 300))
            self.assertEqual(sentinel.read_bytes(), b"unchanged\n")

    def test_cli_conflicts_and_external_pristine_refuse_before_source_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary).resolve()
            owner.chmod(0o700)
            for extra in (
                ("--ready",),
                ("--compile-owned",),
                ("--preflight",),
                ("--upstream", str(owner)),
                ("--observe-products", str(owner)),
            ):
                with (
                    patch.object(
                        SUBJECT, "source_controls", side_effect=AssertionError("source run")
                    ),
                    redirect_stdout(io.StringIO()),
                    redirect_stderr(io.StringIO()),
                ):
                    self.assertEqual(
                        SUBJECT.main([str(owner), str(owner), "--source-controls", *extra]), 1
                    )

    def test_actual_retained_companion_file_change_is_not_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary).resolve()
            owner.chmod(0o700)
            file = owner / "literal.json"
            file.write_bytes(b'{"counter":3}\n')
            deadline = time.monotonic() + 5
            retained = SUBJECT.snapshot_inputs(
                owner, {"literal.json": SUBJECT.BASE.digest(file.read_bytes())}, deadline
            )
            file.write_bytes(b'{"counter":999}\n')
            self.refusal(lambda: SUBJECT.current_inputs(retained, deadline))


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(
        "PASS" if result.wasSuccessful() else "FAIL",
        "portable owned AUTH source-controls tests=" + str(result.testsRun),
        "failures=" + str(len(result.failures)),
        "errors=" + str(len(result.errors)),
        "skipped=" + str(len(result.skipped)),
    )
    raise SystemExit(
        0 if result.wasSuccessful() and result.testsRun == 22 and not result.skipped else 1
    )
