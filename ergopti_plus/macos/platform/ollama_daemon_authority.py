# platform/ollama_daemon_authority.py
"""Retain a same-session authority file through exact native daemon retirement."""

import importlib.util
import os
import signal
from pathlib import Path


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


OWNER = load("ergopti_daemon_session_owner", Path(__file__).with_name("suspended_image_owner.py"))
POLICY = load(
    "ergopti_shared_daemon_authority",
    Path(__file__).absolute().parents[2] / "_shared/python/managed_ollama_daemon_authority.py",
)
ImageRefusal = OWNER.ImageRefusal


class DaemonAuthority(OWNER.EmptySession):
    """A receipt is published only by its bound mapped-image and ACTIVE owner."""

    @classmethod
    def acquire(cls, session, *, register):
        return cls.acquire_sibling(session, "source", register=register)

    def publish(self, operation, alias, policy):
        if (
            operation is not self._operation
            or operation.image_ready is not True
            or operation.active is not True
            or operation.physically_retired is True
            or getattr(operation, "_retirement_started", False)
            or self.session._operation is not operation
            or not self.session._written
            or alias._operation is not operation
            or self._written
        ):
            raise ImageRefusal("state")
        operation.recheck_source()
        self.session.validate()
        self.validate()
        with alias.context():
            payload = POLICY.seal(
                {"source_alias": alias.proof, "listener": operation.listener},
                self.session._written,
                policy,
                os.geteuid(),
            )
        while len(self._written) < len(payload):
            operation.progress()
            count = os.write(self._file_fd, payload[len(self._written) :])
            if count <= 0:
                raise ImageRefusal("session")
            self._written += payload[len(self._written) : len(self._written) + count]
        os.fsync(self._file_fd)
        self.validate()
        self.session.validate()
        operation.recheck_source()


def read_pair(directory, name, policy, expected_uid, *, progress):
    """Read exact original session bytes and its sealed same-nonce authority.

    A parsed receipt does not grant source or socket authority. The caller must
    re-admit its original catalogue/alias and compare the complete native image
    tuple on the actual accepted socket before transmitting any private header.
    """
    import re
    import stat

    sessions = load(
        "ergopti_daemon_bound_sessions",
        Path(__file__).absolute().parents[2] / "_shared/python/managed_ollama_sessions.py",
    )
    if (
        type(name) is not str
        or re.fullmatch(r"daemon-[0-9a-f]{32}\.json", name) is None
        or type(expected_uid) is not int
        or expected_uid != os.geteuid()
        or not callable(progress)
    ):
        raise ImageRefusal("session")
    directory = Path(directory)
    descriptors = []
    primary = cleanup = None
    result = None

    def owned_open(*arguments, **options):
        # Deliver cancellation only after the returned native FD has an owner.
        previous = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        )
        try:
            descriptor = os.open(*arguments, **options)
            try:
                descriptors.append(descriptor)
            except BaseException as error:
                try:
                    os.close(descriptor)
                except BaseException as close_error:
                    raise ImageRefusal("operation", primary=error, cleanup=close_error) from error
                raise
            return descriptor
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    try:
        progress()
        directory_fd = owned_open(
            directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        )
        observed_directory = os.fstat(directory_fd)

        def directory_check():
            progress()
            held = os.fstat(directory_fd)
            named = directory.stat(follow_symlinks=False)
            if (
                not stat.S_ISDIR(held.st_mode)
                or held.st_uid != expected_uid
                or stat.S_IMODE(held.st_mode) != 0o700
                or OWNER.vnode(held) != OWNER.vnode(observed_directory)
                or OWNER.vnode(named) != OWNER.vnode(held)
            ):
                raise ImageRefusal("session")

        directory_check()
        records = []

        def read_file(filename, maximum):
            progress()
            descriptor = owned_open(
                filename,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                dir_fd=directory_fd,
            )
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != expected_uid
                or stat.S_IMODE(before.st_mode) != 0o600
                or before.st_nlink != 1
                or not 0 < before.st_size <= maximum
            ):
                raise ImageRefusal("session")
            records.append((filename, descriptor, before))
            data = bytearray()
            while len(data) < before.st_size:
                progress()
                chunk = os.pread(descriptor, min(65536, before.st_size - len(data)), len(data))
                if not chunk:
                    raise ImageRefusal("session")
                data.extend(chunk)
            progress()
            if os.pread(descriptor, 1, len(data)):
                raise ImageRefusal("session")
            return bytes(data)

        raw_session = read_file(name, sessions.MAXIMUM_SESSION_BYTES)
        raw_authority = read_file("source-" + name[len("daemon-") :], policy.maximum_bytes)
        authority = POLICY.authenticate(raw_authority, raw_session, policy, expected_uid)
        session = POLICY.RUNTIME.private_session(POLICY.RUNTIME.metadata_bytes(raw_session))
        for filename, descriptor, before in records:
            progress()
            after = os.fstat(descriptor)
            named = os.stat(filename, dir_fd=directory_fd, follow_symlinks=False)

            def identity(value):
                return (
                    value.st_dev,
                    value.st_ino,
                    value.st_uid,
                    value.st_mode,
                    value.st_nlink,
                    value.st_size,
                    value.st_mtime_ns,
                    value.st_ctime_ns,
                )

            if identity(before) != identity(after) or identity(named) != identity(after):
                raise ImageRefusal("session")
        directory_check()
        result = session, authority
    except BaseException as error:
        primary = error
    while descriptors:
        descriptor = descriptors.pop()
        try:
            os.close(descriptor)
        except BaseException as error:
            if cleanup is None:
                cleanup = error
    if cleanup is not None:
        raise ImageRefusal("operation", primary=primary, cleanup=cleanup) from primary
    if primary is not None:
        raise primary
    return result
