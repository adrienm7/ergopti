# platform/network/native_ollama_api.py
"""Bound local Ollama API ports over the signed SDK socket-provenance worker.

Discovery sends no HTTP bytes. Requests require its exact PID/start identity on
the actual connected socket before transmitting their bounded private payload.
"""

import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys

ENGINE_PATH = Path(__file__).with_name("native_http.py")
specification = importlib.util.spec_from_file_location("ergopti_ollama_native_wire", ENGINE_PATH)
ENGINE = importlib.util.module_from_spec(specification)
sys.modules[specification.name] = ENGINE
specification.loader.exec_module(ENGINE)

LISTENER_FIELDS = {
    "pid",
    "uid",
    "start_seconds",
    "start_microseconds",
    "device",
    "inode",
}
REASONS = frozenset(
    (
        "complete",
        "admission",
        "protocol",
        "deadline",
        "cancelled",
        "connect",
        "unavailable",
    )
)


class NativeOllamaError(ENGINE.NativeHTTPError):
    """Closed native API failure without private listener or request bytes."""

    def __init__(self, reason):
        self.reason = reason if reason in REASONS else "protocol"
        Exception.__init__(self, "Native Ollama request failed: " + self.reason)


def listener(value):
    if not isinstance(value, dict) or set(value) != LISTENER_FIELDS:
        raise ENGINE.NativeHTTPError("protocol")
    if type(value["pid"]) is not int or not 1 <= value["pid"] < 1 << 31:
        raise ENGINE.NativeHTTPError("protocol")
    if type(value["uid"]) is not int or value["uid"] != os.geteuid():
        raise ENGINE.NativeHTTPError("protocol")
    for name in ("start_seconds", "start_microseconds", "device", "inode"):
        text = value[name]
        if (
            not isinstance(text, str)
            or not text.isascii()
            or not text.isdigit()
            or str(int(text)) != text
            or int(text) >= 1 << 64
        ):
            raise ENGINE.NativeHTTPError("protocol")
    if int(value["start_microseconds"]) >= 1000000 or int(value["device"]) >= 1 << 32:
        raise ENGINE.NativeHTTPError("protocol")
    return value


def source_alias_proof(value):
    """Receive only the canonical optional alias schema; no filesystem admission here."""
    policy_path = Path(__file__).resolve().parents[3] / "_shared/python/managed_source_alias.py"
    try:
        spec = importlib.util.spec_from_file_location("ergopti_ollama_alias_schema", policy_path)
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
    except (OSError, ValueError, TypeError):
        raise ENGINE.NativeHTTPError("unavailable") from None
    try:
        return policy.proof_fields(value)
    except policy.AliasRefusal:
        raise ENGINE.NativeHTTPError("protocol") from None


class NativeOllamaResponse(ENGINE.NativeHTTPResponse):
    _terminal_reasons = REASONS

    def __init__(
        self,
        executable,
        device,
        inode,
        port,
        timeout,
        idle_timeout,
        expected=None,
        method=None,
        path=None,
        headers=(),
        body="",
        *,
        source_alias=None,
    ):
        if (
            type(port) is not int
            or not 1024 <= port <= 65535
            or (
                timeout is not None
                and (
                    isinstance(timeout, bool)
                    or not isinstance(timeout, (int, float))
                    or not math.isfinite(timeout)
                    or timeout <= 0
                )
            )
            or isinstance(idle_timeout, bool)
            or not isinstance(idle_timeout, (int, float))
            or not math.isfinite(idle_timeout)
            or idle_timeout <= 0
        ):
            raise ENGINE.NativeHTTPError("protocol")
        self._listener_expected = expected
        self._device_expected, self._inode_expected = device, inode
        milliseconds = math.ceil(timeout * 1000) if timeout is not None else None
        idle_milliseconds = math.ceil(idle_timeout * 1000)
        if (milliseconds is not None and milliseconds > (1 << 31) - 1) or idle_milliseconds > (
            1 << 31
        ) - 1:
            raise ENGINE.NativeHTTPError("protocol")
        request = {
            "version": 1,
            "executable": executable,
            "device": device,
            "inode": inode,
            "port": port,
            "timeout_ms": milliseconds,
        }
        if expected is None:
            if milliseconds is None or method is not None or path is not None or headers or body:
                raise ENGINE.NativeHTTPError("protocol")
            flag = "--managed-ollama-listener-probe"
            arguments = [flag, str(milliseconds)]
        else:
            listener(expected)
            if (method, path) not in (
                ("GET", "/api/ergopti-native-http-admission"),
                ("POST", "/api/pull"),
            ):
                raise ENGINE.NativeHTTPError("protocol")
            if not isinstance(body, str):
                raise ENGINE.NativeHTTPError("protocol")
            if not isinstance(headers, (list, tuple)):
                raise ENGINE.NativeHTTPError("protocol")
            private_headers = []
            names = set()
            required = {
                "x-ergopti-native-session",
                "x-ergopti-native-challenge",
                "x-ergopti-native-body-sha256",
            }
            for pair in headers:
                if (
                    not isinstance(pair, (list, tuple))
                    or len(pair) != 2
                    or any(not isinstance(value, str) for value in pair)
                ):
                    raise ENGINE.NativeHTTPError("protocol")
                name, value = pair
                if name.lower() in names:
                    raise ENGINE.NativeHTTPError("protocol")
                names.add(name.lower())
                if (name.lower(), value) in (
                    ("accept-encoding", "identity"),
                    ("content-type", "application/json"),
                ):
                    continue
                length = 32 if name.lower() == "x-ergopti-native-operation" else 64
                if (
                    name.lower() not in required | {"x-ergopti-native-operation"}
                    or re.fullmatch(r"[a-f0-9]{" + str(length) + "}", value) is None
                ):
                    raise ENGINE.NativeHTTPError("protocol")
                private_headers.append([name, value])
            private_names = {name.lower() for name, _ in private_headers}
            if not required <= private_names or (
                method == "POST" and "x-ergopti-native-operation" not in private_names
            ):
                raise ENGINE.NativeHTTPError("protocol")
            request.update(
                pid=expected["pid"],
                start_seconds=expected["start_seconds"],
                start_microseconds=expected["start_microseconds"],
                method=method,
                path=path,
                headers=private_headers,
                body=body,
                idle_ms=idle_milliseconds,
            )
            flag = "--managed-ollama-api-worker"
            arguments = [
                flag,
                str(request["idle_ms"]),
                str(milliseconds) if milliseconds is not None else "none",
            ]
        if source_alias is not None:
            request["source_alias"] = source_alias_proof(source_alias)
        # These roles read one LF-terminated JSON line. The generic HTTP role's
        # EOF framing remains unchanged in the shared process owner.
        encoded = (
            json.dumps(request, separators=(",", ":"), ensure_ascii=True).encode("ascii") + b"\n"
        )
        if not hasattr(self, "_open_wire"):
            raise ENGINE.NativeHTTPError("unavailable")
        tag, payload = self._open_wire(encoded, arguments, timeout, idle_timeout)
        try:
            if expected is None:
                if tag != b"C":
                    raise ENGINE.NativeHTTPError("protocol")
                self._terminal(payload)
                self.status, self.headers = None, []
            else:
                self._receive_http_head(tag, payload)
        except BaseException:
            self.close()
            raise

    def _validate_terminal(self, value):
        if set(value) != {"version", "success", "reason", "listener"}:
            raise ENGINE.NativeHTTPError("protocol")
        self._validate_completion(value)
        if value["listener"] is not None:
            observed = listener(value["listener"])
            if (
                observed["device"] != self._device_expected
                or observed["inode"] != self._inode_expected
            ):
                raise ENGINE.NativeHTTPError("protocol")
            if self._listener_expected is not None and observed != self._listener_expected:
                raise NativeOllamaError("admission")
        elif value["success"]:
            raise ENGINE.NativeHTTPError("protocol")

    @staticmethod
    def _terminal_error(reason):
        return NativeOllamaError(reason)

    @property
    def listener(self):
        # Identity becomes caller authority only after C + exact EOF + reap0.
        if not self._complete:
            raise ENGINE.NativeHTTPError("protocol")
        return dict(self._terminal_value["listener"])


def discover(executable, device, inode, port, timeout, idle_timeout, *, source_alias=None):
    with NativeOllamaResponse(
        executable,
        device,
        inode,
        port,
        timeout,
        idle_timeout,
        source_alias=source_alias,
    ) as response:
        return response.listener


def open_request(
    executable,
    device,
    inode,
    port,
    expected,
    method,
    path,
    headers,
    body,
    timeout,
    idle_timeout,
    *,
    source_alias=None,
):
    return NativeOllamaResponse(
        executable,
        device,
        inode,
        port,
        timeout,
        idle_timeout,
        expected,
        method,
        path,
        headers,
        body,
        source_alias=source_alias,
    )
