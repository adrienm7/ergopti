# tools/diagnostics/hs_owned_configuration_fixture_test.py
"""Handwritten owner-file and native receipt refusals, frozen before fixture code."""

import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import types
from unittest import mock
import unittest

import hs_owned_configuration_fixture as fixture
from hs_karabiner_config_probe_test import owned_receipt, NONCE, EXECUTABLE, DOMAIN


class OwnedConfigurationNativeControls(unittest.TestCase):
    """Real private filesystem tests; native runtime/process endpoints are modeled."""

    def report(self):
        return {
            "status": "ok",
            "operation_error": None,
            "cleanup_errors": [],
            "application_cleanup": "confirmed inherited PGID retired",
            "native_owner": {
                "worker_pid": 42,
                "group_id": 42,
                "closed": True,
                "reservation_lost": False,
                "live_group_members": [],
                "escaped_sessions_managed": False,
            },
        }

    def test_healthy_packet_is_a_private_complete_native_cohort_only(self):
        result = fixture.admit(owned_receipt(), self.report(), NONCE, 42, EXECUTABLE, DOMAIN)
        self.assertEqual(result["variant_count"], 8)
        self.assertEqual(result["manipulator_count"], 480)
        self.assertIs(result["installation"], False)
        self.assertIs(result["remapping"], False)

    def test_each_physical_retirement_obligation_and_actual_pid_are_required(self):
        for field, value in {
            "worker_pid": 43,
            "group_id": 43,
            "closed": False,
            "reservation_lost": True,
            "live_group_members": [43],
            "escaped_sessions_managed": True,
        }.items():
            with self.subTest(field=field):
                report = self.report()
                report["native_owner"][field] = value
                with self.assertRaisesRegex(ValueError, "Native"):
                    fixture.admit(owned_receipt(), report, NONCE, 42, EXECUTABLE, DOMAIN)

    def test_raised_operation_or_cleanup_and_unconfirmed_group_cannot_qualify(self):
        for field, value in {
            "status": "error",
            "operation_error": "failure",
            "cleanup_errors": ["pending"],
            "application_cleanup": "unconfirmed; inputs retained",
        }.items():
            with self.subTest(field=field):
                report = self.report()
                report[field] = value
                with self.assertRaisesRegex(ValueError, "Native"):
                    fixture.admit(owned_receipt(), report, NONCE, 42, EXECUTABLE, DOMAIN)

    def test_bounded_actual_owner_file_is_byte_exact(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            file = root / "receipt.json"
            data = b'{"actual":true}\n'
            file.write_bytes(data)
            file.chmod(0o600)
            self.assertEqual(fixture.read_owned(file, 128), data)

    def test_actual_alias_fifo_and_oversized_owner_files_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            file = root / "receipt.json"
            file.write_bytes(b"{}")
            file.chmod(0o600)
            alias = root / "alias"
            alias.symlink_to(file.name)
            with self.assertRaises((ValueError, OSError)):
                fixture.read_owned(alias, 128)
            fifo = root / "fifo"
            os.mkfifo(fifo, 0o600)
            with self.assertRaisesRegex(ValueError, "bounded ordinary owner"):
                fixture.read_owned(fifo, 128)
            with self.assertRaisesRegex(ValueError, "bounded ordinary owner"):
                fixture.read_owned(file, 1)
            self.assertEqual(file.read_bytes(), b"{}")

    def test_source_hash_and_physical_inode_both_remain_current(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            source = root / "source.lua"
            source.write_bytes(b"return {}\n")
            identity = fixture.file_identity(source)
            fixture.verify_identity(source, identity)
            source.write_bytes(b"return { changed = true }\n")
            with self.assertRaisesRegex(ValueError, "Source identity changed"):
                fixture.verify_identity(source, identity)
            source.unlink()
            source.write_bytes(b"return {}\n")
            with self.assertRaisesRegex(ValueError, "Source identity changed"):
                fixture.verify_identity(source, identity)

    def test_full_native_packet_and_final_file_cannot_be_replaced_by_equal_count_flags(self):
        for field, value in {
            "complete": False,
            "cleanup_settled": False,
            "pid": 43,
            "installation": True,
            "remapping": True,
        }.items():
            with self.subTest(field=field):
                packet = owned_receipt()
                packet[field] = value
                with self.assertRaisesRegex(ValueError, "identity or observation"):
                    fixture.admit(packet, self.report(), NONCE, 42, EXECUTABLE, DOMAIN)

    def test_actual_final_graph_and_separate_stock_sentinel_are_exact(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            (root / "karabiner").mkdir(mode=0o700)
            packet = owned_receipt()
            final = root / "karabiner/karabiner.json"
            stock = root / "stock-personal.json"
            original = b"private personal source\n"
            stock.write_bytes(original)
            stock.chmod(0o600)
            final.write_text(json.dumps(packet["variants"][-1]["config"]))
            final.chmod(0o600)
            hashes = fixture.admit_files(root, packet, original)
            self.assertEqual(hashes["stock_sha256"], hashlib.sha256(original).hexdigest())
            final.write_text("{}")
            with self.assertRaisesRegex(ValueError, "Actual final private"):
                fixture.admit_files(root, packet, original)
            final.write_text(json.dumps(packet["variants"][-1]["config"]))
            stock.write_bytes(b"foreign")
            with self.assertRaisesRegex(ValueError, "Stock private sentinel changed"):
                fixture.admit_files(root, packet, original)

    def test_equal_bytes_and_timestamp_cannot_hide_a_replacement_inode(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            source = root / "source.lua"
            source.write_bytes(b"return {}\n")
            original = source.stat()
            identity = fixture.file_identity(source)
            source.rename(root / "original-held.lua")
            source.write_bytes(b"return {}\n")
            source.chmod(original.st_mode & 0o7777)
            os.utime(source, ns=(original.st_atime_ns, original.st_mtime_ns))
            self.assertNotEqual(source.stat().st_ino, original.st_ino)
            self.assertEqual(source.read_bytes(), b"return {}\n")
            self.assertEqual(source.stat().st_mtime_ns, original.st_mtime_ns)
            with self.assertRaisesRegex(ValueError, "Source identity changed"):
                fixture.verify_identity(source, identity)


class OwnedConfigurationFailureObservationControls(unittest.TestCase):
    """Closed diagnostics cannot change genuine admission or expose failure text."""

    def invoke(self, packet, report):
        operation = getattr(fixture, "admit_with_failure_observation", fixture.admit)
        return operation(packet, report, NONCE, 42, EXECUTABLE, DOMAIN)

    def capture_refusal(self, report, packet=None):
        sink = io.StringIO()
        with mock.patch.object(fixture.sys, "stderr", sink):
            with self.assertRaises(ValueError):
                self.invoke(owned_receipt() if packet is None else packet, report)
        raw = sink.getvalue()
        self.assertLessEqual(len(raw.encode()), 512)
        self.assertTrue(raw.startswith("ERGOPTI_OWNED_CONFIGURATION_FAILURE "))
        self.assertEqual(raw.count("\n"), 1)
        return json.loads(raw.removeprefix("ERGOPTI_OWNED_CONFIGURATION_FAILURE "))

    def expected(self, operation="none", cleanup="none", retirement="acknowledged"):
        return {
            "schema": 1,
            "kind": "owned_configuration_controller_failure_observation",
            "authority": False,
            "native_verdict": "unchanged",
            "operation": operation,
            "cleanup": cleanup,
            "retirement": retirement,
        }

    def test_original_controller_refusals_project_only_their_fixed_operation(self):
        cases = (
            ("Native private publication observation deadline", "observation_deadline"),
            ("Native private publication receipt deadline", "receipt_deadline"),
            ("Exact native publication child exited before receipt", "child_exited_before_receipt"),
            ("Exact native publication child exited during receipt", "child_exited_during_receipt"),
            ("Source identity changed", "source_identity_changed"),
            ("Native private publication controller deadline", "controller_deadline"),
        )
        for reason, operation in cases:
            with self.subTest(operation=operation):
                report = OwnedConfigurationNativeControls().report()
                report["operation_error"] = reason
                self.assertEqual(self.capture_refusal(report), self.expected(operation=operation))

    def test_cleanup_failure_cannot_be_hidden_by_a_complete_native_packet(self):
        report = OwnedConfigurationNativeControls().report()
        report["cleanup_errors"] = ["Retirement: private details must never be projected"]
        self.assertEqual(self.capture_refusal(report), self.expected(cleanup="refused"))

    def test_unconfirmed_retirement_remains_a_refusal(self):
        report = OwnedConfigurationNativeControls().report()
        report["application_cleanup"] = "unconfirmed; inputs retained"
        self.assertEqual(self.capture_refusal(report), self.expected(retirement="unconfirmed"))

    def test_original_packet_validation_remains_required_after_clean_retirement(self):
        packet = owned_receipt()
        packet["complete"] = False
        self.assertEqual(
            self.capture_refusal(OwnedConfigurationNativeControls().report(), packet),
            self.expected(),
        )

    def test_unknown_failure_text_never_enters_the_diagnostic(self):
        report = OwnedConfigurationNativeControls().report()
        report["operation_error"] = "/private/customer/path\n" + "sensitive" * 5000
        self.assertEqual(
            self.capture_refusal(report), self.expected(operation="unclassified_refusal")
        )

    def test_nonplain_reports_receive_no_additional_foreign_getter_call(self):
        calls = []
        original = ValueError("primary owner refusal")

        class ForeignReport(dict):
            def get(self, *args):
                calls.append(args)
                raise original

        sink = io.StringIO()
        with mock.patch.object(fixture.sys, "stderr", sink):
            with self.assertRaises(ValueError) as error:
                self.invoke(owned_receipt(), ForeignReport())
        self.assertIs(error.exception, original)
        self.assertEqual(len(calls), 1)
        self.assertEqual(
            json.loads(sink.getvalue().removeprefix("ERGOPTI_OWNED_CONFIGURATION_FAILURE ")),
            self.expected(operation="unavailable", cleanup="unavailable", retirement="unavailable"),
        )

    def test_failed_diagnostic_sink_preserves_the_original_exception_identity(self):
        original = ValueError("primary owner refusal")
        report = OwnedConfigurationNativeControls().report()
        with mock.patch.object(fixture, "admit", side_effect=original):
            with mock.patch.object(
                fixture.sys.stderr, "write", side_effect=OSError("sink unavailable")
            ):
                with self.assertRaises(ValueError) as error:
                    self.invoke(owned_receipt(), report)
        self.assertIs(error.exception, original)

    def test_healthy_genuine_admission_emits_nothing_and_keeps_its_result_identity(self):
        actual_admit = fixture.admit
        returned = []

        def observed(*args):
            result = actual_admit(*args)
            returned.append(result)
            return result

        sink = io.StringIO()
        with mock.patch.object(fixture, "admit", side_effect=observed):
            with mock.patch.object(fixture.sys, "stderr", sink):
                result = self.invoke(owned_receipt(), OwnedConfigurationNativeControls().report())
        self.assertEqual(sink.getvalue(), "")
        self.assertEqual(len(returned), 1)
        self.assertIs(result, returned[0])
        self.assertEqual(result["variant_count"], 8)
        self.assertIs(result["installation"], False)
        self.assertIs(result["remapping"], False)


class OwnedConfigurationProviderControls(unittest.TestCase):
    """Actual provider/source binding controls without native process qualification."""

    def repository(self):
        return Path(fixture.__file__).parent.parent.parent

    def providers(self):
        return (fixture, fixture.probe, fixture.timer, fixture.clock, fixture.owner, fixture.facade)

    def test_actual_provider_closure_and_loaded_contracts_are_current(self):
        bound = fixture.validate_providers(self.repository())
        self.assertEqual(len(bound), 8)
        self.assertEqual(bound, fixture.validate_providers(self.repository()))
        self.assertEqual(sum("module" in identity for identity in bound.values()), 6)
        self.assertTrue(
            all(identity["definitions"] for identity in bound.values() if "module" in identity)
        )

    def test_each_foreign_actual_module_is_refused(self):
        repo = self.repository()
        with tempfile.TemporaryDirectory() as folder:
            foreign = Path(folder).resolve() / "foreign-provider.py"
            foreign.write_bytes(b"# genuine foreign source\n")
            for module in self.providers():
                with self.subTest(module=module.__name__):
                    with mock.patch.object(module, "__file__", str(foreign)):
                        with self.assertRaisesRegex(ValueError, "another source repository"):
                            fixture.validate_providers(repo)

    def test_relabelled_module_cannot_hide_foreign_executing_code(self):
        operation = fixture.probe.typed_equal
        replacement = types.FunctionType(
            operation.__code__.replace(co_filename="/tmp/foreign-provider.py"),
            operation.__globals__,
            operation.__name__,
            operation.__defaults__,
            operation.__closure__,
        )
        replacement.__module__ = operation.__module__
        with mock.patch.object(fixture.probe, "typed_equal", replacement):
            with self.assertRaisesRegex(ValueError, "Executing provider code"):
                fixture.validate_providers(self.repository())

    def test_replaced_same_origin_operation_changes_retained_binding(self):
        bound = fixture.validate_providers(self.repository())
        original = fixture.probe.typed_equal
        replacement = types.FunctionType(
            original.__code__,
            original.__globals__,
            original.__name__,
            original.__defaults__,
            original.__closure__,
        )
        replacement.__module__ = original.__module__
        with mock.patch.object(fixture.probe, "typed_equal", replacement):
            self.assertNotEqual(bound, fixture.validate_providers(self.repository()))
        self.assertEqual(bound, fixture.validate_providers(self.repository()))

    def test_foreign_creator_and_validator_aliases_are_refused(self):
        for module, name in (
            (fixture.clock, "owner"),
            (fixture.clock, "facade"),
            (fixture.facade, "owner"),
            (fixture.probe, "unique_object"),
            (fixture.probe, "TIMER_CONTRACT"),
        ):
            with self.subTest(module=module.__name__, alias=name):
                with mock.patch.object(module, name, object()):
                    with self.assertRaisesRegex(ValueError, "provider alias|facade alias"):
                        fixture.validate_providers(self.repository())

    def test_loaded_contract_drift_cannot_qualify_current_source(self):
        for contract in (fixture.probe.CONTRACT, fixture.timer.CONTRACT):
            with self.subTest(contract=contract):
                with mock.patch.dict(contract, {"unexpected_provider_generation": "foreign"}):
                    with self.assertRaisesRegex(ValueError, "contract differs from source"):
                        fixture.validate_providers(self.repository())

    def test_timer_contract_is_captured_and_actual_drift_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            for relative in (
                "static/ergopti_plus/macos",
                "static/ergopti_plus/_shared",
                "static/layouts",
            ):
                (root / relative).mkdir(parents=True)
            for index in range(100):
                (root / "static/ergopti_plus/macos" / f"source{index}.lua").write_text(
                    "return {}\n"
                )
            for relative in fixture.SOURCE_EXTRAS:
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((self.repository() / relative).read_bytes())
            selected = "tools/diagnostics/hs_delayed_timer_contract.json"
            inventory = fixture.source_inventory(root)
            self.assertIn(selected, inventory)
            (root / selected).write_bytes(b'{"foreign":true}\n')
            with self.assertRaisesRegex(ValueError, "Source identity changed"):
                fixture.verify_identity(root / selected, inventory[selected])


if __name__ == "__main__":
    unittest.main()
