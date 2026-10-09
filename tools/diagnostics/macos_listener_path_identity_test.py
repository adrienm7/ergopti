#!/usr/bin/env python3
"""Receive the actual path helper with controlled libproc, on real POSIX files.

These controls do not emulate Darwin process identity, mappings or TCP tables.
The native XCTest producer must still qualify those independent SDK witnesses.
"""

import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT
    / "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/LoopbackListenerCompatibility.c"
)

PORTS = r"""
#define _XOPEN_SOURCE 700
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#define PROC_PIDPATHINFO_MAXSIZE 4096
static char observed[PROC_PIDPATHINFO_MAXSIZE];
static int path_refusal;
static int canonical_refusal;
static int proc_pidpath(pid_t pid, char *path, uint32_t capacity) {
    (void)pid;
    if (path_refusal != 0) { errno = path_refusal; return 0; }
    size_t length = strlen(observed);
    if (length >= capacity) { errno = EOVERFLOW; return 0; }
    memcpy(path, observed, length + 1);
    return (int)length;
}
static char *controlled_realpath(const char *path, char *result) {
    if (canonical_refusal != 0) { errno = canonical_refusal; return NULL; }
    return realpath(path, result);
}
#define realpath controlled_realpath
"""

RECEIVER = r"""
int receive(const char *observed_path, const char *source_path, uint64_t device,
    uint64_t inode, int path_error, int canonical_error) {
    (void)&controlled_realpath; // Keep exact frozen-preimage compilation meaningful.
    size_t length = strlen(observed_path);
    if (length >= sizeof(observed)) { return EOVERFLOW; }
    memcpy(observed, observed_path, length + 1);
    path_refusal = path_error; canonical_refusal = canonical_error;
    return path_identity(42, source_path, device, inode);
}
"""


class ActualPathIdentityReceiving(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name != "posix":
            raise unittest.SkipTest("POSIX filesystem receiving requires a POSIX host")
        cls.build = tempfile.TemporaryDirectory(prefix="ergopti-listener-path-build-")
        source = SOURCE.read_text(encoding="utf-8")
        beginning = "static int path_identity("
        ending = "// A known fixture PID is diagnostic input only."
        if source.count(beginning) != 1 or source.count(ending) != 1:
            raise AssertionError("The actual producer helper is not uniquely delimited")
        helper = source[source.index(beginning) : source.index(ending)]
        program = Path(cls.build.name) / "receiver.c"
        library = Path(cls.build.name) / "receiver.so"
        program.write_text(PORTS + helper + RECEIVER, encoding="utf-8")
        subprocess.run(
            [
                "cc",
                "-std=c11",
                "-Wall",
                "-Werror",
                "-pedantic",
                "-fPIC",
                "-shared",
                str(program),
                "-o",
                str(library),
            ],
            check=True,
            capture_output=True,
        )
        cls.native = ctypes.CDLL(str(library))
        cls.native.receive.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_uint64,
            ctypes.c_uint64,
            ctypes.c_int,
            ctypes.c_int,
        ]
        cls.native.receive.restype = ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="ergopti-listener-path-case-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.directory = self.root / "physical"
        self.directory.mkdir(mode=0o700)
        self.original = self.directory / "source"
        self.original.write_bytes(b"independent original executable bytes")
        self.original.chmod(0o700)
        identity = self.original.stat()
        self.device = identity.st_dev & 0xFFFFFFFF
        self.inode = identity.st_ino
        self.ancestor_alias = self.root / "lexical"
        self.ancestor_alias.symlink_to(self.directory, target_is_directory=True)
        self.lexical = self.ancestor_alias / "source"

    def receive(self, requested=None, observed=None, device=None, inode=None, **errors):
        return self.native.receive(
            os.fsencode(self.original if observed is None else observed),
            os.fsencode(self.original if requested is None else requested),
            self.device if device is None else device,
            self.inode if inode is None else inode,
            errors.get("path_error", 0),
            errors.get("canonical_error", 0),
        )

    def test_original_exact_named_spelling_remains_admitted(self):
        self.assertEqual(self.receive(), 0)

    def test_actual_parent_alias_keeps_same_source_identity(self):
        self.assertNotEqual(str(self.lexical), str(self.original))
        self.assertEqual(self.lexical.stat().st_ino, self.inode)
        self.assertEqual(self.receive(requested=self.lexical), 0)

    def test_wrong_original_inode_refuses_even_with_canonical_spelling(self):
        self.assertNotEqual(self.inode, self.inode + 1)
        self.assertNotEqual(self.receive(requested=self.lexical, inode=self.inode + 1), 0)

    def test_wrong_original_device_refuses_even_with_canonical_spelling(self):
        self.assertNotEqual(
            self.receive(requested=self.lexical, device=(self.device + 1) & 0xFFFFFFFF),
            0,
        )

    def test_unrelated_owned_regular_executable_cannot_supply_identity(self):
        unrelated = self.directory / "foreign"
        unrelated.write_bytes(b"independent foreign executable bytes")
        unrelated.chmod(0o700)
        self.assertNotEqual(unrelated.stat().st_ino, self.inode)
        self.assertNotEqual(self.receive(requested=self.lexical, observed=unrelated), 0)

    def test_same_inode_different_hardlink_name_is_not_path_authority(self):
        alternate = self.directory / "alternate"
        os.link(self.original, alternate)
        self.assertEqual(alternate.stat().st_ino, self.inode)
        self.assertNotEqual(self.receive(requested=alternate), 0)

    def test_final_component_symlink_cannot_broaden_original_admission(self):
        final_link = self.directory / "final-link"
        final_link.symlink_to(self.original)
        self.assertEqual(final_link.stat().st_ino, self.inode)
        self.assertNotEqual(self.receive(requested=final_link), 0)

    def test_replaced_named_source_cannot_replace_original_identity(self):
        self.original.rename(self.directory / "retained-original")
        self.original.write_bytes(b"independent replacement executable bytes")
        self.original.chmod(0o700)
        self.assertNotEqual(self.original.stat().st_ino, self.inode)
        self.assertNotEqual(self.receive(requested=self.lexical), 0)

    def test_missing_original_named_source_is_not_admitted(self):
        self.original.unlink()
        self.assertNotEqual(self.receive(requested=self.lexical), 0)

    def test_nonregular_named_source_is_not_admitted(self):
        self.original.unlink()
        self.original.mkdir(mode=0o700)
        self.assertNotEqual(self.receive(requested=self.lexical), 0)

    def test_proc_pidpath_refusal_is_preserved(self):
        import errno

        self.assertEqual(self.receive(requested=self.lexical, path_error=errno.EPERM), errno.EPERM)

    def test_canonicalization_refusal_cannot_supply_authority(self):
        import errno

        self.assertEqual(
            self.receive(requested=self.lexical, canonical_error=errno.EACCES), errno.EACCES
        )


if __name__ == "__main__":
    unittest.main()
