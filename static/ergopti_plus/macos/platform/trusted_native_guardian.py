# platform/trusted_native_guardian.py
"""Bind the existing admitted bundle helper without claiming compiler provenance."""

import hashlib
import importlib.util
import os
from pathlib import Path
import stat


def load_engine():
    path = Path(__file__).parent / "network/native_http.py"
    specification = importlib.util.spec_from_file_location("ergopti_trusted_guardian_engine", path)
    engine = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(engine)
    return engine


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


class GuardianRefusal(RuntimeError):
    """Fixed reasons retain primary/cleanup causes without exposing names."""

    def __init__(self, reason, *, primary=None, cleanup=None):
        super().__init__(reason)
        self.primary, self.cleanup = primary, cleanup


class TrustedNativeGuardian:
    """Only the fixed bundle/self default, never a UI-supplied outgoing override.

    This retains the established native helper trust boundary. Named vnode/hash
    checks do not prove the guardian process's mapped executable or source build.
    The guardian independently proves the suspended server image before secrets.
    """

    @classmethod
    def acquire(cls, executable, *, register, progress):
        value = cls()
        value._descriptor = None
        value._close_debt = None
        value._operation = None
        register(value)
        try:
            value.engine = load_engine()
            value.path = Path(value.engine._resolve_worker())
            if str(value.path) != str(executable):
                raise GuardianRefusal("helper")
            progress()
            value._descriptor = os.open(
                value.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
            )
            value._initial = os.fstat(value._descriptor)
            value._digest = value._hash(progress)
            value.validate(progress=progress)
            return value
        except BaseException as primary:
            try:
                value.close()
            except BaseException as cleanup:
                raise GuardianRefusal("operation", primary=primary, cleanup=cleanup) from primary
            raise

    def _hash(self, progress):
        digest = hashlib.sha256()
        offset = 0
        while offset < self._initial.st_size:
            progress()
            chunk = os.pread(self._descriptor, min(65536, self._initial.st_size - offset), offset)
            if not chunk:
                raise GuardianRefusal("helper")
            digest.update(chunk)
            offset += len(chunk)
        progress()
        if os.pread(self._descriptor, 1, offset):
            raise GuardianRefusal("helper")
        return digest.hexdigest()

    def validate(self, *, progress):
        if self._descriptor is None or self._close_debt is not None:
            raise GuardianRefusal("cleanup")
        progress()
        if self.engine._resolve_worker() != str(self.path):
            raise GuardianRefusal("helper")
        held = os.fstat(self._descriptor)
        named = self.path.stat(follow_symlinks=False)
        if (
            not stat.S_ISREG(held.st_mode)
            or held.st_uid not in (0, os.geteuid())
            or held.st_mode & 0o6022
            or not held.st_mode & 0o111
            or held.st_nlink != 1
            or identity(held) != identity(self._initial)
            or identity(named) != identity(held)
            or self._hash(progress) != self._digest
            or identity(os.fstat(self._descriptor)) != identity(self._initial)
            or identity(self.path.stat(follow_symlinks=False)) != identity(self._initial)
        ):
            raise GuardianRefusal("helper")
        progress()

    def bind_operation(self, operation):
        if self._operation is not None:
            raise GuardianRefusal("state")
        self._operation = operation

    def close(self):
        if self._operation is not None and self._operation._guardian_retirement_proven is not True:
            raise GuardianRefusal("cleanup")
        descriptor = self._descriptor
        self._descriptor = None
        if descriptor is not None:
            try:
                os.close(descriptor)
            except BaseException as error:
                if self._close_debt is None:
                    self._close_debt = error
        if self._close_debt is not None:
            raise GuardianRefusal("cleanup") from self._close_debt
