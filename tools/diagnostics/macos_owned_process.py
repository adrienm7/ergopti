# tools/diagnostics/macos_owned_process.py
"""Reserve a native child's PID until its inherited process group is retired.

WNOWAIT observations never reap the leader. The reserved leader PID therefore
cannot be borrowed by a foreign process group between census and signals.
Only descendants remaining in the acquired PGID are managed; this helper makes
no claim about processes that create another session or leave that group.
"""

import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


class OwnedProcessError(RuntimeError):
    """A native ownership observation failed; inputs must remain available."""


class OwnedProcessInterrupted(OwnedProcessError):
    """Cancellation preserves ownership until cleanup revalidates the native reservation."""


def require(condition, message):
    """Reject an unsupported native ownership operation."""
    if not condition:
        raise OwnedProcessError(message)


class ProcBSDInfo(ctypes.Structure):
    """Apple proc_info.h's fixed PROC_PIDTBSDINFO record, including its reserved slot."""

    _fields_ = (
        [
            (name, ctypes.c_uint32)
            for name in (
                "flags",
                "status",
                "xstatus",
                "pid",
                "ppid",
                "uid",
                "gid",
                "ruid",
                "rgid",
                "svuid",
                "svgid",
                "reserved",
            )
        ]
        + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
        + [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid")]
        + [
            ("nice", ctypes.c_int32),
            ("start_sec", ctypes.c_uint64),
            ("start_usec", ctypes.c_uint64),
        ]
    )


class NativeProcessGroups:
    """Admit actual macOS nonreaping waits and native inherited-PGID census."""

    def __init__(self):
        require(sys.platform == "darwin", "Native process-group ownership requires macOS")
        require(
            all(
                hasattr(os, name)
                for name in (
                    "waitid",
                    "P_PID",
                    "WEXITED",
                    "WNOHANG",
                    "WNOWAIT",
                    "CLD_EXITED",
                    "CLD_KILLED",
                    "CLD_DUMPED",
                )
            ),
            "This Python runtime does not expose native WNOWAIT ownership",
        )
        require(ctypes.sizeof(ProcBSDInfo) == 136, "Unsupported native PROC_PIDTBSDINFO ABI")
        self.library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.library.proc_listpids.argtypes = [
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self.library.proc_listpids.restype = ctypes.c_int
        self.library.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self.library.proc_pidinfo.restype = ctypes.c_int

    def observe_exit(self, process):
        """Observe a direct child's exit while preserving its waitable PID reservation."""
        require(
            process.returncode is None, "Leader was reaped before native process-group retirement"
        )
        try:
            observation = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except ChildProcessError as failure:
            raise OwnedProcessError(
                "Direct child reservation was lost; no further group signal is permitted"
            ) from failure
        if observation is None or observation.si_pid == 0:
            return None
        require(
            observation.si_pid == process.pid
            and observation.si_code in (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED),
            "Unexpected native nonreaping child observation",
        )
        # A repeated actual native observation admits WNOWAIT's behavior, rather
        # than merely assuming the flag is implemented because it is exported.
        repeated = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        require(
            repeated is not None
            and repeated.si_pid == observation.si_pid
            and repeated.si_code == observation.si_code
            and repeated.si_status == observation.si_status,
            "Native WNOWAIT did not preserve the exact child's terminal observation",
        )
        return observation

    def live_members(self, group_id, reserved_leader):
        """Exclude zombie records, never an unobserved live group leader."""
        required = self.library.proc_listpids(2, group_id, None, 0)  # PROC_PGRP_ONLY
        require(0 < required <= 1024 * 1024, "Native process-group census size was refused")
        capacity = required + 256  # Room for a concurrent fork; a full census is refused.
        storage = (ctypes.c_int * ((capacity + 3) // 4))()
        written = self.library.proc_listpids(2, group_id, storage, ctypes.sizeof(storage))
        require(
            0 < written < ctypes.sizeof(storage) and written % ctypes.sizeof(ctypes.c_int) == 0,
            "Native process-group census was truncated or unavailable",
        )
        live = []
        reserved_zombie_seen = False
        for pid in storage[: written // ctypes.sizeof(ctypes.c_int)]:
            if pid <= 0:
                continue
            info = ProcBSDInfo()
            ctypes.set_errno(0)
            received = self.library.proc_pidinfo(
                pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info)
            )  # PROC_PIDTBSDINFO, include zombies
            if received == 0 and ctypes.get_errno() == errno.ESRCH:
                continue
            require(
                received == ctypes.sizeof(info) and info.pid == pid,
                "Native process-group member identity was unavailable",
            )
            if info.pgid != group_id:
                continue  # The census race left this inherited-PGID ownership scope.
            if pid == reserved_leader:
                require(
                    info.status == 5 and info.ppid == os.getpid(),
                    "Reserved group leader was not our native zombie",
                )  # SZOMB
                reserved_zombie_seen = True
            if info.status != 5:
                live.append(pid)
        require(reserved_zombie_seen, "Native census did not prove the reserved zombie leader")
        return live


class OwnedProcessGroup:
    """Retain one acquired leader until all observed inherited-PGID members retire."""

    def __init__(self, process, native):
        self.process = process
        self.native = native
        self.reap_started = False
        self.reaped = False
        self.reservation_lost = False
        self.signals = []
        self.last_live_members = []

    def observe_exit(self):
        """Never call Popen.poll/wait before native group retirement."""
        require(
            not self.reap_started and not self.reservation_lost,
            "Child reservation cannot authorize another signal",
        )
        try:
            return self.native.observe_exit(self.process)
        except OwnedProcessInterrupted:
            raise
        except Exception:
            self.reservation_lost = True
            raise

    def wait_for_exit(self, timeout):
        """Poll WNOWAIT within a deadline without releasing the acquired PID."""
        deadline = time.monotonic() + timeout
        while True:
            if self.observe_exit() is not None:
                return
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired("owned native child", timeout)
            time.sleep(0.02)

    def closed_before_reap(self):
        """A reserved zombie leader and no live inherited-PGID member permit one reap."""
        if self.observe_exit() is None:
            return False
        self.last_live_members = self.native.live_members(self.process.pid, self.process.pid)
        return not self.last_live_members

    def settle(self, timeout=1):
        """Signal only while the leader remains reserved; never signal after reap."""
        if self.reaped:
            return True
        if self.reap_started or self.reservation_lost:
            return False
        for sig in (None, signal.SIGTERM, signal.SIGKILL):
            if sig is not None:
                self.observe_exit()  # ECHILD/reaped state refuses the signal before it happens.
                try:
                    os.killpg(self.process.pid, sig)
                    self.signals.append(sig)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + (timeout if sig is not None else 0)
            while True:
                if self.closed_before_reap():
                    self.reap_started = True
                    self.process.wait(timeout=1)
                    self.reaped = True
                    return True
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.02)
        return False

    def receipt(self):
        """Return ownership observations without command arguments or environment values."""
        return {
            "worker_pid": self.process.pid,
            "group_id": self.process.pid,
            "closed": self.reaped,
            "reservation_lost": self.reservation_lost,
            "signals": self.signals,
            "live_group_members": self.last_live_members,
            "escaped_sessions_managed": False,
        }


def acquire_owned(arguments, native, register, **options):
    """Register a native PID before delivering acquisition-time interruptions.

    Parent handlers temporarily collect signals instead of changing the mask:
    Popen workers must not inherit newly blocked SIGTERM/SIGINT across exec.
    """
    previous = {}
    pending = []
    group = None
    failure = None

    def deferred(signum, frame):
        pending.append((signum, frame))

    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            old = signal.getsignal(signum)
            signal.signal(signum, deferred)
            previous[signum] = old
        options.setdefault("stdin", subprocess.DEVNULL)
        process = subprocess.Popen(arguments, start_new_session=True, **options)
        group = OwnedProcessGroup(process, native)
        try:
            register(group)
        except BaseException:
            group.settle()
            raise
    except BaseException as error:
        failure = error
    finally:
        for signum, handler in previous.items():
            try:
                signal.signal(signum, handler)
            except Exception as error:
                if failure is None:
                    failure = error
    if failure is not None:
        raise failure
    for signum, frame in pending:
        handler = previous[signum]
        if callable(handler):
            handler(signum, frame)
        elif handler == signal.SIG_DFL:
            os.kill(os.getpid(), signum)
    return group


def exclusive_receipt(path, receipt):
    """Publish one closed terminal packet atomically without replacing user state."""
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".owned-process-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(receipt, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)  # Existing destination is a refusal, never an overwrite.
    finally:
        os.unlink(temporary)


def run_guardian(receipt_path, timeout, arguments):
    """Keep worker streams inherited and native normal status exact for XCTest invokers."""
    receipt_path = Path(receipt_path)
    require(
        receipt_path.parent.is_dir()
        and not receipt_path.exists()
        and not receipt_path.is_symlink(),
        "Terminal receipt path is not exclusively available",
    )
    require(
        (receipt_path.parent.stat().st_mode & 0o777) == 0o700,
        "Guardian receipt directory is not private",
    )
    require(
        timeout > 0 and arguments, "Guardian requires a positive deadline and exact child arguments"
    )
    native = NativeProcessGroups()
    old_handlers = {}
    group = None
    failure = None

    def interrupted(_signal, _frame):
        raise OwnedProcessInterrupted("Owned native guardian interrupted")

    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            old_handlers[sig] = signal.signal(sig, interrupted)

        def register(acquired):
            nonlocal group
            group = acquired

        acquire_owned(arguments, native, register)
        group.wait_for_exit(timeout)
    except BaseException as error:
        failure = error
    finally:
        cleanup_failure = None
        closed = False
        try:
            for sig in old_handlers:
                signal.signal(sig, signal.SIG_IGN)
            closed = group is not None and group.settle()
            if closed:
                status = group.process.returncode if failure is None else 124
                exclusive_receipt(
                    receipt_path,
                    {
                        "schema": 1,
                        "guardian_pid": os.getpid(),
                        "worker_pid": group.process.pid,
                        "group_id": group.process.pid,
                        "closed": True,
                        "exit_status": status,
                    },
                )
        except Exception as error:
            cleanup_failure = error
        finally:
            for sig, handler in old_handlers.items():
                try:
                    signal.signal(sig, handler)
                except Exception as error:
                    cleanup_failure = error
    if failure is not None:
        raise OwnedProcessError(
            "Owned guardian operation failed before its deadline or was interrupted"
        ) from failure
    if cleanup_failure is not None:
        raise OwnedProcessError(
            "Owned guardian terminal publication or retirement failed"
        ) from cleanup_failure
    require(closed, "Owned guardian retains inherited-PGID retirement debt")
    return group.process.returncode


def relay_worker_signal(status):
    """Mirror a retired worker's signal only onto this current guardian process."""
    require(status < 0, "Only a signaled worker can request guardian signal relay")
    signum = -status
    if signum not in (signal.SIGKILL, signal.SIGSTOP):
        signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["run"])
    parser.add_argument("receipt")
    parser.add_argument("timeout", type=float)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    arguments = options.arguments[1:] if options.arguments[:1] == ["--"] else options.arguments
    try:
        result = run_guardian(options.receipt, options.timeout, arguments)
    except (OwnedProcessError, OSError) as error:
        print("Native owned process failed: " + str(error), file=sys.stderr)
        raise SystemExit(124)
    if result < 0:
        relay_worker_signal(result)
    raise SystemExit(result)
