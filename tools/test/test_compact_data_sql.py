# tools/test/test_compact_data_sql.py

"""Native SQLite and public CLI regressions for lossless ledger compaction."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "compact_data_sql.py"
SCHEMA = ROOT / "static" / "ergopti_plus" / "_shared" / "data" / "db" / "schema.sql"
SPEC = importlib.util.spec_from_file_location("compact_data_sql_owner", TOOL)
OWNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OWNER)


def captured_batch(event_id: int, replacement: str, offset: int = 0) -> str:
    """Independent ordinary hotstring INSERT shape from the canonical producer."""
    literal = "'" + replacement.replace("'", "''") + "'"
    return (
        f"\n-- === ingest batch 2026-07-18 09:00:00.000 (offset {offset} -> {offset + 120}, 1 entry(ies)) ===\n"
        "BEGIN TRANSACTION;\n"
        "INSERT OR IGNORE INTO events_hotstring "
        "(device_id,id,ts,date,app,kind,trigger,replacement,h_type,net_saved_chars) VALUES "
        f"('device',{event_id},'2026-07-18 09:00:00.000','2026-07-18','fixture','fired','code',{literal},NULL,1);\n"
        "COMMIT;\n"
    )


def read_rows(path: Path) -> list[tuple]:
    """One-pass SQLite is independent of the streaming framing under test."""
    with contextlib.closing(sqlite3.connect(":memory:")) as conn:
        conn.executescript(SCHEMA.read_text(encoding="utf-8"))
        conn.executescript(path.read_bytes().decode("utf-8-sig"))
        return conn.execute("SELECT id,replacement FROM events_hotstring ORDER BY id").fetchall()


class CompactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ergopti-compact-")
        self.addCleanup(self.temp.cleanup)
        self.metrics = Path(self.temp.name) / "metrics é漢 space"
        self.path = self.metrics / "by_device" / "device" / "data.sql"
        self.path.parent.mkdir(parents=True)
        self.backup = self.path.with_suffix(".sql.bak")

    def write(self, text: str):
        self.path.write_bytes(text.encode("utf-8"))

    def cli(self):
        return subprocess.run(
            [sys.executable, str(TOOL), str(self.metrics)],
            cwd=ROOT,
            env={
                **os.environ,
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONUTF8": "1",
                "PYTHONIOENCODING": "utf-8",
            },
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=30,
            check=False,
        )

    def assert_refused(self, source: bytes):
        self.path.write_bytes(source)
        previous_backup = b"prior independent backup must remain exact"
        self.backup.write_bytes(previous_backup)
        result = self.cli()
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("FAILED", result.stdout)
        self.assertNotIn("Done. Backup kept", result.stdout)
        self.assertEqual(
            source, self.path.read_bytes(), "refused projection cannot replace its authority"
        )
        self.assertEqual(previous_backup, self.backup.read_bytes())
        self.assertFalse((self.path.parent / "_compact_work.db").exists())
        self.assertFalse(self.path.with_suffix(".compact.tmp").exists())

    def test_public_cli_retains_small_capture_at_real_two_mib_boundary(self):
        # Thousands of ordinary small batches align one 100-character capture;
        # no huge replacement or test-only reduction of CHUNK_CHARS is needed.
        self.assertEqual(2 * 1024 * 1024, OWNER.CHUNK_CHARS)
        chunks = []
        size = 0
        event_id = 1
        expected = []
        while size < OWNER.CHUNK_CHARS - 1050:
            text = "ordinary bounded replacement text"
            batch = captured_batch(event_id, text, event_id * 120)
            chunks.append(batch)
            expected.append((event_id, text))
            size += len(batch)
            event_id += 1
        payload = "SQL example\nCOMMIT;\n" + "B" * 80
        self.assertEqual(100, len(payload))
        padding = captured_batch(event_id, "", event_id * 120)
        capture = captured_batch(event_id + 1, payload, (event_id + 1) * 120)
        fake_end = capture.index("COMMIT;\n") + len("COMMIT;\n")
        needed = OWNER.CHUNK_CHARS - 1 - size - len(padding) - fake_end
        self.assertGreaterEqual(needed, 0)
        self.assertLessEqual(needed, 512)
        # Keep every replacement at most 100 characters, including the small
        # alignment padding. Spread any remainder over ordinary preceding rows.
        for position in range(len(expected) - 1, -1, -1):
            if needed <= 100:
                break
            row_id, text = expected[position]
            extra = min(needed - 100, 100 - len(text))
            text += "A" * extra
            chunks[position] = captured_batch(row_id, text, row_id * 120)
            expected[position] = (row_id, text)
            size += extra
            needed -= extra
        self.assertLessEqual(needed, 100)
        padding_text = "A" * needed
        padding = captured_batch(event_id, padding_text, event_id * 120)
        chunks.extend([padding, capture])
        expected.extend([(event_id, padding_text), (event_id + 1, payload)])
        self.assertLessEqual(max(len(row[1]) for row in expected), 100)
        self.assertEqual(OWNER.CHUNK_CHARS - 1, size + len(padding) + fake_end)
        self.write("".join(chunks))
        source = self.path.read_bytes()
        self.assertGreater(len(source), OWNER.CHUNK_CHARS)
        self.assertEqual(
            expected, read_rows(self.path), "original canonical SQL must contain the capture"
        )
        result = self.cli()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Done. Backup kept", result.stdout)
        self.assertEqual(
            expected,
            read_rows(self.path),
            "compaction must retain every raw row, including the last capture",
        )
        self.assertNotIn("[warn]", result.stdout)
        self.assertEqual(source, self.backup.read_bytes())

    def test_stream_preserves_quoted_markers_comments_and_utf8_across_reads(self):
        payload = "é漢😀 doubled ' quote\nCOMMIT;\n-- fake comment\n/* fake block */\r\nend"
        source = (
            captured_batch(1, "first")
            + "/* odd ' quote\nCOMMIT;\nstill comment */\n-- odd ' line quote\n"
            + captured_batch(2, payload)
        )
        self.write(source)
        for count in [1, 7, 31, 700, OWNER.CHUNK_CHARS]:
            with self.subTest(chunk_chars=count), sqlite3.connect(":memory:") as conn:
                conn.executescript(SCHEMA.read_text(encoding="utf-8"))
                with (
                    patch.object(OWNER, "CHUNK_CHARS", count),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    OWNER.exec_large_file(conn, self.path)
                self.assertFalse(conn.in_transaction)
                rows = conn.execute(
                    "SELECT id,replacement FROM events_hotstring ORDER BY id"
                ).fetchall()
                self.assertEqual([(1, "first"), (2, payload)], rows)

    def test_native_lexical_states_are_recovered_at_line_boundaries(self):
        cases = [
            ("SELECT 'é😀\n", 0, 1),
            ("doubled '' CREATE TRIGGER t BEGIN\n", 1, 1),
            ("closing'; -- odd ' quote\n", 1, 0),
            ('SELECT "quoted\n', 0, 2),
            ("SELECT `quoted\n", 0, 3),
            ("SELECT [quoted\n", 0, 4),
            ("SELECT /* odd ' quote\n", 0, 5),
            ("comment -- ' */ SELECT 1;\n", 5, 0),
            ("-- odd ' quote and /*\n", 0, 0),
        ]
        for text, before, after in cases:
            with self.subTest(text=text):
                self.assertEqual(after, OWNER._sqlite_line_state(text, before))

    def test_many_captured_markers_keep_native_scan_work_linear(self):
        payload = "captured SQL\n" + "COMMIT;\n" * 1000 + "done"
        source = captured_batch(1, payload)
        self.write(source)
        native_complete = sqlite3.complete_statement
        calls = 0
        scanned = 0

        def observe(text):
            nonlocal calls, scanned
            calls += 1
            scanned += len(text)
            return native_complete(text)

        with contextlib.closing(sqlite3.connect(":memory:")) as conn:
            conn.executescript(SCHEMA.read_text(encoding="utf-8"))
            with (
                patch.object(sqlite3, "complete_statement", observe),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                OWNER.exec_large_file(conn, self.path)
            self.assertEqual(
                payload, conn.execute("SELECT replacement FROM events_hotstring").fetchone()[0]
            )
        self.assertGreater(
            calls, 1000, "the actual SQLite lexer must observe the adversarial markers"
        )
        self.assertLessEqual(
            scanned, 6 * len(source) + 6 * calls, "candidate count cannot multiply prefix rescans"
        )

    def test_public_cli_refuses_malformed_complete_sql_without_replacement(self):
        self.assert_refused(
            (captured_batch(1, "retained") + "BEGIN;\nNOT VALID SQL;\nCOMMIT;\n").encode()
        )

    def test_public_cli_refuses_constraint_failure_instead_of_skipping_rows(self):
        invalid = (
            "BEGIN;\nINSERT INTO events_hotstring (device_id,id,ts,date,app,kind,trigger,replacement) "
            "VALUES ('device',1,'2026-07-18 09:00:00.000','2026-07-18','fixture','fired','x','second');\nCOMMIT;\n"
        )
        self.assert_refused((captured_batch(1, "first") + invalid).encode())

    def test_public_cli_refuses_torn_quoted_eof(self):
        self.assert_refused(
            (
                captured_batch(1, "retained")
                + "BEGIN;\nINSERT INTO events_hotstring VALUES ('torn\nCOMMIT;\nstill quoted"
            ).encode()
        )

    def test_public_cli_refuses_eof_inside_transaction(self):
        pending = captured_batch(2, "pending").removesuffix("COMMIT;\n")
        self.assert_refused((captured_batch(1, "retained") + pending).encode())

    def test_public_cli_rejects_invalid_utf8_without_rewriting_capture_bytes(self):
        self.assert_refused(captured_batch(1, "retained").encode() + b"-- invalid \xff\n")

    def test_public_cli_accepts_final_commit_without_lf_and_comment_only_tail(self):
        for suffix in ["", "\n-- odd ' quote comment", "\n/* closed block ' comment */\n"]:
            with self.subTest(tail=suffix):
                self.write(captured_batch(1, "exact").removesuffix("\n") + suffix)
                result = self.cli()
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual([(1, "exact")], read_rows(self.path))

    def test_public_cli_preserves_literal_crlf_and_first_ignored_copy(self):
        payload = "first\r\nCOMMIT;\r\né😀"
        self.write(captured_batch(1, payload) + captured_batch(1, "ignored duplicate"))
        result = self.cli()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual([(1, payload)], read_rows(self.path))

    def test_export_read_refusal_preserves_source_backup_and_owned_stage_cleanup(self):
        self.write(captured_batch(1, "retained"))
        source = self.path.read_bytes()
        previous_backup = b"prior independently retained backup"
        self.backup.write_bytes(previous_backup)
        load = OWNER.exec_large_file

        def load_then_deny_read(conn, path):
            load(conn, path)
            conn.set_authorizer(
                lambda action, table, *_: (
                    sqlite3.SQLITE_DENY
                    if action == sqlite3.SQLITE_READ and table == "events_hotstring"
                    else sqlite3.SQLITE_OK
                )
            )

        with (
            patch.object(OWNER, "exec_large_file", load_then_deny_read),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertFalse(OWNER.compact_device(self.path, SCHEMA))
        self.assertEqual(source, self.path.read_bytes())
        self.assertEqual(previous_backup, self.backup.read_bytes())
        self.assertFalse((self.path.parent / "_compact_work.db").exists())
        self.assertFalse(self.path.with_suffix(".compact.tmp").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
