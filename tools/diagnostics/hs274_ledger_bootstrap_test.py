# tools/diagnostics/hs274_ledger_bootstrap_test.py
"""Initial canonical ledger publication against physical FILEs and SQLite.

The native EFBIG control belongs to the Common Linux diagnostic gate. Portable
mode also runs from the macOS Lua suite; neither mode claims Darwin-native IO.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "journal_physical_bridge", Path(__file__).with_name("hs274_persistence_test.py")
)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class LedgerBootstrapTests(unittest.TestCase):
    def replay(self, mode, native_control=None):
        self.assertIn(mode, ("portable_close", "portable_write", "native"))
        if mode == "native":
            self.assertIsNotNone(
                native_control, "the native feature must supply its actual boundary owner"
            )

        lua = (
            os.environ.get("ERGOPTI_DIAGNOSTIC_LUA54")
            or shutil.which("lua5.4")
            or shutil.which("lua")
        )
        self.assertTrue(lua, "Lua 5.4 is required for the physical journal replay")
        original_popen, original_read = subprocess.Popen, os.read
        children, limits = [], []
        pending = b""

        with tempfile.TemporaryDirectory(prefix="ergopti-ledger-bootstrap-") as temporary:

            def popen(*args, **kwargs):
                kwargs["env"] = dict(kwargs["env"], HOME=temporary)
                if mode == "native":
                    kwargs["preexec_fn"] = native_control.ignore_signal
                child = original_popen(*args, **kwargs)
                children.append(child)
                return child

            def read(fd, count):
                nonlocal pending
                chunk = original_read(fd, count)
                if children and fd == children[-1].stdout.fileno():
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        row = json.loads(line)
                        if row.get("native_write_limit") is not None:
                            self.assertEqual(mode, "native")
                            limit = row["native_write_limit"]
                            native_control.set_limit(children[-1].pid, limit)
                            limits.append(limit)
                        if row.get("native_write_restore"):
                            self.assertEqual(mode, "native")
                            native_control.restore_limit(children[-1].pid)
                            limits.append("restored")
                return chunk

            environment = {
                "ERGOPTI_LEDGER_BOOTSTRAP_MODE": mode,
                "ERGOPTI_PHYSICAL_SOURCE_ROOT": os.environ.get(
                    "ERGOPTI_PHYSICAL_SOURCE_ROOT", str(ROOT)
                ),
            }
            with (
                patch.dict(os.environ, environment),
                patch.object(BRIDGE.subprocess, "Popen", side_effect=popen),
                patch.object(BRIDGE.os, "read", side_effect=read),
            ):
                receipt = BRIDGE.run_fixture(
                    lua,
                    temporary,
                    ROOT / "static/ergopti_plus/macos/tests/fixtures/keystats/ledger_bootstrap.lua",
                )
            self.assertEqual(receipt["fault_mode"], mode)
            self.assertFalse(receipt["initialized_after_refusal"])
            self.assertTrue(receipt["retry_initialized"])
            self.assertTrue(receipt["canonical_absent_after_refusal"])
            self.assertTrue(receipt["journal_absent_after_refusal"])
            self.assertTrue(receipt["failed_close"]["native_closed"])
            self.assertEqual(receipt["raw_rows"], 1)
            self.assertEqual(receipt["duration_ms"], 100)
            self.assertTrue(receipt["outbox_empty"])
            with BRIDGE.sqlite3.connect(":memory:") as database:
                database.executescript(
                    (ROOT / "static/ergopti_plus/_shared/data/db/schema.sql").read_text()
                )
                database.executescript((Path(temporary) / "data.sql").read_text())
                self.assertEqual(
                    database.execute("SELECT COUNT(*) FROM events_app_switch").fetchone()[0], 1
                )
            self.assertFalse(
                list(Path(temporary).glob("*.ergoptiplus-stage-lock")), "staging directory leaked"
            )
            if mode == "native":
                self.assertEqual(len(limits), 2)
                self.assertGreater(limits[0], 0)
                self.assertEqual(limits[1], "restored")
            else:
                self.assertEqual(limits, [])
            receipt["native_limit_changes"] = len(limits)
            return receipt

    def test_portable_buffered_close_refusal_then_retry_publishes_complete_ledger(self):
        self.replay("portable_close")

    def test_portable_write_refusal_then_retry_publishes_complete_ledger(self):
        self.replay("portable_write")


if __name__ == "__main__":
    unittest.main()
