# tests/support/keystats/rebuild_sqlite_bridge.py
"""Real SQLite schema-image bridge for Lua rebuild transaction tests.

The SQL, transaction, attached database, and schema bytes are real sqlite3.
Backup page progress and injected errors model the lsqlite3 boundary; this is
not a substitute for testing sqlite3_backup against the pinned C binding.
"""

import sqlite3
from pathlib import Path


class RebuildSQLiteBridge:
    """Own multiple connections, model backup handles, and confine file paths."""

    OK, ERROR, BUSY, DONE = 0, 1, 5, 101

    def __init__(self, directory):
        self.root = Path(directory).resolve()
        self.connections = {}
        self.backups = {}
        self.closed = set()
        self.faults = {}
        self.next_connection = 0
        self.next_backup = 0
        self.backup_pages = None

    def _fault(self, name):
        sequence = self.faults.get(name, [])
        return sequence.pop(0) if sequence else None

    def _connection(self, identifier, allow_destination=False):
        db = self.connections[identifier]
        if identifier in self.closed and not allow_destination:
            raise ValueError("SQLite userdata is closed")
        if not allow_destination and any(b["target"] == identifier for b in self.backups.values()):
            raise ValueError("destination connection is busy with a backup")
        return db

    @staticmethod
    def _schema(value):
        if (
            not isinstance(value, str)
            or not value
            or not all(c.isalnum() or c == "_" for c in value)
        ):
            raise ValueError("invalid schema name")
        return value

    @staticmethod
    def _execute(db, sql):
        # executescript implicitly commits, so preserve each explicit transaction.
        pending = ""
        for character in sql:
            pending += character
            if character == ";" and sqlite3.complete_statement(pending):
                db.execute(pending)
                pending = ""
        if pending.strip():
            db.execute(pending)

    def handle(self, request):
        """Return the same {ok,value,error} shape consumed by the Lua proxy."""
        try:
            return {"ok": True, "value": self._handle(request)}
        except (KeyError, ValueError, TypeError, OSError, sqlite3.Error) as error:
            return {"ok": False, "error": str(error)}

    def _handle(self, request):
        op = request["op"]
        if op == "configure":
            pages = request.get("backup_pages")
            if pages is not None and (not isinstance(pages, int) or pages < 1):
                raise ValueError("backup_pages must be a positive integer")
            self.backup_pages = pages
            return True
        if op == "inject":
            self.faults[request["operation"]] = list(request["codes"])
            return True
        if op == "open":
            path = request["path"]
            if path != "":
                path = Path(path).resolve()
                if path != self.root and self.root not in path.parents:
                    raise ValueError("SQLite fixture path outside owned directory")
                path = str(path)
            db = sqlite3.connect(path, isolation_level=None)
            db.row_factory = sqlite3.Row
            self.next_connection += 1
            self.connections[self.next_connection] = db
            return self.next_connection
        if op == "backup_init":
            target_id, source_id = request["target"], request["source"]
            if target_id == source_id:
                raise ValueError("backup requires distinct connections")
            target = self._connection(target_id)
            source = self._connection(source_id)
            if target.in_transaction:
                raise ValueError("backup destination already has a transaction")
            target_name = self._schema(request["target_name"])
            source_name = self._schema(request["source_name"])
            # Schema query validates both names before any backup handle exists.
            target.execute(f"PRAGMA {target_name}.schema_version").fetchone()
            pages = source.execute(f"PRAGMA {source_name}.page_count").fetchone()[0]
            self.next_backup += 1
            self.backups[self.next_backup] = {
                "target": target_id,
                "source": source_id,
                "target_name": target_name,
                "source_name": source_name,
                "remaining": self.backup_pages or max(1, pages),
                "done": False,
            }
            return self.next_backup
        if op in ("backup_step", "backup_finish"):
            backup_id = request["backup"]
            backup = self.backups[backup_id]
            if op == "backup_finish":
                # Native finish consumes its handle even on a non-OK return.
                del self.backups[backup_id]
                injected = self._fault("finish")
                result = backup.get("fatal", self.OK) if injected is None else injected
                # A BUSY close already discarded the Lua DB pointer. Finishing
                # this backup cannot close that orphaned native connection.
                return result
            fault = self._fault("step")
            if fault is not None and fault != self.OK:
                if fault not in (self.BUSY, 6):
                    backup["fatal"] = fault
                return fault
            if backup["done"]:
                return self.DONE
            pages = request["pages"]
            if not isinstance(pages, int):
                raise ValueError("page count must be an integer")
            backup["remaining"] = 0 if pages < 0 else max(0, backup["remaining"] - pages)
            if backup["remaining"] > 0:
                return self.OK
            source = self._connection(backup["source"], True)
            target = self._connection(backup["target"], True)
            image = source.serialize(name=backup["source_name"])
            target.deserialize(image, name=backup["target_name"])
            backup["done"] = True
            return self.DONE
        identifier = request["connection"]
        db = self._connection(identifier, op == "close")
        if op == "close":
            if identifier in self.closed:
                raise ValueError("SQLite userdata is closed")
            # Pinned lsqlite3 clears its userdata even when sqlite3_close is BUSY.
            if any(identifier in (b["target"], b["source"]) for b in self.backups.values()):
                self.closed.add(identifier)
                return self.BUSY
            fault = self._fault("close")
            db.close()
            del self.connections[identifier]
            return self.OK if fault is None else fault
        if op == "exec":
            fault = self._fault("exec")
            if fault is not None and fault != self.OK:
                return fault
            self._execute(db, request["sql"])
            return self.OK
        if op == "rows":
            return [dict(row) for row in db.execute(request["sql"])]
        raise ValueError("unknown SQLite bridge operation")

    def close(self):
        """Release fixture resources even after an assertion failure."""
        self.backups.clear()
        for db in self.connections.values():
            db.close()
        self.connections.clear()


def run_fixture(lua, script, root, temporary, source_root=None, timeout=90):
    """Run a Lua JSON-line child against real SQLite, with an owned deadline."""
    import json
    import os
    import selectors
    import subprocess
    import time

    bridge = RebuildSQLiteBridge(temporary)
    child = subprocess.Popen(
        [str(lua), str(script), str(root), str(temporary), str(source_root or root)],
        env=dict(os.environ, TMPDIR=str(temporary)),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    deadline, pending, receipt = time.monotonic() + timeout, b"", None
    try:
        while True:
            while b"\n" not in pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError("Rebuild SQLite fixture timed out")
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    break
                pending += chunk
            if b"\n" not in pending:
                break
            line, pending = pending.split(b"\n", 1)
            request = json.loads(line)
            if request.get("kind") == "done":
                receipt = request
                break
            if request.get("kind") != "request":
                raise ValueError("unexpected Lua fixture message")
            child.stdin.write(json.dumps(bridge.handle(request)) + "\n")
            child.stdin.flush()
        child.stdin.close()
        status = child.wait(timeout=max(0.1, deadline - time.monotonic()))
        if status != 0 or receipt is None:
            raise AssertionError(child.stderr.read() or "Lua SQLite fixture did not finish")
        if bridge.connections or bridge.backups:
            raise AssertionError("Lua fixture retained SQLite connections or backups")
        return receipt
    finally:
        selector.close()
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()
        bridge.close()
