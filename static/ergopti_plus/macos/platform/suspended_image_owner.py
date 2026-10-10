# platform/suspended_image_owner.py
"""Own the native suspended guardian and release session bytes after image proof."""

import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import stat
import subprocess
import time


class ImageRefusal(RuntimeError):
    """Fixed reasons never expose private session bytes or native stderr."""

    def __init__(self, reason, *, primary=None, cleanup=None):
        super().__init__(reason)
        self.primary, self.cleanup = primary, cleanup


def vnode(value):
    return value.st_dev, value.st_ino


def decimal(text, maximum, *, positive=False):
    if (
        type(text) is not str
        or re.fullmatch(r"0|[1-9][0-9]*", text) is None
        or len(text) > 20
        or int(text) > maximum
        or (positive and int(text) == 0)
    ):
        raise ImageRefusal("protocol")
    return int(text)


class EmptySession:
    """Retain one canonical empty file; secrets stay in memory until IMAGE_READY."""

    @classmethod
    def acquire(cls, directory, data, *, register):
        value = cls()
        value.directory = Path(directory)
        value.name = "daemon-" + secrets.token_hex(16) + ".json"
        value.path = value.directory / value.name
        value.data = dict(data)
        value._directory_fd = None
        value._file_fd = None
        value._created = False
        value._close_debt = None
        value._operation = None
        value._written = b""
        register(value)
        try:
            value.directory.mkdir(mode=0o700, exist_ok=True)
            value._directory_fd = os.open(
                value.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
            )
            value._directory_identity = os.fstat(value._directory_fd)
            directory_identity = value._directory_identity
            if (
                not stat.S_ISDIR(directory_identity.st_mode)
                or directory_identity.st_uid != os.geteuid()
                or stat.S_IMODE(directory_identity.st_mode) != 0o700
                or vnode(value.directory.stat(follow_symlinks=False)) != vnode(directory_identity)
            ):
                raise ImageRefusal("session")
            value._file_fd = os.open(
                value.name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=value._directory_fd,
            )
            value._created = True
            value._file_identity = os.fstat(value._file_fd)
            value.validate()
            return value
        except BaseException as primary:
            try:
                value.retire()
            except BaseException as cleanup:
                raise ImageRefusal("operation", primary=primary, cleanup=cleanup) from primary
            raise

    @classmethod
    def acquire_sibling(cls, session, purpose, *, register):
        """Acquire an exclusive same-nonce private file under the held directory."""
        if (
            purpose not in ("network", "source")
            or re.fullmatch(r"daemon-[0-9a-f]{32}\.json", session.name) is None
        ):
            raise ImageRefusal("session")
        value = cls()
        value.directory = session.directory
        value.name = purpose + "-" + session.name[len("daemon-") :]
        value.path = value.directory / value.name
        value.session = session
        value._directory_fd = None
        value._file_fd = None
        value._created = False
        value._close_debt = None
        value._operation = None
        value._written = b""
        register(value)
        try:
            session.validate()
            value._directory_fd = os.dup(session._directory_fd)
            os.set_inheritable(value._directory_fd, False)
            value._directory_identity = os.fstat(value._directory_fd)
            value._file_fd = os.open(
                value.name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=value._directory_fd,
            )
            value._created = True
            value._file_identity = os.fstat(value._file_fd)
            value.validate()
            session.validate()
            return value
        except BaseException as primary:
            try:
                value.retire()
            except BaseException as cleanup:
                raise ImageRefusal("operation", primary=primary, cleanup=cleanup) from primary
            raise

    def bind_operation(self, operation):
        if self._operation is not None:
            raise ImageRefusal("state")
        self._operation = operation

    def validate(self):
        if self._close_debt is not None or self._file_fd is None or self._directory_fd is None:
            raise ImageRefusal("cleanup")
        directory = os.fstat(self._directory_fd)
        named_directory = self.directory.stat(follow_symlinks=False)
        file = os.fstat(self._file_fd)
        named_file = os.stat(self.name, dir_fd=self._directory_fd, follow_symlinks=False)
        if (
            not stat.S_ISDIR(directory.st_mode)
            or directory.st_uid != os.geteuid()
            or stat.S_IMODE(directory.st_mode) != 0o700
            or vnode(directory) != vnode(self._directory_identity)
            or vnode(named_directory) != vnode(directory)
            or not stat.S_ISREG(file.st_mode)
            or file.st_uid != os.geteuid()
            or stat.S_IMODE(file.st_mode) != 0o600
            or file.st_nlink != 1
            or vnode(file) != vnode(self._file_identity)
            or vnode(named_file) != vnode(file)
            or os.pread(self._file_fd, len(self._written) + 1, 0) != self._written
        ):
            raise ImageRefusal("session")

    def release_key(self, operation):
        """The exact bound operation must hold actual suspended-image authority."""
        if (
            operation is not self._operation
            or operation.image_ready is not True
            or operation.physically_retired is True
            or self._written
        ):
            raise ImageRefusal("state")
        self.validate()
        operation.recheck_source()
        payload = (json.dumps(self.data, sort_keys=True, separators=(",", ":")) + "\n").encode()
        if not 1 <= len(payload) <= 4096:
            raise ImageRefusal("session")
        while len(self._written) < len(payload):
            operation.progress()
            count = os.write(self._file_fd, payload[len(self._written) :])
            if count <= 0:
                raise ImageRefusal("session")
            self._written += payload[len(self._written) : len(self._written) + count]
        os.fsync(self._file_fd)
        self.validate()
        operation.recheck_source()

    def retire(self):
        if self._operation is not None and self._operation.physically_retired is not True:
            raise ImageRefusal("cleanup")
        if self._created:
            self.validate()
            os.unlink(self.name, dir_fd=self._directory_fd)
            self._created = False
        for attribute in ("_file_fd", "_directory_fd"):
            descriptor = getattr(self, attribute)
            setattr(self, attribute, None)
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except BaseException as error:
                    if self._close_debt is None:
                        self._close_debt = error
        if self._close_debt is not None:
            raise ImageRefusal("cleanup") from self._close_debt


class SuspendedImageOwner:
    """Exact native child proof precedes secrets; exact guardian reap follows use.

    The guardian owns the child group. Its PID is not the daemon PID. No generic
    Popen session wrapper, hard kill, callback-only receipt or process-exit-only
    observation substitutes for its explicit native retirement protocol.
    """

    def __init__(
        self, launcher, request, session, source_check, outgoing, *, register, bootstrap=None
    ):
        self.launcher = Path(launcher)
        self.request = dict(request)
        self.session = session
        self.bootstrap = bootstrap
        self.source_check = source_check
        self.outgoing = outgoing
        self.process = None
        self.image_ready = False
        self.active = False
        self.listener_bound = False
        self.physically_retired = False
        self.listener = None
        self._retired = None
        self._retirement_started = False
        self._refused = None
        self._outgoing_closed = None
        self._bootstrap_closed = None
        self._logs_closed = None
        self._failure = None
        self._protocol_debt = False
        self._close_debt = None
        self._buffers = {"stdout": bytearray(), "stderr": bytearray()}
        self._eof = set()
        self._selector = selectors.DefaultSelector()
        self._startup_deadline = time.monotonic() + request["remaining_ms"] / 1000
        self._spawn_attempted = False
        self._guardian_retirement_proven = False
        self._default_guardian = None
        register(self)
        session.bind_operation(self)
        if outgoing is None:
            if set(request).intersection(
                ("outgoing_worker", "outgoing_device", "outgoing_inode", "outgoing_sha256")
            ):
                raise ImageRefusal("source")
            path = Path(__file__).with_name("trusted_native_guardian.py")
            specification = importlib.util.spec_from_file_location(
                "ergopti_image_trusted_guardian", path
            )
            guardian = importlib.util.module_from_spec(specification)
            specification.loader.exec_module(guardian)
            self._default_guardian = guardian.TrustedNativeGuardian.acquire(
                launcher,
                progress=self.progress,
                register=lambda value: setattr(self, "_default_guardian", value),
            )
            self._default_guardian.bind_operation(self)
        else:
            outgoing.bind_operation(self)
        if bootstrap is not None:
            bootstrap.bind_operation(self)

    def progress(self):
        if time.monotonic() >= self._startup_deadline:
            raise ImageRefusal("deadline")

    def recheck_source(self):
        if self._retirement_started or self._failure is not None or self._protocol_debt:
            raise ImageRefusal("state")
        self.progress()
        self.source_check()
        if self.outgoing is None:
            self._default_guardian.validate(progress=self.progress)
        elif self.outgoing.fields(progress=self.progress) != {
            name: self.request[name]
            for name in ("outgoing_worker", "outgoing_device", "outgoing_inode", "outgoing_sha256")
        }:
            raise ImageRefusal("source")
        if self.bootstrap is not None:
            fields = self.bootstrap.fields()
            if fields != {name: self.request.get(name) for name in fields}:
                raise ImageRefusal("source")
        self.progress()

    def start(self):
        self.recheck_source()
        self.session.validate()
        self.request["remaining_ms"] = max(
            1, int((self._startup_deadline - time.monotonic()) * 1000)
        )
        wire = (json.dumps(self.request, separators=(",", ":")) + "\n").encode()
        if len(wire) > 65537:
            raise ImageRefusal("protocol")
        self.progress()
        self._spawn_attempted = True
        # Register the allocated Popen object before its actual constructor. A
        # setup interruption retains pending ownership rather than losing PID.
        self.process = subprocess.Popen.__new__(subprocess.Popen)
        self.process.__init__(
            [str(self.launcher), "--owned-suspended-image-guardian"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
        for name in ("stdout", "stderr"):
            stream = getattr(self.process, name)
            os.set_blocking(stream.fileno(), False)
            self._selector.register(stream, selectors.EVENT_READ, name)
        os.set_blocking(self.process.stdin.fileno(), False)
        self._send(wire, self._startup_deadline)
        self._wait(lambda: self.image_ready, self._startup_deadline)
        self.recheck_source()
        self.session.release_key(self)
        if self.bootstrap is not None:
            self.bootstrap.release_key(self)
        self._send(b"ACTIVATE\n", self._startup_deadline)
        self._wait(lambda: self.active, self._startup_deadline)

    def wait_listener_bound(self):
        if self.request.get("listener_event") is not True or not self.active:
            raise ImageRefusal("state")
        self.recheck_source()
        self._wait(lambda: self.listener_bound, self._startup_deadline)
        self.recheck_source()
        if self._retirement_started or not self.active or self.physically_retired:
            raise ImageRefusal("state")

    def _send(self, data, deadline):
        offset = 0
        while offset < len(data):
            if time.monotonic() >= deadline:
                raise ImageRefusal("deadline")
            try:
                count = os.write(self.process.stdin.fileno(), data[offset:])
            except BlockingIOError:
                self._pump(deadline)
                continue
            if count <= 0:
                raise ImageRefusal("protocol")
            offset += count

    def _parse(self, raw):
        try:
            fields = raw.decode("ascii").split(" ")
            if any(not value for value in fields) or fields[:1] != ["V1"]:
                raise ImageRefusal("protocol")
            if self._retired is not None or self._refused is not None:
                raise ImageRefusal("protocol")
            role = fields[1]
            if role == "IMAGE_READY" and len(fields) == 8:
                if self.image_ready or self.active or self._retirement_started:
                    raise ImageRefusal("protocol")
                pid = decimal(fields[2], 2**31 - 1, positive=True)
                uid = decimal(fields[3], 2**32 - 1)
                decimal(fields[4], 2**64 - 1)
                decimal(fields[5], 999999)
                device = decimal(fields[6], 2**32 - 1)
                inode = decimal(fields[7], 2**64 - 1, positive=True)
                if (
                    uid != os.geteuid()
                    or (str(device), str(inode)) != (self.request["device"], self.request["inode"])
                    or pid == self.process.pid
                ):
                    raise ImageRefusal("source")
                self.listener = {
                    "pid": pid,
                    "uid": uid,
                    "start_seconds": fields[4],
                    "start_microseconds": fields[5],
                    "device": fields[6],
                    "inode": fields[7],
                }
                self.image_ready = True
            elif role == "ACTIVE" and len(fields) == 2:
                if not self.image_ready or self.active or self._retirement_started:
                    raise ImageRefusal("protocol")
                self.active = True
            elif role == "LISTENER_BOUND" and len(fields) == 3:
                name = Path(self.request["session_path"]).name
                if (
                    self.request.get("listener_event") is not True
                    or not self.active
                    or self.listener_bound
                    or self._retirement_started
                    or fields[2] != name.removeprefix("daemon-").removesuffix(".json")
                ):
                    raise ImageRefusal("protocol")
                self.progress()
                self.listener_bound = True
            elif role == "PENDING" and len(fields) == 3:
                decimal(fields[2], 2**31 - 1)
                self._retirement_started = True
            elif role == "REFUSED" and len(fields) == 3:
                if self.image_ready or self._refused is not None or self._retired is not None:
                    raise ImageRefusal("protocol")
                self._retirement_started = True
                self._refused = decimal(fields[2], 2**31 - 1)
                self._failure = ImageRefusal("admission")
            elif role == "OUTGOING_CLOSED" and len(fields) == 3:
                if self._outgoing_closed is not None or self._retired is not None:
                    raise ImageRefusal("protocol")
                self._outgoing_closed = decimal(fields[2], 2**31 - 1)
                self._retirement_started = True
            elif role == "BOOTSTRAP_CLOSED" and len(fields) == 3:
                if self.bootstrap is None or self._bootstrap_closed is not None:
                    raise ImageRefusal("protocol")
                self._bootstrap_closed = decimal(fields[2], 2**31 - 1)
                self._retirement_started = True
            elif role == "LOGS_CLOSED" and len(fields) == 3:
                if "log_directory" not in self.request or self._logs_closed is not None:
                    raise ImageRefusal("protocol")
                self._logs_closed = decimal(fields[2], 2**31 - 1)
                self._retirement_started = True
            elif role == "RETIRED" and len(fields) == 9:
                if self._retired is not None or self._refused is not None:
                    raise ImageRefusal("protocol")
                status = decimal(fields[2], 255)
                if fields[3:6] != ["1", "1", "0"] or self._outgoing_closed is None:
                    raise ImageRefusal("protocol")
                if self.bootstrap is not None and self._bootstrap_closed is None:
                    raise ImageRefusal("protocol")
                if "log_directory" in self.request and self._logs_closed is None:
                    raise ImageRefusal("protocol")
                closes = tuple(decimal(value, 2**31 - 1) for value in fields[6:])
                self._retired = (status, closes)
                self._retirement_started = True
            else:
                raise ImageRefusal("protocol")
        except (ValueError, IndexError, UnicodeError, ImageRefusal) as error:
            self._protocol_debt = True
            self._failure = ImageRefusal("protocol")
            raise self._failure from error

    def _pump(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ImageRefusal("deadline")
        for key, _ in self._selector.select(min(remaining, 0.05)):
            try:
                data = os.read(key.fileobj.fileno(), 4096)
            except BlockingIOError:
                continue
            name = key.data
            if not data:
                self._selector.unregister(key.fileobj)
                self._eof.add(name)
                continue
            if name == "stderr":
                # Keep only bounded private diagnostics; never project to receipt.
                self._buffers[name].extend(data[: max(0, 65536 - len(self._buffers[name]))])
                continue
            self._buffers[name].extend(data)
            if len(self._buffers[name]) > 4096:
                self._protocol_debt = True
                self._failure = ImageRefusal("protocol")
                raise self._failure
            while b"\n" in self._buffers[name]:
                line, _, rest = self._buffers[name].partition(b"\n")
                self._buffers[name] = bytearray(rest)
                self._parse(line)

    def _wait(self, condition, deadline):
        while not condition():
            if self._failure is not None:
                raise self._failure
            if "stdout" in self._eof:
                raise ImageRefusal("protocol")
            self._pump(deadline)

    def _close_stream(self, name):
        stream = getattr(self.process, name, None)
        if stream is None:
            return
        setattr(self.process, name, None)
        try:
            stream.close()
        except BaseException as error:
            if self._close_debt is None:
                self._close_debt = error

    def _close_selector(self):
        selector = self._selector
        self._selector = None
        if selector is not None:
            try:
                selector.close()
            except BaseException as error:
                if self._close_debt is None:
                    self._close_debt = error

    def _close_default_guardian(self):
        if self._default_guardian is not None:
            try:
                self._default_guardian.close()
            except BaseException as error:
                if self._close_debt is None:
                    self._close_debt = error

    @property
    def log_write_errno(self):
        """Bounded write result; actual physical closure remains a separate proof."""
        return self._logs_closed

    def public_receipt(self):
        """Project bounded lifecycle scalars without keys, names or native logs."""
        receipt = {
            "image_ready": self.image_ready,
            "active": self.active,
            "physically_retired": self.physically_retired,
            "native_retired": self._retired is not None,
            "refused": self._refused,
            "outgoing_close_errno": self._outgoing_closed,
            "owned_close_errnos": list(self._retired[1]) if self._retired else None,
            "guardian_status": getattr(self.process, "returncode", None),
            "protocol_debt": self._protocol_debt,
        }
        if "log_directory" in self.request:
            receipt["log_write_errno"] = self._logs_closed
        if self.bootstrap is not None:
            receipt["bootstrap_close_errno"] = self._bootstrap_closed
        return receipt

    def settle(self, timeout=15):
        """A timeout retains live owner debt; no hard-kill shortcut exists."""
        if self.physically_retired:
            return self._close_debt is None and self._failure is None
        if not self._spawn_attempted:
            self._guardian_retirement_proven = True
            self._close_default_guardian()
            self._close_selector()
            if self._close_debt is not None:
                return False
            self.physically_retired = True
            return True
        if self.process is None or not getattr(self.process, "_child_created", False):
            return False
        deadline = time.monotonic() + timeout
        if self.process.stdin is not None:
            try:
                self._send(b"CANCEL\n", deadline)
            except (BrokenPipeError, OSError):
                pass
            finally:
                self._close_stream("stdin")
        while self._eof != {"stdout", "stderr"}:
            try:
                self._pump(deadline)
            except ImageRefusal:
                return False
        if self._buffers["stdout"]:
            self._failure = ImageRefusal("protocol")
            return False
        try:
            status = self.process.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            return False
        retired = self._retired is not None and status in (0, 74)
        refused = self._refused is not None and self._retired is None and status == 0
        proven = (retired or refused) and not self._protocol_debt
        self._close_stream("stdout")
        self._close_stream("stderr")
        self._close_selector()
        if self._close_debt is not None or not proven:
            return False
        self._guardian_retirement_proven = True
        self._close_default_guardian()
        if self._close_debt is not None:
            return False
        self.physically_retired = True
        if retired and (
            status != 0
            or self._outgoing_closed != 0
            or any(self._retired[1])
            or (self.bootstrap is not None and self._bootstrap_closed != 0)
        ):
            self._failure = ImageRefusal("cleanup")
        return self._failure is None
