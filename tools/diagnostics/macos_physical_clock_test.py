# tools/diagnostics/macos_physical_clock_test.py
"""Independent parser, filesystem and hosted-clock supervisor refusal controls."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
FACTS = {
    "current_before": True,
    "wrong_owner_denied": True,
    "wrong_token_denied": True,
    "duplicate_bind_refused": True,
    "detached": True,
    "retired_after_detach": True,
    "read_after_detach_denied": True,
    "getter_unchanged": True,
    "successor_distinct": True,
    "successor_current": True,
    "successor_detached": True,
    "successor_retired": True,
}
EXPECTED = {"pid": 42, "version": "1.1.1", "nonce": "independent-source-nonce"}
BRACKET = {
    "before": {"ticks": 120000000, "numer": 125, "denom": 3},
    "after": {"ticks": 120000100, "numer": 125, "denom": 3},
}
HEALTHY = {
    "schema": 1,
    "status": "ok",
    "runtime": "native Hammerspoon",
    "version": "1.1.1",
    "pid": 42,
    "nonce": "independent-source-nonce",
    "getter_what": "C",
    "binding_scope": "borrowed hs.timer.absoluteTime API only",
    "samples": [
        {"phase": "legacy_before", "ns": "5000000001"},
        {"phase": "bound_read", "ns": "5000000002"},
        {"phase": "bound_now", "ns": "5000000003"},
        {"phase": "legacy_after_detach", "ns": "5000000004"},
        {"phase": "successor_read", "ns": "5000000005"},
    ],
    "facts": FACTS,
}
OWNER = {
    "worker_pid": 42,
    "group_id": 42,
    "closed": True,
    "reservation_lost": False,
    "signals": [15],
    "live_group_members": [],
    "escaped_sessions_managed": False,
}


class HostedClockControls(unittest.TestCase):
    """Keep all expected observations independent of the new controller."""

    def setUp(self):
        specification = importlib.util.spec_from_file_location(
            "independent_hosted_clock", HERE / "macos_physical_clock.py"
        )
        self.controller = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(self.controller)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.path = self.root / "result.json"

    def receipt(self):
        return copy.deepcopy(HEALTHY)

    def validate(self, packet=None, bracket=None):
        return self.controller.validate_receipt(
            self.receipt() if packet is None else packet,
            EXPECTED,
            BRACKET if bracket is None else bracket,
        )

    def observe(self, group=None, *, now=None, changed=None, mach=None):
        if group is None:
            group = mock.Mock()
            group.observe_exit.return_value = None
        if mach is None:
            mach = mock.Mock()
            mach.sample.return_value = BRACKET["after"]
        return self.controller.observe(
            group,
            self.path,
            EXPECTED,
            BRACKET["before"],
            mach,
            changed or (lambda: None),
            10,
            now=now or (lambda: 1),
            pause=lambda _delay: None,
        )

    def test_valid_nontrivial_timebase_is_recomputed_independently(self):
        self.assertEqual(self.validate(), self.receipt())

    def test_boolean_pid_schema_and_foreign_runtime_are_refused(self):
        for key, value in (
            ("pid", True),
            ("pid", 43),
            ("pid", 42.0),
            ("schema", True),
            ("schema", 2),
            ("runtime", "stub Hammerspoon"),
            ("version", "1.1.2"),
        ):
            with self.subTest(key=key, value=value):
                packet = self.receipt()
                packet[key] = value
                with self.assertRaises(ValueError):
                    self.validate(packet)

    def test_missing_extra_and_foreign_nonce_are_refused(self):
        for packet in [dict(self.receipt(), extra=0), dict(self.receipt(), nonce="old"), {}]:
            with self.assertRaises(ValueError):
                self.validate(packet)
        packet = self.receipt()
        del packet["getter_what"]
        with self.assertRaises(ValueError):
            self.validate(packet)

    def test_lua_getter_and_native_domain_token_claim_are_refused(self):
        for key, value in [("getter_what", "Lua"), ("binding_scope", "native boot domain")]:
            packet = self.receipt()
            packet[key] = value
            with self.assertRaises(ValueError):
                self.validate(packet)

    def test_facts_require_literal_true_and_closed_fields(self):
        for key in FACTS:
            for value in [False, None, 1, "true"]:
                packet = self.receipt()
                packet["facts"][key] = value
                with self.subTest(key=key, value=value):
                    with self.assertRaises(ValueError):
                        self.validate(packet)
        packet = self.receipt()
        packet["facts"]["domain_qualified"] = True
        with self.assertRaises(ValueError):
            self.validate(packet)

    def test_wrong_sample_count_phase_and_shape_are_refused(self):
        packets = []
        packet = self.receipt()
        packet["samples"].pop()
        packets.append(packet)
        packet = self.receipt()
        packet["samples"][0]["phase"] = "replacement"
        packets.append(packet)
        packet = self.receipt()
        packet["samples"][0]["extra"] = 1
        packets.append(packet)
        for packet in packets:
            with self.assertRaises(ValueError):
                self.validate(packet)

    def test_lossy_or_noncanonical_nanoseconds_are_refused(self):
        for value in [
            5000000001,
            5000000001.0,
            True,
            "05000000001",
            "+5000000001",
            "5e9",
            "5000000001.0",
            "-1",
            "9223372036854775808",
        ]:
            packet = self.receipt()
            packet["samples"][0]["ns"] = value
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    self.validate(packet)

    def test_samples_outside_native_parent_bracket_are_refused(self):
        for value in ["4999999999", "5000004167", "120000001"]:
            packet = self.receipt()
            packet["samples"][0]["ns"] = value
            with self.assertRaises(ValueError):
                self.validate(packet)

    def test_unordered_or_repeated_native_samples_are_refused(self):
        packet = self.receipt()
        packet["samples"][1]["ns"] = "5000000001"
        with self.assertRaises(ValueError):
            self.validate(packet)
        packet["samples"][1]["ns"] = "5000000000"
        with self.assertRaises(ValueError):
            self.validate(packet)

    def test_native_timebase_must_be_positive_integral_and_stable(self):
        for field, value in [
            ("numer", 0),
            ("denom", 0),
            ("numer", True),
            ("denom", 3.0),
            ("numer", 4294967296),
        ]:
            bracket = copy.deepcopy(BRACKET)
            bracket["before"][field] = value
            with self.assertRaises(ValueError):
                self.validate(bracket=bracket)
        bracket = copy.deepcopy(BRACKET)
        bracket["after"]["denom"] = 1
        with self.assertRaises(ValueError):
            self.validate(bracket=bracket)

    def test_negative_backward_and_overflowing_mach_ticks_are_refused(self):
        for value in [-1, True, 18446744073709551616, 18446744073709551615]:
            bracket = copy.deepcopy(BRACKET)
            bracket["before"]["ticks"] = value
            with self.assertRaises(ValueError):
                self.validate(bracket=bracket)
        bracket = copy.deepcopy(BRACKET)
        bracket["after"]["ticks"] = 119999999
        with self.assertRaises(ValueError):
            self.validate(bracket=bracket)

    def test_ordinary_private_receipt_and_duplicate_json_keys(self):
        self.path.write_text(json.dumps(self.receipt()), encoding="utf-8")
        self.assertEqual(self.controller.read_receipt(self.path), self.receipt())
        for body in ['{"schema":0,"schema":1}', '{"pid":0,"\\u0070id":42}', "{", "null"]:
            self.path.write_text(body, encoding="utf-8")
            with self.assertRaises(ValueError):
                self.controller.read_receipt(self.path)

    def test_symlink_receipt_is_refused(self):
        ordinary = self.root / "ordinary.json"
        ordinary.write_text("{}")
        self.path.symlink_to(ordinary)
        with self.assertRaises((ValueError, OSError)):
            self.controller.read_receipt(self.path)

    def test_parent_directory_redirect_is_refused(self):
        link = self.root / "redirect"
        link.symlink_to(self.root, target_is_directory=True)
        self.path.write_text("{}")
        with self.assertRaises((ValueError, OSError)):
            self.controller.read_receipt(link / "result.json")

    def test_fifo_receipt_is_refused_without_blocking(self):
        os.mkfifo(self.path, 0o600)
        with self.assertRaises((ValueError, OSError)):
            self.controller.read_receipt(self.path)

    def test_oversized_result_is_refused_before_json_decode(self):
        self.path.write_bytes(b" " * 16385)
        with mock.patch.object(
            self.controller.json,
            "loads",
            side_effect=AssertionError("Do not decode oversized bytes"),
        ):
            with self.assertRaises(ValueError):
                self.controller.read_receipt(self.path)

    def test_wrong_file_owner_is_refused(self):
        self.path.write_text("{}")
        original = os.fstat

        def foreign(descriptor):
            fields = list(original(descriptor))
            fields[4] = os.geteuid() + 1
            return os.stat_result(fields)

        with mock.patch.object(self.controller.os, "fstat", side_effect=foreign):
            with self.assertRaises(ValueError):
                self.controller.read_receipt(self.path)

    def test_native_exit_before_result_is_refused(self):
        self.path.write_text(json.dumps(self.receipt()))
        group = mock.Mock()
        group.observe_exit.return_value = object()
        with self.assertRaises(ValueError):
            self.observe(group)

    def test_native_exit_after_result_cannot_qualify_the_interval(self):
        self.path.write_text(json.dumps(self.receipt()))
        group = mock.Mock()
        group.observe_exit.side_effect = [None, object()]
        with self.assertRaises(ValueError):
            self.observe(group)

    def test_expired_deadline_refuses_even_an_existing_healthy_receipt(self):
        self.path.write_text(json.dumps(self.receipt()))
        with self.assertRaises(ValueError):
            self.observe(now=lambda: 10)

    def test_missing_receipt_reaches_finite_native_deadline(self):
        moments = iter([1, 2, 10])
        with self.assertRaises(ValueError):
            self.observe(now=lambda: next(moments))

    def test_production_source_drift_is_refused(self):
        self.path.write_text(json.dumps(self.receipt()))
        with self.assertRaises(RuntimeError):
            self.observe(changed=mock.Mock(side_effect=RuntimeError("drift")))

    def test_healthy_live_exact_source_and_parent_clock_are_accepted(self):
        self.path.write_text(json.dumps(self.receipt()))
        mach, changed = mock.Mock(), mock.Mock()
        mach.sample.return_value = BRACKET["after"]
        self.assertEqual(self.observe(changed=changed, mach=mach)["native_result"], self.receipt())
        mach.sample.assert_called_once_with()
        changed.assert_called_once_with()

    def test_budget_rejects_bool_float_zero_and_any_sdk_extension(self):
        self.assertEqual(self.controller.validate_budget(25), 25)
        for value in [True, 25.0, 0, -1, 26, 240, 300]:
            with self.assertRaises(ValueError):
                self.controller.validate_budget(value)

    def test_native_owner_requires_exact_closed_inherited_group(self):
        report = {"status": "ok", "native_owner": copy.deepcopy(OWNER)}
        self.controller.validate_owner(report, 42)
        for key, value in [
            ("closed", False),
            ("closed", 1),
            ("reservation_lost", True),
            ("worker_pid", 43),
            ("group_id", 43),
            ("live_group_members", [43]),
            ("escaped_sessions_managed", True),
        ]:
            packet = copy.deepcopy(report)
            packet["native_owner"][key] = value
            with self.assertRaises(ValueError):
                self.controller.validate_owner(packet, 42)
        with self.assertRaises(ValueError):
            self.controller.validate_owner(dict(report, status="error"), 42)

    def test_native_platform_refuses_before_network_output_or_spawn(self):
        with (
            mock.patch.object(self.controller.sys, "platform", "linux"),
            mock.patch.object(
                self.controller.subprocess, "run", side_effect=AssertionError("No foreign command")
            ),
        ):
            with self.assertRaises(ValueError):
                self.controller.run(self.root, self.root, 25)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_clock_error_and_changed_scale_are_not_fake_domain_qualification(self):
        self.path.write_text(json.dumps(self.receipt()))
        mach = mock.Mock()
        mach.sample.side_effect = RuntimeError("Actual Mach query failed")
        with self.assertRaises(RuntimeError):
            self.observe(mach=mach)
        mach.sample.side_effect = None
        mach.sample.return_value = {"ticks": 120000100, "numer": 1, "denom": 1}
        with self.assertRaises(ValueError):
            self.observe(mach=mach)

    def test_signature_version_failure_precedes_foreign_verification(self):
        import plistlib

        app = self.root / "Hammerspoon.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/Hammerspoon"
        executable.write_bytes(b"fake-not-native")
        executable.chmod(0o700)
        (app / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleShortVersionString": "1.1.2"})
        )
        with mock.patch.object(
            self.controller.subprocess,
            "run",
            side_effect=AssertionError("No signature command on wrong version"),
        ):
            with self.assertRaises(ValueError):
                self.controller.admit_runtime(app, "1.1.1", 10)

    def test_archive_bytes_require_the_existing_qualified_checksum(self):
        archive = self.root / "archive.zip"
        archive.write_bytes(b"abc")
        known = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        self.controller.verify_archive(archive, known)
        with self.assertRaises(ValueError):
            self.controller.verify_archive(
                archive, "11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa"
            )

    def test_foreign_commands_inherit_remaining_absolute_deadline(self):
        completed = subprocess.CompletedProcess(["fixture"], 0, b"", b"")
        with (
            mock.patch.object(self.controller.time, "monotonic", return_value=1),
            mock.patch.object(
                self.controller.subprocess, "run", return_value=completed
            ) as operation,
        ):
            self.controller.command(["fixture"], 4, 10)
            self.assertGreater(operation.call_args.kwargs["timeout"], 0)
            self.assertLessEqual(operation.call_args.kwargs["timeout"], 3)
        with (
            mock.patch.object(self.controller.time, "monotonic", return_value=4),
            mock.patch.object(
                self.controller.subprocess,
                "run",
                side_effect=AssertionError("Do not start at expired deadline"),
            ),
        ):
            with self.assertRaises(ValueError):
                self.controller.command(["fixture"], 4, 10)

    def test_foreign_command_error_or_timeout_is_not_qualified(self):
        with mock.patch.object(self.controller.time, "monotonic", return_value=1):
            for result in [
                subprocess.CompletedProcess(["fixture"], 1, b"", b"failure"),
                subprocess.TimeoutExpired("fixture", 3),
            ]:
                with self.subTest(result=type(result).__name__):
                    kwargs = (
                        {"side_effect": result}
                        if isinstance(result, Exception)
                        else {"return_value": result}
                    )
                    with mock.patch.object(self.controller.subprocess, "run", **kwargs):
                        with self.assertRaises((ValueError, subprocess.TimeoutExpired)):
                            self.controller.command(["fixture"], 4, 10)

    def test_qualified_version_and_pin_cannot_be_missing_or_changed(self):
        build = self.root / "tools/build/build_macos_app.sh"
        build.parent.mkdir(parents=True)
        workflow = self.root / ".github/workflows/ci-macos.yml"
        workflow.parent.mkdir(parents=True)
        pin = "11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa"
        build.write_text('HAMMERSPOON_VERSION="${HAMMERSPOON_VERSION:-1.1.1}"\n')
        workflow.write_text("printf '%s  %s\\n' " + pin + ' "$archive" | shasum -a 256 --check\n')
        self.assertEqual(self.controller.qualified_pin(self.root), ("1.1.1", pin))
        workflow.write_text("no archive pin")
        with self.assertRaises(ValueError):
            self.controller.qualified_pin(self.root)
        workflow.write_text("printf '%s  %s\\n' " + pin + ' "$archive" | shasum -a 256 --check\n')
        build.write_text('HAMMERSPOON_VERSION="${HAMMERSPOON_VERSION:-1.1.2}"\n')
        with self.assertRaises(ValueError):
            self.controller.qualified_pin(self.root)

    def test_native_group_id_refuses_float_and_boolean_aliases(self):
        for pid, forged in [(42, 42.0), (1, True)]:
            packet = {"status": "ok", "native_owner": copy.deepcopy(OWNER)}
            packet["native_owner"]["worker_pid"] = pid
            packet["native_owner"]["group_id"] = forged
            with self.assertRaises(ValueError):
                self.controller.validate_owner(packet, pid)

    def test_source_imports_are_exact_canonical_repo_dependencies(self):
        repo = HERE.parent.parent
        self.controller.validate_imports(repo)
        for module in (self.controller.owner, self.controller.facade):
            with mock.patch.object(module, "__file__", str(self.root / "foreign.py")):
                with self.assertRaises((ValueError, OSError)):
                    self.controller.validate_imports(repo)
            link = self.root / (module.__name__ + ".py")
            link.symlink_to(Path(module.__file__))
            with mock.patch.object(module, "__file__", str(link)):
                with self.assertRaises((ValueError, OSError)):
                    self.controller.validate_imports(repo)

    def test_unsigned_native_product_overflow_refused_even_if_quotient_fits_lua(self):
        safe = {"ticks": 9223372036854775807, "numer": 2, "denom": 3}
        self.assertEqual(self.controller.checked_sample(safe), 6148914691236517204)
        wrapped_product = {"ticks": 9223372036854775808, "numer": 2, "denom": 3}
        with self.assertRaises(ValueError):
            self.controller.checked_sample(wrapped_product)

    def test_download_keeps_https_certificate_verification_and_remaining_deadline(self):
        completed = subprocess.CompletedProcess(["curl"], 0, b"200 0", b"")
        with (
            mock.patch.object(self.controller.time, "monotonic", return_value=1),
            mock.patch.object(
                self.controller.subprocess, "run", return_value=completed
            ) as operation,
        ):
            reply = self.controller.download_archive(
                "https://example.invalid/official.zip", self.path, 4
            )
        args = operation.call_args.args[0]
        self.assertEqual(args[args.index("--proto") + 1], "=https")
        self.assertEqual(args[args.index("--proto-redir") + 1], "=https")
        self.assertNotIn("--insecure", args)
        self.assertNotIn("-k", args)
        self.assertNotIn("--cacert", args)
        self.assertEqual(reply["http_status"], 200)
        self.assertEqual(reply["ssl_verify_result"], 0)
        self.assertEqual(reply["curl_returncode"], 0)
        self.assertEqual(reply["tls_policy"], "default trust; peer and host verification enabled")
        self.assertLessEqual(operation.call_args.kwargs["timeout"], 3)

    def test_download_certificate_failure_retains_typed_native_facts(self):
        completed = subprocess.CompletedProcess(
            ["curl"], 60, b"000 20", b"curl: (60) certificate verification failed"
        )
        with (
            mock.patch.object(self.controller.time, "monotonic", return_value=1),
            mock.patch.object(self.controller.subprocess, "run", return_value=completed),
        ):
            with self.assertRaises(self.controller.AcquisitionRefused) as refused:
                self.controller.download_archive(
                    "https://example.invalid/official.zip", self.path, 4
                )
        self.assertEqual(refused.exception.evidence["refusal"], "certificate_verification")
        self.assertEqual(refused.exception.evidence["http_status"], 0)
        self.assertEqual(refused.exception.evidence["ssl_verify_result"], 20)
        self.assertEqual(refused.exception.evidence["curl_returncode"], 60)
        self.assertIn(
            "certificate verification failed", refused.exception.evidence["curl_error_summary"]
        )

    def test_download_http_and_transport_errors_are_distinct_actual_replies(self):
        for status, code, reason in [
            (403, 22, "http_status"),
            (500, 22, "http_status"),
            (500, 0, "http_status"),
            (0, 6, "transport_exit"),
            (0, 35, "tls_handshake"),
        ]:
            completed = subprocess.CompletedProcess(
                ["curl"], code, f"{status:03d} 0".encode(), b"actual curl refusal"
            )
            with (
                self.subTest(status=status, code=code),
                mock.patch.object(self.controller.time, "monotonic", return_value=1),
                mock.patch.object(self.controller.subprocess, "run", return_value=completed),
            ):
                with self.assertRaises(self.controller.AcquisitionRefused) as refused:
                    self.controller.download_archive(
                        "https://example.invalid/official.zip", self.path, 4
                    )
            self.assertEqual(refused.exception.evidence["refusal"], reason)
            self.assertEqual(refused.exception.evidence["http_status"], status)
            self.assertEqual(refused.exception.evidence["curl_returncode"], code)

    def test_download_deadline_refusals_never_start_late_or_admit_timeout(self):
        with (
            mock.patch.object(self.controller.time, "monotonic", return_value=4),
            mock.patch.object(
                self.controller.subprocess, "run", side_effect=AssertionError("No expired download")
            ),
        ):
            with self.assertRaises(self.controller.AcquisitionRefused) as refused:
                self.controller.download_archive(
                    "https://example.invalid/official.zip", self.path, 4
                )
        self.assertEqual(refused.exception.evidence["refusal"], "deadline")
        for result in [
            subprocess.CompletedProcess(["curl"], 28, b"000 0", b"operation timed out"),
            subprocess.TimeoutExpired("curl", 3),
        ]:
            options = (
                {"side_effect": result}
                if isinstance(result, Exception)
                else {"return_value": result}
            )
            with (
                mock.patch.object(self.controller.time, "monotonic", return_value=1),
                mock.patch.object(self.controller.subprocess, "run", **options),
            ):
                with self.assertRaises(self.controller.AcquisitionRefused) as refused:
                    self.controller.download_archive(
                        "https://example.invalid/official.zip", self.path, 4
                    )
            self.assertEqual(refused.exception.evidence["refusal"], "deadline")

    def test_acquisition_certificate_refusal_retains_stage_metadata_without_extraction(self):
        facts = {
            "refusal": "certificate_verification",
            "curl_returncode": 60,
            "http_status": 0,
            "ssl_verify_result": 20,
        }
        with (
            mock.patch.object(self.controller, "qualified_pin", return_value=("1.1.1", "1" * 64)),
            mock.patch.object(
                self.controller,
                "download_archive",
                side_effect=self.controller.AcquisitionRefused(facts),
            ),
            mock.patch.object(
                self.controller,
                "command",
                side_effect=AssertionError("No extraction after TLS refusal"),
            ),
        ):
            with self.assertRaises(self.controller.AcquisitionRefused):
                self.controller.acquire_runtime(self.root, self.root, 1e20)
        evidence = json.loads((self.root / "acquisition.json").read_text())
        self.assertEqual(evidence["status"], "error")
        self.assertEqual(evidence["stage"], "download")
        self.assertEqual(evidence["transport"]["refusal"], "certificate_verification")
        self.assertEqual(evidence["version"], "1.1.1")
        self.assertEqual(evidence["archive_sha256_expected"], "1" * 64)
        self.assertFalse((self.root / "runtime").exists())

    def test_acquisition_checksum_refusal_retains_archive_before_extraction(self):
        def downloaded(_url, path, _deadline):
            path.write_bytes(b"abc")
            return {"http_status": 200, "ssl_verify_result": 0, "curl_returncode": 0}

        with (
            mock.patch.object(self.controller, "qualified_pin", return_value=("1.1.1", "1" * 64)),
            mock.patch.object(self.controller, "download_archive", side_effect=downloaded),
            mock.patch.object(
                self.controller,
                "command",
                side_effect=AssertionError("No extraction before matching checksum"),
            ),
        ):
            with self.assertRaises(self.controller.AcquisitionRefused):
                self.controller.acquire_runtime(self.root, self.root, 1e20)
        evidence = json.loads((self.root / "acquisition.json").read_text())
        self.assertEqual(evidence["status"], "error")
        self.assertEqual(evidence["stage"], "archive_checksum")
        self.assertEqual(evidence["transport"]["http_status"], 200)
        self.assertEqual((self.root / "Hammerspoon.zip").read_bytes(), b"abc")
        self.assertFalse((self.root / "runtime").exists())

    def test_acquisition_signature_refusal_preserves_extracted_stage(self):
        pin = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        def downloaded(_url, path, _deadline):
            path.write_bytes(b"abc")
            return {"http_status": 200, "ssl_verify_result": 0, "curl_returncode": 0}

        with (
            mock.patch.object(self.controller, "qualified_pin", return_value=("1.1.1", pin)),
            mock.patch.object(self.controller, "download_archive", side_effect=downloaded),
            mock.patch.object(
                self.controller,
                "command",
                return_value=subprocess.CompletedProcess(["ditto"], 0, b"", b""),
            ),
            mock.patch.object(
                self.controller, "admit_runtime", side_effect=ValueError("actual signature refusal")
            ),
        ):
            with self.assertRaises(self.controller.AcquisitionRefused):
                self.controller.acquire_runtime(self.root, self.root, 1e20)
        evidence = json.loads((self.root / "acquisition.json").read_text())
        self.assertEqual(evidence["status"], "error")
        self.assertEqual(evidence["stage"], "signature")
        self.assertIn("actual signature refusal", evidence["error_summary"])
        self.assertTrue((self.root / "runtime").is_dir())

    def test_download_unknown_metadata_cannot_report_verified_success(self):
        for output in [b"", b"200.0 0", b"200 0 extra", b"200 true"]:
            with (
                mock.patch.object(self.controller.time, "monotonic", return_value=1),
                mock.patch.object(
                    self.controller.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(["curl"], 0, output, b""),
                ),
            ):
                with self.assertRaises(self.controller.AcquisitionRefused) as refused:
                    self.controller.download_archive(
                        "https://example.invalid/official.zip", self.path, 4
                    )
            self.assertEqual(refused.exception.evidence["refusal"], "transport_metadata")

    def test_download_success_reply_after_deadline_is_refused(self):
        with (
            mock.patch.object(self.controller.time, "monotonic", side_effect=[1, 4]),
            mock.patch.object(
                self.controller.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["curl"], 0, b"200 0", b""),
            ),
        ):
            with self.assertRaises(self.controller.AcquisitionRefused) as refused:
                self.controller.download_archive(
                    "https://example.invalid/official.zip", self.path, 4
                )
        self.assertEqual(refused.exception.evidence["refusal"], "deadline")

    def test_download_cannot_expand_the_ten_second_prerequisite_inside_sdk(self):
        with (
            mock.patch.object(self.controller.time, "monotonic", return_value=1),
            mock.patch.object(
                self.controller.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["curl"], 0, b"200 0", b""),
            ) as operation,
        ):
            self.controller.download_archive(
                "https://example.invalid/official.zip", self.path, 1000
            )
        self.assertLessEqual(operation.call_args.kwargs["timeout"], 10)
        arguments = operation.call_args.args[0]
        self.assertLessEqual(float(arguments[arguments.index("--max-time") + 1]), 10)

    def test_completed_acquisition_cannot_outlive_its_final_phase_boundary(self):
        pin = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        # This portable refusal fixture never executes or admits a Mach-O image.
        executable = self.root / "portable-refusal-only"
        executable.write_bytes(b"not native")

        def downloaded(_url, path, _deadline):
            path.write_bytes(b"abc")
            return {"http_status": 200, "ssl_verify_result": 0, "curl_returncode": 0}

        with (
            mock.patch.object(self.controller.time, "monotonic", side_effect=[1, 2, 12]),
            mock.patch.object(self.controller, "qualified_pin", return_value=("1.1.1", pin)),
            mock.patch.object(self.controller, "download_archive", side_effect=downloaded),
            mock.patch.object(
                self.controller,
                "command",
                return_value=subprocess.CompletedProcess(["ditto"], 0, b"", b""),
            ),
            mock.patch.object(self.controller, "admit_runtime", return_value=(executable, {})),
        ):
            with self.assertRaises(self.controller.AcquisitionRefused) as refused:
                self.controller.acquire_runtime(self.root, self.root, 1000)
        self.assertEqual(refused.exception.evidence["refusal"], "deadline")
        evidence = json.loads((self.root / "acquisition.json").read_text())
        self.assertEqual(evidence["status"], "error")
        self.assertEqual(evidence["refusal"], "deadline")
        self.assertEqual(evidence["elapsed_seconds"], 11)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(HostedClockControls)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    print(
        f"PASS independent hosted clock controls tests={result.testsRun} failures={len(result.failures)} errors={len(result.errors)} skipped={len(result.skipped)}"
    )
    raise SystemExit(0 if result.wasSuccessful() and not result.skipped else 1)
