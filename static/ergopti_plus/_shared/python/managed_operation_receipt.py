# _shared/python/managed_operation_receipt.py
"""Retain an existing private caller receipt through bounded publication."""

import json
import os
from pathlib import Path
import stat

MAXIMUM_BYTES = 4096


class ReceiptRefusal(Exception):
    """Closed filesystem admission failure without caller paths."""


def identity(value):
    return value.st_dev, value.st_ino, value.st_uid, value.st_nlink, stat.S_IFMT(value.st_mode)


class ReservedReceipt:
    """Write only the same initially empty, private regular file the caller reserved."""

    def __init__(self, path):
        self.path = Path(path)
        self.descriptor = None
        try:
            descriptor = os.open(self.path, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            self.descriptor = descriptor
            current = os.fstat(descriptor)
            if (
                not stat.S_ISREG(current.st_mode)
                or current.st_uid != os.geteuid()
                or current.st_nlink != 1
                or current.st_size != 0
                or stat.S_IMODE(current.st_mode) != 0o600
                or identity(current) != identity(self.path.lstat())
            ):
                raise ReceiptRefusal()
            self.expected = identity(current)
            self.published = False
        except BaseException:
            self.close()
            raise

    def publish(self, value):
        if self.descriptor is None or self.published:
            raise ReceiptRefusal()
        before = os.fstat(self.descriptor)
        if (
            identity(before) != self.expected
            or before.st_size != 0
            or stat.S_IMODE(before.st_mode) != 0o600
            or identity(self.path.lstat()) != self.expected
        ):
            raise ReceiptRefusal()
        data = (
            json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
        ).encode("ascii")
        if len(data) > MAXIMUM_BYTES:
            raise ReceiptRefusal()
        offset = 0
        while offset < len(data):
            count = os.write(self.descriptor, data[offset:])
            if count <= 0:
                raise ReceiptRefusal()
            offset += count
        os.fsync(self.descriptor)
        after = os.fstat(self.descriptor)
        if (
            identity(after) != self.expected
            or after.st_size != len(data)
            or identity(self.path.lstat()) != self.expected
        ):
            raise ReceiptRefusal()
        self.published = True

    def close(self):
        if self.descriptor is not None:
            descriptor, self.descriptor = self.descriptor, None
            os.close(descriptor)

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()
