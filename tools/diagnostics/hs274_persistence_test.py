# tools/diagnostics/hs274_persistence_test.py
"""Real-SQLite bridge for the macOS physical persistence Lua tests, and its confinement proof.

The live-ingest and two-rebuild proof that lived here is test_physical_history_persistence.lua.
"""

import json
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import selectors
import sqlite3
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import time

ROOT = Path(__file__).resolve().parents[2]


def native_attributes(path, follow):
    """Expose actual stat identity for native FileSystem publication fixtures."""
    try:
        observed = os.stat(path, follow_symlinks=follow)
    except FileNotFoundError:
        return False
    mode = observed.st_mode
    kind = (
        "directory"
        if stat.S_ISDIR(mode)
        else "file"
        if stat.S_ISREG(mode)
        else "link"
        if stat.S_ISLNK(mode)
        else "other"
    )
    attributes = {
        "type": kind,
        "size": observed.st_size,
        "dev": observed.st_dev,
        "ino": observed.st_ino,
        "uid": observed.st_uid,
        "gid": observed.st_gid,
        "permissions": stat.filemode(mode)[1:],
    }
    if stat.S_ISLNK(mode):
        attributes["target"] = os.readlink(path)
    return attributes


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
    digests = {}
    digest_identity = 0
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
                elif operation in ("stat_identity", "lstat_identity"):
                    value = native_attributes(request["path"], operation == "stat_identity")
                elif operation == "mkdir":
                    owned_path(temporary, request["path"]).mkdir(mode=0o700)
                    value = True
                elif operation == "replace":
                    os.replace(
                        owned_path(temporary, request["source"]),
                        owned_path(temporary, request["path"]),
                    )
                    value = True
                elif operation == "link":
                    os.link(
                        owned_path(temporary, request["source"]),
                        owned_path(temporary, request["destination"]),
                    )
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
                elif operation == "sha256_new":
                    digest_identity += 1
                    digests[digest_identity] = hashlib.sha256()
                    value = digest_identity
                elif operation == "sha256_append":
                    digests[request["digest"]].update(bytes.fromhex(request["hex"]))
                    value = True
                elif operation == "sha256_finish":
                    value = digests.pop(request["digest"]).hexdigest()
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
            owned_source = owned / "replace-source"
            owned_source.write_text("controlled original", encoding="utf-8")
            targets = [
                ("mkdir", root / "owned-sibling"),
                ("mkdir", owned / ".." / "escaped-directory"),
                ("open", root / "escaped.sqlite"),
                ("open", owned / "link" / "escaped.sqlite"),
                ("mkdir", owned / "link" / "escaped-directory"),
            ]
            requests = [{"op": operation, "path": str(path)} for operation, path in targets]
            requests.extend(
                [
                    {
                        "op": "replace",
                        "source": str(owned_source),
                        "path": str(root / "outside-target"),
                    },
                    {
                        "op": "replace",
                        "source": str(root / "outside-source"),
                        "path": str(owned_source),
                    },
                ]
            )
            fixture = root / "confinement.lua"
            source = [
                'package.path = arg[1] .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path',
                'local json, refusals = require("json"), {}',
            ]
            for message in requests:
                request = json.dumps({"kind": "request", **message})
                source.extend(
                    [
                        f'assert(io.stdout:write({json.dumps(request)} .. "\\n")); assert(io.stdout:flush())',
                        'refusals[#refusals + 1] = json.decode(assert(io.stdin:read("*l")))',
                    ]
                )
            source.append('print(json.encode({ kind = "done", refusals = refusals }))')
            fixture.write_text("\n".join(source) + "\n")
            receipt = run_fixture(lua, str(owned), fixture)
            self.assertEqual(len(receipt["refusals"]), len(requests))
            for refusal in receipt["refusals"]:
                self.assertFalse(refusal["ok"])
                self.assertIn("outside temporary directory", refusal["error"])
            self.assertFalse((root / "owned-sibling").exists())
            self.assertFalse((root / "escaped-directory").exists())
            self.assertFalse((root / "escaped.sqlite").exists())
            self.assertEqual(list(outside.iterdir()), [])
            self.assertEqual(owned_source.read_text(encoding="utf-8"), "controlled original")
            self.assertFalse((root / "outside-target").exists())


class NativeMetadataTests(unittest.TestCase):
    def test_actual_file_identity_matches_the_operating_system(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "owned.txt"
            path.write_bytes(b"physical metadata")
            observed = native_attributes(path, True)
            expected = path.stat()
            self.assertEqual(observed["type"], "file")
            for name in ("size", "dev", "ino", "uid", "gid"):
                self.assertEqual(observed[name], getattr(expected, "st_" + name))
            self.assertEqual(observed["permissions"], stat.filemode(expected.st_mode)[1:])
            self.assertEqual(native_attributes(temporary, False)["type"], "directory")

    def test_actual_symlink_and_target_identities_remain_distinct(self):
        with tempfile.TemporaryDirectory() as temporary:
            target, link = Path(temporary) / "target.txt", Path(temporary) / "link.txt"
            target.write_bytes(b"preserved target")
            link.symlink_to(target.name)
            followed, exact = native_attributes(link, True), native_attributes(link, False)
            self.assertEqual(followed["ino"], target.stat().st_ino)
            self.assertEqual(exact["ino"], link.lstat().st_ino)
            self.assertEqual(exact["type"], "link")
            self.assertEqual(exact["target"], target.name)
            self.assertNotEqual(followed["ino"], exact["ino"])
            target.unlink()
            self.assertFalse(native_attributes(link, True))
            self.assertEqual(native_attributes(link, False)["ino"], exact["ino"])

    def test_only_proven_missing_metadata_is_absence(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertFalse(native_attributes(Path(temporary) / "missing", False))
            with patch.object(os, "stat", side_effect=PermissionError("metadata denied")):
                with self.assertRaisesRegex(PermissionError, "metadata denied"):
                    native_attributes(temporary, False)


class ForeignLedgerGenerationTests(unittest.TestCase):
    """Real source rewrites must invalidate a durable foreign prefix receipt."""

    def setUp(self):
        self.lua = os.environ.get("ERGOPTI_DIAGNOSTIC_LUA54") or shutil.which("lua5.4")
        self.assertTrue(self.lua, "Foreign ledger replay requires Lua 5.4")
        self.temporary = tempfile.TemporaryDirectory(prefix="ergopti-foreign-generation-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        folder = self.root / "metrics/by_device/foreign"
        folder.mkdir(parents=True)
        (folder / "device.json").write_text(
            json.dumps(
                {"device_id": "foreign", "name": "Controlled foreign device", "os": "linux"}
            ),
            encoding="utf-8",
        )
        self.ledger = folder / "data.sql"
        self.schema = ROOT / "static/ergopti_plus/_shared/data/db/schema.sql"
        with sqlite3.connect(self.root / "cache.sqlite") as connection:
            connection.executescript(self.schema.read_text(encoding="utf-8"))

    @staticmethod
    def batch(identifier, padding=""):
        """Return one canonical committed event transaction."""
        metadata = json.dumps({"padding": padding}).replace("'", "''")
        return (
            "BEGIN TRANSACTION;\n"
            "INSERT OR IGNORE INTO events_system "
            "(device_id,id,ts,date,action,metadata_json) VALUES "
            f"('foreign',{identifier},'2026-10-25 10:00:00.000','2026-10-25','wake','{metadata}');\n"
            "COMMIT;\n"
        ).encode("utf-8")

    def replay(self):
        """Run the actual importer in a fresh Lua process and SQLite connection."""
        return run_fixture(
            self.lua,
            self.temporary.name,
            ROOT
            / "static/ergopti_plus/macos/tests/fixtures/keystats/foreign_ledger_generation.lua",
        )

    def assert_committed_receipt(self, result):
        """Independently hash exactly the source prefix committed in SQLite."""
        watermark = result["watermark"][0]
        offset = watermark["imported_data_sql_size"]
        self.assertEqual(
            watermark["imported_data_sql_sha256"],
            hashlib.sha256(self.ledger.read_bytes()[:offset]).hexdigest(),
        )

    def test_fixture_isolates_lua_module_paths_from_host_dependencies(self):
        self.ledger.write_bytes(self.batch(1))
        modules = self.root / "unbundled-modules"
        modules.mkdir()
        (modules / "lfs.lua").write_text("error('unbundled-lua-module')\n", encoding="utf-8")
        lua_path, cpath = str(modules / "?.lua"), str(modules / "?.so")
        with patch.dict(
            os.environ,
            {
                "LUA_PATH": lua_path,
                "LUA_CPATH": cpath,
                "LUA_PATH_5_4": lua_path,
                "LUA_CPATH_5_4": cpath,
            },
        ):
            control = subprocess.run(
                [
                    self.lua,
                    "-e",
                    'local ok, reason = pcall(require, "lfs"); '
                    'assert(not ok and tostring(reason):find("unbundled-lua-module", 1, true))',
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
            result = self.replay()
        self.assertEqual([row["id"] for row in result["rows"]], [1])
        paths = result["module_paths"]["lua"].split(";")
        self.assertTrue(paths)
        self.assertTrue(all(path.startswith(str(ROOT / "static/ergopti_plus")) for path in paths))
        self.assertEqual(result["module_paths"]["native"], "")
        self.assertFalse(result["module_paths"]["lfs_loaded"])
        self.assert_committed_receipt(result)

    def test_actual_compactor_then_append_imports_new_event_after_restart(self):
        self.ledger.write_bytes(self.batch(1) * 100)
        before = self.replay()
        self.assertEqual([row["id"] for row in before["rows"]], [1])
        old_size = self.ledger.stat().st_size
        spec = importlib.util.spec_from_file_location(
            "foreign_compactor", ROOT / "tools/compact_data_sql.py"
        )
        compactor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(compactor)
        self.assertTrue(compactor.compact_device(self.ledger, self.schema))
        with self.ledger.open("ab") as stream:
            stream.write(self.batch(99))
        self.assertLess(self.ledger.stat().st_size, old_size)
        after = self.replay()
        self.assertEqual([row["id"] for row in after["rows"]], [1, 99])
        self.assert_committed_receipt(after)

    def test_equal_size_rewrite_imports_complete_replacement_generation(self):
        self.ledger.write_bytes(self.batch(1) * 4)
        self.replay()
        old_size = self.ledger.stat().st_size
        replaced = self.batch(1) + self.batch(99)
        replaced += b"--" + b" " * (old_size - len(replaced) - 3) + b"\n"
        self.assertEqual(len(replaced), old_size)
        self.ledger.write_bytes(replaced)
        after = self.replay()
        self.assertEqual([row["id"] for row in after["rows"]], [1, 99])
        self.assert_committed_receipt(after)

    def test_larger_rewrite_refuses_the_old_mid_literal_offset(self):
        self.ledger.write_bytes(self.batch(1) * 2)
        self.replay()
        old_size = self.ledger.stat().st_size
        self.ledger.write_bytes(self.batch(1) + self.batch(99, "x" * old_size))
        self.assertGreater(self.ledger.stat().st_size, old_size)
        after = self.replay()
        self.assertEqual([row["id"] for row in after["rows"]], [1, 99])
        self.assert_committed_receipt(after)

    def test_legacy_watermark_without_digest_replays_before_publishing_a_receipt(self):
        self.ledger.write_bytes(self.batch(1))
        self.replay()
        with sqlite3.connect(self.root / "cache.sqlite") as connection:
            connection.execute("UPDATE devices SET imported_data_sql_sha256=NULL")
        with self.ledger.open("ab") as stream:
            stream.write(self.batch(99))
        after = self.replay()
        self.assertEqual([row["id"] for row in after["rows"]], [1, 99])
        self.assert_committed_receipt(after)

    def test_torn_append_keeps_the_digest_at_the_previous_commit(self):
        first, second = self.batch(1), self.batch(99)
        self.ledger.write_bytes(first + second.removesuffix(b"COMMIT;\n"))
        partial = self.replay()
        self.assertEqual([row["id"] for row in partial["rows"]], [1])
        self.assertEqual(partial["watermark"][0]["imported_data_sql_size"], len(first))
        self.assert_committed_receipt(partial)
        with self.ledger.open("ab") as stream:
            stream.write(b"COMMIT;\n")
        after = self.replay()
        self.assertEqual([row["id"] for row in after["rows"]], [1, 99])
        self.assert_committed_receipt(after)

    def test_large_prefix_yields_and_persists_a_native_digest_across_restart(self):
        self.ledger.write_bytes(self.batch(1) * 1000)
        initial = self.replay()
        self.assertGreater(initial["turns"], 1)
        self.assert_committed_receipt(initial)
        with self.ledger.open("ab") as stream:
            stream.write(self.batch(99, "é\nCOMMIT;\nquoted ' text"))
        after = self.replay()
        self.assertGreater(after["turns"], 1)
        self.assertEqual([row["id"] for row in after["rows"]], [1, 99])
        self.assert_committed_receipt(after)

    def test_atomic_path_replacement_preserves_the_open_generation_then_imports_its_successor(self):
        self.ledger.write_bytes(self.batch(1) * 1000)
        (self.root / "replacement.sql").write_bytes(self.batch(1) + self.batch(99))
        after = self.replay()
        self.assertEqual(after["generations"], 2)
        self.assertEqual([row["id"] for row in after["rows"]], [1, 99])
        self.assert_committed_receipt(after)


if __name__ == "__main__":
    unittest.main()
