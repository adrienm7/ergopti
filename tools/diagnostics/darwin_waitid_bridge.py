# tools/diagnostics/darwin_waitid_bridge.py
"""TEST ONLY: nonreaping Darwin LP64 direct-child observation.

The record and constants come from independently pinned Apple XNU headers.
The native SDK oracle must qualify the running system before privileged use.
Loading libSystem relies on the trusted Apple OS/dyld shared cache; this is not
custody of a file under /usr/lib or permission to signal an arbitrary PID.
"""

import ctypes
from collections import namedtuple
import sys


class DarwinWaitIdError(RuntimeError):
    """A wait observation cannot authorize physical retirement."""


class DarwinSigInfo(ctypes.Structure):
    """Apple LP64 siginfo_t, including the reserved unsigned-long tail."""

    _fields_ = [
        ("si_signo", ctypes.c_int),
        ("si_errno", ctypes.c_int),
        ("si_code", ctypes.c_int),
        ("si_pid", ctypes.c_int),
        ("si_uid", ctypes.c_uint32),
        ("si_status", ctypes.c_int),
        ("si_addr", ctypes.c_void_p),
        ("si_value", ctypes.c_void_p),
        ("si_band", ctypes.c_long),
        ("__pad", ctypes.c_ulong * 7),
    ]


DarwinObservation = namedtuple("DarwinObservation", "si_pid si_signo si_code si_status si_uid")


class DarwinWaitId:
    """Observe an acquired direct child twice without releasing its reservation.

    ``library`` is a portable-test seam, never a privileged admission receipt.
    Callers own the direct child and must separately qualify SDK ABI, PGID,
    census, cancellation, deadline, currentness, and final single reap.
    """

    def __init__(self, *, library=None):
        if ctypes.sizeof(DarwinSigInfo) != 104 or ctypes.alignment(DarwinSigInfo) != 8:
            raise DarwinWaitIdError("unsupported Darwin LP64 siginfo ABI")
        if library is None:
            if sys.platform != "darwin":
                raise DarwinWaitIdError("Darwin waitid requires the native Apple OS")
            library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        self.library = library
        self.library.waitid.argtypes = [
            ctypes.c_int,
            ctypes.c_uint32,
            ctypes.POINTER(DarwinSigInfo),
            ctypes.c_int,
        ]
        self.library.waitid.restype = ctypes.c_int

    def _one(self, pid):
        value = DarwinSigInfo()
        ctypes.set_errno(0)
        result = self.library.waitid(1, pid, ctypes.byref(value), 37)
        if result != 0:
            raise DarwinWaitIdError("native nonreaping waitid refused: " + str(ctypes.get_errno()))
        if value.si_pid == 0:
            return None
        if value.si_pid != pid or value.si_signo != 20 or value.si_code not in (1, 2, 3):
            raise DarwinWaitIdError("unexpected native terminal receipt")
        return DarwinObservation(
            value.si_pid, value.si_signo, value.si_code, value.si_status, value.si_uid
        )

    def observe_pid(self, pid):
        """Return a stable immutable exit observation, or None for a live child."""
        if type(pid) is not int or not 0 < pid < 2**31:
            raise DarwinWaitIdError("invalid direct child identity")
        first = self._one(pid)
        if first is None:
            return None
        if self._one(pid) != first:
            raise DarwinWaitIdError("nonreaping waitid did not preserve the exact receipt")
        return first
