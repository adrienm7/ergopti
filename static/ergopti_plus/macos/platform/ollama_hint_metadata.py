# platform/ollama_hint_metadata.py
"""Bounded nonblocking native regular-file reads for asynchronous selection hints."""

import os
from pathlib import Path
import signal
import stat


class MetadataRefusal(RuntimeError):
    """A failed read or uncertain cleanup never produces a candidate."""

    def __init__(self, reason, *, primary=None, cleanup=None):
        super().__init__(reason)
        self.primary, self.cleanup = primary, cleanup


def identity(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def read_regular(path, maximum, *, progress):
    """Own the returned FD before delivering cancellation; close before returning bytes."""
    if type(maximum) is not int or maximum <= 0 or not callable(progress):
        raise MetadataRefusal("metadata")
    descriptor = None
    primary = cleanup = None
    result = None
    try:
        progress()
        previous = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        )
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= maximum:
            raise MetadataRefusal("metadata")
        pieces, count = [], 0
        while count <= maximum:
            progress()
            piece = os.read(descriptor, min(maximum + 1 - count, 65536))
            if not piece:
                break
            pieces.append(piece)
            count += len(piece)
        progress()
        after = os.fstat(descriptor)
        named = Path(path).stat(follow_symlinks=False)
        if (
            count > maximum
            or count != before.st_size
            or identity(before) != identity(after)
            or identity(named) != identity(after)
        ):
            raise MetadataRefusal("metadata")
        result = b"".join(pieces)
    except BaseException as error:
        primary = error
    finally:
        if descriptor is not None:
            closing, descriptor = descriptor, None
            try:
                os.close(closing)
            except BaseException as error:
                cleanup = error
    if cleanup is not None:
        raise MetadataRefusal("cleanup", primary=primary, cleanup=cleanup) from primary
    if primary is not None:
        raise primary
    return result
