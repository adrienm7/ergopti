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


if __name__ == "__main__":
    unittest.main()
