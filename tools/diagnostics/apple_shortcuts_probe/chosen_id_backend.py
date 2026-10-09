# tools/diagnostics/apple_shortcuts_probe/chosen_id_backend.py
"""Darwin chosen-ID backend with bounded capture and retained native ownership.

This is a concrete native qualification backend, not a Hammerspoon transport.
The remote Shortcuts Events service has no proven retirement receipt in the
public API: CLI/group cancellation is reported separately and never promoted.
"""

import importlib.util
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import time

LIMIT = 65536


class Refused(RuntimeError):
    """Closed private error; never carry native stderr, names or identifiers."""


def require(value, reason="native_refused"):
    if value is not True:
        raise Refused(reason)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "invalid_reply")
        result[key] = value
    return result


class NativeShortcuts:
    """Own real native query/invocation groups; no TCC or database mutations."""

    def __init__(self, root, ownership=None, native=None):
        self.root = Path(root).resolve()
        self.query_source = (
            self.root / "static/ergopti_plus/macos/adapters/apple_shortcuts_query.js"
        )
        if ownership is None:
            require(sys.platform == "darwin" and sys.version_info >= (3, 13), "native_unavailable")
            path = self.root / "tools/diagnostics/macos_owned_process.py"
            spec = importlib.util.spec_from_file_location("chosen_id_native_owner", path)
            ownership = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(ownership)
        self.ownership = ownership
        self.native = native if native is not None else ownership.NativeProcessGroups()
        self.pending = []
        self.receipts = []
        self.generation = 0
        self.nonce = 0
        self.choices = {}

    def identity(self, path="/usr/bin/shortcuts"):
        """Capture exact regular executable metadata; refuse route symlinks."""
        info = os.lstat(path)
        require(stat.S_ISREG(info.st_mode) and bool(info.st_mode & 0o111), "identity_refused")
        require(os.path.realpath(path) == path, "identity_refused")
        return (
            info.st_dev,
            info.st_ino,
            info.st_uid,
            info.st_gid,
            info.st_mode,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
        )

    def cancel(self):
        """Retry exact acquired groups; local closure is not service retirement."""
        self.generation += 1
        self.choices = {}
        for group in tuple(self.pending):
            if group.settle() is True:
                self.receipts.append(group.receipt())
                self.pending.remove(group)
        return {
            "local_retired": not self.pending,
            "automation_retired": False,
            "reason": "service_retirement_unqualified",
        }

    def capture(self, arguments, timeout=20, limit=LIMIT):
        """Drain fixed-size pipe reads, reserving the leader until group retirement."""
        require(not self.pending, "cleanup_pending")
        group = None
        streams, raw = {}, {"out": bytearray(), "err": bytearray()}
        selector = selectors.DefaultSelector()
        try:
            group = self.ownership.acquire_owned(
                arguments,
                self.native,
                self.pending.append,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for stream, role in ((group.process.stdout, "out"), (group.process.stderr, "err")):
                streams[role] = stream
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, role)
            deadline = time.monotonic() + timeout
            while True:
                require(time.monotonic() < deadline, "query_timeout")
                for key, _ in selector.select(0.02):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    data = raw[key.data]
                    require(len(data) + len(chunk) <= limit, "reply_limit")
                    data.extend(chunk)
                exited = group.observe_exit() is not None
                # A descendant holding a pipe open cannot extend the operation
                # forever; the same deadline and native group fence still apply.
                if exited and not selector.get_map():
                    break
            require(group.settle() is True, "cleanup_pending")
            self.receipts.append(group.receipt())
            self.pending.remove(group)
            require(group.process.returncode == 0 and not raw["err"], "execution_refused")
            return bytes(raw["out"])
        finally:
            selector.close()
            # Keep refused groups available for a retry on this same instance.
            try:
                for retained in tuple(self.pending):
                    if retained.settle() is True:
                        self.receipts.append(retained.receipt())
                        self.pending.remove(retained)
            finally:
                for stream in streams.values():
                    stream.close()

    def query(self, operation, identifier=None):
        """Actually issue a source-owned structured bounded native query."""
        self.nonce += 1
        nonce = self.nonce
        self.identity("/usr/bin/osascript")
        before = self.query_source.read_bytes()
        arguments = [
            "/usr/bin/osascript",
            "-l",
            "JavaScript",
            str(self.query_source),
            operation,
            str(nonce),
        ]
        if identifier is not None:
            arguments.append(identifier)
        raw = self.capture(arguments)
        require(self.query_source.read_bytes() == before, "source_changed")
        require(0 < len(raw) <= LIMIT, "invalid_reply")
        try:
            value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
        except (ValueError, UnicodeError):
            raise Refused("invalid_reply") from None
        require(
            type(value) is dict
            and type(value.get("version")) is int
            and value["version"] == 1
            and type(value.get("nonce")) is int
            and value["nonce"] == nonce
            and value.get("operation") == operation,
            "invalid_reply",
        )
        if value.get("status") == "refused":
            require(
                set(value) == {"version", "nonce", "operation", "status", "reason"}
                and value["reason"]
                in {
                    "native_refused",
                    "automation_permission_refused",
                    "catalogue_limit",
                    "missing",
                },
                "invalid_reply",
            )
            raise Refused(value["reason"])
        require(
            set(value) == {"version", "nonce", "operation", "status", "rows", "truncated"}
            and value["status"] == "observed"
            and type(value["rows"]) is list
            and len(value["rows"]) <= 64
            and type(value["truncated"]) is bool,
            "invalid_reply",
        )
        import re

        ids = set()
        for row in value["rows"]:
            require(
                type(row) is dict and set(row) == {"id", "name", "accepts_input"}, "invalid_reply"
            )
            require(
                type(row["id"]) is str
                and re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", row["id"])
                is not None
                and row["id"] not in ids
                and type(row["name"]) is str
                and "\0" not in row["name"]
                and len(row["name"].encode("utf-8")) <= 4096
                and type(row["accepts_input"]) is bool,
                "invalid_reply",
            )
            ids.add(row["id"])
        if operation == "revalidate":
            require(
                len(value["rows"]) == 1
                and not value["truncated"]
                and value["rows"][0]["id"] == identifier,
                "stale_discovery",
            )
        return value

    def discover(self):
        """Return opaque choices only after settled native inventory and CLI checks."""
        require(not self.pending, "cleanup_pending")
        self.generation += 1
        self.choices = {}
        cli = self.identity()
        help_bytes = self.capture(["/usr/bin/shortcuts", "run", "--help"])
        require(b"shortcut-name-or-identifier" in help_bytes, "cli_contract_refused")
        data = self.query("discover")
        require(self.identity() == cli, "identity_refused")
        choices = []
        for index, row in enumerate(data["rows"], 1):
            key = f"{self.generation}:{index}"
            self.choices[key] = (dict(row), cli)
            choices.append({"key": key, "label": row["name"], "provider": "apple_shortcuts"})
        return {"choices": choices, "truncated": data["truncated"]}

    def resolve(self, key, arguments=()):
        """Check actual stable ID, name/input metadata and CLI identity again."""
        require(not arguments, "unsupported_input")
        require(key in self.choices, "stale_discovery")
        row, cli = self.choices[key]
        epoch = self.generation
        require(self.identity() == cli, "identity_refused")
        observed = self.query("revalidate", row["id"])
        require(
            observed["rows"] == [row] and self.generation == epoch and key in self.choices,
            "stale_discovery",
        )
        require(self.identity() == cli, "identity_refused")
        return {"version": 1, "executable": "/usr/bin/shortcuts", "arguments": ["run", row["id"]]}

    def invoke(self, key, admitted, expected_output=None):
        """Run one explicitly chosen native ID; report only CLI/group completion.

        Product adapters must not promote this into automation completion or
        offer service cancellation while automation_retired remains false.
        """
        require(callable(admitted) and admitted() is True, "admission_refused")
        epoch = self.generation
        scalar = self.resolve(key)
        require(admitted() is True and self.generation == epoch, "admission_refused")
        require(key in self.choices and self.identity() == self.choices[key][1], "identity_refused")
        output = self.capture([scalar["executable"], *scalar["arguments"]])
        if expected_output is not None:
            require(
                type(expected_output) is bytes and output == expected_output,
                "fixture_output_refused",
            )
        return {
            "cli_completed": True,
            "local_retired": not self.pending,
            "automation_retired": False,
            "fixture_output_verified": expected_output is not None,
            "reason": "service_retirement_unqualified",
        }

    def inventory(self):
        """Distinguish actual native tools from admitted automation providers."""
        rows = []
        for provider, path, boundary in (
            ("apple_shortcuts", "/usr/bin/shortcuts", "service_retirement_unqualified"),
            ("applescript_jxa", "/usr/bin/osascript", "service_retirement_unqualified"),
            ("automator", "/usr/bin/automator", "service_retirement_unqualified"),
            ("launchservices", "/usr/bin/open", "application_identity_unqualified"),
        ):
            try:
                self.identity(path)
                present = True
            except (OSError, Refused):
                present = False
            rows.append(
                {
                    "id": provider,
                    "installed": present,
                    "available": False,
                    "reason": boundary if present else "tool_unavailable",
                }
            )
        return rows
