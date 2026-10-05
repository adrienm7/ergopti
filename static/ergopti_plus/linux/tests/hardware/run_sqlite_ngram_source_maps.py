#!/usr/bin/env python3
# tests/hardware/run_sqlite_ngram_source_maps.py
# ==============================================================================
# MODULE: Independent N-gram Source Map Snapshot Oracle
# DESCRIPTION:
# Reads actual native Writer snapshots through Python SQLite in readonly mode.
# Expected counters come from the supported software inputs, independently of
# the Linux Reader projection and the Writer's SQL composition.
# ==============================================================================
"""Independent readonly SQLite oracle; expected values come from fixture inputs."""

import json, sqlite3, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
first = sqlite3.connect(f"file:{root / 'first.sqlite'}?mode=ro", uri=True)
second = sqlite3.connect(f"file:{root / 'second.sqlite'}?mode=ro", uri=True)
for db in (first, second):
    db.execute("PRAGMA query_only=ON")
    assert db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
checks = failures = 0
results = []


def check(name, actual, expected):
    global checks, failures
    checks += 1
    ok = actual == expected
    failures += not ok
    results.append(dict(name=name, actual=actual, expected=expected, ok=ok))
    print(("PASS " if ok else "FAIL ") + name + " actual=" + repr(actual))


def row(db, app, extra=""):
    rows = db.execute(
        "SELECT c,td,cd,e,esrc_json FROM ngram_chars WHERE app=? AND token='x' " + extra, (app,)
    ).fetchall()
    assert len(rows) == 1, (app, rows)
    return rows[0][:4], json.loads(rows[0][4])


a, b = row(first, "owned-public")
check("first public batch native snapshot", (a, b), ((2, 0, 0, 0), {"extension": 2}))
a, b = row(second, "owned-public")
check(
    "second public batch preserves additive sources",
    (a, b),
    ((4, 0, 0, 0), {"extension": 3, "paste": 1}),
)
raw = [
    json.loads(r[0])
    for r in second.execute(
        "SELECT events_json FROM events_typing WHERE app='owned-public' ORDER BY id"
    )
]
check(
    "raw source metadata independent input conservation",
    [[(e[0], e[2]["st"], e[2]["s"]) for e in batch] for batch in raw],
    [[("x", "extension", 1), ("x", "extension", 1)], [("x", "extension", 1), ("x", "paste", 1)]],
)
a, b = row(second, "owned-recognized")
check(
    "recognized public map remains additive",
    (a, b),
    ((6, 0, 0, 0), {"hotstring": 2, "llm": 2, "other": 2}),
)
a, b = row(second, "owned-manual")
check(
    "manual scalar and synthetic absence",
    (a, b.get("none"), sum(b.values())),
    ((2, 0, 0, 0), None, 0),
)
a, b = row(second, "owned-direct", "AND device_id='owned-direct' AND date='2000-01-01'")
check("unrelated exact scalar columns", a, (11, 20, 5, 3))
check(
    "native direct arbitrary and known source merge",
    b,
    {"extension": 3, "paste": 3, "hotstring": 1, "llm": 1, "other": 2},
)
controls = second.execute(
    "SELECT device_id,date,c,json_extract(esrc_json,'$.extension') FROM ngram_chars WHERE app='owned-direct' AND (device_id='owned-second' OR date='1999-01-01') ORDER BY date"
).fetchall()
check(
    "independent other device and historical date",
    controls,
    [("owned-direct", "1999-01-01", 2, 1), ("owned-second", "2000-01-01", 5, 4)],
)
a, b = row(second, "owned-string-input")
check("incoming strings still rejected", b, {})
a, b = row(second, "owned-legacy")
check(
    "stored recognized strings preserve numeric addition",
    [b.get(k) for k in ["hotstring", "llm", "other"]],
    [3, 5, 7],
)
check("stored extra string retains numeric addition", b.get("extension"), 11)
a, b = row(second, "owned-literal")
check("quoted Unicode source is literal key", b, {"addon.é'\"": 4})
assert checks == 12
(root / "independent-oracle.json").write_text(
    json.dumps(
        dict(
            sqlite=sqlite3.sqlite_version,
            readonly=True,
            checks=checks,
            failures=failures,
            results=results,
        ),
        indent=2,
        ensure_ascii=False,
    )
    + "\n"
)
print(f"Independent readonly SQLite oracle: {checks} checks, {failures} failures")
sys.exit(1 if failures else 0)
