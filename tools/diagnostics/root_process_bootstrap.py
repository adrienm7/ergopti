# tools/diagnostics/root_process_bootstrap.py
"""TEST ONLY: fixed-source protected compilation with the actual root parent.

This module is embedded as fixed admitted text, after the waitid bridge, in an
admitted Apple Python -I -S -B invocation. It imports no runner-owned module.
Trusted Apple OS, Apple compiler/runtime and already privileged actors are an
explicit boundary. Unknown physical retirement permanently revokes operations
and retains the actual live root parent. Such debt is not production closure.
"""

import base64
import ctypes
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

BOOTSTRAP_C_SHA256 = "6adb17bcbadee205468ae5694693ecbc1ba3d9799e4ccd3d9b3f5f31955047ad"
CLEAN_ENVIRONMENT = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}


class BootstrapRefusal(RuntimeError):
    """Fail closed while preserving any acquired child and physical scope."""


def bootstrap_require(condition, message):
    if not condition:
        raise BootstrapRefusal(message)


def bootstrap_now():
    value = time.monotonic()
    bootstrap_require(type(value) is float and value >= 0, "monotonic clock unavailable")
    return value


class DarwinTimespec(ctypes.Structure):
    """Apple LP64 timespec, independently pinned from the XNU headers."""

    _fields_ = [("tv_sec", ctypes.c_int64), ("tv_nsec", ctypes.c_int64)]


class DarwinStat(ctypes.Structure):
    """Apple LP64 struct stat; the native SDK oracle must qualify this layout."""

    _fields_ = [
        ("st_dev", ctypes.c_int32),
        ("st_mode", ctypes.c_uint16),
        ("st_nlink", ctypes.c_uint16),
        ("st_ino", ctypes.c_uint64),
        ("st_uid", ctypes.c_uint32),
        ("st_gid", ctypes.c_uint32),
        ("st_rdev", ctypes.c_int32),
        ("st_atimespec", DarwinTimespec),
        ("st_mtimespec", DarwinTimespec),
        ("st_ctimespec", DarwinTimespec),
        ("st_birthtimespec", DarwinTimespec),
        ("st_size", ctypes.c_int64),
        ("st_blocks", ctypes.c_int64),
        ("st_blksize", ctypes.c_int32),
        ("st_flags", ctypes.c_uint32),
        ("st_gen", ctypes.c_uint32),
        ("st_lspare", ctypes.c_int32),
        ("st_qspare", ctypes.c_int64 * 2),
    ]


class RootACL:
    """Admit explicit successful stat and valid zero-entry or absent extended ACL.

    A NULL from acl_get_fd_np cannot prove absence. The filesec stat succeeds
    first, and its physical identity must agree with the held descriptor before
    and after the query. The injected library is only a portable-test seam.
    """

    def __init__(self, *, library=None):
        bootstrap_require(
            ctypes.sizeof(DarwinStat) == 144 and ctypes.alignment(DarwinStat) == 8,
            "Darwin stat ABI refused",
        )
        self.lib = (
            library
            if library is not None
            else ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        )
        self.lib.filesec_init.argtypes = []
        self.lib.filesec_init.restype = ctypes.c_void_p
        self.lib.fstatx_np.argtypes = [ctypes.c_int, ctypes.POINTER(DarwinStat), ctypes.c_void_p]
        self.lib.fstatx_np.restype = ctypes.c_int
        self.lib.filesec_get_property.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        self.lib.filesec_get_property.restype = ctypes.c_int
        self.lib.filesec_free.argtypes = [ctypes.c_void_p]
        self.lib.filesec_free.restype = None
        self.lib.acl_valid.argtypes = [ctypes.c_void_p]
        self.lib.acl_valid.restype = ctypes.c_int
        self.lib.acl_get_entry.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self.lib.acl_get_entry.restype = ctypes.c_int
        self.lib.acl_free.argtypes = [ctypes.c_void_p]
        self.lib.acl_free.restype = ctypes.c_int

    @staticmethod
    def identity(value):
        return (
            value.st_dev,
            value.st_ino,
            value.st_uid,
            value.st_gid,
            value.st_mode,
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )

    def empty(self, descriptor):
        before = os.fstat(descriptor)
        security = self.lib.filesec_init()
        bootstrap_require(bool(security), "file security allocation unavailable")
        acl = ctypes.c_void_p()
        try:
            native = DarwinStat()
            bootstrap_require(
                self.lib.fstatx_np(descriptor, ctypes.byref(native), security) == 0,
                "explicit file security stat unavailable",
            )
            snapshot = (
                native.st_dev,
                native.st_ino,
                native.st_uid,
                native.st_gid,
                native.st_mode,
                native.st_nlink,
                native.st_size,
                native.st_mtimespec.tv_sec * 1_000_000_000 + native.st_mtimespec.tv_nsec,
                native.st_ctimespec.tv_sec * 1_000_000_000 + native.st_ctimespec.tv_nsec,
            )
            bootstrap_require(
                snapshot == self.identity(before), "file security stat identity mismatch"
            )
            ctypes.set_errno(0)
            result = self.lib.filesec_get_property(security, 5, ctypes.byref(acl))
            if result == -1 and ctypes.get_errno() == errno.ENOENT:
                bootstrap_require(not acl.value, "absent ACL returned an unexpected pointer")
            else:
                bootstrap_require(
                    result == 0 and acl.value is not None and acl.value > 1,
                    "extended ACL property unavailable",
                )
                bootstrap_require(self.lib.acl_valid(acl.value) == 0, "invalid extended ACL")
                entry = ctypes.c_void_p()
                ctypes.set_errno(0)
                first = self.lib.acl_get_entry(acl.value, 0, ctypes.byref(entry))
                bootstrap_require(
                    first == -1 and ctypes.get_errno() == errno.EINVAL and not entry.value,
                    "extended ACL is not empty",
                )
            bootstrap_require(
                self.identity(os.fstat(descriptor)) == self.identity(before),
                "held file changed during security query",
            )
        finally:
            try:
                if acl.value:
                    bootstrap_require(
                        self.lib.acl_free(acl.value) == 0, "extended ACL release unknown"
                    )
            finally:
                self.lib.filesec_free(security)


class RootPath:
    """Held root-owned canonical ancestry; executable use remains a closed role."""

    def __init__(self, path, acl, *, directory=False, sticky_anchor=False):
        self.path, self.acl = Path(path), acl
        self.nodes = []
        self.close_debt = []
        try:
            bootstrap_require(
                self.path.is_absolute() and self.path.resolve(strict=True) == self.path,
                "noncanonical Apple path",
            )
            for item in [*reversed(self.path.parents), self.path]:
                named = item.lstat()
                bootstrap_require(
                    named.st_uid == 0
                    and (
                        not named.st_mode & 0o022
                        or (
                            item == Path("/private/var/tmp")
                            and stat.S_IMODE(named.st_mode) == 0o1777
                        )
                    ),
                    "Apple ancestry is writable outside root",
                )
                bootstrap_require(
                    stat.S_ISDIR(named.st_mode)
                    if item != self.path or directory
                    else stat.S_ISREG(named.st_mode) and named.st_nlink == 1,
                    "Apple path type refused",
                )
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
                if stat.S_ISDIR(named.st_mode):
                    flags |= os.O_DIRECTORY
                fd = os.open(item, flags)
                self.nodes.append((item, fd, self.identity(named, ancestry=item != self.path)))
                bootstrap_require(
                    self.identity(os.fstat(fd), ancestry=item != self.path)
                    == self.identity(named, ancestry=item != self.path),
                    "Apple path changed",
                )
                acl.empty(fd)
                if item != self.path:
                    self.nodes[-1] = (item, None, self.nodes[-1][2])
                    try:
                        os.close(fd)
                    except OSError as error:
                        self.close_debt.append(error)
                        raise
            self.current()
        except BaseException as original:
            try:
                self.close()
            except OSError:
                original.root_path_close_debt = self
            original.root_path_owner = self
            raise

    @staticmethod
    def identity(value, *, ancestry=False):
        physical = (
            value.st_dev,
            value.st_ino,
            value.st_uid,
            value.st_gid,
            value.st_mode,
            value.st_nlink,
        )
        return (
            physical
            if ancestry
            else physical + (value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        )

    def current(self):
        for path, fd, expected in self.nodes:
            borrowed = fd is not None
            if not borrowed:
                fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                bootstrap_require(
                    self.identity(os.fstat(fd), ancestry=path != self.path) == expected
                    and self.identity(path.lstat(), ancestry=path != self.path) == expected,
                    "Apple input changed",
                )
                self.acl.empty(fd)
            finally:
                if not borrowed:
                    os.close(fd)

    def close(self):
        while self.nodes:
            _, fd, _ = self.nodes.pop()
            if fd is not None:
                try:
                    os.close(
                        fd
                    )  # Custody is consumed before close; an unknown result is never retried.
                except OSError as error:
                    self.close_debt.append(error)
                    raise


class BootstrapProcInfo(ctypes.Structure):
    """Apple proc_bsdinfo; the native SDK oracle independently verifies layout."""

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


class RootReservation:
    """One actual direct child, including its waitable PGID reservation."""

    def __init__(self, process, waiter, deadline):
        self.process, self.waiter, self.deadline = process, waiter, deadline
        self.closed = False
        self.expired = False
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
        bootstrap_require(ctypes.sizeof(BootstrapProcInfo) == 136, "proc_bsdinfo ABI refused")

    def observed(self):
        bootstrap_require(
            not self.closed and self.process.returncode is None, "child already reaped"
        )
        return self.waiter.observe_pid(self.process.pid)

    def remaining(self):
        bootstrap_require(
            not self.expired and bootstrap_now() < self.deadline,
            "absolute operation deadline expired",
        )

    def live_group(self):
        amount = self.library.proc_listpids(2, self.process.pid, None, 0)
        bootstrap_require(0 < amount <= 65536, "group census size refused")
        storage = (ctypes.c_int * ((amount + 256 + 3) // 4))()
        count = self.library.proc_listpids(2, self.process.pid, storage, ctypes.sizeof(storage))
        bootstrap_require(
            0 < count < ctypes.sizeof(storage) and count % 4 == 0, "group census truncated"
        )
        seen, live = False, []
        for pid in storage[: count // 4]:
            if pid <= 0:
                continue
            value = BootstrapProcInfo()
            ctypes.set_errno(0)
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(value), ctypes.sizeof(value))
            if not result and ctypes.get_errno() == errno.ESRCH:
                continue
            bootstrap_require(
                result == ctypes.sizeof(value) and value.pid == pid, "group member identity refused"
            )
            if value.pgid != self.process.pid:
                continue
            if pid == self.process.pid:
                bootstrap_require(
                    value.ppid == os.getpid() and value.status == 5 and value.uid == 0,
                    "reserved root zombie identity refused",
                )
                seen = True
            if value.status != 5:
                live.append(pid)
        bootstrap_require(seen, "reserved zombie missing from group census")
        return live

    def close_if_terminal(self):
        receipt = self.observed()
        if receipt is None or self.live_group():
            return None
        self.remaining()
        pid, status = os.waitpid(self.process.pid, 0)
        bootstrap_require(pid == self.process.pid, "final child reap unknown")
        self.closed = True
        self.process.returncode = os.waitstatus_to_exitcode(status)
        bootstrap_require(
            self.process.returncode
            == (receipt.si_status if receipt.si_code == 1 else -receipt.si_status),
            "reap did not match the reserved terminal receipt",
        )
        return self.process.returncode

    def await_closed(self):
        while True:
            self.remaining()
            result = self.close_if_terminal()
            if result is not None:
                return result
            time.sleep(0.001)

    def settle(self):
        for number in (signal.SIGTERM, signal.SIGKILL):
            self.remaining()
            receipt = self.observed()  # ECHILD revokes any subsequent signal.
            if receipt is not None and not self.live_group():
                return self.close_if_terminal()
            # The actual acquired PID is reserved even before successful PGID creation.
            target = (
                -self.process.pid
                if os.getpgid(self.process.pid) == self.process.pid
                else self.process.pid
            )
            try:
                os.kill(target, number)
            except ProcessLookupError:
                pass
            until = min(self.deadline, bootstrap_now() + 0.05)
            while bootstrap_now() < until:
                result = self.close_if_terminal()
                if result is not None:
                    return result
                time.sleep(0.001)
        return self.await_closed()

    def retain_expired(self):
        self.expired = True
        # No signals, compilation, new deadline, reap or path deletion after uncertainty.
        # The live root process remains the actual parent, never a JSON ownership surrogate.
        while True:
            time.sleep(1)


def admit_apple_runtime(acl):
    """Require actual Apple runtime files and its whole library tree before native tools."""
    executable = Path(sys.executable).resolve(strict=True)
    bootstrap_require(
        str(executable).startswith(("/Applications/", "/Library/Developer/"))
        and executable.name.startswith("python3"),
        "Apple interpreter role refused",
    )
    paths = [RootPath(executable, acl)]
    roots = {Path(sys.prefix).resolve(strict=True), Path(os.__file__).resolve(strict=True).parent}
    for root in roots:
        paths.append(RootPath(root, acl, directory=True))
    for name, module in tuple(sys.modules.items()):
        value = getattr(module, "__file__", None)
        if value and not value.startswith("<"):
            location = Path(value).resolve(strict=True)
            bootstrap_require(
                any(location.is_relative_to(root) for root in roots),
                "non-Apple Python dependency loaded",
            )
            paths.append(RootPath(location, acl))
    return paths


def admit_fixed_tree(root, acl, deadline):
    """Admit every existing root-owned file/ACL under a closed Apple input tree.

    This is a permission/custody prerequisite, not a content manifest or signing
    receipt. Any external symlink, special file or writable/ACL-bearing entry
    refuses; trusted root/Apple installers remain an explicit boundary.
    """
    root = Path(root).resolve(strict=True)
    held_root = RootPath(root, acl, directory=True)
    try:
        subjects = 0
        for path in root.rglob("*"):
            bootstrap_require(bootstrap_now() < deadline, "Apple tree admission deadline")
            target = path.resolve(strict=True)
            bootstrap_require(target.is_relative_to(root), "Apple input external link")
            held = RootPath(target, acl, directory=target.is_dir())
            try:
                held.current()
            finally:
                held.close()
            subjects += 1
        bootstrap_require(subjects > 0, "Apple input tree was empty")
        held_root.current()
        return held_root
    except BaseException:
        held_root.close()
        raise


def root_bootstrap(arguments, waiter_type, abi_decoder):
    """Compile and execute only the fixed C supervisor under the original deadline."""
    bootstrap_require(
        sys.platform == "darwin" and os.getuid() == os.geteuid() == 0,
        "bootstrap requires actual root",
    )
    bootstrap_require(len(arguments) == 5, "closed bootstrap argument count")
    compiler_path, sdk_path, encoded, expiry, encoded_abi = arguments
    # SDK observations gate ABI use only; actual root custody is independently acquired below.
    abi_decoder(encoded_abi)
    bootstrap_require(re.fullmatch(r"[1-9][0-9]{0,18}", expiry), "absolute deadline shape")
    deadline = int(expiry) / 1_000_000_000
    now = bootstrap_now()
    bootstrap_require(now < deadline <= now + 25, "absolute deadline refused")
    source = base64.b64decode(encoded, validate=True)
    bootstrap_require(
        0 < len(source) <= 65536 and hashlib.sha256(source).hexdigest() == BOOTSTRAP_C_SHA256,
        "fixed C source pin refused",
    )
    bootstrap_require(
        re.fullmatch(
            r"/(?:Applications/[^\n]+\.app/Contents/Developer/Toolchains/XcodeDefault\.xctoolchain|Library/Developer/CommandLineTools)/usr/bin/clang",
            compiler_path,
        ),
        "fixed Apple compiler role refused",
    )
    sdk = Path(sdk_path)
    bootstrap_require(
        re.fullmatch(r"MacOSX[0-9]*(?:\.[0-9]+)*\.sdk", sdk.name), "Apple SDK role refused"
    )
    os.environ.clear()
    os.environ.update(CLEAN_ENVIRONMENT)
    acl = RootACL()
    paths = admit_apple_runtime(acl)
    compiler = RootPath(compiler_path, acl)
    selected_sdk = admit_fixed_tree(sdk_path, acl, deadline)
    toolchain = Path(compiler_path).parent.parent.parent
    admitted_toolchain = admit_fixed_tree(toolchain, acl, deadline)
    admitted_python = admit_fixed_tree(Path(sys.prefix), acl, deadline)
    anchor = RootPath(
        "/private/var/tmp", acl, directory=True, sticky_anchor=True
    )  # Special sticky anchor is admitted below.
    waiter = waiter_type()
    owners = []
    directory_fd = None
    scope = None
    try:
        # A real direct-child two-observation/reap prerequisite runs before a root compiler.
        probe = os.fork()
        if probe == 0:
            os._exit(7)
        probe_reaped = False
        try:
            while True:
                bootstrap_require(bootstrap_now() < deadline, "waitid prerequisite timed out")
                observed = waiter.observe_pid(probe)
                if observed is not None:
                    bootstrap_require(
                        observed.si_code == 1 and observed.si_status == 7 and observed.si_uid == 0,
                        "root waitid prerequisite refused",
                    )
                    pid, status = os.waitpid(probe, 0)
                    probe_reaped = True
                    bootstrap_require(
                        pid == probe and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 7,
                        "root waitid prerequisite reap refused",
                    )
                    break
                time.sleep(0.001)
        except BaseException:
            if not probe_reaped:
                # No compiler starts and no PID is reaped or signaled on an unknown bridge result.
                while True:
                    time.sleep(1)
            raise
        flags = fcntl.fcntl(0, fcntl.F_GETFL)
        bootstrap_require(
            stat.S_ISFIFO(os.fstat(0).st_mode) and flags & os.O_NONBLOCK,
            "borrowed cancellation reader refused",
        )
        scope = Path("/private/var/tmp") / ("ergopti-root-process-" + os.urandom(16).hex())
        os.mkdir(scope, 0o700)
        directory_fd = os.open(scope, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        acl.empty(directory_fd)
        baseline = os.fstat(directory_fd)
        bootstrap_require(
            baseline.st_uid == 0 and stat.S_IMODE(baseline.st_mode) == 0o700,
            "root-created scope refused",
        )
        fd = os.open(
            "source.c",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o400,
            dir_fd=directory_fd,
        )
        try:
            at = 0
            while at < len(source):
                bootstrap_require(bootstrap_now() < deadline, "copy deadline expired")
                count = os.write(fd, source[at:])
                bootstrap_require(count > 0, "fixed source copy failed")
                at += count
            os.fsync(fd)
            acl.empty(fd)
        finally:
            consumed, fd = fd, None
            os.close(consumed)
        protected_source = RootPath(scope / "source.c", acl)
        paths.append(protected_source)
        bootstrap_require(
            hashlib.sha256(os.pread(protected_source.nodes[-1][1], len(source) + 1, 0)).hexdigest()
            == BOOTSTRAP_C_SHA256,
            "protected fixed source digest refused",
        )
        bootstrap_require(
            set(os.listdir(directory_fd)) == {"source.c"}, "protected source inventory refused"
        )
        compiler.current()
        selected_sdk.current()
        admitted_toolchain.current()
        admitted_python.current()
        protected_source.current()
        owner = RootReservation(None, waiter, deadline)
        owners.append(owner)
        process = subprocess.Popen(
            [
                str(compiler.path),
                "-std=c17",
                "-Wno-deprecated-declarations",
                "-isysroot",
                str(selected_sdk.path),
                str(scope / "source.c"),
                "-o",
                str(scope / "probe"),
            ],
            env=CLEAN_ENVIRONMENT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        owner.process = process
        bootstrap_require(owner.await_closed() == 0, "protected native compilation failed")
        compiler.current()
        selected_sdk.current()
        admitted_toolchain.current()
        admitted_python.current()
        protected_source.current()
        product = scope / "probe"
        os.chmod(product, 0o500, follow_symlinks=False)
        image = RootPath(product, acl)
        paths.append(image)
        bootstrap_require(
            set(os.listdir(directory_fd)) == {"source.c", "probe"}, "protected inventory refused"
        )
        data = product.read_bytes()
        bootstrap_require(0 < len(data) <= 4194304, "protected product size refused")
        image.current()
        owner = RootReservation(None, waiter, deadline)
        owners.append(owner)
        process = subprocess.Popen(
            [str(product), "--probe", hashlib.sha256(data).hexdigest(), expiry],
            env=CLEAN_ENVIRONMENT,
            stdin=0,
            stdout=1,
            stderr=2,
            start_new_session=True,
        )
        owner.process = process
        bootstrap_require(owner.await_closed() == 0, "protected supervisor refused")
        # The supervisor consumed only its own product. The root parent owns source and directory cleanup.
        bootstrap_require(
            set(os.listdir(directory_fd)) == {"source.c"}, "retired scope inventory refused"
        )
        current = os.fstat(directory_fd)
        named = scope.lstat()
        bootstrap_require(
            (current.st_dev, current.st_ino, current.st_uid, stat.S_IMODE(current.st_mode))
            == (baseline.st_dev, baseline.st_ino, 0, 0o700)
            and (named.st_dev, named.st_ino) == (baseline.st_dev, baseline.st_ino),
            "root-created scope changed",
        )
        os.unlink("source.c", dir_fd=directory_fd)
        consumed, directory_fd = directory_fd, None
        os.close(consumed)
        os.rmdir(scope)
        scope = None
        print("V1 RETIRED", flush=True)
    except BaseException:
        for owner in owners:
            if owner.process is not None and not owner.closed:
                try:
                    owner.settle()
                except BaseException:
                    owner.retain_expired()
        raise
    finally:
        for path in reversed(paths):
            path.close()
        selected_sdk.close()
        admitted_toolchain.close()
        admitted_python.close()
        compiler.close()
        anchor.close()
