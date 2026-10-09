# tools/diagnostics/macos_owned_image_alias_test.py
"""Receive real POSIX hard links and private alias fences; Darwin SDK/exec is separate."""

import ctypes
import errno
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


class Alias(ctypes.Structure):
    _fields_ = (
        [(name, ctypes.c_int) for name in ("directory_fd", "lease_fd", "image_fd", "ancestor_fd")]
        + [(name, ctypes.c_uint32) for name in ("lease_created", "image_created")]
        + [("close_error", ctypes.c_int32)]
        + [
            (name, ctypes.c_uint64)
            for name in (
                "directory_device",
                "directory_inode",
                "ancestor_device",
                "ancestor_inode",
                "lease_device",
                "lease_inode",
                "device",
                "inode",
            )
        ]
        + [("nonce", ctypes.c_char * 33), ("executable", ctypes.c_char * 4096)]
    )


FAULT_SOURCE = r"""#include "OwnedImageAliasCompatibility.h"
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
static int unlink_fault;
static int close_fault;
static int foreign_source = -1;
static int foreign_duplicate = -1;
static int original_close_attempts;
static int original_descriptor = -1;
size_t test_alias_size(void) { return sizeof(ergopti_owned_image_alias); }
void test_faults(int unlink_image, int uncertain_close, int foreign_fd) {
    unlink_fault = unlink_image; close_fault = uncertain_close;
    foreign_source = foreign_fd; foreign_duplicate = -1;
    original_descriptor = -1; original_close_attempts = 0;
}
int test_foreign_duplicate(void) { return foreign_duplicate; }
int test_original_close_attempts(void) { return original_close_attempts; }
int controlled_unlinkat(int fd, const char *name, int flags) {
    if (unlink_fault && strncmp(name, ".ergopti-image-", 15) == 0) {
        unlink_fault = 0; errno = EIO; return -1;
    }
    return unlinkat(fd, name, flags);
}
int controlled_close(int fd) {
    if (fd == original_descriptor) { original_close_attempts++; }
    if (close_fault) {
        close_fault = 0; original_descriptor = fd; original_close_attempts = 1;
        if (close(fd) != 0) { return -1; }
        foreign_duplicate = fcntl(foreign_source, F_DUPFD_CLOEXEC, fd);
        if (foreign_duplicate != fd) { errno = EIO; return -1; }
        errno = EINTR; return -1;
    }
    return close(fd);
}
"""


class ActualAliasControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name != "posix":
            raise RuntimeError("Actual POSIX alias receiving requires a native POSIX host")
        cls.build = TemporaryDirectory(prefix="ergopti-owned-alias-controls-")
        cls.addClassCleanup(cls.build.cleanup)
        root = Path(__file__).resolve().parents[2]
        source = (
            root
            / "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/OwnedImageAliasCompatibility.c"
        )
        include = source.parent / "include"
        binary = Path(cls.build.name) / "alias-library"
        compiler = (
            ["/usr/bin/xcrun", "clang"] if sys.platform == "darwin" else ["cc", "-D_GNU_SOURCE"]
        )
        controls = Path(cls.build.name) / "faults.c"
        controls.write_text(FAULT_SOURCE, encoding="utf-8", newline="\n")
        object_file = Path(cls.build.name) / "alias.o"
        compile_common = compiler + [
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-fPIC",
            "-I",
            str(include),
        ]
        subprocess.run(
            compile_common
            + [
                "-Dclose=controlled_close",
                "-Dunlinkat=controlled_unlinkat",
                "-c",
                str(source),
                "-o",
                str(object_file),
            ],
            check=True,
            timeout=30,
            capture_output=True,
        )
        subprocess.run(
            compile_common + ["-shared", str(controls), str(object_file), "-o", str(binary)],
            check=True,
            timeout=30,
            capture_output=True,
        )
        cls.native = ctypes.CDLL(str(binary), use_errno=True)
        cls.native.test_alias_size.restype = ctypes.c_size_t
        if cls.native.test_alias_size() != ctypes.sizeof(Alias):
            raise RuntimeError(
                "Independent receiving ABI does not match the actual compiled C SDK record"
            )
        cls.native.test_faults.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
        cls.native.test_foreign_duplicate.restype = ctypes.c_int
        cls.native.test_original_close_attempts.restype = ctypes.c_int
        cls.native.ergopti_image_alias_create.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.POINTER(Alias),
        ]
        cls.native.ergopti_image_alias_admit.argtypes = (
            [ctypes.c_char_p, ctypes.c_char_p] + [ctypes.c_uint64] * 8 + [ctypes.POINTER(Alias)]
        )
        for name in ("create", "admit", "close", "retire"):
            getattr(cls.native, "ergopti_image_alias_" + name).restype = ctypes.c_int
        for name in ("close", "retire"):
            getattr(cls.native, "ergopti_image_alias_" + name).argtypes = [ctypes.POINTER(Alias)]

    def setUp(self):
        self.native.test_faults(0, 0, -1)
        self.temporary = TemporaryDirectory(prefix="ergopti-owned-alias-")
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.source = self.root / "ollama"
        self.source.write_bytes(b"independent original executable bytes")
        self.source.chmod(0o755)
        self.descriptor = os.open(self.source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        self.addCleanup(os.close, self.descriptor)
        self.addCleanup(self.temporary.cleanup)
        self.aliases = []
        self.addCleanup(self.close_all)
        self.nonce = b"0123456789abcdef0123456789abcdef"

    def close_all(self):
        for alias in self.aliases:
            self.native.ergopti_image_alias_close(ctypes.byref(alias))

    def acquire(self, descriptor=None, nonce=None):
        alias = Alias()
        self.aliases.append(alias)
        result = self.native.ergopti_image_alias_create(
            self.descriptor if descriptor is None else descriptor,
            os.fsencode(self.root),
            self.nonce if nonce is None else nonce,
            ctypes.byref(alias),
        )
        return result, alias

    def admit(self, owner, **changes):
        alias = Alias()
        self.aliases.append(alias)
        fields = {
            name: getattr(owner, name)
            for name in (
                "directory_device",
                "directory_inode",
                "ancestor_device",
                "ancestor_inode",
                "lease_device",
                "lease_inode",
                "device",
                "inode",
            )
        }
        nonce = changes.pop("nonce", self.nonce)
        fields.update(changes)
        return self.native.ergopti_image_alias_admit(
            os.fsencode(self.root), nonce, *fields.values(), ctypes.byref(alias)
        ), alias

    def test_same_vnode_link_preserves_held_bytes_and_dylib_directory(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        self.assertEqual(
            (owner.device, owner.inode),
            (os.fstat(self.descriptor).st_dev, os.fstat(self.descriptor).st_ino),
        )
        path = Path(os.fsdecode(owner.executable))
        self.assertEqual(path.parent, self.root.resolve())
        self.assertEqual(path.read_bytes(), b"independent original executable bytes")
        self.assertEqual(os.fstat(self.descriptor).st_nlink, 2)
        result, borrowed = self.admit(owner)
        self.assertEqual(result, 0)
        self.assertEqual((borrowed.device, borrowed.inode), (owner.device, owner.inode))
        self.assertEqual(self.native.ergopti_image_alias_close(ctypes.byref(borrowed)), 0)
        self.assertTrue(path.exists(), "Request borrower must never delete source owner state")
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertFalse(path.exists())
        self.assertEqual(os.fstat(self.descriptor).st_nlink, 1)

    def test_original_unlink_after_alias_does_not_reopen_or_change_source_vnode(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        self.source.unlink()
        result, borrowed = self.admit(owner)
        self.assertEqual(result, 0)
        self.assertEqual(
            os.pread(borrowed.image_fd, 64, 0), b"independent original executable bytes"
        )
        self.assertEqual(os.fstat(borrowed.image_fd).st_ino, os.fstat(self.descriptor).st_ino)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual(os.fstat(self.descriptor).st_nlink, 0)

    def test_source_replaced_before_link_cannot_publish_foreign_bytes(self):
        self.source.unlink()
        self.source.write_bytes(b"foreign replacement must survive")
        result, owner = self.acquire()
        self.assertEqual(result, errno.ESTALE)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual(self.source.read_bytes(), b"foreign replacement must survive")
        self.assertEqual(os.pread(self.descriptor, 64, 0), b"independent original executable bytes")
        self.assertEqual(list(self.root.glob(".ergopti-*")), [])

    def test_missing_source_before_alias_refuses_no_empty_path_fd_link(self):
        self.source.unlink()
        result, owner = self.acquire()
        self.assertEqual(result, errno.ENOENT)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_writable_source_descriptor_never_acquires_alias_authority(self):
        descriptor = os.open(self.source, os.O_RDWR)
        try:
            result, owner = self.acquire(descriptor)
            self.assertEqual(result, errno.EPERM)
            self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        finally:
            os.close(descriptor)

    def test_each_exact_directory_lease_and_catalogue_identity_fence_is_required(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        for name in (
            "directory_device",
            "directory_inode",
            "lease_device",
            "lease_inode",
            "device",
            "inode",
        ):
            with self.subTest(field=name):
                result, _alias = self.admit(owner, **{name: getattr(owner, name) + 1})
                self.assertEqual(result, errno.ESTALE)

    def test_unknown_nonce_alias_cannot_borrow_source_authority(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        result, _alias = self.admit(owner, nonce=b"f" * 32)
        self.assertNotEqual(result, 0)

    def test_runtime_directory_must_remain_private(self):
        self.root.chmod(0o775)
        result, owner = self.acquire()
        self.assertEqual(result, errno.ESTALE)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual(list(self.root.glob(".ergopti-*")), [])

    def test_pinned_runtime_755_mode_is_preserved_under_exact_owned_private_ancestor(
        self,
    ):
        parent = self.root
        runtime = parent / "runtime"
        runtime.mkdir(mode=0o755)
        runtime.chmod(0o755)
        self.source.rename(runtime / "ollama")
        self.root = runtime
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        self.assertEqual(runtime.stat().st_mode & 0o777, 0o755)
        self.assertEqual(
            (owner.ancestor_device, owner.ancestor_inode),
            (parent.stat().st_dev, parent.stat().st_ino),
        )
        result, borrowed = self.admit(owner)
        self.assertEqual(result, 0)
        self.assertEqual(self.native.ergopti_image_alias_close(ctypes.byref(borrowed)), 0)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual(runtime.stat().st_mode & 0o777, 0o755)

    def test_uncertain_ancestor_walk_close_remains_debt_and_never_recloses_foreign_fd(
        self,
    ):
        runtime = self.root / "runtime"
        runtime.mkdir(mode=0o755)
        runtime.chmod(0o755)
        self.source.rename(runtime / "ollama")
        self.root = runtime
        foreign = runtime / "foreign"
        foreign.write_bytes(b"foreign ancestor descriptor")
        descriptor = os.open(foreign, os.O_RDONLY)
        duplicate = -1
        try:
            self.native.test_faults(0, 1, descriptor)
            primary, owner = self.acquire()
            duplicate = self.native.test_foreign_duplicate()
            self.assertEqual(primary, errno.EINTR)
            self.assertEqual(owner.close_error, errno.EINTR)
            self.assertGreaterEqual(duplicate, 0)
            self.assertEqual(
                self.native.ergopti_image_alias_retire(ctypes.byref(owner)), errno.EINTR
            )
            self.assertEqual(self.native.test_original_close_attempts(), 1)
            self.assertEqual(os.pread(duplicate, 64, 0), b"foreign ancestor descriptor")
            self.assertEqual(list(runtime.glob(".ergopti-*")), [])
        finally:
            if duplicate >= 0:
                os.close(duplicate)
            os.close(descriptor)

    def test_lease_directory_must_remain_private(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        (self.root / (".ergopti-lease-" + self.nonce.decode())).chmod(0o755)
        result, _alias = self.admit(owner)
        self.assertEqual(result, errno.EPERM)

    def test_preexisting_lease_is_refused_without_overwriting_user_state(self):
        lease = self.root / (".ergopti-lease-" + self.nonce.decode())
        lease.mkdir(mode=0o700)
        (lease / "foreign").write_bytes(b"user state")
        result, owner = self.acquire()
        self.assertEqual(result, errno.EEXIST)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual((lease / "foreign").read_bytes(), b"user state")

    def test_preexisting_alias_is_refused_and_only_empty_owned_lease_removed(self):
        image = self.root / (".ergopti-image-" + self.nonce.decode())
        image.write_bytes(b"foreign image")
        result, owner = self.acquire()
        self.assertEqual(result, errno.EEXIST)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual(image.read_bytes(), b"foreign image")
        self.assertEqual(list(self.root.glob(".ergopti-lease-*")), [])

    def test_replaced_alias_name_refuses_cleanup_without_deleting_foreign_image(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        path = Path(os.fsdecode(owner.executable))
        path.unlink()
        path.write_bytes(b"foreign image")
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), errno.ESTALE)
        self.assertEqual(path.read_bytes(), b"foreign image")
        self.assertGreaterEqual(owner.image_fd, 0)

    def test_unknown_lease_file_keeps_physical_cleanup_debt(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        lease = self.root / (".ergopti-lease-" + self.nonce.decode())
        (lease / "foreign").write_bytes(b"foreign state")
        self.assertEqual(
            self.native.ergopti_image_alias_retire(ctypes.byref(owner)), errno.ENOTEMPTY
        )
        self.assertTrue(Path(os.fsdecode(owner.executable)).exists())
        self.assertGreaterEqual(owner.image_fd, 0)

    def test_symlink_source_never_supplies_a_hard_link_authority(self):
        self.source.rename(self.root / "original")
        self.source.symlink_to("original")
        result, owner = self.acquire()
        self.assertEqual(result, errno.ESTALE)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)

    def test_partial_unlink_failure_retries_only_exact_retained_owned_image(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        self.native.test_faults(1, 0, -1)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), errno.EIO)
        self.assertEqual((owner.lease_created, owner.image_created), (0, 1))
        self.assertTrue(Path(os.fsdecode(owner.executable)).exists())
        self.assertGreaterEqual(owner.image_fd, 0)
        self.assertEqual(self.native.ergopti_image_alias_retire(ctypes.byref(owner)), 0)
        self.assertEqual((owner.lease_created, owner.image_created), (0, 0))
        self.assertFalse(Path(os.fsdecode(owner.executable)).exists())

    def test_uncertain_close_never_recloses_a_reused_foreign_fd_or_claims_success(self):
        result, owner = self.acquire()
        self.assertEqual(result, 0)
        foreign = self.root / "foreign"
        foreign.write_bytes(b"foreign user bytes")
        descriptor = os.open(foreign, os.O_RDONLY)
        duplicate = -1
        try:
            self.native.test_faults(0, 1, descriptor)
            self.assertEqual(
                self.native.ergopti_image_alias_retire(ctypes.byref(owner)), errno.EINTR
            )
            duplicate = self.native.test_foreign_duplicate()
            self.assertGreaterEqual(duplicate, 0)
            self.assertEqual(os.pread(duplicate, 64, 0), b"foreign user bytes")
            self.assertEqual(owner.image_fd, -1)
            self.assertEqual(
                self.native.ergopti_image_alias_close(ctypes.byref(owner)), errno.EINTR
            )
            self.assertEqual(self.native.test_original_close_attempts(), 1)
            self.assertEqual(os.pread(duplicate, 64, 0), b"foreign user bytes")
        finally:
            if duplicate >= 0:
                os.close(duplicate)
            os.close(descriptor)

    def test_primary_source_refusal_and_cleanup_failure_remain_distinct(self):
        self.source.unlink()
        self.source.write_bytes(b"foreign user bytes")
        primary, owner = self.acquire()
        self.assertEqual(primary, errno.ESTALE)
        descriptor = os.open(self.source, os.O_RDONLY)
        duplicate = -1
        try:
            self.native.test_faults(0, 1, descriptor)
            cleanup = self.native.ergopti_image_alias_retire(ctypes.byref(owner))
            duplicate = self.native.test_foreign_duplicate()
            self.assertEqual((primary, cleanup), (errno.ESTALE, errno.EINTR))
            self.assertEqual(self.source.read_bytes(), b"foreign user bytes")
        finally:
            if duplicate >= 0:
                os.close(duplicate)
            os.close(descriptor)

    def test_invalid_nonce_lexical_values_never_open_private_runtime(self):
        for nonce in (b"", b"a" * 31, b"A" * 32, b"../" + b"a" * 29):
            with self.subTest(nonce=nonce):
                result, owner = self.acquire(nonce=nonce)
                self.assertEqual(result, errno.EINVAL)
                self.assertEqual(owner.directory_fd, -1)


if __name__ == "__main__":
    unittest.main()
