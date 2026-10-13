"""Portable real-filesystem and fixed native-command planning controls.

No Darwin compilation, CMS, installed capability, physical capture or shipping
qualification is created by these tests. Native validator controls stay separate.
"""

import hashlib
import os
from pathlib import Path
import tempfile
import time
import unittest
import owned_runtime_product_build as product


class ProductionBuildControls(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-production-build-controls-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name).resolve()
        self.leaf = self.root / "source"
        self.leaf.write_bytes(b"fixed independent source bytes\n")

    def held(self):
        fd = os.open(self.leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        item = product.HeldSource(
            self.leaf,
            fd,
            product.identity(os.fstat(fd)),
            self.leaf.read_bytes(),
            "filesystem-control-not-git-qualification",
        )
        self.addCleanup(item.close)
        return item

    def test_held_read_and_atime_only_stay_current(self):
        held = self.held()
        before = os.fstat(held.descriptor)
        self.assertEqual(os.pread(held.descriptor, before.st_size, 0), held.data)
        held.current()

        # The explicit fingerprint omits access time and retains every stable
        # identity/content field; no filesystem-dependent atime assumption.
        class AccessTimeOnly:
            def __getattr__(self, name):
                if name == "st_atime":
                    return before.st_atime + 3600
                if name == "st_atime_ns":
                    return before.st_atime_ns + 3600000000000
                return getattr(before, name)

        self.assertEqual(product.identity(before), product.identity(AccessTimeOnly()))

    def test_named_inode_replacement_refuses(self):
        held = self.held()
        replacement = self.root / "replacement"
        replacement.write_bytes(held.data)
        os.replace(replacement, self.leaf)
        with self.assertRaises(product.ProductBuildRefusal):
            held.current()

    def test_held_content_mutation_refuses(self):
        held = self.held()
        self.leaf.write_bytes(b"changed independent source bytes\n")
        with self.assertRaises(product.ProductBuildRefusal):
            held.current()

    def test_source_mode_change_refuses(self):
        held = self.held()
        os.chmod(self.leaf, 0o600 if self.leaf.stat().st_mode & 0o077 else 0o644)
        with self.assertRaises(product.ProductBuildRefusal):
            held.current()

    def test_product_hardlink_refuses(self):
        os.link(self.leaf, self.root / "alias")
        with self.assertRaises(product.ProductBuildRefusal):
            product._snapshot(self.root, time.monotonic() + 10)

    def test_product_directory_symlink_refuses(self):
        outside = self.root / "real"
        outside.mkdir()
        (self.root / "linked").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(product.ProductBuildRefusal):
            product._snapshot(self.root, time.monotonic() + 10)

    def test_existing_destination_refuses(self):
        before = self.leaf.read_bytes()
        with self.assertRaises(FileExistsError):
            product._write_exclusive(self.leaf, b"not a replacement", 0o644, time.monotonic() + 10)
        self.assertEqual(self.leaf.read_bytes(), before)

    def test_compiled_copy_hash_mismatch_refuses(self):
        stamp = product.identity(self.leaf.stat())
        with self.assertRaises(product.ProductBuildRefusal):
            product._compiled_bytes(
                self.leaf,
                (stamp, hashlib.sha256(b"other bytes").hexdigest()),
                time.monotonic() + 10,
            )

    def commands(self):
        work = self.root / "work"
        work.mkdir()
        sdk = self.root / "MacOSX.sdk"
        sdk.mkdir()
        headers = self.root / "hs-lua-headers"
        headers.mkdir()
        return dict(product.compile_commands(self.root, work, sdk, headers))

    def test_exact_both_architecture_compile_rosters(self):
        commands = self.commands()
        self.assertEqual(
            set(commands),
            {
                "lifecycle_arm64",
                "lifecycle_x86_64",
                "installer_arm64",
                "installer_x86_64",
                "validator_arm64",
                "validator_x86_64",
                "module_arm64",
                "module_x86_64",
                "installer_universal",
                "validator_universal",
                "module_universal",
            },
        )
        for arch in ("arm64", "x86_64"):
            self.assertIn(arch + "-apple-macosx13.0", commands["installer_" + arch])
            self.assertIn(
                str(self.root / product.SWIFT / "OwnedRuntimePublisherIdentity.swift"),
                commands["installer_" + arch],
            )
            self.assertIn(
                str(self.root / product.SWIFT / "OwnedRuntimePublisherIdentity.swift"),
                commands["validator_" + arch],
            )
            self.assertNotIn(
                str(self.root / product.SWIFT / "Main.swift"), commands["installer_" + arch]
            )

    def test_lifecycle_object_links_only_installer_once(self):
        commands = self.commands()
        for arch in ("arm64", "x86_64"):
            object_path = str(self.root / "work" / ("lifecycle_" + arch + ".o"))
            self.assertEqual(commands["installer_" + arch].count(object_path), 1)
            self.assertNotIn(object_path, commands["validator_" + arch])
            self.assertNotIn(object_path, commands["module_" + arch])

    def test_module_uses_only_fixed_repository_and_hs_headers(self):
        commands = self.commands()
        for arch in ("arm64", "x86_64"):
            argv = commands["module_" + arch]
            self.assertEqual(
                [argv[i + 1] for i, v in enumerate(argv) if v == "-I"],
                [str(self.root / "hs-lua-headers"), str(self.root / "tools/build")],
            )
            self.assertIn("-bundle", argv)
            self.assertIn(str(self.root / product.MODULE_SOURCE), argv)

    def test_signature_header_reaches_both_native_swift_products(self):
        commands = self.commands()
        self.assertEqual(
            product.SIGNATURE_HEADER,
            product.LAUNCHER + "CPOSIXCompatibility/include/OwnedRuntimeSignatureCompatibility.h",
        )
        self.assertEqual(product.SOURCE_PATHS.count(product.SIGNATURE_HEADER), 1)
        header = str(self.root / product.SIGNATURE_HEADER)
        for arch in ("arm64", "x86_64"):
            for role in ("installer", "validator"):
                argv = commands[role + "_" + arch]
                self.assertEqual(argv.count("-import-objc-header"), 1)
                self.assertEqual(argv[argv.index("-import-objc-header") + 1], header)
            self.assertNotIn("-import-objc-header", commands["module_" + arch])

    def test_expired_copy_deadline_refuses(self):
        stamp = (
            product.identity(self.leaf.stat()),
            hashlib.sha256(self.leaf.read_bytes()).hexdigest(),
        )
        with self.assertRaises(product.ProductBuildRefusal):
            product._compiled_bytes(self.leaf, stamp, time.monotonic() - 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
