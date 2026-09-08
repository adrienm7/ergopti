# tools/bench/linux-metrics-reader.py
"""Bounded synthetic SQLite fixture and subprocess evidence; no private inputs."""
import argparse
import contextlib
import json
import pathlib
import resource
import sqlite3
import subprocess
import tempfile
import time
import datetime

parser = argparse.ArgumentParser()
parser.add_argument('--days', type=int, default=7)
parser.add_argument('--apps', type=int, default=3)
parser.add_argument('--events', type=int, default=16, help='Distinct synthetic n-grams per app/day/type')
parser.add_argument('--output', required=True)
args = parser.parse_args()
if not (2 <= args.days <= 730 and 1 <= args.apps <= 64 and 1 <= args.events <= 512):
    parser.error('Require days 2–730, apps 1–64, events 1–512')
if args.days * args.apps * args.events * 9 > 8000000:
    parser.error('Workload exceeds eight million queried n-gram rows')
root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ergopti-linux-metrics-') as temporary:
    database = pathlib.Path(temporary) / 'synthetic.sqlite'
    with contextlib.closing(sqlite3.connect(database)) as connection:
        connection.executescript((root / 'static/ergopti_plus/_shared/data/db/schema.sql').read_text())
        tables = ['ngram_chars', 'ngram_bigrams', 'ngram_trigrams', 'ngram_quadgrams',
                  'ngram_pentagrams', 'ngram_hexagrams', 'ngram_heptagrams',
                  'ngram_words', 'ngram_word_bigrams']
        today = datetime.date.today()
        for day_index in range(args.days):
            day = (today - datetime.timedelta(days=day_index)).isoformat()
            for app_index in range(args.apps):
                app = f'synthetic.app.{app_index}'
                connection.execute('INSERT INTO agg_app_day(device_id,date,app,chars,time_ms) VALUES (?,?,?,?,?)',
                                   ('synthetic', day, app, args.events * 7, args.events * 1000))
                for hour in range(24):
                    connection.execute('INSERT INTO agg_app_day_hourly(device_id,date,app,hour,c) VALUES (?,?,?,?,?)',
                                       ('synthetic', day, app, f'{hour:02}', args.events))
                for table in tables:
                    # Repeated tokens across apps/days exercise production merge arithmetic.
                    connection.executemany(f'INSERT INTO {table}(device_id,date,app,token,c,td,cd,e) VALUES (?,?,?,?,?,?,?,?)',
                                           (('synthetic', day, app, f'synthetic{event}', 7, 700, 7, event % 3)
                                            for event in range(args.events)))
            connection.commit()
    started = time.monotonic()
    result = subprocess.run(['luajit', str(root / 'tools/bench/linux-metrics-reader.lua'), str(root), str(database),
                             str(args.days), str(args.apps), str(args.events)],
                            capture_output=True, text=True, timeout=600, check=True)
    evidence = json.loads(result.stdout)
    evidence.update(database_bytes=database.stat().st_size,
                    workload=dict(days=args.days, apps=args.apps, events_per_app_day_type=args.events,
                                  ngram_rows=args.days * args.apps * args.events * 9,
                                  description='queried synthetic aggregates and nine n-gram tables; not raw event replay'),
                    elapsed_ms=(time.monotonic() - started) * 1000,
                    children_peak_rss_kib=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
                    stderr=result.stderr, sqlite_version=sqlite3.sqlite_version)
    pathlib.Path(args.output).write_text(json.dumps(evidence, indent=2) + '\n')
