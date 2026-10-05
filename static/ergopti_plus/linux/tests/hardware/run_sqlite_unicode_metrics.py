# tests/hardware/run_sqlite_unicode_metrics.py
# =============================================================================
# MODULE: Native Unicode Metrics Independent SQLite Oracle (Linux)
# DESCRIPTION:
# Validate actual public software codepoint ingestion and canonical class counts.
# =============================================================================

"""Independent literal SQLite character-length and canonical category oracle."""

import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

p = Path(__file__).resolve().parent
runtime = sys.argv[1]
checks = failures = 0


def check(name, test):
    global checks, failures
    checks += 1
    try:
        test()
    except Exception as exc:
        failures += 1
        print("FAIL", name, repr(exc))
    else:
        print("PASS", name)


def eq(actual, expected):
    assert actual == expected, (actual, expected)


with tempfile.TemporaryDirectory(prefix="metrics-unicode-") as owned:
    env = os.environ.copy()
    env["OWN_METRICS_UNICODE_ROOT"] = str(Path(owned) / "producer")
    proc = subprocess.run(
        [runtime, str(p / "run_sqlite_unicode_metrics.lua")],
        cwd=p.parent.parent,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    print("PRODUCER", proc.returncode)
    if proc.returncode:
        print(proc.stdout, proc.stderr)
        raise SystemExit(proc.returncode)
    result = json.loads(proc.stdout.strip().splitlines()[-1])
    conn = sqlite3.connect(
        (Path(result["root"]) / "accepted.sqlite").as_uri() + "?mode=ro", uri=True
    )
    # Expected class order: letter, digit, punctuation, space, other.
    # Existing canonical coarse shared policy is the oracle, not full Unicode
    # general-category or grapheme segmentation. Combining U+0301 is a letter
    # under that policy; Han and emoji are other, NBSP/NNBSP are explicit spaces.
    cases = {
        "ascii": ("A1! \n", 5, (1, 1, 1, 2, 0)),
        "accent": ("éĀ", 2, (2, 0, 0, 0, 0)),
        "han": ("中", 1, (0, 0, 0, 0, 1)),
        "emoji": ("🙂", 1, (0, 0, 0, 0, 1)),
        "spaces": ("\u00a0\u202f\n", 3, (0, 0, 0, 3, 0)),
        "combining": ("e\u0301", 2, (2, 0, 0, 0, 0)),
    }
    cells = next(iter(result["manifest"].values()))
    for name, (text, length, classes) in cases.items():
        app = "manual-" + name
        row = conn.execute(
            "SELECT text,length(text),events_json FROM events_typing WHERE app=?", (app,)
        ).fetchone()

        def raw_check():
            eq(row[:2], (text, length))
            events = json.loads(row[2])
            eq(len(events), length)
            eq("".join(e[0] for e in events), text)
            eq(cells[app]["chars"], length)

        check(name + " exact native Unicode codepoint lengths/raw/Reader", raw_check)
        actual = conn.execute(
            "SELECT letter,digit,punct,space,other FROM agg_app_day_chars_class WHERE app=?", (app,)
        ).fetchone()
        expected_projection = dict(
            zip(("char_letter", "char_digit", "char_punct", "char_space", "char_other"), classes)
        )

        def class_check():
            eq(actual, classes)
            for field, value in expected_projection.items():
                eq(cells[app][field], value)

        check(name + " canonical class counts/native SQL/Reader", class_check)
    for app, text, length in [
        ("synthetic-ascii", "abc", 3),
        ("synthetic-unicode", "Aé中🙂e\u0301\n", 7),
    ]:

        def synthetic_check():
            row = conn.execute(
                "SELECT events_json FROM events_typing WHERE app=?", (app,)
            ).fetchone()
            events = json.loads(row[0])
            eq(len(events), length)
            joined = "".join(e[0] for e in events)
            eq(joined, text)
            eq(conn.execute("SELECT length(?)", (joined,)).fetchone()[0], length)
            eq(
                conn.execute(
                    "SELECT llm_chars,llm_triggers,chars FROM agg_app_day WHERE app=?", (app,)
                ).fetchone(),
                (length, 1, 0),
            )
            eq(
                conn.execute(
                    "SELECT letter,digit,punct,space,other FROM agg_app_day_chars_class "
                    "WHERE app=?",
                    (app,),
                ).fetchone(),
                (0, 0, 0, 0, 0),
            )
            eq(cells[app]["llm_chars"], length)
            eq(result["public_manifest"], result["manifest"])

        check(
            app + " codepoint counts/source counters/absence of manual categories", synthetic_check
        )
    assert checks == 14, "all fourteen native Unicode subjects must execute"
    print(
        json.dumps(
            {
                "checks": checks,
                "failures": failures,
                "runtime": result["runtime"],
                "libuv": result["libuv"],
                "oracle_sqlite": sqlite3.sqlite_version,
            }
        )
    )
    conn.close()
raise SystemExit(1 if failures else 0)
