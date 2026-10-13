"""Actual resource filesystem controls; no source admission, CMS or installation grant."""

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import hashlib
import os
import tempfile
import time
import unittest
import owned_runtime_product_build as product

PKG = "Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg"
PLIST = "org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon.plist"
_supplier = os.environ.get("ERGOPTI_VHD_BUILD_ASSET_SOURCE")
if not _supplier:
    raise RuntimeError(
        "ERGOPTI_VHD_BUILD_ASSET_SOURCE is required; no source supplier was admitted"
    )
VENDOR = Path(_supplier)
if not VENDOR.is_absolute() or VENDOR.resolve(strict=True) != VENDOR:
    raise RuntimeError("ERGOPTI_VHD_BUILD_ASSET_SOURCE must be a canonical absolute vendor root")
EXPECTED = (
    (
        PKG,
        VENDOR / "dist" / PKG,
        "d73d6d9428f0f80b87b8a8ba8a1031f2cbc3bc1fa6b74842d1f1b764b2916fc9",
        2089117,
    ),
    (
        PLIST,
        VENDOR / "files/LaunchDaemons" / PLIST,
        "4431ec6b5d220004bfa947cb9c069de34365b5ec4f5fd0cf674a74c8e7923659",
        653,
    ),
)


class ResourceFilesystemControls(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-vhd-resource-controls-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name).resolve()
        self.resources = self.root / "Resources"
        self.resources.mkdir()
        rows = []
        for name, path, digest, size in EXPECTED:
            data = path.read_bytes()
            self.assertEqual(len(data), size)
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
            rows.append((name, data))
        # This finite component supplies real pinned vendor bytes. It explicitly
        # models only copy currentness, never a factory or signed-source grant.
        self.payload = SimpleNamespace(resources=tuple(rows))
        self.deadline = time.monotonic() + 10

    def stage(self, current=lambda: None):
        return product._stage_virtual_hid_resources(
            self.resources, self.payload, self.deadline, current
        )

    def test_actual_two_leaf_copy_preserves_fixed_bytes_and_nonexecutability(self):
        target, snapshot = self.stage()
        self.assertEqual(set(target.iterdir()), {target / PKG, target / PLIST})
        self.assertEqual(set(snapshot[0]), {"."})
        for name, _, digest, size in EXPECTED:
            leaf = target / name
            self.assertEqual(leaf.stat().st_size, size)
            self.assertEqual(hashlib.sha256(leaf.read_bytes()).hexdigest(), digest)
            self.assertEqual(leaf.stat().st_mode & 0o777, 0o644)
            self.assertEqual(leaf.stat().st_nlink, 1)

    def test_second_copy_cannot_overwrite_original_members(self):
        target, before = self.stage()
        with self.assertRaises(FileExistsError):
            self.stage()
        self.assertEqual(product._snapshot(target, self.deadline), before)

    def test_source_refusal_precedes_any_resource_directory(self):
        primary = RuntimeError("controlled original source refusal")

        def current():
            raise primary

        with self.assertRaises(RuntimeError) as caught:
            self.stage(current)
        self.assertIs(caught.exception, primary)
        self.assertEqual(list(self.resources.iterdir()), [])

    def test_currentness_loss_after_first_copy_retains_failure_without_second_member(self):
        primary = RuntimeError("controlled source revocation")
        live = True
        original = product._write_exclusive

        def write(*args, **kwargs):
            nonlocal live
            original(*args, **kwargs)
            live = False

        def current():
            if not live:
                raise primary

        with patch.object(product, "_write_exclusive", side_effect=write):
            with self.assertRaises(RuntimeError) as caught:
                self.stage(current)
        self.assertIs(caught.exception, primary)
        target = self.resources / "VirtualHIDDriverPayload"
        self.assertTrue((target / PKG).is_file())
        self.assertFalse((target / PLIST).exists())

    def test_copied_byte_mutation_refuses_before_returning_a_snapshot(self):
        original = product._write_exclusive

        def write(name, data, *args, **kwargs):
            original(name, b"changed" if name == PLIST else data, *args, **kwargs)

        with patch.object(product, "_write_exclusive", side_effect=write):
            with self.assertRaises(product.ProductBuildRefusal):
                self.stage()

    def test_unowned_extra_member_refuses(self):
        original = product._write_exclusive

        def write(*args, **kwargs):
            original(*args, **kwargs)
            if args[0] == PKG:
                (self.resources / "VirtualHIDDriverPayload" / "unowned").write_bytes(b"unknown")

        with patch.object(product, "_write_exclusive", side_effect=write):
            with self.assertRaises(product.ProductBuildRefusal):
                self.stage()

    def test_parent_symlink_is_never_followed(self):
        linked = self.root / "Linked"
        linked.symlink_to(self.resources, target_is_directory=True)
        with self.assertRaises(product.ProductBuildRefusal):
            product._stage_virtual_hid_resources(linked, self.payload, self.deadline, lambda: None)
        self.assertEqual(list(self.resources.iterdir()), [])

    def test_foreign_roster_cannot_create_resources(self):
        self.payload.resources = (("../foreign", b"bytes"), (PLIST, self.payload.resources[1][1]))
        with self.assertRaises(product.ProductBuildRefusal):
            self.stage()
        self.assertEqual(list(self.resources.iterdir()), [])

    def test_directory_replacement_fences_the_second_write(self):
        original = product._write_exclusive
        target = self.resources / "VirtualHIDDriverPayload"
        retained = self.resources / "OriginalPayload"

        def write(*args, **kwargs):
            original(*args, **kwargs)
            if args[0] == PKG:
                target.rename(retained)
                target.mkdir()

        with patch.object(product, "_write_exclusive", side_effect=write):
            with self.assertRaises(product.ProductBuildRefusal):
                self.stage()
        self.assertEqual(list(target.iterdir()), [])
        self.assertTrue((retained / PKG).is_file())
        self.assertFalse((retained / PLIST).exists())

    def test_expired_budget_creates_no_resource_members(self):
        self.deadline = time.monotonic() - 1
        with self.assertRaises(product.ProductBuildRefusal):
            self.stage()
        target = self.resources / "VirtualHIDDriverPayload"
        self.assertFalse(target.exists() and list(target.iterdir()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
