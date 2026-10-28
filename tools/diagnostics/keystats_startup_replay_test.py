# tools/diagnostics/keystats_startup_replay_test.py
"""Exercise cold ledger recovery through the actual Lua manager and real SQLite."""

import importlib.util
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "startup_replay_bridge", Path(__file__).with_name("hs274_persistence_test.py")
)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)
BATCHES = 32
ROWS_PER_BATCH = 100
ROWS = BATCHES * ROWS_PER_BATCH
DATE = "2026-10-28"
DEVICE = "bootstrap-proof"


def batch(number, offset, ending):
    """Use the actual producer's complete transaction and cursor marker format."""
    header = (
        f"-- === ingest batch {DATE} 12:00:00.000 "
        f"(offset {offset} -> {ending}, {ROWS_PER_BATCH} entry(ies)) ===\n"
        "BEGIN TRANSACTION;\n"
    )
    rows = "".join(
        "INSERT OR IGNORE INTO events_system VALUES "
        f"('{DEVICE}',{event},'{DATE} 12:00:00','{DATE}','wake',"
        f'\'{{"pad":"{"x" * 1000}"}}\');\n'
        for event in range(number * ROWS_PER_BATCH, (number + 1) * ROWS_PER_BATCH)
    )
    return header + rows + "COMMIT;\n"


class StartupReplayTests(unittest.TestCase):
    def fixture(self, temporary, mode):
        """Replay with the caller's source tree and an owned child/SQLite lifetime."""
        lua = os.environ.get("ERGOPTI_DIAGNOSTIC_LUA54") or shutil.which("lua5.4")
        self.assertTrue(lua, "actual Lua 5.4 is required")
        environment = {
            "HOME": temporary,
            "ERGOPTI_PHYSICAL_SOURCE_ROOT": os.environ.get(
                "ERGOPTI_PHYSICAL_SOURCE_ROOT", str(ROOT)
            ),
            "ERGOPTI_STARTUP_REPLAY_MODE": mode,
        }
        previous_umask = os.umask(0o077)
        try:
            with patch.dict(os.environ, environment):
                return BRIDGE.run_fixture(
                    lua,
                    temporary,
                    ROOT / "static/ergopti_plus/macos/tests/fixtures/keystats/startup_replay.lua",
                )
        finally:
            os.umask(previous_umask)

    def seed(self, temporary):
        """Seed a durable multi-transaction ledger with no disposable SQLite cache."""
        root = Path(temporary)
        (root / ".gitignore").write_text("today.log\n")
        ledger = "".join(
            batch(number, number * ROWS_PER_BATCH, (number + 1) * ROWS_PER_BATCH)
            for number in range(BATCHES)
        )
        (root / "data.sql").write_text(ledger)
        return ledger

    def complete(self, result, cursor=ROWS, rows=ROWS, cold=True):
        """Require full raw recovery and checked metadata publication before success."""
        self.assertTrue(result["initialized"], result)
        self.assertTrue(result["sentinel_before_complete"], result)
        if cold:
            self.assertLess(result["rows_after_init"], ROWS, result)
        self.assertGreater(result["turns"], 1, result)
        self.assertEqual(result["raw_rows"], rows, result)
        self.assertEqual(result["cursor"], cursor, result)
        self.assertEqual(result["next_id"], rows, result)
        self.assertNotEqual(result["revision"], "0", result)
        self.assertTrue(result["stopped"], result)
        self.assertEqual(result["errors"], {}, result)

    def test_cold_cache_yields_before_replay_finishes(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-cold-replay-") as temporary:
            ledger = self.seed(temporary)
            self.complete(self.fixture(temporary, "complete"))
            self.assertEqual((Path(temporary) / "data.sql").read_text(), ledger)

    def test_cancelled_partial_cache_replays_on_restart(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-cancel-replay-") as temporary:
            self.seed(temporary)
            partial = self.fixture(temporary, "cancel")
            self.assertTrue(partial["stopped"], partial)
            self.assertLess(partial["raw_rows"], ROWS, partial)
            self.assertEqual(partial["cursor"], 0, partial)
            self.assertEqual(partial["revision"], "0", partial)
            self.complete(self.fixture(temporary, "complete"))

    def test_warm_outbox_cursor_never_rewinds_to_older_ledger(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-warm-replay-") as temporary:
            ledger = self.seed(temporary)
            outbox = (
                f"-- === ingest batch {DATE} 12:00:00.000 (offset {ROWS} -> {ROWS + 1}, 1 entry(ies)) ===\n"
                "BEGIN TRANSACTION;\n"
                f"INSERT OR IGNORE INTO events_system VALUES ('{DEVICE}',{ROWS},"
                f"'{DATE} 12:00:00','{DATE}','wake','{{}}');\nCOMMIT;\n"
            )
            with sqlite3.connect(Path(temporary) / "cache.sqlite") as database:
                for name in ("schema.sql", "media_schema.sql"):
                    database.executescript(
                        (ROOT / "static/ergopti_plus/_shared/data/db" / name).read_text()
                    )
                database.executescript(ledger + outbox)
                for key, value in {
                    "local_data_sql_outbox": outbox,
                    "today_log_offset": str(ROWS + 1),
                    "today_log_date": DATE,
                    "next_event_id": str(ROWS + 1),
                }.items():
                    database.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, value))
            self.complete(self.fixture(temporary, "warm"), ROWS + 1, ROWS + 1, cold=False)

    def test_replay_failures_block_both_ingest_paths_until_restart(self):
        for fault in ("read", "sql", "schedule"):
            with (
                self.subTest(fault=fault),
                tempfile.TemporaryDirectory(prefix="ergopti-refused-replay-") as temporary,
            ):
                self.seed(temporary)
                refused = self.fixture(temporary, "fault_" + fault)
                self.assertIs(refused.get("blocked"), True, refused)
                self.assertEqual(refused["rotation_reads_after_failure"], 0, refused)
                self.assertEqual(refused["stop_read_delta"], 0, refused)
                self.assertEqual(refused["replay_pending_rows"], 1, refused)
                self.assertEqual(refused["revision"], "0", refused)
                self.assertTrue(refused["durability_restored"], refused)
                self.assertTrue(refused["stopped"], refused)
                self.complete(self.fixture(temporary, "warm"), cold=False)

    def test_metadata_refusals_never_clear_the_pending_replay(self):
        for fault in (
            "publication",
            "id_publication",
            "date_publication",
            "context_publication",
            "pending_delete",
        ):
            with (
                self.subTest(fault=fault),
                tempfile.TemporaryDirectory(prefix="ergopti-publication-replay-") as temporary,
            ):
                self.seed(temporary)
                refused = self.fixture(temporary, "fault_" + fault)
                self.assertEqual(refused["replay_pending_rows"], 1, refused)
                self.assertEqual(refused["revision"], "0", refused)
                self.assertEqual(refused["rotation_reads_after_failure"], 0, refused)
                self.assertEqual(refused["stop_read_delta"], 0, refused)
                self.assertTrue(refused["errors"], refused)
                self.assertTrue(refused["stopped"], refused)
                self.complete(self.fixture(temporary, "warm"), cold=False)

    def test_durable_mode_refusal_retains_cleanup_and_blocks_publication(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-durable-replay-") as temporary:
            self.seed(temporary)
            refused = self.fixture(temporary, "fault_durability")
            self.assertEqual(refused["synchronous"], 0, refused)
            self.assertEqual(refused["replay_pending_rows"], 1, refused)
            self.assertEqual(refused["revision"], "0", refused)
            self.assertEqual(refused["rotation_reads_after_failure"], 0, refused)
            self.assertEqual(refused["stop_read_delta"], 0, refused)
            self.assertTrue(refused["durability_restored"], refused)
            self.assertTrue(refused["stopped"], refused)
            self.complete(self.fixture(temporary, "warm"), cold=False)

    def test_timer_cancel_refusal_retains_the_database_until_exact_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-cancel-owner-") as temporary:
            self.seed(temporary)
            result = self.fixture(temporary, "fault_cancel")
            self.assertIs(result["first_stop"], False, result)
            self.assertTrue(result["live_after_refusal"], result)
            self.assertTrue(result["stale_callback_blocked"], result)
            self.assertTrue(result["stopped"], result)
            self.complete(self.fixture(temporary, "warm"), cold=False)


if __name__ == "__main__":
    unittest.main()
