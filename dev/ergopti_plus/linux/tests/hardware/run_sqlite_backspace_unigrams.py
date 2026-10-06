# tests/hardware/run_sqlite_backspace_unigrams.py

# ==============================================================================
# MODULE: Independent Native Backspace Unigram Oracle
# DESCRIPTION:
# Reads the actual native fixture PROFILE with readonly SQLite and checks raw,
# stored and public correction tuples without physical keyboard claims.
# ==============================================================================

import json
import sqlite3
import sys
from pathlib import Path

profile = Path(sys.argv[1])
o = json.loads((profile / "observation.json").read_text())
db = sqlite3.connect((profile / "readonly.sqlite").as_uri() + "?mode=ro", uri=True)
db.execute("PRAGMA query_only=ON")
print(
    f"RUNTIME Python {sys.version.split()[0]}; SQLite {sqlite3.sqlite_version}; mode=ro/query_only=ON"
)
checks = failures = 0


def check(name, fn):
    global checks, failures
    checks += 1
    try:
        fn()
        print("PASS " + name)
    except Exception as exc:
        failures += 1
        print("FAIL " + name + ": " + str(exc))


def equal(actual, expected):
    assert actual == expected, (actual, expected)


check(
    "independent native store integrity",
    lambda: equal(db.execute("PRAGMA integrity_check").fetchall(), [("ok",)]),
)


def raw_sources():
    counts = {"none": 0, "hotstring": 0, "llm": 0}
    for (events,) in db.execute("SELECT events_json FROM events_typing"):
        for event in json.loads(events):
            if event[0] != "[BS]":
                continue
            meta = event[2]
            if isinstance(meta, dict):
                source = meta.get("st", "none")
            else:
                assert meta == []
                source = "none"
            counts[source] += 1
    equal(counts, {"none": 1, "hotstring": 2, "llm": 1})


check("independent positive raw BS floor and canonical metadata", raw_sources)
check(
    "independent persisted manual and synthetic BS tuples",
    lambda: equal(
        db.execute(
            "SELECT app,c,td,cd,e,COALESCE(json_extract(esrc_json,'$.hotstring'),0),COALESCE(json_extract(esrc_json,'$.llm'),0) FROM ngram_chars WHERE token='[BS]' ORDER BY app"
        ).fetchall(),
        [
            ("hotstring", 2, 0, 0, 0, 2, 0),
            ("llm", 1, 0, 0, 0, 0, 1),
            ("manual", 1, o["manual_delay"], 1, 0, 0, 0),
        ],
    ),
)
check(
    "independent literal software spelling remains four codepoints",
    lambda: equal(
        db.execute(
            "SELECT token,c,json_extract(esrc_json,'$.other') FROM ngram_chars WHERE app='literal' ORDER BY token"
        ).fetchall(),
        [("B", 1, 1), ("S", 1, 1), ("[", 1, 1), ("]", 1, 1)],
    ),
)
check(
    "independent ordinary scalar characters and source gains unchanged",
    lambda: equal(
        db.execute(
            "SELECT SUM(chars),SUM(hs_chars),SUM(llm_chars),SUM(hs_input_chars),SUM(llm_input_chars) FROM agg_app_day"
        ).fetchone(),
        (1, 2, 2, 2, 1),
    ),
)
check(
    "independent manual errors exclude synthetic correction counts",
    lambda: equal(db.execute("SELECT SUM(bs_total) FROM agg_app_day_errors").fetchone(), (1,)),
)


def public_markers():
    for app, expected in {"manual": (1, 0, 0), "hotstring": (2, 2, 0), "llm": (1, 0, 1)}.items():
        entry = o["after"]["today"][app]["c"]["[BS]"]
        equal((entry["c"], entry["hs"], entry["llm"]), expected)
        equal((entry["e"], entry["o"]), (0, 0))
        assert all(isinstance(entry[k], (int, float)) for k in ("c", "hs", "llm", "e", "o"))


check("independent public postflush BS tuples agree with literal raw source counts", public_markers)
check(
    "independent repeated flush keeps four raw groups and thirteen events",
    lambda: equal(
        db.execute(
            "SELECT COUNT(*),SUM(json_array_length(events_json)) FROM events_typing"
        ).fetchone(),
        (4, 13),
    ),
)
db.close()
assert checks == 8
print(f"Readonly canonical backspace oracle: {checks} checks, {failures} failures")
sys.exit(0 if failures == 0 else 1)
