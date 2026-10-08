#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_native_artifact_cleanup_retry.py
# Actual additive opaque C ABI; no fake kernel, compiler, child or process owner.
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

SOURCE_C = "b1b09d8cb30ca679ef2c51a500006c1fa097d9e871fe2f9bed154cdc6c0484af"
SOURCE_H = "d5350f97a6a43a99fc520d11dc496de42df7a523e38debf1af865f342439692c"
NAME = "ergopti-plus-linux.tar.gz"
PAYLOAD = b"abc"
FOREIGN = b"Independent unrelated namespace bytes"
CASES = ("regular", "hardlink", "symlink", "dangling", "unexpected-basename")


class Descriptor:
    def __init__(self, fd, role):
        self.fd, self.role, self.closed, self.unknown = fd, role, False, False

    def close(self):
        if self.closed:
            return
        if self.unknown or self.fd is None:
            raise RuntimeError("Descriptor close authority unavailable")
        exact, self.fd = self.fd, None
        try:
            os.close(exact)
        except BaseException:
            self.unknown = True
            raise
        self.closed = True


class Ledger:
    def __init__(self):
        self.items, self.acquiring, self.unknown = [], False, False

    def acquire(self, role, action):
        if self.acquiring or self.unknown:
            raise RuntimeError("Fixture acquisition unavailable")
        self.acquiring = True
        try:
            fd = action()
            if type(fd) is not int or fd < 0:
                self.unknown = True
                raise RuntimeError("Invalid fixture descriptor")
            item = Descriptor(fd, role)
            self.items.append(item)  # register before read/stat/follow-up operations
            return item
        except BaseException:
            self.unknown = True  # no guessed numeric descriptor after ambiguous acquisition
            raise
        finally:
            self.acquiring = False

    def assert_closed(self):
        assert not self.acquiring and not self.unknown, "Unknown descriptor acquisition"
        assert all(item.closed and not item.unknown for item in self.items), (
            "Fixture descriptor debt"
        )


def read_all(fd):
    parts, offset = [], 0
    while True:
        chunk = os.pread(fd, 65536, offset)
        if not chunk:
            return b"".join(parts)
        offset += len(chunk)
        assert offset <= 4 * 1024 * 1024, "Bounded source/library input exceeded"
        parts.append(chunk)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_size)


def regular_input(ledger, path, expected, role):
    assert re.fullmatch(r"[0-9a-f]{64}", expected), "Expected input identity invalid"
    path = Path(path)
    assert path.is_absolute(), "Absolute input required"
    current = Path(path.anchor)
    for part in path.parts[1:]:
        assert part not in (".", ".."), "Literal input required"
        current /= part
        assert not stat.S_ISLNK(current.lstat().st_mode), "Symlink input refused"
    item = ledger.acquire(role, lambda: os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW))
    before = os.fstat(item.fd)
    assert stat.S_ISREG(before.st_mode), "Regular input required"
    assert hashlib.sha256(read_all(item.fd)).hexdigest() == expected, (
        "Input source identity refused"
    )
    assert identity(os.fstat(item.fd)) == identity(before), "Input descriptor changed"
    return item, path, expected, identity(before)


def refence(inputs):
    for item, path, expected, captured in inputs:
        assert identity(os.fstat(item.fd)) == captured, "Captured execution descriptor changed"
        assert identity(path.lstat()) == captured, "Original execution input replaced"
        assert hashlib.sha256(read_all(item.fd)).hexdigest() == expected, (
            "Execution input bytes changed"
        )


def bind_library(item):
    raw = os.pread(item.fd, 20, 0)
    assert raw[:6] == b"\x7fELF\x02\x01" and raw[18:20] == b"\x3e\x00", (
        "Real Linux x86_64 ELF required"
    )
    exact = "/proc/self/fd/" + str(item.fd)
    assert identity(os.stat(exact)) == identity(os.fstat(item.fd)), "Owned library image mismatch"
    library = ctypes.CDLL(exact, use_errno=True)
    pointer = ctypes.c_void_p
    specs = {
        "abi_version": (ctypes.c_uint, []),
        "clock_ms": (ctypes.c_double, []),
        "reserve": (ctypes.c_int, [ctypes.c_int, ctypes.POINTER(pointer)]),
        "allocate_output": (ctypes.c_int, [pointer, ctypes.c_double, ctypes.POINTER(ctypes.c_int)]),
        "stage": (
            ctypes.c_int,
            [pointer, ctypes.c_int, ctypes.c_int64, ctypes.c_char_p, ctypes.c_double],
        ),
        "cleanup_with_disposition": (ctypes.c_int, [pointer, ctypes.POINTER(ctypes.c_int)]),
        "descriptors_closed": (ctypes.c_int, [pointer]),
        "named_remaining": (ctypes.c_int, [pointer]),
        "dispose_unpublished": (ctypes.c_int, [pointer]),
    }
    api = {}
    for name, (result, args) in specs.items():
        call = getattr(library, "ergopti_archive_publication_" + name)
        call.restype, call.argtypes = result, args
        api[name] = call
    assert api["abi_version"]() == 1, "Native ABI mismatch"
    return library, api


def write_exact(fd, payload):
    offset = 0
    while offset < len(payload):
        count = os.write(fd, payload[offset:])
        assert count > 0, "Actual fixture write refused"
        offset += count


def case(api, variant, parent, inputs):
    ledger = Ledger()
    directory = Path(tempfile.mkdtemp(prefix="namespace-" + variant + "-", dir=parent))
    original_directory = ledger.acquire(
        "fixture-directory",
        lambda: os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW),
    )
    directory_identity = identity(os.fstat(original_directory.fd))[:4]
    owner = ctypes.c_void_p()
    result = api["reserve"](original_directory.fd, ctypes.byref(owner))
    assert result == 0 and owner.value is not None, "Actual retained owner reserve refused"
    original_pointer = owner.value
    deadline = api["clock_ms"]() + 10000.0
    out = ctypes.c_int(-1)
    allocated = api["allocate_output"](owner, deadline, ctypes.byref(out))
    assert allocated == 0 and out.value >= 0, "Actual O_TMPFILE output refused"
    # The actual ABI transfers this NEW output descriptor to this fixture.
    output = ledger.acquire("transferred-output", lambda: out.value)
    write_exact(output.fd, PAYLOAD)
    output_identity = identity(os.fstat(output.fd))
    assert stat.S_ISREG(output_identity[2]) and os.fstat(output.fd).st_nlink == 0
    sentinel = ledger.acquire(
        "unrelated-sentinel",
        lambda: os.open(
            "sentinel",
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=original_directory.fd,
        ),
    )
    write_exact(sentinel.fd, b"Unrelated retained sentinel")
    sentinel_identity = identity(os.fstat(sentinel.fd))
    # Sentinel is not a namespace competitor; unlink its OWN original name,
    # retaining the independent FD across all native cleanup/descriptors.
    os.unlink("sentinel", dir_fd=original_directory.fd)
    competitor_name = "foreign-extra" if variant == "unexpected-basename" else NAME
    target_name = "fixture-target"
    target = None
    if variant in ("regular", "unexpected-basename"):
        competitor = ledger.acquire(
            "fixture-competitor",
            lambda: os.open(
                competitor_name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=original_directory.fd,
            ),
        )
        write_exact(competitor.fd, FOREIGN)
        competitor.close()
    elif variant in ("hardlink", "symlink"):
        # Keep target outside the native namespace: an unexpected second entry
        # must not obscure the intended expected-basename identity classifier.
        target = ledger.acquire(
            "fixture-target",
            lambda: os.open(
                directory.parent / (directory.name + "-target"),
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
            ),
        )
        write_exact(target.fd, FOREIGN)
        if variant == "hardlink":
            os.link(
                directory.parent / (directory.name + "-target"),
                competitor_name,
                dst_dir_fd=original_directory.fd,
                follow_symlinks=False,
            )
        else:
            os.symlink(
                "../" + directory.name + "-target", competitor_name, dir_fd=original_directory.fd
            )
    else:
        os.symlink(
            "../" + directory.name + "-missing", competitor_name, dir_fd=original_directory.fd
        )
    captured = identity(
        os.stat(competitor_name, dir_fd=original_directory.fd, follow_symlinks=False)
    )
    captured_link = (
        os.readlink(competitor_name, dir_fd=original_directory.fd)
        if variant in ("symlink", "dangling")
        else None
    )

    def check_competitor():
        assert (
            identity(os.stat(competitor_name, dir_fd=original_directory.fd, follow_symlinks=False))
            == captured
        ), "Foreign identity changed"
        if captured_link is not None:
            assert os.readlink(competitor_name, dir_fd=original_directory.fd) == captured_link, (
                "Foreign symlink target changed"
            )
        else:
            probe = ledger.acquire(
                "foreign-read-only-probe",
                lambda: os.open(
                    competitor_name,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=original_directory.fd,
                ),
            )
            assert read_all(probe.fd) == FOREIGN, "Foreign bytes changed"
            probe.close()
        if target is not None:
            assert read_all(target.fd) == FOREIGN, "Unrelated target bytes changed"
        if variant == "dangling":
            try:
                os.stat(competitor_name, dir_fd=original_directory.fd)
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("Dangling target unexpectedly exists")
        assert (
            identity(os.fstat(sentinel.fd)) == sentinel_identity
            and read_all(sentinel.fd) == b"Unrelated retained sentinel"
        )
        assert identity(os.fstat(original_directory.fd))[:4] == directory_identity

    ctypes.set_errno(0)
    staged = api["stage"](owner, output.fd, len(PAYLOAD), NAME.encode(), deadline)
    stage_errno = ctypes.get_errno()
    if variant == "unexpected-basename":
        assert staged == 0, "Actual archive stage refused"
    else:
        assert staged == -1 and stage_errno == errno.EEXIST, "Native collision was not EEXIST"
    assert identity(os.fstat(output.fd))[:2] == output_identity[:2], (
        "Original output identity replaced"
    )
    output.close()  # original transferred writer ACK before native retirement
    check_competitor()
    for _ in range(2):
        disposition = ctypes.c_int(771)
        assert api["cleanup_with_disposition"](owner, ctypes.byref(disposition)) == -1
        assert disposition.value == 1, "Actual pre-destructive conflict receipt missing"
        assert owner.value == original_pointer and api["descriptors_closed"](owner) == 0
        assert api["named_remaining"](owner) > 0, "Original archive name debt discarded"
        check_competitor()
        refence(inputs)
    # Fixture alone removes its acknowledged OWN exact competitor; production
    # never receives the path/FD or permission to delete a foreign entry.
    assert (
        identity(os.stat(competitor_name, dir_fd=original_directory.fd, follow_symlinks=False))
        == captured
    )
    os.unlink(competitor_name, dir_fd=original_directory.fd)
    disposition = ctypes.c_int(771)
    assert api["cleanup_with_disposition"](owner, ctypes.byref(disposition)) == 0
    assert disposition.value == 0 and owner.value == original_pointer
    assert api["descriptors_closed"](owner) == 1 and api["named_remaining"](owner) == 0
    assert api["dispose_unpublished"](owner) == 0
    owner.value = None  # no second call or dereference after native memory ACK
    assert (
        identity(os.fstat(sentinel.fd)) == sentinel_identity
        and read_all(sentinel.fd) == b"Unrelated retained sentinel"
    )
    assert identity(os.fstat(original_directory.fd))[:4] == directory_identity
    assert os.listdir(original_directory.fd) == [], "Native owned archive name remains"
    if target is not None:
        assert read_all(target.fd) == FOREIGN
        target_path = directory.parent / (directory.name + "-target")
        assert identity(target_path.lstat()) == identity(os.fstat(target.fd))
        os.unlink(target_path)
        target.close()
    sentinel.close()
    original_directory.close()
    ledger.assert_closed()
    assert identity(directory.lstat())[:4] == directory_identity, "Fixture directory entry changed"
    directory.rmdir()
    refence(inputs)
    return {
        "case": variant,
        "passed": True,
        "same_owner": True,
        "conflicts": 2,
        "fixture_competitor_removed": True,
        "native_descriptors_closed": True,
        "native_disposed_once": True,
        "sentinel_preserved": True,
        "fixture_debt": 0,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--library-sha256", required=True)
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()
    assert not os.getenv("LD_PRELOAD") and not os.getenv("LD_AUDIT"), "Native interposition refused"
    parent = Path(os.environ["TMPDIR"])
    assert str(parent) == "/var/tmp/ergopti-cloud-validation" and parent.is_dir(), (
        "Canonical fixture parent required"
    )
    inputs_ledger = Ledger()
    source = Path(args.source_root) / "static/ergopti_plus/linux/native/archive_output"
    inputs = [
        regular_input(inputs_ledger, source / "archive_publication.c", SOURCE_C, "native-source"),
        regular_input(inputs_ledger, source / "archive_publication.h", SOURCE_H, "native-header"),
        regular_input(inputs_ledger, args.library, args.library_sha256, "actual-built-library"),
    ]
    library, api = bind_library(inputs[-1][0])
    receipts = []
    for variant in CASES:
        refence(inputs)
        receipts.append(case(api, variant, parent, inputs))
    assert len(receipts) == 5 and all(
        row["passed"] and row["fixture_debt"] == 0 for row in receipts
    )
    refence(inputs)
    for item, _, _, _ in inputs:
        item.close()
    inputs_ledger.assert_closed()
    assert library is not None  # retain mapped library through final native use
    print(
        json.dumps(
            {
                "schema_version": 1,
                "state": "native_namespace_conflicts_passed",
                "passed": 5,
                "failed": 0,
                "skipped": 0,
                "fixture_debt": 0,
                "native_owner_debt": 0,
                "cases": receipts,
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
