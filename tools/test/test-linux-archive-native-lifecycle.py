#!/usr/bin/env python3
"""Exercise the real retained archive publication and two offset readers."""

import ctypes
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "static/ergopti_plus/linux/updater/native"

with tempfile.TemporaryDirectory(prefix="ergopti-native-lifecycle-") as temporary:
    parent = Path(temporary).resolve(strict=True)
    library = parent / "archive.so"
    subprocess.run(
        [
            "cc",
            "-std=c11",
            "-O2",
            "-fPIC",
            "-shared",
            "-Wall",
            "-Wextra",
            "-Werror",
            str(SOURCE / "archive_publication.c"),
            "-o",
            str(library),
        ],
        check=True,
    )
    native = ctypes.CDLL(str(library), use_errno=True)
    owner_type = ctypes.c_void_p

    def function(name, result, *args):
        call = getattr(native, "ergopti_archive_publication_" + name)
        call.restype, call.argtypes = result, args
        return call

    clock = function("clock_ms", ctypes.c_double)
    create = function(
        "create_directory",
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_double,
        ctypes.POINTER(owner_type),
    )
    output = function(
        "allocate_output", ctypes.c_int, owner_type, ctypes.c_double, ctypes.POINTER(ctypes.c_int)
    )
    stage = function(
        "stage",
        ctypes.c_int,
        owner_type,
        ctypes.c_int,
        ctypes.c_int64,
        ctypes.c_char_p,
        ctypes.c_double,
    )
    commit = function("commit", ctypes.c_int, owner_type)
    reader = function(
        "allocate_reader", ctypes.c_int, owner_type, ctypes.c_double, ctypes.POINTER(ctypes.c_int)
    )
    cleanup = function("cleanup", ctypes.c_int, owner_type)
    closed = function("descriptors_closed", ctypes.c_int, owner_type)
    dispose = function("dispose_unpublished", ctypes.c_int, owner_type)
    display = function(
        "copy_display_path", ctypes.c_int, owner_type, ctypes.c_char_p, ctypes.c_size_t
    )
    deadline = clock() + 10000
    real_parent = parent / "real-parent"
    real_parent.mkdir()
    alias = parent / "linked-parent"
    alias.symlink_to(real_parent, target_is_directory=True)
    rejected = owner_type()
    assert create(os.fsencode(alias), deadline, ctypes.byref(rejected)) == -1
    assert rejected.value is not None
    assert cleanup(rejected) == 0, ctypes.get_errno()
    assert closed(rejected) == 1
    assert dispose(rejected) == 0, ctypes.get_errno()
    assert alias.is_symlink() and list(real_parent.iterdir()) == []
    owner = owner_type()
    assert create(os.fsencode(parent), deadline, ctypes.byref(owner)) == 0, ctypes.get_errno()
    early_reader = ctypes.c_int(123)
    assert reader(owner, deadline, ctypes.byref(early_reader)) == -1
    assert early_reader.value == -1
    file_descriptor = ctypes.c_int(-1)
    assert output(owner, deadline, ctypes.byref(file_descriptor)) == 0, ctypes.get_errno()
    duplicate = ctypes.c_int(123)
    assert output(owner, deadline, ctypes.byref(duplicate)) == -1
    assert duplicate.value == -1
    payload = b"archive bytes\x00with binary data"
    assert os.write(file_descriptor.value, payload) == len(payload)
    assert stage(owner, file_descriptor.value, len(payload), b"archive.tar.gz", deadline) == 0, (
        ctypes.get_errno()
    )
    os.close(file_descriptor.value)
    assert commit(owner) == 0, ctypes.get_errno()
    selected = ctypes.create_string_buffer(4352)
    assert display(owner, selected, len(selected)) == 0, ctypes.get_errno()
    published = Path(os.fsdecode(selected.value))
    assert published.read_bytes() == payload
    for offset in (0, 8):
        descriptor = ctypes.c_int(-1)
        assert reader(owner, deadline, ctypes.byref(descriptor)) == 0, ctypes.get_errno()
        try:
            assert os.pread(descriptor.value, len(payload), offset) == payload[offset:]
        finally:
            os.close(descriptor.value)
    assert cleanup(owner) == 0, ctypes.get_errno()
    assert closed(owner) == 1
    assert not published.exists() and not published.parent.exists()
    assert dispose(owner) == 0, ctypes.get_errno()
print("Native archive lifecycle: complete publication, independent readers and retirement passed.")
