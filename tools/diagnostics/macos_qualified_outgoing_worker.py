# tools/diagnostics/macos_qualified_outgoing_worker.py
"""Retain source authority from the receiver's actual compile/sign operation."""

import hashlib
import os
from pathlib import Path
import stat


class QualificationRefusal(RuntimeError):
    """A closed lexical reason, without compiler paths or private diagnostics."""

    def __init__(self, reason, *, primary=None, cleanup=None):
        super().__init__(reason)
        self.primary, self.cleanup = primary, cleanup


def fingerprint(descriptor, progress=lambda: None):
    before = os.fstat(descriptor)
    value = hashlib.sha256()
    offset = 0
    while offset < before.st_size:
        progress()
        data = os.pread(descriptor, min(65536, before.st_size - offset), offset)
        if not data:
            raise QualificationRefusal("bytes")
        value.update(data)
        offset += len(data)
    progress()
    if os.pread(descriptor, 1, offset) or identity(os.fstat(descriptor)) != identity(before):
        raise QualificationRefusal("bytes")
    return value.hexdigest()


def identity(value):
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


class OwnedOutgoingWorkerQualification:
    """No constructor admits an existing signed or caller-described executable.

    The original receiving context builds from its independently pinned copies,
    signs and verifies the real output, then keeps input/output descriptors. Native
    role fields are binding metadata only; this owner retains the source proof.
    """

    @classmethod
    def build(cls, binary, inputs, arguments, execute, *, register):
        value = cls()
        value.binary = Path(binary)
        value._inputs = []
        value._output = None
        value._qualified = False
        value._close_debt = None
        value._operation = None
        register(value)
        try:
            if (
                not value.binary.is_absolute()
                or value.binary.exists()
                or value.binary.is_symlink()
                or not str(value.binary).endswith("/Contents/MacOS/ErgoptiPlus")
                or arguments[:3] != ["/usr/bin/xcrun", "swiftc", "-parse-as-library"]
                or arguments[-2:] != ["-o", str(value.binary)]
                or not inputs
            ):
                raise QualificationRefusal("source")
            for original, copied, expected in inputs:
                for path in (Path(original), Path(copied)):
                    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
                    value._inputs.append((path, descriptor, os.fstat(descriptor), expected))
            value._check_inputs()
            execute(arguments, timeout=90)
            value._check_inputs()
            execute(["/usr/bin/codesign", "--force", "--sign", "-", str(value.binary)])
            execute(["/usr/bin/codesign", "--verify", "--strict", str(value.binary)])
            value._output = os.open(value.binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            value._observed = os.fstat(value._output)
            value._digest = fingerprint(value._output)
            value._qualified = True
            value.fields()
            return value
        except BaseException as primary:
            try:
                value.close()
            except BaseException as cleanup:
                raise QualificationRefusal(
                    "operation", primary=primary, cleanup=cleanup
                ) from primary
            raise primary

    def _check_inputs(self, progress=lambda: None):
        for path, descriptor, observed, expected in self._inputs:
            current = os.fstat(descriptor)
            named = path.stat(follow_symlinks=False)
            if (
                not stat.S_ISREG(current.st_mode)
                or current.st_uid != os.geteuid()
                or current.st_mode & 0o022
                or identity(current) != identity(observed)
                or identity(named) != identity(observed)
                or fingerprint(descriptor, progress) != expected
                or identity(path.stat(follow_symlinks=False)) != identity(observed)
            ):
                raise QualificationRefusal("source")

    def fields(self, *, progress=lambda: None):
        """Only the live original compiled context may emit native public refs."""
        if (
            not getattr(self, "_qualified", False)
            or self._output is None
            or self._close_debt is not None
        ):
            raise QualificationRefusal("state")
        self._check_inputs(progress)
        current = os.fstat(self._output)
        named = self.binary.stat(follow_symlinks=False)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.geteuid()
            or current.st_mode & 0o022
            or not current.st_mode & 0o111
            or current.st_nlink != 1
            or identity(current) != identity(self._observed)
            or identity(named) != identity(self._observed)
            or fingerprint(self._output, progress) != self._digest
            or identity(self.binary.stat(follow_symlinks=False)) != identity(self._observed)
        ):
            raise QualificationRefusal("worker")
        return {
            "outgoing_worker": str(self.binary),
            "outgoing_device": str(current.st_dev),
            "outgoing_inode": str(current.st_ino),
            "outgoing_sha256": self._digest,
        }

    def bind_operation(self, operation):
        """The retained source context outlives each actual guardian operation."""
        if self._operation is not None and self._operation.physically_retired is not True:
            raise QualificationRefusal("cleanup")
        self.fields()
        self._operation = operation

    def close(self):
        """Retire numeric references before uncertain close; preserve every debt."""
        if self._operation is not None and self._operation.physically_retired is not True:
            raise QualificationRefusal("cleanup")
        descriptors = [record[1] for record in self._inputs]
        self._inputs = []
        if self._output is not None:
            descriptors.append(self._output)
            self._output = None
        self._qualified = False
        for descriptor in descriptors:
            try:
                os.close(descriptor)
            except BaseException as error:
                if self._close_debt is None:
                    self._close_debt = error
        if self._close_debt is not None:
            raise QualificationRefusal("cleanup") from self._close_debt
