# _shared/python/managed_ollama_pull.py
"""Own one authenticated model pull through injected native listener/API ports.

Retiring the HTTP request does not retire the daemon operation. A caller keeps
its original task slot until a same-session authenticated operation receipt
reports the native helpers and background downloads physically retired.
"""

import importlib.util
import json
from pathlib import Path
import re
import secrets
import time

SPEC = importlib.util.spec_from_file_location(
    "ergopti_ollama_pull_policy", Path(__file__).with_name("managed_ollama_runtime.py")
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)

ADMISSION_PATH = "/api/ergopti-native-http-admission"


class PullOwner:
    """Explicit operation owner; only ``retirement`` can release submitted work."""

    def __init__(self, session, executable, ports, idle_timeout, maximum_bytes):
        self.session = POLICY.private_session(dict(session))
        if type(maximum_bytes) is not int or maximum_bytes <= 0:
            raise POLICY.RuntimeRefusal("protocol")
        self.executable, self.ports = executable, ports
        self.idle_timeout, self.maximum_bytes = idle_timeout, maximum_bytes
        self.listener = None
        self.operation = secrets.token_hex(16)
        self.admitted = self.submitted = self.request_finished = self.retired = False
        self.success = False

    @property
    def pending(self):
        """A true value is cleanup debt, even after the local HTTP child exits."""
        return self.submitted and not self.retired

    def _request(self, method, path, body, timeout, operation=None):
        deadline = time.monotonic() + timeout if timeout is not None else None
        headers, challenge = POLICY.authenticated_headers(
            self.session, method, path, body, operation
        )
        if deadline is not None:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                raise POLICY.RuntimeRefusal("deadline")
        response = self.ports.open_request(
            self.executable,
            self.session["device"],
            self.session["inode"],
            int(self.session["port"]),
            self.listener,
            method,
            path,
            headers,
            body.decode("utf-8"),
            timeout,
            self.idle_timeout,
        )
        return response, challenge

    def _receipt(self, timeout, operation=None):
        response, challenge = self._request("GET", ADMISSION_PATH, b"", timeout, operation)
        with response:
            if response.status != 200:
                raise POLICY.RuntimeRefusal("session")
            result = bytearray()
            while chunk := response.read():
                result.extend(chunk)
                if len(result) > self.maximum_bytes:
                    raise POLICY.RuntimeRefusal("protocol")
            if response.listener != self.listener:
                raise POLICY.RuntimeRefusal("session")
            return POLICY.authenticated_receipt(
                self.session,
                response.headers,
                bytes(result),
                challenge,
                response.listener,
                operation,
            )

    def admit(self, timeout):
        """Fence the actual listener first, then authenticate its source-bound lease."""
        if self.admitted or self.listener is not None or self.submitted:
            raise POLICY.RuntimeRefusal("state")
        deadline = time.monotonic() + timeout
        self.listener = self.ports.discover(
            self.executable,
            self.session["device"],
            self.session["inode"],
            int(self.session["port"]),
            timeout,
            self.idle_timeout,
        )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise POLICY.RuntimeRefusal("deadline")
        self._receipt(remaining)
        self.admitted = True

    def pull(self, model, emit, timeout=None):
        """Stream actual progress under the caller's existing idle/absolute clocks.

        A missing absolute timeout preserves a progressing multi-gigabyte pull.
        Cancellation or malformed progress closes and reaps its native request;
        the daemon's independent operation remains pending until retirement.
        """
        if not self.admitted or self.submitted or not callable(emit):
            raise POLICY.RuntimeRefusal("state")
        if (
            not isinstance(model, str)
            or not model
            or len(model.encode("utf-8")) > self.maximum_bytes
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9./_:-]*", model) is None
        ):
            raise POLICY.RuntimeRefusal("model")
        body = json.dumps({"model": model, "stream": True}, separators=(",", ":")).encode("utf-8")
        # Once sending may begin, an interrupted constructor cannot tell whether
        # the daemon accepted the body. Keep the operation lease in either case.
        self.submitted = True
        try:
            response, _ = self._request("POST", "/api/pull", body, timeout, self.operation)
            with response:
                if response.status != 200:
                    raise POLICY.RuntimeRefusal("pull")
                pending = bytearray()
                success, failure = False, False
                while chunk := response.read():
                    pending.extend(chunk)
                    while b"\n" in pending:
                        row, _, rest = pending.partition(b"\n")
                        pending = bytearray(rest)
                        if not row or len(row) > self.maximum_bytes:
                            raise POLICY.RuntimeRefusal("protocol")
                        progress = self._progress(bytes(row))
                        success = progress.get("status") == "success"
                        failure = failure or "error" in progress
                        emit(progress)
                    if len(pending) > self.maximum_bytes:
                        raise POLICY.RuntimeRefusal("protocol")
                if pending or response.listener != self.listener:
                    raise POLICY.RuntimeRefusal("protocol")
                self.success = success and not failure
        finally:
            # The native port contract physically joins on every constructor or
            # context failure. This flag is local request closure, never proof
            # that upstream PullModel/background downloads have returned.
            self.request_finished = True
        return self.success

    def _progress(self, data):
        value = POLICY.metadata_bytes(data)
        if (
            not value
            or not set(value) <= {"status", "digest", "total", "completed", "error"}
            or ("status" in value) == ("error" in value)
        ):
            raise POLICY.RuntimeRefusal("protocol")
        for name in ("status", "error", "digest"):
            if name in value and not isinstance(value[name], str):
                raise POLICY.RuntimeRefusal("protocol")
        for name in ("total", "completed"):
            if name in value and (type(value[name]) is not int or not 0 <= value[name] < 1 << 63):
                raise POLICY.RuntimeRefusal("protocol")
        return value

    def retirement(self, timeout):
        """Poll under a caller-owned bounded clock; unknown or changed peers refuse."""
        if not self.submitted or not self.request_finished or self.retired:
            raise POLICY.RuntimeRefusal("state")
        receipt = self._receipt(timeout, self.operation)
        if receipt["operation_state"] == "unknown":
            raise POLICY.RuntimeRefusal("session")
        self.retired = receipt["operation_state"] == "retired"
        return self.retired
