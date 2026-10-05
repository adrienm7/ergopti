# tests/hardware/run_sqlite_ngram_collector_sources.py
# =============================================================================
# MODULE: Native Ngram Collector Independent SQLite Oracle (Linux)
# DESCRIPTION:
# Check genuine public software source ingestion with independent literal SQL.
# =============================================================================

"""One actual Lua runtime invocation and nine independent behavioral subjects."""

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


def projection(item):
    eq(tuple(item[field] for field in ("c", "hs", "llm", "o")), (11, 1, 2, 6))


with tempfile.TemporaryDirectory(prefix="ngram-collector-") as owned:
    env = os.environ.copy()
    env["OWN_NGRAM_COLLECTOR_ROOT"] = str(Path(owned) / "producer")
    proc = subprocess.run(
        [runtime, str(fixture / "run_sqlite_ngram_collector_sources.lua")],
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
    print("RUNTIME", result["runtime"], "LIBUV", result["libuv"])
    print("SQLITE production", result["sqlite"], "independent", sqlite3.sqlite_version)
    with sqlite3.connect(
        (Path(result["root"]) / "accepted.sqlite").as_uri() + "?mode=ro", uri=True
    ) as conn:

        def raw_tags():
            raw = conn.execute(
                "SELECT events_json FROM events_typing WHERE app='owned-collector'"
            ).fetchone()
            events = json.loads(raw[0])
            eq(len(events), 11)
            eq("".join(event[0] for event in events), "xxxxxxxxxxx")
            tags = {}
            for event in events:
                if len(event) > 2 and isinstance(event[2], dict) and event[2].get("s") == 1:
                    tag = event[2]["st"]
                    tags[tag] = tags.get(tag, 0) + 1
                else:
                    eq(event[2] if len(event) > 2 else [], [])
                    tags["manual"] = tags.get("manual", 0) + 1
            eq(
                tags,
                {
                    "manual": 2,
                    "case-transform": 3,
                    "owned-extension": 2,
                    "llm": 2,
                    "other": 1,
                    "hotstring": 1,
                },
            )

        check("public collector persists exact software source metadata", raw_tags)

        def stored_sources():
            row = conn.execute(
                "SELECT c,esrc_json FROM ngram_chars WHERE app='owned-collector' AND token='x'"
            ).fetchone()
            eq(row[0], 11)
            eq(
                json.loads(row[1]),
                {"case-transform": 3, "owned-extension": 2, "llm": 2, "other": 1, "hotstring": 1},
            )
            counts = conn.execute(
                "SELECT SUM(CASE WHEN j.key='hotstring' THEN j.value ELSE 0 END),"
                "SUM(CASE WHEN j.key='llm' THEN j.value ELSE 0 END),"
                "SUM(CASE WHEN j.key NOT IN ('hotstring','llm','none') "
                "THEN j.value ELSE 0 END) "
                "FROM ngram_chars AS n,json_each(n.esrc_json) AS j "
                "WHERE n.app='owned-collector' AND n.token='x'"
            ).fetchone()
            eq(counts, (1, 2, 6))
            print("SQL_ORACLE collector", row[0], *counts)

        check("native literal SQL conserves every admitted source count", stored_sources)
        check(
            "public Reader stored range includes both extra source labels",
            lambda: projection(result["reader"]["c"]["x"]),
        )
        check(
            "public Reader split-today includes both extra source labels",
            lambda: projection(result["split"]["today"]["owned-collector"]["c"]["x"]),
        )
        check(
            "public keylogger range after flush matches independent SQL",
            lambda: projection(result["public_range"]["today"]["owned-collector"]["c"]["x"]),
        )
        check(
            "public dashboard prefetch after flush matches independent SQL",
            lambda: projection(
                result["dashboard"]["_prefetch_data"]["today"]["owned-collector"]["c"]["x"]
            ),
        )

        def healthy_counters():
            eq(
                conn.execute(
                    "SELECT chars,hs_chars,hs_triggers,llm_chars,llm_triggers "
                    "FROM agg_app_day WHERE app='owned-collector'"
                ).fetchone(),
                (2, 1, 1, 2, 1),
            )
            eq(
                conn.execute(
                    "SELECT letter,digit,punct,space,other "
                    "FROM agg_app_day_chars_class WHERE app='owned-collector'"
                ).fetchone(),
                (2, 0, 0, 0, 0),
            )

        check("manual counts and recognized synthetic counters stay healthy", healthy_counters)

        def healthy_filters():
            eq(result["filtered"]["c"], {})
            eq(result["excluded"]["c"], {})
            eq(result["reader"]["w"], {})
            eq(
                conn.execute(
                    "SELECT COUNT(*) FROM ngram_words WHERE app='owned-collector'"
                ).fetchone()[0],
                0,
            )

        check("filters and collector synthetic word exclusions remain healthy", healthy_filters)

        def word_family():
            row = conn.execute(
                "SELECT c,(SELECT SUM(value) FROM json_each(esrc_json) "
                "WHERE key NOT IN ('hotstring','llm','none')) "
                "FROM ngram_words WHERE app='owned-word' AND token='owned'"
            ).fetchone()
            eq(row, (4, 2))
            for payload in [
                result["words"]["w"],
                result["split_words"]["today"]["owned-word"]["w"],
            ]:
                eq(
                    tuple(payload["owned"][field] for field in ("c", "hs", "llm", "o")),
                    (4, 1, 1, 2),
                )

        check("same Reader helper admits extra source labels in word-family rows", word_family)

assert checks == 9, "all nine native public collector and Reader subjects must execute"
print(f"Native public collector sources: {checks} checks, {failures} failures")
raise SystemExit(0 if failures == 0 else 1)
