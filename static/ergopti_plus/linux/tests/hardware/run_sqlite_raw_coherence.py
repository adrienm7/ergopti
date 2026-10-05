#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_sqlite_raw_coherence.py
# ==============================================================================
# MODULE: Native SQLite Raw Batch Coherence Regression (Linux)
# DESCRIPTION:
# One actual Lua runtime produces SQLite snapshots in an owned temporary folder.
# Twelve independent native SQLite checks preserve the accepted batch's values,
# IDs, local day and observed UTC timestamps. No clock/SQL/provider replacement
# or physical-input claim; software event timestamps remain explicit input data.
# ==============================================================================

import argparse
import json
import math
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile


def verify_snapshots(result):
    checks, failures = 0, 0

    def open_phase(phase):
        return sqlite3.connect(
            Path(result["root"], phase + ".sqlite").as_uri() + "?mode=ro", uri=True
        )

    refused = open_phase("refused")
    accepted = open_phase("accepted")
    repeat = open_phase("repeat")

    def check(name, body):
        nonlocal checks, failures
        checks += 1
        try:
            body()
            print("PASS", name)
        except Exception as error:
            failures += 1
            print("FAIL", name, str(error))

    def same(actual, expected):
        assert actual == expected, (actual, expected)

    def rows(db):
        return db.execute(
            "SELECT id,app,wpm,text,events_json,date,ts FROM events_typing ORDER BY id"
        ).fetchall()

    raw = rows(accepted)
    check(
        "actual distinct local/UTC days with untouched clocks",
        lambda: same(
            (result["local_day"] != result["utc_day"], result["clock_unchanged"]), (True, True)
        ),
    )
    check(
        "public refusal retains all four software keys pending",
        lambda: same(result["pending_refused"], 4),
    )
    check(
        "statement refusal has zero durable raw rows",
        lambda: same(refused.execute("SELECT COUNT(*) FROM events_typing").fetchone()[0], 0),
    )
    check(
        "separate refused ID reservation stays acknowledged",
        lambda: same(
            refused.execute("SELECT value FROM meta WHERE key='linux_next_event_id'").fetchone()[0],
            "3",
        ),
    )
    check("healthy public retry clears pending keys", lambda: same(result["pending_accepted"], 0))
    check("retry accepts exactly two per-app raw batches", lambda: same(len(raw), 2))
    check(
        "retry uses only independently reserved accepted IDs",
        lambda: same([r[0] for r in raw], [3, 4]),
    )
    check(
        "raw event quantity conserves four supplied keys",
        lambda: same(sum((len(json.loads(r[4])) for r in raw)), 4),
    )

    def rate_and_values():
        expected = {"owned-rate-a": ("ab", ["a", "b"]), "owned-rate-b": ("cd", ["c", "d"])}
        assert set((r[1] for r in raw)) == set(expected)
        for row in raw:
            text, chars = expected[row[1]]
            events = json.loads(row[4])
            assert row[3] == text
            assert [e[0] for e in events] == chars and [e[1] for e in events] == [0, 1300]
            assert math.isclose(row[2], 2 / 5 * 60000 / 1300, rel_tol=0, abs_tol=1e-12), (
                row[2],
                2 / 5 * 60000 / 1300,
            )

    check(
        "independent native values preserve fractional WPM and exact event/text bytes",
        rate_and_values,
    )

    def date_and_ts():
        for row in raw:
            assert row[5] == result["local_day"]
            assert (
                result["bounds"]["accepted_before"] <= row[6] <= result["bounds"]["accepted_after"]
            )

    check("accepted retry groups local date with actually observed UTC instant", date_and_ts)

    def conservation():
        count = accepted.execute("SELECT SUM(c) FROM ngram_chars").fetchone()[0]
        assert count == 4
        assert count == sum((len(json.loads(r[4])) for r in raw))

    check("derived/raw counts conserve same accepted batch", conservation)

    def unchanged():
        assert rows(repeat) == raw
        assert (
            repeat.execute("SELECT * FROM ngram_chars ORDER BY device_id,date,app,token").fetchall()
            == accepted.execute(
                "SELECT * FROM ngram_chars ORDER BY device_id,date,app,token"
            ).fetchall()
        )

    check("second flush preserves accepted raw and derived rows", unchanged)
    for db in [refused, accepted, repeat]:
        db.close()
    return checks, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="luajit", help="One actual Lua runtime to execute")
    options = parser.parse_args()
    driver = Path(__file__).resolve().parents[2]
    producer = Path(__file__).with_suffix(".lua").resolve()
    version = subprocess.run([options.lua, "-v"], check=True, capture_output=True, text=True)
    sqlite_version = subprocess.run(
        ["sqlite3", "--version"], check=True, capture_output=True, text=True
    )
    print("Lua producer runtime:", (version.stdout + version.stderr).strip())
    print("Production SQLite CLI:", sqlite_version.stdout.strip())
    print("Independent Python native SQLite:", sqlite3.sqlite_version)
    with tempfile.TemporaryDirectory(prefix="ergopti-sqlite-raw-coherence-") as folder:
        root = str(Path(folder) / "database")
        environment = os.environ.copy()
        environment["TZ"] = "OWN-24"
        environment["OWN_RAW_COHERENCE_ROOT"] = root
        process = subprocess.run(
            [options.lua, str(producer)],
            cwd=driver,
            env=environment,
            capture_output=True,
            text=True,
        )
        print("Lua producer exit:", process.returncode)
        if process.returncode:
            print(process.stdout, end="")
            print(process.stderr, end="")
            process.check_returncode()
        result = json.loads(process.stdout.splitlines()[-1])
        if result["root"] != root:
            raise RuntimeError("producer returned a database outside its owned root")
        print("Actual calendar days:", result["local_day"], "local;", result["utc_day"], "UTC")
        checks, failures = verify_snapshots(result)
    assert checks == 12, "native raw coherence must execute all twelve checks"
    print("Native raw WPM/day coherence oracle:", checks, "checks,", failures, "failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
