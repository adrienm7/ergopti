# tools/test/test-rebuild-sqlite-bridge.py
"""Exercise the portable rebuild fixture over real Python SQLite and Lua."""

import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "static/ergopti_plus/macos/tests/support/keystats"
spec = importlib.util.spec_from_file_location(
    "rebuild_sqlite_bridge", SUPPORT / "rebuild_sqlite_bridge.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class RebuildSQLiteBridgeTests(unittest.TestCase):
    """Prove schema-copy behavior and owner cleanup using real SQLite."""

    def test_lua_proxy_copies_temp_to_attached_database(self):
        lua = os.environ.get("ERGOPTI_DIAGNOSTIC_LUA54") or shutil.which("lua5.4")
        self.assertTrue(lua, "Lua 5.4 is required")
        with tempfile.TemporaryDirectory(prefix="ergopti-rebuild-sqlite-") as temporary:
            result = bridge.run_fixture(
                lua, SUPPORT / "rebuild_sqlite_bridge_probe.lua", ROOT, temporary
            )
            self.assertTrue(result["ok"])

    def test_busy_close_consumes_userdata_and_keeps_the_orphan_visible(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-rebuild-close-") as temporary:
            native = bridge.RebuildSQLiteBridge(temporary)
            try:

                def send(op, **fields):
                    return native.handle({"op": op, **fields})

                source = send("open", path="")["value"]
                target = send("open", path="")["value"]
                self.assertEqual(
                    send("exec", connection=source, sql="CREATE TABLE t(v);")["value"], 0
                )
                backup = send(
                    "backup_init",
                    target=target,
                    target_name="main",
                    source=source,
                    source_name="main",
                )["value"]
                self.assertEqual(send("close", connection=source)["value"], native.BUSY)
                self.assertEqual(send("backup_finish", backup=backup)["value"], native.OK)
                self.assertFalse(send("close", connection=source)["ok"])
                self.assertIn(source, native.connections)
                self.assertIn(source, native.closed)
                self.assertEqual(send("close", connection=target)["value"], native.OK)
            finally:
                native.close()


if __name__ == "__main__":
    unittest.main()
