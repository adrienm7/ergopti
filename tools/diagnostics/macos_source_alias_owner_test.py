# tools/diagnostics/macos_source_alias_owner_test.py
"""Actual POSIX acquisition/cleanup; native image and daemon tests are separate."""

import errno
import importlib.util
import os
from pathlib import Path
import signal
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "alias_native_owner", ROOT / "static/ergopti_plus/macos/platform/source_alias_owner.py"
)
OWNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OWNER)
FINGERPRINT = "4f382b08854345f22682de3701228b9a132034a7b29b74a95cb52d7c1330e960"


class ActualAliasOwnership(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.anchor = Path(self.temporary.name)
        self.anchor.chmod(0o700)
        self.root = self.anchor / "runtime"
        self.root.mkdir(mode=0o755)
        self.root.chmod(0o755)
        self.binary = self.root / "ollama"
        self.binary.write_bytes(b"independent executable bytes")
        self.binary.chmod(0o755)
        self.source = os.open(self.binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        self.addCleanup(os.close, self.source)
        identity = os.fstat(self.source)
        self.identity = {"device": str(identity.st_dev), "inode": str(identity.st_ino)}
        self.registered = None

    def acquire(self, *, fingerprint=FINGERPRINT, progress=lambda: None):
        def register(value):
            self.registered = value

        return OWNER.AliasOwner.acquire(
            self.root, self.source, self.identity, fingerprint, register=register, progress=progress
        )

    def test_actual_native_link_preserves_catalogue_inode_bytes_and_dylib_directory(self):
        alias = self.acquire()
        self.assertEqual(alias.executable.parent, self.root.resolve())
        self.assertEqual(alias.executable.stat().st_ino, os.fstat(self.source).st_ino)
        self.assertEqual(alias.executable.read_bytes(), b"independent executable bytes")
        self.assertEqual(self.binary.stat().st_nlink, 2)
        with alias.context():
            pass
        alias.retire()
        self.assertEqual(list(self.root.iterdir()), [self.binary])
        self.assertEqual(self.binary.stat().st_nlink, 1)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.assertEqual(os.pread(self.source, 64, 0), b"independent executable bytes")

    def test_original_source_unlink_after_acquisition_never_reopens_original(self):
        alias = self.acquire()
        self.binary.unlink()
        self.assertEqual(alias.executable.stat().st_ino, os.fstat(self.source).st_ino)
        self.assertEqual(alias.executable.read_bytes(), b"independent executable bytes")
        alias.retire()
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertEqual(os.pread(self.source, 64, 0), b"independent executable bytes")

    def test_replacement_before_link_refuses_and_preserves_foreign_binary(self):
        self.binary.unlink()
        self.binary.write_bytes(b"foreign user bytes")
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            self.acquire()
        self.assertEqual(self.binary.read_bytes(), b"foreign user bytes")
        self.assertEqual(list(self.root.iterdir()), [self.binary])
        self.assertEqual(self.registered._fds, {})

    def test_raced_source_link_never_passes_held_inode_fence(self):
        actual_link = os.link

        def raced(source, target, **options):
            self.binary.unlink()
            self.binary.write_bytes(b"foreign source race")
            actual_link(source, target, **options)

        with patch.object(OWNER.os, "link", side_effect=raced):
            with self.assertRaises(OWNER.POLICY.AliasRefusal):
                self.acquire()
        self.assertEqual(self.binary.read_bytes(), b"foreign source race")
        self.assertEqual(list(self.root.iterdir()), [self.binary])

    def test_primary_hash_refusal_removes_only_owned_empty_lease(self):
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            self.acquire(fingerprint="f" * 64)
        self.assertEqual(self.binary.read_bytes(), b"independent executable bytes")
        self.assertEqual(list(self.root.iterdir()), [self.binary])
        self.assertEqual(self.registered._fds, {})

    def test_writable_namespace_refuses_before_private_names(self):
        self.root.chmod(0o775)
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            self.acquire()
        self.assertEqual(list(self.root.iterdir()), [self.binary])

    def test_live_bound_operation_keeps_alias_and_lease_owned(self):
        alias = self.acquire()
        operation = SimpleNamespace(physically_retired=False)
        alias.bind_operation(operation)
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            alias.retire()
        self.assertTrue(alias.executable.exists())
        self.assertGreater(len(alias._fds), 0)
        operation.physically_retired = True
        alias.retire()
        self.assertEqual(list(self.root.iterdir()), [self.binary])

    def test_duplicate_operation_binding_refuses(self):
        alias = self.acquire()
        alias.bind_operation(SimpleNamespace(physically_retired=True))
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            alias.bind_operation(SimpleNamespace(physically_retired=True))
        alias.retire()

    def test_partial_image_unlink_retry_uses_retained_vnode_without_lease_reopen(self):
        alias = self.acquire()
        actual_unlink = os.unlink
        failed = False

        def refuse_image(name, **options):
            nonlocal failed
            if name == alias.image_name and not failed:
                failed = True
                raise OSError(errno.EIO, "injected native unlink refusal")
            actual_unlink(name, **options)

        with patch.object(OWNER.os, "unlink", side_effect=refuse_image):
            with self.assertRaises(OSError):
                alias.retire()
        self.assertEqual(alias._created, {"image"})
        self.assertTrue(alias.executable.exists())
        self.assertFalse((self.root / alias.lease_name).exists())
        alias.retire()
        self.assertEqual(list(self.root.iterdir()), [self.binary])

    def test_unknown_lease_file_retains_cleanup_debt_and_foreign_state(self):
        alias = self.acquire()
        foreign = self.root / alias.lease_name / "foreign"
        foreign.write_bytes(b"foreign lease state")
        with self.assertRaises(OSError):
            alias.retire()
        self.assertEqual(foreign.read_bytes(), b"foreign lease state")
        self.assertTrue(alias.executable.exists())
        self.assertGreater(len(alias._fds), 0)
        foreign.unlink()
        alias.retire()

    def test_replaced_image_name_never_deletes_foreign_file(self):
        alias = self.acquire()
        image = alias.executable
        image.unlink()
        image.write_bytes(b"foreign image")
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            alias.retire()
        self.assertEqual(image.read_bytes(), b"foreign image")
        # A changed namespace never authorizes cleanup. Final fixture retirement
        # closes only actually retained descriptor references without claiming success.
        for key in tuple(alias._fds):
            alias._close(key)

    def test_original_source_identity_cannot_be_rederived_from_namespace(self):
        self.identity["inode"] = str(int(self.identity["inode"]) + 1)
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            self.acquire()
        self.assertEqual(list(self.root.iterdir()), [self.binary])
        self.assertEqual(self.registered._fds, {})

    def test_readwrite_source_fd_refuses(self):
        writable = os.open(self.binary, os.O_RDWR | os.O_CLOEXEC)
        try:

            def register(value):
                self.registered = value

            with self.assertRaises(OWNER.POLICY.AliasRefusal):
                OWNER.AliasOwner.acquire(
                    self.root,
                    writable,
                    self.identity,
                    FINGERPRINT,
                    register=register,
                    progress=lambda: None,
                )
            self.assertEqual(list(self.root.iterdir()), [self.binary])
        finally:
            os.close(writable)

    def test_preexisting_nonce_image_survives_refused_acquisition(self):
        nonce = "f" * 32
        foreign = self.root / (".ergopti-image-" + nonce)
        foreign.write_bytes(b"foreign preexisting image")
        with patch.object(OWNER.secrets, "token_hex", return_value=nonce):
            with self.assertRaises(FileExistsError):
                self.acquire()
        self.assertEqual(foreign.read_bytes(), b"foreign preexisting image")
        self.assertEqual(list(self.root.glob(".ergopti-lease-*")), [])

    def test_partial_marker_write_failure_removes_only_actual_owned_prefix(self):
        actual_write = os.write
        writes = 0

        def partial(descriptor, data):
            nonlocal writes
            writes += 1
            if writes == 1:
                return actual_write(descriptor, data[:3])
            raise OSError(errno.EIO, "injected actual marker write failure")

        with patch.object(OWNER.os, "write", side_effect=partial):
            with self.assertRaises(OSError):
                self.acquire()
        self.assertEqual(writes, 2)
        self.assertEqual(list(self.root.iterdir()), [self.binary])
        self.assertEqual(self.registered._fds, {})

    def test_foreign_marker_replacement_refuses_without_deleting_its_bytes(self):
        alias = self.acquire()
        marker = self.root / alias.lease_name / "source.json"
        marker.unlink()
        marker.write_bytes(b"foreign marker bytes")
        with self.assertRaises(OWNER.POLICY.AliasRefusal):
            alias.retire()
        self.assertEqual(marker.read_bytes(), b"foreign marker bytes")
        for key in tuple(alias._fds):
            alias._close(key)

    def test_actual_sigint_during_close_continues_remaining_fd_retirement(self):
        alias = self.acquire()
        actual_close = os.close
        previous = signal.signal(signal.SIGINT, signal.default_int_handler)
        interrupted = False
        attempts = []

        def interrupted_close(descriptor):
            nonlocal interrupted
            attempts.append(descriptor)
            actual_close(descriptor)
            if not interrupted:
                interrupted = True
                os.kill(os.getpid(), signal.SIGINT)

        descriptors = tuple(alias._fds.values())
        try:
            with patch.object(OWNER.os, "close", side_effect=interrupted_close):
                with self.assertRaises(OWNER.POLICY.AliasRefusal) as caught:
                    alias.retire()
                self.assertIsInstance(caught.exception.cleanup, KeyboardInterrupt)
                with self.assertRaises(OWNER.POLICY.AliasRefusal):
                    alias.retire()
            self.assertCountEqual(attempts, descriptors)
            self.assertEqual(alias._fds, {})
            for descriptor in descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
        finally:
            signal.signal(signal.SIGINT, previous)

    def test_primary_refusal_and_close_failure_remain_distinct(self):
        actual_close = os.close
        failed = False

        def fail_once(descriptor):
            nonlocal failed
            actual_close(descriptor)
            if not failed:
                failed = True
                raise OSError(errno.EINTR, "uncertain close")

        with patch.object(OWNER.os, "close", side_effect=fail_once):
            with self.assertRaises(OWNER.POLICY.AliasRefusal) as caught:
                self.acquire(fingerprint="f" * 64)
        self.assertEqual(str(caught.exception), "operation")
        self.assertEqual(str(caught.exception.primary), "admission")
        self.assertEqual(str(caught.exception.cleanup), "cleanup")
        self.assertEqual(caught.exception.cleanup.cleanup.errno, errno.EINTR)
        self.assertEqual(self.registered._fds, {})

    def test_uncertain_close_retires_numeric_reference_and_preserves_foreign_fd(self):
        alias = self.acquire()
        target = alias._fds["marker"]
        foreign = self.anchor / "foreign"
        foreign.write_bytes(b"foreign descriptor")
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
            with patch.object(OWNER.os, "close", side_effect=uncertain):
                with self.assertRaises(OWNER.POLICY.AliasRefusal):
                    alias.retire()
                with self.assertRaises(OWNER.POLICY.AliasRefusal):
                    alias.retire()
            self.assertEqual(attempts, [target])
            self.assertEqual(alias._fds, {})
            self.assertEqual(os.pread(reused[0], 64, 0), b"foreign descriptor")
        finally:
            for descriptor in reused:
                actual_close(descriptor)


if __name__ == "__main__":
    unittest.main()
