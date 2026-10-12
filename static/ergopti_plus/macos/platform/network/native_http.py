# platform/network/native_http.py
"""Own one signed native HTTP request and its bounded binary response stream.

This engine has no Python HTTP or TLS dependency. Foundation owns the network;
the caller owns redirects, output descriptors, integrity and publication.
"""

import json
import math
import os
from pathlib import Path
import selectors
import stat
import struct
import subprocess
import time


# Retain the actual constructor class for opt-in registered role acquisition.
# The legacy unregistered transport still uses its original call unchanged.
_ROLE_POPEN = subprocess.Popen


MAX_FRAME_BYTES = 65536
MAX_REQUEST_BYTES = 65536
WORKER_FLAG = "--managed-http-worker"
REASONS = frozenset(
    (
        "complete",
        "deadline",
        "cancelled",
        "offline",
        "certificate",
        "proxy",
        "connect",
        "unavailable",
        "protocol",
        "content_encoding",
    )
)


class NativeHTTPError(Exception):
    """Fixed lexical failure with no URL, certificate or credential payload."""

    def __init__(self, reason):
        self.reason = reason if reason in REASONS else "protocol"
        super().__init__("Native HTTP request failed: " + self.reason)


def _positive_timeout(value):
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(value)
        and value > 0
    )


def _resolve_worker():
    root = Path(__file__).absolute().parents[2]
    suffix = "/Contents/Resources/static/ergopti_plus/macos"
    if not str(root).endswith(suffix):
        raise NativeHTTPError("unavailable")
    expected = str(root)[: -len(suffix)] + "/Contents/MacOS/ErgoptiPlus"
    if os.environ.get("ERGOPTI_LAUNCHER_EXECUTABLE") != expected:
        raise NativeHTTPError("unavailable")
    try:
        observed = os.stat(expected, follow_symlinks=False)
    except OSError:
        raise NativeHTTPError("unavailable") from None
    if not stat.S_ISREG(observed.st_mode) or not os.access(expected, os.X_OK):
        raise NativeHTTPError("unavailable")
    for name, value in (
        ("ERGOPTI_LAUNCHER_DEVICE", observed.st_dev),
        ("ERGOPTI_LAUNCHER_INODE", observed.st_ino),
    ):
        if os.environ.get(name) != str(value):
            raise NativeHTTPError("unavailable")
    return expected


class NativeHTTPResponse:
    """A streaming response whose success includes terminal evidence and reap.

    ``read`` returns decoded HTTP payload bytes. Empty bytes mean a verified
    terminal frame, exact pipe EOF and exit status zero, never a truncated pipe.
    ``close`` physically retires an incompletely consumed native request.
    """

    def __init__(self, url, headers, method="GET", timeout=None, idle_timeout=None, direct=False):
        if timeout is not None and not _positive_timeout(timeout):
            raise NativeHTTPError("protocol")
        if not _positive_timeout(idle_timeout) or type(direct) is not bool:
            raise NativeHTTPError("protocol")
        if method not in ("GET", "HEAD") or not isinstance(url, str):
            raise NativeHTTPError("protocol")
        if not isinstance(headers, (list, tuple)) or any(
            not isinstance(pair, (list, tuple))
            or len(pair) != 2
            or any(not isinstance(value, str) for value in pair)
            for pair in headers
        ):
            raise NativeHTTPError("protocol")
        request = json.dumps(
            {
                "version": 1,
                "url": url,
                "method": method,
                "headers": headers,
                "timeout": timeout,
                "idle_timeout": idle_timeout,
                "direct": direct,
            },
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("ascii")
        try:
            tag, payload = self._open_wire(
                request,
                [WORKER_FLAG, str(idle_timeout), str(timeout) if timeout is not None else "none"],
                timeout,
                idle_timeout,
            )
            self._diagnostic_stage = "native_head"
            self._receive_http_head(tag, payload)
        except NativeHTTPError as failure:
            self._close_for_failure(failure)
            raise
        except (OSError, ValueError, TypeError) as source:
            failure = NativeHTTPError("unavailable")
            self._close_for_failure(failure, source)
            raise failure from None
        except BaseException as failure:
            # Role-specific initial validation still belongs to the constructor.
            self._close_for_failure(failure)
            raise

    _terminal_reasons = REASONS

    def _open_wire(
        self,
        request_bytes,
        arguments,
        timeout,
        idle_timeout,
        *,
        register=None,
        absolute_deadline=None,
        progress=None,
        pre_acquire=None,
    ):
        """Open a private bounded role request and return its first frame.

        The signed worker identity and physical lifecycle are shared by native
        roles. Arguments contain only the fixed role and public timing scalars;
        role-specific URLs, listener identities and bodies remain on stdin.
        The caller must close on any subsequent initial-frame validation error.
        """
        if hasattr(self, "_process"):
            raise NativeHTTPError("protocol")
        self._started = time.monotonic()
        self._absolute = self._started + timeout if _positive_timeout(timeout) else None
        self._idle_timeout = idle_timeout
        self._idle_deadline = (
            self._started + idle_timeout if _positive_timeout(idle_timeout) else self._started
        )
        self._pending = b""
        self._complete = False
        self._closed = False
        self._terminal_value = None
        self._process = None
        self._selector = None
        self._role_progress = None
        self._role_process_constructor = False
        self._role_process_complete = False
        try:
            if absolute_deadline is not None:
                if not _positive_timeout(absolute_deadline):
                    raise NativeHTTPError("protocol")
                self._absolute = absolute_deadline
            if progress is not None and not callable(progress):
                raise NativeHTTPError("protocol")
            self._role_progress = progress
            if pre_acquire is not None and not callable(pre_acquire):
                raise NativeHTTPError("protocol")
            if register is not None:
                if not callable(register) or register(self) is not True:
                    raise NativeHTTPError("protocol")
                # A registration callback may revoke/close synchronously. It
                # cannot leave a closed owner while we acquire new resources.
                if (
                    self._closed is not False
                    or self._selector is not None
                    or self._process is not None
                ):
                    raise NativeHTTPError("protocol")
            # The retained role is registered before selector or child acquisition.
            if (
                register is not None
                or absolute_deadline is not None
                or progress is not None
                or pre_acquire is not None
            ):
                self._remaining()
                # progress() is an external callback and can close this empty
                # response normally. Refuse before acquiring any successor.
                if (
                    self._closed is not False
                    or self._selector is not None
                    or self._process is not None
                ):
                    raise NativeHTTPError("protocol")
            self._selector = selectors.DefaultSelector()
            if timeout is not None and not _positive_timeout(timeout):
                raise NativeHTTPError("protocol")
            if not _positive_timeout(idle_timeout):
                raise NativeHTTPError("protocol")
            if type(request_bytes) is not bytes or not 0 < len(request_bytes) <= MAX_REQUEST_BYTES:
                raise NativeHTTPError("protocol")
            if (
                not isinstance(arguments, (list, tuple))
                or not arguments
                or any(
                    not isinstance(value, str) or not value or len(value) > 64
                    for value in arguments
                )
            ):
                raise NativeHTTPError("protocol")
            flag = arguments[0]
            if not flag.startswith("--") or any(
                character not in "-abcdefghijklmnopqrstuvwxyz0123456789" for character in flag
            ):
                raise NativeHTTPError("protocol")
            for value in arguments[1:]:
                if value != "none" and not _positive_timeout(float(value)):
                    raise NativeHTTPError("protocol")
            self._diagnostic_stage = "native_identity"
            executable = _resolve_worker()
            if (
                register is not None
                or absolute_deadline is not None
                or progress is not None
                or pre_acquire is not None
            ):
                acquired_selector = self._selector
                if (
                    self._closed is not False
                    or acquired_selector is None
                    or self._process is not None
                ):
                    raise NativeHTTPError("protocol")
                # The source owner supplies its original full admission once at
                # acquisition. Recurring progress retains the lighter liveness
                # check; neither port renews the original absolute deadline.
                if pre_acquire is not None:
                    pre_acquire()
                self._remaining()
                # The exact already-acquired selector must survive the callback;
                # a closed or replaced owner cannot acquire a native child.
                if (
                    self._closed is not False
                    or self._selector is not acquired_selector
                    or self._process is not None
                ):
                    raise NativeHTTPError("protocol")
            self._diagnostic_stage = "native_spawn"
            if register is not None:
                # A real Popen constructor can raise after child creation. Keep
                # its exact object reachable before entering that constructor.
                self._process = _ROLE_POPEN.__new__(_ROLE_POPEN)
                self._role_process_constructor = True
                self._process.__init__(
                    [executable, *arguments],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    bufsize=0,
                    close_fds=True,
                )
                self._role_process_complete = True
            else:
                self._process = subprocess.Popen(
                    [executable, *arguments],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    bufsize=0,
                    close_fds=True,
                )
            self._diagnostic_stage = "native_pipe_setup"
            os.set_blocking(self._process.stdin.fileno(), False)
            os.set_blocking(self._process.stdout.fileno(), False)
            self._selector.register(self._process.stdin, selectors.EVENT_WRITE)
            self._diagnostic_stage = "native_write"
            offset = 0
            while offset < len(request_bytes):
                self._ready()
                try:
                    count = os.write(self._process.stdin.fileno(), request_bytes[offset:])
                except BlockingIOError:
                    continue
                if count <= 0:
                    raise NativeHTTPError("protocol")
                offset += count
            self._selector.unregister(self._process.stdin)
            self._process.stdin.close()
            self._selector.register(self._process.stdout, selectors.EVENT_READ)
            self._diagnostic_stage = "native_first_frame"
            return self._frame()
        except NativeHTTPError as failure:
            self._close_initial_role_failure(register is not None, failure)
            raise
        except (OSError, ValueError, TypeError) as source:
            failure = NativeHTTPError("unavailable")
            self._close_initial_role_failure(register is not None, failure, source)
            raise failure from None
        except BaseException as failure:
            # A signal/KeyboardInterrupt can arrive before a response context
            # exists. Retire the exact constructor child before propagating it.
            self._close_initial_role_failure(register is not None, failure)
            raise

    def _close_initial_role_failure(self, registered, failure=None, source=None):
        if not registered:
            if failure is None:
                self.close()
            else:
                self._close_for_failure(failure, source)
            return
        try:
            self.close()
        except BaseException as refused:
            # The captured registered close records its exact failure; _closed
            # remains false. Preserve the primary without granting retirement.
            if failure is not None:
                self._observe_failure(refused, "native_cleanup")
        if failure is not None:
            self._observe_failure(
                failure, getattr(self, "_diagnostic_stage", "native_request"), source
            )

    def _receive_http_head(self, tag, payload):
        """Validate the existing generic H schema for HTTP-bearing native roles."""
        if tag == b"C":
            self._terminal(payload)
            raise NativeHTTPError("protocol")
        if tag != b"H":
            raise NativeHTTPError("protocol")
        metadata = self._json(payload)
        if (
            set(metadata) != {"version", "status", "headers"}
            or metadata["version"] != 1
            or type(metadata["version"]) is not int
        ):
            raise NativeHTTPError("protocol")
        if type(metadata["status"]) is not int or not 100 <= metadata["status"] <= 599:
            raise NativeHTTPError("protocol")
        if not isinstance(metadata["headers"], list) or any(
            not isinstance(pair, list)
            or len(pair) != 2
            or any(not isinstance(value, str) for value in pair)
            for pair in metadata["headers"]
        ):
            raise NativeHTTPError("protocol")
        self.status = metadata["status"]
        self.headers = metadata["headers"]

    def _remaining(self):
        progress = getattr(self, "_role_progress", None)
        if progress is not None:
            progress()
        now = time.monotonic()
        deadline = self._idle_deadline
        if self._absolute is not None:
            deadline = min(deadline, self._absolute)
        remaining = deadline - now
        if remaining <= 0:
            raise NativeHTTPError("deadline")
        return remaining

    def _ready(self):
        while not self._selector.select(self._remaining()):
            self._remaining()

    def _read_exact(self, count, allow_eof=False):
        parts = []
        received = 0
        while received < count:
            self._ready()
            try:
                part = os.read(self._process.stdout.fileno(), count - received)
            except BlockingIOError:
                continue
            if not part:
                if allow_eof and received == 0:
                    return b""
                raise NativeHTTPError("protocol")
            self._idle_deadline = time.monotonic() + self._idle_timeout
            parts.append(part)
            received += len(part)
        return b"".join(parts)

    def _frame(self):
        length = struct.unpack(">I", self._read_exact(4))[0]
        if not 1 <= length <= MAX_FRAME_BYTES:
            raise NativeHTTPError("protocol")
        payload = self._read_exact(length)
        return payload[:1], payload[1:]

    @staticmethod
    def _json(payload):
        def object_pairs(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate protocol key")
                result[key] = value
            return result

        try:
            value = json.loads(payload, object_pairs_hook=object_pairs)
        except (UnicodeError, ValueError):
            raise NativeHTTPError("protocol") from None
        if not isinstance(value, dict):
            raise NativeHTTPError("protocol")
        return value

    @classmethod
    def _validate_completion(cls, value):
        """Validate the closed role's common terminal semantics."""
        if type(value.get("version")) is not int or value["version"] != 1:
            raise NativeHTTPError("protocol")
        if (
            type(value.get("success")) is not bool
            or not isinstance(value.get("reason"), str)
            or value["reason"] not in cls._terminal_reasons
        ):
            raise NativeHTTPError("protocol")
        if value["success"] != (value["reason"] == "complete"):
            raise NativeHTTPError("protocol")

    def _validate_terminal(self, value):
        """The generic HTTP role permits exactly its original three C fields."""
        if set(value) != {"version", "success", "reason"}:
            raise NativeHTTPError("protocol")
        self._validate_completion(value)

    @staticmethod
    def _terminal_error(reason):
        return NativeHTTPError(reason)

    def _terminal(self, payload):
        self._diagnostic_stage = "native_terminal"
        value = self._json(payload)
        self._validate_terminal(value)
        # Extension validators cannot bypass the shared completion semantics.
        self._validate_completion(value)
        if self._read_exact(1, allow_eof=True):
            raise NativeHTTPError("protocol")
        try:
            code = self._process.wait(timeout=self._remaining())
        except subprocess.TimeoutExpired:
            raise NativeHTTPError("deadline") from None
        # This is observed only after validated terminal, EOF and exact wait.
        self._terminal_value = value
        if not value["success"]:
            raise self._terminal_error(value["reason"])
        if code != 0:
            raise NativeHTTPError("protocol")
        self._complete = True

    def read(self, maximum=MAX_FRAME_BYTES - 1):
        if type(maximum) is not int or not 1 <= maximum < MAX_FRAME_BYTES or self._closed:
            raise NativeHTTPError("protocol")
        try:
            if self._complete and not self._pending:
                return b""
            self._diagnostic_stage = "native_body"
            self._remaining()
            if not self._pending and not self._complete:
                tag, payload = self._frame()
                if tag == b"C":
                    self._terminal(payload)
                elif tag == b"D" and payload:
                    self._pending = payload
                else:
                    raise NativeHTTPError("protocol")
            result, self._pending = self._pending[:maximum], self._pending[maximum:]
            return result
        except NativeHTTPError as failure:
            self._close_for_failure(failure)
            raise
        except (OSError, ValueError, TypeError) as source:
            failure = NativeHTTPError("protocol")
            self._close_for_failure(failure, source)
            raise failure from None

    def _close_for_failure(self, failure, source=None):
        """Retire through the original owner before projecting fixed observations."""
        try:
            self.close()
        except BaseException as refused:
            self._observe_failure(refused, "native_cleanup")
            raise
        self._observe_failure(failure, getattr(self, "_diagnostic_stage", "native_request"), source)

    def _observe_failure(self, failure, stage, source=None):
        if hasattr(failure, "native_diagnostic"):
            return
        if source is not None and hasattr(source, "native_diagnostic"):
            failure.native_diagnostic = source.native_diagnostic.copy()
            return
        observed = failure if source is None else source
        kind = "other"
        for cls in (
            NativeHTTPError,
            subprocess.TimeoutExpired,
            OSError,
            ValueError,
            TypeError,
            AttributeError,
        ):
            if isinstance(observed, cls):
                kind = cls.__name__
                break
        process = getattr(self, "_process", None)
        retired = getattr(self, "_closed", False) is True
        if process is not None:
            retired = (
                retired
                and type(getattr(process, "returncode", None)) is int
                and all(
                    stream is None or stream.closed for stream in (process.stdin, process.stdout)
                )
            )
        pid = getattr(process, "pid", None) if retired else None
        status = getattr(process, "returncode", None) if retired else None
        terminal = getattr(self, "_terminal_value", None) if retired else None
        reason = terminal.get("reason") if type(terminal) is dict else None
        failure.native_diagnostic = {
            "stage": stage,
            "exception_class": kind,
            "native_child_pid": pid if type(pid) is int and pid > 0 else None,
            "native_child_status": status if type(status) is int else None,
            "native_receipt_reason": reason if type(reason) is str and reason in REASONS else None,
            "cleanup": "confirmed" if retired else "unconfirmed",
        }

    def close(self):
        if self._closed:
            return
        if self._selector is not None:
            self._selector.close()
        if self._process is not None:
            if (
                getattr(self, "_role_process_constructor", False)
                and not self._role_process_complete
                and getattr(self._process, "_child_created", False) is not True
            ):
                # No complete constructor or exact child receipt proves that
                # partial descriptors retired. Keep this registered debt.
                raise NativeHTTPError("unavailable")
            if self._process.poll() is None:
                self._process.kill()
            for stream in (self._process.stdin, self._process.stdout):
                if stream is not None and not stream.closed:
                    stream.close()
            # No successor/publication may race the physical native process.
            self._process.wait()
        self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def open_request(url, headers=(), method="GET", timeout=None, idle_timeout=None, direct=False):
    """Open one owned native response; the caller must consume or close it."""
    return NativeHTTPResponse(url, headers, method, timeout, idle_timeout, direct)
