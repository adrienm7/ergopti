# tools/compact_data_sql.py
#
# ==============================================================================
# MODULE: data.sql compaction tool
# DESCRIPTION:
# Rewrites every device's data.sql under a metrics directory as a compact
# snapshot — one SQL row per primary key instead of thousands of accumulated
# UPSERT deltas. Typical reduction: 10-50x.
#
# DESIGNED FOR LOW-RAM MACHINES (8 GB):
# - Reads data.sql in 2 MB text chunks; flushes at COMMIT boundaries via
#   executescript() (SQLite C parser — orders of magnitude faster than a
#   Python-side statement splitter).
# - Uses a file-based SQLite DB so pages spill to disk automatically.
# - Exports compact SQL in streaming batches of 500 rows.
#
# USAGE:
#   python compact_data_sql.py <metrics_dir>
#
# SAFETY:
# - Writes to .compact.tmp first, then renames atomically over data.sql.
# - Keeps data.sql.bak as a fallback before replacing.
# - Original is never modified until the rename succeeds.
# ==============================================================================

import sys
import re
import os
import sqlite3
import shutil
import time
from pathlib import Path

# Make tools/lib importable (repo root on sys.path) for the shared-tree SSOT.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.lib.paths import shared  # noqa: E402


# ============================================================
# ============================================================
# ======= 1/ Schema path resolution =======
# ============================================================
# ============================================================


def find_schema(metrics_dir: Path) -> Path | None:
    """Locate schema.sql relative to the metrics directory."""
    candidates = [
        shared("data", "db", "schema.sql"),
        metrics_dir.parent.parent.parent
        / "static"
        / "ergopti_plus"
        / "_shared"
        / "data"
        / "db"
        / "schema.sql",
    ]
    for p in candidates:
        if p.exists():
            return p
    return None


# ============================================================
# ============================================================
# ======= 2/ Memory-safe chunked SQL loader =======
# ============================================================
# ============================================================

# Carry retains the unexecuted transaction; complete physical lines are scanned
# once through SQLite's own lexer. Captured literals can contain COMMIT lines.
CHUNK_CHARS = 2 * 1024 * 1024
_COMMIT_LINE = re.compile(r"(?m)^[ \t]*COMMIT;[ \t]*(?:\r?\n|$)")
_LEXICAL_PREFIXES = ("", "'", '"', "`", "[", "/*")
_LEXICAL_CLOSERS = (";", "';", '";', "`;", "];", "*/;")


def _sqlite_line_state(text: str, state: int) -> int:
    """Recover SQLite's lexical state only at a physical line boundary.

    Canonical ledgers contain comments, PRAGMA, BEGIN, INSERT and COMMIT, never
    CREATE TRIGGER. Builders emit physical newlines only inside quoted values.
    Prefixes reopen the preceding quote/comment; native completeness probes
    identify its ending state without a second SQL tokenizer. A virtual final
    LF ends a line comment but never contributes to source offsets.
    """
    source = _LEXICAL_PREFIXES[state] + text
    for result, closer in enumerate(_LEXICAL_CLOSERS):
        if sqlite3.complete_statement(source + closer):
            return result
    raise ValueError("Ledger is outside the canonical SQL framing contract.")


def _scan_commit_lines(text: str, state: int) -> tuple[int, int]:
    """Return the native ending state and last trusted COMMIT character offset.

    Segments partition complete physical lines, so every source character enters
    at most six native probes, independent of the number of captured markers.
    """
    position = 0
    last_end = 0
    for match in _COMMIT_LINE.finditer(text):
        state = _sqlite_line_state(text[position : match.start()], state)
        if state == 0:
            last_end = match.end()
        # Include this candidate in the next probe even when it was quoted.
        position = match.start()
    rest = text[position:]
    state = _sqlite_line_state(rest if rest.endswith("\n") else rest + "\n", state)
    return state, last_end


def exec_large_file(conn: sqlite3.Connection, path: Path) -> None:
    """Stream canonical SQL, retaining every byte until native execution succeeds.

    Full transaction scripts reach executescript only at SQLite-qualified COMMIT
    lines. Invalid SQL and incomplete EOF transactions refuse compaction rather
    than exporting a partial image over the authoritative source.
    """
    carry = ""
    pending_line = ""
    state = 0
    read_chars = 0
    carry_start = 0
    n_commits = 0
    # Preserve captured CRLF exactly and reject malformed UTF-8 before replacing
    # a source; universal-newline or replacement decoding would alter its data.
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        while True:
            chunk = fh.read(CHUNK_CHARS)
            if not chunk:
                break
            carry += chunk
            pending_line += chunk
            read_chars += len(chunk)
            last_lf = chunk.rfind("\n")
            if last_lf < 0:
                continue
            complete = len(pending_line) - len(chunk) + last_lf + 1
            scan_start = read_chars - len(pending_line)
            state, last_end = _scan_commit_lines(pending_line[:complete], state)
            pending_line = pending_line[complete:]
            if last_end:
                consumed = scan_start + last_end - carry_start
                conn.executescript(carry[:consumed])
                if conn.in_transaction:
                    raise sqlite3.DatabaseError("Ledger batch did not close its transaction.")
                # No exception can authorize dropping unexecuted source bytes.
                carry = carry[consumed:]
                carry_start = scan_start + last_end
                n_commits += 1
                if n_commits % 10 == 0:
                    print(f"    ...{n_commits} batches flushed", flush=True)
    # SQLite accepts a final COMMIT without LF and comment-only tails. A torn
    # literal raises; a complete INSERT after BEGIN still requires COMMIT.
    if carry.strip():
        conn.executescript(carry)
    if conn.in_transaction:
        raise sqlite3.DatabaseError("Ledger ended inside an open transaction.")
    print(f"    {n_commits} batches loaded.", flush=True)


# ============================================================
# ============================================================
# ======= 3/ SQL value quoting =======
# ============================================================
# ============================================================


def quote_val(v) -> str:
    """Quote a Python value as a SQL literal.

    Args:
            v: Value to quote (int, float, str, or None).

    Returns:
            SQL-safe literal string.
    """
    if v is None:
        return "NULL"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


# ============================================================
# ============================================================
# ======= 4/ Streaming table dump =======
# ============================================================
# ============================================================

EXPORT_BATCH = 500


def dump_table(conn: sqlite3.Connection, fh, table: str, replace: bool) -> int:
    """Write all rows of `table` as INSERT statements into `fh`.

    Args:
            conn: SQLite connection with the loaded data.
            fh: Open file handle to write SQL into.
            table: Table name to export.
            replace: INSERT OR REPLACE (agg/ngram) vs INSERT OR IGNORE (events).

    Returns:
            Number of rows exported.
    """
    verb = "INSERT OR REPLACE" if replace else "INSERT OR IGNORE"
    # Optional historical tables may be absent. A refused SELECT on an existing
    # table is a real export failure, never an empty table to silently omit.
    if (
        conn.execute(
            "SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?", (table,)
        ).fetchone()
        is None
    ):
        return 0
    cur = conn.execute(f"SELECT * FROM {table} LIMIT 1")
    if cur.fetchone() is None:
        return 0
    cols = [d[0] for d in cur.description]
    col_list = ", ".join(cols)

    count = 0
    batch: list[str] = []
    cur = conn.execute(f"SELECT * FROM {table}")
    for row in cur:
        vals = ", ".join(quote_val(v) for v in row)
        batch.append(f"{verb} INTO {table} ({col_list}) VALUES ({vals});")
        count += 1
        if len(batch) >= EXPORT_BATCH:
            fh.write("\n".join(batch) + "\n")
            batch = []
    if batch:
        fh.write("\n".join(batch) + "\n")
    return count


# ============================================================
# ============================================================
# ======= 5/ Single-device compaction =======
# ============================================================
# ============================================================

EVENT_TABLES = [
    "devices",
    "events_typing",
    "events_app_switch",
    "events_window_switch",
    "events_shortcut",
    "events_system",
    "events_hotstring",
    "events_llm",
    "events_session",
    "events_mouse",
    "events_ergo",
    "events_window_topo",
]

AGG_TABLES = [
    "agg_app_day",
    "agg_app_day_buckets",
    "agg_app_day_burst",
    "agg_app_day_session",
    "agg_app_day_chars_class",
    "agg_app_day_errors",
    "agg_app_day_ergo",
    "agg_app_day_layouts",
    "agg_app_day_kc_hold",
    "agg_app_day_titles",
    "agg_app_day_hourly",
    "agg_app_day_hourly_min5",
    "agg_app_day_switches_to",
    "agg_system_day",
    "meta",
]

NGRAM_TABLES = [
    "ngram_chars",
    "ngram_bigrams",
    "ngram_trigrams",
    "ngram_quadgrams",
    "ngram_pentagrams",
    "ngram_hexagrams",
    "ngram_heptagrams",
    "ngram_words",
    "ngram_word_bigrams",
    "ngram_shortcuts",
    "ngram_shortcut_bigrams",
    "ngram_keycodes",
    "ngram_scancodes",
]


def compact_device(sql_path: Path, schema_path: Path) -> bool:
    """Compact a single device's data.sql.

    Args:
            sql_path: Path to the device's data.sql.
            schema_path: Path to schema.sql.

    Returns:
            True on success, False on failure (original untouched).
    """
    device_id = sql_path.parent.name
    size_mb = sql_path.stat().st_size / (1024 * 1024)
    print(f"\n[{device_id}]", flush=True)
    print(f"  Input:   {size_mb:.1f} MB", flush=True)
    t0 = time.time()

    tmp_db = sql_path.parent / "_compact_work.db"
    try:
        tmp_db.unlink(missing_ok=True)
    except Exception:
        pass

    conn = sqlite3.connect(str(tmp_db))
    conn.execute("PRAGMA journal_mode = OFF")
    conn.execute("PRAGMA synchronous = OFF")
    conn.execute("PRAGMA temp_store = FILE")
    # 64 MB page cache — safe on 8 GB RAM machines.
    conn.execute("PRAGMA cache_size = -65536")

    stage_path = None
    try:
        schema = schema_path.read_text(encoding="utf-8")
        conn.executescript(schema)

        print(f"  Phase 1/3: loading into SQLite...", flush=True)
        exec_large_file(conn, sql_path)
        t_load = time.time()
        print(f"  Phase 1/3: done in {t_load - t0:.1f}s", flush=True)

        row_count = conn.execute("SELECT COUNT(*) FROM agg_app_day").fetchone()[0]
        print(f"  agg_app_day rows: {row_count}", flush=True)

        print(f"  Phase 2/3: exporting compact SQL...", flush=True)
        tmp_sql = sql_path.with_suffix(".compact.tmp")
        total_rows = 0
        with open(tmp_sql, "w", encoding="utf-8", newline="") as fh:
            stage_path = tmp_sql
            fh.write(f"-- ergopti metrics -- device {device_id} -- schema_version 1\n")
            fh.write("-- This file is APPEND-ONLY. Do not edit by hand.\n")
            fh.write(
                f"-- Compacted by compact_data_sql.py on {time.strftime('%Y-%m-%d %H:%M:%S')}\n"
            )
            fh.write("PRAGMA foreign_keys = OFF;\n\n")
            fh.write("BEGIN TRANSACTION;\n")
            for tbl in EVENT_TABLES:
                n = dump_table(conn, fh, tbl, replace=False)
                if n:
                    print(f"    {tbl}: {n} rows", flush=True)
                    total_rows += n
            for tbl in AGG_TABLES + NGRAM_TABLES:
                n = dump_table(conn, fh, tbl, replace=True)
                if n:
                    print(f"    {tbl}: {n} rows", flush=True)
                    total_rows += n
            fh.write("COMMIT;\n")

        t_export = time.time()
        new_size_mb = tmp_sql.stat().st_size / (1024 * 1024)
        ratio = size_mb / max(new_size_mb, 0.01)
        print(f"  Phase 2/3: {total_rows} rows exported in {t_export - t_load:.1f}s", flush=True)
        print(
            f"  Size:    {size_mb:.1f} MB -> {new_size_mb:.1f} MB  ({ratio:.1f}x reduction)",
            flush=True,
        )

        print(f"  Phase 3/3: replacing data.sql...", flush=True)
        bak = sql_path.with_suffix(".sql.bak")
        shutil.copy2(sql_path, bak)
        os.replace(tmp_sql, sql_path)
        stage_path = None
        print(f"  Done. Backup kept at {bak.name}", flush=True)
        return True

    except Exception as e:
        import traceback

        print(f"  ERROR: {e}", flush=True)
        traceback.print_exc()
        return False
    finally:
        conn.close()
        if stage_path is not None:
            stage_path.unlink(missing_ok=True)
        try:
            tmp_db.unlink(missing_ok=True)
        except Exception:
            pass


# ============================================================
# ============================================================
# ======= 6/ Entry point =======
# ============================================================
# ============================================================


def main() -> None:
    """Run compaction on all devices under the given metrics directory."""
    if len(sys.argv) < 2:
        print("Usage: python compact_data_sql.py <metrics_dir>")
        sys.exit(1)

    metrics_dir = Path(sys.argv[1]).resolve()
    by_device = metrics_dir / "by_device"
    if not by_device.is_dir():
        print(f"ERROR: by_device/ not found under {metrics_dir}")
        sys.exit(1)

    schema_path = find_schema(metrics_dir)
    if not schema_path:
        print("ERROR: schema.sql not found.")
        sys.exit(1)
    print(f"Schema: {schema_path}", flush=True)

    devices = [d for d in by_device.iterdir() if d.is_dir() and (d / "data.sql").exists()]
    if not devices:
        print("No data.sql files found.")
        sys.exit(0)

    # Sort smallest first so we validate on the lightweight Mac device first.
    devices.sort(key=lambda d: (d / "data.sql").stat().st_size)
    print(f"Found {len(devices)} device(s).\n", flush=True)

    results = {}
    for dev in devices:
        results[dev.name] = compact_device(dev / "data.sql", schema_path)

    print("\n=== Summary ===", flush=True)
    for dev_id, ok in results.items():
        print(f"  {dev_id}: {'OK' if ok else 'FAILED'}", flush=True)
    if not all(results.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
