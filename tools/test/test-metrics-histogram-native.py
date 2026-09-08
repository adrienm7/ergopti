# tools/test/test-metrics-histogram-native.py
"""Exercise both Lua readers against real SQLite grouping, without a desktop."""
import argparse
import datetime
import pathlib
import sqlite3
import subprocess
import tempfile
from contextlib import closing

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--readers-root', type=pathlib.Path, default=root,
                    help='Alternate checkout containing the two reader source files only.')
arguments = parser.parse_args()
tables = ['ngram_chars', 'ngram_bigrams', 'ngram_trigrams', 'ngram_quadgrams',
          'ngram_pentagrams', 'ngram_hexagrams', 'ngram_heptagrams',
          'ngram_words', 'ngram_word_bigrams']
with tempfile.TemporaryDirectory(prefix='ergopti-histogram-regression-') as temporary:
    database = pathlib.Path(temporary) / 'fixture.sqlite'
    with closing(sqlite3.connect(database)) as connection:
        connection.executescript((root / 'static/ergopti_plus/_shared/data/db/schema.sql').read_text())
        for day in ['2020-01-01', datetime.date.today().isoformat()]:
            for app in ['app-a', 'app-b']:
                # Two byte-identical blobs and one distinct blob share a group key.
                # Event totals deliberately differ from both source-row counts and
                # histogram totals: neither is a valid multiplicity substitute.
                for device, count, histogram, sources in [
                    ('one', 11, '{"20":3}', '{"hotstring":2,"llm":3,"other":4,"none":99}'),
                    ('two', 17, '{"20":3}', '{"hotstring":2,"llm":3,"other":4,"none":99}'),
                    ('three', 23, '{"20":1,"50":2}', '{"hotstring":3,"llm":4,"other":5,"none":99}'),
                ]:
                    key = (device, day, app)
                    connection.execute('INSERT INTO agg_app_day_burst(device_id,date,app,count_total,length_buckets_json) VALUES (?,?,?,?,?)',
                                       (*key, count, histogram))
                    connection.execute('INSERT INTO agg_app_day_hourly(device_id,date,app,hour,c,e_buckets_json) VALUES (?,?,?,?,?,?)',
                                       (*key, '12', count, histogram))
                    connection.execute('INSERT INTO agg_app_day_hourly_min5(device_id,date,app,slot,c,e_buckets_json) VALUES (?,?,?,?,?,?)',
                                       (*key, '12:05', count, histogram))
                    for table in tables:
                        connection.execute(f'INSERT INTO {table}(device_id,date,app,token,c,td,e,esrc_json) VALUES (?,?,?,?,?,?,?,?)',
                                           (*key, 'token', count, count * 10, count, sources))
        connection.commit()
    subprocess.run(['luajit', str(root / 'tools/test/metrics-histogram-native.lua'), str(root), str(database),
                    str(arguments.readers_root.resolve())],
                   check=True, timeout=90)
