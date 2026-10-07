# tools/diagnostics/hs_owned_configuration_fixture_test.py
"""Handwritten owner-file and native receipt refusals, frozen before fixture code."""

import hashlib
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
