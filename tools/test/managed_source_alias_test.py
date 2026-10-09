# tools/test/managed_source_alias_test.py
"""Independent retained-FD/census controls; no Darwin execution/signing credit."""

import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(value)
    return value


ALIASES = load(
    "source_alias_controls",
    ROOT / "static/ergopti_plus/_shared/python/managed_source_alias.py",
)
POLICY = load(
    "alias_catalogue_controls",
    ROOT / "static/ergopti_plus/_shared/python/managed_ollama_runtime.py",
)
FINGERPRINT = "4f382b08854345f22682de3701228b9a132034a7b29b74a95cb52d7c1330e960"


class RetainedAliasReceiving(unittest.TestCase):
    def setUp(self):
        if os.name != "posix":
            self.skipTest("Actual dir-FD source alias receiving requires the Darwin/POSIX port")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.anchor = Path(self.temporary.name)
        self.anchor.chmod(0o700)
        self.root = self.anchor / "runtime"
        self.root.mkdir(mode=0o755)
        self.root.chmod(0o755)
        binary = self.root / "ollama"
        binary.write_bytes(b"independent executable bytes")
        binary.chmod(0o755)
        self.nonce = "0123456789abcdef0123456789abcdef"
        self.image = self.root / (".ergopti-image-" + self.nonce)
        os.link(binary, self.image)
        self.lease = self.root / (".ergopti-lease-" + self.nonce)
        self.lease.mkdir(mode=0o700)
        self.proof = {"version": 1, "nonce": self.nonce, "binary_sha256": FINGERPRINT}
        for stem, path in (
            ("directory", self.root),
            ("ancestor", self.anchor),
            ("lease", self.lease),
        ):
            self.proof[stem + "_device"] = str(path.stat().st_dev)
            self.proof[stem + "_inode"] = str(path.stat().st_ino)
        self.source = {
            "device": str(binary.stat().st_dev),
            "inode": str(binary.stat().st_ino),
        }
        self.marker = self.lease / "source.json"
        self.marker.write_bytes(
            json.dumps(self.proof | self.source, sort_keys=True, separators=(",", ":")).encode()
        )
        self.marker.chmod(0o600)
        (self.root / "LICENSE.ollama").write_bytes(b"independent license")
        self.asset = {"binary_sha256": FINGERPRINT, "runtime_libraries_sha256": {}}
        self.contract = {"binary_path": "ollama", "license_path": "LICENSE.ollama"}

    def context(self, **options):
        return ALIASES.AliasContext(
            self.root,
            options.get("proof", self.proof),
            options.get("source_identity", self.source),
            options.get("fingerprint", FINGERPRINT),
            progress=options.get("progress", lambda: None),
        )

    def refused(self, **options):
        with self.assertRaises((ALIASES.AliasRefusal, OSError)):
            self.context(**options)

    def test_exact_same_vnode_alias_receives_only_two_extra_files(self):
        with self.context() as context:
            self.assertEqual(
                context.additional_files,
                {
                    ".ergopti-image-" + self.nonce,
                    ".ergopti-lease-" + self.nonce + "/source.json",
                },
            )
            self.assertEqual(
                POLICY.verify_directory(
                    self.root, self.contract, self.asset, alias_context=context
                ),
                self.root / "ollama",
            )
            self.assertEqual((self.root / "ollama").stat().st_ino, self.image.stat().st_ino)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.assertTrue(self.image.exists())
        self.assertTrue(self.marker.exists())

    def test_generic_catalogue_admission_still_refuses_alias_extras(self):
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.verify_directory(self.root, self.contract, self.asset)

    def test_each_exact_proof_identity_is_required(self):
        for name in (
            "directory_device",
            "directory_inode",
            "ancestor_device",
            "ancestor_inode",
            "lease_device",
            "lease_inode",
        ):
            value = dict(self.proof)
            value[name] = str(int(value[name]) + 1)
            with self.subTest(field=name):
                self.refused(proof=value)

    def test_original_session_identity_cannot_be_rederived_from_ui_proof(self):
        for name in ("device", "inode"):
            value = dict(self.source)
            value[name] = str(int(value[name]) + 1)
            with self.subTest(field=name):
                self.refused(source_identity=value)
        self.refused(source_identity=None)

    def test_proof_schema_and_uint64_decimal_types_are_exact(self):
        for name, wrong in (
            ("version", True),
            ("version", 2),
            ("nonce", "f" * 31),
            ("nonce", "F" * 32),
            ("directory_inode", 1),
            ("directory_inode", "01"),
            ("directory_inode", str(2**64)),
            ("ancestor_device", str(2**32)),
            ("lease_inode", "0"),
            ("binary_sha256", "bad"),
        ):
            value = dict(self.proof)
            value[name] = wrong
            with self.subTest(field=name, kind=type(wrong).__name__):
                self.refused(proof=value)
        self.refused(proof=self.proof | {"unknown": 1})

    def test_actual_apfs_sized_identity_strings_remain_lossless(self):
        value = self.proof | {"directory_inode": "1152921500312523020"}
        self.assertEqual(ALIASES.proof_fields(value)["directory_inode"], "1152921500312523020")
        self.assertEqual(ALIASES.decimal("1152921500312523020", 2**64 - 1), 1152921500312523020)

    def test_catalogue_fingerprint_and_actual_binary_bytes_both_required(self):
        self.refused(fingerprint="f" * 64)
        (self.root / "ollama").write_bytes(b"foreign executable bytes")
        self.refused()

    def test_replaced_alias_inode_cannot_supply_source_authority(self):
        self.image.unlink()
        self.image.write_bytes(b"independent executable bytes")
        self.image.chmod(0o755)
        self.refused()

    def test_additional_foreign_hard_link_refuses(self):
        os.link(self.image, self.anchor / "foreign")
        self.refused()

    def test_source_alias_marker_symlinks_refuse(self):
        for name in ("image", "marker"):
            path = getattr(self, name)
            original = path.with_name(path.name + "-original")
            path.rename(original)
            path.symlink_to(original.name)
            with self.subTest(name=name):
                self.refused()
            path.unlink()
            original.rename(path)

    def test_marker_bytes_and_permissions_are_exact(self):
        original = self.marker.read_bytes()
        self.marker.write_bytes(original + b"\n")
        self.refused()
        self.marker.write_bytes(original)
        self.marker.chmod(0o644)
        self.refused()

    def test_foreign_lease_file_is_never_excluded_from_census(self):
        (self.lease / "foreign").write_bytes(b"foreign lease state")
        self.refused()
        self.assertEqual((self.lease / "foreign").read_bytes(), b"foreign lease state")

    def test_unknown_nonce_directories_and_images_refuse(self):
        foreign = self.root / (".ergopti-lease-" + "f" * 32)
        foreign.mkdir(mode=0o700)
        self.refused()
        foreign.rmdir()
        foreign = self.root / (".ergopti-image-" + "f" * 32)
        foreign.write_bytes(b"foreign image")
        self.refused()

    def test_unknown_runtime_file_still_refuses_with_valid_alias(self):
        (self.root / "foreign.dylib").write_bytes(b"foreign runtime bytes")
        with self.context() as context:
            with self.assertRaises(POLICY.RuntimeRefusal):
                POLICY.verify_directory(self.root, self.contract, self.asset, alias_context=context)

    def test_writable_runtime_and_intermediate_ancestors_refuse(self):
        self.root.chmod(0o775)
        self.refused()
        self.root.chmod(0o755)
        self.anchor.chmod(0o775)
        self.refused()

    def test_nonprivate_lease_refuses(self):
        self.lease.chmod(0o755)
        self.refused()

    def test_namespace_replacement_after_admission_is_detected_before_completion(self):
        context = self.context()
        self.image.unlink()
        self.image.write_bytes(b"foreign replacement")
        try:
            with self.assertRaises(ALIASES.AliasRefusal):
                context.validate()
        finally:
            context.close()
        self.assertEqual(self.image.read_bytes(), b"foreign replacement")

    def test_inplace_write_after_admission_is_detected_under_retained_fd(self):
        context = self.context()
        (self.root / "ollama").write_bytes(b"foreign overwrite")
        try:
            with self.assertRaises(ALIASES.AliasRefusal):
                context.validate()
        finally:
            context.close()

    def test_success_context_closes_every_actual_retained_fd(self):
        context = self.context()
        descriptors = tuple(context._fds.values())
        with context:
            pass
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        self.assertEqual(context._fds, {})

    def test_early_original_clock_expiry_closes_all_acquired_descriptors(self):
        opened = []
        actual_open = os.open

        def capture(*args, **options):
            descriptor = actual_open(*args, **options)
            opened.append(descriptor)
            return descriptor

        def expired():
            if opened:
                raise TimeoutError("deadline")

        with patch.object(ALIASES.os, "open", side_effect=capture):
            with self.assertRaises(TimeoutError):
                self.context(progress=expired)
        self.assertGreater(len(opened), 0)
        for descriptor in opened:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_actual_sigint_during_close_retires_remaining_fds_and_retains_debt(self):
        context = self.context()
        descriptors = tuple(context._fds.values())
        actual_close = os.close
        previous = signal.signal(signal.SIGINT, signal.default_int_handler)
        interrupted = False
        attempts = []

        def interrupt_after_physical_close(descriptor):
            nonlocal interrupted
            attempts.append(descriptor)
            actual_close(descriptor)
            if not interrupted:
                interrupted = True
                os.kill(os.getpid(), signal.SIGINT)

        try:
            with patch.object(ALIASES.os, "close", side_effect=interrupt_after_physical_close):
                with self.assertRaises(ALIASES.AliasRefusal) as caught:
                    context.close()
                self.assertIsInstance(caught.exception.cleanup, KeyboardInterrupt)
                with self.assertRaises(ALIASES.AliasRefusal):
                    context.close()
            self.assertTrue(interrupted)
            self.assertEqual(attempts, list(descriptors))
            self.assertEqual(context._fds, {})
            for descriptor in descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
        finally:
            signal.signal(signal.SIGINT, previous)
            # This finalizer retains the real old-source refusal without leaking
            # the observed remaining descriptors when receiving the regression.
            for descriptor in tuple(context._fds.values()):
                actual_close(descriptor)
            context._fds.clear()

    def test_primary_byte_refusal_and_uncertain_cleanup_remain_distinct(self):
        (self.root / "ollama").write_bytes(b"foreign original bytes")
        actual_close = os.close
        attempts = []

        def uncertain(descriptor):
            actual_close(descriptor)
            if not attempts:
                attempts.append(descriptor)
                raise OSError(errno.EINTR, "uncertain close")

        with patch.object(ALIASES.os, "close", side_effect=uncertain):
            with self.assertRaises(ALIASES.AliasRefusal) as caught:
                self.context()
        self.assertEqual(str(caught.exception), "operation")
        self.assertIsInstance(caught.exception.primary, ALIASES.AliasRefusal)
        self.assertEqual(str(caught.exception.primary), "admission")
        self.assertIsInstance(caught.exception.cleanup, ALIASES.AliasRefusal)
        self.assertEqual(str(caught.exception.cleanup), "cleanup")
        self.assertEqual(caught.exception.cleanup.cleanup.errno, errno.EINTR)
        self.assertEqual(len(attempts), 1)

    def test_uncertain_close_never_recloses_reused_foreign_fd(self):
        context = self.context()
        target = next(iter(context._fds.values()))
        foreign = self.anchor / "foreign"
        foreign.write_bytes(b"foreign FD survives")
        actual_close = os.close
        reused = []
        attempts = []

        def uncertain(descriptor):
            if descriptor == target:
                attempts.append(descriptor)
                actual_close(descriptor)
                replacement = os.open(foreign, os.O_RDONLY | os.O_CLOEXEC)
                self.assertEqual(replacement, descriptor)
                reused.append(replacement)
                raise OSError(errno.EINTR, "uncertain close")
            actual_close(descriptor)

        try:
            with patch.object(ALIASES.os, "close", side_effect=uncertain):
                with self.assertRaises(ALIASES.AliasRefusal):
                    context.close()
                with self.assertRaises(ALIASES.AliasRefusal):
                    context.close()
            self.assertEqual(attempts, [target])
            self.assertEqual(os.pread(reused[0], 64, 0), b"foreign FD survives")
        finally:
            for descriptor in reused:
                actual_close(descriptor)


if __name__ == "__main__":
    unittest.main()
