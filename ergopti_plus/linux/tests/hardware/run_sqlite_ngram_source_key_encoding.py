# tests/hardware/run_sqlite_ngram_source_key_encoding.py
# ==============================================================================
# MODULE: Native Ngram Source Key Independent SQLite Oracle (Linux)
# DESCRIPTION:
# Compare literal labels against real stored JSON, raw metadata and SQLite keys.
# ==============================================================================

"""Native SQLite source-label regression, one actual Lua child."""

import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

fixture = Path(__file__).resolve().parent
runtime = sys.argv[1]
checks = failures = 0


def check(name, fn):
    global checks, failures
    checks += 1
    try:
        fn()
    except Exception as exc:
        failures += 1
        print("FAIL", name, repr(exc))
    else:
        print("PASS", name)


def eq(actual, expected):
    assert actual == expected, (actual, expected)


with tempfile.TemporaryDirectory(prefix="source-label-regression-") as owned:
    env = os.environ.copy()
    env["OWN_SOURCE_ESCAPE_ROOT"] = str(Path(owned) / "producer")
    proc = subprocess.run(
        [runtime, str(fixture / "run_sqlite_ngram_source_key_encoding.lua")],
        cwd=fixture.parent.parent,
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
    print("RUNTIME", result["runtime"], "LIBUV", result["libuv"], "CLOCK", result["clock"])
    print("SQLITE production", result["sqlite"], "independent", sqlite3.sqlite_version)
    conn = sqlite3.connect(
        (Path(result["root"]) / "accepted.sqlite").as_uri() + "?mode=ro", uri=True
    )
    conn.execute("PRAGMA query_only=ON")
    labels = {
        "ordinary": "addon",
        "quote": "addon.é'\"",
        "escaped_tab": "addon\\t",
        "invalid_escape": "addon\\q",
        "newline": "addon\nline",
        "tab": "addon\tfield",
        "carriage_return": "addon\rfield",
    }
    eq(result["labels"], labels)
    for name, label in labels.items():
        app = "owned-" + name
        raw = conn.execute("SELECT events_json FROM events_typing WHERE app=?", (app,)).fetchone()[
            0
        ]
        stored = conn.execute(
            "SELECT c,td,cd,e,esrc_json,json_valid(esrc_json),hex(esrc_json) "
            "FROM ngram_chars WHERE app=? AND token='x'",
            (app,),
        ).fetchone()
        print("SQL_BYTES", name, stored[5], stored[6])

        def raw_check():
            events = json.loads(raw)
            eq(len(events), 2)
            eq([event[0] for event in events], ["x", "x"])
            eq([(event[2]["s"], event[2]["st"]) for event in events], [(1, label), (1, label)])
            eq(stored[:4], (2, 0, 0, 0))

        check(name + " actual raw metadata and scalar counts remain healthy", raw_check)

        def source_check():
            eq(stored[5], 1)
            eq(json.loads(stored[4]), {label: 2})
            # Native json_each exposes the same exact literal key and count.
            eq(
                conn.execute("SELECT key,value FROM json_each(?)", (stored[4],)).fetchall(),
                [(label, 2)],
            )

        check(name + " admitted label remains one valid literal JSON source key", source_check)

    def manual_check():
        stored = conn.execute(
            "SELECT c,esrc_json FROM ngram_chars WHERE app='owned-manual' AND token='x'"
        ).fetchone()
        eq(stored[0], 1)
        eq(json.loads(stored[1]), {})

    check("manual input remains free of synthetic attribution", manual_check)
    conn.close()

assert checks == 15, "all fifteen actual native source-label subjects must execute"
print(f"Native public source key encoding: {checks} checks, {failures} failures")
raise SystemExit(0 if failures == 0 else 1)
