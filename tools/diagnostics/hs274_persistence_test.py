# tools/diagnostics/hs274_persistence_test.py
"""Real-SQLite bridge for the macOS physical persistence Lua tests, and its confinement proof.

The live-ingest and two-rebuild proof that lived here is test_physical_history_persistence.lua.
"""

import json
import os
from pathlib import Path
import shutil
import selectors
import sqlite3
import subprocess
import tempfile
import unittest
import time

ROOT = Path(__file__).resolve().parents[2]


def owned_path(temporary, candidate):
    """Confine fixture mutations after resolving parent traversal and symlinks."""
    root = Path(temporary).resolve()
    path = Path(candidate).resolve()
    if path != root and root not in path.parents:
        raise ValueError("Physical fixture refuses path outside temporary directory")
    return path


def run_fixture(lua, temporary, fixture=None):
    """Answer Lua API requests with one real connection and an owned child deadline."""
    connection = None
    identity = 0
    child = subprocess.Popen(
        [
            lua,
            str(fixture or Path(__file__).with_name("hs274-persistence.lua")),
            str(ROOT),
            temporary,
            os.environ.get("ERGOPTI_PHYSICAL_SOURCE_ROOT", str(ROOT)),
        ],
        env=dict(os.environ, TMPDIR=temporary),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 90
    receipt = None
    pending_output = b""
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    try:
        while True:
            while b"\n" not in pending_output:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError("Physical release SQLite fixture timed out")
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    break
                pending_output += chunk
            if b"\n" not in pending_output:
                break
            line, pending_output = pending_output.split(b"\n", 1)
            request = json.loads(line)
            if request.get("kind") == "done":
                receipt = request
                break
            if request.get("kind") != "request":
                raise ValueError("Unexpected physical persistence response")
            try:
                operation = request["op"]
                if operation == "stat":
                    path = Path(request["path"])
                    value = (
                        {
                            "type": "directory" if path.is_dir() else "file",
                            "size": path.stat().st_size,
                        }
                        if path.exists()
                        else False
                    )
                elif operation == "directory":
                    value = sorted(path.name for path in Path(request["path"]).iterdir())
                elif operation == "mkdir":
                    owned_path(temporary, request["path"]).mkdir(mode=0o700)
                    value = True
                elif operation == "open":
                    if connection is not None:
                        raise ValueError("Prior SQLite connection is still owned")
                    connection = sqlite3.connect(
                        owned_path(temporary, request["path"]), isolation_level=None
                    )
                    connection.row_factory = sqlite3.Row
                    identity += 1
                    value = identity
                else:
                    if connection is None or request["connection"] != identity:
                        raise ValueError("SQLite request does not own the live connection")
                    if operation == "close":
                        connection.close()
                        connection = None
                        value = 0
                    elif operation == "rows":
                        value = [dict(row) for row in connection.execute(request["sql"])]
                    elif operation == "bound":
                        connection.execute(request["sql"], request["values"])
                        value = 0
                    elif operation == "exec":
                        # executescript implicitly commits; execute complete statements
                        # separately so the production BEGIN/COMMIT boundary stays real.
                        pending = ""
                        for character in request["sql"]:
                            pending += character
                            if character == ";" and sqlite3.complete_statement(pending):
                                connection.execute(pending)
                                pending = ""
                        if pending.strip():
                            connection.execute(pending)
                        value = 0
                    else:
                        raise ValueError("Unknown SQLite bridge operation")
                response = {"ok": True, "value": value}
            except (KeyError, ValueError, OSError, sqlite3.Error) as error:
                response = {"ok": False, "error": str(error)}
            child.stdin.write(json.dumps(response) + "\n")
            child.stdin.flush()
        child.stdin.close()
        status = child.wait(timeout=max(0.1, deadline - time.monotonic()))
        if status != 0 or receipt is None:
            raise AssertionError(
                child.stderr.read() or "Physical persistence fixture did not finish"
            )
        if connection is not None:
            raise AssertionError("Physical persistence fixture retained a live SQLite connection")
        return receipt
    finally:
        selector.close()
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()
        if connection is not None:
            connection.close()


class PhysicalReleasePersistenceTests(unittest.TestCase):
    """The actual Mac writer/walker/rebuild drives an adapted real SQLite API."""

    def test_bridge_refuses_paths_outside_its_owned_temporary_directory(self):
        lua = os.environ.get("ERGOPTI_DIAGNOSTIC_LUA54") or shutil.which("lua5.4")
        self.assertTrue(lua, "Selected physical persistence proof requires Lua 5.4")
        with tempfile.TemporaryDirectory(prefix="ergopti-physical-confinement-") as temporary:
            root = Path(temporary)
            owned = root / "owned"
            outside = root / "outside"
            owned.mkdir()
            outside.mkdir()
            (owned / "link").symlink_to(outside, target_is_directory=True)
            targets = [
                ("mkdir", root / "owned-sibling"),
                ("mkdir", owned / ".." / "escaped-directory"),
                ("open", root / "escaped.sqlite"),
                ("open", owned / "link" / "escaped.sqlite"),
                ("mkdir", owned / "link" / "escaped-directory"),
            ]
            fixture = root / "confinement.lua"
            source = [
                'package.path = arg[1] .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path',
                'local json, refusals = require("json"), {}',
            ]
            for operation, path in targets:
                request = json.dumps({"kind": "request", "op": operation, "path": str(path)})
                source.extend(
                    [
                        f'assert(io.stdout:write({json.dumps(request)} .. "\\n")); assert(io.stdout:flush())',
                        'refusals[#refusals + 1] = json.decode(assert(io.stdin:read("*l")))',
                    ]
                )
            source.append('print(json.encode({ kind = "done", refusals = refusals }))')
            fixture.write_text("\n".join(source) + "\n")
            receipt = run_fixture(lua, str(owned), fixture)
            self.assertEqual(len(receipt["refusals"]), 5)
            for refusal in receipt["refusals"]:
                self.assertFalse(refusal["ok"])
                self.assertIn("outside temporary directory", refusal["error"])
            self.assertFalse((root / "owned-sibling").exists())
            self.assertFalse((root / "escaped-directory").exists())
            self.assertFalse((root / "escaped.sqlite").exists())
            self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
