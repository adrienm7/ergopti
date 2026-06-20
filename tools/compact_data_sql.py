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
		metrics_dir.parent.parent.parent / "static" / "ergopti_plus" / "_shared" / "data" / "db" / "schema.sql",
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

# 2 MB text chunks — two of these + carry stays well under 10 MB peak.
CHUNK_CHARS = 2 * 1024 * 1024


def exec_large_file(conn: sqlite3.Connection, path: Path) -> None:
	"""Stream a multi-GB SQL file into `conn` with bounded RAM usage.

	Flushes at every COMMIT boundary via executescript() which delegates
	all statement parsing to SQLite's C engine — far faster than a
	Python-side splitter.

	Args:
		conn: Open SQLite connection.
		path: Path to the .sql file to load.
	"""
	carry = ""
	n_commits = 0
	with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
		while True:
			chunk = fh.read(CHUNK_CHARS)
			if not chunk:
				break
			carry += chunk
			# Find the last complete COMMIT in the carry buffer.
			last_end = -1
			pos = 0
			while True:
				idx = carry.find("COMMIT;\n", pos)
				if idx == -1:
					break
				last_end = idx + len("COMMIT;\n")
				pos = last_end
			if last_end > 0:
				try:
					conn.executescript(carry[:last_end])
				except sqlite3.Error as e:
					if "UNIQUE constraint" not in str(e):
						print(f"    [warn] {e}")
				n_commits += 1
				carry = carry[last_end:]
				if n_commits % 10 == 0:
					print(f"    ...{n_commits} batches flushed", flush=True)
	# Flush any remaining carry.
	if carry.strip():
		try:
			conn.executescript(carry)
		except sqlite3.Error as e:
			if "UNIQUE constraint" not in str(e):
				print(f"    [warn] {e}")
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
	try:
		cur = conn.execute(f"SELECT * FROM {table} LIMIT 1")
	except sqlite3.OperationalError:
		return 0
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
	"events_typing", "events_app_switch", "events_window_switch",
	"events_shortcut", "events_system", "events_hotstring", "events_llm",
	"events_session", "events_mouse", "events_ergo", "events_window_topo",
]

AGG_TABLES = [
	"agg_app_day", "agg_app_day_buckets", "agg_app_day_burst",
	"agg_app_day_session", "agg_app_day_chars_class", "agg_app_day_errors",
	"agg_app_day_ergo", "agg_app_day_layouts", "agg_app_day_kc_hold",
	"agg_app_day_titles", "agg_app_day_hourly", "agg_app_day_hourly_min5",
	"agg_app_day_switches_to", "agg_system_day",
	"meta",
]

NGRAM_TABLES = [
	"ngram_chars", "ngram_bigrams", "ngram_trigrams", "ngram_quadgrams",
	"ngram_pentagrams", "ngram_hexagrams", "ngram_heptagrams",
	"ngram_words", "ngram_word_bigrams",
	"ngram_shortcuts", "ngram_shortcut_bigrams",
	"ngram_keycodes", "ngram_scancodes",
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
		with open(tmp_sql, "w", encoding="utf-8") as fh:
			fh.write(f"-- ergopti metrics -- device {device_id} -- schema_version 1\n")
			fh.write("-- This file is APPEND-ONLY. Do not edit by hand.\n")
			fh.write(f"-- Compacted by compact_data_sql.py on {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
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
		print(f"  Size:    {size_mb:.1f} MB -> {new_size_mb:.1f} MB  ({ratio:.1f}x reduction)", flush=True)

		print(f"  Phase 3/3: replacing data.sql...", flush=True)
		bak = sql_path.with_suffix(".sql.bak")
		shutil.copy2(sql_path, bak)
		os.replace(tmp_sql, sql_path)
		print(f"  Done. Backup kept at {bak.name}", flush=True)
		return True

	except Exception as e:
		import traceback
		print(f"  ERROR: {e}", flush=True)
		traceback.print_exc()
		return False
	finally:
		conn.close()
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


if __name__ == "__main__":
	main()
