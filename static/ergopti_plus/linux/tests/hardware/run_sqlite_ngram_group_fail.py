# tests/hardware/run_sqlite_ngram_group_fail.py
# ==============================================================================
# MODULE: Native Ngram Group Independent SQLite Oracle (Linux)
# DESCRIPTION:
# Check actual public Writer group refusal and retry using readonly SQLite snapshots.
# ==============================================================================

import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

checks = failures = 0


def eq(actual, expected):
    assert actual == expected, (actual, expected)


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


def read_snapshot(root, name, app):
    db = sqlite3.connect((Path(root) / (name + ".sqlite")).as_uri() + "?mode=ro", uri=True)
    db.execute("PRAGMA query_only=ON")
    rows = db.execute(
        "SELECT token,c,td,cd,e,esrc_json FROM ngram_chars WHERE app=? ORDER BY token", (app,)
    ).fetchall()
    rows = [tuple(row[:5]) + (json.loads(row[5]),) for row in rows]
    effects = db.execute(
        "SELECT app,token FROM owned_trigger_effect WHERE app=? ORDER BY rowid", (app,)
    ).fetchall()
    db.close()
    return rows, effects


before = [("alpha", 10, 100, 5, 3, {"addon": 4}), ("beta", 20, 200, 6, 4, {"addon": 5})]
after = [
    ("alpha", 13, 120, 7, 4, {"addon": 6, "hotstring": 1}),
    ("beta", 25, 240, 9, 6, {"addon": 8, "llm": 2}),
]
healthy = [
    ("alpha", 3, 20, 2, 1, {"addon": 2, "hotstring": 1}),
    ("beta", 5, 40, 3, 2, {"addon": 3, "llm": 2}),
]
with tempfile.TemporaryDirectory(prefix="ngram-fail-audit-") as owned:
    here = Path(__file__).resolve().parent
    env = os.environ.copy()
    env["OWN_NGRAM_FAIL_ROOT"] = str(Path(owned) / "producer")
    proc = subprocess.run(
        [sys.argv[1], str(here / "run_sqlite_ngram_group_fail.lua")],
        cwd=here.parent.parent,
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
    root = result["root"]
    print(
        "RUNTIME",
        result["runtime"],
        "LIBUV",
        result["libuv"],
        "SQLITE production",
        result["sqlite"],
        "independent",
        sqlite3.sqlite_version,
        "ORDER",
        result["order"],
    )
    print("NATIVE_DIAGNOSTICS", proc.stdout.strip().splitlines()[:-1])
    for app in ("first", "last"):
        refused = read_snapshot(root, app + "-refused", app)
        retry = read_snapshot(root, app + "-retry", app)
        print("ACTUAL", app, "REFUSED", refused, "RETRY", retry, "RECEIPT", result["receipts"][app])
        check(app + " FAIL returns refusal", lambda: eq(result["receipts"][app]["accepted"], False))
        check(
            app + " FAIL preserves preexisting group and rolls back trigger effects",
            lambda: eq(refused, (before, [])),
        )
        check(app + " healthy retry credits group exactly once", lambda: eq(retry, (after, [])))
    check(
        "ABORT refusal is atomic and retry healthy",
        lambda: eq(
            (
                result["receipts"]["abort"]["accepted"],
                read_snapshot(root, "abort-refused", "abort"),
                read_snapshot(root, "abort-retry", "abort"),
            ),
            (False, (before, []), (after, [])),
        ),
    )
    check(
        "untriggered multirow group retains scalars and known/arbitrary sources",
        lambda: eq(
            (result["healthy"], read_snapshot(root, "healthy", "healthy")), (True, (healthy, []))
        ),
    )
assert checks == 8
print(f"Writer ngram FAIL diagnostic: {checks} checks, {failures} failures")
raise SystemExit(1 if failures else 0)
