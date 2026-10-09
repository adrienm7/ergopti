# tools/diagnostics/installed_vhd_reference_fixture_test.py
"""Actual filesystem custody controls; Darwin tools/privilege are not modeled successes."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "reference_fixture", Path(__file__).with_name("installed_vhd_reference_fixture.py")
)
SUBJECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUBJECT)


class FixtureCustodyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "image").write_bytes(b"fixed actual image")

    def tearDown(self):
        self.temporary.cleanup()

    def test_actual_inventory_captures_file_bytes_and_identity(self):
        record = SUBJECT.inventory(self.root)
        self.assertEqual(
            record["image"]["sha256"],
            "a758d4c8c3acda64338430d7fc4552f4b3837ce90fd61502e51241d36586bba1",
        )
        self.assertEqual(record["image"]["bytes"], 18)
        self.assertEqual(record["image"]["kind"], "file")
        self.assertEqual(record["image"]["identity"]["ino"], (self.root / "image").stat().st_ino)

    def test_same_inventory_remains_current(self):
        record = SUBJECT.inventory(self.root)
        self.assertEqual(SUBJECT.inventory(self.root), record)

    def test_changed_bytes_are_distinct(self):
        before = SUBJECT.inventory(self.root)
        (self.root / "image").write_bytes(b"replacement bytes!")
        self.assertNotEqual(SUBJECT.inventory(self.root), before)

    def test_actual_replacement_inode_is_distinct(self):
        before = SUBJECT.inventory(self.root)
        (self.root / "new").write_bytes(b"fixed actual image")
        os.replace(self.root / "new", self.root / "image")
        self.assertNotEqual(SUBJECT.inventory(self.root), before)

    def test_mode_change_is_distinct(self):
        before = SUBJECT.inventory(self.root)
        os.chmod(
            self.root / "image",
            0o644 if (self.root / "image").stat().st_mode & 0o777 != 0o644 else 0o600,
        )
        self.assertNotEqual(SUBJECT.inventory(self.root), before)

    def test_added_inventory_node_is_distinct(self):
        before = SUBJECT.inventory(self.root)
        (self.root / "foreign").write_bytes(b"foreign")
        self.assertNotEqual(SUBJECT.inventory(self.root), before)

    def test_actual_symlink_source_refuses_without_reading_target(self):
        os.symlink("image", self.root / "alias")
        with self.assertRaisesRegex(SUBJECT.Refusal, "source_type"):
            SUBJECT.inventory(self.root)

    def test_declared_link_is_recorded_without_traversal(self):
        os.symlink("absent", self.root / "alias")
        row = SUBJECT.inventory(self.root, allow_links=True)["alias"]
        self.assertEqual(row["kind"], "link")
        self.assertEqual(row["target"], "absent")

    def test_actual_hardlink_source_refuses(self):
        os.link(self.root / "image", self.root / "alias")
        with self.assertRaisesRegex(SUBJECT.Refusal, "source_type"):
            SUBJECT.inventory(self.root)

    def test_actual_fifo_source_refuses_without_blocking(self):
        os.mkfifo(self.root / "fifo")
        with self.assertRaisesRegex(SUBJECT.Refusal, "source_type"):
            SUBJECT.inventory(self.root)

    def test_node_budget_refuses(self):
        with self.assertRaisesRegex(SUBJECT.Refusal, "inventory_limit"):
            SUBJECT.inventory(self.root, maximum_nodes=1)

    def test_byte_budget_refuses(self):
        with self.assertRaisesRegex(SUBJECT.Refusal, "inventory_limit"):
            SUBJECT.inventory(self.root, maximum_bytes=2)

    def test_invalid_relative_names_refuse(self):
        for value in ["", "/escape", "..", "a/../b", "a//b", "a/./b", "a\x00b", "a\\b"]:
            with self.subTest(value=value):
                with self.assertRaisesRegex(SUBJECT.Refusal, "relative_path"):
                    SUBJECT.member(value)

    def test_legitimate_fixed_relative_paths(self):
        self.assertEqual(
            SUBJECT.member("daemon.app/Contents/Info.plist"),
            ("daemon.app", "Contents", "Info.plist"),
        )

    def test_nonce_namespace_is_exact(self):
        nonce = "1a" * 16
        self.assertEqual(
            str(SUBJECT.fixture_root(nonce)),
            "/Library/ErgoptiPlusNativeFixture-" + nonce,
        )
        for value in ["", "f" * 31, "F" * 32, "f" * 33, "../" + "f" * 32]:
            with self.assertRaisesRegex(SUBJECT.Refusal, "nonce"):
                SUBJECT.fixture_root(value)

    def test_deadline_refuses_before_native_operation(self):
        with self.assertRaisesRegex(SUBJECT.Refusal, "deadline"):
            SUBJECT.remaining(0)

    def test_wrong_pinned_package_bytes_refuse(self):
        with self.assertRaisesRegex(SUBJECT.Refusal, "package_pin"):
            SUBJECT.verify_package("8.5.0", b"untrusted")

    def test_unsupported_package_refuses(self):
        with self.assertRaisesRegex(SUBJECT.Refusal, "package_version"):
            SUBJECT.verify_package("9.0.0", b"")

    def test_root_snapshot_rejects_a_root_alias(self):
        alias = self.root.parent / (self.root.name + "-alias")
        os.symlink(self.root, alias)
        try:
            with self.assertRaisesRegex(SUBJECT.Refusal, "source_type"):
                SUBJECT.inventory(alias)
        finally:
            alias.unlink()

    def test_exact_cleanup_refuses_changed_inventory_and_preserves_foreign_node(self):
        before = SUBJECT.inventory(self.root)
        (self.root / "foreign").write_bytes(b"preserve")
        with self.assertRaisesRegex(SUBJECT.Refusal, "inventory_changed"):
            SUBJECT.remove_tree(self.root, before)
        self.assertEqual((self.root / "foreign").read_bytes(), b"preserve")

    def test_exact_cleanup_removes_only_captured_root(self):
        before = SUBJECT.inventory(self.root)
        SUBJECT.remove_tree(self.root, before)
        self.assertFalse(os.path.lexists(self.root))
        self.temporary.cleanup()


class ExpansionRouteTests(unittest.TestCase):
    """Modeled tool ports prove routing/refusal, never Darwin option or package authority."""

    package_fixture = b"disclosed routing fixture; not a pinned package"
    verify_real_package = False

    def run_prepare(self, mode, advertised=False):
        from types import SimpleNamespace
        from unittest.mock import patch
        import subprocess

        calls, package_checks, payload_checks = [], [], []
        clock = [100.0]
        original_module = SUBJECT.module
        original_verify_package = SUBJECT.verify_package
        original_verify_payload = SUBJECT.verify_payload
        original_lstat = Path.lstat
        tool_fields = list(Path("/usr/bin/true").stat())
        tool_fields[4] = (
            0  # Explicitly modeled root-owned tool metadata, not actual Darwin custody.
        )
        tool_stat = os.stat_result(tool_fields)
        packages = original_module("installed_vhd_static_fixture")
        native_tools = {"/usr/sbin/pkgutil", "/usr/bin/curl", "/usr/bin/codesign"}

        def metadata(path, *args, **kwargs):
            if str(path) in native_tools:
                return tool_stat
            return original_lstat(path, *args, **kwargs)

        def providers(name):
            if name == "installed_vhd_signature_text":
                # Signature acquisition is a captured port, not a trust verdict.
                return SimpleNamespace(observe_signature_text=lambda *args: None)
            if name == "installed_vhd_static_fixture":
                return packages
            return original_module(name)

        def verify_package(version, body):
            package_checks.append((version, body))
            if self.verify_real_package or mode == "wrong_package":
                return original_verify_package(version, body)
            # Only operation routing uses this captured verifier boundary.
            self.assertEqual(version, "8.4.0")
            self.assertEqual(body, self.package_fixture)

        def verify_payload(version, payload):
            payload_checks.append((version, str(payload)))
            if mode == "changed_package":
                # Sole bypass isolates the existing final package-currentness fence.
                return
            return original_verify_payload(version, payload)

        def execute(argv, **kwargs):
            calls.append(list(argv))
            self.assertFalse(kwargs["check"])
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
            self.assertIs(kwargs["stdout"], subprocess.PIPE)
            self.assertIs(kwargs["stderr"], subprocess.PIPE)
            self.assertGreater(kwargs["timeout"], 0)
            stdout, stderr, status = b"", b"", 0
            if argv[:2] == ["/usr/sbin/pkgutil", "--help"]:
                stderr = (
                    b"pkgutil help --expand-full"
                    if advertised
                    else b"pkgutil help; fixed text without option"
                )
                if mode == "help_failure":
                    status = 2
            elif argv[0] == "/usr/bin/curl":
                package = Path(argv[argv.index("--output") + 1])
                package.write_bytes(
                    b"wrong fixed bytes" if mode == "wrong_package" else self.package_fixture
                )
                self.assertEqual(argv[-1], packages.package_url("8.4.0"))
            elif argv[:2] == ["/usr/sbin/pkgutil", "--check-signature"]:
                pass
            elif argv[:2] == ["/usr/sbin/pkgutil", "--expand-full"]:
                payload = Path(argv[3]) / "Payload"
                payload.mkdir(parents=True)
                if mode == "wrong_payload":
                    (payload / "foreign").write_bytes(b"fixed unexpected payload bytes")
                if mode == "operation_failure":
                    status = 2
                elif mode == "stdout":
                    stdout = b"unexpected"
                elif mode == "stderr":
                    stderr = b"unexpected"
                elif mode == "late":
                    clock[0] = 1001.0
                elif mode == "changed_package":
                    Path(argv[2]).write_bytes(b"changed after expansion")
            elif argv[0] == "/usr/bin/codesign":
                pass
            else:
                self.fail("Unexpected controlled native operation")
            return subprocess.CompletedProcess(argv, status, stdout, stderr)

        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary).resolve()
            os.chmod(owner, 0o700)
            with (
                patch.object(SUBJECT.sys, "platform", "darwin"),
                patch.object(SUBJECT.time, "monotonic", lambda: clock[0]),
                patch.object(Path, "lstat", metadata),
                patch.object(SUBJECT, "module", providers),
                patch.object(SUBJECT, "verify_package", verify_package),
                patch.object(SUBJECT, "verify_payload", verify_payload),
                patch.object(SUBJECT.subprocess, "run", execute),
            ):
                try:
                    SUBJECT.prepare(owner, 1000.0)
                except SUBJECT.Refusal as error:
                    reason = str(error)
                else:
                    self.fail("Routing fixture must never prepare a qualified native reference")
            expansion = [row for row in calls if row[:2] == ["/usr/sbin/pkgutil", "--expand-full"]]
            for row in expansion:
                self.assertEqual(
                    row,
                    [
                        "/usr/sbin/pkgutil",
                        "--expand-full",
                        str(owner / packages.package_name("8.4.0")),
                        str(owner / "expanded-8.4.0"),
                    ],
                )
            self.assertEqual(calls[0], ["/usr/sbin/pkgutil", "--help"])
            return reason, calls, expansion, package_checks, payload_checks

    def test_help_without_advertisement_reaches_fixed_expansion_and_real_payload_refusal(self):
        reason, _, expansion, package_checks, payload_checks = self.run_prepare("missing_payload")
        self.assertEqual(reason, "payload_inventory")
        self.assertEqual(len(expansion), 1)
        self.assertEqual(len(package_checks), 1)
        self.assertEqual(len(payload_checks), 1)

    def test_advertised_but_invalid_operation_refuses_status(self):
        reason, _, expansion, _, payload_checks = self.run_prepare("operation_failure", True)
        self.assertEqual(reason, "native_status")
        self.assertEqual(len(expansion), 1)
        self.assertEqual(payload_checks, [])

    def test_unadvertised_invalid_operation_also_refuses_status(self):
        reason, _, expansion, _, payload_checks = self.run_prepare("operation_failure")
        self.assertEqual(reason, "native_status")
        self.assertEqual(len(expansion), 1)
        self.assertEqual(payload_checks, [])

    def test_expansion_requires_both_streams_empty(self):
        for mode in ("stdout", "stderr"):
            with self.subTest(mode=mode):
                reason, _, expansion, _, payload_checks = self.run_prepare(mode, True)
                self.assertEqual(reason, "expand_output")
                self.assertEqual(len(expansion), 1)
                self.assertEqual(payload_checks, [])

    def test_successful_operation_cannot_admit_wrong_real_payload(self):
        reason, _, expansion, _, payload_checks = self.run_prepare("wrong_payload", True)
        self.assertEqual(reason, "payload_inventory")
        self.assertEqual(len(expansion), 1)
        self.assertEqual(len(payload_checks), 1)

    def test_actual_package_pin_refuses_before_expansion(self):
        reason, _, expansion, package_checks, payload_checks = self.run_prepare(
            "wrong_package", True
        )
        self.assertEqual(reason, "package_pin")
        self.assertEqual(len(package_checks), 1)
        self.assertEqual(expansion, [])
        self.assertEqual(payload_checks, [])

    def test_help_operation_status_still_refuses_before_download(self):
        reason, calls, expansion, package_checks, payload_checks = self.run_prepare(
            "help_failure", True
        )
        self.assertEqual(reason, "native_status")
        self.assertEqual(len(calls), 1)
        self.assertEqual(expansion, [])
        self.assertEqual(package_checks, [])
        self.assertEqual(payload_checks, [])

    def test_late_expansion_cannot_admit_payload(self):
        reason, _, expansion, _, payload_checks = self.run_prepare("late", True)
        self.assertEqual(reason, "deadline")
        self.assertEqual(len(expansion), 1)
        self.assertEqual(payload_checks, [])

    def test_existing_package_currentness_fence_survives_expansion(self):
        reason, _, expansion, _, payload_checks = self.run_prepare("changed_package", True)
        self.assertEqual(reason, "package_changed")
        self.assertEqual(len(expansion), 1)
        self.assertEqual(len(payload_checks), 1)


class PayloadInventoryDiagnosticTests(unittest.TestCase):
    """Fixed original ordinal witnesses; modeled inventory never qualifies Darwin."""

    app_metadata = (
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/._embedded.provisionprofile"
    )
    prefix = b"ERGOPTI_VHD_PAYLOAD_INVENTORY_DIAGNOSTIC "

    def captured(self, actual):
        import json
        from unittest.mock import patch

        writes = []
        reader, writer = os.pipe()
        saved_stderr = os.dup(2)
        real_write = os.write
        try:
            os.dup2(writer, 2)
            os.close(writer)
            writer = -1

            def observed_write(fd, body):
                writes.append((fd, body))
                return real_write(fd, body)

            with patch.object(SUBJECT.os, "write", side_effect=observed_write):
                SUBJECT.observe_payload_inventory_refusal("8.4.0", actual)
        finally:
            os.dup2(saved_stderr, 2)
            os.close(saved_stderr)
            if writer >= 0:
                os.close(writer)
        try:
            received = os.read(reader, 8193)
            self.assertEqual(os.read(reader, 1), b"")
        finally:
            os.close(reader)
        self.assertEqual(len(writes), 1)
        fd, body = writes[0]
        self.assertEqual(received, body)
        self.assertEqual(fd, 2)
        self.assertLessEqual(len(body), 8192)
        self.assertTrue(body.startswith(self.prefix))
        self.assertTrue(body.endswith(b"\n"))
        packet = json.loads(body[len(self.prefix) :])
        self.assertEqual(packet["expected_count"], 42)
        self.assertEqual(packet["reason"], "payload_inventory")
        self.assertIs(packet["authority"], False)
        self.assertIs(packet["installation_qualified"], False)
        self.assertIs(packet["reference_qualified"], False)
        return packet, body

    def test_missing_known_indices_extra_count_and_private_names_are_bounded(self):
        actual = {
            "Library": {"identity": {"mode": 16877}},
            "/private/SECRET/foreign-payload": {"bytes": 99, "sha256": "SECRET"},
        }
        packet, body = self.captured(actual)
        self.assertEqual(packet["missing_expected_indices"], list(range(22)) + list(range(23, 42)))
        self.assertIn(3, packet["missing_expected_indices"])
        self.assertIn(8, packet["missing_expected_indices"])
        self.assertEqual(packet["extra_count"], 1)
        for private in (b"SECRET", b"private", b"foreign-payload", b"Applications", b"Library"):
            self.assertNotIn(private, body)

    def test_fixed_original_file_and_directory_scalar_matches_are_nullable(self):
        actual = {
            self.app_metadata: {
                "identity": {"mode": 33188},
                "bytes": 579,
                "sha256": "31187b1fd98223fdbf4bdc8d46fb86da52ec03591de2e4f71275a7cec5aea14e",
            },
            "Library": {"identity": {"mode": 16877}},
        }
        packet, _ = self.captured(actual)
        self.assertEqual(
            packet["rows"][3],
            {
                "index": 3,
                "present": True,
                "type_matches": True,
                "mode_matches": True,
                "bytes_matches": True,
                "sha256_matches": True,
            },
        )
        self.assertEqual(
            packet["rows"][22],
            {
                "index": 22,
                "present": True,
                "type_matches": True,
                "mode_matches": True,
                "bytes_matches": None,
                "sha256_matches": None,
            },
        )
        self.assertEqual(
            packet["missing_expected_indices"], [0, 1, 2] + list(range(4, 22)) + list(range(23, 42))
        )

    def test_fixed_original_file_type_mode_size_and_digest_mismatches_are_false(self):
        packet, _ = self.captured(
            {self.app_metadata: {"identity": {"mode": 16877}, "bytes": 580, "sha256": "0" * 64}}
        )
        self.assertEqual(
            packet["rows"][3],
            {
                "index": 3,
                "present": True,
                "type_matches": False,
                "mode_matches": False,
                "bytes_matches": False,
                "sha256_matches": False,
            },
        )

    def test_all_missing_rows_have_only_fixed_indices_and_nullable_booleans(self):
        packet, _ = self.captured({})
        self.assertEqual(
            set(packet),
            {
                "schema",
                "kind",
                "authority",
                "version",
                "reason",
                "expected_count",
                "rows",
                "missing_expected_indices",
                "extra_count",
                "installation_qualified",
                "reference_qualified",
            },
        )
        self.assertEqual(packet["schema"], 1)
        self.assertEqual(packet["version"], "8.4.0")
        self.assertEqual(packet["kind"], "installed_vhd_payload_inventory_refusal_observation")
        self.assertEqual(packet["missing_expected_indices"], list(range(42)))
        self.assertEqual(packet["extra_count"], 0)
        self.assertEqual(
            packet["rows"],
            [
                {
                    "index": i,
                    "present": False,
                    "type_matches": None,
                    "mode_matches": None,
                    "bytes_matches": None,
                    "sha256_matches": None,
                }
                for i in range(42)
            ],
        )

    def test_failure_only_observer_uses_the_single_already_read_inventory(self):
        import copy
        from unittest.mock import patch

        actual = {"Library": {"identity": {"mode": 16877}}}
        before = copy.deepcopy(actual)
        with (
            patch.object(SUBJECT, "inventory", return_value=actual) as capture,
            patch.object(SUBJECT, "observe_payload_inventory_refusal") as observe,
            patch.object(SUBJECT, "__name__", "__main__"),
        ):
            with self.assertRaisesRegex(SUBJECT.Refusal, "^payload_inventory$"):
                SUBJECT.verify_payload("8.4.0", Path("/private/SECRET"))
            capture.assert_called_once_with(Path("/private/SECRET"))
            observe.assert_called_once_with("8.4.0", actual)
            self.assertIs(observe.call_args.args[1], actual)
        self.assertEqual(actual, before)
        # A captured single-entry predicate port checks routing only; the real
        # frozen42 corpus is restored by patch exit and is never regenerated.
        with (
            patch.object(SUBJECT, "PAYLOADS", {"8.4.0": {"Library": [16877, 0, "fixed"]}}),
            patch.object(SUBJECT, "inventory", return_value=actual) as capture,
            patch.object(SUBJECT, "observe_payload_inventory_refusal") as observe,
            patch.object(SUBJECT, "__name__", "__main__"),
        ):
            SUBJECT.verify_payload("8.4.0", Path("/private/SECRET"))
            capture.assert_called_once()
            observe.assert_not_called()

    def test_write_fault_or_partial_write_cannot_redeem_the_original_refusal(self):
        from unittest.mock import patch

        for result in (OSError("SECRET stderr unavailable"), 1):
            with (
                self.subTest(result=type(result).__name__),
                patch.object(SUBJECT, "__name__", "__main__"),
                patch.object(SUBJECT, "inventory", return_value={}),
                patch.object(
                    SUBJECT.os,
                    "write",
                    side_effect=result if isinstance(result, OSError) else None,
                    return_value=result if isinstance(result, int) else None,
                ) as write,
            ):
                with self.assertRaisesRegex(SUBJECT.Refusal, "^payload_inventory$"):
                    SUBJECT.verify_payload("8.4.0", Path("/private/SECRET"))
                self.assertEqual(write.call_count, 1)

    def test_oversized_optional_serialization_is_not_written_and_refusal_survives(self):
        from unittest.mock import patch

        with (
            patch.object(SUBJECT, "__name__", "__main__"),
            patch.object(SUBJECT, "inventory", return_value={}),
            patch.object(SUBJECT.json, "dumps", return_value="x" * 8192),
            patch.object(SUBJECT.os, "write") as write,
        ):
            with self.assertRaisesRegex(SUBJECT.Refusal, "^payload_inventory$"):
                SUBJECT.verify_payload("8.4.0", Path("/private/SECRET"))
            write.assert_not_called()

    def test_malformed_optional_values_and_unsupported_versions_never_disclose_values(self):
        from unittest.mock import patch

        packet, body = self.captured(
            {
                self.app_metadata: {
                    "identity": {"mode": "SECRET"},
                    "bytes": "/private/SECRET",
                    "sha256": "SECRET" * 10000,
                }
            }
        )
        self.assertEqual(
            packet["rows"][3],
            {
                "index": 3,
                "present": True,
                "type_matches": None,
                "mode_matches": None,
                "bytes_matches": None,
                "sha256_matches": None,
            },
        )
        self.assertNotIn(b"SECRET", body)
        with patch.object(SUBJECT.os, "write") as write:
            SUBJECT.observe_payload_inventory_refusal("SECRET version", {})
            write.assert_not_called()


if __name__ == "__main__":
    unittest.main()
