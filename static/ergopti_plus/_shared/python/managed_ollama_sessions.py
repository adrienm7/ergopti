# _shared/python/managed_ollama_sessions.py
"""Read bounded private daemon leases before injected listener authentication."""

import importlib.util
import math
import os
from pathlib import Path
import re
import stat
import time

SPEC = importlib.util.spec_from_file_location(
    "ergopti_ollama_session_policy", Path(__file__).with_name("managed_ollama_runtime.py")
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)

MAXIMUM_SESSIONS = 64
MAXIMUM_SESSION_BYTES = 4096


def identity(value):
    return value.st_dev, value.st_ino, value.st_uid, value.st_mode, value.st_nlink, value.st_size


def directory_descriptor(directory):
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    observed = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(observed.st_mode)
        or observed.st_uid != os.geteuid()
        or observed.st_mode & 0o077
    ):
        os.close(descriptor)
        raise POLICY.RuntimeRefusal("session")
    return descriptor


def read_session(directory, name):
    """Keep NOFOLLOW descriptors through parsing and the before/after fences."""
    if re.fullmatch(r"daemon-[A-Za-z0-9_-]+\.json", name) is None:
        raise POLICY.RuntimeRefusal("session")
    directory_fd = directory_descriptor(directory)
    descriptor = None
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory_fd)
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
            or not 0 < before.st_size <= MAXIMUM_SESSION_BYTES
        ):
            raise POLICY.RuntimeRefusal("session")
        data = os.read(descriptor, MAXIMUM_SESSION_BYTES + 1)
        after = os.fstat(descriptor)
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (
            len(data) != before.st_size
            or len(data) > MAXIMUM_SESSION_BYTES
            or identity(before) != identity(after)
            or identity(after) != identity(current)
            or identity(os.fstat(directory_fd)) != identity(Path(directory).lstat())
        ):
            raise POLICY.RuntimeRefusal("session")
        return POLICY.private_session(POLICY.metadata_bytes(data))
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory_fd)


def select(directory, port, expected, authenticate, timeout):
    """Only an SDK-bound authenticated live listener may select a private lease.

    Stale files are neither admitted nor deleted. There is one original finite
    admission clock across bounded candidates; a model pull has its own clocks.
    """
    if (
        type(port) is not int
        or not 1024 <= port <= 65535
        or not callable(authenticate)
        or type(timeout) not in (float, int)
        or not math.isfinite(timeout)
        or timeout <= 0
        or set(expected) != {"source_commit", "binary_sha256", "asset_sha256", "device", "inode"}
    ):
        raise POLICY.RuntimeRefusal("session")
    deadline = time.monotonic() + timeout
    descriptor = directory_descriptor(directory)
    try:
        names = []
        with os.scandir(descriptor) as entries:
            for entry in entries:
                if len(names) >= MAXIMUM_SESSIONS:
                    raise POLICY.RuntimeRefusal("session")
                names.append(entry.name)
    finally:
        os.close(descriptor)
    for name in sorted(names):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise POLICY.RuntimeRefusal("deadline")
        try:
            session = read_session(directory, name)
        except (OSError, POLICY.RuntimeRefusal):
            continue
        if session["port"] != str(port) or any(
            session[key] != value for key, value in expected.items()
        ):
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise POLICY.RuntimeRefusal("deadline")
        try:
            return authenticate(session, remaining)
        except (OSError, POLICY.RuntimeRefusal):
            continue
    raise POLICY.RuntimeRefusal("session")
